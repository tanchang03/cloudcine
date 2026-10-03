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

    // 主窗口标题栏：与用户可见名称保持一致（播放器子窗口的标题在
    // `ChildWindowController` 里单独设为「云影 · 播放器」）。
    // 标题文字虽然被 `applyVirtualTitleBar` 藏掉了，但属性本身仍保留 ——
    // 窗口菜单、Mission Control、辅助功能都读它。
    self.title = "云影 CloudCine"

    applyVirtualTitleBar()
    applyMinimumSize()

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

  // -------------------------------------------------------------------
  // 虚拟标题栏 & 最小尺寸
  // -------------------------------------------------------------------

  /// 抹掉系统标题栏，让窗口内容一路铺到最顶端。
  ///
  /// 三个开关各管一件事，缺一不可（与播放器子窗口 `ChildWindowController`
  /// 的做法完全一致）：
  ///   - `titlebarAppearsTransparent`：标题栏不再画自己的底色，
  ///     Flutter 的内容能一直铺到窗口最顶端；
  ///   - `titleVisibility = .hidden`：不画窗口标题文字 ——
  ///     应用名改由侧栏的 Logo 承担，顶部那条**刻意什么都不画**，
  ///     画了就像系统标题栏没去掉；
  ///   - `.fullSizeContentView`：内容视图铺满整个窗口（含标题栏那 32pt），
  ///     否则顶上会留一条画不到的空白。
  ///
  /// 红黄绿三个原生按钮**仍然浮在左上角**（位置由 AppKit 决定，
  /// x 约 9..69、圆心距顶 16），Flutter 侧靠
  /// `AppTheme.titleBarHeight = 32` 的顶部留白（`WindowTopInset`）给它们让位。
  ///
  /// **刻意保留原生红黄绿**：它们才是真正的窗口控制（关闭 / 最小化 /
  /// 缩放 / 全屏），自带悬停符号、辅助功能、双击标题栏缩放、键盘快捷键。
  private func applyVirtualTitleBar() {
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    styleMask.insert(.fullSizeContentView)

    if #available(macOS 11.0, *) {
      titlebarSeparatorStyle = .none
    }
  }

  /// 不允许把窗口拖到比**默认尺寸**更小。
  ///
  /// 默认尺寸写在 `Base.lproj/MainMenu.xib` 的 `contentRect` 里（1280 × 820）。
  /// 这里**不写死数字**，而是从当前 frame 反算内容区 —— 以后改默认尺寸时，
  /// 最小尺寸自动跟着走。
  ///
  /// 为什么需要：界面是按桌面宽度排的（左侧 196pt 侧栏 + 主区），再窄下去
  /// 页头、筛选行、海报卡片会挤到换行甚至溢出（800×600 时就有 overflow 告警）。
  ///
  /// 用 `contentMinSize` 而不是 `minSize`：后者约束的是**窗口 frame**
  /// （含标题栏那一段），设成同一个数会让内容区比预期矮一截。
  private func applyMinimumSize() {
    contentMinSize = contentRect(forFrameRect: frame).size
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

    // 鼠标追踪模式：**播放窗口必须在没焦点时也能收到 hover**。
    //
    // 引擎的默认值是 `InKeyWindow`（见 `FlutterViewController.h` 里
    // `mouseTrackingMode` 的说明），它给视图挂的 `NSTrackingArea` 带的是
    // `NSTrackingActiveInKeyWindow` —— 也就是「**只有本窗口是 key window** 时
    // 才把 hover 事件送进 Flutter」。对播放器这个默认值是错的：用户把播放窗口
    // 搁在一边、焦点留在主窗口或别的应用上，鼠标滑到画面上时 Dart 侧一个 hover
    // 都收不到，控制栏与剧集列表按钮就不出来 —— 而 `PlayerWindowApp` 的整套
    // 浮层正是靠 hover 唤醒的（见 `_pokeChrome`）。用户反馈的症状正是
    // 「窗口不是当前焦点时，鼠标滑到播放器上什么反应都没有」。
    //
    // `.always` 对应 AppKit 的 `NSTrackingActiveAlways`：按 Apple 文档
    // 「不论第一响应者、窗口状态还是**应用状态**，owner 都收消息」。这正是
    // Finder 工具栏那种原生手感 —— 窗口没激活，鼠标划过去照样高亮
    // （flutter/flutter#185426 里维护者也是这么说的，并建议至少给多窗口场景
    // 这么设；引擎自己的多窗口建出来的 controller 没有别的口子能配它）。
    //
    // ⚠️ 它只管 **hover**（进入 / 移动 / 离开）。点击仍然要先激活窗口，但引擎的
    // `FlutterView.acceptsFirstMouse` 返回 YES，所以「第一次点击」会同时完成
    // 激活与派发，不会出现「点一下只是激活、再点一下才生效」。
    //
    // ⚠️ 引擎切换追踪模式时**不会**先摘掉旧的那个 tracking area（只有设成
    // `None` 才摘，见 `configureTrackingArea`）。viewDidLoad 已经按默认值挂过
    // 一个，所以这里挂完会同时存在两个：窗口是 key 时 hover 事件会到两次。
    // 不处理它：两次事件的位置完全相同，Dart 侧 `_pokeChrome()` 幂等；而
    // 「指针进入」在引擎里本来就有去重（`flutter_state_is_added` 时丢弃 kAdd）。
    controller.mouseTrackingMode = .always

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
