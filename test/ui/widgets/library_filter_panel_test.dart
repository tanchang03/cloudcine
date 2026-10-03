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
    testWidgets('年份与类型都列出来，带作品数', (tester) async {
      await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 2023, genres: ['剧情']),
        work('c', year: 1995, genres: ['科幻']),
      ]);

      await open(tester);

      expect(find.text('2021'), findsOneWidget);
      expect(find.text('2023'), findsOneWidget);
      expect(find.text('1995'), findsOneWidget);
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
      // ⚠️ 这里**不能**用宽松的 `find.textContaining('刮削')`：面板上还有
      // 「刮削」分组标题和「已刮削」那颗 chip，宽松匹配会同时命中三处 ——
      // 那样这条断言就不再是在验「提示语说了要刮削」，而是「面板里出现过
      // 刮削两个字」。
      expect(
        find.textContaining('刮削一次就能拿到上映年份'),
        findsOneWidget,
        reason: '光说「还没有带年份的作品」是不够的，还得告诉用户怎么办',
      );
    });

    testWidgets('没有类型信息 → 提示刮削后会出现', (tester) async {
      await pump(tester, works: [work('a', year: 2021)]);

      await open(tester);

      expect(find.textContaining('还没有类型信息'), findsOneWidget);
    });

    testWidgets('「已刮削」单独一组列出来', (tester) async {
      await pump(tester, works: [work('a', year: 2021, genres: ['剧情'])]);

      await open(tester);

      expect(find.text('刮削'), findsOneWidget, reason: '分组标题');
      expect(
        find.text('已刮削'),
        findsOneWidget,
        reason: '它是一个**开关**（单选、没有「或」的余地），所以只有一颗 '
            'chip —— 与年份 / 类型那种多选是两回事',
      );
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
    testWidgets('点一个年份 → 选中，再点一次 → 取消', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 1995, genres: ['剧情']),
      ]);
      await open(tester);

      await tester.tap(find.text('2021'));
      await tester.pumpAndSettle();
      expect(state(c).years, {2021});

      await tester.tap(find.text('2021'));
      await tester.pumpAndSettle();
      expect(state(c).years, isEmpty);
    });

    testWidgets('多选：年份与类型可以叠加', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 2023, genres: ['科幻']),
      ]);
      await open(tester);

      await tester.tap(find.text('2021'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧情'));
      await tester.pumpAndSettle();

      expect(state(c).years, {2021});
      expect(state(c).genres, {'剧情'});
    });

    testWidgets('点 chip 不会把面板关掉', (tester) async {
      await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
        work('b', year: 1995, genres: ['科幻']),
      ]);
      await open(tester);

      await tester.tap(find.text('2021'));
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
      await tester.tap(find.text('2021'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧情'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(Tooltip), matching: find.text('2')),
        findsOneWidget,
        reason: '用户从别的地方回到媒体库，一眼就要看出「列表不是全量，'
            '是因为筛着东西」—— 否则只会觉得「怎么少了好多片子」',
      );
      expect(state(c).years.length + state(c).genres.length, 2);
    });

    testWidgets('点「已刮削」→ 打开，再点一次 → 取消', (tester) async {
      final c = await pump(tester, works: [work('a', year: 2021)]);
      await open(tester);

      await tester.tap(find.text('已刮削'));
      await tester.pumpAndSettle();
      expect(state(c).scrapedOnly, isTrue);

      await tester.tap(find.text('已刮削'));
      await tester.pumpAndSettle();
      expect(state(c).scrapedOnly, isFalse);
    });

    testWidgets('「已刮削」也算一项生效条件，按钮上要出现数字', (tester) async {
      // 这一棵树上刻意**不放年份 / 类型**：面板里那些 chip 也带数字，
      // 混在一起就分不清按钮上那个「1」是角标还是某颗 chip 的计数。
      final c = await pump(tester, works: [work('a')]);
      await open(tester);

      await tester.tap(find.text('已刮削'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(Tooltip), matching: find.text('1')),
        findsOneWidget,
        reason: '它是面板里三组条件之一。不数进去的话，用户明明筛着东西，'
            '按钮上却没有任何标记 —— 他会以为「列表少了好多片子」是别的原因',
      );
      expect(state(c).selectedCount, 1);
    });

    testWidgets('「清空筛选」把「已刮削」也一起清掉', (tester) async {
      final c = await pump(tester, works: [work('a')]);
      await open(tester);
      await tester.tap(find.text('已刮削'));
      await tester.pumpAndSettle();
      expect(state(c).scrapedOnly, isTrue);

      await tester.tap(find.widgetWithText(TextButton, '清空筛选'));
      await tester.pumpAndSettle();

      expect(
        state(c).scrapedOnly,
        isFalse,
        reason: '它没有别的清除入口（不像分类栏与搜索框各有一个）。不清的话，'
            '用户点完「清空筛选」列表还是空的，而面板上已经看不出是哪儿在筛',
      );
      expect(state(c).hasExtra, isFalse);
    });

    testWidgets('清空筛选只清面板里的三组，不动分类与搜索词', (tester) async {
      final c = await pump(tester, works: [
        work('a', year: 2021, genres: ['剧情']),
      ]);

      await open(tester);
      await tester.tap(find.text('2021'));
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

      expect(state(c).years, isEmpty);
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
    testWidgets('countWorksByYear 出错 → 面板显示失败', (tester) async {
      await pump(
        tester,
        works: [work('a', year: 2021, genres: ['剧情'])],
        repo: _BrokenYearRepo(),
      );
      await open(tester);

      expect(
        find.textContaining('统计年份失败'),
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
    /// 「电影」栏里有一部 1995 年的科幻片；「动漫」栏是空的。
    ///
    /// 在「电影」栏里选好条件，再切到「动漫」—— 选中的两项就都不在当前
    /// 范围里了（`yearCountsProvider` 是按分类收窄的）。
    Future<ProviderContainer> selectThenSwitch(
      WidgetTester tester,
    ) async {
      final c = await pump(tester, works: [
        work('a', year: 1995, genres: ['科幻']),
      ]);
      await open(tester);
      await tester.tap(find.text('1995'));
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
        find.text('1995'),
        findsOneWidget,
        reason: '这一项不在 `counts` 里（动漫栏里没有 1995 年的片子），但它**仍然'
            '是生效的筛选条件**。不画出来的话，用户看到按钮上写着「已选 2 项」、'
            '列表却是空的，却找不到那第二个条件在哪 —— 唯一出路是「清空筛选」，'
            '把另一个还想留的条件一起抹掉。',
      );
      expect(find.text('科幻'), findsOneWidget);
      expect(find.text('无结果'), findsNWidgets(2));
    });

    testWidgets('点那颗「无结果」的 chip 能把它单独取消，别的条件不受影响', (tester) async {
      final c = await selectThenSwitch(tester);

      await tester.tap(find.text('1995'));
      await tester.pumpAndSettle();

      expect(state(c).years, isEmpty);
      expect(
        state(c).genres,
        {'科幻'},
        reason: '用户点的是「1995」这一颗，不该顺手把「科幻」也清掉 ——'
            '能**单独**取消正是把它画出来的全部意义。',
      );
    });

    testWidgets('有已选项时不再说「还没有带年份的作品」', (tester) async {
      await selectThenSwitch(tester);

      expect(
        find.textContaining('还没有带年份的作品'),
        findsNothing,
        reason: '范围里不是「没有带年份的作品」，而是「这个年份没有」。'
            '两句话同时出现会自相矛盾 —— 用户正看着一颗勾着的「1995'
            '（无结果）」。',
      );
    });
  });

  /// 面板必须能从遥控器上关掉。
  ///
  /// 这不是「顺手加个按钮」：`MenuAnchor` 关自己**只认 Esc**
  /// （源码里 `_kMenuShortcuts` 把 escape 绑到 `DismissIntent`），
  /// 而它是个 `OverlayPortal`、**不是路由**。Android TV 遥控器上没有 Esc，
  /// 按 BACK 又会穿透到路由上把人带走 —— 没有显式出口，这个面板就是一间单向门。
  group('关得掉：TV 上没有 Esc', () {
    testWidgets('面板底部有「关闭」按钮，点它能把面板关掉', (tester) async {
      await pump(tester, works: [work('/a', year: 1995)]);
      await open(tester);
      expect(find.byKey(const Key('library-filter-panel')), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('library-filter-panel')),
        findsNothing,
        reason: 'TV 上这是唯一的出口 —— 遥控器没有 Esc',
      );
    });

    testWidgets('面板开着时按系统返回键：关面板，而不是把人带离页面', (tester) async {
      await pump(tester, works: [work('/a', year: 1995)]);
      await open(tester);
      expect(find.byKey(const Key('library-filter-panel')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('library-filter-panel')),
        findsNothing,
        reason: '遥控器的 BACK 应当先关掉这个浮层',
      );
      expect(
        find.byType(LibraryFilterButton),
        findsOneWidget,
        reason: '页面本身不能被带走 —— 原来 BACK 会穿透到路由，'
            '面板还开着，人已经离开媒体库了',
      );
    });

    testWidgets('面板关着时不能把返回键拦下（否则这个页面就退不出去了）', (tester) async {
      await pump(tester, works: [work('/a', year: 1995)]);

      // ⚠️ 只能用 predicate 找：`PopScope` 是**泛型**（`PopScope<T>`），
      // 而 `find.byType` 比的是 `runtimeType` 全等，泛型参数一多就找不着。
      PopScope scope() {
        final found = tester
            .widgetList<PopScope>(find.byWidgetPredicate((w) => w is PopScope))
            .toList();
        expect(
          found,
          hasLength(1),
          reason: '这棵最小树里应当只有筛选按钮自己那一个 PopScope',
        );
        return found.single;
      }

      expect(
        scope().canPop,
        isTrue,
        reason: '没开面板时必须是 true，否则整个媒体库页面就再也退不出去',
      );

      await open(tester);
      expect(
        scope().canPop,
        isFalse,
        reason: '开着面板时那一下 BACK 的语义是「关面板」',
      );
    });
  });
}

/// 年份计数**故意抛出异常**的仓储，用来验证面板出错时的文案。
class _BrokenYearRepo extends InMemoryMediaRepository {
  @override
  Future<Map<int, int>> countWorksByYear({
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
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
    bool scrapedOnly = false,
    String? query,
  }) async =>
      throw StateError('数据库炸了');
}
