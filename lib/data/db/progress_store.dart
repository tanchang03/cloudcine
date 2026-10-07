import 'dart:async';
import 'dart:io';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/services/playback_progress.dart';

/// 播放进度的**独立落盘存储**。
///
/// ## 一句话
///
/// 它是一个**只装进度**的 JSON 文件（`<应用支持目录>/playback_progress.json`），
/// 与媒体库索引库 `cloudcine.sqlite` **互不隶属**。清空索引库删的是后者的
/// 几张表、恢复备份换的是后者的整个文件字节 —— 两条路都碰不到这个文件。
///
/// ## 为什么是 JSON 文件，而不是第二个 SQLite 库
///
/// 三条理由，按重要性排：
///
///   1. **它就是同步载荷**。上传到网盘的那份字节与本地这份**逐字相同**，
///      于是「本地存了什么」和「网上存了什么」永远是同一个格式、同一段
///      序列化代码 —— 少一处能让两边悄悄分叉的地方。
///   2. **没有 codegen 依赖**。第二个 drift 库要跑 `build_runner` 生成
///      `*.g.dart`，而这份数据的全部操作就是「读一整个 Map、写一整个 Map」，
///      值不上为它引一套代码生成。
///   3. **写频率与体积都撑得住**。进度每 10 秒变一次（播放中的进度回报），
///      一次全量重写。几千条约几百 KB，落在一块 SSD 上是一次毫秒级的写；
///      而真正常见的规模是几百条。
///
/// ## 线程 / 并发模型
///
/// 单进程内**只有一个实例**（组合根里的 `progressStoreProvider`）。
/// 独立播放窗口跑在另一个 Flutter 引擎里，但它**碰不到这里** —— 它把进度
/// 通过跨窗口通道报回主窗口（见 `player_bridge_host.dart`），由主窗口落库。
///
/// ## ⛔ 写入是「防抖 + 原子替换」
///
///   * **防抖**（[flushDelay]）：一次播放中每 10 秒就有三处写入
///     （`markPlayed` / `saveResumePosition` / `saveMaxPosition`），
///     每次都落盘是三次全量重写。合并成一次，用户感受不到差别。
///   * **原子替换**：先写 `<path>.tmp` 再 `rename`。直接覆写原文件的话，
///     写到一半被杀（电视上很常见）会留下一份**截断的 JSON** —— 下次读回来
///     整份进度都没了，而用户只会看到「所有进度凭空消失」。
///     `rename` 在同一文件系统内是原子的，读到的要么是旧的完整文件、
///     要么是新的完整文件。
///
/// ## ⛔ 写之前**一定**先 [load]
///
/// 两处都做了保证（[flush] 与 [mergeFrom] 各自先 `await load()`），因为
/// 「先写、后读」的后果是**静默的**：`_book` 里只有刚写的那一条，
/// 落盘时把整个文件覆盖成「只有一条」，用户磁盘上原有的几百条进度全没了。
class ProgressStore {
  ProgressStore({
    required String filePath,
    DateTime Function()? clock,
    Duration flushDelay = const Duration(seconds: 2),
  })  : _path = filePath,
        _clock = clock ?? DateTime.now,
        _flushDelay = flushDelay;

  /// 本地进度文件名。与网盘上那份**同名**（见 `LibraryBackupService.progressFileName`）。
  static const String fileName = 'playback_progress.json';

  final String _path;
  final DateTime Function() _clock;
  final Duration _flushDelay;

  final ProgressBook _book = ProgressBook();
  bool _loaded = false;
  bool _dirty = false;
  Timer? _flushTimer;
  Future<void>? _loading;
  Future<void>? _inFlight;
  bool _disposed = false;

  /// 落盘路径。
  String get path => _path;

  /// 内存里的那份。**只读用途**（同步服务拿它序列化上传）。
  ProgressBook get book => _book;

  /// 是否已经读过磁盘（[load] 跑过）。
  bool get isLoaded => _loaded;

  /// 有没有还没落盘的改动。
  bool get isDirty => _dirty;

  // -------------------------------------------------------------------
  // 读
  // -------------------------------------------------------------------

