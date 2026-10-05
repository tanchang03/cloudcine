import 'dart:async';

import 'package:video_player/video_player.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/diagnostics/resource_probe.dart';
import '../../domain/services/playback_engine.dart';
import 'change_gate.dart';

/// 官方 `video_player`（Android 端 = Media3 ExoPlayer）引擎。
///
/// 用于替换 Android TV 上的 FvpPlaybackEngine：同片源 4K 在 MiTV 上
/// fvp/libmdk 拿不到硬解（`VDEC Exit` + 300% CPU），而夸克用 ExoPlayer
/// 能把 CPU 压到 30% 左右。macOS 上 `viewType: platformView` 会被官方
/// 实现忽略（退回 textureView），行为安全。
///
/// ## 与 FvpPlaybackEngine 相比缺失的能力
///
/// - 没有官方可读的轨道清单 / 当前音轨 / 字幕轨（video_player 不在
///   契约里暴露），`tracks` 恒为 [EngineTracks.empty]，相关切换命令
///   变成 no-op。
/// - 没有字幕对外接口，`loadExternalSubtitle*` 是 no-op。
/// - 没有日志流、没有网速、没有 ffmpeg 元数据（chapters 始终空）。
class VideoPlayerExoPlaybackEngine implements PlaybackEngine {
  VideoPlayerController? _controller;
  bool _disposed = false;
  final ResourceProbe _resourceProbe = ResourceProbe();

  VideoPlayerController? get videoController => _controller;

  @override
  EngineCapabilities get capabilities => EngineCapabilities.mdkTv;

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
  @override
  Stream<String> get log => _log.stream;
  @override
  Stream<EngineVideoSize> get videoSize => _videoSize.stream;
  @override
  Stream<double> get bufferingPercentage => _bufferingPercentage.stream;
  @override
  Stream<double> get networkSpeed => _networkSpeed.stream;

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

  @override
  Future<void> open(EngineMedia media, {bool play = true}) async {
    if (_disposed) return;
    await _teardown();

    diag.info('播放', '外接 ExoPlayer 引擎打开：起播=${media.startAt.inSeconds}s');

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(media.url),
      httpHeaders: media.headers,
      viewType: VideoViewType.platformView,
    );
    _controller = controller;
    controller.addListener(_onValueChanged);

    try {
      await controller.initialize();
    } catch (e) {
      _emitError('$e');
      return;
    }

    if (media.startAt > Duration.zero) {
      await controller.seekTo(media.startAt);
    }

    // 章节/音轨/字幕在官方 video_player 上不可用，但要把这些 tick 派发器
    // 状态推一下，否则 UI 等完控的的 ChangeNotifier 会永远收不到。
    if (_gTracks.accept(EngineTracks.empty.signature)) {
      _tracks.add(EngineTracks.empty);
    }
    _resourceProbe.start();

    if (play) await controller.play();
  }

  @override
  Future<void> play() async => _controller?.play();
  @override
  Future<void> pause() async => _controller?.pause();
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

  @override
  Future<void> stop() async {
    _resourceProbe.stop();
    final c = _controller;
    if (c == null) return;
    await c.pause();
    await c.seekTo(Duration.zero);
  }

  @override
  Future<void> seek(Duration to) async => _controller?.seekTo(to);
  @override
  Future<void> setVolume(double value) async =>
      await _controller?.setVolume((value / 100).clamp(0.0, 1.0));
  @override
  Future<void> setRate(double value) async =>
      await _controller?.setPlaybackSpeed(value);

  // 官方 video_player 不暴露音轨/字幕/外挂字幕接口，全部为 no-op。
  @override
  Future<void> selectAudioTrack(int? id) async {}
  @override
  Future<void> selectSubtitleTrack(int? id) async {}
  @override
  Future<void> loadExternalSubtitle(String uri) async {}
  @override
  Future<void> loadExternalSubtitleText(
    String text, {
    String? title,
    String? language,
  }) async {}

  @override
  Future<List<EngineChapter>> chapters() async => const [];

  @override
  Future<void> dispose() async {
    _disposed = true;
    _resourceProbe.stop();
    await _teardown();
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

  Future<void> _teardown() async {
    _controller?.removeListener(_onValueChanged);
    final c = _controller;
    _controller = null;
    if (c != null) {
      _resetGates();
      await c.dispose();
    }
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

    final volume100 = v.volume * 100;
    if (_gVolume.accept(volume100)) _volume.add(volume100);

    final err = v.errorDescription;
    if (err != null) _emitError(err);

    if (v.isInitialized) {
      final size = EngineVideoSize(v.size.width.toInt(), v.size.height.toInt());
      if (_gVideoSize.accept(size)) _videoSize.add(size);
    }

    final end = EngineTimeRange.cacheEndAt(
      <EngineTimeRange>[
        for (final r in v.buffered)
          EngineTimeRange(start: r.start, end: r.end),
      ],
      v.position,
    );
    if (_gBufferEnd.accept(end)) _bufferEnd.add(end);
  }
}
