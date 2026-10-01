import '../../core/utils/filename_parser.dart';
import '../../core/utils/media_category.dart';
import 'drive_provider.dart';

/// 元数据来源。
///
/// 这个字段不是装饰 —— UI 要如实告诉用户「这条信息是猜的还是查的」。
/// 本地解析出来的标题带 `(文件名解析)` 标记，避免用户以为刮削失败。
enum ScrapeSource {
  /// 文件名解析（离线，永远可用）
  local,

  /// 在线刮削（TMDB 等）
  online,

  /// 用户手工修改
  manual;

  String get label => switch (this) {
        ScrapeSource.local => '文件名解析',
        ScrapeSource.online => '在线刮削',
        ScrapeSource.manual => '手动修改',
      };
}

/// 媒体库里的一条**作品级**记录。
///
/// 一个 work 对应一部电影或一部剧；它下面挂着若干 [MediaItem]。
/// 海报、简介、评分这些「一部作品只有一份」的信息挂在这里，
/// 而不是在每一集上重复存 N 份。
class MediaWork {
  const MediaWork({
    required this.key,
    required this.provider,
    required this.kind,
    required this.title,
    this.category = MediaCategory.other,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterUrl,
    this.posterFile,
    this.posterFaceX,
    this.backdropUrl,
    this.backdropFile,
    this.rating,
    this.genres = const [],
    this.onlineId,
    this.source = ScrapeSource.local,
    this.scrapedAt,
    this.itemCount = 0,
    this.totalBytes = 0,
    this.lastPlayedAt,
    required this.updatedAt,
  });

  /// 归组键（与 `MediaItem.groupKey` 同源）
  final String key;

  final DriveProvider provider;
  final MediaKind kind;

  /// 展示标题
  final String title;

  /// 媒体库一级分类（电影 / 剧集 / 动漫 / 综艺 / 纪录片 / 其他）。
  ///
  /// **与 [kind] 是两个独立的维度**，理由见 [MediaCategory] 的类文档。
  /// 它由 `MediaCategoryGuesser` 在扫描期算出并落库 —— 之所以要落库而不是
  /// 每次查询时现算，是因为分类栏要能**在 SQL 里筛选**，几千部作品在
  /// Dart 侧过滤会让「点一下分类」变成一次全表扫描。
  final MediaCategory category;

  /// 原始标题（在线刮削返回的 `original_title`）
  final String? originalTitle;

  final int? year;
  final String? overview;

  /// 海报远程地址（在线刮削给的）
  final String? posterUrl;

  /// 海报本地缓存文件名（相对海报缓存目录）
  final String? posterFile;

  /// 这张海报里**人物所在的水平位置**（归一化 0~1）。
  ///
  /// 只有海报来自**夸克的视频帧**（16:9）时才有值 —— 那时封面会被裁成
  /// 竖版，需要锚住人物而不是裁到画面正中（双人对谈镜头的中点是两人
  /// 之间的空隙）。来自 TMDB 的海报本身就是 2:3，不需要锚点，此处为 `null`。
  ///
  /// ⚠️ 它必须和 [posterUrl] **同步更新**：换了封面来源却没换锚点，
  /// 就会拿视频帧的人脸位置去裁一张海报。`scan_service` 在写这两个字段时
  /// 是成对处理的。
  final double? posterFaceX;

  final String? backdropUrl;
  final String? backdropFile;

  final double? rating;
  final List<String> genres;

  /// 在线刮削的条目 ID（如 TMDB 的 `tv/12345`）
  final String? onlineId;

  final ScrapeSource source;
  final DateTime? scrapedAt;

  /// 作品下的文件数（冗余字段，列表页避免 N+1 查询）
  final int itemCount;
  final int totalBytes;
  final DateTime? lastPlayedAt;
  final DateTime updatedAt;

  bool get hasPoster => (posterFile ?? '').isNotEmpty || (posterUrl ?? '').isNotEmpty;
  bool get isScraped => source == ScrapeSource.online || source == ScrapeSource.manual;

  /// 年份展示文本。
  String get yearLabel => year == null ? '年份未知' : '$year';

  /// 副标题：`剧集 · 2023 · 12 集 · 8.7`
  ///
  /// 第一段用 [category] 而不是 [kind]：动漫 / 综艺 / 纪录片都算「剧集」
  /// 结构，用 kind 的话海报墙上看不出它们的区别 —— 而那正是分类栏想表达的
  /// 信息。两者对电影和普通剧集的结果完全一致，所以这个替换不会让老用户
  /// 觉得字变了。
  String get subtitleLine {
    final parts = <String>[category.label];
    if (year != null) parts.add('$year');
    if (itemCount > 0) {
      parts.add(kind == MediaKind.episode ? '$itemCount 集' : '$itemCount 个文件');
    }
    if (rating != null) parts.add(rating!.toStringAsFixed(1));
    return parts.join(' · ');
  }

