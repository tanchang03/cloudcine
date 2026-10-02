import '../entities/media_work.dart';

/// 一次「折叠」的完整计划：把 [sourceKeys] 这几行折叠进 [targetKey]。
///
/// 计划是**纯数据**，不含任何副作用 —— 真正落库的是
/// `MediaRepository.mergeWorksInto`。这样「谁该并进谁」这条最容易出错的
/// 判断可以脱离数据库单测。
class WorkMergePlan {
  const WorkMergePlan({
    required this.targetKey,
    required this.sourceKeys,
    required this.onlineId,
  });

  /// **人工指定**的折叠：依据是用户，不是刮削身份。
  ///
  /// 与自动那条路的唯一区别是「凭什么说这两部是同一部」——
  /// 自动只认 `onlineId`，而本地片名差异大、压根没刮到、刮到两个不同条目
  /// 但其实是同一部这三种情况，只有人能判断。落库动作完全一样。
  const WorkMergePlan.manual({
    required this.targetKey,
    required this.sourceKeys,
  }) : onlineId = '';

  /// 留下的那一部（列表里能看到的）。
  final String targetKey;

  /// 被折叠走的那几部（列表里不再出现，行本身保留）。
  ///
  /// **有序且不含 [targetKey]** —— 顺序按 [WorkMergePlanner] 的确定性
  /// 排序给出，好让日志与测试可以逐字比对。
  final List<String> sourceKeys;

  /// 把它们认成同一部的依据（`tv/12345` / `douban/movie/678`）。
  ///
  /// **空串表示「人工指定」**（见 [WorkMergePlan.manual]）—— 人工合并没有
  /// 一个「依据 id」，硬塞一个假 id 只会让日志里出现一行看不懂的东西。
  final String onlineId;

  /// 这次折叠是人点的还是算法算的（日志文案分两路）。
  bool get isManual => onlineId.isEmpty;

  int get mergedCount => sourceKeys.length;

  @override
  String toString() => 'WorkMergePlan($targetKey ← ${sourceKeys.join(",")} '
      'by ${isManual ? "手动" : onlineId})';
}

/// 判断「哪几部作品其实是同一部」—— **纯函数，不碰数据库**。
///
/// ## 唯一的依据是 `onlineId`
///
/// 本地文件名解析出的归组键（`groupKey`）已经把大部分情况归好了：同一目录
/// 下的 `S01E01` / `S01E02` 天然同组。剩下归不了的是**跨目录**那批 ——
/// `/电影/流浪地球2/` 和 `/电影/The.Wandering.Earth.II.2023/` 是两部片子，
/// 只有刮削才能告诉我们它们是同一部。
///
/// 刮削给出的身份就是 [MediaWork.onlineId]（TMDB `movie/843527`、豆瓣
/// `douban/tv/12345`），所以这里只按它分组。**按片名做模糊匹配是绝不做的**
/// —— 那正是 `182.格力空调` 那次事故的形态（纯数字前缀把「182」和「1821」
/// 认成一部），而且一旦合错就是两部不相干的片子被揉进一个格子。
///
/// ## 四条硬约束（做错都是静默坏数据）
///
///   1. **只认 `source == online`**。本地解析出的两行（都还没刮到）即使
///      `onlineId` 都为空也不会进任何分组 —— 空值不参与分组，所以这条
///      其实是「`onlineId` 必须非空」的推论，但两个条件都显式写出来，
///      因为将来若有人给本地行填上某种「伪 id」，只判非空就会放行。
///   2. **`source == manual` 的行不参与**（用户手写过片名/分类的东西不许被
///      算法动）。这一条被第 1 条蕴含，但它值得单独存在：它是**产品规则**，
///      不是实现细节。
///   3. **同一个 `onlineId` 里 `kind` 必须一致**。正常不会冲突（TMDB 的 id
///      本身就带 `tv/` `movie/` 前缀），但真出现冲突时**不合并**比合错好。
///   4. **已经被折叠走的行（`mergedInto != null`）不再参与**，也**不能当
///      目标** —— 否则会形成链（A←B←C），而链上的中间节点被单独撤销就会
///      把后面的节点孤儿化。
///
/// ## 目标怎么选
///
/// 「文件最多的那个」当目标。理由：目标的海报/简介会被留下，而文件多的
/// 那一部更可能是用户平时在看的那一部（另一部往往只扫到一两个散文件）。
/// 并列时取 `firstSeenAt` 更早的（先入库的那个是「老住户」），再并列时
/// 按 `key` 升序 —— 这一层是为了**确定性**：没有它，同一个库两次运行
/// 可能选出不同的目标，而用户会看到海报在两部片子之间来回跳。
abstract final class WorkMergePlanner {
  /// 全库扫一遍，给出所有该执行的折叠计划。
  ///
  /// 返回的顺序按 `onlineId` 升序，组内 [WorkMergePlan.sourceKeys] 也升序
  /// —— 纯函数的意义就在于「同样的输入永远给出同样的输出」。
  static List<WorkMergePlan> plan(List<MediaWork> works) {
    // 分组键用 `onlineId\u0000kind`：把约束 3 做进键里，比事后检查更
    // 不容易漏（一个 `if` 忘了写就会把电影和剧集合起来）。
    final buckets = <String, List<MediaWork>>{};
    for (final w in works) {
      if (w.source != ScrapeSource.online) continue;
      if (w.source == ScrapeSource.manual) continue;
      final id = (w.onlineId ?? '').trim();
      if (id.isEmpty) continue;
      if (w.isMergedAway) continue;
      buckets.putIfAbsent('$id\u0000${w.kind.name}', () => []).add(w);
    }

    final plans = <WorkMergePlan>[];
    for (final entry in buckets.entries) {
      if (entry.value.length < 2) continue;
      final id = entry.key.split('\u0000').first;
      final ordered = [...entry.value]..sort(_byPreference);
      final target = ordered.first;
      final sources = ordered.skip(1).map((w) => w.key).toList()..sort();
      plans.add(
        WorkMergePlan(
          targetKey: target.key,
          sourceKeys: sources,
          onlineId: id,
        ),
      );
    }

    plans.sort((a, b) {
      final byId = a.onlineId.compareTo(b.onlineId);
      return byId != 0 ? byId : a.targetKey.compareTo(b.targetKey);
    });
    return plans;
  }

