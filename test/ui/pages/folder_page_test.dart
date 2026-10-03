import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/ui/pages/folder_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/folder_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/storage_meter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 「文件夹」作为**侧栏一级入口**那一页。
///
/// ## 为什么要在页面这一层测
///
/// 这一页是从媒体库的视图切换里拆出来的，风险全在「拆干净了没有」上：
///
///   1. 它得有自己的页头（标题「文件夹」），不能还挂在媒体库的标题下面 ——
///      否则用户点侧栏切过来，看到的还是「媒体库」，会以为点错了；
///   2. 它的搜索框必须筛**当前这一层**，而**不能**写进媒体库的
///      `libraryFilterProvider.query`。两处原先共用一个词，拆开后若还共用，
///      用户会在「媒体库搜了『沙丘』→ 切到文件夹」时看到一个几乎空白的
///      目录（框是空的、列表被上一个页面的词过滤着），而完全看不出原因。
///      这条正是拆分的**唯一**状态陷阱，且不报错、只在特定顺序下出现。
class _FakeAuth extends AuthController {
  _FakeAuth({this.account});

  /// 要摆出的账号。`null` 用一份**不带容量信息**的默认值 —— 容量条的两个分支
  /// （画 / 不画）都靠它区分，所以默认值必须是没有容量的那一份。
  final CloudAccount? account;

  @override
  Future<AuthState> build() async => AuthState(
        account: account ??
            CloudAccount(
              provider: DriveProvider.quark,
              authMode: AuthMode.browserCookie,
              authorizedAt: DateTime(2026, 10, 3),
            ),
      );
}

/// 真的那个 `build()` 会去读设置并准备一次网盘扫描，与这里要测的东西无关。
class _FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState();
}

/// 列表里某一行的文字。
///
/// 必须限定在 `ListView` 内：搜索框（`EditableText`）里的字也会被 `find.text`
/// 命中，而用例里正好会往搜索框里打同样的词 —— 直接 `find.text('第2季')`
/// 会同时找到「输入框里的」和「列表行上的」两个，`findsOneWidget` 随之失败。
Finder rowText(String name) => find.descendant(
      of: find.byType(ListView),
      matching: find.text(name),
    );

