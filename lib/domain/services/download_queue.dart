import 'dart:async';
import 'dart:io';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../adapters/download_task_store.dart';
import '../entities/download_task.dart';
import 'drive_download.dart';

/// 下载队列：**并发调度 + 暂停 / 继续 / 取消 + 持久化**。
///
/// ## 它解决什么问题
///
/// 单个文件的下载逻辑（取链、Range、原子落盘）全在 [DriveDownloadService]
/// 里。这个类管的是**「同时下几个、谁先谁后、停下来之后怎么接着下」** ——
/// 也就是网盘客户端里那个「传输列表」背后的东西。
///
/// ## 为什么队列自己持有一份内存列表（而不是每次都查库）
///
/// 进度回调每收一个数据块就来一次，而一个几十 GB 的文件是几十万次。
/// 每次都读一次 SQLite 的话，下载会被自己的进度条拖垮。所以：
///
///   - **内存列表是 UI 读的那一份**（`tasks`），每次进度变化就地改；
///   - **数据库是持久化镜像**，按秒节流写（见 [_persistThrottled]）。
///
/// 两边在正常运行时一致，崩溃时最多差一秒 —— 而那一秒的差在续传时会被
/// `.part` 的真实长度抹平（见 `DriveDownloadService` 里那段）。
///
/// ## 它不认识 Flutter
///
/// 没有任何 `ChangeNotifier` / `BuildContext`。变化通过 [onChanged] 这个
/// 回调通知出去，由 UI 层的 provider 接住。这样队列的调度逻辑
/// （并发上限、暂停 / 继续、启动归一）可以在纯 Dart 测试里跑，不需要
/// `WidgetTester`、也不需要起一个真的 SQLite。
class DownloadQueue {
  DownloadQueue({
    required DownloadTaskStore store,
    required DriveDownloadService Function() service,
    required int Function() concurrency,
    DateTime Function()? clock,
  })  : _store = store,
        _service = service,
        _concurrency = concurrency,
        _clock = clock ?? DateTime.now;

  final DownloadTaskStore _store;

  /// 每次开跑现取一个服务实例。
  ///
  /// 做成工厂而不是构造时传一个实例：适配器注册表是可以被重建的
  /// （见 `adapterRegistryProvider`），冻住一个旧适配器会在那种情况下
  /// 拿着失效的会话去取链。
  final DriveDownloadService Function() _service;

  /// 当前允许的同时下载数。每次调度现读 —— 用户在设置页改了它，
  /// 下一次 [_pump] 就生效，不需要重建整个队列。
  final int Function() _concurrency;

  final DateTime Function() _clock;

  /// 列表变了。UI 层接住它去刷新。
  ///
  /// 注意它**会被节流**（进度变化最多 4 次/秒），而结构性变化
  /// （入队 / 暂停 / 完成 / 失败 / 删除）是立刻通知的 —— 见 [_notify]。
  void Function()? onChanged;

  final List<DownloadTask> _tasks = [];

  /// 正在跑的任务 → 它的暂停 / 取消令牌。
  ///
  /// 只存在于内存里：进程一死这些令牌就没了意义（下载已经不在跑了），
  /// 而任务本身在库里躺着，下次启动会以「已暂停」的姿态回来。
  final Map<String, DriveDownloadControl> _running = {};

  /// 上一次把进度写库的时刻，按任务记。
  final Map<String, DateTime> _lastPersist = {};

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  bool _disposed = false;

  /// 全部任务（按创建时间倒序，与 [DownloadTaskStore.loadAll] 同序）。
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  /// 正在真正跑的任务数。
  int get runningCount => _running.length;

  /// 「进行中」的任务数（排队 + 下载中）。侧栏角标读的就是它。
  int get activeCount =>
      _tasks.where((t) => t.status.isRunning || t.status.isPending).length;

  // -------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------

  /// 从库里恢复。
  ///
  /// ## 启动时必须做的那一件事
  ///
  /// 把库里所有「下载中」的行改成「已暂停」。上一次运行被杀掉时，那些行
  /// 还停在 `downloading` —— 而**现在没有任何东西在下它们**。不改的话，
  /// 界面会永远显示一条不动的「下载中」，而且因为队列的并发位只数
  /// `_running`，它也不会挡着别的任务，于是这条记录会一直挂在那儿骗人。
  ///
  /// ⚠️ 刻意**不**自动续传。理由见 `DownloadStatus.paused` 的文档：
  /// 一开应用就闷头下几十 GB 不是用户这次打开应用想干的事。
  Future<void> init() async {
    final paused = await _store.pauseRunning(_clock());
    final loaded = await _store.loadAll();
    if (_disposed) return;
    _tasks
      ..clear()
      ..addAll(loaded);
    _notify(force: true);
    if (paused > 0) {
      diag.info('下载', '$paused 个下载任务在上次退出时未完成，已置为「已暂停」');
    }
    _pump();
  }

