import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/diag_log.dart';
import 'player_protocol.dart';
import 'window_launch.dart';

/// 主窗口 ↔ 播放窗口的跨引擎通道。
///
/// 用 [ChannelMode.bidirectional] 是刻意的：插件允许**最多两个**引擎注册同一个
/// 通道名，且只有这两个能互相调用 —— 正好是「主窗口 + 一个播放窗口」的形状。
/// 换成 `unidirectional` 会让任何第三个窗口都能打进来，没有必要。
///
/// ⚠️ 代价：如果关掉的播放窗口其引擎没有真正销毁（见 `player_window_app.dart`
/// 里 `dispose()` 的探针注释），它的通道注册就不会注销，**再开一个播放窗口会
/// 撞 `CHANNEL_LIMIT_REACHED`**。那条报错出现即等于证明「引擎没销毁」。
const WindowMethodChannel playerWindowChannel = WindowMethodChannel(
  'cloudcine/player',
  mode: ChannelMode.bidirectional,
);

/// 协议方法名。集中在这里，免得主窗口和播放窗口各写一份字符串。
abstract final class PlayerBridgeMethod {
  /// 播放窗口 → 主窗口：「你在吗」。
  ///
  /// 它同时是**通道连通性**的判据：通道不通时 `invokeMethod` 会抛
  /// [WindowChannelException]，而那是唯一能证明两个引擎确实连上的证据 ——
  /// 引擎起得来、插件注册得上，都不代表通道通。
  static const String ping = 'ping';

  /// 主窗口 → 播放窗口：「播这个」。参数是 [PlayRequest.toJson]。
  static const String play = 'play';

  /// 播放窗口 → 主窗口：「开窗时那个请求给我」。
  ///
  /// 新窗口必须走这条路，不能由主窗口直接推 —— 原因见 [_pendingPlayRequest]。
  static const String fetchPendingPlay = 'fetchPendingPlay';

  /// 播放窗口 → 主窗口：「我看到这里了」。参数是
  /// [PlaybackProgressReport.toJson]。
  static const String reportProgress = 'reportProgress';

  /// 播放窗口 → 主窗口：「这条直链失效了，再给我一条」。参数是
  /// [TicketRefreshRequest.toJson]，返回 [PlayRequest.toJson] 或 null。
  ///
  /// 方向是**播放窗口发起**而不是主窗口定时推：直链过期只在下一次真正发起
  /// 请求时才暴露（最典型的是拖进度条触发 Range 请求），提前推一条新链既没有
  /// 触发时机，也会打断正在播的流。所以让它坏在哪、修在哪。
  static const String refreshTicket = 'refreshTicket';
}

/// 当前平台是否支持多窗口。
///
/// `desktop_multi_window` 只实现了 macOS / Windows / Linux；在 Android 上碰它的
/// 任何 API 都会抛 `MissingPluginException`。所有入口都要先过这道闸。
///
/// 用 [defaultTargetPlatform] 而不是 `dart:io` 的 `Platform`：前者是项目里
/// 既有的平台判定口径（见 `playback_exit_policy.dart`），且单测可以用
/// `debugDefaultTargetPlatformOverride` 覆盖。
bool get supportsMultiWindow =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// 播放窗口回报进度时，主窗口该做什么。
///
/// **必须由 UI 层装上**（见 `playerBridgeHostProvider`）：这个文件在
/// `main()` 里就被调用，那时还没有 Riverpod 容器，拿不到仓储。
/// 没装上时进度回报会被安静丢弃，只在日志里留一条 debug。
void Function(PlaybackProgressReport report)? onPlaybackProgress;

/// 播放窗口要求刷新直链时，主窗口该做什么。
///
/// 与 [onPlaybackProgress] 同样的理由必须由 UI 层装上（需要仓储与适配器）。
///
/// 返回 `null` 表示刷不出来（条目已不在库里、取链失败、平台不支持），
/// 播放窗口拿到 null 就应当**停在原地并如实告诉用户**，而不是反复重试 ——
/// 重试由它自己的 `TicketRefreshGuard` 管，这里只负责一次成败。
Future<PlayRequest?> Function(TicketRefreshRequest request)? onTicketRefresh;

