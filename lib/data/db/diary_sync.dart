import 'dart:async';
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/services/watch_diary.dart';
import 'diary_store.dart';

/// 观影日记的**静默同步**：与媒体库备份完全无关的一条小通道。
///
/// ## 它做的四件事（顺序不能换）
///
///   1. **捕种** —— 扫描媒体库，把「刚达到 80%、但还没记入日记」的作品自动记进去。
///      自动记入默认开启（设计文档 §10.1），所以这一步通常是「把新看完的剧补录」。
///      老用户的库里可能已经攒了几百部看完的作品，不捕种的话它们永远进不了日记。
///   2. **下载** —— 取网盘上的 `云影备份/watch_diary.json`。
///   3. **合并** —— 逐条 LWW（[DiaryBook.mergeFrom]）。不是整份覆盖：PC 端记了
///      《三体》、手机端记了《狂飙》，两条都该留下。
///   4. 最后才决定要不要上传：**只有合并后的状态与网盘上那份不同**才传。
///
/// ## ⛔ 「静默」是硬要求
///
/// 与 `ProgressSyncService` 同一条：绝不弹窗、绝不抛、绝不阻塞。挂在启动、
/// 退出播放器、30 分钟定时器上；任何一次失败只该在诊断日志留一行，下一轮重试。
///
/// 尤其：**下载失败时绝不上传**。读不到远程就传本地，等于用「本机知道的那部分
/// 日记」把网盘上另一台设备的日记整个覆盖掉 —— 而那正是这功能最不能出的错。
///
/// ## 日记不回填媒体库
///
/// 进度要回填 `media_items` 的三列（二十多处 SQL 查询在读），日记不需要 ——
/// 它就是历史事实，UI 直接读日记文件。所以这一步比进度同步少一段。
class DiarySyncService {
  DiarySyncService({
    required DiaryStore store,
    required Future<Map<String, DiaryEntry>> Function() captureEligible,
    required Future<Uint8List?> Function() downloadRemote,
    required Future<void> Function(Uint8List bytes) uploadRemote,
  })  : _store = store,
        _capture = captureEligible,
        _download = downloadRemote,
        _upload = uploadRemote;

  final DiaryStore _store;

  /// 扫描媒体库、构建「新达标的作品 → 日记条目」的映射。
  ///
  /// 返回**空 map** 完全正常（没有新看完的作品）—— 不是错误。
  /// 抛异常 = 这次扫库失败，调用方**必须**据此放弃上传（理由见类文档）。
  final Future<Map<String, DiaryEntry>> Function() _capture;

  /// 读网盘上的日记文件。`null` = 还没有（不是错误）；抛异常 = 读不到。
  final Future<Uint8List?> Function() _download;

  /// 覆盖写网盘上的日记文件。
  final Future<void> Function(Uint8List bytes) _upload;

  bool _running = false;
  DateTime? _lastSuccessAt;
  String? _lastError;

  bool get isRunning => _running;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;

