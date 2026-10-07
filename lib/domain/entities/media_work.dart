import '../../core/utils/directory_title.dart';
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
    this.followed = false,
    this.followStartedAt,
    this.followCheckedAt,
    this.newItemCount = 0,
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

  // -------------------------------------------------------------------
  // 追剧 / 更新提醒（v17）
  // -------------------------------------------------------------------

  /// 是否在追剧。四列里**唯一由用户直接改**的一列。
  final bool followed;

  /// **追剧起点**。`null` = 没在追剧 / 还没建立基线。
  ///
  /// ⛔ 只在用户开启追剧时写一次，之后**任何检查都不推进它** ——
  /// 它是剧集行 NEW 标签的基线（见 [isNewSinceFollow]）。
  final DateTime? followStartedAt;

  /// **上次追更检查时刻**（水位线）。检查**成功**后才推进。
  final DateTime? followCheckedAt;

  /// 未读新增条数（角标数字）。增量累加，清零只清这一列。
  final int newItemCount;

  /// 有未读更新（海报墙角标据此决定画不画）。
  bool get hasUpdate => newItemCount > 0;

  /// 这一条媒体项算不算「追剧之后才出现的新集」。
  ///
  /// 两个条件缺一不可：
  ///   1. `firstSeenAt > followStartedAt` —— 追剧**之后**才入库的；
  ///      没有这一条的话，刚开启追剧那一刻会把已有的 12 集全标成 NEW；
  ///   2. [played] 为假 —— **从没播过**。
  ///
  /// ## 为什么参数是原始值而不是 `MediaItem`
  ///
  /// ⛔ 「播过没有」的判据是 `media_items.max_position_ms`（历史最远位置，
  ///    只增不减），而**它不在 `MediaItem` 域实体上** —— PC 端是另一条独立
  ///    查询 `MediaRepository.maxPositions(itemIds)` 拿到的（详情页画进度条
  ///    用的就是它）。所以这里让调用方把「播过没有」算好了传进来，
  ///    而不是让实体去依赖另一个实体（那还会把 `media_item.dart` 里的
  ///    `formatBytes` 一起引进来，与本文件的 `format.dart` 撞名）。
  ///
  /// ⛔ 第 2 条用 `maxPositionMs` 而不是 `resumePositionMs`：
  ///    后者看完会被清成 `NULL`，拿它当判据的话「看完的一集」会重新变成
  ///    NEW。`maxPositionMs` 是只增不减的历史最远位置，正是「看过没有」。
  ///
  /// 因为第 2 条，**播过就自动消失，不需要任何额外写入** —— 这也是为什么
  /// 剧集行不需要一张「已读」表。
  ///
  /// 与 Android 端 `Work.isNewSinceFollow(item)` 同口径（那边 `LibraryItem`
  /// 直接带 `maxPositionMs`，所以不需要这个参数）。
  bool isNewSinceFollow({
    required DateTime firstSeenAt,
    required bool played,
  }) {
    final since = followStartedAt;
    if (since == null) return false;
    if (!firstSeenAt.isAfter(since)) return false;
    return !played;
  }

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
    /// 把片头两列一起清成 `null`（与 [clearFollow] 同一个套路、同一条理由）。
    ///
    /// 加它之前，内存实现里靠一个逐列抄一遍的 `_withIntro` 重建整行 ——
    /// 那种写法每加一列都要记得同步，漏一列就是静默丢数据（注释里专门
    /// 警告过 `mergedInto` 那一列）。有了这个开关，清空就是一次 `copyWith`。
    bool clearIntro = false,
    bool? followed,
    DateTime? followStartedAt,
    DateTime? followCheckedAt,
    int? newItemCount,
    /// 把追剧的三列一起**清回默认**（两条水位线 `null` + 计数 `0`）。
    ///
    /// ## 为什么需要这个开关
    ///
    /// [copyWith] 对每个可空字段都用 `??` 兜底，**没法把字段改回 `null`** ——
    /// 传 `null` 等于「不改」。所以「取消追剧」这件事用 `copyWith` 表达不出来，
    /// 而它会**静默失败**：`followed` 变成 `false` 了，两条水位线却还留着，
    /// 于是用户重新打开追剧时，`followStartedAt` 还是上一次的旧值 ——
    /// 中间那段时间入库的集会被算成「追剧以来新增」，一开就是一堆 NEW。
    ///
    /// 与 `LibraryFilter.copyWith` 的 `clearCategory` 是同一个套路：
    /// 不可空类型用 `??` 表达「不改」，可空类型就需要一个显式的清空开关。
    ///
    /// ⚠️ `followed` 本身**不在**这个开关的范围里：它是「开还是关」，
    /// 由调用方显式传值。
    bool clearFollow = false,
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
        introStartMs: clearIntro ? null : (introStartMs ?? this.introStartMs),
        introEndMs: clearIntro ? null : (introEndMs ?? this.introEndMs),
        // ⚠️ 两个 `DateTime?` 与 [mergedInto] 同一条限制：传 `null` 是「不改」
        // 而不是「清空」。要清空传 `clearFollow: true`
        // （`MediaRepository.setFollowed(key, false)` 走的就是它）。
        followed: followed ?? this.followed,
        followStartedAt:
            clearFollow ? null : (followStartedAt ?? this.followStartedAt),
        followCheckedAt:
            clearFollow ? null : (followCheckedAt ?? this.followCheckedAt),
        newItemCount: clearFollow ? 0 : (newItemCount ?? this.newItemCount),
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
        // 同理：追剧四列是**用户的追更状态**，与刮削无关。漏抄的表现是
        // 「点一下自定义，追剧就没了，角标也没了」—— 而且没有任何提示。
        followed: followed,
        followStartedAt: followStartedAt,
        followCheckedAt: followCheckedAt,
        newItemCount: newItemCount,
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
    this.requireExactTitle = false,
    this.fallbacks = const [],
  });

  /// 由文件名解析结果构造。**片名都提不出来时返回 `null`**（没有可查的东西）。
  ///
  /// ## 两档查询
  ///
  ///   - **严格档**（[requireExactTitle] 为 `false`）：解析可信 —— 有年份的
  ///     电影，或带季集结构的剧集。交给常规闸门（年份硬闸门 + 标题相似度分档）；
  ///   - **宽松档**（[requireExactTitle] 为 `true`）：**没有年份的电影**。
  ///     它在 2026-10-03 之前被直接拒掉（`isConfident` 为假 → 返回 `null`），
  ///     于是 `/来自：分享/奥德赛/1080P.mkv` 这类片子**永远刮不出来**。
  ///     现在放行，但把闸门换得更紧 —— 理由见 [requireExactTitle]。
  ///
  /// ## 为什么做成工厂而不是让调用方各拼各的
  ///
  /// 现在有**两个**地方要发刮削请求：扫描期（`ScanService`）与详情页的
  /// 「刮削」按钮（`WorkScraper`）。两处只要有一处漏了 `alternateTitle`、
  /// 或者年份的取值口径不同，同一个作品在两处就会**查出不同的结果** ——
  /// 而这是静默的：用户只会觉得「这个按钮有时候不准」。
  ///
  /// [dirPath] 是**这个文件所在目录**（带尾斜杠）。传了它才会生成
  /// [fallbacks]（文件名搜不到时改用目录名再搜）—— 理由见 [_fallbacksOf]。
  /// 两个调用点都必须传：漏了不会报错，只会让那条兜底永远不生效。
  static ScrapeQuery? fromParsed(ParsedMediaName parsed, {String? dirPath}) {
    final title = parsed.title;
    if (title == null || title.isEmpty) return null;
    // 类型都认不出来 = 这条文件名除了技术标记什么都没有（`S01E01.1080p.mkv`）。
    // 拿它去搜必然搜到别的片子 —— 这是**没有可查的东西**，不是档位问题。
    if (parsed.kind == MediaKind.unknown) return null;

    // 走到这里 `!isConfident` 只剩一种情形：**电影且没有年份** ——
    // 剧集不靠年份消歧（季集号自己就能定位），有年份的电影属于严格档。
    final relaxed = !parsed.isConfident;
    // 宽松档仍然要求「片名像个名字」：`159`、`1080p` 这类串不是名字，
    // 搜出去只会带回一堆编号相同的无关条目（2026-10-02「182」事故的同类）。
    if (relaxed && !parsed.hasUsableTitle) return null;

    return ScrapeQuery(
      title: title,
      alternateTitle: _alternateOf(parsed),
      kind: parsed.kind,
      year: parsed.year,
      season: parsed.season,
      episode: parsed.episode,
      requireExactTitle: relaxed,
      fallbacks: _fallbacksOf(parsed, dirPath),
    );
  }

  /// 目录名兜底的**最大条数**（文件所在目录 + 上级目录）。
  ///
  /// 每多一条就多花一个搜索词，而豆瓣的匿名额度实测只有约 10 个
  /// （见 `ScraperPipeline` 的类文档）。两级正好覆盖用户能一眼说清楚的
  /// 那两件事；再往上基本都是 `/来自：分享/动漫/` 这类栏目名，
  /// 本来就被 `DirectoryTitle.isContainerSegment` 挡掉了。
  static const int _maxDirFallbacks = 2;

  /// 文件名搜不到时的备用查询：**文件所在目录 → 上级目录**（逐级向上）。
  ///
  /// ## 为什么需要
  ///
  /// 2026-10-03 现场：`/来自：分享/仙逆/126 纯享-仙踪-[4K][HEVC][2026-02-01].mp4`
  /// 的文件名里没有作品名，只有「编号 + 描述」；`仙逆` 只写在目录上。
  /// 解析层本该用目录名归组（见 `MediaFilenameParser.parse`），但那一层
  /// 依赖一串前置判据，任何一条失手就会退回垃圾片名 —— 而**刮削是最后一
  /// 道防线**：它手上直接有这个文件的完整路径，不必受归组结论的牵连。
  ///
  /// ## 为什么目录候选一律当**剧集**、且走**宽松档**
  ///
  ///   - 目录名是**系列名**（`DirectoryTitle` 的口径），所以按剧集搜
  ///     （TMDB 的 `/search/tv`）—— 一部剧/动画的名字几乎只可能是剧名；
  ///   - 目录名没有年份、也没有季集号，闸门只剩标题相似度，而
  ///     `strongSimilarity = 0.6` 是为「有年份」定的档 —— 所以必须换成
  ///     **精确同名**（与无年份电影同一条理由，见 [requireExactTitle]）。
  ///
  /// ## 三处刻意的省略
  ///
  ///   - **不设 `alternateTitle`**：目录名极少中英混排，带上只会把一次
  ///     失败变成两次请求；
  ///   - **不设 `year`**：目录名里的年份几乎都是「合集整理于某年」，
  ///     当过滤条件用会把正主筛掉；
  ///   - **不与主查询重名**：`/…/仙逆/仙逆.S01E01.mkv` 这种「目录名就是
  ///     片名」的布局很常见，那条兜底与主查询完全等价，白花一次额度。
  static List<ScrapeQuery> _fallbacksOf(ParsedMediaName parsed, String? dirPath) {
    if (dirPath == null || dirPath.isEmpty) return const [];
    final own = _normalizeName(parsed.title);

    final out = <ScrapeQuery>[];
    for (final name in DirectoryTitle.ancestorNames(dirPath)) {
      if (out.length >= _maxDirFallbacks) break;
      if (_normalizeName(name) == own) continue;
      out.add(
        ScrapeQuery(
          title: name,
          kind: MediaKind.episode,
          requireExactTitle: true,
        ),
      );
    }
    return out;
  }

  /// 「同一个名字」的判定口径 —— 与 `ParsedMediaName.groupKey` 一致。
  static String _normalizeName(String? s) =>
      (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

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

  /// **宽松档**：这条查询没有年份可用于消歧（无年份的电影），因此闸门改用
  /// **归一化精确同名**这条判据，并且调用方还要求这条命中**排在该源候选的
  /// 第一位**（见 `TmdbScraper._pickVerified` 与 `DoubanScraper._pickBest`）。
  ///
  /// ## 为什么不是「取第一个过闸门的」
  ///
  /// 无年份时闸门只剩标题相似度，而 `strongSimilarity = 0.6` 是**为「有年份」
  /// 定的档**（那里的主力判据是年份硬闸门，标题只是辅助）。实测 2026-10-03
  /// 搜「奥德赛」时，被 0.6 档放行、但**是别的片子**的有：`特洛伊奥德赛`
  /// 0.68、`奥德赛：史诗的诞生` 0.78、`《奥德赛》序章` 0.86 —— 「取第一条」
  /// 会把它们照单收下，而那是**静默刮错**（标题/简介/评分/海报换成另一部
  /// 片子的，且不报错）。
  ///
  /// ## 为什么也不要求「精确同名唯一」
  ///
  /// 同一次实测：「奥德赛」在 TMDB 上有 **4 条**精确同名（豆瓣 2 条）。
  /// 要求唯一会把正主也挡掉。所以只要求**第一条精确同名** —— 既挡住上面的
  /// 前缀误配，又借数据源自己的相关度排序在多个同名条目里挑一个（TMDB 把
  /// 最热门的排最前）。第一条都不精确，就交回手动通道。
  final bool requireExactTitle;

  /// 本条失败后**按顺序再试**的候选查询（空 = 没有兜底）。
  ///
  /// 目前只有一个来源：[fromParsed] 从 `dirPath` 生成的目录名候选。
  ///
  /// ## 为什么挂在 `ScrapeQuery` 上、而不是新造一个「查询链」类型
  ///
  /// 链的持有者是 `WorkSeedBook._queries`（`Map<String, ScrapeQuery>`）与
  /// `WorkScraper._queryFor`，两处都是「一个作品一条查询」。新造一个类型
  /// 就要把这两处的类型、以及它们的所有调用点一起改 —— 换来的只是
  /// 「`ScrapeQuery` 里不会出现 `ScrapeQuery`」这一条形式上的洁癖。
  ///
  /// ⚠️ **兜底自己不再带兜底**（[fromParsed] 造出来的那几条 `fallbacks`
  /// 恒为空）。链只有一层深，`ScraperPipeline.scrape` 的循环也就没有递归。
  final List<ScrapeQuery> fallbacks;

  bool get isEpisode => kind == MediaKind.episode;

  /// 这条查询会实际发出的搜索词条数（含兜底）。
  ///
  /// 给测试与「这次刮削花了多少额度」的排查用 —— 豆瓣匿名额度只有约 10 个，
  /// 而链每多一条就多花一个词。
  int get attemptCount => 1 + fallbacks.length;

  @override
  String toString() =>
      'ScrapeQuery("$title"${alternateTitle == null ? "" : " / $alternateTitle"}, '
      '${kind.name}, y=$year, s=$season, e=$episode'
      '${requireExactTitle ? ", 精确同名档" : ""}'
      '${fallbacks.isEmpty ? "" : ", 兜底 ${fallbacks.map((f) => f.title).join(" → ")}"})';
}