/// 主窗口侧：还没被播放窗口取走的播放请求。
///
/// **为什么要有这个「待取」盒子，而不是创建窗口后直接把请求推过去** ——
/// 因为有时序竞争：`WindowController.create` 返回时，子窗口才刚开始起引擎，
/// 它注册跨引擎通道要等到第一帧之后。此刻推过去必然拿 `CHANNEL_UNREGISTERED`。
///
/// 所以投递分两条路：
///   - **新窗口 → 拉**：请求放进盒子，子窗口启动完成后自己来取（[PlayerBridgeMethod.fetchPendingPlay]）。
///   - **已有窗口 → 推**：那个引擎早就就绪，直接 `play`；推失败就留在盒子里，
///     等下次开窗被拉走。**不做重试循环** —— 那只会把一个已经失败的操作拖长。
///
/// 主窗口只有一个引擎，所以用进程内全局变量即可，不需要跨引擎存储。
PlayRequest? _pendingPlayRequest;

/// 仅测试用：读出/清空待取请求。
@visibleForTesting
PlayRequest? get debugPendingPlayRequest => _pendingPlayRequest;

@visibleForTesting
void debugSetPendingPlayRequest(PlayRequest? request) =>
    _pendingPlayRequest = request;

/// 主窗口侧：注册跨引擎通道的处理器。
///
/// **必须早于任何播放窗口的 ping**，否则播放窗口会拿到 `CHANNEL_UNREGISTERED`。
/// 调用点放在 `main()` 里、`runApp` 之前。
///
/// 失败不抛异常：多窗口只是 PC 端的增强能力，通道没注册上不该挡住应用启动。
Future<void> registerPlayerWindowBridge() async {
  if (!supportsMultiWindow) return;
  try {
    await playerWindowChannel.setMethodCallHandler(handlePlayerWindowCall);
    diag.info('窗口', '已注册播放器跨窗口通道');
  } catch (e) {
    diag.warn('窗口', '注册播放器跨窗口通道失败：$e');
  }
}

/// 主窗口侧：处理播放窗口发过来的请求。
@visibleForTesting
Future<Object?> handlePlayerWindowCall(MethodCall call) async {
  switch (call.method) {
    case PlayerBridgeMethod.ping:
      return 'pong';

    case PlayerBridgeMethod.fetchPendingPlay:
      final pending = _pendingPlayRequest;
      // 只交付一次。留着它会让「重新自检」反复把同一部片重新播一遍。
      _pendingPlayRequest = null;
      if (pending != null) {
        diag.info('窗口', '播放请求已被播放窗口取走：${pending.describe()}');
      }
      return pending?.toJson();

    case PlayerBridgeMethod.reportProgress:
      final report = PlaybackProgressReport.fromJson(call.arguments);
      if (report == null) {
        diag.warn('窗口', '收到解不开的进度回报，忽略');
        return null;
      }
      final handler = onPlaybackProgress;
      if (handler == null) {
        // 只在 debug 级别记：这条会每 10 秒来一次，用 warn 会刷屏。
        diag.debug('窗口', '收到进度回报但没有落库回调（UI 层还没装上）');
        return null;
      }
      handler(report);
      return null;

    case PlayerBridgeMethod.refreshTicket:
      final refresh = TicketRefreshRequest.fromJson(call.arguments);
      if (refresh == null) {
        diag.warn('窗口', '收到解不开的刷新请求，忽略');
        return null;
      }
      final refreshHandler = onTicketRefresh;
      if (refreshHandler == null) {
        // 用 warn 而不是 debug：正常运行时这条**不该出现**（UI 层一定会装上），
        // 出现即说明启动路径被改坏了。
        diag.warn('窗口', '播放窗口要求刷新直链，但没有装上取链回调');
        return null;
      }
      diag.info('窗口', '播放窗口要求刷新直链：$refresh');
      final fresh = await refreshHandler(refresh);
      if (fresh == null) {
        diag.warn('窗口', '刷新直链失败：$refresh');
        return null;
      }
      // 只打片名/档位/位置，不打新链 —— 直链带签名查询串。
      diag.info(
        '窗口',
        '已刷新直链 → ${fresh.describe()} @ ${fresh.startPosition.inSeconds}s',
      );
      return fresh.toJson();

    default:
      throw MissingPluginException('主窗口未实现的通道方法：${call.method}');
  }
}

