import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/cookie_parser.dart';
import '../../core/utils/format.dart';
import '../../core/utils/hls_playlist.dart';
import '../../core/utils/mpv_cache_state.dart';
import '../../core/utils/mpv_subtitle_log.dart';
import '../../core/utils/playback_seek.dart';
import '../../core/utils/player_audio_effect.dart';
import '../../core/utils/player_buffer_progress.dart';
import '../../core/utils/seek_acceleration.dart';
import '../../core/utils/text_encoding.dart';
import '../../core/utils/track_bridge.dart';
import '../../core/utils/track_labels.dart';
import '../../data/playback/fvp_playback_engine.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../../data/stream/dolby_vision_probe.dart';
import '../../data/stream/local_stream_relay.dart';
import '../../domain/adapters/stream_relay.dart';
import '../../domain/entities/playback_preference.dart';
import '../../domain/entities/stream_ticket.dart';
import '../../domain/services/cache_speed_meter.dart';
import '../../domain/services/episode_queue.dart';
import '../../domain/services/intro_marker.dart';
import '../../domain/services/intro_session.dart';
import '../../domain/services/missing_media.dart';
import '../../domain/services/playback_completion.dart';
import '../../domain/services/playback_engine.dart';
import '../../domain/services/playback_engine_router.dart';
import '../../domain/services/playback_resume.dart';
import '../theme/app_theme.dart';
import '../widgets/anchored_menu.dart';
import '../widgets/buffered_slider.dart';
import '../widgets/missing_media_dialog.dart';
import '../widgets/now_playing_bars.dart';
import '../widgets/playback_surface.dart';
import '../widgets/player_keys.dart';
import '../widgets/tv_text.dart';
import 'child_window_channel.dart';
import 'player_protocol.dart';
import 'player_window_bridge.dart';
import 'window_launch.dart';

/// 顶部浮层（片名 + 网盘全路径）的 key。
///
/// 暴露出来只为一件事：**量它的高度**。顶栏的高度随「有没有网盘路径」变
/// （没有路径时少一行），而「少没少那一行」只能靠尺寸断言 ——
/// 找 `MouseRegion` 的第几个、或者数 `Text` 的个数都会随布局调整误报。
const Key topChromeKey = ValueKey('player-top-chrome');

/// 内置自检视频的 asset URI（32 KB，H.264 baseline + AAC，3 秒）。
///
/// 用它而不是「让用户选一个本地文件」是刻意的：走 asset 零权限、零网络，
/// 让「mpv 在这个引擎里到底能不能出画」变成一个不受环境影响的确定性结论 ——
/// 自检要回答的是**解码链路**通不通，不该把「用户挑没挑文件」「沙箱给不给读」
/// 这些变量混进来。
///
/// （应用确实已经申请了 `com.apple.security.files.user-selected.read-only`
/// —— 播放器「加载本地字幕文件」要用，见两份 entitlements。但那是**功能**需要，
/// 不是自检需要的。）
const String kSelfTestAssetUri = 'asset:///assets/player_selftest.mp4';

