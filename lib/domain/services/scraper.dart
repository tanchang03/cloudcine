import '../../core/diagnostics/diag_log.dart';
import '../entities/media_work.dart';

/// 元数据刮削器契约。
///
/// 实现方可以是离线的（文件名解析）或在线的（TMDB）。上层只认这个接口，
/// 因此「换一个数据源」不需要动扫描器一行代码。
abstract class MetadataScraper {
  /// 稳定标识，用于日志与「当前用的是哪个源」
  String get id;

  /// 展示名
  String get displayName;

  /// 是否可用（在线刮削要检查 API Key 有没有配）。
  ///
  /// **不可用时必须返回 `false` 而不是抛异常** —— 扫描器据此跳过它，
  /// 让整次刮削降级而不是失败。
  bool get isEnabled;

  /// 刮一条。**失败返回 `null`，不抛异常。**
  ///
  /// 这个契约很重要：一部片子刮不到不该让整次扫描中断，而网络抖动、
  /// API 限流、条目不存在都属于「刮不到」。
  Future<ScrapedMetadata?> scrape(ScrapeQuery query);
}

/// 文件名刮削器 —— **永远可用的那一层**。
///
/// 它不做任何网络请求，只是把 `MediaFilenameParser` 的结果包装成
/// [ScrapedMetadata]。存在的意义是让「刮削」这条链路**在任何情况下
/// 都有输出**：没有 API Key、断网、API 挂了，媒体库照样有标题、年份、
/// 季集、分辨率，而不是一片空白。
///
/// 这也是为什么它必须排在在线刮削器**之后**作为兜底，而不是之前 ——
/// 在线的信息更全（有简介和海报），但没它也能活。
class LocalFilenameScraper implements MetadataScraper {
  const LocalFilenameScraper();

  @override
  String get id => 'local';

  @override
  String get displayName => '文件名解析';

  @override
  bool get isEnabled => true;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async {
    final title = query.title.trim();
    if (title.isEmpty) return null;
    return ScrapedMetadata(
      title: title,
      year: query.year,
      source: ScrapeSource.local,
      matchedQuery: title,
    );
  }
}

/// 刮削流水线：**按顺序尝试，第一个成功的胜出**。
///
/// 顺序即优先级。典型配置是 `[TmdbScraper, LocalFilenameScraper]`：
/// 先试在线（信息全），失败就退到本地（永远有）。
///
/// ⚠️ 本地刮削器必须**放在最后**。放在前面的话它永远成功，在线的
/// 那个就再也轮不到了 —— 媒体库里会全是「只有标题和年份」的条目。
class ScraperPipeline {
  ScraperPipeline(this.scrapers);

  /// 按优先级排列的刮削器。
  final List<MetadataScraper> scrapers;

  /// 走一遍流水线。**永不返回 `null`**（除非连片名都没有）。
  ///
  /// 返回结果里带上 `matchedQuery`，便于排查「刮错了片子」——
  /// 很多时候是片名解析错了，而不是刮削器错了。
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async {
    for (final s in scrapers) {
      if (!s.isEnabled) {
        diag.debug('刮削', '跳过 ${s.id}（未启用）');
        continue;
      }
      try {
        final result = await s.scrape(query);
        if (result != null) {
          diag.info(
            '刮削',
            '${s.id} 命中：$query → "${result.title}"'
            '${result.year == null ? "" : " (${result.year})"}',
          );
          return result;
        }
        diag.info('刮削', '${s.id} 未命中：$query');
      } catch (e) {
        // 单个刮削器抛异常（网络库没兜住、解析崩了）不该中断流水线
        diag.warn('刮削', '${s.id} 抛出异常，继续下一个', error: e);
      }
    }
    return null;
  }
}
