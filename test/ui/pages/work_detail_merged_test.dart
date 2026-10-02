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

/// 详情页的「已并入《X》」提示条与「拆开」。
///
/// ## 为什么这三条值得单独钉住
///
/// 自动归一是**用户没发起**的动作。他能观察到的只有「我的电影少了一部」，
/// 而这句话既可以解释成合并、也可以解释成扫描删了数据 —— 没有这条提示，
/// 他没有任何办法分辨。所以：
///
///   1. 折叠过就**必须**有提示（不然是「莫名其妙少了一部」）；
///   2. 提示里的数字与文件列表必须**同口径**（不然用户会怀疑文件丢了）；
///   3. 「拆开」必须真的生效（不然提示条是个谎言，而且他不敢再用自动归一）。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaItem item(String workKey, String fileId, String name) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: name,
        dirId: 'd1',
        dirPath: '/电影/$workKey/',
        groupKey: workKey,
        kind: MediaKind.movie,
        title: name,
        firstSeenAt: now,
        updatedAt: now,
      );

  Future<DriftMediaRepository> seed(
    WidgetTester tester, {
    required bool merged,
  }) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);

    await repo.upsertWorks([
      MediaWork(
        key: 'a',
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: '流浪地球2',
        onlineId: 'movie/843527',
        source: ScrapeSource.online,
        itemCount: 1,
        updatedAt: now,
      ),
      MediaWork(
        key: 'b',
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: 'The Wandering Earth II',
        onlineId: 'movie/843527',
        source: ScrapeSource.online,
        itemCount: 1,
        updatedAt: now,
      ),
    ], now: now);
    await repo.upsertItems([
      item('a', 'fa1', 'A.2023.E01.mkv'),
      item('b', 'fb1', 'B.2023.E05.mkv'),
    ], now: now);
    if (merged) await repo.mergeWorksInto('a', ['b']);

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
        child: const MaterialApp(home: WorkDetailPage(workKey: 'a')),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('折叠过 → 有提示条，且文件列表是并集', (tester) async {
    await seed(tester, merged: true);

    expect(find.textContaining('已并入'), findsOneWidget);
    expect(find.textContaining('The Wandering Earth II'), findsWidgets);
    // ⚠️ 用 `findsWidgets` 而不是 `findsOneWidget`：`MediaItemRow` 会把文件名
    // 画两次（标题 + 提示），断言「恰好一个」是在测版式而不是在测并集。
    expect(
      find.text('A.2023.E01.mkv'),
      findsWidgets,
      reason: '并集少了一半的话，用户看到的是「两个格子变成一个、集数却少了」',
    );
    expect(find.text('B.2023.E05.mkv'), findsWidgets);
  });

  testWidgets('没折叠过 → 一条提示都不画（版式与上线前一致）', (tester) async {
    await seed(tester, merged: false);

    expect(find.textContaining('已并入'), findsNothing);
    expect(find.text('A.2023.E01.mkv'), findsWidgets);
    expect(
      find.text('B.2023.E05.mkv'),
      findsNothing,
      reason: '没合并时把源作品的文件也列出来，等于把「并集」当成了默认行为',
    );
  });

  testWidgets('点「拆开」→ 提示条消失、列表回到只有自己的文件', (tester) async {
    final repo = await seed(tester, merged: true);

    await tester.tap(find.text('拆开'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已并入'), findsNothing);
    expect(find.text('B.2023.E05.mkv'), findsNothing);
    expect(await repo.countWorks(), 2,
        reason: '拆开只清标记，源作品那一行本来就没被删过');
    expect((await repo.listWorks()).map((w) => w.key).toSet(), {'a', 'b'});
  });
}
