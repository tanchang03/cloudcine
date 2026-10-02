import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/format.dart';
import '../../domain/entities/drive_entry.dart';
// ⚠️ 必须 `hide formatBytes`：`media_item.dart` 里也有一个同名函数
// （二进制单位、只收 `int`），两个都导入会让每一处调用变成 ambiguous。
// 这里要的是 core 里那个（收 `int?`、可指定小数位）。
import '../../domain/entities/media_item.dart' hide formatBytes;
import '../../domain/services/media_discovery.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../providers/drive_browse_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scan_providers.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'copy_button.dart';
import 'play_action.dart';
import 'tv_affordance.dart';

/// 网盘目录视图。
///
/// ## 它解决什么问题
///
/// 海报墙是**按作品**组织的（一部剧一个格子），而用户经常是**按位置**找东西：
/// 「我上礼拜存在 `/电影/科幻/` 那部片子叫什么来着」。没有这个视图时，
/// 唯一的线索是详情页里那一行路径，得一部一部点进去看。
///
/// ## 数据从哪来：**网盘实时目录**，不是本地索引
///
/// 这是本视图与「已扫描媒体库」的根本分工：
///
///   - 海报墙 = 「我库里有什么」，读本地索引，离线可用；
///   - 目录视图 = 「网盘上有什么」，**逐层实时列目录**。
///
/// 原先两者读的是同一份本地索引（目录树由 `MediaItem.dirPath` 重建）。
/// 那样做有个躲不开的后果：**媒体库里没扫到的东西，在目录视图里也看不见**。
/// 新上传一部电影、上次扫描漏掉一个目录、扫描中途被取消 —— 用户在目录视图里
/// 翻到那个位置会看到「空的」，而网盘上明明有东西。要让他看到，只能再跑一次
/// 全盘扫描（几千个目录、几分钟）。
///
/// 现在目录视图读网盘本身，于是它天然回答了「我新传的东西在哪」，并且可以
/// 就地**发现**（见下）。本地索引退居叠加层，只用来标记「这个已经在库里了」。
///
/// ## 发现：只走用户指的那一小片
///
/// 目录行有「发现」，视频文件行有「加入媒体库」，页头有「发现本目录」。
/// 它们都只遍历用户指定的那一片，几秒完成，且**只增不减** —— 与全盘扫描的
/// 区别见 [MediaDiscoveryService] 的类文档。
///
/// ## 搜索
///
/// 搜索框在目录视图里筛的是**当前这一层**（客户端过滤，瞬时，不发请求）。
/// 跨目录找东西由海报墙的搜索负责：网盘的搜索接口只按关键词返回一批结果，
/// 没法按路径枚举（`file/search` 换关键词返回同一批，见 `HOWTO.md`），
/// 拿它假装「全盘路径搜索」只会给出看起来对、其实不全的结果。
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
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final loggedIn = auth?.isAuthorized ?? false;
    final crumb = ref.watch(currentCrumbProvider);
    final listing = ref.watch(driveListingProvider(crumb));
    final query = ref.watch(libraryFilterProvider).query.trim();

    // 发现跑完时给一条结果提示。**只在「运行中 → 结束」那一次跳变上触发**：
    // 每一条进度回调都弹一次的话，用户会被几十个 SnackBar 刷屏。
    ref.listen<DiscoveryState>(discoveryControllerProvider, (prev, next) {
      if (prev?.running != true || next.running) return;
      final text = _discoveryMessage(next);
      if (text == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(text)),
      );
    });

    if (!loggedIn) {
      return EmptyState(
        icon: Icons.lock_outline_rounded,
        title: '目录视图要读网盘',
        body: '它直接列网盘上的目录结构（不是读已扫描的媒体库），'
            '所以需要先登录网盘账号。',
        actionLabel: '去登录',
        onAction: () => context.go('/auth'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Breadcrumb(
          stack: ref.watch(driveBrowseProvider),
          onClearSearch: onClearSearch,
        ),
        _DiscoveryBar(crumb: crumb),
        Expanded(
          child: listing.when(
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
              title: '读取网盘目录失败',
              body: '$e',
              actionLabel: '重试',
              onAction: () => ref.invalidate(driveListingProvider(crumb)),
            ),
            data: (l) => _EntryList(
              listing: l,
              query: query,
              onClearSearch: onClearSearch,
            ),
          ),
        ),
      ],
    );
  }

  /// 发现结束后的提示文案。
  static String? _discoveryMessage(DiscoveryState s) {
    if (s.error != null) return s.error;
    final o = s.outcome;
    if (o == null) return null;

    final target = s.target ?? o.rootPath;
    final what = o.scope == DiscoveryScope.file ? '文件' : '目录';

    // ⚠️ 「一个视频都没找到」和「目录根本没读到」必须分开说。
    // 前者是事实（这里确实没有视频），后者的数字是**偏小**的 ——
    // 合成一句「没有发现可入库的视频」，用户会以为网盘上真没有，
    // 而其实只是那一次请求超时了。
    if (o.isEmpty && o.failedDirs > 0) {
      return '「$target」这次没读到（${o.failedDirs} 个目录失败），'
          '可能不是空的，稍后再试一次。';
    }
    if (o.isEmpty) {
      return '「$target」里没有发现可入库的视频'
          '${o.scope == DiscoveryScope.file ? '' : '（含子目录）'}';
    }

    final buf = StringBuffer('$what「$target」发现 ${o.mediaFound} 个视频：')
      ..write('新增 ${o.added}')
      ..write(' · 已在库 ${o.existing}')
      ..write(' · 涉及 ${o.works} 部作品');
    if (o.subtitlesIndexed > 0) buf.write(' · 字幕 ${o.subtitlesIndexed} 条');
    // 有目录没读到时必须说出来：这时的数字**偏小**，不说就会被当成
    // 「就这么多」——用户会以为新片没被发现。
    if (o.failedDirs > 0) buf.write('（有 ${o.failedDirs} 个目录没读到，结果不完整）');
    return buf.toString();
  }
}

