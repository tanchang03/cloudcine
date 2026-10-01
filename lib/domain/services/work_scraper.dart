import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/filename_parser.dart';
import '../adapters/media_repository.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';
import 'scraper.dart';

/// 单部作品的刮削结果。
enum WorkScrapeStatus {
  /// 在线源命中，作品行已更新。
  scraped,

  /// 在线源都试过了，没有命中（作品行不变）。
  notFound,

  /// 文件名解析不出可信片名，没有可查的东西。
  noQuery,
}

/// 刮一部作品的产物。
class WorkScrapeOutcome {
  const WorkScrapeOutcome({required this.status, this.work, this.metadata});

  final WorkScrapeStatus status;

  /// 落库后的作品行（[WorkScrapeStatus.scraped] 时非空）。
  final MediaWork? work;

  /// 命中的元数据（[WorkScrapeStatus.scraped] 时非空）。
  final ScrapedMetadata? metadata;

  /// 面向用户的一句话结果。
  String get message => switch (status) {
        WorkScrapeStatus.scraped =>
          '已刮削：${metadata!.title}'
              '${metadata!.year == null ? "" : "（${metadata!.year}）"}',
        WorkScrapeStatus.notFound => '在线源都没有找到匹配的条目，'
            '可能是片名解析不准，或这个词在数据源里没有收录。',
        WorkScrapeStatus.noQuery => '这个文件名解析不出可信的片名，无法刮削。',
      };
}

/// **按需刮削单部作品**。
///
/// ## 为什么要有这个服务（而不是只有扫描期刮削）
///
/// 扫描期自动刮削对 TMDB 是合适的（额度宽、失败无副作用），但对**豆瓣**是
/// 有害的：匿名额度实测只有约 10 个搜索词，145 部作品走一遍必然中途耗尽，
/// 而额度耗尽之后是 `103 need_login` —— 用户看到的是「豆瓣一条都刮不到」，
/// 且这个 IP 短时间内都用不了。
///
/// 所以刮削改成**按需触发**：默认扫描不刮，用户在详情页点「刮削」才发请求。
/// 一次点击最多消耗 2 个搜索词，额度能撑很久，风控也几乎不会触发。
/// 想恢复自动刮削就在设置里打开「扫描后自动刮削」（默认关）。
///
/// ## 它做三件事
///
///   1. 从作品的**文件名**重新解析出查询（不是从库里已存的标题）——
///      这样反复刮削的查询词是稳定的，不会「刮一次之后第二次查的是
///      上一次刮来的名字」；
///   2. 跑一遍 [ScraperPipeline]（并发的多源，见那边的文档）；
///   3. 把命中的元数据**合并回作品行**并落库。
///
/// 第 3 步刻意不复用 `ScanService._buildWork`：那个方法的输入是扫描期的
/// 种子，而这里必须从**库里已有的作品行**出发，否则会把分类、文件数、
/// 播放记录这些与刮削无关的字段清掉。
class WorkScraper {
  WorkScraper({
    required MediaRepository library,
    required ScraperPipeline pipeline,
    MediaFilenameParser parser = const MediaFilenameParser(),
    DateTime Function()? clock,
  })  : _library = library,
        _pipeline = pipeline,
        _parser = parser,
        _clock = clock ?? DateTime.now;

  final MediaRepository _library;
  final ScraperPipeline _pipeline;
  final MediaFilenameParser _parser;
  final DateTime Function() _clock;

