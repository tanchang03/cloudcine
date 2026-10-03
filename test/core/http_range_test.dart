import 'package:cloudcine/core/utils/http_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRangeHeader', () {
    test('没有 Range 头时返回 null —— 按整个文件响应，不猜起点', () {
      expect(parseRangeHeader(null, 1000), isNull);
      expect(parseRangeHeader('', 1000), isNull);
    });

    test('bytes=N- 补到文件末尾', () {
      final r = parseRangeHeader('bytes=0-', 1000)!;
      expect(r.start, 0);
      expect(r.end, 999);
      expect(r.length, 1000);
    });

    test('bytes=a-b 是闭区间，长度要含两端', () {
      final r = parseRangeHeader('bytes=0-99', 1000)!;
      expect(r.length, 100);
    });

    test('bytes=-N 表示最后 N 字节', () {
      final r = parseRangeHeader('bytes=-500', 1000)!;
      expect(r.start, 500);
      expect(r.end, 999);
    });

    test('尾部区间比文件还长时从头开始，不越界', () {
      final r = parseRangeHeader('bytes=-5000', 1000)!;
      expect(r.start, 0);
      expect(r.end, 999);
    });

    test('长度未知时 bytes=0- 无从换算终点，返回 null', () {
      // 这是 mpv 探测文件头的常见形态：它自己也不知道文件多大。
      // 返回 null 让调用方按全文件流式响应，而不是编一个假的终点。
      expect(parseRangeHeader('bytes=0-', 0), isNull);
      expect(parseRangeHeader('bytes=0-', -1), isNull);
    });

    test('起点超过文件长度返回 null —— 交给 416', () {
      expect(parseRangeHeader('bytes=2000-', 1000), isNull);
    });

    test('终点超过文件长度时被截断而不是原样返回', () {
      final r = parseRangeHeader('bytes=900-5000', 1000)!;
      expect(r.start, 900);
      expect(r.end, 999);
    });

    test('多段只取第一段', () {
      // mpv 不会发多段，但语法合法。支持它意味着响应要换成
      // multipart/byteranges —— 为一个用不到的分支引入整套编码不值得。
      final r = parseRangeHeader('bytes=0-99,200-299', 1000)!;
      expect(r.start, 0);
      expect(r.end, 99);
    });

    test('不是 bytes 单位 / 语法坏了时返回 null', () {
      expect(parseRangeHeader('items=0-9', 1000), isNull);
      expect(parseRangeHeader('bytes=abc-def', 1000), isNull);
      expect(parseRangeHeader('bytes=100', 1000), isNull);
    });

    test('终点小于起点时返回 null', () {
      expect(parseRangeHeader('bytes=500-100', 1000), isNull);
    });
  });

  group('clampRange', () {
    test('超出末尾的部分丢掉，而不是报 416', () {
      // mpv 收到 416 会**放弃 seek**，而它真正想要的只是「尽量多给一点」。
      final r = clampRange(const ByteRange(900, 5000), 1000)!;
      expect(r.start, 900);
      expect(r.end, 999);
    });

    test('完全越界时返回 null', () {
      expect(clampRange(const ByteRange(1500, 2000), 1000), isNull);
    });

    test('长度未知时原样返回', () {
      final r = clampRange(const ByteRange(0, 99), 0)!;
      expect(r.end, 99);
    });
  });

  group('formatContentRange', () {
    test('格式是 bytes start-end/total', () {
      expect(
        formatContentRange(const ByteRange(0, 999), 1000),
        'bytes 0-999/1000',
      );
    });
  });
}
