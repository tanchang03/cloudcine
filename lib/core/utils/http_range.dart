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

/// `Range` 头的解析结果。
///
/// ## 为什么必须是「结果类型」，而不是 `ByteRange?`
///
/// 曾经这里是 `ByteRange? parseRangeHeader(...)`，用**一个 `null`** 同时表达
/// 三件处置**完全不同**的事：
///
///   1. 客户端没要求区间（没有这个头）→ 应当 `200` + 整文件；
///   2. 语法不认识 / 长度未知，算不出区间 → 应当 `200` + 整文件；
///   3. 语法合法，但**起点已在文件之外** → **必须 `416`**。
///
/// 调用方手里只有一个 `null`，就只能三选一。本地中继当时选了「整文件」，
/// 于是「`bytes=5014520206-` 去问一条 3.13 GiB 的流要第 5.01 GB」被回成了
/// **`200` + 从 0 开始的整条流**：
///
///   * HTTP 语义上，对一个带 Range 的请求回 `200` 等于「我不支持区间，
///     这是完整资源」。播放器（media3 `DefaultHttpDataSource`）于是把
///     响应体**前 `position` 个字节丢掉**去对齐它要的偏移；
///   * 可它要的偏移是 5.01 GB，而整条流只有 3.13 GiB —— 它会把整部片子
///     读完、丢掉，然后才报 EOF。
///
/// 实测现场（小米电视，`凡人` 4K 3.13 GiB）：`正在加载…` 一直不消失、
/// 中继 loopback 稳定 2.1 MB/s、读满 7 分钟仍未出首帧 —— 它正卡在
/// 「读完整部片子去跳过 5.01 GB」这一步。
///
/// 把三种处置做成三个类型，调用方就**必须**逐个写出来，编译器不允许漏。
sealed class RangeRequest {
  const RangeRequest();
}

/// 客户端**没有**要求区间 —— 按 `200` + 整文件响应。
final class NoRangeRequest extends RangeRequest {
  const NoRangeRequest();
}

/// 要到了一个**可满足**的区间 —— 按 `206` + 该区间响应。
final class SatisfiableRange extends RangeRequest {
  const SatisfiableRange(this.range);

  final ByteRange range;
}

/// 语法合法，但**起点已在文件之外** —— 按 `416` 响应
/// （`Content-Range: bytes */总长`，空体）。
///
/// ⛔ **绝不允许降级成「整文件从 0 开始」**：见 [RangeRequest] 的文档。
final class UnsatisfiableRange extends RangeRequest {
  const UnsatisfiableRange();
}

/// 解析请求头 `Range: bytes=…`。
///
/// [totalLength] 未知时传 `<= 0`：此时 `bytes=0-` 这种「到结尾」的写法
/// 无从换算，返回 [NoRangeRequest]（按全文件响应），**不是** 416 ——
/// 「不知道」和「要不到」是两件事。
RangeRequest parseRangeRequest(String? header, int totalLength) {
  final raw = header?.trim();
  if (raw == null || raw.isEmpty) return const NoRangeRequest();

  final lower = raw.toLowerCase();
  const prefix = 'bytes=';
  // 单位不认识（`items=0-9`）：RFC 7233 要求**忽略**这个头，按 200 整文件
  // 响应，而不是 416。
  if (!lower.startsWith(prefix)) return const NoRangeRequest();

  // 多段区间（`bytes=0-99,200-299`）是合法语法，但没有任何播放器的
  // 常规路径会发，而支持它意味着响应要换成 multipart/byteranges ——
  // 为一个用不到的分支引入一整套编码逻辑不值得。**只取第一段**。
  final spec = raw.substring(prefix.length).split(',').first.trim();
  final dash = spec.indexOf('-');
  // `bytes=100`：没有 `-`，语法不认识。
  if (dash < 0) return const NoRangeRequest();

  final first = spec.substring(0, dash).trim();
  final last = spec.substring(dash + 1).trim();

  // `bytes=-N`：最后 N 个字节。
  if (first.isEmpty) {
    final n = int.tryParse(last);
    if (n == null || n <= 0) return const NoRangeRequest();
    if (totalLength <= 0) return const NoRangeRequest();
    return SatisfiableRange(ByteRange(math.max(0, totalLength - n), totalLength - 1));
  }

  final start = int.tryParse(first);
  if (start == null || start < 0) return const NoRangeRequest();
  // ⚠️ 这一条是**唯一**该给 416 的分支：起点合法但落在文件之外。
  //    它以前返回 null，与「没要求区间」混在一起 —— 就是那个 bug。
  if (totalLength > 0 && start >= totalLength) return const UnsatisfiableRange();

  int end;
  if (last.isEmpty) {
    // `bytes=N-`：从 N 到结尾。**长度未知时无法给终点** —— 按全文件响应，
    // 而不是编一个假的终点。
    if (totalLength <= 0) return const NoRangeRequest();
    end = totalLength - 1;
  } else {
    final parsed = int.tryParse(last);
    if (parsed == null) return const NoRangeRequest();
    end = parsed;
    if (totalLength > 0) end = math.min(end, totalLength - 1);
  }

  // 终点小于起点：整条 Range 头非法 → 忽略它，按 200 整文件响应。
  if (end < start) return const NoRangeRequest();
  return SatisfiableRange(ByteRange(start, end));
}

/// 生成响应头 `Content-Range` 的值。
String formatContentRange(ByteRange range, int totalLength) =>
    'bytes ${range.start}-${range.end}/$totalLength';

/// 把请求区间裁剪到文件范围内。
///
/// 客户端可能请求超过文件末尾的区间（mpv 探测时会这么干）。超出的部分
/// 直接丢掉而不是报错：按 HTTP 语义那应当是 416，但 mpv 收到 416 会**放弃
/// seek**，而它真正想要的只是「尽量多给一点」。
///
/// ⚠️ 这条策略现在由 [parseRangeRequest] 负责执行（它在解析时就截断终点）。
/// 本地中继**已经不再调用**本函数 —— 留着它是因为「裁剪到文件范围内」本身
/// 是个独立、可测的语义；新代码请优先用 [parseRangeRequest]，它不会把
/// 「起点越界」（必须 416）和「没要求区间」（按整文件响应）混成一个 null。
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
