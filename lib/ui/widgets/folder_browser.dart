import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/format.dart';
import '../../domain/entities/drive_entry.dart';
// ⚠️ 必须 `hide formatBytes`：`media_item.dart` 里也有一个同名函数
// （二进制单位、只收 `int`），两个都导入会让每一处调用变成 ambiguous。
// 这里要的是 core 里那个（收 `int?`、可指定小数位）。
import '../../domain/entities/media_item.dart' hide formatBytes;
import '../../domain/services/drive_cleanup.dart';
import '../../domain/services/folder_sort.dart';
import '../../domain/services/media_discovery.dart';
import '../../domain/services/media_entry_classifier.dart';
import '../providers/app_providers.dart';
import '../providers/auth_providers.dart';
import '../providers/drive_browse_providers.dart';
import '../providers/drive_cleanup_providers.dart';
import '../providers/drive_move_providers.dart';
import '../providers/folder_providers.dart';
import '../providers/scan_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'copy_button.dart';
import 'download_action.dart';
import 'drive_delete_dialog.dart';
import 'drive_move_dialog.dart';
import 'modified_time_column.dart';
import 'play_action.dart';
import 'tv_affordance.dart';

/// 这一层最终**显示在屏幕上**的条目，顺序就是屏幕上的顺序。
///
/// 抽成顶层函数是因为有**两个**地方要回答「屏幕上有哪些条目」：
///   1. `_EntryList` —— 画出来；
///   2. `_SelectionBar` —— 「全选」要勾的正是这些。
///
/// 两处各写一遍的话，用户筛出三个文件、点「全选」、按下删除时，勾上的可能
/// 是同一目录里另外两百个 —— 而且**界面上一眼看不出来**（数字对得上，
/// 因为他看的就是「已选 203 项」这句话）。所以这一条判据只能有一份。
///
/// 分组顺序（目录 → 视频 → 其他文件）由 [sortListing] 保证，是**结构**，
/// 不随用户选的排序方式改变；这里只是把它摊平成一维。
List<DriveEntry> displayEntries(
  DriveListing listing,
  String query,
  FolderSortMode mode,
) {
  final q = query.trim().toLowerCase();
  bool hit(DriveEntry e) => q.isEmpty || e.name.toLowerCase().contains(q);

  final sorted = sortListing(
    listing.folders.where(hit).toList(),
    listing.videos.where(hit).toList(),
    listing.others.where(hit).toList(),
    mode,
  );
  return [...sorted.folders, ...sorted.videos, ...sorted.others];
}

/// 一行的复选框。
///
/// 刻意**不用** `Checkbox`：那个控件的点击目标是它自己（约 40×40），而这里
/// 整行都是开关 —— 在电视遥控器上，把焦点停在一个小方块上比停在整行上难
/// 得多。所以它只是**状态显示**，真正的落点由整行承担。
class _RowCheck extends StatelessWidget {
  const _RowCheck({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Icon(
      selected ? Icons.check_box_rounded : Icons.check_box_outline_blank,
      size: 18,
      color: selected ? AppTheme.accent : AppTheme.dim,
    );
  }
}

/// 多选模式下选中行的底色。
Color _rowColor(bool selected) => selected
    ? Color.alphaBlend(AppTheme.accent.withValues(alpha: 0.14), AppTheme.panel)
    : AppTheme.panel;

/// 网盘目录视图 —— 侧栏上「文件夹」那一页的主体。
///
/// 它曾经是媒体库页里的一个视图（靠页头那个分段控件切过去），现在是一级
/// 入口。两者数据源、搜索语义、排序口径没有一处共用，所以合成一页时媒体库
/// 页头得为它挂上一堆自己用不着的分支 —— 理由见 `LibraryView` 的枚举文档。
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
/// ## 直接播：**不要求先入库**
///
/// 视频文件行**整行可点，点了就播**（任何一行都有播放按钮）。没入库的那些
/// 走 `playDriveEntry`：现造一条内存里的媒体项，**一行都不落库**。这样
/// 「新上传的、上次扫漏的、分享过来还没入库的」不必先经过「加入媒体库」
/// 那个会真的改库的动作 —— 用户点播放的意图是看片，不是整理媒体库。
///
/// 「已在库」标签与「加入媒体库」按钮都还在，所以「盘上的」与「库里的」
/// 依然一眼可分；变的只是不必先入库才能看。代价（续播点、连播、同目录字幕、
/// 播放偏好、片头标记这些库内能力会降级）见 `playDriveEntry` 的文档。
///
/// ## 全部文件都列出来，**每一种都能下载**
///
/// 这一层原先只列视频，其余文件（字幕 / 图片 / 文档 / 压缩包）只在面包屑上
/// 给一个数字。现在三组都列：**目录 → 视频 → 其他文件**，其他文件永远垫底
/// （它们是附属物，混进视频里会把「这一层有几部片子」冲散）。
///
/// 三组的下载入口各就各位：
///   - **目录行** → 「下载全部」（含子目录，见 [downloadDriveFolder]）；
///   - **视频行** → 整行可点=播，右侧另有独立的「下载」图标；
///   - **其他文件行** → 整行不可点，右侧一个「下载」。
///
/// ⚠️ 视频行那个「下载」是**独立按钮**而不是「整行的第二种含义」：
/// 一部 4K 原盘几十 GB，如果整行既能播又能存，用户点下去根本不知道自己
/// 触发了哪一个。整行只有一个含义（播），存盘必须点到那个 ⤓ 上。
///
/// 判据仍然只有 `classifyEntry` 一处，所以「列表里说它是视频」
/// 与「扫描会把它写进库」永远是同一件事。
///
/// ## 搜索
///
/// 搜索框在目录视图里筛的是**当前这一层**（客户端过滤，瞬时，不发请求）。
/// 跨目录找东西由海报墙的搜索负责：网盘的搜索接口只按关键词返回一批结果，
/// 没法按路径枚举（`file/search` 换关键词返回同一批，见 `HOWTO.md`），
/// 拿它假装「全盘路径搜索」只会给出看起来对、其实不全的结果。
///
/// ## 多选删除（清理网盘空间）
///
/// 工具条上的「多选」进入选择模式（长按任意一行也行），勾上要清理的条目后
/// 一次性删掉。勾选状态在 [folderSelectionProvider]。
///
/// 三条与「删」这件事绑死的规矩：
///
///   1. **换目录就清空勾选**（见那个 provider 的类文档）—— 勾选表达的是
///      「我屏幕上这几个」，翻层之后还留着上一个目录的选择，用户会删掉
///      他看不见的东西；
///   2. **「全选」只勾当前可见的**（已过搜索词，见 [displayEntries]）；
///   3. 删除前必须过一次 [DriveDeleteDialog] —— 这条路径不可逆。
///
/// 删除的后果不止网盘：成功删掉的条目对应的**本地索引行**也会一起清掉
/// （见 `DriveCleanupController`），否则海报墙上会留下一批点开就报错的死卡片。
///
/// ## 排序
///
/// 默认按**修改时间倒序**（刚传的片子在第一行），可以在面包屑那一行的
/// 排序按钮上切成「名称」自然序。它排的是**这一层的条目**，与页头那个
/// `WorkSort`（排库里的作品）不是同一件事，所以控件也分开摆。
///
/// 排序在**渲染时**做（`sortListing`），不在 `driveListingProvider` 里 ——
/// 放进 provider 的话，切一次排序就要把整个目录重新列一遍网盘（见那里的注释）。
/// 目录整组永远排在视频前面：换排序方式改不了这个结构，只改组内顺序。
class FolderBrowser extends ConsumerWidget {
  const FolderBrowser({super.key, required this.onClearSearch});

