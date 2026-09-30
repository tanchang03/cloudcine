import 'dart:async';

/// 令牌桶限流器。
///
/// 网盘接口的风控是真实约束（夸克实测约 3 QPS 未触发风控，但这是**未公开**的
/// 阈值，必须保守）。所有对网盘的调用都要先 [acquire]。
///
/// 设计要点：
///   - **时钟与等待可注入**，因此单元测试不需要真的 `sleep`，
///     可以用虚拟时钟精确验证「第 N 次请求应等待多少毫秒」；
///   - 桶容量 [burst] 允许短时突发，避免逐条扫描时每次都硬等；
///   - 等待时间有上限保护，避免参数配错导致线程被挂死。
class TokenBucket {
  TokenBucket({
    required this.ratePerSecond,
    this.burst = 1,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    this.maxWait = const Duration(seconds: 60),
  })  : assert(ratePerSecond > 0, 'ratePerSecond 必须为正数'),
        assert(burst >= 1, 'burst 至少为 1'),
        _clock = clock ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  /// 每秒允许的请求数
  final double ratePerSecond;

  /// 桶容量（允许的突发请求数）
  final int burst;

  /// 单次等待上限。超过则直接放行并记一次「超限放行」，
  /// 避免因配置错误把调用方永久阻塞。
  final Duration maxWait;

  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  double _tokens = 0;
  DateTime? _lastRefill;

  /// 因超过 [maxWait] 而被强行放行的次数（可观测指标）
  int get forcedThrough => _forcedThrough;
  int _forcedThrough = 0;

  /// 当前可用令牌数（测试与诊断用）
  double get availableTokens {
    _refill();
    return _tokens;
  }

  /// 相邻两次请求的理论最小间隔
  Duration get minInterval =>
      Duration(microseconds: (1000000 / ratePerSecond).round());

  void _refill() {
    final now = _clock();
    final last = _lastRefill;
    if (last == null) {
      _tokens = burst.toDouble();
      _lastRefill = now;
      return;
    }
    final elapsedUs = now.difference(last).inMicroseconds;
    if (elapsedUs <= 0) return;
    final added = elapsedUs / 1000000.0 * ratePerSecond;
    _tokens = (_tokens + added).clamp(0.0, burst.toDouble());
    _lastRefill = now;
  }

  /// 取用令牌。不足时按速率等待。
  Future<void> acquire({int tokens = 1}) async {
    assert(tokens >= 1, 'tokens 至少为 1');
    if (tokens > burst) {
      throw ArgumentError.value(
        tokens,
        'tokens',
        '单次取用不能超过桶容量 $burst',
      );
    }

    _refill();
    if (_tokens >= tokens) {
      _tokens -= tokens;
      return;
    }

    final needed = tokens - _tokens;
    var wait = Duration(microseconds: (needed / ratePerSecond * 1000000).round());
    if (wait > maxWait) {
      wait = maxWait;
      _forcedThrough++;
    }

    await _delay(wait);
    _refill();
    _tokens = (_tokens - tokens).clamp(0.0, burst.toDouble());
  }

  /// 包住一次调用：先取令牌，再执行。
  Future<T> run<T>(Future<T> Function() task, {int tokens = 1}) async {
    await acquire(tokens: tokens);
    return task();
  }

  @override
  String toString() =>
      'TokenBucket(${ratePerSecond.toStringAsFixed(2)}/s, burst=$burst)';
}

/// 按「最小请求间隔」构造限流器。
///
/// [ScanPolicy.minRequestInterval] 用的是间隔语义，这里做一次换算，
/// 让调用方不必关心速率与间隔的区别。
TokenBucket bucketFromInterval(
  Duration interval, {
  int burst = 1,
  DateTime Function()? clock,
  Future<void> Function(Duration)? delay,
}) {
  final us = interval.inMicroseconds;
  final rate = us <= 0 ? 1000.0 : 1000000.0 / us;
  return TokenBucket(
    ratePerSecond: rate,
    burst: burst,
    clock: clock,
    delay: delay,
  );
}
