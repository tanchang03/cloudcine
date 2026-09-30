import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostics/diag_log.dart';
import '../theme/app_theme.dart';
import 'child_window_channel.dart';
import 'player_protocol.dart';
import 'player_window_bridge.dart';
import 'window_launch.dart';

/// 内置自检视频的 asset URI（32 KB，H.264 baseline + AAC，3 秒）。
///
/// 用它而不是「让用户选一个本地文件」是刻意的：macOS 沙箱下读用户选中的文件
/// 需要 `com.apple.security.files.user-selected.read-only` 权限，而本应用目前
/// **没有**申请它（网盘应用本来也不需要）。走 asset 则零权限、零网络，
/// 让「mpv 在这个引擎里到底能不能出画」变成一个不受环境影响的确定性结论。
const String kSelfTestAssetUri = 'asset:///assets/player_selftest.mp4';

/// PC 端播放器独立窗口的根组件。
///
/// 它跑在**自己的 Flutter 引擎**里（见 `player_window_bridge.dart` 的说明），
/// 因此：
///   - 不能用主窗口的 Riverpod 容器、不能读主窗口的 Provider；
///   - 需要什么就通过跨窗口通道要 —— 包括「播哪部片」。
///
/// ## 职责边界
///
/// 这个窗口**只负责出画**。取链、鉴权、重试、落库全部留在主窗口：
/// 主窗口把 [PlayRequest]（直链 + 请求头 + 标题 + 本地行号）推过来或放在
/// 待取盒子里，这里拿到就播，并每 10 秒把位置报回去。它甚至不知道「夸克」。
///
/// ## 页面上为什么还留着自检
///
/// 独立窗口一旦出问题（黑屏、没声音），最难的是「哪一环坏了」。自检把
/// 引擎 / 原生插件 / libmpv / 跨引擎通道四件事各自变成一个能一眼看懂的结论，
/// 省掉一轮「猜 + 重跑」。
class PlayerWindowApp extends StatefulWidget {
  const PlayerWindowApp({super.key, required this.launch});

  final WindowLaunch launch;

  @override
  State<PlayerWindowApp> createState() => _PlayerWindowAppState();
}

class _PlayerWindowAppState extends State<PlayerWindowApp> {
  final TextEditingController _urlController = TextEditingController();

  Player? _player;
  VideoController? _controller;

  List<_SelfCheck> _checks = const <_SelfCheck>[];
  String? _nowPlaying;
  bool _busy = false;

  /// 是否处于全屏。
  ///
  /// **以原生回调为准**（见 [ChildWindowMethod.onFullScreenChanged]）：这里设的
  /// 值只是乐观更新，用来让按钮立刻有反应；系统自己退出全屏（Esc、绿灯、
  /// 三指手势）时会被回调纠正回来。
  bool _fullScreen = false;

  /// 窗口是否置顶。
  ///
  /// 这个没有原生回调 —— 置顶只能由我们自己改，不存在「被系统改掉」的路径，
  /// 所以本地状态就是真相。
  bool _alwaysOnTop = false;

  /// 当前是否在播放。控制栏那个播放/暂停按钮跟着它变。
  ///
  /// 不订阅 `stream.playing` 的话，按钮会永远显示「播放」——
  /// 语义正好反过来，点下去才知道错了。
  bool _playing = false;

  /// 当前视频的**显示**宽高比（`VideoParams.aspect`，已含像素宽高比修正）。
  ///
  /// 它决定两件事：窗口的形状（推给原生锁 `contentAspectRatio`），以及画面
  /// 该铺多大。`null` = 还没有片源。
  ///
  /// 用 `aspect` 而不是 `width / height`：后者是**像素**尺寸，遇到
  /// 720×576（SAR 16:15）这种片子算出来是 1.25，而实际要显示成 4:3 = 1.333，
  /// 差一点就会在左右留出细黑边。
  double? _videoAspect;

  /// 是否正在看诊断面板。
  ///
  /// 自检与调试按钮**默认藏起来**：播放窗口的主职是出画，一堆日志和按钮
  /// 摆在画面下面既占地方又容易让人以为播放器坏了。
  bool _showDiagnostics = false;

  /// 拖动进度条时的预览位置。
  ///
  /// 拖拽过程中不能直接 seek（会把 mpv 拖垮，而且松手前的位置没有意义），
  /// 所以先记在这里让滑块跟手，松手时才真正 `seek`。
  Duration? _seekPreview;

  /// 本窗口有没有成功注册为跨引擎通道的配对一方。
  bool _channelReady = false;
  String? _channelError;

  /// 进度回报的节流器（每 10 秒一次）。
  final ProgressThrottle _progressThrottle = ProgressThrottle();

  /// 「刷新直链」的重试闸。
  final TicketRefreshGuard _refreshGuard = TicketRefreshGuard();

  /// 当前这条流对应的请求。
  ///
  /// null 表示**没有对应的库记录**（内置自检视频 / 手输直链）—— 此时既不
  /// 回报进度，也没有可刷新的来源。
  ///
  /// 用一个对象而不是几个散字段（itemId / qualityId / …）：它们必须同时有效
  /// 才有意义，拆开就容易出现「清了 itemId 忘了清 qualityId」这种半有效状态。
  PlayRequest? _currentRequest;

  /// 是否正在刷新直链。
  ///
  /// **与 [_busy] 分开**：`_busy` 是给按钮看的（禁用态），这条是防重入的。
  /// 混用会吞掉该有的刷新 —— 直链过期导致的 mpv 报错经常在上一次 `open()`
  /// 还没返回时就到了，那时 `_busy` 是 true。
  bool _refreshing = false;

  /// mpv 的流订阅。释放时要显式取消。
  final List<StreamSubscription<Object?>> _subs = [];

