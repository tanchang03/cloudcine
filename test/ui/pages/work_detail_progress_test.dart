import 'package:cloudcine/core/utils/filename_parser.dart';
// ⚠️ drift 生成的表行类也叫 `MediaItemRow`（`media_items` 表的那一行），
// 与 UI 里那个同名 —— 不 hide 掉的话这个名字在这个文件里是歧义的。
import 'package:cloudcine/data/db/app_database.dart' hide MediaItemRow;
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/work_detail_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:cloudcine/ui/widgets/media_item_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 作品详情页「文件」列表里的**播放进度条**。
///
/// ## 为什么要在 widget 这一层测
///
/// 「每行画一条进度条」在 `test/ui/widgets/media_item_row_test.dart` 里测过了
/// （纯函数 + 单行渲染）。这里守的是**只有把整页铺开才看得见**的三件事：
///
///   1. 进度是**按条目**接上去的 —— 接到同一行、或者全部接到第一行，
///      纯函数都测不出来；
///   2. **看完的一集仍然是满格** —— 续播点那时已经被清成 NULL 了。这一条
///      是这个功能存在的理由：用续播点画的话，用户刚看完回来看到的是 0%；
///   3. 播放中写进库的进度**真的会让这一页重取** —— 少了
///      `ref.watch(playbackProgressSignalProvider)` 这一行，界面在**下次打开
///      详情页之前**永远停在上一次的样子，而且不报错。
void main() {
  final now = DateTime.now();

  /// 条目主键（`quark:S01E01`）。**不写字面量**：主键格式是
  /// `MediaItem.idFor` 的事，这里抄一份的话，哪天格式变了这些用例会静默失效
  /// （存进去了、但一行都读不出来）。
  String itemKey(String fileId) => MediaItem.idFor(DriveProvider.quark, fileId);

  MediaItem ep(
    String id, {
    int episode = 1,
    int? durationMs = 60 * 60 * 1000,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: '$id.mkv',
        dirId: 'd1',
        dirPath: '/动漫/进击的巨人/',
        groupKey: 'aot',
        kind: MediaKind.episode,
        title: '进击的巨人',
        season: 1,
        episode: episode,
        durationMs: durationMs,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 挂上详情页，返回容器。
  Future<ProviderContainer> pumpDetail(
    WidgetTester tester, {
    required List<MediaItem> items,
    Map<String, Duration> watched = const {},
    Map<String, Duration?> resume = const {},
  }) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = AppDatabase.memory();
    addTearDown(database.close);
    final repo = DriftMediaRepository(database);
    await repo.upsertWorks([
      MediaWork(
        key: 'aot',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '进击的巨人',
        updatedAt: now,
      ),
    ], now: now);
    await repo.upsertItems(items, now: now);

    for (final e in watched.entries) {
      await repo.saveMaxPosition(e.key, e.value);
    }
    for (final e in resume.entries) {
      await repo.saveResumePosition(e.key, e.value);
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        mediaRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: WorkDetailPage(workKey: 'aot')),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// 某一行底下的进度条值。`null` = 这一行没有进度条。
  double? barOf(WidgetTester tester, String label) {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(MediaItemRow),
    );
    final bar = find.descendant(
      of: row,
      matching: find.byType(LinearProgressIndicator),
    );
    if (bar.evaluate().isEmpty) return null;
    return tester.widget<LinearProgressIndicator>(bar).value;
  }

  testWidgets('进度条接在**那一条自己的**行上', (tester) async {
    await pumpDetail(
      tester,
      items: [ep('S01E01', episode: 1), ep('S01E02', episode: 2)],
      watched: {itemKey('S01E01'): const Duration(minutes: 15)},
    );

    expect(
      barOf(tester, '进击的巨人 S01E01'),
      closeTo(0.25, 0.001),
      reason: '15 / 60 分钟',
    );
    expect(
      barOf(tester, '进击的巨人 S01E02'),
      isNull,
      reason: '没播过的那一行不该有进度条 —— 全部画在第一条上是最容易犯的'
          '错（id 用错一个变量），而且看起来「像那么回事」。',
    );
  });

  testWidgets('没播过的一行不画进度条', (tester) async {
    await pumpDetail(tester, items: [ep('S01E01')]);
    expect(barOf(tester, '进击的巨人 S01E01'), isNull);
  });

  testWidgets('看完的一集稳定显示满格 —— 哪怕续播点已经被清掉', (tester) async {
    await pumpDetail(
      tester,
      items: [ep('S01E01')],
      // 播到结尾：历史最大位置记满。
      watched: {itemKey('S01E01'): const Duration(minutes: 60)},
      // 同时「已看完」把续播点清成 NULL（既有语义，不能动）。
      resume: {itemKey('S01E01'): null},
    );

    expect(
      barOf(tester, '进击的巨人 S01E01'),
      1.0,
      reason: '这一条就是这个功能存在的理由。用续播点画进度条的话，用户刚'
          '看完一集回到详情页，那一行显示的是 0% —— 恰好是他最想看到 100% '
          '的时刻。',
    );
  });

  testWidgets('时长未知的条目即使看过也不画（不画一条假的 0%）', (tester) async {
    await pumpDetail(
      tester,
      items: [ep('S01E01', durationMs: null)],
      watched: {itemKey('S01E01'): const Duration(minutes: 15)},
    );

    expect(barOf(tester, '进击的巨人 S01E01'), isNull);
  });

  testWidgets('播放中写进库的进度会让这一页重取 —— 不用退出再进来', (tester) async {
    final container = await pumpDetail(
      tester,
      items: [ep('S01E01')],
      watched: {itemKey('S01E01'): const Duration(minutes: 15)},
    );
    expect(barOf(tester, '进击的巨人 S01E01'), closeTo(0.25, 0.001));

    // 模拟播放页/播放窗口又落了一次进度，然后推刷新信号。
    await container
        .read(mediaRepositoryProvider)
        .saveMaxPosition(itemKey('S01E01'), const Duration(minutes: 45));
    container.read(playbackProgressSignalProvider.notifier).bump();
    await tester.pumpAndSettle();

    expect(
      barOf(tester, '进击的巨人 S01E01'),
      closeTo(0.75, 0.001),
      reason: '少了这一句 `watch`，详情页会一直停在上一次打开时的样子 —— '
          '而它看起来完全正常，只是数字不动。',
    );
  });

  testWidgets('刷新信号推来时**不闪转圈**（保留上一份数据）', (tester) async {
    final container = await pumpDetail(
      tester,
      items: [ep('S01E01')],
      watched: {itemKey('S01E01'): const Duration(minutes: 15)},
    );

    container.read(playbackProgressSignalProvider.notifier).bump();
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '用 `watch`（依赖变化 → refresh，`when` 默认 skipLoadingOnRefresh）'
          '而不是监听后 `invalidate`（reload → 会走 loading 分支）。后者会让'
          '这一页每 10 秒白一下。',
    );
    await tester.pumpAndSettle();
  });
}