  void dispose() {
    _disposed = true;
    onChanged = null;
    // ⚠️ 用 `pause()` 而不是 `cancel()`：应用退出时正在下的那些，
    // `.part` 必须留下 —— 那正是「下次继续」的全部依据。取消会把它们删掉，
    // 表现就是「关一次应用，下了一半的 20 GB 白下了」。
    for (final control in _running.values) {
      control.pause();
    }
    _running.clear();
  }

  // -------------------------------------------------------------------
  // 入队与调度
  // -------------------------------------------------------------------

  /// 把一个文件加进队列（已在队列里则按新信息重排）。
  ///
  /// 同一个 `fileId` 已经**下完**时，这一次会被当成一次**全新的下载**
  /// （`receivedBytes` 归零）。不归零的话续传会从「文件末尾」开始要
  /// `Range`，服务端回 416，表现是「重下一次已经下过的文件直接失败」。
  Future<void> enqueue({
    required String provider,
    required String fileId,
    required String name,
    required String savePath,
    String dirPath = '/',
    int? sizeBytes,
  }) async {
    if (_disposed) return;
    final id = DownloadTask.idFor(provider, fileId);
    final now = _clock();
    final i = _indexOf(id);

    if (i >= 0) {
      final old = _tasks[i];
      // 已经在跑：不打断它。用户重复点同一个文件不该让下载重来。
      if (old.status == DownloadStatus.downloading) return;
      final samePath = old.savePath == savePath;
      final resumeFrom = samePath && old.status != DownloadStatus.completed
          ? old.receivedBytes
          : 0;
      _tasks[i] = old.copyWith(
        name: name,
        dirPath: dirPath,
        savePath: savePath,
        sizeBytes: sizeBytes ?? old.sizeBytes,
        receivedBytes: resumeFrom,
        status: DownloadStatus.queued,
        clearError: true,
        updatedAt: now,
      );
      await _store.save(_tasks[i]);
    } else {
      final task = DownloadTask(
        id: id,
        provider: provider,
        fileId: fileId,
        name: name,
        dirPath: dirPath,
        savePath: savePath,
        sizeBytes: sizeBytes,
        createdAt: now,
        updatedAt: now,
      );
      _tasks.insert(0, task);
      await _store.save(task);
    }

    _notify(force: true);
    _pump();
  }

  /// 排队 / 下载中 → 已暂停。
  ///
  /// 正在跑的那个只是**打上标记**：下载循环在下一个数据块边界看到它，
  /// 抛出 `DriveDownloadPaused`，状态由 [_start] 那边统一改。这里不去改
  /// 状态，因为「暂停」这个动作真正完成的时刻是**最后一块字节落盘的那一刻**，
  /// 而那时才知道准确的已下字节数。
  Future<void> pause(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    final task = _tasks[i];
    switch (task.status) {
      case DownloadStatus.downloading:
        _running[id]?.pause();
      case DownloadStatus.queued:
        _setStatus(id, DownloadStatus.paused);
      case DownloadStatus.paused:
      case DownloadStatus.completed:
      case DownloadStatus.failed:
        break;
    }
  }

  /// 已暂停 / 失败 → 排队，并立刻试着开跑。
  ///
  /// 失败也走这里（不另设「重试」）：失败之后唯一有意义的动作就是重试，
  /// 而重试本来就该带断点 —— 已经下了一半的部分没有理由扔掉。
  Future<void> resume(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    if (!_tasks[i].status.canResume) return;
    _setStatus(id, DownloadStatus.queued, clearError: true);
    _pump();
  }

  /// 全部暂停。正在跑的那些会在下一个数据块边界停下来。
  Future<void> pauseAll() async {
    for (final t in List<DownloadTask>.of(_tasks)) {
      if (t.status.canPause) await pause(t.id);
    }
  }

  /// 全部继续。
  Future<void> resumeAll() async {
    var any = false;
    for (final t in List<DownloadTask>.of(_tasks)) {
      if (!t.status.canResume) continue;
      _setStatus(t.id, DownloadStatus.queued, clearError: true);
      any = true;
    }
    if (any) _pump();
  }

