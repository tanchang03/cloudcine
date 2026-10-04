import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/diagnostics/resource_probe.dart';
import '../../core/utils/mpv_cache_state.dart';
import '../../core/utils/mpv_chapters.dart';
import '../../core/utils/player_buffer_config.dart';
import '../../core/utils/player_subtitle_config.dart';
import '../../core/utils/track_labels.dart';
import '../../domain/services/intro_marker.dart';
import '../../domain/services/playback_engine.dart';
import '../../domain/services/playback_media.dart';
import 'change_gate.dart';

/// 视频管线诊断：这一拍该发日志、跳过，还是收工。
enum VideoProbeAction {
  /// 还没到点（或者解码器还没起来）—— 什么都不做。
  skip,

  /// 读一次属性并发一条日志。
  sample,

  /// 这一轮问完了，把定时器停掉。
  stop,
}

/// 决定视频管线探针的下一拍干什么。
///
/// ## 为什么把它抽成纯函数
///
/// 这段判断有两条**错了不报错、只会静静把排查带偏**的规则：
///
///   1. **`hwdec-current` 在 `loadfile` 之后的一小段里是空串**（解码器还没
///      起来）。把它当成「软解」会得出「硬解没生效」的结论，而实际上它
///      下一秒就起来了 —— 用户会照着这个假结论去改一堆没用的参数。
///      所以第一拍必须**等到非空**才发。
///   2. **采样必须跨越整段播放**。旧策略只发两拍（约第 6s / 第 27s），
///      而用户报的是「**全程**不流畅」—— 只测起播那 30 秒，读数全是 0，
///      于是得出「没有掉帧」的假结论，把排查方向整个带偏（10-04 就栽在
///      这里）。现在改成「每 [sampleEveryTicks] 拍发一条，直到 [maxTicks]」。
///
/// 探针本身要真的 mpv 才能跑（单测里起不来），所以把**判断**与**读属性**
/// 拆开：判断在这里，读属性在调用方。
@visibleForTesting
VideoProbeAction nextVideoProbeAction({
  required int ticks,
  required int samples,
  required bool decoderReady,
  int maxTicks = 120,
  int maxSamples = 16,
  int sampleEveryTicks = 7,
}) {
  if (samples == 0) {
    // 30 秒还等不到解码器就不再等：要么这条流没有视频轨（纯音频），
    // 要么硬解根本没起来 —— 两种都值得留一行（见调用方的 warn）。
    if (ticks >= 10) return VideoProbeAction.stop;
    return decoderReady ? VideoProbeAction.sample : VideoProbeAction.skip;
  }
  if (ticks > maxTicks || samples >= maxSamples) return VideoProbeAction.stop;
  // 每隔 sampleEveryTicks 拍（默认 7 × 3s = 21s）发一条，一直发到 6 分钟。
  return ticks % sampleEveryTicks == 0
      ? VideoProbeAction.sample
      : VideoProbeAction.skip;
}

