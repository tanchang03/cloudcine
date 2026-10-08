import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/folder_sort.dart';
import 'package:cloudcine/domain/services/media_discovery.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:cloudcine/ui/providers/settings_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/folder_browser.dart';
import 'package:cloudcine/ui/windows/desktop_play.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/fake_drive.dart';

/// 目录视图的**排序**、**修改时间单列**，以及**点了就播**。
///
/// ## 为什么要在 widget 这一层测
///
/// 排序本身在 `test/domain/folder_sort_test.dart` 里测过了（纯函数）。这里守的
/// 是另外四件只有把页面铺开才看得见的事：
///
///   1. 默认（没有任何设置行）时列表就是**修改时间倒序** —— 纯函数测不出
///      「provider 有没有真的把这个默认值接上」；
///   2. 工具条上切一次，**列表顺序真的变了**，而且**落到了设置里** ——
///      用户报的「改了没反应」几乎都出在这一步；
///   3. 修改时间是**单独一列**（`ModifiedTimeColumn`，与详情页共用），
///      不再拼在下面那行
///      `体积 · 时长 · 分辨率` 里 —— 这条是这次需求的原话，而拼接写法
///      在纯函数里根本不可见；
///   4. 未入库的视频行**点了就播**，而且**一行都不写库** —— 这条要真的走一次
///      导航才验得到（点了之后去没去播放页、带过去的是哪一条）。
class _FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState(
        account: CloudAccount(
          provider: DriveProvider.quark,
          authMode: AuthMode.browserCookie,
          authorizedAt: DateTime(2026, 10, 1),
        ),
      );
}

/// 真的那个 `build()` 会去读设置并准备一次网盘扫描，与这里要测的东西无关。
class _FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState();
}

/// `/play` 的替身：把**带过来的那一条**印在屏幕上。
///
/// 印 `displayTitle` 而不只是 id，是为了能分辨「走的是库里那一条」还是
/// 「走的是现造的那一条」—— 同一部片子在两条路上的片名可以不同（库里那条
/// 可能已经刮削过），而这正是我们要钉住的差别。
class _PlayProbe extends StatelessWidget {
  const _PlayProbe({required this.item});

  final MediaItem? item;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Text('播放页：${item?.id ?? "没有条目"}｜${item?.displayTitle ?? ""}'),
      );
}

