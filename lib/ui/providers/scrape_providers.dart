import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/media_category.dart';
import '../../data/scrape/douban_client.dart';
import '../../data/scrape/tmdb_client.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/scraper.dart';
import '../../domain/services/work_merge_planner.dart';
import '../../domain/services/work_merge_service.dart';
import '../../domain/services/work_scraper.dart';
import 'app_providers.dart';
import 'library_providers.dart';
import 'library_refresh_providers.dart';
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

/// 手动刮削可选的源列表（供对话框渲染「选哪个源」的选择器）。
///
/// 排除本地兜底（它给不出候选）。只有一个在线源时 UI 那边会隐藏选择器。
final manualScrapeSourcesProvider =
    Provider<List<({String id, String displayName})>>((ref) {
  return ref.watch(scraperPipelineProvider).availableSources;
});

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

      // 刮到之后立刻看一眼：这一部和别的作品刮到了同一条目吗？
      //
      // 放在这里而不是等下一次全盘扫描，是因为「两个格子变成一个」这件事
      // 如果延后几分钟才发生，用户已经不在这个页面上了，只会觉得
      // 「我的电影莫名其妙少了一部」。
      //
      // ⚠️ 传 `outcome.work`（落库后的行）而不是 `work`（刮削前的行）：
      // 判「有没有兄弟」用的是 `onlineId`，而它正是这次刮削刚写进去的 ——
      // 用旧行会永远找不到兄弟。
      final clause = ok ? await _mergeClauseAfterScrape(outcome.work ?? work) : null;

      state = WorkScrapeState(
        messageKey: workKey,
        message: clause == null ? outcome.message : '${outcome.message} $clause',
        ok: ok,
      );

      if (ok) _refreshAfter(work, outcome);
    } catch (e) {
      state = WorkScrapeState(
        messageKey: workKey,
        message: '刮削失败：$e',
      );
    }
  }

  /// 手动刮削：把用户选中的候选应用上去。
  ///
  /// 返回刮削产物供调用方（对话框）判断成败 —— 对话框要据此决定是关掉
  /// 还是留在原地让用户换一条。`null` = 作品已经不在库里了。
  ///
  /// 复用 [WorkScrapeState.runningKey] 而不是另开一个状态：两个入口
  /// （自动 / 手动）**不能同时跑** —— 同一部作品的两次刮削会互相覆盖，
  /// 而用户看到的会是先返回的那一次的结果。
  ///
  /// [category] 是对话框那个「媒体类型」选择框的值（`null` = 用户没动它）。
  /// 透传给 [WorkScraper.applyCandidate]。
  Future<WorkScrapeOutcome?> applyCandidate(
    String workKey,
    ScrapeCandidate candidate, {
    MediaCategory? category,
  }) async {
    if (state.runningKey != null) return null;
    state = WorkScrapeState(runningKey: workKey);

    try {
      final work = await ref.read(mediaRepositoryProvider).workByKey(workKey);
      if (work == null) {
        state = WorkScrapeState(
          messageKey: workKey,
          message: '找不到这部作品，它可能已经被重新扫描移除。',
        );
        return null;
      }

      final outcome = await ref
          .read(workScraperProvider)
          .applyCandidate(work, candidate, category: category);
      final ok = outcome.status == WorkScrapeStatus.scraped;

      // 手动选的那一条同样是「同一条目」的强证据 —— 用户亲手点了候选，
      // 所以这里比自动通道更应该归一。文案里也要说清楚，否则用户会以为
      // 「我明明只点了这一部，怎么旁边那部没了」。
      //
      // ⚠️ 传 `outcome.work`（落库后的行）：判兄弟用的 `onlineId` 是这次
      // 刮削刚写进去的，用旧行永远找不到兄弟。见 `scrape()` 里同一处。
      final clause =
          ok ? await _mergeClauseAfterScrape(outcome.work ?? work) : null;

      state = WorkScrapeState(
        messageKey: workKey,
        message:
            clause == null ? outcome.message : '${outcome.message} $clause',
        ok: ok,
      );

      if (ok) _refreshAfter(work, outcome);
      return outcome;
    } catch (e) {
      state = WorkScrapeState(
        messageKey: workKey,
        message: '刮削失败：$e',
      );
      return null;
    }
  }

  /// 「自定义」：清掉在线刮削信息，改成用户自己敲的片名与分类。
  ///
  /// 返回写库后的作品行；作品已不在库里、或另一个写操作正占着
  /// [WorkScrapeState.runningKey] 时返回 `null`。
  ///
  /// ## 为什么与两个刮削入口共用 `runningKey`
  ///
  /// 同一部作品不能有两笔写操作并发跑 —— 用户看到的会是先返回的那一次
  /// 的结果，而另一次的提示还挂在屏幕上。三个入口（自动 / 手动 / 自定义）
  /// 都是「改这一行」，所以共用同一个互斥位。
  ///
  /// ## 刷新交给 [_refreshAfter]
  ///
  /// 这个动作会同时改片名、分类、海报、年份、类型 —— 列表、详情页、三组
  /// 角标都可能变。复用同一套刷新规则，免得「自定义之后分类栏的数字没
  /// 跟上」变成又一处要单独记得的例外。
  Future<WorkScrapeOutcome?> customize(
    String workKey, {
    required String title,
    required MediaCategory category,
  }) async {
    if (state.runningKey != null) return null;
    state = WorkScrapeState(runningKey: workKey);

    try {
      final repo = ref.read(mediaRepositoryProvider);
      final work = await repo.workByKey(workKey);
      if (work == null) {
        state = WorkScrapeState(
          messageKey: workKey,
          message: '找不到这部作品，它可能已经被重新扫描移除。',
        );
        return null;
      }

      final updated = await repo.customizeWork(
        workKey,
        title: title,
        category: category,
      );
      if (updated == null) {
        state = WorkScrapeState(
          messageKey: workKey,
          message: '找不到这部作品，它可能已经被重新扫描移除。',
        );
        return null;
      }

      // 「清空刮削数据」这条路以前完全不留痕，是整条链路最难查的一环：
      // 它会把分类**锁死**（`categoryManual=true`），而之后的手动刮削若
      // 把「媒体类型」留在默认的「自动」，就会一直保持这个锁定的分类
      // （见 `WorkScraper._categoryFor` 的第 ② 步）。把这一刻写下来，
      // 「分类为什么改不动」才有据可查。
      diag.info(
        '刮削',
        '$workKey 自定义（清空在线信息）：片名="$title"，'
            '分类锁为 ${category.label}（categoryManual=true），'
            // 封面那一列的结果也记一笔：「清完之后还有没有图」是这条路上
            // 唯一看得见的产物，而它可能因为名下文件都没缩略图而真的空着
            // —— 写下来，「自定义之后封面没了」就不用从库里反推。
            '封面=${updated.posterUrl ?? '无（名下文件都没有网盘缩略图）'}',
      );

      final outcome = WorkScrapeOutcome(
        status: WorkScrapeStatus.customized,
        channel: ScrapeChannel.manual,
        work: updated,
      );
      state = WorkScrapeState(
        messageKey: workKey,
        message: outcome.message,
        ok: true,
      );

      _refreshAfter(work, outcome);
      return outcome;
    } catch (e) {
      state = WorkScrapeState(
        messageKey: workKey,
        message: '保存失败：$e',
      );
      return null;
    }
  }

  /// 刮削成功后要把哪些东西重算一遍。
  ///
  ///   - **详情页**要重画（新标题 / 海报 / 简介 / 类型标签）；
  ///   - **海报墙**也要 —— 否则退回列表还是旧卡片，用户会以为刮削没生效；
  ///   - **分类栏的角标**（[categoryCountsProvider]）是**另一次 `GROUP BY`**
  ///     的结果，不会跟着 [workListProvider] 一起重算。
  ///
  /// 最后那一条是加了「刮削会改分类」之后才出现的：一部片子从「电影」
  /// 挪到「动漫」时，两个栏目的数字得同时变 —— 不作废的话它们会一直停在
  /// 旧值直到重启应用，而用户看到的现象是「分类没生效」，
  /// 但他点进「动漫」栏里确实能看到那部片子，于是更迷惑。
  ///
  /// 只在**分类真的变了**时才作废：那是一次全表 `GROUP BY`，
  /// 而绝大多数刮削（补海报、修简介）并不会动分类。
  ///
  /// 年份 / 类型同理（它们是筛选面板另外两组选项的来源）：刮削会同时改
  /// `year` 与 `genres`，不作废的话面板上会一直列着「2020 · 3 部」
  /// 这种过期数字，而用户点进去发现是 4 部。
  /// 刮完之后立刻看一眼「这一部和别的作品是不是同一条目」，并拼一句给用户看的话。
  ///
  /// ## 它回答两个问题
  ///
  ///   1. **库里是不是已经有这一部了？** 判据复用 `WorkMergePlanner` 的
  ///      `onlineId` 分组（不另写一套筛法，否则会出现「提示说已经有一部、
  ///      归一却一个都没合」）；
  ///   2. **要不要自动合上？** 由设置 `autoMergeByOnlineId` 决定。
  ///
  /// ## 返回值是「附加到结果后面的一句话」，不是「合并结果」
  ///
  /// 三种情形：
  ///
  ///   - 库里没有同一部 → `null`（绝大多数刮削，不给用户加噪音）；
  ///   - 有，且开着自动归一 → 归一那句话（`WorkMergeResult.message`）；
  ///   - 有，但**没开**自动归一（或归一没做成）→ 一句「库里已经有《X》」+
  ///     「怎么合」的提示。
  ///
  /// 最后那一种是这次新加的：以前只有「合了」才有话，没开开关时用户什么都
  /// 看不到 —— 而他刚手动刮完一部、库里其实早就有一部同名的，正是最需要被
  /// 告知的时候。
  ///
  /// ## 为什么读设置而不是把服务常驻在 provider 里
  ///
  /// 与扫描那条（`buildScanService` 决定传不传 `merger`）同一个道理：
  /// 开关是**用户此刻的设置**，而不是应用启动时的快照。做成常驻 provider
  /// 会让「刚在设置里关掉，回来点刮削还是合了」变成静默 bug。
  ///
  /// ## 永不抛异常
  ///
  /// 归一是刮削之后的「锦上添花」，它失败不该让用户看到「刮削失败」——
  /// 那时元数据其实已经写进去了。异常降级成一条 `diag.warn` 并返回 `null`。
  Future<String?> _mergeClauseAfterScrape(MediaWork work) async {
    try {
      final repo = ref.read(mediaRepositoryProvider);
      final enabled =
          ref.read(settingsProvider).valueOrNull?.autoMergeByOnlineId ?? false;

      // 先看库里有没有同一条目的另一部 —— 没有就到此为止（绝大多数刮削）。
      final sibling = WorkMergePlanner.siblingOf(work, await repo.allWorks());
      if (sibling == null) return null;

      if (enabled) {
        final result = await WorkMergeService(library: repo).mergeFor(work.key);
        // 合并没做成（期间库变过 / 那一行已经被别的流程折走）→ 落到下面的
        // 提示，别让用户以为「库里根本没有这一部」。
        if (result != null) return result.message;
      }

      return '媒体库里已经有同一部《${sibling.title}》（同一条目）—— '
          '可在任一部的详情页用「合并到…」把两个格子并成一部；'
          '打开设置里的「自动归一同一部影片」可以以后自动合。';
    } catch (e) {
      diag.warn('刮削', '${work.key} 刮削后的归一/提示失败，跳过', error: e);
      return null;
    }
  }

  void _refreshAfter(MediaWork before, WorkScrapeOutcome outcome) {
    ref.invalidate(workDetailProvider(before.key));
    ref.invalidate(workListProvider);

    final after = outcome.work;
    if (after == null) return;

    if (after.category != before.category) {
      ref.invalidate(categoryCountsProvider);
      // 分类变了，这部作品就**离开了（或进入了）当前分类的统计范围** ——
      // 面板上那两组角标是按当前分类收窄算出来的，必须一起重算。
      //
      // 只按「year / genres 变了没」判是不够的：TMDB 说这是「动画」时，
      // `year` 可能一个字都没变，而它已经从「电影」栏挪走了。
      //
      // `genreCountsProvider` 那一条看着多余（分类变了，`genres` 一般不也
      // 跟着变吗），实际不是：库里可能有「`genres` 已经是『动画』、`category`
      // 还停在『剧集』」的行 —— 回填虽然会修，但它**每次开库只跑一次**，
      // 之后才出现（或之后才被读到）的行它管不到。而这时 `genres` 逐字没变，
      // 「按集合比类型」那条判据盖不住，不作废就会在「剧集」栏里挂着一个
      // 根本不存在的类型。见 `test/ui/providers/scrape_refresh_test.dart`。
      ref.invalidate(yearCountsProvider);
      ref.invalidate(genreCountsProvider);
      return;
    }

    if (after.year != before.year) {
      ref.invalidate(yearCountsProvider);
    }
    // 按**集合**比：类型列表的顺序取决于数据源返回的顺序，
    // 顺序变了不代表内容变了，不该白跑一次统计。
    if (!setEquals(after.genres.toSet(), before.genres.toSet())) {
      ref.invalidate(genreCountsProvider);
    }
  }
}

