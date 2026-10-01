import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:flutter_test/flutter_test.dart';

/// `MediaRepository.listItems` —— 目录视图的数据入口。
///
/// 它是唯一一条「不按作品读」的查询，所以也是**唯一**能回答
/// 「文件在网盘上的哪个目录」的地方。这里用内存实现钉住语义
/// （drift 实现是它的等价 SQL，两边口径必须一致）。
void main() {
  final now = DateTime(2026, 10, 1);
  var seq = 0;

  MediaItem item(String dirPath, String name) {
    seq++;
    return MediaItem(
      provider: DriveProvider.quark,
      fileId: 'f$seq',
      name: name,
      dirId: 'd$seq',
      dirPath: dirPath,
      groupKey: name,
      kind: MediaKind.movie,
      firstSeenAt: now,
      updatedAt: now,
    );
  }

  Future<InMemoryMediaRepository> seeded() async {
    final repo = InMemoryMediaRepository();
    await repo.upsertItems([
      item('/电影/科幻/', 'Dune.2021.mkv'),
      item('/电影/科幻/', 'Arrival.2016.mkv'),
      item('/电影/剧情/', 'Nomadland.mkv'),
      item('/电影2/', 'Trap.mkv'),
      item('/剧集/科幻/', 'Severance.S01E01.mkv'),
      item('/', 'Root.mkv'),
    ]);
    return repo;
  }

  test('不带条件 → 全部，且按「目录路径 → 文件名」排序', () async {
    final repo = await seeded();
    final all = await repo.listItems();
    expect(all, hasLength(6));

    // 同一目录的文件必须连着出现 —— 搜索结果就是按这个顺序平铺的，
    // 顺序乱了用户看到的就是「路径跳来跳去」的一串。
    final dirs = all.map((i) => i.dirPath).toList();
    expect(dirs, List.of(dirs)..sort());

    // 目录内按**自然序**（SQL 只能给字节序，所以实现里在 Dart 侧又排了一遍）。
    final scifi = all
        .where((i) => i.dirPath == '/电影/科幻/')
        .map((i) => i.name)
        .toList();
    expect(scifi, ['Arrival.2016.mkv', 'Dune.2021.mkv']);
  });

  test('pathPrefix 取该目录**及其子孙**', () async {
    final repo = await seeded();
    final hits = await repo.listItems(pathPrefix: '/电影');
    expect(hits.map((i) => i.name).toSet(),
        {'Dune.2021.mkv', 'Arrival.2016.mkv', 'Nomadland.mkv'});
  });

  test('pathPrefix 带结尾斜杠与不带等价', () async {
    final repo = await seeded();
    final a = await repo.listItems(pathPrefix: '/电影');
    final b = await repo.listItems(pathPrefix: '/电影/');
    expect(a.map((i) => i.id).toList(), b.map((i) => i.id).toList());
  });

  test('前缀必须按**整段**比：`/电影` 不能带出 `/电影2`', () async {
    final repo = await seeded();
    final hits = await repo.listItems(pathPrefix: '/电影');
    // 只比 `startsWith('/电影')` 的话 `Trap.mkv` 会混进来 ——
    // 用户会看到一个明明不在这个目录里的文件。
    expect(hits.map((i) => i.name), isNot(contains('Trap.mkv')));
  });

  test('pathPrefix 为根 → 全部（不能把根目录下的文件漏掉）', () async {
    final repo = await seeded();
    for (final prefix in [null, '', '/', '  ']) {
      final hits = await repo.listItems(pathPrefix: prefix);
      expect(hits, hasLength(6), reason: '前缀：$prefix');
    }
  });

  test('query 匹配文件名', () async {
    final repo = await seeded();
    expect((await repo.listItems(query: 'dune')).single.name, 'Dune.2021.mkv');
  });

  test('query 匹配展示路径 —— 「按文件夹路径找文件」靠它', () async {
    final repo = await seeded();
    final hits = await repo.listItems(query: '/剧集/科幻');
    expect(hits.single.name, 'Severance.S01E01.mkv');
  });

  test('pathPrefix 与 query 同时生效', () async {
    final repo = await seeded();
    final hits = await repo.listItems(pathPrefix: '/电影', query: '科幻');
    expect(hits.map((i) => i.name).toSet(),
        {'Dune.2021.mkv', 'Arrival.2016.mkv'});
  });

  test('limit / offset 生效', () async {
    final repo = await seeded();
    final page = await repo.listItems(limit: 2);
    expect(page, hasLength(2));
    final next = await repo.listItems(limit: 2, offset: 2);
    expect(next.map((i) => i.id).toSet().intersection(
          page.map((i) => i.id).toSet(),
        ),
        isEmpty);
  });
}
