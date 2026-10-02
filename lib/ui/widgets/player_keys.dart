import 'package:flutter/services.dart';

/// 播放器**共用**的数字键表：数字键 → 目标位置比例（`0.0`–`0.9`）。
///
/// ## 为什么要有「跳到 N%」
///
/// TV 上没有可拖的进度条 —— 遥控器的方向键拖不动滑块（实测，见
/// `docs/AndroidTV-遥控器体验评估.md` §5.5），长按快进再快也要按十几下才挪到
/// 片子中间。数字键是**一步到位**的唯一手段，而电视遥控器本来就带数字键，
/// 白放着不用。
///
/// 约定沿用老式影碟机 / 电视的习惯：`0` 开头、`5` 一半、`9` 九成。
///
/// ## 为什么不提供「跳到结尾」
///
/// 用户真正想按的是「不看了」，那件事的入口是返回键 —— 跳到结尾只会立刻
/// 触发播完退出，看起来像应用崩了。
///
/// ## 为什么这张表要共享
///
/// 两个播放器各有一张键位表（内置播放页走遥控器键、独立播放窗口走桌面键）。
/// 键位表本身必须各写一份（输入模型不同），但**「哪个键算数字几」是同一件事**
/// —— 各写一份的结果是「一个播放器认小键盘、另一个不认」，而用户只会觉得
/// 「这个键有时灵有时不灵」。
///
/// ⚠️ 主键盘 `digitN` 与小键盘 `numpadN` **都要认**：遥控器的数字键实测映射到
/// `digitN`（与物理键盘同一个键码），但不少电视盒子 / 手柄把小键盘键报上来。
/// 少认一半就是「有的遥控器按 5 没反应」，而那台遥控器在开发机上永远不出现。
final Map<LogicalKeyboardKey, int> seekDigitKeys = {
  LogicalKeyboardKey.digit0: 0,
  LogicalKeyboardKey.digit1: 1,
  LogicalKeyboardKey.digit2: 2,
  LogicalKeyboardKey.digit3: 3,
  LogicalKeyboardKey.digit4: 4,
  LogicalKeyboardKey.digit5: 5,
  LogicalKeyboardKey.digit6: 6,
  LogicalKeyboardKey.digit7: 7,
  LogicalKeyboardKey.digit8: 8,
  LogicalKeyboardKey.digit9: 9,
  LogicalKeyboardKey.numpad0: 0,
  LogicalKeyboardKey.numpad1: 1,
  LogicalKeyboardKey.numpad2: 2,
  LogicalKeyboardKey.numpad3: 3,
  LogicalKeyboardKey.numpad4: 4,
  LogicalKeyboardKey.numpad5: 5,
  LogicalKeyboardKey.numpad6: 6,
  LogicalKeyboardKey.numpad7: 7,
  LogicalKeyboardKey.numpad8: 8,
  LogicalKeyboardKey.numpad9: 9,
};

/// 这个键是不是数字键。
bool isSeekDigit(LogicalKeyboardKey key) => seekDigitKeys.containsKey(key);

/// 数字键对应的目标位置比例（`0.0`–`0.9`）；不是数字键则 `null`。
double? seekFractionForKey(LogicalKeyboardKey key) {
  final digit = seekDigitKeys[key];
  return digit == null ? null : digit / 10;
}
