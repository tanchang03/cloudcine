import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/buffered_slider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 带缓冲层的进度条。
///
/// 这里只钉住两条**会悄悄坏掉**的事：缓冲层缺失时组件还能不能建起来，
/// 以及回调给的数到底是比例还是毫秒。轨道长什么样是像素级的事，
/// 交给肉眼 —— 但「比例 vs 毫秒」一旦搞反，进度条会跳到完全不对的地方，
/// 而且两个播放器表现不一样（一个对、一个错），必须钉死。
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double width = 300,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(child: SizedBox(width: width, child: child)),
        ),
      ),
    );
  }

  testWidgets('没有缓冲信息时也能建起来（不画那一层，不抛异常）', (tester) async {
    await pump(
      tester,
      BufferedSlider(value: 0.3, buffered: null, onChanged: (_) {}),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('有缓冲信息时也能建起来', (tester) async {
    await pump(
      tester,
      BufferedSlider(value: 0.3, buffered: 0.8, onChanged: (_) {}),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('缓冲比例真的进了绘制层（不是只停在参数上）', (tester) async {
    await pump(
      tester,
      BufferedSlider(value: 0.3, buffered: 0.8, onChanged: (_) {}),
    );

    // 必须拿到**轨道形状**里去查：只有它会真的画那层缓冲。参数传丢了的话
    // 组件照样建得起来、也不抛异常 —— 表现就是缓冲层悄悄没了。
    final theme = tester.widget<SliderTheme>(find.byType(SliderTheme)).data;
    final shape = theme.trackShape;
    expect(shape, isA<BufferedTrackShape>());
    // 0.8 而不是 80：比例一旦被当成百分比传下来，轨道会画到外面去。
    expect((shape! as BufferedTrackShape).buffered, 0.8);
  });

  testWidgets('回调给的是 0..1 的比例，不是毫秒', (tester) async {
    double? last;
    await pump(
      tester,
      BufferedSlider(
        value: 0.2,
        buffered: 0.5,
        onChanged: (v) => last = v,
      ),
    );

    // 点在轨道最右端附近：如果回调给的是毫秒，这里会是几百上千的数。
    final box = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(box.right - 4, box.center.dy));
    await tester.pumpAndSettle();

    expect(last, isNotNull);
    expect(last!, greaterThan(0.5));
    expect(last!, lessThanOrEqualTo(1.0));
  });

  testWidgets('不可拖时不回调（时长还没解出来的那一段）', (tester) async {
    var calls = 0;
    await pump(
      tester,
      BufferedSlider(
        value: 0,
        enabled: false,
        onChanged: (_) => calls++,
      ),
    );

    final box = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(box.right - 4, box.center.dy));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
