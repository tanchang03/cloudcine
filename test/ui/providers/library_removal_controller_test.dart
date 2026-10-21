import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/library_batch_delete.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/library_removal_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 批量移除的执行者 —— 勾了「一并删网盘」之后**到底动了什么**。
///
/// ## 为什么值得单独测
///
/// 这条路径把两件不可逆程度完全不同的事串在一起（删网盘文件 / 删本地索引），
/// 每一种做错的方式都**不会报错**：
///
///   1. **顺序反了**：先删索引就拿不到 fid 了（fid 只存在 `media_items`
///      里）—— 用户勾了「一并删」，网盘上却一个都没少；
///   2. **失败被吞掉**：提示说「已删除」，网盘上还占着几十 GB；
///   3. **只读网盘被算成失败**：百度那条只读接入的文件根本删不了，
///      算进失败数会让「3 个成功 2 个失败」这句话自相矛盾（弹窗已经说过
///      那 2 个只会从媒体库移除）；
///   4. **不分块**：一百多个 fid 一次发出去，超时之后用户什么都拿不到。
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

/// 百度那一路：只读接入，`canWrite == false`。
class _ReadOnlyDrive extends FakeDriveAdapter {
  _ReadOnlyDrive() : super(const {});

  @override
  DriveProvider get provider => DriveProvider.baidu;

  @override
  Capabilities get capabilities =>
      const Capabilities(provider: DriveProvider.baidu, canWrite: false);
}

