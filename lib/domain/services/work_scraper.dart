import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/filename_parser.dart';
import '../../core/utils/media_category.dart';
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

  /// 用户**清掉了在线刮削信息**，改成自己敲的片名与分类
  /// （详情页「自定义」按钮，走 `MediaRepository.customizeWork`）。
  ///
  /// 与 [scraped] 分开是必须的：两者的成功文案不同，而且 [WorkScrapeOutcome]
  /// 的 `metadata` 在自定义这条路上是 `null` —— 把自定义也报成 [scraped]，
  /// 成功文案里那句 `metadata!.title` 会直接抛。
  customized,
}

/// 这次刮削是**谁发起的**。
///
/// ## 为什么它不是一个可有可无的装饰
///
/// [WorkScrapeStatus.notFound] 在两个通道里是**两件不同的事**，而它们一度
/// 共用同一句文案 —— 于是手动对话框里会冒出一句讲自动流程的话
/// （「在线源都没有找到匹配的条目，可能是片名解析不准」）。用户刚刚亲眼
/// 看到了一列候选、亲手点了一条，被告知「没找到条目」，只会以为界面坏了。
///
///   - [auto]：**算法**拿着文件名解析出来的词去搜，没有找到信得过的条目。
///     下一步是「换个词自己搜」，所以文案要把人引到旁边的「手动」按钮上。
///   - [manual]：**用户亲手**从候选里挑了一条，但这一条解析不出完整元数据
///     （条目被删、接口改版、详情返回了空对象）。下一步是「换一条候选」——
///     这跟他敲的词没关系，叫他去改片名是误导。
enum ScrapeChannel {
  /// 详情页「刮削」按钮发起。
  ///
  /// ⚠️ 扫描期那条自动刮削（`ScanService`）走的是 `ScraperPipeline`，
  /// **不产出** [WorkScrapeOutcome]，所以 `auto` 只有这一个来源。也正因为
  /// 来源唯一、且详情页上「手动」按钮就并排放在「刮削」旁边，auto 那条
  /// 文案才敢写死「点旁边的『手动』」。
  auto,

  /// 手动刮削对话框里用户选中候选后发起。
  manual,
}

/// 刮一部作品的产物。
class WorkScrapeOutcome {
  const WorkScrapeOutcome({
    required this.status,
    required this.channel,
    this.work,
    this.metadata,
    this.sourceName,
  });

  final WorkScrapeStatus status;

  /// 谁发起的。决定 [message] 用哪一套说法，见 [ScrapeChannel]。
  ///
  /// **故意不给默认值**：两个通道的说法混用正是当初那个 bug，而默认值会让
  /// 「漏填」这件事静默地编译通过。
  final ScrapeChannel channel;

  /// 落库后的作品行（[WorkScrapeStatus.scraped] 时非空）。
  final MediaWork? work;

  /// 命中的元数据（[WorkScrapeStatus.scraped] 时非空）。
  final ScrapedMetadata? metadata;

  /// 命中来源的展示名（如「豆瓣」「TMDB」），用于在 [message] 里提示用户
  /// 「这条结果是从哪个源刮来的」。手动通道由 [applyCandidate] 从候选的
  /// `source` 经流水线 `displayNameOf` 查得；自动通道暂留空。
  final String? sourceName;

