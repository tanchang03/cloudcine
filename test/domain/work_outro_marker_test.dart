import 'package:flutter_test/flutter_test.dart';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';

/// **手标片尾**（`MediaWork.outroOffsetMs`，schema 19）的纯逻辑单测。
///
/// ## 为什么这一组值得单独写
///
/// 片尾与片头最大的不同是**它存的是距末尾的偏移，不是绝对时间**。
/// 这个表示法有两个只会在跨集播放时才暴露的失效：
///
///   1. 存成绝对时间 ⇒ 第 1 集标的 41:30 搬到片长 25 分钟的特辑上，
///      落点落在片长之后 ⇒ 片尾永远不触发（用户看到的是「标了没用」）；
///   2. 偏移比片长还大 ⇒ `duration - offset` 变成负数 ⇒ 落点落在 0 之前，
///      如果照单全收，播放器一进片就提示「已到片尾」。
///
/// 两条都是**静默**的，所以边界必须钉住。
void main() {
  MediaWork work({
    int? introStartMs,
    int? introEndMs,
    int? outroOffsetMs,
    int? learnedIntroStartMs,
    int? learnedIntroEndMs,
    int? learnedOutroOffsetMs,
    int learnedSamples = 0,
  }) =>
      MediaWork(
        key: 'quark:g1',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '测试剧',
        introStartMs: introStartMs,
        introEndMs: introEndMs,
        outroOffsetMs: outroOffsetMs,
        learnedIntroStartMs: learnedIntroStartMs,
        learnedIntroEndMs: learnedIntroEndMs,
        learnedOutroOffsetMs: learnedOutroOffsetMs,
        learnedSamples: learnedSamples,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  group('MediaWork.outroStart —— 手标片尾的落点', () {
    test('距末尾 90 秒 + 片长 43 分钟 → 落点在 41:30', () {
      final w = work(outroOffsetMs: 90_000);
      expect(
        w.outroStart(const Duration(minutes: 43)),
        const Duration(minutes: 41, seconds: 30),
      );
    });

    test('没标过 → null（不能编出一个「片尾 = 片长」的落点）', () {
      expect(work().outroStart(const Duration(minutes: 43)), isNull);
    });

    test('片长未知 → null —— 片长没出来之前算不出落点', () {
      // ⛔ 这里返回 `Duration.zero` 的话，播放器一进片就会提示「已到片尾」。
      expect(work(outroOffsetMs: 90_000).outroStart(Duration.zero), isNull);
    });

    test('偏移 ≥ 片长 → null，而不是一个 0 之前的落点', () {
      // 场景：用户在长片里标了「距末尾 10 分钟」，切到一集只有 8 分钟的
      // 花絮。落点会算成负数 —— 照单全收就是「一进片就报已到片尾」。
      final w = work(outroOffsetMs: 600_000);
      expect(w.outroStart(const Duration(minutes: 8)), isNull);
      // 恰好等于片长也不行：落点会是 0，等于「整集都是片尾」。
      expect(w.outroStart(const Duration(minutes: 10)), isNull);
      // 片长比偏移**多 1 毫秒**才成立（落点在 1 毫秒处）。
      expect(
        w.outroStart(const Duration(minutes: 10) + const Duration(milliseconds: 1)),
        const Duration(milliseconds: 1),
      );
    });

    test('⛔ 手标与学习读的是两组独立的列，互不干扰', () {
      // 「合在一处算」会让「你亲手标的被机器学出来的盖掉」这条回归无法被
      // 单独测出来 —— 两个方法刻意不互相调用，这里把这条约定钉住。
      final both = work(outroOffsetMs: 60_000, learnedOutroOffsetMs: 300_000);
      const duration = Duration(minutes: 43);
      expect(both.outroStart(duration), const Duration(minutes: 42));
      expect(both.learnedOutroStart(duration), const Duration(minutes: 38));
    });
  });

  group('MediaWork.hasManualSkip —— 片尾也算手标', () {
    test('只标了片尾 → 有手标（否则「清除手动标记」会消失）', () {
      expect(work(outroOffsetMs: 90_000).hasManualSkip, isTrue);
    });

    test('只标了片头起点（半条）→ 不算', () {
      // 与 `introRange` 的口径一致：半条区间跳不了，谈不上「标过」。
      expect(work(introStartMs: 5_000).hasManualSkip, isFalse);
    });

    test('完整片头区间 → 算', () {
      expect(
        work(introStartMs: 5_000, introEndMs: 95_000).hasManualSkip,
        isTrue,
      );
    });

    test('只有学习结论 → 不算手标', () {
      expect(
        work(learnedIntroEndMs: 88_000, learnedOutroOffsetMs: 70_000)
            .hasManualSkip,
        isFalse,
      );
    });
  });

  group('copyWith(clearIntro: true) —— 清除的是**三列**', () {
    test('片头起、片头止、片尾偏移一起清掉', () {
      // ⛔ 漏掉片尾那一列的后果：用户点了「清除手动标记」，片头不跳了，
      //    但片尾还在提示 —— 而界面上写着「已清除」，没有任何办法自己发现。
      final cleared = work(
        introStartMs: 5_000,
        introEndMs: 95_000,
        outroOffsetMs: 90_000,
      ).copyWith(clearIntro: true);

      expect(cleared.introStartMs, isNull);
      expect(cleared.introEndMs, isNull);
      expect(cleared.outroOffsetMs, isNull);
      expect(cleared.hasManualSkip, isFalse);
    });

    test('学习那一组不受影响 —— 清除手标不等于丢掉结论', () {
      final cleared = work(
        introStartMs: 5_000,
        introEndMs: 95_000,
        outroOffsetMs: 90_000,
        learnedIntroStartMs: 0,
        learnedIntroEndMs: 88_000,
        learnedOutroOffsetMs: 70_000,
        learnedSamples: 4,
      ).copyWith(clearIntro: true);

      expect(cleared.learnedIntroEndMs, 88_000);
      expect(cleared.learnedOutroOffsetMs, 70_000);
      expect(cleared.learnedSamples, 4);
    });
  });

  group('customized() —— 片尾也要参与「用户改过」的判定', () {
    /// `customized` 是「用户手改元数据」那一步：它把在线刮削的产物全部清空，
    /// 但**与刮削无关的列必须原样抄回来** —— 片头 / 片尾就在其中。
    MediaWork customize(MediaWork w) => w.customized(
          title: w.title,
          category: MediaCategory.series,
          updatedAt: w.updatedAt,
        );

    test('只标了片尾 → 清刮削数据之后仍然在（漏抄 = 跳片尾悄悄失效）', () {
      final after = customize(work(outroOffsetMs: 90_000));

      expect(after.outroOffsetMs, 90_000);
      expect(after.hasManualSkip, isTrue);
    });

    test('片头起止与学习结论也一起原样保留', () {
      final after = customize(
        work(
          introStartMs: 5_000,
          introEndMs: 95_000,
          outroOffsetMs: 90_000,
          learnedIntroEndMs: 88_000,
          learnedOutroOffsetMs: 70_000,
          learnedSamples: 4,
        ),
      );

      expect(after.introStartMs, 5_000);
      expect(after.introEndMs, 95_000);
      expect(after.outroOffsetMs, 90_000);
      expect(after.learnedIntroEndMs, 88_000);
      expect(after.learnedOutroOffsetMs, 70_000);
      expect(after.learnedSamples, 4);
    });

    test('clearIntro 之后 customized 保留的仍是 null', () {
      final w = work(outroOffsetMs: 90_000).copyWith(clearIntro: true);
      expect(customize(w).outroOffsetMs, isNull);
    });
  });
}
