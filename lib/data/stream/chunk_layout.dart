/// 把整条流切成**定长块**，并负责「字节偏移 ↔ 块序号」的换算。
///
/// 本地流式代理的一切调度都以块为单位：多线程并发拉的是块、LRU 淘汰的是
/// 块、mpv 请求的是字节区间但要落到块上。换算规则只能有一份 —— 三处各写
/// 一遍算术，错一次的表现是「播到某个位置开始花屏」，极难定位。
library;

import 'dart:math' as math;

import '../../core/utils/http_range.dart';

class ChunkLayout {
  const ChunkLayout({
    required this.chunkSize,
    required this.totalLength,
  })  : assert(chunkSize > 0),
        assert(totalLength > 0);

  /// 单块字节数。
  final int chunkSize;

  /// 文件总字节数。**必须已知**：长度未知时无法做随机访问与预取调度。
  final int totalLength;

  int get chunkCount => (totalLength + chunkSize - 1) ~/ chunkSize;

  /// 第 [index] 块的起始字节偏移。
  int startOf(int index) => index * chunkSize;

  /// 第 [index] 块的**闭区间**终点。最后一块会被文件末尾截断。
  int endOf(int index) =>
      math.min(startOf(index) + chunkSize, totalLength) - 1;

  /// 第 [index] 块的字节数（最后一块可能不足 [chunkSize]）。
  int lengthOf(int index) => endOf(index) - startOf(index) + 1;

  /// [offset] 落在第几块。
  int indexOf(int offset) => offset ~/ chunkSize;

  /// 覆盖 [range] 的块序号，升序连续。
  List<int> indicesOf(ByteRange range) {
    final first = indexOf(range.start);
    final last = indexOf(range.end);
    return List<int>.generate(last - first + 1, (i) => first + i, growable: false);
  }

  /// 第 [index] 块的请求区间（闭区间），直接用于 `Range` 头。
  ByteRange rangeOf(int index) => ByteRange(startOf(index), endOf(index));

  bool isValidIndex(int index) => index >= 0 && index < chunkCount;
}
