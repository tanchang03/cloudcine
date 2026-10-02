import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_merge_service.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/widgets/batch_merge_dialog.dart';
import 'package:cloudcine/ui/widgets/merge_target_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量归一的对话框：勾选 N 部 → 挑一部留下 → 一次合掉。
///
/// ## 钉住的四件事
///
///   1. **目标可以是被勾中的某一部** —— 这是它最自然的用法，而单部那条路的
///      判据第一条就是「不能自己并自己」；
///   2. 勾选的那几部要**排在候选最前**并标出来，否则用户得先想清楚留哪一部
///      再去别处翻；
///   3. 底部在**点确认之前**就说清「把 N 部并入《X》」；
///   4. 合不上的那部不拖累其余的。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaWork work(
    String key, {
    required String title,
    int itemCount = 1,
    String? mergedInto,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
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

  /// 打开对话框。[sourceKeys] 是「用户勾选的那一批」。
  /// ⚠️ [result] 是一个**取值器**而不是值：对话框的结果要等用户点完
  /// 「合并」才有，而本函数返回时对话框刚打开。写成值的话拿到的一定是 null，
  /// 而断言会报成一句与原因毫无关系的「Expected 's1' / Actual: null」。
  Future<({DriftMediaRepository repo, WorkMergeResult? Function() result})> open(
    WidgetTester tester, {
    required List<String> sourceKeys,
    List<(String, String)> mergeFirst = const [],
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);

    await repo.upsertWorks([
      work('s1', title: 'S01', itemCount: 3),
      work('s2', title: 'S02', itemCount: 2),
      work('s3', title: 'S03', itemCount: 8),
      work('z', title: '自己折着别人的一部'),
      work('y2', title: '被 z 折走的那一部'),
      work('other', title: '不相干', itemCount: 7),
    ], now: now);
    await repo.upsertItems([
      item('s1', 'f1'),
      item('s2', 'f2'),
      item('s3', 'f3'),
      item('z', 'f4'),
      item('y2', 'f5'),
      item('other', 'f9'),
    ], now: now);
    for (final (target, source) in mergeFirst) {
      await repo.mergeWorksInto(target, [source]);
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    WorkMergeResult? popped;

    final sources = <MediaWork>[
      for (final k in sourceKeys)
        if (await repo.workByKey(k) case final w?) w,
    ];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  popped = await BatchMergeDialog.show(context, sources);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    return (repo: repo, result: () => popped);
  }

  Finder inDialog(Finder inner) =>
      find.descendant(of: find.byType(Dialog), matching: inner);

  Future<void> pick(WidgetTester tester, String title) async {
    await tester.tap(inDialog(find.text(title)).first);
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(inDialog(find.text('合并')).last);
    await tester.pumpAndSettle();
  }

  testWidgets('候选里**包含**勾选的那几部，且它们排在最前', (tester) async {
    await open(tester, sourceKeys: ['s1', 's2']);

    // 目标常常就在勾的这批里 —— 排掉它们等于逼用户去别处翻。
    expect(inDialog(find.text('S01')), findsWidgets);
    expect(inDialog(find.text('S02')), findsWidgets);

    final rows = tester.widgetList<MergeTargetRow>(find.byType(MergeTargetRow));
    expect(rows.first.badge, '已选中',
        reason: '勾的这几部要顶到最前并标出来：用户说「合并到…」时，'
            '最可能的答案就是其中内容最全的那一部。');
  });

  testWidgets('底部在点确认**之前**就说清「把 N 部并入《X》」', (tester) async {
    await open(tester, sourceKeys: ['s1', 's2']);
    await pick(tester, 'S03');

    expect(inDialog(find.textContaining('把 2 部并入《S03》')), findsOneWidget,
        reason: '方向写反的代价是「用户想留的那部消失了」，所以必须在他'
            '按下按钮之前就摆出来。');
  });

  testWidgets('目标是勾选的那一部时，留下它、折走其余的', (tester) async {
    final (:repo, :result) = await open(tester, sourceKeys: ['s1', 's2', 's3']);
    await pick(tester, 'S01');
    await confirm(tester);

    expect(result()?.plan.targetKey, 's1');
    expect(result()?.plan.sourceKeys, ['s2', 's3']);
    expect(result()?.changed, 2);

    expect((await repo.listWorks()).map((w) => w.key).toSet(),
        {'s1', 'z', 'y2', 'other'});
    // 目标自己绝不能被折进自己 —— 那会造出一个在列表里消失、
    // 详情页也打不开的自指别名行。
    expect((await repo.workByKey('s1'))?.mergedInto, isNull);
    expect((await repo.workByKey('s2'))?.mergedInto, 's1');
    // 归一不搬 group_key，目标看到的是全部文件。
    expect((await repo.itemsForWork('s1')).map((i) => i.fileId).toSet(),
        {'f1', 'f2', 'f3'});
  });

  testWidgets('合不上的那一部：整行不可点，并把原因写在按钮旁边',
      (tester) async {
    // z 自己折着 y2（会成链），所以 z 不能当源。
    await open(
      tester,
      sourceKeys: ['z'],
      mergeFirst: [('z', 'y2')],
    );

    expect(inDialog(find.textContaining('拆开')), findsWidgets,
        reason: '只说「合不了」用户无从下手 —— 必须告诉他先去把 z 拆开。');

    final rows = tester.widgetList<MergeTargetRow>(find.byType(MergeTargetRow));
    expect(
      rows.where((r) => r.blockedReason != null),
      isNotEmpty,
      reason: '按钮亮着却点了没反应，是最让人以为应用坏了的一种失败。',
    );
  });

  testWidgets('撤销：合完再撤销，各部回到独立状态', (tester) async {
    final (:repo, :result) = await open(tester, sourceKeys: ['s1', 's2']);
    await pick(tester, 'S03');
    await confirm(tester);

    expect(result(), isNotNull);
    final n = await WorkMergeService(library: repo)
        .undo(result()!.plan.sourceKeys);

    expect(n, 2);
    expect((await repo.listWorks()).map((w) => w.key).toSet(),
        {'s1', 's2', 's3', 'z', 'y2', 'other'});
  });
}
