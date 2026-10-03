import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/media_category.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/work_merge_service.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../providers/library_providers.dart';
import '../providers/library_selection_providers.dart';
import '../providers/scan_providers.dart';
import '../providers/scrape_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/batch_merge_dialog.dart';
import '../widgets/common_widgets.dart';
import '../widgets/library_filter_panel.dart';
import '../widgets/play_action.dart';
import '../widgets/poster_image.dart';
import '../widgets/tv_affordance.dart';
import '../widgets/tv_focus.dart';

/// 空列表时那个按钮**具体该清掉什么**。
///
/// 见 [libraryEmptyHint]。
enum LibraryEmptyAction {
  /// 只清筛选面板的两组（年份 / 类型）。
  clearExtra,

  /// 只清搜索词（连同输入框里的字）。
  clearQuery,

  /// 清掉搜索词**与**面板两组，但**保留分类**。
  clearExtraAndQuery,

  /// 全部复位 —— 分类、排序、搜索词、面板两组。
  clearAll,
}

/// 点一部作品：解析「该播哪一条」然后开播。
///
/// 封面视图与列表视图**共用这一份**。两边各写一份的话，「列表里点了不动」
/// 或「列表里点了却播错一集」只是时间问题 —— 而这两处的行为必须一致，
/// 因为用户换来换去的是同一个「点片子就播」的预期。
///
/// [onBusy] 由调用方用来转圈：解析要打两次 SQLite，期间不给反馈的话用户
/// 会觉得点了没反应，然后再点一次。
Future<void> playWork({
  required BuildContext context,
  required WidgetRef ref,
  required MediaWork work,
  required void Function(bool busy) onBusy,
}) async {
  onBusy(true);
  try {
    final item = await resolvePlayTarget(
      ref.read(mediaRepositoryProvider),
      work.key,
    );
    if (!context.mounted) return;
    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('这部作品下没有可播放的文件'),
        ),
      );
      return;
    }
    diag.info('媒体库', '列表直开：${work.title} → ${item.displayTitle}');
    await playItem(context, ref, item);
  } catch (e, st) {
    diag.error('媒体库', '列表直开失败', error: e, stackTrace: st);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('打开失败：$e'),
      ),
    );
  } finally {
    onBusy(false);
  }
}

/// 列表为空时该说哪句话、给哪个行动按钮。
///
/// ## 为什么按钮必须与提示语指向同一件事
///
/// 原先这里是「提示语按条件分两种，按钮一律 `clear()`」。而 `clear()` 是
/// **全部复位**：只打了搜索词的用户点下去，连分类栏选的位置和排序都一起
/// 丢掉 —— 他不会把「我的栏目没了」和「我刚点了个清空按钮」联系起来。
///
/// ## 为什么要按「全部在用的条件」分派，而不是挑一个清
///
  /// 按钮的用途是**让用户重新看到内容**。同时设了搜索词与年份时只清一个，
  /// 列表很可能还是空的 —— 用户会认为这个按钮坏了。所以：
  ///
  ///   1. 两组都在用 → 两个都清，保留分类；
  ///   2. 只有年份 / 类型 → 清那两组，保留分类；
  ///   3. 只有搜索词 → 清搜索词，保留分类；
  ///   4. 都没有（只切了分类）→ 提示语本来就在说「换个分类看看」，
  ///      按钮也就该是「回到全部」。
  ///
  /// 抽成纯函数是为了能单测：这一段的分支写错不报错，只表现为「用户点完
  /// 丢了本来不想丢的东西」，事后才被发现。
  @visibleForTesting
  ({String body, String actionLabel, LibraryEmptyAction action}) libraryEmptyHint(
    LibraryFilter filter,
  ) {
    final query = filter.query.trim();
    final hasQuery = query.isNotEmpty;

    // 面板里**实际**在筛的那几组。这句话必须点名它们：用户会照着提示去清
    // 「年份 / 类型」，而如果他只开了「已刮削」，那句话就是在让他去清一组
    // 根本没选过的条件 —— 而他点完按钮列表变空的原因也解释不了。
    final facets = [
      if (filter.scrapedOnly) '「已刮削」',
      if (filter.years.isNotEmpty || filter.genres.isNotEmpty) '年份 / 类型',
    ];

    if (filter.hasExtra && hasQuery) {
      return (
        body: '没有同时匹配「$query」与所选${facets.join("、")}的作品。',
        actionLabel: '清空筛选条件',
        action: LibraryEmptyAction.clearExtraAndQuery,
      );
    }
    if (filter.hasExtra) {
      return (
        body: '当前筛选条件下一条都没筛到。清掉${facets.join("、")}再看看。',
      actionLabel: '清空筛选',
      action: LibraryEmptyAction.clearExtra,
    );
  }
  if (hasQuery) {
    return (
      body: '没有匹配「$query」的作品。',
      actionLabel: '清空搜索',
      action: LibraryEmptyAction.clearQuery,
    );
  }
  return (
    body: '这个分类下暂时没有作品。换个分类看看，或者重新扫描一次。',
    actionLabel: '回到全部',
    action: LibraryEmptyAction.clearAll,
  );
}