  @override
  void initState() {
    super.initState();
    // 引导流程要碰平台通道，放到首帧之后 —— 在 initState 里直接 await 会让
    // 第一帧迟迟出不来，窗口看起来像卡住了。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _urlController.dispose();
    unawaited(_releasePlayer());

    // ⚠️ 这行日志是**探针**，不要当成普通日志删掉。
    //
    // `desktop_multi_window` 的 macOS 侧在关窗时只做
    // `MultiWindowManager.removeWindow(windowId:)`（见插件 `FlutterWindow.swift`
    // 的 `NSWindow.willCloseNotification` 观察者）—— 它**不通知 Dart**。
    //
    // 所以「关窗后声音还在放吗」取决于引擎到底有没有被销毁：
    //   1. 引擎随窗口销毁 → 本方法执行 → 这行会出现在日志里；
    //   2. 引擎不销毁 → 本方法不执行 → 日志里没有这行。
    // 关窗后去诊断页搜「播放窗口已释放」即可判定。
    //
    // 无论哪种情况，原生侧的 `windowWillClose` 都会发一次 `onClosing`
    // （见 `child_window_channel.dart`），以及页面上那个「停止并关闭」
    // 按钮会走确定性的释放路径。
    diag.info('播放窗口', '播放窗口已释放（dispose 执行了）');

    super.dispose();
  }

  // -------------------------------------------------------------------
  // 释放
  // -------------------------------------------------------------------

  /// 停止播放并释放 mpv。**幂等**。
  ///
  /// 三条路都会走到这里，而且它们会互相重叠（关窗通知 + dispose 常常
  /// 前后脚发生），所以必须幂等 —— 重复 `dispose()` 一个已释放的 [Player]
  /// 会抛。
  ///
  /// **不调用 `setState`**：它可能从 `dispose()` 里被调到。
  Future<void> _releasePlayer() async {
    // 解除窗口的比例锁：没有片源了，让用户自由拖动窗口。
    //
    // 放在早退之前 —— 一次都没播过时也该保证窗口不被锁着（否则上一次
    // 播放留下的比例会一直生效）。
    _videoAspect = null;
    unawaited(setChildWindowAspectRatio(null));

    final player = _player;
    if (player == null) return;
    _player = null;
    _controller = null;
    _currentRequest = null;
    _refreshing = false;
    _refreshGuard.reset();

    // 先取消订阅：否则 dispose 过程中还可能触发一次进度回报，
    // 而那会在通道上打一条指向已释放播放器的消息。
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();

    try {
      // 先 stop 再 dispose：stop 会释放解码器与网络连接，
      // 让 dispose 之后的清理更快、更干净。
      await player.stop();
    } catch (_) {
      // 引擎可能已经在拆了。停不下来不影响下一步的 dispose。
    }
    try {
      await player.dispose();
      diag.info('播放窗口', '已释放播放器（stop + dispose）');
    } catch (e) {
      diag.warn('播放窗口', '释放播放器失败：$e');
    }
  }

  /// 先释放再关窗。**这是确定性的那条路** —— 不依赖关窗通知的时序。
  Future<void> _stopAndClose() async {
    await _releasePlayer();
    await closeChildWindow();
  }

  // -------------------------------------------------------------------
  // 窗口形态：全屏 / 置顶
  // -------------------------------------------------------------------

  /// 原生回报的全屏状态变化。
  ///
  /// 存在的意义是「**系统自己退出了全屏**」这条路 —— 按 Esc、点绿灯、
  /// 三指手势都不经过我们的通道。少了它，界面会一直以为自己还在全屏，
  /// 于是那条全屏退出栏继续挂在窗口底下，而窗口已经变回带标题栏的形态。
  Future<void> _onFullScreenChanged(bool fullScreen) async {
    if (!mounted || _fullScreen == fullScreen) return;
    setState(() => _fullScreen = fullScreen);
  }

  /// 切换全屏。
  Future<void> _setFullScreen(bool on) async {
    if (!mounted) return;
    // 先本地置上：原生那边是全屏**动画**，等回调再刷新按钮会让它迟一拍。
    // 真状态仍以 [_onFullScreenChanged] 为准。
    final previous = _fullScreen;
    setState(() => _fullScreen = on);

    if (await setChildWindowFullScreen(on)) return;

    // 原生侧没接上（通道没装好 / 平台不支持）→ 把界面回滚。
    // 不回滚的话按钮会显示「已全屏」而窗口纹丝不动，用户只会觉得按钮坏了。
    if (!mounted) return;
    setState(() => _fullScreen = previous);
    _toast('当前平台不支持切换全屏');
  }

  /// 切换置顶。
  Future<void> _setAlwaysOnTop(bool on) async {
    if (!mounted) return;
    final previous = _alwaysOnTop;
    setState(() => _alwaysOnTop = on);

    if (await setChildWindowAlwaysOnTop(on)) return;

    if (!mounted) return;
    setState(() => _alwaysOnTop = previous);
    _toast('当前平台不支持窗口置顶');
  }

  // -------------------------------------------------------------------
  // 引导：装关窗回调 → 入场 → 拉请求 → 自检
  // -------------------------------------------------------------------

  Future<void> _bootstrap() async {
    // 原生通知要**最先**装：万一窗口起得很慢、用户在引导完成前就把它关了，
    // 也还有机会释放。
    //
    // ⚠️ 两个回调必须**一次装完**：`setMethodCallHandler` 是覆盖式的，
    // 分两次装会让先装的那个静默失效。
    await registerChildWindowHandlers(
      onClosing: _releasePlayer,
      onFullScreenChanged: _onFullScreenChanged,
    );

    // 顺序是硬要求，不能换：
    //   1. 先入场（注册跨引擎通道）。原生侧要求**调用方自己也在配对里**，
    //      不先注册就去拉请求，拿到的一定是 `CHANNEL_UNREGISTERED`。
    //   2. 再拉待播请求（新窗口必须走这条，理由见 bridge 里的说明）。
    //   3. 最后自检 —— 它要 ping，也需要通道已经入场。
    await _enterChannel();
    final request = await _pullPendingPlay();
    if (request != null) unawaited(_playRequest(request));
    await _runSelfCheck();
  }

