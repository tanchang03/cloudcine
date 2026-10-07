import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 追剧：**检查更新之后，详情页要跟着动**（2026-10-07 现场）。
///
/// ## 用户报的原话
///
/// > 「遮天这部动画片设置为追剧后，点击更新后发现有 2 个更新，但是并没有在
/// >   简介的文件列表中发现这俩文件」
/// > 「可能是因为没有刷新缓存，**点击一下刷新可以看到 2 个新文件**」
///
/// ## 为什么值得一个文件
///
/// 这是本项目里最容易再犯、也最难查的一类 bug：**库写对了，但读库的视图
/// 没人通知它重读**。日志上一切正常（`[发现] 媒体 13（新增 2 / 已有 11）`、
/// `[追剧] 检查结束：… 新增 2`），库里的 `new_item_count` 也确实是 2，
/// 偏偏那一页停在旧数据上 —— 于是它既不像「写失败」（库里有），
/// 也不像「查询错」（点一下刷新就对了），只能对着信号链一条条数。
///
/// 真根因：`workDetailProvider` 当时只 `watch(playbackProgressSignalProvider)`
/// （播放进度），而写库的那几条路径（扫描 / 发现 / **追更检查** / 批量刮削）
/// 推的是 `libraryWriteSignalProvider` —— 它不在那条链的下游里。
///
/// 所以第一个用例**不读源码**，而是真的跑一遍：写库 → 推信号 →
/// 断言详情页看见了新文件。读源码的守卫抓不住「信号推错了对象」这种错。
///
/// ## 第二、三个用例：**「点开即已读」**
///
/// 用户的口径是「无论播放了多长时间，只要点击了，就去掉 new 标记」。
/// 原先的判据只有 `max_position_ms`（进度上报写的），而进度上报只在
/// **整十秒边界**触发 ⇒ 点开看一眼（2~3 秒）等于什么都没发生。
/// 现在 `last_played_at`（起播即写的已读回执）也算数，见
/// `domain/services/follow_read.dart`。
///
/// ⚠️ 两个容易写错的地方（写这个文件时各踩了一次）：
///   - `upsertItems` 插入时**用 `now` 顶掉 `firstSeenAt`**（「首次入库时刻 =
///     本次扫描时刻」是它的语义）⇒ 想让老集与追剧起点有先后，得传两次
///     不同的 `now`，而不是在 `MediaItem` 上填 `firstSeenAt`；
///   - 写播放记录的仓储方法收的是**完整 item id**（`quark:f3`），不是
///     `fileId`。传错时它静默匹配 0 行 —— 正是「看过没有」这类判据最难查的
///     失败形态（`saveMaxPosition` 如此，`markPlayed` 也如此）。
void main() {
  final now = DateTime(2026, 10, 7, 12, 0);
  final followStarted = now.subtract(const Duration(hours: 2));

  MediaItem ep(String id, {int? episode}) => MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: '$id.mkv',
        dirId: 'd1',
        dirPath: '/来自：分享/Z 遮.天/',
        groupKey: 'zhetian',
        kind: MediaKind.episode,
        title: '遮天',
        episode: episode,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaWork work({int newItemCount = 0}) => MediaWork(
        key: 'zhetian',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '遮天',
        followed: true,
        followStartedAt: followStarted,
        followCheckedAt: followStarted,
        newItemCount: newItemCount,
        updatedAt: now,
      );

  /// 一套「内存库 + 真仓储 + ProviderContainer」。
  Future<({AppDatabase db, DriftMediaRepository repo, ProviderContainer c})>
      harness() async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    return (db: db, repo: repo, c: container);
  }

  test('追更检查写完库并推信号之后，详情页跟着重查', () async {
    final h = await harness();

    await h.repo.upsertWorks([work()], now: now);
    // 老集：入库时刻在**追剧起点之前**（所以它们不是「追剧后新增的」）。
    await h.repo.upsertItems(
      [ep('f1', episode: 1), ep('f2', episode: 2)],
      now: followStarted.subtract(const Duration(days: 1)),
    );

    final before = await h.c.read(workDetailProvider('zhetian').future);
    expect(before!.items.length, 2);

    // ---- 模拟一次「检查更新」----
    // 新集入库（入库时刻落在追剧起点之后），然后累加角标。
    // 这两步就是 `FollowService._run` 里「逐目录发现 → 回写」那两段。
    await h.repo.upsertItems([ep('f3', episode: 3)], now: now);
    await h.repo.applyFollowCheck(
      increments: {'zhetian': 1},
      checkedKeys: {'zhetian'},
      checkedAt: now,
    );

    // 检查控制器写完之后推的**正是这个**信号。
    h.c.read(libraryWriteSignalProvider.notifier).bump();

    final after = await h.c.read(workDetailProvider('zhetian').future);

    expect(
      after!.items.length,
      3,
      reason: '⛔ 少了 `ref.watch(libraryWriteSignalProvider)`，这里会停在 2 ——'
          '库确实写对了，但这一页没人通知它重读。用户看到的就是'
          '「提示有更新、文件列表里找不到」，点一下页头「刷新」才冒出来'
          '（2026-10-07 现场原话）。',
    );
    expect(after.work.newItemCount, 1);
  });

  test('点开一集就算看过：角标跟着降（2 → 1 → 0）', () async {
    final h = await harness();

    await h.repo.upsertWorks([work(newItemCount: 2)], now: now);
    await h.repo.upsertItems(
      [ep('f1', episode: 1), ep('f2', episode: 2)],
      now: followStarted.subtract(const Duration(days: 1)),
    );
    // 两集新集：入库时刻在追剧起点之后，且还没点开过。
    await h.repo.upsertItems(
      [ep('f3', episode: 3), ep('f4', episode: 4)],
      now: now.subtract(const Duration(hours: 1)),
    );

    await h.c.read(workDetailProvider('zhetian').future);

    expect(
      (await h.repo.workByKey('zhetian'))!.newItemCount,
      2,
      reason: '还有两集没看过，角标不该消失 —— 清早了用户就再也看不到「有更新」。',
    );

    // 「点开即已读」写的是 `last_played_at`（已读回执），**不是**
    // `max_position_ms` —— 2026-10-07 现场用户只看了 2~3 秒就关窗，
    // 进度一次都没上报过（节流器只在整十秒边界触发）。
    await h.repo.markPlayed('quark:f3', now);
    // 起播入口会推播放进度信号，详情页跟着重取。
    h.c.read(playbackProgressSignalProvider.notifier).bump();
    await h.c.read(workDetailProvider('zhetian').future);

    expect(
      (await h.repo.workByKey('zhetian'))!.newItemCount,
      1,
      reason: '看过一集还剩一集 —— 角标必须跟着降。停在 2 的话，用户刚看完一集'
          '却看到海报还写着「更新 2」（2026-10-07 现场原话：『媒体库列表中的'
          '「更新 2」标记也没有相应的调整』）。',
    );

    // 第二集也点开过。
    await h.repo.markPlayed('quark:f4', now);
    h.c.read(playbackProgressSignalProvider.notifier).bump();
    await h.c.read(workDetailProvider('zhetian').future);

    expect(
      (await h.repo.workByKey('zhetian'))!.newItemCount,
      0,
      reason: '两集都点开过了，角标该消失。',
    );
    expect(
      (await h.repo.workByKey('zhetian'))!.followStartedAt,
      followStarted,
      reason: '⛔ 改角标只写 `new_item_count` 一列：动了 `follow_started_at`，'
          '剧集行的 NEW 标签会跟着角标一起消失（那正是「哪几集是新的」）。',
    );
  });

  test('「看过」也算数：位置没上报、但播过（`max_position_ms` 仍是 NULL）', () async {
    final h = await harness();

    await h.repo.upsertWorks([work(newItemCount: 1)], now: now);
    await h.repo.upsertItems([ep('f1', episode: 1)], now: now);

    final detail = await h.c.read(workDetailProvider('zhetian').future);

    expect(
      detail!.items.single.lastPlayedAt,
      isNull,
      reason: '还没点开过 —— 这一条既没有位置也没有播放记录',
    );
    expect(
      detail.work.newItemCount,
      1,
      reason: '这一集是追剧之后入库的、又没点开过 ⇒ 它是新的，角标为 1',
    );
    expect(
      detail.maxPositions,
      isEmpty,
      reason: '只有 2~3 秒的播放不会留下位置 —— 正是现场库里三列全 NULL 的样子',
    );
  });
}
