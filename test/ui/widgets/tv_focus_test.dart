import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 焦点指示器。
///
/// 这个组件存在的唯一理由是：`InkWell` 的焦点高亮被海报**盖住**了。
/// 所以最要紧的几条断言是
///   1. 焦点提示**不含任何带颜色的蒙版** —— 真机反馈是「不需要背景蒙版色凸显，
///      看起来有点多余，也不太美观」，所以只允许**中性白**提亮；
///   2. 它**一个描边都不画** —— 上一轮反馈「好多按钮都出现了一圈很粗的边框」；
///   3. 它真的**画在子节点之后**（结构上压在最上面）；
///   4. 它**不会**变成焦点遍历里多出来的一站；
///   5. 不传 [TvFocusable.brighten] 时**一层罩都不叠** —— 大多数调用点自己有
///      ink 高亮，多叠一层只会让画面发脏。
void main() {
  // 焦点提示只在「键盘 / 遥控器在操作」时出现。
  // 默认的 `automatic` 依赖真机上的交互历史（有没有点过屏幕），测不了；
  // 这里把两个分支各自钉死。
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  /// `TvFocusable` 内部所有 `DecoratedBox` 的 `BoxDecoration`。
  List<BoxDecoration> decorations(WidgetTester tester) => tester
      .widgetList<DecoratedBox>(
        find.descendant(
          of: find.byType(TvFocusable),
          matching: find.byType(DecoratedBox),
        ),
      )
      .map((b) => b.decoration)
      .whereType<BoxDecoration>()
      .toList();

  /// 提亮层 = 那个**只有颜色、没有描边**的 `DecoratedBox`。
  ///
  /// 判据是「有没有一个纯色层」，而不是「有没有描边」—— 后者正是要消掉的东西。
  Color? overlayColor(WidgetTester tester) {
    for (final d in decorations(tester)) {
      if (d.border == null && d.color != null) return d.color;
    }
    return null;
  }

  /// 断言某个颜色是**中性**的（R=G=B），即不带强调色。
  ///
  /// 这条守卫的是用户那句「不需要背景蒙版色凸显」：把 `Colors.white` 换成
  /// `AppTheme.accent` 之类**不会让任何功能失效**，只会让一屏卡片整体发蓝发脏。
  void expectNeutral(Color color, {required String reason}) {
    expect(
      color.r,
      color.g,
      reason: reason,
    );
    expect(
      color.g,
      color.b,
      reason: reason,
    );
  }

  /// 整个组件里**一个描边都不该有**。
  ///
  /// 它出错的方式是静默的：多画一圈 2px 亮蓝边不会让任何功能失效，只会让用户
  /// 觉得「很奇怪、体验很糟糕」。
  void expectNoBorder(WidgetTester tester) {
    final bordered = decorations(tester).where((d) => d.border != null);
    expect(
      bordered,
      isEmpty,
      reason: '焦点提示只该是一层色罩。再叠描边就成了真机上那圈「很粗的边框」',
    );
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
    double brighten = 0.10,
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
                brighten: brighten,
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

  testWidgets('遥控器/键盘操作时出现焦点提示：放大 + 中性提亮，且压在子节点之上',
      (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await pumpCard(tester, id: 'A', focusedIds: []);

    expect(overlayColor(tester), isNull, reason: '还没聚焦就不该有罩');
    expect(scaleOf(tester), 1.0);
    expectNoBorder(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    final color = overlayColor(tester);
    expect(
      color,
      isNotNull,
      reason: '这是「遥控器正指着哪张卡片」唯一的视觉反馈 —— 默认的 focusColor '
          '在海报卡片上是看不见的（ink 画在子节点下面）',
    );
    expectNeutral(
      color!,
      reason: '提亮层必须是**中性白**。带颜色的罩子会把内容整体染色，'
          '正是用户说的「背景蒙版色凸显…有点多余，也不太美观」',
    );
    expect(
      color.a,
      lessThan(0.35),
      reason: '罩子是**叠在** InkWell 那层高亮之上的，两者同色会相加 —— '
          '调太亮就回到了当初被吐槽的「又亮又重」',
    );
    expect(scaleOf(tester), 1.05, reason: '放大是官方 TV 规范的焦点指示之一');
    expectNoBorder(tester);

    // 结构断言：罩子必须是 Stack 里**最后一个**孩子。
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
      reason: '焦点罩必须画在子节点之后，否则会被海报整个盖住',
    );
    expect(stack.children.first, isNot(isA<Positioned>()));
  });

  testWidgets('不传 brighten 时只放大、不叠任何罩（默认行为）', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await pumpCard(tester, id: 'A', focusedIds: [], brighten: 0.0);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      overlayColor(tester),
      isNull,
      reason: '侧栏项 / chip / 列表行这些自己有 ink 高亮的调用点不该再叠一层，'
          '叠了会和 ink 相加、画面发脏',
    );
    expect(scaleOf(tester), 1.05, reason: '不叠罩不代表没有焦点提示 —— 放大还在');
  });

  testWidgets('鼠标/触摸操作时不出焦点罩（桌面端点过的卡片不该留一层亮罩）',
      (tester) async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    await pumpCard(tester, id: 'A', focusedIds: []);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      overlayColor(tester),
      isNull,
      reason: '桌面上鼠标点过的卡片如果留一层亮罩，看起来会像「已选中」，'
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