  /// 只关心 [key] 那一部：它在哪个计划里（作为目标或源）？
  ///
  /// 刮削完一部之后没必要把全库重算一遍的**判断**部分 —— 但调用方仍需
  /// 拿到全库列表（要比较的是所有行的 `onlineId`）。这个方法存在的价值
  /// 是「别在服务层重写一遍筛选规则」。
  static WorkMergePlan? planFor(String key, List<MediaWork> works) {
    for (final p in plan(works)) {
      if (p.targetKey == key || p.sourceKeys.contains(key)) return p;
    }
    return null;
  }

  /// 全库里和 [work] 刮到**同一条目**的那一部（`null` = 没有这样的兄弟）。
  ///
  /// ## 它和 [planFor] 的关系：同一条判据的两个出口
  ///
  /// 刮削完成后要告诉用户「库里是不是已经有这一部了」。**必须**复用
  /// [plan] 的分组规则（这里走 [planFor]），不能另写一套「按 `onlineId`
  /// 找一行」的筛法 —— 两套判据一旦漂移，就会出现「提示说库里已经有一部，
  /// 而归一一个都没合」，用户看到的是「它明明说并了，列表里却还是两个格子」。
  ///
  /// ## 返回哪一部
  ///
  ///   - [work] 是被折走的源（它自己是目标）→ 返回目标那一部；
  ///   - [work] 是目标（它折着别人）→ 返回第一个源。
  ///
  /// 返回值的用途只有一个：把**片名**拼进给用户看的那句话里。所以「挑哪
  /// 一个兄弟」不影响正确性，只影响那句话读起来顺不顺。
  ///
  /// [work] 必须是**根**（`mergedInto == null`）：别名行不参与归一，也不该
  /// 被当成「有兄弟」—— 它本来就已经并进别处了。
  static MediaWork? siblingOf(MediaWork work, List<MediaWork> works) {
    final plan = planFor(work.key, works);
    if (plan == null) return null;
    final byKey = {for (final w in works) w.key: w};
    if (plan.targetKey != work.key) return byKey[plan.targetKey];
    for (final k in plan.sourceKeys) {
      final s = byKey[k];
      if (s != null) return s;
    }
    return null;
  }

  /// 排序偏好：文件多的在前；并列时入库早的在前；再并列按 key 升序。
  ///
  /// `firstSeenAt == null` 视为「最晚」（排到最后）：老库升级上来的行可能
  /// 没有这个值，而「没有记录」不该赢得「有记录」。
  static int _byPreference(MediaWork a, MediaWork b) {
    final byCount = b.itemCount.compareTo(a.itemCount);
    if (byCount != 0) return byCount;

    final fa = a.firstSeenAt;
    final fb = b.firstSeenAt;
    if (fa == null && fb != null) return 1;
    if (fa != null && fb == null) return -1;
    if (fa != null && fb != null) {
      final bySeen = fa.compareTo(fb);
      if (bySeen != 0) return bySeen;
    }
    return a.key.compareTo(b.key);
  }