/// 面包屑 + 上一级 + 复制路径。
///
/// 面包屑是**可点的**，不只是装饰：用户从 `/电影/科幻/2023/` 里想跳到
/// `/电影/科幻/` 时，点一下比按三次「上一级」直接。
///
/// 它读的是**浏览栈**（每一格带着网盘目录 ID），不是从路径反推 ——
/// 网盘允许同名目录，靠路径反推会把两棵不同的子树并成一棵。
class _Breadcrumb extends ConsumerStatefulWidget {
  const _Breadcrumb({required this.stack, required this.onClearSearch});

  final List<DriveCrumb> stack;

  /// 跳层前先清空搜索。
  ///
  /// **不清的话，跳过去之后列表还是被同一个词过滤着** —— 用户看到的是一个
  /// 空目录（或者只剩零星几条），第一反应是「点了没反应」。搜索词在
  /// 页面顶部的输入框里，而它离用户点的地方很远，很难把两件事联系起来。
  ///
  /// 必须由页面传进来（而不是在这里改 provider）：输入框的真源是页面的
  /// `TextEditingController`，只清 provider 会让框里留着旧词而列表已经
  /// 不过滤了 —— 那种自相矛盾比不清空更难懂。
  final VoidCallback onClearSearch;

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
    if (oldWidget.stack.length != widget.stack.length ||
        oldWidget.stack.last != widget.stack.last) {
      _scrollToEnd();
    }
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
    final stack = widget.stack;
    final atRoot = stack.length <= 1;
    final controller = ref.read(driveBrowseProvider.notifier);
    final listing = ref.watch(driveListingProvider(stack.last)).valueOrNull;

