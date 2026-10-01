import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/play_target.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「点开这部作品，该播哪一条」。
///
/// 这条规则的作用点是**海报墙上的一次点击**，用户不会看到任何提示 ——
/// 播错了他只会觉得「这软件怎么老从头开始」。所以下面每一条都对应一个
/// 具体的、能被用户感知的症状。
void main() {
  final now = DateTime(2026, 9, 30);

  MediaItem ep(int n, {bool extra = false}) => MediaItem(
        provider: DriveProvider.quark,
        fileId: 'f$n',
        name: 'Show.S01E${n.toString().padLeft(2, '0')}.mkv',
        dirId: 'd1',
        dirPath: '/剧/Show/',
        groupKey: 'show',
        kind: MediaKind.episode,
        title: 'Show',
        season: 1,
        episode: n,
        isSampleOrExtra: extra,
        firstSeenAt: now,
        updatedAt: now,
      );

  test('全新作品 → 第一集', () {
    final items = [ep(1), ep(2), ep(3)];
    expect(PlayTarget.resolve(items: items)?.episode, 1);
  });

  test('有没看完的一集 → 那一集（「接着看」优先级最高）', () {
    final items = [ep(1), ep(2), ep(3)];
    final picked = PlayTarget.resolve(
      items: items,
      resume: {'quark:f3': const Duration(minutes: 20)},
      lastPlayedAt: {
        'quark:f1': now.subtract(const Duration(days: 2)),
        'quark:f3': now,
      },
    );
    // 第 3 集没看完 → 播第 3 集，而不是「最近播放列表里的第一项」。
    expect(picked?.episode, 3);
  });

  test('最近播放的那一集已看完 → 仍然回到那一集，不猜下一集', () {
    final items = [ep(1), ep(2), ep(3)];
    final picked = PlayTarget.resolve(
      items: items,
      // 看完的集续播点会被清掉，所以这里刻意没有 resume。
      resume: const {},
      lastPlayedAt: {'quark:f2': now},
    );
    // 为什么不跳到第 3 集：`lastPlayedAt` 有值 + 没有续播点，既可能是
    // 「看完了」，也可能是「点开 3 秒就关了」。猜错会把用户丢到一集他
    // 根本没看过的内容上，而猜错的代价远大于「重看一集的开头」。
    expect(picked?.episode, 2);
  });

  test('续播点落在更早的一集、播放时刻落在更晚的一集 → 取续播的那一集', () {
    // 这是真实会发生的状态：第 5 集看到一半，随手点开第 8 集看了两分钟
    // （不够 5 秒没存续播点？不，10 秒粒度），总之第 8 集没有续播点。
    final items = [ep(5), ep(8)];
    final picked = PlayTarget.resolve(
      items: items,
      resume: {'quark:f5': const Duration(minutes: 30)},
      lastPlayedAt: {
        'quark:f5': now.subtract(const Duration(hours: 1)),
        'quark:f8': now,
      },
    );
    // 判据是「**没看完**」而不是「最近」。第 8 集没有续播点，说明它要么
    // 看完了要么刚点开就关 —— 两种情况都不是「接着看」。
    expect(picked?.episode, 5);
  });

  test('多条续播点 → 取播放时刻最新的那一条', () {
    final items = [ep(1), ep(2), ep(3)];
    final picked = PlayTarget.resolve(
      items: items,
      resume: {
        'quark:f1': const Duration(minutes: 10),
        'quark:f2': const Duration(minutes: 30),
      },
      lastPlayedAt: {
        'quark:f1': now,
        'quark:f2': now.subtract(const Duration(days: 1)),
      },
    );
    expect(picked?.episode, 1);
  });

  test('有续播点但完全没有播放时刻（老库） → 取集号最大的那一集', () {
    final items = [ep(1), ep(2), ep(3)];
    final picked = PlayTarget.resolve(
      items: items,
      resume: {'quark:f3': const Duration(minutes: 5)},
    );
    // 列表顺序是「季 → 集」，所以最后一项就是用户看得最靠后的一集。
    // 退化到「列表第一项」会让每次点开都回到第 1 集。
    expect(picked?.episode, 3);
  });

  test('花絮不参与挑选 —— 点《流浪地球》不该播 40 秒的预告', () {
    final items = [
      ep(1, extra: true),
      ep(2),
      ep(3),
    ];
    expect(PlayTarget.resolve(items: items)?.episode, 2);
  });

  test('整组都是花絮时仍然能播（退回全部候选）', () {
    // 只有花絮的作品也该能点开，否则那些条目在媒体库界面上等于不存在。
    final items = [ep(1, extra: true), ep(2, extra: true)];
    expect(PlayTarget.resolve(items: items)?.episode, 1);
  });

  test('只有一条 → 就是它（电影、单集花絮）', () {
    final items = [ep(7)];
    expect(PlayTarget.resolve(items: items)?.episode, 7);
  });

  test('空作品 → null（调用方据此提示「没有可播放的文件」）', () {
    expect(PlayTarget.resolve(items: const []), isNull);
  });

  test('零续播点等于「没有续播点」', () {
    // `resumePositions` 的口径是「没存过的条目不出现在 Map 里」，
    // 但存了 0 的情况在边界上出现过 —— 两者都必须被当成「没看到一半」。
    final items = [ep(1), ep(2)];
    final picked = PlayTarget.resolve(
      items: items,
      resume: {'quark:f2': Duration.zero},
      lastPlayedAt: {'quark:f2': now},
    );
    expect(picked?.episode, 2);
  });
}