/// 媒体库主页（海报墙）。
///
/// ## 交互口径（照搬 VidHub / Infuse 一类媒体库播放器）
///
/// **点卡片 = 直接开播**，不是先看一页简介。
///
/// 用户点海报的意图几乎总是「看片」；先跳到详情页再让他点一次播放，
/// 等于每次看片都多一次点击。想了解剧情的人点卡片右下角的「简介」。
///
/// 播哪一条由 `PlayTarget` 决定：
///   - 有没看完的一集 → 接着那一集；
///   - 看过但已看完 → 还是那一集（不猜「下一集」，理由见 `PlayTarget`）；
///   - 全新 → 第一集。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  /// 搜索防抖。每敲一个字都打一次 SQLite 查询在本地库上不算贵，
  /// 但**每次都让整个海报墙重建**是真的卡 —— 250ms 足够覆盖打字间隔。
  static const Duration _debounceDelay = Duration(milliseconds: 250);

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      ref.read(libraryFilterProvider.notifier).setQuery(value);
    });
  }

  /// 清空搜索框**与**筛选条件。
  ///
  /// 两处都要动：`libraryFilterProvider.query` 是列表的真源，而输入框里
  /// 还留着上一次打的字。只改一边会得到「列表已经不过滤了，但搜索框里
  /// 还有词」这种自相矛盾的状态。
  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    ref.read(libraryFilterProvider.notifier).setQuery('');
  }

  /// 重新读库。
  ///
  /// 网盘目录那一份（目录内容 + 「已入库」叠加层）**不在这里**：它属于
  /// 侧栏的「文件夹」页，那里有自己的刷新按钮（`folder_page.dart`）。
  void _refresh() {
    ref.invalidate(workListProvider);
    ref.invalidate(categoryCountsProvider);
    ref.invalidate(playedCountProvider);
    // 筛选面板的两组选项也是从库里数出来的，一起失效 ——
    // 否则手动改了库（比如在设置页清过数据）之后，面板上还列着
    // 已经一部都不剩的年份 / 类型。
    ref.invalidate(yearCountsProvider);
    ref.invalidate(genreCountsProvider);
    ref.invalidate(libraryStatsProvider);
    // 「还有多少部没刮过」也是从库里数出来的。
    ref.invalidate(unscrapedCountProvider);
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(libraryViewProvider);
    final works = ref.watch(workListProvider);
    final stats = ref.watch(libraryStatsProvider).valueOrNull;
    final filter = ref.watch(libraryFilterProvider);
    final scan = ref.watch(scanControllerProvider);
    final scanning = scan.running;
    final scrape = ref.watch(libraryScrapeControllerProvider);

    // 没配在线源（TMDB Key / 豆瓣 Cookie）时「刮削媒体库」必须**禁用**：
    // 流水线只剩本地文件名兜底，而 `WorkScraper.scrape` 明确把「只有本地
    // 兜底」判成未命中 —— 点了会跑完全程、一部都不命中，用户只会以为
    // 「这个按钮坏了」。禁用 + tooltip 说清去哪配，才是诚实的做法。
    final canScrape =
        ref.watch(settingsProvider).valueOrNull?.canScrapeOnline ?? false;

    // 「还有多少部没刮过」要读一次全表，而刮削 / 扫描进行中按钮显示的是
    // 各自的进度、用不到它 —— 那段时间**不要** watch，否则每推一次列表信号
    // （刮削是每部一次）就多一次全表读。见 `unscrapedCountProvider` 的文档。
    final unscrapedCount = (!canScrape || scanning || scrape.running)
        ? null
        : ref.watch(unscrapedCountProvider).valueOrNull;

    // 封面与列表列的是**同一批作品**（只是排布不同），所以排序 / 筛选 /
    // 多选在这两个视图里完全共用 —— 不需要「当前是哪个视图」的判据。
    final selecting = ref.watch(librarySelectionProvider).active;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (selecting)
          _SelectionHeader(onRefresh: _refresh)
        else
          PageHeader(
            title: '媒体库',
            subtitle:
                stats == null ? null : '${stats.items} 个视频 · ${stats.works} 部作品',
            actions: [
              // 批量动作放在最前：它们是这一页最重的两个动作，TV 上折行后
              // 也落在最左边（遥控器从海报墙按一次 ↑ 就够得到）。
              TvIconLabel(
                label: '刮削',
                child: IconButton(
                  tooltip: !canScrape
                      ? '未启用在线刮削：到「设置 → 刮削」填 TMDB Key 或豆瓣 Cookie'
                      : scanning
                          ? '正在扫描，稍后再刮削'
                          : (unscrapedCount == null
                              ? '刮削媒体库（只刮未刮削的作品）'
                              : '刮削媒体库：还有 $unscrapedCount 部没刮过'),
                  onPressed: (!canScrape || scanning || scrape.running)
                      ? null
                      : () => ref
                          .read(libraryScrapeControllerProvider.notifier)
                          .start(),
                  icon: scrape.running
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 17),
                ),
              ),
              TvIconLabel(
                label: '重扫',
                child: IconButton(
                  tooltip: scanning ? '正在扫描…' : '重新扫描媒体库',
                  onPressed: (scanning || scrape.running)
                      ? null
                      : () => ref.read(scanControllerProvider.notifier).start(),
                  icon: const Icon(Icons.radar_rounded, size: 17),
                ),
              ),
              const SizedBox(width: 8),
              const _ViewSwitch(),
              const SizedBox(width: 8),
              HeaderSearchBox(
                controller: _search,
                onChanged: _onSearchChanged,
                // 搜的是**库里已入库的**作品 / 文件。网盘目录那一份搜索在
                // 侧栏的「文件夹」页，它只筛当前这一层，是另一回事。
                hint: '搜片名或文件名…',
              ),
              const SizedBox(width: 8),
              const _SortMenu(),
              const SizedBox(width: 4),
              const LibraryFilterButton(),
              const SizedBox(width: 4),
              // 「选择」是一个**模式开关**，不是一次动作：点它进入多选，
              // 之后点卡片才是勾选。做成常驻按钮而不是长按 / 右键才出的
              // 隐藏入口，是因为电视上既没有右键也没有可靠的长按。
              TvIconLabel(
                label: '选择',
                child: IconButton(
                  tooltip: '多选（批量合并）',
                  onPressed: () =>
                      ref.read(librarySelectionProvider.notifier).enter(),
                  icon: const Icon(Icons.checklist_rounded, size: 17),
                ),
              ),
              // 「刷新」是个纯图标按钮：桌面上悬停会出 tooltip，电视上没有
              // hover —— 所以 TV 上补一个看得见的「刷新」标签。
              TvIconLabel(
                label: '刷新',
                child: IconButton(
                  tooltip: '刷新',
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                ),
              ),
            ],
          ),
        // 扫描 / 刮削进行时，页头下方占一条实时进度 —— 用户在这里就能看到
        // 「卡片一批批长出来」「一部部刮削成功」，不用切到扫描页去等。
        if (scanning || scrape.running || scrape.finished)
          _LibraryActivityBar(scan: scan, scrape: scrape),
        const _CategoryBar(),
        Expanded(
          child: works.when(
            loading: () => const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline_rounded,
              danger: true,
              title: '读取媒体库失败',
              body: '$e',
              actionLabel: '重试',
              onAction: () => ref.invalidate(workListProvider),
            ),
            data: (list) {
              if (list.isEmpty) {
                // 四种空态要分开：**库里本来就没有**（该去扫描）、
                // **这一栏本来就该是空的**（还没看过任何片子 / 还没刮过）、
                // **筛选没筛到**（该清条件）。给错行动按钮比不给更糟。
                if (filter.playedOnly) return const _NoPlayHistoryState();
                // 「只开了已刮削」单独一支：这与「条件太紧」是两回事 ——
                // 见 `_NoScrapedState`。带了年份 / 类型或搜索词就走下面的
                // 通用分支（那时候确实是条件太紧）。
                if (filter.scrapedOnly &&
                    filter.years.isEmpty &&
                    filter.genres.isEmpty &&
                    filter.query.trim().isEmpty) {
                  return const _NoScrapedState();
                }
                if (filter.isEmpty) return const _NeverScannedState();
                // 提示语与按钮都由 `libraryEmptyHint` 按**当前实际存在的
                // 条件**分派 —— 按钮绝不能一律 `clear()`（那会连分类栏选的
                // 位置一起丢掉），理由见那个函数的文档。
                final hint = libraryEmptyHint(filter);
                return EmptyState(
                  icon: Icons.search_off_rounded,
                  title: '这里还没有内容',
                  body: hint.body,
                  actionLabel: hint.actionLabel,
                  onAction: () {
                    final notifier = ref.read(libraryFilterProvider.notifier);
                    switch (hint.action) {
                      case LibraryEmptyAction.clearExtra:
                        notifier.clearExtra();
                      case LibraryEmptyAction.clearQuery:
                        // 走 `_clearSearch` 而不是 `setQuery('')`：输入框里
                        // 还留着上一次打的字，只改状态会得到「列表已经不过滤
                        // 了，但搜索框里还有词」这种自相矛盾的样子。
                        _clearSearch();
                      case LibraryEmptyAction.clearExtraAndQuery:
                        notifier.clearExtra();
                        _clearSearch();
                      case LibraryEmptyAction.clearAll:
                        notifier.clear();
                    }
                  },
                );
              }
              // 封面与列表读的是同一个 `list`，只有排布不同。
              return view == LibraryView.posters
                  ? _PosterGrid(works: list)
                  : _WorkList(works: list);
            },
          ),
        ),
      ],
    );
  }
}