    /// 跳层 = 先清搜索再动栈。
    void navigate(VoidCallback action) {
      widget.onClearSearch();
      action();
    }

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
          // 「上一级」是纯图标按钮；TV 上补一个文字标签，
          // 否则「已经在最上层」与「上一级」两种状态只能靠颜色分辨。
          TvIconLabel(
            label: atRoot ? '最上层' : '上一级',
            enabled: !atRoot,
            child: IconButton(
              onPressed: atRoot ? null : () => navigate(controller.up),
              iconSize: 16,
              padding: EdgeInsets.zero,
              // 默认的 48×48 会把这一条撑成两倍高，跟分类栏（28）明显不齐。
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              tooltip: atRoot ? '已经在最上层' : '上一级',
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < stack.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          '/',
                          style: TextStyle(fontSize: 11, color: AppTheme.dim),
                        ),
                      ),
                    _Crumb(
                      label: stack[i].isRoot ? '根目录' : stack[i].name,
                      current: i == stack.length - 1,
                      onTap: () => navigate(() => controller.open(stack[i])),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            listing == null
                ? '读取中…'
                : '${listing.folders.length} 个子目录 · '
                    '${listing.videos.length} 个视频',
            style: const TextStyle(fontSize: 11, color: AppTheme.dim),
          ),
          const SizedBox(width: 4),
          CopyTextButton(
            text: stack.last.path,
            label: '复制当前目录路径',
            tvLabel: '复制路径',
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

/// 「发现」这一排：说明当前目录 + 两个发现入口 + 进度。
class _DiscoveryBar extends ConsumerWidget {
  const _DiscoveryBar({required this.crumb});

  final DriveCrumb crumb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovery = ref.watch(discoveryControllerProvider);
    final scanning = ref.watch(scanControllerProvider).running;
    final controller = ref.read(discoveryControllerProvider.notifier);
    // 扫描在跑时不许发现：两边的节流器是各自独立的实例，并发跑等于把实际
    // QPS 翻倍（见 `DiscoveryController.canStart`）。按钮必须**置灰**，
    // 而不是点了没反应 —— 后者会被当成功能坏了。
    final enabled = !discovery.running && !scanning;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              discovery.running
                  ? _progressLabel(discovery)
                  : scanning
                      ? '正在全盘扫描，等它跑完再发现（同时跑会把网盘请求速率翻倍）。'
                      : '发现会把这里（含子目录）的视频补进媒体库，'
                          '只增不减，不会碰其他目录。',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: discovery.running ? AppTheme.accent : AppTheme.dim,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (discovery.running) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: controller.cancel,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('停止', style: TextStyle(fontSize: 12)),
            ),
          ] else ...[
            // 两个入口都摆出来，不做成菜单：绝大多数时候用户要的是「含子目录」，
            // 但它对「我只想看这一层」的人来说是错的（会白列一堆子目录）。
            TextButton(
              onPressed: enabled
                  ? () => controller.discoverDirectory(crumb, recursive: false)
                  : null,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('仅本层', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed:
                  enabled ? () => controller.discoverDirectory(crumb) : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.travel_explore_rounded, size: 15),
              label: const Text(
                '发现本目录',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _progressLabel(DiscoveryState s) {
    final p = s.progress;
    final target = s.target ?? '';
    if (p == null) return '正在发现「$target」…';
    return '正在发现「$target」：已看 ${p.scannedDirs} 个目录 · '
        '${p.scannedFiles} 个文件 · 媒体 ${p.mediaFound} · 新增 ${p.added}';
  }
}

/// 当前层的子目录 + 视频（可选按关键词过滤）。
class _EntryList extends ConsumerWidget {
  const _EntryList({
    required this.listing,
    required this.query,
    required this.onClearSearch,
  });

  final DriveListing listing;
  final String query;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = query.toLowerCase();
    final filtering = q.isNotEmpty;

    final folders = filtering
        ? listing.folders.where((e) => e.name.toLowerCase().contains(q)).toList()
        : listing.folders;
    final videos = filtering
        ? listing.videos.where((e) => e.name.toLowerCase().contains(q)).toList()
        : listing.videos;

    if (folders.isEmpty && videos.isEmpty) {
      return _emptyState(ref, filtering);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
      itemCount: folders.length + videos.length,
      itemBuilder: (context, i) {
        if (i < folders.length) {
          return _FolderRow(
            crumb: listing.crumb,
            dir: folders[i],
            // 进目录前先清搜索：否则跳过去之后列表仍被同一个词过滤着，
            // 看到的是空目录 —— 用户的第一反应是「点了没反应」。
            onTap: () {
              if (filtering) onClearSearch();
              ref
                  .read(driveBrowseProvider.notifier)
                  .open(listing.crumb.child(folders[i]));
            },
          );
        }
        return _DriveFileRow(crumb: listing.crumb, entry: videos[i - folders.length]);
      },
    );
  }

  Widget _emptyState(WidgetRef ref, bool filtering) {
    if (filtering) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '这一层没有匹配的目录或视频',
        body: '搜「$query」只筛**当前目录**的条目。'
            '要找整个媒体库里的片子，去海报墙搜。',
        actionLabel: '清空搜索',
        onAction: onClearSearch,
      );
    }

    // 「这一层没有视频」和「这个目录是空的」是两回事：前者很常见
    // （片子都在子目录里），后者的出路完全不同。
    final hasFolders = listing.folders.isNotEmpty;
    if (hasFolders) {
      return const EmptyState(
        icon: Icons.folder_open_rounded,
        title: '这一层没有视频',
        body: '视频都在它的子目录里。进一个子目录，或者用上面的'
            '「发现本目录」把整棵子树一次找完。',
      );
    }
    return EmptyState(
      icon: Icons.folder_off_outlined,
      title: '这个目录是空的',
      body: '网盘上这个目录里什么都没有。',
      actionLabel: '回到根目录',
      onAction: () => ref.read(driveBrowseProvider.notifier).reset(),
    );
  }
}

/// 一行子目录：进目录（点整行）+ 只发现这一个目录（右侧按钮）。
class _FolderRow extends ConsumerWidget {
  const _FolderRow({
    required this.crumb,
    required this.dir,
    required this.onTap,
  });

