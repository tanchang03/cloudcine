import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/services/follow_service.dart';
import '../../domain/services/media_discovery.dart';
import '../../domain/services/scan_service.dart';
import 'app_providers.dart';
import 'drive_browse_providers.dart';
import 'library_providers.dart';
import 'library_refresh_providers.dart';
import 'scan_providers.dart';

/// 追更检查的进度 / 结果快照。
///
/// 与 `DiscoveryState` / `ScanState` 同一形状（running + progress + outcome +
/// error），刻意**不合并**它们：三者回答的是三件不同的事，而 UI 需要同时
/// 显示「正在扫描」和「正在检查更新」—— 合成一个状态机之后，
/// 后开始的那个会把前一个的进度盖掉。
@immutable
class FollowState {
  const FollowState({
    this.running = false,
    this.progress,
    this.outcome,
    this.error,
  });

  final bool running;

  /// 检查进度（`done / total` 个目录）。`running` 为假时是 `null`。
  final FollowProgress? progress;

  /// 上一次跑完的结果。**只在跑完之后有值**，用来决定要不要弹提示。
  final FollowOutcome? outcome;

  /// 面向用户的失败原因。与 [outcome] 互斥（失败时没有 outcome）。
  final String? error;

  FollowState copyWith({
    bool? running,
    FollowProgress? progress,
    FollowOutcome? outcome,
    String? error,
    bool clearProgress = false,
    bool clearOutcome = false,
    bool clearError = false,
  }) {
    return FollowState(
      running: running ?? this.running,
      progress: clearProgress ? null : (progress ?? this.progress),
      outcome: clearOutcome ? null : (outcome ?? this.outcome),
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  String toString() =>
      'FollowState(running=$running, progress=$progress, '
      'outcome=$outcome, error=${error ?? "-"})';
}

/// 追更检查的**组合根接线**：把 [FollowService] 需要的三样东西凑齐。
///
/// ## ⛔ 这里持有的必须是**同一个** `FollowService` 实例
///
/// `FollowService._running` 是防并发的那把锁（两次并发检查会各自读到同一个
/// 水位线、各自把增量写一遍 ⇒ **角标翻倍**，而且不报错）。`Provider` 天然
/// 缓存实例，所以这条是自动成立的 —— 但别改成 `autoDispose`，那会在没人
/// 监听时销毁并重建，锁就没了。
final followServiceProvider = Provider<FollowService>((ref) {
  return FollowService(
    library: ref.watch(mediaRepositoryProvider),
    settings: ref.watch(settingsStoreProvider),
    // ⛔ 适配器**写死** `recursive: true`（见 [followDiscoveryAdapter]）：
    //    剧集常在 `S01/` 子目录里，只看一层会永远发现不了新集。
    // ⛔ 每次列目录都**现建**一个 `MediaDiscoveryService`（`buildScanPolicy`
    //    现读设置），与 `DiscoveryController._buildService` 一致 ——
    //    缓存一份的话，用户在设置页改了并发 / 限速要重启才生效。
    discoverDirectory: followDiscoveryAdapter(
      buildService: () async => MediaDiscoveryService(
        registry: ref.read(adapterRegistryProvider),
        library: ref.read(mediaRepositoryProvider),
        policy: await buildScanPolicy(ref),
      ),
      provider: browseProvider,
    ),
  );
});

/// 追更检查的控制器：**发起、转播进度、取消、刷新**。
///
/// 真正的逻辑在 [FollowService]（无 UI 依赖，可单测）。
class FollowController extends Notifier<FollowState> {
  ScanCancellation? _cancel;
  bool _disposed = false;

  @override
  FollowState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return const FollowState();
  }

  /// 请求停止。协作式：在目录边界生效。
  void cancel() => _cancel?.cancel();

  /// 现在能不能发起一次检查。
  ///
  /// ⛔ **全盘扫描在跑的时候不能**。理由与 `DiscoveryController.canStart`
  ///    完全相同：两边的节流器是各自的实例，并发跑等于把实际 QPS 翻倍
  ///    （夸克那条约 3 QPS 的安全线会被顶穿），而且两个任务会同时往同一批
  ///    作品行上写。
  ///
  /// ⛔ 这是**单向**守卫（追更让着扫描），与 discovery 那边一致：
  ///    反方向检查会让 `scan_providers` 与这里互相 import。
  bool get canStart =>
      !state.running && !ref.read(scanControllerProvider).running;

  /// 跑一次检查。
  ///
  /// @param force `true` = 手动入口（页头按钮）：无视节流窗口、也无视
  ///   `follow_auto_check` 是不是 `off`（用户明确要求了）。
  Future<void> start({bool force = false}) async {
    if (!canStart) return;

    final token = ScanCancellation();
    _cancel = token;
    _emit(const FollowState(running: true));

    try {
      final outcome = await ref.read(followServiceProvider).check(
            force: force,
            cancel: token,
            onProgress: (p) => _emit(FollowState(running: true, progress: p)),
          );
      _emit(FollowState(outcome: outcome));
    } catch (e) {
      diag.warn('追剧', '检查失败：$e');
      _emit(FollowState(error: _explain(e)));
    } finally {
      _cancel = null;
      // ⛔ 取消与失败**也改过库**（每列完一个目录就落盘了），所以刷新放在
      //    `finally` 里 —— 只刷成功路径会让取消之后角标停在旧值上。
      //    与 `DiscoveryController.discoverDirectory` 同一套理由。
      if (!_disposed) _refreshAfterWrite();
    }
  }

  /// 开启 / 取消追剧 —— 作品详情页那颗按钮唯一的写入入口。
  ///
  /// ## 为什么不让 UI 直接调仓储
  ///
  /// 写完必须刷新**四处**，各描述同一份数据的一个侧面：
  ///   * `workListProvider` —— 海报墙那一格（追剧栏里多一部 / 少一部）；
  ///   * `followedUpdateCountProvider` —— 分类栏「追剧 N」的角标；
  ///   * `libraryStatsProvider` —— 页头那句「N 个视频 · M 部作品」；
  ///   * `workDetailProvider(key)` —— **眼前这一页**。
  ///
  /// 最后一条是这一支独有的：[start] 的刷新只管「检查完之后各列表变了」，
  /// 而这里用户就站在这部作品的详情页上。漏掉它的表现是**点了按钮毫无反应**
  /// （库里已经追上了，眼前这颗却还写着「追剧」）—— 用户会再点一次，
  /// 于是又取消了，来回几下之后他会认为这个按钮坏了。
  /// 这类「写完没刷新」的 bug 不报错，只表现为「点不动」。
  ///
  /// ⛔ 清角标**不在这里做**：`MediaRepository.setFollowed` 开启时已经把
  ///    `new_item_count` 写 0 了（那一条要与水位线在同一个事务里写）。
  ///    这里再补一次 `setFollowNewItemCount` 等于同一件事写两遍 —— 而且第二次
  ///    写的时候 `follow_started_at` 已经变成「现在」了，语义开始含糊。
  Future<void> toggleFollow(String workKey, bool followed) async {
    await ref.read(mediaRepositoryProvider).setFollowed(workKey, followed);
    _refreshAfterWrite();
    ref.invalidate(workDetailProvider(workKey));
  }

  /// 写库之后的刷新。
  ///
  /// 与 `DiscoveryController._refreshAfterWrite` 同一套口径，另加一个
  /// [followedUpdateCountProvider]（分类栏「追剧 N」的角标）——
  /// 它是这次检查唯一改变的**聚合数字**，漏了它用户会看到
  /// 「海报上有角标，但分类栏还写着 0」。
  void _refreshAfterWrite() {
    ref.read(libraryWriteSignalProvider.notifier).bump();
    ref.invalidate(workListProvider);
    ref.invalidate(followedUpdateCountProvider);
    ref.invalidate(libraryStatsProvider);
  }

  String _explain(Object e) => '检查更新失败：$e';

  void _emit(FollowState next) {
    if (_disposed) return;
    state = next;
  }
}

final followControllerProvider =
    NotifierProvider<FollowController, FollowState>(FollowController.new);
