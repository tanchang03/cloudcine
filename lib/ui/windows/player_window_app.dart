import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/format.dart';
import '../../core/utils/playback_seek.dart';
import '../../core/utils/player_buffer_config.dart';
import '../../core/utils/player_buffer_progress.dart';
import '../../core/utils/text_encoding.dart';
import '../../core/utils/track_labels.dart';
import '../../domain/services/cache_speed_meter.dart';
import '../../domain/services/playback_media.dart';
import '../../domain/services/playback_resume.dart';
import '../theme/app_theme.dart';
import '../widgets/buffered_slider.dart';
import 'child_window_channel.dart';
import 'player_protocol.dart';
import 'player_window_bridge.dart';
import 'window_launch.dart';

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

  Player? _player;
  VideoController? _controller;

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
  static const double _episodeTileHeight = 84;

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

  /// 是否正在等第一帧 —— 也就是「画面还是黑的」那段时间。
  ///
  /// 光靠 [_busy] 盖不住它：`Player.open()` **不等文件加载完成**（见
  /// [_openStream]），它返回时画面往往还一片黑。这正是「刚打开视频缓冲过程中
  /// 黑屏」的那一段，也是加载指示最该出现的地方。
  ///
  /// 清掉它的信号见 [_ensurePlayer] 里那几条订阅 —— 取「先到的那个」，因为
  /// 没有哪个信号能保证一定来（比如某些流不会触发 video reconfig）。
  bool _awaitingFrame = false;

  /// 已经缓存到播放头**前面**多少秒（mpv 的 `demuxer-cache-time`）。
  ///
  /// 注意它不是「从头一共下下来多少」：mpv 的缓存是有上限的，填满之后这个数
  /// 就停在那儿不动了。所以显示的时候要写「已缓存多少秒（可看多少）」，
  /// 而不是拿它去除以总时长当百分比 —— 后者在一部长片上是 0.4%，
  /// 看着像坏了（实测：默认缓存上限下，45 分钟片子的稳定值约 10 秒）。
  Duration _cacheAhead = Duration.zero;

  /// 缓存速度：**每秒能缓存多少秒视频**。null = 还没算出来。
  ///
  /// 单位看着别扭但很关键 —— `1.0×` 正好是「下载与播放持平」的分界线，
  /// 低于它就迟早再卡一次。KB/s 是 [_cacheBytesPerSecond] 的事。
  double? _cacheRate;

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

  /// mpv 的流订阅。释放时要显式取消。
  final List<StreamSubscription<Object?>> _subs = [];

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
    _playlistController.dispose();
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

  /// 停止播放并释放 mpv。**幂等**。
  ///
  /// 三条路都会走到这里，而且它们会互相重叠（关窗通知 + dispose 常常
  /// 前后脚发生），所以必须幂等 —— 重复 `dispose()` 一个已释放的 [Player]
  /// 会抛。
  ///
  /// **不调用 `setState`**：它可能从 `dispose()` 里被调到。
  Future<void> _releasePlayer() async {
    final player = _player;
    if (player == null) return;
    _player = null;
    _controller = null;
    _currentRequest = null;
    _refreshing = false;
    _refreshGuard.reset();

    // 先取消订阅：否则 dispose 过程中还可能触发一次进度回报，
    // 而那会在通道上打一条指向已释放播放器的消息。
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();

    try {
      // 先 stop 再 dispose：stop 会释放解码器与网络连接，
      // 让 dispose 之后的清理更快、更干净。
      await player.stop();
    } catch (_) {
      // 引擎可能已经在拆了。停不下来不影响下一步的 dispose。
    }
    try {
      await player.dispose();
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

  /// 惰性建播放器。
  ///
  /// 两条硬约束（都是踩过的坑）：
  ///   1. `VideoController` 必须绑定到**正在播放的那个** [Player]，不能另建一个；
  ///   2. 必须在任何 `open()` 之前建出来。
  /// 违反任一条的表现都是「有声音、进度条在走，但画面全黑，且不报错」。
  void _ensurePlayer() {
    if (_player != null) return;
    // ⚠️ 必须把日志级别抬到 `warn`。这不是「顺手多要点日志」，而是过期检测的
    // **必要条件** —— 完整实测记录见 [isHttp4xxLog] 的文档。
    //
    // 一句话：`mpv_request_log_messages` 的语义是「该级别**及以上严重**的消息
    // 才发」，而实测 `HTTP error 403` 是 **warn** 级（比 error 轻）。media_kit
    // 默认是 `MPVLogLevel.error`，那条消息**根本不会被发送到 Dart**。
    //
    // 抬到 warn 只影响 `stream.log` 的流量（warn 级本来就很少），
    // `stream.error` 完全不受影响：media_kit 仍然只挑 `level == 'error'` 的。
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.warn,
        bufferSize: PlayerBufferConfig.bufferSize,
      ),
    );
    // 先记下来：万一下一行抛异常，dispose 也还能回收这个原生实例。
    _player = player;
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    // 补 media_kit 构造参数管不到的 mpv 缓冲属性（demuxer-readahead-secs）。
    unawaited(PlayerBufferConfig.apply(player));

    // 进度回报。挂在 `position` 上而不是用计时器：位置流本身就是「播到哪了」
    // 的唯一真相，用计时器反而要在暂停时额外判断。
    _subs.add(
      player.stream.position.listen((position) {
        unawaited(_onPosition(position));
      }),
    );

    // 播放错误。mpv 的报错很笼统（`Failed to open ...`），但对用户来说
    // 「播不了」这个结论是准确的 —— 具体原因看诊断日志。
    //
    // ⚠️ 这里**不只是记日志**：网盘直链是带签名的临时 URL，过期后的表现正是
    // 一条 mpv 报错（拖进度条会重新发 Range 请求，所以最常见的症状是
    // 「播到一半一拖就报错」）。
    //
    // 但这条路只是过期检测的**一半**：它拿到的是二级症状（`Failed to open`），
    // 一级证据（HTTP 4xx）走下面那条 `stream.log`。两者分工见 [isHttp4xxLog]。
    _subs.add(
      player.stream.error.listen((msg) {
        unawaited(_onPlayerError(msg));
      }),
    );

    // mpv 的日志。这条订阅是过期检测的另一半：
    //
    // `stream.error` 看不到最直接的那条证据（`http: HTTP error 4xx`），
    // 原因是**级别**（实测它是 warn，而 media_kit 默认只请求 error）叠加上
    // media_kit 自己的前缀过滤。详见 [isHttp4xxLog] 顶部的实测记录。
    //
    // 不能改成「把 `stream.error` 的口径放宽」—— 那条消息**根本没进来**，
    // 放宽也够不着。
    //
    // ⚠️ 这条订阅能不能收到东西，取决于 `_ensurePlayer` 里把日志级别抬到了
    // `warn`。两处是**配套**的，改一处必须改另一处。
    _subs.add(
      player.stream.log.listen((entry) {
        if (!isHttp4xxLog(entry.text)) return;
        unawaited(_onTicketExpiryLog(entry));
      }),
    );

    // 播放/暂停状态。控制栏那个按钮要跟着它变 —— 否则会一直显示
    // 「播放」而实际在播放，语义正好反过来。
    _subs.add(
      player.stream.playing.listen((playing) {
        if (!mounted || _playing == playing) return;
        setState(() => _playing = playing);
      }),
    );

    // 缓冲状态。播到一半缓存见底时 mpv 会自己停下来等数据，画面是静止的 ——
    // 不告诉用户「在等」，他只会以为播放器卡死了。
    _subs.add(
      player.stream.buffering.listen((buffering) {
        if (!mounted || _buffering == buffering) return;
        setState(() => _buffering = buffering);
      }),
    );

    // 缓存量。缓冲指示上「已缓存多少秒」和「速度」两个数都来自这里。
    //
    // 速度算不出来时**保留上一次的值**：返回 null 只是「这一拍样本不够」，
    // 清成 0 会让数字一格一格地闪，比一直显示同一个旧值更难看。
    _subs.add(
      player.stream.buffer.listen((ahead) {
        final rate = _cacheMeter.accept(ahead);
        if (!mounted) return;
        setState(() {
          _cacheAhead = ahead;
          if (rate != null) _cacheRate = rate;
        });
      }),
    );

    // 初始填充的百分比。见 [_cacheFill] 那条注释：只在 0~100 之间时可信。
    _subs.add(
      player.stream.bufferingPercentage.listen((percent) {
        if (!mounted) return;
        setState(() => _cacheFill = percent);
      }),
    );

    // 「出画了」的信号。**三个都听，取先到的那个**：
    //
    //   - `videoParams`：mpv 要解出第一帧才能定输出格式，所以它是**最准**的
    //     「有画面了」；
    //   - `duration` / `position`：兜底。不是每种流都会触发 video reconfig
    //     （比如纯音频），只认那一个的话加载指示会永远挂在屏幕上。
    //
    // 代价是最多早收一两秒（duration 通常在解码开始前就已知），但
    // 「永远不收」比「早收」糟得多。
    _subs.add(
      player.stream.videoParams.listen((params) {
        if ((params.w ?? 0) > 0) _clearAwaitingFrame();
      }),
    );
    _subs.add(
      player.stream.duration.listen((d) {
        if (d > Duration.zero) _clearAwaitingFrame();
      }),
    );
    _subs.add(
      player.stream.position.listen((p) {
        if (p > Duration.zero) _clearAwaitingFrame();
      }),
    );

    // 音轨与内嵌字幕轨的清单。
    //
    // 这是「菜单里到底有哪些选项」的唯一来源，而它在容器解析完之前是空的，
    // 所以必须**持续听**，不能在 `open()` 之后读一次 `state.tracks` 了事 ——
    // 那样菜单会永远空着。
    _subs.add(player.stream.tracks.listen(_onTracks));

    // 当前选中的轨。切轨成功与否只能由 mpv 说了算（见 [_activeAudioId]）。
    _subs.add(player.stream.track.listen(_onTrackSelection));
  }

  /// 轨道清单变了。只存真实的那些（合成轨见 [TrackLabels.realTracks]）。
  void _onTracks(Tracks tracks) {
    if (!mounted) return;
    setState(() {
      _audioTracks = TrackLabels.realTracks(tracks.audio, (t) => t.id);
      _embeddedSubtitles = TrackLabels.realTracks(tracks.subtitle, (t) => t.id);
    });
  }

  /// 当前选中的轨变了。
  ///
  /// 字幕那条要判 `int.tryParse`：media_kit 用 `SubtitleTrack.no()`（id 是
  /// 字符串 `'no'`）表示「字幕关着」，它不是轨道号。
  void _onTrackSelection(Track selection) {
    if (!mounted) return;
    setState(() {
      _activeAudioId = selection.audio.id;
      _activeSubtitleId = int.tryParse(selection.subtitle.id);
    });
  }

  /// 第一帧已经出来了 —— 收掉加载指示。
  void _clearAwaitingFrame() {
    if (!mounted || !_awaitingFrame) return;
    setState(() => _awaitingFrame = false);
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
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_chromeVisible) setState(() => _chromeVisible = false);
  }

  /// 播放 / 暂停。单击画面与控制栏那个按钮都走这里。
  ///
  /// 图标立刻按「已切换」更新：真状态仍以 `stream.playing` 为准，但那条流要
  /// 等 mpv 回话，光靠它按钮会慢半拍 —— 用户点了没反应就会再点一次。
  void _togglePlay() {
    final player = _player;
    if (player == null) return;
    setState(() => _playing = !_playing);
    unawaited(player.playOrPause());
  }

  // -------------------------------------------------------------------
  // 进度回报
  // -------------------------------------------------------------------

  /// 位置流入口：先喂刷新闸，再回报进度。
  ///
  /// 两件事挂在同一个流上是有意的 —— 它们共用同一个「播到哪了」的真相：
  /// 刷新闸要判断「重开之后位置有没有真的往前走」，那正是这个值。
  Future<void> _onPosition(Duration position) async {
    // 刷新后能连续播过一段，说明这次刷新是有效的 —— 把自动重试计数清零。
    // 不这么做的话，一部长片里撞上两三次过期就把额度用满了。
    if (_refreshGuard.observe(position, now: DateTime.now())) {
      diag.info('播放窗口', '直链刷新有效，自动刷新计数已清零');
    }
    await _reportProgress(position);
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
          duration: _player?.state.duration ?? Duration.zero,
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

  /// `stream.log` 上发现了 HTTP 4xx —— 直链过期的**一级证据**。
  ///
  /// 与 [_onPlayerError] 的分工见 [isHttp4xxLog]。
  Future<void> _onTicketExpiryLog(PlayerLog entry) async {
    final safe = redactUrls(entry.text);

    if ((_currentRequest?.itemId ?? '').isEmpty) {
      // 没有库记录（内置自检视频 / 手输直链）→ 无从刷新，也不会连刷，
      // 所以这里记一条 warn 就够。
      //
      // **刻意不弹提示**：没有库记录时用户本来也只能自己换一条链，
      // 他会在画面上直接看到播不动。
      diag.warn('播放窗口', '直链疑似过期（${entry.prefix}）：$safe');
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
    diag.debug('播放窗口', '直链疑似过期（${entry.prefix}）：$safe');
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

    // 位置要在重开**之前**取：报错之后 mpv 的 position 可能已经归零，
    // 那样刷新会把用户丢回片头。
    final position = _player?.state.position ?? request.startPosition;

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
      await _openStream(
        fresh.url,
        fresh.describe(),
        headers: fresh.headers,
        startAt: position,
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
    await _reportProgress(
      _player?.state.position ?? Duration.zero,
      force: true,
    );

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
    } catch (e, st) {
      diag.error('播放窗口', '取新直链失败（$reason）', error: e, stackTrace: st);
      _toast('直链刷新失败：$e');
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
      await _openStream(
        fresh.url,
        fresh.describe(),
        headers: fresh.headers,
        startAt: position,
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
      await _adoptRequest(fresh, startAt: start);
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
  Future<void> _adoptRequest(PlayRequest request, {Duration? startAt}) async {
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
    }

    _currentRequest = request;
    _progressThrottle.reset();
    _refreshGuard.reset();

    await _openStream(
      request.url,
      request.describe(),
      headers: request.headers,
      startAt: startAt ?? request.startPosition,
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
  Future<void> _openStream(
    String uri,
    String label, {
    Map<String, String> headers = const <String, String>{},
    Duration startAt = Duration.zero,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      // 从这一刻到「解出第一帧」之间画面是**黑的**，而 `open()` 不等文件加载
      // 完成 —— 这段正是「刚打开视频时黑屏」的那几秒，加载指示要盖住它。
      // 收掉它的信号见 [_clearAwaitingFrame]。
      _awaitingFrame = true;
      // 换片源 = 上一次的缓存量与增速全部作废。不清的话缓冲指示会带着
      // 上一部片子的「已缓存 10 秒」出现，然后突然跳回 0。
      _cacheAhead = Duration.zero;
      _cacheRate = null;
      _cacheFill = null;
      _cacheMeter.reset();
    });
    try {
      _ensurePlayer();
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
      // `startAt` 默认为 `Duration.zero` 而不是 null 也是必须的，理由见
      // [PlaybackMedia]：mpv 的 `start` 属性会**残留**到下一个文件。
      await _player!.open(
        PlaybackMedia.build(uri, headers: headers, startAt: startAt),
        play: true,
      );
      if (!mounted) return;
      setState(() => _nowPlaying = label);
    } catch (e, st) {
      // 开流失败就永远等不到第一帧了 —— 必须自己收掉加载指示，否则它会一直
      // 挂在画面上，把「播放失败」的提示也盖住。
      if (mounted) setState(() => _awaitingFrame = false);
      diag.error('播放窗口', 'open 失败：$label', error: e, stackTrace: st);
      // 必须走 [_toast]：这里直接用 `ScaffoldMessenger.of(context)` 在这个
      // 组件里**一定失败**（理由见 [_messengerKey]）—— 而这条正是
      // 「一播就报错」的路径，用户最需要看到提示的时候反而会再抛一个异常。
      _toast('播放失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  /// 弹框用的 navigator。
  ///
  /// ⚠️ **与 [_messengerKey] 是同一类坑，理由也一样**：`build` 里的 `context`
  /// 是 [PlayerWindowApp] 自己的 element context，而它返回的正是 `MaterialApp`
  /// —— 也就是说这个 context 在 `MaterialApp` **外面**，头上既没有 `Navigator`
  /// 也没有 `MaterialLocalizations`。
  ///
  /// `showDialog(context: context)` 撞上去会直接抛
  /// 「No MaterialLocalizations found」，表现是「点画质，什么都没发生」。
  /// 所以弹框必须拿 `MaterialApp` **内部**的 context，而 `navigatorKey` 就是
  /// 那条稳定的取用路径（实测：画质弹框的用例就是这么红起来的）。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 画质按钮的锚点。画质菜单不再是屏幕居中的 `AlertDialog`，
  /// 而是用 `Overlay` + `CompositedTransformFollower` 挂在按钮正上方，
  /// 所以需要一个 `LayerLink` 把「按钮」与「菜单」连起来。
  final LayerLink _qualityLink = LayerLink();

  /// 弹一条提示。取 messenger 前先判 mounted —— 这个类里的调用点
  /// 多半在 `await` 之后或流回调里，那时窗口可能已经关了。
  void _toast(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _stop() async {
    await _player?.stop();
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
      // 弹框同理，理由见 [_navigatorKey]。
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

  /// 方向键的跳转步长。与内置播放页一致。
  static const Duration _seekStep = Duration(seconds: 10);

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
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _seekBy(-_seekStep),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _seekBy(_seekStep),
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
    if (_player == null) return;
    _togglePlay();
    _pokeChrome();
  }

  /// ← / →：相对跳转。
  ///
  /// 基准取 `player.state.position` 而不是我们自己缓存的某个字段：mpv 的
  /// `position` 流每 ~100ms 才来一条，缓存字段在「刚跳完立刻再按一下」时还是
  /// 上一次的旧值 —— 连按三下只会跳出一段的距离。
  void _seekBy(Duration delta) {
    final player = _player;
    if (player == null) return;
    final target = clampSeekTarget(
      player.state.position + delta,
      player.state.duration,
    );
    unawaited(player.seek(target));
    // 同 [_onPlayPauseKey]：让用户看见时间码跳到了哪儿。
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
                if (_awaitingFrame || _buffering)
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
    final controller = _controller;
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
        child: controller == null
            ? const Center(
                child: Text(
                  '还没有载入片源',
                  style: TextStyle(fontSize: 13, color: AppTheme.dim),
                ),
              )
            : Video(
                controller: controller,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
      ),
    );
  }

  /// 加载 / 缓冲指示。
  ///
  /// 覆盖两段黑屏：
  ///   - [_awaitingFrame]：开流到解出第一帧之间。`Player.open()` **不等文件
  ///     加载完成**，这段画面是全黑的，也是最该给反馈的几秒；
  ///   - [_buffering]：播到一半缓存见底，mpv 停下来等数据。
  ///
  /// 两段的底色**不一样**：等首帧时画面本来就是黑的，用不透明底色把它盖掉；
  /// 中途卡顿则只压一层半透明 —— 那一帧画面还在，全盖掉等于把进度也抹了。
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
                _awaitingFrame ? '正在载入片源…' : '正在缓冲…',
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
  String _cacheStatusLine() {
    final parts = <String>['已缓存 ${_formatDuration(_cacheAhead)}'];

    final bytes = _cacheBytesPerSecond();
    if (bytes != null && bytes >= 1) {
      // 复用 `formatBytes`（已有单测覆盖），只在后面补一个「/秒」。
      parts.add('≈${formatBytes(bytes.round())}/s');
    } else {
      // 没有文件大小（手输直链、自检视频）时换不出字节数，就退回报倍速 ——
      // 它本身也说明问题：`1.0×` 是下载与播放持平的分界线。
      final rate = _cacheRate;
      if (rate != null && rate > 0.05) {
        parts.add('${rate.toStringAsFixed(1)}×');
      }
    }
    return parts.join(' · ');
  }

  /// 把 [CacheSpeedMeter] 的倍速换算成字节/秒；缺任何一环都返回 null。
  ///
  /// 换算靠平均码率：`文件大小 ÷ 时长`，再乘「每秒缓存多少秒视频」。
  /// 这是**估算**（VBR 片源会偏），所以显示时带 `≈`。
  double? _cacheBytesPerSecond() {
    final rate = _cacheRate;
    final size = _currentRequest?.sizeBytes;
    final total = _player?.state.duration ?? Duration.zero;
    if (rate == null || size == null || size <= 0) return null;
    if (total <= Duration.zero) return null;

    final seconds =
        total.inMicroseconds / Duration.microsecondsPerSecond;
    return rate * (size / seconds);
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

    return Row(
      children: [
        IconButton(
          onPressed: _player == null ? null : _togglePlay,
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
        // 上一集 / 下一集只在真有列表时出现。电影上挂两个永远灰着的按钮，
        // 只会把控制栏撑得更长。
        if (hasPlaylist) ...[
          _buildBarIcon(
            icon: Icons.skip_previous_rounded,
            tooltip: '上一集',
            onPressed:
                index > 0 ? () => unawaited(_openEpisode(playlist[index - 1])) : null,
          ),
          _buildBarIcon(
            icon: Icons.skip_next_rounded,
            tooltip: '下一集',
            onPressed: index >= 0 && index < playlist.length - 1
                ? () => unawaited(_openEpisode(playlist[index + 1]))
                : null,
          ),
        ],
        const Spacer(),
        // 画质：**文字按钮**而不是图标。用户要看的是「现在是多少」，
        // 而不是「这里有个设置入口」—— 夸克播放器也是这么做的。
        //
        // 按钮用 `CompositedTransformTarget` 包起来，菜单要锚在它正上方
        // （见 [_qualityLink] 与 [_showQualityMenu]）。
        CompositedTransformTarget(
          link: _qualityLink,
          child: TextButton(
            onPressed: qualities.isEmpty
                ? null
                : () => unawaited(_showQualityMenu()),
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
        // 这两个入口**常驻，不按「有没有轨」决定显不显示**：轨道清单要等 mpv
        // 解析完容器才填出来，起播前一直是空的。按有无来隐藏的话，控制栏会在
        // 开播那一瞬间突然多出两个图标，把右边一排整体挤动一下 —— 看起来像
        // 界面抖了一下。一个灰着的按钮比一个会跳动的布局好。
        _buildBarIcon(
          icon: Icons.subtitles_outlined,
          tooltip: '字幕',
          onPressed:
              _player == null ? null : () => unawaited(_showSubtitleMenu()),
        ),
        _buildBarIcon(
          icon: Icons.audiotrack_rounded,
          tooltip: '音轨',
          onPressed: _player == null ? null : () => unawaited(_showAudioMenu()),
        ),
        // 剧集列表的入口**不在这里**。原来它是控制栏上的一个图标，但它要跟
        // 着一个展开后面板走，放在底部控制栏里，展开后会出现「按钮在这儿、
        // 面板在右上角」的割裂感 —— 现在挪到画面右边缘那条竖长条上
        // （见 [_buildPlaylistEdgeTab]），点它面板就从那边滑出来。
        _buildBarIcon(
          icon: Icons.refresh_rounded,
          tooltip: _currentRequest == null
              ? '重新取链（当前片源没有库记录，无从刷新）'
              : '重新取链并续播',
          onPressed: _busy || _currentRequest == null
              ? null
              : () => unawaited(_refreshTicket(reason: '用户手动触发', manual: true)),
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
        // 全屏下红绿灯被系统收走，这是唯一能确定性地「停掉声音并关窗」的地方
        // （先释放再关，不依赖关窗通知的时序）。
        _buildBarIcon(
          icon: Icons.close_rounded,
          tooltip: '停止并关闭',
          onPressed: _busy ? null : () => unawaited(_stopAndClose()),
        ),
      ],
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

  Widget _buildEpisodeTile(PlaylistEntry entry, {required bool current}) {
    return InkWell(
      onTap: () => unawaited(_openEpisode(entry)),
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
            _buildThumbnail(entry, current: current),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      color: current ? Colors.white : Colors.white70,
                    ),
                  ),
                  if (entry.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      entry.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white38),
                    ),
                  ],
                  if (entry.hasProgress) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _episodeProgress(entry),
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
          ],
        ),
      ),
    );
  }

  /// 缩略图。
  ///
  /// ⚠️ 用的是**作品海报**，不是这一集的截图 —— 网盘不给逐集预览图，
  /// 我们也没有在列表里逐集解码首帧的能力（那要为每一集起一次 seek）。
  /// 没有海报时（没开在线刮削、刮削失败、离线）退回占位图。
  Widget _buildThumbnail(PlaylistEntry entry, {required bool current}) {
    final url = entry.thumbnailUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 96,
        height: 54,
        child: url == null
            ? _buildThumbPlaceholder(current: current)
            : Image.network(
                url,
                fit: BoxFit.cover,
                // ⚠️ 必须兜住失败：海报是 TMDB 的外链，离线、没配 API Key、
                // 图片被删都会走到这里。不兜的话整个列表会变成一片红色报错块。
                errorBuilder: (_, _, _) => _buildThumbPlaceholder(current: current),
                loadingBuilder: (context, child, progress) =>
                    progress == null
                        ? child
                        : _buildThumbPlaceholder(current: current),
              ),
      ),
    );
  }

  Widget _buildThumbPlaceholder({required bool current}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: current
              ? <Color>[AppTheme.accent.withValues(alpha: 0.5), Colors.black54]
              : const <Color>[Colors.white24, Colors.black54],
        ),
      ),
      child: const Center(
        child: Icon(Icons.movie_outlined, size: 18, color: Colors.white70),
      ),
    );
  }

  /// 这一集看过多少（0..1）。
  ///
  /// 时长未知时返回 0 —— 画一条满格或半格的**假**进度比不画更误导。
  double _episodeProgress(PlaylistEntry entry) {
    final total = entry.duration.inMilliseconds;
    if (total <= 0) return 0;
    return (entry.resumePosition.inMilliseconds / total).clamp(0.0, 1.0);
  }

  // -------------------------------------------------------------------
  // 画质
  // -------------------------------------------------------------------

  /// 画质菜单。
  ///
  /// 早先用 `showDialog` + `AlertDialog`：菜单**居中**浮在画面正中，
  /// 盖住画面、还跟底部控制栏的画质按钮离得老远，体验很差。
  /// 现在改用 `Overlay` + `CompositedTransformFollower` **贴着画质按钮正上方**
  /// 划出来（见 [_qualityLink]），点哪儿开、菜单就在哪儿上方，跟主流播放器一致。
  ///
  /// 不用 `PopupMenuButton`：每一项要带副标题（`1920×1080 · 4.2 Mbps`），
  /// 而 `PopupMenuItem` 的高度是固定的，塞两行会溢出；自定义 `Overlay` 没有这个限制。
  Future<void> _showQualityMenu() async {
    final request = _currentRequest;
    if (request == null) return;
    final qualities = request.qualities;
    if (qualities.isEmpty) {
      _toast('这个片源没有可选清晰度');
      return;
    }

    // 菜单开着别让浮层自己收起来 —— 用户看不到按钮会以为界面卡住了。
    _cancelHide();

    // ⚠️ 这里**不能**用 `State.context`：它在 `MaterialApp` 外面，
    // 拿它的 overlay 会抛「No MaterialLocalizations found」——
    // 表现为「点画质，什么都没发生」。理由见 [_navigatorKey]。
    final overlay = _navigatorKey.currentState?.overlay;
    if (overlay == null) {
      _pokeChrome();
      return;
    }

    final completer = Completer<void>();
    late final OverlayEntry entry;
    void close() {
      if (entry.mounted) entry.remove();
      if (!completer.isCompleted) completer.complete();
    }

    entry = OverlayEntry(
      builder: (context) => _QualityPopupLayer(
        link: _qualityLink,
        qualities: qualities,
        activeId: request.qualityId,
        onPick: (q) {
          close();
          unawaited(_switchQuality(q));
        },
        onDismiss: close,
      ),
    );
    overlay.insert(entry);
    await completer.future;
    if (mounted) _pokeChrome();
  }

  /// 音轨选择弹框。
  ///
  /// 「没有音轨」和「只有一条音轨」是两回事，但**都还是要把菜单打开**：
  /// 用户点它是想知道「这条片子的音频是什么样的」（语言 / 编码 / 声道 / 码率），
  /// 那是**识别**能力，不是「切换」能力。所以只在完全读不到轨道时才提示。
  Future<void> _showAudioMenu() async {
    final player = _player;
    if (player == null) return;
    if (_audioTracks.isEmpty) {
      _toast('还没读到音轨（片源可能还在打开）');
      return;
    }

    _cancelHide();
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      _pokeChrome();
      return;
    }

    final picked = await showDialog<AudioTrack>(
      context: dialogContext,
      builder: (context) => _AudioDialog(
        tracks: _audioTracks,
        activeId: _activeAudioId,
      ),
    );
    if (!mounted) return;
    _pokeChrome();
    if (picked == null) return;
    // 不在这里 setState 记「已选中」：成功与否由 `stream.track` 回报
    // （见 [_activeAudioId]）。
    await player.setAudioTrack(picked);
  }

  /// 字幕选择弹框。
  ///
  /// ## 为什么是个 `while` 循环而不是一次 `showDialog`
  ///
  /// 菜单里除了字幕，还有一个**动作**项（「搜索在线字幕…」）：选它之后要去网上
  /// 搜，搜完把**同一个菜单**重新打开，让用户从结果里挑。写成递归的话栈会随
  /// 搜索次数增长，而且「谁负责把菜单关掉」会变得很难读 —— 循环把
  /// 「开菜单 → 拿到选择 → 要么应用要么重开」这一件事摆在一处。
  Future<void> _showSubtitleMenu() async {
    final player = _player;
    if (player == null) return;

    while (true) {
      // 弹菜单这件事单独一个方法：它自己不带任何 `await` 之前的上下文获取，
      // 循环体里也就没有「跨 async gap 用 context」的问题。
      final picked = await _promptSubtitleChoice();
      if (!mounted) return;

      // 关掉菜单（点外面 / Esc），或者菜单根本弹不出来（没有 Navigator）：
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
        if (!await _pickLocalSubtitle(player)) return;
        if (!mounted) return;
        continue;
      }

      _pokeChrome();
      await _applySubtitleChoice(player, picked);
      return;
    }
  }

  /// 弹出字幕菜单。返回用户的选择；**菜单弹不出来或用户关掉它**都返回 null
  /// （这两种情况调用方的处置完全一样，没必要分开）。
  Future<_SubtitleChoice?> _promptSubtitleChoice() async {
    _cancelHide();
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return null;

    return showDialog<_SubtitleChoice>(
      context: dialogContext,
      builder: (context) => _SubtitleDialog(
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
  Future<void> _applySubtitleChoice(
    Player player,
    _SubtitleChoice picked,
  ) async {
    switch (picked.kind) {
      case _SubtitleKind.off:
        _clearExternalSubtitle();
        await player.setSubtitleTrack(SubtitleTrack.no());
        return;

      case _SubtitleKind.embedded:
        // 内嵌轨的选择态由 mpv 回报（`stream.track` → `_activeSubtitleId`），
        // 这里只把三个「外挂字幕」的记账清掉。
        _clearExternalSubtitle();
        await player.setSubtitleTrack(
          SubtitleTrack('${picked.trackId}', null, null),
        );
        return;

      case _SubtitleKind.cloud:
        final fileId = picked.fileId;
        if (fileId == null) return;
        final brief = _cloudSubtitleOf(fileId);
        final text = await _fetchSubtitleText(fileId);
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
        await player.setSubtitleTrack(
          SubtitleTrack.data(
            text,
            title: brief?.label,
            language: brief?.language,
          ),
        );
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
        await player.setSubtitleTrack(
          SubtitleTrack.data(
            text,
            // 在线字幕没有「我们自己的展示名」，用站点给的标题（片名）回退到
            // 文件名 —— 它们只出现在 mpv 自己的轨道列表里。
            title: brief?.title ?? brief?.fileName,
            language: brief?.language,
          ),
        );
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
        await player.setSubtitleTrack(
          SubtitleTrack.data(
            text,
            title: picked.localLabel,
            // 本地文件的语言无从得知（文件名里的 `chs` 只是发布组的习惯，
            // 不是规范）。不给比猜错好 —— mpv 会用它去做「按语言自动选轨」。
          ),
        );
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
  Future<bool> _pickLocalSubtitle(Player player) async {
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
    await player.setSubtitleTrack(
      SubtitleTrack.data(text, title: picked.label),
    );
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
  /// 高频流，存进 State 会让**整个播放器**每秒重建十次（连 `Video` 一起）。
  /// 用 StreamBuilder 把重建限制在这条进度条内部。
  ///
  /// ⚠️ 它挂在浮层的 `Column` 里，所以**不能**再包一层 `Expanded`
  /// （那要求 `Row` / `Flex` 父级）。横向伸展由内部那个 `Row` 负责。
  Widget _buildSeekBar() {
    final player = _player;
    if (player == null) return const SizedBox.shrink();

    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (context, durationSnapshot) {
        final total = durationSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
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
                      // 「已经缓存到这儿了」那一层。见 [_cacheAhead]：它是
                      // 播放头**前面**的秒数，换算成进度的规则在
                      // [PlayerBufferProgress]；时长未知时返回 null（不画）。
                      buffered: PlayerBufferProgress.fraction(
                        position: played,
                        cacheAhead: _cacheAhead,
                        duration: total,
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
                        await player.seek(
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
            child: SelectableText(
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

/// 清晰度选择弹框。
///
/// 只是**选择**：它不自己换流，而是把选中的档位 `pop` 回去，由
/// [_PlayerWindowAppState._switchQuality] 走跨引擎通道让主窗口重新取链。
/// 理由见 [QualityBrief] 的类文档 —— 播放窗口没有取链能力。
/// 画质菜单的浮层。
///
/// 两层叠在一起：
/// 1. 全屏透明 `GestureDetector` —— 点菜单以外任意处即关闭（点视频、点别的控件都算）；
/// 2. `CompositedTransformFollower` —— 把菜单贴到 [_QualityPopupLayer.link]
///    锚的那个画质按钮**正上方、右沿对齐**（见 [player_window_app._qualityLink]）。
class _QualityPopupLayer extends StatelessWidget {
  const _QualityPopupLayer({
    required this.link,
    required this.qualities,
    required this.activeId,
    required this.onPick,
    required this.onDismiss,
  });

  /// 与画质按钮共享的锚点。
  final LayerLink link;

  final List<QualityBrief> qualities;

  /// 当前正在播的那一档。打勾 / 高亮用。
  final String? activeId;

  /// 选了一档 → 关掉菜单并把选择抛上去。
  final ValueChanged<QualityBrief> onPick;

  /// 点菜单外 → 只关菜单。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 透明全屏拦截层：吃掉菜单以外的所有点击，点它即关。
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          // 按钮「右上角」对齐菜单「右下角」→ 菜单整块落在按钮上方、右沿齐平。
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          child: _QualityPopup(
            qualities: qualities,
            activeId: activeId,
            onPick: onPick,
          ),
        ),
      ],
    );
  }
}

/// 画质菜单本体：一块圆角面板，顶上一行「清晰度」，下面是可选项列表。
///
/// 每一项带副标题（`1920×1080 · 4.2 Mbps`），当前档打勾。
class _QualityPopup extends StatelessWidget {
  const _QualityPopup({
    required this.qualities,
    required this.activeId,
    required this.onPick,
  });

  final List<QualityBrief> qualities;

  /// 当前正在播的那一档。打勾用。
  final String? activeId;

  final ValueChanged<QualityBrief> onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.panel,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 10, 14, 7),
              child: Text(
                '清晰度',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1, thickness: 1, color: Colors.white12),
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
                onTap: () => onPick(q),
              ),
          ],
        ),
      ),
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
    _AudioDialog(tracks: tracks, activeId: activeId);

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
    _SubtitleDialog(
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
class _AudioDialog extends StatelessWidget {
  const _AudioDialog({required this.tracks, required this.activeId});

  final List<AudioTrack> tracks;

  /// 当前选中的音轨 id。打勾用。
  final String? activeId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      title: const Text('音轨', style: TextStyle(fontSize: 15)),
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      content: SizedBox(
        width: 340,
        child: ListView(
          shrinkWrap: true,
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
        ),
      ),
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
class _SubtitleDialog extends StatelessWidget {
  const _SubtitleDialog({
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
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      title: const Text('字幕', style: TextStyle(fontSize: 15)),
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      content: SizedBox(
        width: 380,
        child: ListView(
          shrinkWrap: true,
          children: [
            _SubtitleTile(
              title: '关闭字幕',
              selected: _nothingActive,
              onTap: () =>
                  Navigator.of(context).pop(const _SubtitleChoice.off()),
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
        ),
      ),
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