/// 媒体库顶部的**活动条**：扫描 / 刮削进行时占一行，显示实时进度。
///
/// ## 为什么单独一条，而不是塞进页头
///
/// 页头那一行已经有八个控件，TV 上要折成两行；而进度条需要的是**整行宽度**
/// （一眼看出「还剩多少」），塞进页头只会两边都憋屈。
///
/// ## 为什么扫描与刮削共用一条
///
/// 两者不会同时跑（媒体库页把两个入口互斥了），所以一条就够 —— 分开两条
/// 会多出一块「另一个永远是空的」的版式。
///
/// ## 刮削结束后为什么还留着
///
/// 结果（命中多少 / 未命中多少）是用户点这一次按钮唯一的回执。跑完就消失的话，
/// 用户只看到进度条闪了一下，不知道到底刮成了几部。留到用户点「关闭」，
/// 或下一次扫描 / 刮削开始时被顶掉。
class _LibraryActivityBar extends ConsumerWidget {
  const _LibraryActivityBar({required this.scan, required this.scrape});

  final ScanState scan;
  final LibraryScrapeState scrape;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 刮削优先：它结束后那条结果提示还要留着，而扫描不会与它同时跑。
    final scraping = scrape.running || scrape.finished;
    final tv = AppTheme.isTvLayout(context);

