import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/work_detail_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 追剧：新集在**别的季格**里时，详情页要主动指路（2026-10-07）。
///
/// ## 为什么需要这一层
///
/// 新集入库之后，作品里「哪几集是新的」是逐格算的（`WorkLevels` 按季分桶），
/// 而用户停在某一格上。两者不一致时，界面上如果什么都不说，用户看到的就是
/// 「提示有更新，文件列表里一行新的都没有」—— 2026-10-07 现场的原话。
///
/// 所以这一页加了两样东西，本文件把两样都钉住：
///
///   1. **格子角标**「N 新」—— 告诉用户新集在**哪一格**；
///   2. **指路条**「有 N 集更新在「X」里 · 去看看」—— 并且**点一下真的切过去**。
///
/// ⚠️ 第 2 条必须断言「点了之后列表真的换了」而不只是「提示条消失了」：
///    只换高亮不换列表的话，提示条一样会消失（因为已经站在那一格了），
///    测试会绿，而用户仍然看不到那一集。
///
/// ⚠️ 用**内存库 + 真仓储**：`upsertItems` 插入时用 `now` 顶掉 `firstSeenAt`
///    （「首次入库时刻 = 本次扫描时刻」），所以「哪些集是追剧之后新增的」
///    只能靠**两次不同 `now`** 的写入来构造，不能在 `MediaItem` 上直接填。
void main() {
  final now = DateTime(2026, 10, 7, 12, 0);
  final followStarted = now.subtract(const Duration(days: 3));

  MediaItem ep(String id, {int? season, int? episode}) => MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: '$id.mkv',
        dirId: 'd1',
        dirPath: '/来自：分享/Z 遮.天/',
        groupKey: 'zhetian',
        kind: MediaKind.episode,
        title: '遮天',
        season: season,
        episode: episode,
        firstSeenAt: now,
        updatedAt: now,
      );

  testWidgets('新集在别的季 → 那一格挂「N 新」，并给出可点击的指路条', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);

    await repo.upsertWorks([
      MediaWork(
        key: 'zhetian',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: '遮天',
        followed: true,
        followStartedAt: followStarted,
        followCheckedAt: followStarted,
        newItemCount: 1,
        updatedAt: now,
      ),
    ], now: now);

    // 第 1 季：追剧**之前**就入库了（所以不是「追剧后新增的」）。
    await repo.upsertItems(
      [ep('f1', season: 1, episode: 1)],
      now: followStarted.subtract(const Duration(days: 1)),
    );
    // 第 2 季：追剧之后才入库的 → 唯一的一条新集。
    await repo.upsertItems([ep('f2', season: 2, episode: 1)], now: now);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: WorkDetailPage(workKey: 'zhetian')),
      ),
    );
    await tester.pumpAndSettle();

    // 默认停在「点播放会播的那一集」所在的季（第 1 季）—— 新集不在这一格。
    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);
    expect(find.text('遮天 S01E01'), findsOneWidget);
    expect(find.text('遮天 S02E01'), findsNothing);

    // ① 角标：说的是「新集在**哪一格**」。
    expect(
      find.text('1 新'),
      findsOneWidget,
      reason: '季格上没有角标，用户就没有任何线索知道该去哪一格找新集',
    );

    // ② 指路条：把「被告知有更新」和「新集在哪」连起来。
    expect(
      find.text('有 1 集更新在「第 2 季」里'),
      findsOneWidget,
      reason: '这一条只在「当前格一条新的都没有、而别处有时」出现 ——'
          '它就是用户 2026-10-07 报的「说有 2 个更新但列表里找不到」的解药',
    );

    // ③ 点一下**真的切过去**（而不只是把提示条藏掉）。
    await tester.tap(find.text('有 1 集更新在「第 2 季」里'));
    await tester.pumpAndSettle();

    expect(
      find.text('遮天 S02E01'),
      findsOneWidget,
      reason: '点了指路条列表却没换 —— 那这条就只是一句安慰话',
    );
    expect(find.text('遮天 S01E01'), findsNothing);
    expect(
      find.text('有 1 集更新在「第 2 季」里'),
      findsNothing,
      reason: '已经站在新集那一格了，指路条就该消失（它不是常驻的横幅）',
    );
  });
}
