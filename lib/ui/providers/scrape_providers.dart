import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/scrape/douban_client.dart';
import '../../data/scrape/tmdb_client.dart';
import '../../domain/services/scraper.dart';
import '../../domain/services/work_scraper.dart';
import 'app_providers.dart';
import 'library_providers.dart';
import 'settings_providers.dart';

/// 在线刮削的**源配置**（只包含影响「用哪些源、打哪个地址」的那几项）。
///
/// ## 为什么要单独抽一个值对象
///
/// [scraperPipelineProvider] 必须**长期存活**：`TmdbScraper` 的熔断计数、
/// `DoubanScraper` 的节流与 `103` 熔断都挂在实例上。如果直接
/// `ref.watch(settingsProvider)`，那么用户**调一次音量**都会重建流水线，
/// 把刚积累起来的熔断状态清空 —— 表现是「设置页动一下，豆瓣又开始打请求」。
///
/// 抽成带 `==` 的值对象之后，只有真正相关的设置变了才会重建。
class ScrapeSources {
  const ScrapeSources({
    this.tmdbApiKey = '',
    this.tmdbApiBase = TmdbScraper.defaultBaseUrl,
    this.tmdbImageBase = TmdbScraper.defaultImageBaseUrl,
    this.doubanCookie = '',
  });

  final String tmdbApiKey;
  final String tmdbApiBase;
  final String tmdbImageBase;
  final String doubanCookie;

  bool get hasTmdb => tmdbApiKey.isNotEmpty;
  bool get hasDouban => doubanCookie.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ScrapeSources &&
      other.tmdbApiKey == tmdbApiKey &&
      other.tmdbApiBase == tmdbApiBase &&
      other.tmdbImageBase == tmdbImageBase &&
      other.doubanCookie == doubanCookie;

  @override
  int get hashCode =>
      Object.hash(tmdbApiKey, tmdbApiBase, tmdbImageBase, doubanCookie);
}

final scrapeSourcesProvider = Provider<ScrapeSources>((ref) {
  final s = ref.watch(settingsProvider).valueOrNull;
  return ScrapeSources(
    tmdbApiKey: s?.tmdbApiKey.trim() ?? '',
    // 「留空 = 用官方地址」在这里换算，默认值只保留 `TmdbScraper` 一个真源。
    tmdbApiBase: _orDefault(s?.tmdbApiBase, TmdbScraper.defaultBaseUrl),
    tmdbImageBase: _orDefault(
      s?.tmdbImageBase,
      TmdbScraper.defaultImageBaseUrl,
    ),
    doubanCookie: s?.doubanCookie.trim() ?? '',
  );
});

/// 在线刮削的流水线。**长期存活**，见 [ScrapeSources] 的文档。
///
/// 顺序即优先级，最后一个是兜底：
///
///   1. **TMDB** —— 元数据最全（有简介、有类型、有原始标题），是首选；
///   2. **豆瓣** —— 补 TMDB 最弱的一块：国产剧 / 国漫 / 综艺，且境内可达；
///   3. **本地文件名解析** —— 永远成功，所以**必须排最后**（见 [ScraperPipeline]）。
///
/// ⚠️ 顺序别改。把豆瓣排到 TMDB 前面会让「先简单：TMDB 优先」这个决定失效，
/// 而且豆瓣的额度小得多，优先烧它没有道理。
final scraperPipelineProvider = Provider<ScraperPipeline>((ref) {
  final src = ref.watch(scrapeSourcesProvider);
  final http = ref.watch(httpClientProvider);

  return ScraperPipeline(<MetadataScraper>[
    if (src.hasTmdb)
      TmdbScraper(
        http: http,
        apiKey: src.tmdbApiKey,
        baseUrl: src.tmdbApiBase,
        imageBaseUrl: src.tmdbImageBase,
      ),
    if (src.hasDouban)
      DoubanScraper(http: http, cookie: src.doubanCookie),
    const LocalFilenameScraper(),
  ]);
});

/// 单部作品的按需刮削。
final workScraperProvider = Provider<WorkScraper>(
  (ref) => WorkScraper(
    library: ref.watch(mediaRepositoryProvider),
    pipeline: ref.watch(scraperPipelineProvider),
  ),
);

/// 详情页「刮削」按钮的状态。
class WorkScrapeState {
  const WorkScrapeState({
    this.runningKey,
    this.messageKey,
    this.message,
    this.ok = false,
  });

  /// 正在刮哪一部（`null` = 空闲）。同一时刻只允许一个。
  final String? runningKey;

  /// 下面这条消息属于哪一部作品。
  ///
  /// 带上作品键而不是全局一条消息：用户刮完 A 又去看 B 时，B 的页面上
  /// 不该还挂着 A 的结果。
  final String? messageKey;

  final String? message;
  final bool ok;

  bool isRunning(String workKey) => runningKey == workKey;

  String? messageFor(String workKey) =>
      messageKey == workKey ? message : null;

  bool okFor(String workKey) => messageKey == workKey && ok;
}

/// 「刮削」按钮的控制器。
///
/// 只做三件事：**发请求、给结果文案、刷新受影响的列表**。真正的刮削逻辑在
/// [WorkScraper]（无 UI 依赖，可单测）。
class WorkScrapeController extends Notifier<WorkScrapeState> {
  @override
  WorkScrapeState build() => const WorkScrapeState();

  Future<void> scrape(String workKey) async {
    if (state.runningKey != null) return;
    state = WorkScrapeState(runningKey: workKey);

    try {
      final work = await ref.read(mediaRepositoryProvider).workByKey(workKey);
      if (work == null) {
        state = WorkScrapeState(
          messageKey: workKey,
          message: '找不到这部作品，它可能已经被重新扫描移除。',
        );
        return;
      }

      final outcome = await ref.read(workScraperProvider).scrape(work);
      final ok = outcome.status == WorkScrapeStatus.scraped;
      state = WorkScrapeState(
        messageKey: workKey,
        message: outcome.message,
        ok: ok,
      );

      if (ok) {
        // 详情页要重画（新标题/海报/简介），海报墙也要 —— 否则退回列表
        // 还是旧卡片，用户会以为刮削没生效。
        ref.invalidate(workDetailProvider(workKey));
        ref.invalidate(workListProvider);
      }
    } catch (e) {
      state = WorkScrapeState(
        messageKey: workKey,
        message: '刮削失败：$e',
      );
    }
  }
}

final workScrapeControllerProvider =
    NotifierProvider<WorkScrapeController, WorkScrapeState>(
  WorkScrapeController.new,
);

/// 设置里的地址留空时回退到默认值。
String _orDefault(String? raw, String fallback) {
  final v = (raw ?? '').trim();
  return v.isEmpty ? fallback : v;
}
