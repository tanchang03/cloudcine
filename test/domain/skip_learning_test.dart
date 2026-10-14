import 'package:cloudcine/domain/services/skip_learning.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一集 45 分钟的片子（学习门槛 `minDuration = 8min` 之上）。
const _episode = Duration(minutes: 45);

SkipSample _sample({
  required SkipKind kind,
  required Duration anchor,
  Duration duration = _episode,
  bool negative = false,
  String itemId = 'q:1',
  String workKey = 'w',
  DateTime? at,
}) =>
    SkipSample(
      id: '$itemId#${kind.name}',
      itemId: itemId,
      workKey: workKey,
      kind: kind,
      anchor: anchor,
      duration: duration,
      negative: negative,
      createdAt: at ?? DateTime(2026, 10, 11),
    );

/// 用户拖了一次并**停下来看了**。
SkipAnchor? _seekAndWatch(
  SkipAnchorCollector c, {
  required Duration from,
  required Duration to,
  Duration duration = _episode,
  double rate = 1.0,
  Duration watch = SkipLearning.stableWatch,
}) {
  c.noteSeek(
    SeekObservation(from: from, to: to, duration: duration, rate: rate),
  );
  return c.notePosition(to + watch);
}

void main() {
  group('有效落点：只有「停下来看」才算', () {
    test('拖到 92 秒并停留 ⇒ 确认片头锚点', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final anchor = _seekAndWatch(
        c,
        from: Duration.zero,
        to: const Duration(seconds: 92),
      );

      expect(anchor, isNotNull);
      expect(anchor!.anchor, const Duration(seconds: 92));
      expect(SkipLearning.classify(anchor), SkipKind.intro);
    });

    test('停留不够长就不确认（探索性拖拽）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final anchor = _seekAndWatch(
        c,
        from: Duration.zero,
        to: const Duration(seconds: 92),
        watch: const Duration(seconds: 5),
      );

      expect(anchor, isNull, reason: '看 5 秒不算「停下来」');
      expect(c.pending, const Duration(seconds: 92), reason: '落点仍在待确认');
    });

    test('拖了又拖 ⇒ 只有最后一个落点作数', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      c.noteSeek(
        const SeekObservation(
          from: Duration.zero,
          to: Duration(seconds: 92),
          duration: _episode,
          rate: 1.0,
        ),
      );
      // 还没停留够就又往前拖了一次 —— 第一个落点作废。
      final first = _seekAndWatch(
        c,
        from: const Duration(seconds: 92),
        to: const Duration(seconds: 110),
      );

      expect(first, isNotNull);
      expect(
        first!.anchor,
        const Duration(seconds: 110),
        reason: '用户最后停下来的位置才是有效落点',
      );
    });

    test('回拖 ⇒ 该落点作废（「拖拽点不在片头片尾」的主力场景）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      c.noteSeek(
        const SeekObservation(
          from: Duration.zero,
          to: Duration(seconds: 92),
          duration: _episode,
          rate: 1.0,
        ),
      );
      // 用户拖回去重看片头 —— 说明 92 秒不是他要跳过的位置。
      final anchor = c.notePosition(const Duration(seconds: 10));

      expect(anchor, isNull);
      expect(c.pending, isNull, reason: '回拖之后不该再留着待确认落点');
    });

    test('后退方向的 seek 根本不记（用户想回看，不是想跳过）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      c.noteSeek(
        const SeekObservation(
          from: Duration(minutes: 10),
          to: Duration(minutes: 3),
          duration: _episode,
          rate: 1.0,
        ),
      );

      expect(c.pending, isNull);
    });

    test('幅度太小的 seek 不记（防抖 / 误触）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      c.noteSeek(
        const SeekObservation(
          from: Duration(seconds: 90),
          to: Duration(seconds: 91),
          duration: _episode,
          rate: 1.0,
        ),
      );

      expect(c.pending, isNull);
    });

    test('倍速播放时的 seek 不记（位置语义变了）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      c.noteSeek(
        const SeekObservation(
          from: Duration.zero,
          to: Duration(seconds: 92),
          duration: _episode,
          rate: 2.0,
        ),
      );

      expect(c.pending, isNull);
    });
  });

  group('片头 / 片尾分类', () {
    test('落点在正片中间 ⇒ 既不是片头也不是片尾', () {
      final anchor = SkipAnchor(
        anchor: const Duration(minutes: 20),
        duration: _episode,
        playStart: Duration.zero,
      );

      expect(SkipLearning.classify(anchor), isNull);
    });

    test('续播（起播在第 5 分钟）⇒ 不产生片头锚点', () {
      final anchor = SkipAnchor(
        anchor: const Duration(seconds: 92),
        duration: _episode,
        playStart: const Duration(minutes: 5),
      );

      expect(
        SkipLearning.classify(anchor),
        isNull,
        reason: '用户没看过开头，「0 → 落点」这个区间不成立',
      );
    });

    test('落点距末尾 40 秒 ⇒ 片尾', () {
      final anchor = SkipAnchor(
        anchor: _episode - const Duration(seconds: 40),
        duration: _episode,
        playStart: Duration.zero,
      );

      expect(SkipLearning.classify(anchor), SkipKind.outro);
    });

    test('短视频（8 分钟以内）不学习 —— 两个窗口会重叠', () {
      final short = const Duration(minutes: 6);
      final anchor = SkipAnchor(
        anchor: const Duration(minutes: 5, seconds: 30),
        duration: short,
        playStart: Duration.zero,
      );

      expect(SkipLearning.classify(anchor), isNull);
    });
  });

  group('片尾靠「切下一集」确认，不靠停留', () {
    test('拖到片尾并停留 ⇒ 不产出片尾锚点（可能只是在看结尾）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final anchor = _seekAndWatch(
        c,
        from: Duration(minutes: 10),
        to: _episode - const Duration(seconds: 40),
      );

      expect(
        anchor,
        isNull,
        reason: '停留确认不可撤回，而「看完」与「切集」在那一刻分不清',
      );
    });

    test('从距末尾 40 秒处切下一集 ⇒ 产出片尾锚点', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final anchor = c.noteEpisodeSwitch(
        position: _episode - const Duration(seconds: 40),
        duration: _episode,
      );

      expect(anchor, isNotNull);
      expect(anchor!.offset, const Duration(seconds: 40));
    });

    test('自然播完自动连播 ⇒ 不产出片尾锚点（偏移几乎为 0）', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final anchor = c.noteEpisodeSwitch(
        position: _episode - const Duration(seconds: 1),
        duration: _episode,
      );

      expect(anchor, isNull, reason: '用户把结尾看完了，那里不是片尾');
    });

    test('看了 10 秒就切集 ⇒ 什么都不产出', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final anchor = c.noteEpisodeSwitch(
        position: const Duration(seconds: 10),
        duration: _episode,
      );

      expect(anchor, isNull);
    });

    test('同一次播放里片尾最多产一条', () {
      final c = SkipAnchorCollector();
      c.notePlayStart(Duration.zero);

      final first = c.noteEpisodeSwitch(
        position: _episode - const Duration(seconds: 40),
        duration: _episode,
      );
      final second = c.noteEpisodeSwitch(
        position: _episode - const Duration(seconds: 30),
        duration: _episode,
      );

      expect(first, isNotNull);
      expect(second, isNull);
    });
  });

  group('跨集聚合：中位数 + MAD', () {
    test('三集落点一致 ⇒ 学出片头', () {
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'q:1'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 92), itemId: 'q:2'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 91), itemId: 'q:3'),
      ];

      final intro = SkipLearning.learnIntro(samples);

      expect(intro, isNotNull);
      expect(intro!.end, const Duration(seconds: 91));
      expect(intro.samples, 3);
      expect(intro.spread, const Duration(seconds: 1));
    });

    test('一个离群点不影响结论（中位数免疫）', () {
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'q:1'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 92), itemId: 'q:2'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 91), itemId: 'q:3'),
        // 用户在某集拖到了第 20 分钟看剧情 —— 均值会被拽到 6 分钟，
        // 中位数几乎不动。
        _sample(kind: SkipKind.intro, anchor: const Duration(minutes: 20), itemId: 'q:4'),
      ];

      final intro = SkipLearning.learnIntro(samples);

      expect(intro, isNotNull);
      expect(
        intro!.end,
        const Duration(milliseconds: 91500),
        reason: '四个样本的中位数 = 中间两个(91s, 92s)的平均 = 91.5s —— '
            '离群点没有把它拽走（均值会被拽到 6 分钟）',
      );
      expect(
        intro.spread,
        const Duration(seconds: 1),
        reason: 'MAD 只看到 1 秒的散布，完全不受那个 20 分钟的离群点影响',
      );
    });

    test('落点散得厉害 ⇒ 拒绝建立（宁可不生效）', () {
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 20), itemId: 'q:1'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'q:2'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 160), itemId: 'q:3'),
      ];

      expect(
        SkipLearning.learnIntro(samples),
        isNull,
        reason: '各集片头位置差异过大（MAD 70s > 8s），说明这不是一个稳定片头',
      );
    });

    test('样本不足 3 集 ⇒ 拒绝建立', () {
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'q:1'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 91), itemId: 'q:2'),
      ];

      expect(SkipLearning.learnIntro(samples), isNull);
    });

    test('负样本不参与聚合', () {
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'q:1'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 91), itemId: 'q:2'),
        _sample(
          kind: SkipKind.intro,
          anchor: const Duration(minutes: 30),
          itemId: 'q:3',
          negative: true,
        ),
      ];

      expect(
        SkipLearning.learnIntro(samples),
        isNull,
        reason: '去掉负样本只剩 2 条，够不到门槛',
      );
    });

    test('片尾用「距末尾的偏移」聚合，各集片长不同也能对齐', () {
      // 正片 45 分钟、特辑 60 分钟 —— 绝对时间差 15 分钟，
      // 但「离结尾 40 秒开始是片尾」是一致的。
      final samples = [
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(seconds: 40),
          itemId: 'q:1',
        ),
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(seconds: 42),
          itemId: 'q:2',
        ),
        _sample(
          kind: SkipKind.outro,
          anchor: const Duration(minutes: 60) - const Duration(seconds: 41),
          duration: const Duration(minutes: 60),
          itemId: 'q:3',
        ),
      ];

      final outro = SkipLearning.learnOutro(samples);

      expect(outro, isNotNull);
      expect(outro!.offset, const Duration(seconds: 41));
      expect(outro.samples, 3);
    });

    test('片尾偏移超过 5 分钟 ⇒ 那不是片尾，是「跳到中后段」', () {
      final samples = [
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(minutes: 12),
          itemId: 'q:1',
        ),
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(minutes: 12),
          itemId: 'q:2',
        ),
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(minutes: 12),
          itemId: 'q:3',
        ),
      ];

      expect(SkipLearning.learnOutro(samples), isNull);
    });

    test('片头与片尾一起学出来', () {
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'q:1'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 92), itemId: 'q:2'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 91), itemId: 'q:3'),
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(seconds: 40),
          itemId: 'q:1',
        ),
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(seconds: 42),
          itemId: 'q:2',
        ),
        _sample(
          kind: SkipKind.outro,
          anchor: _episode - const Duration(seconds: 41),
          itemId: 'q:3',
        ),
      ];

      final outcome = SkipLearning.learn(samples);

      expect(outcome.intro, isNotNull);
      expect(outcome.outro, isNotNull);
      expect(outcome.samples, 3, reason: '取两者的较大值');
      expect(outcome.isEmpty, isFalse);
    });

    test('样本表里混着别的作品的样本时，调用方负责先按 workKey 过滤', () {
      // 这一条是**契约提醒**：`learn*` 只认传进来的列表，
      // 不自己按 workKey 分组 —— 分组是仓储层的事（一条 SQL）。
      final samples = [
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'a:1', workKey: 'A'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'b:1', workKey: 'B'),
        _sample(kind: SkipKind.intro, anchor: const Duration(seconds: 90), itemId: 'c:1', workKey: 'C'),
      ];

      expect(SkipLearning.learnIntro(samples), isNotNull);
    });
  });

  group('中位数工具', () {
    test('奇数个取中间', () {
      expect(
        SkipLearning.median(const [
          Duration(seconds: 3),
          Duration(seconds: 1),
          Duration(seconds: 2),
        ]),
        const Duration(seconds: 2),
      );
    });

    test('偶数个取中间两个的平均', () {
      expect(
        SkipLearning.median(const [
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 3),
          Duration(seconds: 4),
        ]),
        const Duration(milliseconds: 2500),
      );
    });

    test('空列表返回 null', () {
      expect(SkipLearning.median(const []), isNull);
    });
  });
}
