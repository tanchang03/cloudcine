import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/media_category.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_work.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../providers/drive_browse_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scan_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/folder_browser.dart';
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

    if (filter.hasExtra && hasQuery) {
      return (
        body: '没有同时匹配「$query」与所选年份 / 类型的作品。',
        actionLabel: '清空筛选条件',
        action: LibraryEmptyAction.clearExtraAndQuery,
      );
    }
    if (filter.hasExtra) {
      return (
        body: '当前筛选条件下一条都没筛到。清掉年份 / 类型再看看。',
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

  /// 重新读库。两种视图的数据来源不同（作品表 / 网盘目录），必须一起失效。
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
    // 目录视图：列表本身要重列网盘，叠加的「已入库」标记也要重算。
    ref.invalidate(folderTreeProvider);
    ref.invalidate(indexedFileIdsProvider);
    ref.invalidate(driveListingProvider);
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(libraryViewProvider);
    final works = ref.watch(workListProvider);
    final stats = ref.watch(libraryStatsProvider).valueOrNull;
    final filter = ref.watch(libraryFilterProvider);
    final scanning = ref.watch(scanControllerProvider).running;
    final posters = view == LibraryView.posters;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '媒体库',
          subtitle: posters
              ? (stats == null
                  ? null
                  : '${stats.items} 个视频 · ${stats.works} 部作品')
              : _folderSubtitle(ref),
          actions: [
            if (scanning)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    SizedBox(width: 7),
                    Text(
                      '正在扫描',
                      style: TextStyle(fontSize: 11.5, color: AppTheme.accent),
                    ),
                  ],
                ),
              ),
            const _ViewSwitch(),
            const SizedBox(width: 8),
            _SearchBox(
              controller: _search,
              onChanged: _onSearchChanged,
              // 两个视图搜的东西**不是一回事**，提示词必须说清：海报墙搜的是
              // 库里已入库的作品/文件，目录视图筛的是**当前这一层网盘目录**。
              hint: posters ? '搜片名或文件名…' : '筛当前目录…',
            ),
            // 排序只对海报墙有意义：目录视图按**目录结构**排（自然序），
            // 换排序方式在那里没有任何东西会变，摆着只会让人以为坏了。
            if (posters) ...[
              const SizedBox(width: 8),
              const _SortMenu(),
              const SizedBox(width: 4),
              // 年份 / 类型筛选同理：目录视图的列表是**文件**，
              // 而年份 / 类型是作品的元数据，在那里没有可筛的东西。
              const LibraryFilterButton(),
            ],
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
        if (posters) ...[
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
                  // 三种空态要分开：**库里本来就没有**（该去扫描）、
                  // **这一栏本来就该是空的**（还没看过任何片子）、
                  // **筛选没筛到**（该清条件）。给错行动按钮比不给更糟。
                  if (filter.playedOnly) return const _NoPlayHistoryState();
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
                return _PosterGrid(works: list);
              },
            ),
          ),
        ] else
          Expanded(child: FolderBrowser(onClearSearch: _clearSearch)),
      ],
    );
  }

  /// 目录视图的副标题：当前网盘目录 + 它这一层有什么。
  ///
  /// 副标题必须**跟着浏览位置变**：它回答的是「我现在在哪、这一层有多少」。
  /// 只在页头显示一次整库规模的话，用户翻进一个空目录会以为整个盘空了。
  ///
  /// 数字来自网盘列表本身（而不是本地索引）：这个视图现在描述的是
  /// 「网盘上有什么」，用一个本地索引算出来的数字会与列表里看到的对不上。
  static String? _folderSubtitle(WidgetRef ref) {
    final crumb = ref.watch(currentCrumbProvider);
    final listing = ref.watch(driveListingProvider(crumb)).valueOrNull;
    final where = crumb.isRoot ? '根目录' : crumb.path;
    if (listing == null) return where;
    final extra = listing.otherFileCount > 0
        ? ' · 另有 ${listing.otherFileCount} 个非视频文件'
        : '';
    return '$where · ${listing.folders.length} 个子目录 · '
        '${listing.videos.length} 个视频$extra';
  }
}

/// 「海报墙 / 文件夹」切换。
///
/// 做成同一页面里的分段控件而不是侧栏第四项：两者读的是同一批数据，
/// 只是视角不同（「有哪些片子」vs「网盘上是怎么放的」）。分成两个一级入口
/// 会让用户觉得它们是两个功能，而搜索、刷新、扫描状态这些本该共用的东西
/// 也得各写一份。
class _ViewSwitch extends ConsumerWidget {
  const _ViewSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(libraryViewProvider);

    return Container(
      height: 32,
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
              icon: option == LibraryView.posters
                  ? Icons.grid_view_rounded
                  : Icons.folder_rounded,
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
    final color = selected ? AppTheme.text : AppTheme.muted;
    return Material(
      color: selected ? AppTheme.panel3 : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
      child: SizedBox(
        height: 28,
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
            const SizedBox(width: 6),
            _CategoryChip(
              label: '最近播放',
              icon: Icons.history_rounded,
              count: played,
              selected: filter.playedOnly,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).setPlayedOnly(),
            ),
            for (final category in MediaCategory.displayOrder) ...[
              const SizedBox(width: 6),
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
    return Material(
      color: selected ? AppTheme.accent.withValues(alpha: 0.16) : AppTheme.panel,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 13,
                  color: selected ? AppTheme.accent : AppTheme.muted,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? AppTheme.accent : AppTheme.muted,
                ),
              ),
              // 计数为 0 或还没算出来时不显示角标：一个「综艺 0」的按钮
              // 只会让人以为坏了，而它其实只是没有综艺。
              if (count != null && count! > 0) ...[
                const SizedBox(width: 5),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10.5,
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
    setState(() => _resolving = true);
    try {
      final item = await resolvePlayTarget(
        ref.read(mediaRepositoryProvider),
        widget.work.key,
      );
      if (!mounted) return;
      if (item == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('这部作品下没有可播放的文件'),
          ),
        );
        return;
      }
      diag.info('媒体库', '卡片直开：${widget.work.title} → ${item.displayTitle}');
      await playItem(context, ref, item);
    } catch (e, st) {
      diag.error('媒体库', '卡片直开失败', error: e, stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('打开失败：$e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _openDetail() => context.push(
        '/work?key=${Uri.encodeComponent(widget.work.key)}',
      );

  @override
  Widget build(BuildContext context) {
    final work = widget.work;

    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _play,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(work: work),
                  // 悬停时压一层暗罩 + 播放图标：把「点这张卡片会直接播」
                  // 这件事在点下去**之前**就说清楚。
                  if (_hovered && !_resolving)
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

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.onChanged,
    required this.hint,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// 提示词随视图变：海报墙搜的是「片名 / 文件名」，目录视图还多一层
  /// **路径**（那正是它存在的理由），不写出来的话用户不会想到可以搜目录。
  final String hint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      // ⚠️ 这个高度是**写死的 32**，故意不进 tvTextScaler。媒体库页头（含搜索框）
      // 不能在 TV 上放大字号：P1-3 给海报网格套了 `tvTextScaler`，但页头那行
      // 没有 —— 一个固定高度的输入框一旦被放大字号，里面的字会顶破 32 的框、
      // 触发 RenderFlex 溢出。要放大也得先让这个 `SizedBox` 改吸收高度。
      height: 32,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
        cursorHeight: 14,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12, color: AppTheme.dim),
          prefixIcon: const Icon(Icons.search_rounded, size: 15),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          filled: true,
          fillColor: AppTheme.panel,
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.accent, width: 0.8),
          ),
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