/// PC 端播放器独立窗口的根组件。
///
/// 它跑在**自己的 Flutter 引擎**里（见 `player_window_bridge.dart` 的说明），
/// 因此：
///   - 不能用主窗口的 Riverpod 容器、不能读主窗口的 Provider；
///   - 需要什么就通过跨窗口通道要 —— 包括「播哪部片」。
///
/// ## 职责边界
///
/// 这个窗口**只负责出画**。取链、鉴权、重试、落库全部留在主窗口：
/// 主窗口把 [PlayRequest]（直链 + 请求头 + 标题 + 本地行号）推过来或放在
/// 待取盒子里，这里拿到就播，并每 10 秒把位置报回去。它甚至不知道「夸克」。
///
/// ## 页面上为什么还留着自检
///
/// 独立窗口一旦出问题（黑屏、没声音），最难的是「哪一环坏了」。自检把
/// 引擎 / 原生插件 / libmpv / 跨引擎通道四件事各自变成一个能一眼看懂的结论，
/// 省掉一轮「猜 + 重跑」。
class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({super.key, required this.launch});

  final WindowLaunch launch;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> {
  final TextEditingController _urlController = TextEditingController();

  /// 默认内核（media_kit）。**`verboseLog` 必须为 true** —— 见 [_ensurePlayer]。
  ///
  /// ⚠️ 它**只服务 mpv 专有能力**：诊断面板读原生属性（`track-list` /
  /// `demuxer-cache-state`），以及音效（`af` / `audio-channels`）。
  /// 起播、切轨、挂字幕、跳章节一律走 [_engine] —— 绕开契约去直接调 mpv 会让
  /// 「清晰度要重取链」「外挂字幕要先解码」这类业务规则被绕过，而且换到 fvp
  /// 内核之后那些调用会打在**一个已经停掉的**播放器上。
  MediaKitPlaybackEngine? _mkEngine;

  /// 内核路由。**选哪个内核**这件事只有一份实现
  /// （见 `PlaybackEngineRouter`）—— 与内置播放页共用。
  PlaybackEngineRouter? _router;

  /// 杜比视界探测（惰性建：只有真的开流时才用得上）。
  ///
  /// 与内置播放页**各自持有一个实例**是有意的：两个播放器跑在两个 Flutter
  /// 引擎里，进程内不共享对象。缓存是「同一个窗口内别重复探同一条流」，
  /// 跨窗口重探一次（一次 256 KiB 的 Range 请求）完全可以接受。
  final DolbyVisionProbe _dvProbe = DolbyVisionProbe();

  /// 当前内核。`null` = 还没建（窗口刚打开）或已经释放。
  PlaybackEngine? get _engine => _router?.engine;

  /// mpv 实例。**只给 mpv 专有能力用**（见 [_mkEngine]）。
  Player? get _player => _mkEngine?.player;

  /// 片头跳过状态机。两个播放器（内置播放页、独立窗口）共用 [IntroSession]，
  /// 状态转移只在它里面写一份 —— 否则会漂移成「内置页跳得对、独立窗口跳得怪」，
  /// 而它们跑在不同的 Flutter 引擎里，用户根本不会想到这是两套代码。
  final IntroSession _introSession = IntroSession();

  List<_SelfCheck> _checks = const <_SelfCheck>[];
  String? _nowPlaying;
  bool _busy = false;

  /// 是否处于全屏。
  ///
  /// **以原生回调为准**（见 [ChildWindowMethod.onFullScreenChanged]）：这里设的
  /// 值只是乐观更新，用来让按钮立刻有反应；系统自己退出全屏（Esc、绿灯、
  /// 三指手势）时会被回调纠正回来。
  bool _fullScreen = false;

  /// 窗口是否置顶。
  ///
  /// 这个没有原生回调 —— 置顶只能由我们自己改，不存在「被系统改掉」的路径，
  /// 所以本地状态就是真相。
  bool _alwaysOnTop = false;

  /// 当前「音效」预设。
  ///
  /// 来源是请求里带的那个字符串（见 `PlayRequest.audioEffect`）—— 播放窗口
  /// 读不到设置库，用户的选择只能由主窗口投过来。用户在本窗口改了之后，
  /// 本地立刻生效并**报回主窗口落库**（见 [PlayerBridgeMethod.saveAudioEffect]），
  /// 下次开窗口才不会又变回默认。
  ///
  /// ⚠️ 与「音轨」无关（音轨是片源里封着的流）。两者的区别见
  /// `core/utils/player_audio_effect.dart` 的类文档。
  AudioEffectPreset _audioEffect = AudioEffectPreset.auto;

  /// 当前是否在播放。控制栏那个播放/暂停按钮跟着它变。
  ///
  /// 不订阅 `stream.playing` 的话，按钮会永远显示「播放」——
  /// 语义正好反过来，点下去才知道错了。
  bool _playing = false;

  /// 控制栏与片名浮层是否可见。
  ///
  /// **默认可见**：窗口刚打开、用户还不知道有哪些操作时，先让他看到按钮。
  /// 之后鼠标一动就重置隐藏倒计时（见 [_pokeChrome]）。
  bool _chromeVisible = true;

  /// 隐藏浮层的倒计时。
  ///
  /// 用「鼠标一停就计时」而不是「离开窗口才隐藏」，是因为用户很可能把鼠标
  /// 停在画面中间看片 —— 那时他并不需要控制栏挡着画面。
  Timer? _hideTimer;

  /// 当前有几个 anchored 菜单浮层开着（画质 / 字幕 / 音轨 / 片头）。
  ///
  /// ## 为什么需要它
  ///
  /// 菜单挂在 **Overlay** 上（`showAnchoredMenu` → `PopupRoute`），位置在播放页
  /// 那个 `MouseRegion` **之外**。而菜单就贴着按钮正上方划出来 —— 用户点开画质
  /// 之后必然把鼠标移到菜单上去选，那一刻 `MouseRegion.onExit` 判定「指针离开了
  /// 窗口内容」，走到 [_hideChrome]：菜单还开着，底部控制栏先没了。用户看到的
  /// 是「点了画质，播放控制栏整体消失」，而菜单孤零零浮在画面上。
  ///
  /// [_cancelHide] 挡不住这条路径：它只取消**倒计时**，而 `onExit` 是即时调用。
  /// 所以用一个计数器把「菜单存续期」标出来，[_hideChrome] 和倒计时回调见到
  /// 它就退回去。用**计数**而不是 bool：字幕菜单会重开（搜完在线字幕 / 挑完
  /// 本地文件都会把同一个菜单再弹一次），嵌套期间必须仍然算「开着」。
  int _menuDepth = 0;

  /// 右侧剧集列表是否展开。
  bool _playlistOpen = false;

  /// 剧集面板本体**是否在树上**。
  ///
  /// 与 [_playlistOpen] 分开的理由是动画：收起时必须先让滑出动画跑完再摘掉
  /// 它，立刻摘掉就只剩「画面变宽」而没有「面板滑走」。
  ///
  /// 但也不能图省事一直挂着 —— 宽度为 0 的面板照样活在树上，测试查得到、
  /// 朗读功能也读得到，等于「收起了但还在」。所以收起后延迟一拍再摘。
  bool _playlistMounted = false;

  /// 摘掉面板的那个延迟。[_togglePlaylist] 每次都会先取消它。
  Timer? _playlistUnmountTimer;

  /// 剧集列表的滚动控制器。
  ///
  /// 存在的唯一理由是**自动定位当前集**：展开列表时要把正在播的那一集滚进
  /// 视野。列表项等高（[_episodeTileHeight]），所以定位就是一次乘法，
  /// 不需要逐项测量。
  final ScrollController _playlistController = ScrollController();

  /// 剧集列表每一项的高度。
  ///
  /// 写成常量而不是让 `ListView` 自己量：自动定位要用它算滚动偏移。
  ///
  /// ⚠️ 它同时是**上限**（`itemExtent` 会把每一项强制成这么高），所以必须
  /// 比「最高的那一项」还高，否则内容溢出去画到面板外面 —— 真机表现成
  /// 「开剧集列表后底部按钮乱飞／被裁」（见 `_buildEpisodeTile` 上方的说明）。
  ///
  /// 按现在的内容算：上下内边距 16 + 两行标题约 30 + 副标题约 15 + 进度条约 8
  /// ≈ 69；缩略图那一支是 54 + 16 = 70。取 96 是给它们留出余量（字体度量
  /// 随平台/字号缩放会变，实测里这几像素的差就是溢出与不溢出的分界）。
  /// 原来是 84（标题只画一行），放开到两行后一起上调。
  static const double _episodeTileHeight = 96;

  /// 剧集列表面板的宽度。
  static const double _playlistWidth = 320;

  /// 剧集面板滑入 / 滑出的时长。
  ///
  /// 面板自身的滑动与画面被挤窄**共用**这一个时长：两者同时在动，错开就会在
  /// 面板和画面之间露出一瞬的黑边（宽度已经让出来了，面板还没滑到）。
  static const Duration _playlistAnimDuration = Duration(milliseconds: 260);

  /// mpv 是否在缓冲（缓存见底、正在等数据）。
  ///
  /// 与 [_awaitingFrame] 的区别：那是「还没出画」（开流到第一帧之间），这是
  /// 「已经出过画、播到一半卡住了」。两者都要显示加载指示，但来源不同。
  bool _buffering = false;

  /// 播放头位置。
  ///
  /// ## 为什么要有它，而不是各处去读 `player.state.position`
  ///
  /// 原来满窗口都在读 `_player!.state.position` —— 那是**内核自己的**状态，
  /// 只有 media_kit 有。换内核之后那个字段就不存在了（fvp 那边只有
  /// `VideoPlayerValue`），所以位置必须由契约的 `position` 流搬进本类。
  ///
  /// ⚠️ 新鲜度**没有损失**：mpv 的 `state.position` 本来就是它内部订阅同一个
  /// 属性流时更新的，两者同一节拍（约 10 Hz）。别为了「更准」再回去读内核。
  ///
  /// ⚠️ 它**不触发重建**（位置流每 100ms 一条，setState 会让整个播放器每秒
  /// 重建十次）。要实时跟手的地方用 `StreamBuilder` 订阅 `engine.position`
  /// （见 [_buildSeekBar]），本字段只服务「按下按键那一刻读一次」这类场景。
  Duration _position = Duration.zero;

  /// 总时长。来源同 [_position]。时长未知时是 0（不是 null）——
  /// 与 mpv / mdk 两边的口径一致，判据统一写成 `> Duration.zero`。
  Duration _duration = Duration.zero;

  /// 是否正在等第一帧 —— 也就是「画面还是黑的」那段时间。
  ///
  /// 光靠 [_busy] 盖不住它：`Player.open()` **不等文件加载完成**（见
  /// [_openStream]），它返回时画面往往还一片黑。这正是「刚打开视频缓冲过程中
  /// 黑屏」的那一段，也是加载指示最该出现的地方。
  ///
  /// 清掉它的信号见 [_ensurePlayer] 里那几条订阅 —— 取「先到的那个」，因为
  /// 没有哪个信号能保证一定来（比如某些流不会触发 video reconfig）。
  bool _awaitingFrame = false;

  /// 本次播放中，mpv 有没有真的报过**非零的视频尺寸**。
  ///
  /// ⚠️ 它是「播完」护栏的证据（见 [PlaybackCompletion]），所以语义要**窄**到
  /// 只有 `videoParams.w > 0` 才置位 —— 不能从 `_awaitingFrame` 反推，
  /// 因为那个标记会被 `duration` / `position` 一起清掉，而两者纯音频流同样
  /// 会给，于是「有声音没画面」会被记成「出过画面」，护栏就失效了。
  ///
  /// 每次换流归零（见 [_openStream]）。
  bool _sawVideoFrame = false;

  /// 这条流有没有已经做过 m3u8 自检（见 [_probeHlsPlaylist]）。
  ///
  /// 每次换流归零。存在的理由就是「一次故障会连着触发好几个钩子」——
  /// 不设闸的话同一条列表会被抓好几遍。
  bool _hlsProbed = false;

  /// 「转码档开了 N 秒还没出画面」那次延迟检查的定时器（见
  /// [_scheduleHlsSettleCheck]）。
  Timer? _hlsSettleTimer;

  /// 转码档开流后，隔多久回来验一次「到底出画面了没有」。
  ///
  /// 10 秒是个折中：HLS 要先取 m3u8 再取前几个分片，正常起播在这之内；
  /// 而真的坏了的话，10 秒时 mpv 的错误日志已经写满，`track-list` 也稳定了。
  static const Duration hlsSettleDelay = Duration(seconds: 10);

  /// 排一次「转码档开流后仍无画面」的延迟检查。
  ///
  /// ## 为什么不能只靠现有的那几个钩子
  ///
  /// 实测（2026-10-04 14:29 那份日志）：`_onTicketExpiryLog` 在 `open()` 之后
  /// **46 毫秒**就把诊断打了出来，那时 mpv 还没开始读 m3u8 —— `track-list`
  /// 必然是 `[]`、`duration` 必然是空。**证据全在，只是取早了**，等于白打。
  ///
  /// 所以补这一条**按时间**触发的路：开流满 [hlsSettleDelay] 后如果
  /// [_sawVideoFrame] 还是 false，再落一次诊断 —— 那时拿到的才是
  /// 「流里到底有没有视频轨」这个真正能定性的结论。
  ///
  /// 只在 [PlayRequest.isHls] 的流上排：原画是直链文件，10 秒不出画面通常
  /// 只是网慢，没必要刷诊断。
  void _scheduleHlsSettleCheck() {
    _hlsSettleTimer?.cancel();
    _hlsSettleTimer = null;
    if (!mounted || _engine == null) return;
    if (!(_currentRequest?.isHls ?? false)) return;
    _hlsSettleTimer = Timer(hlsSettleDelay, () {
      _hlsSettleTimer = null;
      if (!mounted || _sawVideoFrame) return;
      if (!(_currentRequest?.isHls ?? false)) return;
      unawaited(_dumpPlaybackDiagnostics('转码档开流 ${hlsSettleDelay.inSeconds} 秒仍没出画面'));
    });
  }

  /// mpv 日志的**尾巴**（环形缓冲，只留最近 [mpvLogTailSize] 条）。
  ///
  /// ## 为什么要有它
  ///
  /// `stream.log` 一路订阅原本只喂给两个过滤器（字幕、HTTP 4xx），**其余全部
  /// 丢掉** —— 于是「转码档只有声音没画面」这类故障在诊断日志里**一条痕迹
  /// 都没有**，只能靠猜。而 mpv 自己通常是说了原因的（`vd:` / `ffmpeg/demuxer`
  /// 那些行），只是没人把它写下来。
  ///
  /// 缓冲而不是全量落盘：mpv 的日志在 warn 级下本来就不多，但一次播放里
  /// 也够刷屏了。只留最近一段，在**出事的那一刻**再落盘（见
  /// [_dumpPlaybackDiagnostics]），既拿得到上下文，又不会把日志撑爆。
  final List<String> _mpvLogTail = <String>[];

  /// mpv 日志缓冲的条数上限。
  static const int mpvLogTailSize = 120;

  /// 正在**换一条流**（切清晰度 / 切集 / 刷新过期直链），而不是首次开播。
  ///
  /// ## 为什么不能复用 [_awaitingFrame]
  ///
  /// 两者的差别是「画面还在不在」：
  ///   - 首次开播：画面本来就是黑的，[_awaitingFrame] 用一个**不透明**的罩子
  ///     把黑盖住，用户看到的是「正在载入片源…」；
  ///   - 换流：mpv 的视频输出**保留着上一帧**，罩子只需压一层半透明 ——
  ///     全盖掉等于把用户正在看的那一帧也抹了，看起来就是「重新缓存了一遍」。
  ///
  /// 所以换流时不设 [_awaitingFrame]、不清缓冲，只立这个标记；收掉它的信号
  /// 与 [_awaitingFrame] 同源（见 [_clearAwaitingFrame]）。
  bool _switching = false;

  /// 网盘字幕正文的预取缓存（fileId → 正文）。见 [_prefetchCloudSubtitles]。
  ///
  /// 换片 / 换集时清空：字幕是**跟着条目**的，留着上一部的正文既没用又占内存。
  final Map<String, String> _subtitleTextCache = <String, String>{};

  /// 正在预取的网盘字幕 fileId（防重复请求）。
  final Set<String> _subtitlePrefetching = <String>{};

  /// 缓冲覆盖到的**绝对位置**（mpv 的 `demuxer-cache-time`）。
  ///
  /// ⚠️ 它是**时间戳**，不是「播放头前面还有多少秒」：mpv 手册写的是
  /// 「returns the **last timestamp** of buffered data in demuxer」，
  /// 源码里对应 `demux_reader_state.ts_end`。别再加播放头 —— 加了等于把
  /// 播放头算两遍，症状是「一跳进度条缓冲层就凭空长出一大截」
  /// （详见 [PlayerBufferProgress]）。
  ///
  /// 要「还能看多少秒」得自己减 `position`，见 [_cacheStatusLine]。
  Duration _cacheEnd = Duration.zero;

  /// 缓存速度：**每秒能缓存多少秒视频**。null = 还没算出来。
  ///
  /// 单位看着别扭但很关键 —— `1.0×` 正好是「下载与播放持平」的分界线，
  /// 低于它就迟早再卡一次。KB/s 是 [_cacheBytesPerSecond] 的事。
  ///
  /// ⚠️ 读它请用 [_currentCacheRate]：本字段**不会**因为「太久没新样本」而
  /// 失效，直接读会把一个过时的尖峰一直印在界面上。
  double? _cacheRate;

  /// [_cacheRate] 最近一次被刷新的时刻，配合 [_currentCacheRate] 做过期。
  ///
  /// 为什么需要过期：`_cacheRate` 只在算出新值时才更新（`null` 时保留旧值，
  /// 否则数字会一格一格地闪）。可一旦 mpv 停止发 `demuxer-cache-time`
  /// （缓存填满、片源结束），那个旧值就**永远留在界面上** —— 若它恰好是一个
  /// 尖峰，用户就会长时间看着一个假数字（「缓冲 1.0 GB/s」的观感由此而来）。
  DateTime? _cacheRateAt;

  /// 缓存倍速的有效期。超过它没刷新就当没测到。
  static const Duration _cacheRateStaleAfter = Duration(seconds: 5);

  /// mpv 直接给的**输入速率**（字节/秒，`demuxer-cache-state.raw-input-rate`）。
  ///
  /// 这是**真实下载速率**，不是估算：有它就不必再乘平均码率，也就顺带消掉了
  /// 「播转码档时码率对不上」那个偏差。拿不到时为 null，那时退回
  /// [_cacheBytesPerSecond] 的估算值。解析见 [rawInputBytesPerSecond]。
  double? _netBytesPerSecond;

  /// 当前**可信**的缓存倍速。
  double? get _currentCacheRate {
    final at = _cacheRateAt;
    final rate = _cacheRate;
    if (rate == null || at == null) return null;
    if (DateTime.now().difference(at) > _cacheRateStaleAfter) return null;
    return rate;
  }

  /// mpv 自己的「初始填充」百分比（0~100，`cache-buffering-state`）。
  ///
  /// ⚠️ **只在开播填充那一段有意义**：填满之后它就停在 100 不再变。所以进度条
  /// 用它，填完（或它不在 0~100 之间）之后退回不确定态，别让进度条一直顶在
  /// 100% 假装还在加载。
  double? _cacheFill;

  /// 缓存速度的估算器。换片源 / seek 时要 [CacheSpeedMeter.reset]。
  final CacheSpeedMeter _cacheMeter = CacheSpeedMeter();

  /// 鼠标静止多久后隐藏浮层。
  static const Duration _chromeIdleTimeout = Duration(seconds: 3);

  /// 是否正在看诊断面板。
  ///
  /// 自检与调试按钮**默认藏起来**：播放窗口的主职是出画，一堆日志和按钮
  /// 摆在画面下面既占地方又容易让人以为播放器坏了。
  bool _showDiagnostics = false;

  /// 拖动进度条时的预览位置。
  ///
  /// 拖拽过程中不能直接 seek（会把 mpv 拖垮，而且松手前的位置没有意义），
  /// 所以先记在这里让滑块跟手，松手时才真正 `seek`。
  Duration? _seekPreview;

  /// 本窗口有没有成功注册为跨引擎通道的配对一方。
  bool _channelReady = false;
  String? _channelError;

  /// 进度回报的节流器（每 10 秒一次）。
  final ProgressThrottle _progressThrottle = ProgressThrottle();

  /// 「刷新直链」的重试闸。
  final TicketRefreshGuard _refreshGuard = TicketRefreshGuard();

  /// 当前这条流对应的请求。
  ///
  /// null 表示**没有对应的库记录**（内置自检视频 / 手输直链）—— 此时既不
  /// 回报进度，也没有可刷新的来源。
  ///
  /// 用一个对象而不是几个散字段（itemId / qualityId / …）：它们必须同时有效
  /// 才有意义，拆开就容易出现「清了 itemId 忘了清 qualityId」这种半有效状态。
  PlayRequest? _currentRequest;

  /// 是否正在刷新直链。
  ///
  /// **与 [_busy] 分开**：`_busy` 是给按钮看的（禁用态），这条是防重入的。
  /// 混用会吞掉该有的刷新 —— 直链过期导致的 mpv 报错经常在上一次 `open()`
  /// 还没返回时就到了，那时 `_busy` 是 true。
  bool _refreshing = false;

  /// **mpv 专有**的流订阅（日志尾巴、诊断）。释放时要显式取消。
  ///
  /// 与 [_engineSubs] 分开是有意的：这一份挂在 `MediaKitPlaybackEngine.player`
  /// 上，**换内核时不动**（它是诊断素材，与当前在播的内核无关）；
  /// 而 [_engineSubs] 每次换内核都必须重接（契约的流广播且不重放）。
  final List<StreamSubscription<Object?>> _subs = [];

  /// **契约**的事件订阅。**换内核时必须整批重接**（见 [_bindEngine]）。
  final List<StreamSubscription<Object?>> _engineSubs = [];

  // -------------------------------------------------------------------
  // 音轨 / 字幕
  // -------------------------------------------------------------------

  /// mpv 报上来的**真实**音轨。
  ///
  /// 「真实」是关键词：容器打开之前它是空的 —— mpv 要先解出容器才知道里面
  /// 有什么。所以菜单刚打开时没有音轨**不是 bug**，是流还没解析完。
  List<AudioTrack> _audioTracks = const [];

  /// mpv 报上来的**真实**内嵌字幕轨。
  List<SubtitleTrack> _embeddedSubtitles = const [];

  /// 上一次已经落过日志的字幕轨清单，用来给 [_onTracks] 去重。
  ///
  /// `stream.tracks` 每次轨道变动都会发一遍（打开文件、切轨、探到新信息），
  /// 不挡一下会把同一份清单反复写进诊断日志 —— 而那份日志是给用户整段
  /// 复制粘贴的，刷屏会把它变得没法看。
  String? _loggedSubtitleInventory;

  /// 这一条片子的播放偏好（逐文件，见 `PlaybackPreference`）。
  ///
  /// 与内置播放页（`player_page.dart`）**共用同一张表与同一套语义**：用户在这边
  /// 换的字幕，下次在电视上打开同一集照样生效。窗口只**读它来还原**，用户改了
  /// 什么就报回主窗口落库（见 [_savePreference]）—— 它自己不碰数据库。
  PlaybackPreference _pref = const PlaybackPreference();

  /// 音轨还原只做一次。
  ///
  /// 理由与内置播放页那份相同：`stream.tracks` 在换流与切轨时都会再发一遍，
  /// 无闸的话用户刚手动切完就被顶回偏好里那一条 —— 表现是「切了没反应」，
  /// 而日志里一切正常。
  bool _audioRestored = false;

  /// 字幕还原只做一次。同上。
  bool _subtitleRestored = false;

  /// 当前选中的音轨 id（[AudioTrack.id]）。
  ///
  /// **以 mpv 回报为准**（`player.stream.track`），不在点击时乐观更新：
  /// 切轨可能失败（不存在、容器不支持），乐观更新会让菜单打勾在错误的那一条上，
  /// 而用户完全没有察觉。
  String? _activeAudioId;

  /// 当前选中的内嵌字幕轨号。`null` = 字幕关着。
  int? _activeSubtitleId;

  /// 当前选中的**网盘**字幕的 fileId。`null` = 没选。
  ///
  /// 与 [_activeSubtitleId] 分开记账，是因为 mpv 回报的「当前字幕轨」**认不出
  /// 我们后挂上去的外挂字幕是哪一条** —— 它只知道现在有一条字幕轨处于选中态。
  /// 靠那一个字段去高亮，菜单会在「内嵌轨 2」上打勾，而实际显示的是网盘字幕。
  String? _activeCloudSubtitleId;

  /// 当前选中的**在线**字幕的 fileId。`null` = 没选。理由同上。
  int? _activeOnlineSubtitleId;

  /// 用户挑中的本地字幕文件。`null` = 还没挑过。
  ///
  /// 留着它是为了「下次开菜单还能一眼选回来」：本地字幕不进库、也不进
  /// `PlayRequest`（它跟片子无关，是用户临时挂的），不留就每次都要重新走一遍
  /// 文件选择器。
  _LocalSubtitle? _localSubtitle;

  /// 当前挂着的本地字幕的路径。`null` = 没挂。
  ///
  /// 与 [_localSubtitle] 分开：挑过之后又切到别的字幕时，前者要留着（还能选
  /// 回来），后者要清掉（不然菜单会在一条已经不在播的字幕上打勾）。
  String? _activeLocalPath;

  /// 上一次「搜索在线字幕」的结果。
  ///
  /// **留在窗口里、换片才清**，不是每次开菜单都重搜：字幕站有每日额度
  /// （OpenSubtitles 免费档只有个位数），而用户「打开菜单看一眼有什么」
  /// 的次数远多于「真的要换一条」。每次开菜单都打一次接口，一天下来额度
  /// 会在用户毫无察觉的情况下烧光 —— 而那时的表现是「下载失败」，
  /// 与「搜索」看起来毫无关系。
  List<OnlineSubtitleBrief> _onlineSubtitles = const [];

  /// 正在搜。菜单里那一条要显示成「搜索中…」并且不能再点。
  bool _searchingOnlineSubtitles = false;

  /// 本地流式中继。
  ///
  /// ⚠️ 它跑在**播放窗口这个引擎里**，不是主窗口那边：独立窗口是另一个
  /// Flutter 引擎，够不到主进程的 provider。放本地也让「关掉主窗口、继续在
  /// 播放窗口里看」照常成立 —— 中继不会跟着主窗口一起消失。
  ///
  /// 配置由主窗口随**每条请求**投过来（见 `PlayRequest.streamRelay`），
  /// 在 [_prepareSource] 里应用。这里的默认值只是「第一次播放之前」的初值。
  final LocalStreamRelay _relay = LocalStreamRelay();

  /// 当前中继会话标识。换源时必须先关掉旧的（理由见 [_prepareSource]）。
  String? _relayToken;

  @override
  void initState() {
    super.initState();
    // 引导流程要碰平台通道，放到首帧之后 —— 在 initState 里直接 await 会让
    // 第一帧迟迟出不来，窗口看起来像卡住了。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _urlController.dispose();
    // 隐藏浮层的倒计时必须在这里掐掉：它到点会 `setState`，而那时 element
    // 已经在拆了。测试里则会表现成「A Timer is still pending」。
    _hideTimer?.cancel();
    _playlistUnmountTimer?.cancel();
    _hlsSettleTimer?.cancel();
    _playlistController.dispose();
    // 关掉中继服务本体（含监听端口与所有会话）。只关当前会话是不够的：
    // 换源路径上的旧会话如果没被清掉，端口会一直挂着。
    unawaited(_relay.dispose());
    unawaited(_releasePlayer());

    // ⚠️ 这行日志是**探针**，不要当成普通日志删掉。
    //
    // `desktop_multi_window` 的 macOS 侧在关窗时只做
    // `MultiWindowManager.removeWindow(windowId:)`（见插件 `FlutterWindow.swift`
    // 的 `NSWindow.willCloseNotification` 观察者）—— 它**不通知 Dart**。
    //
    // 所以「关窗后声音还在放吗」取决于引擎到底有没有被销毁：
    //   1. 引擎随窗口销毁 → 本方法执行 → 这行会出现在日志里；
    //   2. 引擎不销毁 → 本方法不执行 → 日志里没有这行。
    // 关窗后去诊断页搜「播放窗口已释放」即可判定。
    //
    // 无论哪种情况，原生侧的 `windowWillClose` 都会发一次 `onClosing`
    // （见 `child_window_channel.dart`），以及页面上那个「停止并关闭」
    // 按钮会走确定性的释放路径。
    diag.info('播放窗口', '播放窗口已释放（dispose 执行了）');

    super.dispose();
  }

  // -------------------------------------------------------------------
  // 释放
  // -------------------------------------------------------------------

  /// 停止播放并释放两个内核。**幂等**。
  ///
  /// 三条路都会走到这里，而且它们会互相重叠（关窗通知 + dispose 常常
  /// 前后脚发生），所以必须幂等 —— 重复 `dispose()` 一个已释放的 [Player]
  /// 会抛。
  ///
  /// **不调用 `setState`**：它可能从 `dispose()` 里被调到。
  Future<void> _releasePlayer() async {
    final router = _router;
    if (router == null) return;
    _router = null;
    _mkEngine = null;
    _currentRequest = null;
    _refreshing = false;
    _refreshGuard.reset();

    // 先取消订阅：否则 dispose 过程中还可能触发一次进度回报，
    // 而那会在通道上打一条指向已释放播放器的消息。
    //
    // ⚠️ 契约订阅（[_engineSubs]）也要一起取消 —— 两个内核的事件流都会在
    // `dispose()` 里被 close，留着订阅会在关闭时抛。
    for (final sub in [..._subs, ..._engineSubs]) {
      await sub.cancel();
    }
    _subs.clear();
    _engineSubs.clear();

    try {
      // 先 stop 再 dispose：stop 会释放解码器与网络连接，
      // 让 dispose 之后的清理更快、更干净。
      //
      // ⚠️ 先停**当前**内核：DV 片源上它就是 fvp，而 `router.dispose()` 只会
      // dispose 两个内核（mdk 那条路上「停住」与「销毁」不是一回事）。
      await router.engine.stop();
    } catch (_) {
      // 引擎可能已经在拆了。停不下来不影响下一步的 dispose。
    }
    try {
      // 两个内核一起释放（路由自己知道有几个）。
      await router.dispose();
      diag.info('播放窗口', '已释放播放器（stop + dispose）');
    } catch (e) {
      diag.warn('播放窗口', '释放播放器失败：$e');
    }
  }

  /// 先释放再关窗。**这是确定性的那条路** —— 不依赖关窗通知的时序。
  Future<void> _stopAndClose() async {
    await _releasePlayer();
    await closeChildWindow();
  }

  // -------------------------------------------------------------------
  // 窗口形态：全屏 / 置顶
  // -------------------------------------------------------------------

  /// 原生回报的全屏状态变化。
  ///
  /// 存在的意义是「**系统自己退出了全屏**」这条路 —— 按 Esc、点绿灯、
  /// 三指手势都不经过我们的通道。少了它，界面会一直以为自己还在全屏，
  /// 于是那条全屏退出栏继续挂在窗口底下，而窗口已经变回带标题栏的形态。
  Future<void> _onFullScreenChanged(bool fullScreen) async {
    if (!mounted || _fullScreen == fullScreen) return;
    setState(() => _fullScreen = fullScreen);
  }

  /// 切换全屏。
  Future<void> _setFullScreen(bool on) async {
    if (!mounted) return;
    // 先本地置上：原生那边是全屏**动画**，等回调再刷新按钮会让它迟一拍。
    // 真状态仍以 [_onFullScreenChanged] 为准。
    final previous = _fullScreen;
    setState(() => _fullScreen = on);

    if (await setChildWindowFullScreen(on)) return;

    // 原生侧没接上（通道没装好 / 平台不支持）→ 把界面回滚。
    // 不回滚的话按钮会显示「已全屏」而窗口纹丝不动，用户只会觉得按钮坏了。
    if (!mounted) return;
    setState(() => _fullScreen = previous);
    _toast('当前平台不支持切换全屏');
  }

  /// 切换置顶。
  Future<void> _setAlwaysOnTop(bool on) async {
    if (!mounted) return;
    final previous = _alwaysOnTop;
    setState(() => _alwaysOnTop = on);

    if (await setChildWindowAlwaysOnTop(on)) return;

    if (!mounted) return;
    setState(() => _alwaysOnTop = previous);
    _toast('当前平台不支持窗口置顶');
  }

  // -------------------------------------------------------------------
  // 引导：装关窗回调 → 入场 → 拉请求 → 自检
  // -------------------------------------------------------------------

  Future<void> _bootstrap() async {
    // 原生通知要**最先**装：万一窗口起得很慢、用户在引导完成前就把它关了，
    // 也还有机会释放。
    //
    // ⚠️ 两个回调必须**一次装完**：`setMethodCallHandler` 是覆盖式的，
    // 分两次装会让先装的那个静默失效。
    await registerChildWindowHandlers(
      onClosing: _releasePlayer,
      onFullScreenChanged: _onFullScreenChanged,
    );

    // 顺序是硬要求，不能换：
    //   1. 先入场（注册跨引擎通道）。原生侧要求**调用方自己也在配对里**，
    //      不先注册就去拉请求，拿到的一定是 `CHANNEL_UNREGISTERED`。
    //   2. 再拉待播请求（新窗口必须走这条，理由见 bridge 里的说明）。
    //   3. 最后自检 —— 它要 ping，也需要通道已经入场。
    await _enterChannel();
    final request = await _pullPendingPlay();
    if (request != null) unawaited(_playRequest(request));
    await _runSelfCheck();

    // 浮层先露着，几秒后自动收起。
    //
    // 这一句不能省：`_chromeVisible` 初值是 true，但**倒计时只有
    // [_pokeChrome] 会起** —— 不在这里起一次的话，浮层会一直挂在那儿，
    // 直到用户第一次移动鼠标才开始「几秒后自动隐藏」。而「窗口刚打开、
    // 鼠标还没动」正是最该自动收起的那段时间。
    _pokeChrome();
  }

  /// 注册为跨引擎通道的配对一方。返回是否成功。
  Future<bool> _enterChannel() async {
    try {
      await playerWindowChannel.setMethodCallHandler(_onMainWindowCall);
      _channelReady = true;
      _channelError = null;
      return true;
    } on WindowChannelException catch (e) {
      _channelReady = false;
      _channelError = '${e.code}：${e.message}';
      return false;
    } catch (e) {
      _channelReady = false;
      _channelError = '$e';
      return false;
    }
  }

  /// 主窗口发过来的请求。
  ///
  /// 协议层面的事情（心跳）交给 [handleMainWindowCall]，这里只加**行为**：
  /// 「播这个」要真的去操作播放器。
  Future<Object?> _onMainWindowCall(MethodCall call) async {
    if (call.method == PlayerBridgeMethod.play) {
      final request = PlayRequest.fromJson(call.arguments);
      if (request == null) {
        diag.warn('播放窗口', '收到解不开的播放请求，忽略');
        return null;
      }
      diag.info('播放窗口', '主窗口推来播放请求：${request.describe()}');
      unawaited(_playRequest(request));
      return null;
    }
    return handleMainWindowCall(call);
  }

  /// 向主窗口要那条「开窗时就该播」的请求。
  Future<PlayRequest?> _pullPendingPlay() async {
    if (_channelReady) {
      try {
        final raw = await playerWindowChannel
            .invokeMethod<Object?>(PlayerBridgeMethod.fetchPendingPlay);
        final request = PlayRequest.fromJson(raw);
        if (request != null) {
          diag.info('播放窗口', '从主窗口取到播放请求：${request.describe()}');
          return request;
        }
      } catch (e) {
        diag.warn('播放窗口', '拉取待播请求失败：$e');
      }
    }
    // 拉不到就退回**启动参数**里那份兜底：主窗口建窗时一并塞进了入口参数。
    // 这条路不依赖通道，所以通道真出问题时窗口至少还能把片播出来。
    return PlayRequest.fromJson(widget.launch.payload);
  }

  // -------------------------------------------------------------------
  // 自检
  // -------------------------------------------------------------------

  Future<void> _runSelfCheck() async {
    final checks = <_SelfCheck>[];

    checks.add(
      _SelfCheck(
        '窗口引擎',
        widget.launch.windowId.isEmpty
            ? '已启动，但没拿到 windowId'
            : 'windowId = ${widget.launch.windowId}',
        ok: true,
      ),
    );

    // path_provider 是「原生插件有没有在**这个引擎**上注册成功」最直接的证据：
    // 子窗口是独立引擎，`MainFlutterWindow.swift` 里那句
    // `RegisterGeneratedPlugins(registry: controller)` 没生效的话，
    // 这里会抛 MissingPluginException。
    try {
      final dir = await getApplicationSupportDirectory();
      checks.add(_SelfCheck('原生插件注册', dir.path, ok: true));
    } catch (e) {
      checks.add(_SelfCheck('原生插件注册', '$e', ok: false));
    }

    // mpv：`Player()` 的构造会去加载 libmpv。这一步过了，说明整个媒体栈在
    // 这个引擎里可用；过不了，播放窗口就没有存在的意义。
    try {
      _ensurePlayer();
      checks.add(const _SelfCheck('libmpv', 'Player 构造成功', ok: true));
    } catch (e) {
      checks.add(_SelfCheck('libmpv', '$e', ok: false));
    }

    checks.add(
      _SelfCheck(
        '通道入场（本窗口）',
        _channelReady ? '已注册为配对的一方' : (_channelError ?? '未注册'),
        ok: _channelReady,
      ),
    );

    // 跨引擎通道：这是**唯一**能证明两个引擎真的连上了的证据 ——
    // 引擎起得来、插件注册得上，都不代表通道通。
    if (_channelReady) {
      try {
        final reply = await playerWindowChannel
            .invokeMethod<String>(PlayerBridgeMethod.ping);
        checks.add(_SelfCheck('跨引擎通道', '主窗口回话：$reply', ok: true));
      } on WindowChannelException catch (e) {
        checks.add(_SelfCheck('跨引擎通道', '${e.code}：${e.message}', ok: false));
      } catch (e) {
        checks.add(_SelfCheck('跨引擎通道', '$e', ok: false));
      }
    } else {
      checks.add(const _SelfCheck('跨引擎通道', '跳过：本窗口没入场', ok: false));
    }

    if (!mounted) return;
    setState(() => _checks = checks);
  }

  /// 惰性建内核与路由。
  ///
  /// 两条硬约束（都是踩过的坑）：
  ///   1. 渲染句柄必须绑定到**正在播放的那个**播放器实例，不能另建一个
  ///      （`MediaKitPlaybackEngine` 的构造函数里就是这么做的，见那边的注释）；
  ///   2. 必须在任何 `open()` 之前建出来。
  /// 违反任一条的表现都是「有声音、进度条在走，但画面全黑，且不报错」。
  ///
  /// ⚠️ 第 1 条在**换内核**之后仍然成立：DV 片源切到 fvp 时，渲染句柄也跟着
  /// 换成 fvp 那个（见 `PlaybackSurface`），不会出现「解码在新内核、出画在旧
  /// 内核」——那正是上面那个症状。
  void _ensurePlayer() {
    if (_router != null) return;

    // ⚠️ `verboseLog: true` 是**必要条件**，不是「顺手多要点日志」——
    // 完整实测记录见 [isHttp4xxLog] 的文档。
    //
    // 一句话：`mpv_request_log_messages` 的语义是「该级别**及以上严重**的消息
    // 才发」，而实测 `HTTP error 403` 是 **warn** 级（比 error 轻）。media_kit
    // 默认是 `MPVLogLevel.error`，那条消息**根本不会被发送到 Dart**。
    //
    // 抬到 warn 只影响日志流的流量（warn 级本来就很少），`error` 流完全不受
    // 影响：media_kit 仍然只挑 `level == 'error'` 的。
    //
    // 缓冲参数与 `libass` 那两条开关都在引擎的构造函数里（它们曾经长在这里，
    // 搬进引擎是为了让「两个播放器的 mpv 配置」只有一份）。
    //
    // 独立播放窗口只存在于桌面（`supportsMultiWindow` 已排除 Android），
    // 所以 `tv` 永远是 false。
    final engine = MediaKitPlaybackEngine(tv: false, verboseLog: true);
    _mkEngine = engine;
    _router = PlaybackEngineRouter(
      defaultEngine: engine,
      // ⚠️ 这两项必须与 `main.dart` 里的 `fvp.registerWith` **同一个判据**。
      // 少了 `registerWith`，fvp 的 macOS 平台实现不会注册，DV 片源会照常
      // 走官方那套栈 —— 也就是「偏绿，且不报任何错」。
      dolbyVisionEngine: Platform.isMacOS ? FvpPlaybackEngine.new : null,
      dolbyVisionProbe: Platform.isMacOS ? _dvProbe.probe : null,
      logTag: '播放窗口',
    );

    _bindEngine(_router!.engine);

    // mpv 的**原始**日志尾巴（带 level / prefix）。
    //
    // ## 为什么这条不走契约的 `log` 流
    //
    // 契约的 `log` 是 `Stream<String>`，服务的是**业务过滤器**（字幕解码诊断、
    // 直链过期）。而尾巴是**诊断面板的原始素材**，它唯一的消费者
    // [_dumpPlaybackDiagnostics] 本身就是 100% mpv 的（读 `track-list` /
    // `demuxer-cache-state` 这些 mpv 属性）。丢掉 level 与 prefix 会让
    // 「哪一子系统报的、多严重」在日志里消失，而那正是排查时要看的东西。
    //
    // 代价是换到 fvp 内核后这条流会静默（mpv 已经停了）—— 那没关系：
    // mdk 本来就没有日志通道，DV 片源上这份尾巴注定是空的。
    _subs.add(engine.player.stream.log.listen(_appendMpvLog));
  }

  /// 把订阅接到 [engine] 上。**换内核时必须重新接** —— 契约的流都是广播且
  /// **不重放**（见 `PlaybackEngine` 的类文档），晚一步这一整集就收不到任何
  /// 事件，表现是「画面在动，但进度条、音轨菜单、暂停按钮全是死的」。
  void _bindEngine(PlaybackEngine engine) {
    for (final s in _engineSubs) {
      unawaited(s.cancel());
    }
    _engineSubs.clear();

    // 进度回报。挂在 `position` 上而不是用计时器：位置流本身就是「播到哪了」
    // 的唯一真相，用计时器反而要在暂停时额外判断。
    _engineSubs.add(
      engine.position.listen((position) {
        _position = position;
        unawaited(_onPosition(position));
      }),
    );

    // 「出画了」的信号。**三个都听，取先到的那个**：
    //
    //   - `videoSize`：内核要解出第一帧才能定输出格式，所以它是**最准**的
    //     「有画面了」；
    //   - `duration` / `position`：兜底。不是每种流都会触发 video reconfig
    //     （比如纯音频），只认那一个的话加载指示会永远挂在屏幕上。
    //
    // 代价是最多早收一两秒（duration 通常在解码开始前就已知），但
    // 「永远不收」比「早收」糟得多。
    _engineSubs.add(
      engine.videoSize.listen((size) {
        if (!size.hasVideo) return;
        _clearAwaitingFrame();
        // ⚠️ 这一位是「播完」护栏的证据（见 [PlaybackCompletion]），
        // **不能**用 `_awaitingFrame` 代替它 —— 后者也会被
        // `duration` / `position` 清掉，而那两者纯音频流同样会给，
        // 于是「有声音没画面」会被误记成「出过画面」。
        _sawVideoFrame = true;
      }),
    );
    _engineSubs.add(
      engine.duration.listen((d) {
        if (d == _duration) return;
        _duration = d;
        if (d > Duration.zero) _clearAwaitingFrame();
      }),
    );
    _engineSubs.add(
      engine.position.listen((p) {
        if (p > Duration.zero) _clearAwaitingFrame();
      }),
    );

    // 播放错误。内核的报错很笼统（`Failed to open ...`），但对用户来说
    // 「播不了」这个结论是准确的 —— 具体原因看诊断日志。
    //
    // ⚠️ 这里**不只是记日志**：网盘直链是带签名的临时 URL，过期后的表现正是
    // 一条报错（拖进度条会重新发 Range 请求，所以最常见的症状是
    // 「播到一半一拖就报错」）。
    //
    // 但这条路只是过期检测的**一半**：它拿到的是二级症状（`Failed to open`），
    // 一级证据（HTTP 4xx）走下面那条 `log`。两者分工见 [isHttp4xxLog]。
    _engineSubs.add(
      engine.error.listen((msg) {
        unawaited(_onPlayerError(msg));
      }),
    );

    // 内核日志。这条订阅是过期检测的另一半：
    //
    // `error` 流看不到最直接的那条证据（`http: HTTP error 4xx`），
    // 原因是**级别**（实测它是 warn，而 media_kit 默认只请求 error）叠加上
    // media_kit 自己的前缀过滤。详见 [isHttp4xxLog] 顶部的实测记录。
    //
    // ⚠️ 它能不能收到东西，取决于 `_ensurePlayer` 里 `verboseLog: true`。
    // 两处是**配套**的，改一处必须改另一处。
    _engineSubs.add(
      engine.log.listen((text) {
        // ⚠️ 字幕消息要**先分流**，不能混进下面那条「直链过期」的路：
        // 字幕解不开跟直链没有半点关系，走进去只会白白刷一次链
        // （刷完还是解不开，而用户会看到画质档位莫名其妙地跳了一下）。
        //
        // 它也不能靠 `error` 那条路兜底 —— 那句话里既没有 `failed`
        // 也没有 `error`，详见 [isSubtitleDiagnosticLog]。
        if (isSubtitleDiagnosticLog(text)) {
          diag.warn('播放窗口', '内核字幕：${redactUrls(text)}');
          return;
        }
        if (!isHttp4xxLog(text)) return;
        unawaited(_onTicketExpiryLog(text));
      }),
    );

    // 播放/暂停状态。控制栏那个按钮要跟着它变 —— 否则会一直显示
    // 「播放」而实际在播放，语义正好反过来。
    _engineSubs.add(
      engine.playing.listen((playing) {
        if (!mounted || _playing == playing) return;
        setState(() => _playing = playing);
      }),
    );

    // 缓冲状态。播到一半缓存见底时内核会自己停下来等数据，画面是静止的 ——
    // 不告诉用户「在等」，他只会以为播放器卡死了。
    _engineSubs.add(
      engine.buffering.listen((buffering) {
        if (!mounted || _buffering == buffering) return;
        setState(() => _buffering = buffering);
      }),
    );

    // 缓存量。缓冲指示上「已缓存多少秒」和「速度」两个数都来自这里。
    //
    // ⚠️ 它是**绝对时间戳**（mpv `demuxer-cache-time`），不是「前面还有多少
    // 秒」。直接拿它当增量会把播放头算两遍 —— 见 [PlayerBufferProgress]。
    // 速度那边靠**求差**，整体偏移不影响结果。
    //
    // 速度算不出来时**保留上一次的值**：返回 null 只是「这一拍样本不够」，
    // 清成 0 会让数字一格一格地闪，比一直显示同一个旧值更难看。
    _engineSubs.add(
      engine.bufferEnd.listen((end) {
        final rate = _cacheMeter.accept(end);
        if (!mounted) return;
        setState(() {
          _cacheEnd = end;
          if (rate != null) {
            _cacheRate = rate;
            // 时间戳跟着值一起走：[_currentCacheRate] 靠它判断这一份还新不新。
            _cacheRateAt = DateTime.now();
          }
        });
      }),
    );

    // 初始填充的百分比。见 [_cacheFill] 那条注释：只在 0~100 之间时可信。
    _engineSubs.add(
      engine.bufferingPercentage.listen((percent) {
        if (!mounted) return;
        setState(() => _cacheFill = percent);
      }),
    );

    // 音轨与内嵌字幕轨的清单。
    //
    // 这是「菜单里到底有哪些选项」的唯一来源，而它在容器解析完之前是空的，
    // 所以必须**持续听**，不能在 `open()` 之后读一次内核状态了事 ——
    // 那样菜单会永远空着。
    _engineSubs.add(engine.tracks.listen(_onTracks));

    // 当前选中的轨。切轨成功与否只能由内核说了算（见 [_activeAudioId]）。
    _engineSubs.add(
      engine.activeAudioTrackId.listen((id) {
        if (!mounted) return;
        setState(() => _activeAudioId = id == null ? null : '$id');
      }),
    );
    _engineSubs.add(
      engine.activeSubtitleTrackId.listen((id) {
        if (!mounted) return;
        // 内核回报的当前字幕轨也落一条。它和 [_onTracks] 那条配合起来能把
        // 「字幕出不来」拆成三种，而不是笼统一句「没字幕」：
        //   1. 清单有、这里始终没有 → 我们的切轨没生效；
        //   2. 清单有、这里也有 → 内核确实选中了，问题在解码/渲染
        //      （最典型：本机 libmpv 缺 `pgssub` 解码器）；
        //   3. 这里来回跳 → 有东西在跟我们抢字幕轨。
        if (id != _activeSubtitleId) {
          diag.info('播放窗口', '内核回报当前字幕轨：${id ?? "无"}');
        }
        setState(() => _activeSubtitleId = id);
      }),
    );

    // 一集播完（EOF）。自动连播的触发信号：订阅它、在回调里找下一集。
    //
    // ⚠️ 必须在这里注册，而不是在 `open()` 之后读一次内核的完成状态 ——
    // 那样只会拿到「上一条流是不是播完了」的旧值，新流刚开时它往往还是 true
    // （media_kit 不会自动归零），于是会**立刻**触发一次「连播」，
    // 把用户刚点开的这集秒切到下一集。
    _engineSubs.add(
      engine.completed.listen((completed) {
        if (completed) unawaited(_onCompleted());
      }),
    );

    // 实时输入速率。**轮询本体在引擎里**（原来长在这个窗口里，1 Hz 读
    // `demuxer-cache-state`）—— 搬进去是为了让两个播放器只有一份读数。
    //
    // 能力缺失时（mdk 没有对等物，见 [EngineCapabilities.networkSpeed]）
    // 这条流永不发，于是 [_netBytesPerSecond] 一直是 null，界面自动退回估算值。
    _engineSubs.add(
      engine.networkSpeed.listen((bytes) {
        if (!mounted) return;
        // 值没变就不 setState：1 Hz 的重建虽然便宜，但没必要。
        if (bytes == _netBytesPerSecond) return;
        setState(() => _netBytesPerSecond = bytes);
      }),
    );
  }

  /// 轨道清单变了。
  ///
  /// 契约里的清单**已经过滤过合成轨**（media_kit 那两条 `auto` / `no` 由
  /// `MediaKitPlaybackEngine.mapTracks` 剔掉，mdk 给的本来就是真轨道号），
  /// 所以这里不再需要 [TrackLabels.realTracks] 那一道 —— 但**菜单仍然吃
  /// media_kit 的类型**，所以这里过一次 [TrackBridge] 转过去。
  /// 理由（为什么不改菜单的类型）见 `TrackBridge` 的类文档。
  void _onTracks(EngineTracks tracks) {
    if (!mounted) return;

    final audio = <AudioTrack>[
      for (final t in tracks.audio) TrackBridge.audio(t),
    ];
    final subs = <SubtitleTrack>[
      for (final t in tracks.subtitle) TrackBridge.subtitle(t),
    ];

    // 内嵌字幕清单落一条日志。**这是「字幕出不来」的第一分诊点**：
    //   - 这里就是「无」→ 根本没识别到轨道（容器/文件名的问题）；
    //   - 这里有轨道、菜单也能选中，但画面没字 → 解码/渲染的问题，
    //     接着看 `内核字幕：…`（见 [isSubtitleDiagnosticLog]）。
    // 没有这一条，两种故障在日志里长得一模一样，只能靠猜。
    //
    // ⚠️ 编解码器短名（`subrip` / `hdmv_pgs_subtitle`）正是这条日志的**关键
    // 那一列** —— 位图字幕解不开与文本字幕解不开是两回事。它现在走契约的
    // `EngineTrack.codec`（两个内核给的都是 FFmpeg 短名，口径一致）。
    final inventory = tracks.subtitle
        .map((t) => '${t.id}/${t.codec ?? "-"}/${t.language ?? "-"}'
            '${t.isDefault ? "/默认" : ""}')
        .join('，');
    if (inventory != _loggedSubtitleInventory) {
      _loggedSubtitleInventory = inventory;
      diag.info(
        '播放窗口',
        '内嵌字幕轨 ${tracks.subtitle.length} 条：'
        '${tracks.subtitle.isEmpty ? "无" : inventory}',
      );
    }

    setState(() {
      _audioTracks = audio;
      _embeddedSubtitles = subs;
    });

    // 轨道清单刚到手 —— 这是还原音轨 / 内嵌字幕的**唯一**时机：内核给每条轨
    // 编的号只有这时才知道，而偏好里存的是特征（见 `TrackPreference`），
    // 必须拿真实清单去比。
    unawaited(_restoreFromPreference());
  }

  // -------------------------------------------------------------------
  // 逐文件播放偏好：读它还原 / 用户改了就报回主窗口
  // -------------------------------------------------------------------
  //
  // 与内置播放页（`player_page.dart`）**共用同一张表与同一套语义**：用户在这边
  // 换的字幕，下次在电视上打开同一集照样生效 —— 反之亦然。窗口只读它来还原，
  // 用户改了什么就报回主窗口落库（见 [_savePreference]），它自己不碰数据库。

  /// 把 [_pref] 记着的音轨与字幕套回这次播放。
  ///
  /// 跑在轨道流的回调里（见 [_onTracks]），因为**只有那一刻**才知道内核给每条
  /// 轨编的号；而偏好里存的是特征，必须拿真实清单去比
  /// （见 `TrackPreference` 的类文档）。
  ///
  /// 音轨与字幕各只尝试一次（[_audioRestored] / [_subtitleRestored]）：那个流
  /// 在换流与切轨时都会再发一遍，无闸的话用户刚手动切完就被顶回偏好里那一条
  /// —— 表现是「切了没反应」，而日志里一切正常。
  Future<void> _restoreFromPreference() async {
    final engine = _engine;
    if (engine == null || !mounted) return;
    final pref = _pref;

    if (!_audioRestored && _audioTracks.isNotEmpty) {
      _audioRestored = true;
      final index = TrackPreference.bestIndex(
        pref.audio,
        [
          for (var i = 0; i < _audioTracks.length; i++)
            TrackPreference(
              // 音轨 id 直接用内核的轨道号（mpv 的 `aid` / mdk 的 stream index）。
              // 两个内核报的都是**容器里的流号**，口径天然一致，不需要加来源
              // 前缀 —— 而内置播放页存的也是同一个口径（见 `TrackBridge`）。
              trackId: _audioTracks[i].id,
              language: _audioTracks[i].language,
              title: _audioTracks[i].title,
              index: i,
            ),
        ],
      );
      if (index != null) {
        diag.info('播放窗口', '按上次的选择还原音轨：${_audioTracks[index].id}');
        // `int.parse` 而不是 `tryParse`：[TrackBridge] 的 id 就是轨道号本身，
        // 解析不了说明上游契约被改坏了，应当炸出来而不是静默不切轨。
        await engine.selectAudioTrack(int.parse(_audioTracks[index].id));
      } else if (pref.audio != null) {
        // 匹配不上就**什么都不做**：那说明这一集没有那条轨（换了集、或者换了
        // 片源版本）。让内核用它自己的默认（发布者标了 `default` 的那条）
        // 比我们硬套一条语言都对不上的更对。
        diag.info(
          '播放窗口',
          '音轨偏好没匹配上（候选 ${_audioTracks.length} 条），沿用播放器默认',
        );
      }
    }

    if (_subtitleRestored) return;

    // 「关掉字幕」也是一个要记住的选择。不还原的话，用户在一部片里关掉字幕，
    // 下次打开又被挂上一条 —— 而他明明关过。
    if (!pref.subtitlesEnabled) {
      _subtitleRestored = true;
      _clearExternalSubtitle();
      await engine.selectSubtitleTrack(null);
      diag.info('播放窗口', '按上次的选择保持字幕关闭');
      return;
    }

    final sub = pref.subtitle;
    if (sub == null) {
      // 没记过具体某一条 → 交给内核自己的默认，别多此一举。
      _subtitleRestored = true;
      return;
    }

    // 网盘字幕：正文在主窗口，走与用户手点**完全同一条路**
    //（[_applySubtitleChoice]）—— 取正文、挂上去、记选中态都在那一处，
    // 另写一遍必然漏掉其中一步。
    final cloudFileId = _cloudFileIdOf(sub);
    if (cloudFileId != null) {
      _subtitleRestored = true;
      diag.info('播放窗口', '按上次的选择还原网盘字幕：$cloudFileId');
      await _applySubtitleChoice(_SubtitleChoice.cloud(cloudFileId));
      return;
    }

    // 内嵌轨：清单得先到。没到就**不落闸**，等下一次轨道回报。
    if (_embeddedSubtitles.isEmpty) return;
    _subtitleRestored = true;
    final index = TrackPreference.bestIndex(
      sub,
      [
        for (var i = 0; i < _embeddedSubtitles.length; i++)
          TrackPreference(
            // id 带来源前缀，与内置播放页同一个口径（那边是 `embedded#N`）。
            // 不带的话「内嵌第 2 条」与「网盘第 2 条」在偏好里长得一模一样，
            // 两个播放器读同一个库时会互相顶掉。
            trackId: 'embedded#${_embeddedSubtitles[i].id}',
            language: _embeddedSubtitles[i].language,
            title: _embeddedSubtitles[i].title,
            index: i,
          ),
      ],
    );
    if (index == null) {
      diag.info(
        '播放窗口',
        '字幕偏好没匹配上（内嵌 ${_embeddedSubtitles.length} 条），沿用播放器默认',
      );
      return;
    }
    diag.info('播放窗口', '按上次的选择还原内嵌字幕：${_embeddedSubtitles[index].id}');
    _clearExternalSubtitle();
    await engine.selectSubtitleTrack(int.parse(_embeddedSubtitles[index].id));
  }

  /// 偏好里那条字幕如果是**网盘字幕**，返回它的 `fileId`；否则返回 `null`。
  ///
  /// 判据是 id 前缀：内置播放页给网盘字幕编的 id 是 `<itemId>#<fileId>`
  /// （见 `SubtitleService._buildTrack`），内嵌轨是 `embedded#<sid>`。
  ///
  /// ⚠️ 两种来源必须分得开，否则「上次选的是网盘 ASS」会被当成「内嵌第 N 条」
  /// 还原 —— 图形字幕（PGS/VobSub）在本机 libmpv 上经常解不出来，用户看到的
  /// 是「字幕又没了」。
  ///
  /// 注意这里**只认当前这一条片子的前缀**：从同剧别的集继承来的偏好里带的是
  /// 那一集的 `itemId`，返回 `null`，于是自动落到内嵌轨那条路上去（那一集的
  /// 网盘字幕文件与这一集本来就不是同一个）。
  String? _cloudFileIdOf(TrackPreference preference) {
    final id = preference.trackId;
    final itemId = _currentRequest?.itemId;
    if (id == null || itemId == null || itemId.isEmpty) return null;
    final prefix = '$itemId#';
    if (!id.startsWith(prefix)) return null;
    final fileId = id.substring(prefix.length);
    return fileId.isEmpty ? null : fileId;
  }

  /// 用户在本窗口改了某项播放设置 —— 就地更新 [_pref] 并报回主窗口落库。
  ///
  /// 与内置播放页同一套做法：**值没变就直接返回**。白跑一次写库 + 一次跨引擎
  /// 往返，只为了让库里那串 JSON 重新排一遍序，没有任何意义。
  ///
  /// ## 为什么报的是**整份**而不是「改了哪一项」
  ///
  /// 主窗口收到就整份覆盖写，不必实现一套合并语义 —— 「哪些字段该保留」一旦有
  /// 两处实现（两边各一套 patch 规则），必然漂移成「保存字幕时把画质抹了」这种
  /// 查不出来的 bug。而整份里那些用户没动过的项**本来就是从库里读出来的**
  /// （见 [_adoptRequest]），覆盖写不会丢任何东西。
  void _savePreference(PlaybackPreference Function(PlaybackPreference) update) {
    final next = update(_pref);
    if (next == _pref) return;
    setState(() => _pref = next);
    unawaited(_reportPreference(next));
  }

  /// 把偏好报回主窗口，由它写进库。
  ///
  /// 播放窗口**刻意不碰数据库**：它跑在另一个 Flutter 引擎里，拿不到主窗口的
  /// 仓储，连 `groupKey` 都不知道。所以只能走通道 —— 与 [_saveAudioEffect]、
  /// 片头标记同一条边界。
  ///
  /// 失败**不影响本次播放**（设置早就生效了），只记一条日志。但必须留痕：否则
  /// 用户下次开窗口发现设置又变回去了，而日志里一条线索都没有。
  Future<void> _reportPreference(PlaybackPreference preference) async {
    final request = _currentRequest;
    // 手输直链 / 内置自检视频这类**没有库记录**的播放：没有 itemId 就没有行可以
    // 挂，报过去也会被主窗口丢掉（见 `player_window_bridge.dart` 那个 case）。
    if (request == null || request.itemId.isEmpty) return;
    if (!_channelReady) {
      diag.warn('播放', '跨窗口通道不可用，播放偏好存不下来（本次播放已生效）');
      return;
    }
    try {
      await playerWindowChannel.invokeMethod<void>(
        PlayerBridgeMethod.savePlaybackPreference,
        <String, Object?>{
          'itemId': request.itemId,
          'preference': preference.toJson(),
        },
      );
    } catch (e) {
      diag.warn('播放', '播放偏好没能报回主窗口（本次播放已生效）：$e');
    }
  }

  /// 第一帧已经出来了 —— 收掉加载指示。
  ///
  /// 换流那条路（[_switching]）也由它收：两者的「有画面了」信号是同一批
  /// （见 [_bindEngine] 里 `videoSize` / `duration` / `position` 那三条订阅）。
  void _clearAwaitingFrame() {
    if (!mounted) return;
    if (!_awaitingFrame && !_switching) return;
    setState(() {
      _awaitingFrame = false;
      _switching = false;
    });
  }

  // -------------------------------------------------------------------
  // 浮层显隐（片名 + 控制栏）
  // -------------------------------------------------------------------

  /// 鼠标动了：显示浮层，并把隐藏倒计时**重新起算**。
  ///
  /// 每次移动都重置是刻意的 —— 用户正在找按钮的时候把按钮藏起来是最糟的时机。
  void _pokeChrome() {
    if (!mounted) return;
    _hideTimer?.cancel();
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    _hideTimer = Timer(_chromeIdleTimeout, () {
      // 倒计时到点时窗口可能已经关了。
      if (!mounted) return;
      // 菜单开着时也不收：鼠标移到菜单上会让倒计时重新起算，而此刻用户正在
      // 菜单里挑，把按钮藏掉只会让人以为界面坏了（见 [_menuDepth]）。
      if (_menuDepth > 0) return;
      setState(() => _chromeVisible = false);
    });
  }

  /// 鼠标停在浮层上：**取消**倒计时 —— 别把用户正要点/正在拖的控件抽走。
  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (!_chromeVisible) setState(() => _chromeVisible = true);
  }

  /// 立刻隐藏浮层（单击画面、鼠标移出窗口）。
  void _hideChrome() {
    // 菜单浮层开着时**绝不隐藏**。菜单挂在 Overlay 上、在播放页 `MouseRegion`
    // 之外，鼠标移到菜单上会被判成「移出窗口」走到这里 —— 真隐藏了，用户看到
    // 的就是「点了画质，菜单还在、控制栏先没了」（见 [_menuDepth]）。
    if (_menuDepth > 0) return;
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_chromeVisible) setState(() => _chromeVisible = false);
  }

  /// 弹一个 anchored 菜单，存续期间压住控制栏的自动隐藏。
  ///
  /// 只做两件事：把 [_menuDepth] 加减一，以及开弹前 [_cancelHide]。
  /// **不负责**菜单关闭后重新计时 —— 那是调用方的事：各菜单拿到结果后要按
  /// 自己的时机 `_pokeChrome()`（有的还要接着 await 一次切档 / 落库，提前
  /// 起计时会在那段时间里把按钮收走）。
  Future<T?> _pinnedMenu<T>(Future<T?> Function() open) async {
    _menuDepth++;
    _cancelHide();
    try {
      return await open();
    } finally {
      _menuDepth--;
    }
  }

  /// 播放 / 暂停。单击画面与控制栏那个按钮都走这里。
  ///
  /// 图标立刻按「已切换」更新：真状态仍以 `playing` 流为准，但那条流要等内核
  /// 回话，光靠它按钮会慢半拍 —— 用户点了没反应就会再点一次。
  void _togglePlay() {
    final engine = _engine;
    if (engine == null) return;
    setState(() => _playing = !_playing);
    unawaited(engine.playOrPause());
  }

  // -------------------------------------------------------------------
  // 进度回报
  // -------------------------------------------------------------------

  /// 位置流入口：先喂刷新闸，再回报进度。
  ///
  /// 两件事挂在同一个流上是有意的 —— 它们共用同一个「播到哪了」的真相：
  /// 刷新闸要判断「重开之后位置有没有真的往前走」，那正是这个值。
  Future<void> _onPosition(Duration position) async {
    // 片头探测必须在**任何 await 之前**完成「判定 + 置位」：位置流每 ~100ms
    // 一条，不先置位会让同一帧的两条都各自起一次探测，把 `chapter-list` 读上
    // 十几次。判定本体在 [IntroSession.shouldProbe]。
    if (_introSession.shouldProbe(position)) {
      _introSession.markProbed();
      unawaited(_probeIntro());
    }
    // 进了片头区间就跳。判定 + 置位收在 [IntroSession.takeSkipTarget]：
    // `seek` 是异步往返，晚置位会连发几次 seek（画面往前窜、进度条乱跳）。
    final skipTo = _introSession.takeSkipTarget(position);
    if (skipTo != null) {
      unawaited(_seek(skipTo));
      _toast('已跳过片头');
    }

    // 刷新后能连续播过一段，说明这次刷新是有效的 —— 把自动重试计数清零。
    // 不这么做的话，一部长片里撞上两三次过期就把额度用满了。
    if (_refreshGuard.observe(position, now: DateTime.now())) {
      diag.info('播放窗口', '直链刷新有效，自动刷新计数已清零');
    }
    await _reportProgress(position);
  }

  /// 探测一次文件章节里的片头区间。
  ///
  /// 结果晚到时（`detectIntro` 是异步的）用户可能已经换集 —— 那时
  /// `_currentRequest` 的 itemId 已经变了，写进去会让**下一集**顶着这一集的
  /// 片头区间跳。所以用 itemId 挡一下竞态（与内置播放页同一处判断）。
  Future<void> _probeIntro() async {
    final engine = _engine;
    if (engine == null) return;
    final itemId = _currentRequest?.itemId;
    // 章节的**读法**两个内核不同（mpv 读 `chapter-list` 属性 / mdk 查
    // `MediaInfo.chapters`），但都由契约的 `chapters()` 收口；而**认片头**
    // 与那几条诊断日志只有一份（`IntroMarkerDetector.detectAndLog`）——
    // 与内置播放页共用，否则两边会漂移成「这边跳得对、那边跳得怪」。
    final marker = IntroMarkerDetector.detectAndLog(
      IntroMarkerDetector.fromEngineChapters(await engine.chapters()),
      label: _currentRequest?.title ?? '',
    );
    if (!mounted || _currentRequest?.itemId != itemId) return;
    _introSession.setChapter(marker);
  }

  /// 把一条 mpv 日志存进尾巴（环形缓冲）。见 [_mpvLogTail]。
  void _appendMpvLog(PlayerLog entry) {
    _mpvLogTail.add('[${entry.level}] ${entry.prefix}: ${redactUrls(entry.text)}');
    if (_mpvLogTail.length > mpvLogTailSize) {
      _mpvLogTail.removeAt(0);
    }
  }

  /// 把「这一刻播放器到底在放什么」全部写进诊断日志。
  ///
  /// 只在**可疑的播完**时调用 —— 那正是需要拿证据的时刻（平时刷这些属性
  /// 只会污染日志，而且 `getProperty` 是跨 isolate 调用，不该放进热路径）。
  ///
  /// ## 为什么要读 mpv 属性，而不是只看我们自己的状态
  ///
  /// 「有声音没画面」有两个完全不同的成因，在我们这层**看不出区别**：
  ///   1. 流里**根本没有视频轨**（夸克转码没出画面 / 我们挑错了 variant）；
  ///   2. 有视频轨但**解码器开不起来**（codec / 硬解 / 内存）。
  ///
  /// 两者的修法完全不同，而 `track-list` 一行就能分开它们 —— 这一份诊断
  /// 存在的唯一目的就是拿到那一行。
  Future<void> _dumpPlaybackDiagnostics(String reason) async {
    diag.warn('播放窗口', '──── 播放异常诊断：$reason ────');

    // ⚠️ 这一整段**只对 mpv 有效**：它读的是 mpv 的原生属性，而 fvp 那边
    // 没有对等物（`EngineCapabilities.rawProperty` 就是 false）。所以在 DV
    // 片源上会看到「读不到」—— 那不是故障，是这条诊断路的**已知边界**。
    // 说清楚比留一串看不懂的 `<读不到>` 强：否则下一个人会去查一个不存在的 bug。
    if (_engine is! MediaKitPlaybackEngine) {
      diag.warn(
        '播放窗口',
        '  当前内核不是 media_kit（杜比视界片源会走 fvp），'
        '下面的 mpv 属性读的是**空闲的** mpv 实例，不代表正在播的那条流',
      );
    }

    final platform = _player?.platform;
    if (platform is! NativePlayer) {
      diag.warn('播放窗口', '  播放器不是 NativePlayer，读不到 mpv 属性');
      return;
    }

    for (final key in const <String>[
      'file-format',
      'duration',
      'demuxer-cache-time',
      'demuxer-cache-state',
      'video-out-params',
      'audio-params',
      'track-list',
    ]) {
      String value;
      try {
        value = await platform.getProperty(key);
      } catch (e) {
        value = '<读不到：$e>';
      }
      diag.warn('播放窗口', '  $key = ${_truncate(value.isEmpty ? '<空>' : value)}');
    }

    if (_mpvLogTail.isEmpty) {
      // 这条本身就是结论：mpv 一条 warn 级日志都没给，说明它认为一切正常 ——
      // 那问题就在「流本身就短」，而不是解码失败。
      diag.warn('播放窗口', '  mpv 日志缓冲为空（mpv 一条 warn 级日志都没给）');
    } else {
      diag.warn('播放窗口', '  最近 ${_mpvLogTail.length} 条 mpv 日志：');
      for (final line in _mpvLogTail) {
        diag.warn('播放窗口', '    $line');
      }
    }

    // HLS（转码档）才做这一步：**用我们自己的请求头**把 m3u8 抓下来。
    //
    // 这是「转码档只有声音没画面」的分水岭证据：
    //   - 自己抓得到 200 → 票据与请求头都没问题，问题在 mpv 那边；
    //   - 自己抓也是 404 → 鉴权 / 票据的问题（最可能是少了某个 cookie）。
    //
    // 只在这条流是 HLS 时才抓：原画是带签名的**直链文件**，抓它既没有信息量，
    // 又等于往网盘发一个几 GiB 的请求。
    final request = _currentRequest;
    if (request != null && request.isHls) {
      await _probeHlsPlaylist(request);
    }
    diag.warn('播放窗口', '──── 诊断结束 ────');
  }

  /// 用**播放票据自带的请求头**（含 Cookie）试探性地抓一次 m3u8。
  ///
  /// 只在已经出事时调用，所以多这一次请求无所谓；但它回答了排查时最关键
  /// 的那个二选一 —— 是「我们给的凭证不对」还是「mpv 读不动这条流」。
  ///
  /// 失败一律自己兜住：诊断不该把播放窗口拖崩。
  ///
  /// ⚠️ **每条流最多抓一次**（[_hlsProbed]）。一次故障会连着触发好几个钩子
  /// （EOF 护栏、404、mpv 报错），不设闸的话同一条 m3u8 会被抓三四遍，
  /// 日志里刷出几份一样的摘要，反而把别的东西挤掉。
  Future<void> _probeHlsPlaylist(PlayRequest request) async {
    if (_hlsProbed) return;
    _hlsProbed = true;

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final httpRequest = await client.getUrl(Uri.parse(request.url));
      for (final e in request.headers.entries) {
        httpRequest.headers.set(e.key, e.value);
      }
      final response = await httpRequest.close();

      final chunks = <List<int>>[];
      var total = 0;
      await for (final chunk in response) {
        if (total >= 8192) break;
        chunks.add(chunk);
        total += chunk.length;
      }
      final text = utf8.decode(
        chunks.expand<int>((c) => c).toList(growable: false),
        allowMalformed: true,
      );
      diag.warn(
        '播放窗口',
        '  m3u8 自检：HTTP ${response.statusCode}，$total 字节'
        '（请求头键=${request.headers.keys.toList()} '
        'Cookie键=${cookieHeaderKeyNames(request.headers["Cookie"])}）',
      );
      // ⚠️ 这一行是整份诊断里**信息量最大的一条**。
      //
      // 「转码档播两三秒就 EOF」有两个完全不同的成因，而用户观感一模一样：
      //   - 播放列表本身就只有几秒（服务端给了预览档 / 转码没做完）；
      //   - 播放列表是完整的，是播放器没跟上（分片取不到、解码失败…）。
      // 「合计时长」一眼分开这两者 —— 所以它必须打出来，不能只打前几行原文。
      diag.warn(
        '播放窗口',
        '  m3u8 摘要：${summarizeHlsPlaylist(text).describe()}',
      );
      final lines = text
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .take(12);
      for (final line in lines) {
        // 分片地址里可能带 token，走同一套脱敏。
        diag.warn('播放窗口', '    m3u8 | ${redactUrls(line)}');
      }
      // m3u8 能下 **不等于** 分片能下 —— 转码档的鉴权挂在分片 URL 上
      // （`auth_key`），所以必须把第一条分片也探一次。
      await _probeFirstSegment(request, text);
    } catch (e) {
      diag.warn('播放窗口', '  m3u8 自检失败：$e');
    } finally {
      client?.close(force: true);
    }
  }

  /// 用播放票据的请求头抓**第一条分片**，只读一小段就断开。
  ///
  /// ## 它回答的问题
  ///
  /// 「m3u8 200 但播不出来」只剩两种可能：
  ///   - **分片取不到**（`auth_key` 过期 / cookie 不全 / 分片还没转码出来）→ 这里 4xx/5xx；
  ///   - **分片取得到，是解码或选流的问题** → 这里 200。
  ///
  /// 两种情况在我们这一层观感完全一样（有声音没画面），而修法一个在天上
  /// 一个在地下。这一行就是那条分界线。
  ///
  /// 只读 64 KiB 就断：`.ts` 分片动辄几 MB，诊断不该为了取证把整条片子拉下来。
  Future<void> _probeFirstSegment(PlayRequest request, String playlistText) async {
    final relative = firstSegmentUri(playlistText);
    if (relative == null) {
      diag.warn('播放窗口', '  分片自检：播放列表里没有分片行');
      return;
    }
    final base = Uri.tryParse(request.url);
    if (base == null) {
      diag.warn('播放窗口', '  分片自检：播放地址解析不了');
      return;
    }
    // 分片在列表里是**相对路径**，必须按 m3u8 自己的地址去拼（同
    // `isRelayableUrl` 那条注释里说的基准问题）。
    final segment = base.resolve(relative);

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final httpRequest = await client.getUrl(segment);
      for (final e in request.headers.entries) {
        httpRequest.headers.set(e.key, e.value);
      }
      final response = await httpRequest.close();
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        if (total >= 65536) break;
      }
      diag.warn(
        '播放窗口',
        '  分片自检：HTTP ${response.statusCode}，读到 $total 字节'
        '（类型=${response.headers.contentType} '
        '声明长度=${response.contentLength}）',
      );
    } catch (e) {
      // 诊断不该把播放窗口拖崩 —— 失败本身也是证据，照记。
      diag.warn('播放窗口', '  分片自检失败：$e');
    } finally {
      client?.close(force: true);
    }
  }

  /// 属性值可能很长（`track-list`、`demuxer-cache-state` 都是 node 转出来的
  /// 大串），截断是为了别让一条属性把日志刷满 —— 我们要的通常只是前几段。
  static String _truncate(String s) =>
      s.length <= 600 ? s : '${s.substring(0, 600)}…（截断 ${s.length} 字）';

  /// 一集播完：自动切到同作品的下一集（若设置允许、且确实有下一集）。
  ///
  /// 触发点是 `player.stream.completed`。与剧集列表里的「下一集」共用
  /// [EpisodeQueue.nextAfter] —— 那条规则是两处共用的一份纯函数：当前项不在
  /// 列表里不从头开始、跳过花絮而不是撞上就停、到尾不循环。
  Future<void> _onCompleted() async {
    final request = _currentRequest;
    if (request == null) return;

    // ⚠️ 先判「这次 EOF 是不是真的播完了」。
    //
    // 顺序刻意放在 `autoPlayNext` 判断**之前**：诊断要对**所有**用户生效，
    // 关掉自动连播的人一样会遇到「只有 2 秒」，而那批人正是最需要这份日志的
    // —— 他们没有级联可看，故障表现得更安静。
    //
    // 内核的 `completed` 只表示「读到流末尾」，不表示这一集被看过了。
    // 实测（2026-10-04，夸克转码档 HLS）：流只有 1~2 秒、有声音没画面，
    // mpv 照常报 EOF —— 于是不加护栏的话，60 秒内会级联「看」完 5 部片，
    // 而真正的故障（这一档根本读不出东西）**一次都没露出来**，用户只看到
    // 播放窗口自己在疯狂换片。
    //
    // 判据本体在 [PlaybackCompletion]（纯函数，两个播放器共用）。
    //
    // ⚠️ 位置与时长读的是**我们自己**的状态（由契约的流搬进来），不是内核的
    // 状态字段 —— 后者只有 media_kit 有。契约已经统一了口径，所以判据不用改。
    final position = _position;
    final duration = _duration;
    final realEnd = PlaybackCompletion.isRealEnd(
      position: position,
      sawVideo: _sawVideoFrame,
    );

    // ⚠️ **诊断的触发条件刻意不等于护栏的触发条件**。
    //
    // 2026-10-04 实测踩到的坑：转码档 HLS 的故障现场是「位置 3~7 秒、mpv 报过
    // 视频尺寸」，于是护栏**放行**（按它的规则，这确实像一段真播完的短片）。
    // 上一版把诊断挂在护栏里面，结果护栏一次都没拦，诊断也一次都没跑 ——
    // 最要紧的那份证据（`media.m3u8` 里到底写了什么）从头到尾没落过盘。
    //
    // 所以：只要**是转码档**而且**短命**，不管护栏判成什么都要抓。
    // 判据用 `isHls`（原画是带签名的直链，本来就正常，别拿它刷日志）。
    final shortHls = request.isHls &&
        position < PlaybackCompletion.suspiciousHlsPosition;
    if (!realEnd || shortHls) {
      final why = realEnd
          ? '转码档（HLS）只播了 ${position.inSeconds}s 就报播完'
              '（时长=${duration.inSeconds}s）'
          : PlaybackCompletion.describe(
              position: position,
              duration: duration,
              sawVideo: _sawVideoFrame,
            );
      // ⚠️ 必须留痕（warn 级）：下一次报「怎么不自动连播了」，第一件要
      // 确认的就是这几个量。写成 debug 的话这类问题在日志里根本找不到。
      diag.warn('播放窗口', '播完但没当成播完：$why');
      // 出事这一刻把 mpv 的真实状态抓下来 —— 这是「转码档只有声音没画面」
      // 这类问题唯一能拿到的第一手证据（mpv 平时的话全被过滤器丢了）。
      await _dumpPlaybackDiagnostics(why);
    }

    if (!realEnd) {
      // 只有开着自动连播的人需要那句提示：没开的人本来就不会跳，
      // 说「已停止」反而让他以为自己改过设置。
      if (request.autoPlayNext) {
        _toast('这一集没能正常播放，已停止自动连播');
      }
      return;
    }

    if (!request.autoPlayNext) return;

    final playlist = request.playlist;
    final next = EpisodeQueue.nextAfter(
      entries: playlist,
      idOf: (e) => e.itemId,
      currentId: request.itemId,
      isExtra: (e) => e.isExtra,
    );
    if (next == null) {
      diag.info('播放窗口', '已是最后一集（或没有可连播的下一集），不自动连播');
      return;
    }
    diag.info('播放窗口', '自动连播下一集 → ${next.title}');
    _toast('自动播放下一集');
    await _openEpisode(next);
  }

  /// 把播放位置回报给主窗口，由它落库。
  ///
  /// **只在有库记录且通道可用时回报**：内置自检视频、手输直链都没有对应的
  /// 库记录，报上去只会让主窗口去更新一个不存在的行。
  ///
  /// 节流靠 [ProgressThrottle] 的「整十秒边界」—— 不节流的话每秒会往方法
  /// 通道打 10 条消息。
  ///
  /// [force] 为 true 时**绕过节流**立即上报，并且**等到主窗口写库完成**才返回
  /// （`handlePlayerWindowCall` 那边是 await 的）。换流之前必须走这条路：
  ///
  ///   - 节流器只在整十秒上报，用户在第 245 秒切走时，最后那 5 秒（以及
  ///     「看了 6 秒就切走」的整段）压根没机会报上去；
  ///   - 主窗口拿到换流请求后要**读库**算新流的续播点，这次写入必须排在读之前 ——
  ///     排反了就是「切走再切回来，又从头开始」。
  Future<void> _reportProgress(Duration position, {bool force = false}) async {
    final itemId = _currentRequest?.itemId ?? '';
    if (itemId.isEmpty || !_channelReady) return;

    final due = force ? position : _progressThrottle.accept(position);
    if (due == null) return;

    try {
      await playerWindowChannel.invokeMethod<void>(
        PlayerBridgeMethod.reportProgress,
        PlaybackProgressReport(
          itemId: itemId,
          position: due,
          duration: _duration,
        ).toJson(),
      );
    } catch (e) {
      // 丢一次回报只影响「最近播放」的精度，不该打断播放。
      diag.debug('播放窗口', '进度回报失败：$e');
    }
  }

  // -------------------------------------------------------------------
  // 刷新过期直链
  // -------------------------------------------------------------------

  /// `stream.error` 上的 mpv 报错。
  ///
  /// 这条路管的是**二级症状**（`Failed to open <url>.`），它只在「打开时就
  /// 已经过期」的情况下出现。播到一半才过期的那条一级证据走
  /// [isHttp4xxLog] 那条 `stream.log` 路径 —— 两条刻意不重叠，理由见那里的说明。
  ///
  /// 过滤口径仍然放宽（任何带 failed / error 的都试一次），因为**漏判的代价**
  /// 是「播到一半卡死、用户只能关窗重开」。误判的代价由 [TicketRefreshGuard]
  /// 兜住：非时效性的失败刷几次就会停，同一次故障的回声由它的冷却窗口收掉。
  Future<void> _onPlayerError(String message) async {
    // ⚠️ 字幕解码失败**必须先分流并直接返回**，两个理由：
    //
    //   1. 换了直链也解不开 —— 这是本机 libmpv 缺解码器，不是链的问题。
    //      掉进下面那条 `_refreshTicket` 只会让用户看到「档位自己跳了一下、
    //      字幕照旧没有」。
    //   2. 这句话**不含 `failed` 也不含 `error`**（mpv 说的是
    //      `Could not find subtitle decoder for format 'hdmv_pgs_subtitle'.`），
    //      不在这里放行就会被下面那行直接丢掉 —— 实测踩过，
    //      详见 [isSubtitleDiagnosticLog]。
    if (isSubtitleDiagnosticLog(message)) {
      diag.warn('播放窗口', 'mpv 字幕：${redactUrls(message)}');
      return;
    }

    final lower = message.toLowerCase();
    // 与内置播放页同一套过滤：mpv 的告警里也常带 'error' 字样，
    // 不值得为它重开一次流。
    if (!lower.contains('failed') && !lower.contains('error')) return;

    // ⚠️ 必须**先抹直链再落日志**。mpv 的 `Failed to open %s.` 会把完整 URL
    // 带进来，而夸克直链的签名就在查询串里 —— 不抹的话它会被写进诊断日志
    // 文件，而那个文件是给用户复制粘贴用的。理由详见 [redactUrls]。
    final safe = redactUrls(message);
    diag.warn('播放窗口', 'mpv 报错：$safe');

    if ((_currentRequest?.itemId ?? '').isEmpty) {
      // 没有库记录 → 没有可刷新的来源。如实告诉用户，别装作没事。
      _toast('播放出错：$safe');
      return;
    }
    await _refreshTicket(reason: safe);
  }

  /// 内核日志里发现了 HTTP 4xx —— 直链过期的**一级证据**。
  ///
  /// 与 [_onPlayerError] 的分工见 [isHttp4xxLog]。
  ///
  /// ⚠️ 参数是**纯文本**（契约的 `log` 流是 `Stream<String>`），所以这里不再
  /// 打 mpv 那条日志的 `prefix`。那不是信息损失：完整行（含 level / prefix）
  /// 仍然在 [_mpvLogTail] 里，出事时由 [_dumpPlaybackDiagnostics] 整段落盘。
  Future<void> _onTicketExpiryLog(String text) async {
    final safe = redactUrls(text);

    if ((_currentRequest?.itemId ?? '').isEmpty) {
      // 没有库记录（内置自检视频 / 手输直链）→ 无从刷新，也不会连刷，
      // 所以这里记一条 warn 就够。
      //
      // **刻意不弹提示**：没有库记录时用户本来也只能自己换一条链，
      // 他会在画面上直接看到播不动。
      diag.warn('播放窗口', '直链疑似过期：$safe');
      return;
    }

    // ⚠️ 有库记录时**刻意用 debug 而不是 warn**。
    //
    // 实测：一次过期会连出十几条 403 —— ffmpeg 的 http 层带 reconnect，
    // 退避是 0s / 1s / 3s / 7s…，每一轮都再报一次。逐条打 warn 会把日志刷爆。
    //
    // 而真正有信息量的是 [_refreshTicket] 那行
    // 「请求刷新直链：… 原因：…」—— 它同时说了「发生了什么」和「我们打算怎么办」，
    // 而且一次故障只打一条（冷却窗口收掉回声）。
    diag.debug('播放窗口', '直链疑似过期：$safe');

    // 转码档（HLS）报 4xx 是**另一码事**：它的地址不带签名，鉴权靠 cookie，
    // 而 4xx 在这里既可能是 cookie 不对、也可能是分片取不到。刷新直链
    // （下面那句）治不了后者 —— 所以先把证据抓下来，再照常去刷新。
    if (_currentRequest?.isHls ?? false) {
      await _dumpPlaybackDiagnostics('转码档报 HTTP 4xx：$safe');
    }

    await _refreshTicket(reason: safe);
  }

  /// 向主窗口要一条新链，并**从当前位置续播**。
  ///
  /// [manual] 为 true 表示用户手动点的按钮：手动操作不受自动闸限制，
  /// 且先把计数清零（用户显然认为还有救）。
  Future<void> _refreshTicket({
    required String reason,
    bool manual = false,
  }) async {
    if (!mounted || _refreshing) return;

    final request = _currentRequest;
    if (request == null || request.itemId.isEmpty) return;

    if (!_channelReady) {
      diag.warn('播放窗口', '跨引擎通道不可用，无法刷新直链');
      _toast('跨窗口通道不可用，刷新不了直链');
      return;
    }

    // 位置要在重开**之前**取：报错之后内核报的位置可能已经归零，
    // 那样刷新会把用户丢回片头。
    //
    // 引擎都还没建（还没开过流）时才退回请求里带的续播点。
    final position = _engine == null ? request.startPosition : _position;

    if (manual) {
      // 手动刷新清空计数，但**照样重新起冷却**：手动刷新也会招来旧流那批
      // 403 回声，不重新起算的话它们立刻就把刚清空的额度烧掉。
      // 理由见 [TicketRefreshGuard.reset]。
      _refreshGuard.reset(now: DateTime.now());
    } else if (!_refreshGuard.begin(position, now: DateTime.now())) {
      // ⚠️ `begin` 返回 false 有**两种**原因，必须分开对待 ——
      // 混在一起会变成「一次故障的回声弹好几条提示」或者
      // 「用满了却什么都不说」。判据是 `exhausted`。
      if (_refreshGuard.exhausted) {
        diag.warn(
          '播放窗口',
          '自动刷新已用满 ${_refreshGuard.maxAttempts} 次，停止重试',
        );
        _toast('直链反复失效，已停止自动重试（可手动「重新取链并续播」）');
      } else {
        diag.debug('播放窗口', '自动刷新冷却中，跳过这条回声');
      }
      return;
    }

    _refreshing = true;
    setState(() => _busy = true);
    try {
      diag.info(
        '播放窗口',
        '请求刷新直链：${request.describe()} @ ${position.inSeconds}s'
        '（第 ${_refreshGuard.attempts} 次${manual ? "，手动" : ""}）原因：$reason',
      );
      final fresh = await _requestFreshTicket(
        itemId: request.itemId,
        qualityId: request.qualityId,
        position: position,
        reason: reason,
      );
      if (fresh == null) return;
      diag.info('播放窗口', '拿到新直链 → ${fresh.describe()}');
      // 换掉上下文：刷新后档位/标题可能变（服务端这次没给同一档），
      // 后续回报与再刷新都应当基于新请求。
      _currentRequest = fresh;
      // ⚠️ 这里**不能**走 [_adoptRequest]：它会重置 [_refreshGuard]，
      // 而把重试计数清零正好等于把这个闸废掉 —— 一条永远刷不好的链会变成
      // 无限重试。换片才该重置。
      //
      // 刷链 = 同一条流的地址换了，画面上的东西一点没变 —— 保留上一帧。
      await _openStream(
        fresh.url,
        fresh.describe(),
        headers: fresh.headers,
        startAt: position,
        keepLastFrame: true,
      );
    } finally {
      _refreshing = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 向主窗口要一条新直链。**不做任何闸门判断** —— 闸由调用方各负其责。
  ///
  /// 抽出来是因为三条路都要它，而它们的闸各不相同：
  ///   - 自动续播（直链过期）→ 受 [TicketRefreshGuard] 限制；
  ///   - 用户手动「重新取链」→ 清空计数、重起冷却；
  ///   - 用户切集 / 切画质 → 与自动重试无关，**不消耗重试额度**
  ///     （否则用户连点几集就把「过期自动续播」的额度用光了）。
  ///
  /// 失败一律返回 null 并自己弹提示 —— 调用方不必再各写一遍错误处理。
  Future<PlayRequest?> _requestFreshTicket({
    required String itemId,
    required String? qualityId,
    required Duration position,
    required String reason,
  }) async {
    // 换流之前先把「当前这一集看到哪了」落库（**强制**，且等到写完）。
    //
    // 放在这里而不是三个调用点各写一遍：切集、切画质、直链过期续播，三条路
    // 都是「换一条流」，都该先记账。
    //
    // ⚠️ 顺序不能反：主窗口紧接着要读这个库算新流的续播点。写在读之前，
    // 「切走再切回来」才能续上；写晚了，切回来就是从头开始 —— 而用户在
    // 同一个窗口里来回切集时，那条路的进度本来只存在于这张表里。
    await _reportProgress(_position, force: true);

    try {
      final raw = await playerWindowChannel.invokeMethod<Object?>(
        PlayerBridgeMethod.refreshTicket,
        TicketRefreshRequest(
          itemId: itemId,
          qualityId: qualityId,
          position: position,
        ).toJson(),
      );
      final fresh = PlayRequest.fromJson(raw);
      if (fresh == null) {
        diag.warn('播放窗口', '主窗口拿不出新直链（$reason）');
        _toast('直链刷新失败，请看诊断日志');
        return null;
      }
      return fresh;
    } on WindowChannelException catch (e) {
      // 「文件已经不在网盘上」：这不是「这次没取到」，而是「这条索引已经
      // 失效」—— 必须给用户一个「从媒体库移除」的出口，否则自动连播时只会
      // 看到「播完一集就没动静了」。其余错误码（登录失效、限流、网络）是
      // 临时的，不该拿去问用户要不要删片。
      if (e.code == PlayerBridgeError.missingFile) {
        if (await _handleMissingFile(itemId)) {
          // 文件没了且用户已移除，窗口没有内容可放 → 关掉它。
          await closeChildWindow();
        }
        return null;
      }
      diag.error('播放窗口', '取新直链失败（$reason）', error: e);
      _toast('直链刷新失败：${e.message}');
      return null;
    } catch (e, st) {
      diag.error('播放窗口', '取新直链失败（$reason）', error: e, stackTrace: st);
      _toast('直链刷新失败：$e');
      return null;
    }
  }

  /// 播放窗口撞上「文件已经不在网盘上」之后的完整处置。
  ///
  /// 取链这一步在**主窗口**发生（`player_bridge_host.dart` 的
  /// `_asMissingFileError`），播放窗口手里只有一句 `drive/notFound`，且连
  /// `groupKey` 都没有。所以「能删到哪一层」要回主窗口查
  /// （[PlayerBridgeMethod.queryMissingMedia]），删除本身也只能由主窗口
  /// 执行（[PlayerBridgeMethod.removeMissingMedia]）—— 库与仓储都装在那边。
  ///
  /// 返回用户是否真的移除了（调用方据此关掉窗口）。
  Future<bool> _handleMissingFile(String itemId) async {
    if (!_channelReady) {
      _toast('文件不存在或已被删除（跨窗口通道不可用）');
      return false;
    }
    final plan = await _queryMissingPlan(itemId);
    if (plan == null) return false;
    if (!mounted) return false;
    final scope = await MissingMediaDialog.show(context, plan);
    if (scope == null) return false;
    if (!mounted) return false;
    final removed = await playerWindowChannel.invokeMethod<bool>(
      PlayerBridgeMethod.removeMissingMedia,
      MissingMediaRemoval(itemId: itemId, scope: scope).toJson(),
    );
    if (removed == true) {
      _toast(plan.removedMessage(scope));
      return true;
    }
    _toast('移除失败：库里找不到这条记录');
    return false;
  }

  /// 回主窗口查「这一条是不是真没了、能删到哪一层」。
  ///
  /// 返回 `null` 表示查不到（主窗口那边库里没有这一行）—— 那时如实提示，
  /// 不要弹一个字段全空的对话框。
  Future<MissingMediaPlan?> _queryMissingPlan(String itemId) async {
    try {
      final raw = await playerWindowChannel.invokeMethod<Object?>(
        PlayerBridgeMethod.queryMissingMedia,
        <String, Object?>{'itemId': itemId},
      );
      final brief = MissingMediaBrief.fromJson(raw);
      if (brief == null) {
        _toast('文件不存在或已被删除');
        return null;
      }
      return brief.toPlan();
    } on WindowChannelException catch (e) {
      diag.error('播放窗口', '查询失效媒体失败', error: e);
      _toast('文件不存在或已被删除（查询失败）');
      return null;
    }
  }

  /// 切换清晰度。**用户操作**，不受自动重试闸限制。
  ///
  /// 换档不是「自己换一条 URL」：播放窗口没有取链能力（见 [PlayRequest] 的
  /// 类文档），所以要把新档位 id 报回主窗口，由它重新取一条链回来 ——
  /// 复用的正是「刷新过期直链」那条通道。位置原样带上，于是换档对用户表现为
  /// 「卡一下接着播」。
  Future<void> _switchQuality(QualityBrief target) async {
    final request = _currentRequest;
    if (request == null || _refreshing) return;
    if (target.id == request.qualityId) return;

    final position = _player?.state.position ?? request.startPosition;
    _refreshing = true;
    try {
      diag.info('播放窗口', '切换清晰度 → ${target.label}（${target.id}）');
      final fresh = await _requestFreshTicket(
        itemId: request.itemId,
        qualityId: target.id,
        position: position,
        reason: '用户切换清晰度 → ${target.label}',
      );
      if (fresh == null) return;
      _currentRequest = fresh;
      // 记进这部片的偏好。判据是**回来的那条链实际落在哪一档**
      // （`fresh.qualityId`），不是我们请求的那一档：主窗口在目标档取不到地址时
      // 会回退到别的档，记下请求值会让下次打开去选一个取不到地址的档位 ——
      // 表现是「一进播放页就报错」，而用户上次只是随手点了一下。
      final freshQuality = fresh.qualityId;
      if (freshQuality != null && freshQuality.isNotEmpty) {
        _savePreference((p) => p.withQuality(freshQuality));
      }
      // ⚠️ 这一行是「换档到底有没有走到开流」的**分界证据**。
      //
      // 2026-10-04 实测日志里出现过一次「已刷新直链 →（4K）」之后**没有**
      // `open →`：那时最需要知道的就是「是没走到这一步，还是进去了又被
      // 早退」。只靠下面 `_openStream` 里那行日志分不开这两种情况 ——
      // 少了这一条，下一轮排查还得重新猜。
      diag.info(
        '播放窗口',
        '换档取回新链 → ${fresh.describe()}'
        '（${fresh.isHls ? "HLS 转码档" : "直链原画"}，${fresh.describeHeaders()}）'
        '准备开流 @ ${position.inSeconds}s',
      );
      // 换档：同一部片子的另一条流，用户视线里的位置没变 —— 保留上一帧、
      // 不清缓冲，只给一个「正在切换…」的半透明提示（见 [_openStream]）。
      await _openStream(
        fresh.url,
        fresh.describe(),
        headers: fresh.headers,
        startAt: position,
        keepLastFrame: true,
      );
    } finally {
      _refreshing = false;
    }
  }

  /// 切到剧集列表里的另一集。
  Future<void> _openEpisode(PlaylistEntry entry) async {
    final request = _currentRequest;
    if (request == null || _refreshing) return;
    if (entry.itemId == request.itemId) return;

    // 起点由**我们**算，而不是把库里存的原始值直接报过去：已经看完的一集
    // 要能从头重看，否则点它会直接跳到结尾出字幕。口径与主窗口开播时是
    // 同一处实现（`PlaybackResume`）。
    final start = PlaybackResume.startFrom(
      stored: entry.resumePosition,
      total: entry.duration,
    );
    _refreshing = true;
    try {
      diag.info('播放窗口', '切换剧集 → ${entry.title} @ ${start.inSeconds}s');
      final fresh = await _requestFreshTicket(
        itemId: entry.itemId,
        qualityId: request.qualityId,
        position: start,
        reason: '用户切换剧集 → ${entry.title}',
      );
      if (fresh == null) return;
      // 切集：与切档同理 —— 上一集的画面还在，保留它、给半透明提示，
      // 不要「黑一下再重新缓冲」。
      await _adoptRequest(fresh, startAt: start, keepLastFrame: true);
    } finally {
      _refreshing = false;
    }
  }

  // -------------------------------------------------------------------
  // 播放
  // -------------------------------------------------------------------

  Future<void> _playRequest(PlayRequest request) async {
    // 重入保护只在这一条路上：它是「主窗口推来 / 用户点开」的入口，同一时刻
    // 再来一条说明状态已经乱了。刷新与切集各有自己的闸（见 [_refreshTicket]）。
    if (_busy) return;
    await _adoptRequest(request);
  }

  /// 接纳一条新请求：换上下文、重置节流与刷新闸，然后开流。
  ///
  /// [startAt] 不给就用请求自带的 `startPosition`（切集时要显式给 ——
  /// 那条路的起点是我们算出来的，与请求里带的不是同一个值）。
  ///
  /// [keepLastFrame] 透传给 [_openStream]：切集时为 true（保留上一集画面），
  /// 从主窗口新开播时为 false（没有上一帧可留）。
  Future<void> _adoptRequest(
    PlayRequest request, {
    Duration? startAt,
    bool keepLastFrame = false,
  }) async {
    // 把片名写到窗口标题栏。原生侧建窗时给的是默认标题「云影 · 播放器」，
    // 这里换成真实的片名 —— 任务栏/Dock 上才分得清是哪个窗口。
    unawaited(setChildWindowTitle(request.title));

    // 换片要先重置节流器：否则新片恰好停在上一部片报过的那个整十秒上时，
    // 那一次回报会被当成重复而吞掉。
    //
    // 刷新闸也要重置：上一部片的失败次数不该算到新片上。
    //
    // ⚠️ 判据是 **itemId 变了**，不是「又来了一条请求」：刷新直链也会走到这里，
    // 那条路换的只是 URL，片还是同一部 —— 清掉的话用户正在挑的在线字幕列表
    // 会在一次自动刷新后凭空消失。
    if (_currentRequest?.itemId != request.itemId) {
      // 换集/换片：上一集搜出来的在线字幕**不能留**。搜索条件里带着集号，
      // 留着它会让菜单显示「上一集的字幕」，用户选了会发现对不上时间轴。
      _onlineSubtitles = const [];
      _searchingOnlineSubtitles = false;
      // 外挂字幕是**跟着上一部片挂上去的**，新片开流后 mpv 那边已经没了，
      // 这几个「当前选中」的记账必须一起归零，否则菜单会在一条不存在的
      // 字幕上打勾。
      _activeCloudSubtitleId = null;
      _activeOnlineSubtitleId = null;
      // 本地字幕连「挑过的那个文件」一起清：它是为上一集挑的，下一集几乎
      // 必然对不上时间轴。留在菜单里等于给用户埋一个坑。
      _localSubtitle = null;
      _activeLocalPath = null;
      // 网盘字幕的**预取缓存**跟着条目走，换集就没有意义了：留着既没用又占内存。
      _subtitleTextCache.clear();
      // 音效**只在换片/换集时**从请求里取。
      //
      // ⚠️ 不能放在 `if` 外面：刷新直链也走这个方法，而那条路拿的是同一个
      // 条目的新请求 —— 如果用户刚在本窗口把音效改成「立体声」，主窗口那边
      // 落库还没回来时来一次刷新，就会把选择**悄悄改回**请求里带的旧值。
      // （换片才取，与上面那批「换集清理」同一套时机。）
      _audioEffect = PlayerAudioEffect.parse(request.audioEffect);
      // 逐文件偏好**同一时机**取，理由与上面音效那段完全一样：刷新直链拿的
      // 是同一个条目的新请求，此时重取会把用户刚在本窗口改的字幕/音轨**悄悄
      // 改回**库里那份旧值。
      //
      // 注意这里**只播种、不改写**：请求里那份是主窗口从库里读出来的，用户没
      // 动过的项就原样带着。所以后面报回去时「整份覆盖写」不会抹掉任何一项
      // —— 详见 [_savePreference]。
      _pref = request.preference ?? const PlaybackPreference();
      _audioRestored = false;
      _subtitleRestored = false;
    }

    _currentRequest = request;
    _progressThrottle.reset();
    _refreshGuard.reset();

    await _openStream(
      request.url,
      request.describe(),
      headers: request.headers,
      startAt: startAt ?? request.startPosition,
      keepLastFrame: keepLastFrame,
    );
  }

  /// 播一条**没有库记录**的流：内置自检视频 / 手输直链。
  ///
  /// 必须清掉条目上下文。不清的话有个很隐蔽的后果：先播了库里的第 102 项，
  /// 再点「播放内置自检视频」，`_currentRequest` 还指着 102 —— 自检视频播到
  /// 10 秒时就把进度报成了 102，凭空污染「最近播放」，而且看不出是谁干的。
  Future<void> _playRaw(String uri, String label) async {
    _currentRequest = null;
    // 与 [_adoptRequest] 同一套清理：在线字幕结果是**跟着条目**的，
    // 条目没了它就没有归属了（再打开菜单会列出上一部片搜出来的东西）。
    _onlineSubtitles = const [];
    _searchingOnlineSubtitles = false;
    _activeCloudSubtitleId = null;
    _activeOnlineSubtitleId = null;
    _localSubtitle = null;
    _activeLocalPath = null;
    // 预取的网盘字幕正文同样没有归属了（见 [_adoptRequest] 里那段说明）。
    _subtitleTextCache.clear();
    _progressThrottle.reset();
    _refreshGuard.reset();
    await _play(uri, label);
  }

  /// 用户或主窗口发起的播放。**带重入保护**。
  Future<void> _play(
    String uri,
    String label, {
    Map<String, String> headers = const <String, String>{},
    Duration startAt = Duration.zero,
  }) async {
    if (_busy) return;
    await _openStream(uri, label, headers: headers, startAt: startAt);
  }

  /// 真正去 `open` 一条流。**不带重入保护** —— 闸由调用方各负其责。
  ///
  /// 之所以要把这一步单独拆出来给 [_refreshTicket] 用：直链过期导致的报错
  /// 经常在上一次 `open()` **还没返回时**就到达了，那时 `_busy` 是 true，
  /// 走 [_play] 会被静默吞掉 —— 表现就是「刷新功能明明写了却从不生效」。
  ///
  /// [keepLastFrame] 给**换流**（切清晰度 / 切集 / 刷新直链）用：这些操作里
  /// mpv 的视频输出还挂着上一帧，不该用不透明的罩子盖掉、也不该清缓冲 ——
  /// 否则用户看到的就是「重新缓存了一遍」。首次开播不给（画面本来就是黑的，
  /// 要罩住它）。详见 [_switching]。
  Future<void> _openStream(
    String uri,
    String label, {
    Map<String, String> headers = const <String, String>{},
    Duration startAt = Duration.zero,
    bool keepLastFrame = false,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      // 换流时**不在这里**立 [_switching]：这之后还要先做中继预热（可能几百
      // 毫秒），而那段时间旧会话还开着、**旧流还在正常播** —— 画面上不该有
      // 任何指示，否则等于凭空告诉用户「卡了」。真正该立标记的时刻是
      // `open()` 之前，见下面那处。
      _switching = false;
      // ⚠️ 无条件归零，连 `keepLastFrame` 那条路也一样：它描述的是「**这条**
      // 流有没有出过画面」，而换清晰度换的就是另一条流。留着旧值的话，
      // 「新流没画面」会被上一条流的证据掩盖 —— 护栏正好在最需要它时失效。
      _sawVideoFrame = false;
      // 同一条理由：自检是**按流**做的，换流了就该重新允许抓一次。
      _hlsProbed = false;
      if (!keepLastFrame) {
        // 从这一刻到「解出第一帧」之间画面是**黑的**，而 `open()` 不等文件加载
        // 完成 —— 这段正是「刚打开视频时黑屏」的那几秒，加载指示要盖住它。
        // 收掉它的信号见 [_clearAwaitingFrame]。
        _awaitingFrame = true;
        // 换片源 = 上一次的缓存量与增速全部作废。不清的话缓冲指示会带着
        // 上一部片子的「已缓存 10 秒」出现，然后突然跳回 0。
        _cacheEnd = Duration.zero;
        _cacheRate = null;
        _cacheRateAt = null;
        _cacheFill = null;
        _netBytesPerSecond = null;
        _cacheMeter.reset();
      }
    });
    // 旧中继会话由 [_prepareSource] 交回来、在这里关（见它的文档：必须等
    // `open()` 之后）。声明在 try 之外是为了让 `finally` 一定拿得到它。
    String? pendingClose;
    try {
      _ensurePlayer();
      // 片头状态机随每条新流归零。读 `_currentRequest` 拿这次的开关与手标区间：
      // 换集 / 换清晰度 / 刷新直链都走 `_openStream`，且它们都先把 `_currentRequest`
      // 更新成新请求（新请求带着从主窗口重新读出来的设置与手标区间）。
      // 漏了归零的后果是「只有第一集跳片头」—— `_probed` 留着 true，换集后
      // 永远不再读章节，而第一集恰好最不需要跳。
      final req = _currentRequest;
      _introSession.reset(
        manual: req == null
            ? null
            : IntroMarker.fromMilliseconds(req.introStartMs, req.introEndMs),
        enabled: req?.skipIntro ?? false,
      );
      // 输入速率的采样起点由引擎自己管：它在 `open()` 里重起 1 Hz 轮询
      // （换源那一刻起重新采，上一条流的数字不会带过来）。
      //
      // ⚠️ 请求头必须带上。夸克直链缺 Cookie 一律返回 412，
      // 表现是「能取到链、一播就报错」，而错误信息里看不出是缺头。
      //
      // 日志里**不打 url**：直链带签名查询串，诊断日志是给用户复制粘贴用的，
      // 不能成为泄露渠道。请求头同理，只打键名。
      diag.info('播放窗口', 'open → $label（请求头=${headers.keys.toList()}）');
      // ⚠️ 起播位置**必须**走 `Media(start:)`，**不能**在 open 之后 `seek`。
      //
      // `Player.open()` 并不等待文件加载完成（它只发 `loadlist`，再设
      // `playlist-pos`），紧跟着的那次 `seek` 落在解复用器就绪之前就被丢掉。
      // 实测（产物里的真 libmpv，60 秒素材）：`loadfile` 之后立刻 `seek 20`
      // → 3 秒后位置是 3.0s（seek 被完全忽略）；同一素材改用 `start=20`
      // → 位置 23.0s。
      //
      // 这正是「续播点了没用、每次都从头开始」的根因 —— 主窗口明明算出了
      // 续播点（日志里的「续播：… 从 130s 开始」），播放窗口也确实发起了
      // seek，但它没有生效。换清晰度、刷新过期直链走的也是这一条路。
      //
      // `startAt` 默认为 `Duration.zero` 而不是 null 也是必须的：`start`
      // 属性会**残留**到下一个文件。这个「每次都必须显式给」的规则收在
      // `PlaybackEngine.open` 的契约里（两个内核各自落成自己的下达方式）。
      //
      // 网盘直链先过一遍本地中继（多连接并发预取）。拿不到就**原样直连**：
      // 中继失败一律静默，最坏只是「没变快」，绝不是「播不了」。
      final source = await _prepareSource(uri, label, headers, startAt: startAt);
      pendingClose = source.previousToken;
      // 到这里旧中继会话已经关了（`_prepareSource` 的最后一步），旧流随时会断；
      // 接下来这一句 `open()` 会让内核丢掉当前流。**从这一刻起**才该立
      // 「正在切换…」—— 上一帧还在画面上，所以用半透明罩，别盖掉它。
      if (keepLastFrame && mounted) {
        setState(() => _switching = true);
      }

      // ⚠️ 顺序：**先选内核、再下发音效、最后 open**。
      //   - 选内核要在 `open` 之前（内核一 `open` 就没法换了）；
      //   - 音效要在 `open` 之前重新下发（理由见 [_applyAudioEffect]），
      //     而它必须发给**新选中的**那个内核 —— 顺序反了会发给上一次的内核。
      //
      // 探测用的是**上游**地址与请求头（`uri` / `headers`），不是中继那条
      // `127.0.0.1` 地址：要判的是网盘上那份文件，而中继只是转发。
      // 跳过 HLS、只探 http(s) 这些规则都在 `PlaybackEngineRouter.selectFor`
      // 里 —— **与内置播放页同一份**。
      final router = _router!;
      final selection = await router.selectFor(
        key: '${_currentRequest?.itemId ?? uri}|'
            '${_currentRequest?.qualityId ?? "-"}',
        url: Uri.parse(uri),
        headers: headers,
      );
      if (selection.changed) {
        // 换了内核 = 换了渲染句柄（两个内核的句柄类型不同），画面必须重建。
        _bindEngine(selection.engine);
        if (mounted) setState(() {});
      }

      await _applyAudioEffect();
      await router.engine.open(
        EngineMedia(url: source.url, headers: source.headers, startAt: startAt),
      );
      if (!mounted) return;
      setState(() => _nowPlaying = label);
      // 转码档（HLS）要晚一点再验一次：`open()` 不等加载完成，刚打开那一瞬间
      // `track-list` 必然是空的（见 [_dumpPlaybackDiagnostics] 的时机问题）。
      _scheduleHlsSettleCheck();
    } catch (e, st) {
      // 开流失败就永远等不到第一帧了 —— 必须自己收掉加载指示，否则它会一直
      // 挂在画面上，把「播放失败」的提示也盖住。
      // [_switching] 也要一起收：换流失败时它同样等不到「有画面了」的信号。
      if (mounted) {
        setState(() {
          _awaitingFrame = false;
          _switching = false;
        });
      }
      diag.error('播放窗口', 'open 失败：$label', error: e, stackTrace: st);
      // 必须走 [_toast]：这里直接用 `ScaffoldMessenger.of(context)` 在这个
      // 组件里**一定失败**（理由见 [_messengerKey]）—— 而这条正是
      // 「一播就报错」的路径，用户最需要看到提示的时候反而会再抛一个异常。
      _toast('播放失败：$e');
    } finally {
      // ⚠️ 旧中继会话**在这里**才关（而不是在 `_prepareSource` 里）：
      // mpv 到这一刻才真正换了源，之前它还在读旧会话。理由见
      // [_prepareSource] 的文档（关早了会引出一条假的 HTTP 404）。
      await _closeRelayToken(pendingClose);
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 重新下发「音效」预设。
  ///
  /// ## 为什么每次开流前都要重发
  ///
  /// `audio-channels` 在 mpv 里是**按文件选项**，换一条 URL（换集 / 切清晰度 /
  /// 刷新直链都走 [_openStream]）会回到默认值 —— 只设一次的话，第二集开始音效
  /// 就悄悄失效了，而菜单上那个勾还在（勾读的是我们自己的状态）。
  /// 重新下发的代价是两次 `setProperty`，可以忽略。
  ///
  /// ## 为什么换内核后是空操作
  ///
  /// 音效是 mpv 专有能力：mdk 既没有 `af` 也没有 `audio-channels` 的等价物
  /// （见 [EngineCapabilities.audioEffects]）。DV 片源上它静默跳过 ——
  /// 用户在菜单里点的时候会收到 [_showAudioEffectMenu] 的那句说明。
  Future<void> _applyAudioEffect() async {
    final engine = _engine;
    if (engine is! MediaKitPlaybackEngine) return;
    await PlayerAudioEffect.apply(engine.player, _audioEffect);
  }

  /// 决定这条流**从哪里读**：本地中继，还是原直链。
  ///
  /// 走不通（长度未知 / 是 HLS / 端口绑不上）就原样返回。**失败一律静默** ——
  /// 用户既没有「重试」按钮也没有第二个开关，弹提示只会让人以为播放坏了，
  /// 而真相是「这次没加速」。
  ///
  /// ## ⚠️ 返回里那个 [previousToken] 必须由调用方关（**在 `open()` 之后**）
  ///
  /// 旧中继会话**不能在这里关**。mpv 此刻还在读它，会话一没，那条连接就断，
  /// ffmpeg 立刻吐出：
  ///
  /// ```
  /// http: Stream ends prematurely at 88080384, should be 7563081406
  /// http: Will reconnect at 88080384 in 0 second(s), error=Input/output error.
  /// http: HTTP error 404 Not Found      ← 我们自己的中继对已关闭的 token 回 404
  /// ```
  ///
  /// 而 `isHttp4xxLog` 只按正文里的 `HTTP error 4\d\d` 判定 —— 它分不出这条
  /// 404 来自**我们自己刚拆掉的旧流**。于是每次换档都会误判成「新直链过期」，
  /// 立刻触发一次 `_refreshTicket`，与正在加载的新流抢 `open()`。
  ///
  /// 换成 HLS 档位之后这个误判变得致命：新流本来就慢（要先取 m3u8 再取分片），
  /// 被这次假刷新一打断，用户看到的就是「一切画质就只有两秒」。
  ///
  /// 所以顺序必须是：**建新会话 → 预热 → `open()` → 关旧会话**。
  /// 与中继那条路注释里「先开新的、再关旧的」是同一个理由。
  Future<({String url, Map<String, String> headers, String? previousToken})>
      _prepareSource(
    String uri,
    String label,
    Map<String, String> headers, {
    Duration startAt = Duration.zero,
  }) async {
    // 先把主窗口投过来的配置应用上（见 `PlayRequest.streamRelay`）。
    // 不应用的话这里只能用自己的默认值，「在设置页关掉中继」对独立窗口就
    // 不生效 —— 而用户不可能知道这两条路是分开的，只会觉得开关时灵时不灵。
    final request = _currentRequest;
    _relay.configure(
      enabled: request?.streamRelay ?? true,
      connections: request?.relayConnections ?? 8,
    );

    // 换源 = 上一条中继会话作废。但它**只记下来、不关**：关的动作交给调用方，
    // 必须等 mpv 真的换了源（见本方法的文档）。放在这里关的话，「新流还没开
    // 起来、旧流已经被掐断」这一小段里 mpv 什么都拿不到，而且会引出那条假 404。
    final previousToken = _relayToken;
    _relayToken = null;

    final parsed = Uri.tryParse(uri);
    final size = _currentRequest?.sizeBytes;
    final direct = (url: uri, headers: headers, previousToken: previousToken);
    // 没有请求头 = 本地文件 / 内置自检视频，本来就不走网络。
    if (parsed == null || headers.isEmpty) {
      return direct;
    }
    // 转码档（HLS）**没有「总长度」这回事**，不能拿 size 当门槛：服务端没声明
    // 体积时它是 null，而那条流恰恰最需要走中继（理由见 `isRelayableUrl` 的
    // 文档 —— 播放器直连 CDN 会被本机 `http_proxy` 打成一个未放行的协议）。
    final hls = isHlsUrl(parsed);
    if (!hls && (size == null || size <= 0)) {
      return direct;
    }
    if (!isRelayableUrl(parsed)) {
      return direct;
    }

    final endpoint = await _relay.open(
      StreamTicket(
        url: parsed,
        headers: headers,
        contentLength: size,
        supportsRange: true,
      ),
      label: label,
      // 告诉中继「播放器大概从哪儿开始读」：切集 / 切清晰度时起点常在中后段，
      // 让预取窗口直接摆过去，省掉开流后那一次上游往返。
      //
      // ⚠️ HLS 会话不做预取（上游本来就是分片并发下发的），换算没有意义。
      startOffset: hls ? 0 : _byteOffsetFor(startAt, size!),
    );
    if (endpoint == null) {
      return direct;
    }
    _relayToken = endpoint.token;

    // 只有「换流」（存在旧会话）才等预热：这期间**旧流还在播**，等待是白赚的；
    // 而全新开播时没有旧流垫着，等它就是白白拖慢出画。
    //
    // ⚠️ HLS 不预热：它没有预取窗口可等（`statsOf` 对 HLS 返回 null，
    // `warmUpRelay` 会立刻返回 false）。照走的话日志会打一句误导性的
    // 「预热超时」，看起来像出了问题。
    if (previousToken != null && !hls) {
      final ready = await warmUpRelay(_relay, endpoint.token);
      diag.info('播放窗口', ready ? '新中继已预热，关闭旧会话' : '新中继预热超时，直接切换');
    }

    // ⚠️ 走本地中继时**不带**原请求头：里面是账号 Cookie，而接收方是本机的
    // 中继服务，它会在发往上游时自己带上。
    return (
      url: endpoint.uri.toString(),
      headers: const <String, String>{},
      previousToken: previousToken,
    );
  }

  /// 把续播点换算成**大致**字节偏移，给中继当预取起点的提示。
  ///
  /// 用「时长比例 × 文件大小」近似。VBR 片源上会有偏差，但这里只是**提示**：
  /// 中继拿它摆预取窗口，播放器随后的真实 Range 请求会立刻把窗口拉正，
  /// 偏了只多下一点、不会播错。
  ///
  /// 时长还没解出来（全新开播）时返回 0，等于不提示 —— 那时本来就从头播。
  int _byteOffsetFor(Duration startAt, int length) {
    final total = _duration.inMilliseconds;
    if (startAt <= Duration.zero || total <= 0) return 0;
    final ratio = (startAt.inMilliseconds / total).clamp(0.0, 1.0);
    return (length * ratio).round();
  }

  /// 关掉一条指定会话（而不是「当前会话」）。见 [_prepareSource] 的换源顺序。
  ///
  /// 它替代了原来那个「关当前会话」的写法：换源时必须能**先开新的、再关旧的**，
  /// 所以关闭动作要按 token 指名道姓，而不是看 `_relayToken` 现在指着谁。
  Future<void> _closeRelayToken(String? token) async {
    if (token == null) return;
    await _relay.close(token);
  }

  /// 弹提示用的 messenger。
  ///
  /// ⚠️ **必须用 key，不能用 `ScaffoldMessenger.of(context)`。**
  ///
  /// 这个类的 `context` 是 [PlayerWindowApp] **自己**的 element，而
  /// `MaterialApp`（以及它内部的 `ScaffoldMessenger`）是在 `build()` 里造出来
  /// 的、位于它**下面**。`of(context)` 只会顺着祖先链往上找 —— 而上面什么
  /// 都没有，于是直接抛 `No ScaffoldMessenger widget found`。
  ///
  /// 这个坑很阴：它只在**错误路径**上显形（播放出错、刷新用满、平台不支持），
  /// 平时一次都不会触发。等到真出错那天，用户看到的不是提示，而是另一条异常
  /// —— 提示系统自己成了故障源。
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// `MaterialApp` 的 navigator。
  ///
  /// 菜单浮层由 [showAnchoredMenu] 推到这个 navigator 上（它拿的是**按钮自己**
  /// 的 context，所以本来就能取到），这个 key 是为了给 `MaterialApp` 一个稳定的
  /// navigator 身份，也方便将来从 `State` 里直接推路由。
  ///
  /// ⚠️ 别拿 `build` 里的 `context` 去 `Navigator.of` / `ScaffoldMessenger.of`：
  /// 那是 [PlayerWindowApp] 自己的 element，而它返回的正是 `MaterialApp`
  /// —— 也就是说它在 `MaterialApp` **外面**，头上既没有 `Navigator` 也没有
  /// `MaterialLocalizations`。撞上去会直接抛「No MaterialLocalizations found」。
  /// 提示走 [_messengerKey]，菜单走按钮自己的 context。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 弹一条提示。取 messenger 前先判 mounted —— 这个类里的调用点
  /// 多半在 `await` 之后或流回调里，那时窗口可能已经关了。
  void _toast(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _stop() async {
    await _engine?.stop();
    if (!mounted) return;
    setState(() => _nowPlaying = null);
  }

  // -------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '云影 · 播放器',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      // 提示要用 key 拿 messenger，不能用 `ScaffoldMessenger.of(context)`。
      // 理由见 [_messengerKey] 的说明。
      scaffoldMessengerKey: _messengerKey,
      // 菜单浮层推在这个 navigator 上，理由见 [_navigatorKey]。
      navigatorKey: _navigatorKey,
      home: Scaffold(
        // 整窗都是画面底：窗口形状已经由原生锁成视频比例（见
        // `_onVideoParams`），所以画面之外不该再露出别的东西。
        backgroundColor: AppTheme.cinema,
        body: CallbackShortcuts(
          // 诊断页上**不能**绑播放快捷键：那一页有一个手输直链的输入框，
          // 空格必须能当空格打进去。
          //
          // 这一条不能靠「输入框会自己吃掉空格」来兜底 —— 字符输入**不走**
          // 按键链（它由平台输入法通道送进来），而 `CallbackShortcuts` 在焦点
          // 链上位于输入框**下方**，所以空格会先被我们截走。表现就是
          // 「诊断页里地址打不出空格」，且没有任何报错。
          bindings: _showDiagnostics
              ? _diagnosticsShortcuts
              : _playbackShortcuts,
          child: Focus(
            // 没有它快捷键收不到事件：`CallbackShortcuts` 只在自己处于焦点
            // 链上时才生效，而这个窗口里没有别的可聚焦控件。
            autofocus: true,
            child: _showDiagnostics ? _buildDiagnosticsPage() : _buildPlayer(),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 键盘快捷键
  // -------------------------------------------------------------------

  /// 方向键的步长累加（10 秒 → 30 → 60 → 5 分钟）。
  ///
  /// 与内置播放页共用 [SeekRepeatTracker] 的算法，但**状态各一份** ——
  /// 这个窗口跑在另一个 Flutter 引擎里，够不到播放页那个实例。
  ///
  /// ⚠️ 这张键位表走 `CallbackShortcuts`，**收不到 key-up**，所以「这一串
  /// 结束了没有」只能靠 [seekHoldGap] 的间隔超时判断（那边走
  /// `Focus.onKeyEvent`，松手时能显式复位）。代价是「手快连点两下」的第二下
  /// 会跳 30 秒而不是 10 秒 —— 只是不精确，不会出错。
  final SeekRepeatTracker _seekRepeat = SeekRepeatTracker();

  /// 播放页的键位表。
  ///
  /// ## 为什么必须挂在窗口根节点上
  ///
  /// `CallbackShortcuts` 只是往焦点链里插一个节点，**只在自己位于焦点链上时**
  /// 才收得到按键 —— 所以它下面那个 `Focus(autofocus: true)` 是必需品，
  /// 少了它一条快捷键都不会触发，而且**不报任何错**。
  ///
  /// ## 为什么控制栏整块被设成不可聚焦
  ///
  /// 按键从**主焦点**出发沿焦点链往上找，**最近的那个处理者赢**。而控制栏里的
  /// 进度条滑块自带方向键处理 —— 实测（Flutter 3.29）把焦点给一个
  /// `value: 0.5` 的滑块再按 →，它的值会变成 `0.55`：方向键根本轮不到我们。
  /// 于是用户只要点过一次进度条，← / → 就再也不是「跳 10 秒」，而且滑块会停在
  /// 拖拽预览态上不动（见 [_seekPreview]），看起来像进度条坏了。
  /// 控制栏里的控件本来就只该用鼠标操作，所以整块关掉聚焦 —— 见
  /// [_buildChrome] 里那层 `ExcludeFocus`。
  ///
  /// ⚠️ 空格**不**受这个问题影响：实测焦点在一个按钮上时按空格，按钮的
  /// `onPressed` 不会被触发、走的仍然是我们这张表（按钮的激活键绑在
  /// `WidgetsApp` 那一层，比我们远）。所以 `ExcludeFocus` 是为了方向键，
  /// 不是为了空格 —— 别把它当成「顺便防按钮」。
  Map<ShortcutActivator, VoidCallback> get _playbackShortcuts =>
      <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): _onPlayPauseKey,
        // 长按 ←/→ 会连续触发（`SingleActivator` 默认 `includeRepeats: true`），
        // 步长交给累加器：按一下 10 秒，按住不放会涨到 5 分钟。
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekBy(-_seekRepeat.step(-1)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seekBy(_seekRepeat.step(1)),
        // 数字键跳百分比。遥控器那套（内置播放页）也有，键表在
        // `widgets/player_keys.dart` 里共享 —— 两边「哪个键算数字几」必须一致。
        for (final entry in seekDigitKeys.entries)
          SingleActivator(entry.key): () =>
              _seekToFraction(entry.value / 10),
        // 与桌面播放器的通行习惯一致：F 切换全屏、Esc 退出。
        const SingleActivator(LogicalKeyboardKey.keyF): () =>
            _setFullScreen(!_fullScreen),
        const SingleActivator(LogicalKeyboardKey.escape): _onEscapeKey,
      };

  /// 诊断页的键位表：只留 Esc。
  ///
  /// 与 [_playbackShortcuts] 分成两张表而不是在同一张里加判断，是因为这里要
  /// **腾出空格**给输入框（理由见 `build()` 里的说明）。
  Map<ShortcutActivator, VoidCallback> get _diagnosticsShortcuts =>
      <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _onEscapeKey,
      };

  /// 空格：播放 / 暂停。
  ///
  /// 与「单击画面」共用 [_togglePlay]，但**多一步 [_pokeChrome]**：
  /// 单击画面本来就会顺手把浮层收掉，而按空格时用户正在看画面 —— 不把浮层
  /// 亮一下，他看不到按钮已经从「播放」翻成「暂停」，只会怀疑按键没生效。
  void _onPlayPauseKey() {
    if (_engine == null) return;
    _togglePlay();
    _pokeChrome();
  }

  /// 发起 seek 的**唯一**入口 —— 除了转发给 mpv，还负责作废缓存测速的样本。
  ///
  /// ## 为什么必须统一走这里
  ///
  /// `demuxer-cache-time` 是**绝对时间戳**（见 [PlayerBufferProgress]），
  /// 所以**向前** seek 会让它整体跳升一大截。那段「增长」不是下载速度，
  /// 留在 [CacheSpeedMeter] 的窗口里会被算成一个假尖峰（倍速能到几百上千），
  /// 并在界面上挂满 [_cacheRateStaleAfter]。
  ///
  /// [CacheSpeedMeter] 自己的回退容差挡不住这种情况 —— 它处理的是「变小」
  /// （换片源、往回跳），而向前跳是「变大」，看起来就像缓存暴涨。
  ///
  /// 顺手把已经算出的 [_cacheRate] 也清掉：`reset()` 只清样本，旧值还会靠
  /// 那个 5 秒宽限继续显示，而它一定不适用于新位置。
  Future<void> _seek(Duration target) async {
    _cacheMeter.reset();
    _cacheRate = null;
    _cacheRateAt = null;
    await _engine?.seek(target);
  }

  /// ← / →：相对跳转。
  ///
  /// 基准取 [_position]（由契约的 `position` 流搬进来）。它原来读的是
  /// `player.state.position` —— 两者**同一节拍**（mpv 的 `state.position`
  /// 本来就是这个流在更新），所以「刚跳完立刻再按一下」时的新鲜度没有变化。
  void _seekBy(Duration delta) {
    if (_engine == null) return;
    final target = clampSeekTarget(_position + delta, _duration);
    unawaited(_seek(target));
    // 同 [_onPlayPauseKey]：让用户看见时间码跳到了哪儿。
    _pokeChrome();
  }

  /// 数字键：跳到片子的 [fraction]（`0.0`–`0.9`）。
  ///
  /// ## 为什么时长未知时**什么都不做**
  ///
  /// 还在探测容器（或直播流）时 `duration` 是 0。拿它当分母的话目标恒为 0，
  /// 于是「按 5 跳到一半」变成「跳回开头」—— 用户会以为自己按错了键，
  /// 然后反复按，每次都回到开头。宁可这一下不生效。
  ///
  /// ## 为什么也要 `_pokeChrome()`
  ///
  /// 与 [_seekBy] 同一个理由：跳完必须让用户看见时间码落到哪儿了。
  void _seekToFraction(double fraction) {
    if (_engine == null) return;
    final duration = _duration;
    if (duration <= Duration.zero) return;

    final target = clampSeekTarget(
      Duration(milliseconds: (duration.inMilliseconds * fraction).round()),
      duration,
    );
    unawaited(_seek(target));
    _pokeChrome();
  }

  /// Esc：先退全屏，再退诊断页。
  ///
  /// 两个分支的顺序是刻意的 —— 全屏下打开诊断页时，用户第一下 Esc 想的是
  /// 「退出全屏」，而不是「回到播放」。
  void _onEscapeKey() {
    if (_fullScreen) {
      _setFullScreen(false);
    } else if (_showDiagnostics) {
      // 诊断页开着时 Esc 退回播放 —— 与「返回播放」按钮同义。
      setState(() => _showDiagnostics = false);
    }
  }

  // -------------------------------------------------------------------
  // 播放器（窗口化与全屏**共用同一套**布局）
  // -------------------------------------------------------------------

  /// 播放器主体：画面铺满，控制栏浮在底部。
  ///
  /// 全屏与窗口化**不再分两套布局**。原来分两套是因为窗口化那边是个可滚动的
  /// 诊断页、画面被夹在中间；现在诊断页挪走了，两种形态的唯一差别只剩
  /// 「窗口有多大」—— 那是原生的事，Dart 这边不必知道。
  Widget _buildPlayer() {
    final playlist = _currentRequest?.playlist ?? const <PlaylistEntry>[];
    return MouseRegion(
      // 鼠标在窗口里动 → 显示浮层并重置隐藏倒计时。
      //
      // 整窗**一个** region：控制栏与剧集列表都在它内部，所以它们在树上
      // 的位置不影响「鼠标在动」这件事。
      onHover: (_) => _pokeChrome(),
      // 指针**进入窗口**也要唤醒浮层 —— 光有 `onHover` 不够。
      //
      // 引擎把 `mouseEntered` 翻成 pointer **add**（`FlutterViewController` 的
      // `mouseEntered:` → `kAdd`），而 `MouseRegion.onHover` 只在
      // `PointerHoverEvent` 上回调：鼠标滑进来后**立刻停住**（只来了一个 add、
      // 没有后续 move）时浮层不会出现。而「滑到画面上看一眼有哪些按钮」正是
      // 最常见的动作，所以这条必须有。
      //
      // ⚠️ 它同时也是**窗口没焦点**时的那条路：原生侧把子窗口的
      // `mouseTrackingMode` 设成了 `.always`（见 `MainFlutterWindow.swift` 的
      // `ChildWindowController.attach`），否则窗口不是 key window 时引擎一个
      // hover 事件都不送过来，这一整块浮层就再也叫不醒。
      onEnter: (_) => _pokeChrome(),
      // 移出窗口 → 立刻收起。这就是「鼠标移除窗口，标题和播放栏隐藏」。
      onExit: (_) => _hideChrome(),
      child: Row(
        // ⚠️ 必须 stretch：默认的 center 会把 Row 的子项高度压成 0
        // （`Stack` 只有 `Positioned` 子项时按最小约束取尺寸），画面直接消失。
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 画面区。**挤窄而不是被盖住**：下面那个面板一展开，这一块就变窄，
          // 于是 `BoxFit.contain` 会重新算比例，画面永远不会被列表压在底下。
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: _buildVideoSurface()),

                // 缓冲 / 加载指示。放在控制栏**之前**（画在它下面）：它不吃
                // 点击，但如果画在控制栏上面，会把「正在缓冲」盖在按钮上。
                if (_awaitingFrame || _buffering || _switching)
                  Positioned.fill(child: _buildLoadingVeil()),

                // 剧集面板的入口：贴在画面区右边缘的一条竖长条。
                //
                // 放在**画面区**里而不是整个窗口的右边：面板展开时画面区变窄，
                // 它跟着挪到面板的左边缘，于是「点一下收起」永远在面板边上，
                // 不必去窗口最右侧找它。
                if (playlist.length > 1)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: _buildPlaylistEdgeTab(),
                  ),

                // 顶部浮层：片名 + 网盘全路径。
                //
                // ⚠️ 它与底部控制栏**共用同一份显隐状态**（[_chromeVisible]），
                // 自己**不持有任何定时器** —— 「显示和消失同控制栏一致」就是靠
                // 这一条落地的：鼠标动 / 进窗口出现、移出窗口或静置超时收起，
                // 两条永远同步。若给它单开一个 Timer，两边迟早会错开半拍。
                //
                // 隐藏时同样**整个移出树**（理由与下面那条一样）：留一个透明的
                // 层会在画面顶部多出一条看不见、却照样吃点击的死区。
                if (_chromeVisible)
                  Positioned(left: 0, right: 0, top: 0, child: _buildTopChrome()),

                // 片名 + 控制栏浮层。隐藏时**整个移出树**，而不是留一个透明的层 ——
                // 留层会让画面底部多出一条看不见、但照样吃点击的区域。
                if (_chromeVisible)
                  Positioned(left: 0, right: 0, bottom: 0, child: _buildChrome()),
              ],
            ),
          ),

          // 剧集面板：**挤占**画面宽度。
          if (playlist.length > 1) _buildPlaylistRegion(playlist),
        ],
      ),
    );
  }

  /// 贴在画面右边缘的剧集面板入口。
  ///
  /// 平时**透明且不响应点击**，鼠标一进窗口（浮层显形）才淡入。这样它既不挡
  /// 画面，又不会变成一块看不见却照样吃掉点击的死区 —— 那是最难查的一类
  /// 「点了没反应」。
  Widget _buildPlaylistEdgeTab() {
    final shown = _chromeVisible || _playlistOpen;
    return Center(
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: IgnorePointer(
          ignoring: !shown,
          child: Tooltip(
            message: _playlistOpen ? '收起剧集列表' : '剧集列表',
            child: ClipRRect(
              // 只圆左边：右边是画面边界，圆了会像一块浮在半空的小卡片。
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(8),
              ),
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                child: InkWell(
                  onTap: _togglePlaylist,
                  child: SizedBox(
                    width: 26,
                    height: 66,
                    child: Icon(
                      _playlistOpen
                          ? Icons.chevron_right_rounded
                          : Icons.chevron_left_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 会滑动、会挤窄画面的剧集面板容器。
  ///
  /// 两层动画**必须同时跑、同时长**：
  ///   - 外层 `AnimatedContainer` 把宽度从 0 放到 [_playlistWidth]，画面因此被
  ///     挤窄（`Expanded` 让出来的）；
  ///   - 内层 `AnimatedSlide` 把面板本体从右侧外面平移进来。
  ///
  /// 只做第一层是「擦除」（内容不动、露出得越来越多），只做第二层面板会
  /// 压在画面上 —— 用户要的是「面板滑进来，画面让位」，两个都得有。
  ///
  /// 面板本体**固定** [_playlistWidth] 宽再被 `ClipRect` 裁，而不是让它跟着
  /// 容器一起被压扁：压扁会让里面的文字在动画途中反复重排，看着像在抖。
  Widget _buildPlaylistRegion(List<PlaylistEntry> entries) {
    final open = _playlistOpen;
    return ClipRect(
      child: AnimatedContainer(
        duration: _playlistAnimDuration,
        curve: Curves.easeOutCubic,
        width: open ? _playlistWidth : 0,
        child: _playlistMounted
            ? AnimatedSlide(
                offset: open ? Offset.zero : const Offset(1, 0),
                duration: _playlistAnimDuration,
                curve: Curves.easeOutCubic,
                child: SizedBox(
                  width: _playlistWidth,
                  height: double.infinity,
                  child: _buildPlaylistPanel(entries),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildVideoSurface() {
    final engine = _engine;
    return GestureDetector(
      // 单击：播放 / 暂停，并收起浮层。
      //
      // ⚠️ 与双击共存是安全的：`GestureDetector` 同时挂了 `onTap` 与
      // `onDoubleTap` 时，单击会被**推迟到双击判定超时之后**才触发 ——
      // 双击进全屏不会先「暂停一下」。
      onTap: () {
        _togglePlay();
        _hideChrome();
      },
      // 双击切全屏 —— 走**我们自己的**原生窗口全屏。
      //
      // ⚠️ 刻意不用 media_kit 自带的那一套：它默认的 `onEnterFullscreen`
      // 会在窗口**内部** push 一个 Navigator 路由（不是真的 macOS 全屏），
      // 而那条路由在 pop 时会对一个已经失活的 element 做
      // `dependOnInheritedWidgetOfExactType`，直接抛
      // 「Looking up a deactivated widget's ancestor is unsafe」。
      // 两套全屏机制并存只会互相打架，所以用 `controls: NoVideoControls`
      // 把它的控制栏与全屏一起关掉，全屏只留我们自己这一套。
      onDoubleTap: () => _setFullScreen(!_fullScreen),
      // 拖拽画面 = 拖动窗口。标题栏已经去掉了（见 `MainFlutterWindow.swift`），
      // 所以画面本身就是唯一还能拖的地方 —— 不做这件事的话，无边框窗口
      // 就只能靠系统的那一小条边来挪，等于挪不动。
      //
      // ⚠️ 只报「开始 / 继续」两件事，**不报位移**：位移由原生按鼠标的
      // **屏幕**坐标算（见 `beginChildWindowDrag`）。原来逐帧报 `details.delta`
      // 会在 macOS 上自激振荡 —— 窗口一移动，同一个鼠标位置在窗口内的坐标就
      // 反着变了，而系统会把这次变化当成新的拖动事件补发回来，于是我们再加一次
      // 反向位移，窗口就在两个位置之间高频抖动。实测反馈正是「拖拽时窗口抖得
      // 厉害」。绝对坐标没有这个回路，而且误差不累积。
      onPanStart: (_) => unawaited(beginChildWindowDrag()),
      onPanUpdate: (_) => unawaited(updateChildWindowDrag()),
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: AppTheme.cinema,
        // `BoxFit.contain` 是「视频固定比例、黑边填充」的实现：窗口随便拖成
        // 什么形状，画面都保持自己的比例，多出来的地方由这层底色补成黑边。
        //
        // ⚠️ 用 [PlaybackSurface] 而不是直接 `Video(...)`：两个内核的渲染句柄
        // **类型不同**（media_kit 是 `VideoController`，fvp 是
        // `VideoPlayerController`），挑哪个组件是它的事。
        //
        // 不带控制栏（media_kit 那边给 `controls: null`）：双击进全屏走的是
        // **我们自己的**原生窗口全屏，理由见上面 `onDoubleTap` 那段说明。
        child: engine == null
            ? const Center(
                child: Text(
                  '还没有载入片源',
                  style: TextStyle(fontSize: 13, color: AppTheme.dim),
                ),
              )
            : PlaybackSurface(
                engine: engine,
                fit: BoxFit.contain,
                fill: AppTheme.cinema,
              ),
      ),
    );
  }

  /// 加载 / 缓冲指示。
  ///
  /// 覆盖两段黑屏：
  ///   - [_awaitingFrame]：开流到解出第一帧之间。`Player.open()` **不等文件
  ///     加载完成**，这段画面是全黑的，也是最该给反馈的几秒；
  ///   - [_buffering]：播到一半缓存见底，mpv 停下来等数据；
  ///   - [_switching]：换流（切清晰度 / 切集 / 刷链）。上一帧还在画面上，
  ///     所以底色与 [_buffering] 同为半透明 —— 只是文案不同，让用户知道
  ///     这是他自己刚点的操作，而不是网络出问题。
  ///
  /// 两段的底色**不一样**：等首帧时画面本来就是黑的，用不透明底色把它盖掉；
  /// 中途卡顿 / 换流则只压一层半透明 —— 那一帧画面还在，全盖掉等于把进度也抹了。
  Widget _buildLoadingVeil() {
    final fill = _cacheFill;
    // mpv 的填充百分比一旦到 100 就再也不变，那时进度条只会顶在那儿假装
    // 还在加载 —— 退回不确定态（这一层的转圈本来就一直在转）。
    final showBar = fill != null && fill > 0 && fill < 100;

    return IgnorePointer(
      // 吃点击没有意义：这层只是画面上的一个告知，让它透过去，用户照样能
      // 点暂停、点关闭。
      child: ColoredBox(
        color: _awaitingFrame
            ? AppTheme.cinema
            : Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _awaitingFrame
                    ? '正在载入片源…'
                    : _switching
                        ? '正在切换…'
                        : '正在缓冲…',
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Text(
                _cacheStatusLine(),
                style: const TextStyle(fontSize: 11.5, color: Colors.white70),
              ),
              if (showBar) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: 180,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: fill / 100,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 「已缓存多少 · 多快」那一行。两样都拿不到就只说在等。
  ///
  /// ⚠️ 显示的是**播放头前面还有多少秒**（`缓冲终点 − 播放头`），不是
  /// [_cacheEnd] 本身。后者是绝对时间戳（语义是「缓存到 14:11 了」），
  /// 直接印出来会是一个跟总时长同量级的数 —— 而这一行唯一的用处是回答
  /// 「还能撑多久」，那恰好就是超前的秒数。
  String _cacheStatusLine() {
    final ahead = _cacheEnd > _position ? _cacheEnd - _position : Duration.zero;
    final parts = <String>['已缓存 ${_formatDuration(ahead)}'];

    final bytes = _currentBytesPerSecond();
    if (bytes != null && bytes >= 1) {
      // 复用 `formatBytes`（已有单测覆盖），只在后面补一个「/秒」。
      parts.add('≈${formatBytes(bytes.round())}/s');
    } else {
      // 没有文件大小（手输直链、自检视频）、或字节数被护栏挡下时，退回报倍速
      // —— 它本身也说明问题：`1.0×` 是下载与播放持平的分界线。
      final rate = _currentCacheRate;
      if (rate != null && rate > 0.05) {
        parts.add('${rate.toStringAsFixed(1)}×');
      }
    }
    return parts.join(' · ');
  }

  /// 界面上该显示多少字节/秒。
  ///
  /// **优先用内核直接给的输入速率**（[_netBytesPerSecond]，真实下载速率），
  /// 拿不到才退回估算。两条路的差别很实际：估算要乘「文件大小 ÷ 时长」这个
  /// 平均码率，播转码档时它跟实际流码率对不上，会把网速放大若干倍。
  ///
  /// ⚠️ 换到 fvp 内核后第一条路**永远拿不到值**（mdk 没有
  /// `demuxer-cache-state` 的对等物，见 [EngineCapabilities.networkSpeed]）——
  /// 于是 DV 片源上显示的始终是估算值。这是**已知的降级**，不是故障。
  ///
  /// 两条路都过同一道护栏（[defaultMaxCacheBytesPerSecond]）：无论来源如何，
  /// 超过它就不是网速，宁可这一拍不显示。
  double? _currentBytesPerSecond() {
    final net = _netBytesPerSecond;
    if (net != null && net >= 1 && net <= defaultMaxCacheBytesPerSecond) {
      return net;
    }
    return _cacheBytesPerSecond();
  }

  /// 把 [CacheSpeedMeter] 的倍速换算成字节/秒；缺任何一环、或算出来的数字
  /// 物理上不可能时返回 `null`。
  ///
  /// 换算与护栏都在 [cacheBytesPerSecond] 里 —— 那里写了为什么必须挡掉
  /// GB/s 级的数字（一句话：`demuxer-cache-time` 量到的可能是本地块填充，
  /// 不是下载），别在这里另写一份判断。
  double? _cacheBytesPerSecond() {
    return cacheBytesPerSecond(
      rate: _currentCacheRate,
      sizeBytes: _currentRequest?.sizeBytes,
      duration: _duration,
    );
  }

  // ⚠️ 这里原来有一个 1 Hz 轮询 `demuxer-cache-state` 的计时器
  //（`_startNetSpeedPolling` / `_readNetSpeed`）。它**搬进引擎**了
  // （`MediaKitPlaybackEngine`），本类只订阅契约的 `networkSpeed` 流
  // —— 理由很实际：两个播放器各轮询一次会得到两份不同的读数，
  // 而「怎么读这个属性」本来就该跟着内核走。

  /// 顶部浮层：片名 + 网盘全路径。
  ///
  /// ## 为什么放顶部而不是并进控制栏
  ///
  /// 控制栏那一行（[_buildNowPlayingLine]）已经在底部了，再往里塞路径会把
  /// 进度条挤窄；而且底部那一行**只出片名**——同名文件（翡翠台 / 粤语 /
  /// 4K 重制）在它上面长得一模一样，用户没法确认「放的是哪一份」。
  ///
  /// ## 显隐
  ///
  /// 它**没有自己的定时器**：显隐完全由 [_chromeVisible] 决定，与底部控制栏
  /// 逐帧同步（见 [_buildPlayer] 那处的说明）。这里的 `MouseRegion` 只负责
  /// 「鼠标停在浮层上时别收」（用户正在读那一长串路径），语义与控制栏那层
  /// 完全一致。
  ///
  /// 用**自上而下的渐变**（与控制栏的自下而上镜像）：纯色会在亮画面上显成
  /// 一块贴在顶部的补丁，渐变能让它的下边缘「化」进画面里。
  Widget _buildTopChrome() {
    final request = _currentRequest;
    final title = request?.title ?? '';
    // 自检视频 / 手输直链没有网盘路径，那时整行不画 —— 留一个空行只会把
    // 片名推得离顶边更远。
    final path = request?.filePath ?? '';

    return MouseRegion(
      // 给用例一个稳定的抓手：顶栏的高度会随「有没有路径」变（见下面那个
      // `if (path.isNotEmpty)`），而「高度对不对」只能靠量尺寸断言 ——
      // 少了这个 key，测试就只能靠「第几个 MouseRegion」去猜，一改布局就误报。
      key: topChromeKey,
      // 鼠标停在浮层上时**别收起** —— 用户可能正在读路径。
      onEnter: (_) => _cancelHide(),
      onHover: (_) => _cancelHide(),
      // 回到画面上：重新开始计时，而不是立刻收（那样鼠标一动就闪）。
      onExit: (_) => _pokeChrome(),
      child: GestureDetector(
        // 吃掉落在浮层上的点击，别穿到下面的画面手势层变成「点一下 → 暂停」。
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: 0.78),
                Colors.black.withValues(alpha: 0.55),
                Colors.black.withValues(alpha: 0),
              ],
              stops: const <double>[0, 0.45, 1],
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.isEmpty ? '云影 · 播放器' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (path.isNotEmpty) ...[
                const SizedBox(height: 3),
                // 路径通常比片名长得多，**必然**被省略号截断。挂个 tooltip
                // 让人hover 一下能看到完整路径 —— 否则这一行等于只显示了
                // 前十几个字，而用户要确认的恰恰是结尾那一段（档位/版本）。
                Tooltip(
                  message: path,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white70,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 底部浮层：片名 + 进度条 + 按钮行。
  ///
  /// 用**渐变**而不是一块纯色半透明：纯色在亮画面上会显成一块贴在底部的
  /// 补丁，渐变能让它的上边缘「化」进画面里。
  Widget _buildChrome() {
    // ⚠️ 这层 `ExcludeFocus` 不是装饰，是 ← / → 能生效的**前提**。
    //
    // 按键从主焦点沿焦点链往上找、最近的处理器赢。进度条滑块自带方向键处理
    // （实测：焦点给滑块后按 →，值会从 0.50 变 0.55）—— 用户只要点过一次
    // 进度条，← / → 就变成「调滑块的值」而不是「跳 10 秒」，而滑块会停在
    // 拖拽预览态上不动（见 [_seekPreview]），看起来就是「进度条卡住了」。
    //
    // 关掉聚焦**不影响鼠标**：点击、拖拽走的是手势层，不经过焦点。
    // 详细理由与实测数据见 [_playbackShortcuts]。
    return ExcludeFocus(
      child: MouseRegion(
        // 鼠标停在浮层上时**别收起** —— 用户可能正在拖进度条、正在找按钮。
        onEnter: (_) => _cancelHide(),
        onHover: (_) => _cancelHide(),
        // 从浮层回到画面上：重新开始计时，而不是立刻收（那样鼠标一动就闪）。
        onExit: (_) => _pokeChrome(),
        child: GestureDetector(
          // 吃掉落在浮层上的点击。不挡的话它们会穿到下面的画面手势层，
          // 变成「点一下控制栏的空白处 → 暂停」。
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.78),
                ],
                stops: const <double>[0, 0.4, 1],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildNowPlayingLine(),
                const SizedBox(height: 2),
                _buildSeekBar(),
                _buildButtonRow(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 片名那一行：左边片名，右边「第几集 / 共几集」。
  Widget _buildNowPlayingLine() {
    final request = _currentRequest;
    final title = request?.title ?? '';
    final playlist = request?.playlist ?? const <PlaylistEntry>[];
    final index = _currentEpisodeIndex(playlist);

    return Row(
      children: [
        Expanded(
          child: Text(
            title.isEmpty ? '云影 · 播放器' : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (index >= 0)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              '第 ${index + 1} / ${playlist.length} 集',
              style: const TextStyle(fontSize: 11.5, color: Colors.white70),
            ),
          ),
      ],
    );
  }

  Widget _buildButtonRow() {
    final playlist = _currentRequest?.playlist ?? const <PlaylistEntry>[];
    final index = _currentEpisodeIndex(playlist);
    final hasPlaylist = playlist.length > 1;
    final qualities = _currentRequest?.qualities ?? const <QualityBrief>[];
    final hasLibrary =
        _currentRequest != null && _currentRequest!.itemId.isNotEmpty;

    // 控制栏拆成两簇：**左簇**播控（播放 / 上下集 / 片头标记），**右簇**设置
    // （画质 / 字幕 / 音轨 / 刷新 / 置顶 / 自检 / 全屏 / 关闭）。
    //
    // ⚠️ 两簇各自包一层横向滚动、中间用 `Spacer` 撑开 —— 这是「窄窗不溢出」
    // 的唯一稳法，三条理由缺一不可：
    //   1. 剧集面板展开时画面区被挤到 ~480px（见 [_buildPlayer] 里 `Expanded`
    //      让位 320px 面板），一排按钮放不下就溢出，debug 下变 RenderFlex
    //      overflow 异常，真机表现成「开剧集列表后底部按钮乱飞／被裁」。
    //   2. 横向滚动的视口在**滚动方向**给子 `Row` 的是**无界宽度**，所以
    //      `Spacer` / `Expanded` 这种「占剩余空间」的控件**不能**放进滚动
    //      内部的 `Row`（无界里没法算），必须放到**外层这条有界 `Row`** 上。
    //   3. 视口的交叉轴（这里是垂直）也必须拿到有界高度，否则报 `hasSize`；
    //      外层 `Row` 被 `SizedBox(height: 44)` 钉死后，两个滚动视图的垂直
    //      约束就都有界了（44 = 紧凑密度下图标按钮标称高度 48 − 2×2）。
    //
    // 宽窗（不溢出）时：左簇是非 flex 子项，取内容宽度（~180px，永远放得下）；
    // 右簇在 `Flexible` 里拿剩余全部宽度，`mainAxisAlignment.end` 让它贴右边缘
    // —— 视觉与改前完全一致。只有真正放不下时右簇才在 44 高、受限宽度的盒子里
    // 横向滚动，且所有按钮仍在树上（tooltip 找得到、点得到）。
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          // 左簇：播控。非 flex → 取内容宽度，不挤占右簇空间。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: _engine == null ? null : _togglePlay,
                  // 键位写进 tooltip：播放器上没有任何东西提示「空格能暂停」，
                  // 而这是用户最常按的一个键。
                  tooltip: _playing ? '暂停（空格）' : '播放（空格）',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 22,
                    color: Colors.white,
                  ),
                ),
                // 上一集 / 下一集只在真有列表时出现。电影上挂两个永远灰着的
                // 按钮，只会把控制栏撑得更长。
                if (hasPlaylist) ...[
                  _buildBarIcon(
                    icon: Icons.skip_previous_rounded,
                    tooltip: '上一集',
                    onPressed: index > 0
                        ? () => unawaited(_openEpisode(playlist[index - 1]))
                        : null,
                  ),
                  _buildBarIcon(
                    icon: Icons.skip_next_rounded,
                    tooltip: '下一集',
                    onPressed: index >= 0 && index < playlist.length - 1
                        ? () => unawaited(_openEpisode(playlist[index + 1]))
                        : null,
                  ),
                ],
                // 片头标记。只有**有库记录**的片子才显示：自检视频 / 手输直链
                // 没有可写的那一行，点了也只是报错。这个按钮 = 「这部剧的片头
                // 在哪，帮我跳过」，与自动跳片头共用 [IntroSession]。
                if (hasLibrary)
                  Builder(
                    builder: (buttonContext) => _buildBarIcon(
                      icon: Icons.fast_forward_rounded,
                      tooltip: '片头标记',
                      onPressed: _engine == null
                          ? null
                          : () => unawaited(_showIntroMenu(buttonContext)),
                    ),
                  ),
              ],
            ),
          ),
          // 右簇：设置。`Expanded` 拿全部剩余宽度，`Align` 负责把它贴到右边缘；
          // 放不下时在 44 高、受限宽度的盒子里横向滚动，绝不溢出外层 `Row`。
          //
          // ⚠️ 这里**不能**用 `Spacer` + `Flexible`（曾经的写法，实测不贴右）：
          // 两者各是 flex 1，剩余宽度被对半分；而 `SingleChildScrollView` 在主轴
          // 上是收缩的（宽 = 内容宽）、`Flexible` 又是 loose fit —— 分到的那一半
          // 填不满的部分会留在末尾。1280 宽的窗口里右簇右沿离右边框还差 ~150px，
          // 用户看到的就是「底部按钮没右对齐」。`Expanded` 是 tight fit，视口撑满
          // 分配宽度，`Align` 再把内容贴到右边缘；内容真放不下时视口宽度即可用
          // 宽度，横向滚动照常生效。
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // 画质：**文字按钮**而不是图标。用户要看的是「现在是多少」，
                    // 而不是「这里有个设置入口」—— 夸克播放器也是这么做的。
                    //
                    // 按钮外面套一层 `Builder`：菜单要锚在**这个按钮**的正上方，
                    // 就得拿到按钮自己的 `BuildContext` 去量它的位置
                    // （见 [globalRectOf] 与 [_showQualityMenu]）。
                    Builder(
                      builder: (buttonContext) => TextButton(
                        onPressed: qualities.isEmpty
                            ? null
                            : () => unawaited(_showQualityMenu(buttonContext)),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white38,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _currentRequest?.qualityLabel ?? '画质',
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ),
                    // 字幕与音轨。
                    //
                    // 这两个入口**常驻，不按「有没有轨」决定显不显示**：轨道清单
                    // 要等 mpv 解析完容器才填出来，起播前一直是空的。按有无来隐藏
                    // 的话，控制栏会在开播那一瞬间突然多出两个图标，把右边一排
                    // 整体挤动一下 —— 看起来像界面抖了一下。一个灰着的按钮比一个
                    // 会跳动的布局好。
                    Builder(
                      builder: (buttonContext) => _buildBarIcon(
                        icon: Icons.subtitles_outlined,
                        tooltip: '字幕',
                        onPressed: _engine == null
                            ? null
                            : () => unawaited(_showSubtitleMenu(buttonContext)),
                      ),
                    ),
                    Builder(
                      builder: (buttonContext) => _buildBarIcon(
                        icon: Icons.audiotrack_rounded,
                        tooltip: '音轨',
                        onPressed: _engine == null
                            ? null
                            : () => unawaited(_showAudioMenu(buttonContext)),
                      ),
                    ),
                    // 音效紧挨着音轨，但**不是同一件事**（音轨=片源里的流，
                    // 音效=输出处理）。图标用等化器而不是喇叭：喇叭在别的
                    // 播放器里是「音量」，这里再放一个会撞车。
                    Builder(
                      builder: (buttonContext) {
                        // 音效是 mpv 专有能力。DV 片源走 fvp 时这里**置灰并说明
                        // 原因** —— 静默失效的表现是「点了没反应」，那是最难查的
                        // 一类问题，而且用户会以为自己没设置对
                        // （见 [EngineCapabilities] 的类文档）。
                        final ok = _engine?.capabilities.audioEffects ?? false;
                        return _buildBarIcon(
                          icon: Icons.graphic_eq_rounded,
                          tooltip: !ok
                              ? '音效（这条片源用的解码内核不支持）'
                              : _audioEffect == AudioEffectPreset.auto
                                  ? '音效'
                                  : '音效 · '
                                      '${PlayerAudioEffect.label(_audioEffect)}',
                          onPressed: !ok
                              ? null
                              : () => unawaited(
                                    _showAudioEffectMenu(buttonContext),
                                  ),
                        );
                      },
                    ),
                    // 剧集列表的入口**不在这里**。原来它是控制栏上的一个图标，
                    // 但它要跟一个展开后面板走，放在底部控制栏里，展开后会出现
                    // 「按钮在这儿、面板在右上角」的割裂感 —— 现在挪到画面右边缘
                    // 那条竖长条上（见 [_buildPlaylistEdgeTab]），点它面板就从
                    // 那边滑出来。
                    _buildBarIcon(
                      icon: Icons.refresh_rounded,
                      tooltip: _currentRequest == null
                          ? '重新取链（当前片源没有库记录，无从刷新）'
                          : '重新取链并续播',
                      onPressed: _busy || _currentRequest == null
                          ? null
                          : () => unawaited(
                              _refreshTicket(
                                reason: '用户手动触发',
                                manual: true,
                              ),
                            ),
                    ),
                    _buildBarIcon(
                      icon: _alwaysOnTop
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      tooltip: _alwaysOnTop ? '取消置顶' : '窗口置顶',
                      onPressed: () => _setAlwaysOnTop(!_alwaysOnTop),
                    ),
                    _buildBarIcon(
                      icon: Icons.monitor_heart_outlined,
                      tooltip: '环境自检 / 出画验证',
                      onPressed: () => setState(() => _showDiagnostics = true),
                    ),
                    _buildBarIcon(
                      icon: _fullScreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      tooltip: _fullScreen ? '退出全屏（Esc）' : '全屏（F）',
                      onPressed: () => _setFullScreen(!_fullScreen),
                    ),
                    // 全屏下红绿灯被系统收走，这是唯一能确定性地「停掉声音并
                    // 关窗」的地方（先释放再关，不依赖关窗通知的时序）。
                    _buildBarIcon(
                      icon: Icons.close_rounded,
                      tooltip: '停止并关闭',
                      onPressed: _busy ? null : () => unawaited(_stopAndClose()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 剧集列表
  // -------------------------------------------------------------------

  /// 展开 / 收起剧集列表。展开时把当前集滚进视野。
  void _togglePlaylist() {
    _playlistUnmountTimer?.cancel();
    _playlistUnmountTimer = null;

    if (!_playlistOpen) {
      if (_playlistMounted) {
        setState(() => _playlistOpen = true);
      } else {
        // ⚠️ 首次展开必须**分两帧**。隐式动画只在第二次 build 时才开始动：
        // 面板刚上树的那一帧，`AnimatedSlide` 会把 offset 直接设成终值
        // （没有「上一个值」可插值），于是它一挂上来就已经在终点了，
        // 滑入动画根本不会发生。先挂一个「在右外侧、宽度 0」的面板，
        // 下一帧再让它滑进来，两个动画才同时起步。
        setState(() => _playlistMounted = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _playlistOpen = true);
        });
      }
      _revealCurrentEpisode();
      return;
    }

    setState(() => _playlistOpen = false);
    // 等滑出动画跑完再摘掉面板，理由见 [_playlistMounted]。
    _playlistUnmountTimer = Timer(_playlistAnimDuration, () {
      if (!mounted) return;
      setState(() => _playlistMounted = false);
    });
  }

  /// 当前正在播的那一集在列表里的下标。找不到返回 -1。
  int _currentEpisodeIndex(List<PlaylistEntry> entries) {
    final id = _currentRequest?.itemId;
    if (id == null || id.isEmpty) return -1;
    return entries.indexWhere((e) => e.itemId == id);
  }

  /// 把当前正在播的那一集滚进视野。
  ///
  /// **这是列表能不能用的关键**：一部剧几十集，展开后默认停在第一集，
  /// 而用户正在看第 27 集 —— 他得自己滚半天，也就等于这个列表没用。
  void _revealCurrentEpisode() {
    final entries = _currentRequest?.playlist ?? const <PlaylistEntry>[];
    final index = _currentEpisodeIndex(entries);
    if (index < 0) return;

    // 等一帧：此刻列表还没建出来，`position` 拿不到。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_playlistController.hasClients) return;
      final position = _playlistController.position;
      // 让当前集落在**上三分之一**处，而不是正中间：这个列表的用法是
      // 「我在第 27 集，后面还有十几集」，下面留多点上下文更有用。
      final target =
          (index * _episodeTileHeight - position.viewportDimension / 3)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      _playlistController.jumpTo(target);
    });
  }

  Widget _buildPlaylistPanel(List<PlaylistEntry> entries) {
    final currentId = _currentRequest?.itemId;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.84),
        border: Border(
          left: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '剧集（${entries.length}）',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '收起剧集列表',
                  onPressed: _togglePlaylist,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _playlistController,
              // 等高列表：自动定位要用它算偏移（见 [_revealCurrentEpisode]）。
              itemExtent: _episodeTileHeight,
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _buildEpisodeTile(
                  entry,
                  current: entry.itemId == currentId,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 剧集列表里的一行。
  ///
  /// 长什么样、显示哪个字段，全在顶层的 [EpisodeTile] 里 —— 提到那里是为了
  /// 能在测试里**单独渲染**它。这一行里全是「改错不报错」的规则：主标题该是
  /// 文件名还是集号、动效只画在当前那一行、副标题怎么拼，错了都不会抛异常，
  /// 只会看起来「本来就是这么设计的」。
  Widget _buildEpisodeTile(PlaylistEntry entry, {required bool current}) {
    return EpisodeTile(
      // ⚠️ 按**条目**给键，不是按位置。缩略图那一格是有状态的（异步取图），
      // 无键时 `ListView.builder` 会让「第 3 行的 State」跟着**索引**走 ——
      // 换一部剧之后第 3 行就顶着上一部剧第 3 集的图，直到新图下载完。
      // 键让 State 跟着条目走，换剧时直接重建。
      key: ValueKey(entry.itemId),
      entry: entry,
      current: current,
      progress: episodeProgressOf(entry),
      onTap: () => unawaited(_openEpisode(entry)),
    );
  }

  // -------------------------------------------------------------------
  // 画质
  // -------------------------------------------------------------------

  /// 画质菜单。
  ///
  /// 早先用 `showDialog` + `AlertDialog`：菜单**居中**浮在画面正中，盖住画面、
  /// 还跟底部控制栏的画质按钮离得老远。现在贴着**按钮正上方**划出来
  /// （见 [showAnchoredMenu]），点哪儿开、菜单就在哪儿上方，跟主流播放器一致。
  ///
  /// ⚠️ 锚点必须从**按钮自己的** context（[buttonContext]）量，不能用
  /// `State.context`：后者在 `MaterialApp` 外面，量不到按钮的坐标，
  /// 也取不到能推浮层的 Navigator。
  Future<void> _showQualityMenu(BuildContext buttonContext) async {
    final request = _currentRequest;
    if (request == null) return;
    final qualities = request.qualities;
    if (qualities.isEmpty) {
      _toast('这个片源没有可选清晰度');
      return;
    }

    // 菜单存续期间压住控制栏的自动隐藏 —— 含「鼠标移到菜单上被判成移出窗口」
    // 那条**即时**隐藏路径（见 [_menuDepth]）。
    _cancelHide();

    if (!buttonContext.mounted) {
      _pokeChrome();
      return;
    }
    final navigator = Navigator.of(buttonContext, rootNavigator: true);
    final anchor = globalRectOf(buttonContext);
    if (anchor == null) {
      _pokeChrome();
      return;
    }

    final picked = await _pinnedMenu(
      () => showAnchoredMenu<QualityBrief>(
        navigator: navigator,
        anchor: anchor,
        builder: (context) => _QualityMenuPanel(
          qualities: qualities,
          activeId: request.qualityId,
        ),
      ),
    );
    if (!mounted) return;
    _pokeChrome();
    if (picked == null) return;
    await _switchQuality(picked);
  }

  /// 片头标记菜单。
  ///
  /// 与 [PlayerWindowApp] 顶部说明一致：独立窗口不碰数据库，所以这个菜单只把
  /// 「标了什么」报回主窗口（见 [PlayerBridgeMethod.saveIntroRange]），
  /// 落库由主窗口的 [onSaveIntroRange] 完成 —— 那里能拿到 `groupKey` 与仓储。
  Future<void> _showIntroMenu(BuildContext buttonContext) async {
    final request = _currentRequest;
    if (request == null || request.itemId.isEmpty) return;

    _cancelHide();
    if (!buttonContext.mounted) {
      _pokeChrome();
      return;
    }
    final navigator = Navigator.of(buttonContext, rootNavigator: true);
    final anchor = globalRectOf(buttonContext);
    if (anchor == null) {
      _pokeChrome();
      return;
    }

    final marker = _introSession.marker;
    final hasManual = _introSession.manual != null;
    final positionMs = _position.inMilliseconds;

    final action = await _pinnedMenu(
      () => showAnchoredMenu<_IntroAction>(
        navigator: navigator,
        anchor: anchor,
        builder: (context) => _IntroMenuPanel(
          hasMarker: marker != null,
          hasManual: hasManual,
          positionLabel: _fmtPosition(Duration(milliseconds: positionMs)),
        ),
      ),
    );
    if (!mounted) return;
    _pokeChrome();
    if (action == null) return;
    await _applyIntroAction(action, positionMs);
  }

  /// 把用户在片头菜单里选的动作落库，并同步进 [IntroSession]。
  Future<void> _applyIntroAction(_IntroAction action, int positionMs) async {
    final request = _currentRequest;
    if (request == null || request.itemId.isEmpty) return;

    switch (action) {
      case _IntroAction.setStart:
      case _IntroAction.setEnd:
        // 0 秒没意义：用户还没让画面播起来就点「标起点」，会标成一个永远不跳的 0。
        if (positionMs <= 0) {
          _toast('先让画面播起来，再标片头起点 / 终点');
          return;
        }
        final snapshot = await _saveIntroRange(
          request.itemId,
          startMs: action == _IntroAction.setStart ? positionMs : null,
          endMs: action == _IntroAction.setEnd ? positionMs : null,
        );
        if (snapshot == null) {
          _toast('片头标记没保存（库里找不到这部片）');
          return;
        }
        // 落库成功：把最新值同步进状态机，紧接着那次播放就该跳 —— 否则用户会
        // 以为标记没生效，于是再标一次。
        _introSession.setManual(
          IntroMarker.fromMilliseconds(snapshot.startMs, snapshot.endMs),
        );
        _toast(
          action == _IntroAction.setStart
              ? '片头起点已记为 ${_fmtPosition(Duration(milliseconds: positionMs))}'
              : '片头终点已记为 ${_fmtPosition(Duration(milliseconds: positionMs))}',
        );
        // 标完若区间还不成立（只标了一半 / 起终点反了），必须说一声：
        // 否则用户看到的是「标了两个点，可是还是不跳」。
        if (_introSession.marker == null) {
          _toast('还差一半：片头要同时有起点和终点，且起点在终点之前');
        }

      case _IntroAction.jump:
        final marker = _introSession.marker;
        if (marker == null) return;
        unawaited(_seek(marker.start));

      case _IntroAction.clear:
        final snapshot = await _saveIntroRange(request.itemId, clear: true);
        if (snapshot == null) {
          _toast('清除片头标记失败（库里找不到这部片）');
          return;
        }
        _introSession.setManual(null);
        _toast('已清除片头标记');
    }
  }

  /// 把片头区间（起点 / 终点 / 清除）报回主窗口落库，返回落库后的真实值。
  Future<IntroRangeSnapshot?> _saveIntroRange(
    String itemId, {
    int? startMs,
    int? endMs,
    bool clear = false,
  }) async {
    if (!_channelReady) {
      _toast('跨窗口通道不可用，标记存不了');
      return null;
    }
    try {
      final raw = await playerWindowChannel.invokeMethod<Object?>(
        PlayerBridgeMethod.saveIntroRange,
        IntroRangeSaveRequest(
          itemId: itemId,
          startMs: startMs,
          endMs: endMs,
          clear: clear,
        ).toJson(),
      );
      return IntroRangeSnapshot.fromJson(raw);
    } catch (e) {
      diag.error('播放窗口', '保存片头区间失败', error: e);
      return null;
    }
  }

  /// `m:ss`（时长 < 1 小时）或 `h:mm:ss`。
  String _fmtPosition(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 音轨选择菜单。
  ///
  /// 「没有音轨」和「只有一条音轨」是两回事，但**都还是要把菜单打开**：
  /// 用户点它是想知道「这条片子的音频是什么样的」（语言 / 编码 / 声道 / 码率），
  /// 那是**识别**能力，不是「切换」能力。所以只在完全读不到轨道时才提示。
  Future<void> _showAudioMenu(BuildContext buttonContext) async {
    final engine = _engine;
    if (engine == null) return;
    if (_audioTracks.isEmpty) {
      _toast('还没读到音轨（片源可能还在打开）');
      return;
    }

    _cancelHide();
    if (!buttonContext.mounted) {
      _pokeChrome();
      return;
    }
    final navigator = Navigator.of(buttonContext, rootNavigator: true);
    final anchor = globalRectOf(buttonContext);
    if (anchor == null) {
      _pokeChrome();
      return;
    }

    final picked = await _pinnedMenu(
      () => showAnchoredMenu<AudioTrack>(
        navigator: navigator,
        anchor: anchor,
        builder: (context) => _AudioMenuPanel(
          tracks: _audioTracks,
          activeId: _activeAudioId,
        ),
      ),
    );
    if (!mounted) return;
    _pokeChrome();
    if (picked == null) return;
    // 不在这里 setState 记「已选中」：成功与否由内核回报
    // （`activeAudioTrackId` → [_activeAudioId]）。
    //
    // `int.parse` 而不是 `tryParse`：[TrackBridge] 的 id 就是轨道号本身
    // （合成轨已经被引擎剔掉了），解析不了说明上游契约被改坏了。
    await engine.selectAudioTrack(int.parse(picked.id));
    // 记进这部片的偏好。
    //
    // ⚠️ 与「切清晰度」「切字幕」不同，这里**不等成功确认就记**：候选全部来自
    // 内核自己报的轨道清单，切一条清单里存在的轨不会失败（清晰度那条要服务端
    // 重新取链，才需要等 `activeQualityId` 确认）。
    var index = -1;
    for (var i = 0; i < _audioTracks.length; i++) {
      if (_audioTracks[i].id == picked.id) {
        index = i;
        break;
      }
    }
    _savePreference(
      (p) => p.withAudio(
        TrackPreference(
          trackId: picked.id,
          language: picked.language,
          title: picked.title,
          // 下标一并存下：有些片源一条语言标记都不写，那时「用户选的是第几条」
          // 是唯一能跨集对上号的依据（见 `TrackPreference`）。
          index: index < 0 ? null : index,
        ),
      ),
    );
  }

  /// 「音效」菜单 —— 输出的声道 / 直通模式。
  ///
  /// ⛔ 与紧邻的 [_showAudioMenu]（音轨）**不是同一件事**，虽然名字只差一个字：
  /// 音轨列的是**片源里封着的流**（换一集就换一批），音效是**播放端对输出的
  /// 处理方式**（与片源封了什么无关）。夸克播放器也把它们分成「语言」与
  /// 「音效」两个入口。合并两者的第一个后果是用户会以为「音效」里那一列
  /// 就是能选的音轨，找不到粤语时来报「音轨丢了」。
  /// 完整理由与「为什么只有四个选项」见 `core/utils/player_audio_effect.dart`。
  Future<void> _showAudioEffectMenu(BuildContext buttonContext) async {
    final engine = _engine;
    if (engine == null) return;
    // 音效是 mpv 专有能力：mdk 既没有 `af` 也没有 `audio-channels` 的等价物
    // （见 [EngineCapabilities.audioEffects]）。**明说而不是静默**——
    // 静默失效的表现是「用户点了没反应」，那是最难查的一类问题，
    // 而且他会以为自己没设置对。
    if (!engine.capabilities.audioEffects) {
      _toast('这条片源用的是另一个解码内核，音效暂不支持');
      return;
    }

    _cancelHide();
    if (!buttonContext.mounted) {
      _pokeChrome();
      return;
    }
    final navigator = Navigator.of(buttonContext, rootNavigator: true);
    final anchor = globalRectOf(buttonContext);
    if (anchor == null) {
      _pokeChrome();
      return;
    }

    final picked = await _pinnedMenu(
      () => showAnchoredMenu<AudioEffectPreset>(
        navigator: navigator,
        anchor: anchor,
        builder: (context) => _AudioEffectMenuPanel(active: _audioEffect),
      ),
    );
    if (!mounted) return;
    _pokeChrome();
    // 选的是当前这一档时**什么都不做**：白跑一次 `setProperty` 会让 mpv
    // 重配音频输出（听感上是一次极短的断音），而用户什么都没改。
    if (picked == null || picked == _audioEffect) return;

    setState(() => _audioEffect = picked);
    // 立即生效、不重开流：`audio-channels` / `audio-spdif` 都是 mpv 运行期
    // 可改的属性，而重开流会把用户正在看的位置丢掉。
    //
    // 走 [_applyAudioEffect] 而不是直接调 `PlayerAudioEffect`：那一步会自己
    // 判断当前内核是不是 mpv（上面那道闸已经拦住了，这里是第二道保险 ——
    // 换内核的时序与菜单打开之间没有同步关系）。
    await _applyAudioEffect();
    // 报回主窗口落库 —— 播放窗口刻意不碰数据库（见本类的类文档）。
    unawaited(_saveAudioEffect(picked));
    // 同时记进**这部片**的偏好。两个都要写：`saveAudioEffect` 改的是这台设备
    // 的全局默认（下次开别的片也用它），这里记的是「这部片被单独调过」——
    // 两者语义不同，见 `PlaybackPreference.audioEffect`。
    _savePreference((p) => p.withAudioEffect(picked.value));
  }

  /// 把音效选择报回主窗口，由它写进设置库。
  ///
  /// 失败**不影响本次播放**（音效已经生效了），只记一条日志 —— 但必须留痕：
  /// 否则用户下次开窗口发现音效又变回默认，而日志里一条线索都没有。
  Future<void> _saveAudioEffect(AudioEffectPreset preset) async {
    if (!_channelReady) {
      diag.warn('音效', '跨窗口通道不可用，音效设置存不下来（本次播放已生效）');
      return;
    }
    try {
      await playerWindowChannel.invokeMethod<void>(
        PlayerBridgeMethod.saveAudioEffect,
        <String, Object?>{'value': preset.value},
      );
    } catch (e) {
      diag.warn('音效', '音效设置没能报回主窗口（本次播放已生效）：$e');
    }
  }

  /// 字幕选择菜单。
  ///
  /// ## 为什么是个 `while` 循环而不是一次弹菜单
  ///
  /// 菜单里除了字幕，还有一个**动作**项（「搜索在线字幕…」）：选它之后要去网上
  /// 搜，搜完把**同一个菜单**重新打开，让用户从结果里挑。写成递归的话栈会随
  /// 搜索次数增长，而且「谁负责把菜单关掉」会变得很难读 —— 循环把
  /// 「开菜单 → 拿到选择 → 要么应用要么重开」这一件事摆在一处。
  Future<void> _showSubtitleMenu(BuildContext buttonContext) async {
    if (_engine == null) return;

    if (!buttonContext.mounted) return;
    // navigator 与锚点都在**第一次 await 之前**取好：这个菜单会被重开好几次
    //（搜完在线字幕 / 挑完本地文件），每次都去碰按钮的 context 就要跨 async
    // gap，而按钮在整段流程里不会挪位置 —— 取一次就够。
    final navigator = Navigator.of(buttonContext, rootNavigator: true);
    final anchor = globalRectOf(buttonContext);
    if (anchor == null) return;

    // 菜单一打开就在后台预取**网盘字幕**正文：用户浏览菜单这几秒通常足够取完，
    // 等他真点下去就是瞬时挂上，而不是「点了没反应」（那正是被读成
    // 「切字幕要重新缓存」的那一下）。在线字幕不在预取范围（按次计费）。
    _prefetchCloudSubtitles();

    while (true) {
      // 弹菜单这件事单独一个方法：它只收已经取好的 navigator 与锚点，
      // 循环体里也就没有「跨 async gap 用 context」的问题。
      final picked = await _promptSubtitleChoice(navigator, anchor);
      if (!mounted) return;

      // 关掉菜单（点外面 / Esc），或者菜单根本弹不出来（按钮已经不在树上）：
      // 什么都不做，但要把控制栏的隐藏倒计时重新起算 —— 用户刚在这里点过，
      // 此刻把按钮藏起来是最糟的时机。
      if (picked == null) {
        _pokeChrome();
        return;
      }

      if (picked.kind == _SubtitleKind.searchOnline) {
        // 搜索失败 / 一条都没搜到时**不重开菜单**：`_searchOnlineSubtitles`
        // 已经把原因（或结论）弹成提示了，再盖一个菜单上去正好挡住那句话。
        if (!await _searchOnlineSubtitles()) return;
        if (!mounted) return;
        continue;
      }

      if (picked.kind == _SubtitleKind.pickLocal) {
        // 挑完文件**重开菜单**（而不是直接挂上就结束）：用户挑完通常还要看到
        // 「本地文件」那一组里出现了刚挑的那条、并且打上了勾 —— 那是对
        // 「我到底选中了哪个文件」的确认。文件选择器本身不显示这个。
        if (!await _pickLocalSubtitle()) return;
        if (!mounted) return;
        continue;
      }

      _pokeChrome();
      await _applySubtitleChoice(picked);
      return;
    }
  }

  /// 弹出字幕菜单。返回用户的选择；**菜单弹不出来或用户关掉它**都返回 null
  /// （这两种情况调用方的处置完全一样，没必要分开）。
  Future<_SubtitleChoice?> _promptSubtitleChoice(
    NavigatorState navigator,
    Rect anchor,
  ) {
    // 走 [_pinnedMenu] 而不是直接 `showAnchoredMenu`：这个菜单会**重开**
    // （搜完在线字幕 / 挑完本地文件都再来一次），每次重开都重新压住控制栏的
    // 自动隐藏；中间那段搜索时间里调用方自己也没起计时（见 [_showSubtitleMenu]）。
    return _pinnedMenu(
      () => showAnchoredMenu<_SubtitleChoice>(
        navigator: navigator,
        anchor: anchor,
        builder: (context) => _SubtitleMenuPanel(
          tracks: _embeddedSubtitles,
          cloud: _currentRequest?.subtitles ?? const <SubtitleBrief>[],
          online: _onlineSubtitles,
          searchingOnline: _searchingOnlineSubtitles,
          local: _localSubtitle,
          activeId: _activeSubtitleId,
          activeCloudId: _activeCloudSubtitleId,
          activeOnlineId: _activeOnlineSubtitleId,
          activeLocalPath: _activeLocalPath,
        ),
      ),
    );
  }

  /// 应用一条字幕选择。
  ///
  /// 四种来源在这里穷举。**外挂字幕（网盘 / 在线）比内嵌轨多一步**：要先拿到
  /// 正文才能交给 mpv，而正文在另一个引擎里（见 `PlayerBridgeMethod` 的三个
  /// 字幕方法）。漏掉一种来源的表现是「点了没反应」，所以这里不写 `default`。
  ///
  /// 选中态一律**在成功之后**才 setState，不做乐观更新：外挂字幕可能取不下来，
  /// 乐观更新会让菜单在一条根本没加载上的字幕上打勾，用户以为切成功了。
  Future<void> _applySubtitleChoice(_SubtitleChoice picked) async {
    final engine = _engine;
    if (engine == null) return;

    switch (picked.kind) {
      case _SubtitleKind.off:
        _clearExternalSubtitle();
        await engine.selectSubtitleTrack(null);
        // 「关掉字幕」本身也是一个要记住的选择（见
        // `PlaybackPreference.subtitlesEnabled`）—— 不记的话，用户在一部片里
        // 关掉字幕，下次打开又被自动挂上一条，而他明明关过。
        _savePreference((p) => p.withSubtitle(null));
        return;

      case _SubtitleKind.embedded:
        // 内嵌轨的选择态由内核回报（`activeSubtitleTrackId` →
        // `_activeSubtitleId`），这里只把三个「外挂字幕」的记账清掉。
        //
        // 落一条日志是为了对上 [isSubtitleDiagnosticLog] 那条：内核报
        // 「解不开」时必须能回答「我们到底让它解哪一条」。缺了这条，
        // 只看到一句 `Could not find subtitle decoder` 是不知道该怪谁的。
        diag.info('播放窗口', '选择内嵌字幕轨：id=${picked.trackId}');
        _clearExternalSubtitle();
        await engine.selectSubtitleTrack(picked.trackId);
        // 记进这部片的偏好。`language` / `title` / `index` 从清单里现取 ——
        // 只存一个 `sid` 是没用的：换一集之后那个号指的是完全另一条轨
        // （见 `TrackPreference` 的类文档）。
        final embeddedId = picked.trackId;
        var embeddedIndex = -1;
        for (var i = 0; i < _embeddedSubtitles.length; i++) {
          if (_embeddedSubtitles[i].id == '$embeddedId') {
            embeddedIndex = i;
            break;
          }
        }
        final embeddedTrack =
            embeddedIndex < 0 ? null : _embeddedSubtitles[embeddedIndex];
        _savePreference(
          (p) => p.withSubtitle(
            TrackPreference(
              // 来源前缀与内置播放页同一个口径（那边也是 `embedded#N`）——
              // 少了它就分不出「内嵌第 2 条」与「网盘第 2 条」。
              trackId: 'embedded#$embeddedId',
              language: embeddedTrack?.language,
              title: embeddedTrack?.title,
              index: embeddedIndex < 0 ? null : embeddedIndex,
            ),
          ),
        );
        return;

      case _SubtitleKind.cloud:
        final fileId = picked.fileId;
        if (fileId == null) return;
        final brief = _cloudSubtitleOf(fileId);
        // 预取命中就免掉这次跨窗口往返 + 网盘下载 —— 用户点下去即挂上。
        // 没命中才现取（见 [_prefetchCloudSubtitles]）。
        final text =
            _subtitleTextCache[fileId] ?? await _fetchSubtitleText(fileId);
        if (text == null) {
          if (mounted) _toast('这条网盘字幕取不下来（详见诊断日志）');
          return;
        }
        if (!mounted) return;
        setState(() {
          _activeCloudSubtitleId = fileId;
          _activeOnlineSubtitleId = null;
          _activeLocalPath = null;
        });
        // 走契约的 `loadExternalSubtitleText`（正文直接给）：正文是我们自己
        // 取回来并解码成 UTF-8 的**字符串**，没有地址。mdk 那条路要求 URI，
        // 由实现落临时文件兜底（见契约里那条方法的文档）。
        await engine.loadExternalSubtitleText(
          text,
          title: brief?.label,
          language: brief?.language,
        );
        // 记进这部片的偏好。id 用与内置播放页相同的 `<itemId>#<fileId>`
        // （见 `SubtitleService._buildTrack`）—— 同一个网盘文件在整部剧里
        // id 稳定，所以这一项**跨集也能对上**（还原时见 [_cloudFileIdOf]）。
        final cloudItemId = _currentRequest?.itemId;
        if (cloudItemId != null && cloudItemId.isNotEmpty) {
          final cloudBriefs =
              _currentRequest?.subtitles ?? const <SubtitleBrief>[];
          var cloudIndex = -1;
          for (var i = 0; i < cloudBriefs.length; i++) {
            if (cloudBriefs[i].fileId == fileId) {
              cloudIndex = i;
              break;
            }
          }
          _savePreference(
            (p) => p.withSubtitle(
              TrackPreference(
                trackId: '$cloudItemId#$fileId',
                language: brief?.language,
                title: brief?.label,
                index: cloudIndex < 0 ? null : cloudIndex,
              ),
            ),
          );
        }
        return;

      case _SubtitleKind.online:
        final id = picked.onlineId;
        if (id == null) return;
        final brief = _onlineSubtitleOf(id);
        // 失败时提示已经在里面弹过了，这里直接收工。
        final text = await _fetchOnlineSubtitleText(id);
        if (text == null) return;
        if (!mounted) return;
        setState(() {
          _activeOnlineSubtitleId = id;
          _activeCloudSubtitleId = null;
          _activeLocalPath = null;
        });
        await engine.loadExternalSubtitleText(
          text,
          // 在线字幕没有「我们自己的展示名」，用站点给的标题（片名）回退到
          // 文件名 —— 它们只出现在内核自己的轨道列表里。
          title: brief?.title ?? brief?.fileName,
          language: brief?.language,
        );
        // ⛔ **不记进偏好**：在线字幕按次计费（OpenSubtitles 免费档只有个位数
        // 额度），下次自动还原等于替用户烧额度 —— 而他这次未必想看那条。
        // 代价是「下次打开回到上一条记住的字幕」，这是刻意接受的取舍。
        return;

      case _SubtitleKind.local:
        final path = picked.localPath;
        if (path == null) return;
        // 每次应用都**重新读一遍**文件：路径是不变的，内容可能被外部改过
        // （用户拿编辑器调了时间轴）。缓存正文会让「改了没生效」变成一个
        // 完全无从查起的问题。
        final text = await _readLocalSubtitle(path);
        if (text == null) return;
        if (!mounted) return;
        setState(() {
          _activeLocalPath = path;
          _activeCloudSubtitleId = null;
          _activeOnlineSubtitleId = null;
        });
        await engine.loadExternalSubtitleText(
          text,
          title: picked.localLabel,
          // 本地文件的语言无从得知（文件名里的 `chs` 只是发布组的习惯，
          // 不是规范）。不给比猜错好 —— 内核会用它去做「按语言自动选轨」。
        );
        // ⛔ **不记进偏好**：路径是为**这一集**挑的，下一集几乎必然对不上
        // 时间轴；而且文件很可能已经被删掉或挪走 —— 那时还原会**静默失败**
        //（`_readLocalSubtitle` 返回 null），内核停在「没有字幕」，
        // 比干脆不还原更糟。
        return;

      case _SubtitleKind.searchOnline:
      case _SubtitleKind.pickLocal:
        // 走不到这里：`_showSubtitleMenu` 把它们拦在前面了。写出来只是为了让
        // 穷举是完整的 —— 将来加了新来源，编译器会在这里提醒。
        return;
    }
  }

  /// 把三个「外挂字幕」的选中记账一起清掉。
  ///
  /// ⚠️ 必须**一起**清：同一时刻只可能挂着一条外挂字幕，漏清一个的表现是
  /// 菜单在两行上同时打勾 —— 用户会以为自己挂了两条。
  void _clearExternalSubtitle() {
    setState(() {
      _activeCloudSubtitleId = null;
      _activeOnlineSubtitleId = null;
      _activeLocalPath = null;
    });
  }

  /// 上一次搜索结果里的网盘字幕。
  SubtitleBrief? _cloudSubtitleOf(String fileId) {
    for (final s in _currentRequest?.subtitles ?? const <SubtitleBrief>[]) {
      if (s.fileId == fileId) return s;
    }
    return null;
  }

  /// 上一次搜索结果里的在线字幕。
  OnlineSubtitleBrief? _onlineSubtitleOf(int fileId) {
    for (final s in _onlineSubtitles) {
      if (s.fileId == fileId) return s;
    }
    return null;
  }

  /// 去字幕站搜一次。返回**是否要把菜单重新打开**。
  ///
  /// 返回 false 的三种情况（没片名可搜、请求失败、一条都没搜到）都不该重开
  /// 菜单：前两种要留出地方显示原因，第三种重开只会得到一个和刚才一模一样的
  /// 菜单（`_onlineSubtitles` 是空的，那一组不会出现）。
  Future<bool> _searchOnlineSubtitles() async {
    // 防重入：这个动作会真的打接口，连点两下就是白烧两次额度。
    if (_searchingOnlineSubtitles) return false;

    final request = SubtitleSearchRequest(
      itemId: _currentRequest?.itemId ?? '',
      // 兜底片名用**显示标题**。它可能带集号（`… S01E01`），搜出来会偏 ——
      // 但这条路只在没有库记录时走（手输直链、内置自检视频）；有库记录时
      // 主窗口会拿结构化的片名与季集号去搜（见 `SubtitleQuery`）。
      fallbackQuery: _currentRequest?.title ?? '',
    );
    if (request.isEmpty) {
      _toast('不知道该搜什么：这个片源没有片名，也没有库记录');
      return false;
    }

    setState(() => _searchingOnlineSubtitles = true);
    final List<OnlineSubtitleBrief> hits;
    try {
      final raw = await playerWindowChannel.invokeMethod<List<Object?>>(
        PlayerBridgeMethod.searchOnlineSubtitles,
        request.toJson(),
      );
      hits = <OnlineSubtitleBrief>[
        for (final item in raw ?? const <Object?>[])
          if (OnlineSubtitleBrief.fromJson(item) case final brief?) brief,
      ];
    } on WindowChannelException catch (e) {
      // ⚠️ 失败**不是**「搜不到」。`e.code` 是失败种类（Api-Key 不对、额度用完、
      // 连不上），`e.message` 是一句能直接给用户看的中文。混成「搜不到」的话，
      // 用户会以为这部片没有字幕，而实际要去做的是去设置页改 Key ——
      // 与 TMDB 熔断那个坑是同一个形状。
      if (mounted) {
        setState(() => _searchingOnlineSubtitles = false);
        diag.warn('窗口', '搜索在线字幕失败（${e.code}）：${e.message}');
        _toast(e.message);
      }
      return false;
    } catch (e) {
      if (mounted) {
        setState(() => _searchingOnlineSubtitles = false);
        diag.warn('窗口', '搜索在线字幕失败：$e');
        _toast('搜索在线字幕失败：$e');
      }
      return false;
    }
    if (!mounted) return false;

    setState(() {
      _searchingOnlineSubtitles = false;
      _onlineSubtitles = hits;
    });
    if (hits.isEmpty) {
      _toast('在线字幕站上没有找到匹配的字幕');
      return false;
    }
    diag.info('窗口', '在线字幕候选 ${hits.length} 条，重新打开菜单');
    return true;
  }

  /// 预取**网盘字幕**的正文。字幕菜单打开时调用。
  ///
  /// ## 为什么要预取
  ///
  /// 挂一条网盘字幕要先向主窗口要它的字节（[_fetchSubtitleText]，一次跨窗口
  /// 往返 + 一次网盘下载），再交给 mpv。放在「用户点下之后」做，就是
  /// 「点了没反应」的那一秒 —— 而播放其实**没有中断**，用户却会把它读成
  /// 「切字幕要重新缓存」。
  ///
  /// 预取只是把这段等待**提前**：菜单一打开就开始取，用户浏览菜单的几秒通常
  /// 足够；等他真点了，[_applySubtitleChoice] 直接命中 [_subtitleTextCache]。
  ///
  /// ## ⚠️ 只预取网盘字幕
  ///
  /// **在线字幕不预取**：那条路要走字幕站的下载地址、按次计费，把菜单里所有
  /// 候选都拉一遍等于替用户烧额度（见 [_fetchOnlineSubtitleText] 的说明）。
  ///
  /// **本地字幕也不预取**：它的正文每次都**重新读**，好让用户在外部改过时间轴
  /// 之后能生效（见 [_applySubtitleChoice] 里 `_SubtitleKind.local` 那段）。
  ///
  /// 失败无所谓 —— 真选中时会再取一次，那时才弹提示。
  void _prefetchCloudSubtitles() {
    for (final brief in _currentRequest?.subtitles ?? const <SubtitleBrief>[]) {
      final id = brief.fileId;
      if (id.isEmpty) continue;
      if (_subtitleTextCache.containsKey(id)) continue;
      if (!_subtitlePrefetching.add(id)) continue;
      unawaited(_prefetchOneSubtitle(brief));
    }
  }

  Future<void> _prefetchOneSubtitle(SubtitleBrief brief) async {
    try {
      final text = await _fetchSubtitleText(brief.fileId);
      if (text == null || text.isEmpty || !mounted) return;
      // 不 setState：缓存不参与绘制，只在用户真选中时被读一次。
      _subtitleTextCache[brief.fileId] = text;
      diag.debug('播放窗口', '网盘字幕已预取：${brief.label}');
    } finally {
      _subtitlePrefetching.remove(brief.fileId);
    }
  }

  /// 向主窗口要一条网盘字幕的正文。失败返回 null。
  ///
  /// 通道不通（`CHANNEL_UNREGISTERED`、主窗口没装回调）时**必须**给出提示：
  /// 静默什么都不做会被读成「点了没反应」。
  Future<String?> _fetchSubtitleText(String fileId) async {
    try {
      return await playerWindowChannel.invokeMethod<String>(
        PlayerBridgeMethod.fetchSubtitleText,
        <String, Object?>{'fileId': fileId},
      );
    } on WindowChannelException catch (e) {
      diag.warn('窗口', '取字幕正文失败（通道 ${e.code}）fid=$fileId');
      return null;
    } catch (e) {
      diag.warn('窗口', '取字幕正文失败 fid=$fileId：$e');
      return null;
    }
  }

  /// 让用户挑一个本地字幕文件并**立刻挂上**。返回是否要把菜单重新打开。
  ///
  /// ## 为什么挑完就直接挂，而不是「先挑、再回菜单点一下」
  ///
  /// 挑文件这个动作本身已经表达了「我要用它」。再让用户回菜单点一次是同一步的
  /// 重复，而中间那次菜单重开会让刚弹过的系统选择器看起来像没生效。
  ///
  /// ## 沙箱
  ///
  /// macOS 下读用户挑中的文件需要
  /// `com.apple.security.files.user-selected.read-only`（两份 entitlements
  /// 都已加）。**没有那一条时选择器照样弹、照样返回路径**，只有紧接着的读取会
  /// 失败 —— 所以失败提示必须写清「读不了」，不能只说「加载失败」。
  Future<bool> _pickLocalSubtitle() async {
    const group = XTypeGroup(
      label: '字幕文件',
      extensions: <String>['srt', 'ass', 'ssa', 'vtt', 'sub', 'idx', 'txt'],
    );

    final XFile? file;
    try {
      // 只给 `extensions`、不给 UTType：写错一个 UTType 会让**整个**过滤器
      // 失效（选择器里所有文件都变灰），而扩展名匹配在各版本 macOS 上都成立。
      file = await openFile(acceptedTypeGroups: const <XTypeGroup>[group]);
    } catch (e) {
      diag.warn('窗口', '打开本地字幕选择器失败：$e');
      if (mounted) _toast('打不开文件选择器：$e');
      return false;
    }
    // 用户取消：什么都不做、也不提示 —— 取消不是错误。
    if (file == null || !mounted) return false;

    final picked = _LocalSubtitle(file.path, file.name);
    final text = await _readLocalSubtitle(picked.path);
    if (text == null || !mounted) return false;

    setState(() {
      _localSubtitle = picked;
      _activeLocalPath = picked.path;
      _activeCloudSubtitleId = null;
      _activeOnlineSubtitleId = null;
    });
    // 走契约的 `loadExternalSubtitleText`（正文直接给）而不是
    // `loadExternalSubtitle`（按 URI）：正文是**我们刚刚重新读并解码出来的**
    // —— 用户在外部改过时间轴之后要能生效（见上面那句注释），所以不能把
    // 路径甩给内核让它自己去读。mdk 那条路的「落临时文件」由实现兜底
    // （见契约里那条方法的文档）。
    await _engine?.loadExternalSubtitleText(text, title: picked.label);
    return true;
  }

  /// 读一个本地字幕文件并解码成 UTF-8 文本。失败返回 null（并且已经提示过）。
  ///
  /// 解码必须走 `decodeTextBytes`（先严格 UTF-8、失败再 GBK）：中文外挂字幕
  /// 大量是 GBK，直接用 `readAsString()` 会得到满屏乱码，而且**不报错**。
  Future<String?> _readLocalSubtitle(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.isEmpty) {
        if (mounted) _toast('这个字幕文件是空的');
        return null;
      }
      return decodeTextBytes(bytes);
    } catch (e) {
      // 沙箱没申请权限时会走到这里，而报的**不是**权限错
      // （是 `Operation not permitted` 这种）—— 所以提示写清是「读不了这个文件」。
      diag.warn('窗口', '读本地字幕失败 $path：$e');
      if (mounted) _toast('读不了这个文件：$e');
      return null;
    }
  }

  /// 向主窗口要一条**在线**字幕的正文。失败返回 null，**并且已经弹过提示**。
  ///
  /// 与 [_fetchSubtitleText] 的差别只在错误处理：这条路会走到字幕站上换下载
  /// 地址，最典型的失败是「今天的额度用完了」—— 那句话必须原样透给用户，
  /// 否则他会一直点，而每点一次都在继续烧额度。
  Future<String?> _fetchOnlineSubtitleText(int fileId) async {
    try {
      final text = await playerWindowChannel.invokeMethod<String>(
        PlayerBridgeMethod.fetchOnlineSubtitle,
        <String, Object?>{'fileId': fileId},
      );
      if (text == null || text.isEmpty) {
        if (mounted) _toast('这条在线字幕取不下来（详见诊断日志）');
        return null;
      }
      return text;
    } on WindowChannelException catch (e) {
      if (mounted) {
        diag.warn('窗口', '取在线字幕失败（${e.code}）：${e.message}');
        _toast(e.message);
      }
      return null;
    } catch (e) {
      if (mounted) {
        diag.warn('窗口', '取在线字幕失败 fileId=$fileId：$e');
        _toast('取在线字幕失败：$e');
      }
      return null;
    }
  }

  Widget _buildBarIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 18,
      color: Colors.white,
      disabledColor: Colors.white24,
      // 紧凑：控制栏是浮层，它的高度直接等于被它盖住的画面高度。
      visualDensity: VisualDensity.compact,
      icon: Icon(icon),
    );
  }

  /// 进度条 + 两端时间。
  ///
  /// 用 `StreamBuilder` 而不是把位置存进 State：`position` 是每 ~100ms 一条的
  /// 高频流，存进 State 会让**整个播放器**每秒重建十次（连画面一起）。
  /// 用 StreamBuilder 把重建限制在这条进度条内部。
  ///
  /// ⚠️ 它挂在浮层的 `Column` 里，所以**不能**再包一层 `Expanded`
  /// （那要求 `Row` / `Flex` 父级）。横向伸展由内部那个 `Row` 负责。
  Widget _buildSeekBar() {
    final engine = _engine;
    if (engine == null) return const SizedBox.shrink();

    // ⚠️ 两条流来自**当前**内核。换内核时这个 widget 会被重建（`_openStream`
    // 里那次 `setState`），于是 StreamBuilder 重新订阅 —— 而契约的流是广播且
    // **不重放**的，所以 `initialData` 不是可有可无的优化：它填的正是
    // 「重新订阅」到「下一条事件」之间那一段。
    return StreamBuilder<Duration>(
      stream: engine.duration,
      initialData: _duration,
      builder: (context, durationSnapshot) {
        final total = durationSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: engine.position,
            initialData: _position,
            builder: (context, positionSnapshot) {
              final maxMs = total.inMilliseconds.toDouble();
              final hasDuration = maxMs > 0;
              // 真实的播放头。**不能**用 [_seekPreview]：那是拖拽预览，
              // mpv 的缓存并不会跟着预览值走。
              final played = positionSnapshot.data ?? Duration.zero;
              final current = _seekPreview ?? played;

              return Row(
                children: [
                  _buildTimeLabel(current),
                  Expanded(
                    child: BufferedSlider(
                      value: hasDuration
                          ? (current.inMilliseconds / maxMs).clamp(0.0, 1.0)
                          : 0,
                      // 「已经缓存到这儿了」那一层。见 [_cacheEnd]：它是
                      // **绝对位置**（不是「前面还有多少秒」），换算规则在
                      // [PlayerBufferProgress]；时长未知时返回 null（不画）。
                      buffered: PlayerBufferProgress.fraction(
                        position: played,
                        cacheEnd: _cacheEnd,
                        duration: total,
                        // mpv 自己说在等数据时，缓冲层收到播放头。
                        // 理由见 [PlayerBufferProgress.fraction]。
                        stalled: _buffering,
                      ),
                      // 时长还不知道时（还在解文件头）不给拖：拖了也没意义，
                      // 而且滑块会在真时长到达时突然跳一下。
                      enabled: hasDuration,
                      onChanged: (v) => setState(() {
                            _seekPreview = Duration(
                              milliseconds: (v * maxMs).round(),
                            );
                          }),
                      // 拖拽过程中不 seek —— 那会把 mpv 拖垮，而且中间那些
                      // 位置本来就没有意义。松手才真的跳。
                      onChangeEnd: (v) async {
                        setState(() => _seekPreview = null);
                        await _seek(
                          Duration(milliseconds: (v * maxMs).round()),
                        );
                      },
                    ),
                  ),
                  _buildTimeLabel(total),
                ],
              );
            },
          );
        },
    );
  }

  Widget _buildTimeLabel(Duration d) {
    return Text(
      _formatDuration(d),
      style: const TextStyle(
        fontSize: 11.5,
        color: Colors.white70,
        // 等宽数字：不然秒数从 9 跳到 10 时整条栏会左右抖。
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }

  /// `1:02:03` / `2:03`；未知时长给 `--:--`。
  static String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // -------------------------------------------------------------------
  // 诊断页（默认藏起来）
  // -------------------------------------------------------------------

  /// 自检 + 出画验证。
  ///
  /// 默认**不显示**。播放窗口的主职是出画，一堆日志和按钮摆在画面下面既占
  /// 地方，也容易让人以为播放器坏了（实测反馈正是如此）。但排查能力不能丢 ——
  /// 独立窗口出问题时最难的是「哪一环坏了」，所以留一个入口进得来。
  Widget _buildDiagnosticsPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _showDiagnostics = false),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('返回播放（Esc）'),
            ),
            const Spacer(),
            if (_currentRequest != null)
              Text(
                '同组条目 ${_currentRequest!.playlist.length} · '
                '可选档位 ${_currentRequest!.qualities.length}',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _buildHeader(),
        const SizedBox(height: 16),
        _buildChecks(),
        const SizedBox(height: 18),
        _buildControls(),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          '播放器窗口',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.panel3,
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Text(
            '独立窗口',
            style: TextStyle(fontSize: 10.5, color: AppTheme.muted),
          ),
        ),
        const Spacer(),
        if (_nowPlaying != null)
          Flexible(
            child: Text(
              _nowPlaying!,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ),
      ],
    );
  }

  Widget _buildChecks() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '环境自检',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _busy ? null : _runSelfCheck,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('重新自检'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_checks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '正在自检…',
              style: TextStyle(fontSize: 12, color: AppTheme.dim),
            ),
          )
        else
          for (final check in _checks) _SelfCheckRow(check: check),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '出画验证',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              // 走 _playRaw：这条流没有库记录，不能把上一个片子的进度
              // 报成它的。
              onPressed: _busy
                  ? null
                  : () => _playRaw(kSelfTestAssetUri, '内置自检视频'),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('播放内置自检视频'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _stop,
              icon: const Icon(Icons.stop_rounded, size: 16),
              label: const Text('停止'),
            ),
            // 手动刷新直链。
            //
            // 自动刷新只在 mpv 报错时触发，而 mpv 对 HTTP 403 的措辞并不稳定
            // —— 漏判时用户需要一条自己能把片子救回来的路，否则只能关窗重开、
            // 再手动找进度。没有库记录时（自检视频 / 手输直链）刷新无从下手，
            // 所以那时按钮是灰的。
            OutlinedButton.icon(
              onPressed: _busy || _currentRequest == null
                  ? null
                  : () => _refreshTicket(reason: '用户手动触发', manual: true),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重新取链并续播'),
            ),
            // 窗口形态，与播放控制分开放。
            OutlinedButton.icon(
              onPressed: () => _setFullScreen(true),
              icon: const Icon(Icons.fullscreen_rounded, size: 17),
              label: const Text('全屏（F）'),
            ),
            OutlinedButton.icon(
              onPressed: () => _setAlwaysOnTop(!_alwaysOnTop),
              icon: Icon(
                _alwaysOnTop
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                size: 16,
              ),
              label: Text(_alwaysOnTop ? '已置顶' : '窗口置顶'),
            ),
            // 与「停止」分开：这个先**释放**再关窗，是关窗后还在出声时
            // 确定能停下来的那条路（不依赖关窗通知的时序）。
            TextButton.icon(
              onPressed: _busy ? null : _stopAndClose,
              icon: const Icon(Icons.close_rounded, size: 15),
              label: const Text('停止并关闭'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 直链入口：用来验证**真实片源**。内置自检视频只能证明渲染管线通，
        // 证明不了真实片源能播。
        //
        // ⚠️ 夸克直链走这里**播不了** —— 它需要 Cookie 请求头，而输入框只收
        // 一个地址。要验证夸克片源请从主窗口点播放，走的是带请求头的那条路。
        TextField(
          controller: _urlController,
          style: const TextStyle(fontSize: 12, color: AppTheme.text),
          decoration: InputDecoration(
            isDense: true,
            hintText: '粘贴一个**不需要请求头**的可播地址（本地文件 / 公开 http）',
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.dim),
            filled: true,
            fillColor: AppTheme.panel,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
            ),
          ),
          onSubmitted: (value) {
            final uri = value.trim();
            if (uri.isNotEmpty) _playRaw(uri, uri);
          },
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () {
                  final uri = _urlController.text.trim();
                  if (uri.isEmpty) return;
                  _playRaw(uri, uri);
                },
          icon: const Icon(Icons.link_rounded, size: 15),
          label: const Text('播放该地址'),
        ),
      ],
    );
  }
}

@immutable
class _SelfCheck {
  const _SelfCheck(this.title, this.detail, {required this.ok});

  final String title;
  final String detail;
  final bool ok;
}

class _SelfCheckRow extends StatelessWidget {
  const _SelfCheckRow({required this.check});

  final _SelfCheck check;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              check.ok
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              size: 14,
              color: check.ok ? AppTheme.ok : AppTheme.danger,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(
              check.title,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ),
          Expanded(
            child: TvSelectableText(
              check.detail,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'monospace'],
                fontSize: 11.5,
                height: 1.45,
                color: check.ok ? AppTheme.muted : AppTheme.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 剧集列表里的一行。
///
/// ## 为什么它是顶层类，而不是 `_PlayerWindowAppState` 的一个方法
///
/// 这一行里有三条**改错不报错**的规则，必须能单独渲染来测：
///
///   1. 主标题是**文件名**（`PlaylistEntry.rowTitle`），不是集号 ——
///      用户扫这个列表是为了找「网盘上那个文件」；
///   2. 「正在播放」动效**只画在当前那一行**（画满全表 = 没有任何信息）；
///   3. 副标题里集号排在最前，被省略号吃掉的只能是后面的码率 / 体积。
///
/// 三条错了都不会抛异常，只会看起来「本来就是这么设计的」。而窗口整体在
/// `flutter test` 里根本建不出来（`Player()` 找不到 libmpv），所以只能把它
/// 单独拿出来渲染 —— 与 `buildAudioMenuForTest` 同一个理由。
@visibleForTesting
class EpisodeTile extends StatelessWidget {
  const EpisodeTile({
    super.key,
    required this.entry,
    required this.current,
    required this.progress,
    this.onTap,
  });

  final PlaylistEntry entry;

  /// 是不是**正在播**的那一集。决定背景、左侧竖线、字重与动效。
  final bool current;

  /// 看过多少（0..1）。见 [episodeProgressOf]。
  final double progress;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: current ? AppTheme.accent.withValues(alpha: 0.16) : null,
          border: Border(
            // 左侧那条竖线是「我在这一集」最显眼的标记 —— 背景色在缩略图上
            // 往往看不出来（图本身可能就很亮）。
            left: BorderSide(
              color: current ? AppTheme.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            _buildThumbnail(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // **文件名优先**（见 `PlaylistEntry.rowTitle`）。面板上最大的
                    // 那行字给文件名：用户扫这个列表是为了找「网盘上那个文件」，
                    // 而集号在下面一行同样看得到 —— 夸克的播放列表也是这么排的。
                    entry.rowTitle,
                    // ⚠️ **两行**，不是一行。文件名动辄六七十个字符
                    //（`The.Glory.S01E01.2160p.NF.WEB-DL.SDR.HEVC.DDP5.1.Atmos-老K.mkv`），
                    // 而这一行只有约 190px（面板 320 − 缩略图 96 − 间距与内边距）
                    // ≈ 中文 15 个字。放开一行等于只剩开头那几个字符，
                    // 而 `S01E01` 恰好就在开头之后不远 —— 挤掉的是分辨能力本身。
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      // 当前这一集加粗。非当前的用 w500 而不是 w400：这一行现在
                      // 是**文件名**，等宽度参差、整体偏细，w400 在 12.5px 下
                      // 糊成一团灰线。
                      fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                      color: current ? Colors.white : Colors.white70,
                      height: 1.25,
                    ),
                  ),
                  if (entry.rowSubtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      // 集号排在最前（见 `PlaylistEntry.rowSubtitle`）——
                      // 这一行只有一行，省略号吃掉末尾的码率无所谓，
                      // 吃掉集号就等于这一行认不出是哪一集了。
                      entry.rowSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                  if (entry.hasProgress) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppTheme.accent,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 「正在播放」动效。只画在当前这一集上 —— 静态标记（左侧竖线、
            // 背景色、加粗）已经有三处了，**动**才是那个缺掉的信号。
            //
            // 放在行尾而不是压在缩略图上：缩略图现在是**这一集自己的画面**
            // （见 [PlaylistEntry.thumbnailUrl]），盖住它等于把用户用来分辨
            // 「这是哪一集」的那点信息弄脏。
            if (current) ...[
              const SizedBox(width: 8),
              const NowPlayingBars(size: 14),
            ],
          ],
        ),
      ),
    );
  }

  /// 缩略图那一格。
  ///
  /// 只负责**摆位置**（96×54、圆角），内容交给 [_EpisodeThumbnail] ——
  /// 那一格要异步去主窗口取图，而 [EpisodeTile] 本身保持无状态是刻意的：
  /// 它被 `ListView.builder` 按索引重建，状态挂在它身上会跟着**位置**走
  /// （换一部剧时第 3 行的 State 留给新的第 3 集，显示上一部剧的图）。
  Widget _buildThumbnail() =>
      _EpisodeThumbnail(entry: entry, current: current);
}

/// 剧集行里那一格缩略图（96×54）。
///
/// ## 为什么是异步的
///
/// 夸克缩略图**缺 Cookie 一律 401**，而播放窗口在另一个引擎里、拿不到凭证
/// 也没有主窗口那套 HTTP 配置。所以这里只能把地址报给主窗口，由它下载
/// （并落进海报缓存）之后回一个**本地路径**，再用 `Image.file` 显示 ——
/// 见 `PlayerBridgeMethod.fetchThumbnail`。
///
/// ## 三级降级，每一级都有明确的视觉结果
///
///   1. 解析中 → 占位图（**不是**留白，否则列表会「先空一下再长出来」）；
///   2. 拿到路径 → `Image.file`；
///   3. 没有地址 / 取不到 → 占位图。
///
/// ⚠️ 取不到**不重试**：一屏七八行同时要图，逐行重试只会把夸克的 QPS 额度
/// 烧在一件用户根本不会注意到的事情上（占位图本来就是这个列表的既有形态）。
class _EpisodeThumbnail extends StatefulWidget {
  const _EpisodeThumbnail({required this.entry, required this.current});

  final PlaylistEntry entry;

  /// 是不是正在播的那一集。只影响占位图的底色。
  final bool current;

  /// 这一格的宽度。`_episodeTileHeight` 的注释里按它算过行高（54 + 16），
  /// 改这里要一起核。
  static const double width = 96;

  /// 这一格的高度。
  static const double height = 54;

  @override
  State<_EpisodeThumbnail> createState() => _EpisodeThumbnailState();
}

class _EpisodeThumbnailState extends State<_EpisodeThumbnail> {
  /// 主窗口回过来的**本地文件路径**。null = 还没有 / 取不到（都显示占位图）。
  String? _path;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(_EpisodeThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集 / 换剧时地址会变。不重解析的话那一行会一直显示上一集（或上一部
    // 剧）的图 —— 而这恰好把「用缩略图区分集数」变成了**误导**。
    if (oldWidget.entry.thumbnailUrl != widget.entry.thumbnailUrl ||
        oldWidget.entry.itemId != widget.entry.itemId) {
      setState(() => _path = null);
      unawaited(_resolve());
    }
  }

  Future<void> _resolve() async {
    final url = widget.entry.thumbnailUrl;
    if (url == null || url.isEmpty) return;
    final path = await fetchEpisodeThumbnail(widget.entry.itemId, url);
    // 解析期间这一行可能已经被滚出屏幕（列表在回收），那时不能 setState。
    if (!mounted) return;
    setState(() => _path = path);
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: _EpisodeThumbnail.width,
        height: _EpisodeThumbnail.height,
        child: path == null
            ? _buildPlaceholder()
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                // ⚠️ **必须限解码尺寸**：夸克给的是 640×360（约 12 KB），
                // 而这一格只有 96×54。全尺寸解码一张约 0.9 MB，一屏七八行、
                // 一部剧几十集 —— Flutter 的图片缓存默认上限 100 MB，一滚就
                // 被挤爆，表现是「滚动时缩略图反复重新解码」。
                // 按 2 倍图算（视网膜屏上正好清晰，再大也看不出来）。
                cacheWidth: (_EpisodeThumbnail.width * 2).round(),
                // 文件可能被「清理海报缓存」删掉、也可能本身就是坏图。
                // 不兜的话整行会变成一块红色报错块。
                errorBuilder: (_, _, _) => _buildPlaceholder(),
              ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: widget.current
              ? <Color>[AppTheme.accent.withValues(alpha: 0.5), Colors.black54]
              : const <Color>[Colors.white24, Colors.black54],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 18, color: Colors.white70),
      ),
    );
  }
}

/// 向主窗口要一张缩略图的**本地路径**。
///
/// 播放窗口自己下不了这张图：夸克缩略图缺 Cookie 一律 401，而凭证、HTTP
/// 配置与海报缓存都在主窗口那边（见 `PlayerBridgeMethod.fetchThumbnail`）。
///
/// 取不到一律返回 `null`（通道不通、主窗口没装回调、图真的下不来）——
/// 调用方退回占位图即可。**刻意不区分失败原因**：对用户来说它们的视觉结果
/// 完全一样，而面板一屏七八行，任何一条提示都会变成刷屏。
Future<String?> fetchEpisodeThumbnail(String itemId, String url) async {
  if (url.isEmpty) return null;
  try {
    return await playerWindowChannel.invokeMethod<String>(
      PlayerBridgeMethod.fetchThumbnail,
      <String, Object?>{'itemId': itemId, 'url': url},
    );
  } catch (e) {
    diag.debug('播放窗口', '取缩略图失败（该行退回占位图）：$e');
    return null;
  }
}

/// 这一集看过多少（0..1）。
///
/// ## 分子用 `maxPosition`，不是 `resumePosition`
///
/// 续播点看完会被清成 0，用它当分子的话「刚看完的一集」会画成 0% —— 而它是
/// 唯一该显示满格的那一行。历史最大位置只增不减、永不清除。
/// （与详情页文件列表底下那条进度条同一口径，见 `PlaylistEntry.maxPosition`。）
///
/// 时长未知时返回 0 —— 画一条满格或半格的**假**进度比不画更误导。
/// 抽成顶层纯函数是为了能直接单测「时长未知不画假进度」这条。
double episodeProgressOf(PlaylistEntry entry) {
  final total = entry.duration.inMilliseconds;
  if (total <= 0) return 0;
  return (entry.maxPosition.inMilliseconds / total).clamp(0.0, 1.0);
}

/// 清晰度选择菜单。
///
/// 只是**选择**：它不自己换流，而是把选中的档位 `pop` 回去，由
/// [_PlayerWindowAppState._switchQuality] 走跨引擎通道让主窗口重新取链。
/// 理由见 [QualityBrief] 的类文档 —— 播放窗口没有取链能力。
///
/// 摆位与动画都在 [showAnchoredMenu] 里（贴着画质按钮正上方划出来）；
/// 这里只管「长什么样」。
class _QualityMenuPanel extends StatelessWidget {
  const _QualityMenuPanel({
    required this.qualities,
    required this.activeId,
  });

  final List<QualityBrief> qualities;

  /// 当前正在播的那一档。打勾 / 高亮用。
  final String? activeId;

  @override
  Widget build(BuildContext context) {
    return AnchoredMenuPanel(
      title: '清晰度',
      maxWidth: 300,
      children: [
        for (final q in qualities)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            selected: q.id == activeId,
            selectedTileColor: AppTheme.accent.withValues(alpha: 0.14),
            title: Text(q.label, style: const TextStyle(fontSize: 13)),
            subtitle: q.detail == null
                ? null
                : Text(
                    q.detail!,
                    style: const TextStyle(fontSize: 11),
                  ),
            // 打勾而不是只靠高亮：深色底上的高亮在小屏/低对比度下
            // 未必看得出来，而「现在是多少」是用户点开这个菜单的唯一原因。
            trailing: q.id == activeId
                ? const Icon(Icons.check_rounded, size: 18)
                : null,
            onTap: () => Navigator.of(context).pop(q),
          ),
      ],
    );
  }
}

/// 「音效」菜单面板。
///
/// 只是**选择**：选中的预设 `pop` 回去，由
/// [_PlayerWindowAppState._showAudioEffectMenu] 应用并报回主窗口。
///
/// 摆位与动画在 [showAnchoredMenu] 里；这里只管「长什么样」。
/// 选项与文案全部来自 `PlayerAudioEffect`（**两个播放器共用那一份**）——
/// 在这里另写一套名字的话，同一个预设在内置播放页叫「环绕上混」、
/// 在独立窗口叫「环绕声」，用户会以为是两个不同的功能。
class _AudioEffectMenuPanel extends StatelessWidget {
  const _AudioEffectMenuPanel({required this.active});

  final AudioEffectPreset active;

  @override
  Widget build(BuildContext context) {
    return AnchoredMenuPanel(
      title: '音效',
      maxWidth: 300,
      children: [
        // ⚠️ 用 `selectable` 而不是 `all`：macOS 上「直通」会把整部片卡死，
        // 列出来只会变成一条「点了没反应」的反馈。理由见
        // `PlayerAudioEffect.passthroughAvailable`。
        for (final p in PlayerAudioEffect.selectable)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            selected: p == active,
            selectedTileColor: AppTheme.accent.withValues(alpha: 0.14),
            title: Text(
              PlayerAudioEffect.label(p),
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              PlayerAudioEffect.detail(p),
              style: const TextStyle(fontSize: 11),
            ),
            trailing: p == active
                ? const Icon(Icons.check_rounded, size: 18)
                : null,
            onTap: () => Navigator.of(context).pop(p),
          ),
        // 说明为什么没有 EQ 那一套。**不是装饰**：用户是从夸克过来的，
        // 找不到「人声增强 / 虚拟环绕」时必须有一句话告诉他为什么，
        // 否则那会变成一条「功能缺失」的反馈。
        const Divider(height: 1, thickness: 1, color: Colors.white12),
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 9, 14, 11),
          child: Text(
            '人声增强 / 低音增强 / 虚拟环绕需要音频滤镜，当前内置播放引擎未提供。',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white38,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}

/// 片头菜单里的动作。与内置播放页的 [_IntroAction] 同一套语义，但**不共享类型**：
/// 两个播放器是不同文件、不同引擎，共用类型反而会逼出一个谁都不该依赖的
/// 跨文件符号。
enum _IntroAction {
  /// 把当前位置记为片头起点。
  setStart,

  /// 把当前位置记为片头终点。
  setEnd,

  /// 跳到片头起点（区间已成立时）。
  jump,

  /// 清除手标的片头区间（文件章节不受影响）。
  clear,
}

/// 片头标记菜单的面板。
class _IntroMenuPanel extends StatelessWidget {
  const _IntroMenuPanel({
    required this.hasMarker,
    required this.hasManual,
    required this.positionLabel,
  });

  /// 当前是否已有生效的片头区间（章节或手标任一成立）。
  final bool hasMarker;

  /// 是否已有**手标**区间（决定「清除」这一项显不显示）。
  final bool hasManual;

  /// 当前播放位置，给「标记起点 / 终点」做提示用。
  final String positionLabel;

  @override
  Widget build(BuildContext context) {
    return AnchoredMenuPanel(
      title: '片头标记',
      maxWidth: 260,
      children: [
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.flag_rounded, size: 18),
          title: const Text('标记片头起点', style: TextStyle(fontSize: 13)),
          subtitle: Text('当前 $positionLabel', style: const TextStyle(fontSize: 11)),
          onTap: () => Navigator.of(context).pop(_IntroAction.setStart),
        ),
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.flag_outlined, size: 18),
          title: const Text('标记片头终点', style: TextStyle(fontSize: 13)),
          subtitle: Text('当前 $positionLabel', style: const TextStyle(fontSize: 11)),
          onTap: () => Navigator.of(context).pop(_IntroAction.setEnd),
        ),
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          enabled: hasMarker,
          leading: const Icon(Icons.fast_forward_rounded, size: 18),
          title: const Text('跳到片头', style: TextStyle(fontSize: 13)),
          onTap: hasMarker
              ? () => Navigator.of(context).pop(_IntroAction.jump)
              : null,
        ),
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          enabled: hasManual,
          leading: const Icon(Icons.delete_outline_rounded, size: 18),
          title: const Text('清除片头标记', style: TextStyle(fontSize: 13)),
          onTap: hasManual
              ? () => Navigator.of(context).pop(_IntroAction.clear)
              : null,
        ),
      ],
    );
  }
}