final workScrapeControllerProvider =
    NotifierProvider<WorkScrapeController, WorkScrapeState>(
  WorkScrapeController.new,
);

// ---------------------------------------------------------------------------
// 批量刮削：媒体库页的「刮削媒体库」按钮
// ---------------------------------------------------------------------------

/// 库里**还没在线刮过**的作品 —— 批量刮削的目标。
///
/// ## 判据是 `source == local`
///
/// 三个取值（见 `ScrapeSource`）在这里各有一个明确的去向：
///
///   - `local`：文件名解析的产物，**还没被在线源刮过** —— 正是要刮的；
///   - `online`：已经刮过了，跳过；
///   - `manual`：用户点过「自定义」，亲手敲了片名 / 分类。**批量刮削必须
///     跳过它**。[WorkScraper.scrape] 走的是 `overrideManual: true`（那是给
///     详情页那个按钮用的：用户亲手点、明确要求覆盖），批量通道沿用同一个
///     开关就会把用户手敲的片名与分类**一次性冲掉**，而且不报错 ——
///     这正是「我明明改过的片子，点了一下刮削全变回去了」的来源。
///
/// 另外跳过**已被折叠走的别名行**（`mergedInto` 非空）：它的文件已经算在
/// 目标那一部下面，再刮一次只会把同一份元数据写进一行列表里看不见的记录。
///
/// 抽成顶层函数是为了让「按钮上的数字」与「真正会刮的条数」共用同一个筛法
/// —— 两处各写一遍的话，会出现「按钮写着 128、进度跑到 130 才停」这种对不上。
List<MediaWork> unscrapedOf(List<MediaWork> all) => all
    .where((w) => !w.isMergedAway && w.source == ScrapeSource.local)
    .toList(growable: false);

