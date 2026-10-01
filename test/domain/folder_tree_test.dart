import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/folder_tree.dart';
import 'package:flutter_test/flutter_test.dart';

/// 网盘目录树。
///
/// 它是「按位置找片子」这条路径上唯一的结构来源，而它的输入只有
/// `MediaItem.dirPath` 一个字符串。所以这里的每条断言都对应一个
/// **界面上看得见、但不会报错**的症状：目录少了一层、计数对不上、
/// 顺序乱掉、搜索搜不到。
void main() {
  final now = DateTime(2026, 10, 1);

  var seq = 0;
  MediaItem item(
    String dirPath,
    String name, {
    int sizeBytes = 0,
    String? title,
  }) {
    seq++;
    return MediaItem(
      provider: DriveProvider.quark,
      fileId: 'f$seq',
      name: name,
      dirId: 'd$seq',
      dirPath: dirPath,
      groupKey: title ?? name,
      kind: MediaKind.movie,
      title: title,
      sizeBytes: sizeBytes,
      firstSeenAt: now,
      updatedAt: now,
    );
  }

  group('建树', () {
    test('空列表 → 只有根，且根是空的', () {
      final tree = FolderTree.build(const []);
      expect(tree.root.isRoot, isTrue);
      expect(tree.root.path, '/');
      expect(tree.root.children, isEmpty);
      expect(tree.root.files, isEmpty);
      expect(tree.fileCount, 0);
      // 根不算「子目录」，否则界面上的「N 个文件夹」会凭空多一个。
      expect(tree.subfolderCount, 0);
    });

    test('根目录下的文件挂在根上（dirPath 就是 `/`）', () {
      final tree = FolderTree.build([item('/', 'A.mkv')]);
      expect(tree.root.files.single.name, 'A.mkv');
      expect(tree.root.itemCount, 1);
      expect(tree.subfolderCount, 0);
    });

    test('中间层没有文件时目录链要自动补齐', () {
      // 扫描器是深度优先走的，完全可能出现「只扫到叶子」的片段
      // （例如中间层全是空目录）。少补一层的话，面包屑会缺一段，
      // 而用户点「上一级」会跳到一个不存在的路径上。
      final tree = FolderTree.build([item('/电影/科幻/2023/', 'A.mkv')]);
      expect(tree.subfolderCount, 3);
      final mid = tree.nodeAt('/电影/科幻');
      expect(mid, isNotNull);
      expect(mid!.children.single.name, '2023');
      expect(tree.nodeAt('/电影')!.parentPath, '/');
    });

    test('同名目录在不同父目录下是两个节点', () {
      final tree = FolderTree.build([
        item('/电影/2023/', 'A.mkv'),
        item('/剧集/2023/', 'B.mkv'),
      ]);
      expect(tree.subfolderCount, 4);
      expect(tree.nodeAt('/电影/2023')!.files.single.name, 'A.mkv');
      expect(tree.nodeAt('/剧集/2023')!.files.single.name, 'B.mkv');
    });

    test('路径带不带结尾斜杠指向同一个节点', () {
      // 扫描器写的是 `/电影/`，而界面手里的往往是 `/电影`。
      // 两者被当成两个节点的话，目录列表里会出现两个「电影」。
      final tree = FolderTree.build([
        item('/电影/', 'A.mkv'),
        item('/电影', 'B.mkv'),
      ]);
      expect(tree.subfolderCount, 1);
      expect(tree.nodeAt('/电影')!.files.length, 2);
      expect(tree.nodeAt('/电影/')!.files.length, 2);
    });
  });

  group('汇总数字是递归的', () {
    test('计数与体积含全部子孙', () {
      final tree = FolderTree.build([
        item('/电影/', 'root.mkv', sizeBytes: 100),
        item('/电影/科幻/', 'a.mkv', sizeBytes: 1000),
        item('/电影/科幻/', 'b.mkv', sizeBytes: 2000),
        item('/电影/科幻/2023/', 'c.mkv', sizeBytes: 3000),
      ]);

      final movie = tree.nodeAt('/电影')!;
      expect(movie.directFileCount, 1);
      expect(movie.itemCount, 4);
      expect(movie.totalBytes, 6100);

      final scifi = tree.nodeAt('/电影/科幻')!;
      expect(scifi.directFileCount, 2);
      expect(scifi.itemCount, 3);
      expect(scifi.totalBytes, 6000);
      // 为什么必须是递归的：用户看「电影」这一行时想知道的是这个分类下
      // 总共多少片，而不是「直接躺在这个目录里的有几个」。
      expect(tree.root.itemCount, 4);
      expect(tree.root.totalBytes, 6100);
    });

    test('拿不到体积的项按 0 计，不会让合计变成 null', () {
      final tree = FolderTree.build([
        item('/电影/', 'a.mkv', sizeBytes: 500),
        item('/电影/', 'b.mkv'),
      ]);
      expect(tree.nodeAt('/电影')!.totalBytes, 500);
    });
  });

  group('排序', () {
    test('子目录按自然序（第2期 在 第10期 前面）', () {
      final tree = FolderTree.build([
        for (final n in ['第10期', '第2期', '第1期'])
          item('/综艺/Show/$n/', '$n.mkv'),
      ]);
      expect(
        tree.nodeAt('/综艺/Show')!.children.map((c) => c.name).toList(),
        ['第1期', '第2期', '第10期'],
      );
    });

    test('同一层内的文件按自然序', () {
      final tree = FolderTree.build([
        for (final n in ['E10', 'E2', 'E1'])
          item('/剧/Show/', '$n.mkv'),
      ]);
      expect(
        tree.nodeAt('/剧/Show')!.files.map((f) => f.name).toList(),
        ['E1.mkv', 'E2.mkv', 'E10.mkv'],
      );
    });

    test('全局文件列表按目录聚在一起', () {
      // 搜索结果是按这个顺序平铺的：同一目录的文件要连着出现，
      // 否则用户看到的是「路径跳来跳去」的一串。
      final tree = FolderTree.build([
        item('/b/', 'x.mkv'),
        item('/a/', 'y.mkv'),
        item('/a/', 'z.mkv'),
      ]);
      expect(tree.files.map((f) => f.dirPath).toList(), ['/a/', '/a/', '/b/']);
    });
  });

  group('面包屑链路', () {
    test('从根到当前目录，含首尾', () {
      final tree = FolderTree.build([item('/电影/科幻/2023/', 'A.mkv')]);
      final chain = tree.pathTo('/电影/科幻/2023');
      expect(chain.map((n) => n.name).toList(), ['/', '电影', '科幻', '2023']);
      expect(chain.first.isRoot, isTrue);
      expect(chain.last.path, '/电影/科幻/2023');
    });

    test('根自己的链路只有它自己', () {
      final tree = FolderTree.build(const []);
      expect(tree.pathTo('/').map((n) => n.name).toList(), ['/']);
    });

    test('路径不存在时返回空列表（而不是抛异常）', () {
      // 重扫之后目录可能已经没了，UI 要能据此给出「回到根目录」的出路。
      final tree = FolderTree.build([item('/电影/', 'A.mkv')]);
      expect(tree.pathTo('/已经不在了'), isEmpty);
      expect(tree.nodeAt('/已经不在了'), isNull);
    });
  });

  group('搜索', () {
    final tree = FolderTree.build([
      item('/电影/科幻/', 'Dune.2021.2160p.mkv', title: '沙丘'),
      item('/电影/剧情/', 'Nomadland.2020.mkv'),
      item('/剧集/科幻/', 'Severance.S01E01.mkv'),
    ]);

    test('按文件名匹配', () {
      expect(tree.findFiles('dune').single.name, 'Dune.2021.2160p.mkv');
    });

    test('按**路径**匹配 —— 这才是「按文件夹路径找文件」', () {
      // 用户经常记得「在 /剧集/科幻/ 下面」却记不住片名。
      final hits = tree.findFiles('/剧集/科幻');
      expect(hits.single.name, 'Severance.S01E01.mkv');
    });

    test('目录名片段也能命中路径', () {
      final hits = tree.findFiles('科幻');
      expect(hits.map((f) => f.name).toSet(),
          {'Dune.2021.2160p.mkv', 'Severance.S01E01.mkv'});
    });

    test('大小写不敏感', () {
      expect(tree.findFiles('DUNE'), hasLength(1));
    });

    test('空关键词不返回任何东西', () {
      // 返回全部的话，一进目录视图就会把整库铺出来（而搜索框是空的）。
      expect(tree.findFiles('   '), isEmpty);
      expect(tree.findFolders(''), isEmpty);
    });

    test('找目录：按名字与路径，且不含根', () {
      final hits = tree.findFolders('科幻');
      expect(
        hits.map((f) => f.path).toSet(),
        {'/电影/科幻', '/剧集/科幻'},
      );
      // 根永远命中「任何关键词的子串」判断里的空串那一档，必须排掉，
      // 否则搜索结果里会莫名其妙多一条「根目录」。
      expect(tree.findFolders('/').any((f) => f.isRoot), isFalse);
    });

    test('limit 生效，避免关键词太宽泛时拉出整库', () {
      final many = FolderTree.build([
        for (var i = 0; i < 50; i++) item('/电影/', 'A$i.mkv'),
      ]);
      expect(many.findFiles('a', limit: 10), hasLength(10));
    });
  });

  group('路径工具（与 core/utils/drive_paths 同口径）', () {
    test('归一化 / 父级 / 末段名', () {
      expect(FolderTree.normalize('/电影/'), '/电影');
      expect(FolderTree.parentOf('/电影/科幻'), '/电影');
      expect(FolderTree.parentOf('/'), '/');
      expect(FolderTree.nameOf('/电影/科幻'), '科幻');
      expect(FolderTree.segments('/电影/科幻'), ['电影', '科幻']);
      expect(FolderTree.withTrailingSlash('/电影'), '/电影/');
    });
  });
}
