import 'dart:async';
import 'dart:io';

// 不加前缀：`FVPControllerExtensions` 是**扩展方法**，前缀导入不会把它带进
// 隐式解析的作用域，于是 `controller.setAudioTracks(...)` 会编译不过。
import 'package:fvp/fvp.dart';
import 'package:fvp/mdk.dart' as mdk;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/diagnostics/resource_probe.dart';
import '../../domain/services/playback_engine.dart';
import 'change_gate.dart';

/// fvp（libmdk）引擎。macOS 服务杜比视界 P5；Android TV 服务 ≥4K 片源。
///
/// 2026-10-05：Android TV 上按 `docs/解决4k片源不卡顿解析方案.md` 重新启用
/// （platformView + 钳制 1080p，不开 tunnel）。2026-10-04 失败过两轮：
/// 未钳 `maxWidth/maxHeight` 时 GL 渲染器在 4K 上渲染（更卡、音画不同步）；
/// 开 `tunnel` 时走 `AMediaCodec:dv=1`（4K 无画面）。机制见 main.dart 注释。
///
/// 顺带钉住两条读源码得到的事实，省得下次重查：
///   - `platformView` **不等于**零拷贝：mdk 仍要跑一遍 GL 渲染器把每帧画进
///     SurfaceView；`tunnel:true` 才是「解码器直接写 surface」。
///   - tunnel 分支**显式跳过** `maxWidth/maxHeight` 钳制（`video_player_mdk.dart`
///     原文 *"'tunnel' has no GL renderer"*），于是 SurfaceView 的
///     `setFixedSize` 拿到的是**视频原生**尺寸（这台电视上是 3840×2160），
///     而 Android 的显示层只有 1920×1080 —— 这一条**没有被证实**是
///     「看不到画面」的成因，但它是下次要查的第一个假设。
///
/// ## ⛔ 前提：必须先 `fvp.registerWith`
///
/// fvp 的 macOS 平台声明里**没有 `dartPluginClass`**（只有 linux / windows /
/// ohos / elinux 有）。也就是说它**不会**自动注册 —— 不显式调用
/// `fvp.registerWith(options: {'platforms': ['macos']})` 的话，
/// `video_player` 会用官方的 `video_player_avfoundation`（Apple 那套栈），
/// **DV 依然渲染不对，而且不报任何错**。这是本迁移最容易踩的坑。
///
/// ## 与 media_kit 那条路的差异（都是实测确认过的）
///
/// | | media_kit（mpv） | 本实现（mdk） |
/// |---|---|---|
/// | 起播位置 | `Media(start:)` | `initialize()` 后 `seekTo()` |
/// | 缓冲终点 | `demuxer-cache-time`（**绝对时间戳**） | `value.buffered`（**区间列表**）→ [EngineTimeRange.cacheEndAt] |
/// | 音效 | `af` / `audio-channels` | **没有**（见 [EngineCapabilities.mdk]） |
/// | 实时速率 | `demuxer-cache-state` | **没有** |
/// | 引擎日志 | `stream.log` | **没有** |
///
/// ## ✅ 本机 `http_proxy` 不会打断这条路（已核实，别再查一遍）
///
/// media_kit 那条路上有个著名陷阱：本机设了 `http_proxy` 时，ffmpeg 会把请求
/// 交给 `httpproxy` 协议，而 mpv 的**协议白名单**没放行它 →
/// `avformat_open_input() failed`（HLS 那个故障就是这么来的，只能靠本地中继绕）。
///
/// fvp 这条路**没有**这个问题，依据在 `fvp-0.39.0/lib/src/video_player_mdk.dart`
/// 的 `_create`：网络源（`DataSourceType.network`）**根本不设**
/// `avio.protocol_whitelist`，于是 FFmpeg 用它自己的默认（不限制），
/// `httpproxy` 自然可用；而给本地文件设的那份白名单里也**显式写了
/// `httpproxy`**。两处都放行，所以无论走直链还是走 `127.0.0.1` 的本地中继
/// 都不会撞上它。
///
/// ## ⚠️ 本实现拿不到缓冲信息（fvp 的限制，不是 bug）
///
/// fvp 的 `video_player` 平台实现**不上报 `buffered`**（全文件里没有这个词），
/// 所以 [bufferEnd] 实际上**永远收不到非 0 值**，进度条上那层「已缓存」在 DV
/// 片源上不会出现。
///
/// 之所以不额外做补偿：`PlayerBufferProgress.positionOf` 在 `cacheEnd <= 0`
/// 时本来就退回播放头 —— 于是缓冲层自动收敛到与已播层重合（**看不见**），
/// 是**优雅降级**而不是破图。fvp 也没暴露从 `VideoPlayerController` 反查底层
/// `mdk.Player` 的入口（`MdkVideoPlayerPlatform._players` 是私有的），
/// 硬取要重新实现整个平台层，不值得。
class FvpPlaybackEngine implements PlaybackEngine {
  FvpPlaybackEngine();

