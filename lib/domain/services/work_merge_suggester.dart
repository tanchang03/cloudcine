import '../../core/utils/directory_title.dart';
import '../../core/utils/drive_paths.dart';
import '../entities/media_work.dart';
import 'work_merge_planner.dart';

/// 一条「要不要把《源》并进《目标》」的建议。
///
/// 它是**建议**，不是决定 —— 落库永远由用户在对话框里点确认才发生
/// （见 `WorkMergeService.mergeInto`）。这个类型只负责把「为什么觉得这两部
/// 是同一部」讲清楚，好让用户在两秒内判断得出来。
class WorkMergeSuggestion {
  const WorkMergeSuggestion({
    required this.sourceKey,
    required this.targetKey,
    required this.sourceTitle,
    required this.targetTitle,
    required this.sourceDir,
    required this.targetDir,
    required this.sourceItemCount,
    required this.targetItemCount,
  });

  /// 要被并走的那一部（本次发现新入库的那部）。
  final String sourceKey;

  /// 留下的那一部（它的目录是 [sourceDir] 的上级）。
  final String targetKey;

  final String sourceTitle;
  final String targetTitle;

  /// 源作品所在的目录（**带结尾斜杠**，与 `MediaItem.dirPath` 同口径）。
  final String sourceDir;

  /// 目标作品的目录 —— 它是 [sourceDir] 的祖先（或就是它本身）。
  final String targetDir;

  final int sourceItemCount;
  final int targetItemCount;

  /// 合并之后源作品名下会有几个文件（提示里给用户看「会变成多少集」）。
  int get mergedItemCount => sourceItemCount + targetItemCount;

  /// 这一对（源 → 目标）的身份，用来去重「这条问过没有」。
  ///
  /// 用 `\u0000` 而不是 `-` 之类：作品键是**用户网盘上的名字**归一化来的，
  /// 里面什么字符都可能有，拿可见字符当分隔符迟早会撞出一对假相同的 id
  /// （`a-b` + `c` 与 `a` + `b-c`）。
  String get id => '$sourceKey\u0000$targetKey';

  @override
  String toString() => 'WorkMergeSuggestion('
      '$sourceKey → $targetKey，目录 $sourceDir ⊂ $targetDir)';
}

/// 判断「这次发现新入库的作品里，有没有哪一部其实是某个已有作品的一部分」。
///
/// ## 它解决什么问题
///
/// 2026-10-07 现场：用户在 `/来自：分享/兰丨香R-故/` 里发现了一个新子目录
/// `兰z.香z.如z.故  去头去尾版 (2026) 4K/`（47 集）。这一批文件入库了、
/// 作品数也涨了，但它们**没有**并进已有的《兰香如故》（20 集）——
/// 因为归组键按解析出的片名算，而子目录名里被插了 `z.` 规避关键词过滤、
/// 还多了「去头去尾版」后缀，两个 `groupKey` 天然不同。
///
/// 自动归一也救不回来：它只认 `onlineId`，而「发现」流程不刮削，
/// 新作品是 `source=local`、`onlineId` 为空（见 `WorkMergePlanner`）。
///
/// 于是用户看到的是一墙 30 部剧集里第 30 位躺着一部名字认不出来的新作品。
/// 这个类做的就是把那件事**指出来**，判断留给用户。
///
/// ## 判据：目录包含 + 名字沾边，两条都要
///
/// 只靠目录包含会误报（`/电影/合集/` 下面塞一部不相干的片子），
/// 只靠名字沾边更会误报（`182` 与 `1821` 那次事故就是这么来的，
/// 见 `WorkMergePlanner` 的类文档）。两条叠在一起才够窄：
///
///   1. **源的某个目录落在目标的某个目录之下**（含同一目录）——
///      「你在《X》的目录里又放进了一部《Y》」这一件事本身就值得问一句；
///   2. **两个标题归一化后至少共有 [minSharedChars] 个字符** ——
///      挡住「同一个收藏夹里的两部不相干片子」。
///
/// 另外还要过一遍 [WorkMergePlanner.manualBlocker]：**能不能合由它说了算**。
/// 在这里另写一套「可不可以合」的判据，迟早会出现「对话框弹出来了、
/// 点确认却什么都不发生」——而那看起来就像应用坏了。
///
/// ## 为什么不做成自动合并
///
/// 名字被插字符规避过滤这件事**任何自动算法都救不回来**
/// （`超z级z马z力z欧z银z河z大z电影aa` 那条注释里已经立过这个判断），
/// 而合错的代价是两部不相干的片子被揉进一个格子。所以这里的产出恒为
/// 「一条待用户确认的建议」，永远不落库。
///
/// ## ⚠️ 2026-10-07 起：主路径已经由「目录锚点」接管
///
/// 上面那条现场（子目录里 47 集没并进《兰香如故》）现在**不会再发生**：
/// `DirectoryAnchorIndex` 会在解析期就把它们归到已有的《兰香如故》上
/// （见 `MediaFilenameParser.parse` 的 `anchors`），根本不会另起一部作品，
/// 于是这里也就不会出建议。
///
/// 这个类留下来管**锚点定不下来**的那几种情况：
///   - 同一目录下有几部剧（闸 2：不唯一）→ 锚点放弃；
///   - 名字完全不沾边（闸 3）→ 锚点放弃；
///   - 目标不是剧集，或新作品是**刮削之后**才分叉出来的。
abstract final class WorkMergeSuggester {
  const WorkMergeSuggester._();

