import 'package:cloudcine/ui/pages/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 控制栏「无操作收起」的判据。
///
/// 2026-10-05 起判据收成两条：`!immersive && playing`。原来的第三条
/// `stageFocused`（焦点必须在画面）被删掉 —— 遥控器用 OK 暂停 / 恢复播放
/// 时焦点**停留在控制栏按钮上**而不是画面，于是「暂停 → 恢复播放」之后
/// `stageFocused` 恒为 false，控制栏**永远不自动收起**（用户看到的就是
/// 「暂停再播放后控制栏一直挂着」）。去掉它之后，只要在播放且非沉浸，
/// 30 秒无操作就收起。
///
/// ⚠️ `stageFocused` 参数保留在签名里（调用点仍传），但**不再参与判据**。
void main() {
  test('播放中、还没藏 → 该藏（不管焦点在不在画面）', () {
    expect(
      shouldAutoHideControls(immersive: false, playing: true, stageFocused: true),
      isTrue,
      reason: '遥控器静置，该只剩画面',
    );
    // ⚠️ 焦点在控制栏按钮上（遥控器 OK 暂停/恢复后的常态）同样该藏 ——
    // 这正是修掉的问题：否则「暂停再播放后控制栏一直挂着」。
    expect(
      shouldAutoHideControls(immersive: false, playing: true, stageFocused: false),
      isTrue,
      reason: '恢复播放后 30 秒无操作就该收起，焦点在哪不再决定它',
    );
  });

  test('已经沉浸（控制栏已藏）→ 不该再藏', () {
    expect(
      shouldAutoHideControls(immersive: true, playing: true, stageFocused: true),
      isFalse,
      reason: '已经藏了，再藏一次是空操作，只会让定时器反复触发',
    );
  });

  test('暂停时 → 不该藏（用户多半在读字幕 / 调设置）', () {
    expect(
      shouldAutoHideControls(immersive: false, playing: false, stageFocused: true),
      isFalse,
      reason: '暂停藏控制栏会把正看的东西盖掉',
    );
  });
}
