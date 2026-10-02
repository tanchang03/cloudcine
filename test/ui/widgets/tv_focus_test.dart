import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 焦点指示器。
///
/// 这个组件存在的唯一理由是：`InkWell` 的焦点高亮被海报**盖住**了。
/// 所以最要紧的两条断言是
///   1. 焦点环真的**画在子节点之后**（结构上压在最上面）；
///   2. 它**不会**变成焦点遍历里多出来的一站。
void main() {
  // 焦点环只在「键盘 / 遥控器在操作」时出现。
  // 默认的 `automatic` 依赖真机上的交互历史（有没有点过屏幕），测不了；
  // 这里把两个分支各自钉死。
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  /// 焦点环 = `TvFocusable` 里那个带 border 的 `DecoratedBox`。
  bool hasRing(WidgetTester tester) {
    final boxes = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(TvFocusable),
        matching: find.byType(DecoratedBox),
      ),
    );
    return boxes.any((b) {
      final d = b.decoration;
      return d is BoxDecoration && d.border != null;
    });
  }

  double scaleOf(WidgetTester tester) => tester
      .widget<AnimatedScale>(
        find.descendant(
          of: find.byType(TvFocusable),
          matching: find.byType(AnimatedScale),
        ),
      )
      .scale;

  Future<void> pumpCard(
    WidgetTester tester, {
    required String id,
    required List<String> focusedIds,
    VoidCallback? onTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 80,
              child: TvFocusable(
                borderRadius: BorderRadius.circular(10),
                focusScale: 1.05,
                child: Material(
                  color: Colors.black,
                  child: InkWell(
                    onTap: onTap ?? () {},
                    onFocusChange: (v) {
                      if (v) focusedIds.add(id);
                    },
                    child: const Center(child: Text('卡片')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('遥控器/键盘操作时出现焦点环，并且环压在子节点之上', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await pumpCard(tester, id: 'A', focusedIds: []);

    expect(hasRing(tester), isFalse, reason: '还没聚焦就不该有环');
    expect(scaleOf(tester), 1.0);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      hasRing(tester),
      isTrue,
      reason: '这是「遥控器正指着哪张卡片」唯一的视觉反馈 —— 默认的 focusColor '
          '在海报卡片上是看不见的（ink 画在子节点下面）',
    );
    expect(scaleOf(tester), 1.05, reason: '放大是官方 TV 规范的焦点指示之一');

    // 结构断言：环必须是 Stack 里**最后一个**孩子。
    // 放到第一个（或换成给 InkWell 设 focusColor）就会被海报盖住，
    // 那正是修复前「焦点看不见」的成因。
    final stack = tester.widget<Stack>(
      find
          .descendant(
            of: find.byType(TvFocusable),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(
      stack.children.last,
      isA<Positioned>(),
      reason: '焦点环必须画在子节点之后，否则会被海报整个盖住',
    );
    expect(stack.children.first, isNot(isA<Positioned>()));
  });

  testWidgets('鼠标/触摸操作时不出焦点环（桌面端点过的卡片不该留一圈环）', (tester) async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    await pumpCard(tester, id: 'A', focusedIds: []);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      hasRing(tester),
      isFalse,
      reason: '桌面上鼠标点过的卡片如果留一圈焦点环，看起来会像「已选中」，'
          '这是 Flutter 默认就会避免的行为',
    );
    expect(scaleOf(tester), 1.0);
  });

  testWidgets('TvFocusable 不是多出来的一站焦点 —— 一次方向键就走过一张卡片', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    final focusedIds = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Row(
            children: [
              for (final id in ['A', 'B'])
                SizedBox(
                  width: 120,
                  height: 80,
                  child: TvFocusable(
                    borderRadius: BorderRadius.circular(10),
                    child: Material(
                      color: Colors.black,
                      child: InkWell(
                        onTap: () {},
                        onFocusChange: (v) {
                          if (v) focusedIds.add(id);
                        },
                        child: Center(child: Text(id)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(focusedIds, ['A'], reason: '第一次 Tab 应当直接落到卡片 A 上');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      focusedIds,
      ['A', 'B'],
      reason: '如果 TvFocusable 自己也是一个焦点站，这里会停在中间那一层，'
          '表现就是「每张卡片都要多按一次方向键」',
    );
  });
}