/// 「还有多少部没刮过」——「刮削媒体库」按钮上的数字。
///
/// ## 为什么刮削进行中不要 watch 它
///
/// 它每次都要 `allWorks()` **读全表**再在 Dart 里过滤。刮削中每部都会推一次
/// 列表信号（为了「一个一个出现」的动态感），那时再重算它就是每部一次全表
/// 读 —— 而刮削中的按钮显示的是控制器自己的 `done/total`，用不到这个数字。
/// 所以调用方在刮削（或扫描）进行中**不要 watch** 它（见 `library_page.dart`）。
final unscrapedCountProvider = FutureProvider<int>((ref) async {
  // 库变了就重算：扫描结束、刮削结束、删除作品…
  ref.watch(libraryListSignalProvider);
  final all = await ref.watch(mediaRepositoryProvider).allWorks();
  return unscrapedOf(all).length;
});

/// 「刮削媒体库」的进度快照。
class LibraryScrapeState {
  const LibraryScrapeState({
    this.running = false,
    this.total = 0,
    this.done = 0,
    this.scraped = 0,
    this.missed = 0,
    this.currentTitle,
    this.cancelRequested = false,
    this.finished = false,
  });

  final bool running;

  /// 本次要刮的总数（点下按钮那一刻定下的）。
  final int total;
  final int done;

