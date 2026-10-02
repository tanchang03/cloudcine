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

  /// 按关键词搜一批候选，供**用户手动挑选**。
  ///
  /// 与 [scrape] 的关键差别：这里**不做匹配校验、也不自动选第一条** ——
  /// 用户要看到尽可能多的候选自己点。返回空列表表示「这个源给不出候选」
  /// （离线源本来就没有），而不是「搜索失败」。
  ///
  /// ⚠️ 这里有默认实现，但**它只对 `extends` 生效**。本项目所有实现都是
  /// `implements MetadataScraper`（见 `TmdbScraper` / `DoubanScraper` /
  /// `LocalFilenameScraper`），而 `implements` **不继承任何实现体** ——
  /// 新增一个带默认实现的方法，会让所有 `implements` 方**编译失败**。
  /// 所以这两个方法（以及 [resolve]）在离线源和测试假实现里都要显式补上。
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async => const [];

  /// 把用户选中的候选解析成完整元数据。取不到返回 `null`。
  ///
  /// 为什么不能直接用候选里的字段：豆瓣的搜索结果里既没有完整海报也没有
  /// 简介，必须再打一次详情接口。TMDB 的搜索结果倒是够全，但类型名也要
  /// 走一次缓存的类型表 —— 所以统一成「选中之后再解析」。
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async => null;
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
///
/// ⚠️ 「排最后」不是建议而是**契约**：[ScraperPipeline] 把列表的**最后一个**
/// 当作兜底、不参与并发竞速。把它放到前面，它会立刻返回并赢下每一次刮削，
/// 在线源连一次机会都没有。`scraper_pipeline_test.dart` 里有一条回归测试
/// 专门钉这件事。
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

  /// 离线源给不出候选 —— 它的「候选」就是文件名解析结果本身，
  /// 而那是详情页里直接可改的字段，没必要再走一遍候选列表。
  ///
  /// ⚠️ 必须显式写出来：`implements` 不继承 [MetadataScraper] 的默认实现。
  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async => const [];

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async => null;
}

/// 刮削流水线：**按优先级并发尝试，优先级最高的那个成功者胜出**。
///
/// ## 两种源的两种跑法
///
/// 列表按优先级排列，例如 `[TmdbScraper, DoubanScraper, LocalFilenameScraper]`。
/// 最后一个是**兜底**，前面几个是**竞速者**，两类跑法不同：
///
///   - **竞速者同时起跑**（都在同一个事件循环里发出请求），但结果**按优先级
///     取**：先等高优先级那个的结论，它成功就用它；它失败才看下一个 ——
///     而那时下一个多半早就返回了，所以只多花「取结果」的时间，不多花网络时间。
///     这样既拿到了并发的延迟收益，又保住了「TMDB 优先」这条排序语义。
///   - **兜底不参与竞速**。本地文件名解析永远成功、而且几乎瞬时返回，
///     让它参赛的话它会永远赢，在线源一次都轮不到 —— 媒体库里会全是
///     「只有标题和年份」的条目。所以它只在竞速者**全部**失败后才跑。
///
/// ## 代价（已知并接受）
///
/// 低优先级的源即使结果用不上，请求也已经发出去了。对 TMDB 无所谓，
/// 对**豆瓣**则是实打实的额度消耗（匿名约 10 个搜索词）。当前接受这个代价：
/// 豆瓣的搜索现在只由「详情页的刮削按钮」按需触发，量很小。
/// 如果将来放开批量刮削导致额度不够，把 [scrape] 里的
/// `Future.wait` 改成串行 await 即可 —— 上面的分流逻辑不用动。
class ScraperPipeline {
  ScraperPipeline(List<MetadataScraper> scrapers)
      : scrapers = List<MetadataScraper>.unmodifiable(scrapers);

  /// 按优先级排列的刮削器。**最后一个是兜底。**
  final List<MetadataScraper> scrapers;

