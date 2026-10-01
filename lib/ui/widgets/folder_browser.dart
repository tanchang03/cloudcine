import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_item.dart';
import '../../domain/services/folder_tree.dart';
import '../providers/folder_providers.dart';
import '../providers/library_providers.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'copy_button.dart';
import 'media_item_row.dart';

/// 网盘目录视图。
///
/// ## 它解决什么问题
///
/// 海报墙是**按作品**组织的（一部剧一个格子），而用户经常是**按位置**找东西：
/// 「我上礼拜存在 `/电影/科幻/` 那部片子叫什么来着」。没有这个视图时，
/// 唯一的线索是详情页里那一行路径，得一部一部点进去看。
///
/// ## 数据从哪来
///
/// 完全来自**本地索引**（`MediaItem.dirPath`），不连网盘 —— 见
/// [FolderTree]。所以翻目录是纯内存操作，网盘掉线也能用。
///
/// ## 两种模式
///
///   - **浏览**：面包屑 + 当前层的子目录与文件；
///   - **搜索**：搜索框里有词时切成平铺结果，**文件夹与文件分开列**，
///     每条文件都带完整路径 —— 这才是「根据文件夹路径找媒体文件」。
class FolderBrowser extends ConsumerWidget {
  const FolderBrowser({super.key, required this.onClearSearch});

  /// 清空搜索框。
  ///
  /// 由页面传进来，因为搜索词的真源在页面的 `TextEditingController` 里
  /// （`libraryFilterProvider.query` 只是它的影子）。从这里直接改 provider
  /// 会让输入框里留着旧词而列表已经不过滤了 —— 那种不一致比不清空更难懂。
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final treeAsync = ref.watch(folderTreeProvider);
    final path = ref.watch(currentFolderProvider);
    final query = ref.watch(libraryFilterProvider).query.trim();

    return treeAsync.when(
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
        title: '读取目录失败',
        body: '$e',
        actionLabel: '重试',
        onAction: () => ref.invalidate(folderTreeProvider),
      ),
      data: (tree) {
        if (query.isNotEmpty) {
          return _SearchResults(
            tree: tree,
            query: query,
            onClearSearch: onClearSearch,
          );
        }

        final node = tree.nodeAt(path);
        if (node == null) {
          // 重扫之后目录没了（网盘上被改名/删除）。给一条明确的出路，
          // 而不是渲染一棵空树让用户以为盘里没东西了。
          return EmptyState(
            icon: Icons.folder_off_outlined,
            title: '这个目录已经不在了',
            body: '$path\n\n它可能在网盘上被改名或删除了，重新扫描后目录树会更新。',
            actionLabel: '回到根目录',
            onAction: () => ref.read(currentFolderProvider.notifier).reset(),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Breadcrumb(tree: tree, node: node),
            Expanded(child: _FolderList(node: node)),
          ],
        );
      },
    );
  }
}

/// 面包屑 + 上一级 + 复制路径。
///
/// 面包屑是**可点的**，不只是装饰：用户从 `/电影/科幻/2023/` 里想跳到
/// `/电影/科幻/` 时，点一下比按三次「上一级」直接。
class _Breadcrumb extends ConsumerStatefulWidget {
  const _Breadcrumb({required this.tree, required this.node});

  final FolderTree tree;
  final FolderNode node;

  @override
  ConsumerState<_Breadcrumb> createState() => _BreadcrumbState();
}

class _BreadcrumbState extends ConsumerState<_Breadcrumb> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToEnd();
  }

  @override
  void didUpdateWidget(covariant _Breadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.path != widget.node.path) _scrollToEnd();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 把面包屑滚到**末尾**，让当前目录始终可见。
  ///
  /// 面包屑唯一的用处就是回答「我在哪」，而路径一深（`/电影/科幻/2023/4K/`）
  /// 当前那一段就会被挤出可视区 —— 那时它变成了一条「显示祖先」的装饰。
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chain = widget.tree.pathTo(widget.node.path);
    final atRoot = widget.node.isRoot;
    final controller = ref.read(currentFolderProvider.notifier);

    return Container(
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: atRoot ? null : controller.up,
            iconSize: 16,
            padding: EdgeInsets.zero,
            // 默认的 48×48 会把这一条撑成两倍高，跟分类栏（28）明显不齐。
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            tooltip: atRoot ? '已经在最上层' : '上一级',
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < chain.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          '/',
                          style: TextStyle(fontSize: 11, color: AppTheme.dim),
                        ),
                      ),
                    _Crumb(
                      label: chain[i].isRoot ? '根目录' : chain[i].name,
                      current: i == chain.length - 1,
                      onTap: () => controller.open(chain[i].path),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            widget.node.directFileCount == 0
                ? '${widget.node.itemCount} 个文件'
                : '本层 ${widget.node.directFileCount} 个 · '
                    '共 ${widget.node.itemCount} 个',
            style: const TextStyle(fontSize: 11, color: AppTheme.dim),
          ),
          const SizedBox(width: 4),
          CopyTextButton(
            text: widget.node.path,
            label: '复制当前目录路径',
            icon: Icons.folder_copy_outlined,
          ),
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.label,
    required this.current,
    required this.onTap,
  });

  final String label;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: current ? AppTheme.panel2 : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: current ? null : onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'Menlo',
              fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              color: current ? AppTheme.text : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 当前层的子目录 + 文件。