  /// 跑一轮。**绝不抛**。
  Future<DiarySyncOutcome> syncSilently() async {
    if (_running) return const DiarySyncOutcome.skipped('上一轮还没跑完');
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
      _lastError = '$e';
      diag.error('日记', '日记同步异常：$e');
      return DiarySyncOutcome.failed('$e');
    } finally {
      _running = false;
    }
  }

  Future<DiarySyncOutcome> _run() async {
    await _store.load();
    diag.debug('日记', '本轮开始：本地 ${_store.book.length} 条'
        '（可见 ${_store.book.visibleCount}、墓碑 ${_store.book.entries.values.where((e) => e.isDeleted).length}）');

    // 1. 捕种：把新达标的作品自动记进去。失败不致命，继续走远程那一步。
    var captured = 0;
    final capturedEntries = <String, DiaryEntry>{};
    try {
      diag.debug('日记', '捕种：扫描媒体库，找出新达标且未记入的作品');
      final fresh = await _capture();
      if (fresh.isNotEmpty) {
        diag.info('日记', '捕种到 ${fresh.length} 部新达标作品');
        captured = await _store.mergeFrom(DiaryBook(Map<String, DiaryEntry>.of(fresh)));
        capturedEntries.addAll(fresh);
      }
    } catch (e) {
      diag.warn('日记', '捕种失败（继续走远程同步）：$e');
    }

    // 2. 下载。`null` = 网盘上还没有这份文件（不是错误）。
    Uint8List? remoteBytes;
    var remoteReadable = false;
    try {
      remoteBytes = await _download();
      remoteReadable = true;
    } catch (e) {
      diag.warn('日记', '下载远程日记失败，本轮不上传：$e');
    }

    if (!remoteReadable) {
      // ⛔ 读不到远程就**不传**。但本地该做的两件事照做：捕种/合并后的结果
      // 仍然落盘，下次进日记页是对的。
      await _store.flush();
      return DiarySyncOutcome.failed('下载远程日记失败，本轮未上传');
    }

    // 3. 合并（逐条 LWW）。
    var mergedIn = 0;
    if (remoteBytes != null) {
      mergedIn = await _store.mergeFrom(DiaryBook.fromBytes(remoteBytes));
    }

    await _store.flush();

    // 4. 要不要上传？判据是「合并后的状态与网盘上那份是否不同」。
    var needUpload = false;
    if (remoteBytes == null) {
      needUpload = _store.book.isNotEmpty;
    } else {
      final remoteBook = DiaryBook.fromBytes(remoteBytes);
      // remoteBook 作为基，看把本地合进去会不会改变它。
      needUpload = remoteBook.mergeFrom(_store.book) > 0;
    }

    var uploaded = false;
    if (needUpload) {
      try {
        await _upload(_store.book.toBytes());
        uploaded = true;
      } catch (e) {
        diag.warn('日记', '上传日记文件失败（本地已合并，下一轮重试）：$e');
        return DiarySyncOutcome(
          ok: false,
          message: '上传失败：$e',
          captured: captured,
          capturedEntries: capturedEntries,
          mergedIn: mergedIn,
          downloaded: remoteBytes != null,
        );
      }
    }

    diag.info(
      '日记',
      '同步完成：本地 ${_store.book.length} 条 ｜ 捕种 $captured、合入 $mergedIn ｜ '
      '${uploaded ? "已上传" : "无需上传"}',
    );
    return DiarySyncOutcome(
      ok: true,
      message: uploaded ? '已同步并上传' : '已同步（无需上传）',
      captured: captured,
      capturedEntries: capturedEntries,
      mergedIn: mergedIn,
      downloaded: remoteBytes != null,
      uploaded: uploaded,
    );
  }
}

/// 一轮静默同步的结果。**只用于日志与诊断**，不上屏。
class DiarySyncOutcome {
  const DiarySyncOutcome({
    required this.ok,
    required this.message,
    this.captured = 0,
    this.capturedEntries = const {},
    this.mergedIn = 0,
    this.downloaded = false,
    this.uploaded = false,
  });

  const DiarySyncOutcome.skipped(String why)
      : ok = true,
        message = why,
        captured = 0,
        capturedEntries = const {},
        mergedIn = 0,
        downloaded = false,
        uploaded = false;

  factory DiarySyncOutcome.failed(String why) =>
      DiarySyncOutcome(ok: false, message: why);

  final bool ok;
  final String message;

  /// 本轮自动捕种（自动记入）了多少条。
  final int captured;

  /// 本轮自动捕种得到的条目（含标题），用于顶部「《X》已记入观影日记」提示条。
  final Map<String, DiaryEntry> capturedEntries;

  /// 从远程合进来的条数。
  final int mergedIn;

  final bool downloaded;
  final bool uploaded;

  @override
  String toString() =>
      'DiarySyncOutcome(ok=$ok, $message, captured=$captured, merged=$mergedIn, '
      'down=$downloaded, up=$uploaded)';
}
