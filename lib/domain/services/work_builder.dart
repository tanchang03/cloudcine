import '../../core/utils/filename_parser.dart';
import '../../core/utils/media_category.dart';
import '../entities/drive_provider.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';

/// 一部作品的**种子**：遍历期累积的、与刮削无关的那部分信息。
///
/// 「种子」与「作品行」分开的原因：遍历时只可能拿到本地信息（文件名解析 +
/// 网盘给的缩略图），而海报/简介要等刮削。先建种子、后建行，才能做到
/// 「边扫边出作品」—— 详见 `ScanService` 里 `flushWorks` 的说明。
class WorkSeed {
  WorkSeed({
    required this.kind,
    required this.title,
    required this.category,
    this.year,
  });

  final MediaKind kind;
  final String title;
  final int? year;

  /// 一级分类（电影 / 剧集 / 动漫 / 综艺 / 纪录片 / 其他）。
  ///
  /// 在**第一条**命中这个分组的文件上判定一次，之后不再改 —— 同一部剧的
  /// 每一集文件名可能差异很大（`S01E01` 有季集号、`SP` 特别篇没有），
  /// 逐集重判会让分类在「剧集」和「其他」之间跳。以第一条为准更稳定，
  /// 而第一条通常是最规整的那一集。
  final MediaCategory category;

  /// 网盘服务端缩略图地址（**未刮削时的封面兜底**）。
  ///
  /// 只取分组里的**第一条**有缩略图的 —— 一部剧几十集，每集都存一份地址
  /// 没有意义：作品海报只需要一张，而且用户认的是「这部剧」而不是「第 7 集
  /// 的那一帧」。
  ///
  /// 它只在**没有在线刮削海报**时才被用上（见 [WorkSeedBook.build]）。
  ///
  /// ⚠️ 它和 [posterFaceX] 是**一对**，只在 [WorkSeedBook.add] 里那一处 `if`
  /// 里一起赋值。构造函数故意不收这两个参数 —— 那样就会出现「构造时给了地址、
  /// 循环里再补锚点」这种半截状态，而它们描述的是同一张图。
  String? posterUrl;

  /// [posterUrl] 那张图里**人物所在的水平位置**（0~1），来自夸克人脸框。
  ///
  /// ⚠️ 与 [posterUrl] 是**一对**，必须同进同退：它们描述的是同一张图。
  /// 只换地址不换锚点 = 拿上一张图的人脸位置去裁这一张。
  double? posterFaceX;

  int itemCount = 0;
  int totalBytes = 0;

  /// 这个作品里出现过的**季号**（`parsed.season`；没标季的记 `0`）。
  ///
  /// 攒 `Set` 而不是计数器：一季里几十集，计数器会把「12 集」当成「12 季」。
  /// `0` 代表「未标季」，展示时不计入季数。
  final Set<int> seasons = {};

  /// 已标季号的季数（不含「未标季」那一桶）。列表页卡片显示「N 季」用它。
  int get seasonCount => seasons.where((s) => s > 0).length;

  /// 作品下所有文件的**网盘修改时间**最大值。
  ///
  /// 新增一集或替换一集时，这个值会变大，整个作品在「最近修改」排序里
  /// 就会浮到前面 —— 这比 `updatedAt`（入库时间）更能反映「用户刚动过」
  /// 这件事。
  DateTime? lastModifiedAt;

  @override
  String toString() =>
      'WorkSeed("$title", ${kind.name}, $category, $itemCount 项)';
}

/// 分组种子的累积器：**扫描与局部发现共用的归组真源**。
///
/// ## 为什么必须是同一个实例类型
///
/// 全盘扫描和文件夹里的「发现」都会往媒体库写作品行。两处各写一遍归组
/// 逻辑的话，同一个文件走两条路会得到不同的 `groupKey` / `category` /
/// 封面 —— 而这是**静默**的：媒体库里会多出一个重复的作品格子，
/// 或者分类莫名从「动漫」变成「剧集」，没有任何报错。
///
/// 所以「怎么归组、怎么取种、怎么建行」只有这一份实现。
///
/// ## 三个内部集合的分工
///
///   - `_seeds`：分组键 → 种子（累积计数与封面）
///   - `_queries`：分组键 → 刮削查询（遍历结束后统一跑；用 Map 天然去重）
///   - `_dirty`：还没写成作品行的分组键（`flush()` 消费）
class WorkSeedBook {
  final Map<String, WorkSeed> _seeds = {};
  final Map<String, ScrapeQuery> _queries = {};
  final Set<String> _dirty = {};

