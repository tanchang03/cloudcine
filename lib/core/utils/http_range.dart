/// HTTP Range 语义的解析与生成。
///
/// 本地流式代理必须自己处理 Range：mpv 靠它做 seek 与断点续读，而
/// `dart:io` 只把原始字符串递过来，**不做任何解释**。解析错了的表现是
/// 「能播但一拖进度条就黑屏」，而不是任何一条能查的异常。
library;

import 'dart:math' as math;

/// 一个**闭区间**字节范围（两端都包含，与 HTTP 的 `bytes=a-b` 一致）。
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;

  /// 闭区间终点。不是「长度」—— 混这两个是 Range 处理里最常见的 bug。
  final int end;

  /// 区间字节数。
  int get length => end - start + 1;

  @override
  String toString() => 'bytes $start-$end';
}

/// 解析请求头 `Range: bytes=…`。
///
/// 返回 `null` 表示**客户端没有要求区间**：没有这个头，或者语法不认识。
/// 这时应当按「整个文件」响应（200），而不是猜一个起点 —— 猜错的代价是
/// 播放器拿到错误的 Content-Range，进而把整条流判成不可 seek。
///
/// [totalLength] 未知时传 `<= 0`：此时 `bytes=0-` 这种「到结尾」的写法
/// 无从换算，同样返回 `null`（按全文件响应）。
ByteRange? parseRangeHeader(String? header, int totalLength) {
  final raw = header?.trim();
  if (raw == null || raw.isEmpty) return null;

  final lower = raw.toLowerCase();
  const prefix = 'bytes=';
  if (!lower.startsWith(prefix)) return null;

  // 多段区间（`bytes=0-99,200-299`）是合法语法，但没有任何播放器的
  // 常规路径会发，而支持它意味着响应要换成 multipart/byteranges ——
  // 为一个用不到的分支引入一整套编码逻辑不值得。**只取第一段**。
  final spec = raw.substring(prefix.length).split(',').first.trim();
  final dash = spec.indexOf('-');
  if (dash < 0) return null;

  final first = spec.substring(0, dash).trim();
  final last = spec.substring(dash + 1).trim();

  // `bytes=-N`：最后 N 个字节。
  if (first.isEmpty) {
    final n = int.tryParse(last);
    if (n == null || n <= 0) return null;
    if (totalLength <= 0) return null;
    return ByteRange(math.max(0, totalLength - n), totalLength - 1);
  }

  final start = int.tryParse(first);
  if (start == null || start < 0) return null;
  if (totalLength > 0 && start >= totalLength) return null;

  int end;
  if (last.isEmpty) {
    // `bytes=N-`：从 N 到结尾。**长度未知时无法给终点** —— 返回 null 让
    // 调用方按全文件流式响应，而不是编一个假的终点。
    if (totalLength <= 0) return null;
    end = totalLength - 1;
  } else {
    final parsed = int.tryParse(last);
    if (parsed == null) return null;
    end = parsed;
    if (totalLength > 0) end = math.min(end, totalLength - 1);
  }

  if (end < start) return null;
  return ByteRange(start, end);
}

/// 生成响应头 `Content-Range` 的值。
String formatContentRange(ByteRange range, int totalLength) =>
    'bytes ${range.start}-${range.end}/$totalLength';

/// 把请求区间裁剪到文件范围内。
///
/// 客户端可能请求超过文件末尾的区间（mpv 探测时会这么干）。超出的部分
/// 直接丢掉而不是报错：按 HTTP 语义那应当是 416，但 mpv 收到 416 会**放弃
/// seek**，而它真正想要的只是「尽量多给一点」。
ByteRange? clampRange(ByteRange range, int totalLength) {
  if (totalLength <= 0) return range;
  // 起点**已经**在文件外：这是真正的 416，必须返回 null。
  //
  // 夹成「最后一个字节」是最糟的一种自作聪明 —— 客户端以为自己拿到了想要
  // 的数据，于是接着往下解，解出来的是文件末尾那几字节。
  if (range.start >= totalLength) return null;
  final end = math.min(range.end, totalLength - 1);
  if (end < range.start) return null;
  return ByteRange(range.start, end);
}
