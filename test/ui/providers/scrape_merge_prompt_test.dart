import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:cloudcine/domain/services/work_scraper.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/scrape_providers.dart';
import 'package:cloudcine/ui/providers/settings_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 刮削完成之后那句「库里是不是已经有同一部了」。
///
/// ## 为什么值得一个文件
///
/// 手动刮削最常见的用法就是「同一部片子被扫成了两个格子」——用户在一部的
/// 详情页里刮削，把它刮到和另一部**同一条目**。这时有两件事要发生：
///
///   1. 开着「自动归一同一部影片」（默认开）→ 直接合上；
///   2. **没开**的时候 → 以前什么都不说。用户刚手动刮完、库里明明早就有
///      同一部，却一个字都没被告知，只能自己发现列表里有两个一样的格子。
///
/// 这里钉住两条路各自的文案，以及「库里没有同一部时**不加噪音**」。
///
/// ## 为什么用内存库
///
/// 被验的是控制器「拼哪句话」，与 SQL 无关；归一的落库语义由
/// `work_merge_service_test.dart` / `work_merge_test.dart` 单独覆盖。
void main() {
  final now = DateTime(2026, 10, 2);

  MediaWork work({
    required String key,
    required String title,
    String? onlineId,
    ScrapeSource source = ScrapeSource.local,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        category: MediaCategory.movie,
        onlineId: onlineId,
        source: source,
        itemCount: 1,
        firstSeenAt: now,
        updatedAt: now,
      );

  late AppDatabase settingsDb;
  late SettingsStore store;
  late InMemoryMediaRepository repo;
  late ProviderContainer container;

  setUp(() {
    settingsDb = AppDatabase.memory();
    store = SettingsStore(settingsDb);
    repo = InMemoryMediaRepository();
  });

  tearDown(() async {
    container.dispose();
    await settingsDb.close();
  });

  /// 建容器：真设置存储（内存库）+ 内存媒体库 + 脚本化刮削器。
  ///
  /// [autoMerge] 写进设置存储 —— 控制器读的是 `settingsProvider`，
  /// 而它又是从 `settingsStoreProvider` 建的，这样才和真机上「用户此刻的
  /// 设置」同一条路径。
  Future<void> build({required bool autoMerge, String onlineId = 'movie/1'}) async {
    await store.write(
      SettingKeys.autoMergeByOnlineId,
      autoMerge ? 'true' : 'false',
    );
    container = ProviderContainer(
      overrides: [
        mediaRepositoryProvider.overrideWithValue(repo),
        settingsStoreProvider.overrideWithValue(store),
        workScraperProvider.overrideWith(
          (ref) => _ScriptedScraper(
            library: repo,
            pipeline: ScraperPipeline(const []),
            repo: repo,
            onlineId: onlineId,
            at: now,
          ),
        ),
      ],
    );
    // 设置是异步读的：不等它落地，控制器里 `valueOrNull` 会是 null
    // （→ 当成「关」），用例就会假红。
    await container.read(settingsProvider.future);
  }

  /// 走手动通道刮 [key]。
  Future<String?> scrape(String key) async {
    final outcome = await container
        .read(workScrapeControllerProvider.notifier)
        .applyCandidate(
          key,
          const ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '流浪地球2'),
        );
    expect(outcome, isNotNull, reason: '作品在库里，这一条该跑起来。');
    return container.read(workScrapeControllerProvider).messageFor(key);
  }

  test('开着自动归一 → 直接合上，文案说清并进了哪一部', () async {
    await repo.upsertWorks([
      work(key: 'a', title: '流浪地球2', onlineId: 'movie/1', source: ScrapeSource.online),
      work(key: 'b', title: 'The Wandering Earth II'),
    ], now: now);
    await build(autoMerge: true);

    final message = await scrape('b');

    expect(
      (await repo.workByKey('b'))?.mergedInto,
      'a',
      reason: '刮到同一条目 → 折进文件多的那一部（这里 a 是目标）。',
    );
    expect(
      message,
      contains('并入《流浪地球2》'),
      reason: '用户刚点了「用这一条更新」，得当场看到「它被并到哪去了」——'
          '否则列表里少一个格子会让他以为文件丢了。',
    );
    expect(message, contains('识别为同一条目'));
  });

  test('关掉自动归一 → 不合，但必须提示「库里已经有同一部」', () async {
    await repo.upsertWorks([
      work(key: 'a', title: '流浪地球2', onlineId: 'movie/1', source: ScrapeSource.online),
      work(key: 'b', title: 'The Wandering Earth II'),
    ], now: now);
    await build(autoMerge: false);

    final message = await scrape('b');

    expect(
      (await repo.workByKey('b'))?.mergedInto,
      isNull,
      reason: '用户关掉了自动归一 —— 算法不许擅自合并。',
    );
    expect(
      message,
      contains('媒体库里已经有同一部《流浪地球2》'),
      reason: '这就是这次新加的那句话：以前关掉开关时用户什么都看不到，'
          '而他刚手动刮完、库里明明早就有同一部。',
    );
    expect(
      message,
      contains('合并到…'),
      reason: '提示必须给出下一步 —— 只说「已经有一部」而不说怎么合，'
          '用户还是得自己摸。',
    );
  });

  test('库里没有同一部 → 一句话都不多加（别给常见情况加噪音）', () async {
    await repo.upsertWorks([
      work(key: 'a', title: '别的片子', onlineId: 'movie/999', source: ScrapeSource.online),
      work(key: 'b', title: 'The Wandering Earth II'),
    ], now: now);
    await build(autoMerge: true);

    final message = await scrape('b');

    expect(message, contains('已刮削：流浪地球2'));
    expect(message, isNot(contains('媒体库里已经有同一部')));
    expect(message, isNot(contains('并入')));
  });
}

/// 脚本化的刮削器：`applyCandidate` 把作品改写成「刮到了 [onlineId]」并落库。
///
/// 继承真 `WorkScraper` 而不是另造接口，是为了让 `workScraperProvider` 的
/// 类型不用动 —— 被验的是控制器拼的那句话，真正的刮削逻辑由
/// `work_scraper_test.dart` 覆盖。
class _ScriptedScraper extends WorkScraper {
  _ScriptedScraper({
    required super.library,
    required super.pipeline,
    required this.repo,
    required this.onlineId,
    required this.at,
  });

  final MediaRepository repo;
  final String onlineId;
  final DateTime at;

  @override
  Future<WorkScrapeOutcome> applyCandidate(
    MediaWork work,
    ScrapeCandidate candidate, {
    MediaCategory? category,
  }) async {
    final after = work.copyWith(
      title: candidate.title,
      onlineId: onlineId,
      source: ScrapeSource.online,
      scrapedAt: at,
      updatedAt: at,
    );
    await repo.upsertWorks([after], now: at);
    return WorkScrapeOutcome(
      status: WorkScrapeStatus.scraped,
      channel: ScrapeChannel.manual,
      work: after,
      metadata: ScrapedMetadata(title: candidate.title, onlineId: onlineId),
      sourceName: 'TMDB',
    );
  }
}
