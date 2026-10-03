import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/download_task.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/diagnostics_page.dart';
import 'package:cloudcine/ui/pages/downloads_page.dart';
import 'package:cloudcine/ui/pages/folder_page.dart';
import 'package:cloudcine/ui/pages/scan_page.dart';
import 'package:cloudcine/ui/pages/settings_page.dart';
import 'package:cloudcine/ui/pages/work_detail_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/download_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_affordance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';
import '../../support/focus_reach.dart';

/// **下载**与**设置**两页在电视尺寸下的排版。
///
/// ## 为什么单开一个文件，而不是塞进各自那一份
///
/// 那两份测的是**功能接线**（点哪个按钮调哪个方法、设置写进哪个键），
/// 它们都用 1000–1100 宽的窗口 —— 那正是桌面尺寸，于是 TV 分支在那些用例里
/// **一次都没被走到**。而「TV 上排版乱」这件事只有把 view 报成 960 才会显形。
///
/// ## 宽度是 624，不是 960
///
/// 见 `library_tv_layout_test.dart` 的长注释：真实链路上被吃掉两层 ——
/// 过扫描 48×2 + 侧栏 240。只把 view 设成 960 而让页面占满，等于凭空多给
/// 336px，测出来的「没溢出」是假的。
class _FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState(
        account: CloudAccount(
          provider: DriveProvider.quark,
          authMode: AuthMode.browserCookie,
          authorizedAt: DateTime(2026, 10, 3),
        ),
      );
}

/// 只喂状态、不碰真队列（真队列会去建 SQLite、读适配器注册表）。
class _FakeQueue extends DownloadQueueController {
  _FakeQueue(this._tasks);

  final List<DownloadTask> _tasks;

  @override
  List<DownloadTask> build() => _tasks;
}

/// 真的那个 `build()` 会去读设置并准备一次网盘扫描，与排版无关
/// （照抄 `folder_browser_test.dart` 的做法）。
class _FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState();
}

/// 文件夹页要一层真的目录内容才会把工具条铺出来 —— 空列表时它渲染的是
/// 空态，那样这条用例就测不到任何东西（面包屑 + 发现按钮那一行才是
/// 电视上最可能挤爆的地方）。
Map<String, List<DriveEntry>> _driveTree() => {
      'root': [
        for (var i = 1; i <= 3; i++)
          DriveEntry(
            id: 'd$i',
            name: '第${i * 3}季（一个相当长的目录名）',
            isDirectory: true,
            modifiedAt: DateTime(2026, 9, 1 + i),
          ),
        for (var i = 1; i <= 4; i++)
          DriveEntry(
            id: 'f$i',
            name: 'Show.S01E0$i.1080p.WEB-DL.x264.mkv',
            isDirectory: false,
            sizeBytes: 1048576 * i,
            modifiedAt: DateTime(2026, 9, 20, i),
          ),
      ],
    };

DownloadTask _task(String fileId, DownloadStatus status) => DownloadTask(
      id: 'quark:$fileId',
      provider: 'quark',
      fileId: fileId,
      name: '$fileId.bin',
      dirPath: '/电影',
      savePath: '/tmp/cloudcine_tv_layout/$fileId.bin',
      status: status,
      receivedBytes: 500,
      sizeBytes: 1000,
      createdAt: DateTime(2026, 10, 3, 12),
      updatedAt: DateTime(2026, 10, 3, 12),
    );

