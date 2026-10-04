/// 杜比视界（Dolby Vision）片源探测。
///
/// ## 为什么要在**播放之前**自己解析容器
///
/// 杜比视界 Profile 5 的像素在 Dolby 私有的 **IPT-PQ-C2** 色彩空间里，不是
/// YCbCr。要还原成 RGB 必须把 **RPU** 元数据应用到画面上 —— 而这件事发生在
/// **渲染阶段**，不是解码阶段（实测：软解帧与 `-hwaccel videotoolbox` 帧逐字节
/// 相同）。于是「内核能不能渲染 DV」决定了颜色对不对，而**判断片源是不是 DV**
/// 只能回到容器元数据本身。
///
/// 让播放器先打开再问它「这是不是 DV」是行不通的：打开本身就要求**先选好**
/// 用哪个内核。所以必须在开播前拿到答案。
///
/// ## 判据存在哪儿
///
/// 两个容器族各有一处，都在**文件很靠前**的位置（实测我们那条 4K DV 片源，
/// 映射记录在偏移 439 字节处），所以读一个头部区间就够：
///
/// - **Matroska / WebM（EBML）**：`Segment` → `Tracks` → `TrackEntry` →
///   `BlockAdditionMapping`(0x41E4)，其中 `BlockAddIDType`(0x41E7) 等于
///   `0x64766343`（ASCII `"dvcC"`）或 `0x64767643`（`"dvvC"`）时，
///   `BlockAddIDExtraData`(0x41ED) 就是 24 字节的 DOVI 配置记录。
///   ⚠️ **别去搜字面量 `dvcC`**：那个字符串是 `BlockAddIDType` 的**值**，
///   文件里出现的是它的 4 字节大端表示，不是可读文本。
/// - **ISO BMFF（MP4 / MOV）**：`moov` → … → `stsd` 里的 `dvcC` / `dvvC` 盒，
///   盒体本身就是那 24 字节记录。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 解析出来的杜比视界配置。
///
/// 字段名沿用 Dolby《Dolby Vision Streams Within the ISO Base Media File
/// Format》里的记录字段名，便于和规范对照。
class DolbyVisionInfo {
  const DolbyVisionInfo({
    required this.profile,
    required this.level,
    required this.blSignalCompatibilityId,
    required this.rpuPresent,
    required this.elPresent,
    required this.blPresent,
  });

  /// DV 档位。**5 = 单层 IPT-PQ-C2，最常见也最麻烦的那一档**；
  /// 7/8 通常带 HDR10 兼容 base layer；9 是 AVC 系。
  final int profile;

  /// 档位内的等级（影响码率上限），与颜色无关。
  final int level;

  /// base layer 的信号兼容性。
  ///
  /// **0 = 没有兼容层** —— 也就是说这条流**没有 HDR10 兜底**，把它当普通
  /// HDR10 或 SDR 播都会偏色，且**任何 tone-mapping 参数都救不回来**。
  /// 非 0（常见 1/2/4/6）表示还能退化成 HDR10，那就有别的出路。
  final int blSignalCompatibilityId;

  /// 是否带 RPU（动态元数据）。P5 必有。
  final bool rpuPresent;

  /// 是否带增强层（FEL/MEL）。P7 才有。
  final bool elPresent;

  /// 是否带 base layer。
  final bool blPresent;

  /// **必须换到支持 DV 的内核**，否则颜色一定不对。
  ///
  /// 判据刻意收得很窄，只认「P5 且没有兼容层」这一种**确定救不回来**的组合：
  /// 带 HDR10 兼容层的片子退化成 HDR10 播只是「不够好」，而把这类片子也
  /// 拽去走另一条内核，等于让它们在一条没经过验证的路径上承担风险。
  bool get needsDolbyVisionEngine =>
      profile == 5 && blSignalCompatibilityId == 0;

