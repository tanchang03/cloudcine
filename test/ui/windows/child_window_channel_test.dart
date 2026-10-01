import 'package:cloudcine/ui/windows/child_window_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 这个通道的**两端分别用两种语言写**：Dart 在这里，方法名与参数形状在
/// `macos/Runner/MainFlutterWindow.swift` 的 `ChildWindowController` 里。
///
/// 名字写错、参数类型对不上，表现都是**静默失效** —— 因为这里的每个调用都
/// 包在 `try/catch` 里（那是刻意的：设置不了标题不该把播放窗口搞崩），
/// 异常会被降级成一条 debug 日志，功能却已经死了。
///
/// 所以这些用例把 Dart 这一侧的契约钉死：发出去的方法名、参数、返回值语义，
/// 以及收到原生通知后的分发行为。Swift 那一侧只能靠人工核对，但至少
/// 字符串常量在这里是显式的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();

  /// Dart → 原生：被拦下来的调用
  late List<MethodCall> outgoing;

  /// 拦住 Dart → 原生的调用。[reply] 用来模拟原生的回复（抛异常 = 没实现）。
  void mockNative({Object? Function(MethodCall call)? reply}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(childWindowChannel, (call) async {
      outgoing.add(call);
      return reply?.call(call);
    });
  }

  /// 原生 → Dart：把一条方法调用送进 Dart 侧的处理器，返回原生的回复。
  Future<ByteData?> callFromNative(MethodCall call) async {
    ByteData? reply;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      childWindowChannel.name,
      codec.encodeMethodCall(call),
      (data) => reply = data,
    );
    return reply;
  }

  setUp(() {
    outgoing = <MethodCall>[];
    mockNative();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(childWindowChannel, null);
  });

  group('通道名与方法名', () {
    test('通道名与原生侧一致', () {
      expect(childWindowChannel.name, 'cloudcine/window');
    });

    test('通知方法名与原生侧逐字一致', () {
      // 改这里就必须同步改 MainFlutterWindow.swift 里的字符串。
      expect(ChildWindowMethod.onClosing, 'onClosing');
      expect(ChildWindowMethod.onFullScreenChanged, 'onFullScreenChanged');
    });
  });

  group('Dart → 原生', () {
    test('设置标题发 setTitle + 字符串', () async {
      await setChildWindowTitle('银翼杀手');

      expect(outgoing, hasLength(1));
      expect(outgoing.single.method, 'setTitle');
      expect(outgoing.single.arguments, '银翼杀手');
    });

    test('空标题直接不发 —— 免得把标题栏清空', () async {
      await setChildWindowTitle('');

      expect(outgoing, isEmpty);
    });

    test('关窗发 close', () async {
      await closeChildWindow();

      expect(outgoing.single.method, 'close');
    });

    test('全屏开关把布尔值原样发过去', () async {
      expect(await setChildWindowFullScreen(true), isTrue);
      expect(await setChildWindowFullScreen(false), isTrue);

      expect(outgoing.map((c) => c.method), ['setFullScreen', 'setFullScreen']);
      expect(outgoing.map((c) => c.arguments), [true, false]);
    });

    test('置顶开关把布尔值原样发过去', () async {
      expect(await setChildWindowAlwaysOnTop(true), isTrue);

      expect(outgoing.single.method, 'setAlwaysOnTop');
      expect(outgoing.single.arguments, true);
    });

    test('开始拖动发 beginWindowDrag，且**不带**位移', () async {
      await beginChildWindowDrag();

      expect(outgoing.single.method, 'beginWindowDrag');
      // ⚠️ 刻意不带参数。带位移回来就等于退回「逐帧累加位移」，而那是窗口抖动
      // 的成因：Flutter 的坐标是**窗口内**的，窗口一移动它就反着变，而系统会
      // 把这次变化当成新的拖动事件补发回来 —— 于是我们再加一次反向位移，
      // 窗口就在两个位置之间高频来回（实测症状：拖拽时窗口抖得厉害）。
      // 位移改由原生按鼠标的**屏幕**坐标算，见 `MainFlutterWindow.swift`。
      expect(outgoing.single.arguments, isNull);
    });

    test('继续拖动发 updateWindowDrag，同样不带参数', () async {
      await updateChildWindowDrag();

      expect(outgoing.single.method, 'updateWindowDrag');
      expect(outgoing.single.arguments, isNull);
    });

    test('原生没接上时拖动不抛异常 —— 拖不动只是观感问题', () async {
      mockNative(reply: (_) => throw MissingPluginException('原生侧没注册'));

      await expectLater(beginChildWindowDrag(), completes);
      await expectLater(updateChildWindowDrag(), completes);
    });

    test('原生没接上时返回 false，不抛异常', () async {
      // 跑在主窗口上、或原生侧还没装好时就是这样。
      // 返回 false 而不是 void：调用方要据此回滚自己那份乐观状态，
      // 否则界面会显示「已全屏」而窗口纹丝不动。
      mockNative(reply: (_) => throw MissingPluginException('原生侧没注册'));

      expect(await setChildWindowFullScreen(true), isFalse);
      expect(await setChildWindowAlwaysOnTop(true), isFalse);
      expect(await setChildWindowFullScreen(false), isFalse);
    });

    test('原生抛别的异常时也返回 false', () async {
      mockNative(reply: (_) => throw StateError('窗口已经没了'));

      expect(await setChildWindowFullScreen(true), isFalse);
    });

    test('设置标题失败不抛异常 —— 设不了标题不该搞崩正在出画的窗口', () async {
      mockNative(reply: (_) => throw MissingPluginException('原生侧没注册'));

      await expectLater(setChildWindowTitle('x'), completes);
      await expectLater(closeChildWindow(), completes);
    });
  });

  group('原生 → Dart', () {
    test('onClosing 调到关窗回调，并回一个成功信封', () async {
      var closed = 0;
      await registerChildWindowHandlers(onClosing: () async => closed++);

      final reply =
          await callFromNative(const MethodCall(ChildWindowMethod.onClosing));

      expect(closed, 1);
      // 非 null 的成功信封 = 「收到了」。原生据此能区分「Dart 处理了」
      // 和「Dart 没实现」。
      expect(reply, isNotNull);
      expect(codec.decodeEnvelope(reply!), isNull);
    });

    test('onFullScreenChanged 把布尔值交给回调', () async {
      final seen = <bool>[];
      await registerChildWindowHandlers(
        onClosing: () async {},
        onFullScreenChanged: (value) async => seen.add(value),
      );

      await callFromNative(
        const MethodCall(ChildWindowMethod.onFullScreenChanged, true),
      );
      await callFromNative(
        const MethodCall(ChildWindowMethod.onFullScreenChanged, false),
      );

      expect(seen, [true, false]);
    });

    test('全屏通知的参数不是 bool 时按「退出全屏」处理', () async {
      final seen = <bool>[];
      await registerChildWindowHandlers(
        onClosing: () async {},
        onFullScreenChanged: (value) async => seen.add(value),
      );

      for (final raw in const <Object?>['true', null, 1, <String>[]]) {
        await callFromNative(
          MethodCall(ChildWindowMethod.onFullScreenChanged, raw),
        );
      }

      // 猜错成全屏会把界面锁在一个没有退出栏的布局里 —— 猜 false 更安全。
      expect(seen, [false, false, false, false]);
    });

    test('没装全屏回调时收到通知不崩', () async {
      await registerChildWindowHandlers(onClosing: () async {});

      final reply = await callFromNative(
        const MethodCall(ChildWindowMethod.onFullScreenChanged, true),
      );

      expect(reply, isNotNull);
    });

    test('未知方法回 null 回复，且不触发任何回调', () async {
      var closed = 0;
      final seen = <bool>[];
      await registerChildWindowHandlers(
        onClosing: () async => closed++,
        onFullScreenChanged: (value) async => seen.add(value),
      );

      final reply = await callFromNative(const MethodCall('nope'));

      // 框架对处理器抛出的 `MissingPluginException` 就是回一个 **null 回复**
      // —— 那正是「这个方法我没实现」的标准表达。
      expect(reply, isNull);
      expect(closed, 0);
      expect(seen, isEmpty);
    });

    test('重复注册以最后一次为准 —— 提醒调用方必须一次装完', () async {
      var first = 0;
      var second = 0;
      await registerChildWindowHandlers(onClosing: () async => first++);
      await registerChildWindowHandlers(onClosing: () async => second++);

      await callFromNative(const MethodCall(ChildWindowMethod.onClosing));

      // `MethodChannel.setMethodCallHandler` 是**覆盖式**的。所以关窗与全屏
      // 两件事必须由同一个处理器分发 —— 分两次装会让先装的那个静默失效，
      // 在这里就是「关窗后 mpv 不释放」，很难查到原因。
      expect(second, 1);
      expect(first, 0, reason: '前一个处理器已被顶掉');
    });
  });
}