    final String title;
    final String? detail;
    final VoidCallback onAction;
    final String actionLabel;
    final IconData actionIcon;
    final double? fraction;

    if (scraping) {
      fraction = scrape.fraction;
      title = scrape.running
          ? '正在刮削 ${scrape.done}/${scrape.total}'
          : scrape.summary;
      detail = scrape.running && scrape.currentTitle != null
          ? '当前：${scrape.currentTitle}'
          : null;
      if (scrape.running) {
        onAction =
            () => ref.read(libraryScrapeControllerProvider.notifier).cancel();
        actionLabel = '停止';
        actionIcon = Icons.stop_rounded;
      } else {
        onAction =
            () => ref.read(libraryScrapeControllerProvider.notifier).dismiss();
        actionLabel = '关闭';
        actionIcon = Icons.close_rounded;
      }
    } else {
      final p = scan.progress;
      fraction = null;
      title = p == null ? '正在扫描…' : '正在扫描 · ${p.phase.label}';
      final dir = p?.currentDirPath;
      detail = p == null
          ? null
          : '已扫 ${p.scannedDirs} 个目录 · 命中 ${p.foundMedia} 个视频'
              '${dir == null || dir.isEmpty ? "" : " · $dir"}';
      onAction = () => ref.read(scanControllerProvider.notifier).cancel();
      actionLabel = '停止';
      actionIcon = Icons.stop_rounded;
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      padding: const EdgeInsets.fromLTRB(14, 9, 10, 11),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                scraping ? Icons.auto_awesome_rounded : Icons.radar_rounded,
                size: tv ? 20 : 15,
                color: AppTheme.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: tv ? AppTheme.tvActionLabel : 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon, size: 15),
                label: Text(actionLabel),
              ),
            ],
          ),
          if (fraction != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 4,
                backgroundColor: AppTheme.panel3,
              ),
            ),
          ],
          if (detail != null) ...[
            const SizedBox(height: 7),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: tv ? 13 : 11,
                color: AppTheme.dim,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「封面 / 列表」切换。
///
/// 只在这两个视图之间切：它们读的是**同一批作品**，只是排布不同，所以做成
/// 同一页面里的分段控件就够了（搜索、分类栏、排序、筛选、多选全部共用）。
///
/// ⚠️ 「文件夹」**不在这里** —— 它读的是网盘实时目录、不是本地索引，与这里
/// 没有一处共用，已经是侧栏上并列的一级入口（`ui/pages/folder_page.dart`）。
class _ViewSwitch extends ConsumerWidget {
  const _ViewSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(libraryViewProvider);
    final tv = AppTheme.isTvLayout(context);

    return Container(
      // TV 上抬到 44：32 高的分段控件里，焦点环几乎没有地方画，而 12sp 的
      // 标签隔三米读不出来。
      height: tv ? 44 : 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in LibraryView.values)
            _ViewSegment(
              label: option.label,
              icon: switch (option) {
                LibraryView.posters => Icons.grid_view_rounded,
                LibraryView.list => Icons.view_list_rounded,
              },
              selected: view == option,
              onTap: () => ref.read(libraryViewProvider.notifier).set(option),
            ),
        ],
      ),
    );
  }
}