  /// 面向用户的一句话结果。
  ///
  /// 按 `(状态, 通道)` **两个维度**取文案 —— 只按状态分是不够的，理由见
  /// [ScrapeChannel]。成功那条两个通道共用（「已刮削：…」对谁说都一样），
  /// 但会附上来源名（手动通道独有），让用户知道「这条结果来自哪个源」。
  String get message => switch ((status, channel)) {
        (WorkScrapeStatus.scraped, _) =>
          '已刮削：${metadata!.title}'
              '${metadata!.year == null ? "" : "（${metadata!.year}）"}'
              '${sourceName == null ? "" : " · $sourceName"}',
        (WorkScrapeStatus.customized, _) =>
          '已清除在线刮削信息，设为「${work!.title}」· ${work!.category.label}'
              ' —— 重扫与自动刮削都不会再覆盖它。',
        (WorkScrapeStatus.notFound, ScrapeChannel.auto) =>
          '在线源都没找到信得过的条目 —— 可能是片名解析不准，'
              '或这个词在数据源里没有收录。点旁边的「手动」自己敲片名再搜；'
              '如果这片子本来就不在数据源里（自制、演唱会、赛事…），'
              '点「自定义」直接写死片名和分类。',
        (WorkScrapeStatus.notFound, ScrapeChannel.manual) =>
          '这一条解析不出完整信息（条目可能已被删除或改版），换一条候选再试。',
        (WorkScrapeStatus.noQuery, _) => '这个文件名解析不出可信的片名，无法刮削。',
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
    // 本方法产出的结果**全部**属于自动通道。写成方法头的局部常量、而不是
    // 在每个 `return` 处内联，是为了让「这里不产出手动通道的结果」在方法头
    // 一眼可见 —— 文案错配正是从「两处返回混在一起」开始的。
    const channel = ScrapeChannel.auto;

    try {
      final items = await _library.itemsForWork(work.key);
      if (items.isEmpty) {
        return const WorkScrapeOutcome(
          status: WorkScrapeStatus.noQuery,
          channel: channel,
        );
      }

      final query = _queryFor(items);
      if (query == null) {
        diag.info('刮削', '${work.key} 文件名解析不出可信片名，跳过');
        return const WorkScrapeOutcome(
          status: WorkScrapeStatus.noQuery,
          channel: channel,
        );
      }

      final meta = await _pipeline.scrape(query);
      // ⚠️ 必须看 `source`：流水线的兜底是**本地文件名解析**，它永远成功。
      // 只判 `meta != null` 会把「什么都没刮到」当成成功，然后把
      // 「文件名解析」的结果当成在线结果写进库（`source` 变成 online），
      // 用户会看到「已刮削」但海报简介一个都没有。
      if (meta == null || meta.source != ScrapeSource.online) {
        diag.info('刮削', '${work.key} 在线源未命中：$query');
        return const WorkScrapeOutcome(
          status: WorkScrapeStatus.notFound,
          channel: channel,
        );
      }

      final merged = _apply(work, meta);
      // `overrideManual: true`：用户**亲手点了**这个按钮，所以即使这部作品
      // 是他之前「自定义」过的（`source == manual`），这次也照刮不误 ——
      // 那是他唯一能把作品交还给在线源的路。扫描期那条自动刮削没有这个
      // 开关，碰不到自定义过的行（见 `mergeWorkForUpsert`）。
      await _library.upsertWorks(
        [merged],
        now: _clock(),
        overrideManual: true,
      );
      diag.info('刮削', '${work.key} 已更新：${meta.title}');
      return WorkScrapeOutcome(
        status: WorkScrapeStatus.scraped,
        channel: channel,
        work: merged,
        metadata: meta,
      );
    } catch (e) {
      diag.warn('刮削', '${work.key} 刮削失败，按未命中处理', error: e);
      return const WorkScrapeOutcome(
        status: WorkScrapeStatus.notFound,
        channel: channel,
      );
    }
  }