/// 字幕菜单里一个选择的**来源**。
///
/// 几种字幕在用户眼里是同一个列表里的选项，「从哪来」只决定**加载方式**：
/// 内嵌轨是切轨，其余三种都是「取回正文再塞给 mpv」（只是取的路径不同）。
/// 用一个枚举而不是几个可空字段，是为了让「加载」那一步能穷举 ——
/// 漏一种的表现是「点了没反应」。
enum _SubtitleKind {
  off,
  embedded,
  cloud,
  online,
  local,

  /// 不是一条字幕，而是「去搜一下」这个动作。菜单里的一个入口。
  searchOnline,

  /// 不是一条字幕，而是「去挑一个文件」这个动作。
  pickLocal,
}

class _SubtitleChoice {
  const _SubtitleChoice._(
    this.kind, {
    this.trackId,
    this.fileId,
    this.onlineId,
    this.localPath,
    this.localLabel,
  });

  const _SubtitleChoice.off() : this._(_SubtitleKind.off);

  const _SubtitleChoice.embedded(int id)
      : this._(_SubtitleKind.embedded, trackId: id);

  const _SubtitleChoice.cloud(String id)
      : this._(_SubtitleKind.cloud, fileId: id);

  const _SubtitleChoice.online(int id)
      : this._(_SubtitleKind.online, onlineId: id);

