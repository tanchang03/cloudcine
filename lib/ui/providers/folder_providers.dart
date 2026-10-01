import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/folder_tree.dart';
import 'app_providers.dart';

/// 媒体库的两种呈现方式。
///
/// 做成**同一个页面里的两种视图**而不是侧栏两个一级入口：它们读的是同一批
/// 数据，只是视角不同（「有哪些片子」vs「网盘上是怎么放的」）。分成两个入口
/// 会让用户觉得「媒体库」和「文件夹」是两个东西，而搜索框、刷新、扫描状态
/// 这些本该共用的东西也得各写一份。
enum LibraryView {
  posters('海报墙'),
  folders('文件夹');

  const LibraryView(this.label);

  final String label;
}

class LibraryViewController extends Notifier<LibraryView> {
  @override
  LibraryView build() => LibraryView.posters;

  void set(LibraryView view) => state = view;
}

final libraryViewProvider =
    NotifierProvider<LibraryViewController, LibraryView>(
  LibraryViewController.new,
);

/// 目录视图当前所在的目录（归一化路径，根为 `/`）。
///
/// **只存一个路径字符串**，不存节点：目录树本身由 [folderTreeProvider] 提供，
/// 重扫之后树会重建，而路径是个稳定的「坐标」—— 存节点就会拿着一份过期的
/// 树去渲染（表现为翻着翻着突然一片空白）。
///
/// 路径不存在时（重扫后目录没了）由 UI 兜底，这里不做校验。
class FolderPathController extends Notifier<String> {
  @override
  String build() => FolderTree.rootPath;

  void open(String path) {
    final normalized = FolderTree.normalize(path);
    if (normalized != state) state = normalized;
  }

  /// 回到上一层。已在根目录时不动 —— 否则会把自己又设一遍，白白重建界面。
  void up() => open(FolderTree.parentOf(state));

  void reset() {
    if (state != FolderTree.rootPath) state = FolderTree.rootPath;
  }
}

final currentFolderProvider =
    NotifierProvider<FolderPathController, String>(FolderPathController.new);

/// 网盘目录树。
///
/// ## 为什么一次读全量
///
/// 目录树要给出**递归**的文件数与体积（「电影」这一行要显示它下面总共多少片），
/// 那必须看到全部媒体项才能算。个人网盘量级（实测几百到几千条）下一次全表读
/// 只要几十毫秒，而换成「每进一层查一次库」会带来两个新问题：递归计数还得
/// 单独算，且每次点目录都要等一次 SQLite 往返。
///
/// 全量读的代价是**切目录不再查库** —— 翻目录是纯内存操作，瞬时响应。
///
/// 刷新入口是媒体库页头的「刷新」按钮（它同时 invalidate 这个 provider）。
final folderTreeProvider = FutureProvider<FolderTree>((ref) async {
  final items = await ref.watch(mediaRepositoryProvider).listItems();
  return FolderTree.build(items);
});
