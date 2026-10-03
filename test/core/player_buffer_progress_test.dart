import 'package:cloudcine/core/utils/player_buffer_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度条上「已缓冲」那一层的算法。
///
/// ## 为什么这条规则值得单独钉住
///
/// mpv 的 `demuxer-cache-time` 是**绝对时间戳**（「已缓存区间的结束位置」），
/// 而它长得太像「前面还有多少秒」了 —— 直觉上会顺手把播放头加上去。
///
/// 算错的后果**不是报错，是进度条悄悄画错**，而且错得很有规律：
/// 每跳一次进度条，缓冲层就凭空多出**一整个播放头**那么长。
/// 2026-10-03 用户实测：《黑暗荣耀》播到 12:07 / 全长 47:17 时，
/// 真实缓存到 13:2x，界面画到 25:5x —— 于是他看到「一点进度就缓存了一大截，
/// 可画面照样卡」，日志里干干净净。
///
/// 所以下面的断言一律**写明这个数字为什么重要**，而不是只对一遍算术。
void main() {
  const total = Duration(minutes: 45);
  const position = Duration(minutes: 10);

  group('positionOf', () {
    test('缓冲终点就是 mpv 报的那个时间戳，不加播放头', () {
      // 「缓存到了 12:00」就是 12:00。再加一次 10:00 是本次事故的成因。
      expect(
        PlayerBufferProgress.positionOf(
          position: position,
          cacheEnd: const Duration(minutes: 12),
        ),
        const Duration(minutes: 12),
      );
    });

    test('非正的缓存终点退回播放头，而不是掉回 0', () {
      // 还没解出任何缓存数据时 mpv 给 0。掉回 0 会画出一条比已播还短的
      // 缓冲线 —— 播放头左边的数据一定已经拿到了，那是明显的破图。
      expect(
        PlayerBufferProgress.positionOf(
          position: position,
          cacheEnd: Duration.zero,
        ),
        position,
      );
      expect(
        PlayerBufferProgress.positionOf(
          position: position,
          cacheEnd: const Duration(seconds: -5),
        ),
        position,
      );
    });

    test('缓存终点落在播放头后面时也退回播放头', () {
      // seek 到旧缓存区间之外的一瞬间就会这样：mpv 在 seek 过程中把
      // `ts_duration` 置 0，但 `ts_end` **不会**同步清零，于是会短暂地报出
      // 一个属于**旧位置**的时间戳。不退回去的话缓冲层会跑到已播线左边。
      expect(
        PlayerBufferProgress.positionOf(
          position: const Duration(minutes: 10),
          cacheEnd: const Duration(minutes: 3),
        ),
        const Duration(minutes: 10),
      );
    });
  });

  group('fraction', () {
    test('缓冲比例 = 缓存终点 ÷ 总时长', () {
      // 10:00 播到 12:00 缓存完 → 12/45。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheEnd: const Duration(minutes: 12),
        duration: total,
      );

      expect(f, closeTo(12 / 45, 1e-9));
    });

    test('回归：跳进度条之后不能把播放头算两遍', () {
      // 用户实测的那一组数：《黑暗荣耀》47:17 的片子播到 12:07。
      //   · 正确：缓存终点 13:20 → 800s / 2837s ≈ 28.2%
      //   · 事故：播放头 + 缓存终点 = 1527s / 2837s ≈ 53.8%
      // 后者正是「一跳就缓存了一大截」的观感。这条断言存在的唯一目的
      // 就是让那个写法再也回不来。
      const totalSec = 47 * 60 + 17;
      const positionSec = 12 * 60 + 7;
      const cacheEndSec = 13 * 60 + 20;

      final f = PlayerBufferProgress.fraction(
        position: const Duration(seconds: positionSec),
        cacheEnd: const Duration(seconds: cacheEndSec),
        duration: const Duration(seconds: totalSec),
      );

      expect(f, closeTo(cacheEndSec / totalSec, 1e-9));
      expect(f, isNot(closeTo((positionSec + cacheEndSec) / totalSec, 1e-3)));
    });

    test('缓存终点超过总时长时夹到 1.0', () {
      // 1 GB 缓存上限下整部片子常被全部缓存完。不夹的话缓冲层会画到轨道外面。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheEnd: const Duration(hours: 2),
        duration: total,
      );

      expect(f, 1.0);
    });

    test('时长未知时不给比例（null = 不要画这一层）', () {
      // 时长还没解出来时画什么都是编的。返回 0 会画出「一点都没缓冲」，
      // 返回 1 会画出「全都缓存好了」，两个都是假信息。
      expect(
        PlayerBufferProgress.fraction(
          position: position,
          cacheEnd: const Duration(minutes: 12),
          duration: Duration.zero,
        ),
        isNull,
      );
    });

    test('时长未知且位置也是 0 时同样不给比例', () {
      expect(
        PlayerBufferProgress.fraction(
          position: Duration.zero,
          cacheEnd: Duration.zero,
          duration: Duration.zero,
        ),
        isNull,
      );
    });

    test('mpv 说在等数据时，缓冲层收回到播放头', () {
      // `paused-for-cache`（media_kit 的 `stream.buffering`）是 mpv 直接报的
      // **状态**，不经过任何换算。它说明播放头前面已经没有可用数据了 ——
      // 这时界面再宣称前面有缓冲，用户唯一能据此做的判断（能不能往前拖）
      // 就会全错。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheEnd: const Duration(minutes: 12),
        duration: total,
        stalled: true,
      );

      // 与「缓存终点就是播放头」同一个落点。
      expect(f, closeTo(10 / 45, 1e-9));
    });

    test('卡顿时哪怕缓存终点看着很远也不往前画', () {
      // 同上，只是缓存终点报得更大：mpv 都说了在等数据，就不能往前画。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheEnd: const Duration(minutes: 30),
        duration: total,
        stalled: true,
      );

      expect(f, closeTo(10 / 45, 1e-9));
    });
  });
}