  const _SubtitleChoice.local(String path, String label)
      : this._(_SubtitleKind.local, localPath: path, localLabel: label);

  const _SubtitleChoice.searchOnline() : this._(_SubtitleKind.searchOnline);

  const _SubtitleChoice.pickLocal() : this._(_SubtitleKind.pickLocal);

  final _SubtitleKind kind;

  /// mpv 的 `sid`。内嵌轨才有。
  final int? trackId;

  /// 网盘字幕的 fileId。
  final String? fileId;

  /// 在线字幕在这家站点上的 `file_id`。
  final int? onlineId;

  /// 本地字幕文件的**绝对路径**。
  ///
  /// 记路径而不是记正文：正文在应用时重新读一遍，「文件被外部改过」也能生效，
  /// 而且不用把一份可能几百 KB 的文本挂在 State 上。
  final String? localPath;

  /// 本地字幕的展示名（文件名）。
  final String? localLabel;
}

/// 用户挑中的那个本地字幕文件（只记路径与展示名，不记正文）。
@immutable
class _LocalSubtitle {
  const _LocalSubtitle(this.path, this.label);

  final String path;
  final String label;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _LocalSubtitle && other.path == path && other.label == label);

  @override
  int get hashCode => Object.hash(path, label);
}

/// 仅测试用：把两个菜单构件直接暴露出来。
///
/// ## 为什么非得开这个口子
///
/// 这两个菜单在测试环境里**点不开**：控制栏上那两个入口都写着
/// `_player == null ? null : …`（见 `_buildButtonRow`），而 `Player()` 在
/// `flutter test` 里根本建不出来 —— 它抛
/// `Cannot find Mpv.framework … in the Frameworks folder`，因为 `flutter test`
/// 跑在宿主 Dart VM 上，libmpv 不在 rpath 里。于是按钮永远是禁用的，
/// 弹菜单那条路径**在测试里不可达**。
///
/// 但菜单里有两条**改错不报错**的规则，恰恰最需要钉住：
///
///   1. **有外挂字幕挂着时，内嵌轨一律不打勾。** mpv 认不出我们后挂上去的
///      外挂字幕是哪一条，它只把「有字幕轨被选中」报成一个数字；靠那个数字
///      去高亮，会在**错误的那条内嵌轨**上打勾。
///   2. **「关闭字幕」永远第一项。** mpv 没有「上一条」的概念，想关掉字幕时
///      必须有一条明确的退路。
///
/// 这两条坏了都不会抛异常，只会表现成「勾打在错的那一行」或「找不到关不掉字幕
/// 的入口」。所以只能把构件抽出来单独渲染来断言。
@visibleForTesting
Widget buildAudioMenuForTest({
  required List<AudioTrack> tracks,
  String? activeId,
}) =>
    _AudioMenuPanel(tracks: tracks, activeId: activeId);

