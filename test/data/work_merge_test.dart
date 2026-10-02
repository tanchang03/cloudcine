import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// 跨目录归一（`mergedInto` 折叠标记）的**真库**测试。
///
/// ## 为什么必须用真的 [AppDatabase.memory]
///
/// 这一层要验的是「别名行真的从 SQL 查询里消失了、目标作品真的把源作品
/// 的文件并进来了」。这些行为全在 SQL 里（`WHERE merged_into IS NULL`、
/// `IN (子查询)`），内存替身复刻得再像也证明不了真库如此。而漏掉任何一处
/// 的后果都是**静默**的：列表少一部、角标多一部、或者并集只并了一半。
///
/// ## 折叠与删除的区别，是这个文件反复要证明的事
///
/// 折叠**不删行、不改 `media_items.group_key`**。所以每一条「合上了」的
/// 断言旁边都该有一条「还能拆回去」的 —— 那才是这个设计存在的理由。
void main() {
  final now = DateTime(2026, 10, 2);

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
  });

  tearDown(() => db.close());

  Future<void> seedWork(
    String key, {
    String? onlineId,
    String source = 'online',
    String title = '片子',
    int itemCount = 0,
    int totalBytes = 0,
    int seasonCount = 0,
    String category = 'movie',
    int? year,
    DateTime? firstSeenAt,
    DateTime? lastPlayedAt,
  }) async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: key,
            provider: DriveProvider.quark.id,
            kind: 'movie',
            title: title,
            category: Value(category),
            year: Value(year),
            onlineId: Value(onlineId),
            source: source,
            itemCount: Value(itemCount),
            totalBytes: Value(totalBytes),
            seasonCount: Value(seasonCount),
            firstSeenAt: Value(firstSeenAt),
            lastPlayedAt: Value(lastPlayedAt),
            updatedAt: now,
          ),
        );
  }

  Future<void> seedItem(
    String workKey,
    String fileId,
    String name, {
    int? sizeBytes,
    int? season,
  }) async {
    await db.into(db.mediaItems).insert(
          MediaItemsCompanion.insert(
            id: 'quark:$fileId',
            provider: DriveProvider.quark.id,
            fileId: fileId,
            name: name,
            groupKey: workKey,
            kind: 'movie',
            sizeBytes: Value(sizeBytes),
            season: Value(season),
            firstSeenAt: now,
            updatedAt: now,
          ),
        );
  }

  /// 常用的开局：两部「同一部片子」的作品，A 大 B 小。
  Future<void> seedPair() async {
    await seedWork('a', onlineId: 'movie/843527', title: '流浪地球2', itemCount: 2);
    await seedWork(
      'b',
      onlineId: 'movie/843527',
      title: 'The Wandering Earth II',
      itemCount: 1,
    );
    await seedItem('a', 'fa1', 'A.2023.E01.mkv');
    await seedItem('a', 'fa2', 'A.2023.E02.mkv');
    await seedItem('b', 'fb1', 'B.2023.E05.mkv');
  }

  group('折叠之后：用户看到的是一部', () {
    test('listWorks 只剩目标，别名行消失', () async {
      await seedPair();

      expect(await repo.mergeWorksInto('a', ['b']), 1);

      final list = await repo.listWorks();
      expect(list.map((w) => w.key), ['a'],
          reason: '「归一」在用户眼里的全部表现就是这一步。别名行还露在'
              '列表里的话，用户会看到两个一模一样的格子。');
    });

    test('allWorks 仍能看到别名行（归一自己需要它）', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      final all = await repo.allWorks();
      expect(all.map((w) => w.key), ['a', 'b'],
          reason: '自动归一每次都要重新算「哪些行还独立着」。看不到别名行，'
              '同一个 onlineId 就会被反复算成「还有两部作品」并重复合并。');
      expect(all.firstWhere((w) => w.key == 'b').mergedInto, 'a');
    });

    test('itemsForWork(目标) 是并集，且仍按「季→部→集→名称」排', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      final items = await repo.itemsForWork('a');
      expect(items.map((i) => i.fileId), ['fa1', 'fa2', 'fb1'],
          reason: '并集少了一半的话，用户看到的是「两个格子变成一个，'
              '但集数少了」—— 比不合并更糟。');
    });

    test('源作品自己的 itemsForWork 只返回它自己的文件', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      // 并集是**单向**的：源不是目标，不该把目标的文件也算进来。
      final items = await repo.itemsForWork('b');
      expect(items.map((i) => i.fileId), ['fb1']);
    });

    test('mergedSourcesOf 给出源行（详情页的「已并入 N 个」靠它）', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      final sources = await repo.mergedSourcesOf('a');
      expect(sources.map((w) => w.key), ['b']);
      expect(sources.single.title, 'The Wandering Earth II',
          reason: '源行的元数据**原样留着** —— 撤销之后它要能自己站住。');
      expect(await repo.mergedSourcesOf('b'), isEmpty);
    });
  });

  group('角标口径：必须严格等于列表里的条数', () {
    test('countWorks / countWorksByCategory / countPlayedWorks 都不含别名行',
        () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      expect(await repo.countWorks(), 1);
      expect((await repo.countWorksByCategory())[MediaCategory.movie], 1);
      // 别名行没播过、目标播过 —— 合并前是 0，合并后仍是 1（目标那一部）。
      await repo.markPlayed('quark:fb1', now);
      await repo.markPlayed('quark:fa1', now);
      expect(await repo.countPlayedWorks(), 1,
          reason: '不滤别名行的话，「最近播放」会显示 2 部，点进去只有 1 部。');
    });

    test('年份角标与 listWorks(years:) 口径一致', () async {
      await seedWork('a', onlineId: 'movie/1', year: 2023, itemCount: 1);
      await seedWork('b', onlineId: 'movie/1', year: 2023, itemCount: 1);
      await repo.mergeWorksInto('a', ['b']);

      final counts = await repo.countWorksByYear();
      expect(counts[2023], 1);

      final list = await repo.listWorks(years: {2023});
      expect(list, hasLength(1));
      expect(counts[2023], list.length,
          reason: '角标与列表对不上时，用户点一下就会看到一个空列表。');
    });
  });

  group('搜索穿透折叠', () {
    test('文件名在**源作品**里也能搜到目标', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      // `B.2023.E05.mkv` 挂在 b 名下，而列表里只有 a。
      final hits = await repo.listWorks(query: 'E05');
      expect(hits.map((w) => w.key), ['a'],
          reason: '那一集明明就列在 a 的详情页里，搜不到等于搜索坏了。');
    });

    test('搜目标自己的文件名照常命中', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);
      final hits = await repo.listWorks(query: 'E01');
      expect(hits.map((w) => w.key), ['a']);
    });
  });

  group('撤销：折叠是双向的', () {
    test('unmergeWorks 把两部都还原，文件各回各家', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);
      expect(await repo.unmergeWorks(['b']), 1);

      final list = await repo.listWorks();
      expect(list.map((w) => w.key).toSet(), {'a', 'b'});
      expect((await repo.itemsForWork('a')).map((i) => i.fileId), ['fa1', 'fa2']);
      expect((await repo.itemsForWork('b')).map((i) => i.fileId), ['fb1']);
      expect(await repo.mergedSourcesOf('a'), isEmpty);
    });

    test('撤销之后再撤销一次 → 0（幂等，不报错）', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);
      await repo.unmergeWorks(['b']);

      expect(await repo.unmergeWorks(['b']), 0);
    });

    test('撤销没折叠过的行 → 0', () async {
      await seedPair();
      expect(await repo.unmergeWorks(['b']), 0);
    });
  });

  group('三条防错（做错就是静默坏数据）', () {
    test('目标不存在 → 一行都不动', () async {
      await seedPair();
      expect(await repo.mergeWorksInto('不存在', ['b']), 0);

      final b = await repo.workByKey('b');
      expect(b!.mergedInto, isNull,
          reason: '折到一个不存在的目标，等于让 b 从列表里消失且没有任何'
              '入口能撤销 —— 那才是真正的数据丢失。');
    });

    test('目标自己是别名行 → 拒绝（不许形成链）', () async {
      await seedWork('root', onlineId: 'movie/1');
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);
      // 现在 b 是 a 的别名。再想把 b 当目标，会形成 root ← b ← … 的链。
      expect(await repo.mergeWorksInto('b', ['root']), 0);
      expect((await repo.workByKey('root'))!.mergedInto, isNull);
    });

    test('源里混进已经是别名的行 → 只折「根」行', () async {
      await seedWork('root', onlineId: 'movie/1');
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      // b 已经是别名；这次只该折 root。
      expect(await repo.mergeWorksInto('a', ['b', 'root']), 1);
      expect((await repo.workByKey('root'))!.mergedInto, 'a');
      expect((await repo.workByKey('b'))!.mergedInto, 'a',
          reason: 'b 原来指向 a，不该被改写。');
    });

    test('源列表里带上目标自己 → 忽略，且不报错', () async {
      await seedPair();
      expect(await repo.mergeWorksInto('a', ['a', 'b']), 1);
      expect((await repo.workByKey('a'))!.mergedInto, isNull,
          reason: '把目标折进它自己会让它从列表里消失 —— 整部作品凭空不见。');
    });
  });

  group('重扫不许把折叠拆开', () {
    test('upsertWorks 之后 mergedInto 仍在（走真库的合并规则）', () async {
      await seedPair();
      await repo.mergeWorksInto('a', ['b']);

      // 模拟一次重扫：本次算出来的 b 行 `mergedInto` 是 null。
      await repo.upsertWorks(
        [
          MediaWork(
            key: 'b',
            provider: DriveProvider.quark,
            kind: MediaKind.movie,
            title: 'The Wandering Earth II',
            category: MediaCategory.movie,
            source: ScrapeSource.local,
            itemCount: 1,
            firstSeenAt: now,
            updatedAt: now,
          ),
        ],
        now: now,
      );

      expect((await repo.workByKey('b'))!.mergedInto, 'a',
          reason: '照抄新值的话，用户每重扫一次，合好的片子就自己变回两个格子。');
      expect((await repo.listWorks()).map((w) => w.key), ['a']);
    });
  });

  group('列表卡片上的三个计数必须是并集', () {
    test('itemCount / totalBytes 把折进来的文件算上', () async {
      await seedWork('a', onlineId: 'movie/1', itemCount: 2, totalBytes: 200);
      await seedWork('b', onlineId: 'movie/1', itemCount: 1, totalBytes: 100);
      await seedItem('a', 'fa1', 'A.E01.mkv', sizeBytes: 100);
      await seedItem('a', 'fa2', 'A.E02.mkv', sizeBytes: 100);
      await seedItem('b', 'fb1', 'B.E01.mkv', sizeBytes: 100);

      expect((await repo.listWorks()).firstWhere((w) => w.key == 'a').itemCount, 2,
          reason: '合并前当然是 2 —— 对照组。');

      await repo.mergeWorksInto('a', ['b']);

      final card = (await repo.listWorks()).single;
      expect(card.itemCount, 3,
          reason: '卡片写 2、点进去 3 个文件 —— 用户的第一反应是「文件丢了」。');
      expect(card.totalBytes, 300);
      // 详情页看到的确实是 3 个 —— 两处口径必须一致。
      expect(await repo.itemsForWork('a'), hasLength(3));
    });

    test('seasonCount 是并集的**去重**季数，不是相加', () async {
      // 目标自己有 S1、源也是 S1 —— 相加会得到「2 季」，而并集只有 1 季。
      await seedWork('a', onlineId: 'movie/1', itemCount: 1, seasonCount: 1);
      await seedWork('b', onlineId: 'movie/1', itemCount: 1, seasonCount: 1);
      await seedItem('a', 'fa1', 'A.S01E01.mkv', season: 1);
      await seedItem('b', 'fb1', 'B.S01E02.mkv', season: 1);

      await repo.mergeWorksInto('a', ['b']);

      expect((await repo.listWorks()).single.seasonCount, 1,
          reason: 'COUNT(DISTINCT season) 不能相加 —— 相加会凭空多出一季。');
    });

    test('跨目录的两季合起来 → 卡片显示「2 季」', () async {
      await seedWork('a', onlineId: 'movie/1', itemCount: 1, seasonCount: 1);
      await seedWork('b', onlineId: 'movie/1', itemCount: 1, seasonCount: 1);
      await seedItem('a', 'fa1', 'A.S01E01.mkv', season: 1);
      await seedItem('b', 'fb1', 'B.S02E01.mkv', season: 2);

      await repo.mergeWorksInto('a', ['b']);

      final card = (await repo.listWorks()).single;
      expect(card.seasonCount, 2);
      expect(card.subtitleLine, contains('2 季'),
          reason: '「跨目录归一」最有价值的一类就是同一部剧被拆到两个目录 —— '
              '这时卡片上的季数必须跟着涨。');
    });

    test('没有折叠过的行**原样返回**，不顺手重算', () async {
      // 老库里 `item_count` 与 `media_items` 的行数本来就可能不一致
      // （`deleteItemsNotIn` 只删项、不减这一列）。顺手重算会把一批与
      // 归一无关的作品的显示数字改掉。
      await seedWork('solo', onlineId: 'movie/9', itemCount: 7, totalBytes: 700);
      await seedItem('solo', 'fs1', 'Solo.mkv', sizeBytes: 100);

      final card = (await repo.listWorks()).single;
      expect(card.itemCount, 7, reason: '存值原样带出来。');
      expect(card.totalBytes, 700);
    });

    test('撤销之后数字回到各算各的', () async {
      await seedWork('a', onlineId: 'movie/1', itemCount: 2, totalBytes: 200);
      await seedWork('b', onlineId: 'movie/1', itemCount: 1, totalBytes: 100);
      await seedItem('a', 'fa1', 'A.E01.mkv', sizeBytes: 100);
      await seedItem('a', 'fa2', 'A.E02.mkv', sizeBytes: 100);
      await seedItem('b', 'fb1', 'B.E01.mkv', sizeBytes: 100);
      await repo.mergeWorksInto('a', ['b']);

      await repo.unmergeWorks(['b']);

      final list = await repo.listWorks();
      expect(list.map((w) => w.key).toSet(), {'a', 'b'});
      expect(list.firstWhere((w) => w.key == 'a').itemCount, 2);
      expect(list.firstWhere((w) => w.key == 'b').itemCount, 1);
    });
  });
}