  /// 刮一部作品并落库。
  ///
  /// **永不抛异常**：网络抖动、源挂了、解析崩了都归到
  /// [WorkScrapeStatus.notFound] —— 这是给一个按钮用的，抛异常只会变成
  /// 一个红色的报错弹窗，而用户真正需要知道的是「没刮到」。
  Future<WorkScrapeOutcome> scrape(MediaWork work) async {
    try {
      final items = await _library.itemsForWork(work.key);
      if (items.isEmpty) {
        return const WorkScrapeOutcome(status: WorkScrapeStatus.noQuery);
      }

      final query = _queryFor(items);
      if (query == null) {
        diag.info('刮削', '${work.key} 文件名解析不出可信片名，跳过');
        return const WorkScrapeOutcome(status: WorkScrapeStatus.noQuery);
      }

      final meta = await _pipeline.scrape(query);
      // ⚠️ 必须看 `source`：流水线的兜底是**本地文件名解析**，它永远成功。
      // 只判 `meta != null` 会把「什么都没刮到」当成成功，然后把
      // 「文件名解析」的结果当成在线结果写进库（`source` 变成 online），
      // 用户会看到「已刮削」但海报简介一个都没有。
      if (meta == null || meta.source != ScrapeSource.online) {
        diag.info('刮削', '${work.key} 在线源未命中：$query');
        return const WorkScrapeOutcome(status: WorkScrapeStatus.notFound);
      }

      final merged = _apply(work, meta);
      await _library.upsertWorks([merged], now: _clock());
      diag.info('刮削', '${work.key} 已更新：${meta.title}');
      return WorkScrapeOutcome(
        status: WorkScrapeStatus.scraped,
        work: merged,
        metadata: meta,
      );
    } catch (e) {
      diag.warn('刮削', '${work.key} 刮削失败，按未命中处理', error: e);
      return const WorkScrapeOutcome(status: WorkScrapeStatus.notFound);
    }
  }

  /// 从作品的文件里挑一条代表，解析出查询。
  ///
  /// 挑法与详情页「播放」按钮一致（`WorkDetail.features.first`）：**跳过花絮
  /// 与样片**。`-trailer.mkv` 解析出来的片名常常带着 `trailer`，拿它去搜
  /// 只会搜到一堆不相关的东西。
  ScrapeQuery? _queryFor(List<MediaItem> items) {
    final features = items.where((i) => !i.isSampleOrExtra).toList();
    final pool = features.isNotEmpty ? features : items;
    for (final item in pool) {
      final parsed = _parser.parse(
        item.name,
        dirName: MediaFilenameParser.dirNameOf(item.dirPath),
      );
      final query = ScrapeQuery.fromParsed(parsed);
      if (query != null) return query;
    }
    return null;
  }

  /// 把刮削结果合并进作品行。
  ///
  /// ## 三处必须显式处理的地方
  ///
  ///   - **分类不跟着变**。`category` 描述的是「这些文件是什么」（电影/剧集/
  ///     动漫/综艺…），是**扫描期对文件**的判定；刮削只补标题海报那类元数据。
  ///   - **海报换了就必须清掉 `posterFaceX`**。刮削海报是 2:3 的竖版作品海报，
  ///     铺满格子、不裁切，压根不需要人脸锚点。这里写 `null` 是**结论**而不是
  ///     缺失 —— 留着旧的锚点，`PosterImage` 会拿视频帧的人脸位置去裁海报。
  ///   - **`posterFile` 要一起清**。缓存文件名是按 URL 散列出来的，地址换了
  ///     就该重新下载；不清的话详情页会继续显示上一版海报。
  MediaWork _apply(MediaWork work, ScrapedMetadata meta) {
    final posterUrl = _nonEmpty(meta.posterUrl) ?? work.posterUrl;
    final posterChanged = posterUrl != work.posterUrl;
    final backdropChanged = meta.backdropUrl != work.backdropUrl;

    return MediaWork(
      key: work.key,
      provider: work.provider,
      kind: work.kind,
      category: work.category,
      title: meta.title,
      originalTitle: meta.originalTitle ?? work.originalTitle,
      year: meta.year ?? work.year,
      overview: meta.overview ?? work.overview,
      posterUrl: posterUrl,
      posterFile: posterChanged ? null : work.posterFile,
      posterFaceX: posterChanged ? null : work.posterFaceX,
      backdropUrl: meta.backdropUrl ?? work.backdropUrl,
      backdropFile: backdropChanged ? null : work.backdropFile,
      rating: meta.rating ?? work.rating,
      genres: meta.genres.isEmpty ? work.genres : meta.genres,
      onlineId: meta.onlineId ?? work.onlineId,
      source: ScrapeSource.online,
      scrapedAt: _clock(),
      // 文件数与体积是**扫描的产物**，与刮削无关。抄一遍是为了让
      // `upsertWorks` 的合并分支原样保留它们 —— 传 0 会把库里的数字抹掉。
      itemCount: work.itemCount,
      totalBytes: work.totalBytes,
      lastPlayedAt: work.lastPlayedAt,
      updatedAt: _clock(),
    );
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}
