import '../../core/diagnostics/diag_log.dart';
import '../adapters/media_repository.dart';
import '../entities/media_work.dart';
import 'work_merge_planner.dart';

/// 一次折叠**实际做完之后**的凭据 —— 调用方拿它做提示与撤销。
class WorkMergeResult {
  const WorkMergeResult({
    required this.plan,
    required this.targetTitle,
    required this.sourceTitles,
    required this.changed,
  });

  final WorkMergePlan plan;

  /// 留下的那一部的片名（提示里说「已并入《XXX》」用）。
  final String targetTitle;

  /// 被折走的几部的片名，与 `plan.sourceKeys` 一一对应。
  final List<String> sourceTitles;

  /// 实际改动的行数。**可能小于** `plan.sourceKeys.length` —— 期间有人
  /// 手动撤销过、或那一行已经被别的流程折走了。用 0 判断「什么都没发生」。
  final int changed;

  /// 面向用户的一句话。
  ///
  /// 两个通道的说法**必须不同**：自动那条是「识别为同一条目」（用户没发起，
  /// 得告诉他程序凭什么合），手动那条是「已把 X 并入 Y」（是他自己点的，
  /// 再说一遍「识别为同一条目」只会让人以为程序又擅自判断了一次）。
  String get message {
    final src = sourceTitles.map((t) => '《$t》').join('、');
    return plan.isManual
        ? '已把 $src 并入《$targetTitle》。'
        : '已把 $src 并入《$targetTitle》（识别为同一条目）。';
  }

  @override
  String toString() => 'WorkMergeResult(changed=$changed, $plan)';
}

/// 跨目录**自动归一**：把刮到同一条目的几部作品折成一部。
///
/// ## 它为什么值得单独存在
///
/// 「哪几部该合」的判断在 [WorkMergePlanner]（纯函数、有单测），落库在
/// `MediaRepository.mergeWorksInto`。这个类只做中间那一层：**把两边接起来，
/// 并且留下痕迹**。
///
/// ## 留痕是硬要求，不是可选项
///
/// 自动归一会在用户毫无察觉的时候让两个格子变成一个。没有日志的话，他
/// 唯一能观察到的现象是「我的电影少了一部」，而**任何排查都无从下手** ——
/// 所以每次折叠都写一条 `diag.info`，把「哪两个 key、按什么 id 合的」
/// 记全。
///
/// ## 为什么「全库重算」是安全的
///
/// [mergeAll] 每次读全库重新算计划，而不是「只处理这次刮削的那一部」。
/// 多花的那一次全表读（几百行）换来的性质很重要：**规则改了之后重跑一次
/// 就能收敛**，不需要用户把每一部重新刮一遍。
///
/// 反过来，[mergeFor] 那个「只看这一部」的入口是给刮削后即时反馈用的
/// —— 用户刚点完「刮削」，不希望等一次全库扫描才看到归一。
class WorkMergeService {
  WorkMergeService({
    required MediaRepository library,
    DiagLog? log,
  })  : _library = library,
        _log = log ?? diag;

  final MediaRepository _library;
  final DiagLog _log;

  /// 全库跑一遍归一，返回**实际发生了的**折叠（已合并过的不重复出现）。
  ///
  /// **永不抛异常**：归一是扫描 / 刮削之后的「锦上添花」，它失败不该让
  /// 用户看到「扫描失败」。异常降级成一条 `diag.warn`。
  Future<List<WorkMergeResult>> mergeAll() async {
    try {
      final works = await _library.allWorks();
      final plans = WorkMergePlanner.plan(works);
      if (plans.isEmpty) return const [];

      final byKey = {for (final w in works) w.key: w};
      final done = <WorkMergeResult>[];
      for (final plan in plans) {
        final result = await _execute(plan, byKey);
        if (result != null) done.add(result);
      }
      if (done.isNotEmpty) {
        _log.info(
          '归一',
          '本次折叠 ${done.length} 组，共 ${done.fold(0, (n, r) => n + r.changed)} 部作品',
        );
      }
      return done;
    } catch (e) {
      _log.warn('归一', '全库归一出错，本次跳过', error: e);
      return const [];
    }
  }

  /// 只看 [key] 那一部：它和别的作品刮到了同一条目吗？
  ///
  /// 返回 `null` 表示「这一部没有可归一的兄弟」—— 包括它自己就是被别人
  /// 折走的别名行（那种情况下它不该再当目标）。
  Future<WorkMergeResult?> mergeFor(String key) async {
    try {
      final works = await _library.allWorks();
      final plan = WorkMergePlanner.planFor(key, works);
      if (plan == null) return null;
      final byKey = {for (final w in works) w.key: w};
      return await _execute(plan, byKey);
    } catch (e) {
      _log.warn('归一', '$key 归一出错，本次跳过', error: e);
      return null;
    }
  }

