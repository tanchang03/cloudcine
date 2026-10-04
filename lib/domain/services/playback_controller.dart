import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../core/utils/mpv_subtitle_log.dart';
import '../../core/utils/playback_seek.dart';
import '../../core/utils/player_audio_effect.dart';
import '../../core/utils/player_buffer_progress.dart';
import '../../core/utils/redact.dart';
import '../../core/utils/subtitle_formats.dart';
import '../../core/utils/track_bridge.dart';
import '../../core/utils/track_labels.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../adapters/cloud_drive_adapter.dart';
import '../adapters/stream_relay.dart';
import '../entities/media_item.dart';
import '../entities/playback_preference.dart';
import '../entities/quality_option.dart';
import '../entities/stream_ticket.dart';
import '../entities/subtitle_track.dart';
import 'intro_marker.dart';
import 'intro_session.dart';
import 'missing_media.dart';
import 'playback_engine.dart';
import 'playback_engine_router.dart';
import 'playback_restore.dart';
import 'subtitle_service.dart';

/// 播放控制器 —— 本应用「能不能看」这件事的唯一裁决者。
///
/// ## 内核：两个，按需路由
///
/// 播放内核**不是固定的**：契约是 [PlaybackEngine]，当前有 media_kit（mpv）
/// 与 fvp（libmdk）两份实现。选哪一个由 [open] 时的一次探测决定 ——
/// **只有杜比视界 Profile 5 的片源走 fvp**，其余全部走 media_kit。
///
/// 为什么非得分两个：
///   - media_kit 容器 / 字幕能力最强（MKV / AVI / TS / RMVB 全能、ASS 完整
///     特效、外挂字幕编码可控），是本应用 100% 既有片源的默认内核；
///   - 但 macOS 上它走 mpv 的 **render API**（`vo=libmpv`），后端只有
///     `gpu` / `sw`，`vo=gpu-next` 架构上不可达 —— 而 DV P5 的像素在
///     IPT-PQ-C2 空间里，必须把 RPU 元数据应用在**渲染阶段**。
///     调任何 mpv 参数都没用，只能换内核。
///
/// ⚠️ 按需路由**没有**减少实现量：DV 片同样要切音轨、挂字幕、跳章节、看缓冲，
/// 所以本类对两个内核一视同仁（一律走契约）。这正是 `playback_engine.dart`
/// 存在的理由。
///
/// ## 状态设计
///
/// 所有可变状态都在这个对象上，UI 通过 `ChangeNotifier` 重建。
/// **不把内核对象暴露给 UI**：那样 UI 就会开始直接调 mpv，
/// 「清晰度切换要重取链」「外挂字幕要先解码」这类业务规则会被绕过。
///
/// 唯一的例外是 [engine]：UI 需要它来给 `PlaybackSurface` 挑渲染组件
/// （两个内核的渲染句柄类型不同），见 `ui/widgets/playback_surface.dart`。
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required DriveAdapterRegistry registry,
    required SubtitleResolver subtitleResolver,
    required PlaybackEngine engine,
    PlaybackEngine Function()? dolbyVisionEngine,
    DolbyVisionProbeFn? dolbyVisionProbe,
    StreamRelay? relay,
    Duration positionSaveInterval = const Duration(seconds: 10),
  })  : _registry = registry,
        _subtitleResolver = subtitleResolver,
        _relay = relay,
        _positionSaveInterval = positionSaveInterval,
        _router = PlaybackEngineRouter(
          defaultEngine: engine,
          dolbyVisionEngine: dolbyVisionEngine,
          dolbyVisionProbe: dolbyVisionProbe,
        ) {
    _bindEngine(_router.engine);
  }

  final DriveAdapterRegistry _registry;
  final SubtitleResolver _subtitleResolver;

  /// 本地中继。**为 null 表示直连** —— 这不是错误状态，只是没启用。
  ///
  /// 注入而不是在这里 new：本类活在领域层，而中继要 bind 端口、发网络
  /// 请求，是实现细节。
  final StreamRelay? _relay;

  /// 当前中继会话的标识。
  ///
  /// 换片源 / 切清晰度时**必须先关掉旧的**：不关的话上一条流还在后台预取，
  /// 几条会话的并发叠加起来会把带宽吃光，而用户看到的是「越播越卡」。
  String? _relayToken;

  final Duration _positionSaveInterval;

  // -------------------------------------------------------------------
  // 内核
  // -------------------------------------------------------------------

  /// 内核路由：**选哪个内核**这件事只有一份实现
  /// （见 `PlaybackEngineRouter` 的类文档）。本类负责的只是「选完之后怎么用」。
  final PlaybackEngineRouter _router;

  /// 当前内核。**给 UI 挑渲染组件用**（见 `PlaybackSurface`）。
  ///
  /// 它会随片源变化 —— UI 必须监听本控制器并在它变化时重建，
  /// 否则「换了内核但画面还是用旧的渲染组件」会表现成一块黑。
  PlaybackEngine get engine => _router.engine;

  /// 内部调用点用的别名。
  ///
  /// ⚠️ 写成 **getter** 而不是字段：内核会被 [PlaybackEngineRouter] 在换源时
  /// 换掉，存一份副本就等于存了一个会过期的引用 —— 而它过期的表现是
  /// 「命令发给了已经不用的那个内核」，即点了没反应且不报错。
  PlaybackEngine get _engine => _router.engine;

  /// 当前内核的能力声明。UI 据此置灰（而不是静默失效）那些做不到的功能。
  EngineCapabilities get capabilities => _router.capabilities;

  // -------------------------------------------------------------------
  // 对外状态
  // -------------------------------------------------------------------

  MediaItem? _item;
  StreamTicket? _ticket;
  String? _activeQualityId;
  bool _loading = false;
  String? _error;

  /// 这次失败是不是「网盘上已经没有这个文件」。
  ///
  /// ## 为什么 UI 需要它，而不只是看 [error] 那句话
  ///
  /// [error] 是给人读的一行字，UI 拿它只能做「显示出来」这一件事。而
  /// 「文件确实没了」这个结论还意味着**有一件事可以做**——把这条已经失效
  /// 的索引从媒体库里删掉。要让播放页长出那个「从媒体库移除」的按钮，
  /// 就得有一个机器可读的信号，靠解析中文文案是做不到的（而且文案一改就断）。
  ///
  /// 判据本体在 `missing_media.dart` 的 `isMissingFileError`（独立窗口那条
  /// 路也用它）。这里只是记下本次 `open()` 的结论：它在每次 `open()` 开头
  /// 归零，所以「重试成功」会自动把它清掉。
  bool _fileMissing = false;

  /// 非致命提示（字幕加载失败、选的档位服务端没给地址…）。
  ///
  /// **绝不能塞进 [_error]**：`error` 在播放页是一层 **88% 不透明的全屏遮罩**，
  /// 会把画面整个盖住。「这条字幕没加载上」不该让用户看不到视频 ——
  /// 实测踩过：自动选字幕失败 → 画面被「播放失败」遮住，声音却还在放，
  /// 用户以为播放器坏了。
  String? _notice;

  List<SubtitleTrack> _externalSubtitles = const [];
  List<SubtitleTrack> _embeddedSubtitles = const [];
  List<mk.AudioTrack> _embeddedAudio = const [];

  /// 正在后台预取正文的字幕 id（防重入）。见 [prefetchCloudSubtitles]。
  final Set<String> _prefetching = <String>{};
  String? _activeSubtitleId;
  bool _subtitlesEnabled = true;

  /// 本次播放要还原的偏好（来自库）。`null` = 这一条没记过，全走默认。
  ///
  /// **只影响「初始状态」**：打开时决定用哪一档画质、字幕开关、以及要不要
  /// 按特征把音轨 / 字幕切到用户上次选的那一条。之后用户在菜单里改的东西
  /// 由 UI 层负责落库 —— 本类不碰数据库，理由与 [onPositionTick] 相同。
  PlaybackPreference? _preference;

  /// 音轨偏好是否已经尝试应用过。
  ///
  /// ## 为什么必须有这个闸
  ///
  /// `tracks` 是**流**：打开文件、探到新信息、切轨都会再发一遍。
  /// 不设闸的话，用户手动切到另一条音轨之后，下一次轨道回报又会把他的选择
  /// **拉回**偏好里那一条 —— 表现是「音轨菜单点了没反应，自己跳回去」，
  /// 而日志里看不出任何异常。
  ///
  /// 只在 `open()` 里归零：同一次播放期间只还原一次。
  bool _audioRestored = false;

  bool _buffering = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 本次打开的文件是否已经播到结尾。见 [onCompleted]（只在上升沿触发）。
  bool _completed = false;

  /// 换源后待核对的起播位置。`null` = 没有欠账。
  ///
  /// 起播位置交给内核的 `startAt` 是**一次静默的尝试**：mpv 收下了 `start`
  /// 属性却没照做时，不会有任何回调。用户报的「选择画质后都会重头就开始
  /// 播放」就是这种形态。所以每次带位置换源都挂一个 [RestoreSeek] 上来，
  /// 由位置流核对，必要时补一次显式 seek（见 [_maybeRestoreSeek]）。
  RestoreSeek? _restore;

  /// 缓冲覆盖到的**绝对位置**。
  ///
  /// ⚠️ 它是**时间戳**，不是「播放头前面还有多少秒」。契约已经把两个内核的
  /// 口径统一到这一点上（mpv 直接给绝对时间戳，mdk 的区间列表由
  /// `EngineTimeRange.cacheEndAt` 折算），所以本类**不需要**再换算一次 ——
  /// 别再加播放头（加了就等于把播放头算两遍，症状见 [PlayerBufferProgress]）。
  Duration _cacheEnd = Duration.zero;
  double _volume = 100;
  double _rate = 1.0;

  /// 当前「音效」预设。默认 [AudioEffectPreset.auto]（跟随片源）。
  ///
  /// 它由播放页在 bootstrap 时从设置库读出来喂进来（本类不碰数据库），
  /// 之后用户在菜单里改。换集**不重置** —— 它描述的是这台设备怎么接音箱，
  /// 与播哪一集无关。
  AudioEffectPreset _audioEffect = AudioEffectPreset.auto;

  /// 当前正在播放的媒体项
  MediaItem? get item => _item;

  /// 当前票据（含全部清晰度档位）
  StreamTicket? get ticket => _ticket;

  /// 可选清晰度。**空列表是正常状态**：服务端没给转码梯度时只有原画。
  List<QualityOption> get qualities => _ticket?.qualities ?? const [];

  String? get activeQualityId => _activeQualityId;

  /// 本地中继的实时统计。**没走中继时是 null。**
  ///
  /// 它是**真实计数**而不是估算：下载了多少字节只有发起请求的那一方
  /// 才知道确切数字。正好拿来对冲缓冲指示的口径差 —— 那边只告诉你
  /// 「缓存到了哪个时间戳」，换算成「还能看多久」要减播放头，
  /// 而中继这边是实打实的字节（见 [_cacheEnd]）。
  RelayStats? get relayStats {
    final token = _relayToken;
    if (token == null) return null;
    return _relay?.statsOf(token);
  }

  bool get isLoading => _loading;
  String? get error => _error;
  bool get hasError => _error != null;

  /// 这次打不开是不是因为「网盘上已经没有这个文件」。见 [_fileMissing]。
  ///
  /// UI 据此决定要不要给「从媒体库移除」这个出口 —— 其它失败种类（登录
  /// 失效、网络断了、限流）都不该给，那些情况下文件还在。
  bool get isFileMissing => _fileMissing;

  /// 非致命提示，UI 应当**不遮挡画面**地展示它（见 [_notice]）。
  String? get notice => _notice;

  /// 自动消失的提示的定时器（跳片头那条）。
  ///
  /// 为什么需要它：跳片头是**我们主动把画面往前推了 90 秒**，而用户什么都没按。
  /// 不给一句提示的话，这件事在用户眼里与「播放器抽风跳帧」没有区别 ——
  /// 而这类「莫名其妙」的投诉最难查，因为它不留任何痕迹。
  Timer? _noticeTimer;

  void clearNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// 显示一条 [duration] 后自己消失的提示。
  ///
  /// 与 [notice] 共用同一个字段，所以**必须防覆盖**：期间如果字幕加载失败
  /// 又设了 `_notice`，定时器到点时不能把那条新提示一起清掉。
  void _showTransientNotice(String message, {Duration? duration}) {
    _noticeTimer?.cancel();
    _notice = message;
    notifyListeners();
    _noticeTimer = Timer(duration ?? const Duration(seconds: 5), () {
      _noticeTimer = null;
      if (_notice != message) return;
      _notice = null;
      notifyListeners();
    });
  }

  /// 网盘外挂字幕（扫描期建立的引用）
  List<SubtitleTrack> get externalSubtitles => _externalSubtitles;

  /// 视频内嵌字幕轨（内核解出来的）
  List<SubtitleTrack> get embeddedSubtitles => _embeddedSubtitles;

  /// 全部可选字幕（外挂 + 内嵌），**按偏好排序**（中文优先）
  List<SubtitleTrack> get allSubtitles {
    final all = [...externalSubtitles, ...embeddedSubtitles];
    all.sort((a, b) => a.preferenceScore.compareTo(b.preferenceScore));
    return all;
  }

  /// 内嵌音轨。
  ///
  /// ⚠️ 类型是 media_kit 的 `AudioTrack`，而数据来自**引擎契约**
  /// （`EngineTracks.audio` → [TrackBridge.audio]）。保留这个类型是因为两个
  /// 播放器的音轨菜单与 `TrackLabels` 都吃它 —— 换掉它们是一次比这大得多的
  /// 改动，而收益只是「少一层转换」。见 `TrackBridge` 的类文档。
  ///
  /// ⛔ **不要**把它喂回播放器：切轨一律走 [selectAudioTrack]。
  List<mk.AudioTrack> get embeddedAudioTracks => _embeddedAudio;

  String? get activeSubtitleId => _activeSubtitleId;
  bool get subtitlesEnabled => _subtitlesEnabled;

  bool get isBuffering => _buffering;
  bool get isPlaying => _playing;
  Duration get position => _position;
  Duration get duration => _duration;

  /// 缓冲覆盖到的绝对位置。见 [_cacheEnd]。
  Duration get bufferedEnd => _cacheEnd;

  /// 进度条上「已缓冲」那一层（0..1）。
  ///
  /// **时长未知时返回 null**，UI 收到 null 就不该画这一层 —— 那时长下画什么
  /// 都是编的。
  double? get bufferedFraction => PlayerBufferProgress.fraction(
        position: _position,
        cacheEnd: _cacheEnd,
        duration: _duration,
        // 内核自己说在等数据时，缓冲层收到播放头。理由见
        // [PlayerBufferProgress.fraction]。
        stalled: _buffering,
      );

  /// 音量（0..100，与设置里存的口径一致）
  double get volume => _volume;

  double get rate => _rate;

  /// 当前「音效」预设。菜单据此打勾。见 [_audioEffect]。
  AudioEffectPreset get audioEffect => _audioEffect;

  bool get hasMedia => _item != null;

  /// 进度（0..1）。时长未知时返回 0。
  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// 是否可以切清晰度（UI 据此决定显不显示那个按钮）。
  bool get canSwitchQuality => qualities.length > 1;

  /// 进度回调（每 [positionSaveInterval] 触发一次）。
  ///
  /// 控制器本身**不依赖仓储**：落库由 UI 层接这个回调完成。
  /// 这样播放控制器可以在单元测试里独立构造。
  void Function(Duration position)? onPositionTick;

  /// **一集播完了**。自动连播由接这个回调的人决定「下一集是谁」。
  ///
  /// ## 为什么是回调而不是控制器自己切集
  ///
  /// 「下一集是哪一条」需要**播放列表**，而两个播放器拿到的列表形状不同
  /// （内置页是 `List<MediaItem>`，独立窗口是 `List<PlaylistEntry>`，
  /// 跑在另一个引擎里）。规则本体在 `EpisodeQueue.nextAfter`，这里只负责
  /// 把「播完了」这个事实播出去 —— 控制器一旦开始自己找下一集，就必然
  /// 要在这一层引入对列表形状的假设，两个播放器又会各长一套。
  ///
  /// ⚠️ 只在**上升沿**触发（`false → true`）。两个内核的 `completed` 都是
  /// 状态流，一次播完可能重复报同一个值；不过滤的话「最后一集播完」
  /// 会反复触发自动连播逻辑，而那时它已经找不到下一集了。
  void Function()? onCompleted;

  /// 一集播完了（供 UI 显示「下一集」按钮之类的状态）。
  bool get isCompleted => _completed;

  // -------------------------------------------------------------------
  // 片头（自动跳过）
  // -------------------------------------------------------------------

  /// 片头状态机。状态与转移全部在 [IntroSession] 里 —— 独立播放窗口用的是
  /// **同一个类**，两边只负责「取数据 + 按回答去 seek」。
  final IntroSession _intro = IntroSession();

  /// 当前生效的片头区间。**章节优先、手标兜底**（见 [IntroSession.marker]）。
  IntroMarker? get introMarker => _intro.marker;

  /// 片头区间是从文件章节来的吗（UI 用它区分「这是压制者标的」与
  /// 「这是你手标的」，两者的提示文案不同）。
  bool get introFromChapters => _intro.fromChapters;

  bool get introSkipped => _intro.skipped;

  /// 用户手标了片头区间（或取消标记）后同步给控制器。
  ///
  /// **不落库**：写库由 UI 层走 `MediaRepository.setWorkIntro*` 完成 ——
  /// 控制器不认识仓储（见 [onPositionTick] 的同一条理由）。
  ///
  /// [marker] 传 `null` 表示取消标记。章节区间不受影响（它是文件里的
  /// 事实，不该被用户的标记清掉）。
  void applyManualIntro(IntroMarker? marker) {
    if (_intro.manual == marker) return;
    _intro.setManual(marker);
    notifyListeners();
  }

  // -------------------------------------------------------------------
  // 打开与取链
  // -------------------------------------------------------------------

  /// 打开一个媒体项。
  ///
  /// [subtitles] 是扫描期建立的字幕引用（可为空）。
  /// [preferredQualityId] 是设置里的默认档位（可为空 = 原画优先）。
  /// [introMarker] 是**库里手标**的片头区间（兜底，可为空）。
  /// [skipIntro] 来自设置；`false` 时连章节也不读（省一次属性查询）。
  /// [preference] 是这一条**上次的播放选择**（音轨 / 字幕 / 字幕开关），
  /// 由调用方从库里读出来；`null` = 没记过，全走默认。画质不在里面 ——
  /// 调用方已经把它折进 [preferredQualityId] 了。
  Future<void> open(
    MediaItem item, {
    List<SubtitleTrack> subtitles = const [],
    String? preferredQualityId,
    bool autoLoadSubtitles = true,
    IntroMarker? introMarker,
    bool skipIntro = true,
    PlaybackPreference? preference,
  }) async {
    _item = item;
    _error = null;
    _fileMissing = false;
    _notice = null;
    _loading = true;
    _position = Duration.zero;
    _duration = Duration.zero;
    // ⚠️ 上一轮换源留下的欠账必须在这里就清掉，**不能**等 [_loadIntoPlayer]。
    // 下面 `resolveStream` 是一次网络往返，这期间**旧流还在播**、位置还在
    // 往上走 —— 欠账留着的话，旧流的位置会被当成新流的位置去核对，
    // 于是凭空补一次 seek（用户看到「刚进播放页画面自己跳一下」）。
    _restore = null;
    _externalSubtitles = subtitles;
    _embeddedSubtitles = const [];
    _embeddedAudio = const [];
    _activeSubtitleId = null;
    // 字幕开关：**偏好优先于全局设置**。
    //
    // 两者语义不同：`autoLoadSubtitles` 是「没记过时要不要自动挑一条」，
    // 而偏好里那一位是「用户上次在这部片上有没有开着字幕」—— 后者更具体，
    // 也是用户在一部片里主动关掉字幕之后**期望下次还记得**的那件事。
    _subtitlesEnabled = preference?.subtitlesEnabled ?? autoLoadSubtitles;
    // 偏好**每次 open 都要重设**：换集时新一集可能继承同作品另一条的选择，
    // 也可能自己有一条。留着上一集的，表现就是「换集后字幕还停在上一集
    // 选的那条」—— 而内嵌轨号在两集之间根本不是同一个东西。
    _preference = preference;
    // 音轨还原的闸跟着归零。不归零的话第二集永远不会再尝试还原
    // （第一集已经把它置位了）—— 而「只有第一集记得音轨」正是最难察觉的
    // 那种半失效。
    _audioRestored = false;
    // 片头状态**每次打开都要归零**。漏了「已探测」标志的后果很隐蔽：
    // 换集之后永远不再读章节，于是「只有第一集跳片头」—— 而第一集恰好
    // 是最不需要跳的那一集（用户是从头开始看的）。
    _intro.reset(manual: introMarker, enabled: skipIntro);
    _completed = false;
    _subtitleResolver.clear();
    notifyListeners();

    diag.section('播放 ${item.displayTitle}');
    diag.info(
      '播放',
      'fid=${item.fileId} 容器=${item.container.label} '
      '分辨率=${item.resolution?.label ?? "-"} 体积=${item.sizeBytes ?? "-"}B '
      '外挂字幕=${subtitles.length} 条',
    );

    try {
      final adapter = _registry.requireAdapter(item.provider);
      final ticket = await adapter.resolveStream(
        item.fileId,
        qualityId: preferredQualityId,
      );

      _ticket = ticket;
      _activeQualityId = _pickActiveQualityId(ticket, preferredQualityId);

      await _loadIntoPlayer(ticket);
      _loading = false;
      notifyListeners();

      if (_subtitlesEnabled) {
        unawaited(_autoLoadSubtitle());
      }
    } on DriveException catch (e) {
      _loading = false;
      _error = _explain(e);
      // 只有 `notFound` 才算「文件没了」：登录失效、限流、网络断了都只是
      // 这次没取到，文件本身还在 —— 拿它们去问用户「要不要从媒体库移除」
      // 是最糟的一类误报。
      _fileMissing = isMissingFileError(e);
      diag.error('播放', '取链失败：$e');
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = '播放失败：$e';
      diag.error('播放', '意外错误：$e');
      notifyListeners();
    }
  }

  /// 把票据交给当前内核。
  ///
  /// ⚠️ **请求头是必须的**。夸克直链缺 Cookie 一律返回 412，
  /// 表现是「能扫描、一播就报错」，而错误信息里看不出是缺头。
  ///
  /// [startAt] 是起播位置。两个内核的**下达方式不同**（media_kit 走
  /// `Media(start:)`，fvp 走 `initialize()` 之后 `seekTo()`），但都**不能**
  /// 用「open 之后再 seek」替代 —— 那次 seek 会被丢掉，正是本项目「续播点了
  /// 没用、每次都从头开始」的根因。差异全部收在各自的实现里。
  ///
  /// ⚠️ 但「交给 `startAt`」是**一次静默的尝试**：内核没照做时不会报错。
  /// 所以带位置换源时额外挂一道 [RestoreSeek] 核对（见方法体里的注释），
  /// 这是「切清晰度后从头开始播」那条反馈的兜底。
  Future<void> _loadIntoPlayer(
    StreamTicket ticket, {
    Duration startAt = Duration.zero,
    bool keepBufferView = false,
  }) async {
    diag.info(
      '播放',
      '交给播放器：${ticket.redactedUrl} '
      '请求头=${ticket.headers.keys.toList()} '
      '档位=${_activeQualityId ?? "-"} '
      '起播=${startAt.inSeconds}s'
      '${keepBufferView ? " 保留缓冲视图" : ""}',
    );
    // 换源 = 缓存作废：内核是从零重新攒的，旧值属于上一条 URL。不清的话
    // 新流一开播，进度条上就挂着上一条流（可能是另一个码率）的缓冲终点 ——
    // 而 [_position] 这时已经被恢复成续播点了，两者一减/一画就对不上，
    // 缓冲层会画到一个根本没缓存到的地方去。
    //
    // ⚠️ 必须放在**这个**入口上，不能只放在 `open()` 里：`switchQuality`
    // 换的是同一部片子的另一档转码，走的是本方法而不是 `open()`，
    // 只清 open() 的话「切清晰度」这条路的缓冲层就会残留。
    //
    // [keepBufferView] 是**切清晰度**专用的例外：那是「同一部片子换一档」，
    // 用户视线里的位置一点没变，把缓冲层瞬间抹到 0 只会让他以为「重新开始
    // 缓存了」。留着旧值不会画错 —— 内核换源后立刻报 `paused-for-cache`，
    // [PlayerBufferProgress.fraction] 在 stalled 时本来就把缓冲层收回到播放
    // 头；而新流自己的缓冲终点一两拍内就会把旧值覆盖掉。
    if (!keepBufferView) {
      _cacheEnd = Duration.zero;
      notifyListeners();
    }

    final source = await _prepareSource(ticket, startAt: startAt);

    // ⚠️ 顺序：**先选内核、再下发音效、最后 open**。
    //   - 选内核要在 `open` 之前（内核一 `open` 就没法换了）；
    //   - 音效要在 `open` 之前重新下发（理由见 [_applyAudioEffect]），
    //     而它必须发给**新选中的**那个内核 —— 顺序反了会发给上一集的内核。
    await _selectEngineFor(ticket);
    await _applyAudioEffect();

    // 起播位置是**一次静默的尝试**（见 [RestoreSeek] 的类文档）：mpv 收下
    // `start` 属性却没照做时，不会有任何回调报错。所以每次带位置换源都在
    // 这里挂一道核对，由位置流（[_maybeRestoreSeek]）决定要不要补一次
    // 显式 seek。
    //
    // ⚠️ 必须挂在**这个位置**，不能提前到 `switchQuality`：上面
    // `_prepareSource` 的预热期间**旧流还在播**，位置流上流过的全是旧流的
    // 值 —— 而它们恰好等于目标（目标就是从旧流取的），提前挂会被它们骗过去。
    _restore = startAt > Duration.zero ? RestoreSeek(startAt) : null;

    // ⚠️ 这一条是**唯一**记录「内核实际打开了哪个地址」的地方。
    //
    // 本方法开头那条「交给播放器」打的是 `ticket.redactedUrl` —— 那是**上游**
    // 地址；而走中继时内核拿到的是 `http://127.0.0.1:PORT/sN`，且**不带任何
    // 请求头**。少了这一条，播放器报
    // `Failed to open http://127.0.0.1:43617/s1.` 时，日志里只有上游地址，
    // 无从确认「中继到底参与了没有、交给内核的是哪条会话」—— 而那恰恰是这个
    // 报错仅有的全部信息量。
    //
    // [redactUrl] 在这里够用：它只丢查询串。中继地址的会话号在**路径**上
    // （`/s1`），会被原样保留；而直链的签名在查询串里，正好被抹掉。
    diag.info(
      '播放',
      '内核打开：${redactUrl(source.url)}'
      '（${source.relayed ? "本地中继" : "直连"}）'
      '请求头=${source.headers.length} 条 起播=${startAt.inSeconds}s',
    );

    await _engine.open(
      EngineMedia(
        url: source.url,
        headers: source.headers,
        startAt: startAt,
      ),
    );
  }

  /// 决定这条流**用哪个内核**。
  ///
  /// 判据、缓存键、以及「为什么要跳过 HLS」全部在
  /// [PlaybackEngineRouter.selectFor] 里 —— **独立播放窗口用的是同一份**。
  /// 这里只负责两件本类才知道的事：
  ///   1. 缓存键的构成（`fileId|档位`，只有本类同时知道这两者）；
  ///   2. 换了内核之后**重新接订阅**并通知 UI 换渲染组件。
  Future<void> _selectEngineFor(StreamTicket ticket) async {
    final selection = await _router.selectFor(
      key: '${_item?.fileId ?? ticket.url}|${_activeQualityId ?? "-"}',
      url: ticket.url,
      headers: ticket.headers,
    );
    if (!selection.changed) return;

    // ⚠️ 订阅**必须**在 `open()` 之前接好：契约里的流都是广播且**不重放**
    // （见 `PlaybackEngine` 的类文档），晚一步这一整集就收不到任何事件 ——
    // 表现是「画面在动，但进度条、音轨菜单、暂停按钮全是死的」。
    _bindEngine(selection.engine);
    // UI 要据此换渲染组件（两个内核的句柄类型不同）。
    notifyListeners();
  }

  /// 重新下发「音效」预设。
  ///
  /// ## 为什么每次开流前都要重发
  ///
  /// `audio-channels` 在 mpv 里是**按文件选项**，换一条 URL（换集 / 切清晰度
  /// 都走 [_loadIntoPlayer]）会回到默认值 —— 只设一次的话，第二集开始音效就
  /// 悄悄失效了，而菜单上那个勾还在（勾读的是我们自己的状态）。
  /// 重新下发的代价是两次 setProperty，可以忽略。
  ///
  /// ## 为什么换内核后是空操作
  ///
  /// 音效是 mpv 专有能力：mdk 既没有 `af` 也没有 `audio-channels` 的等价物
  /// （见 `EngineCapabilities.audioEffects`）。DV 片源上它静默跳过 ——
  /// 用户在菜单里点的时候会收到 [setAudioEffect] 的那句说明。
  Future<void> _applyAudioEffect() async {
    final engine = _engine;
    if (engine is! MediaKitPlaybackEngine) return;
    await PlayerAudioEffect.apply(engine.player, _audioEffect);
  }

  /// 决定这条流**从哪里读**：本地中继，还是原直链。
  ///
  /// 中继不是总能成立（源流不支持 Range、长度未知、端口绑不上），
  /// 拿不到就**原样直连** —— 直连至少能播，所以失败一律静默，只记日志。
  /// 用户看到的最坏情况是「没变快」，绝不是「播不了」。
  Future<_PlaybackSource> _prepareSource(
    StreamTicket ticket, {
    Duration startAt = Duration.zero,
  }) async {
    // 旧会话先**记下来但不立刻关**：新会话要先建起来、把起播点附近预取上，
    // 再关旧的。顺序反过来的话，「新会话还是空的 + 旧会话已经关了」这一小段
    // 里内核什么都拿不到，正是「切一下就卡一下」的那一瞬。
    final previousToken = _relayToken;
    _relayToken = null;

    final relay = _relay;
    final length = ticket.contentLength;
    final direct = _PlaybackSource(ticket.url.toString(), ticket.headers);
    if (relay == null || length == null || length <= 0) {
      await _closeRelayToken(previousToken);
      return direct;
    }
    if (!isRelayableUrl(ticket.url)) {
      await _closeRelayToken(previousToken);
      return direct;
    }

    final endpoint = await relay.open(
      ticket,
      label: _item?.displayTitle,
      // 告诉中继「播放器大概从哪儿开始读」：续播 / 换清晰度时起点常在中后段，
      // 让预取窗口直接摆过去，省掉开流后那一次上游往返。
      startOffset: _byteOffsetFor(startAt, length),
    );
    if (endpoint == null) {
      await _closeRelayToken(previousToken);
      return direct;
    }
    _relayToken = endpoint.token;
    // 会话号必须进日志：播放器打不开时报的是它自己的原话
    // 「Failed to open http://127.0.0.1:43617/s1.」—— 那个 `s1` 就是这里的
    // token。没有它，日志里只有一串「已交给本地中继」，事后没法把屏幕上的
    // 报错对上哪一条会话（一次播放会建多条）。
    diag.info(
      '播放',
      '已交给本地中继：会话 ${endpoint.token}，'
      '${(length / 1073741824).toStringAsFixed(2)} GiB',
    );

    // 只有「换源」（存在旧会话）才等预热：这期间**旧流还在播**，等待是白赚的；
    // 而全新开播时没有旧流垫着，等它就是白白拖慢出画。
    if (previousToken != null) {
      final ready = await warmUpRelay(relay, endpoint.token);
      diag.info('播放', ready ? '新中继已预热，关闭旧会话' : '新中继预热超时，直接切换');
    }
    await _closeRelayToken(previousToken);

    // ⚠️ 走本地中继时**不带**原请求头：里面是账号 Cookie，而接收方是本机的
    // 中继服务，它自己会在发往上游时带上。
    return _PlaybackSource(
      endpoint.uri.toString(),
      const <String, String>{},
      relayed: true,
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

  Future<void> _releaseRelay() async {
    final token = _relayToken;
    _relayToken = null;
    await _closeRelayToken(token);
  }

  /// 关掉一条指定会话（而不是「当前会话」）。见 [_prepareSource] 的换源顺序。
  Future<void> _closeRelayToken(String? token) async {
    final relay = _relay;
    if (token == null || relay == null) return;
    await relay.close(token);
  }

  /// 决定「当前应该用哪一档」。
  ///
  /// 规则本体在 [StreamTicket.pickActiveQualityId] —— **独立播放窗口那条路
  /// 也要用同一套**（主窗口取到票据后据此决定把哪一档的地址发出去），
  /// 所以判定不能留在这一层。这里只保留一个同名薄委托，让调用点不必改。
  String? _pickActiveQualityId(StreamTicket ticket, String? preferred) =>
      ticket.pickActiveQualityId(preferred);

  /// 切换清晰度。
  ///
  /// 夸克各档位流是**同一个 fid 的不同转码产物**，地址在第一次取链时就
  /// 一起拿到了（见 `QuarkPlayInfoParser`），所以这里**不需要重新取链** ——
  /// 直接换 URL 重开即可。位置与播放状态由本方法自己恢复。
  ///
  /// ⚠️ 切档会**重新选内核**（见 [_selectEngineFor]）：从原画（可能是 DV）
  /// 切到转码档要切回 media_kit，反过来则要切到 fvp。判据是同一套探测，
  /// 所以两边的行为不会漂移。
  Future<void> switchQuality(String qualityId) async {
    final ticket = _ticket;
    if (ticket == null) return;

    final q = ticket.qualityById(qualityId);
    if (q == null) {
      diag.warn('播放', '档位 $qualityId 不存在，忽略');
      return;
    }
    if (!q.isAvailable) {
      // 非致命：当前这一档还在正常播，切不过去只是没切。
      _notice = '「${q.label}」这一档服务端没有提供播放地址';
      notifyListeners();
      return;
    }

    final resumeAt = _position;
    final wasPlaying = _playing;

    diag.info(
      '播放',
      '切换清晰度 → ${q.label}（${q.id}），恢复到 ${resumeAt.inSeconds}s',
    );

    _loading = true;
    _error = null;
    _notice = null;
    notifyListeners();

    try {
      final next = ticket.withQuality(q);
      _ticket = next;
      _activeQualityId = q.id;
      // 位置**必须**交给内核的起播参数：换源后位置归零，不恢复的话用户
      // 每切一次清晰度就得自己拖回去。两个内核的下达方式不同，差异收在
      // 各自的实现里（见 [_loadIntoPlayer]）。
      //
      // ⚠️ 但那条路是**静默的**：内核没照做时不报错。所以 [_loadIntoPlayer]
      // 会顺手挂一道核对（[RestoreSeek]），位置没落到位就补一次显式 seek ——
      // 「切清晰度后从头开始播」那条反馈就是靠它兜住的。
      //
      // `keepBufferView`：同一部片子换一档，视线里的位置没变 —— 不该让缓冲层
      // 瞬间抹到 0（那看起来就是「重新缓存」）。详见 [_loadIntoPlayer]。
      await _loadIntoPlayer(next, startAt: resumeAt, keepBufferView: true);

      if (!wasPlaying) await _engine.pause();

      _loading = false;
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = '切换清晰度失败：$e';
      diag.error('播放', '切换清晰度失败：$e');
      notifyListeners();
    }
  }

  /// 重新取链（票据过期 / 播放中断时用）。
  Future<void> retry() async {
    final item = _item;
    if (item == null) return;
    await open(
      item,
      subtitles: _externalSubtitles,
      preferredQualityId: _activeQualityId,
      autoLoadSubtitles: _subtitlesEnabled,
      // 重试用的是**手标**那一份：章节那份会重新探测（票据可能换了一条流，
      // 但同一个文件章节不会变，重探一次没有坏处，还能顺带刷诊断日志）。
      introMarker: _intro.manual,
      skipIntro: _intro.enabled,
      // 重试也要带上偏好：否则「票据过期 → 重试成功」之后字幕 / 音轨会
      // 悄悄回到默认，而用户只会觉得是自己记错了。
      preference: _preference,
    );
  }

  // -------------------------------------------------------------------
  // 字幕
  // -------------------------------------------------------------------

  /// 挑一条字幕加载。**先按上次的选择，匹配不上才取第一条。**
  ///
  /// ## 为什么必须走特征匹配，而不是拿存下来的 id 直接设轨
  ///
  /// 内嵌轨的 id 是内核给**这一条流**编的号，换一集就完全不是一回事 ——
  /// 直接设 `sid=3` 的后果是「第二集挂上了一条完全不相干的字幕」（或者
  /// 干脆没挂上），而用户只看到「字幕怎么自己变了」。
  ///
  /// 匹配不上时退回「第一条」：那条的排序由 [SubtitleTrack.preferenceScore]
  /// 定好（中文优先、非强制优先、文本字幕优先），是「没记过」时最合适的默认。
  Future<void> _autoLoadSubtitle() async {
    final all = allSubtitles;
    if (all.isEmpty) return;
    final index = TrackPreference.bestIndex(
      _preference?.subtitle,
      [
        for (var i = 0; i < all.length; i++)
          TrackPreference.ofSubtitle(all[i], index: i),
      ],
    );
    await selectSubtitle(index == null ? all.first : all[index]);
  }

  /// 预取**网盘字幕**的正文。字幕菜单打开时调用。
  ///
  /// ## 为什么要预取
  ///
  /// 选中一条网盘字幕要先把字节取回来再解码（[SubtitleResolver.load]），
  /// 那是一次网络往返。把它放在「用户点下之后」，就是「点了没反应」的那一秒 ——
  /// 而播放其实**没有中断**，用户却会把它读成「切字幕要重新缓存」。
  ///
  /// 预取只是把这次往返**提前**：菜单一打开就开始取，用户浏览菜单的这几秒
  /// 通常足够；等他真点了，[selectSubtitle] 直接命中 [SubtitleResolver] 的
  /// 缓存，是瞬时的。
  ///
  /// ## ⚠️ 只预取网盘字幕
  ///
  /// **在线字幕不预取**：那条路要走字幕站的下载地址、按次计费，把菜单里
  /// 所有候选都拉一遍等于替用户烧额度（理由见 `player_window_app.dart`
  /// 在线字幕那一段）。
  ///
  /// **本地字幕也不预取**：它的正文每次都**重新读**，好让用户在外部改过
  /// 时间轴之后能生效。
  ///
  /// 失败无所谓 —— 真选中时会再试一次，那时才走 `_notice` 给用户提示。
  void prefetchCloudSubtitles() {
    for (final track in _externalSubtitles) {
      if (track.origin != SubtitleOrigin.cloudFile) continue;
      if (!_prefetching.add(track.id)) continue;
      unawaited(_prefetchOne(track));
    }
  }

  Future<void> _prefetchOne(SubtitleTrack track) async {
    try {
      await _subtitleResolver.load(track);
      diag.debug('字幕', '预取完成：${track.displayLabel}');
    } catch (e) {
      diag.debug('字幕', '预取失败（${track.displayLabel}）：$e');
    } finally {
      _prefetching.remove(track.id);
    }
  }

  /// 选中一条字幕。传 `null` 表示关闭字幕。
  Future<void> selectSubtitle(SubtitleTrack? track) async {
    if (track == null) {
      _activeSubtitleId = null;
      _subtitlesEnabled = false;
      await _engine.selectSubtitleTrack(null);
      notifyListeners();
      return;
    }

    try {
      switch (track.origin) {
        case SubtitleOrigin.embedded:
          // 内嵌轨：内核自己切轨。`id` 就是内核的轨道号。
          final id = track.embeddedTrackId;
          if (id == null) {
            // 兜底分支。正常情况下 `_onTracksChanged` 已经把「没有轨道号」
            // 的合成轨过滤掉了，走不到这里。
            _notice = '这条内嵌字幕没有轨道号，无法切换';
            notifyListeners();
            return;
          }
          await _engine.selectSubtitleTrack(id);

        case SubtitleOrigin.cloudFile:
          // 网盘字幕：我们自己取字节 + 解码成 UTF-8 文本，再交给内核。
          // 这一步同时解决了「请求头」和「GBK 编码」两个问题。
          //
          // ⚠️ 走 [PlaybackEngine.loadExternalSubtitleText] 而不是
          // 「落成临时文件再给 URI」：mdk 只吃 URI，那件事由它的实现兜底
          // （见契约里那条方法的文档）。本层不该知道临时文件的存在。
          final resolved = await _subtitleResolver.load(track);
          if (!resolved.isText) {
            throw StateError('网盘字幕应当解出文本');
          }
          await _engine.loadExternalSubtitleText(
            resolved.text!,
            title: track.displayLabel,
            language:
                track.languageCode.isEmpty ? null : track.languageCode,
          );

        case SubtitleOrigin.localFile:
          final resolved = await _subtitleResolver.load(track);
          final path = resolved.path;
          if (path == null) throw StateError('本地字幕缺少路径');
          await _engine.loadExternalSubtitle(path);
      }
      _activeSubtitleId = track.id;
      _subtitlesEnabled = true;
      _notice = null;
    } catch (e) {
      // 字幕失败**不是播放失败**：视频照常放，只是这条字幕没挂上。
      // 所以走 `_notice` 而不是 `_error` —— 后者会拉起全屏遮罩盖住画面。
      _notice = '加载字幕失败：$e';
      diag.warn('字幕', '加载失败（${track.displayLabel}）：$e');
    }
    notifyListeners();
  }

  /// 开/关字幕。
  Future<void> setSubtitlesEnabled(bool enabled) async {
    if (!enabled) {
      await selectSubtitle(null);
      return;
    }
    final all = allSubtitles;
    if (all.isEmpty) {
      _subtitlesEnabled = true;
      notifyListeners();
      return;
    }
    await selectSubtitle(all.first);
  }

  /// 追加一条本地字幕（用户从磁盘选的）。
  ///
  /// 这是**不落库**的：用户临时选的字幕只对本次播放有效。
  /// 想让它长期生效要放到网盘上（那才是本应用的索引来源）。
  Future<void> addLocalSubtitle(String path, {String? label}) async {
    final track = SubtitleTrack(
      id: 'local#${DateTime.now().microsecondsSinceEpoch}',
      origin: SubtitleOrigin.localFile,
      label: label ?? path.split(RegExp(r'[/\\]')).last,
      format: SubtitleFormatDetector.of(path),
      localPath: path,
      isExternal: true,
    );
    _externalSubtitles = [..._externalSubtitles, track];
    await selectSubtitle(track);
  }

  // -------------------------------------------------------------------
  // 播放控制
  // -------------------------------------------------------------------

  /// 切换音轨。
  ///
  /// 放在控制器上而不是让页面直接调内核：内核一旦漏给 UI，UI 就会开始绕开
  /// 「清晰度要重取链」「外挂字幕要先解码」这类业务规则，而它们恰恰是这个类
  /// 存在的理由。
  ///
  /// 不需要额外记账「当前是哪条」—— 内核自己会通过轨道流回报，
  /// 页面据此高亮即可。
  ///
  /// ⚠️ 参数是 media_kit 的 `AudioTrack`（见 [embeddedAudioTracks]），
  /// 内部只取它的**轨道号**下发给契约。
  Future<void> selectAudioTrack(mk.AudioTrack track) async {
    final id = int.tryParse(track.id);
    if (id == null) {
      // 合成轨（`auto` / `no`）不该走到这里 —— 上游 `TrackLabels.realTracks`
      // 已经把它们剔掉了。真撞上就当没点：静默失败比把声音弄没强。
      diag.warn('播放', '音轨 ${track.id} 没有轨道号，忽略');
      return;
    }
    await _engine.selectAudioTrack(id);
    diag.info('播放', '切换音轨：${track.id} ${track.title ?? ""}');
    notifyListeners();
  }

  Future<void> play() => _engine.play();

  Future<void> pause() => _engine.pause();

  /// 停止播放并**释放解码资源**。
  ///
  /// 与 [pause] 的区别是「页面已经离开」：
  ///   - `pause` 假定用户还会回来，所以保留已打开的文件、解码器和缓冲；
  ///   - `stop` 把它们全部交还，并清掉票据与轨道状态。
  ///
  /// 移动端 / Android TV 上按返回必须走这条（见 `PlaybackExitBehavior`）——
  /// 否则一个已经离开的页面还占着 4K 解码器和网络连接。
  ///
  /// **不清 `_item`**：播放页在退场动画期间还要显示标题，而 `open()`
  /// 本来就会重置全部状态。
  Future<void> stop() async {
    try {
      await _engine.stop();
    } catch (e) {
      // 停止失败不该把返回流程卡住 —— 用户已经要走了。
      diag.warn('播放', '停止播放失败：$e');
    }
    _playing = false;
    _buffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _cacheEnd = Duration.zero;
    // 停止 = 这一次播放结束了，欠账跟着作废（否则下次 open 之前的那段空窗
    // 里，位置流上任何一拍都可能触发一次指向旧目标的 seek）。
    _restore = null;
    _ticket = null;
    _activeQualityId = null;
    _activeSubtitleId = null;
    _embeddedSubtitles = const [];
    _embeddedAudio = const [];
    // 偏好与「音轨已还原」的闸一起清：这一次播放已经结束了，留着会让
    // 下一次 `open()` 之前的那段时间里，某个晚到的轨道回报按旧偏好去切轨。
    // （`open()` 本来就会重设它们，这里清是为了让「停止之后」这个状态干净。）
    _preference = null;
    _audioRestored = false;
    // 片头状态跟着一起清。**手标区间与开关不清**：它们是这一部作品的播放
    // 偏好，与「这次播放结束了」无关 —— 清了会让「退出播放页再进来」
    // 第一次不跳片头。下一次 `open()` 会拿到 UI 传来的新值覆盖它们。
    _intro.endStream();
    _completed = false;
    _error = null;
    _fileMissing = false;
    _notice = null;
    _subtitleResolver.clear();
    notifyListeners();
  }

  Future<void> playOrPause() => _engine.playOrPause();

  /// 相对跳转（方向键 / 快捷键用）。
  Future<void> seekRelative(Duration delta) => seek(_position + delta);

  /// 绝对跳转。自动夹在 `[0, duration]` 内 —— 越界的 seek 在 mpv 上
  /// 表现是「跳到一个不存在的位置然后卡住」，比不跳更糟。
  ///
  /// 夹取规则本体在 [clampSeekTarget]：**独立播放窗口也要用同一套**
  /// （它跑在另一个 Flutter 引擎里，够不到本类），两处各写一遍会漂移。
  Future<void> seek(Duration target) async {
    await _engine.seek(clampSeekTarget(target, _duration));
  }

  /// 按比例跳转（进度条点击用）。
  Future<void> seekToFraction(double fraction) {
    if (_duration <= Duration.zero) return Future.value();
    final f = fraction.clamp(0.0, 1.0);
    return seek(Duration(milliseconds: (_duration.inMilliseconds * f).round()));
  }

  Future<void> setVolume(double value) async {
    await _engine.setVolume(value.clamp(0.0, 100.0));
  }

  Future<void> setRate(double value) async {
    // 0.25x ~ 4x 是合理范围；超出会被内核静默夹住，
    // 不如我们自己夹，这样 UI 上显示的倍速与实际一致。
    await _engine.setRate(value.clamp(0.25, 4.0));
  }

  /// 切换「音效」预设。
  ///
  /// **立即生效、不用重开流**：`audio-channels` 是 mpv 的运行期可改属性，
  /// 改完 mpv 自己重配音频输出。重开流反而会把用户正在看的位置丢掉。
  ///
  /// ⚠️ `audio-spdif` **不是**这样：播放中改它对当前这条流毫无影响（实测
  /// `current-ao` 仍是 `coreaudio`、位置照常前进），它只在**开流时**参与音频链
  /// 的搭建。而且它在 macOS 上会让音频链整个建不起来、把整部片卡死 ——
  /// 详见 `PlayerAudioEffect` 的类文档，那里也解释了为什么这里不能再把
  /// 「两个属性都是运行期可改」当成一句话写。
  ///
  /// ⚠️ 与「音轨」无关，别把两者合并 —— 理由见 `PlayerAudioEffect` 的类文档。
  ///
  /// ## 换内核之后：**做不到，而且要说出来**
  ///
  /// mdk 没有 `af` / `audio-channels` 的对等物（见
  /// [EngineCapabilities.audioEffects]）。DV 片源上这个菜单点了不会有任何
  /// 效果 —— 静默无效是最难查的一类问题（用户会以为自己没设置对），
  /// 所以这里给一句明确的说明。
  Future<void> setAudioEffect(AudioEffectPreset preset) async {
    _audioEffect = preset;
    notifyListeners();

    final engine = _engine;
    if (engine is! MediaKitPlaybackEngine) {
      _showTransientNotice('杜比视界片源用的是另一个解码内核，音效暂不支持');
      return;
    }
    await PlayerAudioEffect.apply(engine.player, preset);
  }

  // -------------------------------------------------------------------
  // 内核事件绑定
  // -------------------------------------------------------------------

  final List<StreamSubscription<Object?>> _engineSubs = [];

  /// 把订阅接到 [engine] 上。**换内核时必须重新接**（见 [_selectEngineFor]）。
  void _bindEngine(PlaybackEngine engine) {
    for (final s in _engineSubs) {
      unawaited(s.cancel());
    }
    _engineSubs.clear();

    _engineSubs.add(engine.playing.listen((v) {
      if (v == _playing) return;
      _playing = v;
      notifyListeners();
    }));

    _engineSubs.add(engine.buffering.listen((v) {
      if (v == _buffering) return;
      _buffering = v;
      notifyListeners();
    }));

    _engineSubs.add(engine.position.listen((v) {
      _position = v;
      notifyListeners();
      // 起播位置的核对挂在位置流上，且**必须在 `_position = v` 之后**：
      // 它要用「内核此刻报的是哪儿」这个事实，读早了拿到的是上一拍的旧值。
      _maybeRestoreSeek(v);
      _maybeTickPosition(v);
      // 章节探测与跳片头都挂在位置流上，且**必须在 `_position = v` 之后**：
      // 两者都要用「流已经解析到哪儿了」这个事实（读早了章节是空的、
      // 位置为 0 时 seek 会被丢掉）。
      _probeChaptersOnce(v);
      _maybeSkipIntro(v);
    }));

    _engineSubs.add(engine.duration.listen((v) {
      if (v == _duration) return;
      _duration = v;
      notifyListeners();
    }));

    // 缓冲终点。契约已经统一成**绝对时间戳**（见 [_cacheEnd]），直接收下。
    _engineSubs.add(engine.bufferEnd.listen((v) {
      if (v == _cacheEnd) return;
      _cacheEnd = v;
      notifyListeners();
    }));

    _engineSubs.add(engine.volume.listen((v) {
      if ((v - _volume).abs() < 0.01) return;
      _volume = v;
      notifyListeners();
    }));

    _engineSubs.add(engine.rate.listen((v) {
      if ((v - _rate).abs() < 0.001) return;
      _rate = v;
      notifyListeners();
    }));

    // 内嵌轨列表：内核解完文件头之后才可用，因此这是**流**而不是一次性查询。
    _engineSubs.add(engine.tracks.listen(_onTracksChanged));

    // 播完了。自动连播的触发信号。
    //
    // ⚠️ 只在**上升沿**触发：`completed` 是状态流（一次播完之后一直为 true，
    // 直到下一次换源才复位）。不过滤的话，每来一次重复回报都会调一遍
    // 「找下一集」——最后一集播完时那是空转，而中间集数则会在 open 生效前被
    // 调两次（第二次数到的「当前集」还是旧的，于是同一集被连播两遍的错觉）。
    _engineSubs.add(engine.completed.listen((v) {
      if (v == _completed) return;
      _completed = v;
      notifyListeners();
      if (v) onCompleted?.call();
    }));

    // 播放错误。契约**原样转发**内核的报错（过滤是上层的事，见契约的文档），
    // 所以关键词过滤与字幕分流都在这里。
    _engineSubs.add(engine.error.listen(_onEngineError));

    // ⚠️ 字幕那条**只能靠日志流**：media_kit 只把特定 prefix 的 error 转发到
    // `error`（`file` / `ffmpeg`（text 必须以 `tcp:` 开头）/ `vd` / `ad` /
    // `cplayer` / `stream`），而报字幕解码失败的是 `sd_lavc` —— 不在白名单里。
    // 所以上面那条监听**永远收不到**它，别因为「已经监听了 error」就把这里删掉。
    //
    // 代价只有一条 warn 级订阅；实际每条字幕轨最多出一条。
    // （mdk 没有日志流，见 `EngineCapabilities.rawLog` —— 这条订阅在那里
    // 永远收不到东西，不是 bug。）
    _engineSubs.add(engine.log.listen((text) {
      if (!isSubtitleDiagnosticLog(text)) return;
      diag.warn('播放', '内核字幕日志：$text');
    }));
  }

  /// 核对「换源时要求的起播位置到底生效了没有」，必要时补一次显式 seek。
  ///
  /// ## 它补的是什么洞
  ///
  /// 起播位置只能走内核的起播参数（`EngineMedia.startAt`）—— 「open 之后再
  /// seek」会被丢掉。但那条路是**一次静默的尝试**：内核收下了却没照做时，
  /// 没有任何回调会报错。实测的用户反馈正是「选择画质后都会重头就开始
  /// 播放」，而日志里「起播=1800s」那一行看着完全正常。
  ///
  /// 判据与「什么时候才敢补」全部在 [RestoreSeek] 里（纯状态机，可单测）。
  /// 这里只负责三件事：喂位置、执行 seek、写诊断。
  void _maybeRestoreSeek(Duration position) {
    final pending = _restore;
    if (pending == null) return;

    switch (pending.observe(position, _duration)) {
      case RestoreSeekAction.wait:
        return;

      case RestoreSeekAction.settle:
        diag.info(
          '播放',
          '起播位置已就位：${position.inSeconds}s'
          '（补发 ${pending.attempts} 次）',
        );
        _restore = null;

      case RestoreSeekAction.seek:
        final target = pending.target;
        // ⚠️ 这条日志是**下一次排查的唯一入口**：它把「内核没照做」这件事
        // 变成了可观测的。只有它出现在日志里，才说明 `startAt` 真的失效过。
        diag.info(
          '播放',
          '起播位置没生效（现在 ${position.inSeconds}s，'
          '应为 ${target.inSeconds}s）→ 补发 seek（第 ${pending.attempts} 次）',
        );
        // 夹取复用公开的 [seek]（越界 seek 在 mpv 上会卡死，见
        // `clampSeekTarget`）。此刻时长多半已经解出来了，所以上界也能夹住。
        unawaited(seek(target));
    }
  }

  void _onEngineError(String msg) {
    // ⚠️ 字幕解码失败**必须先分流**：它不是「这条链播不了」，而是
    // 「本机内核解不开这种字幕」。掉进下面那行会被 `_error ??=` 记成播放
    // 错误（用户会看到「播放器报错」的横幅，而画面其实好好的），
    // 而且这句话不含 `failed`/`error`，本来就会被关键词过滤丢掉 ——
    // 两头都不落好。
    if (isSubtitleDiagnosticLog(msg)) {
      diag.warn('播放', '内核字幕日志：$msg');
      return;
    }
    final lower = msg.toLowerCase();
    if (!lower.contains('failed') && !lower.contains('error')) return;
    diag.warn('播放', '内核报错：$msg');
    _error ??= '播放器报错：$msg';
    notifyListeners();
  }

  /// 进度存档节流。
  ///
  /// `position` 是每 ~100ms 一条的高频流，不能每条都写库。
  /// 用「整十秒边界」当触发条件：天然节流，且不需要额外的计时器。
  int _lastTickSecond = -1;

  void _maybeTickPosition(Duration v) {
    final interval = _positionSaveInterval.inSeconds;
    if (interval <= 0) return;
    final second = v.inSeconds;
    if (second <= 0) return;
    if (second % interval != 0) return;
    if (second == _lastTickSecond) return;
    _lastTickSecond = second;
    onPositionTick?.call(v);
  }

  /// 探测一次文件章节（认出片头就存起来）。
  ///
  /// ## 触发条件是 `position > 0`，不是 `open()` 返回
  ///
  /// `open()` 只把请求投进内核的命令队列，**不等文件加载完成**。
  /// 那一刻读章节拿到的是空的 —— 与「这个文件没章节」完全无法区分。
  /// `position` 变成正数说明解复用器已经跑起来了，容器头一定解析完了。
  ///
  /// 判据本体在 [IntroSession.shouldProbe]（两个播放器共用），这里只负责
  /// 「先置位、再起异步任务」这个顺序。
  void _probeChaptersOnce(Duration position) {
    if (!_intro.shouldProbe(position)) return;
    // 先置位再 await：见 `IntroSession.markProbed` 的文档。
    _intro.markProbed();
    unawaited(_probeChapters());
  }

  Future<void> _probeChapters() async {
    final label = _item?.displayTitle ?? '';
    // 章节的**读法**两个内核不同（mpv 读属性 / mdk 查 MediaInfo），但都由
    // 契约的 `chapters()` 收口；而**认片头**与那几条诊断日志只有一份
    // （`IntroMarkerDetector.detectAndLog`）。
    final marker = IntroMarkerDetector.detectAndLog(
      IntroMarkerDetector.fromEngineChapters(await _engine.chapters()),
      label: label,
    );
    if (marker == null) return;
    // 探测期间用户可能已经换集 / 退出（`open` 会把章节清成 null 并换掉
    // `_item`）。晚到的结果写进去会让**下一集**顶着这一集的片头区间跳 ——
    // 一个只有网络慢时才复现的怪 bug。
    if (_item?.displayTitle != label) return;
    _intro.setChapter(marker);
    notifyListeners();
  }

  /// 播放头进了片头区间就跳过去。判定本体在 [IntroSession.takeSkipTarget]。
  void _maybeSkipIntro(Duration position) {
    final target = _intro.takeSkipTarget(position);
    if (target == null) return;
    diag.info('片头', '跳过片头：${position.inSeconds}s → ${target.inSeconds}s');
    _showTransientNotice('已跳过片头 ${(target - position).inSeconds} 秒');
    // 直接走内核，不再过 `seek()` 的 `clampSeekTarget`：区间的终点已经由
    // `IntroMarkerDetector` 的时长上界保证落在片内（见 `maxLength`），
    // 再夹一次只是多一层没必要的不透明性。
    unawaited(_engine.seek(target));
  }

  void _onTracksChanged(EngineTracks tracks) {
    // 契约里的轨道清单**已经过滤过合成轨**（media_kit 那两条 `auto` / `no`
    // 由 `MediaKitPlaybackEngine.mapTracks` 剔掉，mdk 给的本来就是真轨道号），
    // 所以这里不再需要 `TrackLabels.realTracks` 那一道。
    final embeddedSubs = <SubtitleTrack>[];
    for (var i = 0; i < tracks.subtitle.length; i++) {
      final t = tracks.subtitle[i];
      embeddedSubs.add(
        SubtitleTrack(
          id: 'embedded#${t.id}',
          origin: SubtitleOrigin.embedded,
          label: _labelForEmbedded(
            t.title,
            t.language,
            '内嵌字幕 ${i + 1}',
          ),
          format: SubtitleFormatDetector.of(t.title ?? ''),
          embeddedTrackId: t.id,
          language: _languageFromTag(t.language),
          isDefault: t.isDefault,
        ),
      );
    }

    final embeddedAudio = <mk.AudioTrack>[
      for (final t in tracks.audio) TrackBridge.audio(t),
    ];
    final videoCount = tracks.video.length;

    final changed = embeddedSubs.length != _embeddedSubtitles.length ||
        embeddedAudio.length != _embeddedAudio.length;
    _embeddedSubtitles = embeddedSubs;
    _embeddedAudio = embeddedAudio;
    if (!changed) return;

    diag.info(
      '播放',
      '内嵌轨更新：字幕 ${embeddedSubs.length} 条、'
      '音轨 ${embeddedAudio.length} 条、视频 $videoCount 条',
    );
    notifyListeners();

    // 内嵌字幕往往比外挂字幕晚一步出现，自动选择要再来一次 ——
    // 否则用户看到的初始状态是「没字幕」，得手动去点。
    if (_subtitlesEnabled && _activeSubtitleId == null) {
      unawaited(_autoLoadSubtitle());
    }

    // 音轨同理：内嵌音轨清单也是**流式**出现的，第一次回报时可能还没有
    // （那时 `_embeddedAudio` 是空的，匹配无从谈起）。
    _maybeRestoreAudio();
  }

  /// 按偏好把音轨切到用户上次选的那一条。**每次播放只尝试一次。**
  ///
  /// ## 为什么不做「重试到匹配上为止」
  ///
  /// 匹配不上就说明**这一集没有那条轨**（换了一集、或者换了个片源版本）。
  /// 反复重试只会每来一次轨道回报就翻一次菜单高亮，而结果永远是失败 ——
  /// 所以不管成没成，闸都落下。
  ///
  /// ## 为什么没有偏好时**什么都不做**
  ///
  /// 那是「用户从没在这部片上选过音轨」，正确行为是让内核用它自己的默认
  /// （通常是发布者标记为 default 的那条）。我们自己挑第一条反而会**盖掉**
  /// 那个更权威的选择。
  void _maybeRestoreAudio() {
    if (_audioRestored) return;
    final pref = _preference?.audio;
    if (pref == null) return;
    final tracks = _embeddedAudio;
    if (tracks.isEmpty) return;

    _audioRestored = true;
    final index = TrackPreference.bestIndex(
      pref,
      [
        for (var i = 0; i < tracks.length; i++)
          _audioPreferenceOf(tracks[i], index: i),
      ],
    );
    if (index == null) {
      diag.info('播放', '音轨偏好没匹配上（候选 ${tracks.length} 条），沿用播放器默认');
      return;
    }
    final id = int.tryParse(tracks[index].id);
    if (id == null) return;
    diag.info('播放', '按上次的选择还原音轨：${tracks[index].id}');
    // 这里直接走内核而不是 `selectAudioTrack`：后者会 `notifyListeners()`，
    // 而本方法跑在 `tracks` 的回调里 —— 在回调里触发重建是最容易踩到
    // 「重入」的地方。内核自己会通过选中轨流回报，UI 照样会更新。
    unawaited(_engine.selectAudioTrack(id));
  }

  /// 把 media_kit 的音轨对象摊成可匹配特征。
  ///
  /// 与 `TrackPreference.ofSubtitle` 分开写：那边吃的是领域实体
  /// `SubtitleTrack`，这边吃的是 media_kit 的类型，而领域实体不该反向依赖
  /// media_kit。
  static TrackPreference _audioPreferenceOf(
    mk.AudioTrack track, {
    required int index,
  }) =>
      TrackPreference(
        trackId: track.id,
        language: track.language,
        title: track.title,
        index: index,
      );

  /// 只保留**真实存在的轨道**，剔除 media_kit 硬塞进来的合成轨。
  ///
  /// 实现委托给 `TrackLabels.realTracks` —— 独立播放窗口要用同一条规则
  /// （它拿不到这个控制器），拆成两份必然走样。
  @visibleForTesting
  static List<T> realTracksOf<T>(Iterable<T> tracks, String Function(T) idOf) =>
      TrackLabels.realTracks(tracks, idOf);

  static String _labelForEmbedded(
    String? title,
    String? language,
    String fallback,
  ) {
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return t;
    return _languageFromTag(language)?.label ?? fallback;
  }

  /// 把内核给的语言标记（`chi` / `zho` / `zh` / `eng`）映射成我们的语言对象。
  static SubtitleLanguage? _languageFromTag(String? tag) {
    if (tag == null || tag.trim().isEmpty) return null;
    final t = tag.trim().toLowerCase();
    const table = {
      'chi': SubtitleLanguage(code: 'zh', label: '中文'),
      'zho': SubtitleLanguage(code: 'zh', label: '中文'),
      'zh': SubtitleLanguage(code: 'zh', label: '中文'),
      'chs': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
      'cht': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
      'eng': SubtitleLanguage(code: 'en', label: '英文'),
      'en': SubtitleLanguage(code: 'en', label: '英文'),
      'jpn': SubtitleLanguage(code: 'ja', label: '日文'),
      'ja': SubtitleLanguage(code: 'ja', label: '日文'),
      'kor': SubtitleLanguage(code: 'ko', label: '韩文'),
      'ko': SubtitleLanguage(code: 'ko', label: '韩文'),
    };
    return table[t] ?? SubtitleLanguage(code: t, label: t);
  }

  /// 把 [DriveException] 翻成用户能看懂、且**能据此行动**的话。
  static String _explain(DriveException e) => switch (e.type) {
        DriveErrorType.unauthorized => '登录已失效，请重新扫码登录夸克账号',
        DriveErrorType.notFound => '文件不存在或已被删除（可能网盘侧删掉了）',
        DriveErrorType.fileTooLarge =>
          '夸克拒绝了取链：该文件超出了所有取链路由的体积限制',
        DriveErrorType.rateLimited => '请求过于频繁，请稍后重试',
        DriveErrorType.network => '网络不可用，请检查网络连接',
        _ => e.message,
      };

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    for (final s in _engineSubs) {
      unawaited(s.cancel());
    }
    _engineSubs.clear();
    unawaited(_releaseRelay());
    unawaited(_router.dispose());
    super.dispose();
  }
}

