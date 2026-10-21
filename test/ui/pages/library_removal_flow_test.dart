import 'dart:async';
import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/library_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// **整条批量移除流程**在真实 `LibraryPage` 上的接线。
///
/// ## 为什么单测过了还要这一条
///
/// 前面几个测试各自钉住了一环：文案值对象（说什么）、确认框（返回什么）、
/// 执行器（动什么）。但它们之间**怎么串**没有一条测试覆盖 —— 而串错的方式
/// 全都不会报错：
///
///   1. `_removeSelected` 忘了把勾选结果传给 `alsoDeleteFromDrive`
///      ⇒ 用户勾了「一并删」，网盘上却一个都没少；
///   2. 勾了却没套进度层 ⇒ 几十秒的静默（就是这次要修的那个问题）；
///   3. 结果提示漏传 `drive` ⇒ 删了网盘却提示「网盘文件未动」。
///
/// 这一条从「点选择」一路点到「结果提示」，中间不 mock 页面。
class _FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState(
        accounts: {
          DriveProvider.quark: CloudAccount(
            provider: DriveProvider.quark,
            authMode: AuthMode.browserCookie,
            authorizedAt: DateTime(2026, 10, 21),
          ),
        },
      );
}

class _FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState();
}

/// 删网盘那一步**卡在闸门上**，好让测试看清「删除过程中」的界面。
///
/// 不卡住的话，假网盘是同步返回的，进度层会在同一帧里建出来又拆掉 ——
/// 测试只能断言「最后没有进度层」，那正好是**最不重要**的一半。
class _GatedDrive extends FakeDriveAdapter {
  _GatedDrive() : super(const {});

  final gate = Completer<void>();

  @override
  Future<List<String>> deleteFiles({required List<String> fileIds}) async {
    deleteBatches.add(List.of(fileIds));
    await gate.future;
    return fileIds;
  }
}

void main() {
  final now = DateTime(2026, 10, 21);

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

  /// 铺开媒体库页（桌面排版：这条测的是 PC 那条路）。
  Future<_GatedDrive> pumpPage(WidgetTester tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);
    await repo.upsertWorks([
      work('a', title: '片子甲', itemCount: 2),
      work('b', title: '片子乙'),
    ], now: now);
    await repo.upsertItems([
      item('a', 'fa1'),
      item('a', 'fa2'),
      item('b', 'fb1'),
    ], now: now);

    final drive = _GatedDrive();
    final supportDir = Directory.systemTemp.createTempSync('cloudcine_remove_flow');
    addTearDown(() => supportDir.deleteSync(recursive: true));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
        adapterRegistryProvider.overrideWithValue(AdapterRegistry([drive])),
        authControllerProvider.overrideWith(_FakeAuth.new),
        scanControllerProvider.overrideWith(_FakeScan.new),
        appSupportDirProvider.overrideWithValue(supportDir.path),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: LibraryPage())),
      ),
    );
    await tester.pumpAndSettle();
    return drive;
  }

  testWidgets('点选择 → 勾一部 → 移除 → 勾「一并删网盘」→ 进度层 → 结果提示',
      (tester) async {
    // 桌面排版：这条测的是 PC 端那条路（电视那条在 Android 侧用守卫测试钉）。
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final drive = await pumpPage(tester);

      // ① 进多选，勾上「片子甲」（它名下有 2 个文件）。
      // ⚠️ 按 tooltip 找而不是按文字：桌面排版下页头是**纯图标**
      //    （`TvIconLabel` 的 label 只在电视排版显示），按 '选择' 两个字
      //    一个都找不到 —— 而那种失败会让人以为是页面没渲染。
      await tester.tap(find.byTooltip('多选（批量合并 / 移除）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('片子甲').first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 部'), findsOneWidget);

      // ② 点「移除」—— 确认框要先把「会删几个」写出来。
      await tester.tap(find.text('移除').first);
      await tester.pumpAndSettle();
      expect(find.text('要从媒体库移除这 1 部吗？'), findsOneWidget);
      expect(
        find.text('同时删除网盘上的 2 个文件'),
        findsOneWidget,
        reason: '弹窗上那个数字必须来自 tally（与真正去删的集合同一口径）',
      );

      // ③ 勾上「一并删网盘」：标题与按钮都要换说法。
      await tester.tap(find.text('同时删除网盘上的 2 个文件'));
      await tester.pumpAndSettle();
      expect(find.text('要从媒体库和网盘删除这 1 部吗？'), findsOneWidget);
      expect(find.text('删除 1 部（含网盘文件）'), findsOneWidget);

      // ④ 确认 —— 删除被闸门卡住，此刻应该看得见进度层。
      await tester.tap(find.text('删除 1 部（含网盘文件）'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('正在删除网盘文件 0/2…'),
        findsOneWidget,
        reason: '几十秒的静默就是用户「再点一次移除」的原因 —— 勾了删网盘必须给进度',
      );

      // ⑤ 放行，进度层自己关掉，结果提示要如实说网盘那边动了几个。
      drive.gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('正在删除网盘文件 0/2…'), findsNothing);
      expect(
        find.textContaining('网盘上 2 个文件已删除'),
        findsOneWidget,
        reason: '勾了删网盘却提示「网盘文件未动」的话，用户会以为勾选没生效',
      );
      expect(drive.deletedIds, unorderedEquals(['fa1', 'fa2']),
          reason: '勾的是一部，删的必须是它名下的全部文件');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
