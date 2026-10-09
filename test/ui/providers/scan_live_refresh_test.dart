import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:cloudcine/ui/providers/settings_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 扫描进行中**实时刷新媒体库列表**。
///
/// ## 为什么值得一个文件
///
/// 扫描器从 2026-09-30 起就「边扫边出」（每到一个目录边界就把新分组写成
/// 作品行），但媒体库列表原先只在**整次扫描结束**时才重取。大库要扫几十分钟，
/// 这期间媒体库页面一直显示扫描前的样子 —— 用户会以为卡死了，然后整批结果
/// 一次性冒出来。用户明确要的是「一个一个出现的动态感」。
///
/// 现在扫描控制器在进度回调里推 [libraryListSignalProvider]，列表跟着一批批
/// 长出来。这个文件钉住两件事：
///
///   1. 扫描**过程中**就推过信号（不是只在结束时）；
///   2. 推信号**不等于**把目录视图那棵要读全表的树也拖下水
///      （信号分开正是为了这个，见 `LibraryListSignal` 的文档）。
void main() {
  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() async {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
    // 测试里不要对网盘限速（默认 350ms 会让每个目录多等 350ms）。
    await SettingsStore(db).write(SettingKeys.scanIntervalMs, '0');
  });

  tearDown(() async {
    await db.close();
  });

  /// 根目录两个子目录，各一个视频。
  Map<String, List<DriveEntry>> tree() => {
        'root': const [
          DriveEntry(id: 'd1', name: '剧甲', isDirectory: true),
          DriveEntry(id: 'd2', name: '电影乙', isDirectory: true),
        ],
        'd1': const [
          DriveEntry(
            id: 'f1',
            name: '剧甲.S01E01.1080p.mkv',
            isDirectory: false,
            sizeBytes: 1000,
          ),
        ],
        'd2': const [
          DriveEntry(
            id: 'f2',
            name: '电影乙.2024.1080p.mp4',
            isDirectory: false,
            sizeBytes: 2000,
          ),
        ],
      };

  test('扫描过程中就推列表信号，媒体库列表跟着长出来', () async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([FakeDriveAdapter(tree())]),
        ),
      ],
    );
    addTearDown(container.dispose);

    // 设置先读出来，免得 start() 拿到一个还在 loading 的快照。
    await container.read(settingsProvider.future);

    var bumps = 0;
    container.listen(libraryListSignalProvider, (_, __) => bumps++);

    await container.read(scanControllerProvider.notifier).start(
          provider: DriveProvider.quark,
        );

    expect(
      bumps,
      greaterThan(0),
      reason: '扫描**过程中**必须推过列表信号。只在结束时推的话，用户盯着'
          '屏幕几十分钟什么都看不到，然后整批结果一次冒出来 ——'
          '而「卡片一批批长出来」正是要修的体验。',
    );

    // 顺带确认扫描确实把作品建了出来（否则上面那条可能只是「推了个空信号」）。
    expect(await repo.allWorks(), isNotEmpty);
  });
}
