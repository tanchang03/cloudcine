import 'dart:convert';

import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:cloudcine/domain/services/work_scraper.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/providers/scrape_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 刮削成功后**哪些东西要重算**。
///
/// ## 为什么值得一个文件
///
/// `WorkScrapeController._refreshAfter` 里那条「分类变了 → 筛选面板的两组
/// 角标也要作废」曾经漏掉过：当时的判据只有 `year` 变了没、`genres` 变了没。
/// 而这两条都盖不住下面这个真实场景 ——
///
///   * 库里有一行「`genres` 已经是 TMDB 给的『动画』、`category` 却还停在
///     『剧集』」（老版本写的行，或分类折算那行代码加上之前刮削入库的）；
///   * 用户对它点一次「刮削」，`genres` 一个字都没变、`year` 也没变，
///     **只有 `category` 从「剧集」挪到了「动漫」**；
///   * 于是按旧判据两组角标都不作废，用户看到的筛选面板还停在旧数字上
///     （「剧集栏里还有 1 部动画」），而列表里那部已经不见了。
///
/// 这类「数字与列表对不上」的 bug 特别难自查 —— 用户只会觉得筛选面板不准，
/// 不会想到是刮削没有通知它。
///
/// ## 为什么用真库
///
/// 断言的是「角标 provider **重算了没有**」，而重算的判据落在 SQL 的结果上。
/// 用 `InMemoryMediaRepository` 会把 SQL 那一侧整个跳过。
void main() {
  final now = DateTime(2026, 10, 1);

  late AppDatabase db;
  late _CountingRepo repo;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.memory();
    repo = _CountingRepo(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 把「刮削后长这样」的描述包成一个脚本，并**顺手落库**。
  ///
  /// 落库是必须的：`_refreshAfter` 之后角标会重算，而它要能从库里读到新状态。
  /// 真 `WorkScraper` 也是「算出一行 → 落库 → 返回它」，这里保持同样的顺序。
  Future<MediaWork> Function(MediaWork) change(
    MediaWork Function(MediaWork before) edit,
  ) =>
      (before) async {
        final after = edit(before);
        await repo.upsertWorks([after]);
        return after;
      };

  /// 建容器，并把刮削器换成一个**脚本化**的假实现。
  ///
  /// [transform] 描述「这次刮削把这一行改成了什么样」—— 测试用它来精确指定
  /// 分类 / 年份 / 类型里**哪一个**变了，因为被验的就是「按哪个字段判重算」。
  ProviderContainer build(
    Future<MediaWork> Function(MediaWork before) transform,
  ) {
    container = ProviderContainer(
      overrides: [
        mediaRepositoryProvider.overrideWithValue(repo),
        workScraperProvider.overrideWith(
          (ref) => _ScriptedScraper(
            library: repo,
            pipeline: ScraperPipeline(const []),
            transform: transform,
          ),
        ),
      ],
    );
    return container;
  }

  /// 直接写一行作品。
  ///
  /// 走 `MediaWorksCompanion.insert` 而不是仓储的 `upsertWorks`：只有它能
  /// 写出「`genres` 已刮削、`category` 却还是旧值」这种**自相矛盾**的行，
  /// 而那正是下面第二条用例要复现的老库状态。
  Future<void> seed({
    required String key,
    required String kind,
    required String title,
    required String category,
    int? year,
    List<String> genres = const [],
  }) async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: key,
            provider: DriveProvider.quark.id,
            kind: kind,
            title: title,
            category: Value(category),
            year: Value(year),
            genres: Value(jsonEncode(genres)),
            source: 'local',
            updatedAt: now,
          ),
        );
  }

  Future<void> scrape(String key) =>
      container.read(workScrapeControllerProvider.notifier).scrape(key);

  test('分类变了、年份没变 → 年份角标要重算', () async {
    await seed(
      key: 'w',
      kind: 'episode',
      title: '某剧',
      category: 'series',
      year: 2015,
      genres: const ['剧情'],
    );
    build(
      change(
        (w) => w.copyWith(
          category: MediaCategory.anime,
          genres: const ['动画'],
          source: ScrapeSource.online,
        ),
      ),
    );

    // 用户在「动漫」栏里。刮削前这部还是「剧集」，不该出现在这一栏里。
    container
        .read(libraryFilterProvider.notifier)
        .setCategory(MediaCategory.anime);
    expect(await container.read(yearCountsProvider.future), isEmpty);

    await scrape('w');

    expect(
      await container.read(yearCountsProvider.future),
      {2015: 1},
      reason: '键是**具体年份**（2015）。`year` 一个字都没变（2015 → 2015），'
          '只按「年份变了没」判重算的话这个 provider 会一直返回缓存里的空表'
          '—— 用户看到的是「动漫栏里明明有一部 2015 年的片子，筛选面板里却'
          '没有 2015」。',
    );
  });

  test('分类变了、类型列表没变 → 类型角标同样要重算', () async {
    build(
      change(
        (w) => w.copyWith(
          category: MediaCategory.anime,
          source: ScrapeSource.online,
        ),
      ),
    );

    // ⚠️ 顺序很关键：**先让回填跑过一次**（此时库还是空的），再写这一行。
    //
    // `categoryBackfillProvider` 会把「`genres` 已是『动画』、`category` 还
    // 停在『剧集』」这种自相矛盾的行**提前修好** —— 那样一来下面这个场景就
    // 复现不出来了。而回填**每次开库只跑一次**，之后才被读到的行它管不到，
    // 所以这个分支不是死代码。
    await container.read(categoryBackfillProvider.future);

    await seed(
      key: 'w',
      kind: 'episode',
      title: '某动画',
      category: 'series',
      year: 2015,
      genres: const ['动画'],
    );

    container
        .read(libraryFilterProvider.notifier)
        .setCategory(MediaCategory.series);
    expect(await container.read(genreCountsProvider.future), {'动画': 1});

    await scrape('w');

    expect(
      await container.read(genreCountsProvider.future),
      isEmpty,
      reason: '这一部已经离开「剧集」栏了。这里 `genres` **逐字没变**'
          '（`["动画"]` → `["动画"]`），所以「按集合比类型」那条判据盖不住 ——'
          '不作废的话「剧集」栏里会一直挂着一个根本不存在的「动画」类型。',
    );
  });

  test('只有类型的顺序变了 → 两组角标都不重算', () async {
    await seed(
      key: 'w',
      kind: 'episode',
      title: '某剧',
      category: 'series',
      year: 2015,
      genres: const ['剧情', '喜剧'],
    );
    // 同一组类型、只是顺序换了 —— 数据源返回顺序本来就不稳定。
    build(
      change(
        (w) => w.copyWith(
          genres: const ['喜剧', '剧情'],
          source: ScrapeSource.online,
        ),
      ),
    );

    await container.read(yearCountsProvider.future);
    await container.read(genreCountsProvider.future);
    expect(repo.yearCalls, 1);
    expect(repo.genreCalls, 1);

    await scrape('w');

    await container.read(yearCountsProvider.future);
    await container.read(genreCountsProvider.future);
    expect(
      repo.yearCalls,
      1,
      reason: '年份没变，不该白跑一次全表扫描。',
    );
    expect(
      repo.genreCalls,
      1,
      reason: '顺序变了不代表内容变了。这里如果按列表 `==` 判（而不是按集合），'
          '每刮一次都会多跑一次统计 —— 而两次刮削之间用户什么都看不出来。',
    );
  });

  test('只有年份变了 → 年份角标重算，类型角标不动', () async {
    await seed(
      key: 'w',
      kind: 'episode',
      title: '某剧',
      category: 'series',
      year: 2015,
      genres: const ['剧情'],
    );
    build(change((w) => w.copyWith(year: 2021, source: ScrapeSource.online)));

    await container.read(yearCountsProvider.future);
    await container.read(genreCountsProvider.future);
    expect(repo.yearCalls, 1);
    expect(repo.genreCalls, 1);

    await scrape('w');

    expect(await container.read(yearCountsProvider.future), {2021: 1});
    expect(repo.yearCalls, 2);
    await container.read(genreCountsProvider.future);
    expect(
      repo.genreCalls,
      1,
      reason: '类型没变 —— 这条与上一条合起来钉住「两个维度各自独立判重算」，'
          '而不是「只要刮削成功就把两组都作废」。',
    );
  });
}

