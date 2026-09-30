import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/app_logo.dart';
import 'package:cloudcine/ui/widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把被测组件塞进一个最小可用的 `MaterialApp`：
/// 没有它就没有 `Directionality` / `Theme`，任何 `Text` 都会直接抛。
Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('AppLogo', () {
    testWidgets('默认只有图标，不带应用名', (tester) async {
      await _pump(tester, const AppLogo());

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text(AppLogo.appName), findsNothing);
    });

    testWidgets('showWordmark 打开才显示应用名', (tester) async {
      await _pump(tester, const AppLogo(showWordmark: true));

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.text('云影'), findsOneWidget);
    });
  });

  group('TagChip', () {
    testWidgets('渲染文案', (tester) async {
      await _pump(tester, const TagChip(label: '1080P'));
      expect(find.text('1080P'), findsOneWidget);
    });

    testWidgets('给了图标才渲染图标', (tester) async {
      await _pump(tester, const TagChip(label: '4K'));
      expect(find.byIcon(Icons.star_rounded), findsNothing);

      await _pump(
        tester,
        const TagChip(label: '4K', icon: Icons.star_rounded),
      );
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    });
  });

  group('EmptyState', () {
    testWidgets('只给文案不给回调时不渲染按钮（避免点了没反应）', (tester) async {
      await _pump(
        tester,
        const EmptyState(
          icon: Icons.inbox_rounded,
          title: '媒体库还是空的',
          actionLabel: '去扫描',
        ),
      );

      expect(find.text('媒体库还是空的'), findsOneWidget);
      expect(find.text('去扫描'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('文案与回调都给了才渲染按钮，并且点击能回调', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        EmptyState(
          icon: Icons.inbox_rounded,
          title: '媒体库还是空的',
          body: '先登录网盘再扫描。',
          actionLabel: '去扫描',
          onAction: () => taps++,
        ),
      );

      expect(find.text('先登录网盘再扫描。'), findsOneWidget);
      expect(find.text('去扫描'), findsOneWidget);

      await tester.tap(find.text('去扫描'));
      await tester.pump();
      expect(taps, 1);
    });
  });

  group('KeyValueRow', () {
    testWidgets('标签与值都渲染出来', (tester) async {
      await _pump(
        tester,
        const KeyValueRow(label: '缓存占用', value: '12.4 MB'),
      );

      expect(find.text('缓存占用'), findsOneWidget);
      // 值用 SelectableText 渲染，便于复制诊断信息
      expect(find.text('12.4 MB'), findsOneWidget);
    });
  });

  group('PageHeader', () {
    testWidgets('不给副标题就不占那一行', (tester) async {
      await _pump(tester, const PageHeader(title: '媒体库'));
      expect(find.text('媒体库'), findsOneWidget);
      expect(find.text('12 部作品'), findsNothing);
    });

    testWidgets('给了副标题与操作一起渲染', (tester) async {
      await _pump(
        tester,
        const PageHeader(
          title: '媒体库',
          subtitle: '12 部作品',
          actions: [TagChip(label: '已刮削')],
        ),
      );

      expect(find.text('12 部作品'), findsOneWidget);
      expect(find.text('已刮削'), findsOneWidget);
    });
  });
}
