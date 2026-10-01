import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/widgets/library_filter_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「筛选」按钮与浮层。
///
/// 用 `InMemoryMediaRepository` 而不是真库：这个文件要验的是**交互**——
/// 点一下会发生什么、面板上写的是什么。数据层的口径由
/// `test/domain/media_repository_filter_test.dart` 与
/// `test/data/library_filter_query_test.dart` 负责（那两个跑真库）。
void main() {
  final now = DateTime(2026, 10, 1);

  MediaWork work(
    String key, {
    int? year,
    List<String> genres = const [],
    MediaCategory category = MediaCategory.movie,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: key,
        category: category,
        year: year,
        genres: genres,
        updatedAt: now,
      );

  /// 挂一棵最小的树，并返回那个可读状态的 container。
  ///
  /// [repo] 只在需要「仓储坏了」这类用例时传；默认用正常的替身。
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required List<MediaWork> works,
    MediaRepository? repo,
  }) async {
    final repository = repo ?? InMemoryMediaRepository();
    await repository.upsertWorks(works, now: now);

    final container = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.all(12),
                child: LibraryFilterButton(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// 点开面板。开之前树上只有按钮那一个「筛选」。
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
  }

  LibraryFilter state(ProviderContainer c) => c.read(libraryFilterProvider);

  group('面板内容', () {
    testWidgets('年代与类型都列出来，带作品数', (tester) async {
      await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 2023, genres: ['剧情']),
        work('c', year: 1995, genres: ['科幻']),
      ]);

      await open(tester);

      expect(find.text('2020 年代'), findsOneWidget);
      expect(find.text('1990 年代'), findsOneWidget);
      expect(find.text('剧情'), findsOneWidget);
      expect(find.text('科幻'), findsOneWidget);
      // 剧情 2 部、科幻 1 部
      expect(find.text('2'), findsWidgets);
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('没有带年份的作品 → 说清为什么空', (tester) async {
      await pump(tester, works: [work('a', genres: ['剧情'])]);

      await open(tester);

      expect(
        find.textContaining('还没有带年份的作品'),
        findsOneWidget,
        reason: '空的时候必须说清「为什么空」。一片空白时用户的第一反应是'
            '「功能坏了」，而实际上只是还没刮削过',
      );
      expect(find.textContaining('刮削'), findsOneWidget);
    });

    testWidgets('没有类型信息 → 提示刮削后会出现', (tester) async {
      await pump(tester, works: [work('a', year: 2021)]);

      await open(tester);

      expect(find.textContaining('还没有类型信息'), findsOneWidget);
    });

    testWidgets('没有任何条件时「清空筛选」是禁用的', (tester) async {
      await pump(tester, works: [work('a', year: 2021, genres: ['剧情'])]);

      await open(tester);

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '清空筛选'),
      );
      expect(
        button.onPressed,
        isNull,
        reason: '按钮**置灰而不是隐藏**：位置固定，用户不会因为「上一个状态下'
            '这里有东西」而去找它',
      );
    });
  });

  group('交互', () {
    testWidgets('点一个年代 → 选中，再点一次 → 取消', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 1995, genres: ['剧情']),
      ]);
      await open(tester);

      await tester.tap(find.text('2020 年代'));
      await tester.pumpAndSettle();
      expect(state(c).decades, {2020});

      await tester.tap(find.text('2020 年代'));
      await tester.pumpAndSettle();
      expect(state(c).decades, isEmpty);
    });

    testWidgets('多选：年代与类型可以叠加', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 2023, genres: ['科幻']),
      ]);
      await open(tester);

      await tester.tap(find.text('2020 年代'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧情'));
      await tester.pumpAndSettle();

      expect(state(c).decades, {2020});
      expect(state(c).genres, {'剧情'});
    });

    testWidgets('点 chip 不会把面板关掉', (tester) async {
      await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 1995, genres: ['科幻']),
      ]);
      await open(tester);

      await tester.tap(find.text('2020 年代'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('library-filter-panel')),
        findsOneWidget,
        reason: '多选必须能连续点几下。面板一关一开的话，选第二个类型要'
            '重新点开一次',
      );
    });

    testWidgets('按钮上带出生效条件数', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 1995, genres: ['科幻']),
      ]);

      // 开之前按钮上只有一个「筛选」，没有数字
      expect(find.descendant(of: find.byType(Tooltip), matching: find.text('0')),
          findsNothing);

      await open(tester);
      await tester.tap(find.text('2020 年代'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧情'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(Tooltip), matching: find.text('2')),
        findsOneWidget,
        reason: '用户从别的地方回到媒体库，一眼就要看出「列表不是全量，'
            '是因为筛着东西」—— 否则只会觉得「怎么少了好多片子」',
      );
      expect(state(c).decades.length + state(c).genres.length, 2);
    });

    testWidgets('清空筛选只清面板里的两组，不动分类与搜索词', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
      ]);

      await open(tester);
      await tester.tap(find.text('2020 年代'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧情'));
      await tester.pumpAndSettle();

      // 选完之后再动分类与搜索框：面板上的选项**跟着这两个条件收窄**，
      // 先设的话可能根本没有可选项（这也正是它们的作用）。
      c.read(libraryFilterProvider.notifier)
        ..setCategory(MediaCategory.anime)
        ..setQuery('魔法');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '清空筛选'));
      await tester.pumpAndSettle();

      expect(state(c).decades, isEmpty);
      expect(state(c).genres, isEmpty);
      expect(
        state(c).category,
        MediaCategory.anime,
        reason: '分类栏在面板之外、有自己的清除入口。面板上的「清空筛选」'
            '把它一起抹掉，用户会莫名其妙地丢掉刚打的搜索词',
      );
      expect(state(c).query, '魔法');
    });
  });

  group('统计失败时不能伪装成「正在统计…」', () {
    testWidgets('countWorksByDecade 出错 → 面板显示失败', (tester) async {
      await pump(
        tester,
        works: [work('a', year: 2021, genres: ['剧情'])],
        repo: _BrokenDecadeRepo(),
      );
      await open(tester);

      expect(
        find.textContaining('统计年代失败'),
        findsOneWidget,
        reason: '如果只是 `valueOrNull`，出错也是 `null`，面板会永远停在'
            '「正在统计…」—— 用户等一个永远不会来的结果。',
      );
      expect(find.textContaining('正在统计'), findsNothing);
    });

    testWidgets('countWorksByGenre 出错 → 面板显示失败', (tester) async {
      await pump(
        tester,
        works: [work('a', year: 2021, genres: ['剧情'])],
        repo: _BrokenGenreRepo(),
      );
      await open(tester);

      expect(find.textContaining('统计类型失败'), findsOneWidget);
      expect(find.textContaining('正在统计'), findsNothing);
    });
  });

  group('已选条件在切换分类后仍然可取消', () {
    /// 「电影」栏里有一部 90 年代的科幻片；「动漫」栏是空的。
    ///
    /// 在「电影」栏里选好条件，再切到「动漫」—— 选中的两项就都不在当前
    /// 范围里了（`decadeCountsProvider` 是按分类收窄的）。
    Future<ProviderContainer> selectThenSwitch(
      WidgetTester tester,
    ) async {
      final c = await pump(tester, works: [
        work('a', year: 1995, genres: ['科幻']),
      ]);
      await open(tester);
      await tester.tap(find.text('1990 年代'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('科幻'));
      await tester.pumpAndSettle();

      c.read(libraryFilterProvider.notifier).setCategory(MediaCategory.anime);
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('已选但当前范围里没有的项照样画出来，并标「无结果」', (tester) async {
      await selectThenSwitch(tester);

      expect(
        find.text('1990 年代'),
        findsOneWidget,
        reason: '这一项不在 `counts` 里（动漫栏里没有 90 年代的片子），但它**仍然'
            '是生效的筛选条件**。不画出来的话，用户看到按钮上写着「已选 2 项」、'
            '列表却是空的，却找不到那第二个条件在哪 —— 唯一出路是「清空筛选」，'
            '把另一个还想留的条件一起抹掉。',
      );
      expect(find.text('科幻'), findsOneWidget);
      expect(find.text('无结果'), findsNWidgets(2));
    });

    testWidgets('点那颗「无结果」的 chip 能把它单独取消，别的条件不受影响', (tester) async {
      final c = await selectThenSwitch(tester);

      await tester.tap(find.text('1990 年代'));
      await tester.pumpAndSettle();

      expect(state(c).decades, isEmpty);
      expect(
        state(c).genres,
        {'科幻'},
        reason: '用户点的是「1990 年代」这一颗，不该顺手把「科幻」也清掉 ——'
            '能**单独**取消正是把它画出来的全部意义。',
      );
    });

    testWidgets('有已选项时不再说「还没有带年份的作品」', (tester) async {
      await selectThenSwitch(tester);

      expect(
        find.textContaining('还没有带年份的作品'),
        findsNothing,
        reason: '范围里不是「没有带年份的作品」，而是「这个年代没有」。'
            '两句话同时出现会自相矛盾 —— 用户正看着一颗勾着的「1990 年代'
            '（无结果）」。',
      );
    });
  });
}

/// 年代计数**故意抛出异常**的仓储，用来验证面板出错时的文案。
class _BrokenDecadeRepo extends InMemoryMediaRepository {
  @override
  Future<Map<int, int>> countWorksByDecade({
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
  }) async =>
      throw StateError('数据库炸了');
}

/// 类型计数**故意抛出异常**的仓储。
class _BrokenGenreRepo extends InMemoryMediaRepository {
  @override
  Future<Map<String, int>> countWorksByGenre({
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
  }) async =>
      throw StateError('数据库炸了');
}
