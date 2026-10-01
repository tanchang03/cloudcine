import 'package:cloudcine/domain/services/request_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

/// 列目录请求的节流。
///
/// 这段逻辑在项目里踩过两次坑（配置写了没人 await；补上之后只覆盖「同目录
/// 翻页」、漏掉「换目录」那次请求 —— 对每个目录都只有一页的媒体库等于
/// **全程不节流**）。所以这些用例盯的是「请求**起点**之间的最小间隔」这个
/// 语义本身，而不是某个调用点的写法。
///
/// ⚠️ 时钟是**注入**的（用来决定「还要等多久」），但真正的等待是真实的
/// `Future.delayed`，所以断言留了足够宽的余量，不用 `closeTo` 卡微秒。
void main() {
  test('首次请求不等待', () async {
    final throttle = RequestThrottle(
      minInterval: const Duration(milliseconds: 200),
      clock: DateTime.now,
    );

    final sw = Stopwatch()..start();
    await throttle.wait();
    sw.stop();

    expect(
      sw.elapsedMilliseconds,
      lessThan(100),
      reason: '第一次请求前面没有「上一次」，等它就是白等一个间隔',
    );
  });

  test('间隔不足时按「上次请求起点」补足差额', () async {
    var now = DateTime(2026, 1, 1);
    final throttle = RequestThrottle(
      minInterval: const Duration(milliseconds: 200),
      clock: () => now,
    );

    await throttle.wait();
    // 距离上次请求只过了 50ms，还差 150ms。
    now = now.add(const Duration(milliseconds: 50));

    final sw = Stopwatch()..start();
    await throttle.wait();
    sw.stop();

    expect(
      sw.elapsedMilliseconds,
      greaterThanOrEqualTo(120),
      reason: '不补这一下，几千个目录会以网络往返速度一路打过去，'
          '3 QPS 的安全线形同虚设',
    );
  });

  test('间隔已经够了就不再额外等待', () async {
    var now = DateTime(2026, 1, 1);
    final throttle = RequestThrottle(
      minInterval: const Duration(milliseconds: 200),
      clock: () => now,
    );

    await throttle.wait();
    // 上一次请求本身耗时 500ms，早就超过间隔了。
    now = now.add(const Duration(milliseconds: 500));

    final sw = Stopwatch()..start();
    await throttle.wait();
    sw.stop();

    expect(
      sw.elapsedMilliseconds,
      lessThan(100),
      reason: '按「起点」计时才有这个性质。按终点再固定 sleep 一次的话，'
          '实际速率会被压到远低于配置值',
    );
  });

  test('间隔为 0 表示不节流（测试与离线场景用）', () async {
    final throttle = RequestThrottle(
      minInterval: Duration.zero,
      clock: DateTime.now,
    );

    final sw = Stopwatch()..start();
    for (var i = 0; i < 5; i++) {
      await throttle.wait();
    }
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(100));
  });

  test('reset 之后下一次请求不再被上一次拖住', () async {
    final throttle = RequestThrottle(
      minInterval: const Duration(milliseconds: 300),
      clock: DateTime.now,
    );

    await throttle.wait();
    throttle.reset();

    final sw = Stopwatch()..start();
    await throttle.wait();
    sw.stop();

    expect(sw.elapsedMilliseconds, lessThan(150));
  });
}