  /// 名字相关度门槛：两个标题归一化后**至少**共有的字符数。
  ///
  /// 取 2 是权衡出来的：
  ///
  ///   - 取 1 会让「《兰香如故》× 《兰亭》」这类只剩一个字的组合通过；
  ///   - 取 3 会漏掉本例 —— `兰丨香r故` 与 `兰z香z如z故去头去尾版` 的公共
  ///     字符恰好是 `兰`、`香`、`故` 三个，但「丨」与「r」是发布者塞的
  ///     噪声，稍长一点的名字就会被噪声稀释到 3 以下。
  ///
  /// 短名（两三个字的国产剧）是这个门槛最难受的地方，而它们恰恰最需要
  /// 被认出来 —— 所以宁可宽一点：多问一句的成本是点一下「暂不」，
  /// 漏掉一句的成本是用户永远找不到那 47 集。
  ///
  /// ⛔ 它就是 [kMinSharedNameChars] —— 「名字沾边」这件事全项目只有一个数。
  ///    「目录锚点」（`DirectoryAnchorIndex`）用的也是它，两处一旦不同，
  ///    就会出现「锚点认得出、建议认不出」这种只在特定名字上暴露的分叉。
  static const int minSharedChars = kMinSharedNameChars;

  /// 扫一遍全库，给出所有值得问用户一句的合并建议。
  ///
  /// [dirsByWork] 是「作品键 → 它名下文件所在的目录集合」。由调用方从
  /// `MediaRepository.listItems()` 现搭 —— 建议器不认识仓储，那样它才能
  /// 被纯函数单测覆盖。
  ///
  /// [touchedKeys] 是**本次发现有文件是新入库的**那些作品键。空集直接返回
  /// 空 —— 用户只是重跑了一次发现、什么都没新增时不该被追问同一件事。
  ///
  /// 返回按 [WorkMergeSuggestion.sourceKey] 升序，**每个源最多一条**
  /// （取目录最贴近的那个目标）。
  static List<WorkMergeSuggestion> suggest({
    required List<MediaWork> works,
    required Map<String, List<String>> dirsByWork,
    required Set<String> touchedKeys,
  }) {
    if (touchedKeys.isEmpty) return const [];

    // 能当目标的只有「没被折走」的行 —— 别名当目标会形成链
    // （A←B←C），而链上任何一环被单独撤销都会把后面的节点孤儿化。
    final targets = works.where((w) => !w.isMergedAway).toList();

    final out = <WorkMergeSuggestion>[];
    for (final source in works) {
      if (!touchedKeys.contains(source.key)) continue;
      // 刚被折走的源不提议（理论上走不到：本次发现不会自己去合并）。
      if (source.isMergedAway) continue;

      final sourceDirs = dirsByWork[source.key];
      if (sourceDirs == null || sourceDirs.isEmpty) continue;

      WorkMergeSuggestion? best;
      for (final target in targets) {
        if (target.key == source.key) continue;
        if (_sharedChars(source.title, target.title) < minSharedChars) continue;
        if (WorkMergePlanner.manualBlocker(
              source: source,
              target: target,
              all: works,
            ) !=
            null) {
          continue;
        }

        final targetDirs = dirsByWork[target.key];
        if (targetDirs == null || targetDirs.isEmpty) continue;

        final pair = _nestedPair(sourceDirs, targetDirs);
        if (pair == null) continue;

        final candidate = WorkMergeSuggestion(
          sourceKey: source.key,
          targetKey: target.key,
          sourceTitle: source.title,
          targetTitle: target.title,
          sourceDir: pair.child,
          targetDir: pair.parent,
          sourceItemCount: source.itemCount,
          targetItemCount: target.itemCount,
        );
        if (best == null || _better(candidate, best)) best = candidate;
      }
      if (best != null) out.add(best);
    }

    out.sort((a, b) => a.sourceKey.compareTo(b.sourceKey));
    return out;
  }

