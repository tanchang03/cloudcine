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

/// 详情页的「季 / 部」选择器 —— **交互**这一层。
///
/// ## 为什么单独一个文件
///
/// 「哪些层该出现」的判定在 `WorkLevels`（纯函数，`test/domain/work_levels_test.dart`
/// 已穷举）。这里只钉三件纯函数管不到的事：
///
///   1. 点一下 chip **真的换掉了列表**（而不是只改了高亮）；
///   2. 换季时**部行跟着换**（不是留着上一季的部）；
///   3. 不该出现层的时候**一个 chip 都不画** —— 这条最容易被后来的改动破坏，
///      因为多画一层不会报错，只会让电影详情页多出一排没用的按钮。
///
/// 用**内存库**（`AppDatabase.memory()`）而不是替身仓储：详情页顺带会读
/// 设置（`settingsProvider`），走真库能让那条链路一起被覆盖到。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaItem ep(
    String id, {
    int? season,
    int? episode,
    int? part,
    String? partLabel,
    String? name,
    String? title,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: id,
        name: name ?? '$id.mkv',
        dirId: 'd1',
        dirPath: '/动漫/进击的巨人/',
        groupKey: 'aot',
        kind: MediaKind.episode,
        title: title ?? '进击的巨人',
        season: season,
        episode: episode,
        part: part,
        partLabel: partLabel,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 挂上详情页。返回 tester 便于继续操作。
  Future<void> pumpDetail(
    WidgetTester tester, {
    required List<MediaItem> items,
    String workKey = 'aot',
    String workTitle = '进击的巨人',
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);
    await repo.upsertWorks([
      MediaWork(
        key: workKey,
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: workTitle,
        updatedAt: now,
      ),
    ], now: now);
    await repo.upsertItems(items, now: now);

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
        child: MaterialApp(home: WorkDetailPage(workKey: workKey)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('两季 → 出现季行；点第二季 → 列表只剩那一季的集', (tester) async {
    await pumpDetail(tester, items: [
      ep('a', season: 1, episode: 1),
      ep('b', season: 1, episode: 2),
      ep('c', season: 2, episode: 1),
    ]);

    // 季行在：两个 chip 都画出来了。
    expect(find.text('第 1 季'), findsOneWidget);
    expect(find.text('第 2 季'), findsOneWidget);

    // 默认选中「点播放会播的那一集」所在的季 —— 也就是第一季。
    expect(find.text('进击的巨人 S01E01'), findsOneWidget);
    expect(find.text('进击的巨人 S02E01'), findsNothing);

    await tester.tap(find.text('第 2 季'));
    await tester.pumpAndSettle();

    expect(
      find.text('进击的巨人 S02E01'),
      findsOneWidget,
      reason: '点了第二季列表却没换 —— 这个 chip 就只是个装饰',
    );
    expect(find.text('进击的巨人 S01E01'), findsNothing);
  });

  testWidgets('季 + 部 → 选中有分部的季才出现部行，且部能再筛一层', (tester) async {
    await pumpDetail(tester, items: [
      ep('s1', season: 1, episode: 1),
      ep('s3p1', season: 3, part: 1, episode: 1),
      // 集号刻意与 Part.1 错开：两部的集都叫 S03E01 的话，
      // 「换没换」这件事在断言里根本看不出来。
      ep('s3p2', season: 3, part: 2, episode: 13),
    ]);

    // 第一季没有分部 → 不该出现部行。
    expect(find.text('第 1 部'), findsNothing);

    await tester.tap(find.text('第 3 季'));
    await tester.pumpAndSettle();

    expect(find.text('第 1 部'), findsOneWidget);
    expect(find.text('第 2 部'), findsOneWidget);

    await tester.tap(find.text('第 2 部'));
    await tester.pumpAndSettle();

    expect(find.text('进击的巨人 S03E13'), findsOneWidget);
    expect(
      find.text('进击的巨人 S03E01'),
      findsNothing,
      reason: '部这一层必须真的把列表收窄；只换高亮不换列表等于没筛',
    );
  });

  testWidgets('换季时部行跟着换，不残留上一季的部', (tester) async {
    await pumpDetail(tester, items: [
      ep('s1', season: 1, episode: 1),
      ep('s3p1', season: 3, part: 1, episode: 1),
      ep('s3p2', season: 3, part: 2, episode: 1),
    ]);

    await tester.tap(find.text('第 3 季'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 部'), findsOneWidget);

    await tester.tap(find.text('第 1 季'));
    await tester.pumpAndSettle();

    expect(
      find.text('第 1 部'),
      findsNothing,
      reason: '换到没有分部的季之后部行还在，用户会以为自己还在看第三季',
    );
  });

  testWidgets('单季剧 / 电影 → 一层都不画', (tester) async {
    await pumpDetail(tester, items: [
      ep('a', season: 1, episode: 1),
      ep('b', season: 1, episode: 2),
    ]);

    expect(
      find.text('第 1 季'),
      findsNothing,
      reason: '只有一个选项的选择器是噪音；单季剧的版式必须与改造前一致',
    );
    expect(find.text('第 1 部'), findsNothing);
    // 但集还是要列出来。
    expect(find.text('进击的巨人 S01E01'), findsOneWidget);
  });

  testWidgets('未标季里提不出集号的行显示「剧名-文件名」', (tester) async {
    // 真实样本：`/来自：分享/F飞CC日  志2/` 下 12 个 `01.国语.mp4` / `01.粤语.mp4`…
    // 解析不出片名也解析不出集号，被「目录名作为系列名」那条规则顶成目录名
    // —— 退回 `displayTitle` 的话 12 行主标题一模一样，用户看不出是哪个文件，
    // 而这是「未标季」这一格里唯一能区分它们的信息。
    await pumpDetail(
      tester,
      workTitle: '飞常日志',
      items: [
        ep('a', name: '01.国语.mp4', title: 'F飞CC日 志2'),
        ep('b', name: '01.粤语.mp4', title: 'F飞CC日 志2'),
        // 有集号的**仍要保留片名**：同一集常有多个版本（翡翠台 / MyTVSuper），
        // 版本之间只有片名不同，写成「第 1 集」会让两个版本变成一样的行。
        ep('c', title: '飛常日誌', episode: 1),
      ],
    );

    expect(find.text('飞常日志-01.国语'), findsOneWidget);
    expect(find.text('飞常日志-01.粤语'), findsOneWidget);
    expect(find.text('飛常日誌 E01'), findsOneWidget);
    expect(
      find.text('F飞CC日 志2'),
      findsNothing,
      reason: '条目自己那个目录名不该再出现在列表里 —— 它正是「分不出哪一行」的来源',
    );
  });
}
