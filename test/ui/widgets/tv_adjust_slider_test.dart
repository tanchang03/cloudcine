import 'package:cloudcine/ui/widgets/tv_adjust_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 可调滑块。
///
/// 它存在的**唯一**理由：Material `Slider` 的快捷键表把四个方向键全绑了
/// （`slider.dart:636-639`），于是电视上焦点一落到滑块上，按 ↑/↓ 被它吃掉
/// 去改值，**焦点再也走不掉**（用户报的第 4 条：「无论点击上下左右，都被
/// 滑块控件控制了」）。
///
/// 所以最要紧的不是「←/→ 能改值」—— 那是顺带保住的原有能力 ——
/// 而是**第 2、3 条：↑/↓ 既不改值、又能把焦点带走**。
void main() {
  /// 造一屏：上面一个按钮、中间滑块、下面一个按钮。
  ///
  /// 上下各放一个可聚焦按钮，是为了能断言「焦点真的走出去了」。
  /// 滑块的值用 [ValueNotifier] 回灌 —— **必须回灌**，否则 ←/→ 会基于
  /// 陈旧的 `value` 计算，测出来的是假失败（真实页面里
  /// `ref.watch(settingsProvider)` 就是回灌的）。
  Future<void> pumpScreen(
    WidgetTester tester, {
    required ValueChanged<double> onChanged,
    double initial = 5,
  }) async {
    final notifier = ValueNotifier<double>(initial);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<double>(
            valueListenable: notifier,
            builder: (context, v, _) => Column(
              children: [
                ElevatedButton(onPressed: () {}, child: const Text('上')),
                TvAdjustSlider(
                  value: v,
                  min: 0,
                  max: 10,
                  divisions: 10,
                  onChanged: (next) {
                    notifier.value = next;
                    onChanged(next);
                  },
                ),
                ElevatedButton(onPressed: () {}, child: const Text('下')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 让焦点落到滑块**外层的那个 `Focus`** 上。
  ///
  /// 从 [Slider] 往上找最近的 `Focus` —— 正是 `TvAdjustSlider` 自己包的那层。
  FocusNode sliderFocus(WidgetTester tester) =>
      Focus.of(tester.element(find.byType(Slider)));

  bool isFocused(WidgetTester tester, String label) =>
      Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

  testWidgets('←/→ 改值 —— 滑块原本就该有的能力，不能被修掉', (tester) async {
    final seen = <double>[];
    await pumpScreen(tester, onChanged: seen.add);
    sliderFocus(tester).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(seen, [6.0], reason: '→ 应当把 5 加到 6（步长 = 10/10 = 1）');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(seen, [6.0, 5.0], reason: '← 应当把 6 退回 5');
  });

  testWidgets('⛔ ↑/↓ **不**改值 —— 这是本控件存在的理由', (tester) async {
    final seen = <double>[];
    await pumpScreen(tester, onChanged: seen.add);
    sliderFocus(tester).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(
      seen,
      isEmpty,
      reason: '原生 Slider 会把 ↑↓ 当成调值；这里必须一次都不触发，'
          '否则焦点就又被困住了',
    );
  });

  testWidgets('⛔ 按 ↓ 能把焦点**带走** —— 用户报的就是「走不掉」', (tester) async {
    await pumpScreen(tester, onChanged: (_) {});
    sliderFocus(tester).requestFocus();
    await tester.pumpAndSettle();
    expect(isFocused(tester, '下'), isFalse, reason: '起点：焦点还在滑块上');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(
      isFocused(tester, '下'),
      isTrue,
      reason: '↓ 必须落到下面那个按钮上；停住不动就是第 4 条没修好',
    );
  });

  testWidgets('按 ↑ 同样能把焦点带走', (tester) async {
    await pumpScreen(tester, onChanged: (_) {});
    sliderFocus(tester).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();

    expect(isFocused(tester, '上'), isTrue);
  });

  testWidgets('⛔ 内部子树不可聚焦 —— 否则 Slider 的 Shortcuts 会把 ↑↓ 抢回去',
      (tester) async {
    await pumpScreen(tester, onChanged: (_) {});
    final outer = tester.widget<Focus>(
      find.ancestor(of: find.byType(Slider), matching: find.byType(Focus)).first,
    );

    expect(
      outer.descendantsAreFocusable,
      isFalse,
      reason: '光给 Slider 的 focusNode 设 canRequestFocus: false 是**没用的** ——'
          'Slider 内部的 FocusableActionDetector 会把它覆盖回 true。'
          '必须靠这层结构封死，否则 ↑↓ 迟早又被吃掉',
    );
  });
}
