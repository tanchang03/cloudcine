import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/library_providers.dart';
import '../theme/app_theme.dart';

/// 右上角的「筛选」按钮，点开是贴在它下面的年份 / 类型两组多选。
///
/// ## 为什么是浮层而不是常驻的一排
///
/// 分类栏（`_CategoryBar`）已经占了列表上方一整条，再摆两排类型 / 年份
/// 会把海报墙挤到屏幕下半部分 —— 而这两组条件绝大多数时候是不用的。
/// 做成浮层后，**生效的条件会以数字标在按钮上**，所以「现在到底筛没筛」
/// 这件事仍然是随时可见的，只是不再常驻占地方。
///
/// ## 为什么用 [MenuAnchor] 而不是自己搭 Overlay
///
/// 点外部关闭、Esc 关闭、屏幕边缘自动回弹、焦点管理这几件事
/// [MenuAnchor] 都做完了。自己用 `OverlayEntry` + `CompositedTransformFollower`
/// 搭一遍的话，这些边界都要各自处理，而它们恰恰是「菜单偶尔关不掉」
/// 这类难查问题的来源。
///
/// 面板里放的是普通 [InkWell] 而不是 [MenuItemButton]，所以**点一个 chip
/// 不会把面板关掉** —— 多选必须能连续点几下。
///
/// ## ⚠️ 为什么还要自己加一个「关闭」按钮和 [PopScope]
///
/// `MenuAnchor` 关掉自己**只认 Esc**（源码里 `_kMenuShortcuts` 把 `escape`
/// 绑到 `DismissIntent`）。而它是个 `OverlayPortal`、**不是一条路由**，于是：
///   * **Android TV 遥控器上没有 Esc** → 面板一打开就出不去；
///   * 更糟的是，按遥控器的 BACK 会**穿透到路由**上 —— 面板还开着，
///     人已经被带离媒体库了。
///
/// 所以补两条出口：面板底部的显式「关闭」按钮（鼠标/遥控器都能用），
/// 以及 [PopScope]（面板开着时把 BACK 拦下来关面板，而不是退出页面）。
class LibraryFilterButton extends StatefulWidget {
  const LibraryFilterButton({super.key});

  @override
  State<LibraryFilterButton> createState() => _LibraryFilterButtonState();
}

class _LibraryFilterButtonState extends State<LibraryFilterButton> {
  final MenuController _controller = MenuController();

  /// 自己记一份开关状态。
  ///
  /// `MenuController` **不是** `ChangeNotifier`（它就是个普通类，
  /// 只有 `open()` / `close()` / `isOpen`），所以 `PopScope.canPop`
  /// 没法靠监听它来更新 —— 只能借 `MenuAnchor` 的 `onOpen` / `onClose`
  /// 回调把状态同步过来。
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 面板开着时不许退页面：那一下 BACK 的语义是「关面板」。
      canPop: !_open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _controller.close();
      },
      child: MenuAnchor(
        controller: _controller,
        onOpen: () => setState(() => _open = true),
        onClose: () => setState(() => _open = false),
        // 按钮在窗口最右侧，菜单默认从按钮左下角向右展开会出界；
        // Flutter 的菜单布局会把超出的部分自动推回屏幕内，所以这里只需要
        // 留一点竖直间距。
        alignmentOffset: const Offset(0, 6),
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(AppTheme.panel2),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.black),
          elevation: const WidgetStatePropertyAll(10),
          // 面板自己画内边距，菜单默认那圈 8px 会让分组标题贴不到边。
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          maximumSize: const WidgetStatePropertyAll(Size(300, 460)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: AppTheme.line, width: 0.5),
            ),
          ),
        ),
        menuChildren: [_FilterPanel(onClose: _controller.close)],
        builder: (context, controller, child) => _FilterButton(
          open: controller.isOpen,
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
    );
  }
}