  VideoPlayerController? _controller;
  Timer? _trackTimer;
  bool _disposed = false;

  /// 资源采样（CPU / 内存 / 磁盘）。
  ///
  /// ⚠️ 这条路**没有视频管线探针** —— 读 mpv 属性的那套（`hwdec-current` /
  /// `frame-drop-count`）在 mdk 上没有对等物，fvp 也没把底层 `mdk.Player`
  /// 暴露出来（见类文档末尾）。所以这里的资源采样是这条路**唯一**的周期性
  /// 证据：至少能回答「当时这台机器有多忙」。
  final ResourceProbe _resourceProbe = ResourceProbe();

  /// 上一份「正文型」外挂字幕落成的临时文件。见 [loadExternalSubtitleText]。
  String? _tempSubtitlePath;

  /// 交给 UI 的渲染句柄。
  ///
  /// ⚠️ 领域层的契约**故意不带这个方法**（领域层不引 Flutter，拿不到 widget）。
  /// 由 UI 层按引擎的具体类型决定用哪个渲染组件，见
  /// `ui/widgets/playback_surface.dart`。
  VideoPlayerController? get videoController => _controller;

  @override
  EngineCapabilities get capabilities =>
      Platform.isAndroid ? EngineCapabilities.mdkTv : EngineCapabilities.mdk;

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

  /// **永不发**：mdk 没有对外的日志流（见 [EngineCapabilities.mdk]）。
  ///
  /// 代价是 DV 片源上看不到「本机解不开这种字幕」的诊断 —— 那条信息在
  /// media_kit 那边是从 mpv 的 `sd_lavc` 日志里捞出来的。fvp 只把错误塞进
  /// `VideoPlayerValue.errorDescription`，没有分级日志通道。
  @override
  Stream<String> get log => _log.stream;
  @override
  Stream<EngineVideoSize> get videoSize => _videoSize.stream;
  @override
  Stream<double> get bufferingPercentage => _bufferingPercentage.stream;

  /// **永不发**：mdk 没有 mpv `demuxer-cache-state` 的对等物。
  /// 能力标志见 [EngineCapabilities.mdk]（`networkSpeed: false`），
  /// UI 据此不显示速率读数，而不是显示一个永远为 0 的数字。
  @override
  Stream<double> get networkSpeed => _networkSpeed.stream;

  // 「值没变就不发」的闸。少了它，`addListener` 每一拍（约 10 Hz）都会把
  // 同样的值往上抛，订阅方每拍都重建。规则本体见 [ChangeGate]。
  final _gPlaying = ChangeGate<bool>();
  final _gBuffering = ChangeGate<bool>();
  final _gPosition = ChangeGate<Duration>();
  final _gDuration = ChangeGate<Duration>();
  final _gBufferEnd = ChangeGate<Duration>();
  final _gVolume = ChangeGate<double>();
  final _gRate = ChangeGate<double>();
  final _gTracks = ChangeGate<String>();
  final _gCompleted = ChangeGate<bool>();
  final _gError = ChangeGate<String>();
  final _gVideoSize = ChangeGate<EngineVideoSize>();
  final _gActiveAudio = ChangeGate<int?>();
  final _gActiveSubtitle = ChangeGate<int?>();

  // -------------------------------------------------------------------
  // 命令
  // -------------------------------------------------------------------

