/// 续播位置的取舍规则。
///
/// ## 为什么要有「取舍」而不是存多少就续多少
///
/// 存的是播放器每 10 秒报一次的位置，直接拿它起播会有两个很难看的表现：
///
///   1. **看了三秒、关掉、再打开** → 从第 3 秒开始。用户看到的是「卡在
///      片头不动」，会以为播放器坏了。
///   2. **看完了、再看一遍** → 从「还差一分钟」开始，直接跳到结尾出字幕。
///      用户以为「这视频坏了」。
///
/// 所以两条规则：位置太靠前就当作没看过；接近结尾就当作看完了。
///
/// ## 为什么放在领域层而不是播放窗口里
///
/// 它要**在两个地方用同一套口径**：
///   - 主窗口开播时（决定 `PlayRequest.startPosition`）；
///   - 播放窗口切集时（决定新一集从哪开始）。
///
/// 两处各写一份的话，「点列表里的下一集」和「在库里点下一集」会从不同的
/// 位置起播 —— 而这种不一致极难被发现。
///
/// 它是纯函数，不碰时钟也不碰存储，所以可以直接单元测试。
abstract final class PlaybackResume {
  const PlaybackResume._();

  /// 小于这个位置不值得续 —— 当作没看过。
  ///
  /// 5 秒是个折中：进度是按 10 秒整点上报的，所以真实的已存位置会是 0 / 10 /
  /// 20…；`> 0` 就意味着「至少看了十秒」，那本来就该续。留 5 秒只是为了让
  /// 规则在**未来把上报粒度调细**之后依然成立，也顺手挡掉「误触一下就关」。
  static const Duration minResume = Duration(seconds: 5);

  /// 「看完了」的最小尾巴长度。
  ///
  /// 与 [finishedRatio] 取**大者**：短片（几分钟的花絮）用两分钟太宽，
  /// 长片（三小时的电影）用两分钟又太窄，所以两条一起用。
  static const Duration finishedTail = Duration(minutes: 2);

  /// 「看完了」的尾巴占全片比例。
  static const double finishedRatio = 0.02;

  /// 判定「已看完」的位置阈值。返回 `null` 表示**判不了**。
  ///
  /// 两种判不了的情况，都返回 `null` 而不是 0：
  ///   - 时长未知（网盘没给、还没解析出来）—— 拿不到分母；
  ///   - 片子比尾巴还短（比如 3 秒的自检视频）—— 那样任何位置都会被判成
  ///     「看完了」，等于把续播功能关掉。宁可不判。
  ///
  /// 返回 `null` 时调用方应当**当作没看完**：续播点是用户自己攒出来的，
  /// 误判成「看完了」会把他的进度清掉，代价比多续一次大。
  static Duration? finishedThreshold(Duration total) {
    if (total <= Duration.zero) return null;
    final byRatio = total * finishedRatio;
    final tail = byRatio > finishedTail ? byRatio : finishedTail;
    final threshold = total - tail;
    if (threshold <= Duration.zero) return null;
    return threshold;
  }

  /// 这个位置算不算「已经看完了」。
  ///
  /// 时长未知时一律返回 `false`（见 [finishedThreshold]）。
  static bool isFinished(Duration position, Duration total) {
    if (position <= Duration.zero) return false;
    final threshold = finishedThreshold(total);
    if (threshold == null) return false;
    return position >= threshold;
  }

  /// 开播/切集时**真正**该从哪开始。
  ///
  /// [stored] 是库里存的原始续播点，[total] 是这一集的时长（未知传 `null`）。
  static Duration startFrom({required Duration stored, Duration? total}) {
    if (stored <= minResume) return Duration.zero;
    if (total != null && isFinished(stored, total)) return Duration.zero;
    return stored;
  }
}
