import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放页报错浮层的**焦点归属**。
///
/// ## 这条用例守的是用户报的那句话
///
/// > 「我无法将焦点切换到报错按钮中 …… 点击对话框中的按钮也无法点击」
///
/// 根因不在报错浮层内部（那三个按钮都是普通的 `OutlinedButton` /
/// `FilledButton` / `TextButton`，本身完全可聚焦），而在**它挂在谁里面**：
/// 浮层是 `Focus(focusNode: _stageNode)` 的**后代**，而 `_stageNode` 的矩形
/// **铺满整个画面区**。
///
/// 方向键遍历的判据是「候选节点的矩形要完全落在当前节点之外」——
/// 源码 `focus_traversal.dart` 的 `_sortAndFilterVertically`：
///
/// ```dart
/// TraversalDirection.down =>
///   (FocusNode node) => node.rect != target && node.rect.center.dy >= target.bottom,
/// ```
///
/// 于是从画面往下按，浮层里的按钮（中心点在画面矩形**内部**）全部被过滤掉，
/// 焦点直接跳过它们落到下面的控制栏；而**画面上没有任何东西提示这一点**，
/// 用户唯一的结论是「遥控器坏了」。
///
/// 修法与 TV 面板（`_openTvPanel`）完全一样：播放页在错误出现时显式
/// `requestFocus` 到浮层第一个按钮上（`_PlayerPageState._syncErrorFocus`）。
///
/// ⚠️ 播放页本身在 `flutter test` 里起不来（`PlaybackController` 的 `Player`
/// 是**字段初始化器**，一构造就启 libmpv），所以这里复刻它的**结构**：
/// 一个铺满的画面节点 + 挂在它内部的报错按钮。结构一旦被改回去，这条就红。
void main() {
  /// 发一个键，**并让重建落地**（`sendKeyEvent` 自己不会 pump）。
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets('报错按钮在画面节点**内部**时，方向键走不进去 —— 必须显式 requestFocus',
      (tester) async {
    final stageNode = FocusNode(debugLabel: 'test-stage');
    final actionNode = FocusNode(debugLabel: 'test-error-action');
    addTearDown(stageNode.dispose);
    addTearDown(actionNode.dispose);

    var backed = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: SizedBox(
            height: 540,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 「画面」——播放页里它 `autofocus: true`，先拿到焦点。
                Focus(
                  focusNode: stageNode,
                  autofocus: true,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
                // 「报错浮层」——`_buildStage` 里它挂在画面那一层**内部**。
                Center(
                  child: OutlinedButton(
                    focusNode: actionNode,
                    onPressed: () => backed++,
                    child: const Text('返回'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(stageNode.hasPrimaryFocus, isTrue, reason: '前提：画面先占住焦点');

    // ⚠️ 这就是用户报的那条：方向键走不进去。
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(
      actionNode.hasPrimaryFocus,
      isFalse,
      reason: '画面节点的矩形铺满整个画面区，浮层里的按钮中心点落在它**内部** —— '
          '方向键遍历会把它们全部过滤掉。所以「按方向键走过去」这条路是不存在的，'
          '只能靠播放页显式 requestFocus。',
    );

    // 播放页的补救（`_PlayerPageState._syncErrorFocus` 里那一句）。
    actionNode.requestFocus();
    await tester.pump();
    expect(
      actionNode.hasPrimaryFocus,
      isTrue,
      reason: '焦点显式交给按钮之后，它才真的握有焦点',
    );

    await press(tester, LogicalKeyboardKey.select);
    expect(
      backed,
      1,
      reason: 'OK 认的是 `select`（安卓电视的确定键）—— 焦点到位之后，'
          '「重新取链 / 返回」这些按钮才真的按得动',
    );
  });
}
