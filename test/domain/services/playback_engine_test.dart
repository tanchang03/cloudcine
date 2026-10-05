import 'package:cloudcine/domain/services/playback_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// 引擎契约里**纯逻辑**的那部分。
///
/// 为什么值得测：这些都是「算错了不会报错」的量。
/// 缓冲终点算大了，进度条画出一段读不到的缓存，用户看到「缓冲很满但照样卡」；
/// 出画面判据算松了，加载指示器永远不摘。两者都没有异常、没有日志。
void main() {
  group('缓冲终点折算（mdk 区间列表 → mpv 绝对时间戳）', () {
    test('播放头在某一段里 → 取那一段的终点', () {
      final ranges = [
        const EngineTimeRange(start: Duration.zero, end: Duration(seconds: 30)),
      ];

      expect(
        EngineTimeRange.cacheEndAt(ranges, const Duration(seconds: 12)),
        const Duration(seconds: 30),
      );
    });

    test('⚠️ 取「包含播放头的那一段」，不是全局最大值', () {
      // 这是本函数存在的全部理由。seek 之后 mdk 会同时给出残留的旧段，
      // 取最大值就会宣称缓存到了一段**与播放头不相邻**的位置。
      final ranges = [
        // 播放头在这里
        const EngineTimeRange(
          start: Duration(seconds: 100),
          end: Duration(seconds: 140),
        ),
        // 旧段，远端残留
        const EngineTimeRange(
          start: Duration(seconds: 600),
          end: Duration(seconds: 900),
        ),
      ];

      expect(
        EngineTimeRange.cacheEndAt(ranges, const Duration(seconds: 110)),
        const Duration(seconds: 140),
        reason: '报 900 会让进度条显示缓冲到 15:00 —— 而那段数据与播放头不相邻，'
            '画面照样会卡',
      );
    });

    test('播放头不在任何区间里 → 返回 0，绝不猜', () {
      final ranges = [
        const EngineTimeRange(
          start: Duration(seconds: 600),
          end: Duration(seconds: 900),
        ),
      ];

      expect(
        EngineTimeRange.cacheEndAt(ranges, const Duration(seconds: 5)),
        Duration.zero,
        reason: '少报的代价只是暂时不画缓冲层（PlayerBufferProgress 会退回播放头），'
            '多报的代价是进度条说谎 —— 代价不对称，所以宁可返回 0',
      );
    });

    test('空列表 → 0', () {
      expect(EngineTimeRange.cacheEndAt(const [], Duration.zero), Duration.zero);
    });

    test('两端都是闭区间', () {
      const r = EngineTimeRange(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
      );

      expect(EngineTimeRange.cacheEndAt([r], const Duration(seconds: 10)),
          const Duration(seconds: 20), reason: '起点算「在里面」');
      expect(EngineTimeRange.cacheEndAt([r], const Duration(seconds: 20)),
          const Duration(seconds: 20), reason: '终点算「在里面」');
      expect(EngineTimeRange.cacheEndAt([r], const Duration(seconds: 21)),
          Duration.zero, reason: '越过终点就不在里面了');
    });

    test('永远不会返回某个区间之外的值', () {
      // 抽查一组区间 × 一组播放头，锁住「返回值必属于包含它的那一段」。
      const ranges = [
        EngineTimeRange(start: Duration(seconds: 0), end: Duration(seconds: 10)),
        EngineTimeRange(start: Duration(seconds: 20), end: Duration(seconds: 25)),
        EngineTimeRange(start: Duration(seconds: 40), end: Duration(seconds: 60)),
      ];

      for (var s = 0; s <= 70; s += 1) {
        final pos = Duration(seconds: s);
        final end = EngineTimeRange.cacheEndAt(ranges, pos);
        if (end == Duration.zero) continue;

        final containing = ranges.where(
          (r) => pos >= r.start && pos <= r.end,
        );
        expect(containing, isNotEmpty,
            reason: '非 0 的返回值必须来自一段真的包含播放头的区间');
        expect(
          containing.map((r) => r.end),
          contains(end),
          reason: '位置 $s 上返回了不属于任何包含区间的终点：$end',
        );
      }
    });
  });

  group('出画面判据', () {
    test('宽高都为 0 不算出画面', () {
      expect(EngineVideoSize.unknown.hasVideo, isFalse);
      expect(const EngineVideoSize(0, 1080).hasVideo, isFalse,
          reason: '宽度 0 是「还没解出格式」，不是「有一个 0 宽的画面」');
      expect(const EngineVideoSize(1920, 0).hasVideo, isFalse);
    });

    test('正常尺寸算出画面', () {
      expect(const EngineVideoSize(3840, 1920).hasVideo, isTrue);
      expect(const EngineVideoSize(1, 1).hasVideo, isTrue,
          reason: '判据是「非 0」而不是「够大」—— 小尺寸也可能是真实输出');
    });
  });

  group('轨道快照', () {
    test('三类都空才算空', () {
      expect(EngineTracks.empty.isEmpty, isTrue);
      expect(
        const EngineTracks(
          subtitle: [EngineTrack(id: 1)],
        ).isEmpty,
        isFalse,
        reason: '只有字幕轨也算「有轨道」，上层要据此决定是否再试一次自动选字幕',
      );
    });
  });

  group('轨道指纹', () {
    test('⚠️ 条数相同但 id 不同 → 指纹必须变', () {
      // 换集时最常见的情况：两集都是「1 条音轨、1 条内嵌字幕」，
      // 条数完全一样，只有轨道号变了。只比条数的话会被判成「没变」，
      // 于是偏好还原与自动选字幕都不重跑 —— 表现是「换集后字幕没了」。
      const a = EngineTracks(
        audio: [EngineTrack(id: 1)],
        subtitle: [EngineTrack(id: 2)],
      );
      const b = EngineTracks(
        audio: [EngineTrack(id: 3)],
        subtitle: [EngineTrack(id: 4)],
      );

      expect(a.audio.length, b.audio.length, reason: '前提：条数确实一样');
      expect(a.signature, isNot(b.signature));
    });

    test('内容一样 → 指纹一样', () {
      const a = EngineTracks(audio: [EngineTrack(id: 1), EngineTrack(id: 2)]);
      const b = EngineTracks(audio: [EngineTrack(id: 1), EngineTrack(id: 2)]);

      expect(a.signature, b.signature);
    });

    test('三类各自参与指纹 —— 音轨换了、字幕没换也要变', () {
      const a = EngineTracks(audio: [EngineTrack(id: 1)]);
      const b = EngineTracks(
        audio: [EngineTrack(id: 2)],
        subtitle: [EngineTrack(id: 9)],
      );

      expect(a.signature, isNot(b.signature));
    });
  });

  group('章节', () {
    test('时长是闭区间差', () {
      const c = EngineChapter(
        start: Duration(seconds: 10),
        end: Duration(seconds: 100),
      );

      expect(c.duration, const Duration(seconds: 90));
    });
  });

  group('内核能力声明', () {
    test('media_kit 三项全有', () {
      expect(EngineCapabilities.mediaKit.audioEffects, isTrue);
      expect(EngineCapabilities.mediaKit.networkSpeed, isTrue);
      expect(EngineCapabilities.mediaKit.rawLog, isTrue);
    });

    test('mdk 三项都缺 —— UI 靠它置灰', () {
      // 这条锁的是「界面会正确置灰」。标志位被误改成 true，
      // 表现是菜单可点但点了没反应 —— 用户会以为自己没设置对。
      expect(EngineCapabilities.mdk.audioEffects, isFalse,
          reason: 'mdk 没有 af 滤镜 / audio-channels 的对等物');
      expect(EngineCapabilities.mdk.networkSpeed, isFalse,
          reason: 'mdk 没有 demuxer-cache-state 的对等物');
      expect(EngineCapabilities.mdk.rawLog, isFalse,
          reason: 'mdk 没有 mpv 那种日志流');
    });

    test('两个内核都有章节', () {
      expect(EngineCapabilities.mediaKit.chapters, isTrue);
      expect(EngineCapabilities.mdk.chapters, isTrue,
          reason: 'mdk 的 MediaInfo 里有 chapters，跳片头在新内核上必须照常工作');
    });
  });

  // 高分辨率换内核判据的测试在 `playback_engine_router_test.dart`。
}