class _ViewSegment extends StatelessWidget {
  const _ViewSegment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tv = AppTheme.isTvLayout(context);
    final color = selected ? AppTheme.text : AppTheme.muted;
    return Material(
      color: selected ? AppTheme.panel3 : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tv ? 16 : 9,
            vertical: tv ? 11 : 5,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: tv ? 19 : 14, color: color),
              SizedBox(width: tv ? 8 : 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: tv ? AppTheme.tvActionLabel : 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分类栏。
///
/// 口径照搬 VidHub：一级入口是「全部 / 最近播放 / 电影 / 剧集 / 动漫 /
/// 综艺 / 纪录片 / 其他」，**不是**只按「电影 / 剧集」两分。
///
/// 「最近播放」不是一个分类，而是一个**视图**（见
/// [LibraryFilter.playedOnly]）—— 它跟在这排里是因为用户找它的位置就是这里，
/// 用一个小图标把它和真正的分类区分开，并且**互斥**：点它会退出当前分类，
/// 点分类会退出它。
///
/// 角标数字取自 `countWorksByCategory`（一次 GROUP BY）与
/// `countPlayedWorks`（一次 COUNT），所以这个部件不会在每次滚动海报墙时重查库。
class _CategoryBar extends ConsumerWidget {
  const _CategoryBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final counts = ref.watch(categoryCountsProvider).valueOrNull;
    final played = ref.watch(playedCountProvider).valueOrNull;
    final total =
        counts?.values.fold<int>(0, (sum, n) => sum + n);

    final tv = AppTheme.isTvLayout(context);
    // TV 上把间距拉开：chip 变高变大之后，6 的间距会让相邻两个看起来像
    // 连在一起的一整条，焦点落在哪一个全靠猜。
    final gap = tv ? 10.0 : 6.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
      child: SizedBox(
        // TV 上抬到 44：28 是给鼠标的（点一下就到），遥控器上焦点环画不下、
        // 12sp 的字也读不出来。
        height: tv ? 44 : 28,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _CategoryChip(
              label: '全部',
              count: total,
              selected: filter.category == null && !filter.playedOnly,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).setCategory(null),
            ),
            SizedBox(width: gap),
            _CategoryChip(
              label: '最近播放',
              icon: Icons.history_rounded,
              count: played,
              selected: filter.playedOnly,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).setPlayedOnly(),
            ),
            for (final category in MediaCategory.displayOrder) ...[
              SizedBox(width: gap),
              _CategoryChip(
                label: category.label,
                count: counts?[category],
                selected: filter.category == category,
                onTap: () => ref
                    .read(libraryFilterProvider.notifier)
                    .setCategory(category),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.icon,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  /// 可选前缀图标。目前只有「最近播放」用 —— 它是视图不是分类，
  /// 一个小图标足以让它在整排分类里一眼可辨。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tv = AppTheme.isTvLayout(context);
    final chip = Material(
      color: selected ? AppTheme.accent.withValues(alpha: 0.16) : AppTheme.panel,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tv ? 18 : 12,
            vertical: tv ? 11 : 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: tv ? 18 : 13,
                  color: selected ? AppTheme.accent : AppTheme.muted,
                ),
                SizedBox(width: tv ? 8 : 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: tv ? AppTheme.tvActionLabel : 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppTheme.accent : AppTheme.muted,
                ),
              ),
              // 计数为 0 或还没算出来时不显示角标：一个「综艺 0」的按钮
              // 只会让人以为坏了，而它其实只是没有综艺。
              if (count != null && count! > 0) ...[
                SizedBox(width: tv ? 8 : 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: tv ? 13 : 10.5,
                    color: selected
                        ? AppTheme.accent.withValues(alpha: 0.75)
                        : AppTheme.dim,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // TV 上补一圈焦点环。这条 chip 自己有 `Material`，ink 高亮**画得出来**，
    // 但深色主题下那层高亮在电视上太淡 —— 八个 chip 并排时，用户分辨不出
    // 焦点落在哪一个上。
    return tv
        ? TvFocusable(borderRadius: BorderRadius.circular(7), child: chip)
        : chip;
  }
}

/// 排序菜单。取值见 [WorkSort]。
class _SortMenu extends ConsumerWidget {
  const _SortMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(libraryFilterProvider).sort;
    return PopupMenuButton<WorkSort>(
      tooltip: '排序方式',
      initialValue: sort,
      position: PopupMenuPosition.under,
      onSelected: (v) => ref.read(libraryFilterProvider.notifier).setSort(v),
      itemBuilder: (context) => [
        for (final option in WorkSort.values)
          PopupMenuItem(
            value: option,
            height: 34,
            child: Row(
              children: [
                Icon(
                  option == sort
                      ? Icons.check_rounded
                      : Icons.check_box_outline_blank,
                  size: 14,
                  color: option == sort ? AppTheme.accent : Colors.transparent,
                ),
                const SizedBox(width: 8),
                Text(
                  option.label,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
                ),
              ],
            ),
          ),
      ],
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            const Icon(Icons.swap_vert_rounded, size: 15, color: AppTheme.muted),
            const SizedBox(width: 5),
            Text(
              sort.label,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _PosterGrid extends StatelessWidget {
  const _PosterGrid({required this.works});

  final List<MediaWork> works;

  @override
  Widget build(BuildContext context) {
    final grid = GridView.builder(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        // 用「最大宽度」而不是固定列数：侧栏固定宽 + 窗口可缩放，
        // 固定列数会让宽窗口下的海报被拉成巨幅。
        maxCrossAxisExtent: 172,
        mainAxisSpacing: 18,
        crossAxisSpacing: 14,
        // 卡片宽高比：**桌面沿用标准海报比例 2:3**，TV 上压到 [AppTheme.tvPosterAspect]
        // 让卡片变矮、多挤一排。两种都收在主题里，不写魔法数字。
        //
        // 这个值要和 `PosterImage` 的画法配套看：那里前景是 `BoxFit.contain`，
        // 所以卡片取 2:3 时，**2:3 的 TMDB 真海报正好铺满、看不到模糊底**；
        // 而 16:9 的夸克视频帧会完整落在卡片中部，上下由模糊底图填。
        // 取更窄的比例（比如原来写的 0.56）只会让视频帧更小、模糊带更宽。
        childAspectRatio: AppTheme.isTvLayout(context)
            ? AppTheme.tvPosterAspect
            : AppTheme.posterAspect,
      ),
      itemCount: works.length,
      itemBuilder: (context, i) => _WorkCard(work: works[i]),
    );

    // TV 上整体放大一档文字（官方规范正文最小 12sp、默认 18sp，
    // 而卡片上写的是 10.5–13 —— 隔着三米读不了）。非 TV 上原样返回。
    //
    // 刻意**不动**列数：实测 960×540 下 `maxCrossAxisExtent` 从 172 提到 240
    // 会把列数从 4 压到 3，可见张数从 ~7.7 掉到 ~4.3。
    // 文字已经能读之后，为了「看得见更多」而放弃一半信息量不划算。
    // 卡片高度是固定的（`childAspectRatio`），文字长高只会让海报变矮 ——
    // 海报是 `Expanded`，所以这里放大字号**不会**溢出。
    return AppTheme.tvTextScaler(context, grid);
  }
}

/// 一张作品卡片。
///
/// **点卡片直接开播**，「简介」按钮进详情页。
class _WorkCard extends ConsumerStatefulWidget {
  const _WorkCard({required this.work});

  final MediaWork work;

  @override
  ConsumerState<_WorkCard> createState() => _WorkCardState();
}

class _WorkCardState extends ConsumerState<_WorkCard> {
  bool _hovered = false;

  /// 正在解析「该播哪一条」。解析要打两次 SQLite，期间给个转圈 ——
  /// 否则用户会觉得点了没反应，然后再点一次。
  bool _resolving = false;

  Future<void> _play() async {
    if (_resolving) return;
    await playWork(
      context: context,
      ref: ref,
      work: widget.work,
      onBusy: (busy) {
        if (mounted) setState(() => _resolving = busy);
      },
    );
  }

  void _openDetail() => context.push(
        '/work?key=${Uri.encodeComponent(widget.work.key)}',
      );

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    final selection = ref.watch(librarySelectionProvider);
    final selecting = selection.active;
    final selected = selection.contains(work.key);

    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // **多选模式下点卡片 = 勾选，不是开播**。这是这个开关唯一改变的事，
        // 但它必须彻底：一边勾一边顺手播出去一部片子，比不能多选更糟。
        onTap: selecting
            ? () => ref
                .read(librarySelectionProvider.notifier)
                .toggle(work.key)
            : _play,
        // 长按 = 「我要选这部」的快捷进入方式（桌面右键在这里没有对应物，
        // 而触摸设备上长按是唯一自然的入口）。必须**连按的那一下一起生效**。
        onLongPress: selecting
            ? null
            : () =>
                ref.read(librarySelectionProvider.notifier).enter(work.key),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(work: work),
                  if (selecting)
                    // 勾选框**压在海报上**而不是替掉它：多选时用户判断「这是
                    // 不是我要的那部」靠的仍然是封面，把图换成方框等于让他
                    // 盲选。
                    Positioned(
                      left: 6,
                      top: 6,
                      child: _SelectionTick(selected: selected),
                    ),
                  if (selecting && selected)
                    // 选中的整张压一层淡蓝：小方框在深色海报上不够显眼，
                    // 勾了 8 部之后用户需要一眼看出哪几部是勾上的。
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppTheme.accent.withValues(alpha: 0.55),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  // 悬停时压一层暗罩 + 播放图标：把「点这张卡片会直接播」
                  // 这件事在点下去**之前**就说清楚。多选时不画 —— 那时点下去
                  // 是勾选，画个播放图标是在骗人。
                  if (_hovered && !_resolving && !selecting)
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.32),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 38,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  if (_resolving)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  if (work.rating != null)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: TagChip(
                        label: work.rating!.toStringAsFixed(1),
                        icon: Icons.star_rounded,
                        color: AppTheme.warn,
                        filled: true,
                      ),
                    ),
                  Positioned(
                    right: 5,
                    bottom: 5,
                    child: _DetailButton(
                      highlighted: _hovered,
                      onTap: _openDetail,
                    ),
                  ),
                  if (!work.isScraped)
                    const Positioned(
                      right: 6,
                      top: 6,
                      child: Tooltip(
                        message: '这些信息来自文件名解析，未联网刮削',
                        child: TagChip(
                          label: '文件名',
                          color: AppTheme.dim,
                          filled: true,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              work.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              work.subtitleLine,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppTheme.dim),
            ),
            if (work.metaLine.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                work.metaLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.muted),
              ),
            ],
          ],
        ),
      ),
    );

    // 焦点环必须画在**子节点之上**：这张卡片的 InkWell 是全项目唯一一个
    // 没给自己包 `Material` 的卡片点击区，它的 ink 落到 `Scaffold` 那一层，
    // 而 `_RenderInkFeatures.paint` 是先画 ink、再画子节点 ——
    // 于是高亮被海报整个盖住，**只调主题的 `focusColor` 一点用都没有**。
    // 详见 [TvFocusable] 的类文档。
    return TvFocusable(
      borderRadius: BorderRadius.circular(10),
      // 1.05 是安全值：卡片约 133×199、网格间距 14/18，
      // 每边只向外溢出 3.3 / 5 px，不会和邻卡重叠。
      focusScale: 1.05,
      child: card,
    );
  }
}

