/// 进度条上「缓冲到哪儿了」的计算规则。
///
/// 两个播放器（内置播放页 + 独立播放窗口）**共用这一份**：独立窗口跑在另一个
/// Flutter 引擎里，够不到内置播放页的控制器，两处各写一遍必然漂移。
///
/// ## 数据从哪来，它到底是什么
///
/// media_kit 的 `Player.stream.buffer` 是 mpv 的 `demuxer-cache-time`：
/// **已缓存在播放头「前面」的秒数**。它不是「从头一共下了多少秒」——
/// mpv 的缓存有上限（见 [PlayerBufferConfig.bufferSize]），填满之后这个数
/// 就停在那儿不再增长，而播放头还在往前走。
///
/// ⚠️ 所以**绝不能拿它直接除以总时长当百分比**：一部长片上它稳定在 10~1000
/// 秒，除以总时长是 0.x%~10%，画出来就是一条几乎不动的短线，看着像坏了。
/// 正确的做法是把它当成「相对播放头的增量」：
///
/// ```
/// 缓冲到的绝对位置 = 播放头 + 已缓存秒数
/// ```
///
/// 这样缓冲层会跟着播放头一起往前推 —— 这也是 mpv 真实的语义：缓存是跟着
/// 播放走的窗口，不是从头下载到尾的进度。
class PlayerBufferProgress {
  const PlayerBufferProgress._();

  /// 缓冲覆盖到的绝对位置。
  ///
  /// [cacheAhead] 为负时按 0 处理：mpv 偶尔会报一个浮点毛刺，拿去减会让
  /// 缓冲层退到播放头**后面** —— 那在进度条上是「缓冲比已播还短」的
  /// 破图，而用户只会理解成播放器坏了。
  static Duration positionOf({
    required Duration position,
    required Duration cacheAhead,
  }) {
    if (cacheAhead < Duration.zero) return position;
    return position + cacheAhead;
  }

  /// 缓冲进度（0..1）。**时长未知时返回 null** —— 那代表「不要画缓冲层」。
  ///
  /// 返回 null 而不是 0：时长还没解出来时画一条空的或满的缓冲层，都是在
  /// 凭空编造信息。进度条上宁可只有「已播」和「底」两层。
  ///
  /// ## [stalled]：mpv 说「在等数据」时，缓冲层必须收回到播放头
  ///
  /// 这不是保守处理，是**修正一个已知的虚高**：`demuxer-cache-time` 是
  /// 「缓存字节 ÷ 估算码率」换算出来的秒数，而那个估算码率来自文件头。
  /// VBR 的高码率原画上误差极大 —— 缓存 200 MB，按文件头报的 7.7 Mbps 算
  /// 成「还有 207 秒」，可那一段实际是 35 Mbps，只够 45 秒。
  ///
  /// 于是用户看到的是：进度条说缓冲超前三分钟，画面却每隔几十秒卡一下 ——
  /// 两个数字都不假，只是口径不同。
  ///
  /// 而 `paused-for-cache`（media_kit 的 `Player.stream.buffering`）是 mpv
  /// 直接报的**状态**，不经过任何换算。它为真的时候，「播放头前面没有可用
  /// 的缓冲」就是事实，缓冲层必须如实收回到播放头 —— 否则进度条等于在
  /// 骗人，而用户唯一能据此做的判断（「能不能往前拖」）会全错。
  static double? fraction({
    required Duration position,
    required Duration cacheAhead,
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
      cacheAhead: cacheAhead,
    ).inMilliseconds;
    if (reachedMs <= 0) return 0;

    return (reachedMs / totalMs).clamp(0.0, 1.0);
  }
}