class _FolderList extends ConsumerWidget {
  const _FolderList({required this.node});

  final FolderNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = node.children;
    final files = node.files;

    if (children.isEmpty && files.isEmpty) {
      // 根目录为空 = 整库为空，那是「还没扫过」；子目录为空只是这一层没东西。
      // 两者的出路完全不同，所以行动按钮必须分开给。
      final atRoot = node.isRoot;
      return EmptyState(
        icon: Icons.folder_open_rounded,
        title: atRoot ? '库里还没有媒体文件' : '这个文件夹里没有视频',
        body: atRoot
            ? '先去「扫描」把网盘里的视频找出来，目录树会随着扫描一起建好。'
            : '它可能只装了字幕、图片这类不索引的文件，'
                '或者视频都在它的子文件夹里。',
        actionLabel: atRoot ? '去扫描' : '回到根目录',
        onAction: atRoot
            ? () => context.go('/scan')
            : () => ref.read(currentFolderProvider.notifier).reset(),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
      itemCount: children.length + files.length,
      itemBuilder: (context, i) {
        if (i < children.length) {
          final child = children[i];
          return _FolderRow(
            node: child,
            onTap: () =>
                ref.read(currentFolderProvider.notifier).open(child.path),
          );
        }
        // 目录内部的文件**不重复显示完整路径** —— 面包屑已经说清在哪了，
        // 每行再来一遍会把列表刷成一堵路径墙。搜索结果里则相反，那里
        // 「在哪」正是用户要找的信息。
        return MediaItemRow(item: files[i - children.length], showPath: false);
      },
    );
  }
}

/// 一行子目录。
class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.node, required this.onTap});

  final FolderNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (node.itemCount > 0) '${node.itemCount} 个文件',
      if (node.children.isNotEmpty) '${node.children.length} 个子文件夹',
      if (node.totalBytes > 0) formatBytes(node.totalBytes),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                const Icon(
                  Icons.folder_rounded,
                  size: 18,
                  color: AppTheme.accent,
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: AppTheme.text,
                        ),
                      ),
                      if (parts.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          parts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.dim,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppTheme.dim,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索结果（搜索框里有词时）。
///
/// 文件夹在前、文件在后 —— 用户搜「科幻」时，先看到的是那个目录，
/// 点进去就能继续按位置浏览；直接把目录里的片子摊平反而丢了结构。
class _SearchResults extends ConsumerWidget {
  const _SearchResults({
    required this.tree,
    required this.query,
    required this.onClearSearch,
  });

  final FolderTree tree;
  final String query;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = tree.findFolders(query);
    final files = tree.findFiles(query);

    if (folders.isEmpty && files.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '没有匹配的目录或文件',
        body: '搜「$query」在目录名、文件名和完整路径里都没有命中。',
        actionLabel: '清空搜索',
        onAction: onClearSearch,
      );
    }

    // 从搜索结果进目录 / 定位到某个文件所在目录时，**必须先把搜索清掉**：
    // 否则跳过去之后列表还是搜索结果，看起来像「点了没反应」。
    void goTo(String path) {
      onClearSearch();
      ref.read(currentFolderProvider.notifier).open(path);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
          child: Text(
            '“$query” 命中 ${folders.length} 个目录 · ${files.length} 个文件'
            '${files.length >= 300 ? '（文件只显示前 300 个）' : ''}',
            style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
            itemCount: folders.length + files.length,
            itemBuilder: (context, i) {
              if (i < folders.length) {
                final folder = folders[i];
                return _FolderRow(
                  node: folder,
                  onTap: () => goTo(folder.path),
                );
              }
              final item = files[i - folders.length];
              return MediaItemRow(
                item: item,
                showPath: true,
                onLocate: () => goTo(item.dirPath),
                locateTooltip: '在目录中显示',
              );
            },
          ),
        ),
      ],
    );
  }
}
