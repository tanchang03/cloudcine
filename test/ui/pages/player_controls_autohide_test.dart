import 'package:cloudcine/ui/pages/player_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// 控制栏「无操作收起」的判据。
///
/// 这条最容易漂：一旦控制栏上多了按钮，很容易有人随手加一句
/// 「暂停时也藏」或「焦点在按钮上也藏」。两种都错 ——
/// 前者把正在读的字幕盖掉，后者把控件从用户手底下抽走。
/// 所以判据抽成纯函数、用断言钉死每一档。
void main() {
  test('播放中、焦点在画面、还没藏 → 该藏', () {
    expect(
      shouldAutoHideControls(immersive: false, playing: true, stageFocused: true),
      isTrue,
      reason: '这是唯一的默认分支：遥控器静置，该只剩画面',
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

  test('焦点进了控制栏 / 字幕菜单 → 不该藏（正在操作）', () {
    expect(
      shouldAutoHideControls(immersive: false, playing: true, stageFocused: false),
      isFalse,
      reason: '焦点离开画面意味着用户正在控件的某一处 —— 这时把控件藏掉，'
          '等于把它从手底下抽走',
    );
  });
}