void main() {
  /// 一层目录：两个子目录 + 一个视频。名字刻意让「搜『第2季』」只剩一条。
  Map<String, List<DriveEntry>> tree() => {
        'root': [
          DriveEntry(id: 'd1', name: '第10季', isDirectory: true),
          DriveEntry(id: 'd2', name: '第2季', isDirectory: true),
          DriveEntry(id: 'f1', name: 'Show.S01E02.mkv', isDirectory: false),
        ],
      };

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    CloudAccount? account,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
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
        authControllerProvider.overrideWith(() => _FakeAuth(account: account)),
        scanControllerProvider.overrideWith(_FakeScan.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: FolderPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('有自己的一级页头：标题是「文件夹」，不是「媒体库」', (tester) async {
    await pumpPage(tester);

    expect(find.text('文件夹'), findsOneWidget,
        reason: '它是侧栏上独立的一级入口，页头必须自报家门 —— 还写着'
            '「媒体库」的话，用户会以为侧栏点错了。');
    expect(find.text('媒体库'), findsNothing);
    expect(find.text('第2季'), findsOneWidget,
        reason: '列的是网盘这一层的条目。');
  });

  testWidgets('搜索框筛的是当前这一层，且**不写进**媒体库的搜索词', (tester) async {
    final container = await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '第2季');
    // 搜索是防抖的（250ms），必须等过那一下才看得到结果。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // 只看**列表里**的行：`find.text` 会把搜索框自己那段文字也算进去，
    // 而它此刻正好也写着「第2季」。
    expect(rowText('第2季'), findsOneWidget);
    expect(rowText('第10季'), findsNothing,
        reason: '没筛掉不匹配的条目 = 搜索框是摆设。');
    expect(container.read(folderQueryProvider), '第2季');

    expect(container.read(libraryFilterProvider).query, isEmpty,
        reason: '两处是**两个一级入口**，搜索词必须各管各的 —— 共用一个词会让'
            '「在媒体库搜完再切过来」看到一个被上一个页面的词过滤着的空目录，'
            '而输入框里什么都没有。');
  });

  testWidgets('刷新按钮在这一页的页头（目录内容不跟写库信号自动失效）',
      (tester) async {
    await pumpPage(tester);

    expect(find.byTooltip('刷新'), findsOneWidget);
  });

  testWidgets('账号带容量时，页头下方画出「已用 / 总量 · 剩多少」与进度条',
      (tester) async {
    // 1.5 GiB / 2 GiB —— 剩 0.5 GiB。用 1024 进制是为了让期望文案能心算：
    // 若实现改成了 1000 进制，这里会显示 `1.6 GB / 2.1 GB`，一眼看出不对。
    await pumpPage(
      tester,
      account: CloudAccount(
        provider: DriveProvider.quark,
        authMode: AuthMode.browserCookie,
        authorizedAt: DateTime(2026, 10, 3),
        storageUsedBytes: 1610612736,
        storageTotalBytes: 2147483648,
      ),
    );

    expect(find.text('1.5 GB / 2.0 GB · 剩 512.0 MB'), findsOneWidget,
        reason: '三段缺一不可：只给「已用/总量」的话，用户还得自己减一下才知道'
            '「还能不能把这部片子传上去」—— 而那正是这一行存在的理由。');

    // 进度条填到 75%。这一条钉的是「进度条真的跟着数字走」，
    // 而不是「画了个宽度写死的装饰条」。
    final frac = tester.widget<FractionallySizedBox>(
      find.ancestor(
        of: find.byKey(DriveStorageMeter.fillKey),
        matching: find.byType(FractionallySizedBox),
      ),
    );
    expect(frac.widthFactor, closeTo(0.75, 0.001));
  });

  testWidgets('拿不到容量信息时，整行不画（不画成 0 B / 0 B）', (tester) async {
    // 默认账号没有 `storageTotalBytes`。
    await pumpPage(tester);

    expect(find.byKey(DriveStorageMeter.fillKey), findsNothing,
        reason: '把「不知道」画成 `0 B / 0 B` 会被读成「网盘满了」，与事实'
            '正好相反 —— 用户会去删东西。判据收在组件里，页面不重复。');
  });

  group('多选批量删除', () {
    /// 进入多选模式。
    Future<void> enterSelection(WidgetTester tester) async {
      await tester.tap(find.byTooltip('多选（批量删除）'));
      await tester.pumpAndSettle();
    }

    /// 「删除」按钮此刻是不是按不动。
    ///
    /// ⚠️ 不能用 `find.byType(FilledButton)`：`FilledButton.icon` 是它的
    /// **子类**（`_FilledButtonWithIcon`），而 `byType` 比的是运行时的确切
    /// 类型 —— 用它找会得到「No element」，看起来像按钮没渲染出来。
    bool deleteDisabled(WidgetTester tester, String label) {
      final btn = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      return btn.onPressed == null;
    }

    testWidgets('进入多选：工具条替代面包屑，一个都没勾时删除按钮按不动',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('根目录'), findsOneWidget, reason: '还没进多选，面包屑在。');

      await enterSelection(tester);

      expect(find.text('勾选要移动或删除的条目'), findsOneWidget);
      expect(find.text('根目录'), findsNothing,
          reason: '多选时当前目录是冻结的（换目录会清空勾选），面包屑留着'
              '只会让人以为点它还能跳层 —— 跳了就白勾了。');
      expect(deleteDisabled(tester, '删除'), isTrue,
          reason: '一个都没勾就能按下去的话，用户会得到一个「删除 0 项」的'
              '空动作，然后怀疑这个功能坏了。');
    });

    testWidgets('点一行是**勾选**，不是进那个目录', (tester) async {
      await pumpPage(tester);
      await enterSelection(tester);

      await tester.tap(rowText('第2季'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 项'), findsOneWidget);
      expect(deleteDisabled(tester, '删除 1 项'), isFalse);
      expect(rowText('第10季'), findsOneWidget,
          reason: '点一行只是勾选，不该钻进「第2季」—— 钻进去的话列表会变成'
              '那个目录的内容（这里是空的），而用户以为自己只是选了一下。');
    });

    testWidgets('再点一下取消勾选', (tester) async {
      await pumpPage(tester);
      await enterSelection(tester);

      await tester.tap(rowText('第2季'));
      await tester.pumpAndSettle();
      await tester.tap(rowText('第2季'));
      await tester.pumpAndSettle();

      expect(find.text('勾选要移动或删除的条目'), findsOneWidget);
      expect(find.text('已选 1 项'), findsNothing);
    });

    testWidgets('长按任意一行进入多选，且连按的那一下一起生效', (tester) async {
      await pumpPage(tester);

      await tester.longPress(rowText('Show.S01E02.mkv'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 项'), findsOneWidget,
          reason: '长按的意图是「我要选这个」。长按完还得再点一次才能选上，'
              '等于那一次长按白做了。');
    });

    testWidgets('「全选」只勾当前**可见**的条目（搜索词筛掉的不算）',
        (tester) async {
      await pumpPage(tester);

      // 先筛出只剩一条。
      await tester.enterText(find.byType(TextField), '第2季');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await enterSelection(tester);
      expect(find.text('全选 1 项'), findsOneWidget,
          reason: '全选 = 「把屏幕上这些全勾上」。按「这一层的全部」算的话，'
              '用户筛出三个文件、点全选、按删除，删掉的是同目录另外两百个 —— '
              '而界面上完全看不出这件事。');

      await tester.tap(find.text('全选 1 项'));
      await tester.pumpAndSettle();

      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.text('已全选'), findsOneWidget);
    });

    testWidgets('退出多选会一并清空勾选', (tester) async {
      await pumpPage(tester);
      await enterSelection(tester);

      await tester.tap(rowText('第2季'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);

      await tester.tap(find.byTooltip('退出多选'));
      await tester.pumpAndSettle();
      // 再进一次：不该还勾着上一次那一条。
      await enterSelection(tester);

      expect(find.text('勾选要移动或删除的条目'), findsOneWidget,
          reason: '不清的话，用户下次进多选看到「已选 1 项」，按下删除 —— '
              '删掉的是上一次勾的那个文件，而他以为自己在挑新的。');
    });
  });
}