  /// 删掉一条记录，并把它留下的 `.part` 一起清掉。
  ///
  /// 「取消」与「移除记录」是同一个操作：两者对磁盘的期望都是
  /// 「别留东西」。分成两个方法只会让 UI 那边多一个分支要判断。
  Future<void> remove(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    final task = _tasks[i];
    _running[id]?.cancel();
    _tasks.removeAt(i);
    _lastPersist.remove(id);
    _notify(force: true);
    await _store.remove(id);
    await _deletePart(task);
  }

  /// 清掉全部已完成的记录（**失败的留着** —— 用户可能还想重试）。
  Future<void> clearCompleted() async {
    final ids = _tasks
        .where((t) => t.status == DownloadStatus.completed)
        .map((t) => t.id)
        .toList();
    if (ids.isEmpty) return;
    _tasks.removeWhere((t) => ids.contains(t.id));
    for (final id in ids) {
      _lastPersist.remove(id);
    }
    _notify(force: true);
    await _store.removeMany(ids);
  }

  /// 清掉全部记录（含正在跑的 —— 会先取消）。
  Future<void> clearAll() async {
    final snapshot = List<DownloadTask>.of(_tasks);
    for (final control in _running.values) {
      control.cancel();
    }
    _tasks.clear();
    _lastPersist.clear();
    _notify(force: true);
    await _store.removeMany(snapshot.map((t) => t.id).toList());
    for (final t in snapshot) {
      await _deletePart(t);
    }
  }

  /// 有空位就把排队的任务拉起来。
  ///
  /// 公开是因为「用户在设置页把并发数调大了」这件事也要触发它 ——
  /// 不公开的话那种情况下得等到某个任务跑完才会用上新的并发数。
  void pump() => _pump();

