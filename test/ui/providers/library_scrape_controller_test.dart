import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:cloudcine/domain/services/work_scraper.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:cloudcine/ui/providers/library_refresh_providers.dart';
import 'package:cloudcine/ui/providers/scrape_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 媒体库页的「刮削媒体库」——**批量**刮削。
///
/// ## 为什么值得一个文件
///
/// 这条链路有三件事做错了都**不报错**，只表现为「用户觉得功能坏了」：
///
///   1. **刮了不该刮的**：`source == manual` 的行是用户点过「自定义」、亲手
///      敲的片名 / 分类。批量通道若沿用 `WorkScraper.scrape` 的
///      `overrideManual: true`，会把它们**一次性冲掉**——而用户只是点了一下
///      「刮削媒体库」；
///   2. **列表不刷新**：用户要的正是「一个一个刮削成功」的动态感。若只在整批
///      跑完才刷一次，屏幕上就是几十秒纹丝不动，然后一次性全变；
///   3. **计数对不上**：按钮上的数字与真正会刮的条数必须来自**同一个筛法**，
///      否则会出现「写着 128、进度跑到 130」。
void main() {
  final now = DateTime(2026, 10, 4);

  late AppDatabase db;
  late _CountingRepo repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = _CountingRepo(db);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer build(List<Override> overrides) {
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    return c;
  }

  /// 直接写一行作品（走 `MediaWorksCompanion.insert`，才能造出
  /// `source` / `mergedInto` 各异的行）。
  Future<void> seed({
    required String key,
    required String title,
    String source = 'local',
    String? mergedInto,
  }) async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: key,
            provider: DriveProvider.quark.id,
            kind: 'movie',
            title: title,
            source: source,
            mergedInto: Value(mergedInto),
            updatedAt: now,
          ),
        );
  }

  /// 一个脚本化的刮削器：记录被刮过哪些 key，并按 [onScrape] 返回结果。
  ///
  /// 继承真 `WorkScraper` 是为了让 `workScraperProvider` 的类型不用动 ——
  /// 被验的是它**外面**的批量循环与刷新，单部刮削逻辑由
  /// `work_scraper_test.dart` 覆盖。
  _ScriptedScraper scripted(
    Future<WorkScrapeOutcome> Function(MediaWork work) onScrape,
  ) =>
      _ScriptedScraper(
        library: repo,
        pipeline: ScraperPipeline(const []),
        onScrape: onScrape,
      );

  /// 在线命中：改 `source` 落库，返回 scraped。
  Future<WorkScrapeOutcome> hit(MediaWork work) async {
    final updated = work.copyWith(source: ScrapeSource.online);
    await repo.upsertWorks([updated]);
    return WorkScrapeOutcome(
      status: WorkScrapeStatus.scraped,
      channel: ScrapeChannel.auto,
      work: updated,
      metadata: ScrapedMetadata(title: updated.title),
    );
  }

  test('只刮 source==local 的作品：跳过已刮削 / 自定义 / 被折叠走的', () async {
    await seed(key: 'a', title: '待刮甲');
    await seed(key: 'b', title: '待刮乙');
    await seed(key: 'c', title: '已刮过', source: 'online');
    await seed(key: 'd', title: '用户自定义', source: 'manual');
    // e 被折叠进 a：它的文件已经算在 a 名下，不该再单独刮一次。
    await seed(key: 'e', title: '别名行', mergedInto: 'a');

    final scraper = scripted(hit);
    final container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
      workScraperProvider.overrideWith((ref) => scraper),
    ]);

    await container.read(libraryScrapeControllerProvider.notifier).start();

    expect(
      scraper.calls..sort(),
      ['a', 'b'],
      reason: '只有 local 且未折叠的两行该被刮。`manual` 那一行是用户亲手敲的'
          '片名与分类 —— 批量通道碰它就是把「我明明改过的片子」冲回在线结果，'
          '而且不报错。',
    );

    final state = container.read(libraryScrapeControllerProvider);
    expect(state.finished, isTrue);
    expect(state.total, 2);
    expect(state.done, 2);
    expect(state.scraped, 2);
    expect(state.missed, 0);
  });

  test('每刮完一部推一次列表信号（列表实时刷新）', () async {
    for (final k in ['a', 'b', 'c']) {
      await seed(key: k, title: '片$k');
    }

    final scraper = scripted(hit);
    final container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
      workScraperProvider.overrideWith((ref) => scraper),
    ]);

    // 先订阅，信号才会被推给我们。
    var bumps = 0;
    container.listen(libraryListSignalProvider, (_, __) => bumps++);
    final progress = <int>[];
    container.listen(libraryScrapeControllerProvider, (_, next) {
      if (next.running) progress.add(next.done);
    });

    await container.read(libraryScrapeControllerProvider.notifier).start();

    expect(
      bumps,
      3,
      reason: '3 部 → 3 次列表刷新。只在整批结束时刷一次的话，用户盯着屏幕'
          '几十秒纹丝不动，然后一次性全变 —— 而「一个一个刮削成功」正是'
          '这个功能要给的体验。',
    );
    expect(progress, containsAllInOrder([1, 2, 3]));
  });

  test('未命中计入 missed，且不阻断后面的作品', () async {
    await seed(key: 'a', title: '甲');
    await seed(key: 'b', title: '乙');
    await seed(key: 'c', title: '丙');

    final scraper = scripted((work) async {
      if (work.key == 'b') {
        return const WorkScrapeOutcome(
          status: WorkScrapeStatus.notFound,
          channel: ScrapeChannel.auto,
        );
      }
      return hit(work);
    });
    final container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
      workScraperProvider.overrideWith((ref) => scraper),
    ]);

    await container.read(libraryScrapeControllerProvider.notifier).start();

    expect(scraper.calls, ['a', 'b', 'c']);
    final state = container.read(libraryScrapeControllerProvider);
    expect(state.scraped, 2);
    expect(state.missed, 1);
    expect(state.done, 3);
  });

  test('停止后不再刮后面的作品', () async {
    for (final k in ['a', 'b', 'c']) {
      await seed(key: k, title: '片$k');
    }

    late ProviderContainer container;
    final scraper = scripted((work) async {
      if (work.key == 'a') {
        // 用户在第一部跑完时按了「停止」。
        container.read(libraryScrapeControllerProvider.notifier).cancel();
      }
      return hit(work);
    });
    container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
      workScraperProvider.overrideWith((ref) => scraper),
    ]);

    await container.read(libraryScrapeControllerProvider.notifier).start();

    expect(scraper.calls, ['a'], reason: '协作式停止：当前这一部跑完就收手。');
    final state = container.read(libraryScrapeControllerProvider);
    expect(state.cancelRequested, isTrue);
    expect(state.finished, isTrue);
    expect(state.done, 1);
  });

  test('没有未刮削的作品时不发任何请求，直接结束', () async {
    await seed(key: 'c', title: '已刮过', source: 'online');

    final scraper = scripted(hit);
    final container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
      workScraperProvider.overrideWith((ref) => scraper),
    ]);

    await container.read(libraryScrapeControllerProvider.notifier).start();

    expect(scraper.calls, isEmpty);
    final state = container.read(libraryScrapeControllerProvider);
    expect(state.finished, isTrue);
    expect(state.total, 0);
    expect(state.running, isFalse);
  });

  test('刮完之后「还有多少部没刮过」归零', () async {
    await seed(key: 'a', title: '甲');
    await seed(key: 'b', title: '乙');

    final scraper = scripted(hit);
    final container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
      workScraperProvider.overrideWith((ref) => scraper),
    ]);

    expect(await container.read(unscrapedCountProvider.future), 2);

    await container.read(libraryScrapeControllerProvider.notifier).start();

    expect(
      await container.read(unscrapedCountProvider.future),
      0,
      reason: '按钮上的数字与进度必须对得上：刮完就该是 0。',
    );
  });

  test('库信号一推，媒体库列表就重取一次', () async {
    await seed(key: 'a', title: '甲');
    final container = build([
      mediaRepositoryProvider.overrideWithValue(repo),
    ]);

    await container.read(workListProvider.future);
    final before = repo.listCalls;

    container.read(libraryListSignalProvider.notifier).bump();
    await container.read(workListProvider.future);

    expect(
      repo.listCalls,
      before + 1,
      reason: '`workListProvider` 必须 watch 列表信号 —— 不 watch 的话，'
          '扫描与批量刮削期间推的信号没人接，列表一直停在旧数据上。',
    );
  });
}

/// 会数 `listWorks` 调用次数的真仓储。
///
/// 「列表有没有重取」没有可观察的返回值（重取了也得出同样的行），只能数
/// 查询跑了几次。
class _CountingRepo extends DriftMediaRepository {
  _CountingRepo(super.db);

  int listCalls = 0;

  @override
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
    Set<int>? years,
    Set<String>? genres,
    WorkSort sort = WorkSort.recentModified,
    int limit = 200,
    int offset = 0,
  }) {
    listCalls++;
    return super.listWorks(
      kind: kind,
      category: category,
      playedOnly: playedOnly,
      scrapedOnly: scrapedOnly,
      query: query,
      years: years,
      genres: genres,
      sort: sort,
      limit: limit,
      offset: offset,
    );
  }
}

/// 脚本化的刮削器。见 [main] 里 `scripted` 的说明。
class _ScriptedScraper extends WorkScraper {
  _ScriptedScraper({
    required super.library,
    required super.pipeline,
    required this.onScrape,
  });

  final Future<WorkScrapeOutcome> Function(MediaWork work) onScrape;
  final List<String> calls = [];

  @override
  Future<WorkScrapeOutcome> scrape(MediaWork work) async {
    calls.add(work.key);
    return onScrape(work);
  }
}