/// 仅测试用：字幕菜单。理由见 [buildAudioMenuForTest]。
///
/// `localPath` / `localLabel` 必须**同时**给或同时不给 —— 只给一个等于
/// 「挑过文件但不知道叫什么」，那种状态不存在（见 [_LocalSubtitle]）。
@visibleForTesting
Widget buildSubtitleMenuForTest({
  List<SubtitleTrack> tracks = const <SubtitleTrack>[],
  List<SubtitleBrief> cloud = const <SubtitleBrief>[],
  List<OnlineSubtitleBrief> online = const <OnlineSubtitleBrief>[],
  bool searchingOnline = false,
  String? localPath,
  String? localLabel,
  int? activeId,
  String? activeCloudId,
  int? activeOnlineId,
  String? activeLocalPath,
}) =>
    _SubtitleMenuPanel(
      tracks: tracks,
      cloud: cloud,
      online: online,
      searchingOnline: searchingOnline,
      local: (localPath == null || localLabel == null)
          ? null
          : _LocalSubtitle(localPath, localLabel),
      activeId: activeId,
      activeCloudId: activeCloudId,
      activeOnlineId: activeOnlineId,
      activeLocalPath: activeLocalPath,
    );

/// 音轨菜单。
///
/// 副标题是「识别」那一半：语言之外还给出编码、声道、采样率、码率。
/// 这些字段 mpv 只在探到时才填（见 [TrackLabels]），所以副标题可能是空的 ——
/// 空着比写「未知 · 未知」好。
class _AudioMenuPanel extends StatelessWidget {
  const _AudioMenuPanel({required this.tracks, required this.activeId});

