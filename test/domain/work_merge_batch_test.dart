import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_merge_planner.dart';
import 'package:cloudcine/domain/services/work_merge_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量人工归一（海报墙 / 列表里勾选 N 部 → 「合并到…」）。
///
/// ## 这条通道最容易错的不是「合不上」，是**合多了**或**合少了**
///
/// 单部那条路合错一次只影响一部片子。批量一次动 N 部，而且触发它的典型现场
/// 恰恰是「网盘上一部剧被拆成四五个目录」—— 用户勾的就是那四五条，任何一条
/// 被漏掉或合错方向，他看到的是「还是有五部，只是少了一部」。
///
/// 所以下面钉住的是三组判据：**目标在自己人里**、**合不上的不拖累其余**、
/// **顺序确定**。
void main() {
  final now = DateTime(2026, 10, 2);

  /// 只填规划器真正看的那几列 —— 填得越少，测试越能说明「哪些列是判据」。
  MediaWork w(
    String key, {
    String? title,
    String? mergedInto,
    int itemCount = 1,
    ScrapeSource source = ScrapeSource.local,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title ?? key,
        source: source,
        itemCount: itemCount,
        mergedInto: mergedInto,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaItem item(String workKey, String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/剧集/$workKey/',
        groupKey: workKey,
        kind: MediaKind.movie,
        title: fileId,
        firstSeenAt: now,
        updatedAt: now,
      );

  group('WorkMergePlanner.batchPlan', () {
    test('目标就在勾选的那一批里 → 它不被折走，其余的折进去', () {
      final a = w('a', itemCount: 10);
      final b = w('b');
      final c = w('c');

      final plan = WorkMergePlanner.batchPlan(
        target: a,
        sources: [a, b, c],
        all: [a, b, c],
      );

      expect(plan.sourceKeys, ['b', 'c'],
          reason: '「从勾的这批里挑一部留下」是最自然的用法，'
              '而 manualBlocker 的第一条就是「不能自己并自己」—— '
              '直接循环会把目标自己算成一条「合不了」。');
      expect(plan.blocked, isEmpty);
    });

    test('只勾了一部、且它就是目标 → 一部都不折（canMerge false）', () {
      final a = w('a');
      final plan = WorkMergePlanner.batchPlan(
        target: a,
        sources: [a],
        all: [a],
      );

      expect(plan.sourceKeys, isEmpty);
      expect(plan.canMerge, isFalse,
          reason: '不能返回一个「sourceKeys 为空」却照样让服务层去落库，'
              '那样用户会看到一条「已把 并入《X》」的空提示。');
    });

    test('合不上的不拖累其余的 —— 拦掉的那部进 blocked', () {
      // z 自己折着 y（会成链），所以 z 不能当源；a、b 照常。
      final y = w('y');
      final z = w('z');
      final folded = w('y2', mergedInto: 'z');
      final a = w('a');
      final b = w('b');
      final all = [y, z, folded, a, b];

      final plan = WorkMergePlanner.batchPlan(
        target: y,
        sources: [a, z, b],
        all: all,
      );

      expect(plan.sourceKeys, ['a', 'b']);
      expect(plan.blockedCount, 1);
      expect(plan.blocked['z'], isNotNull);
      expect(plan.blocked['z'], contains('拆开'),
          reason: '要告诉用户**怎么办**，只说「合不了」他无从下手。');
    });

    test('源是别名行 → 拦（别名行不该出现在列表里，出现了就别合）', () {
      final target = w('t', itemCount: 9);
      final away = w('x', mergedInto: 'other');
      final other = w('other');

      final plan = WorkMergePlanner.batchPlan(
        target: target,
        sources: [away],
        all: [target, away, other],
      );

      expect(plan.sourceKeys, isEmpty);
      expect(plan.blocked['x'], isNotNull);
    });

    test('目标已是别名行 → 全部拦（不许成链）', () {
      final target = w('t', mergedInto: 'root');
      final root = w('root');
      final a = w('a');

      final plan = WorkMergePlanner.batchPlan(
        target: target,
        sources: [a],
        all: [target, root, a],
      );

      expect(plan.sourceKeys, isEmpty);
      expect(plan.blocked['a'], isNotNull);
    });

    test('sourceKeys 按 key 升序 —— 同样的输入永远给出同样的输出', () {
      final target = w('target', itemCount: 99);
      final plan = WorkMergePlanner.batchPlan(
        target: target,
        // 故意乱序传入
        sources: [w('s3'), w('s1'), w('s2')],
        all: [target, w('s1'), w('s2'), w('s3')],
      );

      expect(plan.sourceKeys, ['s1', 's2', 's3'],
          reason: '顺序不确定会让日志与提示语在两次运行之间变来变去，'
              '而这是纯函数最该保证的东西。');
    });
  });

  group('WorkMergeService.mergeManyInto', () {
    /// 五部「同一部剧被拆成五个目录」+ 一部不相干的。
    Future<InMemoryMediaRepository> seeded() async {
      final repo = InMemoryMediaRepository();
      await repo.upsertWorks([
        w('s1', title: 'S01', itemCount: 3),
        w('s2', title: 'S02', itemCount: 2),
        w('s3', title: 'S03', itemCount: 1),
        w('other', title: '不相干', itemCount: 7),
      ]);
      await repo.upsertItems([
        item('s1', 'f1'),
        item('s1', 'f2'),
        item('s1', 'f3'),
        item('s2', 'f4'),
        item('s2', 'f5'),
        item('s3', 'f6'),
        item('other', 'f9'),
      ]);
      return repo;
    }

    test('一次落库：列表里只剩目标，文件是并集', () async {
      final repo = await seeded();
      final result = await WorkMergeService(library: repo).mergeManyInto(
        targetKey: 's1',
        sourceKeys: ['s2', 's3'],
      );

      expect(result, isNotNull);
      expect(result!.changed, 2);
      expect(result.plan.targetKey, 's1');
      expect(result.plan.isManual, isTrue);
      expect(result.sourceTitles, ['S02', 'S03']);

      // 列表里只剩 s1 与 other；s2 / s3 成了别名行。
      expect((await repo.listWorks()).map((x) => x.key).toSet(),
          {'s1', 'other'});
      // 归一**不搬 group_key**，所以目标看到的是全部文件。
      expect((await repo.itemsForWork('s1')).map((i) => i.fileId).toSet(),
          {'f1', 'f2', 'f3', 'f4', 'f5', 'f6'});
    });

    test('目标在勾选的那一批里 → 其余的折进去，目标自己原样留着', () async {
      final repo = await seeded();
      await WorkMergeService(library: repo).mergeManyInto(
        targetKey: 's1',
        sourceKeys: ['s1', 's2', 's3'],
      );

      expect((await repo.listWorks()).map((x) => x.key).toSet(),
          {'s1', 'other'});
      expect((await repo.workByKey('s1'))?.mergedInto, isNull,
          reason: '目标自己被折进自己会形成一个自指的别名行 —— '
              '它在列表里消失、详情页也打不开。');
    });

    test('合不上的不拖累其余的 —— 只合能合的，不整批失败', () async {
      final repo = await seeded();
      // 先把 s3 变成「折着别人的一部」（会成链，合不了）。
      await repo.mergeWorksInto('s3', ['other']);

      final result = await WorkMergeService(library: repo).mergeManyInto(
        targetKey: 's1',
        sourceKeys: ['s2', 's3'],
      );

      expect(result, isNotNull,
          reason: '整批失败的表现是「我勾了 5 部，点完什么都没发生」，'
              '而那句错误说的还是用户没勾过的那部片子的问题。');
      expect(result!.plan.sourceKeys, ['s2']);
      expect(result.changed, 1);
      expect((await repo.workByKey('s2'))?.mergedInto, 's1');
      expect((await repo.workByKey('s3'))?.mergedInto, isNull);
    });

    test('一部都合不了 → null（调用方据此说「这次没合上」，不说「失败」）',
        () async {
      final repo = await seeded();
      final result = await WorkMergeService(library: repo).mergeManyInto(
        targetKey: 's1',
        sourceKeys: ['s1'],
      );

      expect(result, isNull);
      expect(await repo.countWorks(), 4,
          reason: '返回 null 时必须一条都没动。');
    });

    test('目标不在库里 → null，不抛', () async {
      final repo = await seeded();
      expect(
        await WorkMergeService(library: repo).mergeManyInto(
          targetKey: '不存在',
          sourceKeys: ['s2'],
        ),
        isNull,
      );
      expect(await repo.countWorks(), 4);
    });

    test('提示语点明留下的那一部（批量也要能看懂合到哪去了）', () async {
      final repo = await seeded();
      final result = await WorkMergeService(library: repo).mergeManyInto(
        targetKey: 's1',
        sourceKeys: ['s2', 's3'],
      );

      expect(result!.message, contains('并入《S01》'));
      expect(result.message, contains('《S02》'));
      expect(result.message, contains('《S03》'));

      // 撤销必须真能还原 —— 一次动 N 部的通道，用户的信任全靠它。
      expect(await WorkMergeService(library: repo).undo(['s2', 's3']), 2);
      expect(await repo.countWorks(), 4);
    });
  });
}
