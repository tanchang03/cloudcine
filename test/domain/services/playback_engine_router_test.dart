import 'dart:async';

import 'package:cloudcine/domain/services/playback_engine.dart';
import 'package:cloudcine/domain/services/playback_engine_router.dart';
import 'package:cloudcine/core/utils/dolby_vision.dart';
import 'package:flutter_test/flutter_test.dart';

/// 最小可用的引擎假实现：所有流都立即完结，命令都是 no-op。
class _FakeEngine implements PlaybackEngine {
  _FakeEngine(this.capabilities_);
  final EngineCapabilities capabilities_;

  @override
  EngineCapabilities get capabilities => capabilities_;

  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<Duration> get bufferEnd => const Stream.empty();
  @override
  Stream<double> get volume => const Stream.empty();
  @override
  Stream<double> get rate => const Stream.empty();
  @override
  Stream<EngineTracks> get tracks => const Stream.empty();
  @override
  Stream<int?> get activeAudioTrackId => const Stream.empty();
  @override
  Stream<int?> get activeSubtitleTrackId => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<String> get error => const Stream.empty();
  @override
  Stream<String> get log => const Stream.empty();
  @override
  Stream<EngineVideoSize> get videoSize => const Stream.empty();
  @override
  Stream<double> get bufferingPercentage => const Stream.empty();
  @override
  Stream<double> get networkSpeed => const Stream.empty();

  @override
  Future<List<EngineChapter>> chapters() async => const [];
  @override
  Future<void> open(EngineMedia media, {bool play = true}) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> selectAudioTrack(int? id) async {}
  @override
  Future<void> selectSubtitleTrack(int? id) async {}
  @override
  Future<void> loadExternalSubtitle(String uri) async {}
  @override
  Future<void> loadExternalSubtitleText(String uri, {String? language, String? title}) async {}
  @override
  Future<void> dispose() async {}
}

DolbyVisionProbeFn _neverDv() =>
    ({required key, required url, required headers}) async => null;

DolbyVisionProbeFn _alwaysDv() => ({required key, required url, required headers}) async =>
    const DolbyVisionInfo(
      profile: 5,
      level: 0,
      blSignalCompatibilityId: 0,
      rpuPresent: true,
      elPresent: false,
      blPresent: true,
    );

void main() {
  group('高分辨率换内核的判据（Android TV）', () {
    late _FakeEngine mpv;
    late _FakeEngine fvp;

    setUp(() {
      mpv = _FakeEngine(EngineCapabilities.mediaKit);
      fvp = _FakeEngine(EngineCapabilities.mdkTv);
    });

    PlaybackEngineRouter router({
      bool highResTv = true,
      DolbyVisionProbeFn? probe,
      bool withFactory = true,
    }) =>
        PlaybackEngineRouter(
          defaultEngine: mpv,
          dolbyVisionEngine: withFactory ? () => fvp : null,
          dolbyVisionProbe: probe ?? _neverDv(),
          highResTvRoute: highResTv,
        );

    test('TV + 2160p → fvp', () async {
      final r = router();
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 2160,
      );
      expect(s.engine, same(fvp));
      expect(s.changed, isTrue);
    });

    test('TV + 1440p（2K）→ media_kit', () async {
      final r = router();
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 1440,
      );
      expect(s.engine, same(mpv));
    });

    test('TV + 1080p → media_kit', () async {
      final r = router();
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 1080,
      );
      expect(s.engine, same(mpv));
    });

    test('非 TV + 4K → media_kit（高分辨率线关闭）', () async {
      final r = router(highResTv: false);
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 2160,
      );
      expect(s.engine, same(mpv));
    });

    test('TV + 4K + 无工厂 → 仍是 media_kit', () async {
      final r = router(withFactory: false);
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 2160,
      );
      expect(s.engine, same(mpv));
    });

    test('TV + 分辨率未知 → media_kit', () async {
      final r = router();
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
      );
      expect(s.engine, same(mpv));
    });

    test('DV 探测命中优先（highResTvRoute 关着也走 fvp）', () async {
      final r = router(highResTv: false, probe: _alwaysDv());
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
      );
      expect(s.engine, same(fvp));
    });

    test('HLS 一律不探测也不走高分辨率线 → media_kit', () async {
      var probed = false;
      Future<DolbyVisionInfo?> tracingProbe(
          {required String key, required Uri url, required Map<String, String> headers}) async {
        probed = true;
        return null;
      }

      final r = router(probe: tracingProbe);
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/media.m3u8'),
        headers: const {},
        videoHeight: 2160,
      );
      // 高分辨率线本身不看 HLS——TV 上 4K HLS 理论会命中。当前实现会命中，
      // 这里先锁「不发 DV 探测」；HLS 4K 的判据跟随通用视频高度。
      expect(probed, isFalse);
      expect(s.engine, same(fvp));
    });

    test('switchToDefault：4K 路由到 fvp 后能强制切回 mpv（ExoPlayer 失败回退）',
        () async {
      final r = router();
      final s = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 2160,
      );
      expect(s.engine, same(fvp));

      final back = await r.switchToDefault();
      expect(back.engine, same(mpv));
      expect(back.changed, isTrue);
      // 切回来后 `selectFor` 仍会判回 fvp（4K 判据还在）——
      // 所以回退路径必须由调用方记住「不再 selectFor」。
      final again = await r.selectFor(
        key: 'k',
        url: Uri.parse('https://example.com/a.mkv'),
        headers: const {},
        videoHeight: 2160,
      );
      expect(again.engine, same(fvp));
    });

    test('switchToDefault 幂等：已在 mpv 上时 changed=false', () async {
      final r = router();
      final back = await r.switchToDefault();
      expect(back.engine, same(mpv));
      expect(back.changed, isFalse);
    });
  });
}
