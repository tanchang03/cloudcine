import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/item_sort.dart';
import 'package:flutter_test/flutter_test.dart';

/// 详情页「文件」列表的排序。
///
/// ## 为什么值得一个文件
///
/// 三个选项里有两件**写错了不报错、只表现为「列表顺序怪」**的事：
///
///   1. 时间未知（网盘没给 `modified`）的条目排到哪一头；
///   2. 时间相同时怎么定序 —— 网盘对一次批量上传只给到秒，一整季会撞在
///      同一个时间戳上，不定序的话每次重开详情页都可能换位置。
///
/// 还有一条更隐蔽的：`episodeOrder` 必须是**原样返回**，而不是在这里重排
/// 一遍「季 → 部 → 集」—— 那条规则的唯一实现在仓储层，抄第二份就会出现
/// 「层级选择器高亮 Part.1、列表第一行却是 Part.2」这种对不上的情况。
void main() {
  final now = DateTime(2026, 10, 3);

  MediaItem item(String name, {DateTime? at, int? season, int? episode}) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: name,
        name: name,
        dirId: 'd1',
        dirPath: '/剧/',
        groupKey: 'g',
        kind: MediaKind.episode,
        title: '剧',
        season: season,
        episode: episode,
        modifiedAt: at,
        firstSeenAt: now,
        updatedAt: now,
      );

  List<String> names(List<MediaItem> items) =>
      items.map((i) => i.name).toList();

  group('ItemSortMode.parse：读不懂就退回默认', () {
    test('默认是修改时间倒序', () {
      expect(
        ItemSortMode.parse(null),
        ItemSortMode.modifiedDesc,
        reason: '全新安装（设置里没有这个键）必须是「修改时间倒序」—— '
            '这一页除了看剧，另一个高频用途是核对刚传上去的东西入库没有',
      );
    });

    test('认三个枚举名', () {
      expect(ItemSortMode.parse('episodeOrder'), ItemSortMode.episodeOrder);
      expect(ItemSortMode.parse('modifiedDesc'), ItemSortMode.modifiedDesc);
      expect(ItemSortMode.parse('modifiedAsc'), ItemSortMode.modifiedAsc);
    });

    test('空串 / 乱写的值 / 手改的值一律退回默认，不抛异常', () {
      // 一个坏掉的设置值不该让详情页打不开。
      for (final raw in ['', ' ', 'time', 'modified', 'DESC', '0', '1']) {
        expect(
          ItemSortMode.parse(raw),
          ItemSortMode.modifiedDesc,
          reason: '「$raw」读不懂时必须是默认值，而不是抛异常或某种空状态',
        );
      }
    });

    test('落库用的是枚举名本身（改名等于让老设置失效）', () {
      expect(ItemSortMode.episodeOrder.value, 'episodeOrder');
      expect(ItemSortMode.modifiedDesc.value, 'modifiedDesc');
      expect(ItemSortMode.modifiedAsc.value, 'modifiedAsc');
    });

    test('三个选项的 label 互不相同 —— 否则菜单里会出现两条一样的字', () {
      final labels = ItemSortMode.values.map((m) => m.label).toSet();
      expect(labels.length, ItemSortMode.values.length);
    });
  });

  group('剧集顺序：原样返回，不重排', () {
    test('完全保持入参顺序（哪怕时间戳是反的）', () {
      // 入参顺序 = 仓储层排好的「季 → 部 → 集 → 名称」。
      // 在这里按时间重排一次，就等于把「剧集顺序」这个选项做没了。
      final input = [
        item('S01E01.mkv', at: DateTime(2026, 9, 30), season: 1, episode: 1),
        item('S01E02.mkv', at: DateTime(2026, 9, 1), season: 1, episode: 2),
        item('S01E03.mkv', at: DateTime(2026, 9, 15), season: 1, episode: 3),
      ];

      expect(
        names(sortItems(input, ItemSortMode.episodeOrder)),
        ['S01E01.mkv', 'S01E02.mkv', 'S01E03.mkv'],
      );
    });
  });

  group('修改时间倒序（默认）', () {
    test('新的在前', () {
      final sorted = sortItems(
        [
          item('旧', at: DateTime(2026, 9, 1)),
          item('新', at: DateTime(2026, 9, 30)),
          item('中', at: DateTime(2026, 9, 15)),
        ],
        ItemSortMode.modifiedDesc,
      );

      expect(names(sorted), ['新', '中', '旧']);
    });

    test('时间未知的垫底 —— 不能当 1970 年排到第一行', () {
      final sorted = sortItems(
        [
          item('不知道', at: null),
          item('早', at: DateTime(2020, 1, 1)),
        ],
        ItemSortMode.modifiedDesc,
      );

      expect(
        names(sorted),
        ['早', '不知道'],
        reason: '用户切到这个排序就是想先看最新的；把没有时间戳的条目顶到'
            '最前面，第一屏会变成一堆「不知道什么时候传的」',
      );
    });

    test('时间相同 → 按名称自然序，保证每次打开位置一致', () {
      // 网盘批量上传给出的时间戳精度只到秒，一整季会撞在同一个值上。
      final same = DateTime(2026, 9, 30, 12, 0);
      final sorted = sortItems(
        [item('第10集.mkv', at: same), item('第2集.mkv', at: same)],
        ItemSortMode.modifiedDesc,
      );

      expect(
        names(sorted),
        ['第2集.mkv', '第10集.mkv'],
        reason: '不定序的话相对位置取决于 List.sort 的内部行为 —— '
            '每次重开详情页都可能换位置，用户会以为列表在乱跳',
      );
    });

    test('全都不知道时间时，退回名称自然序（仍然有确定顺序）', () {
      final sorted = sortItems(
        [item('第10集.mkv', at: null), item('第2集.mkv', at: null)],
        ItemSortMode.modifiedDesc,
      );

      expect(names(sorted), ['第2集.mkv', '第10集.mkv']);
    });
  });

  group('修改时间正序', () {
    test('旧的在前', () {
      final sorted = sortItems(
        [
          item('旧', at: DateTime(2026, 9, 1)),
          item('新', at: DateTime(2026, 9, 30)),
          item('中', at: DateTime(2026, 9, 15)),
        ],
        ItemSortMode.modifiedAsc,
      );

      expect(names(sorted), ['旧', '中', '新']);
    });

    test('时间未知的**仍然垫底** —— 「不知道」不是「最旧」', () {
      // 这一条是正序独有的坑：把 null 当成最小值，它就会排到第一行，
      // 造出一堆「看起来比谁都早」的条目。两个方向的边界口径必须一致。
      final sorted = sortItems(
        [
          item('不知道', at: null),
          item('旧', at: DateTime(2020, 1, 1)),
          item('新', at: DateTime(2026, 9, 30)),
        ],
        ItemSortMode.modifiedAsc,
      );

      expect(names(sorted), ['旧', '新', '不知道']);
    });

    test('时间相同 → 与倒序同一套名称定序（两个方向看到的名字顺序一致）', () {
      final same = DateTime(2026, 9, 30, 12, 0);
      final sorted = sortItems(
        [item('第10集.mkv', at: same), item('第2集.mkv', at: same)],
        ItemSortMode.modifiedAsc,
      );

      expect(names(sorted), ['第2集.mkv', '第10集.mkv']);
    });
  });

  group('sortItems 不修改入参', () {
    test('返回新列表，原列表顺序不动', () {
      final original = [
        item('b.mkv', at: DateTime(2026, 9, 1)),
        item('a.mkv', at: DateTime(2026, 9, 30)),
      ];
      final sorted = sortItems(original, ItemSortMode.modifiedDesc);

      expect(
        names(original),
        ['b.mkv', 'a.mkv'],
        reason: '原列表就是 `WorkLevels` 里那一份，就地排会把它改掉 —— '
            '`primary`（点播放会播哪一条）正是从它算的',
      );
      expect(names(sorted), ['a.mkv', 'b.mkv']);
      expect(identical(original, sorted), isFalse);
    });

    test('剧集顺序这一档也返回新列表，不把入参原样交出去', () {
      final original = [item('a.mkv', at: null)];
      final sorted = sortItems(original, ItemSortMode.episodeOrder);

      expect(identical(original, sorted), isFalse);
    });
  });

  group('compareItemsByTime：直接测两个边界', () {
    test('null 与 null 之间用名称定序，不是「相等」', () {
      final a = item('第10集.mkv', at: null);
      final b = item('第2集.mkv', at: null);

      expect(
        compareItemsByTime(a, b, descending: false) > 0,
        isTrue,
        reason: '返回 0 会让它们的相对位置交给 List.sort 的内部行为',
      );
    });

    test('一边是 null → null 那一方永远靠后，正序倒序都一样', () {
      final known = item('有.mkv', at: DateTime(2026, 1, 1));
      final unknown = item('无.mkv', at: null);

      expect(compareItemsByTime(unknown, known, descending: true) > 0, isTrue);
      expect(compareItemsByTime(unknown, known, descending: false) > 0, isTrue);
      expect(compareItemsByTime(known, unknown, descending: true) < 0, isTrue);
      expect(compareItemsByTime(known, unknown, descending: false) < 0, isTrue);
    });
  });
}
