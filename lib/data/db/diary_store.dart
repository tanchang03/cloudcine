import 'dart:async';
import 'dart:io';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/services/watch_diary.dart';

/// 观影日记的**独立落盘存储**。
///
/// ## 一句话
///
/// 一个只装日记的 JSON 文件（`<应用支持目录>/watch_diary.json`），与媒体库
/// 索引库 `cloudcine.sqlite` **互不隶属**。清空索引库删的是后者的几张表、恢复
/// 备份换的是后者的整个文件字节 —— 两条路都碰不到这个文件。日记记的是「我看过
/// 什么、我给它几分」这种**不可再生**的数据，绝不能被清库误伤。
///
/// ## 为什么是 JSON 文件，而不是第二个 SQLite 库
///
/// 与 `ProgressStore` 同一条理由（见它的类文档）：它**就是同步载荷**，
/// 本地这份与网盘上那份逐字相同，少一处能让两边悄悄分叉的地方；而且它的全部
/// 操作就是「读一整个 Map、写一整个 Map」，值不上引一套 codegen。
///
/// ## ⛔ 写入是「防抖 + 原子替换」
///
/// 日记的写入频率远低于进度（一部剧一辈子一次），但「归档」「改评分」都是
/// 用户动作，仍可能连点。所以同样用 `.tmp` + `rename`：写到一半被杀（电视上
/// 常见）只会留一份截断的临时文件，原文件完好。
///
/// ## ⛔ 写之前**一定**先 [load]
///
/// 见 `ProgressStore` 类文档的同一条：不读就写，会把文件覆盖成「只有刚写的那
/// 一条」，用户磁盘上原有的几百条日记全没了，而且静默。
class DiaryStore {
  DiaryStore({
    required String filePath,
    Duration flushDelay = const Duration(seconds: 2),
  })  : _path = filePath,
        _flushDelay = flushDelay;

  /// 本地日记文件名。与网盘上那份**同名**（见 `LibraryBackupService.diaryFileName`）。
  static const String fileName = 'watch_diary.json';

  final String _path;
  final Duration _flushDelay;

  final DiaryBook _book = DiaryBook();
  bool _loaded = false;
  bool _dirty = false;
  Timer? _flushTimer;
  Future<void>? _loading;
  Future<void>? _inFlight;
  bool _disposed = false;

  /// 落盘路径。
  String get path => _path;

  /// 内存里的那份。**只读用途**（同步服务拿它序列化上传）。
  DiaryBook get book => _book;

  bool get isLoaded => _loaded;
  bool get isDirty => _dirty;

  // -------------------------------------------------------------------
  // 读
  // -------------------------------------------------------------------

  /// 从磁盘读一次。重复调用幂等。
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadNow();
  }

  Future<void> _loadNow() async {
    try {
      final file = File(_path);
      if (!await file.exists()) {
        diag.info('日记', '日记文件不存在，从空开始：$_path');
      } else {
        final text = await file.readAsString();
        final loaded = DiaryBook.fromJsonString(text);
        final added = _book.mergeFrom(loaded);
        diag.info(
          '日记',
          '已载入日记文件：磁盘 ${loaded.length} 条、合入 $added 条'
          '（内存共 ${_book.length} 条）',
        );
      }
    } catch (e) {
      diag.warn('日记', '读取日记文件失败，从空开始：$e');
    } finally {
      _loaded = true;
    }
  }

  // -------------------------------------------------------------------
  // 写（内存 + 防抖落盘）
  // -------------------------------------------------------------------

  /// 写入/覆盖一条。**返回是否真的改了东西**（内容没变就不落盘、不触发同步）。
  ///
  /// 调用方（评分/移出/归档）在传入前已经用 [DiaryEntry.copyWith] 做好了合并，
  /// 这里只负责"按 id 落位 + 标脏"。
  bool put(DiaryEntry entry) {
    final prev = _book[entry.id];
    if (prev != null && prev.sameAs(entry)) return false;
    _book.put(entry);
    _markDirty();
    return true;
  }

  /// 把一份（本地/远程/捕获）日记合进来。返回被改变的条目数（0 = 无需上传/上传）。
  /// 会先 [load]。
  Future<int> mergeFrom(DiaryBook other) async {
    await load();
    final changed = _book.mergeFrom(other);
    if (changed > 0) _markDirty();
    return changed;
  }

  /// 取一条（含墓碑）。展示用 [DiaryBook.visible]。
  DiaryEntry? getEntry(String id) => _book[id];

  // -------------------------------------------------------------------
  // 落盘
  // -------------------------------------------------------------------

  void _markDirty() {
    _dirty = true;
    if (_disposed) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDelay, () {
      unawaited(flush());
    });
  }

  /// 立刻落盘（若有改动）。同步服务上传前**必须**先 await 它。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await load();
    if (!_dirty) return;
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
      _dirty = false;
    } catch (e) {
      diag.error('日记', '日记文件写入失败（${_book.length} 条）：$e');
    }
  }

  /// 关掉计时器并做最后一次落盘。
  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }
}
