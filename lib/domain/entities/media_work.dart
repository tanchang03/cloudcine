import '../../core/utils/filename_parser.dart';
import '../../core/utils/format.dart';
import '../../core/utils/media_category.dart';
import '../services/intro_marker.dart';
import 'drive_provider.dart';
import 'work_poster.dart';

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
    this.categoryManual = false,
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
    this.genresManual = false,
    this.onlineId,
    this.source = ScrapeSource.local,
    this.scrapedAt,
    this.itemCount = 0,
    this.totalBytes = 0,
    this.seasonCount = 0,
    this.mergedInto,
    this.introStartMs,
    this.introEndMs,
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

  /// 分类是否由用户手动指定。
  ///
  /// `true` 时，`mergeWorkForUpsert` 和 `WorkScraper._categoryFor` 不会用
  /// `fromGenres` 覆盖 [category] —— 即使用户重新刮削 / 重新扫描。
  ///
  /// 设为 `false` 可以恢复自动判定行为（后续刮削可再次改写分类）。
  final bool categoryManual;

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

  /// 类型标签是否由用户手动编辑过。
  ///
  /// `true` 时，`mergeWorkForUpsert` 和 `WorkScraper._apply` 不会用刮削
  /// 返回的类型覆盖 [genres] —— 即使用户重新刮削。设为 `false` 恢复
  /// 「刮削说了算」。
  final bool genresManual;

  /// 在线刮削的条目 ID（如 TMDB 的 `tv/12345`）
  final String? onlineId;

  final ScrapeSource source;
  final DateTime? scrapedAt;

  /// 作品下的文件数（冗余字段，列表页避免 N+1 查询）
  final int itemCount;
  final int totalBytes;

  /// 作品下**已标季号**的季数（去重；不含「未标季」那一桶）。
  ///
  /// 冗余字段，与 [itemCount] 同一条理由：卡片要显示「3 季」，现算就得对
  /// `media_items` 做一次 `COUNT(DISTINCT season)` 子查询。
  ///
  /// ⚠️ **`0` 和 `1` 都表示「不该显示」** —— 电影、单季剧、以及还没重扫过的
  /// 老库都是这个值。只有 `>= 2` 才有信息量（「只有一季」写在卡片上是废话）。
  final int seasonCount;

  /// 这一行**已被折叠进**哪一部作品（目标作品的 [key]）；`null` = 它自己
  /// 就是一部独立的作品。
  ///
  /// ## 它不是「删除标记」，是「别名」
  ///
  /// 非空时这一行从列表与所有角标里消失，但**行本身与它下面的文件全部
  /// 原样保留**：`itemsForWork(目标.key)` 会把它们一起查出来。所以
  /// 撤销只是把这一列改回 `null`，不丢任何东西。
  ///
  /// ## 两个必须守住的不变量
  ///
  ///   1. **`media_items.group_key` 永不改写** —— item 永远指向自己那行
  ///      work，`PlayTarget` / 续播点 / 字幕引用都不需要知道「合并」存在。
  ///   2. **不允许链式**：`mergedInto` 指向的一定是一个 `mergedInto == null`
  ///      的根。源行**永远不会**成为别人的目标。
  ///
  /// ## 扫描不许把它清掉
  ///
  /// 重扫时 `WorkSeed.build` 造出来的新行 `mergedInto` 是 `null`，如果
  /// `mergeWorkForUpsert` 照抄新值，**每次扫描都会把所有合并悄悄拆开**，
  /// 而用户只看到「合过的片子又变回两个格子了」。所以这一列走
  /// 「旧值优先」的受保护通道。
  final String? mergedInto;

  /// 是否是「已被折叠走」的别名行 —— 列表 / 角标一律不认它。
  bool get isMergedAway => (mergedInto ?? '').isNotEmpty;

  /// 用户手标的**片头**起点 / 终点（毫秒）；`null` = 没标过。
  ///
  /// 作品级而不是文件级：同一部剧每集片头位置几乎一样，让用户给 24 集
  /// 各标一次是不可接受的（见 `MediaWorks.introStartMs`）。
  ///
  /// 它与**文件自带的章节标记**是两条独立的路，优先级由播放器定：
  /// 章节优先（那是发布者给的准确信息），这一对是兜底 ——
  /// 网盘上的剧集绝大多数没有章节。
  final int? introStartMs;
  final int? introEndMs;

  /// 手标片头区间；半条标记（只标了起点或只标了终点）当没有。
  ///
  /// 用 [IntroMarker.fromMilliseconds] 而不是在这里各判一次：那个函数
  /// 还要挡住「终点早于起点」这类脏数据，规则只能有一份。
  IntroMarker? get introRange =>
      IntroMarker.fromMilliseconds(introStartMs, introEndMs);

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
    // 「N 季」只在这个数字**有信息量**时才出现：一季写在卡片上是废话，
    // 而 0（电影 / 老库）更不该出现。
    if (seasonCount >= 2) parts.add('$seasonCount 季');
    if (itemCount > 0) {
      parts.add(kind == MediaKind.episode ? '$itemCount 集' : '$itemCount 个文件');
    }
    if (rating != null) parts.add(rating!.toStringAsFixed(1));
    return parts.join(' · ');
  }

  /// 卡片第三行：文件大小 · 网盘更新时间。
  ///
  /// 与 [subtitleLine] 分开：副标题已经可能满行（分类 · 年份 · N集 · 评分），
  /// 再塞进去会被 `TextOverflow.ellipsis` 截掉，而体积和时间恰恰是
  /// 用户想看到的信息。单独一行保证它们至少各有一次出现的机会。
  ///
  /// - `totalBytes` 为 0（未扫描或聚合前）时不显示体积；
  /// - `lastModifiedAt` 为 null 时不显示时间；
  /// - 两者都没有时返回空串，调用方应据此不画这一行。
  String get metaLine {
    final parts = <String>[];
    if (totalBytes > 0) parts.add(formatBytes(totalBytes));
    if (lastModifiedAt != null) {
      parts.add(formatRelativeTime(lastModifiedAt!));
    }
    return parts.join(' · ');
  }

  MediaWork copyWith({
    String? title,
    MediaCategory? category,
    bool? categoryManual,
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
    bool? genresManual,
    String? onlineId,
    ScrapeSource? source,
    DateTime? scrapedAt,
    int? itemCount,
    int? totalBytes,
    int? seasonCount,
    String? mergedInto,
    int? introStartMs,
    int? introEndMs,
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
        categoryManual: categoryManual ?? this.categoryManual,
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
        genresManual: genresManual ?? this.genresManual,
        onlineId: onlineId ?? this.onlineId,
        source: source ?? this.source,
        scrapedAt: scrapedAt ?? this.scrapedAt,
        itemCount: itemCount ?? this.itemCount,
        totalBytes: totalBytes ?? this.totalBytes,
        seasonCount: seasonCount ?? this.seasonCount,
        // ⚠️ 传 `null` 是「不改」而不是「拆开合并」—— `copyWith` 清不掉
        // 这一列。撤销合并走 `MediaRepository.unmergeWorks`（一条直接
        // UPDATE），不要在这里绕。
        mergedInto: mergedInto ?? this.mergedInto,
        lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
        firstSeenAt: firstSeenAt ?? this.firstSeenAt,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// **清除在线刮削信息 + 自定义**。
  ///
  /// 走这条路的场景只有一个：自动刮削把这部作品刮错了，而**库里根本没有
  /// 对得上的条目**（自制视频、演唱会、赛事、课程…）。自动那侧能做的都做了，
  /// 剩下唯一正确的动作是把在线源留下的痕迹全部抹掉，换成人自己敲的片名与
  /// 分类 —— 也就是详情页「自定义」那个按钮。
  ///
  /// ## 为什么是独立方法，而不是拼一串 `copyWith`
  ///
  /// `copyWith` 对每个可空字段都用 `??` 兜底，**没法把字段改回 `null`**
  /// （传 `null` 等于「不改」）。而本方法要做的恰恰是把海报、简介、评分、
  /// 刮来的类型这些**清空** —— 用 `copyWith` 拼出来会得到一个「看着像清空了、
  /// 其实一个字段都没清」的行，而且它编译通过、落库成功、界面上什么都不变。
  ///
  /// ## 四个不那么显然的决定
  ///
  ///   - **[source] 是 [ScrapeSource.manual]，不是 [ScrapeSource.local]。**
  ///     `local` 的含义是「这一行是文件名解析的产物」，于是下一次扫描时
  ///     `mergeWorkForUpsert` 会认为「库里这条和我这次算出来的同源」，
  ///     拿文件名解析出的标题**覆盖掉用户刚敲进去的片名**。`manual` 才落进
  ///     那边的保护分支（那条注释写的就是「用户手工改过的当然更不能被
  ///     文件名顶掉」）；
  ///   - **[categoryManual] 只在用户真的改了分类时才锁**：对话框预填的是
  ///     当前分类，用户若没动它（只想清在线信息），就**不新加锁** —— 否则
  ///     一次「清空刮削数据」会把当时那个（很可能是刮错的）分类冻死，之后
  ///     连手动重刮都改不动。改了分类才置 `true`（与 `setWorkCategory`
  ///     同一条规则：显式指定即锁定），此前已有的锁原样保留；
  ///   - **`genres` 只清「刮来的」那一份**：类型标签现在是可手敲、可锁的
  ///     （`genresManual`，详情页「编辑类型」那个 chip），而
  ///     `mergeWorkForUpsert` 早就立过规矩 —— 用户手敲的类型连**重刮削**
  ///     都不许覆盖（那条 `genresManual` 分支排在保护模式**之前**）。
  ///     「清在线信息」当然更该守这条：无条件清空会把用户挑好的类型连同
  ///     锁一起抹掉，而且**不报错**；
  ///   - **文件数 / 体积 / 网盘时间 / 播放记录原样保留**：它们与刮削无关，
  ///     是扫描和播放的产物。这里若图省事不抄，构造器默认值会把库里的真实
  ///     数字抹成 0 —— `itemCount` 一变成 0，卡片副标题上的「N 集」就没了。
  ///
  /// ## 清掉的字段会自己长回来吗
  ///
  /// 会，而且这正是想要的效果 —— 但**只从本地来源**：
  ///
  ///   - `year`：下次重扫时由文件名解析补回（`_preferOld` 在旧值为 `null`
  ///     时取新值）；
  ///   - `posterUrl` / `posterFaceX`：由 [drivePoster] **当场**回落到网盘
  ///     缩略图，或下次重扫时经 `WorkSeed` 成对恢复。
  ///
  /// 而在线源那张**刮错了的海报**不会回来：`mergeWorkForUpsert` 里有一条
  /// 针对 `manual` 的守卫，扫描期的自动刮削碰不到这一行。
  ///
  /// ## [drivePoster]：清掉在线海报之后，封面回落到网盘缩略图
  ///
  /// 「清除刮削」要抹掉的是**刮错的那张图**，不是「这部作品从此没有封面」。
  /// 纯粹清空的话，用户点完「自定义」会看到一墙灰块 —— 而网盘给每个视频
  /// 生成的服务端预览图**一直都在**（`MediaItem.thumbUrl`，扫描时就存了）。
  /// 这与「本地解析永远可用，在线刮削是增强」是同一条原则：刮削是**增强**，
  /// 撤掉增强之后应该退回本地那一级，不是退回空。
  ///
  /// 由调用方（`MediaRepository.customizeWork`）从这部作品的媒体项里挑好
  /// 再传进来：本类不认识仓储，也没法自己查文件。
  MediaWork customized({
    required String title,
    required MediaCategory category,
    required DateTime updatedAt,
    WorkPoster? drivePoster,
  }) =>
      MediaWork(
        key: key,
        provider: provider,
        kind: kind,
        category: category,
        // B：只有用户**真的改了**分类才新加锁。只清在线信息（分类没动）时
        // 不锁 —— 否则「清空刮削数据」会顺手把当时那个（很可能是错的）分类
        // 冻死，之后连手动重刮都改不动（原 bug 现场）。此前已有的锁原样保留：
        // 那是用户更早的明确指定，不该被一次「只为清数据」的操作悄悄解锁。
        categoryManual: category != this.category || categoryManual,
        title: title,
        // ---- 以下全部是在线刮削的产物，逐项清空 ----
        originalTitle: null,
        year: null,
        overview: null,
        // 有网盘缩略图就用它（**清的是刮错的那张，不是「从此不要封面」**）；
        // 没有才真的留空。
        posterUrl: drivePoster?.url,
        // 缓存文件名只对**同一张图**有效：地址没变（清之前用的本来就是
        // 网盘缩略图）时留着，省一次下载；换了图必须清 —— 留着的话
        // `PosterCache.pathFor` 会因为 `knownFile` 存在而直接返回旧文件，
        // 封面显示成前一张。
        posterFile:
            drivePoster?.url != null && drivePoster!.url == posterUrl
                ? posterFile
                : null,
        // 锚点与地址**同进同退**：它由 drivePoster 一起带来，
        // 不会出现「拿视频帧的人脸位置去裁刮削海报」。
        posterFaceX: drivePoster?.faceX,
        backdropUrl: null,
        backdropFile: null,
        rating: null,
        // 只清刮来的那份；用户手敲并锁住的原样保留（理由见上方文档）。
        // `genresManual` 必须一起抄 —— 漏了它就等于**偷偷解锁**：
        // 类型留着，但下一次刮削会把它们整份覆盖掉。
        genres: genresManual ? genres : const [],
        genresManual: genresManual,
        onlineId: null,
        source: ScrapeSource.manual,
        scrapedAt: null,
        // ---- 与刮削无关，原样保留 ----
        itemCount: itemCount,
        totalBytes: totalBytes,
        seasonCount: seasonCount,
        // 「自定义」改的是元数据，跟「这一行是不是被折叠走了」没关系 ——
        // 漏抄会顺手把合并拆掉。
        mergedInto: mergedInto,
        // 同理：片头区间是**用户标的播放偏好**，与刮削无关。漏抄的表现是
        // 「点一下自定义，跳片头就再也不生效了」，而且没有任何提示。
        introStartMs: introStartMs,
        introEndMs: introEndMs,
        lastModifiedAt: lastModifiedAt,
        firstSeenAt: firstSeenAt,
        lastPlayedAt: lastPlayedAt,
        updatedAt: updatedAt,
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
  ///
  /// ## 备用词必须是「另一个名字」，不是一串编号
  ///
  /// 2026-10-02 事故：`182.格力空调显示E6如何维修.mp4` 解析出
  /// `cjk=格力空调显示`、`latin=182`。旧规则只看「两边都非空」，于是又拿
  /// `"182"` 去搜了一次 TMDB —— 模糊搜索返回希腊纪录片《1821: Οι Ήρωες》，
  /// 匹配闸门的前缀档判它 **0.91**（`182` 是 `1821` 的前缀），无条件通过，
  /// 整部家电维修教程被挂上了一部希腊纪录片的海报与简介。
  ///
  /// 判据：去掉数字与标点后**至少还剩 2 个字母**。
  /// `182` → 0 个（拒）、`182 E6` → 1 个（拒）、`3 Idiots` → 6 个（放行）。
  static String? _alternateOf(ParsedMediaName parsed) {
    final cjk = parsed.cjkTitle;
    final latin = parsed.latinTitle;
    if (cjk == null || latin == null) return null;
    if (RegExp(r'[A-Za-z]').allMatches(latin).length < 2) return null;
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
