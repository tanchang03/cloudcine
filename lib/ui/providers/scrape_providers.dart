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

/// 设置里的地址留空时回退到默认值。
String _orDefault(String? raw, String fallback) {
  final v = (raw ?? '').trim();
  return v.isEmpty ? fallback : v;
}