  /// 从 24 字节 DOVI 配置记录解析。
  ///
  /// 位布局（与规范逐位对应，别凭印象改）：
  /// ```text
  /// byte 0             dv_version_major
  /// byte 1             dv_version_minor
  /// byte 2  bits 7..1  dv_profile
  /// byte 2  bit  0     dv_level 高位
  /// byte 3  bits 7..3  dv_level 低位（与上一位拼成 6 位）
  /// byte 3  bit  2     rpu_present_flag
  /// byte 3  bit  1     el_present_flag
  /// byte 3  bit  0     bl_present_flag
  /// byte 4  bits 7..4  dv_bl_signal_compatibility_id
  /// ```
  ///
  /// 实测样本（本项目的 4K DV 片源）：`01 00 0a 4d 00 …` →
  /// profile 5、level 9、compat 0，与 `mdk` 自己打印的
  /// `Dolby Vision 1.0 Profile 5 Level 9` 完全一致。
  ///
  /// 返回 `null` 表示这 24 字节**不像**一份 DOVI 记录。这个校验是必须的：
  /// MP4 那条路靠盒名 `dvcC` 定位，而盒名只有 4 字节，误命中的代价是
  /// 拿一段随机数据当配置去解析 —— 于是会「探测出」一个不存在的档位。
  static DolbyVisionInfo? parseRecord(Uint8List record) {
    if (record.length < 5) return null;

    // 主版本号是唯一一个「合法值域很窄」的字段，拿它当第一道闸。
    // 目前规范只有 1.0；放宽到「非 0」会在随机数据上放行约 1/255。
    if (record[0] != 1) return null;

    final profile = record[2] >> 1;
    final level = ((record[2] & 0x01) << 5) | (record[3] >> 3);
    final compat = record[4] >> 4;

    // 值域闸。DV 档位目前只用到 0~9，等级 0~13（13 是 Level 13）。
    if (profile > 9) return null;
    if (level > 13) return null;

    return DolbyVisionInfo(
      profile: profile,
      level: level,
      blSignalCompatibilityId: compat,
      rpuPresent: (record[3] >> 2) & 0x01 == 1,
      elPresent: (record[3] >> 1) & 0x01 == 1,
      blPresent: record[3] & 0x01 == 1,
    );
  }

  @override
  String toString() => 'DolbyVisionInfo(profile: $profile, level: $level, '
      'compat: $blSignalCompatibilityId, rpu: $rpuPresent, '
      'el: $elPresent, bl: $blPresent)';
}

/// 自动识别容器并探测杜比视界。
///
/// [bytes] 只需是**文件头部**的一段（实测 64 KiB 足够覆盖 Matroska 的
/// `Tracks`；MP4 若是 `moov` 后置则头部探不到，见 [findDolbyVisionInIsoBmff]）。
///
/// 返回 `null` 的两种含义要分清，调用方**都不该当错误处理**：
/// 1. 这片源确实不是杜比视界；
/// 2. 需要的元素不在这一段字节里（截断了）。
///
/// 两者都无法区分，所以调用方的正确反应是「按非 DV 处理」，也就是
/// **维持现有行为** —— 而不是报错或回退到别的内核。
DolbyVisionInfo? detectDolbyVision(Uint8List bytes) {
  if (looksLikeMatroska(bytes)) return findDolbyVisionInMatroska(bytes);
  if (looksLikeIsoBmff(bytes)) return findDolbyVisionInIsoBmff(bytes);
  return null;
}

/// EBML 魔数：`1A 45 DF A3`。
bool looksLikeMatroska(Uint8List bytes) {
  if (bytes.length < 4) return false;
  return bytes[0] == 0x1A &&
      bytes[1] == 0x45 &&
      bytes[2] == 0xDF &&
      bytes[3] == 0xA3;
}

/// ISO BMFF 判据：偏移 4 处是一个已知的顶层盒名。
///
/// 判 `moov` / `mdat` 也收，是因为**不是所有文件都从 `ftyp` 开头**：
/// 有的实现直接以 `moov` 起头，而分片流媒体常见 `styp`。
bool looksLikeIsoBmff(Uint8List bytes) {
  if (bytes.length < 8) return false;
  const known = ['ftyp', 'styp', 'moov', 'mdat', 'free', 'skip'];
  final fourcc = _fourCcAt(bytes, 4);
  return fourcc != null && known.contains(fourcc);
}

// ---------------------------------------------------------------------------
// Matroska / EBML
// ---------------------------------------------------------------------------

/// `Segment`
const int _idSegment = 0x18538067;

/// `Tracks`
const int _idTracks = 0x1654AE6B;

/// `TrackEntry`
const int _idTrackEntry = 0xAE;

/// `BlockAdditionMapping`
const int _idBlockAdditionMapping = 0x41E4;

/// `BlockAddIDType`
const int _idBlockAddIdType = 0x41E7;

/// `BlockAddIDExtraData`
const int _idBlockAddIdExtraData = 0x41ED;

/// `BlockAddIDType` 的取值：ASCII `"dvcC"`。
///
/// 这是**值**不是元素名 —— 文件里以 4 字节大端 `64 76 63 43` 出现。
const int blockAddIdTypeDvcC = 0x64766343;

/// `BlockAddIDType` 的取值：ASCII `"dvvC"`（AVC 系的 DV 配置）。
const int blockAddIdTypeDvvC = 0x64767643;

