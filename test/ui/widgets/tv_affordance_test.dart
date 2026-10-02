import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_affordance.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 上给「只有图标的东西」补的可见说明。
///
/// 这两个组件存在的理由是同一条：**遥控器没有 hover**。
/// 所以最要紧的断言是成对的 ——
///   * TV 上那句话**真的出现在屏幕上**；
///   * 非 TV 上**一点都不多出来**（桌面的排版与既有测试不能被它们改掉）。
///
/// ⚠️ `debugDefaultTargetPlatformOverride` 的复位必须写在**测试体里**
/// （下面 `pumpAt` 的 `finally`）。`tearDown` / `addTearDown` 都排在
/// Flutter 的 `_verifyInvariants` **之后**，用错会得到一条与业务无关的
/// 「The value of a foundation debug variable was changed by the test」。
void main() {
  /// 官方 TV 设计尺寸。`isTvLayout` 的判据是「Android 且逻辑宽度 ≥ 960」，
  /// 两个条件都要满足 —— 只把窗口开大是骗不过判据的。
  const tvSize = Size(960, 540);

  /// 手机尺寸：判据必须在这里返回 false。
  const phoneSize = Size(412, 915);

  Future<void> pumpAt(
    WidgetTester tester, {
    required Size size,
    required Widget child,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: MediaQuery(
            data: MediaQueryData(size: size),
            child: Scaffold(
              body: Center(
                child: SizedBox(width: 400, child: child),
              ),
            ),
          ),
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// 一个「只有图标」的按钮 —— 就是这些组件要补救的那种东西。
  ///
  /// ⚠️ 不能用 `onPressed ?? () {}` 这种写法：那样就**造不出禁用态**了
  /// （传 `null` 会被默认值顶掉），而「禁用时标签跟着变暗」正是要测的一条。
  Widget iconButton({VoidCallback? onPressed, bool enabled = true}) =>
      IconButton(
        tooltip: '刷新',
        onPressed: enabled ? (onPressed ?? () {}) : null,
        icon: const Icon(Icons.refresh_rounded, size: 17),
      );

  group('TvIconLabel', () {
    testWidgets('TV 上补出可见的文字标签，并且原按钮的行为一个都没丢', (tester) async {
      var taps = 0;
      await pumpAt(
        tester,
        size: tvSize,
        child: TvIconLabel(
          label: '刷新',
          child: iconButton(onPressed: () => taps++),
        ),
      );

      // 标签确实画出来了 —— 这是这个组件唯一的目的。
      expect(
        find.text('刷新'),
        findsOneWidget,
        reason: '遥控器没有 hover，标签不画出来就等于「一个含义不明的 ↻ 图标」',
      );

      // 关键：补标签**不是**换控件。原按钮还在，tooltip 还在，点击还能用。
      expect(find.byType(IconButton), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);

      await tester.tap(find.byType(IconButton));
      expect(taps, 1, reason: '包一层 Row 不该影响原来的点击行为');
    });

    testWidgets('非 TV 上原样返回 —— 一个 Text 都不多出来', (tester) async {
      await pumpAt(
        tester,
        size: phoneSize,
        child: TvIconLabel(label: '刷新', child: iconButton()),
      );

      expect(
        find.text('刷新'),
        findsNothing,
        reason: '桌面上有 hover，补出来的标签只会让页头挤成一团；'
            '而且一旦多出一个 Text，既有的页面 widget 测试会跟着变',
      );
      expect(find.byType(IconButton), findsOneWidget);
    });

    testWidgets('macOS 宽屏上也不生效 —— 判据带平台，不是「窗口够宽就算电视」', (tester) async {
      await pumpAt(
        tester,
        size: const Size(1920, 1080),
        platform: TargetPlatform.macOS,
        child: TvIconLabel(label: '刷新', child: iconButton()),
      );

      expect(
        find.text('刷新'),
        findsNothing,
        reason: '1920 宽的桌面窗口如果被当成电视，会凭空多出一堆只该在电视上'
            '出现的标签',
      );
    });

    testWidgets('按钮禁用时标签一起变暗 —— 不许出现「字是亮的、按钮是灰的」', (tester) async {
      await pumpAt(
        tester,
        size: tvSize,
        child: TvIconLabel(
          label: '刷新',
          enabled: false,
          child: iconButton(enabled: false),
        ),
      );

      final text = tester.widget<Text>(find.text('刷新'));
      expect(
        text.style?.color,
        AppTheme.dim,
        reason: '禁用时标签若还是亮的，用户会去点那个亮着的字，'
            '点了没反应 —— 比没有标签更糟',
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
    });
  });

  group('TvNote', () {
    testWidgets('TV 上把「为什么按不动」写成看得见的一行', (tester) async {
      await pumpAt(
        tester,
        size: tvSize,
        child: const TvNote(text: '还没有可用的在线刮削源。'),
      );

      expect(
        find.text('还没有可用的在线刮削源。'),
        findsOneWidget,
        reason: '这句话本来只写在 tooltip 里 —— 电视上按钮变灰却没有任何解释，'
            '用户唯一的结论是「这个应用坏了」',
      );
    });

    testWidgets('非 TV 上什么都不画', (tester) async {
      await pumpAt(
        tester,
        size: phoneSize,
        child: const TvNote(text: '还没有可用的在线刮削源。'),
      );

      expect(
        find.text('还没有可用的在线刮削源。'),
        findsNothing,
        reason: '桌面上按钮的 tooltip 已经把原因说清楚了，再印一遍是重复',
      );
      expect(find.byType(SizedBox), findsWidgets);
    });
  });
}