  final List<AudioTrack> tracks;

  /// 当前选中的音轨 id。打勾用。
  final String? activeId;

  @override
  Widget build(BuildContext context) {
    return AnchoredMenuPanel(
      title: '音轨',
      maxWidth: 340,
      children: [
        for (final t in tracks)
          ListTile(
            dense: true,
            selected: t.id == activeId,
            selectedTileColor: AppTheme.accent.withValues(alpha: 0.14),
            title: Text(
              TrackLabels.audioTitle(t),
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: _subtitleOf(TrackLabels.audioDetail(t)),
            trailing: t.id == activeId
                ? const Icon(Icons.check_rounded, size: 18)
                : null,
            onTap: () => Navigator.of(context).pop(t),
          ),
      ],
    );
  }
}

/// 字幕菜单。
///
/// ## 顺序就是「离用户最近 → 最远」
///
///   1. **关闭字幕**（永远第一项）—— 字幕是**可以不要**的，而 mpv 没有
///      「上一条」的概念，想关掉的时候必须有一条明确的退路；
///   2. **网盘字幕** —— 同一个网盘、同一目录的文件，最可能对得上时间轴；
///   3. **内嵌字幕** —— 就在这个文件里，但往往只有一两条；
///   4. **在线字幕** —— 要下载、有每日额度，所以排最后。
///
/// ## 打勾的口径
///
/// **有外挂字幕（网盘 / 在线）挂着时，内嵌轨一律不打勾**。mpv 认不出我们后挂
/// 上去的外挂字幕是哪一条，它只会把「有字幕轨被选中」报成一个数字 —— 靠那个
/// 数字去高亮，会在错误的内嵌轨上打勾。
class _SubtitleMenuPanel extends StatelessWidget {
  const _SubtitleMenuPanel({
    required this.tracks,
    required this.cloud,
    required this.online,
    required this.searchingOnline,
    required this.local,
    required this.activeId,
    required this.activeCloudId,
    required this.activeOnlineId,
    required this.activeLocalPath,
  });

