import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/redact.dart';

/// 诊断日志级别。
///
/// [osLevel] 是传给 `dart:developer` 的数值，让日志同时出现在
/// Console.app / `log stream` 里（release 模式没有 stdout 可看）。
enum DiagLevel {
  debug('DEBUG', 500),
  info('INFO ', 800),
  warn('WARN ', 900),
  error('ERROR', 1000);

  const DiagLevel(this.label, this.osLevel);

  /// 定宽 5 字符，让日志正文左对齐
  final String label;

  final int osLevel;
}

/// 诊断日志。
///
/// **为什么需要它**：release 模式没有控制台 —— `print` / `debugPrint` 的输出
/// 在双击启动的 .app 里哪儿都看不到，出问题只能靠猜。这个模块把关键链路的
/// 每一次决策落成**可读的文本**，让「哪一步失败、为什么失败」变成事后能翻查的
/// 事实，而不是推断。
///
/// 三个刻意的取舍：
///   1. **同步写盘**。日志量很小（一次播放尝试几十行），换来的是崩溃前最后
///      几行一定已经落盘；异步 `IOSink` 在进程被 kill 时会丢掉缓冲区内容。
///   2. **落盘 + 环形缓冲双份**。环形缓冲供 UI 实时查看；文件供事后取证 ——
///      即使 UI 已经崩了，文件还在。
///   3. **脱敏兜底**。调用方应当用 `redact.dart` 里的助手主动脱敏（只打印
///      请求头的**键名**、URL 只留协议+主机+路径），这里再扫一遍 `key=value`，
///      是防止哪天有人手滑把 Cookie 或直链签名直接拼进消息。
///
/// 日志文件位置：`<应用支持目录>/logs/cloudcine-YYYY-MM-DD.log`。
/// ⚠️ 这个目录**受沙箱影响** —— 沙箱下会落在
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/...`，
/// 所以启动时务必把实际路径写进日志（见 [isSandboxed]）。
class DiagLog {
  DiagLog._();

  /// 仅测试用：拿一个与全局单例互不干扰的实例。
  /// 单例带状态（环形缓冲、文件句柄），测试直接用它会让用例互相污染。
  @visibleForTesting
  DiagLog.forTesting();

  static final DiagLog instance = DiagLog._();

  /// 内存里保留的最大行数（供 UI 查看，不限制落盘）
  static const int maxLines = 800;

  /// 日志文件保留天数
  static const int keepDays = 7;

  static const String _filePrefix = 'cloudcine-';

  final List<String> _lines = <String>[];

  File? _file;
  String? _supportPath;
  bool _started = false;

  /// 写盘失败只记一次 —— 否则「磁盘满了」会变成日志刷屏
  bool _fileWriteBroken = false;

  /// 每写一行自增。UI 用 `ValueListenableBuilder` 监听它刷新列表。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool get isStarted => _started;

  /// 当前日志文件路径；未启动或建文件失败时为 null
  String? get filePath => _file?.path;

  /// 应用支持目录（数据库所在目录）
  String? get supportPath => _supportPath;

  /// 应用数据目录是否位于 macOS 沙箱容器内。
  ///
  /// 这是「debug 能播、release 不能播」这类问题的**头号嫌疑**：
  /// 沙箱会把 `getApplicationSupportDirectory()` 重定向到
  /// `~/Library/Containers/<bundle-id>/Data/...`，于是两个 build 各有各的
  /// 数据库、各有各的凭证存储位置，行为自然不一样。
  bool get isSandboxed {
    final path = _supportPath;
    return path != null && path.contains('/Library/Containers/');
  }

  /// 最近 [maxLines] 行的副本
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 把内存里的日志整段导出（供「复制全部」）
  String dump() => _lines.join('\n');

  // -------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------

  /// 启动日志。必须在 `runApp` 之前调用，否则启动阶段的日志会丢。
  ///
  /// 失败不抛异常 —— 日志系统本身不该成为启动失败的原因。
  Future<void> start({required String supportDirPath}) async {
    if (_started) return;
    _started = true;
    _supportPath = supportDirPath;

    try {
      final dir = Directory(
        '$supportDirPath${Platform.pathSeparator}logs',
      );
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _pruneOldFiles(dir);
      _file = File('${dir.path}${Platform.pathSeparator}${_nameFor(DateTime.now())}');
    } catch (e) {
      _file = null;
      _fileWriteBroken = true;
      // 写不进文件也要能在内存里看到这条
      _push('${_stamp(DateTime.now())} ${DiagLevel.warn.label} [日志] '
          '日志目录不可写，本次仅保留内存日志：$e');
      return;
    }

    // 立刻写一行会话头，两个作用：
    //   1. 让日志文件**马上存在** —— 用户点开「诊断日志」页就能按路径找到它，
    //      而不是要等第一次出错才凭空出现一个文件；
    //   2. 给多次运行之间留一道肉眼可见的分界，翻日志时不会把两次启动
    //      的上下文混在一起。
    section('会话开始');
  }

  /// 清空内存缓冲。**不删文件** —— 文件是取证用的，要删由用户自己去访达删。
  void clearBuffer() {
    _lines.clear();
    revision.value++;
  }

  // -------------------------------------------------------------------
  // 写入
  // -------------------------------------------------------------------

  void debug(String tag, String message) => add(DiagLevel.debug, tag, message);

  void info(String tag, String message) => add(DiagLevel.info, tag, message);

  void warn(String tag, String message, {Object? error}) =>
      add(DiagLevel.warn, tag, message, error: error);

  void error(
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      add(DiagLevel.error, tag, message,
          error: error, stackTrace: stackTrace);

  /// 写一段分隔标题，让日志按「一次播放 / 一次扫描」分段，便于肉眼定位。
  void section(String title) {
    add(DiagLevel.info, '分段', '──────── $title ────────');
  }

  void add(
    DiagLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final buffer = StringBuffer(
      '${_stamp(DateTime.now())} ${level.label} [$tag] '
      '${scrubSecrets(message)}',
    );
    if (error != null) buffer.write(' | ${scrubSecrets(error.toString())}');
    final line = buffer.toString();

    _push(line);

    if (stackTrace != null) {
      // 只留前 12 帧：够定位，又不至于把日志淹掉
      for (final frame in stackTrace.toString().split('\n').take(12)) {
        _push('    $frame');
      }
    }

    developer.log(
      line,
      name: 'cloudtune',
      level: level.osLevel,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// 追加一行到环形缓冲并落盘
  void _push(String line) {
    _lines.add(line);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    revision.value++;
    _append(line);
  }

  void _append(String line) {
    if (_fileWriteBroken) return;
    try {
      final file = _ensureFile();
      if (file == null) return;
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      // 日志写不进去不能影响主流程。只标记一次，不再重试、不再递归记录。
      _fileWriteBroken = true;
    }
  }

  /// 跨天时切换到当天的文件
  File? _ensureFile() {
    final support = _supportPath;
    if (support == null) return null;

    final name = _nameFor(DateTime.now());
    final current = _file;
    if (current != null && current.path.endsWith(name)) return current;

    final file = File(
      '$support${Platform.pathSeparator}logs${Platform.pathSeparator}$name',
    );
    _file = file;
    return file;
  }

  // -------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------

  static String _nameFor(DateTime t) =>
      '$_filePrefix${t.year}-${_two(t.month)}-${_two(t.day)}.log';

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _stamp(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')}';

  /// 删掉超过 [keepDays] 天的旧日志
  static void _pruneOldFiles(Directory dir) {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: keepDays));
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(_filePrefix) || !name.endsWith('.log')) continue;
        if (entity.statSync().modified.isBefore(cutoff)) entity.deleteSync();
      }
    } catch (_) {
      // 清理失败无所谓，不影响写入
    }
  }
}

/// 全局入口：`diag.info('取链', '…')`。
final DiagLog diag = DiagLog.instance;
