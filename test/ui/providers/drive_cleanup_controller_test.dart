import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/drive_cleanup.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/drive_browse_providers.dart';
import 'package:cloudcine/ui/providers/drive_cleanup_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 批量删除控制器 —— 网盘删完之后**还要发生什么**。
///
/// ## 为什么值得单独测这一层
///
/// 它比「调一次 `deleteFiles`」多做的三件事，每一件做错的后果都是**静默
/// 的数据损坏**：
///
///   1. **分块**：丢一批 = 用户勾了却没删掉，而界面报「已删除 N 项」；
///   2. **失败批次的处置**：凭证失效时继续打剩下几十批，只会把夸克那条本就
///      很紧的限流线顶穿；而把「没发出去」的那些算成成功，是在撒谎；
///   3. **本地索引清理**：漏了它，海报墙上留着一批点开就报错的死卡片；
///      而**清多了**（把失败批次对应的也清了）更糟 —— 文件还在网盘上，
///      媒体库里却没了，要回来得重扫一次。
///
/// 这里用内存仓储（不是 drift）：被测的是「控制器决定动哪些行」，
/// 不是 SQL 语义 —— 那部分由 `test/data/` 下的真库测试守着。
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

void main() {
  const root = DriveCrumb(id: 'root', name: '/', path: '/');

  DriveEntry file(String id, {int? size}) => DriveEntry(
        id: id,
        name: '$id.mkv',
        isDirectory: false,
        sizeBytes: size,
      );

  DriveEntry dir(String id) =>
      DriveEntry(id: id, name: id, isDirectory: true);

  MediaItem item(String fileId, String dirPath) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd-$fileId',
        dirPath: dirPath,
        groupKey: 'work-$fileId',
        kind: MediaKind.movie,
        firstSeenAt: DateTime(2026, 10, 3),
        updatedAt: DateTime(2026, 10, 3),
      );

  /// 装配一套「一个假网盘 + 一个内存库 + 已登录」的容器。
  ({ProviderContainer c, FakeDriveAdapter adapter, InMemoryMediaRepository repo})
      setup({
    List<DriveEntry> tree = const [],
    DriveException? deleteFailsWith,
    Set<int>? deleteFailsOnBatch,
  }) {
    final adapter = FakeDriveAdapter(
      {'root': [...tree]},
      deleteFailsWith: deleteFailsWith,
      deleteFailsOnBatch: deleteFailsOnBatch,
    );
    final repo = InMemoryMediaRepository();
    final c = ProviderContainer(
      overrides: [
        adapterRegistryProvider.overrideWithValue(AdapterRegistry([adapter])),
        mediaRepositoryProvider.overrideWithValue(repo),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
    addTearDown(c.dispose);
    return (c: c, adapter: adapter, repo: repo);
  }

  Future<DriveCleanupOutcome?> run(
    ProviderContainer c, {
    required List<DriveEntry> entries,
  }) =>
      c
          .read(driveCleanupControllerProvider.notifier)
          .delete(crumb: root, plan: DriveDeletePlan(entries: entries));

  test('删掉的条目真的从这一层的列表里不见了', () async {
    final s = setup(tree: [file('a'), file('b')]);

    final before = await s.c.read(driveListingProvider(root).future);
    expect(before.videos.map((e) => e.id), containsAll(['a', 'b']));

    final outcome = await run(s.c, entries: [file('a')]);

    expect(s.adapter.deletedIds, ['a']);
    expect(outcome!.deleted, 1);
    expect(outcome.failed, 0);

    final after = await s.c.read(driveListingProvider(root).future);
    expect(after.videos.map((e) => e.id), ['b'],
        reason: '删完不重列的话，用户看到的还是删之前那一层 —— 他会以为'
            '删除没生效，然后再点一次。');
  });

  test('超过一批上限时切成多批，一条不丢', () async {
    final n = DriveDeletePlan.maxIdsPerRequest;
    final entries = [for (var i = 0; i < n + 5; i++) file('f$i')];
    final s = setup(tree: entries);

    final outcome = await run(s.c, entries: entries);

    expect(s.adapter.deleteBatches.length, 2);
    expect(s.adapter.deleteBatches.first.length, n);
    expect(s.adapter.deleteBatches.last.length, 5);
    expect(s.adapter.deletedIds.length, entries.length,
        reason: '丢一条 = 用户勾了它却没删掉，而界面报「已删除 105 项」。');
    expect(outcome!.deleted, entries.length);
    expect(outcome.failed, 0);
  });

  test('凭证失效：中止后续批次，且把**没发出去的**也算成失败', () async {
    final entries = [for (var i = 0; i < 150; i++) file('f$i')];
    final s = setup(
      tree: entries,
      deleteFailsWith: const DriveException(
        type: DriveErrorType.unauthorized,
        message: 'login expired',
      ),
    );

    final outcome = await run(s.c, entries: entries);

    expect(s.adapter.deleteBatches.length, 1,
        reason: '凭证失效不是「按批次的」错误 —— 后面每一批都会以同样的方式'
            '失败。继续打下去只会多出几十个注定失败的请求，把夸克那条'
            '本来就紧的限流线再顶一下。');
    expect(outcome!.deleted, 0);
    expect(outcome.failed, 150,
        reason: '没发出去的那 50 个确实没删掉。报成「成功」是撒谎 —— '
            '用户会以为清干净了，而它们还在网盘上占着空间。');
    expect(outcome.fatalError, isNotNull,
        reason: '必须说出来「剩下的没删」，否则用户以为网盘拒绝了删除，'
            '而不是「这次没试」。');
  });

  test('某一批被限流：**继续**后面的批次（那不是致命错误）', () async {
    final n = DriveDeletePlan.maxIdsPerRequest;
    final entries = [for (var i = 0; i < n + 3; i++) file('f$i')];
    final s = setup(tree: entries, deleteFailsOnBatch: {1});

    final outcome = await run(s.c, entries: entries);

    expect(s.adapter.deleteBatches.length, 2,
        reason: '限流是**可以继续试**的：第 1 批失败不代表第 2 批也会失败。'
            '这里中止的话，用户会白白少删一批。');
    expect(outcome!.deleted, 3);
    expect(outcome.failed, n);
    expect(outcome.fatalError, isNull);
  });

  test('成功删掉的视频会从媒体库索引里一起消失', () async {
    final s = setup(tree: [file('a'), file('b')]);
    await s.repo.upsertItems([item('a', '/'), item('b', '/')]);

    final outcome = await run(s.c, entries: [file('a')]);

    expect(await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'a')),
        isNull,
        reason: '不清理的话，海报墙上那张卡片还挂着，点下去只会报'
            '「文件打不开了」—— 而用户删的是网盘上的文件，'
            '完全没预期媒体库里还留着一条死索引。');
    expect(await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'b')),
        isNotNull,
        reason: '没勾的那一条一个字段都不该动。');
    expect(outcome!.libraryRemoved, 1);
  });

  test('删掉一个目录会连它子树里的索引一起清掉', () async {
    final s = setup(tree: [dir('剧集')]);
    await s.repo.upsertItems([
      item('e1', '/剧集/第一季/'),
      item('e2', '/剧集/第二季/'),
      item('other', '/电影/'),
    ]);

    final outcome = await run(s.c, entries: [dir('剧集')]);

    expect(outcome!.libraryRemoved, 2);
    expect(await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'e1')),
        isNull);
    expect(await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'e2')),
        isNull);
    expect(
      await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'other')),
      isNotNull,
      reason: '按路径前缀清理，前缀算错就会把兄弟目录的索引一起清掉 —— '
          '那是「删了一个目录，另一个目录的片子从库里消失了」。',
    );
  });

  test('删除失败的条目**不**清索引（文件还在网盘上）', () async {
    final s = setup(
      tree: [file('a')],
      deleteFailsWith: const DriveException(
        type: DriveErrorType.unauthorized,
        message: 'login expired',
      ),
    );
    await s.repo.upsertItems([item('a', '/')]);

    final outcome = await run(s.c, entries: [file('a')]);

    expect(outcome!.deleted, 0);
    expect(
      await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'a')),
      isNotNull,
      reason: '网盘上那个文件还在，库里却把它删了 —— 用户会看到「我明明没删'
          '这部片子，它从媒体库里消失了」，而要回来得重扫一次。',
    );
  });

  test('空计划什么都不做（返回 null，不发请求）', () async {
    final s = setup(tree: [file('a')]);

    expect(await run(s.c, entries: const []), isNull);
    expect(s.adapter.deleteBatches, isEmpty);
  });

  test('非视频文件在库里没有行，清索引时不会报错', () async {
    final s = setup(tree: [file('sub')]);
    // 库里一条都没有 —— 字幕 / 图片 / 压缩包就是这种情况。
    final outcome = await run(s.c, entries: [file('sub')]);

    expect(outcome!.deleted, 1);
    expect(outcome.libraryRemoved, 0);
  });
}