  void _pump() {
    if (_disposed) return;
    final limit = _concurrency().clamp(1, kMaxDownloadConcurrency);
    if (_running.length >= limit) return;

    // 排队任务按创建时间**正序**开跑（先入先出）。列表本身是倒序的
    // （新的在前，方便展示），所以这里要单独排一次。
    final queued = _tasks.where((t) => t.status.isPending).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final task in queued) {
      if (_running.length >= limit) break;
      // `_start` 是 async，但它的函数体在第一个 `await` 之前是**同步**跑的
      // —— 也就是说这一行返回时 `_running` 里已经有它了。所以上面那个
      // `_running.length` 的判断是对的，不会一口气把所有排队任务都拉起来。
      unawaited(_start(task));
    }
  }

  Future<void> _start(DownloadTask snapshot) async {
    final id = snapshot.id;
    final control = DriveDownloadControl();
    _running[id] = control;
    _setStatus(id, DownloadStatus.downloading, clearError: true);

    try {
      final result = await _service().download(
        fileId: snapshot.fileId,
        savePath: snapshot.savePath,
        startOffset: snapshot.receivedBytes,
        control: control,
        onProgress: (p) => _onProgress(id, p),
      );
      _setStatus(
        id,
        DownloadStatus.completed,
        receivedBytes: result.bytes,
        sizeBytes: result.bytes,
      );
      diag.info('下载', '已完成：${snapshot.name}（${result.bytes} 字节）');
    } on DriveDownloadPaused catch (e) {
      // `.part` 还在，`e.received` 就是断点。
      _setStatus(id, DownloadStatus.paused, receivedBytes: e.received);
      diag.info('下载', '已暂停：${snapshot.name}（已下 ${e.received} 字节）');
    } on DriveDownloadCancelled {
      // 用户取消了 —— 记录已经被 `remove()` 删掉了，这里什么都不做。
      // 真去做点什么反而会把刚删掉的行又写回去。
    } on DriveException catch (e) {
      _setStatus(
        id,
        DownloadStatus.failed,
        error: explainDownloadError(e),
        receivedBytes: await _partLength(snapshot),
      );
      diag.warn('下载', '失败：${snapshot.name} —— ${e.type.name} ${e.message}');
    } catch (e) {
      _setStatus(
        id,
        DownloadStatus.failed,
        error: '下载失败：$e',
        receivedBytes: await _partLength(snapshot),
      );
      diag.warn('下载', '失败：${snapshot.name} —— $e');
    } finally {
      _running.remove(id);
      _lastPersist.remove(id);
      // 刚空出来一个并发位，看看还有没有排队的。
      _pump();
    }
  }

  /// 失败时把 `.part` 的真实长度写回去。
  ///
  /// 不这么做的话，失败的任务会停在「上一次节流写库时的字节数」上，
  /// 而用户看到的是「已经下了 2 GB，但它说只下了 1.8 GB」——
  /// 下次继续时进度会先跳一下。真源本来就是磁盘，这里只是把它抄下来。
  Future<int> _partLength(DownloadTask task) async {
    try {
      final f = File(task.partPath);
      if (await f.exists()) return await f.length();
    } catch (_) {
      // 读不到就用原来的值，不值得为它把失败原因盖掉。
    }
    return _current(task.id)?.receivedBytes ?? task.receivedBytes;
  }

  // -------------------------------------------------------------------
  // 内存列表与持久化
  // -------------------------------------------------------------------

  void _onProgress(String id, DriveDownloadProgress p) {
    final i = _indexOf(id);
    if (i < 0) return;
    final t = _tasks[i];
    _tasks[i] = t.copyWith(
      receivedBytes: p.received,
      sizeBytes: p.total ?? t.sizeBytes,
    );
    _notify();
    _persistThrottled(_tasks[i]);
  }

  /// 状态变更（结构性，立刻通知 + 立刻落库）。
  void _setStatus(
    String id,
    DownloadStatus status, {
    String? error,
    bool clearError = false,
    int? receivedBytes,
    int? sizeBytes,
  }) {
    if (_disposed) return;
    final i = _indexOf(id);
    if (i < 0) return;
    _tasks[i] = _tasks[i].copyWith(
      status: status,
      error: error,
      clearError: clearError,
      receivedBytes: receivedBytes,
      sizeBytes: sizeBytes,
      updatedAt: _clock(),
    );
    _notify(force: true);
    unawaited(_persist(_tasks[i]));
  }

  void _notify({bool force = false}) {
    if (_disposed) return;
    final callback = onChanged;
    if (callback == null) return;
    if (!force) {
      // 进度通知按 4 次/秒节流。一个几十 GB 的文件是几十万次回调，
      // 每次都让界面重建一遍列表是纯浪费 —— 而 4 Hz 对进度条来说
      // 已经比人眼能分辨的还快了。
      final now = _clock();
      if (now.difference(_lastNotify) < const Duration(milliseconds: 250)) {
        return;
      }
      _lastNotify = now;
    } else {
      _lastNotify = _clock();
    }
    callback();
  }

  void _persistThrottled(DownloadTask task) {
    final now = _clock();
    final last = _lastPersist[task.id];
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastPersist[task.id] = now;
    unawaited(_persist(task));
  }

  Future<void> _persist(DownloadTask task) async {
    try {
      await _store.save(task);
    } catch (e) {
      // 落库失败不该打断下载：进度还会再写很多次，下一次大概率就好了。
      // 但也不能完全静默 —— 否则「暂停后继续，断点没接上」会变成一个
      // 无从查起的问题。
      diag.warn('下载', '进度落库失败（${task.name}）：$e');
    }
  }

  int _indexOf(String id) => _tasks.indexWhere((t) => t.id == id);

  DownloadTask? _current(String id) {
    final i = _indexOf(id);
    return i < 0 ? null : _tasks[i];
  }

  Future<void> _deletePart(DownloadTask task) async {
    try {
      final f = File(task.partPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉只是留个垃圾文件，不值得把上层的操作搞失败。
    }
  }
}

/// 把 [DriveException] 翻译成用户看得懂的一句话。
///
/// 放在这里（而不是各个页面各写一份）：下载记录页、目录视图的提示条
/// 都要说这句话，两处各写一遍的话，改一处文案会让另一处自相矛盾。
String explainDownloadError(DriveException e) => switch (e.type) {
      DriveErrorType.unauthorized => '登录已失效，请重新扫码登录夸克账号',
      DriveErrorType.rateLimited => '请求过于频繁，被夸克限流了，稍后点「继续」即可',
      DriveErrorType.network => '网络中断了。已经下好的部分还在，点「继续」接着下',
      DriveErrorType.notFound => '这个文件已经不在网盘上了',
      DriveErrorType.urlExpired => '下载直链过期了，点「继续」会重新取一条',
      DriveErrorType.fileTooLarge => '这个文件太大，网盘拒绝了取链',
      DriveErrorType.unsupported => '该网盘不支持下载这个文件',
      _ => e.message,
    };