/// media_kit（mpv）引擎。**默认内核**，除杜比视界以外的片源全走这里。
///
/// ## 这一份的职责是「原样包一遍」
///
/// 它**不引入任何新行为**：参数、默认值、裁剪范围、过滤规则全部照抄
/// `PlaybackController` 迁移之前的写法。理由很实际 —— 默认内核承担着
/// 100% 的既有片源，任何「顺手优化」都会变成一次全量回归。
///
/// 唯一真正新增的是 [networkSpeed] 的 1 Hz 轮询：那段逻辑原来长在
/// `player_window_app.dart` 里（`_startNetSpeedPolling`），契约要求它属于
/// 引擎，所以搬过来 —— 解析仍走同一个 [rawInputBytesPerSecond]，
/// 没有第二份实现。
///
/// ## 能力：最全，但 macOS 上渲染不了 DV
///
/// 见 [EngineCapabilities.mediaKit]。mpv 支持音效滤镜（`af` / `audio-channels`）、
/// 实时输入速率、原始日志流 —— 这些在 mdk 上都没有对等物。
///
/// ⚠️ 但 macOS 上 media_kit 走的是 mpv 的 **render API**（`vo=libmpv`），
/// `render_backends[]` 只有 `gpu` / `sw`，`vo=gpu-next` 架构上不可达 ——
/// 所以 DV Profile 5 在这条路上**不可能**渲染正确。这正是按需路由的理由。
///
/// ## 归属：本类**拥有** Player 与 VideoController
///
/// 两者都在构造函数里建出来，[dispose] 负责销毁。这是刻意的 ——
/// 与 [FvpPlaybackEngine] 对称，调用方不必记住「哪个引擎的东西要自己回收」。
///
/// [player] 仍然对外暴露，因为有几个 mpv **专有**能力不走契约：
/// 音效（`PlayerAudioEffect.apply`）与缓冲调优（`PlayerBufferConfig.apply`）。
/// 契约里没有它们是因为 mdk 没有对等物（[EngineCapabilities.audioEffects]
/// / [EngineCapabilities.rawProperty] 都是 false），不是因为它们不该被调用。
class MediaKitPlaybackEngine implements PlaybackEngine {
  /// [tv] 决定缓冲参数与上限。判据由调用方给（`isTvDevice()`）——
  /// 引擎不该自己去猜平台，那是可以注入的、能测的输入。
  ///
  /// [verboseLog] 把 mpv 的日志级别抬到 `warn`。
  ///
  /// ## ⚠️ 只有独立播放窗口需要它，而且是**必要条件**
  ///
  /// 抬高之后 `log` 流才会带上 `http: HTTP error 4xx`（实测是 **warn** 级，
  /// 而 media_kit 默认只请求 `error`）。独立窗口的「直链过期 → 自动重新取链」
  /// 全靠这一条，缺了它用户实际会遇到的那种过期**一次都检测不到**。
  /// 完整实测记录见 `player_protocol.dart` 的 `isHttp4xxLog`。
  ///
  /// 内置播放页**不开**（保持默认 `error`）：它没有那条过期检测，
  /// 而 warn 级会把字幕诊断之外的一堆噪音也放进日志缓冲。
  MediaKitPlaybackEngine({bool tv = false, bool verboseLog = false})
      : _player = mk.Player(
          configuration: mk.PlayerConfiguration(
            logLevel: verboseLog ? mk.MPVLogLevel.warn : mk.MPVLogLevel.error,
            // TV 上换一套更小的缓冲：桌面那套（1 GB + 无限预读）在电视盒子上
            // 会把内存和 eMMC 写满，实测表现就是卡帧 + 音画不同步。
            // 判据与理由都在 `PlayerBufferConfig` 的类文档里。
            bufferSize: PlayerBufferConfig.bufferSizeFor(tv: tv),
            // ⚠️ 必须给：缺了它 media_kit 会把 `sub-visibility` 设成 `no`，
            // **所有**字幕都不显示且不报错。原因见 `PlayerSubtitleConfig`。
            libass: PlayerSubtitleConfig.useLibass,
          ),
        ) {
    // 渲染控制器**必须**绑定到上面那个 player，且必须在任何 `open()` 之前
    // 建出来。
    //
    // 这里曾经写的是 `VideoController(mk.Player())` —— 一个**新建的**实例。
    // 于是「解码」和「出画面」落在两个互不相干的 mpv 实例上：player 照常
    // 解码音频（有声音、进度条正常），但它从来没有视频输出端，画面永远是
    // 空的，而且**不报任何错**。实测症状：mp4 4K 只有声音没画面。
    videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // 让 mpv 在已知有问题的驱动上自动退回软解，比强制硬解稳。
        enableHardwareAcceleration: true,
        // ⚠️ 这一项**必须与 `PlayerBufferConfig.apply` 同值**：两处都会给 mpv
        // 设 `hwdec`，而 `apply` 在本构造函数之后跑 —— 只改一处的话，
        // 另一处会在几百毫秒后把它覆盖掉，表现是「改了没生效」。
        // 取值与理由（为什么是 `mediacodec,auto-safe` 这个列表）都在
        // `PlayerBufferConfig.tvHwdec` 的文档里。桌面拿到 null = 不下发。
        hwdec: PlayerBufferConfig.hwdecFor(tv: tv),
      ),
    );
    _bindStreams();
    // 补 media_kit 构造参数管不到的 mpv 缓冲属性（demuxer-readahead-secs）。
    // setProperty 内部等播放器初始化完成再设，不需要在这里同步等待。
    unawaited(PlayerBufferConfig.apply(_player, tv: tv));
  }

  final mk.Player _player;
  bool _disposed = false;

  /// mpv 播放器实例。
  ///
  /// ⚠️ 暴露它是**刻意的例外**：音效与缓冲调优是 mpv 专有能力，
  /// 契约里没有（mdk 无对等物）。别拿它去绕开契约 —— 起播、切轨、字幕
  /// 一律走本类的方法，否则业务规则（清晰度要重取链、外挂字幕要先解码）
  /// 会被绕过。
  mk.Player get player => _player;

  /// 交给 UI 的渲染句柄（`Video(controller: ...)`）。
  ///
  /// ⚠️ 领域层的契约**故意不带这个方法**（领域层不引 Flutter）。
  /// UI 层按引擎的具体类型决定用哪个渲染组件，见
  /// `ui/widgets/playback_surface.dart`。
  late final VideoController videoController;

  @override
  EngineCapabilities get capabilities => EngineCapabilities.mediaKit;

  // -------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _bufferEnd = StreamController<Duration>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _rate = StreamController<double>.broadcast();
  final _tracks = StreamController<EngineTracks>.broadcast();
  final _activeAudio = StreamController<int?>.broadcast();
  final _activeSubtitle = StreamController<int?>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _log = StreamController<String>.broadcast();
  final _videoSize = StreamController<EngineVideoSize>.broadcast();
  final _bufferingPercentage = StreamController<double>.broadcast();
  final _networkSpeed = StreamController<double>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;

  /// ⚠️ **直接转发**，不做换算。
  ///
  /// mpv 的 `demuxer-cache-time`（media_kit 的 `player.stream.buffer`）本来
  /// 就是**绝对时间戳**，与契约要求的参照系一致 —— 所以这里**不能**再调
  /// [EngineTimeRange.cacheEndAt]。那个换算点是给 mdk 的「区间列表」用的，
  /// 套到 mpv 的标量上会变成「拿一个数字去找包含它的区间」，语义完全错位。
  @override
  Stream<Duration> get bufferEnd => _bufferEnd.stream;

  @override
  Stream<double> get volume => _volume.stream;
  @override
  Stream<double> get rate => _rate.stream;
  @override
  Stream<EngineTracks> get tracks => _tracks.stream;
  @override
  Stream<int?> get activeAudioTrackId => _activeAudio.stream;
  @override
  Stream<int?> get activeSubtitleTrackId => _activeSubtitle.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;
  @override
  Stream<String> get log => _log.stream;
  @override
  Stream<EngineVideoSize> get videoSize => _videoSize.stream;
  @override
  Stream<double> get bufferingPercentage => _bufferingPercentage.stream;
  @override
  Stream<double> get networkSpeed => _networkSpeed.stream;

  // 值没变就不发。规则本体见 [ChangeGate]。
  final _gPlaying = ChangeGate<bool>();
  final _gBuffering = ChangeGate<bool>();
  final _gPosition = ChangeGate<Duration>();
  final _gDuration = ChangeGate<Duration>();
  final _gBufferEnd = ChangeGate<Duration>();
  final _gVolume = ChangeGate<double>();
  final _gRate = ChangeGate<double>();
  final _gTracks = ChangeGate<String>();
  final _gActiveAudio = ChangeGate<int?>();
  final _gActiveSubtitle = ChangeGate<int?>();
  final _gCompleted = ChangeGate<bool>();
  final _gError = ChangeGate<String>();
  final _gVideoSize = ChangeGate<EngineVideoSize>();
  final _gBufferingPercentage = ChangeGate<double>();
  final _gNetworkSpeed = ChangeGate<double>();

  // -------------------------------------------------------------------
  // 命令
  // -------------------------------------------------------------------

  @override
  Future<void> open(EngineMedia media, {bool play = true}) async {
    if (_disposed) return;
    _resetGates();

    // ⛔ 这三步的**顺序是根因修复**，别调换、别删：
    //   1. 等视频 Surface 挂上（media_kit 在此之前把 vo 设成 null）；
    //   2. 补一次 `hwdec`，让它是 mpv 收到的**最后一次**写；
    //   3. 才 `loadfile` —— 解码器这时才定型，零拷贝才配得上。
    // 完整根因（含源码行号与真机证据）见 [_awaitVideoSurface]。
    await _awaitVideoSurface();
    await _reapplyHwdec();

    // ⚠️ 起播位置走 `Media(start:)` 而**不是**「open 之后再 seek」。
    //
    // media_kit 把 `start` 落成「在 mpv 的 `on_load` 钩子里设 start 属性」，
    // 而 `Player.open()` **不等**文件加载完成（它只发 `loadlist`），紧跟的
    // 一次 `seek` 落在解复用器就绪之前就被丢掉 —— 那正是本项目「续播点了
    // 没用、每次都从头开始」的根因。实测记录（含 HLS）见 [PlaybackMedia]。
    //
    // 同理 `start` 会**残留**：mpv 不会在加载完之后清掉它，所以不续播时也
    // 必须显式写 0（`PlaybackMedia.build` 的 `startAt` 默认值就是
    // `Duration.zero`，不给 null 的唯一原因）。
    await _player.open(
      PlaybackMedia.build(
        media.url,
        headers: media.headers,
        startAt: media.startAt,
      ),
      play: play,
    );
    _startNetSpeedPolling();
    // 起播后量一拍视频管线（实际解码器 + 丢帧数）—— 理由见那个方法的文档。
    // 它读的是 mpv 属性，不改变任何播放行为。
    _startVideoPipelineProbe();
    // 同时开始量这台机器的资源（CPU / 内存 / 磁盘）。理由见 [ResourceProbe]：
    // 视频探针只说「丢没丢帧」，说不出「为什么」。
    _resourceProbe.start();
    // 核对「零拷贝到底配上没有」；没配上就再逼 mpv 解析一次。
    // 这是第 1 步超时那条路的兜底，同时**把结果写进诊断日志**。
    unawaited(_verifyZeroCopyHwdec());
  }

  // -------------------------------------------------------------------
  // 硬解：让 mpv 在「Surface 已挂上」之后才定型解码器
  // -------------------------------------------------------------------

  /// 起播后允许「重建解码器」的时间窗。
  ///
  /// 重建有一瞬间的顿挫，放在片头无所谓；放到正片中间就成了新的「卡顿」，
  /// 用户会以为是没修好。所以过了这个窗口就只读不写。
  static const Duration hwdecKickWindow = Duration(seconds: 20);

  /// 起播后**要不要**再逼 mpv 重建一次解码器。
  ///
  /// 三个条件缺一不可，抽成纯函数是因为它们各自都能单独写错：
  ///
  ///   * `hwdecCurrent` 为空串 = 解码器还没起来。**空串不是拷贝档** ——
  ///     把它算进去会在起播那一瞬间误判成「退回拷贝」并触发一次没必要的重建。
  ///   * 必须真的落在**拷贝档**：直通已经生效时这条检查必须一个字节都不改。
  ///   * 必须还在 [hwdecKickWindow] 内（理由见上）。
  @visibleForTesting
  static bool shouldKickHwdec({
    required String hwdecCurrent,
    required Duration position,
  }) =>
      hwdecCurrent.isNotEmpty &&
      PlayerBufferConfig.isCopyHwdec(hwdecCurrent) &&
      position <= hwdecKickWindow;

  static const Duration _surfaceWaitInterval = Duration(milliseconds: 20);

  /// 等 Surface 的**上限拍数**：20ms × 100 = 2 秒。
  static const int _surfaceWaitTicks = 100;

  /// Surface 刚挂上后再让一小段，等 `widListener` 把 `vo` 换回 `gpu`。
  static const Duration _surfaceSettle = Duration(milliseconds: 120);

  /// 等 Android 的 `Surface` 挂上再 `loadfile` —— **4K 走不走零拷贝全看这一步**。
  ///
  /// ## 根因（10-04 定位到源码行）
  ///
  /// media_kit 的 `AndroidVideoController.create()` 跑在**首帧之后的
  /// post-frame 回调**里（`media_kit_video/src/video_controller/video_controller.dart`），
  /// 而它一上来就在**同一批**里写 `vo=null` 与 `hwdec`
  /// （`android_video_controller/real.dart:191-205`，注释写着「必须先把
  /// vo 设成 null 才不会 SIGSEGV」）。
  ///
  /// mpv 的零拷贝 `mediacodec` **要求 VO 能交出 Android surface**。`vo=null`
  /// 时它配不上，逗号列表于是**静默**退回 `mediacodec-copy` —— 而这个选择
  /// 会跟着整条流：之后 Surface 到位，`widListener` 只重建 `vo`
  /// （`real.dart:59-65`），**从不重设 `hwdec`**。
  ///
  /// 我们原来在构造函数之后立刻 `open()`，`loadfile` 几乎总抢在 `create()`
  /// 前面 —— 解码器在「没有 VO」的状态下定型。真机日志两条独立证据：
  ///
  ///   * `hwdec-current` 恒为 `mediacodec-copy`（`[解码]` / `[硬解]` 行）；
  ///   * `widListener` 里那句 `seek(Duration.zero)` 把起播位置冲成 0
  ///     （`起播位置没生效（现在 0s，应为 434s）→ 补发 seek`）。
  ///
  /// ## 判据为什么能用 `rect`
  ///
  /// Java 侧 `VideoOutput` 每次表面变化都发一条 `VideoOutput.Resize`；Dart
  /// 侧在**同一个回调里**同时写 `rect` / `id` / `wid`（`real.dart:267-269`）。
  /// `wid` 是私有字段，而 `rect` 通过 [VideoController.rect] **公开**暴露 ——
  /// 所以「`rect` 变成非 null」就是「Surface 已挂上」的公开判据，不必
  /// `import 'package:media_kit_video/src/...'`。
  ///
  /// ## 边界
  ///
  ///   * **只在 Android 上等**：`rect` 在别的平台由另一条路填，等它只会给
  ///     起播平白加两秒。
  ///   * 等不到就照旧 `open()` —— 最坏情况等于改之前，不会更差。
  ///   * 音频流同样会收到 `VideoOutput.Resize`（它由表面变化触发，与有没有
  ///     视频轨无关），所以这条等待不会给音频流加几秒。
  Future<void> _awaitVideoSurface() async {
    if (_disposed) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    if (videoController.rect.value != null) return;

    for (var i = 0; i < _surfaceWaitTicks; i++) {
      await Future<void>.delayed(_surfaceWaitInterval);
      if (_disposed) return;
      if (videoController.rect.value == null) continue;
      // Surface 刚挂上，但 `widListener` 还要把 `vo` 换回 `gpu`（它内部是
      // 一串异步 setProperty）。多让一小段，确保 `vo=gpu` 排在我们的
      // `hwdec` **之前** —— 顺序反了就等于没改。
      await Future<void>.delayed(_surfaceSettle);
      if (_disposed) return;
      diag.info('硬解', '视频 Surface 已就绪，避开 vo=null 那次解析后重发 hwdec');
      return;
    }
    diag.warn(
      '硬解',
      '等视频 Surface 超时（${_surfaceWaitTicks * _surfaceWaitInterval.inMilliseconds}ms）'
          '—— 按原样起播，hwdec 可能仍退回拷贝档',
    );
  }

  /// 把 `hwdec` 再写一遍，让它成为 mpv 收到的**最后一次**写。
  ///
  /// 构造函数里的 `VideoControllerConfiguration.hwdec` 与
  /// `PlayerBufferConfig.apply` 都写过这一项，但两者都排在 media_kit 的
  /// `create()`（`vo=null` + `hwdec`）**之前**。等 Surface 就绪后再写一次，
  /// mpv 在 `loadfile` 建解码器时看到的才是「vo=gpu + 真 Surface」。
  ///
  /// 读回当前值再写，而不是按 `tv` 推：`apply` 是 `unawaited` 的，读回才是
  /// 「mpv 此刻真正拿着什么」，也不会与那两处的取值跑偏。
  Future<void> _reapplyHwdec() async {
    final platform = _player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      final target = (await platform.getProperty('hwdec')).trim();
      if (_disposed || target.isEmpty) return;
      await platform.setProperty('hwdec', target);
    } catch (_) {
      // 读不到 / 写不进都不该影响起播：最坏就是退回拷贝档。
    }
  }

  /// 起播后核对「零拷贝到底配上没有」；没配上就**再逼 mpv 解析一次**。
  ///
  /// 这是 [_awaitVideoSurface] 的兜底：万一 Surface 比 `loadfile` 还晚
  /// （走了超时那条路），解码器已经定型在拷贝档，只能让它重建。
  ///
  /// ## 为什么要「改一次再改回来」
  ///
  /// mpv 只在 `hwdec` **变化**时重建解码器；写一个与当前相同的字符串是
  /// 空操作。所以这里先写过渡值 [PlayerBufferConfig.hwdecKickTransient]，
  /// 再写回目标值。
  ///
  /// ## 边界
  ///
  ///   * 只在起播 20 秒内动手：重建解码器有一瞬间的顿挫，放在片头无所谓，
  ///     放到正片中间就成了新的「卡顿」。
  ///   * 只动**一次**，而且**只在确实退到拷贝档时**才动 —— 直通已经生效时
  ///     这条方法是纯读，一个字节都不改播放。
  ///   * 全程 try/catch：它只是兜底与取证，失败不该影响播放。
  Future<void> _verifyZeroCopyHwdec() async {
    if (_disposed) return;
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final platform = _player.platform;
    if (platform is! mk.NativePlayer) return;
    try {
      // 解码器起来之前 `hwdec-current` 是空串 —— 空串不是「拷贝档」。
      var current = '';
      for (var i = 0; i < 40 && !_disposed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        current = (await platform.getProperty('hwdec-current')).trim();
        if (current.isNotEmpty) break;
      }
      if (_disposed || current.isEmpty) return;

      if (!PlayerBufferConfig.isCopyHwdec(current)) {
        diag.info('硬解', '零拷贝直通已生效：hwdec-current=$current');
        return;
      }
      // 到这里已经确定「在拷贝档」。剩下唯一的否决条件就是过了重建窗口 ——
      // 判据本身抽在 [shouldKickHwdec] 里（它是这段逻辑里最容易写错的一处）。
      if (!shouldKickHwdec(
        hwdecCurrent: current,
        position: _player.state.position,
      )) {
        diag.warn('硬解', '仍是拷贝档但已过重建窗口 —— 只记录，不动正片');
        return;
      }

      final target = (await platform.getProperty('hwdec')).trim();
      if (target.isEmpty) return;
      diag.warn(
        '硬解',
        '仍是拷贝档（hwdec-current=$current）—— 重建解码器再试一次：'
            '$target → ${PlayerBufferConfig.hwdecKickTransient} → $target',
      );
      await platform.setProperty('hwdec', PlayerBufferConfig.hwdecKickTransient);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await platform.setProperty('hwdec', target);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (_disposed) return;

      final after = (await platform.getProperty('hwdec-current')).trim();
      diag.info(
        '硬解',
        '重建后 hwdec-current=${after.isEmpty ? '?' : after}'
            '（${PlayerBufferConfig.isCopyHwdec(after) ? '仍在拷贝档：这条路走不通' : '直通成功'}）',
      );
    } catch (_) {
      // 纯兜底 + 取证，失败不影响播放。
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> stop() async {
    _stopNetSpeedPolling();
    _stopVideoPipelineProbe();
    _resourceProbe.stop();
    await _player.stop();
  }

  /// 绝对跳转。**不在这里夹取** —— 裁剪规则（`clampSeekTarget`）属于业务：
  /// 独立播放窗口用的是同一套，留在调用方才能保证只有一份。
  @override
  Future<void> seek(Duration to) => _player.seek(to);

  /// 契约口径是 0..100（与设置里存的一致），mpv 也是 0..100。
  @override
  Future<void> setVolume(double value) =>
      _player.setVolume(value.clamp(0.0, 100.0));

  /// 0.25x ~ 4x 是合理范围；超出会被 mpv 静默夹住，不如我们自己夹，
  /// 这样 UI 上显示的倍速与实际一致。
  @override
  Future<void> setRate(double value) =>
      _player.setRate(value.clamp(0.25, 4.0));

  /// `null` = 交回引擎自己决定 → mpv 的 `auto`（选第一条）。
  ///
  /// ⚠️ 与 [FvpPlaybackEngine] 的同一方法是**不同语义**：mdk 那边
  /// `setActiveTracks(audio, [])` 是「一条都不选」＝静音，所以它把 null
  /// 当空操作。这里能真正表达「让引擎决定」，因为 mpv 有 `auto` 这个轨。
  @override
  Future<void> selectAudioTrack(int? id) => _player.setAudioTrack(
        id == null
            ? mk.AudioTrack.auto()
            : mk.AudioTrack('$id', null, null),
      );

  /// `null` = **关掉字幕**（mpv 的 `no`）。
  @override
  Future<void> selectSubtitleTrack(int? id) => _player.setSubtitleTrack(
        id == null
            ? mk.SubtitleTrack.no()
            : mk.SubtitleTrack('$id', null, null),
      );

  @override
  Future<void> loadExternalSubtitle(String uri) =>
      _player.setSubtitleTrack(mk.SubtitleTrack.uri(uri));

  /// mpv **能直接吃字符串**，所以这条对 media_kit 是零成本的。
  ///
  /// ⚠️ 与 [FvpPlaybackEngine] 的同一方法**实现完全不同**（那边要落临时文件）
  /// —— 这正是它被放进契约、而不是推给调用方的原因，见契约里的类文档。
  @override
  Future<void> loadExternalSubtitleText(
    String text, {
    String? title,
    String? language,
  }) =>
      _player.setSubtitleTrack(
        mk.SubtitleTrack.data(text, title: title, language: language),
      );

  /// 读一次章节清单。
  ///
  /// 解析复用 [MpvChapters.read]（mpv 的 `chapter-list` 属性）。
  /// 读的**时机**由调用方决定：必须等 `position > 0`（容器解析完），
  /// 早读会拿到空列表而与「这个文件没章节」无法区分 —— 理由见
  /// [MpvChapters] 的类文档。
  @override
  Future<List<EngineChapter>> chapters() async {
    final raw = await MpvChapters.read(_player);
    return chaptersFrom(raw, _player.state.duration);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _stopNetSpeedPolling();
    _stopVideoPipelineProbe();
    _resourceProbe.stop();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    await Future.wait<void>(<Future<void>>[
      _playing.close(),
      _buffering.close(),
      _position.close(),
      _duration.close(),
      _bufferEnd.close(),
      _volume.close(),
      _rate.close(),
      _tracks.close(),
      _activeAudio.close(),
      _activeSubtitle.close(),
      _completed.close(),
      _error.close(),
      _log.close(),
      _videoSize.close(),
      _bufferingPercentage.close(),
      _networkSpeed.close(),
    ]);

    // 本类拥有 Player 与 VideoController（见类文档），由这里销毁。
    await _player.dispose();
  }

  // -------------------------------------------------------------------
  // 纯函数（可单测，不依赖 Player 实例）
  // -------------------------------------------------------------------

  /// mpv 的轨道号 → 契约的整数 id。
  ///
  /// ⚠️ **不是** `int.parse`：media_kit 的 `tracks.*` 前两条是合成轨
  /// （`auto` / `no`），它们的 `id` 是字符串而不是轨道号。解析不了就返回
  /// `null`，那正是「没有选中任何轨」的正确表示。
  static int? parseTrackId(String? id) => id == null ? null : int.tryParse(id);

  /// `mk.Tracks` → 契约的轨道快照。
  ///
  /// 过滤规则委托给 [TrackLabels.realTracks]：合成轨（`auto` / `no`）必须
  /// 剔掉，否则菜单里会多出两条「点了没反应」的选项，而自动选字幕取
  /// 「第一条」时**每次都会选中它们**。规则本体在那边，别在这里另写一份。
  static EngineTracks mapTracks(mk.Tracks tracks) => EngineTracks(
        video: <EngineTrack>[
          for (final t in TrackLabels.realTracks(tracks.video, (t) => t.id))
            _trackOf(
              id: t.id,
              title: t.title,
              language: t.language,
              codec: t.codec,
              isDefault: t.isDefault,
            ),
        ],
        audio: <EngineTrack>[
          for (final t in TrackLabels.realTracks(tracks.audio, (t) => t.id))
            _trackOf(
              id: t.id,
              title: t.title,
              language: t.language,
              codec: t.codec,
              isDefault: t.isDefault,
            ),
        ],
        subtitle: <EngineTrack>[
          for (final t in TrackLabels.realTracks(tracks.subtitle, (t) => t.id))
            _trackOf(
              id: t.id,
              title: t.title,
              language: t.language,
              codec: t.codec,
              isDefault: t.isDefault,
            ),
        ],
      );

  /// mpv 的章节清单 → 契约的章节列表。
  ///
  /// ## 这里有一处**语义补全**，不是照抄
  ///
  /// mpv 的 `chapter-list` **只给起点**（`IntroChapter` 只有 `title` + `start`），
  /// 而契约要求 `[start, end]`。补法是行业惯例：**一章延伸到下一章的起点**，
  /// 最后一章延伸到片尾（[mediaDuration]）。
  ///
  /// ⚠️ 片尾补不上时（`mediaDuration` 还没解出来，或它比起点还小）退化成
  /// 「终点 = 起点」，于是 `duration` 是 0。这是**诚实的**退化 —— 章节清单
  /// 的用途只有「认片头」，而认片头只看 `start`；编一个假终点反而会污染
  /// `EngineChapter.duration`。
  ///
  /// 同时做一次单调保护：mpv 理论上按序给，但真出现乱序时 `end < start`
  /// 会让 `duration` 变负数 —— 那种值流到界面上是「负数时长」，
  /// 比退化到 0 难查得多。
  static List<EngineChapter> chaptersFrom(
    List<IntroChapter> raw,
    Duration mediaDuration,
  ) {
    if (raw.isEmpty) return const <EngineChapter>[];

    return <EngineChapter>[
      for (var i = 0; i < raw.length; i++)
        EngineChapter(
          start: raw[i].start,
          end: _endOf(raw, i, mediaDuration),
          title: raw[i].title,
        ),
    ];
  }

  static Duration _endOf(
    List<IntroChapter> raw,
    int index,
    Duration mediaDuration,
  ) {
    final start = raw[index].start;
    final next = index + 1 < raw.length ? raw[index + 1].start : mediaDuration;
    // 终点不得早于起点（乱序 / 片长未知两种情况下都会撞上）。
    return next > start ? next : start;
  }

  static EngineTrack _trackOf({
    required String id,
    String? title,
    String? language,
    String? codec,
    bool? isDefault,
  }) =>
      EngineTrack(
        // 上游 `realTracks` 已经保证能解析成整数，所以这里用 `parse` 而不是
        // `tryParse`：真解析不了就应当炸出来，而不是静默产出一条没有轨道号的轨。
        id: int.parse(id),
        title: title,
        language: language,
        codec: codec,
        isDefault: isDefault ?? false,
      );

  // -------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------

  final List<StreamSubscription<Object?>> _subs = [];

  void _bindStreams() {
    final s = _player.stream;

    _subs.add(s.playing.listen((v) {
      if (_gPlaying.accept(v)) _playing.add(v);
    }));
    _subs.add(s.buffering.listen((v) {
      if (_gBuffering.accept(v)) _buffering.add(v);
    }));
    _subs.add(s.position.listen((v) {
      if (_gPosition.accept(v)) _position.add(v);
    }));
    _subs.add(s.duration.listen((v) {
      if (_gDuration.accept(v)) _duration.add(v);
    }));

    // 缓冲终点是**绝对时间戳**，直接转发（见 [bufferEnd] 的文档）。
    _subs.add(s.buffer.listen((v) {
      if (_gBufferEnd.accept(v)) _bufferEnd.add(v);
    }));

    // 音量 / 倍速：mpv 的浮点会抖，闸是必须的（容差判断留给闸的 `==`，
    // 因为 mpv 报的是它自己存的值，同一次设置不会给出两个不同的 double）。
    _subs.add(s.volume.listen((v) {
      if (_gVolume.accept(v)) _volume.add(v);
    }));
    _subs.add(s.rate.listen((v) {
      if (_gRate.accept(v)) _rate.add(v);
    }));

    // 内嵌轨清单：mpv 解完文件头之后才可用，所以这是**流**而不是一次性查询。
    _subs.add(s.tracks.listen((t) {
      final mapped = mapTracks(t);
      if (_gTracks.accept(mapped.signature)) _tracks.add(mapped);
    }));

    // 当前选中的轨。**只认 mpv 的回报**，不看我们下发过什么 ——
    // 切轨成功与否只有 mpv 说了算。
    _subs.add(s.track.listen((t) {
      final audio = parseTrackId(t.audio.id);
      final subtitle = parseTrackId(t.subtitle.id);
      if (_gActiveAudio.accept(audio)) _activeAudio.add(audio);
      if (_gActiveSubtitle.accept(subtitle)) _activeSubtitle.add(subtitle);
    }));

    _subs.add(s.completed.listen((v) {
      if (_gCompleted.accept(v)) _completed.add(v);
    }));

    _subs.add(s.error.listen((msg) {
      // 原样转发，不做过滤（见契约里 [PlaybackEngine.error] 的文档）。
      // mpv 很吵，过滤规则在上层。
      if (_gError.accept(msg)) _error.add(msg);
    }));

    // ⚠️ 字幕那条**只能靠日志流**：media_kit 只把特定 prefix 的 error 转发到
    // `stream.error`（`file` / `ffmpeg`（text 必须以 `tcp:` 开头）/ `vd` /
    // `ad` / `cplayer` / `stream`），而报字幕解码失败的是 `sd_lavc` ——
    // 不在白名单里。所以这里**不能**因为「已经监听了 error」就省掉。
    //
    // 不过闸：日志本来就是有则报的流水，重复文本同样是新事件。
    _subs.add(s.log.listen((entry) => _log.add(entry.text)));

    // 「出画面了没有」的判据。`videoParams` 要等 mpv 解出第一帧才能定输出
    // 格式，所以它是**最准**的那个（独立窗口那条路也是这么判的）。
    _subs.add(s.videoParams.listen((p) {
      final size = EngineVideoSize(p.w ?? 0, p.h ?? 0);
      if (_gVideoSize.accept(size)) _videoSize.add(size);
    }));

    _subs.add(s.bufferingPercentage.listen((v) {
      if (_gBufferingPercentage.accept(v)) _bufferingPercentage.add(v);
    }));
  }

  /// 换源时闸要归零：新流的 duration / 轨道 id 与旧流无关，
  /// 不归零的话「新流的值恰好等于旧流」会被判成没变而不上报。
  void _resetGates() {
    _gPlaying.reset();
    _gBuffering.reset();
    _gPosition.reset();
    _gDuration.reset();
    _gBufferEnd.reset();
    _gVolume.reset();
    _gRate.reset();
    _gTracks.reset();
    _gActiveAudio.reset();
    _gActiveSubtitle.reset();
    _gCompleted.reset();
    _gError.reset();
    _gVideoSize.reset();
    _gBufferingPercentage.reset();
    _gNetworkSpeed.reset();
  }

  // -------------------------------------------------------------------
  // 实时输入速率（1 Hz 轮询）
  // -------------------------------------------------------------------

  Timer? _netSpeedTimer;

  /// 开始 1 Hz 轮询 `demuxer-cache-state`。重复调用只会重置计时器。
  ///
  /// 用轮询而不是 `observeProperty`：那个属性是 **node 类型**，mpv 的变更
  /// 通知不保证发；1 Hz 读一个字符串的代价可以忽略。这段逻辑原来长在
  /// `player_window_app.dart` 里，搬进来是为了让契约的 [networkSpeed]
  /// 有唯一来源 —— 两个播放器各轮询一次会得到两份不同的读数。
  void _startNetSpeedPolling() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_readNetSpeed()),
    );
  }

  void _stopNetSpeedPolling() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
  }

  /// 读一次 mpv 的输入速率。**绝不抛** —— 它跑在播放路径上。
  ///
  /// 任何失败（播放器还没建好、已 dispose、属性读不到）都只是这一拍不发：
  /// 「不知道」不等于「网速是 0」。解析本体在 [rawInputBytesPerSecond]。
  Future<void> _readNetSpeed() async {
    if (_disposed) return;
    final platform = _player.platform;
    // 平台不是 `NativePlayer`（理论上只有 web，本应用不涉及）时读不到。
    if (platform is! mk.NativePlayer) return;
    try {
      final state = await platform.getProperty('demuxer-cache-state');
      if (_disposed) return;
      final bytes = rawInputBytesPerSecond(state);
      if (bytes == null) return;
      if (_gNetworkSpeed.accept(bytes)) _networkSpeed.add(bytes);
    } catch (_) {
      // 静默：速率读数拿不到不该影响播放，也不该刷日志（1 Hz 会刷满）。
    }
  }

  // -------------------------------------------------------------------
  // 视频管线诊断（解码器 / 丢帧数）—— 「4K 掉帧」唯一能落地的判据
  // -------------------------------------------------------------------

  Timer? _pipelineTimer;
  int _pipelineTicks = 0;
  int _pipelineSamples = 0;
  String? _hwdecCurrent;
  bool _videoParamsLogged = false;
  bool _hardwareLogged = false;

  /// 资源采样（CPU / 内存 / 磁盘）。**与视频探针是两件事**：
  /// 那条回答「mpv 自己觉得丢没丢帧」，这条回答「这台机器当时有多忙」。
  ///
  /// 之所以两条都要：`mediacodec-copy` 那条路的瓶颈是**内存带宽**，
  /// 它不丢帧、只让 `vo-delayed-frame-count` 慢慢涨；而「盒子被榨干」
  /// （MediaCodec 的服务进程在**别的进程**里，本进程 CPU 看不出来）
  /// 又会同时抬高系统负载。只有把两侧读数摆在一起，才能把
  /// 「解码器不行」与「机器不行」分开。
  final ResourceProbe _resourceProbe = ResourceProbe();

  /// 每 3 秒读一次 mpv 的视频管线属性，发两拍读数就收工。
  ///
  /// ## 为什么需要它
  ///
  /// 用户报「4K 片源掉帧、1080P 就顺，而夸克播放器播同一片源没问题」。
  /// 这个探针就是当初为了回答它而加的 —— **10-04 真机上它给出了结论**：
  ///
  /// ```
  /// 第 6s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=14
  /// 第27s：解码器=mediacodec-copy 解码丢帧=0 显示丢帧=58
  /// ```
  ///
  /// 解码丢帧恒为 0、中继零告警，而显示丢帧 21 秒涨 44 帧（每秒丢 9%）——
  /// 瓶颈是**「拷回内存 + 上传纹理」**。当时的 `hwdec=auto-safe` 只走白名单，
  /// 而 `mediacodec` / `mediacodec-copy` 都不在白名单里，Android 上只能落到
  /// `-copy`（解码走硬件，但帧要拷回内存再上传纹理；4K 一帧约 12MB，
  /// 24fps 就是 ~580 MB/s）。夸克走 ExoPlayer + SurfaceView（零拷贝）所以不卡。
  ///
  /// 修法是把它改成 `mediacodec,auto-safe`（见 `PlayerBufferConfig.tvHwdec`）。
  /// **所以现在这一行的读数就是验收判据**：`解码器=mediacodec` 且
  /// `显示丢帧` 不再涨 = 生效；仍是 `mediacodec-copy` = 直通没配上、
  /// 自动退回了拷贝路（功能不坏，但掉帧照旧）。
  ///
  /// ⚠️ release 包没有 Dart VM service、`dart:developer` 的 `log()` 也不进
  /// logcat —— 真机上唯一能看到这些读数的地方就是**应用内那个「诊断日志」页**。
  ///
  /// ## 读哪几个属性
  ///
  ///   * `hwdec-current` —— **实际生效**的解码器。这是**唯一**能分辨
  ///     「直通生效」与「静默退回拷贝」的读数。
  ///   * `decoder-frame-drop-count` —— **解码器**丢掉的帧（解不过来）。
  ///   * `frame-drop-count` —— **显示端**丢掉的帧（画不出来 / 上屏跟不上）。
  ///   * `mistimed-frame-count` —— 时间戳对不上的帧。
  ///   * `vo-delayed-frame-count` —— **VO 没能按时上屏**的帧数。这条是关键：
  ///     `video-sync=audio` 下 mpv 常常「不丢帧、只是晚一点画」，于是
  ///     `frame-drop-count` 恒为 0，而观感就是**全程不流畅**。它与
  ///     `frame-drop-count` 一起看，才能把「真丢帧」与「上屏来不及」分开。
  ///   * `estimated-vf-fps` —— 实测帧率。与 `container-fps` 差得多 = 确实在丢。
  ///
  /// 前两个分得开「解不过来」与「画不出来」—— 这正是要回答的问题。
  /// 另有两行一次性读数：`[片源]`（见 [_readVideoParamsOnce]）记宽高 /
  /// 帧率 / 像素格式；`[硬解]`（见 [_readHardwareOnce]）把 `hwdec` / `vo` /
  /// `display-fps` **读回来**。
  ///
  /// ## 采样跨度：整段播放，而不是起播那 30 秒
  ///
  /// 旧策略只发两拍（约第 6s / 第 27s）。用户报的是「**全程**不流畅」，
  /// 而那两拍恰好都贴着「起播 + 片头跳过 seek」，读数全是 0 —— 于是得出
  /// 「没有掉帧」的假结论，把排查方向整个带偏。现在每 21 秒发一条，
  /// 一直发到 6 分钟（见 [nextVideoProbeAction]）。每条约一行，
  /// 不至于把那 800 行的环形缓冲刷满。
  void _startVideoPipelineProbe() {
    _stopVideoPipelineProbe();
    _pipelineTicks = 0;
    _pipelineSamples = 0;
    _hwdecCurrent = null;
    _videoParamsLogged = false;
    _hardwareLogged = false;
    _pipelineTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_readVideoPipeline()),
    );
  }

  void _stopVideoPipelineProbe() {
    _pipelineTimer?.cancel();
    _pipelineTimer = null;
  }

  /// 读一拍。**绝不抛** —— 它跑在播放路径上。
  Future<void> _readVideoPipeline() async {
    if (_disposed) return;
    final platform = _player.platform;
    if (platform is! mk.NativePlayer) return;

    _pipelineTicks++;
    try {
      // 每一拍都读一次解码器：它起来之前是**空串**，空串不等于「软解」。
      final hwdec = (await platform.getProperty('hwdec-current')).trim();
      if (_disposed) return;
      if (hwdec.isNotEmpty) _hwdecCurrent ??= hwdec;

      final action = nextVideoProbeAction(
        ticks: _pipelineTicks,
        samples: _pipelineSamples,
        decoderReady: _hwdecCurrent != null,
      );
      switch (action) {
        case VideoProbeAction.stop:
          // 30 秒都没等到解码器：要么这条流没有视频轨（纯音频），要么硬解
          // 根本没起来。两种都值得留一行 —— 否则诊断页里**什么都没有**，
          // 看起来像「这个探针压根没生效」。
          if (_pipelineSamples == 0) {
            diag.warn('解码', '起播 30 秒仍读不到 hwdec-current'
                '（解码器未起，或这条流没有视频轨）');
          }
          _stopVideoPipelineProbe();
        case VideoProbeAction.skip:
          return;
        case VideoProbeAction.sample:
          final decoded =
              (await platform.getProperty('decoder-frame-drop-count')).trim();
          final shown = (await platform.getProperty('frame-drop-count')).trim();
          final mistimed =
              (await platform.getProperty('mistimed-frame-count')).trim();
          // ⚠️ 这两条是「mpv 说它没问题、眼睛说有问题」时**唯一**能分辨的读数。
          // `frame-drop-count` 恒为 0 而 `vo-delayed-frame-count` 一直涨，
          // 就说明瓶颈在**出画面**那一段（拷贝 / 上传 / 合成），不在解码。
          final voDelayed =
              (await platform.getProperty('vo-delayed-frame-count')).trim();
          final vfFps =
              (await platform.getProperty('estimated-vf-fps')).trim();
          if (_disposed) return;
          _pipelineSamples++;
          // 第一拍顺手把片源本身与硬解配置记下来（各只记一次）。放在样本之后
          // 读：解码器起来之前这几个子属性是空串。
          await _readVideoParamsOnce(platform);
          await _readHardwareOnce(platform);
          if (_disposed) return;
          diag.info(
            '解码',
            '第 ${_pipelineTicks * 3}s：解码器=$_hwdecCurrent '
                '解码丢帧=$decoded 显示丢帧=$shown 时间戳错帧=$mistimed '
                'VO延迟帧=$voDelayed 实测帧率=$vfFps',
          );
      }
    } catch (_) {
      // 播放器已 dispose、或这台设备的 mpv 没有这几个属性：
      // 不影响播放，收工即可（**不要**抛，也不要 1 Hz 刷日志）。
      _stopVideoPipelineProbe();
    }
  }

  /// 片源本身的宽高 / 帧率 / 像素格式 —— **每条流只读一次**。
  ///
  /// ## 为什么值得单独占一行日志
  ///
  /// 「同是 4K，有的卡有的不卡」的差别常常就在**位深**上：10bit（`p010`）
  /// 一帧比 8bit 大一半到一倍，而直通硬解还会把它降到 8bit —— 不把这条记下来，
  /// 「换了参数到底有没有变好」就只能靠感觉。
  ///
  /// 帧率同理：`container-fps` 是片源标称值，`estimated-vf-fps` 是实测值。
  /// 两个差得多就说明 mpv 在丢帧，与 `[解码]` 那两行**互相印证**。
  ///
  /// ## 为什么要在第一拍样本之后才读
  ///
  /// `video-params/*` 在解码器起来之前是**空串**（不是「没有」），
  /// 而第一拍样本恰好是 `hwdec-current` 已经有值的时刻，那时才读得准。
  ///
  /// ⚠️ 整段吞异常：这几个子属性在部分 mpv 构建里不存在，而它只是诊断，
  /// 不该因为读不到就把播放路径搞出异常。
  Future<void> _readVideoParamsOnce(mk.NativePlayer platform) async {
    if (_videoParamsLogged) return;
    _videoParamsLogged = true;
    try {
      final w = (await platform.getProperty('video-params/w')).trim();
      final h = (await platform.getProperty('video-params/h')).trim();
      if (w.isEmpty && h.isEmpty) return; // 没有视频轨（纯音频）
      final fps = (await platform.getProperty('container-fps')).trim();
      final pix =
          (await platform.getProperty('video-params/pixelformat')).trim();
      final hwPix =
          (await platform.getProperty('video-params/hw-pixelformat')).trim();
      final primaries =
          (await platform.getProperty('video-params/primaries')).trim();
      if (_disposed) return;
      diag.info(
        '片源',
        '${w}x$h 标称帧率=${fps.isEmpty ? '?' : fps} '
            '像素格式=${pix.isEmpty ? '?' : pix} '
            '硬解格式=${hwPix.isEmpty ? '?' : hwPix} '
            '原色=${primaries.isEmpty ? '?' : primaries}',
      );
    } catch (_) {
      // 读不到就不记：诊断项不该影响播放。
    }
  }

  /// 硬解**实际生效的那几个属性** —— 每条流只读一次。
  ///
  /// ## 为什么必须读回来
  ///
  /// `PlayerBufferConfig.apply` 记的是**我们下发的值**，不是 mpv 接受的
  /// 值。media_kit 的 `setProperty` 丢掉返回码（`real.dart` 里调完
  /// `mpv_set_property_string` 直接返回），属性名写错、或 mpv 运行期不接受，
  /// 失败是**完全静默**的。10-04 就栽在这里：日志写着
  /// `hwdec=mediacodec,auto-safe`，而 `hwdec-current` 一直是
  /// `mediacodec-copy` —— 到底是「根本没设进去」还是「mpv 试了没配上」，
  /// **只有把 `hwdec` 读回来才能分开**。这条就是那把尺子。
  ///
  /// `display-fps` 一起读：25fps 片源在 60Hz 面板上本身就是 3:2 不均
  /// （judder），而 `frame-drop-count` **抓不到 judder**。把面板刷新率写下来，
  /// 才能把「真丢帧」与「帧率不匹配」分开 —— 这两件事的修法完全不同。
  ///
  /// ⚠️ 整段吞异常：这几个属性在部分 mpv 构建里不存在，而它只是诊断。
  Future<void> _readHardwareOnce(mk.NativePlayer platform) async {
    if (_hardwareLogged) return;
    _hardwareLogged = true;
    try {
      final hwdec = (await platform.getProperty('hwdec')).trim();
      final vo = (await platform.getProperty('vo')).trim();
      final sync = (await platform.getProperty('video-sync')).trim();
      final displayFps = (await platform.getProperty('display-fps')).trim();
      if (_disposed) return;
      diag.info(
        '硬解',
        '下发=${hwdec.isEmpty ? '?' : hwdec} '
            'vo=${vo.isEmpty ? '?' : vo} '
            'video-sync=${sync.isEmpty ? '?' : sync} '
            '面板帧率=${displayFps.isEmpty ? '?' : displayFps}',
      );
    } catch (_) {
      // 读不到就不记：诊断项不该影响播放。
    }
  }
}