  final List<SubtitleTrack> tracks;

  /// 网盘上同目录的字幕文件。
  final List<SubtitleBrief> cloud;

  /// 上一次在线搜索的结果。空 = 还没搜过，或搜了没有。
  final List<OnlineSubtitleBrief> online;

  /// 正在搜在线字幕。那条入口要显示成「搜索中…」并且点不动。
  final bool searchingOnline;

  /// 用户挑过的那个本地字幕文件。`null` = 还没挑过。
  final _LocalSubtitle? local;

  /// 当前选中的内嵌轨号。`null` = 没有内嵌轨处于选中态。
  final int? activeId;

  /// 当前选中的网盘字幕。
  final String? activeCloudId;

  /// 当前选中的在线字幕。
  final int? activeOnlineId;

  /// 当前挂着的本地字幕的路径。
  final String? activeLocalPath;

  /// 没有任何字幕处于选中态 —— 此时「关闭字幕」打勾。
  bool get _nothingActive =>
      activeId == null &&
      activeCloudId == null &&
      activeOnlineId == null &&
      activeLocalPath == null;

  /// 有一条**外挂**字幕挂着。见类文档里的打勾口径。
  bool get _externalActive =>
      activeCloudId != null ||
      activeOnlineId != null ||
      activeLocalPath != null;