/// 在 Matroska 头部字节里找 DV 配置。
///
/// 只沿 `Segment → Tracks → TrackEntry → BlockAdditionMapping` 这一条链走，
/// 不做通用 EBML 遍历：这条链之外的元素与 DV 无关，而通用遍历要维护一张
/// master 元素表，表一旦漏项就会在**某些文件**上静默失效。
DolbyVisionInfo? findDolbyVisionInMatroska(Uint8List bytes) {
  final p = _Cursor(0);
  while (p.v < bytes.length) {
    final id = _readElementId(bytes, p);
    if (id == null) break;
    final size = _readElementSize(bytes, p);
    if (size == null) break;

    if (id == _idSegment) {
      // Segment 常常声明「未知长度」（直播 / 流式写入），这时视作「到缓冲区末尾」。
      final end = size < 0 ? bytes.length : math.min(bytes.length, p.v + size);
      final found = _scanSegment(bytes, p.v, end);
      if (found != null) return found;
      break;
    }
    // 未知长度的非 Segment 元素没法跳过，只能停。
    if (size < 0) break;
    p.v += size;
  }
  return null;
}

DolbyVisionInfo? _scanSegment(Uint8List b, int start, int end) {
  final p = _Cursor(start);
  while (p.v < end) {
    final id = _readElementId(b, p);
    if (id == null) return null;
    final size = _readElementSize(b, p);
    if (size == null) return null;
    if (size < 0) {
      // 只有 Cluster 会声明未知长度，而 Tracks 一定排在 Cluster **之前**；
      // 走到这里说明 Tracks 不在这一段里，停。
      return null;
    }
    final childEnd = math.min(end, p.v + size);
    if (id == _idTracks) {
      final found = _scanTracks(b, p.v, childEnd);
      if (found != null) return found;
    }
    p.v = childEnd;
  }
  return null;
}

DolbyVisionInfo? _scanTracks(Uint8List b, int start, int end) {
  final p = _Cursor(start);
  while (p.v < end) {
    final id = _readElementId(b, p);
    if (id == null) return null;
    final size = _readElementSize(b, p);
    if (size == null || size < 0) return null;
    final childEnd = math.min(end, p.v + size);
    if (id == _idTrackEntry) {
      final found = _scanTrackEntry(b, p.v, childEnd);
      if (found != null) return found;
    }
    p.v = childEnd;
  }
  return null;
}

DolbyVisionInfo? _scanTrackEntry(Uint8List b, int start, int end) {
  final p = _Cursor(start);
  while (p.v < end) {
    final id = _readElementId(b, p);
    if (id == null) return null;
    final size = _readElementSize(b, p);
    if (size == null || size < 0) return null;
    final childEnd = math.min(end, p.v + size);
    if (id == _idBlockAdditionMapping) {
      final found = _scanBlockAdditionMapping(b, p.v, childEnd);
      if (found != null) return found;
    }
    p.v = childEnd;
  }
  return null;
}

DolbyVisionInfo? _scanBlockAdditionMapping(Uint8List b, int start, int end) {
  final p = _Cursor(start);
  int? type;
  DolbyVisionInfo? record;

  while (p.v < end) {
    final id = _readElementId(b, p);
    if (id == null) return null;
    final size = _readElementSize(b, p);
    if (size == null || size < 0) return null;
    final childEnd = math.min(end, p.v + size);

    if (id == _idBlockAddIdType) {
      type = _readUint(b, p.v, childEnd);
    } else if (id == _idBlockAddIdExtraData) {
      record = DolbyVisionInfo.parseRecord(
        Uint8List.sublistView(b, p.v, childEnd),
      );
    }
    p.v = childEnd;
  }

  // 两个子元素**顺序不保证**，所以必须等整块扫完再判定。
  // 只有 dvcC / dvvC 这两种类型的 ExtraData 才是 DOVI 记录；
  // 别的类型（如 `dvcC` 之外的私有扩展）其字节含义不同，拿去解析会得到垃圾。
  if (type != blockAddIdTypeDvcC && type != blockAddIdTypeDvvC) return null;
  return record;
}

// ---------------------------------------------------------------------------
// ISO BMFF（MP4 / MOV）
// ---------------------------------------------------------------------------

/// 需要向下递归的容器盒。
///
/// `stsd` 不在表里 —— 它多一层「版本+标志(4) + 条目数(4)」的头，得特殊处理。
const Set<String> _containerBoxes = {
  'moov',
  'trak',
  'mdia',
  'minf',
  'stbl',
  'edts',
  'udta',
  'mvex',
  'tref',
};

/// 在 ISO BMFF 头部字节里找 `dvcC` / `dvvC` 盒。
///
/// ⚠️ **`moov` 后置的文件头部探不到**（不少录制/转封装工具会这么写）。
/// 这时本函数返回 `null`，而 `null` 的含义与「不是 DV」无法区分 ——
/// 调用方若需要 100% 覆盖，得再取一段**文件尾部**字节重试一次。
DolbyVisionInfo? findDolbyVisionInIsoBmff(Uint8List bytes) =>
    _scanIsoBmff(bytes, 0, bytes.length, skip: 0);