  /// 从作品的文件里挑一条代表，解析出查询。
  ///
  /// 挑法与详情页「播放」按钮一致（`WorkDetail.features.first`）：**跳过花絮
  /// 与样片**。`-trailer.mkv` 解析出来的片名常常带着 `trailer`，拿它去搜
  /// 只会搜到一堆不相关的东西。
  ///
  /// ⚠️ 必须传 `dirPath` 而不是末级目录名 —— 与扫描期（`ScanService`）
  /// **完全同一条解析路径**。两处一旦不同，同一个作品「扫描期刮出来是 A、
  /// 点按钮刮出来是 B」，而用户只会觉得「这个按钮有时候不准」。
  ScrapeQuery? _queryFor(List<MediaItem> items) {
    final features = items.where((i) => !i.isSampleOrExtra).toList();
    final pool = features.isNotEmpty ? features : items;
    for (final item in pool) {
      final parsed = _parser.parse(
        item.name,
        dirPath: item.dirPath,
      );
      final query = ScrapeQuery.fromParsed(parsed);
      if (query != null) return query;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // 手动刮削：用户自己敲片名，从候选里挑一条
  // -------------------------------------------------------------------

  /// 手动刮削对话框的**预填**查询 —— 从文件名重新解析一次。
  ///
  /// ## 为什么要有它
  ///
  /// 自动刮削的失败大多是**片名解析不准**，而对话框如果预填「库里已存的
  /// 标题」，用户看到的会是上一次刮错的结果（`低俗小说`），他得先意识到
  /// 「这个框里是错的」才会去改。预填**文件名解析出来的原始词**
  /// （`超z级z马z力z欧z银z河z大z电影aa`）反而更有用：它诚实地展示了
  /// 「自动刮削拿着这么个词去搜」，用户一眼就知道该删掉那些 `z`。
  ///
  /// 解析不出任何可信片名时返回 `null`，调用方退回用库里已有的标题。
  Future<ScrapeQuery?> queryFor(MediaWork work) async {
    try {
      final items = await _library.itemsForWork(work.key);
      if (items.isEmpty) return null;
      return _queryFor(items);
    } catch (e) {
      diag.warn('刮削', '${work.key} 预填查询失败，改用手工输入', error: e);
      return null;
    }
  }

  /// 按用户输入搜候选。**永不抛异常**，失败就是空列表。
  ///
  /// 与 [scrape] 一样不设「结果为空」以外的失败信号：对话框那边
  /// 无论哪种原因都只能说「换个词再试」，区分了对用户没有额外价值。
  ///
  /// [sourceId] 非空时只搜那一个源 —— 用户在手动对话框里选了「只在豆瓣搜」
  /// 时，没必要把 TMDB 的额度也花掉。`null` = 搜全部启用的源。
  Future<List<ScrapeCandidate>> searchCandidates(
    ScrapeQuery query, {
    String? sourceId,
  }) async {
    try {
      final found = await _pipeline.search(query, sourceId: sourceId);
      diag.info('刮削', '手动刮削搜 "${query.title}"：${found.length} 条候选');
      return found;
    } catch (e) {
      diag.warn('刮削', '手动刮削搜索失败', error: e);
      return const [];
    }
  }

  /// 把用户选中的候选解析成完整元数据并落库。
  ///
  /// ## 与 [scrape] 的一处关键差别
  ///
  /// [scrape] 必须判 `meta.source != online`（因为流水线兜底是本地文件名
  /// 解析，它永远成功）；这里**不用判** —— 候选只可能来自在线源，
  /// 用户亲手点的那一条就是他要的。多判一次反而会挡掉将来可能出现的
  /// 「本地候选」。
  ///
  /// 另外**这里不看匹配闸门**：闸门是替自动流程做判断的，用户已经做过
  /// 判断了。目录名 `超z级z马z力z欧z银z河z大z电影aa` 正是被闸门拦下来的
  /// 那类输入 —— 用户手动选中《超级马力欧银河大电影》时，闸门必须让路。
  Future<WorkScrapeOutcome> applyCandidate(
    MediaWork work,
    ScrapeCandidate candidate,
  ) async {
    // 与 [scrape] 对称：本方法产出的结果全部属于**手动**通道。
    const channel = ScrapeChannel.manual;

    try {
      final meta = await _pipeline.resolve(candidate);
      if (meta == null) {
        diag.info('刮削', '${work.key} 候选 ${candidate.source}/${candidate.sourceId} 解析失败');
        return const WorkScrapeOutcome(
          status: WorkScrapeStatus.notFound,
          channel: channel,
        );
      }

      final merged = _apply(work, meta);
      // 同 [scrape]：用户亲手选的候选，覆盖自定义过的行是**他的意图**。
      await _library.upsertWorks(
        [merged],
        now: _clock(),
        overrideManual: true,
      );
      diag.info(
        '刮削',
        '${work.key} 手动选中 ${candidate.source}/${candidate.sourceId} → ${meta.title}',
      );
      return WorkScrapeOutcome(
        status: WorkScrapeStatus.scraped,
        channel: channel,
        work: merged,
        metadata: meta,
        // 让用户在结果消息里看到「这条来自哪个源」—— 手动刮削时
        // 用户选了候选、也选了搜索源，来源信息对他是有意义的。
        sourceName: _pipeline.displayNameOf(candidate.source),
      );
    } catch (e) {
      diag.warn('刮削', '${work.key} 应用候选失败，按未命中处理', error: e);
      return const WorkScrapeOutcome(
        status: WorkScrapeStatus.notFound,
        channel: channel,
      );
    }
  }

  /// 把刮削结果合并进作品行。
  ///
  /// ## 四处必须显式处理的地方
  ///
  ///   - **分类只在 `genres` 给出结论时才覆盖**（见下面那段长注释）。
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
      category: _categoryFor(work, meta),
      categoryManual: work.categoryManual,
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
      // 用户手敲过的类型标签不被刮削覆盖：他可能就是为了修「刮削返回的
      // 类型是错的」才动手的，再刮一次又冲掉等于白改。
      genres: work.genresManual
          ? work.genres
          : (meta.genres.isEmpty ? work.genres : meta.genres),
      genresManual: work.genresManual,
      onlineId: meta.onlineId ?? work.onlineId,
      source: ScrapeSource.online,
      scrapedAt: _clock(),
      // 文件数与体积是**扫描的产物**，与刮削无关。抄一遍是为了让
      // `upsertWorks` 的合并分支原样保留它们 —— 传 0 会把库里的数字抹掉。
      itemCount: work.itemCount,
      totalBytes: work.totalBytes,
      // 同上：季数也是扫描的产物（刮削不碰 `media_items`）。
      seasonCount: work.seasonCount,
      // 与扫描无关、与刮削也无关，但它是「最近修改」排序的唯一依据。
      // 不抄的话构造器默认 null，落库后这一列被置空，刮完的电影会从
      // 列表前面直接跳到末尾（NULL 在 DESC 排序里垫底）。
      lastModifiedAt: work.lastModifiedAt,
      firstSeenAt: work.firstSeenAt,
      lastPlayedAt: work.lastPlayedAt,
      updatedAt: _clock(),
    );
  }

