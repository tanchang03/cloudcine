/// mpv `demuxer-cache-state` 属性的解析。
///
/// 纯函数、无副作用，便于单元测试。
library;

import 'dart:convert';

/// 从 mpv 的 `demuxer-cache-state` 里取出**真实输入速率**（字节/秒）。
///
/// ## 为什么需要它
///
/// `demuxer-cache-time`（media_kit 的 `player.stream.buffer`）只告诉我们
/// 「缓存涨了多少**秒**」。想变成字节/秒，就得乘一个平均码率 —— 那是估算，
/// 而且播转码档时码率根本对不上（详见 `cacheBytesPerSecond`）。
///
/// mpv 其实**直接给了字节速率**：`demuxer-cache-state.raw-input-rate`，
/// 单位就是字节/秒。它取自输入层「未缓冲读取字节数」计数器的差分
/// （`demux_reader_state.bytes_per_second`），也就是**实际从流里读了多少
/// 字节**，而不是解复用产出了多少 —— 这正是「网速」。
///
/// 本项目随包的 libmpv 是 **0.36.0**，字段名已直接在二进制里核对过存在：
/// `strings .../Mpv.framework/Versions/A/Mpv | grep -Fx raw-input-rate`。
///
/// ## 为什么解析要留两手
///
/// `getProperty` 走的是 `mpv_get_property_string`，而 mpv 官方头文件对
/// **node 类型属性转字符串**只写了一句「通常会走一个字符串格式化器」——
/// **没有**承诺是 JSON（`client.h` 里全文没有 "JSON" 二字，且
/// `mpv_get_property_osd_string` 还明确写了「别解析这些串」）。
///
/// 实测惯例是 JSON，但我们没法在本机跑真播放器验证（`flutter test` 里
/// `Player()` 构造不出来）。所以：**先按 JSON 取，取不到再退回文本扫描**。
/// 两条路都不成立才返回 `null`，由调用方退回估算值 —— 宁可退回估算，
/// 也不要因为格式假设错了就让整条优化静默失效。
///
/// 拿不到、解析不了、值不合理时一律返回 `null`，**不要返回 0**：
/// 0 会被显示成「网速是 0」，而真相是「不知道」。
double? rawInputBytesPerSecond(String cacheState) {
  if (cacheState.isEmpty) return null;

  final raw = _rawInputRateField(cacheState);
  final value = switch (raw) {
    num n => n.toDouble(),
    String s => double.tryParse(s),
    _ => null,
  };
  if (value == null || value.isNaN || value.isInfinite) return null;
  // 负值/零 = 当前没在下载（或还没测出来），不是「网速为 0」。
  if (value <= 0) return null;
  return value;
}

/// 先按 JSON 取 `raw-input-rate`；JSON 走不通就退回文本扫描。
Object? _rawInputRateField(String cacheState) {
  try {
    final decoded = jsonDecode(cacheState);
    if (decoded is Map) {
      final value = decoded['raw-input-rate'];
      if (value != null) return value;
    }
  } on FormatException {
    // 不是严格 JSON —— 落到下面的文本扫描。
    // 不往外抛：这个函数跑在播放路径上。
  }
  return _scanRawInputRate(cacheState);
}

/// 键名两侧的引号可选：mpv 正常会带，但带不带都不该影响取值。
final RegExp _rawInputRatePattern = RegExp(
  r'"?raw-input-rate"?\s*:\s*(-?[0-9][0-9.eE+-]*)',
);

String? _scanRawInputRate(String text) =>
    _rawInputRatePattern.firstMatch(text)?.group(1);
