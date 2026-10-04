import 'dart:typed_data';

import 'package:cloudcine/core/utils/dolby_vision.dart';
import 'package:flutter_test/flutter_test.dart';

/// 杜比视界探测 —— 这是「哪些片源要换内核」的唯一判据。
///
/// 为什么值得测：**探错的代价是不对称的**。
/// - 漏判（DV 片被当成普通片）：颜色不对，但用户看得见，会来报；
/// - 误判（普通片被当成 DV）：把它拽去走一条只为 DV 验证过的内核，
///   等于让绝大多数片源替少数片源承担回归风险，而且**没有报错**。
///
/// 所以断言里既要有「认得出」，也要有「不乱认」。
void main() {
  // 本项目那条 4K DV 片源头部里实测的 24 字节 DOVI 记录（`dvcC @ 439`）。
  // 用它当黄金样本：mdk 自己打印的是 `Profile 5 Level 9`，两者必须对得上。
  const realP5Record = <int>[1, 0, 0x0a, 0x4d, 0x00];

  group('DOVI 记录解析', () {
    test('实测 P5 样本 → profile 5 / level 9 / compat 0', () {
      final info = DolbyVisionInfo.parseRecord(_pad(realP5Record))!;

      expect(info.profile, 5);
      expect(info.level, 9, reason: 'mdk 日志里同一条流报的就是 Level 9');
      expect(info.blSignalCompatibilityId, 0);
      expect(info.rpuPresent, isTrue, reason: 'P5 必有 RPU，没有它无法还原颜色');
      expect(info.elPresent, isFalse, reason: 'P5 是单层，没有增强层');
      expect(info.blPresent, isTrue);
    });

    test('P5 + compat 0 才要求换内核', () {
      final p5 = DolbyVisionInfo.parseRecord(_pad(realP5Record))!;

      expect(
        p5.needsDolbyVisionEngine,
        isTrue,
        reason: '没有 HDR10 兼容层 → 退化成 HDR10/SDR 播都偏色，'
            '任何 tone-mapping 参数都救不回来，只能换内核',
      );
    });

    test('带兼容层的 P8 不换内核', () {
      // profile 8、level 6、compat 1（HDR10 兼容）。
      final p8 = DolbyVisionInfo.parseRecord(_pad(<int>[1, 0, 0x10, 0x35, 0x10]))!;

      expect(p8.profile, 8);
      expect(p8.level, 6);
      expect(p8.blSignalCompatibilityId, 1);
      expect(
        p8.needsDolbyVisionEngine,
        isFalse,
        reason: '有 HDR10 兼容层 → 现有内核退化成 HDR10 播只是「不够好」，'
            '不该为它承担换内核的回归风险',
      );
    });

    test('level 是 6 位，但合法上限只有 13', () {
      // level 的编码跨 byte2 最低位与 byte3 高 5 位。合法等级最高 13，
      // 也就是说**高位永远是 0** —— 一旦 byte2 的最低位被置上，
      // 拼出来的 level 必然 >= 32，应当被值域闸拦掉。
      //
      // 这条断言锁的是「别把 byte2 的最低位算进 profile」：
      // 若实现写成 `profile = byte2`，0x11 会得到 17（>9）而被拒，
      // 与正确实现的拒绝理由不同但结果相同 —— 所以额外断言 profile 的取法。
      expect(
        DolbyVisionInfo.parseRecord(_pad(<int>[1, 0, 0x11, 0x68, 0x00])),
        isNull,
        reason: 'byte2 最低位属于 level → level=45 越界',
      );

      // 正确的 level=13 编码：高位 0 在 byte2，低 5 位在 byte3。
      final info =
          DolbyVisionInfo.parseRecord(_pad(<int>[1, 0, 0x10, 13 << 3, 0x00]))!;
      expect(info.profile, 8);
      expect(info.level, 13);
    });

    test('主版本号不是 1 的一律拒绝', () {
      // 随机数据里 byte0 落在 0~255 是均匀的，靠版本号挡掉 254/255 的噪声。
      expect(DolbyVisionInfo.parseRecord(_pad(<int>[0, 0, 0x0a, 0x4d, 0x00])),
          isNull);
      expect(DolbyVisionInfo.parseRecord(_pad(<int>[2, 0, 0x0a, 0x4d, 0x00])),
          isNull);
    });

    test('档位超出 0~9 的一律拒绝', () {
      // 0xFF >> 1 = 127，远超真实档位 —— 这类值只可能来自误命中的随机数据。
      expect(DolbyVisionInfo.parseRecord(_pad(<int>[1, 0, 0xff, 0x4d, 0x00])),
          isNull);
    });

    test('字节不够时返回 null 而不是越界', () {
      expect(DolbyVisionInfo.parseRecord(Uint8List.fromList(<int>[1, 0, 0x0a])),
          isNull);
      expect(DolbyVisionInfo.parseRecord(Uint8List(0)), isNull);
    });
  });

  group('容器识别', () {
    test('EBML 魔数', () {
      expect(looksLikeMatroska(Uint8List.fromList(<int>[0x1a, 0x45, 0xdf, 0xa3])),
          isTrue);
      expect(looksLikeIsoBmff(Uint8List.fromList(<int>[0x1a, 0x45, 0xdf, 0xa3])),
          isFalse);
    });

    test('MP4 认 ftyp，也认不以 ftyp 起头的变体', () {
      expect(looksLikeIsoBmff(Uint8List.fromList(_box('ftyp', <int>[0, 0, 0, 0]))),
          isTrue);
      expect(looksLikeIsoBmff(Uint8List.fromList(_box('moov', <int>[]))), isTrue,
          reason: '有的实现直接以 moov 起头');
      expect(looksLikeIsoBmff(Uint8List.fromList(_box('mdat', <int>[1, 2, 3]))),
          isTrue);
      expect(looksLikeIsoBmff(Uint8List.fromList(_box('junk', <int>[1, 2, 3]))),
          isFalse);
    });

    test('两种容器都不是时 detect 返回 null', () {
      expect(detectDolbyVision(Uint8List.fromList(List<int>.filled(64, 0xAB))),
          isNull);
    });
  });

  group('Matroska 路径', () {
    test('沿 Segment → Tracks → TrackEntry → BlockAdditionMapping 找到 DV', () {
      final bytes = _matroska(blockAddIdType: blockAddIdTypeDvcC);

      final info = detectDolbyVision(bytes);

      expect(info, isNotNull);
      expect(info!.profile, 5);
      expect(info.blSignalCompatibilityId, 0);
    });

    test('dvvC 也算 —— 两个注册类型都要认', () {
      final bytes = _matroska(blockAddIdType: blockAddIdTypeDvvC);

      expect(detectDolbyVision(bytes), isNotNull);
    });

    test('BlockAddIDType 是别的值时不当 DV', () {
      // 只有 dvcC / dvvC 的 ExtraData 才是 DOVI 记录；其它类型的字节含义不同，
      // 拿去解析会「探出」一个不存在的档位。
      final bytes = _matroska(blockAddIdType: 0x11223344);

      expect(detectDolbyVision(bytes), isNull);
    });

    test('没有 BlockAdditionMapping 的普通 MKV → null', () {
      final bytes = Uint8List.fromList(_ebml(0x1a45dfa3, <int>[]) +
          _ebml(0x18538067, _ebml(0x1654ae6b, _ebml(0xae, _ebml(0xae, <int>[])))));

      expect(detectDolbyVision(bytes), isNull);
    });

    test('头部被截断在 Tracks 之前 → null 且不抛', () {
      final full = _matroska(blockAddIdType: blockAddIdTypeDvcC);
      // 只给到 Segment 头之后一点点，TrackEntry 还没出现。
      final cut = Uint8List.fromList(full.sublist(0, 20));

      expect(() => detectDolbyVision(cut), returnsNormally);
      expect(detectDolbyVision(cut), isNull,
          reason: '截断与「不是 DV」无法区分，调用方必须能安全地按非 DV 处理');
    });

    test('Segment 声明未知长度（流式写入）也能找', () {
      final bytes = _matroska(blockAddIdType: blockAddIdTypeDvcC, unknownSegmentSize: true);

      expect(detectDolbyVision(bytes), isNotNull);
    });
  });

  group('ISO BMFF 路径', () {
    test('沿 moov → trak → stbl → stsd → dvcC 找到 DV', () {
      final bytes = _mp4();

      final info = detectDolbyVision(bytes);

      expect(info, isNotNull);
      expect(info!.profile, 5);
    });

    test('stsd 多一层「版本+条目数」头，别从盒体直接当子盒读', () {
      // 这个用例专门锁 stsd 的那 8 字节：少了它，第一个「子盒」的 size
      // 会被读成 0，整个 moov 的解析就此停住，表现是**静默探不到 DV**。
      final bytes = _mp4();

      expect(detectDolbyVision(bytes), isNotNull);
    });

    test('盒名像 dvcC 但内容不是 DOVI 记录 → null', () {
      final bytes = _box(
        'ftyp',
        <int>[0, 0, 0, 0],
      ) + _box('moov', _box('trak', _box('stbl', _box('stsd',
          <int>[0, 0, 0, 0, 0, 0, 0, 1] + _box('dvcC', List<int>.filled(24, 0xFF))))));

      expect(detectDolbyVision(Uint8List.fromList(bytes)), isNull,
          reason: '盒名只有 4 字节，误命中的代价是拿随机数据当配置解析');
    });

    test('64 位 largesize 盒也能跳过', () {
      // size==1 时真实长度在盒名之后的 8 字节里。读错的话会按 1 字节跳过，
      // 后续所有盒的偏移全错 —— 表现同样是静默探不到。
      final inner = _box('stsd',
          <int>[0, 0, 0, 0, 0, 0, 0, 1] + _box('dvcC', _pad(realP5Record)));
      final largeBox = _boxLarge('trak', inner);
      final bytes = _box('ftyp', <int>[0, 0, 0, 0]) + _box('moov', largeBox);

      expect(detectDolbyVision(Uint8List.fromList(bytes)), isNotNull);
    });
  });
}

