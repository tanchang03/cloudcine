/// 自动追更检查的策略。
///
/// 取值与 Android 端 `library/FollowAutoCheck.kt` **逐字一致**（`off` /
/// `on_launch` / `every_6h`），因为它存在 `settings` 表的
/// `follow_auto_check` 键里、随 `.ccbak` 备份包跨端走 —— 在电脑上选了
/// 「关闭」，电视上不该还在偷偷发请求。
///
/// ## 与「节流窗口」的分工
///
/// 这个枚举回答「**什么时候想起来要检查**」，节流窗口回答「**检查得够不够密**」。
/// 两者不能互相替代：
///
///   * 没有窗口，`on_launch` 会在用户每次重启 App 时都跑一遍；
///   * 没有这个枚举，`off` 就表达不出来（窗口没法表达「永不」）。
///
/// | 取值 | 启动时 | 定时 | 节流窗口 |
/// |---|---|---|---|
/// | [off] | 否 | 否 | — |
/// | [onLaunch]（默认） | 是 | 否 | 6 小时 |
/// | [every6h] | 是 | 每 6 小时 | 6 小时 |
///
/// ⚠️ [onLaunch] 与 [every6h] 的窗口**相同**，差别只在定时器：前者在
/// 一次会话里只检查一次（长时间挂着也不重复发请求），后者会周期性检查。
/// 这不是笔误 —— 「每次开机查一下」和「一直挂着也要查」是两个真实诉求。
///
/// ## 手动入口无视这一切
///
/// 用户点「检查更新」时不看窗口、也不看这里是不是 `off`：他明确要求了。
enum FollowAutoCheck {
  /// 不自动检查（手动入口仍然可用）。
  off('off', '关闭'),

  /// 启动时检查一次（受节流窗口约束）。
  onLaunch('on_launch', '启动时检查'),

  /// 启动时 + 每 6 小时各检查一次。
  every6h('every_6h', '每 6 小时检查');

  const FollowAutoCheck(this.id, this.label);

  /// 落库的字符串（`settings` 表里的值）。
  final String id;

  /// 设置页上的中文标签。
  final String label;

  /// 自动检查的节流窗口。`null` = **不节流**。
  ///
  /// ## ⛔ `null` 不是「不检查」
  ///
  /// 它是「两次检查之间不设最小间隔」，含义是**想跑就跑**。而 [off] 的含义是
  /// 「不要自动跑」—— 两者恰好相反，所以 [off] 那一个 `null` **不能**被调用方
  /// 当成闸门用：`FollowService._run` 里必须先显式判 `policy == off` 再读这个值。
  ///
  /// 只靠这个值挡的话，设成「关闭」之后反而一次节流判断都不做 ⇒ 每次启动都
  /// 真的去列网盘目录。症状是「我明明关了自动检查，它还在发请求」。
  ///
  /// ⚠️ 手动入口**不要**用这个值做判断（见类文档最后一条）。
  Duration? get throttleWindow => switch (this) {
        FollowAutoCheck.off => null,
        FollowAutoCheck.onLaunch => const Duration(hours: 6),
        FollowAutoCheck.every6h => const Duration(hours: 6),
      };

  /// 是否要在会话里挂一个周期定时器。
  bool get runsOnTimer => this == FollowAutoCheck.every6h;

  /// 解析设置值。
  ///
  /// ⛔ 判据**只写在这里一处**：`null`（老库没有这个键）、空串、写坏的值、
  ///    将来被改名的取值，一律退回 [onLaunch]。在别处再写一遍
  ///    `== 'on_launch'` 只会多出一份会漂移的默认值真源 ——
  ///    而漂移的后果是「用户在设置页选了关闭，重启之后又开始检查了」。
  static FollowAutoCheck parse(String? raw) => switch (raw) {
        'off' => FollowAutoCheck.off,
        'every_6h' => FollowAutoCheck.every6h,
        _ => FollowAutoCheck.onLaunch,
      };
}