  /// 全部刮削查询。键是分组键，供遍历结束后的刮削阶段使用。
  Map<String, ScrapeQuery> get queries => _queries;

  /// 已发现的分组数（作品数）。
  int get groupCount => _seeds.length;

  bool get isEmpty => _seeds.isEmpty;

  /// 还没写成作品行的分组键。空表示没有待落库的。
  bool get hasDirty => _dirty.isNotEmpty;

  WorkSeed? seedOf(String key) => _seeds[key];

  /// 收一条**已识别为视频**的媒体项。
  ///
  /// 返回 `false` 表示这条项**连片名都提不出来**（`hasUsableTitle` 为假），
  /// 因此**不归组**：它仍然会作为媒体项入库，只是没有作品行。
  /// 这是刻意的 —— 宁可让它在库里以文件名示人，也不要拿半个名字去
  /// 建一个注定要重刮的作品。
  ///
  /// ## 归组门槛（[ParsedMediaName.hasUsableTitle]）必须**宽于**刮削门槛
  /// （[ParsedMediaName.isConfident]）
  ///
  /// ⛔ 这两个门槛曾经是同一个 —— 这里直接拿 `ScrapeQuery.fromParsed` 的
  /// 空值当「不归组」的判据。后果是**静默丢数据**：
  ///
  /// 2026-10-03，`/来自：分享/奥德赛/1080P.mkv`：文件名整串只有一个分辨率
  /// 标记，片名靠目录名兜底成「奥德赛」，`kind=movie` 而 `year=null` →
  /// `isConfident=false` → `ScrapeQuery` 为 null → 不归组 → `media_works`
  /// 一条都没有 → 媒体库页面（读 `listWorks`）空空如也，而目录视图里那一条
  /// 还标着「已入库」且能播。日志里报的却是「发现成功：媒体 1（新增 1）,
  /// 作品 0」—— 用户看不出哪里错了。
  ///
  /// 所以现在的规则是：**片名像个名字就先建作品行**，年份/类型不够可信只
  /// 让它**不进 `_queries`**（不刮削）。不刮削只是没海报，本地片名照样能用。
  ///
  /// ⚠️ 这也让「同一部电影被拆成两条」的口径保持一致：只要片名解析得出，
  /// 同一个文件走全盘扫描与走文件夹「发现」都会归到同一组。
  bool add({
    required ParsedMediaName parsed,
    required MediaItem item,
    required String dirPath,
  }) {
    final query = ScrapeQuery.fromParsed(parsed, dirPath: dirPath);
    if (query != null) {
      _queries.putIfAbsent(parsed.groupKey, () => query);
    } else if (!parsed.hasUsableTitle) {
      // 片名提不出来，或只是一串编号/分辨率 → 不归组（原行为，一字不动）。
      return false;
    }

    final seed = _seeds.putIfAbsent(
      parsed.groupKey,
      () => WorkSeed(
        kind: parsed.kind,
        title: parsed.title!,
        year: parsed.year,
        // 分类判定用「文件名 + 目录路径 + 片名」三处证据：
        // 网盘上「动漫」这类信息几乎总是写在目录名里
        // （`/动漫/进击的巨人/…`），只看片名会大面积漏判。
        category: MediaCategoryGuesser.guess(
          kind: parsed.kind,
          title: parsed.title,
          fileName: item.name,
          dirPath: dirPath,
        ),
      ),
    );

    // 第一条没缩略图时用后面的补上（夸克对约 30% 的视频还没生成预览图，
    // 而同一部剧里通常总有一集是有的）。
    //
    // ⚠️ 地址和锚点**必须在同一次赋值里一起写**：它们描述的是同一张图。
    // 拆成两次写（先 `posterUrl ??=`、再 `posterFaceX ??=`）会在
    // 「第一集有图但没人脸、第二集有人脸但没图」时拼出一对不匹配的
    // 组合 —— 拿甲图的人脸位置去裁乙图。写成 `if` 而不是 `??=`，
    // 就是为了让这两行在结构上无法分开。
    if (seed.posterUrl == null && item.thumbUrl != null) {
      seed.posterUrl = item.thumbUrl;
      seed.posterFaceX = item.faceAnchorX;
    }

    seed.itemCount++;
    seed.totalBytes += item.sizeBytes ?? 0;
    // 季号来自 `parsed`（不是 `item`）：两者同源，但 `parsed` 是**这次扫描
    // 的解析结果**，而 `item` 在「已入库」路径上可能是库里那一条。
    seed.seasons.add(parsed.season ?? 0);
    final m = item.modifiedAt;
    if (m != null) {
      final current = seed.lastModifiedAt;
      if (current == null || m.isAfter(current)) {
        seed.lastModifiedAt = m;
      }
    }
    _dirty.add(parsed.groupKey);
    return true;
  }

