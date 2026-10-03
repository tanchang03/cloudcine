/// 进度条上「缓冲到哪儿了」的计算规则。
///
/// 两个播放器（内置播放页 + 独立播放窗口）**共用这一份**：独立窗口跑在另一个
/// Flutter 引擎里，够不到内置播放页的控制器，两处各写一遍必然漂移。
///
/// ## 数据是什么：`demuxer-cache-time` 是**绝对时间戳**，不是「前面还有多少秒」
///
/// media_kit 的 `Player.stream.buffer` 就是 mpv 的 `demuxer-cache-time`。
/// mpv 0.36 手册原文：
///
/// > Approximate time of video buffered in the demuxer, in seconds. Same as
/// > `demuxer-cache-duration` but returns the **last timestamp** of buffered
/// > data in demuxer.
///
/// 源码同样明确 —— `player/command.c` 里它返回 `s.ts_end`，
/// `demux/demux.h` 里该字段的定义是
/// `double ts_end; // approx. timestamp of end of buffered range`。
/// 也就是说它是「**已缓存区间的结束位置**」，参照系与 `time-pos` 相同。
///
/// 「播放头前面还有多少秒」是**另一个**属性 `demuxer-cache-duration`
/// （源码：`ts_duration = ts_end - ts_reader`）。media_kit 没有暴露它。
///
/// ## ⚠️ 2026-10-03 实测踩过的坑：把绝对值又加了一遍播放头
///
/// 这里原来写的是 `缓冲位置 = 播放头 + demuxer-cache-time`。**方向反了**：
/// 那个数本身就是位置，再加一次播放头等于把播放头算了两遍。后果是
/// **每跳一次进度条，缓冲层就凭空多出一整个播放头那么长** ——
/// 播到 12:07、真实缓存到 13:2x，界面画到 25:5x；用户看到的是
/// 「一点进度就缓存了一大截，可画面照样卡」，而且**不报任何错**。
///
/// ## 所以规则只有一条
///
/// ```
/// 缓冲到的绝对位置 = demuxer-cache-time（它自己就是位置）
/// ```
class PlayerBufferProgress {
  const PlayerBufferProgress._();

  /// 缓冲覆盖到的绝对位置。
  ///
  /// [cacheEnd] 就是 mpv 报的「已缓存区间结束时间戳」。两种情况退回
  /// [position]，否则会画出「缓冲比已播还短」的破图：
  ///
  ///   - **非正**：还没解出任何缓存数据时 mpv 给的是 0；
  ///   - **小于播放头**：跳到旧缓存区间之外的一瞬间会这样。mpv 在 seek
  ///     过程中把 `ts_duration` 置 0，但 `ts_end` **不会**同步清零，
  ///     所以会短暂地报出一个落在播放头后面的旧值。
  static Duration positionOf({
    required Duration position,
    required Duration cacheEnd,
  }) {
    if (cacheEnd <= Duration.zero) return position;
    if (cacheEnd < position) return position;
    return cacheEnd;
  }

  /// 缓冲进度（0..1）。**时长未知时返回 null** —— 那代表「不要画缓冲层」。
  ///
  /// 返回 null 而不是 0：时长还没解出来时画一条空的或满的缓冲层，都是在
  /// 凭空编造信息。进度条上宁可只有「已播」和「底」两层。
  ///
  /// ## [stalled]：mpv 说「在等数据」时，缓冲层必须收回到播放头
  ///
  /// [stalled] 是 mpv 的 `paused-for-cache`（media_kit 的
  /// `Player.stream.buffering`）—— 一个**状态**，不是换算出来的数。
  ///
  /// 正常情况下 mpv 自己的数就会收敛到播放头：没有数据可读时
  /// `ts_reader`（解复用器位置）追平 `ts_end`，于是
  /// `ts_duration = ts_end - ts_reader` 归零。这一条是**交叉校验** ——
  /// mpv 都已经说了在等数据，界面就不该再宣称播放头前面还有缓冲。
  static double? fraction({
    required Duration position,
    required Duration cacheEnd,
    required Duration duration,
    bool stalled = false,
  }) {
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) return null;

    if (stalled) {
      return (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    }

    final reachedMs = positionOf(
      position: position,
      cacheEnd: cacheEnd,
    ).inMilliseconds;
    if (reachedMs <= 0) return 0;

    return (reachedMs / totalMs).clamp(0.0, 1.0);
  }
}
