import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度回报这条链路上有两个纯逻辑件：**报什么**（[PlaybackProgressReport]）
/// 与**什么时候报**（[ProgressThrottle]）。
///
/// 两者都不会抛异常、也不会崩窗口 —— 出问题时的表现是**安静的**：
/// 节流失灵就是每秒 10 条方法通道消息（卡顿、日志刷屏），
/// 编解码不对称就是「最近播放」永远不更新。所以这里逐条钉住边界。
void main() {
  group('PlaybackProgressReport 编解码', () {
    test('字段能原样过一趟通道', () {
      const original = PlaybackProgressReport(
        itemId: '102',
        position: Duration(minutes: 12, seconds: 30),
        duration: Duration(minutes: 96, seconds: 5),
      );

      final restored = PlaybackProgressReport.fromJson(original.toJson());

      expect(restored, original);
      expect(restored!.position, const Duration(minutes: 12, seconds: 30));
      expect(restored.duration, const Duration(minutes: 96, seconds: 5));
    });

    test('duration 缺省是 0，不是 null 崩', () {
      final restored = PlaybackProgressReport.fromJson(const <String, Object?>{
        'itemId': '102',
        'positionMs': 5000,
      })!;

      expect(restored.duration, Duration.zero);
      expect(restored.position, const Duration(seconds: 5));
    });

    test('没有 itemId 就没有意义 —— 返回 null', () {
      // 主窗口拿到它也不知道该更新哪一行，只会白跑一次落库。
      const raws = <Object?>[
        null,
        'string',
        42,
        <String>[],
        <String, Object?>{},
        <String, Object?>{'positionMs': 5000},
        <String, Object?>{'itemId': ''},
        <String, Object?>{'itemId': 102},
      ];

      for (final raw in raws) {
        expect(() => PlaybackProgressReport.fromJson(raw), returnsNormally,
            reason: 'raw=$raw');
        expect(PlaybackProgressReport.fromJson(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('位置/时长为负或非整数时按 0 处理', () {
      for (final raw in const <Object?>[-5, 'abc', null, 1.5]) {
        final restored = PlaybackProgressReport.fromJson(<String, Object?>{
          'itemId': '102',
          'positionMs': raw,
          'durationMs': raw,
        })!;

        expect(restored.position, Duration.zero, reason: 'raw=$raw');
        expect(restored.duration, Duration.zero, reason: 'raw=$raw');
      }
    });

    test('值语义：字段全同即相等', () {
      const a = PlaybackProgressReport(
        itemId: '102',
        position: Duration(seconds: 20),
        duration: Duration(minutes: 90),
      );
      const b = PlaybackProgressReport(
        itemId: '102',
        position: Duration(seconds: 20),
        duration: Duration(minutes: 90),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('位置不同就不相等 —— 否则节流器之外的去重会误吞', () {
      const a = PlaybackProgressReport(
        itemId: '102',
        position: Duration(seconds: 20),
      );
      const b = PlaybackProgressReport(
        itemId: '102',
        position: Duration(seconds: 30),
      );

      expect(a == b, isFalse);
    });
  });

  group('ProgressThrottle 整十秒边界', () {
    test('0 秒不报 —— 刚打开就报会把上次进度覆盖成 0', () {
      final throttle = ProgressThrottle();

      expect(throttle.accept(Duration.zero), isNull);
      expect(throttle.accept(const Duration(milliseconds: 300)), isNull);
      expect(throttle.accept(const Duration(seconds: -3)), isNull);
    });

    test('非整十秒不报', () {
      final throttle = ProgressThrottle();

      for (final s in const [1, 3, 7, 9, 11, 19, 21, 99]) {
        expect(throttle.accept(Duration(seconds: s)), isNull, reason: '${s}s');
      }
    });

    test('整十秒报，且返回的位置就是喂进去的那个', () {
      final throttle = ProgressThrottle();
      const position = Duration(seconds: 10, milliseconds: 450);

      expect(throttle.accept(position), position);
    });

    test('同一个整十秒只报一次 —— 否则 10.0~10.9 会连报 10 条', () {
      final throttle = ProgressThrottle();

      expect(throttle.accept(const Duration(seconds: 10)), isNotNull);
      // mpv 的 position 是 ~100ms 一条的高频流，同一个整十秒会被喂很多次。
      for (final ms in const [100, 300, 500, 700, 900]) {
        expect(
          throttle.accept(Duration(seconds: 10, milliseconds: ms)),
          isNull,
          reason: '10.${ms}s',
        );
      }
    });

    test('走到下一个整十秒时恢复上报', () {
      final throttle = ProgressThrottle();

      expect(throttle.accept(const Duration(seconds: 10)), isNotNull);
      expect(throttle.accept(const Duration(seconds: 11)), isNull);
      expect(throttle.accept(const Duration(seconds: 20)), isNotNull);
      expect(throttle.accept(const Duration(seconds: 20)), isNull);
      expect(throttle.accept(const Duration(seconds: 30)), isNotNull);
    });

    test('跳到下一个整十秒照样报 —— 用户拖了进度条也认', () {
      final throttle = ProgressThrottle();

      expect(throttle.accept(const Duration(seconds: 10)), isNotNull);
      // 直接拖到 40 分 0 秒：跨过的那几个整十秒不补报，命中即报。
      expect(
        throttle.accept(const Duration(minutes: 40)),
        const Duration(minutes: 40),
      );
    });

    test('reset 后同一个整十秒可以再报 —— 换片必须重置', () {
      final throttle = ProgressThrottle();

      expect(throttle.accept(const Duration(seconds: 10)), isNotNull);
      expect(throttle.accept(const Duration(seconds: 10)), isNull);

      // 不重置的话：新片恰好停在上一部片报过的那个整十秒上时，
      // 那一次回报会被当成重复而吞掉。
      throttle.reset();

      expect(throttle.accept(const Duration(seconds: 10)), isNotNull);
    });

    test('间隔可配 —— 5 秒粒度', () {
      final throttle = ProgressThrottle(intervalSeconds: 5);

      expect(throttle.accept(const Duration(seconds: 5)), isNotNull);
      expect(throttle.accept(const Duration(seconds: 10)), isNotNull);
      // 10 不是 5 的倍数之外的秒数，仍然按 5 的倍数判定。
      expect(throttle.accept(const Duration(seconds: 12)), isNull);
      expect(throttle.accept(const Duration(seconds: 15)), isNotNull);
    });

    test('间隔非正数时永不报 —— 关掉节流不该变成「每条都报」', () {
      for (final interval in const [0, -1]) {
        final throttle = ProgressThrottle(intervalSeconds: interval);

        expect(throttle.accept(const Duration(seconds: 10)), isNull,
            reason: 'interval=$interval');
        expect(throttle.accept(const Duration(minutes: 30)), isNull,
            reason: 'interval=$interval');
      }
    });
  });
}
