import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../providers/app_providers.dart';
import 'desktop_play.dart';
import 'player_window_bridge.dart';

/// 主窗口这一侧的「跨引擎服务台」。
///
/// 独立播放窗口跑在**自己的 Flutter 引擎**里，碰不到主窗口的 Riverpod 容器，
/// 需要什么都得通过通道问。这个 Provider 把主窗口能提供的两种服务装上：
///
///   1. [onPlaybackProgress] —— 播放窗口报「我看到这里了」，这里落库；
///   2. [onTicketRefresh] —— 播放窗口报「直链失效了」，这里重新取链。
///
/// ## 为什么必须由 UI 层装
///
/// `player_window_bridge.dart` 里的处理器在 `main()` 阶段就被注册了，那时
/// 还没有 Riverpod 容器、拿不到仓储与适配器。所以协议文件只声明两个可空的
/// 全局回调，由这里（容器已经起来之后）填上。
///
/// ## 为什么是「纯副作用 Provider」
///
/// 它不产出值，只负责装回调。用 `Provider` + 在 `CloudCineApp.build` 里
/// `watch` 它是 Riverpod 里的常规写法：容器销毁时 `onDispose` 会把回调摘掉，
/// 避免热重载后闭包还指向一个已经失效的 `ref`（那会在下一次回报时抛）。
final playerBridgeHostProvider = Provider<void>((ref) {
  // -------------------------------------------------------------------
  // 服务一：进度落库
  // -------------------------------------------------------------------
  //
  // 内置播放页那条路，进度落库挂在 `playbackControllerProvider` 的
  // `onPositionTick` 上（见 `app_providers.dart`）。但独立窗口那条路播放发生
  // 在**另一个引擎**里，主窗口的 `PlaybackController` 根本没被 `open()` 过，
  // 那个回调永远不会触发 → `lastPlayedAt` 不更新，「最近播放」排序与已看标记
  // 都停在上一次用内置播放页的时候。
  //
  // ⚠️ `markPlayed` 落的是**时间戳**，不是播放位置（库里没有存续播位置的
  // 字段）。所以这里丢的是「最近播放」，不是「续播」。
  onPlaybackProgress = (report) {
    diag.debug(
      '播放',
      '播放窗口回报进度：${report.itemId} @ ${report.position.inSeconds}s',
    );
    unawaited(
      ref
          .read(mediaRepositoryProvider)
          .markPlayed(report.itemId, DateTime.now())
          .catchError((Object e) {
        // 落库失败不该打断播放，但也不能静默 —— 否则「最近播放不更新」
        // 会变成一个无从查起的问题。
        diag.error('播放', '播放窗口进度落库失败：$e');
      }),
    );
  };

  // -------------------------------------------------------------------
  // 服务二：刷新过期直链
  // -------------------------------------------------------------------
  //
  // 播放窗口手里只有一条带签名的直链，它没有（也不该有）重新取链的能力 ——
  // 取链要凭证、要走四路由降级，那套东西留在主窗口。
  //
  // 这里用**同一份取链逻辑**（`buildPlayRequest`）换一条新链，并把播放窗口
  // 报来的位置填回 `startPosition`，于是刷新对用户表现为「卡一下接着播」
  // 而不是「从头开始」。选档也走同一个入口，所以刷新不会把用户手选的档位
  // 换成设置里的默认档。
  onTicketRefresh = (request) async {
    try {
      final item =
          await ref.read(mediaRepositoryProvider).itemById(request.itemId);
      if (item == null) {
        // 条目被删、或被重扫换过 id 时会走到这。
        diag.warn('窗口', '刷新直链失败：库里找不到 ${request.itemId}');
        return null;
      }
      return await buildPlayRequest(
        ref.read,
        item,
        qualityId: request.qualityId,
        startPosition: request.position,
      );
    } catch (e, st) {
      // 取链本身会失败（登录失效、网络断了、路由全挂）。
      // **返回 null 而不是让它抛**：抛出去会变成一条平台通道异常，
      // 播放窗口那边只能看到一句没头没尾的 `PlatformException`，
      // 而这里的日志已经把原因写清楚了。
      diag.error('窗口', '刷新直链时取链失败', error: e, stackTrace: st);
      return null;
    }
  };

  ref.onDispose(() {
    onPlaybackProgress = null;
    onTicketRefresh = null;
  });
});