  /// 清空搜索框。
  ///
  /// 由页面传进来，因为输入框的真源在页面的 `TextEditingController` 里
  /// （[folderQueryProvider] 只是它的影子）。从这里直接改 provider 会让
  /// 输入框里留着旧词而列表已经不过滤了 —— 那种不一致比不清空更难懂。
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final loggedIn = auth?.isAuthorized ?? false;
    final crumb = ref.watch(currentCrumbProvider);
    final listing = ref.watch(driveListingProvider(crumb));
    // 搜索词来自**文件夹自己的** provider，与媒体库那个搜索框无关 ——
    // 理由见 [folderQueryProvider]（共用一个词会出现「框是空的、列表被
    // 上一个页面的词过滤着」）。
    final query = ref.watch(folderQueryProvider).trim();
    final selecting = ref.watch(folderSelectionProvider).active;

    // ⚠️ 换目录 = 清空勾选。
    //
    // 多选时**界面上没有换目录的入口**（面包屑与「上一级」都收起来了，
    // 整行点击也变成了勾选），所以正常情况下走不到这里。这条监听是**兜底**：
    // 列表空了之后那个「回到根目录」的按钮还在（`_emptyState`），
    // 以及将来任何新加的跳转入口 —— 而漏掉它的后果很重：工具条上「已选 N 项」
    // 是用户唯一能核对「我要删什么」的地方，勾选又只存 fid，一旦跨目录残留，
    // 用户看到的是一个「已选 5 项」而列表里一个勾都没有的界面，这时按下删除，
    // 删掉的是他**看不见**的 5 个文件。
    //
    // 清空之后留在多选模式里：删完一批往往还要接着挑下一批，每进一层都要
    // 重新点一次「多选」是多余的摩擦。
    ref.listen<DriveCrumb>(currentCrumbProvider, (prev, next) {
      if (prev == null || prev.id == next.id) return;
      ref.read(folderSelectionProvider.notifier).clearIds();
    });

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
        // 多选时整条工具条换成选择工具条（面包屑与「发现」那一排都收起来）：
        // 那两样此刻都是干扰 —— 用户要回答的是「删哪几个」，而面包屑会让人
        // 以为点它还能跳层（跳了就清空勾选，等于白勾）。
        if (selecting)
          _SelectionBar(crumb: crumb)
        else ...[
          _Breadcrumb(
            stack: ref.watch(driveBrowseProvider),
            onClearSearch: onClearSearch,
          ),
          _DiscoveryBar(crumb: crumb),
        ],
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
              selecting: selecting,
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
                : listing.summary,
            style: const TextStyle(fontSize: 11, color: AppTheme.dim),
          ),
          const SizedBox(width: 8),
          // 排序方式。**摆在列表自己这一行**（面包屑条），而不是页头 ——
          // 页头那个排序按钮排的是库里的作品（`WorkSort`），两个控件挨在一起
          // 会被读成同一个东西。
          const _SortMenu(),
          const SizedBox(width: 4),
          CopyTextButton(
            text: stack.last.path,
            label: '复制当前目录路径',
            tvLabel: '复制路径',
            icon: Icons.folder_copy_outlined,
          ),
          const SizedBox(width: 4),
          // 「多选」是一个**模式开关**，不是一次动作：点它进入选择模式，
          // 之后点行才是勾选。常驻按钮而不是只靠长按 —— 电视遥控器上长按
          // 不可靠，而且一个只存在于手势里的入口没人会发现。
          TvIconLabel(
            label: '多选',
            child: IconButton(
              tooltip: '多选（批量删除）',
              onPressed: () => ref.read(folderSelectionProvider.notifier).enter(),
              iconSize: 16,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              icon: const Icon(Icons.checklist_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

/// 多选模式下替代面包屑那一行的工具条。
///
/// ## 为什么整条换掉，而不是在面包屑上加几个按钮
///
/// 多选时**界面上刻意不给换目录的入口**：勾选只存 fid，而「已选 N 项」是
/// 用户唯一能核对「我要删什么」的地方 —— 跨目录残留的勾选会让他在看不见
/// 那些条目的情况下把它们删掉（见 [FolderSelection] 的类文档）。
/// 收掉面包屑是让这条约束**看得见**，而不是让用户攒出一个我们随后悄悄
/// 丢掉的选择。
///
/// 位置上换成「已选几项 / 全选 / 删除」，用户的目光不用重新找。
///
/// ## 「全选」勾的是**屏幕上这些**
///
/// 与媒体库那边同一条口径（见 `_SelectionHeader` 的注释）。走
/// [displayEntries]，与列表**共用同一份定义**，所以搜索词、排序都算在内。
/// 用「这一层的全部条目」的话，用户筛出三个文件、点全选、按删除，删掉的是
/// 同目录另外两百个 —— 而界面上完全看不出这件事（数字对得上）。
class _SelectionBar extends ConsumerWidget {
  const _SelectionBar({required this.crumb});

  final DriveCrumb crumb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(folderSelectionProvider);
    final listing = ref.watch(driveListingProvider(crumb)).valueOrNull;
    final query = ref.watch(folderQueryProvider);
    final mode = ref.watch(folderSortModeProvider);
    final cleanup = ref.watch(driveCleanupControllerProvider);
    final move = ref.watch(driveMoveControllerProvider);

    final visible = listing == null
        ? const <DriveEntry>[]
        : displayEntries(listing, query, mode);
    final allSelected =
        visible.isNotEmpty && visible.every((e) => selection.contains(e.id));

    // 两个批量动作**共用一个 busy**，同时只允许跑一个。
    //
    // 不共用会出现一个很难看的竞态：删除正在跑（那些 fid 正在网盘上消失）
    // 时用户按下移动，两个循环各按自己那份 fid 列表发请求，而两边结束时
    // 都会重列同一个目录 —— 最后界面显示的是哪一份全看谁后到。
    // 两个控制器各自有 `state.running` 守卫，所以这里只需把按钮一起置灰。
    final deleting = cleanup.running;
    final moving = move.running;
    final busy = deleting || moving;

    return Container(
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          // 选中模式下给边框一点主色：这一条与平时那条面包屑位置相同、
          // 颜色相同的话，用户会以为界面没变（他只是点了「多选」）。
          color: busy ? AppTheme.line : AppTheme.accent.withValues(alpha: 0.5),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          // 批量动作在跑的时候不许退出 / 改选：那会让「正在删 12/37」这句话
          // 指向一批已经变了的条目。
          IconButton(
            tooltip: '退出多选',
            iconSize: 17,
            onPressed:
                busy ? null : () => ref.read(folderSelectionProvider.notifier).exit(),
            icon: const Icon(Icons.close_rounded),
          ),
          const SizedBox(width: 2),
          Text(
            selection.isEmpty ? '勾选要移动或删除的条目' : '已选 ${selection.count} 项',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.text,
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: busy || visible.isEmpty || allSelected
                ? null
                : () => ref
                    .read(folderSelectionProvider.notifier)
                    .addAll(visible.map((e) => e.id)),
            child: Text(
              // 带上数字：用户据此确认「我勾的确实是这一层剩下的全部」。
              allSelected ? '已全选' : '全选 ${visible.length} 项',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: busy || selection.isEmpty
                ? null
                : () => ref.read(folderSelectionProvider.notifier).clearIds(),
            child: const Text('取消选择', style: TextStyle(fontSize: 12.5)),
          ),
          const Spacer(),
          if (busy) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 8),
            Text(
              // 必须说清**在跑哪一件事**。只写「处理中…」的话，用户看到
              // 数字在跳却不知道是移动还是删除 —— 而这两件事按错了的
              // 后果差得很远。
              moving
                  ? (move.hasProgress
                      ? '正在移动 ${move.done}/${move.total}…'
                      : '正在移动…')
                  : (cleanup.hasProgress
                      ? '正在删除 ${cleanup.done}/${cleanup.total}…'
                      : '正在删除…'),
              style: const TextStyle(fontSize: 12, color: AppTheme.accent),
            ),
          ] else ...[
            // 移动在左、删除在右。危险的那个放最右是这一条的既有约定
            // （用户伸手够到的最后一个按钮不该是不可逆的那个）。
            FilledButton.icon(
              onPressed: selection.isEmpty ? null : () => _move(context, ref),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.drive_file_move_outlined, size: 15),
              label: Text(
                // 与删除同一条理由：一个都没勾时不写「移动 0 项」——
                // 灰按钮上写着「移动 0 项」只会让人去猜「为什么是 0」。
                selection.isEmpty ? '移动' : '移动 ${selection.count} 项',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: selection.isEmpty ? null : () => _delete(context, ref),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.danger,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.delete_forever_rounded, size: 15),
              label: Text(
                // 一个都没勾时不写「删除 0 项」：那读起来像一个能按的动作，
                // 而它此刻是灰的 —— 灰按钮上写着「删除 0 项」只会让人
                // 去猜「为什么是 0」。
                selection.isEmpty ? '删除' : '删除 ${selection.count} 项',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 确认 → 删 → 提示。
  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final selection = ref.read(folderSelectionProvider);
    final listing = ref.read(driveListingProvider(crumb)).valueOrNull;
    if (selection.isEmpty || listing == null) return;

    // 勾选只存 fid，而删除要的是条目的**类型与体积**（目录要连带清索引子树、
    // 体积要报给用户），所以在这里用当前列表把 fid 还原成条目。
    //
    // 顺便把「已经被别处删掉、这次列不出来」的那些自然丢掉 —— 它们在网盘上
    // 本来就已经没有了。
    final byId = <String, DriveEntry>{
      for (final e in [
        ...listing.folders,
        ...listing.videos,
        ...listing.others,
      ])
        e.id: e,
    };
    final entries = [
      for (final id in selection.ids)
        if (byId[id] != null) byId[id]!,
    ];
    if (entries.isEmpty) return;

    final plan = DriveDeletePlan(entries: entries);
    final confirmed = await DriveDeleteDialog.show(context, plan);
    if (confirmed != true || !context.mounted) return;

    // await 之后不能再碰 `context`（可能已经被卸载），先取出来。
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref
        .read(driveCleanupControllerProvider.notifier)
        .delete(crumb: crumb, plan: plan);
    if (outcome == null) return;

    // ⚠️ 只有**真的删掉了东西**才退出多选。
    //
    // 成功的那批已经不在列表里了，留着「已选 N 项」是个指向不存在的东西的
    // 计数；但一批都没删掉时（限流 / 网络断了）要**留住勾选** —— 用户想
    // 重试的正是这一批，让他从几十行里重新挑一遍是白费功夫。
    if (outcome.deleted > 0) {
      ref.read(folderSelectionProvider.notifier).exit();
    }

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(outcome.message),
      ),
    );
  }

  /// 选目标 → 移动 → 提示。
  ///
  /// 与 [_delete] 的结构刻意对称（同一套「把 fid 还原成条目」的前置），
  /// 差别只在**收尾**，而且只有一处。
  Future<void> _move(BuildContext context, WidgetRef ref) async {
    final selection = ref.read(folderSelectionProvider);
    final listing = ref.read(driveListingProvider(crumb)).valueOrNull;
    if (selection.isEmpty || listing == null) return;

    // 与 [_delete] 同一段前置：勾选只存 fid，而移动需要条目本身 ——
    // 「目标是不是某个目录的子目录」只能靠条目名 + 当前目录路径算出来。
    final byId = <String, DriveEntry>{
      for (final e in [
        ...listing.folders,
        ...listing.videos,
        ...listing.others,
      ])
        e.id: e,
    };
    final entries = [
      for (final id in selection.ids)
        if (byId[id] != null) byId[id]!,
    ];
    if (entries.isEmpty) return;

    final plan = await DriveMoveDialog.show(
      context,
      entries: entries,
      // ⚠️ 传**当前这一层**的路径，不是条目自己的 `path`：列目录拿到的
      // 条目里那个字段是 `null`（只有扫描器会填），拿它去判断「目标是不是
      // 自己的子目录」会**静默地永远判 false** —— 而那正是唯一可能把目录
      // 结构搞坏的操作。
      sourceDirPath: crumb.path,
    );
    if (plan == null || !context.mounted) return;

    // await 之后不能再碰 `context`（可能已经被卸载），先取出来。
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await ref
        .read(driveMoveControllerProvider.notifier)
        .move(sourceCrumb: crumb, plan: plan);
    if (outcome == null) return;

    // ⚠️ 移动**不退出多选**，只清空勾选 —— 这是与 [_delete] 唯一的不同。
    //
    // 删除是「把不要的清掉」，清完这一轮就结束了；移动是「把散落的归到
    // 一处」，用户接下来往往要进另一个目录再挑一批，每批都退出多选意味着
    // 他每批都得重新点一次「多选」。
    //
    // 勾选本身仍然必须清（判据与删除那边一字不差）：成功移走的那些已经
    // 不在这一层了，留着「已选 5 项」是一个指向不存在的东西的计数，而
    // 那个数字是用户核对「我要动什么」的唯一依据（见 `FolderSelection`）。
    // 一批都没动成时（限流 / 断网）则要**留住勾选** —— 他要重试的正是
    // 这一批，让他从几十行里重新挑一遍是白费功夫。
    if (outcome.moved > 0) {
      ref.read(folderSelectionProvider.notifier).clearIds();
    }

    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(outcome.message),
      ),
    );
  }
}

/// 目录视图的排序方式菜单。
///
/// ## 与页头那个排序按钮的关系：**两回事，别合并**
///
///   - 页头的 `_SortMenu`（`library_page.dart`）排的是**库里的作品**
///     （最近修改 / 评分 / 年份…），只在海报墙与作品列表里出现；
///   - 这一个排的是**当前这一层网盘目录里的条目**（子目录 + 视频文件）。
///
/// 合成一个控件、共用一份状态的话，用户在海报墙把排序切成「评分」再进目录
/// 视图，看到的是按评分排的目录 —— 而目录条目根本没有评分。
///
/// 选择结果**落库**（`SettingKeys.folderSortMode`），设置页里有一项同样的
/// 设置读写它 —— 见 `folderSortModeProvider` 的注释。
class _SortMenu extends ConsumerWidget {
  const _SortMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(folderSortModeProvider);
    return PopupMenuButton<FolderSortMode>(
      tooltip: '排序方式',
      initialValue: mode,
      position: PopupMenuPosition.under,
      onSelected: (v) => unawaited(
        ref.read(settingsProvider.notifier).set(folderSortMode: v),
      ),
      itemBuilder: (context) => [
        for (final option in FolderSortMode.values)
          PopupMenuItem(
            value: option,
            height: 34,
            child: Row(
              children: [
                Icon(
                  option == mode
                      ? Icons.check_rounded
                      : Icons.check_box_outline_blank,
                  size: 14,
                  color: option == mode ? AppTheme.accent : Colors.transparent,
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
      // TV 上 `PopupMenuButton` 靠遥控器也能进（页头那个排序按钮就是同一套），
      // 所以这里只把「当前是什么排序」写成看得见的字 —— 一个光秃秃的
      // ⇅ 图标在电视上猜不出它排的是哪一维、现在排的是什么。
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            const Icon(Icons.swap_vert_rounded, size: 15, color: AppTheme.muted),
            const SizedBox(width: 5),
            Text(
              mode.label,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ],
        ),
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

/// 当前层的子目录 + 视频 + 其他文件（可选按关键词过滤，可选按用户选的维度排序）。
class _EntryList extends ConsumerWidget {
  const _EntryList({
    required this.listing,
    required this.query,
    required this.selecting,
    required this.onClearSearch,
  });

  final DriveListing listing;
  final String query;

  /// 是否处于多选模式。为真时每一行整行都是**勾选**，行上的动作按钮收起。
  final bool selecting;

  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filtering = query.isNotEmpty;

    // 筛选 + 排序**放在这里**（渲染时），不在 `driveListingProvider` 里：
    // 那边是网盘请求，watch 设置会让「切一次排序 = 重列一遍整个目录」。
    //
    // 走 [displayEntries] 而不是自己筛一遍：多选工具条的「全选」读的是
    // 同一个函数，两处必须是同一份定义（理由见那个函数的注释）。
    final entries = displayEntries(
      listing,
      query,
      ref.watch(folderSortModeProvider),
    );

    if (entries.isEmpty) return _emptyState(ref, filtering);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];

        if (entry.isDirectory) {
          return _FolderRow(
            crumb: listing.crumb,
            dir: entry,
            selecting: selecting,
            // 进目录前先清搜索：否则跳过去之后列表仍被同一个词过滤着，
            // 看到的是空目录 —— 用户的第一反应是「点了没反应」。
            onTap: () {
              if (filtering) onClearSearch();
              ref
                  .read(driveBrowseProvider.notifier)
                  .open(listing.crumb.child(entry));
            },
          );
        }

        // ⚠️ 「这是视频还是其他文件」的判据仍然是 `classifyEntry` 一处 ——
        // 与 `driveListingProvider` 分组时用的是同一个函数。列表被摊平成一维
        // 之后不能靠「原来在第几组」来分辨，否则将来加一类条目时，分组那边
        // 改了、这里没改，表现是「某个文件用错了行」（可播的显示成不可播）。
        if (classifyEntry(entry) == EntryRole.video) {
          return _DriveFileRow(
            crumb: listing.crumb,
            entry: entry,
            selecting: selecting,
          );
        }
        return _OtherFileRow(
          crumb: listing.crumb,
          entry: entry,
          selecting: selecting,
        );
      },
    );
  }

  Widget _emptyState(WidgetRef ref, bool filtering) {
    if (filtering) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: '这一层没有匹配的条目',
        body: '搜「$query」只筛**当前目录**的条目。'
            '要找整个媒体库里的片子，去海报墙搜。',
        actionLabel: '清空搜索',
        onAction: onClearSearch,
      );
    }

    // 「这一层没有文件」和「这个目录是空的」是两回事：前者很常见
    // （片子都在子目录里），后者的出路完全不同。
    //
    // ⚠️ 判据是「三组全空」而不是「视频为空」—— 现在字幕 / 压缩包也会列
    // 出来，一个只有 `.srt` 的目录说「这一层没有视频，视频都在子目录里」
    // 会与它上面明明列着一行字幕自相矛盾。
    final hasEntries = listing.folders.isNotEmpty ||
        listing.videos.isNotEmpty ||
        listing.others.isNotEmpty;
    if (hasEntries) {
      return const EmptyState(
        icon: Icons.folder_open_rounded,
        title: '这一层没有文件',
        body: '文件都在它的子目录里。进一个子目录，或者用上面的'
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
///
/// 多选模式下这一行换一套读法：**整行 = 勾选**，两个动作按钮收起。
/// 收起而不是留着，是因为它们此刻有更坏的后果 —— 「下载全部」在勾选模式里
/// 看起来像「确认选择」，而它实际会开始下整个目录。
class _FolderRow extends ConsumerWidget {
  const _FolderRow({
    required this.crumb,
    required this.dir,
    required this.selecting,
    required this.onTap,
  });

  /// 父目录格（用来算这一格的路径与 ID）。
  final DriveCrumb crumb;
  final DriveEntry dir;

  /// 多选模式。为真时 [onTap] 不被调用，整行改成勾选。
  final bool selecting;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final discovery = ref.watch(discoveryControllerProvider);
    final scanning = ref.watch(scanControllerProvider).running;
    final child = crumb.child(dir);
    final indexed = ref.watch(folderTreeProvider).valueOrNull
            ?.indexedCountAt(child.path) ??
        0;

    // 多选模式下只看这一条自己的勾选状态。watch 整个 selection 会让每一条
    // 可见的行在每次勾选时都重建一次 —— 而 `ListView.builder` 只构建可见的
    // 那十几行，这个代价可以忽略，换来的是不必把 `selected` 一层层传下来。
    final selected =
        selecting && ref.watch(folderSelectionProvider).contains(dir.id);

    final parts = <String>[
      if (indexed > 0) '已入库 $indexed 个',
      if (dir.sizeBytes != null && dir.sizeBytes! > 0)
        formatBytes(dir.sizeBytes, fractionDigits: 1),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: _rowColor(selected),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: selecting
              ? () => ref.read(folderSelectionProvider.notifier).toggle(dir.id)
              : onTap,
          // 长按是桌面上的快捷入口：按下去就进多选并勾上这一条。
          // 「连按的那一下一起生效」的完整理由见 `FolderSelectionController.enter`。
          onLongPress: selecting
              ? null
              : () => ref.read(folderSelectionProvider.notifier).enter(dir.id),
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                if (selecting)
                  _RowCheck(selected: selected)
                else
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
                // 修改时间**单列**（不是拼在元信息那一行里）。理由见
                // [ModifiedTimeColumn]：拼接写法里它随前面几段的宽度左右浮动，
                // 同一层十几行根本对不齐，扫不出「哪几个是新传的」。
                ModifiedTimeColumn(modifiedAt: dir.modifiedAt),
                if (!selecting) ...[
                  const SizedBox(width: 4),
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
                  // 「把整个目录（含子目录）下下来」。与上面那个「只这一层」的
                  // 发现按钮长得像，但一个是入库、一个是存盘 —— 所以两个都用
                  // TV 标签写明，否则在电视上就是两个猜不出区别的图标。
                  TvIconLabel(
                    label: '下载全部',
                    child: Tooltip(
                      message: '下载「${dir.name}」里的全部文件（含子目录）',
                      child: IconButton(
                        onPressed: () => downloadDriveFolder(
                          context,
                          ref,
                          crumb: crumb,
                          dir: dir,
                        ),
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        icon: const Icon(Icons.download_rounded),
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppTheme.dim,
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

/// 一行网盘上的视频文件。**整行可点 = 直接播**。
///
/// ## 与作品详情页的 `MediaItemRow` 刻意不共用
///
/// 那一行描述的是**已入库的媒体项**（有解析出的片名、有分辨率档位），这一行
/// 描述的是**网盘上的一个文件**（可能还没入库，只有文件名）。混用会让人分不清
/// 「这是库里的还是盘上的」。
///
/// ## 播放入口对**入库与否**一视同仁
///
/// 以前只有「已在库」的行才有播放按钮，没入库的行只能先点「加入媒体库」——
/// 而用户点播放的意图是**看片**，不是整理媒体库；那个中间步骤还会真的改库。
/// 现在整行可点、并且**任何视频行都有播放按钮**：
///
///   - **已在库** → 走库里那一条（它带着刮削过的片名、归一后的分组，以及
///     续播点 / 连播 / 同目录字幕 / 播放偏好 / 片头标记这些库内能力）；
///   - **没入库** → 现造一条内存里的，**一行都不落库**（见 [playDriveEntry]）。
///
/// 「已在库」标签与「加入媒体库」按钮都还在，所以「盘上的」和「库里的」
/// 依然一眼可分 —— 变的只是**不必先入库才能看**。
class _DriveFileRow extends ConsumerWidget {
  const _DriveFileRow({
    required this.crumb,
    required this.entry,
    required this.selecting,
  });

  final DriveCrumb crumb;
  final DriveEntry entry;

  /// 多选模式。为真时整行 = 勾选，右侧三个动作按钮收起。
  final bool selecting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final indexedIds = ref.watch(indexedFileIdsProvider).valueOrNull;
    final discovery = ref.watch(discoveryControllerProvider);
    final scanning = ref.watch(scanControllerProvider).running;
    final inLibrary =
        indexedIds?.contains(MediaItem.idFor(browseProvider, entry.id)) ?? false;
    final selected =
        selecting && ref.watch(folderSelectionProvider).contains(entry.id);

    final parts = <String>[
      if (entry.sizeBytes != null && entry.sizeBytes! > 0)
        formatBytes(entry.sizeBytes, fractionDigits: 1),
      if (entry.durationMs != null && entry.durationMs! > 0)
        formatDuration(Duration(milliseconds: entry.durationMs!)),
      if (entry.videoWidth != null && entry.videoHeight != null)
        '${entry.videoWidth}×${entry.videoHeight}',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: _rowColor(selected),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          // 整行可点 = 播。与目录行（整行可点 = 进目录）同一套手势：
          // 一行里只有「整行」和「右侧按钮」两种落点，不用先想「这行点不点得动」。
          //
          // 多选模式下整行改成勾选 —— 这是**同一个原则的延续**：一行只有一个
          // 主要含义。此刻用户在做的是「挑要删的」，让他还要提防误触播放
          // 只会让人不敢点。
          onTap: selecting
              ? () => ref.read(folderSelectionProvider.notifier).toggle(entry.id)
              : () => _play(context, ref, inLibrary: inLibrary),
          onLongPress: selecting
              ? null
              : () => ref.read(folderSelectionProvider.notifier).enter(entry.id),
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                // 图标统一成「可播」语义。**不再用它区分入库与否** —— 这一行
                // 现在永远点得动，拿图标表示状态会暗示「没图标的那个播不了」；
                // 状态交给下面的「已在库」标签。
                if (selecting)
                  _RowCheck(selected: selected)
                else
                  const Icon(
                    Icons.play_circle_outline_rounded,
                    size: 18,
                    color: AppTheme.muted,
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
                // 与目录行同一个单列，理由见 [ModifiedTimeColumn]。
                //
                // 多选时**照样显示**（与右侧那三个按钮不同）：用户在挑要删的
                // 东西时，「哪个是上礼拜传错的」正是他的判据之一。
                ModifiedTimeColumn(modifiedAt: entry.modifiedAt),
                const SizedBox(width: 8),
                if (inLibrary) ...[
                  const TagChip(label: '已在库', color: AppTheme.dim),
                  const SizedBox(width: 6),
                ],
                if (!selecting) ...[
                  TvIconLabel(
                    label: '播放',
                    child: IconButton(
                      tooltip: inLibrary ? '播放' : '直接播放（不加入媒体库）',
                      onPressed: () => _play(context, ref, inLibrary: inLibrary),
                      iconSize: 17,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
                  ),
                  // 「下载」与「播放」是**两个不同的按钮**，不是同一行的两种读法：
                  // 整行可点 = 播（用户的默认意图是看片），这个图标 = 存盘。
                  //
                  // 早先这一行刻意**不给**下载，理由是「一部 4K 原盘几十 GB，
                  // 点下去是看片还是等半小时存盘分不清」。那个歧义是真的，
                  // 但解法不是把功能去掉 —— 而是把它做成一个**独立的、带图标的
                  // 按钮**：整行只有一种含义（播），存盘必须点到那个 ⤓ 上。
                  const SizedBox(width: 6),
                  TvIconLabel(
                    label: '下载',
                    child: IconButton(
                      tooltip: '下载到本地',
                      onPressed: () => downloadDriveEntry(
                        context,
                        ref,
                        entry: entry,
                        dirPath: crumb.path,
                      ),
                      iconSize: 17,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      icon: const Icon(Icons.download_rounded),
                    ),
                  ),
                  // 「加入媒体库」只在没入库时出现：它是**显式**的入库动作，
                  // 与上面那个「直接播」是两件事。留着它，用户想让它进库
                  // （要续播点、要上海报墙）时仍有一步到位的入口。
                  if (!inLibrary) ...[
                    const SizedBox(width: 6),
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
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 播这一行。
  ///
  /// **已在库的走库里那一条**（保持原有行为），**没入库的现造一条内存里的**
  /// —— 两者的分工与理由见类文档。
  Future<void> _play(
    BuildContext context,
    WidgetRef ref, {
    required bool inLibrary,
  }) async {
    if (!inLibrary) {
      await playDriveEntry(
        context,
        ref,
        provider: browseProvider,
        entry: entry,
        dirPath: crumb.path,
      );
      return;
    }

    // 已在库：**必须现查库拿 `MediaItem`**。起播入口要的是媒体项（它带着
    // fid、路径、解析结果），而这一行手上只有网盘条目。一次 SQLite 点查，
    // 比在列表里预先加载整库便宜得多。
    final id = MediaItem.idFor(browseProvider, entry.id);
    final item = await ref.read(mediaRepositoryProvider).itemById(id);
    if (!context.mounted) return;

    // 索引里说「在库」、库里却查不到：这一行的标记来自另一个 provider 的
    // 快照，而库可能正在被重扫（或那条记录刚被删）。
    //
    // 以前这里弹一句「这条记录已经不在媒体库里了，重新发现一次即可」——
    // 那是一个**死胡同**：用户的意图是看片，而网盘上那个文件明明还在。
    // 现在直接按「没入库」播，反而正是他想要的。
    if (item == null) {
      await playDriveEntry(
        context,
        ref,
        provider: browseProvider,
        entry: entry,
        dirPath: crumb.path,
      );
      return;
    }
    await playItem(context, ref, item);
  }
}

/// 一行**非媒体文件**（字幕 / 图片 / 文档 / 压缩包 / 蓝光镜像…）。
///
/// ## 为什么现在要列出来
///
/// 以前这一层只列视频，其余文件只在面包屑上给一个数字。当时的理由是
/// 「列出一堆点了加不进库的 `cover.jpg` 只会让人以为功能坏了」——
/// 这个理由在**只有「加入媒体库」一个动作**的年代成立。
///
/// 现在它有动作了：**下载**。而目录视图的定位就是「网盘上有什么」——
/// 用户把一个 `.zip` / 一份 `.pdf` / 一集字幕传上来，就是想在同一个地方
/// 看见它、拿回去。只给数字等于告诉他「有 3 个东西，但不告诉你是什么、
/// 也不让你动」。
///
/// ## 它**不**可点（多选模式除外）
///
/// 整行可点在这里没有合理语义：播不了（分类判据与扫描同源，非视频永远
/// 不入库），加进媒体库也没意义（扫描器本来就会跳过它们）。所以整行是
/// 静态的，动作只有右侧那一个明确的「下载」按钮 —— 与其给一个点了弹
/// 「这不是可播放的视频文件」的整行，不如不给。
///
/// ⚠️ 唯一例外是**多选模式**：那时整行 = 勾选，而勾选恰恰需要整行可点
/// （字幕 / 压缩包也占空间，是清理的常见目标）。这个例外是安全的：勾选
/// 不产生任何副作用，不会出现「点错了却播了一个打不开的文件」。
class _OtherFileRow extends ConsumerWidget {
  const _OtherFileRow({
    required this.crumb,
    required this.entry,
    required this.selecting,
  });

  final DriveCrumb crumb;
  final DriveEntry entry;
  final bool selecting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = classifyEntry(entry);
    final selected =
        selecting && ref.watch(folderSelectionProvider).contains(entry.id);

    final parts = <String>[
      if (entry.sizeBytes != null && entry.sizeBytes! > 0)
        formatBytes(entry.sizeBytes, fractionDigits: 1),
      _roleLabel(role),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: _rowColor(selected),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: selecting
              ? () => ref.read(folderSelectionProvider.notifier).toggle(entry.id)
              : null,
          onLongPress: selecting
              ? null
              : () => ref.read(folderSelectionProvider.notifier).enter(entry.id),
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            child: Row(
              children: [
                if (selecting)
                  _RowCheck(selected: selected)
                else
                  Icon(_roleIcon(role), size: 18, color: AppTheme.dim),
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
                  ),
                ),
                // 与目录行 / 视频行同一个单列，理由见 [ModifiedTimeColumn]。
                ModifiedTimeColumn(modifiedAt: entry.modifiedAt),
                if (!selecting) ...[
                  const SizedBox(width: 8),
                  TvIconLabel(
                    label: '下载',
                    child: IconButton(
                      tooltip: '下载到本地',
                      onPressed: () => downloadDriveEntry(
                        context,
                        ref,
                        entry: entry,
                        dirPath: crumb.path,
                      ),
                      iconSize: 17,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      icon: const Icon(Icons.download_rounded),
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

  /// 类型标签。给的是**人话**而不是扩展名：`.srt` / `.ass` 对用户是
  /// 「字幕」，把扩展名印上去只是把判断推回给他。
  static String _roleLabel(EntryRole role) => switch (role) {
        EntryRole.subtitle => '字幕',
        EntryRole.image => '图片',
        EntryRole.discImage => '光盘镜像',
        EntryRole.other => '文件',
        EntryRole.video => '视频',
        EntryRole.directory => '目录',
      };

  static IconData _roleIcon(EntryRole role) => switch (role) {
        EntryRole.subtitle => Icons.subtitles_outlined,
        EntryRole.image => Icons.image_outlined,
        EntryRole.discImage => Icons.album_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}

// 「修改时间」那一列已抽成共用 widget（`modified_time_column.dart` 的
// [ModifiedTimeColumn]）—— 详情页的文件列表也要显示同一个字段，
// 两处各写一份的话，一处是 `3 天前`、另一处是 `2026-10-03 16:41`，
// 用户会以为是两个不同的东西。
