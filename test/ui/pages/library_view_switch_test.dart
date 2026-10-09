import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/library_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/library_selection_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 媒体库页的**视图切换**与**多选**。
///
/// ## 为什么要在页面这一层测，而不是只测 provider
///
/// 视图切换的全部风险都在「两个视图是不是真的共用同一批数据」上：封面与
/// 列表只是排布不同，切过去片子必须还在、排序 / 筛选 / 多选入口必须还在。
/// 这几条只有真的把页面铺开才看得出来。
///
/// 多选那一半同理：「点卡片到底是勾选还是开播」取决于当前是不是多选模式，
/// 而这个开关散在卡片与列表行两处 —— 只测 [librarySelectionProvider] 证明
/// 不了两处行为一致。
///
/// ⚠️ 「文件夹」**不在这里**测：它已经从视图切换里拆出去，是侧栏上并列的
/// 一级入口（见 `test/ui/pages/folder_page_test.dart`）。
/// 登录控制器的替身：页面要读它，而真的那个 `build()` 会去碰凭证存储 ——
/// 与「视图切换 / 多选」毫无关系。
class FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

/// 扫描控制器的替身。同理，真的那个会去读设置并准备一次网盘扫描。
class FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState();
}

void main() {
  final now = DateTime(2026, 10, 2);

  MediaWork work(String key, {required String title, int itemCount = 1}) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        itemCount: itemCount,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaItem item(String workKey, String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/电影/$workKey/',
        groupKey: workKey,
        kind: MediaKind.movie,
        title: fileId,
        firstSeenAt: now,
        updatedAt: now,
      );

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);
    await repo.upsertWorks([
      work('a', title: '片子甲', itemCount: 3),
      work('b', title: '片子乙', itemCount: 2),
      work('c', title: '片子丙', itemCount: 1),
    ], now: now);
    await repo.upsertItems([
      item('a', 'f1'),
      item('b', 'f2'),
      item('c', 'f3'),
    ], now: now);

    // 媒体库页头会读 `scanDriveProvider`（「重新扫描」必须带上**扫哪一家**），
    // 它经 `connectedDrivesProvider` → `adapterRegistryProvider` →
    // `credentialStoreProvider` → `appSupportDirProvider` 去取凭证目录。
    // 这个 provider 在 `main()` 里注入，单测里给一个真的空目录 ——
    // 别让它去碰用户的家目录。
    // ⚠️ 页面目前**不读** `posterCacheDirProvider`，所以这里刻意不注入它
    // （设置页那条用例才需要）。哪天海报卡片改成 watch 它，这条用例会红 ——
    // 那正是「页面加 watch 要同步补 override」的正常信号。
    final supportDir =
        Directory.systemTemp.createTempSync('cloudcine_view_switch');
    addTearDown(() => supportDir.deleteSync(recursive: true));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
        authControllerProvider.overrideWith(FakeAuth.new),
        scanControllerProvider.overrideWith(FakeScan.new),
        appSupportDirProvider.overrideWithValue(supportDir.path),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: LibraryPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Finder segment(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );

  testWidgets('默认是封面视图；切到列表后海报网格没了，片子还在', (tester) async {
    await pumpPage(tester);

    expect(find.byType(GridView), findsOneWidget,
        reason: '封面视图是海报网格。');
    expect(find.text('片子甲'), findsWidgets);

    await tester.tap(segment('列表'));
    await tester.pumpAndSettle();

    expect(find.byType(GridView), findsNothing,
        reason: '切过去还是网格 = 没切。');
    expect(find.text('片子甲'), findsWidgets,
        reason: '两个视图读的是**同一批作品**，只是排布不同 —— '
            '切一下视图不该让片子消失。');
  });

  testWidgets('列表视图里排序与筛选仍然在（它们管的是作品，不是文件）',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(segment('列表'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('排序方式'), findsOneWidget);
    expect(find.byTooltip('多选（批量合并）'), findsOneWidget,
        reason: '多选是作品级的操作，在列表视图里一样要有入口 —— 而列表恰恰是'
            '库大了之后用户真正会用的那个视图。');
  });

  testWidgets('点「选择」进入多选；点卡片是勾选，不是开播', (tester) async {
    final container = await pumpPage(tester);

    await tester.tap(find.byTooltip('多选（批量合并）'));
    await tester.pumpAndSettle();

    // 页头整条换掉了 —— 那才是「现在是另一种状态」能讲清楚的唯一方式。
    expect(find.text('勾选要管理的作品'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsNothing,
        reason: '多选模式下搜索 / 排序 / 刷新全都没有意义：勾完再去改排序，'
            '选择会被列表重建冲得七零八落。');

    await tester.tap(find.text('片子甲').first);
    await tester.pumpAndSettle();

    expect(find.text('已选 1 部'), findsOneWidget);
    expect(
      container.read(librarySelectionProvider).keys,
      {'a'},
      reason: '点卡片若还是开播，用户就永远勾不上一部片子。',
    );
  });

  testWidgets('全选勾的是当前列表里可见的那几部', (tester) async {
    final container = await pumpPage(tester);

    await tester.tap(find.byTooltip('多选（批量合并）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选 3 部'));
    await tester.pumpAndSettle();

    expect(container.read(librarySelectionProvider).keys, {'a', 'b', 'c'});
    expect(find.text('已全选'), findsOneWidget);
  });

  testWidgets('「合并到…」打开批量合并对话框', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('多选（批量合并）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片子甲').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('合并到…'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    // 对话框里要能找到被勾的那一部当目标 —— 「从这批里挑一部留下」
    // 是这条通道最自然的用法。
    expect(
      find.descendant(of: find.byType(Dialog), matching: find.text('片子甲')),
      findsWidgets,
    );
  });

  testWidgets('退出多选会清空选择（下次进来不会莫名勾着）', (tester) async {
    final container = await pumpPage(tester);

    await tester.tap(find.byTooltip('多选（批量合并）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('片子甲').first);
    await tester.pumpAndSettle();
    expect(container.read(librarySelectionProvider).keys, {'a'});

    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    expect(container.read(librarySelectionProvider).active, isFalse);
    expect(container.read(librarySelectionProvider).keys, isEmpty);
    expect(find.text('媒体库'), findsOneWidget,
        reason: '退出后页头要回到普通那一版。');
  });
}
