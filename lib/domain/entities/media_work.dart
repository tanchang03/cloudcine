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
    this.lastModifiedAt,
    this.firstSeenAt,
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

  /// 作品下所有文件的**网盘修改时间**最大值。
  ///
  /// 取 `MediaItem.modifiedAt` 的最大值：新增一集或替换一集时，
  /// 这个值会变大，整个作品在「最近修改」排序里就会浮到前面。
  final DateTime? lastModifiedAt;

  /// 作品**首次入库**时间。决定「最近添加」排序，upsert 时必须保留旧值。
  final DateTime? firstSeenAt;

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
    DateTime? lastModifiedAt,
    DateTime? firstSeenAt,
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
        lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
        firstSeenAt: firstSeenAt ?? this.firstSeenAt,
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

/// 一条**候选**条目 —— 用户手动指定片名时用来挑的那一批。
///
/// ## 与 [ScrapedMetadata] 的分工
///
/// 这个是「搜索结果里的一条」，信息可能不全：豆瓣的搜索结果连海报都只是
/// 一张 120px 高的横条，简介也没有。它只够**展示给用户选**；
/// 选中之后由刮削器的 `resolve()` 换成完整的 [ScrapedMetadata]。
///
/// ## 为什么需要它
///
/// 文件名不总是完整的片名 —— 发布组会把片名打散、插字符来规避关键词过滤
/// （实测 `超z级z马z力z欧z银z河z大z电影aa`，真名《超级马力欧银河大电影》），
/// 也可能只剩一个 `2026.2160p.WEB-DL.mkv`。这种输入**任何自动算法都救不回来**，
/// 只能让用户自己敲一个词，然后从候选里点一个。
class ScrapeCandidate {
  const ScrapeCandidate({
    required this.source,
    required this.sourceId,
    required this.title,
    this.originalTitle,
    this.year,
    this.posterUrl,
    this.overview,
    this.isEpisode = false,
    this.raw,
  });

  /// 来源 id（`tmdb` / `douban`）。`resolve()` 靠它找回对应的刮削器。
  final String source;

  /// 来源内的条目 id。
  final String sourceId;

  final String title;
  final String? originalTitle;
  final int? year;

  /// **展示用**的小图。豆瓣给的是 120px 横条 —— 不要拿它当作品海报。
  final String? posterUrl;

  final String? overview;

  /// 来源判定的类型（电影 / 剧集）。
  final bool isEpisode;

  /// 来源自己的原始条目。`resolve()` 直接用它，免得再搜一次
  /// （豆瓣的额度是按搜索词计的，重复搜是实打实的浪费）。
  final Map<String, Object?>? raw;

  /// 列表里那行副标题。
  String get subtitle => <String>[
        if (year != null) '$year',
        isEpisode ? '剧集' : '电影',
        switch (source) {
          'douban' => '豆瓣',
          'tmdb' => 'TMDB',
          _ => source,
        },
      ].join(' · ');

  @override
  String toString() =>
      'ScrapeCandidate($source/$sourceId "$title" ${year ?? "-"})';
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