/// 会数调用次数的真仓储。
///
/// 「不该重算」这件事没有可观察的返回值（重算了也得出同样的数字），
/// 只能数**查询跑了几次** —— 而这两次统计是各一次全表扫描，白跑是有代价的。
class _CountingRepo extends DriftMediaRepository {
  _CountingRepo(super.db);

  int yearCalls = 0;
  int genreCalls = 0;

  @override
  Future<Map<int, int>> countWorksByYear({
    MediaCategory? category,
    bool playedOnly = false,
    bool followedOnly = false,
    bool scrapedOnly = false,
    String? query,
  }) {
    yearCalls++;
    return super.countWorksByYear(
      category: category,
      playedOnly: playedOnly,
      followedOnly: followedOnly,
      scrapedOnly: scrapedOnly,
      query: query,
    );
  }

  @override
  Future<Map<String, int>> countWorksByGenre({
    MediaCategory? category,
    bool playedOnly = false,
    bool followedOnly = false,
    bool scrapedOnly = false,
    String? query,
  }) {
    genreCalls++;
    return super.countWorksByGenre(
      category: category,
      playedOnly: playedOnly,
      followedOnly: followedOnly,
      scrapedOnly: scrapedOnly,
      query: query,
    );
  }
}

/// 一个**脚本化**的刮削器：只产出「刮削后那一行」，不碰仓储。
///
/// 继承真 `WorkScraper` 而不是另造一个接口，是为了让 `workScraperProvider`
/// 的类型不用动 —— 被验的是它下游的 `_refreshAfter`，上游刮削逻辑由
/// `work_scraper_test.dart` 单独覆盖。落库交给 [transform]（见 `change`）。
class _ScriptedScraper extends WorkScraper {
  _ScriptedScraper({
    required super.library,
    required super.pipeline,
    required this.transform,
  });

  final Future<MediaWork> Function(MediaWork before) transform;

  @override
  Future<WorkScrapeOutcome> scrape(MediaWork work) async {
    final after = await transform(work);
    return WorkScrapeOutcome(
      status: WorkScrapeStatus.scraped,
      channel: ScrapeChannel.auto,
      work: after,
      metadata: ScrapedMetadata(
        title: after.title,
        year: after.year,
        genres: after.genres,
      ),
    );
  }
}
