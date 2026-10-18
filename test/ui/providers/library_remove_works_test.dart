import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 媒体库批量移除（`MissingMediaController.removeWorks`）。
///
/// ## 为什么测这一层
///
/// 多选的「移除」按钮背后是三件事，每件做错的后果都是**静默的数据残留**：
///
///   1. **整部删除必须带上折叠进来的源作品**（`deleteWork` 的并集口径）——
///      少删一部别名行，「移除整部剧」之后库里还剩半个作品，而任何界面都
///      不报错；
///   2. **返回的文件行数要如实**（调用方拿它写「N 部 / M 个文件」的提示）；
///   3. **刷新只做一次**（删 10 部跑 10 遍 invalidate = 海报墙重画 10 次）。
///
/// 这里用内存仓储（不是 drift）：被测的是「控制器决定动哪些行」，不是 SQL
/// 语义 —— 那部分由 `test/data/` 下的真库测试守着。
void main() {
  final now = DateTime(2026, 10, 17);

  MediaItem item(String fileId, String groupKey) => MediaItem(
        provider: DriveProvider.quark,
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

  /// 装配一套内存库：`work-a` 3 个文件，`work-keep` 1 个文件（没人勾）。
  Future<({ProviderContainer c, InMemoryMediaRepository repo})> setup() async {
    final repo = InMemoryMediaRepository();
    await repo.upsertItems([
      item('a1', 'work-a'),
      item('a2', 'work-a'),
      item('a3', 'work-a'),
      item('k1', 'work-keep'),
    ]);
    await repo.upsertWorks([work('work-a'), work('work-keep')]);
    final c = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    return (c: c, repo: repo);
  }

  /// 在 [setup] 之上加一条折进 `work-a` 的别名行 `work-s`（自身 1 个文件）。
  Future<({ProviderContainer c, InMemoryMediaRepository repo})>
      setupWithMergedAlias() async {
    final s = await setup();
    await s.repo.upsertItems([item('s1', 'work-s')]);
    await s.repo.upsertWorks([work('work-s', mergedInto: 'work-a')]);
    return s;
  }

  test('移除整部 => 它名下的文件与作品行一起没', () async {
    final s = await setup();

    final removed =
        await s.c.read(missingMediaControllerProvider).removeWorks({'work-a'});

    expect(removed, 3, reason: '返回的文件行数要如实 —— 提示里写的是它');
    expect(await s.repo.itemById(item('a1', 'work-a').id), isNull);
    expect(await s.repo.itemById(item('a2', 'work-a').id), isNull);
    expect(await s.repo.workByKey('work-a'), isNull);
  });

  test('折叠进来的别名行跟着一起走（并集口径）', () async {
    final s = await setupWithMergedAlias();

    final removed =
        await s.c.read(missingMediaControllerProvider).removeWorks({'work-a'});

    // 3 + 1 = 4：`work-s` 折进 `work-a`，它的文件也属于这一部。
    expect(removed, 4);
    expect(await s.repo.itemById(item('s1', 'work-s').id), isNull);
    expect(await s.repo.workByKey('work-s'), isNull);
  });

  test('没勾的那部一动不动', () async {
    final s = await setup();

    await s.c.read(missingMediaControllerProvider).removeWorks({'work-a'});

    expect(await s.repo.workByKey('work-keep'), isNotNull);
    expect(await s.repo.itemById(item('k1', 'work-keep').id), isNotNull);
  });

  test('删多部只刷新一次（write signal 只 +1）', () async {
    final s = await setup();
    var bumps = 0;
    s.c.listen(libraryWriteSignalProvider, (_, __) => bumps++);

    await s.c
        .read(missingMediaControllerProvider)
        .removeWorks({'work-a', 'work-s'});

    expect(bumps, 1, reason: '逐部 invalidate 的话，删 N 部海报墙就重画 N 次');
  });

  test('一部都不在库里时不动库、不刷新', () async {
    final s = await setup();
    var bumps = 0;
    s.c.listen(libraryWriteSignalProvider, (_, __) => bumps++);

    final removed = await s.c
        .read(missingMediaControllerProvider)
        .removeWorks({'not-there'});

    expect(removed, 0);
    expect(bumps, 0);
  });

  test('空壳作品（名下一条文件都没有）也删得掉、也刷新', () async {
    // 2026-10-17 现场：《仙逆剧场版：弑仙之战》的文件被目录锚点归到了
    // 上一层目录的《仙逆》名下，作品行空着却照样列在媒体库里，点它只会
    // 得到一句没有出口的提示。
    final repo = InMemoryMediaRepository();
    await repo.upsertWorks([work('empty-shell')]);
    final c = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    var bumps = 0;
    c.listen(libraryWriteSignalProvider, (_, __) => bumps++);

    final removed =
        await c.read(missingMediaControllerProvider).removeWorks({'empty-shell'});

    expect(removed, 0, reason: '空壳行不带文件 —— 返回值说的是文件行数');
    expect(await repo.workByKey('empty-shell'), isNull,
        reason: '作品行必须真的没了，不然用户移除完卡片还挂在原位');
    expect(bumps, 1,
        reason: '删掉的文件行数是 0，但库确实动了 —— 不刷新等于按钮坏了');
  });
}
