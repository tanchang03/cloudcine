import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/work_detail_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手动归一（详情页「合并到…」）的整条链路：按钮 → 对话框 → 落库 → 跳页 → 撤销。
///
/// ## 为什么这四条值得单独钉住
///
/// 自动归一**只认 `onlineId`**，所以这一条通道处理的是它永远碰不到的三种情况
/// （本地片名差异大、压根没刮到、刮到两个不同条目）。也就是说：这条路上
/// **没有任何兜底**，它自己错一次，用户就只能手工在网盘里改目录名。
///
/// 而它最容易错的恰恰不是「合不上」，是**方向**与**能不能退**：
///
///   1. 按钮写的是「合并**到**…」，所以列表里留下的必须是**用户选中的**
///      那一部 —— 搞反了就是「用户想留的那部消失了」；
///   2. 不能合的情况（会成链）必须在点之前就说清楚，否则按钮亮着却点了
///      没反应，看起来就是应用坏了；
///   3. 撤销必须真的还原（这条路上用户的信任全靠它 —— 合并错一次而不可逆，
///      他以后就不敢用了）。
void main() {
  final now = DateTime(2026, 10, 2);

  /// 按标签找一个按钮。
  ///
  /// ⚠️ **不能用 `find.widgetWithText(OutlinedButton, …)`**：
  /// `OutlinedButton.icon` 造出来的是它的一个私有子类，而 `find.byType` 是
  /// **精确类型**匹配 —— 于是「按钮明明画在屏幕上」却找不到，报的还是一句
  /// 与原因毫无关系的「找不到 OutlinedButton」。用 `is` 判定才认子类。
  Finder buttonWith<T extends Widget>(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is T),
      );

  bool isEnabled<T extends Widget>(WidgetTester tester, String label) {
    final w = tester.widget(buttonWith<T>(label)) as T;
    if (w is OutlinedButton) return w.onPressed != null;
    if (w is FilledButton) return w.onPressed != null;
    fail('$T 不是有 onPressed 的按钮类型');
  }

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

  MediaWork work(
    String key, {
    required String title,
    ScrapeSource source = ScrapeSource.local,
    int itemCount = 1,
    String? mergedInto,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        source: source,
        itemCount: itemCount,
        mergedInto: mergedInto,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 打开「currentKey」的详情页。
  ///
  /// [extra] 是除这两部之外的其它作品；[mergeFirst] 用来先把某几部折起来
  /// （造出「源自己还折着别人」这种会成链的状态）。
  Future<DriftMediaRepository> open(
    WidgetTester tester, {
    required String currentKey,
    List<MediaWork> extra = const [],
    List<(String, String)> mergeFirst = const [],
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);

    await repo.upsertWorks(
      [
        work('a', title: '流浪地球2'),
        work('b', title: 'The Wandering Earth II'),
        work('c', title: '另一部不相干的片子', itemCount: 9),
        ...extra,
      ],
      now: now,
    );
    await repo.upsertItems([
      item('a', 'fa1', 'A.2023.E01.mkv'),
      item('b', 'fb1', 'B.2023.E05.mkv'),
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

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: WorkDetailPage(workKey: currentKey)),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('详情页有「合并到…」按钮；点开后列出别的作品、不列自己', (tester) async {
    await open(tester, currentKey: 'a');

    expect(buttonWith<OutlinedButton>('合并到…'), findsOneWidget);
    // 本地数据修正，一次网络请求都不发 —— 不该跟着 canScrapeOnline 变灰。
    expect(isEnabled<OutlinedButton>(tester, '合并到…'), isTrue,
        reason: '没配 TMDB / 豆瓣的用户恰恰最需要它（没有在线源时全靠文件名'
            '解析，同一部片子被拆成两个格子最常见）。');

    await tester.tap(buttonWith<OutlinedButton>('合并到…'));
    await tester.pumpAndSettle();

    // 搜索框预填的是**当前片名**，所以要先清空才看得到别的作品。
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // ⚠️ 候选断言必须**限定在对话框里**：详情页在后面还渲染着，
    // 它自己那张大标题正是「流浪地球2」—— 全局搜会搜到它，
    // 于是「候选里没有自己」这条断言永远是红的。
    Finder inDialog(Finder inner) =>
        find.descendant(of: find.byType(Dialog), matching: inner);

    expect(inDialog(find.text('The Wandering Earth II')), findsWidgets);
    expect(inDialog(find.text('另一部不相干的片子')), findsWidgets);
    // 「不能把一部作品并到它自己」—— 自己不该出现在候选里。
    expect(inDialog(find.text('流浪地球2')), findsNothing);
  });

  testWidgets('搜索框预填当前片名；清空后列出全部作品', (tester) async {
    await open(tester, currentKey: 'a');

    await tester.tap(buttonWith<OutlinedButton>('合并到…'));
    await tester.pumpAndSettle();

    // 预填「流浪地球2」→ 只有自己叫这个名字，被排掉之后零匹配。
    // ⚠️ 这时**必须**告诉用户「清空就能看到全部」，而不是只说「没找到」——
    // 这条通道最常见的用法恰恰是「两个片名完全不一样」。
    expect(find.textContaining('清空'), findsWidgets);
    expect(find.text('The Wandering Earth II'), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('The Wandering Earth II'), findsWidgets);
    expect(find.text('另一部不相干的片子'), findsWidgets);
  });

  testWidgets('选中 → 确认：留下的是**选中的**那一部，页面跟着跳过去', (tester) async {
    final repo = await open(tester, currentKey: 'a');

    await tester.tap(buttonWith<OutlinedButton>('合并到…'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Wandering');
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Wandering Earth II').first);
    await tester.pumpAndSettle();

    // 确认行必须把方向写死 —— 方向搞反的代价是「用户想留的那部不见了」。
    expect(find.textContaining('《流浪地球2》→《The Wandering Earth II》'),
        findsOneWidget);

    await tester.tap(buttonWith<FilledButton>('合并'));
    await tester.pumpAndSettle();

    expect((await repo.workByKey('a'))!.mergedInto, 'b',
        reason: '按钮写的是「合并**到**…」，所以 a 折进 b，留下的那一部是 b。');
    expect((await repo.listWorks()).map((w) => w.key), ['b', 'c']);

    // 页面跟着 mergedInto 跳到目标，并挂上「已并入／拆开」提示条。
    expect(find.textContaining('已并入'), findsOneWidget);
    expect(find.textContaining('流浪地球2'), findsWidgets);
    // 并集：目标页上要能看到源作品的文件。
    expect(find.text('A.2023.E01.mkv'), findsWidgets);
    expect(find.text('B.2023.E05.mkv'), findsWidgets);
  });

  testWidgets('合并后的提示里带「撤销」，点了真的还原', (tester) async {
    final repo = await open(tester, currentKey: 'a');

    await tester.tap(buttonWith<OutlinedButton>('合并到…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Wandering');
    await tester.pumpAndSettle();
    await tester.tap(find.text('The Wandering Earth II').first);
    await tester.pumpAndSettle();
    await tester.tap(buttonWith<FilledButton>('合并'));
    await tester.pumpAndSettle();

    expect(find.text('撤销'), findsOneWidget,
        reason: '合并错一次而不可逆，用户以后就不敢用了 —— 撤销是这条通道的'
            '信任基础。');

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect((await repo.listWorks()).map((w) => w.key).toSet(), {'a', 'b', 'c'});
    expect((await repo.workByKey('a'))!.mergedInto, isNull);
    expect(find.textContaining('已并入'), findsNothing);
  });

  testWidgets('源自己还折着别的作品 → 整个对话框说清楚原因，一条都选不了', (tester) async {
    // 自动归一刚把 b 合到 a 上，用户又想把 a 并进 c。
    // 这时合下去会形成链（c ← a ← b），而链上任何一环被单独撤销都会把
    // 后面的节点孤儿化 —— 所以必须挡住，并且告诉他先「拆开」。
    await open(tester, currentKey: 'a', mergeFirst: [('a', 'b')]);

    await tester.tap(buttonWith<OutlinedButton>('合并到…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('先回到它的详情页点「拆开」'), findsOneWidget);

    // 清空搜索（预填的是当前片名）才看得到别的作品。
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // 点候选行不生效（行本身不可点）。
    await tester.tap(find.text('另一部不相干的片子').first);
    await tester.pumpAndSettle();

    expect(isEnabled<FilledButton>(tester, '合并'), isFalse,
        reason: '按钮亮着却点了没反应，看起来就是应用坏了。');
  });
}
