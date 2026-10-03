import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/folder_tree.dart';
import 'app_providers.dart';
import 'library_refresh_providers.dart';

/// 文件夹视图的搜索词 —— **只筛当前这一层网盘目录**。
///
/// ## 为什么它不再与媒体库共用 `libraryFilterProvider.query`
///
/// 两处原先共用一个搜索词（那时它们是同一个页面里的两个视图）。现在它们是
/// 侧栏上并列的两个一级入口，共用会立刻出现一个说不通的状态：在媒体库搜
/// 「沙丘」之后切到文件夹，**新页面的输入框是空的，而列表被「沙丘」过滤着**
/// —— 用户看到的是一个几乎空白的目录，第一反应是「这个页面坏了」。
///
/// 两处的语义本来也不一样：媒体库搜的是库里已入库的作品 / 文件（要打 SQL，
/// 见 `workListProvider`），文件夹筛的是**当前这一层**的条目（纯客户端过滤，
/// 见 `folder_browser.dart`）。同一个词在两边的含义都不同，就不该是同一个状态。
class FolderQueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;

  void clear() => state = '';
}

final folderQueryProvider =
    NotifierProvider<FolderQueryController, String>(FolderQueryController.new);

/// **本地索引**重建出来的目录树。
///
/// ## 它现在的角色：叠加层，不是数据源
///
/// 目录视图的数据源是**网盘实时目录**（见 `drive_browse_providers.dart`）。
/// 那棵树只回答「网盘上现在有什么」；而用户还需要知道「这里面哪些已经在
/// 库里了」—— 那只能从本地索引读。这棵树就是这个用途：
///
///   - [FolderTree.fileIds]：某个网盘文件是否已入库；
///   - [FolderTree.indexedCountAt]：某个目录里已入库多少个。
///
/// ## 为什么一次读全量
///
/// 目录行要显示**递归**的已入库数量（「电影」这一行要显示它下面总共有多少
/// 片），那必须看到全部媒体项才能算。个人网盘量级（实测几百到几千条）下
/// 一次全表读只要几十毫秒，而换成「每进一层查一次库」会带来两个新问题：
/// 递归计数还得单独算，且每次点目录都要等一次 SQLite 往返。
///
/// 刷新入口是**文件夹页头的「刷新」按钮**（`ui/pages/folder_page.dart`），
/// 以及**任何一次写库之后**（[libraryWriteSignalProvider] 由扫描与发现两处推进）。
final folderTreeProvider = FutureProvider<FolderTree>((ref) async {
  ref.watch(libraryWriteSignalProvider);
  final items = await ref.watch(mediaRepositoryProvider).listItems();
  return FolderTree.build(items);
});

/// 文件夹视图的**多选**状态（批量删除用）。
///
/// ## 为什么「是否在多选模式」与「选了哪些」必须在同一个对象里
///
/// 与媒体库那一份（`library_selection_providers.dart`）同一条理由，这里再写
/// 一遍是因为它更致命：拆成两个 provider 的话，退出多选时必须自己记得清空
/// 选中集合，任何一处漏了都会让用户**下次点「选择」时发现已经勾着一批
/// 上一次的条目** —— 而这里的动作是「删除网盘文件」，不是「合并海报」。
///
/// ## 键是 fid，不是 `DriveEntry`
///
/// 列表每次重列网盘给的都是**新对象**，存对象等于「刷新一下选择就丢了」。
/// 而且删除要的本来就是 fid（`deleteFiles` 收的就是它），存 fid 省一层映射。
///
/// ## ⚠️ 切换目录必须清空选中（本文件最要紧的一条）
///
/// 勾选表达的语义是「**我屏幕上这几个**」，而工具条上的「已选 N 项」是
/// 唯一能让用户确认自己删的是什么的地方。翻到别的目录还留着上一个目录的
/// 选择，用户看到的是一个「已选 5 项」而列表里一个勾都没有的界面 ——
/// 这时按下删除，删掉的是他**看不见**的 5 个文件。所以
/// `FolderBrowser` 在目录变化时会调 [FolderSelectionController.clearIds]。
///
/// 只清选中、**留在多选模式里**：用户删完一批往往还要接着删下一批
/// （进一个子目录继续挑），每进一层都要重新点一次「选择」是多余的摩擦。
class FolderSelection {
  const FolderSelection({
    this.active = false,
    this.ids = const <String>{},
  });

  /// 是否处于多选模式。它决定每一行的行为：关闭时整行是原本的动作
  /// （进目录 / 播放），开启时整行 = 勾选。
  final bool active;

  /// 选中的条目 fid。
  final Set<String> ids;

  int get count => ids.length;

  bool get isEmpty => ids.isEmpty;

  bool contains(String id) => ids.contains(id);

  FolderSelection copyWith({bool? active, Set<String>? ids}) => FolderSelection(
        active: active ?? this.active,
        ids: ids ?? this.ids,
      );

  @override
  bool operator ==(Object other) =>
      other is FolderSelection &&
      other.active == active &&
      // `Set` 没重写 `==`（默认**引用**相等）。直接比会漏掉「内容一样但不是
      // 同一个对象」的更新，Riverpod 会误判成「没变」而不重建 —— 表现是
      // 勾了但复选框不高亮。
      setEquals(other.ids, ids);

  @override
  int get hashCode => Object.hash(active, Object.hashAllUnordered(ids));

  @override
  String toString() => 'FolderSelection(active=$active, ${ids.length} 项)';
}

class FolderSelectionController extends Notifier<FolderSelection> {
  @override
  FolderSelection build() => const FolderSelection();

  /// 进入多选模式。[id] 非空时顺带勾上它 —— 「长按某一行」这条入口必须
  /// **连按的那一下一起生效**，否则用户长按完还得再点一次，那一次长按白做。
  void enter([String? id]) {
    state = FolderSelection(
      active: true,
      ids: id == null ? const <String>{} : <String>{id},
    );
  }

  /// 退出多选模式并清空选中（两者必须同时发生，理由见 [FolderSelection]）。
  void exit() => state = const FolderSelection();

  /// 勾选 / 取消勾选一个条目。
  void toggle(String id) {
    final next = Set<String>.of(state.ids);
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(ids: next);
  }

  /// 勾上一批（「全选」用）。
  ///
  /// **追加**而不是替换：用户可能先手勾了几个，再点全选 —— 追加在任何
  /// 顺序下都不会把已勾的丢掉。
  ///
  /// ⚠️ 调用方传的必须是**当前列表里可见的那些**（已过搜索词）。全选 =
  /// 「把屏幕上这些全勾上」，不是「把这一层全勾上」—— 后者会在用户筛出
  /// 三个文件、点全选、然后按删除时，把同目录另外两百个也一起删掉。
  void addAll(Iterable<String> ids) {
    if (ids.every(state.ids.contains)) return;
    state = state.copyWith(ids: {...state.ids, ...ids});
  }

  /// 只清空选中，**留在**多选模式里（切换目录、删完之后用）。
  void clearIds() {
    if (state.ids.isEmpty) return;
    state = state.copyWith(ids: const <String>{});
  }
}

final folderSelectionProvider =
    NotifierProvider<FolderSelectionController, FolderSelection>(
  FolderSelectionController.new,
);
