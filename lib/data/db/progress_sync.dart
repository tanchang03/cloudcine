import 'dart:async';
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/services/playback_progress.dart';
import 'progress_store.dart';

/// 播放进度的**静默同步**：与媒体库备份完全无关的一条小通道。
///
/// ## 它做的四件事（顺序不能换）
///
///   1. **播种** —— 把媒体库行里已有的进度读进进度库
///      （[MediaRepository.progressSnapshot]）。老用户升级上来的那一刻，
///      进度文件还不存在，而库里已经攒了几百条；不播种的话那批进度
///      永远留在本地，同步不到别的设备。
///   2. **下载** —— 取网盘上的 `云影备份/playback_progress.json`。
///   3. **合并** —— 逐条 LWW（[ProgressBook.mergeFrom]）。**不是**整份覆盖：
///      两台设备各看一集，两条都该留下。
///   4. **回填** —— 把合并后的结果写回 `media_items` 的三列
///      （[MediaRepository.applyProgressSnapshot]），让二十多处 SQL 查询
///      立刻看到新进度。
///
/// 最后才决定要不要上传：**只有当合并后的状态与网盘上那份不同**才传。
///
/// ## ⛔ 「静默」是硬要求
///
/// 这个方法**绝不弹窗、绝不抛异常、绝不阻塞播放**。它挂在启动、退出播放器、
/// 以及一个 30 分钟的定时器上；任何一次失败都只该在诊断日志里留一行，
/// 下一轮自己会重试。
///
/// 尤其是：**下载失败时绝不上传**。读不到远程就传本地，等于用「本机知道的
/// 那部分进度」把网盘上另一台设备的进度**整个覆盖掉** —— 而那正是这个功能
/// 最不能出的错。
///
/// ## 为什么它住在 data 层，以及为什么网盘那一步是**两个回调**
///
/// 它是 [ProgressStore]（落盘，data 层的具体实现）与 [MediaRepository]（库）
/// 的**编排**。领域层只认抽象（见 `library_backup_service.dart` 的类文档），
/// 把编排放在领域层会逼着领域层去 import 一个具体的文件实现。
///
/// 网盘那一步刻意**不**直接依赖 `LibraryBackupService`，而是收成
/// [downloadRemote] / [uploadRemote] 两个函数：那个类要构造出一个可用的实例
/// 得先有一整套 `CloudDriveAdapter`，而这里真正需要的只有「读一个文件」
/// 和「写一个文件」两件事。收成回调之后，单测用一个内存字典就能覆盖
/// 全部合并分支 —— 而这个功能最需要被覆盖的恰恰是合并，不是网盘。
class ProgressSyncService {
  ProgressSyncService({
    required ProgressStore store,
    required MediaRepository repository,
    required Future<Uint8List?> Function() downloadRemote,
    required Future<void> Function(Uint8List bytes) uploadRemote,
  })  : _store = store,
        _repository = repository,
        _download = downloadRemote,
        _upload = uploadRemote;

  final ProgressStore _store;
  final MediaRepository _repository;

  /// 读网盘上的进度文件。`null` = 网盘上还没有这份文件（**不是错误**）。
  /// 抛异常 = 这次读不到（网络失败 / 限流），调用方**必须**据此放弃上传。
  final Future<Uint8List?> Function() _download;

  /// 覆盖写网盘上的进度文件。
  final Future<void> Function(Uint8List bytes) _upload;

  bool _running = false;
  DateTime? _lastSuccessAt;
  String? _lastError;

  /// 有没有一轮正在跑。调度器用它避免叠加（30 分钟的定时器撞上「退出播放器」）。
  bool get isRunning => _running;

  /// 上一次**成功**跑完的时刻；从没成功过时为 `null`。
  DateTime? get lastSuccessAt => _lastSuccessAt;

  /// 上一次失败的原因；从没失败过时为 `null`。
  String? get lastError => _lastError;

  /// 跑一轮。**绝不抛**。
  Future<ProgressSyncOutcome> syncSilently() async {
    if (_running) {
      return const ProgressSyncOutcome.skipped('上一轮还没跑完');
    }
    _running = true;
    try {
      final outcome = await _run();
      if (outcome.ok) {
        _lastSuccessAt = DateTime.now();
        _lastError = null;
      } else {
        _lastError = outcome.message;
      }
      return outcome;
    } catch (e) {
      // 兜底：`_run` 内部已经把每一步都包了，但「绝不让同步拖垮调用方」
      // 这条承诺值得再兜一层 —— 它挂在启动路径与播放器退出路径上。
      _lastError = '$e';
      diag.error('进度', '进度同步异常：$e');
      return ProgressSyncOutcome.failed('$e');
    } finally {
      _running = false;
    }
  }