void main() {
  final now = DateTime(2026, 10, 21);

  MediaItem item(String fileId, String groupKey,
          {DriveProvider provider = DriveProvider.quark}) =>
      MediaItem(
        provider: provider,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd',
        dirPath: '/剧/',
        groupKey: groupKey,
        kind: MediaKind.episode,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaWork work(String key, {String? mergedInto}) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: key,
        mergedInto: mergedInto,
        updatedAt: now,
      );

  /// 一个假夸克 + 内存库 + 已登录。
  ///
  /// `work-a` 名下 3 个文件，`work-keep` 1 个（没人勾）。
  Future<({ProviderContainer c, FakeDriveAdapter adapter, InMemoryMediaRepository repo})>
      setup({
    List<MediaItem> extra = const [],
    List<MediaWork> extraWorks = const [],
    DriveException? deleteFailsWith,
    FakeDriveAdapter? second,
  }) async {
    final adapter = FakeDriveAdapter(const {}, deleteFailsWith: deleteFailsWith);
    final repo = InMemoryMediaRepository();
    await repo.upsertItems([
      item('a1', 'work-a'),
      item('a2', 'work-a'),
      item('a3', 'work-a'),
      item('k1', 'work-keep'),
      ...extra,
    ]);
    await repo.upsertWorks([work('work-a'), work('work-keep'), ...extraWorks]);
    final c = ProviderContainer(
      overrides: [
        adapterRegistryProvider.overrideWithValue(
          AdapterRegistry([adapter, if (second != null) second]),
        ),
        mediaRepositoryProvider.overrideWithValue(repo),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
    addTearDown(c.dispose);
    return (c: c, adapter: adapter, repo: repo);
  }

  test('勾了一并删：网盘 fid 全删，库里的行也一起没', () async {
    final s = await setup();

    final out = await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-a'},
      alsoDeleteFromDrive: true,
    );

    expect(s.adapter.deletedIds, unorderedEquals(['a1', 'a2', 'a3']));
    expect(out.drive?.deleted, 3);
    expect(out.drive?.failed, 0);
    expect(out.removedItems, 3, reason: '提示里的文件行数要如实');
    expect(await s.repo.workByKey('work-a'), isNull);
  });

  test('不勾：一个 fid 都不发，账目是 null（不是「删了 0 个」）', () async {
    final s = await setup();

    final out = await s.c
        .read(libraryRemovalControllerProvider)
        .remove(keys: {'work-a'});

    expect(s.adapter.deleteBatches, isEmpty);
    expect(out.drive, isNull, reason: 'null = 没打算删网盘；0/0 = 想删但没匹配到');
    expect(out.removedItems, 3);
    expect(await s.repo.workByKey('work-a'), isNull);
  });

  test('折叠进来的别名行名下的文件也要删（并集口径）', () async {
    final s = await setup(
      extra: [item('s1', 'work-s')],
      extraWorks: [work('work-s', mergedInto: 'work-a')],
    );

    final out = await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-a'},
      alsoDeleteFromDrive: true,
    );

    expect(s.adapter.deletedIds, unorderedEquals(['a1', 'a2', 'a3', 's1']),
        reason: '别名行的文件属于这一部 —— 漏了它，网盘上会剩一集孤儿');
    expect(out.drive?.deleted, 4);
  });

  test('网盘删失败：失败数如实、索引照样移除（用户要的是移除）', () async {
    final s = await setup(
      deleteFailsWith: const DriveException(
        type: DriveErrorType.unauthorized,
        message: '登录已失效',
      ),
    );

    final out = await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-a'},
      alsoDeleteFromDrive: true,
    );

    expect(out.drive?.deleted, 0);
    expect(out.drive?.failed, 3, reason: '没删掉就要说没删掉，报成功是撒谎');
    expect(out.drive?.fatalError, isNotNull);
    expect(await s.repo.workByKey('work-a'), isNull,
        reason: '主操作是「从媒体库移除」，不能因为附加动作失败而变成空操作');
  });

  test('只读网盘的文件被跳过，且不算进失败数', () async {
    final s = await setup(
      extra: [item('b1', 'work-a', provider: DriveProvider.baidu)],
      second: _ReadOnlyDrive(),
    );

    final tally = await s.c.read(libraryRemovalControllerProvider).tally({'work-a'});
    expect(tally.deletable, 3);
    expect(tally.undeletable, 1, reason: '弹窗要靠它说「这 1 个只会从媒体库移除」');

    final out = await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-a'},
      alsoDeleteFromDrive: true,
    );

    expect(s.adapter.deletedIds, unorderedEquals(['a1', 'a2', 'a3']));
    expect(out.drive?.deleted, 3);
    expect(out.drive?.failed, 0,
        reason: '只读网盘的文件不该算失败 —— 弹窗已经单独说过它们删不了');
  });

  test('超过 100 个文件要分批发', () async {
    final many = [
      for (var i = 0; i < 120; i++) item('m$i', 'work-many'),
    ];
    final s = await setup(extra: many, extraWorks: [work('work-many')]);

    final out = await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-many'},
      alsoDeleteFromDrive: true,
    );

    expect(s.adapter.deleteBatches.length, 2,
        reason: '一次带 120 个 fid 超时的话，用户什么信息都拿不到');
    expect(s.adapter.deleteBatches.first.length, 100);
    expect(s.adapter.deleteBatches.last.length, 20);
    expect(out.drive?.deleted, 120);
  });
  test('进度：分母在发第一批之前就定下来，最后一报是「正在清理媒体库」', () async {
    final many = [
      for (var i = 0; i < 120; i++) item('m$i', 'work-many'),
    ];
    final s = await setup(extra: many, extraWorks: [work('work-many')]);

    final seen = <RemovalProgress>[];
    await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-many'},
      alsoDeleteFromDrive: true,
      onProgress: seen.add,
    );

    expect(seen, isNotEmpty);
    expect(seen.first.phase, RemovalPhase.drive);
    expect(seen.first.done, 0);
    expect(seen.first.total, 120,
        reason: '总数要一开始就报出来 —— 删到一半才知道总数，进度条会从「不确定」跳一下');
    expect(
      [for (final p in seen) p.done],
      containsAll(<int>[0, 100, 120]),
      reason: '每批走完都要报一次，而不是等全部结束才报',
    );
    expect(seen.last.phase, RemovalPhase.library,
        reason: '索引还没清完就不能让进度条满格消失 —— 那看起来像已经结束了');
    expect(seen.last.fraction, isNull,
        reason: '清理索引这一步没有分母，进度条该走不确定态');
  });

  test('进度：只清索引时一个都不报（没有可显示的阶段）', () async {
    final s = await setup();

    final seen = <RemovalProgress>[];
    await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-a'},
      onProgress: seen.add,
    );

    expect(seen, isEmpty, reason: '本地的几十毫秒不该弹一层模态');
  });

  test('进度：撞上凭证失效也走到头，不卡在失败的那一批上', () async {
    final many = [
      for (var i = 0; i < 120; i++) item('m$i', 'work-many'),
    ];
    final s = await setup(
      extra: many,
      extraWorks: [work('work-many')],
      deleteFailsWith: const DriveException(
        type: DriveErrorType.unauthorized,
        message: '登录已失效',
      ),
    );

    final seen = <RemovalProgress>[];
    await s.c.read(libraryRemovalControllerProvider).remove(
      keys: {'work-many'},
      alsoDeleteFromDrive: true,
      onProgress: seen.add,
    );

    final drive = seen.where((p) => p.phase == RemovalPhase.drive);
    expect(drive.last.done, 120,
        reason: '停在 100/120 上关窗，看起来像被掐断了，而不是「有一批没成功」');
    expect(drive.last.fraction, 1.0);
  });
}