  /// 注册为跨引擎通道的配对一方。返回是否成功。
  Future<bool> _enterChannel() async {
    try {
      await playerWindowChannel.setMethodCallHandler(_onMainWindowCall);
      _channelReady = true;
      _channelError = null;
      return true;
    } on WindowChannelException catch (e) {
      _channelReady = false;
      _channelError = '${e.code}：${e.message}';
      return false;
    } catch (e) {
      _channelReady = false;
      _channelError = '$e';
      return false;
    }
  }

  /// 主窗口发过来的请求。
  ///
  /// 协议层面的事情（心跳）交给 [handleMainWindowCall]，这里只加**行为**：
  /// 「播这个」要真的去操作播放器。
  Future<Object?> _onMainWindowCall(MethodCall call) async {
    if (call.method == PlayerBridgeMethod.play) {
      final request = PlayRequest.fromJson(call.arguments);
      if (request == null) {
        diag.warn('播放窗口', '收到解不开的播放请求，忽略');
        return null;
      }
      diag.info('播放窗口', '主窗口推来播放请求：${request.describe()}');
      unawaited(_playRequest(request));
      return null;
    }
    return handleMainWindowCall(call);
  }

  /// 向主窗口要那条「开窗时就该播」的请求。
  Future<PlayRequest?> _pullPendingPlay() async {
    if (_channelReady) {
      try {
        final raw = await playerWindowChannel
            .invokeMethod<Object?>(PlayerBridgeMethod.fetchPendingPlay);
        final request = PlayRequest.fromJson(raw);
        if (request != null) {
          diag.info('播放窗口', '从主窗口取到播放请求：${request.describe()}');
          return request;
        }
      } catch (e) {
        diag.warn('播放窗口', '拉取待播请求失败：$e');
      }
    }
    // 拉不到就退回**启动参数**里那份兜底：主窗口建窗时一并塞进了入口参数。
    // 这条路不依赖通道，所以通道真出问题时窗口至少还能把片播出来。
    return PlayRequest.fromJson(widget.launch.payload);
  }

  // -------------------------------------------------------------------
  // 自检
  // -------------------------------------------------------------------

  Future<void> _runSelfCheck() async {
    final checks = <_SelfCheck>[];

    checks.add(
      _SelfCheck(
        '窗口引擎',
        widget.launch.windowId.isEmpty
            ? '已启动，但没拿到 windowId'
            : 'windowId = ${widget.launch.windowId}',
        ok: true,
      ),
    );

    // path_provider 是「原生插件有没有在**这个引擎**上注册成功」最直接的证据：
    // 子窗口是独立引擎，`MainFlutterWindow.swift` 里那句
    // `RegisterGeneratedPlugins(registry: controller)` 没生效的话，
    // 这里会抛 MissingPluginException。
    try {
      final dir = await getApplicationSupportDirectory();
      checks.add(_SelfCheck('原生插件注册', dir.path, ok: true));
    } catch (e) {
      checks.add(_SelfCheck('原生插件注册', '$e', ok: false));
    }

    // mpv：`Player()` 的构造会去加载 libmpv。这一步过了，说明整个媒体栈在
    // 这个引擎里可用；过不了，播放窗口就没有存在的意义。
    try {
      _ensurePlayer();
      checks.add(const _SelfCheck('libmpv', 'Player 构造成功', ok: true));
    } catch (e) {
      checks.add(_SelfCheck('libmpv', '$e', ok: false));
    }

    checks.add(
      _SelfCheck(
        '通道入场（本窗口）',
        _channelReady ? '已注册为配对的一方' : (_channelError ?? '未注册'),
        ok: _channelReady,
      ),
    );

    // 跨引擎通道：这是**唯一**能证明两个引擎真的连上了的证据 ——
    // 引擎起得来、插件注册得上，都不代表通道通。
    if (_channelReady) {
      try {
        final reply = await playerWindowChannel
            .invokeMethod<String>(PlayerBridgeMethod.ping);
        checks.add(_SelfCheck('跨引擎通道', '主窗口回话：$reply', ok: true));
      } on WindowChannelException catch (e) {
        checks.add(_SelfCheck('跨引擎通道', '${e.code}：${e.message}', ok: false));
      } catch (e) {
        checks.add(_SelfCheck('跨引擎通道', '$e', ok: false));
      }
    } else {
      checks.add(const _SelfCheck('跨引擎通道', '跳过：本窗口没入场', ok: false));
    }

    if (!mounted) return;
    setState(() => _checks = checks);
  }

