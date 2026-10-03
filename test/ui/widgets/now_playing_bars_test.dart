import 'package:cloudcine/ui/widgets/now_playing_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「正在播放」动效。
///
/// ⚠️ 这里**一律不用 `pumpAndSettle`**：这个组件挂着一个 `repeat()` 的
/// [AnimationController]，`pumpAndSettle` 会一直等到超时（表现成用例挂在
/// 「等待动画结束」上，而不是报一个能读的错）。要推进就显式 `pump(时长)`。
void main() {
  group('nowPlayingBarScales（纯函数）', () {
    test('恒返回三根条，且高度比例都在合法区间内', () {
      // 0 或负数会让 `Container` 的高度变成负值 → 渲染期抛异常。
      for (var i = 0; i <= 40; i++) {
        final t = i / 40;
        final scales = nowPlayingBarScales(t);
        expect(scales.length, 3);
        for (final s in scales) {
          expect(s, greaterThanOrEqualTo(minScale));
          expect(s, lessThanOrEqualTo(1.0));
        }
      }
    });

    test('三根条**不同相** —— 同相的话看起来只是整体一起呼吸', () {
      // 这是唯一会「看着不太对但说不清哪不对」的错法：三根条完全同步时，
      // 它读起来像一个呼吸的色块，而不是等化器。
      var found = false;
      for (var i = 0; i <= 40; i++) {
        final scales = nowPlayingBarScales(i / 40);
        if (scales.toSet().length > 1) found = true;
      }
      expect(found, isTrue, reason: '所有相位下三根条都同高 = 相位差写错了');
    });

    test('相位差不是 π 的整数倍 —— 否则第 1 根与第 3 根会完全同步', () {
      // 两根条同步时看起来只有两根条，而截图很难看出「本该有三根」。
      final twoPi = 2 * 3.141592653589793;
      final ratio = barPhaseStep / twoPi;
      expect((ratio - ratio.roundToDouble()).abs(), greaterThan(0.05));
      expect((barPhaseStep - 3.141592653589793).abs(), greaterThan(0.05));
    });
  });

  group('NowPlayingBars（组件）', () {
    testWidgets('画三根条', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: NowPlayingBars(animate: false))),
      ));
      expect(find.byType(Container), findsNWidgets(3));
    });

    testWidgets('动画开着时竖条高度会随时间变（真的在动）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: NowPlayingBars(size: 40))),
      ));
      List<double> heights() => tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => (c.constraints?.maxHeight ?? 0))
          .toList();

      final before = heights();
      await tester.pump(const Duration(milliseconds: 300));
      final after = heights();

      expect(after, isNot(equals(before)), reason: '动画没在跑 = 控制器没 repeat');
      // 收尾：把还挂着的 ticker 交回测试框架，否则会报 pending timer。
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('animate: false 时静止，但仍然是三根条（不是一片空白）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Center(child: NowPlayingBars(animate: false))),
      ));
      final before = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.constraints?.maxHeight)
          .toList();
      await tester.pump(const Duration(milliseconds: 400));
      final after = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.constraints?.maxHeight)
          .toList();
      expect(after, equals(before));
      expect(find.byType(Container), findsNWidgets(3));
    });

    testWidgets('系统「减弱动态效果」开着时不动', (tester) async {
      // 这既是无障碍要求，也是测试里唯一能让它停下来的口子 ——
      // 停下之后 `pumpAndSettle` 才不会卡在超时上。
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: Center(child: NowPlayingBars())),
        ),
      ));
      final before = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.constraints?.maxHeight)
          .toList();
      await tester.pump(const Duration(milliseconds: 400));
      final after = tester
          .widgetList<Container>(find.byType(Container))
          .map((c) => c.constraints?.maxHeight)
          .toList();
      expect(after, equals(before));
    });
  });
}