  /// 在两组目录里找一对「子 → 父」。
  ///
  /// 取**最深**的那个父目录（`p.length` 最大）：一部剧的目录树上可能有
  /// 好几级都成了作品（`/剧A/`、`/剧A/第一季/`），最贴近的那一级才是
  /// 用户心里的「这一部」。
  ///
  /// ⚠️ 根目录（`/`）**不当父目录**。它「包含」一切，一旦有作品的文件直接
  /// 摆在网盘根下，这条建议就会从「同一棵树里的两行」退化成「全库任意两行
  /// 都可能配一对」—— 那正是这个类最想避免的误报形态。
  static ({String child, String parent})? _nestedPair(
    List<String> childDirs,
    List<String> parentDirs,
  ) {
    ({String child, String parent})? best;
    for (final child in childDirs) {
      for (final parent in parentDirs) {
        if (parent == driveRootPath) continue;
        if (!drivePathIsUnder(child, parent)) continue;
        if (best == null || parent.length > best.parent.length) {
          best = (child: child, parent: parent);
        }
      }
    }
    return best;
  }

  /// 同一个源有两个候选目标时挑哪个：目录更深 → 文件更多 → 键更小。
  ///
  /// 后两级纯粹是为了**确定性**：没有它们，同一个库两次运行可能给出不同的
  /// 建议，而用户会看到「刚才问的是并到 A，现在又问并到 B」。
  static bool _better(WorkMergeSuggestion a, WorkMergeSuggestion b) {
    if (a.targetDir.length != b.targetDir.length) {
      return a.targetDir.length > b.targetDir.length;
    }
    if (a.targetItemCount != b.targetItemCount) {
      return a.targetItemCount > b.targetItemCount;
    }
    return a.targetKey.compareTo(b.targetKey) < 0;
  }

  /// 两个标题归一化后共有的字符数（按**字符集**，不看顺序）。
  ///
  /// 判据本体在 `directory_anchor.dart`：归一化口径与
  /// `ParsedMediaName.groupKey` / `DirectoryTitle` 一致 —— 小写、只留
  /// `[a-z0-9\u4e00-\u9fff]`。三处对「什么算同一个名字」的理解一旦不同，
  /// 就会出现「目录名判成了同一部、建议却认不出来」这种极难排查的不一致。
  static int _sharedChars(String a, String b) => sharedNameChars(a, b);
}
