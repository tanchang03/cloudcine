import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/download_task_store_impl.dart';
import '../../domain/adapters/download_task_store.dart';
import '../../domain/entities/download_task.dart';
import '../../domain/services/download_queue.dart';
import '../../domain/services/drive_download.dart';
import 'app_providers.dart';
import 'drive_browse_providers.dart';
import 'settings_providers.dart';

/// 下载记录的持久化。
final downloadTaskStoreProvider = Provider<DownloadTaskStore>(
  (ref) => DriftDownloadTaskStore(ref.watch(databaseProvider)),
);

/// 下载队列的状态（全部下载记录）。
///
/// ## 为什么是 `NotifierProvider` 而不是 `AsyncNotifierProvider`
///
/// 队列的数据源**不是一次异步读**，而是一条持续变化的列表（进度每 250ms
/// 就可能动一次）。做成 `AsyncNotifier` 的话每次变化都要包一层
/// `AsyncData`，而界面还得处理「有数据但在 loading」这种根本不存在的状态。
///
/// 所以：`build()` 同步返回一个空列表，真正的加载由 `init()` 在后台做完
/// 之后通过 `onChanged` 推上来。界面在那一刻之前显示「还没有下载任务」——
/// 对本地 SQLite 来说这个空窗只有几毫秒。
///
/// ⚠️ **不是 `autoDispose`**。下载必须能在用户离开下载页之后继续跑：
/// 自动释放会把队列连同 `_running` 里的暂停令牌一起扔掉，表现是
/// 「切到别的页面，下载就停了」。
final downloadQueueProvider =
    NotifierProvider<DownloadQueueController, List<DownloadTask>>(
  DownloadQueueController.new,
);

class DownloadQueueController extends Notifier<List<DownloadTask>> {
  late final DownloadQueue _queue;
  int _concurrency = kDefaultDownloadConcurrency;
  bool _disposed = false;

  @override
  List<DownloadTask> build() {
    _disposed = false;
    final registry = ref.watch(adapterRegistryProvider);
    _concurrency = ref.read(settingsProvider).valueOrNull?.downloadConcurrency ??
        kDefaultDownloadConcurrency;

    _queue = DownloadQueue(
      store: ref.watch(downloadTaskStoreProvider),
      // 每次开跑现取一个服务实例（适配器注册表可以被重建，
      // 冻住一个旧适配器会拿着失效的会话去取链）。
      service: () => DriveDownloadService(
        adapter: registry.requireAdapter(browseProvider),
      ),
      concurrency: () => _concurrency,
    );

    _queue.onChanged = () {
      if (_disposed) return;
      state = _queue.tasks;
    };

    // 并发数变了：立刻按新值调度一次。
    //
    // 用 `ref.listen` 而不是 `watch` —— `watch` 会让整个 Notifier 重建，
    // 而那会把 `_running` 里的暂停令牌全丢掉，正在下的任务当场失联。
    ref.listen<AsyncValue<AppSettings>>(settingsProvider, (_, next) {
      final value = next.valueOrNull;
      if (value == null) return;
      if (value.downloadConcurrency == _concurrency) return;
      _concurrency = value.downloadConcurrency;
      _queue.pump();
    });

    unawaited(_queue.init());
    ref.onDispose(() {
      _disposed = true;
      _queue.dispose();
    });
    return const [];
  }

  /// 把一个文件加进下载队列。
  Future<void> enqueue({
    required String provider,
    required String fileId,
    required String name,
    required String savePath,
    String dirPath = '/',
    int? sizeBytes,
  }) =>
      _queue.enqueue(
        provider: provider,
        fileId: fileId,
        name: name,
        savePath: savePath,
        dirPath: dirPath,
        sizeBytes: sizeBytes,
      );

  Future<void> pause(String id) => _queue.pause(id);
  Future<void> resume(String id) => _queue.resume(id);
  Future<void> pauseAll() => _queue.pauseAll();
  Future<void> resumeAll() => _queue.resumeAll();

  /// 取消 / 移除记录（并清掉它留下的 `.part`）。
  Future<void> remove(String id) => _queue.remove(id);

  Future<void> clearCompleted() => _queue.clearCompleted();
  Future<void> clearAll() => _queue.clearAll();
}

/// 「进行中」的任务数（排队 + 下载中）。侧栏角标读它。
///
/// **不含已暂停 / 失败**：角标的意义是「有东西正在动，你可能想看」。
/// 把暂停的也算进去的话，一个用户早就放弃的任务会让角标永远挂着，
/// 而点进去发现什么都没在下 —— 角标就不再是可信的信号了。
final downloadActiveCountProvider = Provider<int>((ref) {
  final tasks = ref.watch(downloadQueueProvider);
  return tasks
      .where((t) => t.status.isRunning || t.status.isPending)
      .length;
});

/// 下载任务按状态分组（下载中 → 排队 → 已暂停 → 失败 → 已完成）。
///
/// 分组的**顺序**是刻意的：正在动的排最上面（那是用户点进来看的东西），
/// 已完成的垫底（它们是历史，不需要一直占着视线）。
///
/// 组内按创建时间倒序（新的在前）—— 与 `DownloadTaskStore.loadAll` 同序，
/// 所以这里只做分组、不重排。
final downloadGroupsProvider = Provider<List<DownloadGroup>>((ref) {
  final tasks = ref.watch(downloadQueueProvider);
  const order = [
    DownloadStatus.downloading,
    DownloadStatus.queued,
    DownloadStatus.paused,
    DownloadStatus.failed,
    DownloadStatus.completed,
  ];
  final groups = <DownloadGroup>[];
  for (final status in order) {
    final items = tasks.where((t) => t.status == status).toList();
    if (items.isEmpty) continue;
    groups.add(DownloadGroup(status: status, tasks: items));
  }
  return groups;
});

/// 一个状态分组。
class DownloadGroup {
  const DownloadGroup({required this.status, required this.tasks});

  final DownloadStatus status;
  final List<DownloadTask> tasks;

  int get count => tasks.length;
}
