import '../../core/utils/drive_paths.dart';
import '../../core/utils/file_names.dart';
import '../entities/media_item.dart';

/// 网盘目录树（只读）。
///
/// ## 为什么能离线重建
///
/// `MediaItem` 自带 [MediaItem.dirPath] —— 扫描期按遍历栈拼出来的展示路径
/// （形如 `/电影/流浪地球2 (2023)/`）。把它按 `/` 切开，父子关系就齐了：
/// 不需要再连网盘，也不需要额外的目录表。
///
/// 这与本项目「扫描是唯一必须联网的步骤」的总设计一致：目录视图**离线可用、
/// 瞬时打开**，网盘掉线或凭证过期都不影响翻目录。
///
/// ## 它是「展示路径」的树，不是「目录 ID」的树
///
/// 严格说，两个不同的目录可以有同一个展示路径（网盘允许同名目录，
/// 而扫描器拼路径时用的是目录名）。这一版按**路径**归并 —— 因为用户翻目录
/// 时认的就是路径，把同名目录拆成两棵只会让人以为出现了重复项。
/// 代价是同名目录下的文件会并到一起显示。
///
/// ## 汇总数字是**递归**的
///
/// [FolderNode.itemCount] / [FolderNode.totalBytes] 含全部子孙：用户看
/// 「电影」这一行时想知道的是「这个分类下总共多少片、占多大」，而不是
/// 「直接躺在这个目录里的有几个」。
class FolderTree {
  FolderTree._({
    required this.root,
    required Map<String, FolderNode> index,
    required this.files,
  }) : _index = index;

  /// 根目录。`path` 为 `/`。
  static const String rootPath = driveRootPath;

  final FolderNode root;

  /// 全部目录，按路径索引。用来把「当前路径」O(1) 解析成节点。
  final Map<String, FolderNode> _index;

  /// 全部文件，已按「目录路径 → 文件名（自然序）」排好。
  ///
  /// 目录视图的搜索直接在这上面过滤 —— 搜索结果要能一眼看出文件在哪，
  /// 所以顺序必须按**路径**聚在一起，而不是按入库时间。
  final List<MediaItem> files;

  /// 按路径取目录。不存在返回 `null`（例如重扫后目录没了）。
  FolderNode? nodeAt(String path) => _index[normalize(path)];

  /// 全部目录（含根），按路径排序。
  List<FolderNode> get folders {
    final list = _index.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return list;
  }

  int get folderCount => _index.length;
  int get fileCount => files.length;

  /// 子目录数量（**不含根**）。
  ///
  /// 界面上说「N 个文件夹」时用的就是它 —— 把根算进去会凭空多一个，
  /// 而用户数不出那个多出来的文件夹在哪。
  int get subfolderCount => _index.length - 1;

  /// 从根到 [path] 的完整链路（含首尾）。路径不存在时返回空列表。
  ///
  /// 面包屑要的就是它 —— 逐段取名字由调用方决定，树只负责给出结构。
  List<FolderNode> pathTo(String path) {
    final node = nodeAt(path);
    if (node == null) return const [];
    final chain = <FolderNode>[node];
    var current = node;
    while (current.parentPath != null) {
      final parent = _index[current.parentPath];
      if (parent == null) break;
      chain.insert(0, parent);
      current = parent;
    }
    return chain;
  }