  /// 在线源命中并落库的部数。
  final int scraped;

  /// 在线源没命中的部数（含「文件名解析不出片名」那种压根没发请求的）。
  final int missed;

  /// 正在刮哪一部。进度条旁边显示它，用户才知道不是卡住了。
  final String? currentTitle;

  /// 用户点了「停止」。协作式：当前这一部的网络请求跑完才生效。
  final bool cancelRequested;

  /// 这一轮已经结束（跑完或停下）。
  final bool finished;

  /// 进度比例；总数为 0（或还没开始）时返回 `null`，调用方据此不画确定进度条。
  double? get fraction =>
      total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  /// 一句话摘要。
  String get summary {
    if (running) return '正在刮削 $done/$total · 命中 $scraped';
    if (!finished) return '';
    final head = cancelRequested ? '已停止' : '刮削完成';
    return '$head：$done/$total · 命中 $scraped · 未命中 $missed';
  }
}

/// 批量刮削控制器。
///
/// ## 与详情页「刮削」按钮的分工
///
/// 详情页那个是**一次一部、用户亲手点**（`WorkScrapeController`）；这里是
/// **一次一批、只刮没刮过的**（媒体库页的按钮）。两者共用同一个
/// [workScraperProvider]，所以熔断 / 节流状态是延续的。
///
/// ## 为什么它不碰 `WorkScrapeState.runningKey`
///
/// 那个互斥位是「同一部作品不能有两笔写操作并发」。批量刮削跑的时候，
/// 用户不可能同时在详情页对**同一部**再点一次（列表里那一部正在被刮，
/// 而 UI 上批量按钮已经禁用）—— 真正要挡的是「两边同时写库」，
/// 那由**媒体库页**在扫描 / 刮削进行时禁用对应按钮来保证（见 `library_page`）。
class LibraryScrapeController extends Notifier<LibraryScrapeState> {
  bool _cancelRequested = false;
  bool _disposed = false;