  /// 把 [dirtyKeys] 里的分组建成作品行（元数据留空，刮削阶段再补）。
  ///
  /// 与刮削阶段走的是**同一个** [build]，所以 `mergeWorkForUpsert` 的
  /// 「保护已有元数据」规则照样生效：先建空元数据的行，不会把后来
  /// 刮削到的海报/简介顶掉。
  List<MediaWork> buildDirty({
    required DriveProvider provider,
    required DateTime now,
  }) {
    final works = <MediaWork>[];
    for (final key in _dirty) {
      final work = build(key, provider: provider, meta: null, now: now);
      if (work != null) works.add(work);
    }
    return works;
  }

  /// 消费掉「待落库」标记。调用方在 `buildDirty` 落库**之后**调它。
  void markClean() => _dirty.clear();

  /// 构造一部作品行。
  ///
  /// 刮削结果优先；没有就退到本地解析的标题与年份 —— 这样即使一个刮削器
  /// 都没配，媒体库里也有正常的标题，而不是一串文件名。
  ///
  /// ## 海报的两级来源
  ///
  /// `TMDB 海报` → `网盘缩略图`。第二级是本项目「无刮削也要有画面」的关键：
  /// 夸克给每个视频生成了服务端预览图（实测 640×360 WebP），
  /// 直接拿它当作品封面，媒体库就不再是一墙灰块。
  ///
  /// 顺序不能反：TMDB 的海报是**竖版作品海报**（2:3），网盘缩略图是
  /// **视频画面**（16:9）。有正规海报时用视频截图会显得很不专业。
  MediaWork? build(
    String key, {
    required DriveProvider provider,
    required ScrapedMetadata? meta,
    required DateTime now,
  }) {
    final seed = _seeds[key];
    if (seed == null) return null;

    // 取一次，避免下面两处各算一遍导致「地址用刮削的、锚点用网盘的」这种
    // 只有视觉上才看得出来的错配。
    final scrapedPoster = _nonEmpty(meta?.posterUrl);

    return MediaWork(
      key: key,
      provider: provider,
      kind: seed.kind,
      category: seed.category,
      title: meta?.title ?? seed.title,
      originalTitle: meta?.originalTitle,
      year: meta?.year ?? seed.year,
      overview: meta?.overview,
      posterUrl: scrapedPoster ?? seed.posterUrl,
      // 锚点跟着**实际用的那张图**走：
      //   - 用了刮削海报 → 它是 2:3 的竖版作品海报，铺满格子、不裁切，
      //     不需要锚点（拿视频帧的人脸位置去裁它只会裁错地方）；
      //   - 用了网盘缩略图 → 16:9 要裁成竖版，此时锚点才是「凸显人物」的依据。
      posterFaceX: scrapedPoster == null ? seed.posterFaceX : null,
      backdropUrl: meta?.backdropUrl,
      rating: meta?.rating,
      genres: meta?.genres ?? const [],
      onlineId: meta?.onlineId,
      source: meta?.source ?? ScrapeSource.local,
      scrapedAt: meta?.source == ScrapeSource.online ? now : null,
      itemCount: seed.itemCount,
      totalBytes: seed.totalBytes,
      seasonCount: seed.seasonCount,
      lastModifiedAt: seed.lastModifiedAt,
      // firstSeenAt 由 mergeWorkForUpsert 处理：新作品填 now，已有作品保留旧值。
      updatedAt: now,
    );
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}
