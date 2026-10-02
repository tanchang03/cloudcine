import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/app_logo.dart';
import 'package:cloudcine/ui/widgets/common_widgets.dart';
import 'package:flutter/foundation.dart';
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

/// 在指定平台 + 指定逻辑尺寸下渲染 [child]。
///
/// ⚠️ 复位 `debugDefaultTargetPlatformOverride` 必须**写在测试体里**
/// （下面的 `finally`）。`tearDown` 与 `addTearDown` 都排在 Flutter 的
/// `_verifyInvariants` 之后 —— 它会断言「foundation 的调试变量都已复位」，
/// 用错会得到一条与业务毫无关系的
/// 「The value of a foundation debug variable was changed by the test」。
///
/// 复位成 `null` 是安全的：`foundation/_platform_io.dart` 在 `FLUTTER_TEST`
/// 下会把结果强制成 `android`（那段在 `assert` 里，所以只在测试构建生效），
/// 也就是说「原值」本来就是 android，不是宿主机的 macOS。
Future<void> _pumpAt(
  WidgetTester tester,
  Widget child, {
  required TargetPlatform platform,
  required Size size,
}) async {
  // `tester.view` 的尺寸不是 foundation 调试变量，没有上面那条约束。
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  debugDefaultTargetPlatformOverride = platform;
  try {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
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

  /// 「电视上没有键盘」的说明卡。
  ///
  /// 为什么值得测：它在桌面/手机上**什么都不该显示**（电脑有键盘，说这句话
  /// 是噪音），而一旦判据写反，坏法是「电视上不显示」—— 那正好是唯一需要它
  /// 的地方，而且开发机上永远复现不出来。
  group('TvTypingNotice', () {
    const tvSize = Size(1280, 720);

    testWidgets('电视上出现，并同时给出「上传备份」与「备份与同步」两个下一步', (tester) async {
      await _pumpAt(
        tester,
        const TvTypingNotice(),
        platform: TargetPlatform.android,
        size: tvSize,
      );

      expect(find.textContaining('电视上没有键盘'), findsOneWidget);
      expect(
        find.textContaining('上传备份'),
        findsOneWidget,
        reason: '必须指出「先在别的设备上配好再上传」这一步 —— '
            '只说「电视上打不了字」而不给下一步，等于告诉用户没救了',
      );
      expect(
        find.textContaining('备份与同步'),
        findsOneWidget,
        reason: '必须说清回电视上点哪里，否则用户不知道该去哪找那份备份',
      );
    });

    testWidgets('Android 手机宽度不出现（手机上打字本来就好好的）', (tester) async {
      await _pumpAt(
        tester,
        const TvTypingNotice(),
        platform: TargetPlatform.android,
        size: const Size(412, 915),
      );

      // 断言的是**没渲染出来**，不是「组件不在树上」—— 组件在树上是正常的，
      // 它自己按布局判据返回空盒子。
      expect(find.textContaining('电视上没有键盘'), findsNothing);
    });

    testWidgets('macOS 宽屏不出现（电脑上这段话是噪音）', (tester) async {
      await _pumpAt(
        tester,
        const TvTypingNotice(),
        platform: TargetPlatform.macOS,
        size: const Size(1920, 1080),
      );

      expect(
        find.textContaining('电视上没有键盘'),
        findsNothing,
        reason: '判据必须带平台，不能只看宽度 —— 否则宽屏桌面会冒出一段'
            '「电视上没有键盘」',
      );
    });

    testWidgets('电视上正文被放大 —— 否则三米外读不清，这块就白加了', (tester) async {
      await _pumpAt(
        tester,
        const TvTypingNotice(),
        platform: TargetPlatform.android,
        size: tvSize,
      );

      final ctx = tester.element(find.textContaining('电视上没有键盘'));
      expect(
        MediaQuery.textScalerOf(ctx).scale(12),
        greaterThan(12),
        reason: '设置页其余文字是照电脑屏幕定的 11–12.5px；这块是 TV 用户'
            '唯一的出路，必须自己放大一档（AppTheme.tvTextScaler）',
      );
    });

    testWidgets('提示本身不可聚焦 —— 遥控器不该为了一段说明多按几下', (tester) async {
      await _pumpAt(
        tester,
        const TvTypingNotice(),
        platform: TargetPlatform.android,
        size: tvSize,
      );

      expect(
        find.descendant(
          of: find.byType(TvTypingNotice),
          matching: find.byWidgetPredicate(
            (w) => w is Focus && w.canRequestFocus,
          ),
        ),
        findsNothing,
        reason: '它只是说明文字。将来若在这里加按钮（例如「打开备份与同步」），'
            '方向键就会先穿过它，得先想清楚顺序再改这条断言',
      );
    });
  });
}