void main() {
  /// 真机上电视**壳内**页面区的尺寸：960 − 过扫描 96 − 侧栏 240 = **624**；
  /// 540 − 过扫描 54 = **486**。
  const tvPageWidth = 624.0;
  const tvPageHeight = 486.0;

  /// 壳外那些**整幅页**（`/work`、`/diagnostics`、`/auth/qr`）的尺寸。
  ///
  /// ⚠️ 它们不在 `StatefulShellRoute` 里（见 `app_router.dart`），把整屏换掉，
  /// 所以**既没有侧栏那 240，也没有壳那层过扫描内边距** —— 拿满 960。
  /// 拿 624 去铺它们，测的是一个不存在的屏宽（而且比真实情况更严，
  /// 会掩盖真实宽度下的问题）。
  const tvFullWidth = 960.0;

  /// 铺开一个页面：view 报电视尺寸（判据为真），但页面只拿到 [width]×486。
  Future<void> pumpOnTv(
    WidgetTester tester,
    Widget page, {
    double width = tvPageWidth,
  }) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: const Key('tv-frame'),
              width: width,
              height: tvPageHeight,
              child: page,
            ),
          ),
        ),
      ),
    );
  }

  /// 跑一页并断言「没有 RenderFlex 溢出」。
  ///
  /// ⚠️ 溢出在 Debug 下是黄黑斜纹，**在 Release 下溢出部分直接被裁掉** ——
  /// 后者看起来就像「那个按钮本来就没有」，而它还在焦点链里，遥控器按得到、
  /// 屏幕上却看不见。用户只会以为遥控器坏了。
  Future<void> expectNoOverflow(
    WidgetTester tester,
    Future<void> Function() pump, {
    required String what,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pump();
      expect(tester.takeException(), isNull, reason: '$what 在电视宽度下溢出了');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('下载页：电视宽度下不溢出（进行中 + 已完成两组都在）',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadQueueProvider.overrideWith(
          () => _FakeQueue([
            _task('a', DownloadStatus.downloading),
            _task('b', DownloadStatus.completed),
            _task('c', DownloadStatus.failed),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectNoOverflow(
      tester,
      () async {
        await pumpOnTv(
          tester,
          UncontrolledProviderScope(
            container: container,
            child: const DownloadsPage(),
          ),
        );
        // ⚠️ `pump` 而不是 `pumpAndSettle`：总长未知时进度条是不确定态，
        // 它的动画永远不结束，`pumpAndSettle` 会直接超时。
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        // 防空转：一条任务都没渲染出来时，「不溢出」是废话。
        expect(
          find.textContaining('.bin'),
          findsWidgets,
          reason: '下载任务没铺出来，这条用例测了个寂寞',
        );
      },
      what: '下载页',
    );
  });

  testWidgets('设置页：电视宽度下不溢出', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    // 设置页会读海报缓存目录并异步算占用 —— 给一个真的空目录，
    // 别让它去碰用户的家目录。
    final cacheDir = Directory.systemTemp.createTempSync('cloudcine_tv_settings');
    addTearDown(() => cacheDir.deleteSync(recursive: true));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(DriftMediaRepository(db)),
        authControllerProvider.overrideWith(_FakeAuth.new),
        posterCacheDirProvider.overrideWithValue(cacheDir.path),
        appSupportDirProvider.overrideWithValue(cacheDir.path),
      ],
    );
    addTearDown(container.dispose);

    await expectNoOverflow(
      tester,
      () async {
        await pumpOnTv(
          tester,
          UncontrolledProviderScope(
            container: container,
            child: const SettingsPage(),
          ),
        );
        await tester.pumpAndSettle();
      },
      what: '设置页',
    );
  });

  testWidgets('作品详情页：电视宽度下不溢出（它是控件最密的一页）',
      (tester) async {
    final now = DateTime(2026, 10, 3);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);
    await repo.upsertWorks([
      MediaWork(
        key: 'aot',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '进击的巨人',
        updatedAt: now,
      ),
    ], now: now);
    await repo.upsertItems([
      for (var i = 1; i <= 3; i++)
        MediaItem(
          provider: DriveProvider.quark,
          fileId: 'S01E0$i',
          name: '进击的巨人 S01E0$i.mkv',
          dirId: 'd1',
          dirPath: '/动漫/进击的巨人/',
          groupKey: 'aot',
          kind: MediaKind.episode,
          title: '进击的巨人',
          season: 1,
          episode: i,
          durationMs: 24 * 60 * 1000,
          firstSeenAt: now,
          updatedAt: now,
        ),
    ], now: now);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    // 这一页的页头挤着「刮削 / 手动 / 合并到…」等一排按钮，下面还有带
    // 进度条与分辨率角标的文件行 —— 全项目控件最密的一页，也是媒体库页头
    // 那次溢出之后最可能重演的地方。
    //
    // ⚠️ 宽度给 **960** 而不是 624：`/work` 在 `StatefulShellRoute` **之外**，
    // 拿满整屏（见 `tvFullWidth` 的注释）。给 624 是给了一个不存在的屏宽。
    await expectNoOverflow(
      tester,
      () async {
        await pumpOnTv(
          tester,
          UncontrolledProviderScope(
            container: container,
            child: const WorkDetailPage(workKey: 'aot'),
          ),
          width: tvFullWidth,
        );
        await tester.pumpAndSettle();
        // ⚠️ 防空转：作品取不到时这一页是空态，页头那一排按钮就不在了。
        expect(
          find.textContaining('进击的巨人'),
          findsWidgets,
          reason: '作品没读出来，页头那排按钮没渲染，这条用例测了个寂寞',
        );
      },
      what: '作品详情页',
    );
  });

  testWidgets('壳外的整幅页要让开过扫描区（否则内容左移 48px、返回键被切）',
      (tester) async {
    // ## 这条钉的是什么
    //
    // `AppShell` 给**壳内**那五个一级页面统一加了 `AppTheme.safeAreaInsets`
    // （`app_shell.dart` 的 `build` 里 `body:` 那一层，⚠️ 不写行号）。
    // 但 `/work`、`/diagnostics`、`/auth/qr` 都在
    // `StatefulShellRoute` **之外** —— 它们把整屏换掉，拿不到那一层。
    //
    // 实测（不加时）：`/work` 拿满 960，顶栏左内边距只有 10，而
    // `tvSafeHorizontal = 48`。后果有两层，第二层更难受：
    //   1. 最左边那个返回键落进过扫描带里被切掉；
    //   2. 电视上从媒体库点进详情页，内容**整体左移 48px** —— 页头本该在
    //      同一个位置，跳一下会让人以为换了个应用。
    //
    // ⛔ 反向的两条也在这里钉住：**居中且有 maxWidth 的页不用加**（加了只是
    // 白白缩窄），**全屏视频页更不能加**（会变成黑边）。所以这不是「一刀切
    // 全加上」，得逐页判。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final now = DateTime(2026, 10, 3);
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final repo = DriftMediaRepository(db);
      await repo.upsertWorks([
        MediaWork(
          key: 'aot',
          provider: DriveProvider.quark,
          kind: MediaKind.episode,
          title: '进击的巨人',
          updatedAt: now,
        ),
      ], now: now);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          mediaRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);

      await pumpOnTv(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: const WorkDetailPage(workKey: 'aot'),
        ),
        width: tvFullWidth,
      );
      await tester.pumpAndSettle();

      // 顶栏第一个 TvIconLabel 就是那个「返回」键 —— 它是这一页最贴边的控件。
      final back = tester.getRect(find.byType(TvIconLabel).first);
      expect(
        back.left,
        greaterThanOrEqualTo(AppTheme.tvSafeHorizontal - 0.5),
        reason: '返回键左边距只有 ${back.left}，而电视过扫描带是 '
            '${AppTheme.tvSafeHorizontal}px —— 它会落在被切掉的那一圈里。'
            '`/work` 在壳外，这一层得页面自己加（见 AppTheme.safeAreaInsets 的文档）',
      );
      expect(
        back.top,
        greaterThanOrEqualTo(AppTheme.tvSafeVertical - 0.5),
        reason: '返回键上边距只有 ${back.top}，纵向过扫描带是 '
            '${AppTheme.tvSafeVertical}px',
      );

      // 诊断页同一个病：`/diagnostics` 也在壳外，而且它是要**一行行读**的日志 ——
      // 左边被切掉就等于每条日志都少了开头几个字。
      await pumpOnTv(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: const DiagnosticsPage(),
        ),
        width: tvFullWidth,
      );
      await tester.pumpAndSettle();
      final diagBack = tester.getRect(find.byType(TvIconLabel).first);
      expect(
        diagBack.left,
        greaterThanOrEqualTo(AppTheme.tvSafeHorizontal - 0.5),
        reason: '诊断页的返回键左边距只有 ${diagBack.left} —— 它同样在壳外，'
            '得自己加过扫描边距',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('扫描页：电视宽度下不溢出（那一行按钮 + Spacer + 统计文字）',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(DriftMediaRepository(db)),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
    addTearDown(container.dispose);

    // 这一页的危险处在「开始扫描 / 停止」那一行：`Row` 里塞了两个按钮
    // （图标 + 文字），右边还挂一段统计文字，中间只有一个 `Spacer`。
    // ⚠️ `Spacer` 是 flex 子项，**它只能吃剩下的空间、不能把别人挤小** ——
    // 定宽部分一旦超过 580，它先被压成 0，然后溢出照旧发生。
    await expectNoOverflow(
      tester,
      () async {
        await pumpOnTv(
          tester,
          UncontrolledProviderScope(
            container: container,
            child: const ScanPage(),
          ),
        );
        await tester.pumpAndSettle();
        // ⚠️ 防空转：这一页在未登录时渲染的是空态、拿不到列表时渲染的是错误态，
        // 两种情况下那条 `Row` 根本不存在 —— 「不溢出」就成了废话。
        // 先确认带按钮的那一行真的铺出来了。
        expect(
          find.text('开始扫描'),
          findsOneWidget,
          reason: '扫描页没渲染出「开始扫描」，说明走的是空态，这条用例测了个寂寞',
        );
      },
      what: '扫描页',
    );
  });

  testWidgets('文件夹页：电视宽度下不溢出（面包屑 + 发现按钮那一行）',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(DriftMediaRepository(db)),
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([FakeDriveAdapter(_driveTree())]),
        ),
        authControllerProvider.overrideWith(_FakeAuth.new),
        scanControllerProvider.overrideWith(_FakeScan.new),
      ],
    );
    addTearDown(container.dispose);

    // 这一页的危险处在 `FolderBrowser` 的工具条：左边「上一级」、右边一串
    // 面包屑，下面还有一行「发现全部 / 下载全部」。面包屑那一截靠
    // `Expanded` + 横向滚动兜着（所以再长的路径也挤不爆），但**面包屑之外的
    // 那两个按钮是定宽的** —— 页头那六个控件溢出的同一种错法在这里重演一次
    // 就够了，所以把目录名刻意写长（进得深 = 面包屑更长）。
    await expectNoOverflow(
      tester,
      () async {
        await pumpOnTv(
          tester,
          UncontrolledProviderScope(
            container: container,
            child: const FolderPage(),
          ),
        );
        await tester.pumpAndSettle();
        // ⚠️ 防空转：目录没列出来时这一页渲染的是空态 / 错误态，那条面包屑
        // 工具条根本不存在，测出来的「不溢出」是假的。
        expect(
          find.textContaining('第3季'),
          findsWidgets,
          reason: '目录内容没铺出来，说明走的是空态，这条用例测了个寂寞',
        );
      },
      what: '文件夹页',
    );
  });

  testWidgets('文件夹页：工具条与目录行，遥控器都够得到', (tester) async {
    // 排版没溢出 ≠ 用得了。这一页在电视上的价值全押在「焦点能不能走到
    // 工具条那个『上一级』和列表行」上 —— 走不到的话，用户打开文件夹
    // 只能看第一屏，既退不出去也进不了下一层。
    //
    // ⚠️ 行的目标是**包住 InkWell 的那一层**，不是行里那段文字：焦点宿主
    // 是 InkWell 内部的 `Focus`，它是文字的**祖先**，拿文字去找永远找不到
    // （见 `focus_reach.dart` 的说明）。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          mediaRepositoryProvider.overrideWithValue(DriftMediaRepository(db)),
          adapterRegistryProvider.overrideWithValue(
            AdapterRegistry([FakeDriveAdapter(_driveTree())]),
          ),
          authControllerProvider.overrideWith(_FakeAuth.new),
          scanControllerProvider.overrideWith(_FakeScan.new),
        ],
      );
      addTearDown(container.dispose);

      await pumpOnTv(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: const FolderPage(),
        ),
      );
      await tester.pumpAndSettle();

      final toolbar = find.byType(TvIconLabel);
      final dirRow = find
          .ancestor(
            of: find.textContaining('第3季'),
            matching: find.byType(InkWell),
          )
          .first;
      // ⚠️ 必须挑**已经建出来的那一行**：`ListView` 是懒加载的，624×486 的
      // 视口里 3 个目录 + 4 个视频只建得出前几条（实测只到 `S01E04`）。
      // 默认排序是**修改时间倒序**，所以 `E04`（最晚改的）恰好是列表第一条；
      // 写成 `S01E01` 会得到「找不到」—— 那不是焦点问题，是它压根还没被建。
      // 视口外那几行靠焦点驱动滚动才会建出来，不在这条用例的射程内。
      final fileRow = find
          .ancestor(
            of: find.textContaining('Show.S01E04'),
            matching: find.byType(InkWell),
          )
          .first;

      expect(toolbar, findsWidgets, reason: '工具条没渲染出来，这条用例测不到东西');
      expect(dirRow, findsOneWidget, reason: '目录行没铺出来');
      expect(fileRow, findsOneWidget, reason: '视频行没铺出来');

      final hit = await walkReachability(
        tester,
        probes: {
          '工具条': (t) => anyFocusedInside(t, toolbar),
          '目录行': (t) => focusedInside(t, dirRow),
          '视频行': (t) => focusedInside(t, fileRow),
        },
      );

      expect(hit[0], isTrue, reason: '焦点走不到工具条 —— 「上一级」够不到，'
          '进了深目录就出不来了');
      expect(hit[1], isTrue, reason: '焦点走不到目录行 —— 电视上无法进入下一层');
      expect(hit[2], isTrue, reason: '焦点走不到视频行 —— 电视上点不了「播放」');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('这两页在电视上都还能往下滚 —— 486 高的视口装不下它们',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          downloadQueueProvider.overrideWith(
            () => _FakeQueue([_task('a', DownloadStatus.downloading)]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await pumpOnTv(
        tester,
        UncontrolledProviderScope(
          container: container,
          child: const DownloadsPage(),
        ),
      );
      await tester.pump();

      // 能滚才说明「下面还有内容」这件事是可达的 —— 不滚的话，电视上
      // 视口只有 486，下半页等于不存在（而它既不报错也不提示）。
      expect(
        find.byType(Scrollable),
        findsWidgets,
        reason: '下载 / 设置这类长页面必须包在可滚动容器里，'
            '否则 486 高的电视视口会把下半页整块吃掉',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