  Future<ProgressSyncOutcome> _run() async {
    await _store.load();

    // 1. 播种：库里的投影 → 进度库。只有第一次（或恢复备份之后）会真的
    //    合进东西，之后这一步恒为 0。
    var seeded = 0;
    try {
      seeded = await _store.mergeFrom(await _repository.progressSnapshot());
    } catch (e) {
      diag.warn('进度', '从媒体库播种进度失败（继续走远程那一步）：$e');
    }

    // 2. 下载。`null` = 网盘上还没有这份文件（**不是错误**）。
    Uint8List? remoteBytes;
    var remoteReadable = false;
    try {
      remoteBytes = await _download();
      remoteReadable = true;
    } catch (e) {
      diag.warn('进度', '下载远程进度失败，本轮不上传：$e');
    }

    if (!remoteReadable) {
      // ⛔ 读不到远程就**不传**（理由见类文档）。但本地该做的两件事照做：
      //    合出来的进度仍然是本机最全的一份，回填之后界面是对的。
      await _store.flush();
      await _applyToLibrary();
      return ProgressSyncOutcome.failed('下载远程进度失败，本轮未上传');
    }

    // 3. 合并（逐条 LWW）。
    var mergedIn = 0;
    if (remoteBytes != null) {
      mergedIn = await _store.mergeFrom(ProgressBook.fromBytes(remoteBytes));
    }

    await _store.flush();
    final applied = await _applyToLibrary();

    // 4. 要不要上传？判据是「合并后的状态与网盘上那份是否不同」。
    //
    // ⛔ 不用 `mergedIn > 0` 当判据：那说的是「远程有没有东西给我」，
    //    而这里要问的是「我有没有东西要给远程」。本地新看了一集、远程
    //    一无所知时 `mergedIn == 0`，但**必须上传**。
    var needUpload = false;
    if (remoteBytes == null) {
      needUpload = _store.book.isNotEmpty;
    } else {
      final union = ProgressBook(Map<String, ProgressEntry>.of(
        ProgressBook.fromBytes(remoteBytes).items,
      ));
      needUpload = union.mergeFrom(_store.book) > 0;
    }

    var uploaded = false;
    if (needUpload) {
      try {
        await _upload(_store.book.toBytes());
        uploaded = true;
      } catch (e) {
        diag.warn('进度', '上传进度文件失败（本地已合并，下一轮重试）：$e');
        return ProgressSyncOutcome(
          ok: false,
          message: '上传失败：$e',
          seeded: seeded,
          mergedIn: mergedIn,
          applied: applied,
          downloaded: remoteBytes != null,
        );
      }
    }

    diag.info(
      '进度',
      '同步完成：本地 ${_store.book.length} 条 ｜ 播种 $seeded、'
      '合入 $mergedIn、回填 $applied 条 ｜ '
      '${uploaded ? "已上传" : "无需上传"}',
    );
    return ProgressSyncOutcome(
      ok: true,
      message: uploaded ? '已同步并上传' : '已同步（无需上传）',
      seeded: seeded,
      mergedIn: mergedIn,
      applied: applied,
      downloaded: remoteBytes != null,
      uploaded: uploaded,
    );
  }

  /// 把进度库回填进媒体库；返回被更新的行数。失败不抛。
  Future<int> _applyToLibrary() async {
    try {
      return await _repository.applyProgressSnapshot(_store.book);
    } catch (e) {
      diag.warn('进度', '回填媒体库失败（进度已落盘，下次再试）：$e');
      return 0;
    }
  }
}

/// 一轮静默同步的结果。**只用于日志与诊断**，不上屏。
class ProgressSyncOutcome {
  const ProgressSyncOutcome({
    required this.ok,
    required this.message,
    this.seeded = 0,
    this.mergedIn = 0,
    this.applied = 0,
    this.downloaded = false,
    this.uploaded = false,
  });

  const ProgressSyncOutcome.skipped(String why)
      : ok = true,
        message = why,
        seeded = 0,
        mergedIn = 0,
        applied = 0,
        downloaded = false,
        uploaded = false;

  factory ProgressSyncOutcome.failed(String why) =>
      ProgressSyncOutcome(ok: false, message: why);

  /// 这一轮有没有成功（跳过也算成功 —— 没出事）。
  final bool ok;

  final String message;

  /// 从媒体库播种进进度库的条数。
  final int seeded;

  /// 从远程合进来的条数。
  final int mergedIn;

  /// 回填进媒体库的行数。
  final int applied;

  final bool downloaded;
  final bool uploaded;

  @override
  String toString() =>
      'ProgressSyncOutcome(ok=$ok, $message, seed=$seeded, merged=$mergedIn, '
      'applied=$applied, down=$downloaded, up=$uploaded)';
}
