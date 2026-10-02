import 'package:cloudcine/ui/widgets/player_keys.dart';
import 'package:cloudcine/ui/windows/child_window_channel.dart';
import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_app.dart';
import 'package:cloudcine/ui/windows/player_window_bridge.dart';
import 'package:cloudcine/ui/windows/window_launch.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放窗口的 UI 层。
///
/// ## 为什么这些用例值得写
///
/// 这个组件的整个 UI 层是按实测反馈重写过的，而几条反馈里**两条是布局问题**：
///   1. 控制栏被挤出可视范围（窗口高度算错）—— 看不到按钮；
///   2. 诊断页常驻，窗口一小就露出「好多调试信息和调试按钮」。
///
/// 布局坏了**不会抛异常**，只是「看不见」。所以必须有断言盯着「在不在」——
/// 这类回归靠人眼是查不出来的，因为「东西没了」看起来跟「本来就没有」一样。
///
/// ## 这个组件在测试环境里能起来吗
///
/// 能。`_bootstrap` 在首帧后跑，它碰的所有平台通道在这里都会被拦下来
/// （`cloudcine/window` 与跨引擎通道都由下面的 mock 接住），而没接住的地方
/// **每一处都包了 try/catch** —— 那本来就是设计（设置不了标题不该把正在出画的
/// 窗口搞崩）。所以它只会把自检结果标成失败，不影响 UI 断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const childChannel = MethodChannel('cloudcine/window');
  const codec = StandardMethodCodec();

  /// 跨引擎通道的**底层传输**。`desktop_multi_window` 所有跨窗口调用都走它
  /// （见插件 `window_channel.dart` 里的 `_methodChannel`），所以拦这一条
  /// 就能同时模拟「主窗口在不在」和「主窗口回了什么」。
  const multiChannel = MethodChannel('mixin.one/desktop_multi_window/channels');

  /// 被拦下来的 Dart → 原生 调用（子窗口控制通道）。
  late List<MethodCall> windowCalls;

  /// 被拦下来的「向主窗口要新直链」调用。
  late List<Map<Object?, Object?>> refreshCalls;

  /// `path_provider` 的通道。
  ///
  /// ⚠️ **必须拦下来，否则半个测试套件会以看不出原因的方式失败。**
  ///
  /// `_bootstrap` 的自检会调 `getApplicationSupportDirectory()`。在测试环境里
  /// 这个调用**既不返回也不抛** —— 它就那么挂着（实测：不 mock 时
  /// `_pokeChrome` 永不执行，浮层一直可见）。于是 `_bootstrap` 停在那一行，
  /// 末尾那句 `_pokeChrome()` 永远到不了，浮层的自动隐藏倒计时根本起不来。
  ///
  /// 症状极具误导性：「鼠标静止几秒后自动收起」失败，但 `_pokeChrome` 本身
  /// 是好的（「鼠标一动就重新显示」「移出窗口就收起」两条都能过）——
  /// 看起来像倒计时写错了，其实是引导流程压根没走完。
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    windowCalls = <MethodCall>[];
    refreshCalls = <Map<Object?, Object?>>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(childChannel, (call) async {
      windowCalls.add(call);
      return null;
    });

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      pathChannel,
      // 路径内容不重要，重要的是**这个 Future 会完成**。
      (call) async => '/tmp/cloudcine-test-support',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(multiChannel, (call) async {
      switch (call.method) {
        // 注册 / 注销配对：返回 null 即成功，于是 `_channelReady` 为真。
        case 'registerMethodHandler':
        case 'unregisterMethodHandler':
          return null;
        case 'invokeMethod':
          final args = (call.arguments as Map).cast<Object?, Object?>();
          final method = args['method'];
          if (method == PlayerBridgeMethod.refreshTicket) {
            refreshCalls.add(args);
          }
          if (method == PlayerBridgeMethod.ping) return 'pong';
          // `fetchPendingPlay` 一律回 null：需要片源的用例自己推请求，
          // 这样「默认形态」那几条断言不会被一条意外的播放请求污染。
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(childChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(multiChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
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

  /// 主窗口 → 播放窗口：推一条「播这个」。
  Future<void> pushPlayRequest(WidgetTester tester, PlayRequest request) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      multiChannel.name,
      codec.encodeMethodCall(
        MethodCall('methodCall', <String, Object?>{
          'channel': playerWindowChannel.name,
          'method': PlayerBridgeMethod.play,
          'arguments': request.toJson(),
        }),
      ),
      (_) {},
    );
    await tester.pump();
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
    // 引导流程在 post-frame 起，中间要过好几次跨通道 await。
    //
    // ⚠️ 刻意不用 `pumpAndSettle`：那会把浮层的自动隐藏倒计时也一起跑完，
    // 于是「默认可见」这条就永远断言不到了。
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  /// 排干挂起的计时器，并把「播放失败」那条 SnackBar 彻底送走。
  ///
  /// `testWidgets` 在测试体跑完后会断言「没有挂起的 timer」。有三处会踩到：
  ///   - 双击识别器挂的 40ms 倒计时；
  ///   - SnackBar 的 4 秒自动消失；
  ///   - 浮层的 3 秒自动隐藏。
  ///
  /// ⚠️ **必须逐帧推进，不能一次 `pump(10s)`。** 一次 `pump(Duration)` 只产出
  /// **一帧** —— 动画进度由 Ticker 在帧里推进，时钟跳得再远也只算一帧。而
  /// SnackBar 的退场是「4 秒计时器到期 → 播退场动画 → 动画结束才从树上摘掉」
  /// 三步，每步都在等下一帧；一次性跳时钟，动画刚起步就被冻住。
  ///
  /// 这件事在这里格外要命：测试环境里 `MediaKit.ensureInitialized` 没被调用，
  /// 任何 `open()` 都必然失败，于是每次推片源都会弹一条「播放失败」的
  /// SnackBar。而 SnackBar 是 Scaffold 的贴底浮层，**正好盖住控制栏** ——
  /// 不送走它，所有对控制栏的点击都会落到 SnackBar 上，报出来却是
  /// 「找不到剧集列表 / 找不到清晰度弹框」，完全看不出是被提示挡住的。
  Future<void> drainTimers(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  }

  /// 把鼠标挪一下，让浮层重新显示（`drainTimers` 会把它跑没）。
  Future<void> showChrome(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(40, 40));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(60, 60));
    await tester.pump();
  }

  /// 控制栏上那个「双击切全屏」的手势层。
  final videoSurface = find.byWidgetPredicate(
    (w) => w is GestureDetector && w.onDoubleTap != null,
  );

  group('默认形态：只出画，不露调试', () {
    testWidgets('没有片源时给一句人话，而不是一片空白', (tester) async {
      await pumpPlayer(tester);

      expect(find.text('还没有载入片源'), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('诊断信息**默认不显示** —— 这是实测反馈的第 2 条', (tester) async {
      await pumpPlayer(tester);

      // 「环境自检」是诊断页里的标题；「播放器窗口」是诊断页的页头。
      expect(find.text('环境自检'), findsNothing);
      expect(find.text('播放器窗口'), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('控制栏的按钮一个都不能少 —— 这是实测反馈的第 1 条', (tester) async {
      await pumpPlayer(tester);

      for (final tooltip in const <String>[
        '播放（空格）',
        '重新取链（当前片源没有库记录，无从刷新）',
        '窗口置顶',
        '环境自检 / 出画验证',
        '全屏（F）',
        '停止并关闭',
      ]) {
        expect(
          find.byTooltip(tooltip),
          findsOneWidget,
          reason: '控制栏缺了「$tooltip」—— 用户会看到窗口上少了按钮',
        );
      }
      await drainTimers(tester);
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
      await drainTimers(tester);
    });

    testWidgets('窗口小到应用允许的最小尺寸时控制栏也不溢出', (tester) async {
      // 640×360 是原生侧设的 `minSize`（见 MainFlutterWindow.swift）。
      await pumpPlayer(tester, size: const Size(640, 360));

      // 溢出在 debug 下会变成 RenderFlex overflow 异常。
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('全屏（F）'), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('宽窗下控制栏右簇贴着窗口右边缘 —— 别缩在中间留一大块空白', (tester) async {
      await pumpPlayer(tester, size: const Size(1280, 720));

      // `_buildChrome` 的右内边距是 10，所以右簇最右那个按钮的右沿应当落在
      // 窗口右边缘减去这点内边距的位置。
      //
      // ⚠️ 这条盯的是曾经的一个**不报错的**坏布局：右簇用 `Spacer` + `Flexible`
      // 推右，两者各占 flex 1、剩余宽度被对半分，而 `SingleChildScrollView` 在
      // 主轴上是收缩的、`Flexible` 又是 loose fit —— 分到的那一半填不满的部分
      // 留在末尾。实测 1280 宽的窗口里这个按钮的右沿只到 ~1130，右边空 150px。
      // 用户看到的就是「底部按钮没右对齐」，而控制台一声不响。
      final rect = tester.getRect(find.byTooltip('停止并关闭'));
      expect(
        rect.right,
        greaterThan(1280 - 40),
        reason: '右簇没贴右边缘（右沿 ${rect.right}）—— 按钮会缩在中间、右边空一块',
      );
      await drainTimers(tester);
    });
  });

  group('浮层显隐（片名 + 控制栏）', () {
    testWidgets('默认可见 —— 窗口刚打开时先让人看到有哪些操作', (tester) async {
      await pumpPlayer(tester);

      expect(find.byTooltip('全屏（F）'), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('鼠标静止几秒后自动收起 —— 别一直挡着画面', (tester) async {
      await pumpPlayer(tester);
      expect(find.byTooltip('全屏（F）'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));

      expect(find.byTooltip('全屏（F）'), findsNothing);
      expect(find.text('还没有载入片源'), findsOneWidget, reason: '画面本身还在');
    });

    testWidgets('鼠标一动就重新显示', (tester) async {
      await pumpPlayer(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(find.byTooltip('全屏（F）'), findsNothing);

      await showChrome(tester);

      expect(find.byTooltip('全屏（F）'), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('鼠标移出窗口就收起', (tester) async {
      await pumpPlayer(tester);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 100));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(120, 120));
      await tester.pump();
      expect(find.byTooltip('全屏（F）'), findsOneWidget);

      // 挪到窗口外。
      await mouse.moveTo(const Offset(-40, -40));
      await tester.pump();

      expect(find.byTooltip('全屏（F）'), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('单击画面 → 收起浮层（与「单击暂停」是同一个手势）', (tester) async {
      await pumpPlayer(tester);
      expect(find.byTooltip('全屏（F）'), findsOneWidget);

      await tester.tap(videoSurface);
      // 单击要等双击判定超时才落地。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byTooltip('全屏（F）'), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('单击控制栏上的按钮不会把它自己收掉', (tester) async {
      await pumpPlayer(tester);

      await tester.tap(find.byTooltip('窗口置顶'));
      await tester.pump();

      expect(find.byTooltip('取消置顶'), findsOneWidget);
      await drainTimers(tester);
    });
  });

  group('键盘快捷键', () {
    /// 当前生效的键位表。
    ///
    /// ⚠️ **这里只能查绑定表，不能「按键看结果」。**
    ///
    /// 测试环境里 `Player()` 直接抛
    /// `Exception: Cannot find Mpv.framework/Mpv. Please ensure it's presence
    /// in the Frameworks folder of the application.`（`flutter test` 跑在宿主
    /// Dart VM 上，libmpv 不在 rpath 里）—— 于是 `_player` 永远是 null，
    /// 既没有进度条可以点，也没有可切换的播放状态。
    ///
    /// 所以职责这样分：
    ///   - **有没有接上**（键位表里在不在）由这里钉；
    ///   - **按下去算出来的位置对不对**由 `test/core/playback_seek_test.dart`
    ///     那组纯函数用例钉（夹取规则是两边共用的）。
    /// 已经端到端跑通过的是 F / Esc —— 见下面「全屏」那组，它证明
    /// 「`Focus(autofocus)` + `CallbackShortcuts` + 真实按键事件」这条链是通的。
    List<LogicalKeyboardKey> triggers(WidgetTester tester) => tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings
        .keys
        .whereType<SingleActivator>()
        .map((a) => a.trigger)
        .toList();

    testWidgets('空格 / ← / → 都接上了 —— 缺哪一条都只是「按了没反应」，不报错', (tester) async {
      await pumpPlayer(tester);

      final keys = triggers(tester);
      for (final key in const <LogicalKeyboardKey>[
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ]) {
        expect(
          keys,
          contains(key),
          reason: '$key 没绑上 —— 按下去不会有任何反应，也不会报错',
        );
      }
      // F / Esc 是原有的，不能被这次改动挤掉。
      expect(keys, contains(LogicalKeyboardKey.keyF));
      expect(keys, contains(LogicalKeyboardKey.escape));
      await drainTimers(tester);
    });

    testWidgets('数字键一个都不能少 —— 主键盘与小键盘都要认', (tester) async {
      await pumpPlayer(tester);

      final keys = triggers(tester);
      // 这张表是从 `player_keys.dart` 里长出来的（不是这里手抄的常量），
      // 所以这条断言真正钉的是「窗口把共享表整个接上了」——
      // 少一半的结果是「有的遥控器按 5 没反应」，而那台遥控器在开发机上
      // 永远不出现。
      expect(seekDigitKeys, isNotEmpty);
      for (final entry in seekDigitKeys.entries) {
        expect(
          keys,
          contains(entry.key),
          reason: '${entry.key} 没接上 —— 按下去不会跳到 ${entry.value * 10}%，'
              '也不会报错',
        );
      }
      // 主键盘与小键盘是两组**不同**的键码，各少一个都是上面那种「没反应」。
      expect(keys, contains(LogicalKeyboardKey.digit5));
      expect(keys, contains(LogicalKeyboardKey.numpad5));
      await drainTimers(tester);
    });

    testWidgets('诊断页把空格让给输入框 —— 否则手输直链里的空格打不进去', (tester) async {
      await pumpPlayer(tester);

      await tester.tap(find.byTooltip('环境自检 / 出画验证'));
      await tester.pump();

      // 字符输入不走按键链（由平台输入法通道送进来），而 `CallbackShortcuts`
      // 在焦点链上位于输入框**下方** —— 空格会先被它截走，表现是
      // 「地址里的空格打不出来」，且没有任何报错。
      expect(
        triggers(tester),
        isNot(contains(LogicalKeyboardKey.space)),
        reason: '诊断页上空格必须留给输入框',
      );
      // Esc 要留着：那是「返回播放」的键。
      expect(triggers(tester), contains(LogicalKeyboardKey.escape));
      await drainTimers(tester);
    });

    testWidgets('控制栏整块不可聚焦 —— 否则点过进度条之后方向键就变成调滑块了', (tester) async {
      await pumpPlayer(tester);

      // 按键从主焦点沿焦点链往上找、**最近的处理器赢**。进度条滑块自带方向键
      // 处理，一旦它能拿到焦点，← / → 就不再是「跳 10 秒」而是「调滑块的值」，
      // 而且滑块会停在拖拽预览态上不动（见 `_seekPreview`）—— 用户看到的是
      // 「进度条卡住了」，跟「按键坏了」是两种完全不同的猜测方向。
      expect(
        find.ancestor(
          of: find.byTooltip('播放（空格）'),
          matching: find.byType(ExcludeFocus),
        ),
        findsWidgets,
        reason: '控制栏不在 ExcludeFocus 里 —— 点过一次进度条，方向键就废了',
      );
      await drainTimers(tester);
    });

    testWidgets('滑块真的会吃掉方向键 —— 这就是控制栏必须 ExcludeFocus 的实测依据', (tester) async {
      // ⚠️ 这条测的**不是我们的代码，而是我们依赖的那个机制**。
      //
      // 实测（Flutter 3.29）：把焦点给一个 `value: 0.5` 的 `Slider`，再按 →，
      // 它的值会变成 `0.55` —— 滑块自带的处理比挂在窗口根上的快捷键**更靠近
      // 主焦点**，方向键根本轮不到我们。这就是「点过一次进度条，之后 ← / → 就
      // 跳不动了」的机理，也是上面那条 `ExcludeFocus` 存在的唯一理由。
      //
      // 写成用例是因为：将来 Flutter 改了滑块的键盘行为，我们的修复会
      // **静默失效** —— 快捷键还挂在表里，按下去却没反应，也不报错。
      Future<List<double>> arrowOnSlider({required bool excluded}) async {
        final changes = <double>[];
        final node = FocusNode();
        addTearDown(node.dispose);

        final slider = Slider(
          value: 0.5,
          focusNode: node,
          onChanged: changes.add,
        );
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: excluded ? ExcludeFocus(child: slider) : slider),
        ));

        node.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        return changes;
      }

      expect(
        await arrowOnSlider(excluded: false),
        isNotEmpty,
        reason: '滑块不再吃方向键了（Flutter 行为变了）—— 控制栏那层 ExcludeFocus '
            '可以撤掉，这条断言该跟着改',
      );
      expect(
        await arrowOnSlider(excluded: true),
        isEmpty,
        reason: 'ExcludeFocus 没拦住滑块 —— 控制栏里的 ← / → 会继续被它吃掉',
      );
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
      await drainTimers(tester);
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
      await drainTimers(tester);
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
      // ……而且全屏下控制栏**一个按钮都不能少**：全屏时红绿灯被系统收走，
      // 这是用户唯一能操作的地方。
      expect(find.byTooltip('窗口置顶'), findsOneWidget);
      expect(find.byTooltip('环境自检 / 出画验证'), findsOneWidget);
      expect(find.byTooltip('停止并关闭'), findsOneWidget);
      expect(find.text('还没有载入片源'), findsOneWidget);
      await drainTimers(tester);
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
      await drainTimers(tester);
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
      await drainTimers(tester);
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

  group('拖拽移动窗口', () {
    testWidgets('在画面上拖拽 → 先报「开始」再报「继续」，位移不经过 Dart', (tester) async {
      // 标题栏已经去掉了，画面是唯一还能拖的地方 —— 不报的话无边框窗口
      // 基本挪不动。
      await pumpPlayer(tester);

      await tester.drag(videoSurface, const Offset(30, -20));
      await tester.pump();

      final methods = windowCalls.map((c) => c.method).toList();
      // 顺序是硬要求：原生要靠 begin 记下锚点（按下时的鼠标屏幕位置与窗口
      // 原点），少了它 update 一律早退 —— 窗口纹丝不动，而且**不报任何错**。
      expect(methods, contains('beginWindowDrag'));
      expect(methods, contains('updateWindowDrag'));
      expect(
        methods.indexOf('beginWindowDrag'),
        lessThan(methods.indexOf('updateWindowDrag')),
      );

      // ⚠️ 位移**不**由 Dart 报。逐帧报 `details.delta` 会在 macOS 上自激振荡
      // （窗口在光标底下移动时系统补发 mouseDragged，我们收到一个反向 delta
      // 再加一次反向位移），实测症状正是「拖拽时窗口抖得厉害」。
      expect(windowCalls.any((c) => c.method == 'moveWindowBy'), isFalse);
      for (final call
          in windowCalls.where((c) => c.method.endsWith('WindowDrag'))) {
        expect(call.arguments, isNull, reason: '拖动不该带任何参数');
      }
      await drainTimers(tester);
    });
  });

  group('剧集列表', () {
    /// 点开右侧那条边框按钮，并等滑入动画跑完。
    ///
    /// **不能只 pump 一拍**：展开是分两帧的（先挂上一个宽度 0、位置在右外侧
    /// 的面板，下一帧才开始滑进来），只 pump 一拍时列表项尺寸还是 0，
    /// `tester.tap` 会报「点不中」。
    Future<void> openPlaylist(WidgetTester tester) async {
      await tester.tap(find.byTooltip('剧集列表'));
      // 三拍各有分工：挂上树 → 动画起步 → 跑完。
      // 只 pump 一拍的话列表项尺寸还是 0，`tester.tap` 会报「点不中」；
      // 只 pump 两拍的话面板正停在半路（还在窗口右外侧），点同样落空。
      //
      // 这里刻意不用 `pumpAndSettle`：缓冲指示里的 `CircularProgressIndicator`
      // 是一个永不停止的动画，pumpAndSettle 会一直等到超时。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// 收起并等滑出动画、以及「动画结束后才把面板摘掉」那个延迟都走完。
    Future<void> closePlaylist(WidgetTester tester) async {
      await tester.tap(find.byTooltip('收起剧集列表').first);
      // 收起要多一拍：滑出动画跑完之后，还有一个「把面板从树上摘掉」的延迟，
      // 只 pump 两拍的话面板虽然已经滑走，但仍在树上（`find.text` 还查得到）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('没有剧集时不出现列表按钮 —— 电影不该有个空列表', (tester) async {
      await pumpPlayer(tester);

      expect(find.byTooltip('剧集列表'), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('有剧集时按钮出现，点开列出每一集并标出「第几集 / 共几集」', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      expect(find.text('第 2 / 3 集'), findsOneWidget, reason: '当前在第 2 集');

      await openPlaylist(tester);

      expect(find.text('剧集（3）'), findsOneWidget);
      expect(find.text('第 1 集'), findsOneWidget);
      expect(find.text('第 2 集'), findsOneWidget);
      expect(find.text('第 3 集'), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('看过一集就画一条进度条，没看过的不画', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      await openPlaylist(tester);

      // 夹具里只有第 1 集存了续播点（30 / 45 分钟）。
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('提不出集号的长标题要占两行 —— 挤成一行等于「哪一集」又看不出来', (tester) async {
      // 「目录名作为系列名」的目录里每一项都没有集号，标题是 `剧名-文件名`
      // （见 `desktop_play.dart` 的 `_episodeLabel`）。这类标题动辄 28 个字，
      // 而标题那行只有约 194px（面板 320 − 缩略图 96 − 间距与内边距）≈ 中文
      // 15 字 —— 只给一行的话，用户用来分辨集数的文件名后半段全被省略号吃掉，
      // 这个修复就等于没做。
      const longTitle = '姜松《家电维修视频教程》-182.格力空调显示E6如何维修';
      await pumpPlayer(tester);
      await pushPlayRequest(
        tester,
        _playRequestWithPlaylist(
          playlist: const <PlaylistEntry>[
            PlaylistEntry(
              itemId: 'quark:fid-1',
              title: longTitle,
              subtitle: '1080P · MKV',
              // 带续播点 = 面板会多画一条进度条，这一项就是**最高**的那种
              // 条目。溢出只要有一种组合能触发就会触发，所以拿它来验。
              resumePosition: Duration(minutes: 5),
              duration: Duration(minutes: 45),
            ),
            // 同一列表里放一条短标题当**标尺**：直接断言高度比它高，就同时
            // 证明了「长的那条真的折了行」和「短的那条仍然只占一行」——
            // 比硬编码一个像素值稳（字体度量会随平台/版本变）。
            PlaylistEntry(
              itemId: 'quark:fid-2',
              title: '第 1 集',
              subtitle: '1080P · MKV',
            ),
          ],
        ),
      );
      await drainTimers(tester);
      await showChrome(tester);
      await openPlaylist(tester);

      expect(tester.widget<Text>(find.text(longTitle)).maxLines, 2);
      expect(
        tester.getSize(find.text(longTitle)).height,
        greaterThan(tester.getSize(find.text('第 1 集')).height),
        reason: '长标题要真的折成两行；只放开 maxLines 但被压成一行就白改了',
      );

      // 两行标题 + 副标题仍要装得进 `_episodeTileHeight`。装不下的表现是内容
      // 画到面板外面（真机：「开剧集列表后底部按钮乱飞／被裁」），在测试里
      // 是一条 RenderFlex overflow 异常 —— 所以这里必须显式查一次。
      expect(tester.takeException(), isNull);
      await drainTimers(tester);
    });

    testWidgets('点另一集 → 让主窗口按那一集重新取链', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      await openPlaylist(tester);
      await tester.tap(find.text('第 3 集'));
      await tester.pump();

      expect(refreshCalls, hasLength(1));
      final body = refreshCalls.single['arguments'] as Map;
      expect(body['itemId'], 'quark:fid-3');
      // 第 3 集没看过 → 从头播。
      expect(body['positionMs'], 0);
      await drainTimers(tester);
    });

    testWidgets('切到「已经看完」的一集时从头播，而不是跳到大结局', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      await openPlaylist(tester);
      await tester.tap(find.text('第 1 集'));
      await tester.pump();

      // 第 1 集存的是 30 / 45 分钟 —— 没到「看完」的线，应当续在 30 分钟。
      final body = refreshCalls.single['arguments'] as Map;
      expect(body['positionMs'], const Duration(minutes: 30).inMilliseconds);
      await drainTimers(tester);
    });

    testWidgets('再点一次收起列表', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      await openPlaylist(tester);
      expect(find.text('剧集（3）'), findsOneWidget);

      await closePlaylist(tester);

      expect(find.text('剧集（3）'), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('滑入之后面板必须落在窗口内 —— 停在右外侧就点不中', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);
      await openPlaylist(tester);

      // 这条钉的是「滑入动画到底有没有**跑完**」，而不只是「面板在不在树上」。
      // 只 pump 一两拍时面板还停在 +320 的外侧，列表项中心落在 x≈919 ——
      // 已经在 800 宽的窗口之外，真机上就是「面板没滑出来」，在测试里则表现
      // 成 tap 报「不会命中」。
      final tile = tester.getCenter(find.text('第 1 集'));
      expect(tile.dx, greaterThan(800 - 320), reason: '面板应当占住右侧 320px');
      expect(tile.dx, lessThan(800), reason: '列表项不能被留在窗口外面');
      await drainTimers(tester);
    });
  });

  group('画质设置', () {
    testWidgets('没有可选档位时按钮是灰的 —— 空列表是「没有梯度」不是「还没加载」',
        (tester) async {
      await pumpPlayer(tester);

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '画质'),
      );
      expect(button.onPressed, isNull);
      await drainTimers(tester);
    });

    testWidgets('点画质弹框，列出全部档位并给当前档打勾', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      await tester.tap(find.widgetWithText(TextButton, '原画'));
      await tester.pumpAndSettle();

      expect(find.text('清晰度'), findsOneWidget);
      expect(find.text('超清 1080P'), findsOneWidget);
      expect(find.text('1920×1080 · 4.2 Mbps'), findsOneWidget);
      // 打勾的只有一个 —— 就是当前那一档。
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('选另一档 → 把新档位报回主窗口重新取链（不是自己换 URL）', (tester) async {
      await pumpPlayer(tester);
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);
      await showChrome(tester);

      await tester.tap(find.widgetWithText(TextButton, '原画'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('超清 1080P'));
      await tester.pumpAndSettle();

      expect(refreshCalls, hasLength(1));
      final body = refreshCalls.single['arguments'] as Map;
      expect(body['qualityId'], 'super');
      expect(body['itemId'], 'quark:fid-2', reason: '换档不该把片子也换掉');
      await drainTimers(tester);
    });

    testWidgets('菜单开着时鼠标移出去，控制栏不该跟着消失', (tester) async {
      await pumpPlayer(tester, size: const Size(1280, 720));
      await pushPlayRequest(tester, _playRequestWithPlaylist());
      await drainTimers(tester);

      // ⚠️ 自己建鼠标指针，**不用 `showChrome()`**：`MouseTracker` 按「设备」记账，
      // 一个测试里建两个鼠标指针会直接踩到框架断言
      // （`(event is PointerAddedEvent) == (lastEvent is PointerRemovedEvent)`）。
      // 后面还要用它做「移出窗口」那一步，所以必须自己拿着这个引用。
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(640, 300));
      addTearDown(mouse.removePointer);
      // 移进控制栏 → 浮层重新显示（`drainTimers` 会把它跑没）。
      await mouse.moveTo(const Offset(640, 700));
      await tester.pump();
      expect(find.byTooltip('停止并关闭'), findsOneWidget, reason: '前提：控制栏可见');

      await tester.tap(find.widgetWithText(TextButton, '原画'));
      await tester.pumpAndSettle();
      expect(find.text('清晰度'), findsOneWidget, reason: '前提：菜单已经弹出来了');

      // 点开菜单之后，用户必然把鼠标移到菜单上去选。而菜单挂在 **Overlay** 上、
      // 在播放页那个 `MouseRegion` **之外** —— 这一移会被判成「指针离开了窗口
      // 内容」，直接走到 `_hideChrome()`。真隐藏了，用户看到的就是「菜单还在、
      // 底部控制栏先没了」，也就是那条实测反馈。
      await mouse.moveTo(const Offset(-30, -30));
      await tester.pump();

      expect(
        find.byTooltip('停止并关闭'),
        findsOneWidget,
        reason: '菜单还开着，控制栏不该先没了 —— 用户会以为界面坏了',
      );

      // 倒计时那条路也得挡住：鼠标离开会让倒计时重新起算，到点同样不能收。
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byTooltip('停止并关闭'),
        findsOneWidget,
        reason: '菜单存续期间倒计时到点也不能收控制栏',
      );
      await drainTimers(tester);
    });
  });
}

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

/// 一条「有剧集、有可选档位」的请求，当前播第 2 集。
///
/// 第 1 集**存了续播点**（30 / 45 分钟），另外两集没有 —— 列表上的进度条、
/// 切集时的起播位置都靠这个差别来验。
///
/// [playlist] 可以换掉那一列（长标题那类用例要自己给），不换就用默认的三集。
PlayRequest _playRequestWithPlaylist({List<PlaylistEntry>? playlist}) {
  return PlayRequest(
    url: 'https://cdn.example.com/e2.mp4?sig=x',
    title: '某剧 S01E02',
    itemId: 'quark:fid-2',
    qualityId: 'origin',
    qualityLabel: '原画',
    qualities: const <QualityBrief>[
      QualityBrief(id: 'origin', label: '原画'),
      QualityBrief(
        id: 'super',
        label: '超清 1080P',
        detail: '1920×1080 · 4.2 Mbps',
      ),
    ],
    playlist: playlist ??
        const <PlaylistEntry>[
          PlaylistEntry(
            itemId: 'quark:fid-1',
            title: '第 1 集',
            subtitle: '1080P · MKV',
            resumePosition: Duration(minutes: 30),
            duration: Duration(minutes: 45),
          ),
          PlaylistEntry(
            itemId: 'quark:fid-2',
            title: '第 2 集',
            subtitle: '1080P · MKV',
            duration: Duration(minutes: 45),
          ),
          PlaylistEntry(
            itemId: 'quark:fid-3',
            title: '第 3 集',
            subtitle: '1080P · MKV',
            duration: Duration(minutes: 45),
          ),
        ],
  );
}
