import 'package:cloudcine/core/utils/seek_acceleration.dart';
import 'package:flutter_test/flutter_test.dart';

/// 长按 / 连按快退快进的步长累加。
///
/// ## 为什么值得单独一个文件
///
/// 这条在 TV 上不是「更顺手」，而是**除数字键之外唯一的长距离移动手段** ——
/// 遥控器的方向键拖不动进度条（实测，见评估文档 §5.5）。判据写错有两种坏法，
/// 而且都不报错：
///
///   * 门槛太紧（把长按判成两串）→ 用户按住不放，每次只跳 10 秒，
///     看起来就像「长按没用」；
///   * 门槛太松（把连点判成同一串）→ 用户手快按三下，一下比一下跳得远，
///     看起来就像「按键坏了」。
///
/// 所以这里逐条钉住「什么算同一串」。
void main() {
  group('seekStepFor：步长表', () {
    test('起步是 10 秒 —— 用户按一下就是想要一个 10 秒', () {
      expect(seekStepFor(0), const Duration(seconds: 10));
      expect(seekStepFor(1), const Duration(seconds: 10));
      expect(seekStepFor(2), const Duration(seconds: 10));
    });

    test('连按升级：30 秒 → 1 分钟 → 5 分钟封顶', () {
      expect(seekStepFor(3), const Duration(seconds: 30));
      expect(seekStepFor(5), const Duration(seconds: 30));
      expect(seekStepFor(6), const Duration(seconds: 60));
      expect(seekStepFor(9), const Duration(seconds: 60));
      expect(seekStepFor(10), const Duration(seconds: 300));
    });

    test('封顶之后不再涨 —— 再大就只剩「蒙」了', () {
      expect(seekStepFor(11), seekStepFor(10));
      expect(seekStepFor(1000), seekStepFor(10));
      expect(
        seekStepFor(1000),
        lessThanOrEqualTo(const Duration(minutes: 5)),
        reason: '长按到底也不该一步跨过一集剧的一半：5 分钟已经覆盖'
            '「45 分钟里挪四分之一」，更远的距离该用数字键跳百分比。',
      );
    });

    test('步长单调不减（漏一档会让长按感觉「忽然变慢」）', () {
      var previous = Duration.zero;
      for (var i = 0; i <= 12; i++) {
        final step = seekStepFor(i);
        expect(step, greaterThanOrEqualTo(previous), reason: 'streak=$i');
        previous = step;
      }
    });
  });

  group('SeekRepeatTracker：什么算「同一串」', () {
    /// 可控时钟 —— 判据是「两次之间隔了多久」，不注入就没法测。
    late DateTime now;
    SeekRepeatTracker tracker() => SeekRepeatTracker(now: () => now);

    setUp(() => now = DateTime(2026, 10, 2, 12));

    test('第一下就是 10 秒', () {
      expect(tracker().step(1), const Duration(seconds: 10));
    });

    test('同方向、间隔小于门槛 → 累加（这就是「长按」）', () {
      final t = tracker();

      expect(t.step(1), const Duration(seconds: 10));
      now = now.add(const Duration(milliseconds: 50));
      expect(t.step(1), const Duration(seconds: 10));
      now = now.add(const Duration(milliseconds: 50));
      expect(t.step(1), const Duration(seconds: 10));
      now = now.add(const Duration(milliseconds: 50));
      expect(
        t.step(1),
        const Duration(seconds: 30),
        reason: '第 4 下开始升级。硬件重复间隔实测 33–50ms，'
            '若这里没升档，就说明门槛把长按判成了两串。',
      );
      expect(t.streak, 3);
    });

    test('间隔超过门槛 → 当成新的一串，退回 10 秒', () {
      final t = tracker();

      t.step(1);
      now = now.add(seekHoldGap + const Duration(milliseconds: 1));
      expect(
        t.step(1),
        const Duration(seconds: 10),
        reason: '「按一下、等一下、再按一下」是两次独立的微调，'
            '不该第二下就跳 30 秒。',
      );
      expect(t.streak, 0);
    });

    test('正好等于门槛 → 仍算同一串（边界含在内）', () {
      final t = tracker();
      t.step(1);
      now = now.add(seekHoldGap);
      t.step(1);
      expect(t.streak, 1, reason: '边界取「不超过」，与文档里的 `<=` 一致。');
    });

    test('换方向 → 从头算（← 完了立刻按 → 不该继承 ← 的档位）', () {
      final t = tracker();

      t.step(-1);
      now = now.add(const Duration(milliseconds: 50));
      t.step(-1);
      expect(t.streak, 1);

      now = now.add(const Duration(milliseconds: 50));
      expect(
        t.step(1),
        const Duration(seconds: 10),
        reason: '方向变了就是另一件事 —— 用户刚退过头、现在要往前找。',
      );
      expect(t.streak, 0);
    });

    test('reset 之后从头算（松手 / 跳了别处 / 唤回控制栏）', () {
      final t = tracker();

      for (var i = 0; i < 8; i++) {
        now = now.add(const Duration(milliseconds: 50));
        t.step(1);
      }
      expect(t.streak, greaterThan(0));

      t.reset();
      expect(t.streak, 0);
      expect(t.step(1), const Duration(seconds: 10));
    });

    test('direction 的符号是唯一的判据 —— 传 -1 / +1 之外的量级也按符号算', () {
      final t = tracker();

      t.step(-1);
      now = now.add(const Duration(milliseconds: 50));
      t.step(-9999);
      expect(
        t.streak,
        1,
        reason: '调用方只该传 ±1，但符号相同的超大值不该被当成换方向 —— '
            '换方向误判的后果是长按中途忽然退回 10 秒。',
      );
    });
  });
}
