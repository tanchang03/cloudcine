import 'package:cloudcine/core/utils/mpv_cache_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// mpv `demuxer-cache-state` 的解析。
///
/// 这个函数跑在播放路径上、拿不到真播放器来测（`flutter test` 里 `Player()`
/// 构造不出来），所以它**唯一的防线就是这些用例**。断言写的都是
/// 「坏输入必须变成 null 而不是 0 或异常」—— 返回 0 会被显示成「网速 0」，
/// 抛异常会把播放路径搞挂，两者都比「不知道」糟。
void main() {
  /// 一份贴近真实的 mpv 输出（字段名取自随包的 libmpv 0.36.0 二进制）。
  const realSample = '{"seekable-ranges":[{"start":0.0,"end":3600.0}],'
      '"bof-cached":true,"eof-cached":false,"fw-bytes":1048576,'
      '"raw-input-rate":2359296.0,"total-bytes":734003200,"underrun":false}';

  test('从真实响应里取出输入速率（字节/秒）', () {
    expect(rawInputBytesPerSecond(realSample), 2359296.0);
  });

  test('字段缺失时返回 null（而不是 0）', () {
    const noRate = '{"fw-bytes":1048576,"bof-cached":true}';
    expect(rawInputBytesPerSecond(noRate), isNull);
  });

  test('空串返回 null', () {
    expect(rawInputBytesPerSecond(''), isNull);
  });

  test('不是 JSON 时返回 null 而不是抛异常', () {
    // mpv 在某些版本/属性上给的不是严格 JSON；这个函数跑在播放路径上，
    // 抛出去就是一次未捕获异常。
    expect(rawInputBytesPerSecond('not json at all'), isNull);
    expect(rawInputBytesPerSecond('<node>'), isNull);
  });

  test('不是严格 JSON 但含该键时，退回文本扫描取值', () {
    // mpv 的头文件只承诺「走一个字符串格式化器」，没承诺是 JSON
    // （`client.h` 全文没有 "JSON" 二字）。所以解析不能只认一种格式 ——
    // 格式假设错了会让整条优化静默失效，而那是查不出来的。
    expect(
      rawInputBytesPerSecond('{raw-input-rate:1048576.0,bof-cached:true}'),
      1048576.0,
    );
    expect(
      rawInputBytesPerSecond(
        'demuxer-cache-state: { "fw-bytes": 123, "raw-input-rate": 524288 }',
      ),
      524288.0,
    );
  });

  test('文本扫描也不误伤：键在但值不是数字 → null', () {
    expect(rawInputBytesPerSecond('{raw-input-rate:abc}'), isNull);
  });

  test('JSON 不是对象时返回 null', () {
    expect(rawInputBytesPerSecond('[1,2,3]'), isNull);
    expect(rawInputBytesPerSecond('42'), isNull);
  });

  test('字符串形式的数字也能读（mpv 的字符串化不保证类型）', () {
    const asString = '{"raw-input-rate":"1048576.0"}';
    expect(rawInputBytesPerSecond(asString), 1048576.0);
  });

  test('零与负数返回 null —— 那是「没在下载」，不是「网速 0」', () {
    expect(rawInputBytesPerSecond('{"raw-input-rate":0.0}'), isNull);
    expect(rawInputBytesPerSecond('{"raw-input-rate":-1.0}'), isNull);
  });

  test('类型不对时返回 null', () {
    expect(rawInputBytesPerSecond('{"raw-input-rate":null}'), isNull);
    expect(rawInputBytesPerSecond('{"raw-input-rate":{"a":1}}'), isNull);
    expect(rawInputBytesPerSecond('{"raw-input-rate":"abc"}'), isNull);
  });
}