/// 「简介」按钮。
///
/// **常驻显示**（不只在悬停时出现）：触摸设备上没有 hover 事件，
/// 只在悬停时显示的按钮在那些设备上等于不存在，而详情页里有网盘路径、
/// 文件列表这些只在这里能找到的信息。
///
/// 常驻的代价是海报上多一个控件，所以平时压得很低（半透明深底 + 小字），
/// 悬停时才提亮 —— 视觉噪音和可发现性之间的折中。
class _DetailButton extends StatelessWidget {
  const _DetailButton({required this.highlighted, required this.onTap});

  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: highlighted ? 0.72 : 0.5),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.info_outline_rounded, size: 12, color: Colors.white),
              SizedBox(width: 4),
              Text(
                '简介',
                style: TextStyle(
                  fontSize: 10.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 多选时压在封面 / 缩略图角上的那个圈。
///
/// 两种视图**共用这一个**：勾的状态如果一边是蓝圈一边是蓝框，用户换到
/// 列表视图就会怀疑自己刚才是不是没勾上。
class _SelectionTick extends StatelessWidget {
  const _SelectionTick({required this.selected, this.size = 20});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.accent
            : Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? AppTheme.accent : Colors.white70,
          width: 1.4,
        ),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: size - 6, color: Colors.white)
          : null,
    );
  }
}