  /// **人工合并**前的校验：`null` = 可以合，否则是给用户看的一句原因。
  ///
  /// ## 为什么必须是纯函数、且要能被 UI 提前调用
  ///
  /// 对话框要在用户**还没点确认之前**就把「这一部合不了」写在按钮旁边
  /// （按钮变灰 + 一句原因），而不是等他点了才弹一个错误。同一套判据在
  /// 对话框和 `WorkMergeService.mergeInto` 里各写一遍的话，迟早会出现
  /// 「按钮亮着、点了却什么都不发生」—— 而那看起来就像应用坏了。
  ///
  /// ## 三条判据（前两条是「不可能」，第三条是真会撞上的）
  ///
  ///   1. **不能自己并自己**；
  ///   2. **目标不能已经是别名行** —— 把别名当目标会形成链（A←B←C），
  ///      而链上任何一环被单独撤销都会把后面的节点孤儿化；
  ///   3. **源自己不能已经有折叠进来的作品**。这一条是真会撞上的：
  ///      自动归一刚把两部片子合到《X》上，用户又想把《X》并进《Y》。
  ///      这时正确的动作是先在《X》的详情页把那些「拆开」再合 ——
  ///      **不做「连坐迁移」**（把 X 的源一起改指 Y），因为那样撤销就
  ///      无法精确还原：X 的那些源原本指向 X，撤完却会变成独立的根。
  ///
  /// [all] 只需要能查出「谁折进了谁」，传全库（`allWorks()`）即可。
  static String? manualBlocker({
    required MediaWork source,
    required MediaWork target,
    required List<MediaWork> all,
  }) {
    if (source.key == target.key) {
      return '不能把一部作品并到它自己。';
    }
    if (target.isMergedAway) {
      return '《${target.title}》已经被并进别的作品了，不能再当合并的目标。';
    }
    if (source.isMergedAway) {
      return '《${source.title}》已经被并进别的作品了 —— '
          '先在那一部的详情页里点「拆开」，再回来合并。';
    }
    final folded = all.where((w) => w.mergedInto == source.key).length;
    if (folded > 0) {
      return '《${source.title}》自己已经并入了 $folded 部作品 —— '
          '先在它自己的详情页点「拆开」，再把它并到别处。';
    }
    return null;
  }

  /// **批量**人工合并的校验：把 [sources] 这几部一起折进 [target]。
  ///
  /// ## 它不是「循环调 [manualBlocker]」的薄包装
  ///
  /// 差别只有一处，但那一处正是批量这条通道存在的理由：**目标自己可以出现
  /// 在 [sources] 里**。用户在海报墙上勾了 5 部片子再点「合并到…」，最自然
  /// 的下一步就是从这 5 部里挑一部当留下的那个 —— 而 [manualBlocker] 的第一
  /// 条判据就是「不能自己并自己」，直接循环会把目标自己算成一条「合不了」，
  /// 底部出现一句莫名其妙的红字。
  ///
  /// ## 为什么被拦的**不许整批放弃**
  ///
  /// 返回 [WorkMergeBatchPlan.blocked] 而不是直接拒绝，是为了让 UI 能说
  /// 「这 5 部里有 1 部合不了（原因…），其余 4 部照常合并」。整批放弃的表现
  /// 是「我勾了 5 部，点完什么都没发生，只弹一句错误」—— 而那句错误说的
  /// 还是用户没勾过的那部片子的问题，他根本无从下手。
  ///
  /// 反过来，**可合的一部都没有时要如实返回空**，由服务层判断「这次没做成」。
  static WorkMergeBatchPlan batchPlan({
    required MediaWork target,
    required List<MediaWork> sources,
    required List<MediaWork> all,
  }) {
    final mergeable = <String>{};
    final blocked = <String, String>{};

    for (final source in sources) {
      // 目标自己 = 留下的那一部，不算「被折走」。
      if (source.key == target.key) continue;
      final reason = manualBlocker(source: source, target: target, all: all);
      if (reason != null) {
        blocked[source.key] = reason;
      } else {
        mergeable.add(source.key);
      }
    }

    return WorkMergeBatchPlan(
      targetKey: target.key,
      sourceKeys: mergeable.toList()..sort(),
      blocked: blocked,
    );
  }
}

/// 一次**批量**合并的校验结果：哪些能合、哪些不能、为什么。
///
/// 纯数据、不含副作用 —— 与 [WorkMergePlan] 同一条理由：判断可以脱离数据
/// 库单测，而对话框要在用户**点确认之前**就把结果显示在按钮旁边。
class WorkMergeBatchPlan {
  const WorkMergeBatchPlan({
    required this.targetKey,
    this.sourceKeys = const [],
    this.blocked = const {},
  });

  /// 留下的那一部。
  final String targetKey;

  /// 这次会被折走的（按 `key` 升序，保证日志与测试可逐字比对）。
  final List<String> sourceKeys;

  /// 折不了的：`key` → 给用户看的一句原因。
  final Map<String, String> blocked;

  bool get canMerge => sourceKeys.isNotEmpty;

  int get blockedCount => blocked.length;

  @override
  String toString() => 'WorkMergeBatchPlan($targetKey ← ${sourceKeys.join(",")}，'
      '${blocked.length} 部合不了)';
}