  /// 从磁盘读一次。重复调用是幂等的（第二次直接返回同一个 Future）。
  ///
  /// ⛔ **读进来的内容是「合进」内存那份，不是「替换」**：调用方可能在
  ///    `load()` 返回之前就已经写过几条（启动路径上 `load` 是异步的，
  ///    而播放器可能已经在回报进度）。直接替换会把这几条悄悄丢掉。
  ///    合并用的是同一套 LWW，内存里刚写的那条 `u` 最新，自然赢。
  ///
  /// ⛔ 文件不存在 / 内容损坏**都不算错误**：前者是全新安装，后者最坏也
  ///    只是「这一次读不到进度」。抛出去的话，它挂在启动路径上，
  ///    一次坏文件就会让应用起不来 —— 而进度本来就是**可再生的**数据。
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadNow();
  }

  Future<void> _loadNow() async {
    try {
      final file = File(_path);
      if (!await file.exists()) {
        diag.info('进度', '进度文件不存在，从空开始：$_path');
      } else {
        final text = await file.readAsString();
        final loaded = ProgressBook.fromJsonString(text);
        final added = _book.mergeFrom(loaded);
        diag.info(
          '进度',
          '已载入进度文件：磁盘 ${loaded.length} 条、'
          '合入 $added 条（内存共 ${_book.length} 条）',
        );
      }
    } catch (e) {
      diag.warn('进度', '读取进度文件失败，从空开始：$e');
    } finally {
      _loaded = true;
    }
  }

  // -------------------------------------------------------------------
  // 写（内存 + 防抖落盘）
  // -------------------------------------------------------------------

  /// 记一次「播放过」（已读回执 + 最近播放排序）。
  ///
  /// 返回是否**真的改了东西**（内容没变就不落盘、也不触发同步）。
  bool recordPlayed(String itemId, DateTime at) {
    if (itemId.isEmpty) return false;
    final sec = at.millisecondsSinceEpoch ~/ 1000;
    final old = _book[itemId];
    // 时间戳只前进：设备时钟回拨时不该让「最近播放」倒退。
    if (old != null && old.playedAtSec != null && old.playedAtSec! >= sec) {
      return false;
    }
    return _put(
      itemId,
      (prev) => ProgressEntry(
        resumeMs: prev?.resumeMs,
        maxMs: prev?.maxMs,
        playedAtSec: sec,
        updatedAtSec: _nextUpdated(prev),
      ),
    );
  }

  /// 写续播点（毫秒）。`null` / `<= 0` 一律记成「没有可续的点」。
  ///
  /// 与 `MediaRepository.saveResumePosition` 同一口径：**不写 0**，
  /// `null` 才是这一列真正的「没有可续的点」。
  bool recordResume(String itemId, int? resumeMs) {
    if (itemId.isEmpty) return false;
    final value = (resumeMs == null || resumeMs <= 0) ? null : resumeMs;
    final old = _book[itemId];
    if (old != null && old.resumeMs == value) return false;
    return _put(
      itemId,
      (prev) => ProgressEntry(
        resumeMs: value,
        maxMs: prev?.maxMs,
        playedAtSec: prev?.playedAtSec,
        updatedAtSec: _nextUpdated(prev),
      ),
    );
  }

  /// 把「历史最大播放位置」往上顶到 [positionMs]（**只增不减**）。
  bool recordMax(String itemId, int positionMs) {
    if (itemId.isEmpty || positionMs <= 0) return false;
    final old = _book[itemId];
    if (old != null && old.maxMs != null && old.maxMs! >= positionMs) {
      return false;
    }
    return _put(
      itemId,
      (prev) => ProgressEntry(
        resumeMs: prev?.resumeMs,
        maxMs: positionMs,
        playedAtSec: prev?.playedAtSec,
        updatedAtSec: _nextUpdated(prev),
      ),
    );
  }

  /// 把一份**远程**（或从库里导出）的进度合进来。
  ///
  /// 返回被改变的条目数（0 = 无需上传）。会先 [load]，理由见类文档。
  Future<int> mergeFrom(ProgressBook other) async {
    await load();
    final changed = _book.mergeFrom(other);
    if (changed > 0) _markDirty();
    return changed;
  }

  // -------------------------------------------------------------------
  // 落盘
  // -------------------------------------------------------------------

  /// 安排一次防抖落盘。重复调用只会重置计时器。
  void _markDirty() {
    _dirty = true;
    if (_disposed) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      unawaited(flush());
    });
  }

  /// 立刻落盘（若有改动）。同步服务在上传之前**必须**先 await 它，
  /// 否则上传的会是「内存里比磁盘新」的那一份 —— 两端内容对不上。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    // ⛔ 先保证读过磁盘：不读就写会把文件覆盖成「只有内存里那几条」。
    await load();
    if (!_dirty) return;
    // 合并并发调用：同一时刻只允许一个写序列在跑。
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _writeNow();
    _inFlight = future;
    try {
      await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _writeNow() async {
    final text = _book.toJsonString();
    final tmp = File('$_path.tmp');
    try {
      await tmp.parent.create(recursive: true);
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(_path);
      // ⛔ 只有写成功才清 `_dirty`。写失败时留着它，下一次写入会再试一次 ——
      //    清掉的话这次改动就永远只活在内存里，而进程一退就没了。
      _dirty = false;
    } catch (e) {
      diag.error('进度', '进度文件写入失败（${_book.length} 条）：$e');
    }
  }

  /// 关掉计时器并做最后一次落盘。
  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  // -------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------

  bool _put(
    String itemId,
    ProgressEntry Function(ProgressEntry? prev) build,
  ) {
    final next = build(_book[itemId]);
    _book[itemId] = next;
    _markDirty();
    return true;
  }

  /// 这一条新的 `updatedAtSec`：取「现在」与「旧值」的较大者。
  ///
  /// ⛔ 不取 `max` 的话，一次时钟回拨会让新写入的 `u` 小于网盘上那份旧的
  ///    `u`，于是**本地刚看的进度在合并时输给远程的旧进度** —— 表现是
  ///    「看完一集回到电脑上，进度又退回去了」，而且两边都显示同步成功。
  int _nextUpdated(ProgressEntry? prev) {
    final now = _clock().millisecondsSinceEpoch ~/ 1000;
    final old = prev?.updatedAtSec ?? 0;
    return now > old ? now : old;
  }
}