/// 列表视图：一行一部作品。
///
/// ## 它存在的理由
///
/// 封面视图是「扫一眼找片子」，但库一大（几百部）就没有「扫一眼」这回事了
/// —— 用户要的是**按片名找**、是**一眼看到 N 部连续排下来**。列表一屏能放
/// 的条数是封面的三到四倍，而且片名完整不截断。
///
/// ## 刻意与封面视图保持的四个一致
///
/// 点整行 = **开播**（不是进详情）、长按 = 进入多选并勾上这一行、副标题用的
/// 是同一条 `subtitleLine`、「简介」按钮同样常驻。两边只要有一处不同，用户
/// 换视图时就会踩空 —— 而他换视图往往正是因为想更快地把片子点开。
class _WorkList extends StatelessWidget {
  const _WorkList({required this.works});

  final List<MediaWork> works;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      itemCount: works.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) => _WorkListRow(work: works[i]),
    );

    // 与封面视图同一档处理：TV 上放大文字，但**不动**行密度（列表的价值
    // 就是「一屏能看到更多」，为了字号牺牲条数是本末倒置）。
    return AppTheme.tvTextScaler(context, list);
  }
}

class _WorkListRow extends ConsumerStatefulWidget {
  const _WorkListRow({required this.work});

  final MediaWork work;

  @override
  ConsumerState<_WorkListRow> createState() => _WorkListRowState();
}

class _WorkListRowState extends ConsumerState<_WorkListRow> {
  bool _hovered = false;

  /// 正在解析「该播哪一条」。解析要打两次 SQLite，期间给个转圈 ——
  /// 否则用户会觉得点了没反应，然后再点一次。
  bool _resolving = false;

  Future<void> _play() async {
    if (_resolving) return;
    await playWork(
      context: context,
      ref: ref,
      work: widget.work,
      onBusy: (busy) {
        if (mounted) setState(() => _resolving = busy);
      },
    );
  }

  void _openDetail() => context.push(
        '/work?key=${Uri.encodeComponent(widget.work.key)}',
      );