  /// **人工**把 [sourceKey] 折进 [targetKey]。
  ///
  /// ## 与 [mergeAll] / [mergeFor] 的分工
  ///
  /// 那两个由 [WorkMergePlanner] 决定「谁并进谁」，这里**完全由人指定** ——
  /// 自动那条路只认 `onlineId`，而本地片名差异大（`流浪地球2` vs
  /// `The Wandering Earth II`）、压根没刮到、或刮到两个不同条目但其实是
  /// 同一部这三种情况，只有人能判断。
  ///
  /// ## 目标由**用户选中**，不是「当前作品」
  ///
  /// 按钮写的是「合并**到**…」，所以选中哪一部，列表里就留下哪一部，
  /// 当前这一部变成别名行。方向搞反的代价是「用户想留的那部消失了」——
  /// 好在这条路是可逆的（目标页上有一条常驻的「已并入…／拆开」提示），
  /// 而且对话框在确认前会把方向写清楚。
  ///
  /// 返回 `null` 表示这次没做成：两个 key 有一个不在库里、或撞上
  /// [WorkMergePlanner.manualBlocker] 的任一条。**不抛异常** —— 它是在
  /// 一个对话框的确认按钮后面跑的，抛出去只会变成一句「未知错误」。
  Future<WorkMergeResult?> mergeInto({
    required String targetKey,
    required String sourceKey,
  }) async {
    try {
      final works = await _library.allWorks();
      final byKey = {for (final w in works) w.key: w};
      final source = byKey[sourceKey];
      final target = byKey[targetKey];
      if (source == null || target == null) return null;
      if (WorkMergePlanner.manualBlocker(
            source: source,
            target: target,
            all: works,
          ) !=
          null) {
        return null;
      }
      return await _execute(
        WorkMergePlan.manual(targetKey: targetKey, sourceKeys: [sourceKey]),
        byKey,
      );
    } catch (e) {
      _log.warn('归一', '手动合并 $sourceKey → $targetKey 出错', error: e);
      return null;
    }
  }

  /// **人工**把 [sourceKeys] 这几部一起折进 [targetKey]。
  ///
  /// ## 与 [mergeInto] 的关系：同一个动作，一次做完
  ///
  /// 逐个循环调 [mergeInto] 也能得到一样的结果，但那会给每一部都读一次
  /// 全库（`allWorks`）—— 勾 20 部就是 20 次全表读，而这本来是一次点击。
  /// 更关键的是那样做**没有原子性可言**：中途某一部失败，剩下的状态是
  /// 「合了一半」，用户看到的是「我勾了 5 部，只有 3 部不见了」。
  ///
  /// 所以这里只读一次全库，用 [WorkMergePlanner.batchPlan] 把能合的挑出来，
  /// 再**一次** `mergeWorksInto` 落库。
  ///
  /// ## 合不上的那些**不拖累其余的**
  ///
  /// 校验在 [WorkMergePlanner.batchPlan] 里逐个做，被拦的进 `blocked`
  /// 而不是让整批失败。返回 `null` 只表示「一部都合不了」—— 那种情况下
  /// 调用方该弹的是「这几部合不上去」而不是「合并失败」。
  Future<WorkMergeResult?> mergeManyInto({
    required String targetKey,
    required List<String> sourceKeys,
  }) async {
    try {
      final works = await _library.allWorks();
      final byKey = {for (final w in works) w.key: w};
      final target = byKey[targetKey];
      if (target == null) return null;

      final sources = [
        for (final k in sourceKeys)
          if (byKey[k] != null) byKey[k]!,
      ];
      final plan = WorkMergePlanner.batchPlan(
        target: target,
        sources: sources,
        all: works,
      );
      if (!plan.canMerge) return null;

      return await _execute(
        WorkMergePlan.manual(
          targetKey: targetKey,
          sourceKeys: plan.sourceKeys,
        ),
        byKey,
      );
    } catch (e) {
      _log.warn(
        '归一',
        '批量合并 ${sourceKeys.length} 部 → $targetKey 出错',
        error: e,
      );
      return null;
    }
  }

  /// 撤销一次折叠。返回实际改回独立状态的行数。
  ///
  /// 撤销**不需要**计划：它就是把这几行的 `merged_into` 清掉。所以即使
  /// 后来规则变了、[WorkMergePlanner] 再也不认为它们该合，用户手上那条
  /// 历史记录里的「撤销」按钮依然点得动。
  Future<int> undo(List<String> sourceKeys) async {
    try {
      final n = await _library.unmergeWorks(sourceKeys);
      if (n > 0) {
        _log.info('归一', '撤销折叠：${sourceKeys.join("、")} 恢复为独立作品');
      }
      return n;
    } catch (e) {
      _log.warn('归一', '撤销折叠失败', error: e);
      return 0;
    }
  }

  Future<WorkMergeResult?> _execute(
    WorkMergePlan plan,
    Map<String, MediaWork> byKey,
  ) async {
    final changed = await _library.mergeWorksInto(plan.targetKey, plan.sourceKeys);
    if (changed == 0) return null;

    final target = byKey[plan.targetKey];
    final titles = [
      for (final k in plan.sourceKeys)
        if (byKey[k] != null) byKey[k]!.title,
    ];
    _log.info(
      '归一',
      '按 ${plan.isManual ? "手动指定" : plan.onlineId} 合并：'
          '${plan.sourceKeys.join("、")} → ${plan.targetKey}'
          '（${target?.title ?? "?"}）',
    );
    return WorkMergeResult(
      plan: plan,
      targetTitle: target?.title ?? plan.targetKey,
      sourceTitles: titles,
      changed: changed,
    );
  }
}