  /// 刮削之后这部作品该归到哪一栏。
  ///
  /// ## 为什么这里不能直接 `MediaCategoryGuesser.guess(...)`
  ///
  /// `guess` 的最后一步是「按 `kind` 落到电影 / 剧集」——那是**兜底**，
  /// 只在前面所有证据都没命中时才走。而这里要的是「刮削**新增**了什么证据」，
  /// 不是「从头再判一次」。
  ///
  /// 用 `guess` 会有一个很难查的后果：用户把综艺放在 `/综艺/奔跑吧/`
  /// （扫描期靠目录路径正确地判成 [MediaCategory.variety]），而 TMDB 对国产
  /// 综艺常常给不出「真人秀」这个类型 —— 于是 `guess` 走到 kind 兜底，
  /// 把「综艺」**冲成「剧集」**。用户看到的是「我的综艺栏目空了」。
  ///
  /// ## 所以规则是：genres 说话才算，不说就闭嘴
  ///
  ///   - `fromGenres` 有结论（动画 / 纪录片 / 真人秀）→ 用它。这是 TMDB 的
  ///     真实类型，比目录名和关键词都准 —— `MediaCategoryGuesser` 自己也是
  ///     把 genres 排在第一优先级的，两边口径必须一致；
  ///   - `fromGenres` 没结论（剧情 / 科幻 / 喜剧…这些不改变栏目）→
  ///     **原样保留扫描期的判定**。
  ///
  /// ## 这条路径以前是死的
  ///
  /// 在加上这一行之前，`fromGenres` 在整个项目里**永远不会被执行**：
  /// 扫描期调 `guess` 时不传 `genres`（那时还没刮削），而两个「分类回填」
  /// 入口都只处理 `category` 为空串的老行 —— 刮削过的作品分类非空，
  /// 永远轮不到。结果是：一部目录名里没有「动漫」二字的动画电影，
  /// 刮到了 `genres: ['动画']`、落进了库，却始终留在「电影」栏。
  ///
  /// ⚠️ 改这里要同步改 `MediaRepositoryImpl.backfillWorkCategories` ——
  /// 那边负责把**已经刮过**的作品按同一套规则修正过来，否则老库要等
  /// 用户逐部重刮才生效。
  /// ## 用户手动指定的分类不受刮削影响
  ///
  /// `work.categoryManual == true` 时直接返回原值 —— 用户改过的分类
  /// 不该被 TMDB 的 genres 悄悄覆盖。用户随时可以重新手动指定来「解锁」。
  ///
  /// ## 折算用的必须是「真正会落库的那份 genres」
  ///
  /// `work.genresManual == true` 时，`_apply` 会把 `work.genres` 原样带下去
  /// （而不是 `meta.genres`）。那么分类也必须从 `work.genres` 折算 ——
  /// 否则会出现「类型标签写着『动画』、分类却是『电影』」这种自相矛盾的行，
  /// 而它不会报错，只会让分类栏和详情页各说各话。
  MediaCategory _categoryFor(MediaWork work, ScrapedMetadata meta) {
    if (work.categoryManual) return work.category;
    final genres = work.genresManual ? work.genres : meta.genres;
    final byGenre = MediaCategoryGuesser.fromGenres(genres);
    if (byGenre == null) return work.category;
    if (byGenre != work.category) {
      diag.info(
        '刮削',
        '${work.key} 分类 ${work.category.label} → ${byGenre.label}'
            '（类型 ${genres.join("/")}）',
      );
    }
    return byGenre;
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();
}
