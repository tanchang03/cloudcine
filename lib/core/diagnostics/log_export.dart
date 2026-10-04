import 'dart:io';

/// 日志导出正文的来源。会写进文件头 —— 读日志的人得先知道
/// 「这份日志是完整的，还是只截了尾巴」，否则会对着半截日志下结论。
enum LogExportSource {
  file('日志文件（完整）'),
  fileTruncated('日志文件（末尾截断）'),
  buffer('内存缓冲');

  const LogExportSource(this.label);

  final String label;
}

/// 一次「把日志带走」的载荷：文件名 + 正文。
///
/// 之所以要成一个值对象而不是直接传字符串：文件名和正文是**一起**产生的，
/// 分开算就会出现「名字里的时间戳和正文头部的时间对不上」这种事后极难察觉的
/// 错位，而日志本来就只在出问题时才被翻出来看。
class LogExportPayload {
  const LogExportPayload({
    required this.fileName,
    required this.text,
    required this.source,
  });

  /// 上传到网盘后的文件名。
  final String fileName;

  /// 完整正文（含头部）。
  final String text;

  /// 正文来自哪里。
  final LogExportSource source;
}

/// 正文的字符上限。
///
/// 日志文件是**按天追加**的：一次长时间的折腾能把它写到几 MB，而这条通道走的是
/// 电视的上行带宽 —— 整份传上去可能几分钟都传不完，可真正要看的几十行永远在
/// **最末尾**。所以超长时只发末尾 [logExportMaxChars] 个字符，并在头部写明
/// 「被截了、原文多长」，免得读的人以为日志就这么点。
const int logExportMaxChars = 400000;

/// 文件名里用的平台标签。
///
/// 不直接用 `Platform.localHostname`：Android 上它基本恒定返回 `localhost`，
/// 对「这份日志是哪台机器发的」毫无帮助，还带一个要清洗的字符集。
String logPlatformTag({String? override}) {
  if (override != null) return override;
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

/// `cloudcine-log-android-20261004-164512.txt`
///
/// ⚠️ 带时间戳而不是固定名，是有意的：上传前会先删同名旧文件
/// （见 `LibraryBackupService.uploadFileToBackupDir` 的覆盖语义），
/// 固定名意味着**每传一次就毁掉上一份**。万一这次上传中途失败，
/// 上一次的日志已经没了 —— 而日志恰恰是出事之后才想起来要的东西。
String logExportFileName({
  required DateTime now,
  required String platformTag,
  String prefix = 'cloudcine-log',
  String extension = '.txt',
}) {
  final stamp = '${now.year}${_two(now.month)}${_two(now.day)}'
      '-${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
  return '$prefix-$platformTag-$stamp$extension';
}

/// 截取正文的**末尾** [maxChars] 个字符。
///
/// 按**字符**而不是字节切：日志里大量中文，按字节切会把一个汉字劈成半个，
/// 上传上去就是一段乱码开头 —— 而乱码正好出现在文件开头，最容易被当成
/// 「日志文件损坏了」。
String capLogText(String text, {int maxChars = logExportMaxChars}) {
  if (maxChars <= 0) return '';
  if (text.length <= maxChars) return text;
  return text.substring(text.length - maxChars);
}

/// 组装要上传的日志文本。
///
/// 正文**优先取日志文件**而不是内存环形缓冲：文件里有启动那几行
/// （设备信息、凭证状态、沙箱路径），而缓冲只有最后 800 行，启动阶段的内容
/// 早被挤掉了 —— 偏偏「一打开就播不了」这类问题的答案就在那几行里。
/// 文件读不到（写盘失败、被清掉）时才退回缓冲。
///
/// [readFile] 默认真的去读 [filePath]；测试里换成假的即可，
/// 不必造一个真实文件、也不必去启动全局日志单例。
Future<LogExportPayload> buildLogExportPayload({
  required String? filePath,
  required String buffer,
  required DateTime now,
  String? platformTag,
  int maxChars = logExportMaxChars,
  Future<String> Function(String path)? readFile,
}) async {
  final tag = platformTag ?? logPlatformTag();
  final fileName = logExportFileName(now: now, platformTag: tag);

  var body = buffer;
  var source = LogExportSource.buffer;
  String? note;

  final path = filePath;
  if (path != null) {
    try {
      final raw = await (readFile ?? _readTextFile)(path);
      if (raw.trim().isEmpty) {
        note = '日志文件是空的，改用内存缓冲';
      } else {
        final capped = capLogText(raw, maxChars: maxChars);
        body = capped;
        if (capped.length == raw.length) {
          source = LogExportSource.file;
        } else {
          source = LogExportSource.fileTruncated;
          note = '原文 ${raw.length} 字符，只发末尾 ${capped.length} 字符';
        }
      }
    } catch (e) {
      note = '读取日志文件失败：$e';
    }
  } else {
    note = '本次没有日志文件（写盘失败），只有内存缓冲';
  }

  final header = StringBuffer()
    ..writeln('# 云影诊断日志')
    ..writeln('导出时间：${_stamp(now)}')
    ..writeln('平台：$tag')
    ..writeln('来源：${source.label}')
    ..writeln('日志文件：${path ?? "（无）"}')
    ..writeln('内存缓冲：${buffer.isEmpty ? 0 : buffer.split("\n").length} 行');
  if (note != null) header.writeln('说明：$note');
  header.writeln('---');

  return LogExportPayload(
    fileName: fileName,
    text: '${header.toString()}\n$body',
    source: source,
  );
}

Future<String> _readTextFile(String path) => File(path).readAsString();

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} '
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
