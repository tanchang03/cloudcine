/// 网盘上「小文本文件」的编码判定与解码。
///
/// 单独一个文件是因为**同一套判定现在有两个使用者**：CUE 分轨表
/// （`cue_sheet.dart`）和歌词（`lrc.dart`）。两者面对的是同一类文件 ——
/// 中文 Windows 上的抓轨工具写出来的本地代码页文本 —— 所以判定规则必须
/// 一模一样，否则会出现「CUE 读得出来、同一个目录的 LRC 全是乱码」
/// 这种没法解释的现象。
///
/// 只有 `dart:convert` 的话解不了 GBK（它只有 utf8 / latin1 / ascii），
/// 所以依赖 `fast_gbk`（纯 Dart，无原生依赖）。
library;

import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

/// 按文本的**实际编码**把字节解成字符串。
///
/// 判定顺序刻意是「**先严格 UTF-8，失败再 GBK**」，这个判据很稳：
///   - GBK 的汉字是 `0x81-0xFE` 开头的双字节，几乎必然不是合法 UTF-8 序列，
///     严格解码会抛 `FormatException`；
///   - 纯 ASCII 的文本（英文歌词、只有 `[00:12.34]` 的 LRC）两种编码解出来
///     完全一样，走 UTF-8 分支即可。
///
/// 顺序不能反过来：GBK 解码器对**任何**字节序列都能吐出一个字符串
/// （它没有非法序列的概念），先试 GBK 会让一份完好的 UTF-8 文件被解成乱码，
/// 而且**不会报错** —— 这种错误没有任何补救余地。
///
/// 两种都解不了（文件被截断 / 损坏）时用替换字符兜底：至少把 ASCII 的部分
/// 留下来（CUE 的指令关键字与时间轴、LRC 的时间戳），内容残缺好过整份丢掉。
String decodeTextBytes(List<int> bytes) {
  if (bytes.isEmpty) return '';
  var data = bytes;
  // 去 UTF-8 BOM。
  //
  // 注意这**不是解析的硬前提**：解析器每行都会 `trim()`，而 Dart 的
  // `trim()` 按 ECMAScript 的空白定义走，U+FEFF 也在其列，所以带 BOM 的
  // 文本照样能解析出内容。这一步保证的是**解出来的文本本身是干净的**：
  // 调用方拿它做前缀比较、存库或直接展示时不会撞上一个看不见的零宽字符。
  if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) {
    data = data.sublist(3);
  }
  try {
    return utf8.decode(data);
  } on FormatException {
    try {
      return gbk.decode(data);
    } catch (_) {
      return utf8.decode(data, allowMalformed: true);
    }
  }
}
