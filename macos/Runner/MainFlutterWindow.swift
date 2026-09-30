import Cocoa
import FlutterMacOS
import desktop_multi_window

/// 子窗口控制通道的名字。Dart 侧见 `lib/ui/windows/child_window_channel.dart`。
private let kChildWindowChannelName = "cloudcine/window"

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // PC 端播放器窗口是**另一个 Flutter 引擎**（desktop_multi_window 每窗口
    // 一个引擎），而 method channel 不跨引擎共享 —— 每个引擎都必须单独注册
    // 一遍插件。漏掉这句的表现是：播放窗口能起来，但 `Video` 拿不到 texture
    // 注册器（画面出不来）、`path_provider` 直接抛 MissingPluginException。
    //
    // 这里用的是生成的注册表，所以以后新增的任何插件都会自动带上，
    // 不需要在这个回调里逐个补。
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
      // 顺手把窗口的标题/尺寸/关窗通知接上。必须在**这个回调里**做：
      // 插件已经把 contentViewController 装好并 orderFront 了，
      // 此刻 controller.view.window 才是那个子窗口。
      ChildWindowController.attach(to: controller)
    }

    super.awakeFromNib()
  }
}

/// 每个子窗口一份：负责它的标题、尺寸，以及「关窗前通知 Dart」。
///
/// ## 为什么自己写而不是用 `window_manager`
///
/// 只需要三件事 —— 改标题、改尺寸、关窗时通知 Dart。而 `window_manager`
/// 在**多引擎**下的 macOS 行为没有被验证过（它那个多引擎修复只标注了
/// Windows）。为了三件事引入一个行为未知的大依赖，不如自己写这几十行。
///
/// ## 为什么默认尺寸不是 800×600
///
/// 插件建窗时写死了 `NSRect(x: 0, y: 0, width: 800, height: 600)`（见
/// `desktop_multi_window` 的 `FlutterMultiWindowPlugin.CreateWindow`）。
/// 对播放器来说那是错的形状：800×600 是 4:3，而片子是 16:9，于是画面
/// 上下各留一条黑边，看起来像没铺满。这里改成 1200×675。
final class ChildWindowController: NSObject, NSWindowDelegate {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?

  /// 已请求过释放。用来避免重复通知 Dart。
  private var closingNotified = false

  /// 强引用表。
  ///
  /// **必须有**：`NSWindow.delegate` 是 weak 的，只把实例赋给 delegate 的话
  /// 它立刻就被回收，`windowWillClose` 再也不会被调到。
  private static var instances: [ChildWindowController] = []

