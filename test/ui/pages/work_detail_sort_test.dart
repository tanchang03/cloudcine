import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/format.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/item_sort.dart';
import 'package:cloudcine/ui/pages/work_detail_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/settings_providers.dart';
import 'package:cloudcine/ui/widgets/modified_time_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 详情页「文件」列表的**修改时间**与**排序**。
///
/// ## 为什么要在 widget 这一层测
///
/// 排序本身在 `test/domain/item_sort_test.dart` 里测过了（纯函数）。这里守的
/// 是另外四件只有把页面铺开才看得见的事：
///
///   1. 默认（设置里什么都没有）时列表就是**修改时间倒序** —— 纯函数测不出
///      「provider 有没有真的把这个默认值接上」；
///   2. 每一行**真的显示了那一条自己的**修改时间（不是统一的占位）；
///   3. 菜单上切一次，**列表顺序真的变了**，而且**落到了设置库里** ——
///      用户报的「改了没反应」几乎都出在这一步；
///   4. 排序**不改**「默认高亮哪一季 / 点播放会播哪一集」—— 这一条最容易
///      被后来的改动破坏（把 `primary` 挪到排序之后算就行了），而且**不报错**，
///      只表现为「点播放播的是最新上传的那个文件」。
void main() {
  /// 时间基准取 `DateTime.now()`：界面上是**相对时间**（`5 小时前`），
  /// 写死日期的话测试过几天就红了。偏移一律用**小时**而不是天 ——
  /// `Duration(days: 25)` 跨夏令时切换会变成 24 天 23 小时，
  /// `inDays` 就少一天，而那种红只在一年里的某两天出现。
  final now = DateTime.now();

  MediaItem ep(
    String id, {
    int? season,
    int? episode,
    DateTime? modifiedAt,
    String title = '进击的巨人',
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: '$id.mkv',
        dirId: 'd1',
        dirPath: '/动漫/进击的巨人/',
        groupKey: 'aot',
        kind: MediaKind.episode,
        title: title,
        season: season,
        episode: episode,
        modifiedAt: modifiedAt,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 挂上详情页，返回容器（要读设置库里的值）。
  Future<ProviderContainer> pumpDetail(
    WidgetTester tester, {
    required List<MediaItem> items,
    AppDatabase? db,
    Size size = const Size(1280, 1200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = db ?? AppDatabase.memory();
    if (db == null) addTearDown(database.close);
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

  /// 某一行的纵向位置。用它比大小 = 比列表里的先后。
  double topOf(WidgetTester tester, String label) =>
      tester.getTopLeft(find.text(label)).dy;

  /// 断言 [order] 里的标签从上到下就是这个顺序。
  void expectOrder(WidgetTester tester, List<String> order) {
    for (var i = 0; i + 1 < order.length; i++) {
      expect(
        topOf(tester, order[i]),
        lessThan(topOf(tester, order[i + 1])),
        reason: '「${order[i]}」应该排在「${order[i + 1]}」前面',
      );
    }
  }

  testWidgets('默认按修改时间倒序，且每一行都显示那一条自己的修改时间', (tester) async {
    final t50h = now.subtract(const Duration(hours: 50));
    final t5h = now.subtract(const Duration(hours: 5));
    final t1h = now.subtract(const Duration(hours: 1));

    await pumpDetail(tester, items: [
      ep('S01E01', season: 1, episode: 1, modifiedAt: t50h),
      ep('S01E02', season: 1, episode: 2, modifiedAt: t5h),
      ep('S01E03', season: 1, episode: 3, modifiedAt: t1h),
      // 网盘没给时间的条目：垫底，并且如实显示 `—`。
      ep('S01E04', season: 1, episode: 4),
    ]);

    // 默认就是「修改时间倒序」—— 设置里还没有这一行时也必须如此。
    expect(find.text('修改时间倒序'), findsOneWidget);

    expectOrder(tester, [
      '进击的巨人 S01E03', // 1 小时前（最新）
      '进击的巨人 S01E02', // 5 小时前
      '进击的巨人 S01E01', // 50 小时前
      '进击的巨人 S01E04', // 网盘没给时间 → 垫底，不冒充「1970 年的老片子」
    ]);

    // 时间真的画在行上：每一行的完整时刻都在自己的 tooltip 里。
    // 用 tooltip 而不是相对时间文案来断言「是哪一条的时间」——
    // 相对时间只说明「大约多久以前」，两个不同的时刻可能算出同一句。
    expect(find.byType(ModifiedTimeColumn), findsNWidgets(4));
    expect(find.byTooltip(formatDateTimeMinute(t1h)), findsOneWidget);
    expect(find.byTooltip(formatDateTimeMinute(t5h)), findsOneWidget);
    expect(find.byTooltip(formatDateTimeMinute(t50h)), findsOneWidget);
    expect(
      find.byTooltip('网盘没有给出这一条的修改时间'),
      findsOneWidget,
      reason: '网盘没给时间的条目要如实说「不知道」，不能留空 —— '
          '留空看起来像这一行坏了',
    );
  });

  testWidgets('菜单切到「剧集顺序」→ 列表真的换顺序，并把设置落库', (tester) async {
    final container = await pumpDetail(tester, items: [
      ep('S01E01', season: 1, episode: 1,
          modifiedAt: now.subtract(const Duration(hours: 50))),
      ep('S01E02', season: 1, episode: 2,
          modifiedAt: now.subtract(const Duration(hours: 5))),
      ep('S01E03', season: 1, episode: 3,
          modifiedAt: now.subtract(const Duration(hours: 1))),
    ]);

    // 还没切之前，设置里没有这一行 —— 走的是默认值。
    expect(
      container.read(settingsProvider).valueOrNull!.itemSortMode,
      ItemSortMode.modifiedDesc,
    );

    await tester.tap(find.byTooltip('文件排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集顺序'));
    await tester.pumpAndSettle();

    expectOrder(tester, [
      '进击的巨人 S01E01',
      '进击的巨人 S01E02',
      '进击的巨人 S01E03',
    ]);
    expect(
      container.read(settingsProvider).valueOrNull!.itemSortMode,
      ItemSortMode.episodeOrder,
      reason: '菜单上的切换必须落到设置里 —— 否则用户切完再进另一部作品，'
          '看到的又是按时间排的，只会觉得「这个开关没用」',
    );
    expect(
      await container.read(settingsStoreProvider).read(SettingKeys.itemSortMode),
      ItemSortMode.episodeOrder.value,
      reason: '要真的写进设置库（不是只改了内存状态）：重启之后还得是这个顺序',
    );
  });

  testWidgets('排序落库之后，重新打开详情页仍然是那一档', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    final items = [
      ep('S01E01', season: 1, episode: 1,
          modifiedAt: now.subtract(const Duration(hours: 50))),
      ep('S01E02', season: 1, episode: 2,
          modifiedAt: now.subtract(const Duration(hours: 1))),
    ];

    await pumpDetail(tester, db: db, items: items);

    await tester.tap(find.byTooltip('文件排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集顺序'));
    await tester.pumpAndSettle();

    // 换一个容器重开这一页（同一个库）—— 模拟「退出应用再进来」。
    // 第一个容器不手动 dispose：它由 `pumpDetail` 注册的 teardown 负责，
    // 在这里多调一次只是给自己找「容器已释放」的麻烦。
    await pumpDetail(tester, db: db, items: items);

    expect(find.text('剧集顺序'), findsOneWidget);
    expectOrder(tester, ['进击的巨人 S01E01', '进击的巨人 S01E02']);
  });

  testWidgets('只有一个文件时不画排序开关（没有可排的东西）', (tester) async {
    await pumpDetail(tester, items: [
      ep('only', season: 1, episode: 1, modifiedAt: now),
    ]);

    expect(
      find.byTooltip('文件排序方式'),
      findsNothing,
      reason: '一个文件时画一个排序开关是纯噪音 —— 与 `WorkLevels`'
          '「某层少于 2 个选项不画」同一条口径',
    );
    // 但那一行本身照旧要列出来。
    expect(find.text('进击的巨人 S01E01'), findsOneWidget);
  });

  testWidgets('默认高亮不跟排序走：最新的一集在第二季，打开时仍停在第 1 季', (tester) async {
    // 这一条守的是「排序只改列表长什么样，不改点播放会播哪一条」。
    // 把 `primary` 挪到排序之后再算（看起来只是一行代码的位置）就会红。
    await pumpDetail(tester, items: [
      ep('S01E01', season: 1, episode: 1,
          modifiedAt: now.subtract(const Duration(hours: 50))),
      ep('S01E02', season: 1, episode: 2,
          modifiedAt: now.subtract(const Duration(hours: 5))),
      ep('S02E01', season: 2, episode: 1,
          modifiedAt: now.subtract(const Duration(hours: 1))),
    ]);

    expect(
      find.text('进击的巨人 S02E01'),
      findsNothing,
      reason: '第二季那一集是最新的（时间倒序会把它排到第一行），'
          '但「默认高亮 / 播放目标」看的是剧集顺序里的第一集 —— '
          '跟着排序走的话，用户点播放会播到一个他根本没在看的季度',
    );
    // 而列表内部确实是时间倒序（同一季里最新的那集在前）。
    expectOrder(tester, ['进击的巨人 S01E02', '进击的巨人 S01E01']);
  });
}
