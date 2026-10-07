/// 「已有剧集 → 它的目录」→ 目录锚点索引的**装配**。
///
/// ## 为什么单独一个文件
///
/// 两条入口（文件夹里的「发现」、全盘扫描）都要它，而它们分属
/// `media_discovery.dart` 与 `scan_service.dart` —— 而后者被前者 import。
/// 把装配放进任一边都会造出一个循环 import。
///
/// ## 判据不在这里
///
/// 「哪部作品能当锚点」「目录怎么往上找」「名字要沾边到什么程度」全在
/// `core/utils/directory_anchor.dart`，那一份是**纯函数**、可以穷举单测。
/// 这里只做一件事：把库里的行**翻译**成那个纯函数要的形状。
library;

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/directory_anchor.dart';
import '../../core/utils/filename_parser.dart';
import '../adapters/media_repository.dart';
import '../entities/media_work.dart';

/// 读出库里的剧集作品与它们的目录，建出目录锚点索引。
///
/// 返回 `null` 表示**没有可用的锚点**（库里一部剧集都没有 —— 首次全盘扫描
/// 的常态；或者读库失败）。调用方直接把 `null` 传给解析器即可，语义就是
/// 「不锚定」。
///
/// ## 只取「剧集 + 非别名」
///
///   - **剧集**：只有剧集谈「整目录归一部剧」。电影是「一个目录一部片」，
///     让电影目录当锚点会把新片并进不相干的老片里（闸 1）。
///   - **非别名**：别名行（`mergedInto != null`）不能再被并走，否则会成链。
///
/// ⛔ 这两条**不能**挪到这里就算完 —— `DirectoryAnchorIndex` 自己也要再挡
///    一遍。锚点索引是可变对象，扫描期会 [DirectoryAnchorIndex.register]
///    新作品进去，那条路上没有这个过滤。
///
/// ## 为什么复用 `dirsForWorks`
///
/// 它返回的正是「目录 → 该目录下有文件的那些作品」，与锚点索引的形状
/// **一模一样**，而且已经处理好了三件容易写错的事：
/// 目录路径归一（带尾斜杠）、按 fid 去重、并集口径（把被折叠进来的源作品
/// 名下的文件也算进目标）。
Future<DirectoryAnchorIndex?> loadDirectoryAnchors(
  MediaRepository library,
) async {
  try {
    final works = await library.allWorks();
    final byKey = <String, MediaWork>{for (final w in works) w.key: w};

    final episodeKeys = <String>[
      for (final w in works)
        if (w.kind == MediaKind.episode && w.mergedInto == null) w.key,
    ];
    if (episodeKeys.isEmpty) return null;

    final dirs = await library.dirsForWorks(episodeKeys);

    final anchors = <AnchorWork>[];
    for (final dir in dirs) {
      if (dir.workKeys.isEmpty) continue;
      for (final key in dir.workKeys) {
        final work = byKey[key];
        if (work == null) continue;
        anchors.add(
          AnchorWork(
            key: work.key,
            title: work.title,
            kind: work.kind,
            isAlias: work.mergedInto != null,
            dirs: {dir.dirPath},
          ),
        );
      }
    }

    final index = DirectoryAnchorIndex.of(anchors);
    // ⛔ 这里**故意不打 info 日志**：`parseTransientMedia` 那条路（目录视图里
    //    直接点播）每次点击都会调这个函数，而 `DiagLog` 是同步写盘 + fsync。
    //    要记这件事的调用方自己打（发现 / 扫描各一次，天然低频）。
    return index.isEmpty ? null : index;
  } catch (e) {
    // 锚点只是**锦上添花**：读不到就退回「按文件名归组」的老行为，
    // 而不是让整次发现/扫描失败。代价是这次可能又分叉一部作品出来。
    diag.warn('归组', '目录锚点读取失败，本次退回按文件名归组：$e');
    return null;
  }
}