  MediaWork copyWith({
    String? title,
    MediaCategory? category,
    String? originalTitle,
    int? year,
    String? overview,
    String? posterUrl,
    String? posterFile,
    double? posterFaceX,
    String? backdropUrl,
    String? backdropFile,
    double? rating,
    List<String>? genres,
    String? onlineId,
    ScrapeSource? source,
    DateTime? scrapedAt,
    int? itemCount,
    int? totalBytes,
    DateTime? lastPlayedAt,
    DateTime? updatedAt,
  }) =>
      MediaWork(
        key: key,
        provider: provider,
        kind: kind,
        title: title ?? this.title,
        category: category ?? this.category,
        originalTitle: originalTitle ?? this.originalTitle,
        year: year ?? this.year,
        overview: overview ?? this.overview,
        posterUrl: posterUrl ?? this.posterUrl,
        posterFile: posterFile ?? this.posterFile,
        posterFaceX: posterFaceX ?? this.posterFaceX,
        backdropUrl: backdropUrl ?? this.backdropUrl,
        backdropFile: backdropFile ?? this.backdropFile,
        rating: rating ?? this.rating,
        genres: genres ?? this.genres,
        onlineId: onlineId ?? this.onlineId,
        source: source ?? this.source,
        scrapedAt: scrapedAt ?? this.scrapedAt,
        itemCount: itemCount ?? this.itemCount,
        totalBytes: totalBytes ?? this.totalBytes,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  @override
  String toString() =>
      'MediaWork(${kind.name}, "$title", ${year ?? "-"}, $itemCount 项, '
      '${source.label})';
}

/// 刮削器返回的元数据。**与持久化模型分开**：
/// 刮削器不需要知道库里有没有这条记录、也不需要知道主键长什么样，
/// 它只回答「这个查询对应的作品信息是什么」。
class ScrapedMetadata {
  const ScrapedMetadata({
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.posterUrl,
    this.backdropUrl,
    this.rating,
    this.genres = const [],
    this.onlineId,
    this.source = ScrapeSource.online,
    this.matchedQuery,
  });

  final String title;
  final String? originalTitle;
  final int? year;
  final String? overview;
  final String? posterUrl;
  final String? backdropUrl;
  final double? rating;
  final List<String> genres;
  final String? onlineId;
  final ScrapeSource source;

  /// 实际用于命中的查询词（排查「刮错了」时看这个）
  final String? matchedQuery;

  @override
  String toString() =>
      'ScrapedMetadata("$title", ${year ?? "-"}, src=${source.label}, '
      'poster=${posterUrl == null ? "无" : "有"})';
}

/// 刮削请求：从本地解析结果构造。
///
/// 单独一个类型而不是直接传 `ParsedMediaName`：刮削器只需要这几个字段，
/// 拿到整个解析结果会让「哪些字段影响命中」变得不清晰。
class ScrapeQuery {
  const ScrapeQuery({
    required this.title,
    required this.kind,
    this.alternateTitle,
    this.year,
    this.season,
    this.episode,
  });

  /// 由文件名解析结果构造。解析不可信（片名空 / 类型未知）时返回 `null`。
  ///
  /// ## 为什么做成工厂而不是让调用方各拼各的
  ///
  /// 现在有**两个**地方要发刮削请求：扫描期（`ScanService`）与详情页的
  /// 「刮削」按钮（`WorkScraper`）。两处只要有一处漏了 `alternateTitle`、
  /// 或者年份的取值口径不同，同一个作品在两处就会**查出不同的结果** ——
  /// 而这是静默的：用户只会觉得「这个按钮有时候不准」。
  static ScrapeQuery? fromParsed(ParsedMediaName parsed) {
    final title = parsed.title;
    if (!parsed.isConfident || title == null || title.isEmpty) return null;
    return ScrapeQuery(
      title: title,
      alternateTitle: _alternateOf(parsed),
      kind: parsed.kind,
      year: parsed.year,
      season: parsed.season,
      episode: parsed.episode,
    );
  }

  /// 中英混排时把另一半作为备用查询词。
  ///
  /// 只在**两种文字都解析出来**时才有备用词：只有一个的时候它已经就是
  /// [title] 了，再搜一遍是白花一次配额。
  static String? _alternateOf(ParsedMediaName parsed) {
    final cjk = parsed.cjkTitle;
    final latin = parsed.latinTitle;
    if (cjk == null || latin == null) return null;
    return latin;
  }

  final String title;

  /// 中英混排时的另一半（中文名搜不到时用它再搜一次）
  final String? alternateTitle;

  final MediaKind kind;
  final int? year;
  final int? season;
  final int? episode;

  bool get isEpisode => kind == MediaKind.episode;

  @override
  String toString() =>
      'ScrapeQuery("$title"${alternateTitle == null ? "" : " / $alternateTitle"}, '
      '${kind.name}, y=$year, s=$season, e=$episode)';
}
