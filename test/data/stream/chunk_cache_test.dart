import 'dart:typed_data';

import 'package:cloudcine/data/stream/chunk_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List block(int n) => Uint8List(n);

  group('ChunkCache', () {
    test('没放过的块取不到', () {
      final cache = ChunkCache(maxBytes: 100);
      expect(cache.get(0), isNull);
      expect(cache.contains(0), isFalse);
    });

    test('放进去能取到，字节数跟着走', () {
      final cache = ChunkCache(maxBytes: 100);
      cache.put(0, block(40));
      expect(cache.contains(0), isTrue);
      expect(cache.get(0), isNotNull);
      expect(cache.bytes, 40);
      expect(cache.count, 1);
    });

    test('替换同序号的块不会把字节数算两遍', () {
      final cache = ChunkCache(maxBytes: 100);
      cache.put(0, block(40));
      cache.put(0, block(40));
      expect(cache.bytes, 40);
      expect(cache.count, 1);
    });

    test('超过上限时淘汰**最久未访问**的块', () {
      final cache = ChunkCache(maxBytes: 100);
      cache.put(0, block(40));
      cache.put(1, block(40));
      // 碰一下 0，让它变成「较新」的那一块。
      cache.get(0);
      cache.put(2, block(40));

      // 于是被淘汰的必须是 1，而不是 0 —— 这正是 LRU 相对「滑动窗口」的
      // 价值：mpv 反复读写的文件头/文件尾不会被过早丢掉。
      expect(cache.contains(1), isFalse);
      expect(cache.contains(0), isTrue);
      expect(cache.contains(2), isTrue);
      expect(cache.bytes, lessThanOrEqualTo(100));
    });

    test('淘汰到不再超限为止，不是只淘汰一块', () {
      final cache = ChunkCache(maxBytes: 50);
      cache.put(0, block(40));
      cache.put(1, block(40));
      cache.put(2, block(40));
      expect(cache.bytes, lessThanOrEqualTo(50));
    });

    test('单块就超过上限时也要收住（不会死循环，也不会真的删空）', () {
      final cache = ChunkCache(maxBytes: 10);
      cache.put(0, block(40));
      expect(cache.bytes, 40);
      expect(cache.count, 1);
    });

    test('clear 清空计数', () {
      final cache = ChunkCache(maxBytes: 100);
      cache.put(0, block(40));
      cache.clear();
      expect(cache.bytes, 0);
      expect(cache.count, 0);
    });
  });
}
