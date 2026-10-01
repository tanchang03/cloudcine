import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/folder_tree.dart';
import 'app_providers.dart';
import 'library_refresh_providers.dart';

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
/// 刷新入口是媒体库页头的「刷新」按钮，以及**任何一次写库之后**
/// （[libraryWriteSignalProvider] 由扫描与发现两处推进）。
final folderTreeProvider = FutureProvider<FolderTree>((ref) async {
  ref.watch(libraryWriteSignalProvider);
  final items = await ref.watch(mediaRepositoryProvider).listItems();
  return FolderTree.build(items);
});