  /// 惰性建播放器。
  ///
  /// 两条硬约束（都是踩过的坑）：
  ///   1. `VideoController` 必须绑定到**正在播放的那个** [Player]，不能另建一个；
  ///   2. 必须在任何 `open()` 之前建出来。
  /// 违反任一条的表现都是「有声音、进度条在走，但画面全黑，且不报错」。
  void _ensurePlayer() {
    if (_player != null) return;
    // ⚠️ 必须把日志级别抬到 `warn`。这不是「顺手多要点日志」，而是过期检测的
    // **必要条件** —— 完整实测记录见 [isHttp4xxLog] 的文档。
    //
    // 一句话：`mpv_request_log_messages` 的语义是「该级别**及以上严重**的消息
    // 才发」，而实测 `HTTP error 403` 是 **warn** 级（比 error 轻）。media_kit
    // 默认是 `MPVLogLevel.error`，那条消息**根本不会被发送到 Dart**。
    //
    // 抬到 warn 只影响 `stream.log` 的流量（warn 级本来就很少），
    // `stream.error` 完全不受影响：media_kit 仍然只挑 `level == 'error'` 的。
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    // 先记下来：万一下一行抛异常，dispose 也还能回收这个原生实例。
    _player = player;
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    // 进度回报。挂在 `position` 上而不是用计时器：位置流本身就是「播到哪了」
    // 的唯一真相，用计时器反而要在暂停时额外判断。
    _subs.add(
      player.stream.position.listen((position) {
        unawaited(_onPosition(position));
      }),
    );

    // 播放错误。mpv 的报错很笼统（`Failed to open ...`），但对用户来说
    // 「播不了」这个结论是准确的 —— 具体原因看诊断日志。
    //
    // ⚠️ 这里**不只是记日志**：网盘直链是带签名的临时 URL，过期后的表现正是
    // 一条 mpv 报错（拖进度条会重新发 Range 请求，所以最常见的症状是
    // 「播到一半一拖就报错」）。
    //
    // 但这条路只是过期检测的**一半**：它拿到的是二级症状（`Failed to open`），
    // 一级证据（HTTP 4xx）走下面那条 `stream.log`。两者分工见 [isHttp4xxLog]。
    _subs.add(
      player.stream.error.listen((msg) {
        unawaited(_onPlayerError(msg));
      }),
    );

    // mpv 的日志。这条订阅是过期检测的另一半：
    //
    // `stream.error` 看不到最直接的那条证据（`http: HTTP error 4xx`），
    // 原因是**级别**（实测它是 warn，而 media_kit 默认只请求 error）叠加上
    // media_kit 自己的前缀过滤。详见 [isHttp4xxLog] 顶部的实测记录。
    //
    // 不能改成「把 `stream.error` 的口径放宽」—— 那条消息**根本没进来**，
    // 放宽也够不着。
    //
    // ⚠️ 这条订阅能不能收到东西，取决于 `_ensurePlayer` 里把日志级别抬到了
    // `warn`。两处是**配套**的，改一处必须改另一处。
    _subs.add(
      player.stream.log.listen((entry) {
        if (!isHttp4xxLog(entry.text)) return;
        unawaited(_onTicketExpiryLog(entry));
      }),
    );

    // 播放/暂停状态。控制栏那个按钮要跟着它变 —— 否则会一直显示
    // 「播放」而实际在播放，语义正好反过来。
    _subs.add(
      player.stream.playing.listen((playing) {
        if (!mounted || _playing == playing) return;
        setState(() => _playing = playing);
      }),
    );

    // 视频尺寸。用来定窗口的形状 —— 见 [_onVideoParams]。
    _subs.add(
      player.stream.videoParams.listen((params) {
        unawaited(_onVideoParams(params));
      }),
    );
  }

  // -------------------------------------------------------------------
  // 窗口形状跟着视频走
  // -------------------------------------------------------------------

  /// 视频参数变了 → 把窗口调成这个片子的形状。
  ///
  /// ## 为什么必须做这件事
  ///
  /// 窗口建出来是 16:9（1200×675）。放 2.35:1 的宽银幕片时，画面区域只有
  /// 中间一条，上下两条大黑边 —— 用户既不知道要自己拖，也不知道该拖成多少。
  /// 反过来放 4:3 的老片又会左右留黑边。所以由视频自己决定窗口形状。
  ///
  /// 三件事一起做：
  ///   1. 本地记下比例（画面按它铺）；
  ///   2. 推给原生锁 `contentAspectRatio` —— 之后用户拖动窗口也保持这个形状；
  ///   3. 顺手把窗口尺寸调成「整块画面都看得见」（原生侧做）。
  Future<void> _onVideoParams(VideoParams params) async {
    // 优先 `aspect`（显示比例，含像素宽高比修正）；它缺失时退回 `dw/dh`
    // （已按正确比例缩放过的尺寸）；再不行才用像素宽高。
    final aspect = _pickAspect(params);
    if (aspect == null) return;
    // 容差 1e-3：mpv 会在播放过程中反复重发几乎相同的值，
    // 不挡一下就会每次 tick 都去 resize 一次窗口（画面会抖）。
    if (_videoAspect != null && (_videoAspect! - aspect).abs() < 0.001) return;

    diag.info(
      '播放窗口',
      '视频尺寸 ${params.w}x${params.h}（显示比例 ${aspect.toStringAsFixed(4)}）→ 调整窗口形状',
    );
    if (mounted) setState(() => _videoAspect = aspect);
    await setChildWindowAspectRatio(aspect);
  }

  /// 从 [VideoParams] 里挑一个能用的显示宽高比。
  static double? _pickAspect(VideoParams params) {
    final aspect = params.aspect;
    if (aspect != null && aspect.isFinite && aspect > 0.05) return aspect;

    final dw = params.dw;
    final dh = params.dh;
    if (dw != null && dh != null && dw > 0 && dh > 0) return dw / dh;

    final w = params.w;
    final h = params.h;
    if (w != null && h != null && w > 0 && h > 0) return w / h;

    return null;
  }

  // -------------------------------------------------------------------
  // 进度回报
  // -------------------------------------------------------------------

  /// 位置流入口：先喂刷新闸，再回报进度。
  ///
  /// 两件事挂在同一个流上是有意的 —— 它们共用同一个「播到哪了」的真相：
  /// 刷新闸要判断「重开之后位置有没有真的往前走」，那正是这个值。
  Future<void> _onPosition(Duration position) async {
    // 刷新后能连续播过一段，说明这次刷新是有效的 —— 把自动重试计数清零。
    // 不这么做的话，一部长片里撞上两三次过期就把额度用满了。
    if (_refreshGuard.observe(position, now: DateTime.now())) {
      diag.info('播放窗口', '直链刷新有效，自动刷新计数已清零');
    }
    await _reportProgress(position);
  }

  /// 把播放位置回报给主窗口，由它落库。
  ///
  /// **只在有库记录且通道可用时回报**：内置自检视频、手输直链都没有对应的
  /// 库记录，报上去只会让主窗口去更新一个不存在的行。
  ///
  /// 节流靠 [ProgressThrottle] 的「整十秒边界」—— 不节流的话每秒会往方法
  /// 通道打 10 条消息。
  Future<void> _reportProgress(Duration position) async {
    final itemId = _currentRequest?.itemId ?? '';
    if (itemId.isEmpty || !_channelReady) return;

    final due = _progressThrottle.accept(position);
    if (due == null) return;

    try {
      await playerWindowChannel.invokeMethod<void>(
        PlayerBridgeMethod.reportProgress,
        PlaybackProgressReport(
          itemId: itemId,
          position: due,
          duration: _player?.state.duration ?? Duration.zero,
        ).toJson(),
      );
    } catch (e) {
      // 丢一次回报只影响「最近播放」的精度，不该打断播放。
      diag.debug('播放窗口', '进度回报失败：$e');
    }
  }

