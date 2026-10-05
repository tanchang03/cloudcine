import 'package:cloudcine/ui/widgets/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 安全输入框：焦点路过不弹键盘，只有按 OK（/点一下）才进编辑。
///
/// ## 为什么值得单开一个文件
///
/// 设置页有 6 个自由文本框。Android TV 上 `TextField` 一拿焦点就弹软键盘，
/// 遥控器 ↓ 一路走下去会每经过一个弹一次 —— 焦点移动被键盘打断。
/// 修法是 TV 下默认 `readOnly`，OK 才进编辑（见 `tv_text_field.dart`）。
/// 这三条是那条修复唯一的回归保护：只读态不断言的话，哪天有人把
/// `readOnly` 删了，测试照样全绿、真机上又开始一路弹窗。
void main() {
  /// TV 视口（`flutter test` 默认平台就是 android，960 宽即进 TV 布局）。
  void useTvView(WidgetTester tester) {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;
  }

  Future<TextEditingController> pumpField(
    WidgetTester tester, {
    ValueChanged<String>? onChanged,
  }) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TvTextField(controller: controller, onChanged: onChanged),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  testWidgets('TV 下只读态：有「按OK输入」提示，且不弹键盘', (tester) async {
    useTvView(tester);
    await pumpField(tester);

    expect(find.text('按OK输入'), findsOneWidget);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.readOnly, isTrue);

    // 焦点落上去也不该弹键盘（这正是修掉的那个 bug：路过就弹）。
    final node = tester
        .widget<TextField>(find.byType(TextField))
        .focusNode!;
    node.requestFocus();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('TV 下按 OK 进编辑态：键盘出来，此后才能打字', (tester) async {
    useTvView(tester);
    String? seen;
    final controller = await pumpField(tester, onChanged: (v) => seen = v);

    tester.widget<TextField>(find.byType(TextField)).focusNode!
        .requestFocus();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    // 进编辑要过两轮 postFrame（先失焦再拿回，见 _enterEditing），
    // 外加键盘连接附着的一帧 —— 用 settle 等它们全部落地。
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.text('按OK输入'), findsNothing);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(controller.text, 'abc');
    expect(seen, 'abc');
  });

  testWidgets('TV 下按返回/Esc 退回只读并收键盘，焦点还在框上', (tester) async {
    useTvView(tester);
    await pumpField(tester);

    tester.widget<TextField>(find.byType(TextField)).focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('按OK输入'), findsOneWidget);

    final node =
        tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(node.hasFocus, isTrue,
        reason: '按返回是想「继续往下走」，焦点没了的话遥控器得从头找');
  });

  testWidgets('桌面下就是普通输入框：无提示、直接可输', (tester) async {
    // 不设 TV 视口（默认 800 < 960），也不改平台。
    String? seen;
    final controller = await pumpField(tester, onChanged: (v) => seen = v);

    expect(find.text('按OK输入'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).readOnly,
      isFalse,
    );

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(controller.text, 'abc');
    expect(seen, 'abc');
  });
}
