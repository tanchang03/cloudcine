import 'package:cloudcine/ui/pages/diagnostics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 日志页的取向是「取证材料要能带走」。这里钉住的是**带走路径**那一步：
/// 它看着不起眼，但少了它，用户能看见日志却没法把「文件在哪」告诉别人。
void main() {
  /// 诊断页里有一块「本地中继状态」，它要读 Riverpod 容器。
  ///
  /// ⚠️ 这里**不需要** override 任何数据库相关的 Provider：中继 Provider 刻意
  /// 不依赖设置（理由见 `streamRelayProvider` 的文档），构造它只是 new 一个
  /// 纯 Dart 对象 —— 不碰平台通道，也不 bind 端口（端口是 lazy 的）。
  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(home: Scaffold(body: child)),
      );

  /// ⚠️ `TextButton.icon` 造出来的是 `TextButton` 的**私有子类**
  /// （`_TextButtonWithIcon`），而 `find.byType` 只按精确类型匹配 ——
  /// 直接写 `find.byType(TextButton)` 会一个都找不到，且报的是
  /// 「No element」这种看不出原因的错。这里用 predicate 按 `is` 匹配。
  Finder copyPathButton() => find.byWidgetPredicate(
        (widget) => widget is TextButton,
        description: 'TextButton（复制路径）',
      );

  group('LogPathRow', () {
    testWidgets('有路径时显示路径，点了把路径交出去', (tester) async {
      String? copied;

      await tester.pumpWidget(
        wrap(
          LogPathRow(
            path: '/Users/tandy/Library/Containers/com.cloudcine.cloudcine/'
                'Data/Library/Application Support/cloudcine/logs/'
                'cloudcine-2026-09-30.log',
            onCopy: (value) => copied = value,
          ),
        ),
      );

      expect(find.textContaining('cloudcine-2026-09-30.log'), findsOneWidget);

      await tester.tap(find.text('复制路径'));
      await tester.pump();

      // 复制的是**完整绝对路径**，不是文件名、也不是日志内容。
      expect(
        copied,
        '/Users/tandy/Library/Containers/com.cloudcine.cloudcine/'
        'Data/Library/Application Support/cloudcine/logs/'
        'cloudcine-2026-09-30.log',
      );
    });

    testWidgets('路径可划选 —— 不点按钮也能用鼠标带走', (tester) async {
      await tester.pumpWidget(
        wrap(const LogPathRow(path: '/tmp/a.log', onCopy: _noop)),
      );

      // 普通 Text 在 macOS 上选不中，那样「复制路径」就成了唯一出口。
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('没有路径时按钮禁用，并说明原因', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        wrap(LogPathRow(path: null, onCopy: (_) => tapped = true)),
      );

      expect(find.text('日志文件不可写（仅内存）'), findsOneWidget);

      final button = tester.widget<TextButton>(copyPathButton());
      // 禁用而不是复制空串：静默复制一段空文本会让用户以为
      // 「复制成功了但日志是空的」。
      expect(button.onPressed, isNull);

      await tester.tap(find.text('复制路径'), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
    });
  });

  group('DiagnosticsPage 接线', () {
    testWidgets('路径那一行接到了日志单例上（未启动时按钮禁用）', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: DiagnosticsPage())),
      );

      final row = find.byType(LogPathRow);
      expect(row, findsOneWidget);

      // 这个用例跑在独立的测试进程里，`diag.start()` 没被调用过，
      // 所以拿到的必然是「不可写」形态 —— 正好验证了降级文案。
      expect(
        find.descendant(
          of: row,
          matching: find.text('日志文件不可写（仅内存）'),
        ),
        findsOneWidget,
      );

      final button = tester.widget<TextButton>(
        find.descendant(of: row, matching: copyPathButton()),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('RelayStatusPanel', () {
    testWidgets('没有会话时说明原因，而不是显示一排 0', (tester) async {
      await tester.pumpWidget(wrap(const RelayStatusPanel()));

      // 显示「0 连接 · 已拉 0 B」会让人以为中继在跑却什么都没拉到，而真相
      // 是它根本没被用上（没开、播的是转码档、或播的是本地文件）。
      expect(find.textContaining('当前没有走中继的流'), findsOneWidget);
    });

    testWidgets('没有会话时不留下 periodic timer', (tester) async {
      await tester.pumpWidget(wrap(const RelayStatusPanel()));

      // ⚠️ 这条不是形式主义：跳秒的 timer 一旦在无会话时也启动，诊断页在
      // 任何 `pumpAndSettle` 的用例里都会**超时**，而报错完全指不到这里。
      await tester.pumpAndSettle();
    });
  });
}

void _noop(String _) {}