  // -------------------------------------------------------------------
  // 刷新过期直链
  // -------------------------------------------------------------------

  /// `stream.error` 上的 mpv 报错。
  ///
  /// 这条路管的是**二级症状**（`Failed to open <url>.`），它只在「打开时就
  /// 已经过期」的情况下出现。播到一半才过期的那条一级证据走
  /// [isHttp4xxLog] 那条 `stream.log` 路径 —— 两条刻意不重叠，理由见那里的说明。
  ///
  /// 过滤口径仍然放宽（任何带 failed / error 的都试一次），因为**漏判的代价**
  /// 是「播到一半卡死、用户只能关窗重开」。误判的代价由 [TicketRefreshGuard]
  /// 兜住：非时效性的失败刷几次就会停，同一次故障的回声由它的冷却窗口收掉。
  Future<void> _onPlayerError(String message) async {
    final lower = message.toLowerCase();
    // 与内置播放页同一套过滤：mpv 的告警里也常带 'error' 字样，
    // 不值得为它重开一次流。
    if (!lower.contains('failed') && !lower.contains('error')) return;

    // ⚠️ 必须**先抹直链再落日志**。mpv 的 `Failed to open %s.` 会把完整 URL
    // 带进来，而夸克直链的签名就在查询串里 —— 不抹的话它会被写进诊断日志
    // 文件，而那个文件是给用户复制粘贴用的。理由详见 [redactUrls]。
    final safe = redactUrls(message);
    diag.warn('播放窗口', 'mpv 报错：$safe');

    if ((_currentRequest?.itemId ?? '').isEmpty) {
      // 没有库记录 → 没有可刷新的来源。如实告诉用户，别装作没事。
      _toast('播放出错：$safe');
      return;
    }
    await _refreshTicket(reason: safe);
  }

  /// `stream.log` 上发现了 HTTP 4xx —— 直链过期的**一级证据**。
  ///
  /// 与 [_onPlayerError] 的分工见 [isHttp4xxLog]。
  Future<void> _onTicketExpiryLog(PlayerLog entry) async {
    final safe = redactUrls(entry.text);

    if ((_currentRequest?.itemId ?? '').isEmpty) {
      // 没有库记录（内置自检视频 / 手输直链）→ 无从刷新，也不会连刷，
      // 所以这里记一条 warn 就够。
      //
      // **刻意不弹提示**：没有库记录时用户本来也只能自己换一条链，
      // 他会在画面上直接看到播不动。
      diag.warn('播放窗口', '直链疑似过期（${entry.prefix}）：$safe');
      return;
    }

    // ⚠️ 有库记录时**刻意用 debug 而不是 warn**。
    //
    // 实测：一次过期会连出十几条 403 —— ffmpeg 的 http 层带 reconnect，
    // 退避是 0s / 1s / 3s / 7s…，每一轮都再报一次。逐条打 warn 会把日志刷爆。
    //
    // 而真正有信息量的是 [_refreshTicket] 那行
    // 「请求刷新直链：… 原因：…」—— 它同时说了「发生了什么」和「我们打算怎么办」，
    // 而且一次故障只打一条（冷却窗口收掉回声）。
    diag.debug('播放窗口', '直链疑似过期（${entry.prefix}）：$safe');
    await _refreshTicket(reason: safe);
  }

