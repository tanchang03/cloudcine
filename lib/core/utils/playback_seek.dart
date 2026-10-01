/// 把「想跳到的位置」夹进合法范围。
///
/// ## 为什么必须有这一层，而不是把算出来的位置直接交给播放器
///
/// mpv 收到一个超出文件范围的位置时**不会报错**，它会跳到那个不存在的位置然后
/// 停在那儿 —— 表现是「连按几下右键，画面卡住不动了，进度条也不走了」。
/// 比不跳更糟：用户会以为播放器挂了，而实际上只是位置非法。
///
/// ## 为什么总时长未知时不夹上界
///
/// 文件头还没解出来时 `total` 是 `Duration.zero`，那一刻**没有上界可夹**。
/// 硬夹的话位置会被压回 0 —— 表现是「刚开播按一下右键，进度条归零」。
/// 下界不受影响，任何时候都夹。
///
/// ## 为什么单独成一个函数
///
/// 起播有两条完全独立的路径：内置播放页（`PlaybackController`）与独立播放窗口
/// （`PlayerWindowApp`，跑在自己的 Flutter 引擎里，够不到 `PlaybackController`）。
/// 两处各写一遍夹取，迟早会漂移成「窗口里按左键能退到负数、播放页里不会」——
/// 而漂移之后不会有任何报错，只是其中一个入口行为不对。
Duration clampSeekTarget(Duration target, Duration total) {
  var t = target;
  if (t < Duration.zero) t = Duration.zero;
  if (total > Duration.zero && t > total) t = total;
  return t;
}