  @override
  LibraryScrapeState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const LibraryScrapeState();
  }

  /// 请求停止（协作式）。
  void cancel() {
    if (!state.running) return;
    _cancelRequested = true;
    _emit(
      LibraryScrapeState(
        running: true,
        total: state.total,
        done: state.done,
        scraped: state.scraped,
        missed: state.missed,
        currentTitle: state.currentTitle,
        cancelRequested: true,
      ),
    );
  }

  /// 收起结束后那条结果提示（媒体库页活动条上的「关闭」）。
  ///
  /// 进行中调用是空操作：正在跑的进度条不该被关掉。
  void dismiss() {
    if (state.running) return;
    _emit(const LibraryScrapeState());
  }

  /// 开始一轮批量刮削。
  ///
  /// ## 与扫描互斥
  ///
  /// 两边都写 `media_works`，同时跑会互相覆盖。**由调用方**（媒体库页）在
  /// 扫描运行时禁用按钮；这里只挡住「自己已经在跑」。
  Future<void> start() async {
    if (state.running) return;
    _cancelRequested = false;
    _emit(const LibraryScrapeState(running: true));

    final List<MediaWork> targets;
    try {
      targets = unscrapedOf(
        await ref.read(mediaRepositoryProvider).allWorks(),
      );
    } catch (e) {
      diag.warn('刮削', '批量刮削：读取未刮削作品失败，取消本轮', error: e);
      _emit(const LibraryScrapeState());
      return;
    }
    if (_disposed) return;

    if (targets.isEmpty) {
      _emit(const LibraryScrapeState(finished: true));
      return;
    }

    final scraper = ref.read(workScraperProvider);
    var done = 0;
    var scraped = 0;
    var missed = 0;

    _emit(LibraryScrapeState(running: true, total: targets.length));

    for (final work in targets) {
      if (_cancelRequested || _disposed) break;

      WorkScrapeOutcome outcome;
      try {
        outcome = await scraper.scrape(work);
      } catch (e) {
        // `WorkScraper.scrape` 的契约是「永不抛异常」，但这里是**批量**循环：
        // 万一有一部真的抛了，不该让后面几十部跟着一起断掉。
        diag.warn('刮削', '批量刮削：${work.key} 抛异常，按未命中处理', error: e);
        outcome = const WorkScrapeOutcome(
          status: WorkScrapeStatus.notFound,
          channel: ScrapeChannel.auto,
        );
      }
      if (_disposed) break;

      done++;
      if (outcome.status == WorkScrapeStatus.scraped) {
        scraped++;
      } else {
        missed++;
      }

      _emit(
        LibraryScrapeState(
          running: true,
          total: targets.length,
          done: done,
          scraped: scraped,
          missed: missed,
          currentTitle: work.title,
        ),
      );

      // 每刮完一部就让媒体库列表重取一次 —— 用户要的正是「一个一个刮削成功」
      // 的动态感，而不是等整批跑完才一起冒出来。
      //
      // 只推**列表信号**（不是 `libraryWriteSignalProvider`）：后者会连带
      // 触发目录视图那棵要读全表的 `folderTreeProvider`，而刮削只改
      // `media_works` 的元数据、`media_items` 一个字都没变。见 `LibraryListSignal`。
      ref.read(libraryListSignalProvider.notifier).bump();
    }

    // 自动归一：与扫描结束同一条规则（设置开着才做），放在**全部落库之后** ——
    // 归一要比较不同作品之间的 `onlineId`，一部刚刮完、另一部早在上一轮就
    // 刮好了，只有等这一轮全部写完才看得全。用户点了停止就不做（半份数据上
    // 归一会漏合）。
    if (!_disposed && !_cancelRequested) {
      final enabled =
          ref.read(settingsProvider).valueOrNull?.autoMergeByOnlineId ?? false;
      if (enabled) {
        try {
          await WorkMergeService(library: ref.read(mediaRepositoryProvider))
              .mergeAll();
        } catch (e) {
          diag.warn('刮削', '批量刮削后的自动归一失败，跳过', error: e);
        }
      }
    }

    _refreshAfterAll();
    _emit(
      LibraryScrapeState(
        total: targets.length,
        done: done,
        scraped: scraped,
        missed: missed,
        cancelRequested: _cancelRequested,
        finished: true,
      ),
    );
  }

  void _emit(LibraryScrapeState next) {
    if (_disposed) return;
    state = next;
  }

  /// 整轮结束后的完整刷新。
  ///
  /// 三组筛选角标（分类 / 年份 / 类型）各自是一次全表统计，**不能**跟着每部
  /// 都跑 —— 所以它们只在这里统一作废。`workListProvider` 那一份虽然每部都
  /// 被信号刷过，这里再作废一次是为了兜住「一部都没刮成」（循环一次都没进，
  /// 信号也就一次没推）的情形。
  void _refreshAfterAll() {
    if (_disposed) return;
    ref.invalidate(workListProvider);
    ref.invalidate(libraryStatsProvider);
    ref.invalidate(unscrapedCountProvider);
    ref.invalidate(categoryCountsProvider);
    ref.invalidate(yearCountsProvider);
    ref.invalidate(genreCountsProvider);
    ref.invalidate(playedCountProvider);
    // 目录视图的「已入库」叠加层读的是同一张表。刮削不改「哪些文件已入库」，
    // 但顺手推一下，让任何读库的视图都与列表对齐。
    ref.read(libraryWriteSignalProvider.notifier).bump();
  }
}

final libraryScrapeControllerProvider =
    NotifierProvider<LibraryScrapeController, LibraryScrapeState>(
  LibraryScrapeController.new,
);

/// 设置里的地址留空时回退到默认值。
String _orDefault(String? raw, String fallback) {
  final v = (raw ?? '').trim();
  return v.isEmpty ? fallback : v;
}