  @override
  Widget build(BuildContext context) {
    return AnchoredMenuPanel(
      title: '字幕',
      maxWidth: 380,
      children: [
        _SubtitleTile(
          title: '关闭字幕',
          selected: _nothingActive,
          onTap: () => Navigator.of(context).pop(const _SubtitleChoice.off()),
        ),
        if (cloud.isNotEmpty) ...[
          const _SectionLabel('网盘字幕'),
          for (final s in cloud)
            _SubtitleTile(
              title: s.label,
              detail: s.fileName,
              selected: s.fileId == activeCloudId,
              onTap: () => Navigator.of(context).pop(
                _SubtitleChoice.cloud(s.fileId),
              ),
            ),
        ],
        if (tracks.isNotEmpty) ...[
          const _SectionLabel('内嵌字幕'),
          for (final t in tracks)
            _SubtitleTile(
              title: TrackLabels.subtitleTitle(t),
              detail: TrackLabels.subtitleDetail(t),
              selected: !_externalActive && t.id == '$activeId',
              onTap: () => Navigator.of(context).pop(
                _SubtitleChoice.embedded(int.parse(t.id)),
              ),
            ),
        ],
        if (online.isNotEmpty) ...[
          const _SectionLabel('在线字幕'),
          for (final s in online)
            _SubtitleTile(
              title: s.title ?? s.fileName,
              detail: _onlineDetail(s),
              selected: s.fileId == activeOnlineId,
              onTap: () => Navigator.of(context).pop(
                _SubtitleChoice.online(s.fileId),
              ),
            ),
        ],
        if (local case final picked?) ...[
          const _SectionLabel('本地文件'),
          _SubtitleTile(
            title: picked.label,
            detail: picked.path,
            selected: picked.path == activeLocalPath,
            onTap: () => Navigator.of(context).pop(
              _SubtitleChoice.local(picked.path, picked.label),
            ),
          ),
        ],
        // 「去搜一下」和「去挑个文件」都是**动作**，不是字幕 ——
        // 所以它们单独一组、放在最后：它们是"出口"，不是"选项"。
        //
        // 搜过/挑过之后这两条仍然留着：字幕站上可能有新的，用户也可能想
        // 换一个文件再试。文案跟着变，让他知道点了会发生什么。
        const _SectionLabel('从别处加载'),
        _SubtitleTile(
          title: searchingOnline
              ? '搜索中…'
              : (online.isEmpty ? '搜索在线字幕…' : '重新搜索在线字幕…'),
          leading: Icons.search_rounded,
          // 搜索中时不给点：这是个会打接口、要烧额度的动作。
          onTap: searchingOnline
              ? null
              : () => Navigator.of(context).pop(
                    const _SubtitleChoice.searchOnline(),
                  ),
        ),
        _SubtitleTile(
          title: local == null ? '选择本地字幕文件…' : '换一个本地字幕文件…',
          leading: Icons.folder_open_rounded,
          onTap: () => Navigator.of(context).pop(
            const _SubtitleChoice.pickLocal(),
          ),
        ),
        // 一条都没有时给一句人话。什么都不显示的话，用户只会以为
        // 「这个功能还没做完」。
        if (cloud.isEmpty && tracks.isEmpty && online.isEmpty && local == null)
          const ListTile(
            dense: true,
            enabled: false,
            title: Text(
              '这个片源没有内嵌字幕，网盘同目录也没扫到字幕文件 —— '
              '可以从下面去网上搜，或者自己挑一个本地文件',
              style: TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ),
      ],
    );
  }

  /// 在线候选的副标题：`简体中文 · Movie.chs.srt · 1284 次下载`。
  static String _onlineDetail(OnlineSubtitleBrief s) {
    final lang = TrackLabels.languageLabel(s.language);
    final parts = <String>[
      if (lang != null) lang,
      if (s.fileName.isNotEmpty) s.fileName,
      if (s.downloadCount > 0) '${s.downloadCount} 次下载',
    ];
    return parts.join(' · ');
  }
}

/// 字幕菜单里的一行。
///
/// 抽出来是因为这个菜单有四种来源、行数不定，`ListTile` 的那一长串参数
/// 复制四遍之后，任何一处改动（比如加个 leading）都要改四个地方。
class _SubtitleTile extends StatelessWidget {
  const _SubtitleTile({
    required this.title,
    this.detail,
    this.leading,
    this.selected = false,
    this.onTap,
  });

  final String title;
  final String? detail;
  final IconData? leading;
  final bool selected;

  /// `null` = 不可点（搜索进行中）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      enabled: onTap != null,
      selected: selected,
      selectedTileColor: AppTheme.accent.withValues(alpha: 0.14),
      leading: leading == null
          ? null
          : Icon(leading, size: 18, color: Colors.white70),
      title: Text(title, style: const TextStyle(fontSize: 13)),
      subtitle: _subtitleOf(detail ?? ''),
      // 打勾而不是只靠高亮：深色底上的高亮在小屏/低对比度下未必看得出来，
      // 而「现在挂的是哪一条」是用户点开这个菜单的唯一原因。
      trailing: selected ? const Icon(Icons.check_rounded, size: 18) : null,
      onTap: onTap,
    );
  }
}

/// 菜单里的分组小标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
    );
  }
}

/// 副标题。空串不建这个 widget —— `subtitle: Text('')` 也会占一行高度，
/// 让每一项看起来都像是「有两行但第二行是空的」。
Widget? _subtitleOf(String text) => text.isEmpty
    ? null
    : Text(text, style: const TextStyle(fontSize: 11));

