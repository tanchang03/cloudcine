/// 长按 / 连按快退快进的**步长累加**。
///
/// ## 为什么需要累加，而不是固定 10 秒
///
/// 固定 10 秒时：跳过片头（约 90 秒）要按 9 下，跳到片子中间要按几百下。
/// 于是用户干脆不按了，宁可去拖进度条 —— 而**电视上没有进度条可拖**
/// （遥控器的方向键拖不动它，见 `docs/AndroidTV-遥控器体验评估.md` §5.5）。
/// 也就是说这一条在 TV 上不是「更顺手」，而是「除数字键之外唯一的长距离
/// 移动手段」。
///
/// ## 为什么判据是「连了几次」而不是「按住了多久」
///
/// 硬件重复 keydown 的间隔由设备决定（实测 Android TV 约 50ms、桌面约 33ms），
/// 拿它当「长按」的判据会把「用户手快连点三下」也算成一串。所以真正的判据是
/// **连续性**：同方向，且两次之间不超过 [seekHoldGap]，才算同一串。
///
/// 这样做的代价是「手快连点」的第二下会比预期跳得远一点 —— 那只是不精确，
/// 不会出错（用户看到时间码，按多了再按回来就是）。反过来把长按判丢，
/// 就成了「按住没反应」。
library;

/// 一串「同方向、连续」的按键之间允许的最大间隔。
///
/// 700ms 是折中：
///   * 长按时的硬件重复间隔（33–50ms）远小于它 → 长按**不会**被判成新的一串；
///   * 人手连点两下的间隔普遍在 250–400ms，也小于它 → 会被算成同一串。
///     这正是上面说的「代价只是不精确」，而它在 TV 上更划算：遥控器的
///     硬件重复本来就慢，门槛取小了会让长按断断续续。
const Duration seekHoldGap = Duration(milliseconds: 700);

/// 第 [streak] 次连续快退/快进的步长（`streak` 从 0 起算）。
///
/// 10 秒起步（微调：用户多半只想跳过片头曲），到 5 分钟封顶。
/// **封顶不再更大**是因为「跳到大概那个位置」有更准的工具：数字键跳百分比
/// （见 `player_keys.dart` 的 `seekFractionForKey`）。5 分钟已经够覆盖
/// 「一整集 45 分钟里挪四分之一」，再大就只剩「蒙」了。
Duration seekStepFor(int streak) {
  if (streak < 3) return const Duration(seconds: 10);
  if (streak < 6) return const Duration(seconds: 30);
  if (streak < 10) return const Duration(seconds: 60);
  return const Duration(seconds: 300);
}

/// 连按 / 长按的步长累加器。
///
/// **两个播放器各持有一个**：内置播放页跑在主引擎、独立播放窗口跑在另一个
/// Flutter 引擎里，状态共享不了（与 `clampSeekTarget` 同一个理由）。
/// 共享的只能是这份算法本身。
///
/// 时间从 [_now] 取而不是直接读 `DateTime.now()` —— 判据是「间隔」，
/// 不注入时钟就没法测。
class SeekRepeatTracker {
  SeekRepeatTracker({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  int _streak = 0;

  /// `-1` 快退 / `+1` 快进 / `0` 还没按过。
  int _direction = 0;
  DateTime? _lastAt;

  /// 记一次按键，返回**这一步**该跳多少。
  ///
  /// [direction]：负数 = 快退，正数 = 快进。符号以外的量级不参与判断 ——
  /// 调用方传 `-1` / `+1` 就好。
  Duration step(int direction) {
    final dir = direction < 0 ? -1 : 1;
    final at = _now();
    final last = _lastAt;
    final continuous = last != null &&
        dir == _direction &&
        at.difference(last) <= seekHoldGap;

    // 第一下算 streak 0（10 秒）—— 用户按一下就是想要一个 10 秒。
    _streak = continuous ? _streak + 1 : 0;
    _direction = dir;
    _lastAt = at;
    return seekStepFor(_streak);
  }

  /// 松手 / 换了别的键 / 跳了别处 —— 下一串从头算。
  ///
  /// ⚠️ 桌面播放器的键位表走 `CallbackShortcuts`，**收不到 key-up**，
  /// 所以那边只能靠 [seekHoldGap] 自动断开；内置播放页走 `Focus.onKeyEvent`，
  /// 松手时能显式调到这里。两条路的结果一致，只是精度差一点。
  void reset() {
    _streak = 0;
    _direction = 0;
    _lastAt = null;
  }

  /// 当前这一串已经连了几下（只给测试看）。
  int get streak => _streak;
}
