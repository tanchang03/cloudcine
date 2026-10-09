import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/download_task_store_impl.dart';
import '../../domain/adapters/download_task_store.dart';
import '../../domain/entities/download_task.dart';
import '../../domain/services/download_queue.dart';
import '../../domain/services/drive_download.dart';
import 'app_providers.dart';
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
  /// 当前队列。
  ///
  /// ⛔⛔ **不能**写成 `late final`。Riverpod 在依赖变化时会**复用同一个
  ///    Notifier 实例**再调一次 `build()`；而这里 `ref.watch` 了
  ///    [downloadTaskStoreProvider]，它又挂在 `databaseProvider` 下面 ——
  ///    恢复备份换掉整个 `AppDatabase` 时这条链会一起重建。`late final`
  ///    第二次赋值直接抛
  ///    `LateInitializationError: Field '_queue' has already been initialized`，
  ///    表现是**整个界面变红**（2026-10-07 恢复备份后真机踩到）。
  ///
  ///    同目录的 `FollowController` / `ScanController` 早就按「可重建」写
  ///    （`_disposed = false` 复位那一套），这里当初漏了。
  ///
  /// ⛔ 刻意用**可空字段 + 取值器**而不是 `late DownloadQueue _queue`：
  ///    `late` 读未赋值会抛，而「忘了在 `build()` 里赋值」正是我们要在
  ///    编译期之外也看得见的事；可空类型让「这里可能还没有队列」写进类型里。
  DownloadQueue? _queue;

  /// 当前队列。`build()` 一定会先赋值，所以这里可以直接 `!`。
  DownloadQueue get _q => _queue!;

  int _concurrency = kDefaultDownloadConcurrency;
  bool _disposed = false;

  @override
  List<DownloadTask> build() {
    // ⛔ 先把上一轮那个队列收掉（`build()` 会被调不止一次，见 [_queue] 的
    //    文档）。不收的话：旧队列的进度回调还挂着、`_running` 里的暂停令牌
    //    变成孤儿，而且它的 `store` 已经指向被换掉的那个库。
    //
    //    这里和下面 `ref.onDispose` 里各收一次是**故意**的：不依赖
    //    「Riverpod 到底在 build 之前还是之后触发上一轮的 onDispose」，
    //    而 `DownloadQueue.dispose()` 是幂等的。
    _queue?.dispose();
    _disposed = false;
    final registry = ref.watch(adapterRegistryProvider);
    _concurrency = ref.read(settingsProvider).valueOrNull?.downloadConcurrency ??
        kDefaultDownloadConcurrency;

    final queue = DownloadQueue(
      store: ref.watch(downloadTaskStoreProvider),
      // ⛔ **按每条任务自己的网盘**取服务，不再冻结「当前网盘」那一个适配器。
      //
      //    库里同时有夸克和百度的文件，队列也同时排着两家的任务。冻住一个
      //    的话，另一家的任务会拿别家的凭证去取链 —— 表现为「任务一直失败 /
      //    卡住」，而队列本身一切正常，用户完全看不出是网盘弄错了。
      //
      // ⛔ 仍然**每次开跑现取**（适配器注册表可以被重建，冻住一个旧适配器
      //    会拿着失效的会话去取链）。
      //
      // ⚠️ 不再 `watch(browseProvider)`：队列的命不再是「视图在看哪家」，
      //    而是每条任务自己的归属。换浏览视图**不该**重建整个队列
      //    （那会打断正在跑的任务）。
      service: (provider) => DriveDownloadService(
        adapter: registry.requireAdapter(provider),
      ),
      concurrency: () => _concurrency,
    );
    _queue = queue;

    queue.onChanged = () {
      if (_disposed) return;
      state = queue.tasks;
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
      queue.pump();
    });

    unawaited(queue.init());
    ref.onDispose(() {
      _disposed = true;
      // ⛔ 捕获**局部变量**而不是读 `_queue`：重建时这个回调可能在
      //    `build()` 之后才被触发，那时 `_queue` 已经指向新队列了 ——
      //    读字段就会把**新**队列收掉。
      queue.dispose();
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
      _q.enqueue(
        provider: provider,
        fileId: fileId,
        name: name,
        savePath: savePath,
        dirPath: dirPath,
        sizeBytes: sizeBytes,
      );

  Future<void> pause(String id) => _q.pause(id);
  Future<void> resume(String id) => _q.resume(id);
  Future<void> pauseAll() => _q.pauseAll();
  Future<void> resumeAll() => _q.resumeAll();

  /// 取消 / 移除记录（并清掉它留下的 `.part`）。
  Future<void> remove(String id) => _q.remove(id);

  Future<void> clearCompleted() => _q.clearCompleted();
  Future<void> clearAll() => _q.clearAll();
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
