import 'package:cloudcine/core/utils/http_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseRangeRequest', () {
    /// 可满足时取出区间，其余一律 null —— 让断言读起来和以前一样。
    ByteRange? rangeOf(RangeRequest spec) =>
        spec is SatisfiableRange ? spec.range : null;

    test('没有 Range 头时是 NoRangeRequest —— 按整个文件响应，不猜起点', () {
      expect(parseRangeRequest(null, 1000), isA<NoRangeRequest>());
      expect(parseRangeRequest('', 1000), isA<NoRangeRequest>());
    });

    test('bytes=N- 补到文件末尾', () {
      final r = rangeOf(parseRangeRequest('bytes=0-', 1000))!;
      expect(r.start, 0);
      expect(r.end, 999);
      expect(r.length, 1000);
    });

    test('bytes=a-b 是闭区间，长度要含两端', () {
      final r = rangeOf(parseRangeRequest('bytes=0-99', 1000))!;
      expect(r.length, 100);
    });

    test('bytes=-N 表示最后 N 字节', () {
      final r = rangeOf(parseRangeRequest('bytes=-500', 1000))!;
      expect(r.start, 500);
      expect(r.end, 999);
    });

    test('尾部区间比文件还长时从头开始，不越界', () {
      final r = rangeOf(parseRangeRequest('bytes=-5000', 1000))!;
      expect(r.start, 0);
      expect(r.end, 999);
    });

    test('长度未知时 bytes=0- 无从换算终点 —— NoRangeRequest，**不是** 416', () {
      // 这是 mpv 探测文件头的常见形态：它自己也不知道文件多大。
      // 按全文件流式响应，而不是编一个假的终点。
      //
      // ⚠️ 必须与「起点越界」区分开：「不知道文件多大」不是「要不到」——
      //    前者回 200 整文件，后者必须 416。混在一起正是那个卡死首帧的 bug。
      expect(parseRangeRequest('bytes=0-', 0), isA<NoRangeRequest>());
      expect(parseRangeRequest('bytes=0-', -1), isA<NoRangeRequest>());
    });

    test('起点超过文件长度 → UnsatisfiableRange（必须 416）', () {
      // ⛔ 以前这里断言的是 `isNull`，注释还写着「交给 416」—— 可调用方拿到
      //    null 只会当成「没要求区间」去回「200 + 整文件」。契约的两半分家，
      //    于是「问 3.13 GiB 的流要第 5.01 GB」被回成整文件从 0 开始，播放器
      //    就一直读下去等一个永远不来的偏移（实测卡死首帧 7 分钟以上）。
      expect(parseRangeRequest('bytes=2000-', 1000), isA<UnsatisfiableRange>());
      // 起点正好等于流长：最后一个合法字节是 999，所以 1000 也已经越界。
      expect(parseRangeRequest('bytes=1000-', 1000), isA<UnsatisfiableRange>());
      expect(
        parseRangeRequest('bytes=2000-5000', 1000),
        isA<UnsatisfiableRange>(),
      );
    });

    test('终点超过文件长度时被截断而不是原样返回', () {
      final r = rangeOf(parseRangeRequest('bytes=900-5000', 1000))!;
      expect(r.start, 900);
      expect(r.end, 999);
    });

    test('多段只取第一段', () {
      // mpv 不会发多段，但语法合法。支持它意味着响应要换成
      // multipart/byteranges —— 为一个用不到的分支引入整套编码不值得。
      final r = rangeOf(parseRangeRequest('bytes=0-99,200-299', 1000))!;
      expect(r.start, 0);
      expect(r.end, 99);
    });

    test('不是 bytes 单位 / 语法坏了时按「没要求区间」处理（RFC 7233 要求忽略）', () {
      expect(parseRangeRequest('items=0-9', 1000), isA<NoRangeRequest>());
      expect(parseRangeRequest('bytes=abc-def', 1000), isA<NoRangeRequest>());
      expect(parseRangeRequest('bytes=100', 1000), isA<NoRangeRequest>());
    });

    test('终点小于起点时整条头非法 → 忽略它，NoRangeRequest', () {
      expect(parseRangeRequest('bytes=500-100', 1000), isA<NoRangeRequest>());
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
