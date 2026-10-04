import 'package:cloudcine/domain/services/playback_restore.dart';
import 'package:flutter_test/flutter_test.dart';

/// 换源后「起播位置到底生效了没有」的核对。
///
/// 为什么值得测：`EngineMedia.startAt` 是一条**静默**的路 —— 内核没照做时
/// 没有任何回调报错。判错的代价是两个方向都很难看，而且都不报错：
///   - 该补的时候没补 → 用户报的「切清晰度后从头开始播」；
///   - 不该补的时候补了 → 画面在用户眼皮底下自己跳一下。
void main() {
  const target = Duration(seconds: 1800);
  const total = Duration(seconds: 5400);

  group('startAt 生效时一次都不该补', () {
    test('连续两拍都在目标附近 → 直接了结', () {
      final restore = RestoreSeek(target);

      expect(
        restore.observe(const Duration(milliseconds: 1800400), Duration.zero),
        RestoreSeekAction.wait,
        reason: '第一拍只作参考，还不能断定到位',
      );
      expect(
        restore.observe(const Duration(milliseconds: 1800900), total),
        RestoreSeekAction.settle,
      );
      expect(restore.attempts, 0, reason: '一次 seek 都不该补 —— 白补就是画面自己跳一下');
      expect(restore.isDone, isTrue);
    });

    test('⚠️ 落点差一两秒也算到位（mpv 的 start 落在关键帧上）', () {
      // 判太紧会把「生效了」当成「没生效」，于是每次切档都多补一次 seek。
      final restore = RestoreSeek(target);

      expect(
        restore.observe(const Duration(seconds: 1802), total),
        RestoreSeekAction.wait,
      );
      expect(
        restore.observe(const Duration(seconds: 1803), total),
        RestoreSeekAction.settle,
      );
      expect(restore.attempts, 0);
    });

    test('了结之后不再有任何动作', () {
      final restore = RestoreSeek(target);
      restore.observe(const Duration(seconds: 1800), total);
      restore.observe(const Duration(seconds: 1800), total);

      expect(restore.observe(const Duration(seconds: 0), total),
          RestoreSeekAction.settle);
      expect(restore.attempts, 0, reason: '已经了结的欠账不该再补');
    });
  });

  group('⚠️ 故障现场：startAt 没生效', () {
    test('位置从头开始推进 → 补一次 seek 回目标', () {
      // 用户报的那条：「选择画质后都会重头就开始播放」。
      // 内核报了 0，而且时长已经解出来（说明解复用器就绪）—— 这时补发才不会被丢掉。
      final restore = RestoreSeek(target);

      expect(restore.observe(Duration.zero, total), RestoreSeekAction.seek);
      expect(restore.attempts, 1);
      expect(restore.target, target, reason: '补发的目标必须是换源前那个位置');
    });

    test('时长还没解出来，但位置已经推进 → 同样可以补', () {
      // 直播型 HLS 没有时长，只能靠「位置在动」当就绪信号。
      final restore = RestoreSeek(target);

      expect(restore.observe(Duration.zero, Duration.zero),
          RestoreSeekAction.wait);
      expect(
        restore.observe(const Duration(milliseconds: 500), Duration.zero),
        RestoreSeekAction.seek,
      );
    });

    test('补发后仍没落到位 → 继续补，直到上限', () {
      // 第一次补发可能撞上解复用器刚就绪的那一瞬而被丢掉，所以要允许重试。
      final restore = RestoreSeek(target, maxAttempts: 3);

      expect(restore.observe(Duration.zero, total), RestoreSeekAction.seek);
      expect(restore.observe(const Duration(seconds: 1), total),
          RestoreSeekAction.seek);
      expect(restore.observe(const Duration(seconds: 2), total),
          RestoreSeekAction.seek);
      expect(restore.attempts, 3);
    });

    test('⚠️ 到上限就收手，不能无限空转', () {
      // 遇上真的不可 seek 的流，无限补 = 每 100ms 一次 seek。
      final restore = RestoreSeek(target, maxAttempts: 2);

      expect(restore.observe(Duration.zero, total), RestoreSeekAction.seek);
      expect(restore.observe(const Duration(seconds: 1), total),
          RestoreSeekAction.seek);
      expect(restore.observe(const Duration(seconds: 2), total),
          RestoreSeekAction.settle);
      expect(restore.isDone, isTrue);
      expect(restore.observe(const Duration(seconds: 3), total),
          RestoreSeekAction.settle);
      expect(restore.attempts, 2);
    });

    test('补发之后落到位 → 了结，且不再多补', () {
      final restore = RestoreSeek(target);

      expect(restore.observe(Duration.zero, total), RestoreSeekAction.seek);
      expect(restore.observe(const Duration(seconds: 1800), total),
          RestoreSeekAction.wait);
      expect(restore.observe(const Duration(seconds: 1801), total),
          RestoreSeekAction.settle);
      expect(restore.attempts, 1, reason: '补一次就够，落到位之后别再补');
    });
  });

  group('⚠️ 旧流的位置回报不能当成「到位」', () {
    test('只报了一拍目标位置（旧流残留）→ 仍然要补', () {
      // 换源期间旧流还在播（见 `_prepareSource` 的预热），位置流上会夹着
      // 一条旧流的值 —— 而它恰好等于目标（目标就是从旧流取的）。
      // 只认一拍的话会被它骗过去，于是新流真的从头播也没人管。
      final restore = RestoreSeek(target);

      expect(restore.observe(const Duration(seconds: 1800), Duration.zero),
          RestoreSeekAction.wait);
      expect(restore.observe(Duration.zero, total), RestoreSeekAction.seek);
      expect(restore.attempts, 1);
    });

    test('旧流与新流交替回报 → 没有一次能凑成「连续两拍」', () {
      // 真落到位会**一直**报那个位置；交替出现说明其中一条是残留。
      final restore = RestoreSeek(target, maxAttempts: 3);

      expect(restore.observe(const Duration(seconds: 1800), total),
          RestoreSeekAction.wait, reason: '第一拍看着像到位，但只有一拍');
      expect(restore.observe(Duration.zero, total), RestoreSeekAction.seek,
          reason: '第二拍露馅了 —— 位置掉回 0');
      expect(restore.observe(const Duration(seconds: 1801), total),
          RestoreSeekAction.wait, reason: '又只有一拍，仍然不算');
      expect(restore.observe(const Duration(seconds: 1), total),
          RestoreSeekAction.seek);
      expect(restore.attempts, 2);
    });
  });

  group('就绪之前一律不补', () {
    test('时长未知 + 位置纹丝不动 → 一直等', () {
      // 「open 之后立刻 seek 会被丢掉」是实测过的（`PlaybackMedia` 的 E 行），
      // 那时解复用器还没就绪 —— 补了等于没补，还白白把「补发次数」用掉。
      final restore = RestoreSeek(target);

      expect(restore.observe(Duration.zero, Duration.zero),
          RestoreSeekAction.wait);
      expect(restore.observe(Duration.zero, Duration.zero),
          RestoreSeekAction.wait);
      expect(restore.observe(Duration.zero, Duration.zero),
          RestoreSeekAction.wait);
      expect(restore.attempts, 0);
      expect(restore.isDone, isFalse, reason: '还没就绪，不能提前收手');
    });
  });

  group('没有可恢复的东西时不挂欠账', () {
    test('目标本身就在容差里 → 立刻了结，不补', () {
      // 「刚开播一两秒就切档」就是这种情况：补一次 seek 到 2 秒毫无意义，
      // 而它会让画面闪一下。
      final restore = RestoreSeek(const Duration(seconds: 2));

      expect(restore.isDone, isTrue);
      expect(restore.observe(Duration.zero, total), RestoreSeekAction.settle);
      expect(restore.attempts, 0);
    });
  });
}