DolbyVisionInfo? _scanIsoBmff(
  Uint8List b,
  int start,
  int end, {
  required int skip,
}) {
  var v = start + skip;
  while (v + 8 <= end) {
    var size = _readUint32(b, v);
    final type = _fourCcAt(b, v + 4);
    if (type == null) return null;

    var header = 8;
    if (size == 1) {
      // 64 位长度：`largesize` 紧跟盒名。
      if (v + 16 > end) return null;
      size = _readUint64(b, v + 8);
      header = 16;
    } else if (size == 0) {
      // 0 = 一直到文件末尾。
      size = end - v;
    }
    if (size < header) return null;

    final body = v + header;
    final boxEnd = math.min(end, v + size);

    if (type == 'dvcC' || type == 'dvvC') {
      final info = DolbyVisionInfo.parseRecord(
        Uint8List.sublistView(b, body, boxEnd),
      );
      if (info != null) return info;
    }

    if (type == 'stsd') {
      // `stsd` 体内先有 4 字节版本/标志、再 4 字节条目数，然后才是样本条目盒。
      if (body + 8 <= boxEnd) {
        final found = _scanIsoBmff(b, body, boxEnd, skip: 8);
        if (found != null) return found;
      }
    } else if (_containerBoxes.contains(type)) {
      final found = _scanIsoBmff(b, body, boxEnd, skip: 0);
      if (found != null) return found;
    }

    v += size;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 字节读取原语
// ---------------------------------------------------------------------------

/// 一个可推进的读取位置。
///
/// 做成对象而不是「到处传 `int` 再返回新值」，是因为 EBML 的解析要连续读
/// 「ID → 长度 → 体」，用返回值传递位置很容易漏掉某一处赋值，
/// 而漏掉的症状是**读到上一个元素的字节**、静默解析出错误结果。
class _Cursor {
  _Cursor(this.v);

  int v;
}

/// 读 EBML 元素 ID（1~4 字节，长度由首字节的前导零个数决定）。
int? _readElementId(Uint8List b, _Cursor p) {
  if (p.v >= b.length) return null;
  final first = b[p.v];
  if (first == 0) return null;

  var len = 1;
  if (first < 0x80) len = 2;
  if (first < 0x40) len = 3;
  if (first < 0x20) len = 4;
  // Matroska 里不存在 5 字节以上的 ID；出现说明已经读歪了。
  if (first < 0x10) return null;
  if (p.v + len > b.length) return null;

  var id = 0;
  for (var i = 0; i < len; i++) {
    id = (id << 8) | b[p.v + i];
  }
  p.v += len;
  return id;
}

/// 读 EBML 长度（VINT）。
///
/// 返回 `-1` 表示**未知长度**（全 1 位），这是合法状态而不是错误：
/// `Segment` 与 `Cluster` 都可能是流式写入的未知长度。
int? _readElementSize(Uint8List b, _Cursor p) {
  if (p.v >= b.length) return null;
  final first = b[p.v];
  if (first == 0) return null;

  var len = 8;
  for (var i = 0; i < 8; i++) {
    if ((first & (0x80 >> i)) != 0) {
      len = i + 1;
      break;
    }
  }
  if (p.v + len > b.length) return null;

  var value = first & (0xFF >> len);
  for (var i = 1; i < len; i++) {
    value = (value << 8) | b[p.v + i];
  }
  p.v += len;

  final allOnes = (1 << (7 * len)) - 1;
  return value == allOnes ? -1 : value;
}

/// 读一个无符号整数（1~8 字节，大端）。
int _readUint(Uint8List b, int start, int end) {
  var value = 0;
  for (var i = start; i < end && i < b.length; i++) {
    value = (value << 8) | b[i];
  }
  return value;
}

int _readUint32(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

int _readUint64(Uint8List b, int at) {
  var value = 0;
  for (var i = 0; i < 8; i++) {
    value = (value << 8) | b[at + i];
  }
  return value;
}

String? _fourCcAt(Uint8List b, int at) {
  if (at + 4 > b.length) return null;
  final sb = StringBuffer();
  for (var i = 0; i < 4; i++) {
    final c = b[at + i];
    // 盒名是 ASCII 可打印字符；非可打印一律判为「不是盒名」，
    // 避免把二进制数据当盒名去匹配。
    if (c < 0x20 || c > 0x7E) return null;
    sb.writeCharCode(c);
  }
  return sb.toString();
}