void main() {
  setUp(() {
    // 未入库条目的登记表是**进程级状态**（见 `desktop_play.dart`）：
    // 用例之间必须隔离，否则上一条登记过的条目会让下一条「点了不该登记」
    // 的用例看到非 null。
    debugClearTransientItems();
  });
  /// 一层目录：两个子目录 + 三个视频（其中一个网盘没给修改时间）。
  ///
  /// 两组名字都刻意让「时间倒序」与「名称升序」给出**相反**的结果 ——
  /// 否则两种排序方式下的顺序碰巧一样，用例就分不出「排序生效了」和
  /// 「排序根本没被接上」。
  Map<String, List<DriveEntry>> tree() => {
        'root': [
          DriveEntry(
            id: 'd1',
            name: '第10季',
            isDirectory: true,
            modifiedAt: DateTime(2026, 9, 29, 8, 5),
          ),
          DriveEntry(
            id: 'd2',
            name: '第2季',
            isDirectory: true,
            modifiedAt: DateTime(2026, 9, 1),
          ),
          DriveEntry(
            id: 'f1',
            name: 'Show.S01E02.mkv',
            isDirectory: false,
            sizeBytes: 1048576,
            modifiedAt: DateTime(2026, 9, 1),
          ),
          DriveEntry(
            id: 'f2',
            name: 'Show.S01E10.mkv',
            isDirectory: false,
            sizeBytes: 1048576,
            modifiedAt: DateTime(2026, 9, 30, 12, 0),
          ),
          DriveEntry(
            id: 'f3',
            name: '没有时间的.mkv',
            isDirectory: false,
            sizeBytes: 1048576,
          ),
        ],
      };

  Future<ProviderContainer> pumpBrowser(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.memory();
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([FakeDriveAdapter(tree())]),
        ),
        authControllerProvider.overrideWith(_FakeAuth.new),
        scanControllerProvider.overrideWith(_FakeScan.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: FolderBrowser(onClearSearch: _noop),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// 某一行的纵向位置。用它比大小 = 比列表里的先后。
  double topOf(WidgetTester tester, String name) =>
      tester.getTopLeft(find.text(name)).dy;

  /// 带**真路由器**的版本：只有真走一次导航，才能看到「点了播放之后去了哪、
  /// 带过去的是哪一条」。
  ///
  /// [seed] 是预先写进媒体库的条目（测「已在库」那一支用）。
  Future<ProviderContainer> pumpBrowserWithRouter(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    List<MediaItem> seed = const <MediaItem>[],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.memory();
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // ⛔ 必须显式给出这一项（`pumpBrowser` 那一路不用，因为那几条用例
        //    不点行）。
        //
        // 「点了就播」那条路会走到 `playDriveEntry` → `mediaRepositoryProvider`，
        // 而组合根里的它现在**依赖 `progressStoreProvider`**（进度写透到
        // `playback_progress.json`，见 `app_providers.dart`），后者又挂在
        // `appSupportDirProvider` 上 —— 那个 provider 在 `main()` 之外一律
        // 抛 `UnimplementedError`。所以不补这一项，用例的表现是**点一下行就
        // 抛异常、页面根本没导航**，而失败信息只指向 `play_action.dart`，
        // 看不出缺的是测试的 override。
        //
        // 这里给的是**不带进度库**的仓储（`DriftMediaRepository` 的
        // `progress` 是可空的，类文档明说「单测里大量用例只关心库本身，
        // 不该被迫造一个进度文件」）：这几条用例断言的是 `media_items`
        // 有没有被写，进度那一路与它们无关，而挂一个真的 `ProgressStore`
        // 反而会留下一个 2 秒的防抖落盘计时器 —— 测试结束时那个挂着的
        // Timer 会让用例以「A Timer is still pending」失败。
        mediaRepositoryProvider.overrideWithValue(DriftMediaRepository(db)),
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([FakeDriveAdapter(tree())]),
        ),
        authControllerProvider.overrideWith(_FakeAuth.new),
        scanControllerProvider.overrideWith(_FakeScan.new),
      ],
    );
    addTearDown(container.dispose);

    if (seed.isNotEmpty) {
      await container.read(mediaRepositoryProvider).upsertItems(seed);
    }

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) =>
              Scaffold(body: FolderBrowser(onClearSearch: _noop)),
        ),
        GoRoute(
          path: '/play',
          builder: (_, state) => _PlayProbe(
            // 与真路由同一套安全 cast：`extra` 不是 `MediaItem` 时退回 null。
            item: state.extra is MediaItem ? state.extra as MediaItem : null,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('默认按修改时间倒序，且目录整组排在视频前面', (tester) async {
    await pumpBrowser(tester);

    final order = [
      '第10季', // 09-29
      '第2季', // 09-01
      'Show.S01E10.mkv', // 09-30
      'Show.S01E02.mkv', // 09-01
      '没有时间的.mkv', // 没有时间 → 垫底
    ];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(
        topOf(tester, order[i]),
        lessThan(topOf(tester, order[i + 1])),
        reason: '「${order[i]}」应该排在「${order[i + 1]}」前面 —— '
            '默认是修改时间倒序（新→旧），时间未知的垫底；'
            '同时子目录整组必须排在视频前面',
      );
    }
  });

  testWidgets('工具条切成「名称」后列表重排，并把设置落库', (tester) async {
    final container = await pumpBrowser(tester);

    // 还没切之前，设置里没有这一行 —— 走的是默认值。
    expect(
      container.read(settingsProvider).valueOrNull!.folderSortMode,
      FolderSortMode.modifiedTime,
    );

    await tester.tap(find.byTooltip('排序方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名称'));
    await tester.pumpAndSettle();

    final order = [
      '第2季', // 名称自然序：第2季 在 第10季 前面
      '第10季',
      'Show.S01E02.mkv', // S01E02 在 S01E10 前面
      'Show.S01E10.mkv',
      '没有时间的.mkv',
    ];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(
        topOf(tester, order[i]),
        lessThan(topOf(tester, order[i + 1])),
        reason: '切成「名称」之后「${order[i]}」应该排在「${order[i + 1]}」前面',
      );
    }

    expect(
      container.read(settingsProvider).valueOrNull!.folderSortMode,
      FolderSortMode.fileName,
      reason: '工具条上的切换必须落到设置里 —— 否则设置页显示的是另一个值，'
          '用户会觉得「设了没用」',
    );
    expect(
      await container.read(settingsStoreProvider).read(SettingKeys.folderSortMode),
      FolderSortMode.fileName.value,
      reason: '要真的写进设置库（不是只改了内存状态）：重启之后还得是这个顺序',
    );
  });

  testWidgets('修改时间是单独一列，不再拼在元信息那一行里', (tester) async {
    await pumpBrowser(tester);

    // 每一行的完整时刻都在自己的 tooltip 里 —— 这是「单列」的直接证据：
    // 时间是这一列的内容，而不再是下面那句 `体积 · 时长 · 分辨率 · 时间` 的尾巴。
    expect(find.byTooltip('2026-09-29 08:05'), findsOneWidget);
    expect(find.byTooltip('2026-09-30 12:00'), findsOneWidget);
    expect(
      find.byTooltip('网盘没有给出这一条的修改时间'),
      findsOneWidget,
      reason: '网盘没给时间的条目要如实说「不知道」，不能留空',
    );

    // 元信息那一行现在只剩体积（这一层没有时长 / 分辨率）。
    // 时间若还拼在后面，这里会变成 `1.0 MB · 3 天前`，下面这条就红了。
    expect(find.text('1.0 MB'), findsNWidgets(3));
  });

  testWidgets('窄窗下工具栏不溢出（排序控件是这一行里新加的）', (tester) async {
    // 面包屑那一行是「上一级 + 面包屑 + 计数 + 排序 + 复制路径」——
    // 排序是这次新塞进去的一个控件，窄窗下最容易把它挤爆。
    // ⚠️ RenderFlex 溢出在测试里会以异常形式报出来（不需要额外断言），
    // 所以这里只要能在窄窗下正常画完、控件都还在，就说明没溢出。
    await pumpBrowser(tester, size: const Size(480, 800));

    expect(find.byTooltip('排序方式'), findsOneWidget);
    expect(find.text('第10季'), findsOneWidget);
  });

  // -------------------------------------------------------------------
  // 点了就播（不要求先入库）
  // -------------------------------------------------------------------

  testWidgets('未入库的视频行：整行可点，点了直接播，且一行都不写库', (tester) async {
    final container = await pumpBrowserWithRouter(tester);

    // 点**文件名**（不是右侧按钮）—— 整行都是热区。
    await tester.tap(find.text('Show.S01E02.mkv'));
    await tester.pumpAndSettle();

    expect(
      find.text('播放页：quark:f1｜Show S01E02'),
      findsOneWidget,
      reason: '点播放必须真的把**这一条**带到播放页。库里没有它，所以只能靠'
          '随导航带过去的对象 —— 只带 id 的话内置播放页查库查不到，'
          '只会报「找不到这个媒体项」，而用户点的那部片子就在网盘上',
    );
    expect(
      await container.read(mediaRepositoryProvider).itemById('quark:f1'),
      isNull,
      reason: '「直接播」不该往库里写任何东西 —— 写进去就等于替用户做了'
          '「加入媒体库」这个决定（多一条记录、多一部作品）',
    );
    expect(
      recallTransientItem('quark:f1'),
      isNotNull,
      reason: '未入库的条目要在主窗口登记一份：播到一半直链过期时，主窗口'
          '只能凭它重新取链（查库查不到），否则用户只会看到「刷新失败」',
    );
    expect(
      recallTransientItem('quark:f1')!.dirPath,
      '/',
      reason: '目录路径要按扫描器口径归一（根目录是 `/`）—— 不归一的话，'
          '先直接播、后加入媒体库会解析出两个不同的分组键',
    );
  });

  testWidgets('未入库的行同时给出「播放」与「加入媒体库」两个入口', (tester) async {
    await pumpBrowserWithRouter(tester);

    // 三个视频行都没入库：每行各一个播放按钮 + 一个入库按钮。
    expect(find.byTooltip('直接播放（不加入媒体库）'), findsNWidgets(3));
    expect(find.text('加入媒体库'), findsNWidgets(3));

    // 右侧那个按钮也要真的能起播（不只是画着好看）。
    await tester.tap(find.byTooltip('直接播放（不加入媒体库）').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('播放页：'), findsOneWidget);
  });

  testWidgets('已在库的行走库里那一条（刮削过的片名不会被内存里那份顶掉）', (tester) async {
    // 库里那一条带着刮削后的片名 —— 而「现造的那一条」只会解析出 `Show`。
    // 两者片名不同，于是「走了哪一条」这件事可断言。
    final stored = parseTransientMedia(
      entry: const DriveEntry(id: 'f1', name: 'Show.S01E02.mkv', isDirectory: false),
      provider: DriveProvider.quark,
      dirPath: '/',
    ).item.copyWith(title: '刮削后的名字');

    await pumpBrowserWithRouter(tester, seed: [stored]);
    await tester.pumpAndSettle();

    expect(find.text('已在库'), findsOneWidget, reason: '只有 f1 在库里');
    expect(find.byTooltip('播放'), findsOneWidget);
    expect(
      find.text('加入媒体库'),
      findsNWidgets(2),
      reason: '已在库的那一行不该再给「加入媒体库」—— 那是个重复动作',
    );

    await tester.tap(find.text('Show.S01E02.mkv'));
    await tester.pumpAndSettle();

    expect(
      find.text('播放页：quark:f1｜刮削后的名字 S01E02'),
      findsOneWidget,
      reason: '已在库时必须用库里那一条：它带着刮削过的片名与归一后的分组，'
          '而内存里现造的那份只有文件名解析结果',
    );
  });

  testWidgets('窄窗下未入库的行不溢出（这一行比原先多了一个播放按钮）', (tester) async {
    // 480 是面包屑那一行还能放下的宽度（360 时先溢出的是面包屑，与本行无关）。
    // ⚠️ RenderFlex 溢出会以异常形式报出来，所以这里能画完就说明没溢出。
    await pumpBrowserWithRouter(tester, size: const Size(480, 800));

    expect(find.byTooltip('直接播放（不加入媒体库）'), findsNWidgets(3));
    expect(find.text('加入媒体库'), findsNWidgets(3));
  });
}

void _noop() {}
