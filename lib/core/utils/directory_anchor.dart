/// 目录 → 归属作品（**目录锚点**）：新文件该归到哪部已有剧集下。
///
/// ## 它解决什么问题
///
/// 2026-10-07 现场：`/来自：分享/兰丨香R-故/` 里有 20 个 `01.mp4…20.mp4`，
/// 片名靠目录名兜底 → 作品《兰香如故》（key `兰丨香r故`）。后来该目录下
/// **新开了一层** `兰z.香z.如z.故  去头去尾版 (2026) 4K/`，里面是
/// `S01E01.第1集.2160p…mkv`。
///
/// 这些文件名**自带季集结构**，于是 `MediaFilenameParser` 认定它们
/// 「自称独立发行物」（`_isStandaloneRelease`），片名取自**子目录名**
/// → 归组键 `兰z香z如z故去头去尾版` ≠ `兰丨香r故` → **另起一部作品**。
///
/// 后果是静默的三连：
///   1. 剧集页里看不见那 47 集（列表读的是作品行）；
///   2. 追更检查**报「没有更新」** —— 它的增量统计只认在追作品
///      （`pendingNewItemCounts`），而新作品没在追；
///   3. 用户得自己发现并手动归一。
///
/// ## 判据：**目录归属优先于文件名**
///
/// 用户定的口径：*在同一个媒体剧集的网盘目录里发现的新媒体，统统归为该
/// 剧集，不需要问*。文件名的季集结构只说明「这是第几集」，**不说明
/// 「这是哪部剧」** —— 后者由它落在谁的目录里决定。
///
/// ## 三道闸
///
/// 1. **只有剧集（`MediaKind.episode`）当锚点。**
/// 2. **目录下必须恰好只有一部剧集。** 平铺目录（`/电影/` 里几十部片）
///    下有几部 → **不猜**。
/// 3. **新文件所在目录必须是那部剧目录的严格子目录**（`D ⊊ A`，**不含
///    `D == A`**）。这一条是整套判据的关键，它一条顶两条：
///
///    - `D == A`（文件直接躺在剧集目录里）→ **不锚**。平铺目录
///      （`/电影/`、`/来自：分享/我的资源/`）正好都是这种形状，于是
///      「一部剧 + 一堆电影混放在一个目录里」不会再让新片被吸进那部剧。
///      这种文件本来也不需要锚 —— 目录名兜底（`DirectoryTitle`）已经能
///      把它们归对。
///    - `D ⊊ A`（**在那个剧的目录里又新开了一层**）→ 锚。这是比文件名
///      强得多的**用户意图信号**：「我在《兰香如故》的文件夹里建了一层，
///      放进去的东西当然是它的」。
///
/// ⛔ **刻意不做「名字沾边」**（`WorkMergeSuggester` 那一条）。试过，它会
///    把 `/剧名/S01/`（`S01` 与剧名零公共字符）、`/剧名/4K修复版/`
///    这类**最常见的结构**全部误伤成「不锚」，而它们恰恰是这个功能要救的。
///    「严格子目录」这一条已经把「平铺目录」那一类风险挡掉了。
///
/// ## 索引是**可变**的
///
/// 全盘扫描是 BFS，父目录先于子目录出队。首次扫描时库里还没有那部剧，
/// 所以扫描期每建出一批作品就要 [register] 进去 —— 否则「第一次扫就分叉」，
/// 用户得再扫一次才对。
library;

import 'drive_paths.dart';
import 'filename_parser.dart';

/// 锚点：新文件该归到哪部作品下。
class DirectoryAnchor {
  const DirectoryAnchor({required this.groupKey, required this.title});

  /// 目标作品的 `media_works.key`（**不是**归一化后的标题 —— 作品刮削后
  /// 标题可能改过，而 key 永不改写，见 [ParsedMediaName.groupKeyOverride]）。
  final String groupKey;

  /// 目标作品的标题。锚定后文件沿用它，避免同一部剧里两种标题并存。
  final String title;

  @override
  String toString() => 'DirectoryAnchor($groupKey, "$title")';
}

/// 建索引的输入：一部**已有**作品 + 它在哪些目录下有文件。
class AnchorWork {
  const AnchorWork({
    required this.key,
    required this.title,
    required this.kind,
    required this.isAlias,
    required this.dirs,
  });

  final String key;
  final String title;
  final MediaKind kind;

  /// 别名行（`mergedInto != null`）—— 不当锚点，否则会成链。
  final bool isAlias;

  /// 它的文件所在的目录（**带尾斜杠**，与 `MediaItem.dirPath` 同口径）。
  final Set<String> dirs;
}

