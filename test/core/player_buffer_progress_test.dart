import 'package:cloudcine/core/utils/player_buffer_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// 进度条上「已缓冲」那一层的算法。
///
/// ## 为什么这条规则值得单独钉住
///
/// mpv 给的 `demuxer-cache-time` 是「播放头**前面**缓存了多少秒」，而直觉上
/// 会把它当成「从头下载了多少秒」。算错的后果**不是报错，是进度条悄悄画错**：
/// 一部 45 分钟的片子上，正确值是「播到 10:00、缓存到 10:30」，错算成
/// 「30 秒 / 2700 秒 = 1.1%」，那条缓冲线就永远趴在最左边不动 —— 用户看到
/// 的是「缓冲条坏了」，而日志里什么都没有。
void main() {
  const total = Duration(minutes: 45);
  const position = Duration(minutes: 10);
  const ahead = Duration(seconds: 30);

  group('fraction', () {
    test('缓冲到的位置 = 播放头 + 已缓存秒数', () {
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheAhead: ahead,
        duration: total,
      );

      // 10:00 + 30s = 10:30，占 45 分钟的 7/27。
      expect(f, closeTo((10 * 60 + 30) / (45 * 60), 1e-9));
    });

    test('缓存为 0 时缓冲层停在播放头，而不是掉回 0', () {
      // 「一点都没缓存」的正确画法是「缓冲到播放头为止」—— 播放头左边的数据
      // 一定已经拿到了。掉回 0 会画出一条比已播还短的缓冲线。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheAhead: Duration.zero,
        duration: total,
      );

      expect(f, closeTo(10 / 45, 1e-9));
    });

    test('缓存量超过总时长时夹到 1.0', () {
      // 1 GB 缓存上限下整部片子常被全部缓存完。不夹的话缓冲层会画到轨道外面去。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheAhead: const Duration(hours: 2),
        duration: total,
      );

      expect(f, 1.0);
    });

    test('负的缓存量按 0 处理，缓冲层不退到播放头之后', () {
      // mpv 偶尔报一个浮点毛刺。真的拿它去减，缓冲线会跑到已播线的左边 ——
      // 那在进度条上是一眼可见的破图。
      final f = PlayerBufferProgress.fraction(
        position: position,
        cacheAhead: const Duration(seconds: -5),
        duration: total,
      );

      expect(f, closeTo(10 / 45, 1e-9));
    });

    test('时长未知时不给比例（null = 不要画这一层）', () {
      // 时长还没解出来时画什么都是编的。返回 0 会画出「一点都没缓冲」，
      // 返回 1 会画出「全都缓存好了」，两个都是假信息。
      expect(
        PlayerBufferProgress.fraction(
          position: position,
          cacheAhead: ahead,
          duration: Duration.zero,
        ),
        isNull,
      );
    });

    test('时长未知且位置也是 0 时同样不给比例', () {
      expect(
        PlayerBufferProgress.fraction(
          position: Duration.zero,
          cacheAhead: Duration.zero,
          duration: Duration.zero,
        ),
        isNull,
      );
    });

    test('缓存填满整片时是 1.0', () {
      final f = PlayerBufferProgress.fraction(
        position: const Duration(minutes: 5),
        cacheAhead: const Duration(minutes: 40),
        duration: total,
      );

      expect(f, 1.0);
    });
  });

  group('positionOf', () {
    test('把「前面多少秒」换算成绝对位置', () {
      expect(
        PlayerBufferProgress.positionOf(position: position, cacheAhead: ahead),
        const Duration(minutes: 10, seconds: 30),
      );
    });

    test('负增量不减', () {
      expect(
        PlayerBufferProgress.positionOf(
          position: position,
          cacheAhead: const Duration(seconds: -5),
        ),
        position,
      );
    });
  });
}