  /// 父目录格（用来算这一格的路径与 ID）。
  final DriveCrumb crumb;
  final DriveEntry dir;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovery = ref.watch(discoveryControllerProvider);
    final scanning = ref.watch(scanControllerProvider).running;
    final child = crumb.child(dir);
    final indexed = ref.watch(folderTreeProvider).valueOrNull
            ?.indexedCountAt(child.path) ??
        0;

    final parts = <String>[
      if (indexed > 0) '已入库 $indexed 个',
      if (dir.sizeBytes != null && dir.sizeBytes! > 0)
        formatBytes(dir.sizeBytes, fractionDigits: 1),
      if (dir.modifiedAt != null) formatRelativeTime(dir.modifiedAt!),
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
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
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
                        dir.name,
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
                // 「只发现这一个目录」——不递归。用户点它往往是因为
                // 「子目录太多，我只想要这一层」。
                //
                // 这句话**只**存在于 tooltip 里，而 tooltip 要 hover ——
                // 电视上没有 hover，所以 TV 上补一个「只这一层」标签：
                // 没有它，这个 ⤒ 图标在电视上就是一个猜不出用途的符号。
                TvIconLabel(
                  label: '只这一层',
                  enabled: !(discovery.running || scanning),
                  child: Tooltip(
                    message: '只发现「${dir.name}」这一层',
                    child: IconButton(
                      onPressed: discovery.running || scanning
                          ? null
                          : () => ref
                              .read(discoveryControllerProvider.notifier)
                              .discoverDirectory(child, recursive: false),
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      icon: const Icon(Icons.travel_explore_rounded),
                    ),
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

/// 一行网盘上的视频文件。
///
/// 与作品详情页的 `MediaItemRow` 刻意不共用：那一行描述的是**已入库的媒体项**
/// （有解析出的片名、有分辨率档位），这一行描述的是**网盘上的一个文件**
/// （还没入库，只有文件名）。混用会让人分不清「这是库里的还是盘上的」。
class _DriveFileRow extends ConsumerWidget {
  const _DriveFileRow({required this.crumb, required this.entry});

  final DriveCrumb crumb;
  final DriveEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexedIds = ref.watch(indexedFileIdsProvider).valueOrNull;
    final discovery = ref.watch(discoveryControllerProvider);
    final scanning = ref.watch(scanControllerProvider).running;
    final inLibrary =
        indexedIds?.contains(MediaItem.idFor(browseProvider, entry.id)) ?? false;

    final parts = <String>[
      if (entry.sizeBytes != null && entry.sizeBytes! > 0)
        formatBytes(entry.sizeBytes, fractionDigits: 1),
      if (entry.durationMs != null && entry.durationMs! > 0)
        formatDuration(Duration(milliseconds: entry.durationMs!)),
      if (entry.videoWidth != null && entry.videoHeight != null)
        '${entry.videoWidth}×${entry.videoHeight}',
      if (entry.modifiedAt != null)
        formatRelativeTime(entry.modifiedAt!),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            children: [
              Icon(
                inLibrary
                    ? Icons.play_circle_outline_rounded
                    : Icons.movie_outlined,
                size: 18,
                color: inLibrary ? AppTheme.muted : AppTheme.dim,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
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
              if (inLibrary) ...[
                const TagChip(label: '已在库', color: AppTheme.dim),
                const SizedBox(width: 6),
                TvIconLabel(
                  label: '播放',
                  child: IconButton(
                    tooltip: '播放',
                    onPressed: () => _play(context, ref),
                    iconSize: 17,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                ),
              ] else
                FilledButton.tonal(
                  onPressed: discovery.running || scanning
                      ? null
                      : () => ref
                          .read(discoveryControllerProvider.notifier)
                          .discoverFile(entry, crumb),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  child: const Text(
                    '加入媒体库',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 已在库的文件可以直接播。**必须现查库拿 `MediaItem`**：起播入口
  /// `playItem` 要的是媒体项（它带着 fid、路径、解析结果），而这一行手上
  /// 只有网盘条目。一次 SQLite 点查，比在列表里预先加载整库便宜得多。
  Future<void> _play(BuildContext context, WidgetRef ref) async {
    final id = MediaItem.idFor(browseProvider, entry.id);
    final item = await ref.read(mediaRepositoryProvider).itemById(id);
    if (!context.mounted) return;
    if (item == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('这条记录已经不在媒体库里了，重新发现一次即可'),
        ),
      );
      return;
    }
    await playItem(context, ref, item);
  }
}