  static func attach(to controller: FlutterViewController) {
    guard let window = controller.view.window else {
      debugPrint("cloudcine: 子窗口还没挂到 NSWindow 上，跳过窗口控制注册")
      return
    }
    let channel = FlutterMethodChannel(
      name: kChildWindowChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    let instance = ChildWindowController(channel: channel, window: window)
    channel.setMethodCallHandler(instance.handle)
    window.delegate = instance
    instances.append(instance)
    instance.applyDefaults()
  }

  init(channel: FlutterMethodChannel, window: NSWindow) {
    self.channel = channel
    self.window = window
    super.init()
  }

  /// 建窗后的默认形态。
  private func applyDefaults() {
    guard let window = window else { return }
    window.title = "云影 · 播放器"
    // 16:9。用 setContentSize 而不是 setFrame：setFrame 算的是含标题栏的
    // 外框，直接给 1200×675 会让**画面区域**矮掉一个标题栏的高度。
    window.setContentSize(NSSize(width: 1200, height: 675))
    // 再小就既看不清也点不准控制栏了。
    window.minSize = NSSize(width: 640, height: 360)
    window.center()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setTitle":
      window?.title = (call.arguments as? String) ?? "云影 · 播放器"
      result(nil)

    case "close":
      result(nil)
      // 先回话再关：让 Dart 那边的 await 能正常返回。
      window?.close()

    case "setFullScreen":
      guard let window = window else {
        result(nil)
        return
      }
      let want = (call.arguments as? Bool) ?? false
      // 只在状态真的要变时才 toggle：`toggleFullScreen` 是无参开关，
      // 无脑调用会在「已经全屏、再要求全屏」时把它关掉。
      if want != window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
      }
      result(nil)

    case "setAlwaysOnTop":
      let want = (call.arguments as? Bool) ?? false
      // `.floating` 而不是 `.statusBar`：floating 已经能盖住普通窗口，
      // 又不至于像 statusBar 那样连系统面板都压在下面。
      window?.level = want ? .floating : .normal
      result(nil)

    case "setAspectRatio":
      guard let window = window else {
        result(nil)
        return
      }
      // 全屏时不动尺寸：macOS 全屏窗口的 frame 归系统管，此刻 setContentSize
      // 会被忽略或让画面闪一下；而全屏本来就铺满整屏，没有黑边问题。
      guard !window.styleMask.contains(.fullScreen) else {
        result(nil)
        return
      }
      let aspect = (call.arguments as? NSNumber)?.doubleValue
      guard let aspect = aspect, aspect.isFinite, aspect > 0 else {
        // 解锁。`contentAspectRatio` 置零 = 不约束；`resizeIncrements` 也一并
        // 归位，否则之前残留的增量限制会让窗口只能按步长缩放。
        window.contentAspectRatio = NSSize(width: 0, height: 0)
        window.resizeIncrements = NSSize(width: 1, height: 1)
        result(nil)
        return
      }
      window.contentAspectRatio = NSSize(width: aspect, height: 1)
      // ⚠️ 只设 `contentAspectRatio` **不会**让窗口立刻变成那个形状 —— 它只
      // 约束**以后**的拖拽。所以这里主动把内容区调成该比例：宽度沿用当前值，
      // 高度按比例算出来。不然用户会看到「比例锁了，但窗口还是原来的形状」，
      // 而那一瞬间画面仍然有黑边。
      let content = window.contentRect(forFrameRect: window.frame)
      let minSize = window.minSize
      var width = max(content.width, minSize.width)
      var height = width / aspect
      if height < minSize.height {
        // 极宽的片子（21:9 之类）按当前宽度算出的高度会撞到最小高度，
        // 那样被 AppKit 夹住后比例就失真了。反过来以高度为准重算宽度。
        height = minSize.height
        width = height * aspect
      }
      // 竖屏片源（比例 < 1，手机拍的、部分演唱会录像）按当前宽度反算出的高度
      // 会比屏幕还高 —— 那样标题栏被顶到可视区外，窗口拖不动也关不掉。以屏幕
      // 可视高度封顶后反算宽度，比例照样是准的，只是窗口整体变小。
      let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
      if let visible = visible {
        let maxHeight = visible.height * 0.9
        if height > maxHeight {
          height = maxHeight
          width = height * aspect
        }
      }
      window.setContentSize(NSSize(width: width.rounded(), height: height.rounded()))
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 全屏状态变化后回报给 Dart。
  ///
  /// **必须回报，不能只让 Dart 自己记**：macOS 的全屏是可以由系统退出
  /// （按 Esc、点绿灯、三指手势），那些路径完全不经过我们的通道。Dart 那边
  /// 如果只信自己设的值，就会出现「已经退出全屏了，但界面还以为在全屏」——
  /// 于是全屏布局里的那条退出栏还挂着，而窗口已经变回带标题栏的形态。
  ///
  /// 用 `Did`（动画结束之后）而不是 `Will`：Dart 拿到状态是用来切布局的，
  /// 在动画途中切会让画面先跳一下。
  func windowDidEnterFullScreen(_ notification: Notification) {
    channel.invokeMethod("onFullScreenChanged", arguments: true)
  }

  func windowDidExitFullScreen(_ notification: Notification) {
    channel.invokeMethod("onFullScreenChanged", arguments: false)
  }

  /// 关窗时**尽力**通知 Dart 去释放 mpv。
  ///
  /// ⚠️ 用 `windowWillClose` 而不是 `windowShouldClose`（后者返回 false 能取消
  /// 关闭，等 Dart 回话再关，握手更可靠）—— 但 `windowShouldClose` 在**退出
  /// 应用**时也会被调到，一旦它因为等不到 Dart 回话而返回 false，就会变成
  /// **应用退不掉**。那比「声音还在放」严重得多。所以这里选非阻塞的通知：
  /// 拿得到机会就释放，拿不到也不会让窗口/应用关不掉。
  ///
  /// 确定性的那条路是播放窗口里的「停止并关闭」按钮 —— 它先释放再关，
  /// 不依赖这个通知的时序。
  func windowWillClose(_ notification: Notification) {
    if !closingNotified {
      closingNotified = true
      channel.invokeMethod("onClosing", arguments: nil)
    }
    window?.delegate = nil
    ChildWindowController.instances.removeAll { $0 === self }
  }
}
