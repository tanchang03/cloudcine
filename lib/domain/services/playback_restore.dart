/// 换源后把播放头**补回原处**的判定。
///
/// ## 为什么 `EngineMedia.startAt` 还不够
///
/// 起播位置走的是 mpv 的 `start` 属性（实测记录见 `PlaybackMedia`）。
/// 它多数时候有效，但**是一次静默的尝试**：属性设下去了、mpv 没照做，
/// 没有任何回调会告诉我们。故障形态正是用户报的那句
/// 「选择画质后都会重头就开始播放」—— 而日志里「起播=1800s」那一行
/// 看着一切正常，所以只看日志永远查不出来。
///
/// 所以起播之后要**核对一次**：位置离目标还很远，就补一次显式 `seek`。
///
/// ## 为什么不能一有位置就补
///
/// 「open 之后立刻 seek 会被丢掉」是本项目实测过的（`PlaybackMedia` 的 E 行）：
/// 那时解复用器还没就绪。所以补发要等一个**就绪信号** —— 时长解出来了，
/// 或者位置开始推进。
///
/// ## 为什么「落到位」要连续两拍才算
///
/// 换源期间**旧流还在播**（见 `PlaybackController._prepareSource` 的预热），
/// 所以新流的第一拍之前可能夹着一条旧流的位置回报 —— 而它恰好等于目标
/// （目标就是从旧流的位置取的）。只认一拍的话会被它骗过去，于是新流真的
/// 从头播也没人管。连续两拍就分得开：真落到位会一直报那个位置。
///
/// 纯状态机：不看时钟、不碰 IO，所以能直接单测。
library;

/// [RestoreSeek.observe] 的结论。
enum RestoreSeekAction {
  /// 时机未到，再等等。
  wait,

  /// 补一次显式 seek 到 [RestoreSeek.target]。
  seek,

  /// 了结了（已落到位 / 补发次数用尽）。调用方应当丢掉这个对象。
  settle,
}

/// 一次「换源后恢复播放位置」的核对过程。
class RestoreSeek {
  RestoreSeek(
    this.target, {
    this.tolerance = const Duration(seconds: 3),
    this.maxAttempts = 3,
  }) {
    // 目标本身就在容差里 → 没有可恢复的东西，直接了结。省掉一次无谓的
    // seek（切档前只看了一两秒时就是这种情况）。
    if (target <= tolerance) _done = true;
  }

  /// 要恢复到的位置。
  final Duration target;

  /// 离目标多近算「到位」。
  ///
  /// 3 秒是刻意放宽的：mpv 的 `start` 会落在**关键帧**上，实际位置与请求值
  /// 差个一两秒是正常的 —— 判太紧会把它当成「没生效」，白补一次 seek。
  final Duration tolerance;

  /// 最多补发几次。
  ///
  /// 第一次补发仍可能撞上解复用器刚就绪的那一瞬而被丢掉，所以要允许重试；
  /// 但不能无限补 —— 真遇上不可 seek 的流，无限补就是每 100ms 一次空转。
  final int maxAttempts;

  int _attempts = 0;
  int _consecutiveNear = 0;
  bool _sawDuration = false;
  bool _sawProgress = false;
  Duration? _lastPosition;
  bool _done = false;

  /// 已经补发过几次。
  int get attempts => _attempts;

  bool get isDone => _done;

  /// 收一条位置回报，给出下一步。
  ///
  /// [position] 是内核刚报的播放头，[duration] 是此刻已知的时长
  /// （未知传 [Duration.zero]）—— 后者是「解复用器就绪了没有」的证据之一。
  RestoreSeekAction observe(Duration position, Duration duration) {
    if (_done) return RestoreSeekAction.settle;

    if (duration > Duration.zero) _sawDuration = true;
    final last = _lastPosition;
    if (last != null && last != position) _sawProgress = true;
    _lastPosition = position;

    if ((position - target).abs() <= tolerance) {
      _consecutiveNear++;
      if (_consecutiveNear >= 2) {
        _done = true;
        return RestoreSeekAction.settle;
      }
      return RestoreSeekAction.wait;
    }
    _consecutiveNear = 0;

    // 解复用器还没就绪时补发会被丢掉，所以等信号（见类文档）。
    if (!_sawDuration && !_sawProgress) return RestoreSeekAction.wait;

    if (_attempts >= maxAttempts) {
      _done = true;
      return RestoreSeekAction.settle;
    }
    _attempts++;
    return RestoreSeekAction.seek;
  }
}
