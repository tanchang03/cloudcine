import 'dart:io';

import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/services/folder_sort.dart';
import 'package:cloudcine/ui/pages/settings_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/settings_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置页里的「文件夹视图」一节。
///
/// ## 为什么要测设置页这一半
///
/// 目录视图工具条上那个排序按钮已经在
/// `test/ui/widgets/folder_browser_test.dart` 里测过了，两者读写**同一份设置**
/// （`SettingKeys.folderSortMode`）。这里守的是另一半：**设置页这一侧真的
/// 接上了这个键** —— 下拉框的 `value` 与 `items` 对不上时 `DropdownButton`
/// 会直接断言失败（整页白屏），而 `onChanged` 写错字段只会静默不生效。
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

void main() {
  Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.memory();
    addTearDown(db.close);

    // 设置页在 `_storageSection` 里会读海报缓存目录并异步算占用，
    // 给一个真的空目录，别让它去碰用户的家目录。
    final cacheDir = Directory.systemTemp.createTempSync('cloudcine_settings');
    addTearDown(() => cacheDir.deleteSync(recursive: true));

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(DriftMediaRepository(db)),
        authControllerProvider.overrideWith(_FakeAuth.new),
        posterCacheDirProvider.overrideWithValue(cacheDir.path),
        // 海报缓存与凭证都要落在应用支持目录下，`main()` 里注入的那个在
        // 测试里不存在 —— 不补这一项，设置页一渲染就抛 `UnimplementedError`。
        appSupportDirProvider.overrideWithValue(cacheDir.path),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('「文件夹视图」一节在，默认是修改时间', (tester) async {
    await pumpSettings(tester);

    expect(find.text('文件夹视图'), findsOneWidget);
    expect(find.text('排序方式'), findsOneWidget);
    // 下拉框当前值 = 默认值。`DropdownButton` 的 value 若不在 items 里会
    // 直接断言失败，所以「页面能画出来」本身就已经排掉了那类错误。
    expect(
      find.text('修改时间'),
      findsOneWidget,
      reason: '默认必须是「修改时间」——与目录视图里那个工具条的默认值同一个',
    );
  });

  testWidgets('在这里改成「名称」会写进设置（与目录视图共用同一份）', (tester) async {
    final container = await pumpSettings(tester);

    await tester.tap(find.text('修改时间'));
    await tester.pumpAndSettle();
    // 展开后「名称」是菜单里的那一项（未展开时页面上只有「修改时间」）。
    await tester.tap(find.text('名称').last);
    await tester.pumpAndSettle();

    expect(
      container.read(settingsProvider).valueOrNull!.folderSortMode,
      FolderSortMode.fileName,
    );
    expect(
      await container
          .read(settingsStoreProvider)
          .read(SettingKeys.folderSortMode),
      FolderSortMode.fileName.value,
      reason: '要真的落库：目录视图工具条读的就是这个键，只改内存状态的话'
          '切回目录视图看到的还是老顺序',
    );
    expect(find.text('按名称**自然序**（`第2期` 排在 `第10期` 前面）。'),
        findsOneWidget);
  });
}