  /// 按关键词找**文件**：文件名与完整路径都参与匹配。
  ///
  /// ## 为什么路径也要匹配
  ///
  /// 用户经常记得「在 `/电影/科幻/` 下面」却记不住片名，也可能只记得
  /// 发布组的目录名。只匹配文件名的话，「按文件夹路径找媒体文件」这件事
  /// 就做不到 —— 而这正是目录视图存在的理由。
  ///
  /// 大小写不敏感；[limit] 是为了避免关键词太宽泛时把整库拉进列表。
  List<MediaItem> findFiles(String query, {int limit = 300}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = <MediaItem>[];
    for (final item in files) {
      if (item.name.toLowerCase().contains(q) ||
          item.dirPath.toLowerCase().contains(q)) {
        out.add(item);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /// 按关键词找**目录**：匹配目录名或完整路径。
  List<FolderNode> findFolders(String query, {int limit = 60}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = <FolderNode>[];
    for (final folder in folders) {
      if (folder.path == rootPath) continue;
      if (folder.path.toLowerCase().contains(q)) {
        out.add(folder);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  // -------------------------------------------------------------------
  // 路径工具
  // -------------------------------------------------------------------
  //
  // 这几个方法只是 `core/utils/drive_paths.dart` 的门面：归一化规则只有一份
  // 实现（在 core 里），这里保留同名静态方法是为了让调用方写
  // `FolderTree.normalize(...)` 时读起来仍然是「目录树的路径口径」。
  // **别在这里另写一套** —— 两套归一化只要有一点不一致，就会出现
  // 「按目录筛不到文件」这种静默错误。

  /// 归一化路径。见 [normalizeDrivePath]。
  static String normalize(String raw) => normalizeDrivePath(raw);

  /// 把归一化路径切成目录名列表。根返回空列表。
  static List<String> segments(String path) => drivePathSegments(path);

  /// 父目录路径。根的父亲是自己。
  static String parentOf(String path) => drivePathParent(path);

  /// 末段目录名。根返回 `/`。
  static String nameOf(String path) => drivePathName(path);

  /// 扫描器风格的路径（带结尾斜杠）。用于和 `MediaItem.dirPath` 直接比。
  static String withTrailingSlash(String path) => drivePathWithTrailingSlash(path);

  // -------------------------------------------------------------------
  // 构建
  // -------------------------------------------------------------------

  /// 从媒体项重建整棵树。
  ///
  /// 复杂度 O(项数 × 路径深度)，一次遍历 + 一次自底向上汇总。
  static FolderTree build(Iterable<MediaItem> items) {
    final root = FolderNode._(path: rootPath, name: rootPath, parentPath: null);
    final index = <String, FolderNode>{rootPath: root};
    final allFiles = <MediaItem>[];

    FolderNode ensure(String path) {
      final existing = index[path];
      if (existing != null) return existing;
      final parent = ensure(parentOf(path));
      final node = FolderNode._(
        path: path,
        name: nameOf(path),
        parentPath: parent.path,
      );
      parent._children[path] = node;
      index[path] = node;
      return node;
    }

    for (final item in items) {
      final node = ensure(normalize(item.dirPath));
      node._files.add(item);
      allFiles.add(item);
    }

    // 自底向上汇总。必须**先递归子节点再读它的合计**，所以这里不能用
    // 迭代式写法偷懒。
    void rollUp(FolderNode node) {
      var count = node._files.length;
      var bytes = 0;
      for (final f in node._files) {
        bytes += f.sizeBytes ?? 0;
      }
      for (final child in node._children.values) {
        rollUp(child);
        count += child._itemCount;
        bytes += child._totalBytes;
      }
      node._itemCount = count;
      node._totalBytes = bytes;
    }

    rollUp(root);

    for (final node in index.values) {
      node._files.sort((a, b) => naturalCompare(a.name, b.name));
    }

    allFiles.sort((a, b) {
      final byDir = a.dirPath.compareTo(b.dirPath);
      return byDir != 0 ? byDir : naturalCompare(a.name, b.name);
    });

    return FolderTree._(root: root, index: index, files: allFiles);
  }
}

/// 目录树上的一个节点。
///
/// 构建期可变、构建完只读：`build` 返回之后不会再有任何写入，[children] /
/// [files] 的惰性缓存因此是安全的。
class FolderNode {
  FolderNode._({
    required this.path,
    required this.name,
    required this.parentPath,
  });

  /// 归一化路径。根为 `/`，其余**不带结尾斜杠**。
  final String path;

  /// 末段目录名。根为 `/`。
  final String name;

  /// 父目录路径。根为 `null`。
  final String? parentPath;

  final Map<String, FolderNode> _children = {};
  final List<MediaItem> _files = [];

  int _itemCount = 0;
  int _totalBytes = 0;

  List<FolderNode>? _childCache;
  List<MediaItem>? _fileCache;

  /// 子目录，按**自然序**排（`第2期` 在 `第10期` 前面）。
  List<FolderNode> get children =>
      _childCache ??= (_children.values.toList()
        ..sort((a, b) => naturalCompare(a.name, b.name)));

  /// 直接躺在这一层里的文件，按自然序排。
  ///
  /// **必须缓存**：列表是惰性构建的（`ListView.builder` 每画一行取一次），
  /// 每次都现造一个不可变副本会把这个 getter 变成 O(n) —— 于是整屏
  /// O(n²)，几百个文件的目录会明显卡顿。
  List<MediaItem> get files => _fileCache ??= List.unmodifiable(_files);

  /// **递归**文件数（含全部子孙）。
  int get itemCount => _itemCount;

  /// **递归**体积（含全部子孙）。拿不到体积的项按 0 计。
  int get totalBytes => _totalBytes;

  /// 这一层直接放着的文件数。面包屑上的「N 个文件」用它。
  int get directFileCount => _files.length;

  bool get isRoot => parentPath == null;

  /// 既没有子目录也没有文件。扫描到空目录时会出现。
  bool get isEmpty => _files.isEmpty && _children.isEmpty;

  @override
  String toString() =>
      'FolderNode($path, $directFileCount 文件, ${children.length} 子目录, '
      '共 $itemCount 项)';
}