  @override
  Future<void> open(EngineMedia media, {bool play = true}) async {
    if (_disposed) return;
    await _teardownController();

    diag.info(
      '播放',
      'fvp 引擎打开：请求头=${media.headers.keys.toList()} '
      '起播=${media.startAt.inSeconds}s',
    );

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(media.url),
      // ⚠️ 夸克直链缺 Cookie 一律 412。fvp 会把它写成 mdk 的 `avio.headers`。
      httpHeaders: media.headers,
      // Android 上走 platformView（SurfaceView）：2026-10-05 起按
      // `docs/解决4k片源不卡顿解析方案.md` 的阶段 1，钳制到 1080p 的
      // GL 渲染器画进 ANativeWindow。macOS 上 video_player_mdk 只在
      // Platform.isAndroid 时尊重 viewType，写不写都退回 textureView，安全。
      // ⛔ tunnel 仍不开（全局项，见 main.dart 注册注释）。
      viewType: VideoViewType.platformView,
    );
    _controller = controller;
    controller.addListener(_onValueChanged);

    try {
      await controller.initialize();
    } catch (e) {
      // 契约规定流上不抛异常。fvp 的 create 失败会把错误塞进 value.errorDescription，
      // 但 initialize() 自己也可能抛（平台层异常），两条路都要兜。
      _emitError('$e');
      return;
    }

    // 起播位置。⚠️ 必须在 `play()` **之前**：mdk 在 Prepared 状态下 seek 是有效的
    // （不像 mpv 的 `loadfile` 竞态 —— 那正是 media_kit 那条路非要用
    // `Media(start:)` 的原因）。这一条**必须在真机上验**，续播是主路径。
    if (media.startAt > Duration.zero) {
      await controller.seekTo(media.startAt);
    }

    // 轨道清单：mdk 的 MediaInfo 是**一次性查询**，而内嵌轨可能晚一步才齐。
    // 开一个有限窗口反复问，靠内容指纹去重。
    _startTrackRefreshWindow();

    // 资源采样。这条路没有视频探针，所以它是唯一的周期性证据。
    _resourceProbe.start();

