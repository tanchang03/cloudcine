import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/drive_browse_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 目录视图现在读的是**网盘实时目录**（不再是本地索引重建的目录树）。
///
/// 这些用例守两件事：
///   1. 浏览栈是**带目录 ID 的**，不是靠路径反推 —— 网盘允许同名目录，
///      靠路径反推会把两棵不同的子树并成一棵；
///   2. 一个目录里「哪些条目该出现在列表里」的判据与扫描/发现**同源**，
///      列表里不该出现加不进库的 `cover.jpg` / `.srt`。
void main() {
  Map<String, List<DriveEntry>> tree() => {
        'root': const [
          DriveEntry(id: 'd2', name: '第10季', isDirectory: true),
          DriveEntry(id: 'd1', name: '第2季', isDirectory: true),
          DriveEntry(
            id: 'f1',
            name: 'Movie.2024.1080p.mkv',
            isDirectory: false,
            sizeBytes: 1000,
          ),
          DriveEntry(
            id: 'f2',
            name: 'Show.S01E01.mkv',
            isDirectory: false,
            sizeBytes: 2000,
          ),
          DriveEntry(
            id: 's1',
            name: 'Movie.2024.1080p.chs.srt',
            isDirectory: false,
            sizeBytes: 40,
          ),
          DriveEntry(
            id: 'p1',
            name: 'cover.jpg',
            isDirectory: false,
            sizeBytes: 20,
          ),
        ],
        'd1': const [
          DriveEntry(
            id: 'f3',
            name: 'Inner.mkv',
            isDirectory: false,
            sizeBytes: 10,
          ),
        ],
        'd2': const [],
      };

  ProviderContainer containerWith(FakeDriveAdapter drive) {
    final container = ProviderContainer(
      overrides: [
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([drive]),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('浏览栈', () {
    test('初始只有根，且 ID 来自适配器', () {
      final container = containerWith(FakeDriveAdapter(tree()));
      final stack = container.read(driveBrowseProvider);

      expect(stack, hasLength(1));
      expect(stack.single.isRoot, isTrue);
      expect(
        stack.single.id,
        'root',
        reason: '列目录接口只认目录 ID，所以栈上每一格都必须记着它',
      );
      expect(stack.single.path, '/');
    });

    test('进子目录：压栈，路径按扫描器口径拼（带结尾斜杠的父路径）', () {
      final container = containerWith(FakeDriveAdapter(tree()));
      final notifier = container.read(driveBrowseProvider.notifier);
      final root = container.read(driveBrowseProvider).single;

      notifier.open(
        root.child(const DriveEntry(id: 'd1', name: '第2季', isDirectory: true)),
      );

      final stack = container.read(driveBrowseProvider);
      expect(stack, hasLength(2));
      expect(stack.last.id, 'd1');
      expect(stack.last.path, '/第2季');
      expect(stack.last.name, '第2季');
      expect(container.read(currentCrumbProvider).id, 'd1');
    });

    test('点面包屑上已有的一格 = 回退，而不是再压一层', () {
      final container = containerWith(FakeDriveAdapter(tree()));
      final notifier = container.read(driveBrowseProvider.notifier);
      final root = container.read(driveBrowseProvider).single;
      final child = root.child(
        const DriveEntry(id: 'd1', name: '第2季', isDirectory: true),
      );

      notifier.open(child);
      notifier.open(child.child(
        const DriveEntry(id: 'd9', name: '深层', isDirectory: true),
      ));
      expect(container.read(driveBrowseProvider), hasLength(3));

      notifier.open(root);

      final stack = container.read(driveBrowseProvider);
      expect(stack, hasLength(1));
      expect(stack.single.isRoot, isTrue);
    });

    test('在根目录时「上一级」不动（否则会白白重建界面）', () {
      final container = containerWith(FakeDriveAdapter(tree()));
      final before = container.read(driveBrowseProvider);

      container.read(driveBrowseProvider.notifier).up();

      expect(container.read(driveBrowseProvider), same(before));
    });

    test('reset 回到根', () {
      final container = containerWith(FakeDriveAdapter(tree()));
      final notifier = container.read(driveBrowseProvider.notifier);
      final root = container.read(driveBrowseProvider).single;

      notifier.open(root.child(
        const DriveEntry(id: 'd1', name: '第2季', isDirectory: true),
      ));
      notifier.reset();

      expect(container.read(driveBrowseProvider), hasLength(1));
    });

    test('DriveCrumb 是值对象：同 id/name/path 就相等', () {
      const a = DriveCrumb(id: 'd1', name: '第2季', path: '/第2季');
      const b = DriveCrumb(id: 'd1', name: '第2季', path: '/第2季');
      const c = DriveCrumb(id: 'd9', name: '第2季', path: '/第2季');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse, reason: 'ID 不同就是两个不同的目录（网盘允许同名）');
    });
  });

  group('目录内容', () {
    test('文件夹与视频分开，非视频只计数不列出', () async {
      final container = containerWith(FakeDriveAdapter(tree()));
      final crumb = container.read(currentCrumbProvider);
      container.listen(driveListingProvider(crumb), (_, __) {});

      final listing = await container.read(driveListingProvider(crumb).future);

      expect(listing.folders.map((e) => e.name), ['第2季', '第10季'],
          reason: '自然序：`第2季` 要在 `第10季` 前面');
      expect(listing.videos.map((e) => e.name),
          ['Movie.2024.1080p.mkv', 'Show.S01E01.mkv']);
      expect(
        listing.otherFileCount,
        2,
        reason: '字幕与封面图既不列出来（点了也加不进库），也不能凭空消失 —— '
            '要有一个数字交代它们的存在',
      );
      expect(listing.truncated, isFalse);
    });

    test('多页会一直翻到最后一页', () async {
      final container = containerWith(
        FakeDriveAdapter(tree(), pageSizeOverride: 2),
      );
      final crumb = container.read(currentCrumbProvider);
      container.listen(driveListingProvider(crumb), (_, __) {});

      final listing = await container.read(driveListingProvider(crumb).future);

      expect(listing.folders, hasLength(2));
      expect(listing.videos, hasLength(2));
      expect(listing.otherFileCount, 2);
    });

    test('空目录：两个列表都空，但不是错误', () async {
      final container = containerWith(FakeDriveAdapter(tree()));
      final root = container.read(driveBrowseProvider).single;
      final empty = root.child(
        const DriveEntry(id: 'd2', name: '第10季', isDirectory: true),
      );
      container.listen(driveListingProvider(empty), (_, __) {});

      final listing = await container.read(driveListingProvider(empty).future);

      expect(listing.isEmpty, isTrue);
      expect(listing.folders, isEmpty);
      expect(listing.videos, isEmpty);
    });

    test('写库信号不会让目录重新列一遍网盘', () async {
      final drive = FakeDriveAdapter(tree());
      final container = containerWith(drive);
      final crumb = container.read(currentCrumbProvider);
      container.listen(driveListingProvider(crumb), (_, __) {});
      await container.read(driveListingProvider(crumb).future);

      final before = drive.listedDirs.length;
      expect(before, greaterThan(0), reason: '先确认它真的列过一次');

      // 发现 / 扫描写完库会推这个信号。「已入库」标记来自另外两个 provider
      // （`indexedFileIdsProvider` ← `folderTreeProvider`），它们各自 watch
      // 这个信号 —— 目录列表**不需要**为它重新请求一次网盘。
      //
      // 做错的表现不是报错，而是：每次「发现本目录」之后，界面都会把整个
      // 目录重新列一遍。3000 项的目录 = 30 次请求，白打在夸克那条约 3 QPS
      // 的安全线上，而用户看到的画面一模一样。
      container.read(libraryWriteSignalProvider.notifier).bump();
      await container.read(driveListingProvider(crumb).future);

      expect(drive.listedDirs.length, before);
    });
  });
}
