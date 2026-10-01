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
import '../providers/folder_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scan_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/folder_browser.dart';
import '../widgets/play_action.dart';
import '../widgets/poster_image.dart';

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

  /// 重新读库。两种视图的数据来源不同（作品表 / 媒体项表），必须一起失效。
  void _refresh() {
    ref.invalidate(workListProvider);
    ref.invalidate(categoryCountsProvider);
    ref.invalidate(playedCountProvider);
    ref.invalidate(libraryStatsProvider);
    ref.invalidate(folderTreeProvider);
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
              hint: posters ? '搜片名或文件名…' : '搜文件名或目录路径…',
            ),
            // 排序只对海报墙有意义：目录视图按**目录结构**排（自然序），
            // 换排序方式在那里没有任何东西会变，摆着只会让人以为坏了。
            if (posters) ...[
              const SizedBox(width: 8),
              const _SortMenu(),
            ],
            IconButton(
              tooltip: '刷新',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded, size: 17),
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
                  return filter.isEmpty
                      ? const _NeverScannedState()
                      : EmptyState(
                          icon: Icons.search_off_rounded,
                          title: '这里还没有内容',
                          body: filter.query.trim().isEmpty
                              ? '这个分类下暂时没有作品。换个分类看看，'
                                  '或者重新扫描一次。'
                              : '换个关键词，或者清掉筛选条件。',
                          actionLabel: '清空筛选',
                          onAction: () => ref
                              .read(libraryFilterProvider.notifier)
                              .clear(),
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

  /// 目录视图的副标题：整库规模 + 当前目录规模。
  ///
  /// 两者都要给：整库规模回答「这盘里有多少东西」，当前目录规模回答
  /// 「我在的这一层有多少」—— 只有前者时，用户翻进一个空目录会以为库空了。
  static String? _folderSubtitle(WidgetRef ref) {
    final tree = ref.watch(folderTreeProvider).valueOrNull;
    if (tree == null) return null;
    final node = tree.nodeAt(ref.watch(currentFolderProvider));
    final head = '${tree.fileCount} 个视频 · ${tree.subfolderCount} 个文件夹';
    if (node == null || node.isRoot) return head;
    return '$head · 当前目录 ${node.itemCount} 个';
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
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // 用「最大宽度」而不是固定列数：侧栏固定宽 + 窗口可缩放，
        // 固定列数会让宽窗口下的海报被拉成巨幅。
        maxCrossAxisExtent: 172,
        mainAxisSpacing: 18,
        crossAxisSpacing: 14,
        // 用主题里的标准海报比例（2:3），不要在这里写魔法数字。
        //
        // 这个值要和 `PosterImage` 的画法配套看：那里前景是 `BoxFit.contain`，
        // 所以卡片取 2:3 时，**2:3 的 TMDB 真海报正好铺满、看不到模糊底**；
        // 而 16:9 的夸克视频帧会完整落在卡片中部，上下由模糊底图填。
        // 取更窄的比例（比如原来写的 0.56）只会让视频帧更小、模糊带更宽。
        childAspectRatio: AppTheme.posterAspect,
      ),
      itemCount: works.length,
      itemBuilder: (context, i) => _WorkCard(work: works[i]),
    );
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

    return MouseRegion(
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
          ],
        ),
      ),
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
