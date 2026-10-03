import 'package:cloudcine/core/error/drive_error.dart';
import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/services/drive_batch.dart';
import 'package:cloudcine/domain/services/drive_move.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/drive_browse_providers.dart';
import 'package:cloudcine/ui/providers/drive_move_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 批量移动控制器 —— 网盘移动之后**还要发生什么**。
///
/// ## 为什么值得单独测这一层
///
/// 它比「调一次 `moveFiles`」多做的几件事，每一件做错的后果都是**静默的
/// 数据损坏或撒谎**：
///
///   1. **非法目标**：把 `/电影` 移进 `/电影/科幻` 会造出自引用目录，
///      没有撤销入口 —— 所以这道检查必须跟着动作本身，不能只在界面置灰；
///   2. **分块**：丢一批 = 用户勾了却没移走，而界面报「已移动 N 项」；
///   3. **失败批次的处置**：凭证失效时继续打剩下几十批只会顶穿限流线；
///      而把「没发出去」的算成成功，是在撒谎；
///   4. **记住目标目录**：这是这个功能存在的理由（反复移动时不用重新
///      点五层目录），而它错的方式是「偶尔没记住」—— 只在冷启动后第一次
///      出现，最难查；
///   5. **本地索引不能动**：移动不改 fid，那些行不是死索引。为了「保持
///      一致」把它们删掉，用户会丢掉续播点与播放偏好。
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

  DriveEntry file(String id) =>
      DriveEntry(id: id, name: '$id.mkv', isDirectory: false);

  DriveEntry dir(String id) => DriveEntry(id: id, name: id, isDirectory: true);

  MoveTarget target(String fid, String path) => MoveTarget(
        fid: fid,
        name: path == '/' ? '/' : path.split('/').last,
        path: path,
      );

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

  late AppDatabase settingsDb;
  late SettingsStore store;

  setUp(() {
    // 真设置库（内存）：最近目录那一块要验「真的落库了」，用假 store
    // 就验不到 JSON 编解码与去重那条路径。
    settingsDb = AppDatabase.memory();
    store = SettingsStore(settingsDb);
  });

  tearDown(() async {
    await settingsDb.close();
  });

  /// 装配一套「一个假网盘 + 一个内存库 + 已登录 + 真设置库」的容器。
  ({ProviderContainer c, FakeDriveAdapter adapter, InMemoryMediaRepository repo})
      setup({
    required Map<String, List<DriveEntry>> tree,
    DriveException? moveFailsWith,
    Set<int>? moveFailsOnBatch,
  }) {
    final adapter = FakeDriveAdapter(
      tree,
      moveFailsWith: moveFailsWith,
      moveFailsOnBatch: moveFailsOnBatch,
    );
    final repo = InMemoryMediaRepository();
    final c = ProviderContainer(
      overrides: [
        adapterRegistryProvider.overrideWithValue(AdapterRegistry([adapter])),
        mediaRepositoryProvider.overrideWithValue(repo),
        settingsStoreProvider.overrideWithValue(store),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
    addTearDown(c.dispose);
    return (c: c, adapter: adapter, repo: repo);
  }

  Future<DriveMoveOutcome?> run(
    ProviderContainer c, {
    required List<DriveEntry> entries,
    required MoveTarget target,
  }) =>
      c.read(driveMoveControllerProvider.notifier).move(
            sourceCrumb: root,
            plan: DriveMovePlan(
              entries: entries,
              sourceDirPath: root.path,
              target: target,
            ),
          );

  test('移走的条目真的从源目录不见了', () async {
    final s = setup(tree: {
      'root': [file('a'), file('b')],
      'dest': [],
    });

    final before = await s.c.read(driveListingProvider(root).future);
    expect(before.videos.map((e) => e.id), containsAll(['a', 'b']));

    final outcome =
        await run(s.c, entries: [file('a')], target: target('dest', '/目标'));

    expect(s.adapter.movedIds, ['a']);
    expect(s.adapter.moveTargets, ['dest']);
    expect(outcome!.moved, 1);
    expect(outcome.failed, 0);

    final after = await s.c.read(driveListingProvider(root).future);
    expect(after.videos.map((e) => e.id), ['b'],
        reason: '移完不重列源目录的话，用户看到的还是移之前那一层 —— 他会以为'
            '移动没生效，然后再点一次（于是目标目录里来了两份）。');
  });

  test('超过一批上限时切成多批，一条不丢', () async {
    final n = driveMaxFidsPerRequest;
    final entries = [for (var i = 0; i < n + 5; i++) file('f$i')];
    final s = setup(tree: {'root': entries, 'dest': []});

    final outcome =
        await run(s.c, entries: entries, target: target('dest', '/目标'));

    expect(s.adapter.moveBatches.length, 2);
    expect(s.adapter.moveBatches.first.length, n);
    expect(s.adapter.moveBatches.last.length, 5);
    expect(s.adapter.movedIds.length, entries.length,
        reason: '丢一条 = 用户勾了它却没移走，而界面报「已移动 105 项」。');
    expect(outcome!.moved, entries.length);
    expect(outcome.failed, 0);
  });

  test('凭证失效：中止后续批次，且把**没发出去的**也算成失败', () async {
    final entries = [for (var i = 0; i < 150; i++) file('f$i')];
    final s = setup(
      tree: {'root': entries, 'dest': []},
      moveFailsWith: const DriveException(
        type: DriveErrorType.unauthorized,
        message: 'login expired',
      ),
    );

    final outcome =
        await run(s.c, entries: entries, target: target('dest', '/目标'));

    expect(s.adapter.moveBatches.length, 1,
        reason: '凭证失效不是「按批次的」错误 —— 后面每一批都会以同样的方式'
            '失败。继续打下去只会多出几十个注定失败的请求。');
    expect(outcome!.moved, 0);
    expect(outcome.failed, 150,
        reason: '没发出去的那 50 个确实没移走。报成「成功」是撒谎 —— '
            '用户会去目标目录里找一批根本不存在的文件。');
    expect(outcome.fatalError, isNotNull,
        reason: '必须说出来「剩下的没动」，否则用户以为网盘拒绝了移动，'
            '而不是「这次没试」。');
  });

  test('某一批被限流：**继续**后面的批次（那不是致命错误）', () async {
    final n = driveMaxFidsPerRequest;
    final entries = [for (var i = 0; i < n + 3; i++) file('f$i')];
    final s = setup(tree: {'root': entries, 'dest': []}, moveFailsOnBatch: {1});

    final outcome =
        await run(s.c, entries: entries, target: target('dest', '/目标'));

    expect(s.adapter.moveBatches.length, 2,
        reason: '限流是**可以继续试**的：第 1 批失败不代表第 2 批也会失败。'
            '这里中止的话，用户会白白少移一批。');
    expect(outcome!.moved, 3);
    expect(outcome.failed, n);
    expect(outcome.fatalError, isNull);
  });

  test('目标在某个被移动目录的子目录里：**拦下，一个请求都不发**', () async {
    final s = setup(tree: {
      'root': [dir('电影')],
      '电影': [],
    });

    final outcome = await run(
      s.c,
      entries: [dir('电影')],
      target: MoveTarget(fid: 'sub', name: '科幻', path: '/电影/科幻'),
    );

    expect(outcome, isNull);
    expect(s.adapter.moveBatches, isEmpty,
        reason: '把 /电影 移进 /电影/科幻 会造出一个**自引用目录** —— '
            '目录视图里点进去可以无限深，而且没有任何撤销入口。这是这个'
            '功能里唯一能造成结构性损坏的操作，所以判据必须跟着动作本身，'
            '不能只在界面上把按钮置灰。');
  });

  test('目标就是这些条目现在所在的目录：拦下（那是一次空操作）', () async {
    final s = setup(tree: {
      'root': [file('a')],
    });

    final outcome = await run(
      s.c,
      entries: [file('a')],
      target: MoveTarget(fid: 'root', name: '/', path: '/'),
    );

    expect(outcome, isNull);
    expect(s.adapter.moveBatches, isEmpty,
        reason: '空操作会照样报「已移动 1 项」：用户以为动了、其实没动，'
            '然后去目标目录里找那批「刚被移过去」的文件。报一个成功的'
            '空操作比报错更坏 —— 错至少能被发现。');
  });

  test('空计划什么都不做（返回 null，不发请求）', () async {
    final s = setup(tree: {'root': []});

    expect(
      await run(s.c, entries: const [], target: target('dest', '/目标')),
      isNull,
    );
    expect(s.adapter.moveBatches, isEmpty);
  });

  test('确认之后目标目录被记住，而且真的落了库', () async {
    final s = setup(tree: {
      'root': [file('a')],
      'dest': [],
    });
    expect(await s.c.read(moveTargetsProvider.future), isEmpty);

    await run(s.c, entries: [file('a')], target: target('dest', '/目标'));

    final recents = await s.c.read(moveTargetsProvider.future);
    expect(recents.map((t) => t.fid), ['dest']);
    expect(
      await store.read(SettingKeys.moveTargetRecents),
      isNotNull,
      reason: '要真的落库（不是只改了内存状态）：重启之后还得记得 —— '
          '这个功能的意义就是「下次不用重新点五层目录」。',
    );
  });

  test('移动失败也记住目标（用户马上要重试同一个目录）', () async {
    final s = setup(
      tree: {'root': [file('a')], 'dest': []},
      moveFailsWith: const DriveException(
        type: DriveErrorType.network,
        message: 'down',
      ),
    );

    await run(s.c, entries: [file('a')], target: target('dest', '/目标'));

    expect(
      (await s.c.read(moveTargetsProvider.future)).map((t) => t.fid),
      ['dest'],
      reason: '记在**确认那一刻**而不是成功之后：失败（限流 / 断网）之后'
          '用户马上要重试，而重试时最想看到的正是同一个目录 —— '
          '等到成功才记，恰好把最需要它的那次场景漏掉。',
    );
  });

  test('同一个目标反复用不会堆出多条，且最新在最前', () async {
    final s = setup(tree: {
      'root': [file('a')],
      'dest': [],
      'other': [],
    });

    await run(s.c, entries: [file('a')], target: target('dest', '/目标'));
    await run(s.c, entries: [file('a')], target: target('other', '/别处'));
    await run(s.c, entries: [file('a')], target: target('dest', '/目标'));

    expect(
      (await s.c.read(moveTargetsProvider.future)).map((t) => t.fid),
      ['dest', 'other'],
      reason: '按 fid 去重且最新在前。堆出好几条同名记录的话，'
          '「最近用过」这一列会变成一串看不出区别的重复项。',
    );
  });

  test('本地索引**不动**：移动不改 fid，那些行不是死索引', () async {
    final s = setup(tree: {
      'root': [file('a')],
      'dest': [],
    });
    await s.repo.upsertItems([item('a', '/')]);

    final outcome =
        await run(s.c, entries: [file('a')], target: target('dest', '/目标'));

    expect(outcome!.moved, 1);
    expect(
      await s.repo.itemById(MediaItem.idFor(DriveProvider.quark, 'a')),
      isNotNull,
      reason: '移动之后那个文件还在网盘上（fid 没变），所以库里那一行既不是'
          '死索引、也不该消失。删掉它反而会让用户丢掉续播点与播放偏好，'
          '而重扫也救不回那些旁表数据。它的 dirPath 会陈旧，等下次扫描修正。',
    );
  });
}
