import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_providers.dart';
import '../providers/drive_browse_providers.dart';
import '../providers/folder_providers.dart';
import '../widgets/common_widgets.dart';
import '../widgets/folder_browser.dart';
import '../widgets/storage_meter.dart';
import '../widgets/tv_affordance.dart';

/// 文件夹（网盘目录）—— 侧栏上的一级入口。
///
/// ## 为什么它从「媒体库里的一个视图」升成一级入口
///
/// 两者**不是一个层级的功能**：
///
///   - 媒体库 = 「我库里有什么」，读**本地索引**，按**作品**组织，离线可用；
///   - 文件夹 = 「网盘上是怎么放的」，逐层**实时列网盘**，按**位置**组织，
///     必须先登录。
///
/// 数据源、搜索语义、排序口径、可用动作（发现 / 下载 / 未入库直接播）没有
/// 一处共用。原先合成一页靠一个分段控件连着，代价是媒体库页头要为另一个视图
/// 挂上一堆自己用不着的分支（原先那串 `showsWorks`），而用户在「媒体库」
/// 这个名字下面根本不会想到网盘目录在这里。
///
/// ## 状态各自独立
///
/// 搜索词是 [folderQueryProvider]，**不**与媒体库共用（理由见那个 provider：
/// 共用一个词会出现「输入框是空的、列表被上一个页面的词过滤着」）。
/// 侧栏走 `StatefulShellRoute`，所以切走再切回来，当前目录、排序方式、
/// 搜索词都还在。
class FolderPage extends ConsumerStatefulWidget {
  const FolderPage({super.key});

  @override
  ConsumerState<FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends ConsumerState<FolderPage> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  /// 与媒体库同一个 250ms。这一层可能上千条（一部剧一季几十个文件），
  /// 每敲一个字就重建一次整张列表会明显掉帧。
  static const Duration _debounceDelay = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    // 容量是**登录那一刻的快照**，不会自己更新，所以进这一页时拉一次。
    //
    // 放在 `addPostFrameCallback` 里而不是直接调：`refreshAccount()` 会在拿到
    // 响应后写 `authControllerProvider`，而在 `initState` 里同步触发一次
    // provider 变更，正好撞在这一帧的构建上。
    //
    // ⚠️ 侧栏是 `StatefulShellRoute`（页面常驻），所以这只在**本次运行第一次**
    // 进这一页时发生。之后靠页头那个「刷新」按钮 —— 它是用户唯一能主动
    // 「我刚传完东西，重新算一下」的出口。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(authControllerProvider.notifier).refreshAccount();
    });
  }

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
      ref.read(folderQueryProvider.notifier).set(value);
    });
  }

  /// 清空搜索框**与** [folderQueryProvider]。
  ///
  /// 两处都要动：输入框的真源是这里的 controller，而列表读的是 provider。
  /// 只改一边会得到「列表已经不过滤了，但搜索框里还有词」这种自相矛盾的
  /// 状态。面包屑跳层时由 `FolderBrowser` 回调进来（理由见那里的注释：
  /// 带着搜索词跳到别的目录，用户看到的是个几乎空白的目录，只会以为
  /// 点了没反应）。
  void _clearSearch() {
    _debounce?.cancel();
    _search.clear();
    ref.read(folderQueryProvider.notifier).clear();
  }

  /// 重新列这一层网盘，并把「已入库」叠加层一起重算。
  ///
  /// 三样都要作废：目录内容本身、本地索引叠出来的目录树（`folderTreeProvider`，
  /// 行上那个「N 个已入库」的递归计数）、以及由它派生的文件 id 集合
  /// （视频行上的「已在库」标签）。
  ///
  /// ⚠️ 目录内容**没有**跟着写库信号自动失效（那会让每落库一条就重列一次
  /// 网盘），所以这个按钮是用户唯一的手动出口 —— 少了它，「我刚上传的片子
  /// 怎么没出现」就只能靠切走再切回来。
  void _refresh() {
    ref.invalidate(folderTreeProvider);
    ref.invalidate(indexedFileIdsProvider);
    ref.invalidate(driveListingProvider);
    // 容量也要重算 —— 用户按这个按钮的动机里，「我刚传完/删完东西」占一大半，
    // 而容量恰恰是那件事唯一会变的数字。
    unawaited(ref.read(authControllerProvider.notifier).refreshAccount());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '文件夹',
          subtitle: _subtitle(ref),
          actions: [
            HeaderSearchBox(
              controller: _search,
              onChanged: _onSearchChanged,
              hint: '筛当前目录…',
            ),
            // 「刷新」是个纯图标按钮：桌面上悬停会出 tooltip，电视上没有
            // hover —— 所以 TV 上补一个看得见的「刷新」标签。
            // ⚠️ 不要在这里塞 `SizedBox` 当间隔：`PageHeader` 自己会给
            // （桌面按 8、TV 那支的 `Wrap` 自带 `spacing`），重复给会让
            // 折行位置随宽度飘。
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
        // 容量条（总量 / 已用 / 剩余 + 一条小进度条）。
        //
        // 未登录或拿不到容量时它自己返回空 —— 判据收在组件里，这里不重复。
        DriveStorageMeter(
          account: ref.watch(authControllerProvider).valueOrNull?.account,
        ),
        Expanded(child: FolderBrowser(onClearSearch: _clearSearch)),
      ],
    );
  }

  /// 副标题：当前网盘目录 + 它这一层有什么。
  ///
  /// 必须**跟着浏览位置变**：它回答的是「我现在在哪、这一层有多少」。
  /// 只在页头显示一次整库规模的话，用户翻进一个空目录会以为整个盘空了。
  ///
  /// 数字来自网盘列表本身（而不是本地索引）：这一页描述的是「网盘上有什么」，
  /// 用一个本地索引算出来的数字会与列表里看到的对不上。
  static String? _subtitle(WidgetRef ref) {
    final crumb = ref.watch(currentCrumbProvider);
    final listing = ref.watch(driveListingProvider(crumb)).valueOrNull;
    final where = crumb.isRoot ? '根目录' : crumb.path;
    if (listing == null) return where;
    // 构成那一行由 `DriveListing.summary` 给（面包屑用的是同一份）——
    // 两处各拼一遍的话，将来加一类条目只会改一处。
    return '$where · ${listing.summary}';
  }
}