/// 播放窗口侧：处理主窗口发过来的请求。
///
/// ⚠️ **这个函数必须被 `setMethodCallHandler` 注册上**，否则播放窗口连一句
/// `ping` 都发不出去。原因在原生 `ChannelRegistry.getTarget(for:from:)`：
/// bidirectional 通道的第一步是
///
/// ```swift
/// guard candidates.contains(where: { $0 === window }) else { return nil }
/// ```
///
/// 也就是**调用方自己也必须在配对里**。子窗口没注册过这个通道时，
/// `invokeMethod` 一律拿 `CHANNEL_UNREGISTERED` —— 那看起来像「插件不支持
/// 跨引擎通道」，实际上只是调用方没入场。这个坑踩过一次：自检页会把
/// 「我测试写错了」显示成「通道不通」，白跑一轮实测。
///
/// 这里只处理**协议层面**的方法（心跳）。[PlayerBridgeMethod.play] 要真的去
/// 操作播放器，所以由 `PlayerWindowApp` 包一层再挂上去，不放进这个纯函数。
Future<Object?> handleMainWindowCall(MethodCall call) async {
  switch (call.method) {
    case PlayerBridgeMethod.ping:
      return 'pong';
    default:
      throw MissingPluginException('播放窗口未实现的通道方法：${call.method}');
  }
}

/// 主窗口侧：打开（或复用）播放器窗口。
///
/// **复用优先** —— 对应夸克网盘的 `GetOrCreatePlayerWindow`。反复点播放却每次
/// 都新开一个窗口，用户很快就会攒下一堆播放器窗口，而且每个窗口都占着一个
/// 引擎和一份 mpv 解码资源。
class PlayerWindowLauncher {
  const PlayerWindowLauncher();

  /// 打开窗口并投递 [request]（可为 null = 只开一个空播放窗口）。
  ///
  /// 返回被打开/复用的窗口控制器；平台不支持时为 null。
  /// **不抛异常**：开不了窗口是调用方要处理的正常结果，不是异常路径。
  Future<WindowController?> open([PlayRequest? request]) async {
    if (!supportsMultiWindow) {
      // 明确记一行：否则「点了播放什么都没发生」在日志里完全无迹可寻。
      diag.info('窗口', '当前平台不支持独立播放窗口，应走内置播放页');
      return null;
    }

    _pendingPlayRequest = request;

    final existing = await findExisting();
    if (existing != null) {
      await existing.show();
      diag.info('窗口', '复用已有播放窗口 ${existing.windowId}');
      if (request != null && await _push(existing, request)) {
        _pendingPlayRequest = null;
      }
      return existing;
    }

    final controller = await WindowController.create(
      WindowConfiguration(
        // 入口参数里也带一份请求：它是**兜底**。正常情况下播放窗口会通过
        // `fetchPendingPlay` 来取（那条路没有时序竞争），但万一拉取失败，
        // 窗口至少还能从自己的启动参数里把片子播出来。
        arguments: encodeWindowLaunch(
          WindowKind.player,
          request?.toJson() ?? const <String, Object?>{},
        ),
        hiddenAtLaunch: false,
      ),
    );
    diag.info('窗口', '新建播放窗口 ${controller.windowId}');
    return controller;
  }

  /// 找出已经存在的播放窗口；没有则返回 null。
  Future<WindowController?> findExisting() async {
    if (!supportsMultiWindow) return null;
    for (final controller in await WindowController.getAll()) {
      // 复用 [parseWindowLaunch] 而不是自己判字符串：窗口类型的判定规则只能有
      // 一处，否则将来加了新窗口类型，这里就会漏。
      final launch = parseWindowLaunch(
        <String>[
          kMultiWindowEntryToken,
          controller.windowId,
          controller.arguments,
        ],
      );
      if (launch.isPlayer) return controller;
    }
    return null;
  }

  /// 推一条播放请求给**已经就绪**的播放窗口。成功返回 true。
  ///
  /// 走 [playerWindowChannel]（bidirectional）而不是 `controller.invokeMethod`：
  /// 后者用的是 `mixin.one/window_controller/<id>` 那个**单向**通道，要求子窗口
  /// 先 `setWindowMethodHandler` 才算注册；而 bidirectional 通道两边都已经
  /// 注册过了，直接就能投。
  Future<bool> _push(WindowController controller, PlayRequest request) async {
    try {
      await playerWindowChannel
          .invokeMethod<void>(PlayerBridgeMethod.play, request.toJson());
      diag.info('窗口', '已推送播放请求 → ${request.describe()}');
      return true;
    } on WindowChannelException catch (e) {
      // 多半是子窗口还没注册（引擎仍在起）。留给它自己来取，不重试。
      diag.warn('窗口', '推送播放请求失败（${e.code}），留给播放窗口主动来取');
      return false;
    } catch (e) {
      diag.warn('窗口', '推送播放请求失败：$e');
      return false;
    }
  }
}