/// 把 5 字节样本补到完整的 24 字节记录长度。
Uint8List _pad(List<int> head) =>
    Uint8List.fromList(head + List<int>.filled(24 - head.length, 0));

/// EBML 长度（VINT）。只实现到 2 字节 —— 测试里的元素都很小。
///
/// ⚠️ 1 字节形式**必须带上长度标记位**：长度 0 是 `0x80` 而不是 `0x00`。
/// 写成 `0x00` 会得到一个「没有任何标记位」的字节，真实解析器只能当成
/// 坏数据 —— 而症状是**整个 Segment 解析不出来**，看起来像解析器有 bug。
List<int> _vint(int n) {
  if (n < 0x7f) return <int>[0x80 | n];
  return <int>[0x40 | (n >> 8), n & 0xff];
}

/// 组装一个 EBML 元素（ID 用最少字节大端）。
List<int> _ebml(int id, List<int> body) {
  final idBytes = <int>[];
  var v = id;
  while (v > 0) {
    idBytes.insert(0, v & 0xff);
    v >>= 8;
  }
  return <int>[...idBytes, ..._vint(body.length), ...body];
}

/// 组装一条最小但结构完整的 Matroska：Segment → Tracks → TrackEntry →
/// BlockAdditionMapping → (BlockAddIDType, BlockAddIDExtraData)。
Uint8List _matroska({
  required int blockAddIdType,
  bool unknownSegmentSize = false,
}) {
  final typeBytes = <int>[
    (blockAddIdType >> 24) & 0xff,
    (blockAddIdType >> 16) & 0xff,
    (blockAddIdType >> 8) & 0xff,
    blockAddIdType & 0xff,
  ];

  final mapping = _ebml(0x41e4, <int>[
    ..._ebml(0x41e7, typeBytes),
    ..._ebml(0x41ed, _pad(<int>[1, 0, 0x0a, 0x4d, 0x00])),
  ]);

  final trackEntry = _ebml(0xae, mapping);
  final tracks = _ebml(0x1654ae6b, trackEntry);
  final segmentBody = tracks;

  final header = _ebml(0x1a45dfa3, <int>[]);
  final segment = unknownSegmentSize
      ? <int>[0x18, 0x53, 0x80, 0x67, 0xff, ...segmentBody]
      : _ebml(0x18538067, segmentBody);

  return Uint8List.fromList(<int>[...header, ...segment]);
}

/// 组装一个 ISO BMFF 盒：size(4) + type(4) + body。
List<int> _box(String type, List<int> body) {
  final size = 8 + body.length;
  return <int>[
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...body,
  ];
}

/// 组装一个 64 位 largesize 盒：size=1 + type(4) + largesize(8) + body。
List<int> _boxLarge(String type, List<int> body) {
  final size = 16 + body.length;
  return <int>[
    0, 0, 0, 1,
    ...type.codeUnits,
    ...List<int>.generate(8, (i) => (size >> (8 * (7 - i))) & 0xff),
    ...body,
  ];
}

/// 一条带 dvcC 的最小 MP4。
Uint8List _mp4() {
  final stsd = _box(
    'stsd',
    <int>[0, 0, 0, 0, 0, 0, 0, 1] + _box('dvcC', _pad(<int>[1, 0, 0x0a, 0x4d, 0x00])),
  );
  final stbl = _box('stbl', stsd);
  final minf = _box('minf', stbl);
  final mdia = _box('mdia', minf);
  final trak = _box('trak', mdia);
  final moov = _box('moov', trak);
  return Uint8List.fromList(_box('ftyp', <int>[0, 0, 0, 0]) + moov);
}
