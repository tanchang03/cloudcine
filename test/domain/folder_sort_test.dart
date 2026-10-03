import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/services/folder_sort.dart';
import 'package:flutter_test/flutter_test.dart';

/// 目录视图列表的排序。
///
/// ## 为什么值得一个文件
///
/// 「按什么排」有**两个入口**（目录视图工具条、设置页），而这两个入口读写的
/// 是同一份设置 —— 排错方向、或者 `null` 时间戳排到了第一行，用户看到的只是
/// 「列表顺序怪怪的」，不会有任何报错。这里守三件最容易写错的事：
///
///   1. 默认是**修改时间倒序**（不是名称升序）；
///   2. 时间未知的条目**垫底**，不冒充「1970 年的老片子」挤到最前面；
///   3. 时间相同时用名称定序 —— 网盘批量上传会给出整批相同的秒级时间戳，
///      不定序的话每次重列目录都可能换位置，表现为「列表在乱跳」。
void main() {
  DriveEntry file(String name, {DateTime? at, bool dir = false}) => DriveEntry(
        id: name,
        name: name,
        isDirectory: dir,
        modifiedAt: at,
      );

  group('FolderSortMode.parse：读不懂就退回默认', () {
    test('默认是修改时间倒序', () {
      expect(FolderSortMode.parse(null), FolderSortMode.modifiedTime,
          reason: '全新安装（设置里没有这个键）必须是「修改时间倒序」—— '
              '这正是这个功能被要求做成默认的那条理由：刚传的片子在第一行');
    });

    test('认两个枚举名', () {
      expect(FolderSortMode.parse('modifiedTime'), FolderSortMode.modifiedTime);
      expect(FolderSortMode.parse('fileName'), FolderSortMode.fileName);
    });

    test('空串 / 乱写的值 / 手改的值一律退回默认，不抛异常', () {
      // 一个坏掉的设置值不该让目录视图打不开。
      for (final raw in ['', ' ', 'name', 'modified', 'NAME', '0', '1']) {
        expect(
          FolderSortMode.parse(raw),
          FolderSortMode.modifiedTime,
          reason: '「$raw」读不懂时必须是默认值，而不是抛异常或某种空状态',
        );
      }
    });

    test('落库用的是枚举名本身（改名等于让老设置失效）', () {
      expect(FolderSortMode.modifiedTime.value, 'modifiedTime');
      expect(FolderSortMode.fileName.value, 'fileName');
    });
  });

  group('修改时间倒序（默认）', () {
    test('新的在前', () {
      final list = sortEntries(
        [
          file('旧', at: DateTime(2026, 9, 1)),
          file('新', at: DateTime(2026, 9, 30)),
          file('中', at: DateTime(2026, 9, 15)),
        ],
        FolderSortMode.modifiedTime,
      );

      expect(list.map((e) => e.name).toList(), ['新', '中', '旧']);
    });

    test('时间未知的垫底 —— 不能当 1970 年排到第一行', () {
      final list = sortEntries(
        [
          file('不知道', at: null),
          file('早', at: DateTime(2020, 1, 1)),
        ],
        FolderSortMode.modifiedTime,
      );

      expect(list.map((e) => e.name).toList(), ['早', '不知道'],
          reason: '用户点这个排序就是想先看最新的；把没有时间戳的条目顶到'
              '最前面，第一屏会变成一堆「不知道什么时候传的」');
    });

    test('全都不知道时间时，退回名称自然序（仍然有确定顺序）', () {
      final list = sortEntries(
        [file('第10期', at: null), file('第2期', at: null)],
        FolderSortMode.modifiedTime,
      );

      expect(list.map((e) => e.name).toList(), ['第2期', '第10期']);
    });

    test('时间相同 → 按名称自然序，保证每次刷新位置一致', () {
      // 网盘批量上传给出的时间戳精度只到秒，整批会撞在同一个值上。
      final same = DateTime(2026, 9, 30, 12, 0);
      final list = sortEntries(
        [file('第10集', at: same), file('第2集', at: same)],
        FolderSortMode.modifiedTime,
      );

      expect(list.map((e) => e.name).toList(), ['第2集', '第10集'],
          reason: '不定序的话相对位置取决于 List.sort 的内部行为 —— '
              '每次重列目录都可能换位置，用户会以为列表在乱跳');
    });
  });

  group('名称自然序', () {
    test('数字段按数值比（第2期 在 第10期 前面）', () {
      final list = sortEntries(
        [file('第10期'), file('第2期')],
        FolderSortMode.fileName,
      );

      expect(list.map((e) => e.name).toList(), ['第2期', '第10期']);
    });

    test('完全不看修改时间', () {
      final list = sortEntries(
        [
          file('b', at: DateTime(2026, 9, 30)),
          file('a', at: DateTime(2026, 9, 1)),
        ],
        FolderSortMode.fileName,
      );

      expect(list.map((e) => e.name).toList(), ['a', 'b']);
    });
  });

  group('sortEntries 不修改入参', () {
    test('返回新列表，原列表顺序不动', () {
      final original = [
        file('b', at: DateTime(2026, 9, 1)),
        file('a', at: DateTime(2026, 9, 30)),
      ];
      final sorted = sortEntries(original, FolderSortMode.modifiedTime);

      expect(original.map((e) => e.name).toList(), ['b', 'a'],
          reason: '原列表就是 provider 缓存里的那一份，就地排会把它改掉 —— '
              '下次别人读到的是一个「已经被排过」的列表');
      expect(sorted.map((e) => e.name).toList(), ['a', 'b']);
      expect(identical(original, sorted), isFalse);
    });
  });

  group('sortListing：目录永远排在视频前面，其他文件永远垫底', () {
    test('三组各自排，组间顺序不受排序方式影响', () {
      final folders = [
        file('第10季', at: DateTime(2026, 9, 1), dir: true),
        file('第2季', at: DateTime(2026, 9, 30), dir: true),
      ];
      final videos = [
        file('Show.S01E10.mkv', at: DateTime(2026, 9, 1)),
        file('Show.S01E02.mkv', at: DateTime(2026, 9, 30)),
      ];
      final others = [
        file('Show.S01E10.chs.srt', at: DateTime(2026, 9, 1)),
        file('Show.S01E02.chs.srt', at: DateTime(2026, 9, 30)),
      ];

      final byTime =
          sortListing(folders, videos, others, FolderSortMode.modifiedTime);
      expect(byTime.folders.map((e) => e.name).toList(), ['第2季', '第10季']);
      expect(
        byTime.videos.map((e) => e.name).toList(),
        ['Show.S01E02.mkv', 'Show.S01E10.mkv'],
      );
      expect(
        byTime.others.map((e) => e.name).toList(),
        ['Show.S01E02.chs.srt', 'Show.S01E10.chs.srt'],
      );

      final byName =
          sortListing(folders, videos, others, FolderSortMode.fileName);
      expect(byName.folders.map((e) => e.name).toList(), ['第2季', '第10季']);
      expect(
        byName.videos.map((e) => e.name).toList(),
        ['Show.S01E02.mkv', 'Show.S01E10.mkv'],
      );
      expect(
        byName.others.map((e) => e.name).toList(),
        ['Show.S01E02.chs.srt', 'Show.S01E10.chs.srt'],
      );
    });

    test('返回值就是三组，谁都不会混进别人的组里', () {
      final r = sortListing(
        [file('d', dir: true)],
        [file('v.mkv')],
        [file('sub.srt'), file('cover.jpg')],
        FolderSortMode.fileName,
      );

      expect(r.folders.single.name, 'd');
      expect(r.videos.single.name, 'v.mkv');
      expect(r.others.map((e) => e.name).toList(), ['cover.jpg', 'sub.srt']);
    });

    test('其他文件永远垫底：按修改时间排也一样，不会插到视频前面', () {
      // 这条是**结构**而不是顺序：同目录里一部片子往往配好几条字幕，
      // 让「刚传上来的字幕」排到视频前面，会把「这一层有几部片子」
      // 这件事冲散 —— 而用户翻目录时第一眼看的就是这个。
      final r = sortListing(
        const [],
        [file('old.mkv', at: DateTime(2026, 1, 1))],
        [file('new.srt', at: DateTime(2026, 9, 30))],
        FolderSortMode.modifiedTime,
      );

      expect(r.videos.single.name, 'old.mkv');
      expect(r.others.single.name, 'new.srt');
    });
  });
}
