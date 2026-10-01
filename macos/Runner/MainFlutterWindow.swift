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

    // 去掉标题栏，只留画面 —— 片名与控制栏由 Dart 侧画成浮层（鼠标移入才
    // 显示，见 `PlayerWindowApp`）。
    //
    // 三件事必须一起做，少一件都会露馅：
    //   - `.fullSizeContentView`：内容区铺到标题栏那一层，否则顶部会留下
    //     一条纯色横条；
    //   - `titleVisibility = .hidden`：藏掉标题**文字**（否则它压在画面上）；
    //   - `titlebarAppearsTransparent = true`：标题栏背景透明。
    //
    // ⚠️ 红绿灯（关闭/最小化/缩放）**刻意保留**。它们浮在画面左上角，是唯一
    // 不依赖我们自己代码的关窗路径 —— 隐藏掉之后，一旦 Dart 侧的「停止并
    // 关闭」按钮因为某个 bug 没渲染出来，用户就只能强杀进程。
    window.styleMask.insert(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true

    window.title = "云影 · 播放器"
    // 16:9 的默认形状。**不锁比例** —— 窗口要能自由拖动缩放，画面靠
    // `BoxFit.contain` 自己出黑边（见 `PlayerWindowApp._buildVideoSurface`）。
    // 用 setContentSize 而不是 setFrame：setFrame 算的是含标题栏的外框。
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

    case "beginWindowDrag":
      beginWindowDrag()
      result(nil)

    case "updateWindowDrag":
      updateWindowDrag()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // -------------------------------------------------------------------
  // 拖动窗口
  // -------------------------------------------------------------------

  /// 拖动锚点：手势开始那一刻的鼠标屏幕位置，以及当时的窗口原点。
  ///
  /// 属性写在方法之后在 Swift 里是合法的 —— 放在紧挨着用它们的两个方法旁边，
  /// 比丢到类顶部更容易看懂它们在服务谁。
  private var dragAnchorMouse: NSPoint?
  private var dragAnchorOrigin: NSPoint?

  /// 开始一次拖动：记下锚点。
  ///
  /// ## 为什么是「锚点 + 绝对鼠标位置」而不是「逐帧累加位移」
  ///
  /// 累加位移在 macOS 上会**自激振荡**，实测症状就是「拖窗口时窗口抖得厉害」：
  ///
  ///   1. Flutter 的 `PointerMoveEvent.position` 是**窗口内**坐标；
  ///   2. 我们按它的 `delta` 把窗口移走之后，同一个鼠标位置在窗口里的坐标
  ///      反着变了 `-dx`；
  ///   3. macOS 会把这个变化当成新的 `mouseDragged` 事件补发给窗口 —— 窗口在
  ///      光标底下移动时系统必须补发事件，否则光标矩形与悬停态就永远是错的；
  ///   4. 于是我们再加一次 `-dx` 的位移，窗口被推回原位；紧接着第 3 步再来一次
  ///      —— 窗口就在两个位置之间高频来回。
  ///
  /// 绝对位置没有这个回路：`NSEvent.mouseLocation` 是**屏幕**坐标，窗口怎么动
  /// 它都不变，所以「鼠标相对按下点走了多远」是唯一确定的量。
  ///
  /// 附带一个好处：即使通道消息被延迟或合并，窗口也会落到正确的位置 ——
  /// 每次都是按当前鼠标位置重算的，**误差不累积**。
  private func beginWindowDrag() {
    guard let window = window else { return }
    dragAnchorMouse = NSEvent.mouseLocation
    dragAnchorOrigin = window.frame.origin
  }

  /// 把窗口移到「按当前鼠标位置它该在的地方」。
  ///
  /// 调用频率由 Flutter 的手势决定（每帧一次），但这里**不依赖调用次数**：
  /// 多调少调只影响跟手的平滑度，不影响终点位置 —— 因为它算的是绝对位置，
  /// 不是「在当前位置上再加一点」。
  private func updateWindowDrag() {
    guard let window = window,
          let anchorMouse = dragAnchorMouse,
          let anchorOrigin = dragAnchorOrigin else { return }

    let now = NSEvent.mouseLocation
    var origin = anchorOrigin
    origin.x += now.x - anchorMouse.x
    // 鼠标位置与窗口原点**同处一个坐标系**（屏幕坐标，y 向上），所以这里
    // 不需要像「累加位移」那样把 y 取反 —— 那时要翻是因为 Flutter 的 y 向下。
    origin.y += now.y - anchorMouse.y

    // 非有限值会让原点变成 NaN，窗口直接飞到屏幕外再也拖不回来
    // （红绿灯也点不到，只能强杀进程）。
    guard origin.x.isFinite, origin.y.isFinite else { return }

    // 位置没变就什么都不做。这不是省一次调用的优化：`setFrameOrigin` 会发
    // `NSWindowDidMoveNotification`，而窗口「动了一下」又可能让系统再补发一次
    // 鼠标事件 —— 那正是上面那段注释里那个振荡回路的燃料。鼠标没动就断在这里，
    // 回路彻底闭合不了。
    if origin == window.frame.origin { return }
    window.setFrameOrigin(origin)
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
