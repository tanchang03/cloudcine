import 'package:cloudcine/ui/windows/child_window_channel.dart';
import 'package:cloudcine/ui/windows/player_window_app.dart';
import 'package:cloudcine/ui/windows/window_launch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放窗口的 UI 层。
///
/// ## 为什么这些用例值得写
///
/// 这个组件的整个 UI 层是按实测反馈重写过的，而三条反馈里**两条是布局问题**：
///   1. 控制栏被挤出可视范围（窗口高度算错）—— 看不到按钮；
///   2. 诊断页常驻，窗口一小就露出「好多调试信息和调试按钮」。
///
/// 布局坏了**不会抛异常**，只是「看不见」。所以必须有断言盯着「在不在」——
/// 这类回归靠人眼是查不出来的，因为「东西没了」看起来跟「本来就没有」一样。
///
/// ## 这个组件在测试环境里能起来吗
///
/// 能。`_bootstrap` 在首帧后跑，它碰的所有平台通道在这里都会失败，但
/// **每一处都包了 try/catch** —— 那本来就是设计（设置不了标题不该把正在出画的
/// 窗口搞崩）。所以它只会把自检结果标成失败，不影响 UI 断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const childChannel = MethodChannel('cloudcine/window');
  const codec = StandardMethodCodec();

  /// 被拦下来的 Dart → 原生 调用。
  late List<MethodCall> windowCalls;

  setUp(() {
    windowCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(childChannel, (call) async {
      windowCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(childChannel, null);
  });

  /// 原生 → Dart：把一条通知送进 Dart 侧的处理器。
  Future<void> callFromNative(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      childChannel.name,
      codec.encodeMethodCall(call),
      (_) {},
    );
  }

  /// 起一个播放窗口。[size] 给了就按这个窗口尺寸渲染。
  Future<void> pumpPlayer(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    await tester.pumpWidget(
      const PlayerWindowApp(
        launch: WindowLaunch(
          kind: WindowKind.player,
          windowId: 'w-1',
          payload: <String, Object?>{},
        ),
      ),
    );
    // 两次：一次出首帧，一次让 post-frame 的 `_bootstrap` 跑起来。
    await tester.pump();
    await tester.pump();
  }

  /// 排干挂起的计时器。
  ///
  /// `testWidgets` 在测试体跑完后会断言「没有挂起的 timer」。有两处会踩到：
  ///   - 双击识别器挂的 40ms 倒计时；
  ///   - SnackBar 的 4 秒自动消失。
  ///
  /// 不排干的话报的是「A Timer is still pending even after the widget tree was
  /// disposed」—— 跟被测行为毫无关系，很难看出是测试自己的问题。
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
  }

  /// 控制栏上那个「双击切全屏」的手势层。
  final videoSurface = find.byWidgetPredicate(
    (w) => w is GestureDetector && w.onDoubleTap != null,
  );

  group('默认形态：只出画，不露调试', () {
    testWidgets('没有片源时给一句人话，而不是一片空白', (tester) async {
      await pumpPlayer(tester);

      expect(find.text('还没有载入片源'), findsOneWidget);
    });

    testWidgets('诊断信息**默认不显示** —— 这是实测反馈的第 2 条', (tester) async {
      await pumpPlayer(tester);

      // 「环境自检」是诊断页里的标题；「播放器窗口」是诊断页的页头。
      expect(find.text('环境自检'), findsNothing);
      expect(find.text('播放器窗口'), findsNothing);
    });

    testWidgets('控制栏的按钮一个都不能少 —— 这是实测反馈的第 1 条', (tester) async {
      await pumpPlayer(tester);

      for (final tooltip in const <String>[
        '播放',
        '重新取链（当前片源没有库记录，无从刷新）',
        '窗口置顶',
        '环境自检 / 出画验证',
        '全屏（F）',
      ]) {
        expect(
          find.byTooltip(tooltip),
          findsOneWidget,
          reason: '控制栏缺了「$tooltip」—— 用户会看到窗口上少了按钮',
        );
      }
    });

    testWidgets('没有播放器时播放键是禁用的 —— 点了也不该有反应', (tester) async {
      await pumpPlayer(tester);

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.play_arrow_rounded),
          matching: find.byType(IconButton),
        ),
      );

      expect(button.onPressed, isNull);
    });

    testWidgets('窗口小到应用允许的最小尺寸时控制栏也不溢出', (tester) async {
      // 640×360 是原生侧设的 `minSize`（见 MainFlutterWindow.swift）。
      await pumpPlayer(tester, size: const Size(640, 360));

      // 溢出在 debug 下会变成 RenderFlex overflow 异常。
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('全屏（F）'), findsOneWidget);
    });
  });

  group('诊断页进出', () {
    testWidgets('点自检按钮进诊断页，点返回回到播放', (tester) async {
      await pumpPlayer(tester);

      await tester.tap(find.byTooltip('环境自检 / 出画验证'));
      await tester.pump();

      expect(find.text('环境自检'), findsOneWidget);
      expect(
        find.text('还没有载入片源'),
        findsNothing,
        reason: '诊断页与播放页是互斥的，不能叠在一起',
      );

      await tester.tap(find.text('返回播放（Esc）'));
      await tester.pump();

      expect(find.text('环境自检'), findsNothing);
      expect(find.text('还没有载入片源'), findsOneWidget);
    });
  });

  group('全屏', () {
    testWidgets('双击画面切全屏 —— 走的是我们自己的原生通道', (tester) async {
      await pumpPlayer(tester);

      await tester.tap(videoSurface);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(videoSurface);
      await tester.pump();
      await drainTimers(tester);

      // 关键断言是**走哪条路**：如果双击又落回 media_kit 自带那套，它会去
      // push 一条 Navigator 路由，并在 pop 时对已失活的 element 求
      // InheritedWidget —— 那正是实测报的
      // 「Looking up a deactivated widget's ancestor is unsafe」。
      expect(
        windowCalls.where((c) => c.method == 'setFullScreen').map((c) => c.arguments),
        [true],
        reason: '双击必须调我们自己的 setFullScreen，而不是 media_kit 那套',
      );
    });

    testWidgets('F 键切全屏、Esc 退全屏', (tester) async {
      await pumpPlayer(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(
        windowCalls.where((c) => c.method == 'setFullScreen').map((c) => c.arguments),
        [true, false],
      );
    });

    testWidgets('原生回报全屏状态后，控制栏仍然完整可见', (tester) async {
      await pumpPlayer(tester);

      // 系统自己进的全屏（绿灯 / 三指手势）不经过我们的通道，只能靠原生回调。
      await callFromNative(
        const MethodCall(ChildWindowMethod.onFullScreenChanged, true),
      );
      await tester.pump();

      // 按钮要跟着变……
      expect(find.byTooltip('退出全屏（Esc）'), findsOneWidget);
      // ……而且全屏下控制栏**一个按钮都不能少**：全屏时窗口没有标题栏，
      // 这是用户唯一能退出/操作的地方。
      expect(find.byTooltip('窗口置顶'), findsOneWidget);
      expect(find.byTooltip('环境自检 / 出画验证'), findsOneWidget);
      expect(find.text('还没有载入片源'), findsOneWidget);
    });

    testWidgets('原生说没进全屏时，界面要跟着退回来（不能只信自己设的值）', (tester) async {
      await pumpPlayer(tester);

      await tester.tap(find.byTooltip('全屏（F）'));
      await tester.pump();
      expect(find.byTooltip('退出全屏（Esc）'), findsOneWidget, reason: '乐观更新');

      // 原生侧实际没切成（或者被系统退掉了）—— 回报 false，界面必须回滚。
      await callFromNative(
        const MethodCall(ChildWindowMethod.onFullScreenChanged, false),
      );
      await tester.pump();

      expect(find.byTooltip('全屏（F）'), findsOneWidget);
      expect(find.byTooltip('退出全屏（Esc）'), findsNothing);
    });
  });

  group('置顶', () {
    testWidgets('按钮切置顶，图标跟着变', (tester) async {
      await pumpPlayer(tester);

      await tester.tap(find.byTooltip('窗口置顶'));
      await tester.pump();

      expect(windowCalls.single.method, 'setAlwaysOnTop');
      expect(windowCalls.single.arguments, true);
      expect(find.byTooltip('取消置顶'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    });

    testWidgets('原生侧没接上时回滚，并告诉用户', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(childChannel, (call) async {
        windowCalls.add(call);
        throw MissingPluginException('原生侧没注册');
      });

      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('窗口置顶'));
      await tester.pump();

      // 不回滚的话按钮会显示「已置顶」而窗口纹丝不动，用户只会觉得按钮坏了。
      expect(find.byTooltip('窗口置顶'), findsOneWidget);
      expect(find.byTooltip('取消置顶'), findsNothing);
      expect(find.text('当前平台不支持窗口置顶'), findsOneWidget);
      await drainTimers(tester);
    });
  });
}