  /// 走一遍流水线。**永不返回 `null`**（除非连片名都没有）。
  ///
  /// 返回结果里带上 `matchedQuery`，便于排查「刮错了片子」——
  /// 很多时候是片名解析错了，而不是刮削器错了。
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async {
    if (scrapers.isEmpty) return null;

    // 只有一条时它就是兜底 —— 不能既当竞速者又当兜底，
    // 否则「本地永远赢」那个坑会从另一条路回来。
    final contenders = scrapers.length <= 1
        ? const <MetadataScraper>[]
        : scrapers.sublist(0, scrapers.length - 1);
    final fallback = scrapers.last;

    final enabled = <MetadataScraper>[];
    for (final s in contenders) {
      if (s.isEnabled) {
        enabled.add(s);
      } else {
        diag.debug('刮削', '跳过 ${s.id}（未启用）');
      }
    }

    if (enabled.isNotEmpty) {
      // 同时起跑。**必须一次性建完所有 future**：写成 `await` 循环就退化成
      // 串行了，而这个方法的全部意义就在于并发。
      final futures = <Future<ScrapedMetadata?>>[
        for (final s in enabled) _attempt(s, query),
      ];

      // 再按优先级依次取结果。
      for (var i = 0; i < futures.length; i++) {
        final result = await futures[i];
        if (result != null) {
          diag.info(
            '刮削',
            '${enabled[i].id} 命中：$query → "${result.title}"'
            '${result.year == null ? "" : " (${result.year})"}',
          );
          return result;
        }
      }
    }

    if (!fallback.isEnabled) {
      diag.debug('刮削', '跳过 ${fallback.id}（未启用）');
      return null;
    }
    return _attempt(fallback, query);
  }

  /// 当前可做手动搜索的源（已启用且**能出候选**的）。
  ///
  /// 排除本地兜底 —— 它没有 `search` 能力（永远返回空列表）。UI 用这个
  /// 在手动对话框里渲染「选哪个源」的选择器。
  List<({String id, String displayName})> get availableSources => [
        for (final s in scrapers)
          if (s.isEnabled && s.id != 'local')
            (id: s.id, displayName: s.displayName),
      ];

  /// 按 id 查展示名。找不到返回 `null` —— UI 那边用 `?? source` 兜底，
  /// 而不是把原始 id 贴到用户可见的文案里。
  String? displayNameOf(String sourceId) {
    for (final s in scrapers) {
      if (s.id == sourceId) return s.displayName;
    }
    return null;
  }

  /// 向所有启用的源要候选，**按源的优先级拼接**，一个都不丢。
  ///
  /// 与 [scrape] 的跑法刻意不同：那个是「并发起跑、按优先级取第一个成功的」，
  /// 因为自动刮削只需要一个答案；这里是「用户要自己挑」，所以必须把
  /// 每个源的候选都给出来。串行而不是并发，是因为豆瓣的额度按搜索词计，
  /// 没必要为了省几百毫秒让它和 TMDB 抢跑 —— 手动刮削一次点一下，量很小。
  ///
  /// [sourceId] 非空时只搜那一个源 —— 用户在手动对话框里选了「只在豆瓣搜」
  /// 时，没必要把 TMDB 的额度也花掉。
  Future<List<ScrapeCandidate>> search(
    ScrapeQuery query, {
    String? sourceId,
  }) async {
    final out = <ScrapeCandidate>[];
    for (final s in scrapers) {
      if (!s.isEnabled) continue;
      if (sourceId != null && s.id != sourceId) continue;
      try {
        final found = await s.search(query);
        if (found.isNotEmpty) {
          diag.info('刮削', '${s.id} 候选 ${found.length} 条（"${query.title}"）');
          out.addAll(found);
        }
      } catch (e) {
        // 一个源搜挂了不该让对话框整个空掉 —— 其他源的结果照样有用。
        diag.warn('刮削', '${s.id} 候选搜索失败，跳过', error: e);
      }
    }
    return out;
  }

  /// 用户选中的候选 → 完整元数据。**按来源找回对应的刮削器**。
  ///
  /// 不缓存刮削器实例、也不按 id 建表：来源就是 `scrapers` 里的 `id`，
  /// 直接线性找。列表只有两三项，建表反而多一处要保持同步的状态。
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async {
    for (final s in scrapers) {
      if (s.id == candidate.source) return s.resolve(candidate);
    }
    diag.warn('刮削', '候选来源 ${candidate.source} 不在当前流水线里，忽略');
    return null;
  }

  /// 跑一个刮削器，**把异常也归成「未命中」**。
  ///
  /// 这个 try/catch 是并发版本里更要紧的一道：竞速者全部已经起跑，
  /// 高优先级那个成功后我们就 `return` 了，剩下没被 await 的 future
  /// 一旦抛异常就会变成**未处理的异步错误**（在 Flutter 里会直接
  /// 打到 zone 的错误回调上）。在这里吃掉，就不会有漏网的。
  Future<ScrapedMetadata?> _attempt(
    MetadataScraper scraper,
    ScrapeQuery query,
  ) async {
    try {
      final result = await scraper.scrape(query);
      if (result == null) diag.info('刮削', '${scraper.id} 未命中：$query');
      return result;
    } catch (e) {
      // 单个刮削器抛异常（网络库没兜住、解析崩了）不该中断流水线
      diag.warn('刮削', '${scraper.id} 抛出异常，按未命中处理', error: e);
      return null;
    }
  }
}
