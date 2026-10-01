/// 列目录请求的最小间隔节流器。
///
/// ## 为什么单独一个类
///
/// 全盘扫描与局部发现都要列目录，都要守网盘那条约 3 QPS 的安全线。
/// 这段逻辑在 `ScanService` 里踩过两次坑（见下），把它留在两处各写一份，
/// 就是让第二个入口有机会重犯一次同样的错。
///
/// ## 语义是「请求**起点**之间的最小间隔」
///
/// ⚠️ 必须在**每次请求之前**调用，并按「上次发起时刻」算剩余等待时间。
/// 早先参考项目的实现是在页尾固定 sleep 一次，但内层循环在
/// `pageToken == null` 时先 `break` 了 —— 于是「换目录」的那一次请求
/// 完全没被节流。对「每个目录都只有一页」的媒体库（很常见）等于
/// **全程不节流**：几千个目录会以网络往返速度一路打过去，3 QPS
/// 安全线形同虚设。
///
/// 按请求**起点**而不是终点计时，才是「最小间隔」的正确语义：
/// 请求本身耗时超过这个间隔时不该再额外等待，否则实际速率会被压到
/// 远低于配置值。
class RequestThrottle {
  RequestThrottle({
    required this.minInterval,
    required DateTime Function() clock,
  }) : _clock = clock;

  /// 相邻两次请求的最小间隔。`Duration.zero` 表示不节流（测试用）。
  final Duration minInterval;

  final DateTime Function() _clock;

  /// 上一次请求的**发起时刻**。`null` 表示还没发过（首次请求不等待）。
  DateTime? _lastAt;

  /// 在发起一次列目录请求之前 `await` 它。
  Future<void> wait() async {
    if (minInterval <= Duration.zero) return;
    final last = _lastAt;
    if (last != null) {
      final remaining = minInterval - _clock().difference(last);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }
    _lastAt = _clock();
  }

  /// 重置计时。用于「换了一次独立操作」时不想被上一次的尾巴拖住。
  void reset() => _lastAt = null;
}
