import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_merge_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// [WorkMergeService] 的行为，以及 `InMemoryMediaRepository` 与 drift 实现的
/// **口径一致性**。
///
/// ## 为什么替身这一侧也要单独测一遍
///
/// 内存库被几十个 UI / provider 测试当底座用。它少滤一次 `mergedInto`，
/// 那些测试就会对「合并后列表里有几部」给出与真机不同的结论 —— 而它们
/// **不会变红**（它们本来就不关心合并），只会给出错误的信心。
/// 真库那一侧在 `test/data/work_merge_test.dart`。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaWork work(
    String key, {
    String? onlineId,
    String title = '片子',
    ScrapeSource source = ScrapeSource.online,
    int itemCount = 0,
    DateTime? firstSeenAt,
    MediaCategory category = MediaCategory.movie,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        category: category,
        onlineId: onlineId,
        source: source,
        itemCount: itemCount,
        firstSeenAt: firstSeenAt,
        updatedAt: now,
      );

  MediaItem item(String workKey, String fileId, String name) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: name,
        dirId: 'd1',
        dirPath: '/电影/$workKey/',
        groupKey: workKey,
        kind: MediaKind.movie,
        title: name,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 两部同一部片子：A 大 B 小。
  Future<InMemoryMediaRepository> seeded() async {
    final repo = InMemoryMediaRepository();
    await repo.upsertWorks([
      work('a', onlineId: 'movie/843527', title: '流浪地球2', itemCount: 2),
      work('b', onlineId: 'movie/843527', title: 'The Wandering Earth II', itemCount: 1),
    ]);
    await repo.upsertItems([
      item('a', 'fa1', 'A.2023.E01.mkv'),
      item('a', 'fa2', 'A.2023.E02.mkv'),
      item('b', 'fb1', 'B.2023.E05.mkv'),
    ]);
    return repo;
  }

  group('替身与真库同一口径', () {
    test('折叠后列表只剩一部，但 allWorks 还看得见两行', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);

      expect((await repo.listWorks()).map((w) => w.key), ['a']);
      expect((await repo.allWorks()).map((w) => w.key), ['a', 'b']);
    });

    test('itemsForWork(目标) 是并集；源只看得见自己的', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);

      expect((await repo.itemsForWork('a')).map((i) => i.fileId),
          ['fa1', 'fa2', 'fb1']);
      expect((await repo.itemsForWork('b')).map((i) => i.fileId), ['fb1']);
    });

    test('三个计数都不含别名行', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);

      expect(await repo.countWorks(), 1);
      expect((await repo.countWorksByCategory())[MediaCategory.movie], 1);
      expect(await repo.countPlayedWorks(), 0);
    });

    test('搜索穿透折叠：源作品的文件名也能搜到目标', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);

      expect((await repo.listWorks(query: 'E05')).map((w) => w.key), ['a']);
    });

    test('撤销后各回各家', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);
      await repo.unmergeWorks(['b']);

      expect((await repo.listWorks()).map((w) => w.key).toSet(), {'a', 'b'});
      expect((await repo.itemsForWork('a')).map((i) => i.fileId), ['fa1', 'fa2']);
    });
  });

  group('WorkMergeService.mergeAll', () {
    test('把同一条目的几部折成一部，并给出面向用户的结果', () async {
      final repo = await seeded();
      final results = await WorkMergeService(library: repo).mergeAll();

      expect(results, hasLength(1));
      expect(results.single.plan.targetKey, 'a');
      expect(results.single.targetTitle, '流浪地球2');
      expect(results.single.sourceTitles, ['The Wandering Earth II']);
      expect(results.single.message, contains('并入《流浪地球2》'));
      expect(results.single.changed, 1);
    });

    test('已经合过 → 再跑一次是空的（幂等，不重复报「已合并」）', () async {
      final repo = await seeded();
      final service = WorkMergeService(library: repo);
      await service.mergeAll();

      expect(await service.mergeAll(), isEmpty,
          reason: '不幂等的话，用户每扫一次就会看到一次「已合并」提示，'
              '而实际上什么都没发生。');
    });

    test('没有同一条目的作品 → 空结果，一条都不动', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        work('a', onlineId: 'movie/1', itemCount: 3),
        work('b', onlineId: 'movie/2', itemCount: 3),
      ]);

      expect(await WorkMergeService(library: repo).mergeAll(), isEmpty);
    });

    test('本地解析出的两部（都没刮到）绝不自动合并', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        work('182', source: ScrapeSource.local, itemCount: 1),
        work('1821', source: ScrapeSource.local, itemCount: 1),
      ]);

      expect(await WorkMergeService(library: repo).mergeAll(), isEmpty);
      expect(await repo.countWorks(), 2);
    });
  });

  group('WorkMergeService.mergeFor', () {
    test('刮完一部之后立刻归一 —— 源侧调用也返回计划（要提示用户）', () async {
      final repo = await seeded();
      final result = await WorkMergeService(library: repo).mergeFor('b');

      expect(result?.plan.targetKey, 'a');
      expect(result?.changed, 1);
    });

    test('没有兄弟 → null', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([work('solo', onlineId: 'movie/9')]);
      expect(await WorkMergeService(library: repo).mergeFor('solo'), isNull);
    });

    test('库里没有的 key → null（不抛）', () async {
      final repo = await seeded();
      expect(await WorkMergeService(library: repo).mergeFor('不存在'), isNull);
    });
  });

  group('WorkMergeService.undo', () {
    test('撤销折叠，返回改动的行数', () async {
      final repo = await seeded();
      final service = WorkMergeService(library: repo);
      await service.mergeAll();

      expect(await service.undo(['b']), 1);
      expect(await repo.countWorks(), 2);
    });

    test('撤销没折叠过的行 → 0', () async {
      final repo = await seeded();
      expect(await WorkMergeService(library: repo).undo(['b']), 0);
    });
  });

  group('WorkMergeService.mergeInto（手动归一）', () {
    test('把源折进指定的目标 —— 方向由调用方给，规划器不参与', () async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        // 两部都**没有** onlineId：自动那条路永远不会碰它们，
        // 而这正是手动通道存在的理由。
        work('local', source: ScrapeSource.local, title: '流浪地球2', itemCount: 2),
        work('other', source: ScrapeSource.local, title: 'The Wandering Earth II', itemCount: 1),
      ]);

      final result = await WorkMergeService(library: repo)
          .mergeInto(targetKey: 'other', sourceKey: 'local');

      expect(result, isNotNull);
      expect(result!.changed, 1);
      expect(result.targetTitle, 'The Wandering Earth II');
      expect(result.sourceTitles, ['流浪地球2']);
      expect(result.plan.isManual, isTrue);
      expect((await repo.listWorks()).map((w) => w.key), ['other'],
          reason: '按钮写的是「合并**到**…」，所以留下的是选中的那一部。');
    });

    test('方向反过来也成立（人说了算，不比文件数）', () async {
      final repo = await seeded();
      // 目标故意选**文件少**的那一部 —— 自动归一永远不会这么选。
      final result = await WorkMergeService(library: repo)
          .mergeInto(targetKey: 'b', sourceKey: 'a');

      expect(result?.targetTitle, 'The Wandering Earth II');
      expect((await repo.listWorks()).map((w) => w.key), ['b']);
    });

    test('手动那条的文案不说「识别为同一条目」', () async {
      final repo = await seeded();
      final result = await WorkMergeService(library: repo)
          .mergeInto(targetKey: 'a', sourceKey: 'b');

      expect(result!.message, contains('并入《流浪地球2》'));
      expect(result.message, isNot(contains('识别为')),
          reason: '「识别为」暗示是程序判断的。用户自己点的合并再这么说一遍，'
              '会让人以为算法又擅自判断了一次。');
    });

    test('源已经是别名行 → 不做（防链）', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);
      await repo.upsertWorks([work('c', title: '第三部', itemCount: 1)]);

      expect(
        await WorkMergeService(library: repo)
            .mergeInto(targetKey: 'c', sourceKey: 'b'),
        isNull,
      );
      expect((await repo.allWorks()).firstWhere((w) => w.key == 'b').mergedInto,
          'a',
          reason: '拦下之后 b 必须还指向原来的目标 —— 拦一半会留下脏数据。');
    });

    test('源自己还折着别的作品 → 不做（先拆开）', () async {
      final repo = await seeded();
      await repo.mergeWorksInto('a', ['b']);
      await repo.upsertWorks([work('c', title: '第三部', itemCount: 1)]);

      expect(
        await WorkMergeService(library: repo)
            .mergeInto(targetKey: 'c', sourceKey: 'a'),
        isNull,
      );
    });

    test('key 不在库里 → null（不抛）', () async {
      final repo = await seeded();
      final service = WorkMergeService(library: repo);

      expect(await service.mergeInto(targetKey: '不存在', sourceKey: 'a'), isNull);
      expect(await service.mergeInto(targetKey: 'a', sourceKey: '不存在'), isNull);
    });

    test('合并后列表计数是并集，撤销后各回各家', () async {
      final repo = await seeded();
      final service = WorkMergeService(library: repo);
      await service.mergeInto(targetKey: 'a', sourceKey: 'b');

      final target = (await repo.listWorks()).single;
      expect(target.itemCount, 3, reason: '2 + 1 —— 卡片上的数字必须与详情页'
          '看到的文件数一致，否则用户以为文件丢了。');

      expect(await service.undo(['b']), 1);
      expect((await repo.listWorks()).map((w) => w.key).toSet(), {'a', 'b'});
    });
  });
}
