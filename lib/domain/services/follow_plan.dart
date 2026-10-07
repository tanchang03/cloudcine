import '../entities/follow_dir.dart';

/// 一次追更检查的**纯决策**：从「要查哪些目录」推出「哪些作品的水位线可以推进」。
///
/// ## 为什么把它从 [FollowService] 里抽出来
///
/// 与 `SyncDecision` 同一条理由：这一步的错法**全是静默的** ——
///
///   * 目录少查一个 → 那部剧永远不提醒；
///   * 水位线推早一步 → 新集被永久划进「已经看过」，用户再也不会被提醒；
///   * 折叠过的作品没翻译回目标 key → 每检查一次就把同一批新集重报一次。
///
/// 三种都不会报错，只会在几周后表现成「这功能好像坏了」。所以判据必须能被
/// 不碰 IO 的单测钉住 —— 这个类里**没有** `MediaRepository`、没有网盘、
/// 没有时钟。
///
/// ## 一次检查的两半
///
/// ```
/// ① FollowPlan.of(dirs)          → 要列哪些目录（去重后）
/// ② plan.checkedWorks(failed)    → 哪些作品这次真的被完整检查过了
/// ```
///
/// 中间那一步（真的去列目录）是 [FollowService] 的活，不属于这里。
class FollowPlan {
  const FollowPlan._({required this.dirs, required this.dirsByWork});

  /// 要列目录的目录，**已按 fid 去重**，顺序 = 输入里首次出现的顺序。
  ///
  /// 顺序稳定是有意义的：它决定了「先查哪部剧的目录」，而检查是串行的
  /// （夸克有 QPS 限制），顺序抖动会让每次检查的耗时表现不一致。
  final List<FollowDir> dirs;

  /// 作品 key → 它名下**全部**目录 id。
  ///
  /// ⛔ 判「这部作品这次能不能推进水位线」用的就是它：只要有**一个**目录
  ///    没列成功，就不能推进 —— 那批新集可能正好在没列到的那个目录里。
  ///    宁可这次不报、下次重来，也不能把没看到的划进「已读」。
  final Map<String, Set<String>> dirsByWork;

  /// 从「目录 → 它覆盖的作品」反推出整个计划。
  ///
  /// [dirs] 里同一个 fid 出现多次时**合并** `workKeys`（取并集），路径取
  /// 首次出现的那个。仓储实现已经去过重，这里再兜一次是为了让这个类
  /// **自己**就是可信的 —— 单测直接喂重复输入也应该得到正确的计划。
  factory FollowPlan.of(Iterable<FollowDir> dirs) {
    final byId = <String, FollowDir>{};
    for (final d in dirs) {
      final prev = byId[d.dirId];
      byId[d.dirId] = prev == null
          ? d
          : FollowDir(
              dirId: d.dirId,
              dirPath: prev.dirPath,
              workKeys: {...prev.workKeys, ...d.workKeys},
            );
    }

    final dirsByWork = <String, Set<String>>{};
    for (final d in byId.values) {
      for (final key in d.workKeys) {
        (dirsByWork[key] ??= <String>{}).add(d.dirId);
      }
    }

    return FollowPlan._(
      dirs: List.unmodifiable(byId.values),
      dirsByWork: {
        for (final e in dirsByWork.entries) e.key: Set.unmodifiable(e.value),
      },
    );
  }

  /// 这次检查结束后，**哪些作品的水位线可以推进**。
  ///
  /// 判据：它名下的目录**一个都没失败**。
  ///
  /// ## ⛔ 「一个目录都没有」的作品不在结果里
  ///
  /// 一部在追的作品可能一个目录都没有（文件行的 `dir_id` 全是空串、或者
  /// 它名下一条 `media_items` 都没有）。这时**不能**推进它的水位线 ——
  /// 我们什么都没检查，推进等于凭空宣称「查过了」。
  ///
  /// 代价是它每次都会被重新考虑一遍，但那是零成本的：没有目录就一次网盘
  /// 请求都不发。而反过来（推进）会让它**永远**不再被检查。
  Set<String> checkedWorks(Set<String> failedDirs) {
    final out = <String>{};
    for (final e in dirsByWork.entries) {
      var ok = true;
      for (final dirId in e.value) {
        if (failedDirs.contains(dirId)) {
          ok = false;
          break;
        }
      }
      if (ok) out.add(e.key);
    }
    return out;
  }

  /// 这次要发多少个列目录请求（= [dirs] 的长度）。
  int get requestCount => dirs.length;

  @override
  String toString() => 'FollowPlan(目录 ${dirs.length}，作品 ${dirsByWork.length})';
}