/// 目录 → 归属作品。**纯数据 + 纯查询**，不碰 IO，可穷举单测。
///
/// ⚠️ 它是**可变**的：全盘扫描期间每落一批作品就 [register] 一次
///    （见库文档「索引是可变的」）。传进解析器的那个实例就是这份可变的
///    索引本身 —— 所以扫描到后半程时，前半程新建的作品已经能当锚点了。
///    「空索引」用 `null` 表示，不需要一个常量单例（那样谁都能把它
///    `register` 脏掉，而它是全局共享的）。
class DirectoryAnchorIndex {
  DirectoryAnchorIndex._(this._byDir);

  /// 目录路径（带尾斜杠）→ 该目录下**有文件**的剧集作品。
  final Map<String, List<DirectoryAnchor>> _byDir;

  /// 从已有作品建索引。
  factory DirectoryAnchorIndex.of(Iterable<AnchorWork> works) {
    final byDir = <String, List<DirectoryAnchor>>{};
    for (final w in works) {
      _add(byDir, w);
    }
    return DirectoryAnchorIndex._(byDir);
  }

  /// 登记一部作品。扫描期每落一批作品就调一次（见库文档「索引是可变的」）。
  void register(AnchorWork work) => _add(_byDir, work);

  /// 已登记的目录数（诊断用）。
  int get length => _byDir.length;

  /// 一部作品都没登记 → 调用方可以干脆不传（等价于 `null`）。
  bool get isEmpty => _byDir.isEmpty;

  static void _add(Map<String, List<DirectoryAnchor>> byDir, AnchorWork w) {
    // 闸 1：只有剧集当锚点。
    if (w.isAlias || w.kind != MediaKind.episode) return;
    final title = w.title.trim();
    if (title.isEmpty) return;
    for (final dir in w.dirs) {
      if (dir.isEmpty || dir == driveRootPath || dir == '/') continue;
      final list = byDir.putIfAbsent(dir, () => <DirectoryAnchor>[]);
      if (list.any((a) => a.groupKey == w.key)) continue;
      list.add(DirectoryAnchor(groupKey: w.key, title: title));
    }
  }

  /// 这个目录**上一级**该归哪部已有剧集；定不下来返回 `null`。
  ///
  /// ## ⛔ 先看自己那一级，命中就直接放弃（闸 3）
  ///
  /// `dirPath` 本身就是一个锚点目录时**立刻返回 `null`**，而不是「跳过它
  /// 继续往上找」。两件事都靠这一步：
  ///
  ///   - **`D == A` 不锚**：文件直接躺在剧集目录里时，那只是「目录里有文件」，
  ///     不是「用户把它放进了这部剧」—— 平铺目录（`/电影/`、
  ///     `/来自：分享/我的资源/`）全是这个形状，不挡的话新片会被吸进那部剧。
  ///   - **不越级**：`/甲剧/混放/`（里面是乙剧和丙剧）里的文件不该因为
  ///     再往上是 `/甲剧/` 就归到甲剧头上。
  ///
  /// ## 再往上：最深的一级说了算
  ///
  /// 最深一级不唯一（同一个目录下有几部剧）就**不猜** —— 再往上看只会更笼统。
  DirectoryAnchor? anchorFor(String dirPath) {
    if (_byDir.isEmpty) return null;
    final path = drivePathWithTrailingSlash(dirPath);
    // 闸 3：自己就是锚点目录 → 不锚。
    if (_byDir.containsKey(path)) return null;
    for (final candidate in _ancestorPaths(path).skip(1)) {
      final list = _byDir[candidate];
      if (list == null || list.isEmpty) continue;
      // 闸 2：不唯一 → 不猜。
      if (list.length != 1) return null;
      return list.first;
    }
    return null;
  }

  /// 从 [path] 自己往上到根之前的每一级目录（含自身）。
  ///
  /// `/a/b/c/` → `/a/b/c/`、`/a/b/`、`/a/`。根目录 `/` **不含**。
  /// 调用方用 `.skip(1)` 把「自己」那一级去掉，于是只剩**真祖先**。
  static Iterable<String> _ancestorPaths(String path) sync* {
    var p = path;
    while (p.isNotEmpty && p != '/' && p != driveRootPath) {
      yield p;
      final trimmed = p.replaceAll(RegExp(r'/+$'), '');
      final idx = trimmed.lastIndexOf('/');
      if (idx < 0) return;
      final parent = trimmed.substring(0, idx + 1);
      if (parent.isEmpty || parent == '/') return;
      p = parent;
    }
  }
}
