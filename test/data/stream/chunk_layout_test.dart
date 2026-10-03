import 'package:cloudcine/core/utils/http_range.dart';
import 'package:cloudcine/data/stream/chunk_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 100 字节一块、共 250 字节 → 3 块，最后一块只有 50 字节。
  const layout = ChunkLayout(chunkSize: 100, totalLength: 250);

  group('ChunkLayout', () {
    test('块数向上取整', () {
      expect(layout.chunkCount, 3);
    });

    test('整块文件的块数不会多算一块', () {
      expect(
        const ChunkLayout(chunkSize: 100, totalLength: 200).chunkCount,
        2,
      );
    });

    test('最后一块被文件末尾截断', () {
      expect(layout.startOf(2), 200);
      expect(layout.endOf(2), 249);
      expect(layout.lengthOf(2), 50);
    });

    test('非末尾块是满的', () {
      expect(layout.lengthOf(0), 100);
      expect(layout.endOf(0), 99);
    });

    test('偏移落块：边界必须归后一块', () {
      expect(layout.indexOf(0), 0);
      expect(layout.indexOf(99), 0);
      expect(layout.indexOf(100), 1);
      expect(layout.indexOf(249), 2);
    });

    test('区间覆盖的块是连续升序', () {
      expect(layout.indicesOf(const ByteRange(50, 150)), <int>[0, 1]);
      expect(layout.indicesOf(const ByteRange(0, 249)), <int>[0, 1, 2]);
      expect(layout.indicesOf(const ByteRange(200, 210)), <int>[2]);
    });

    test('rangeOf 是闭区间且不超过文件末尾', () {
      final last = layout.rangeOf(2);
      expect(last.start, 200);
      expect(last.end, 249);
    });

    test('isValidIndex 挡住越界', () {
      expect(layout.isValidIndex(0), isTrue);
      expect(layout.isValidIndex(2), isTrue);
      expect(layout.isValidIndex(3), isFalse);
      expect(layout.isValidIndex(-1), isFalse);
    });
  });
}
