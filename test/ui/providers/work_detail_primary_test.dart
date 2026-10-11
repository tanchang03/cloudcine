import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// `WorkDetail.primary` —— 「详情页点播放会播哪一条」。
///
/// ## 为什么值得单独钉
///
/// 它同时决定两件事，而两件事**必须是同一格**：
///   1. 「播放」按钮播哪一条；
///   2. 打开详情页时默认高亮哪一季（`_resolveSeason` 拿它去找所在的那一格）。
///
/// 2026-10-10 现场：这里曾经是 `features.first` —— **永远第一集**。于是
/// 「在电脑上从详情页点播放，永远从第 1 集开始」，而同一部剧在电视上（简介页
/// 的播放胶囊走 `PlayTarget.resolve`）会接着上次看的那一集。用户报的是
/// 「不同环境最后播放集数不一样」。
///
/// 这类回归**不会报错**：播错一集看起来跟「本来就是这样」一模一样，只有
/// 拿两部设备对着比才看得出来。所以把它固化成用例。
///
/// 断言一律打**终态**（`primary` 的 id），不打「调用了哪个方法」——
/// 口径换了实现方式也不该红，除非它真的播错了那一集。
void main() {
  final now = DateTime.now();

  MediaItem ep(
    int episode, {
    bool extra = false,
    DateTime? playedAt,
  }) {
    final fileId = extra ? 'EX$episode' : 'E$episode';
    return MediaItem(
      provider: DriveProvider.quark,
      fileId: fileId,
      name: extra ? '花絮$episode.mkv' : 'AOT.S01E$episode.mkv',
      dirId: 'd1',
      dirPath: '/动漫/进击的巨人/',
      groupKey: 'aot',
      kind: MediaKind.episode,
      title: '进击的巨人',
      season: 1,
      episode: episode,
      durationMs: 60 * 60 * 1000,
      firstSeenAt: now,
      updatedAt: now,
      lastPlayedAt: playedAt,
      isSampleOrExtra: extra,
    );
  }

  MediaWork work() => MediaWork(
        key: 'aot',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '进击的巨人',
        updatedAt: now,
      );

  /// `items` 要按「季 → 集 → 名称」排好 —— 那是 `itemsForWork` 的承诺，
  /// `PlayTarget.resolve` 不重排（重排就多一处可能与仓储层不一致的地方）。
  WorkDetail detail(
    List<MediaItem> items, {
    Map<String, Duration> resume = const {},
  }) =>
      WorkDetail(work: work(), items: items, resumePositions: resume);

  String idOf(int episode, {bool extra = false}) =>
      MediaItem.idFor(DriveProvider.quark, extra ? 'EX$episode' : 'E$episode');

  test('一集都没播过 → 第一条（行为与「取第一条」的旧实现一致）', () {
    final d = detail([ep(1), ep(2), ep(3)]);

    expect(
      d.primary?.id,
      idOf(1),
      reason: '全新作品没有任何进度可依据，只能给第一集 —— 这一步不能变',
    );
  });

  test('还留着续播点的那一集优先 —— 不是第一条', () {
    final d = detail(
      [ep(1), ep(2), ep(3)],
      resume: {idOf(3): const Duration(minutes: 12)},
    );

    expect(
      d.primary?.id,
      idOf(3),
      reason: '用户点播放的意图是「接着上次看」。给第 1 集等于每次都要手动翻回去 '
          '—— 而电视上会接着第 3 集，两台设备就此对不上。',
    );
  });

  test('续播点有好几处时，取最近播放的那一集', () {
    final d = detail(
      [ep(1), ep(2), ep(3)],
      resume: {
        idOf(1): const Duration(minutes: 5),
        idOf(3): const Duration(minutes: 5),
      },
    );
    // 播放时刻在 items 上（`MediaItem.lastPlayedAt`），不来自 resume。
    final withPlayedAt = WorkDetail(
      work: work(),
      items: [
        ep(1, playedAt: now.subtract(const Duration(days: 3))),
        ep(2),
        ep(3, playedAt: now.subtract(const Duration(hours: 1))),
      ],
      resumePositions: {
        idOf(1): const Duration(minutes: 5),
        idOf(3): const Duration(minutes: 5),
      },
    );

    expect(
      withPlayedAt.primary?.id,
      idOf(3),
      reason: '两条都有续播点时，判据只能是「哪一条更近播过」',
    );
    // 没有播放时刻（老库）时退到列表顺序的最后一个，而不是第一条 ——
    // 那比「第一条」更接近「他看到哪儿了」。
    expect(d.primary?.id, idOf(3));
  });

  test('看完的那一集（续播点已清）仍然回到那一集，而不是第 1 集', () {
    final d = WorkDetail(
      work: work(),
      items: [
        ep(1),
        ep(2, playedAt: now.subtract(const Duration(hours: 2))),
        ep(3),
      ],
      // 「看完」的语义就是续播点被清掉 —— 这里刻意什么都不传。
      resumePositions: const {},
    );

    expect(
      d.primary?.id,
      idOf(2),
      reason: '`lastPlayedAt` 有值 + 没有续播点，既可能是「看完了」也可能是'
          '「点开 3 秒就关了」。猜「下一集」会把用户丢到一集他根本没看过的'
          '内容上；重看一集的开头代价小得多。',
    );
  });

  test('花絮不参与挑选 —— 哪怕它排在前面而且播过', () {
    final d = WorkDetail(
      work: work(),
      items: [
        ep(1, extra: true, playedAt: now),
        ep(1),
        ep(2),
      ],
      resumePositions: {idOf(1, extra: true): const Duration(minutes: 3)},
    );

    expect(
      d.primary?.id,
      idOf(1),
      reason: '点《进击的巨人》看到 3 分钟的花絮，是这套规则一开始就要避免的坑',
    );
  });

  test('整组只有花絮时也挑得出来 —— 不许返回 null', () {
    final d = WorkDetail(
      work: work(),
      items: [ep(1, extra: true), ep(2, extra: true)],
      resumePositions: const {},
    );

    expect(
      d.primary?.id,
      idOf(1, extra: true),
      reason: '「正片为空就返回 null」会让这些条目在界面上等于不存在（播放按钮'
          '永远灰着），而它们其实播得出来',
    );
  });
}
