/// 由 mpv 的 `demuxer-cache-time`（已缓存到播放头前面多少**秒**）估算缓存速度。
///
/// ## 为什么要有它
///
/// 缓冲指示要给两个数：**进度**和**速率**。进度 mpv 直接给了
/// （`cache-buffering-state`，0~100；以及 `demuxer-cache-time` 这个秒数）。
/// 速率没有 —— media_kit 不暴露字节计数，只暴露「缓存了多少秒」。
/// 于是速率只能自己算：对 `demuxer-cache-time` 求时间导数。
///
/// 得到的单位是「每秒能缓存多少秒视频」（下称倍速）。它本身就是有意义的信息
/// —— `1.0×` 是下载与播放刚好持平的分界线，小于它就迟早会再卡一次。
/// 想要 KB/s 还得再乘一次平均码率，那是 UI 层的事（见
/// `PlayerWindowApp` 里的 `_cacheBytesPerSecond`）。
///
/// ## 为什么用滑动窗口而不是「上一个样本」
///
/// `demuxer-cache-time` 是**阶梯状**的：一个切片下完才跳一次，中间几帧不动。
/// 拿相邻两个样本算，会得到一串 0 和一串巨大的尖峰，数字抖得没法看。
/// 窗口里取首尾两点做差，等于对整段做了平均。
///
/// 窗口取 **8 秒**是有实测依据的，不是随手选的：HLS 的缓存量是**阶梯状**的
/// —— 一个切片下完才跳一次（夸克的 `media.m3u8` 切片约 5~10 秒），窗口窄于
/// 一个切片就平均不掉它，算出来的数会在 0 和一个尖峰之间来回跳，印在界面上
/// 就是「网速在抖」的假象。窗口再长则相反：缓冲早就结束了，它还一直报着
/// 上一段的速度。
class CacheSpeedMeter {
  CacheSpeedMeter({
    this.window = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 参与平均的时间跨度。
  final Duration window;

  /// 注入时钟：测试要能不真的等 3 秒。
  final DateTime Function() _now;

  /// 跨度小于这个值就不出数。
  ///
  /// 首尾两点挨得太近时，分母是一个舍入误差级别的数字，商会被放大成
  /// 几十倍 —— 宁可这一拍不显示，也不要闪一个假数字。
  static const double _minSpanSeconds = 0.4;

  /// 缓存量**回退**多少秒算「换了文件」。
  ///
  /// `demuxer-cache-time` 只在两个时刻会变小：换片源（清零）和 seek
  /// （跳到别处，缓存作废）。两者的旧样本都**一律作废** —— 拿旧文件的
  /// 缓存增长去除以新文件经过的时间，得到的数字没有任何意义。
  ///
  /// 留 0.05s 的容差：mpv 的值是从 double 转出来的，浮点毛刺不该被当成换片。
  static const double _rewindToleranceSeconds = 0.05;

  final List<_Sample> _samples = <_Sample>[];

  /// 喂一个新的缓存量，返回当前倍速；样本不够时返回 null。
  ///
  /// 返回 null **不是错误**，调用方应当保留上一次的值继续显示，
  /// 而不是把速度清成 0 —— 那样缓冲指示会一格一格地闪。
  double? accept(Duration cacheAhead) {
    final at = _now();
    final seconds = cacheAhead.inMicroseconds / Duration.microsecondsPerSecond;

    if (_samples.isNotEmpty &&
        seconds < _samples.last.seconds - _rewindToleranceSeconds) {
      _samples.clear();
    }
    _samples.add(_Sample(at, seconds));

    // 丢掉窗口外的旧样本，但**至少留两个**：只有一个点的窗口算不出斜率，
    // 而留着稍旧的那一个至少能给出一个（偏旧但真实）的速度。
    final cutoff = at.subtract(window);
    while (_samples.length > 2 && _samples[1].at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
    if (_samples.length < 2) return null;

    final first = _samples.first;
    final span = at.difference(first.at).inMicroseconds /
        Duration.microsecondsPerSecond;
    if (span < _minSpanSeconds) return null;

    return (seconds - first.seconds) / span;
  }

  /// 换片源 / seek 之后调用：清空样本，避免把上一次的增速带过来。
  void reset() => _samples.clear();
}

class _Sample {
  const _Sample(this.at, this.seconds);

  final DateTime at;
  final double seconds;
}