/// 交给内核的最终地址：可能是网盘直链，也可能是本地中继。
///
/// 拆成类型而不是返回 `MapEntry`：调用点上看 `source.url` / `source.headers`
/// 比 `entry.key` / `entry.value` 清楚，而这类「两个值一起换、漏一个就出事」
/// 的组合正是最该让名字说话的地方 —— 漏换 headers 的表现是「走本地中继
/// 却被要求带 Cookie」，而 412 的错误信息里根本看不出是头的问题。
class _PlaybackSource {
  const _PlaybackSource(this.url, this.headers, {this.relayed = false});

  final String url;

  /// 播放器要带的请求头。**走本地中继时它必须是空的。**
  final Map<String, String> headers;

  /// 这条地址是不是**本地中继**的入口，而不是网盘直链。
  ///
  /// 只用于诊断日志，但必须是**显式的一位**而不是「拿 URL 猜是不是
  /// `127.0.0.1`」：播放器报 `Failed to open http://127.0.0.1:PORT/sN.` 时，
  /// 日志要能直接说出「内核拿到的是中继地址」；靠猜在将来加了别的本地代理
  /// 之后就会说谎，而「日志说谎」比没有日志更坏。
  final bool relayed;
}

/// 从文件名猜字幕格式（用于本地字幕与内嵌轨标签）。
///
/// 单独一个小类而不是直接调 `SubtitleFormats.formatOf`：那个方法吃的是
/// **文件名**，而内嵌轨的 `title` 经常是 `Chinese` / `简体` 这类没有扩展名
/// 的字符串，需要在这里退化成「按内容标记猜」。
class SubtitleFormatDetector {
  const SubtitleFormatDetector._();

  static SubtitleFormat of(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('ass')) return SubtitleFormat.ass;
    if (lower.contains('ssa')) return SubtitleFormat.ssa;
    if (lower.contains('vtt')) return SubtitleFormat.vtt;
    if (lower.contains('pgs') || lower.contains('sup')) {
      return SubtitleFormat.pgs;
    }
    return SubtitleFormat.srt;
  }
}