/// 按钮本体：图标 + 「筛选」+ 生效条件数。
class _FilterButton extends ConsumerWidget {
  const _FilterButton({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final selected = filter.years.length + filter.genres.length;
    final active = selected > 0;

    // 有生效条件时整颗按钮变强调色并带数字：用户从别的地方回到媒体库，
    // 一眼就能看出「列表不是全量，是因为筛着东西」——
    // 否则只会觉得「怎么少了好多片子」。
    final color = active ? AppTheme.accent : AppTheme.muted;

    return Tooltip(
      message: '按年份 / 类型筛选',
      child: Material(
        color: active
            ? AppTheme.accent.withValues(alpha: open ? 0.22 : 0.14)
            : (open ? AppTheme.panel : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune_rounded, size: 15, color: color),
                const SizedBox(width: 5),
                Text(
                  '筛选',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 5),
                  Text(
                    '$selected',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.accent.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮层内容：年份 + 类型两组，底部「清空筛选」+「关闭」。
class _FilterPanel extends ConsumerWidget {
  const _FilterPanel({required this.onClose});

  /// 显式关闭。**TV 上唯一的出口** —— 遥控器没有 Esc，
  /// 而这个面板是个 `OverlayPortal`（不是路由），BACK 也关不掉它。
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    // 传整个 `AsyncValue` 而不是 `valueOrNull`：后者把「正在加载」和「查询
    // 出错」都变成 `null`，于是出错时面板会永远停在「正在统计…」——
    // 用户等一个永远不会来的结果，而日志里什么都没有。
    final years = ref.watch(yearCountsProvider);
    final genres = ref.watch(genreCountsProvider);
    final notifier = ref.read(libraryFilterProvider.notifier);

    final selected = filter.years.length + filter.genres.length;

    return SizedBox(
      key: const Key('library-filter-panel'),
      width: 292,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 11, 12, 9),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, size: 14, color: AppTheme.muted),
                SizedBox(width: 6),
                Text(
                  '筛选',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppTheme.line),
          Flexible(
            child: SingleChildScrollView(
              // 显式关掉 PrimaryScrollController 的接入：浮层里这个滚动视图
              // 不是「页面的主滚动」。不关的话，它会和菜单自身那一层滚动
              // 抢同一个 controller，Flutter 会直接抛
              // 「PrimaryScrollController is attached to more than one
              // ScrollPosition」—— 而这个错只在**打开面板**时才炸。
              primary: false,
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('年份'),
                  _YearChips(counts: years, filter: filter),
                  const SizedBox(height: 15),
                  const _SectionTitle('类型'),
                  _GenreChips(counts: genres, filter: filter),
                ],
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1, color: AppTheme.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 5, 8, 5),
            child: Row(
              children: [
                Text(
                  selected > 0 ? '已选 $selected 项' : '未选条件',
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
                ),
                const Spacer(),
                TextButton(
                  // 没有条件可清时置灰而不是隐藏：按钮位置固定，
                  // 用户不会因为「上一个状态下这里有东西」而去找它。
                  onPressed: filter.hasExtra ? notifier.clearExtra : null,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor: AppTheme.accent,
                    disabledForegroundColor: AppTheme.dim,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: const Text('清空筛选'),
                ),
                TextButton(
                  // TV 上唯一的出口。做成**常驻可见**而不是「只在 TV 上出现」：
                  // 浮层里有一个明确的「关闭」对鼠标用户同样是好事，
                  // 而且平台条件渲染会让这条路径在开发机上永远测不到。
                  onPressed: onClose,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor: AppTheme.text,
                    textStyle: const TextStyle(fontSize: 12),
                  ),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppTheme.dim,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// 年份一组。倒序（新的在前）—— 用户找的通常是「最近几年的片子」。
///
/// ## 为什么「已选但当前范围里没有」的项也要画出来
///
/// 选项是按当前分类 / 搜索词收窄的（见 `yearCountsProvider`），而选中的
/// 条件**不会**跟着分类切换被清掉（`setCategory` 不碰 `years`）。于是：
/// 用户在「电影」栏选了「1995」，切到「动漫」栏 —— 动漫里一部 1995 年的
/// 片子都没有，这一项就不在 `counts` 里了。
///
/// 只画 `counts` 里有的项的话，那颗 chip 会**整个消失**，而它仍然是生效的
/// 筛选条件：用户看到按钮上写着「已选 2 项」、列表却是空的，却找不到那第二个
/// 条件在哪 —— 唯一的出路是「清空筛选」，把另外那个还想留的条件一起抹掉。
/// 所以这里把它一并画出来并标注「无结果」，让它**可以被单独取消**。
class _YearChips extends ConsumerWidget {
  const _YearChips({required this.counts, required this.filter});

  final AsyncValue<Map<int, int>> counts;
  final LibraryFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = counts.valueOrNull;
    if (c == null) {
      // 区分「还没算完」与「算错了」。混在一起的话，出错时面板会一直显示
      // 「正在统计…」—— 用户等一个永远不会来的结果，而这与「库是空的」
      // 表现完全不同，却被同一句话盖住了。
      return counts.hasError
          ? _Hint('统计年份失败：${counts.error}')
          : const _Hint('正在统计…');
    }

    final missing = filter.years.where((y) => !c.containsKey(y)).toList()
      ..sort((a, b) => b.compareTo(a));

    if (c.isEmpty && missing.isEmpty) {
      // 空的时候要说清「为什么空」：没刮削过的作品只有文件名，
      // 拿不到上映年份 —— 用户看到一片空白时的第一反应会是「功能坏了」。
      //
      // ⚠️ 这一句只在**没有任何已选项**时才说。有已选项时再说它，
      // 就与下面那颗写着「无结果」的 chip 自相矛盾（范围里不是没年份，
      // 而是这个年份没有）。
      return const _Hint('还没有带年份的作品。刮削一次就能拿到上映年份。');
    }

    final notifier = ref.read(libraryFilterProvider.notifier);
    final sorted = c.keys.toList()..sort((a, b) => b.compareTo(a));
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final year in sorted)
          _FilterChip(
            label: '$year',
            count: c[year],
            selected: filter.years.contains(year),
            onTap: () => notifier.toggleYear(year),
          ),
        for (final year in missing)
          _FilterChip(
            label: '$year',
            selected: true,
            stale: true,
            onTap: () => notifier.toggleYear(year),
          ),
      ],
    );
  }
}

/// 类型一组。按作品数倒序 —— 片多的类型排在前面，用户更可能点它。
///
/// 「已选但当前范围里没有」的项照样画出来，理由与 [_YearChips] 完全相同。
class _GenreChips extends ConsumerWidget {
  const _GenreChips({required this.counts, required this.filter});

  final AsyncValue<Map<String, int>> counts;
  final LibraryFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = counts.valueOrNull;
    if (c == null) {
      // 与 [_YearChips] 同理：出错不能伪装成「正在统计…」。
      return counts.hasError
          ? _Hint('统计类型失败：${counts.error}')
          : const _Hint('正在统计…');
    }

    final missing = filter.genres.where((g) => !c.containsKey(g)).toList()
      ..sort();

    if (c.isEmpty && missing.isEmpty) {
      return const _Hint('还没有类型信息。刮削之后类型会出现在这里。');
    }

    final notifier = ref.read(libraryFilterProvider.notifier);
    final sorted = c.keys.toList()
      ..sort((a, b) {
        final byCount = (c[b] ?? 0).compareTo(c[a] ?? 0);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final genre in sorted)
          _FilterChip(
            label: genre,
            count: c[genre],
            selected: filter.genres.contains(genre),
            onTap: () => notifier.toggleGenre(genre),
          ),
        for (final genre in missing)
          _FilterChip(
            label: genre,
            selected: true,
            stale: true,
            onTap: () => notifier.toggleGenre(genre),
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.stale = false,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  /// 已选中、但**当前筛选范围里一条都没有**。
  ///
  /// 它仍然是生效的条件（列表为空正因为它），所以照样打勾、照样能点 ——
  /// 只是把数量换成「无结果」，说清为什么这个选项看着「不该在」。
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.accent.withValues(alpha: 0.18) : AppTheme.panel,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: selected
                  ? AppTheme.accent.withValues(alpha: 0.55)
                  : AppTheme.line,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 打勾而不是只换颜色：颜色在深色主题下差异有限，
              // 而多选里「哪几个是选中的」必须一眼可辨。
              if (selected) ...[
                const Icon(Icons.check_rounded, size: 12, color: AppTheme.accent),
                const SizedBox(width: 3),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  // 灰掉而不是用强调色：这一项点下去是**空列表**，
                  // 不该和「有结果」的选项长得一样。
                  color: stale
                      ? AppTheme.dim
                      : (selected ? AppTheme.accent : AppTheme.muted),
                ),
              ),
              if (stale) ...[
                const SizedBox(width: 4),
                const Text(
                  '无结果',
                  style: TextStyle(fontSize: 10, color: AppTheme.dim),
                ),
              ] else if (count != null && count! > 0) ...[
                const SizedBox(width: 4),
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    color: selected
                        ? AppTheme.accent.withValues(alpha: 0.7)
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

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 11.5, color: AppTheme.dim, height: 1.45),
    );
  }
}