  /// 向主窗口要一条新链，并**从当前位置续播**。
  ///
  /// [manual] 为 true 表示用户手动点的按钮：手动操作不受自动闸限制，
  /// 且先把计数清零（用户显然认为还有救）。
  Future<void> _refreshTicket({
    required String reason,
    bool manual = false,
  }) async {
    if (!mounted || _refreshing) return;

    final request = _currentRequest;
    if (request == null || request.itemId.isEmpty) return;

    if (!_channelReady) {
      diag.warn('播放窗口', '跨引擎通道不可用，无法刷新直链');
      _toast('跨窗口通道不可用，刷新不了直链');
      return;
    }

    // 位置要在重开**之前**取：报错之后 mpv 的 position 可能已经归零，
    // 那样刷新会把用户丢回片头。
    final position = _player?.state.position ?? request.startPosition;

    if (manual) {
      // 手动刷新清空计数，但**照样重新起冷却**：手动刷新也会招来旧流那批
      // 403 回声，不重新起算的话它们立刻就把刚清空的额度烧掉。
      // 理由见 [TicketRefreshGuard.reset]。
      _refreshGuard.reset(now: DateTime.now());
    } else if (!_refreshGuard.begin(position, now: DateTime.now())) {
      // ⚠️ `begin` 返回 false 有**两种**原因，必须分开对待 ——
      // 混在一起会变成「一次故障的回声弹好几条提示」或者
      // 「用满了却什么都不说」。判据是 `exhausted`。
      if (_refreshGuard.exhausted) {
        diag.warn(
          '播放窗口',
          '自动刷新已用满 ${_refreshGuard.maxAttempts} 次，停止重试',
        );
        _toast('直链反复失效，已停止自动重试（可手动「重新取链并续播」）');
      } else {
        diag.debug('播放窗口', '自动刷新冷却中，跳过这条回声');
      }
      return;
    }

    _refreshing = true;
    setState(() => _busy = true);
    try {
      diag.info(
        '播放窗口',
        '请求刷新直链：${request.describe()} @ ${position.inSeconds}s'
        '（第 ${_refreshGuard.attempts} 次${manual ? "，手动" : ""}）原因：$reason',
      );
      final raw = await playerWindowChannel.invokeMethod<Object?>(
        PlayerBridgeMethod.refreshTicket,
        TicketRefreshRequest(
          itemId: request.itemId,
          qualityId: request.qualityId,
          position: position,
        ).toJson(),
      );
      final fresh = PlayRequest.fromJson(raw);
      if (fresh == null) {
        diag.warn('播放窗口', '主窗口刷不出新直链');
        _toast('直链刷新失败，请看诊断日志');
        return;
      }
      diag.info('播放窗口', '拿到新直链 → ${fresh.describe()}');
      // 换掉上下文：刷新后档位/标题可能变（服务端这次没给同一档），
      // 后续回报与再刷新都应当基于新请求。
      _currentRequest = fresh;
      await _openStream(
        fresh.url,
        fresh.describe(),
        headers: fresh.headers,
        startAt: position,
      );
    } catch (e, st) {
      diag.error('播放窗口', '刷新直链失败', error: e, stackTrace: st);
      _toast('直链刷新失败：$e');
    } finally {
      _refreshing = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  // -------------------------------------------------------------------
  // 播放
  // -------------------------------------------------------------------

  Future<void> _playRequest(PlayRequest request) async {
    // 把片名写到窗口标题栏。原生侧建窗时给的是默认标题「云影 · 播放器」，
    // 这里换成真实的片名 —— 任务栏/Dock 上才分得清是哪个窗口。
    unawaited(setChildWindowTitle(request.title));

    // 换片要先重置节流器：否则新片恰好停在上一部片报过的那个整十秒上时，
    // 那一次回报会被当成重复而吞掉。
    //
    // 刷新闸也要重置：上一部片的失败次数不该算到新片上。
    _currentRequest = request;
    _progressThrottle.reset();
    _refreshGuard.reset();

    await _play(
      request.url,
      request.describe(),
      headers: request.headers,
      startAt: request.startPosition,
    );
  }

  /// 播一条**没有库记录**的流：内置自检视频 / 手输直链。
  ///
  /// 必须清掉条目上下文。不清的话有个很隐蔽的后果：先播了库里的第 102 项，
  /// 再点「播放内置自检视频」，`_currentRequest` 还指着 102 —— 自检视频播到
  /// 10 秒时就把进度报成了 102，凭空污染「最近播放」，而且看不出是谁干的。
  Future<void> _playRaw(String uri, String label) async {
    _currentRequest = null;
    _progressThrottle.reset();
    _refreshGuard.reset();
    await _play(uri, label);
  }

  /// 用户或主窗口发起的播放。**带重入保护**。
  Future<void> _play(
    String uri,
    String label, {
    Map<String, String> headers = const <String, String>{},
    Duration startAt = Duration.zero,
  }) async {
    if (_busy) return;
    await _openStream(uri, label, headers: headers, startAt: startAt);
  }

  /// 真正去 `open` 一条流。**不带重入保护** —— 闸由调用方各负其责。
  ///
  /// 之所以要把这一步单独拆出来给 [_refreshTicket] 用：直链过期导致的报错
  /// 经常在上一次 `open()` **还没返回时**就到达了，那时 `_busy` 是 true，
  /// 走 [_play] 会被静默吞掉 —— 表现就是「刷新功能明明写了却从不生效」。
  Future<void> _openStream(
    String uri,
    String label, {
    Map<String, String> headers = const <String, String>{},
    Duration startAt = Duration.zero,
  }) async {
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      _ensurePlayer();
      // ⚠️ 请求头必须带上。夸克直链缺 Cookie 一律返回 412，
      // 表现是「能取到链、一播就报错」，而错误信息里看不出是缺头。
      //
      // 日志里**不打 url**：直链带签名查询串，诊断日志是给用户复制粘贴用的，
      // 不能成为泄露渠道。请求头同理，只打键名。
      diag.info('播放窗口', 'open → $label（请求头=${headers.keys.toList()}）');
      await _player!.open(Media(uri, httpHeaders: headers), play: true);
      if (startAt > Duration.zero) await _player!.seek(startAt);
      if (!mounted) return;
      setState(() => _nowPlaying = label);
    } catch (e, st) {
      diag.error('播放窗口', 'open 失败：$label', error: e, stackTrace: st);
      // 必须走 [_toast]：这里直接用 `ScaffoldMessenger.of(context)` 在这个
      // 组件里**一定失败**（理由见 [_messengerKey]）—— 而这条正是
      // 「一播就报错」的路径，用户最需要看到提示的时候反而会再抛一个异常。
      _toast('播放失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 弹提示用的 messenger。
  ///
  /// ⚠️ **必须用 key，不能用 `ScaffoldMessenger.of(context)`。**
  ///
  /// 这个类的 `context` 是 [PlayerWindowApp] **自己**的 element，而
  /// `MaterialApp`（以及它内部的 `ScaffoldMessenger`）是在 `build()` 里造出来
  /// 的、位于它**下面**。`of(context)` 只会顺着祖先链往上找 —— 而上面什么
  /// 都没有，于是直接抛 `No ScaffoldMessenger widget found`。
  ///
  /// 这个坑很阴：它只在**错误路径**上显形（播放出错、刷新用满、平台不支持），
  /// 平时一次都不会触发。等到真出错那天，用户看到的不是提示，而是另一条异常
  /// —— 提示系统自己成了故障源。
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// 弹一条提示。取 messenger 前先判 mounted —— 这个类里的调用点
  /// 多半在 `await` 之后或流回调里，那时窗口可能已经关了。
  void _toast(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _stop() async {
    await _player?.stop();
    if (!mounted) return;
    setState(() => _nowPlaying = null);
  }

  // -------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '云影 · 播放器',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      // 提示要用 key 拿 messenger，不能用 `ScaffoldMessenger.of(context)`。
      // 理由见 [_messengerKey] 的说明。
      scaffoldMessengerKey: _messengerKey,
      home: Scaffold(
        // 整窗都是画面底：窗口形状已经由原生锁成视频比例（见
        // `_onVideoParams`），所以画面之外不该再露出别的东西。
        backgroundColor: AppTheme.cinema,
        body: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            // 与桌面播放器的通行习惯一致：F 切换全屏、Esc 退出。
            const SingleActivator(LogicalKeyboardKey.keyF): () =>
                _setFullScreen(!_fullScreen),
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_fullScreen) {
                _setFullScreen(false);
              } else if (_showDiagnostics) {
                // 诊断页开着时 Esc 退回播放 —— 与「返回播放」按钮同义。
                setState(() => _showDiagnostics = false);
              }
            },
          },
          child: Focus(
            // 没有它快捷键收不到事件：`CallbackShortcuts` 只在自己处于焦点
            // 链上时才生效，而这个窗口里没有别的可聚焦控件。
            autofocus: true,
            child: _showDiagnostics ? _buildDiagnosticsPage() : _buildPlayer(),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 播放器（窗口化与全屏**共用同一套**布局）
  // -------------------------------------------------------------------

  /// 播放器主体：画面铺满，控制栏浮在底部。
  ///
  /// 全屏与窗口化**不再分两套布局**。原来分两套是因为窗口化那边是个可滚动的
  /// 诊断页、画面被夹在中间；现在诊断页挪走了，两种形态的唯一差别只剩
  /// 「窗口有多大」—— 那是原生的事，Dart 这边不必知道。
  Widget _buildPlayer() {
    return Stack(
      children: [
        Positioned.fill(child: _buildVideoSurface()),
        // ⚠️ 控制栏**浮在**画面底部，而不是单独占一行。这不是审美选择：
        // 它单独占一行的话，窗口的内容区就是「视频 + 固定高度的栏」，
        // 没有单一比例可言 —— 原生的 `contentAspectRatio` 需要一个数来锁住
        // 整个窗口，那就无从谈起了。浮在上面，内容区正好等于视频形状。
        Positioned(left: 0, right: 0, bottom: 0, child: _buildControlBar()),
      ],
    );
  }

  Widget _buildVideoSurface() {
    final controller = _controller;
    return GestureDetector(
      // 双击切全屏 —— 走**我们自己的**原生窗口全屏。
      //
      // ⚠️ 刻意不用 media_kit 自带的那一套：它默认的 `onEnterFullscreen`
      // 会在窗口**内部** push 一个 Navigator 路由（不是真的 macOS 全屏），
      // 而那条路由在 pop 时会对一个已经失活的 element 做
      // `dependOnInheritedWidgetOfExactType`，直接抛
      // 「Looking up a deactivated widget's ancestor is unsafe」。
      // 两套全屏机制并存只会互相打架，所以用 `controls: NoVideoControls`
      // 把它的控制栏与全屏一起关掉，全屏只留我们自己这一套。
      onDoubleTap: () => _setFullScreen(!_fullScreen),
      behavior: HitTestBehavior.opaque,
      child: ColoredBox(
        color: AppTheme.cinema,
        child: controller == null
            ? const Center(
                child: Text(
                  '还没有载入片源',
                  style: TextStyle(fontSize: 13, color: AppTheme.dim),
                ),
              )
            : Video(
                controller: controller,
                controls: NoVideoControls,
                fit: BoxFit.contain,
              ),
      ),
    );
  }

  Widget _buildControlBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      // 半透明黑：既压得住明亮的画面，又不会在暗场里显得像一块补丁。
      color: Colors.black.withValues(alpha: 0.55),
      child: Row(
        children: [
          IconButton(
            onPressed: _busy || _player == null
                ? null
                : () => _player!.playOrPause(),
            tooltip: _playing ? '暂停' : '播放',
            icon: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 22,
              color: Colors.white,
            ),
          ),
          _buildSeekBar(),
          _buildBarIcon(
            icon: Icons.refresh_rounded,
            tooltip: _currentRequest == null
                ? '重新取链（当前片源没有库记录，无从刷新）'
                : '重新取链并续播',
            onPressed: _busy || _currentRequest == null
                ? null
                : () => _refreshTicket(reason: '用户手动触发', manual: true),
          ),
          _buildBarIcon(
            icon: _alwaysOnTop
                ? Icons.push_pin_rounded
                : Icons.push_pin_outlined,
            tooltip: _alwaysOnTop ? '取消置顶' : '窗口置顶',
            onPressed: () => _setAlwaysOnTop(!_alwaysOnTop),
          ),
          _buildBarIcon(
            icon: Icons.monitor_heart_outlined,
            tooltip: '环境自检 / 出画验证',
            onPressed: () => setState(() => _showDiagnostics = true),
          ),
          _buildBarIcon(
            icon: _fullScreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            tooltip: _fullScreen ? '退出全屏（Esc）' : '全屏（F）',
            onPressed: () => _setFullScreen(!_fullScreen),
          ),
        ],
      ),
    );
  }

  Widget _buildBarIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 18,
      color: Colors.white,
      disabledColor: Colors.white24,
      icon: Icon(icon),
    );
  }

  /// 进度条 + 两端时间。
  ///
  /// 用 `StreamBuilder` 而不是把位置存进 State：`position` 是每 ~100ms 一条的
  /// 高频流，存进 State 会让**整个播放器**每秒重建十次（连 `Video` 一起）。
  /// 用 StreamBuilder 把重建限制在这条进度条内部。
  Widget _buildSeekBar() {
    final player = _player;
    if (player == null) return const Expanded(child: SizedBox.shrink());

    return Expanded(
      child: StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (context, durationSnapshot) {
          final total = durationSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (context, positionSnapshot) {
              final maxMs = total.inMilliseconds.toDouble();
              final hasDuration = maxMs > 0;
              final current =
                  _seekPreview ?? positionSnapshot.data ?? Duration.zero;

              return Row(
                children: [
                  _buildTimeLabel(current),
                  Expanded(
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: AppTheme.accent,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: AppTheme.accent,
                      ),
                      child: Slider(
                        value: hasDuration
                            ? current.inMilliseconds
                                .clamp(0, total.inMilliseconds)
                                .toDouble()
                            : 0,
                        max: hasDuration ? maxMs : 1,
                        // 时长还不知道时（还在解文件头）不给拖：拖了也没意义，
                        // 而且滑块会在真时长到达时突然跳一下。
                        onChanged: hasDuration
                            ? (v) => setState(() {
                                  _seekPreview =
                                      Duration(milliseconds: v.round());
                                })
                            : null,
                        // 拖拽过程中不 seek —— 那会把 mpv 拖垮，而且中间那些
                        // 位置本来就没有意义。松手才真的跳。
                        onChangeEnd: hasDuration
                            ? (v) async {
                                setState(() => _seekPreview = null);
                                await player.seek(
                                  Duration(milliseconds: v.round()),
                                );
                              }
                            : null,
                      ),
                    ),
                  ),
                  _buildTimeLabel(total),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildTimeLabel(Duration d) {
    return Text(
      _formatDuration(d),
      style: const TextStyle(
        fontSize: 11.5,
        color: Colors.white70,
        // 等宽数字：不然秒数从 9 跳到 10 时整条栏会左右抖。
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }

  /// `1:02:03` / `2:03`；未知时长给 `--:--`。
  static String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '--:--';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // -------------------------------------------------------------------
  // 诊断页（默认藏起来）
  // -------------------------------------------------------------------

  /// 自检 + 出画验证。
  ///
  /// 默认**不显示**。播放窗口的主职是出画，一堆日志和按钮摆在画面下面既占
  /// 地方，也容易让人以为播放器坏了（实测反馈正是如此）。但排查能力不能丢 ——
  /// 独立窗口出问题时最难的是「哪一环坏了」，所以留一个入口进得来。
  Widget _buildDiagnosticsPage() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _showDiagnostics = false),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('返回播放（Esc）'),
            ),
            const Spacer(),
            if (_videoAspect != null)
              Text(
                '视频比例 ${_videoAspect!.toStringAsFixed(3)}',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _buildHeader(),
        const SizedBox(height: 16),
        _buildChecks(),
        const SizedBox(height: 18),
        _buildControls(),
      ],
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          '播放器窗口',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.panel3,
            borderRadius: BorderRadius.circular(5),
          ),
          child: const Text(
            '独立窗口',
            style: TextStyle(fontSize: 10.5, color: AppTheme.muted),
          ),
        ),
        const Spacer(),
        if (_nowPlaying != null)
          Flexible(
            child: Text(
              _nowPlaying!,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ),
      ],
    );
  }

  Widget _buildChecks() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '环境自检',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _busy ? null : _runSelfCheck,
              icon: const Icon(Icons.refresh_rounded, size: 14),
              label: const Text('重新自检'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_checks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '正在自检…',
              style: TextStyle(fontSize: 12, color: AppTheme.dim),
            ),
          )
        else
          for (final check in _checks) _SelfCheckRow(check: check),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '出画验证',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              // 走 _playRaw：这条流没有库记录，不能把上一个片子的进度
              // 报成它的。
              onPressed: _busy
                  ? null
                  : () => _playRaw(kSelfTestAssetUri, '内置自检视频'),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('播放内置自检视频'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _stop,
              icon: const Icon(Icons.stop_rounded, size: 16),
              label: const Text('停止'),
            ),
            // 手动刷新直链。
            //
            // 自动刷新只在 mpv 报错时触发，而 mpv 对 HTTP 403 的措辞并不稳定
            // —— 漏判时用户需要一条自己能把片子救回来的路，否则只能关窗重开、
            // 再手动找进度。没有库记录时（自检视频 / 手输直链）刷新无从下手，
            // 所以那时按钮是灰的。
            OutlinedButton.icon(
              onPressed: _busy || _currentRequest == null
                  ? null
                  : () => _refreshTicket(reason: '用户手动触发', manual: true),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重新取链并续播'),
            ),
            // 窗口形态，与播放控制分开放。
            OutlinedButton.icon(
              onPressed: () => _setFullScreen(true),
              icon: const Icon(Icons.fullscreen_rounded, size: 17),
              label: const Text('全屏（F）'),
            ),
            OutlinedButton.icon(
              onPressed: () => _setAlwaysOnTop(!_alwaysOnTop),
              icon: Icon(
                _alwaysOnTop
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                size: 16,
              ),
              label: Text(_alwaysOnTop ? '已置顶' : '窗口置顶'),
            ),
            // 与「停止」分开：这个先**释放**再关窗，是关窗后还在出声时
            // 确定能停下来的那条路（不依赖关窗通知的时序）。
            TextButton.icon(
              onPressed: _busy ? null : _stopAndClose,
              icon: const Icon(Icons.close_rounded, size: 15),
              label: const Text('停止并关闭'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 直链入口：用来验证**真实片源**。内置自检视频只能证明渲染管线通，
        // 证明不了真实片源能播。
        //
        // ⚠️ 夸克直链走这里**播不了** —— 它需要 Cookie 请求头，而输入框只收
        // 一个地址。要验证夸克片源请从主窗口点播放，走的是带请求头的那条路。
        TextField(
          controller: _urlController,
          style: const TextStyle(fontSize: 12, color: AppTheme.text),
          decoration: InputDecoration(
            isDense: true,
            hintText: '粘贴一个**不需要请求头**的可播地址（本地文件 / 公开 http）',
            hintStyle: const TextStyle(fontSize: 12, color: AppTheme.dim),
            filled: true,
            fillColor: AppTheme.panel,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
            ),
          ),
          onSubmitted: (value) {
            final uri = value.trim();
            if (uri.isNotEmpty) _playRaw(uri, uri);
          },
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () {
                  final uri = _urlController.text.trim();
                  if (uri.isEmpty) return;
                  _playRaw(uri, uri);
                },
          icon: const Icon(Icons.link_rounded, size: 15),
          label: const Text('播放该地址'),
        ),
      ],
    );
  }
}

@immutable
class _SelfCheck {
  const _SelfCheck(this.title, this.detail, {required this.ok});

  final String title;
  final String detail;
  final bool ok;
}

class _SelfCheckRow extends StatelessWidget {
  const _SelfCheckRow({required this.check});

  final _SelfCheck check;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              check.ok
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              size: 14,
              color: check.ok ? AppTheme.ok : AppTheme.danger,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(
              check.title,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ),
          Expanded(
            child: SelectableText(
              check.detail,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontFamilyFallback: const ['Consolas', 'monospace'],
                fontSize: 11.5,
                height: 1.45,
                color: check.ok ? AppTheme.muted : AppTheme.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
