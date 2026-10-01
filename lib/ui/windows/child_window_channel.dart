import 'package:flutter/services.dart';

import '../../core/diagnostics/diag_log.dart';

/// 子窗口控制通道。原生侧见 `macos/Runner/MainFlutterWindow.swift`
/// 的 `ChildWindowController`。
///
/// ## 为什么每个调用都要吞异常
///
/// 这个通道**只在子窗口上注册**（原生侧在 `setOnWindowCreatedCallback` 里
/// 逐个窗口挂），主窗口上没有。所以任何一次调用都可能因为「跑在主窗口」
/// 或「原生侧还没装好」而拿 `MissingPluginException`。
///
/// 而它管的全是**观感**（标题、全屏、置顶）和**收尾**（关窗）—— 拿不到时
/// 安静降级即可，不该因为设置不了标题就把一个正在出画的播放窗口搞崩。
const MethodChannel childWindowChannel = MethodChannel('cloudcine/window');

/// 原生侧发过来的通知方法名。
///
/// ⚠️ 与 `MainFlutterWindow.swift` 里的字符串**必须逐字一致**。名字写错的表现
/// 是原生调用发出去、Dart 这边抛 `MissingPluginException`，而它会被下面的
/// `try/catch` 吞掉 —— 功能静默失效，日志里只有一条 debug。所以
/// `test/ui/windows/child_window_channel_test.dart` 把这些名字钉住了。
abstract final class ChildWindowMethod {
  /// 原生侧通知「这个窗口正在关闭」。
  static const String onClosing = 'onClosing';

  /// 原生侧通知「全屏状态变了」。参数是 `bool`。
  ///
  /// 为什么需要它：macOS 的全屏可以由系统退出（Esc、绿灯、三指手势），
  /// 那些路径不经过我们的通道。Dart 只信自己设的值就会状态漂移。
  static const String onFullScreenChanged = 'onFullScreenChanged';
}

/// 设置本窗口的标题。
Future<void> setChildWindowTitle(String title) async {
  if (title.isEmpty) return;
  try {
    await childWindowChannel.invokeMethod<void>('setTitle', title);
  } catch (e) {
    diag.debug('播放窗口', '设置窗口标题失败：$e');
  }
}

/// 请求原生关闭本窗口。
///
/// 与 `desktop_multi_window` 的区别：插件只暴露 `window_show` / `window_hide`
/// （而且 hide 之后窗口还在、引擎还在、mpv 还在放）。这里是**真的关**。
Future<void> closeChildWindow() async {
  try {
    await childWindowChannel.invokeMethod<void>('close');
  } catch (e) {
    diag.debug('播放窗口', '关闭窗口失败：$e');
  }
}

/// 切换本窗口的全屏。成功返回 true。
///
/// 返回是否成功而不是 void：调用方要据此**回滚**自己那份乐观状态
/// （见 `PlayerWindowApp._setFullScreen`）。不回报的话，原生侧没装好时
/// 界面会显示「已全屏」而窗口纹丝不动，用户只会觉得按钮坏了。
Future<bool> setChildWindowFullScreen(bool on) async {
  try {
    await childWindowChannel.invokeMethod<void>('setFullScreen', on);
    return true;
  } catch (e) {
    diag.debug('播放窗口', '切换全屏失败：$e');
    return false;
  }
}

/// 切换本窗口置顶。成功返回 true。
Future<bool> setChildWindowAlwaysOnTop(bool on) async {
  try {
    await childWindowChannel.invokeMethod<void>('setAlwaysOnTop', on);
    return true;
  } catch (e) {
    diag.debug('播放窗口', '切换置顶失败：$e');
    return false;
  }
}