    if (play) await controller.play();
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> playOrPause() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      await c.play();
    }
  }

  /// mdk 没有独立的 stop。等价物是「停住 + 回到开头」。
  ///
  /// 不 dispose：本引擎的实例会被复用（换集、切清晰度都走 [open]），
  /// 提前销毁会让调用方拿不到后续事件。
  @override
  Future<void> stop() async {
    _resourceProbe.stop();
    final c = _controller;
    if (c == null) return;
    await c.pause();
    await c.seekTo(Duration.zero);
  }

  @override
  Future<void> seek(Duration to) async {
    await _controller?.seekTo(to);
  }

  /// 契约口径是 0..100（与设置里存的一致），而 `video_player` 是 0..1。
  @override
  Future<void> setVolume(double value) async {
    await _controller?.setVolume((value / 100).clamp(0.0, 1.0));
  }

  @override
  Future<void> setRate(double value) async {
    await _controller?.setPlaybackSpeed(value);
  }

  /// ⚠️ `null`（「交回引擎决定」）在本实现里是**空操作**，不是「关掉音轨」。
  ///
  /// mdk 的 `setActiveTracks(audio, [])` 是「一条都不选」＝静音，与
  /// media_kit 的 `AudioTrack.auto()` 语义不同。传空数组会把声音弄没，
  /// 所以这里选择不动 —— 保持当前轨道，行为上更接近「让引擎决定」。
  @override
  Future<void> selectAudioTrack(int? id) async {
    if (id == null) return;
    _controller?.setAudioTracks(<int>[id]);
  }

  /// `null` = **关掉字幕**（mdk 里就是「一条都不激活」）。
  @override
  Future<void> selectSubtitleTrack(int? id) async {
    _controller?.setSubtitleTracks(id == null ? const <int>[] : <int>[id]);
  }

  @override
  Future<void> loadExternalSubtitle(String uri) async {
    _controller?.setExternalSubtitle(uri);
  }

  /// mdk 的 `setExternalSubtitle` **只吃 URI**，所以这里必须把正文落成一个
  /// 临时文件再下发（契约把这件事放在实现里，理由见契约的类文档）。
  ///
  /// ## 为什么扩展名是 `.srt`
  ///
  /// mdk 按扩展名挑解复用器。网盘字幕解码出来的是**纯文本**（SRT / ASS 都是
  /// 文本，`SubtitleResolver` 已经统一成 UTF-8 文本），而 `.txt` 会让 FFmpeg
  /// 挑不到字幕解析器 —— 表现是「挂上了但一个字都不显示」，且不报错。
  ///
  /// 写成 `.srt` 是安全的近似：FFmpeg 的 srt 解析器对 ASS 风格的时间轴也能
  /// 容忍到「至少能显示」，而本实现只服务 DV 片源（少量路径）。
  ///
  /// ## 回收
  ///
  /// 新文件写下之后立刻删上一份；换源与 [dispose] 再兜一次
  /// （见 [_teardownController]）。临时目录里的残留是无害的，但长片反复换
  /// 字幕会攒出几十个文件，不值得留着。
  @override
  Future<void> loadExternalSubtitleText(
    String text, {
    String? title,
    String? language,
  }) async {
    final c = _controller;
    if (c == null) return;

    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/cloudcine-sub-'
      '${DateTime.now().microsecondsSinceEpoch}.srt',
    );
    await file.writeAsString(text, flush: true);

    final previous = _tempSubtitlePath;
    _tempSubtitlePath = file.path;
    if (previous != null && previous != file.path) {
      unawaited(_deleteQuietly(previous));
    }

    // ⚠️ 传**路径**而不是 `file://` URL：mdk 把 uri 直接交给 FFmpeg 的
    // avformat_open_input，而它认本地路径。加 scheme 反而多一层解析。
    c.setExternalSubtitle(file.path);
  }

  /// 删掉上一份临时字幕。**任何失败都吞掉** —— 临时目录的清理不该影响播放。
  Future<void> _deleteTempSubtitle() async {
    final path = _tempSubtitlePath;
    _tempSubtitlePath = null;
    if (path == null) return;
    await _deleteQuietly(path);
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (e) {
      diag.debug('字幕', '删临时字幕失败（无所谓）：$e');
    }
  }

  @override
  Future<List<EngineChapter>> chapters() async {
    final info = _controller?.getMediaInfo();
    final raw = info?.chapters;
    if (raw == null || raw.isEmpty) return const [];

    return <EngineChapter>[
      for (final c in raw)
        EngineChapter(
          start: Duration(milliseconds: c.startTime),
          end: Duration(milliseconds: c.endTime),
          title: c.title,
        ),
    ];
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _trackTimer?.cancel();
    _trackTimer = null;
    _resourceProbe.stop();
    await _teardownController();

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
  }

  // -------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------

  Future<void> _teardownController() async {
    _trackTimer?.cancel();
    _trackTimer = null;
    // 换源 / 销毁都要收掉上一份临时字幕：新流还没挂任何字幕，留着文件
    // 只会让长片反复换字幕时攒出一堆残留。
    await _deleteTempSubtitle();
    final c = _controller;
    _controller = null;
    if (c == null) return;
    c.removeListener(_onValueChanged);
    // 换源时闸要归零：新流的 duration / 轨道 id 与旧流无关，
    // 不归零的话「新流的值恰好等于旧流」会被判成没变而不上报。
    _resetGates();
    await c.dispose();
  }

  void _resetGates() {
    _gPlaying.reset();
    _gBuffering.reset();
    _gPosition.reset();
    _gDuration.reset();
    _gBufferEnd.reset();
    _gVolume.reset();
    _gRate.reset();
    _gTracks.reset();
    _gCompleted.reset();
    _gError.reset();
    _gVideoSize.reset();
    _gActiveAudio.reset();
    _gActiveSubtitle.reset();
  }

  void _emitError(String message) {
    if (_gError.accept(message)) _error.add(message);
  }

  void _onValueChanged() {
    final c = _controller;
    if (c == null || _disposed) return;
    final v = c.value;

    if (_gPlaying.accept(v.isPlaying)) _playing.add(v.isPlaying);
    if (_gBuffering.accept(v.isBuffering)) _buffering.add(v.isBuffering);
    if (_gPosition.accept(v.position)) _position.add(v.position);
    if (_gDuration.accept(v.duration)) _duration.add(v.duration);
    if (_gRate.accept(v.playbackSpeed)) _rate.add(v.playbackSpeed);
    if (_gCompleted.accept(v.isCompleted)) _completed.add(v.isCompleted);

    // 契约是 0..100，video_player 是 0..1。
    final volume100 = v.volume * 100;
    if (_gVolume.accept(volume100)) _volume.add(volume100);

    final err = v.errorDescription;
    if (err != null) _emitError(err);

    if (v.isInitialized) {
      final size = EngineVideoSize(v.size.width.toInt(), v.size.height.toInt());
      if (_gVideoSize.accept(size)) _videoSize.add(size);
      _refreshTracks();
      _refreshActiveTracks();
    }

    // 缓冲终点：**区间列表 → 绝对时间戳**，唯一允许的换算点。
    // fvp 目前不上报 buffered，这里会稳定得到 0（优雅降级，见类文档）。
    final end = EngineTimeRange.cacheEndAt(
      <EngineTimeRange>[
        for (final r in v.buffered)
          EngineTimeRange(start: r.start, end: r.end),
      ],
      v.position,
    );
    if (_gBufferEnd.accept(end)) _bufferEnd.add(end);
  }

  void _startTrackRefreshWindow() {
    _trackTimer?.cancel();
    var ticks = 0;
    // 8 秒的窗口足够覆盖「文件头解完 → 内嵌轨补齐」这段。
    // 有上限是必须的：无限轮询一个 native 调用会白烧 CPU。
    _trackTimer = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (_disposed || ++ticks > 20) {
        t.cancel();
        _trackTimer = null;
        return;
      }
      _refreshTracks();
      _refreshActiveTracks();
    });
  }

  void _refreshTracks() {
    final info = _controller?.getMediaInfo();
    if (info == null) return;

    final tracks = EngineTracks(
      video: <EngineTrack>[for (final s in info.video ?? const []) _track(s)],
      audio: <EngineTrack>[for (final s in info.audio ?? const []) _track(s)],
      subtitle: <EngineTrack>[
        for (final s in info.subtitle ?? const []) _track(s),
      ],
    );

    // 指纹判重：条数与 id 都没变就不上报（见 EngineTracks.signature）。
    if (_gTracks.accept(tracks.signature)) _tracks.add(tracks);
  }

  /// mdk 只把 `title` / `language` 放在 FFmpeg 的 metadata 里，
  /// **没有** `isDefault` 这个概念 —— 所以这里恒为 false。
  /// 上层（`_maybeRestoreAudio`）本来就把「没有偏好」当作「让引擎用默认」，
  /// 不受影响；只有内嵌字幕的「发布者标记为默认」那一条会退化。
  ///
  /// `codec` 从各子类的 `codec.codec` 拿（FFmpeg 的短名，与 mpv 那边口径一致）。
  /// 基类 `StreamInfo` 上没有它，所以必须按子类分派 —— 写成
  /// `s.metadata['codec']` 会拿到空值，因为 FFmpeg 不把编解码器名放进 metadata。
  EngineTrack _track(mdk.StreamInfo s) => EngineTrack(
        id: s.index,
        title: s.metadata['title'],
        language: s.metadata['language'],
        codec: switch (s) {
          mdk.AudioStreamInfo(:final codec) => codec.codec,
          mdk.SubtitleStreamInfo(:final codec) => codec.codec,
          mdk.VideoStreamInfo(:final codec) => codec.codec,
          _ => null,
        },
      );

  void _refreshActiveTracks() {
    final c = _controller;
    if (c == null) return;

    final audio = c.getActiveAudioTracks();
    final subtitle = c.getActiveSubtitleTracks();
    final audioId = (audio == null || audio.isEmpty) ? null : audio.first;
    final subtitleId =
        (subtitle == null || subtitle.isEmpty) ? null : subtitle.first;

    // 也要过闸：这个函数跑在 400ms 的轮询里，不过闸就是每拍抛两次
    // 「值没变」的事件，订阅方（音轨菜单高亮）跟着每拍重建。
    if (_gActiveAudio.accept(audioId)) _activeAudio.add(audioId);
    if (_gActiveSubtitle.accept(subtitleId)) _activeSubtitle.add(subtitleId);
  }
}