  @override
  Widget build(BuildContext context) {
    final work = widget.work;
    final selection = ref.watch(librarySelectionProvider);
    final selecting = selection.active;
    final selected = selection.contains(work.key);

    return TvFocusable(
      borderRadius: BorderRadius.circular(8),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // 与封面卡片**同一套**口径：多选时点 = 勾选，其余时候点 = 开播。
          onTap: selecting
              ? () => ref
                  .read(librarySelectionProvider.notifier)
                  .toggle(work.key)
              : _play,
          onLongPress: selecting
              ? null
              : () => ref.read(librarySelectionProvider.notifier).enter(work.key),
          child: Container(
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.accent.withValues(alpha: 0.13)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  height: 63,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(work: work, borderRadius: 5),
                      if (selecting)
                        Positioned(
                          left: 3,
                          top: 3,
                          child: _SelectionTick(
                            selected: selected,
                            size: 17,
                          ),
                        ),
                      if (_resolving)
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0x66000000),
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        work.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        work.subtitleLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: AppTheme.dim),
                      ),
                      if (work.metaLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          work.metaLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppTheme.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                if (!work.isScraped)
                  const TagChip(label: '文件名', color: AppTheme.dim),
                const SizedBox(width: 8),
                // 多选时**不画**「简介」：那时整行都是勾选区，右下角再挂一个
                // 会跳页的按钮，误触代价是把刚勾好的 8 部丢掉。
                if (!selecting)
                  _DetailButton(
                    highlighted: _hovered,
                    onTap: _openDetail,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 多选模式下**替换页头**的那条操作栏。
///
/// ## 为什么要换掉整个页头，而不是在下面加一条
///
/// 多选是一个**模式**，不是一个面板：进去之后搜索框、排序、筛选这些控件
/// 全都没有意义（勾完 8 部再去改排序，选择会被列表重建冲得七零八落）。
/// 把它们留在屏幕上，用户会去点，然后发现选择莫名其妙变了。换掉页头是
/// 唯一能把这个「现在是另一种状态」讲清楚的做法。
///
/// ## 「全选」选的是**当前列表里可见的**
///
/// 不是全库。`workListProvider` 给的就是当前分类 / 搜索 / 筛选下的结果，
/// 而用户说「全选」时指的一定是「把屏幕上这些全勾上」—— 全库全选会把他
/// 根本没看见的几百部一起并进某一部里，那是不可逆的灾难（虽然能撤销，
/// 但没人会在乎一个自己没见过的数字）。
class _SelectionHeader extends ConsumerWidget {
  const _SelectionHeader({required this.onRefresh});

  /// 合并 / 撤销之后让列表与角标重取。
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(librarySelectionProvider);
    final visible = ref.watch(workListProvider).valueOrNull ?? const [];
    final allSelected =
        visible.isNotEmpty && visible.every((w) => selection.contains(w.key));

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 22, 12),
      decoration: const BoxDecoration(
        color: AppTheme.panel,
        border: Border(bottom: BorderSide(color: AppTheme.line, width: 0.5)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '退出多选',
            iconSize: 18,
            onPressed: () =>
                ref.read(librarySelectionProvider.notifier).exit(),
            icon: const Icon(Icons.close_rounded),
          ),
          const SizedBox(width: 4),
          Text(
            selection.isEmpty
                ? '勾选要管理的作品'
                : '已选 ${selection.count} 部',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.text,
            ),
          ),
          const SizedBox(width: 14),
          TextButton(
            onPressed: visible.isEmpty || allSelected
                ? null
                : () => ref
                    .read(librarySelectionProvider.notifier)
                    .addAll(visible.map((w) => w.key)),
            child: Text(
              allSelected ? '已全选' : '全选 ${visible.length} 部',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: selection.isEmpty
                ? null
                : () =>
                    ref.read(librarySelectionProvider.notifier).clearKeys(),
            child: const Text('取消选择', style: TextStyle(fontSize: 12.5)),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: selection.isEmpty
                ? null
                : () => _mergeSelected(context, ref),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            icon: const Icon(Icons.merge_type_rounded, size: 15),
            label: const Text(
              '合并到…',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 把当前勾选的这一批并到某一部上。
  ///
  /// 作品对象**重新从库里读**（而不是拿 `workListProvider` 里那几行）：
  /// 用户勾完之后列表可能因为后台扫描 / 播放落库重建过，手上那几行有可能是
  /// 旧的 —— 拿旧行去合并，`mergedInto` 的校验会用到过期的 `mergedInto`
  /// 值，出现「明明能合却说合不了」。
  Future<void> _mergeSelected(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(mediaRepositoryProvider);
    final keys = ref.read(librarySelectionProvider).keys;

    final all = await repo.allWorks();
    final byKey = {for (final w in all) w.key: w};
    final sources = [for (final k in keys) if (byKey[k] != null) byKey[k]!];
    if (sources.isEmpty) return;
    if (!context.mounted) return;

    final result = await BatchMergeDialog.show(context, sources);
    if (result == null) return;

    // 合并完立刻退出多选：留在模式里的话，列表里那几部已经消失（成了别名
    // 行），而顶栏还写着「已选 5 部」—— 一个指向不存在的东西的计数。
    ref.read(librarySelectionProvider.notifier).exit();
    onRefresh();

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(result.message),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            final n = await WorkMergeService(library: repo)
                .undo(result.plan.sourceKeys);
            onRefresh();
            messenger.showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text('已撤销，$n 部作品恢复为独立条目。'),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 「最近播放」栏为空。
///
/// **不能复用分类那一套空态**：那里写的是「换个分类看看，或者重新扫描一次」，
/// 而这一栏为空跟扫描、跟分类都无关 —— 它就是「还没看过任何片子」。
/// 让用户去重新扫描一部片子也不会出现，只会白等一次全盘遍历。
class _NoPlayHistoryState extends ConsumerWidget {
  const _NoPlayHistoryState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      icon: Icons.history_toggle_off_rounded,
      title: '还没有播放记录',
      body: '看过的片子会按最近一次播放的时间排在这里，'
          '方便下次接着看。随便点开一部开始就行。',
      actionLabel: '去看看全部',
      onAction: () =>
          ref.read(libraryFilterProvider.notifier).setCategory(null),
    );
  }
}

/// 「已刮削」这个视图里什么都没有的空态。
///
/// 与 `_NoPlayHistoryState` 同一条理由：这不是「条件太紧，清掉就好」，
/// 而是**库里还没有刮削过的作品**。走通用的「清掉筛选条件」的话，用户
/// 照做之后列表是回来了，但他想看的那个视图仍然什么都没有，而他并不知道
/// 该去干什么 —— 这一支存在的意义就是把「刮一部试试」说出来。
class _NoScrapedState extends ConsumerWidget {
  const _NoScrapedState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      // 与详情页那个「刮削」按钮同一个图标：用户照着它就能找到入口。
      icon: Icons.auto_awesome_outlined,
      title: '还没有刮削过的作品',
      body: '在作品详情页点「刮削」拿到海报、简介和上映年份之后，'
          '它就会出现在这里。',
      actionLabel: '取消「已刮削」',
      onAction: () =>
          ref.read(libraryFilterProvider.notifier).toggleScrapedOnly(),
    );
  }
}

/// 「库里什么都没有」的空态。
///
/// **必须区分两种空**：
///   - 扫描正在跑：库里为空只是暂时的，要说「正在扫描、已发现 N 个」。
///     实测踩过 —— 原先这里只有一句「点『扫描』把网盘里的视频全部找出来」，
///     而用户明明已经在扫了，看到这句会以为扫描根本没生效；
///   - 真没扫过：给「去扫描」。
class _NeverScannedState extends ConsumerWidget {
  const _NeverScannedState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final loggedIn = auth?.isAuthorized ?? false;
    final scan = ref.watch(scanControllerProvider);

    if (scan.running) {
      final cursor = scan.progress?.cursor;
      final found = cursor?.foundTracks ?? 0;
      final dirs = cursor?.scannedDirs ?? 0;
      return EmptyState(
        icon: Icons.radar_rounded,
        title: '正在扫描网盘…',
        body: '已遍历 $dirs 个目录、发现 $found 个媒体文件。'
            '作品会随着扫描陆续出现在这里，不用等它跑完。',
        actionLabel: '查看进度',
        onAction: () => context.go('/scan'),
      );
    }

    return EmptyState(
      icon: Icons.movie_filter_outlined,
      title: '媒体库还是空的',
      body: loggedIn
          ? '点「扫描」把网盘里的视频全部找出来。第一次扫描会遍历整个网盘，'
              '耗时取决于目录数量。'
          : '当前没有登录任何网盘账号。',
      actionLabel: loggedIn ? '去扫描' : '去登录',
      onAction: () => loggedIn ? context.go('/scan') : context.go('/auth'),
    );
  }
}