/// 开始一次窗口拖动。
///
/// ## 为什么是「锚点 + 绝对鼠标位置」而不是「逐帧报位移」
///
/// 原来报的是位移（`PointerMoveEvent.delta`），在 macOS 上会**自激振荡**：
/// Flutter 的 `position` 是**窗口内**坐标，窗口一移动，同一个鼠标位置在窗口里
/// 的坐标就反着变了 —— 而窗口在光标底下移动时系统会补发 `mouseDragged` 事件
/// （不补发的话光标矩形与悬停态就永远是错的），于是我们收到一个反向 delta，
/// 再加一次反向位移…… 窗口就在两个位置之间高频抖动。
/// **实测症状：拖拽时窗口抖得厉害。**
///
/// 现在 Dart 侧只报「开始」与「继续」两件事，位移由原生按**鼠标的屏幕坐标**
/// 算（见 `MainFlutterWindow.swift` 的 `beginWindowDrag`）：窗口怎么动都不影响
/// 那个量，回路被彻底切断，而且误差不累积。
///
/// ## 为什么不干脆用 `NSWindow.performDrag(with:)`
///
/// 它要求调用时手上有一个 `NSEvent`，而跨通道调用发生在事件派发之外，
/// `NSApp.currentEvent` 多半是 nil —— 拖起来会时灵时不灵。而且它会吞掉后续的
/// 鼠标事件，Flutter 侧的「单击暂停 / 双击全屏」就再也收不到 mouseUp。
///
/// ## 两者都吞异常
///
/// 拖不动窗口只是观感问题，不该影响一个正在出画的播放窗口。
Future<void> beginChildWindowDrag() async {
  try {
    await childWindowChannel.invokeMethod<void>('beginWindowDrag');
  } catch (e) {
    diag.debug('播放窗口', '开始拖动窗口失败：$e');
  }
}

/// 继续拖动：让窗口跟到当前鼠标位置。
///
/// **不带参数**是刻意的（理由见 [beginChildWindowDrag]）。参数没有了，
/// 「非有限值会让窗口飞到屏幕外」那道守卫也就一并搬到了原生侧。
Future<void> updateChildWindowDrag() async {
  try {
    await childWindowChannel.invokeMethod<void>('updateWindowDrag');
  } catch (e) {
    diag.debug('播放窗口', '拖动窗口失败：$e');
  }
}

/// 装上子窗口要处理的原生通知。
///
/// ⚠️ **只能调一次**。`MethodChannel.setMethodCallHandler` 是**覆盖式**的：
/// 第二次调用会把第一次装的处理器顶掉，而且是静默的。所以关窗与全屏两件事
/// 必须由**同一个**处理器分发，不能各装一个 —— 否则先装的那个会悄无声息地
/// 失效（在这里就是「关窗后 mpv 不释放」，很难查到原因）。
///
/// ⚠️ 另外：`setMethodCallHandler` 返回 `void`（不像 `desktop_multi_window`
/// 的 `WindowMethodChannel` 那样返回 `Future`），所以这里不能 await。
/// 原生侧没注册这个通道时会静默不生效 —— 那正好是我们要的降级行为。
///
/// [onClosing] 这条路是**尽力而为**的：原生用非阻塞的 `windowWillClose`
/// 通知，引擎可能在这条消息处理完之前就开始拆了。原因见原生侧注释 ——
/// 换成阻塞式的 `windowShouldClose` 会让**应用退不掉**，代价更大。
/// 真正的释放保障是另外两条确定性路径：「停止并关闭」按钮，以及
/// `PlayerWindowApp.dispose()`。
Future<void> registerChildWindowHandlers({
  required Future<void> Function() onClosing,
  Future<void> Function(bool fullScreen)? onFullScreenChanged,
}) async {
  try {
    childWindowChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case ChildWindowMethod.onClosing:
          diag.info('播放窗口', '收到窗口关闭通知，释放播放器');
          await onClosing();
          return null;

        case ChildWindowMethod.onFullScreenChanged:
          // 参数不是 bool 时按 false 处理：原生那边只会发 Bool，
          // 收到别的说明协议对不上，此时「当作退出全屏」比「当作全屏」
          // 安全 —— 猜错成全屏会把界面锁在没有退出栏的布局里。
          final fullScreen = call.arguments == true;
          diag.debug('播放窗口', '全屏状态变为 $fullScreen');
          await onFullScreenChanged?.call(fullScreen);
          return null;

        default:
          // 抛 `MissingPluginException` 而不是普通异常：框架收到它会给原生
          // 回一个 **null 回复**，那正是「这个方法我没实现」的标准表达。
          throw MissingPluginException('未实现的窗口通道方法：${call.method}');
      }
    });
  } catch (e) {
    diag.debug('播放窗口', '注册窗口原生通知失败：$e');
  }
}
