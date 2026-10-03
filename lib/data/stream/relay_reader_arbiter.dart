/// 决定「哪一个读取器有权挪动预取窗口」的纯函数判定器。
///
/// ## 它解决什么
///
/// 一条中继会话上会**同时挂着好几个 HTTP 读取器** —— 实测（真 libmpv + 真夸克
/// 原画直链，8 路中继）一次播放里同时存在 3~4 个。播放器拖进度条时**不会关掉
/// 旧连接**：旧读取器留在原地继续被喂，新的那个才在目标位置。
///
/// 而预取窗口的锚点原本是**整个会话唯一的一个**，任何读取器请求任何块都会把它
/// 覆盖掉。于是 seek 之后锚点在旧位置与新位置之间反复拉锯（实测打印）：
///
/// ```
/// ENSURE 1779 anchor=1779   ← 读取器 C（seek 到 1500s）把锚点拉到新位置
/// ENSURE   92 anchor=92     ← 旧读取器 A 又把它拽回旧位置
/// ENSURE  108 anchor=108
/// ENSURE 1797 anchor=1797   ← C 再拉过去
/// ENSURE  134 anchor=134    ← 又被拽回来
/// ```
///
/// 后果实测：seek 之后 69 秒内 **78% 的上游带宽喂给了已经被抛弃的旧位置**
/// （336 MiB 对 70 MiB），新位置只拿到约 0.8 MiB/s，而片源需要 2.37 MiB/s ——
/// 表现就是「拖完进度条看一会卡一会」，几十秒后才自己恢复。而**正常起播不卡**
/// 恰恰是因为那时只有一条读取器，锚点没得争。
///
/// ## 怎么认出「当前在播的那条流」
///
/// 靠**请求范围的长度**，不靠到达顺序，也不靠猜：
///
/// - **在放片子**的读取器：mpv/ffmpeg 一律发**开放式** Range（`bytes=N-`，
///   一直到文件尾），范围动辄几个 GiB。
/// - **只是探一下索引**的读取器：读 MKV 的 `Cues` 会请求**文件尾那一小段**
///   （实测 `bytes=18351436158-`，只有 2 块）。它读几十毫秒就走，**绝不能**
///   让它把窗口挪到文件末尾 —— 那会让正在播的位置饿死。
///
/// 所以「范围 ≥ 一个预取窗口」才算在放片子（[isStream]）。
///
/// 在放片子的读取器里，**最新到达的那个**就是当前读取器 —— seek 一定会新开
/// 连接，所以「最新」正是「用户刚拖到的地方」。mpv 也会为同一条流并行开好几个
/// 连接（实测 2 个），它们位置几乎相同，谁当当前读取器都一样。
///
/// ## 判定规则
///
/// 1. 当前读取器 → 锚点跟着它（顺读推进；它自己跳远了就是 seek，直接换）。
/// 2. 别的读取器，位置落在当前窗口里 → 同一条流的并行连接：**只允许把窗口
///    *向前* 推**，绝不往回拖（否则慢的那个会把窗口拽在身后）。
/// 3. 别的「在放片子」的读取器，位置远离窗口 → 多半是已被抛弃的旧连接：不动
///    锚点，需求进低优先队列。
/// 4. 探索引（短范围）永远走主队列 —— 它只要一两块，代价可忽略；但它**永远
///    不能推动锚点**。
/// 5. 还没有当前读取器（起播，或当前读取器已结束）→ 谁先来谁是。
library;

/// 一次读取请求该被怎么对待。
enum ReaderDemand {
  /// 它就是当前播放位置：**把预取锚点挪到这个块**，需求进主队列。
  anchor,

  /// 不动锚点，但需求进主队列 —— 马上会被服务。
  serve,

  /// 不动锚点，需求进低优先队列：只在预取窗口已经填满、没别的活干时才服务，
  /// 也就是白捡的余量。
  stale,
}

/// 判定器。**纯状态机，不碰 I/O** —— 这样「seek 拉锯」这件事可以拿单测钉死，
/// 不必起真 mpv 去复现。
class RelayReaderArbiter {
  RelayReaderArbiter({required this.window, required this.minStreamBytes})
      : assert(window > 0),
        assert(minStreamBytes > 0);

  /// 「同一个位置」的容差，单位是**块**。取预取窗口的大小。
  ///
  /// 实测里 mpv 的多个并行读取器彼此相距 0~5 块，而 seek 的跨度是 1500+ 块，
  /// 这个阈值把两者分得很开。
  final int window;

  /// 请求范围达到多少字节才算「在放片子」。见 [isStream]。
  final int minStreamBytes;

  int _anchor = 0;
  int? _current;

  /// 在放片子的读取器，按到达顺序排列（最新在末尾）。
  final List<int> _streams = <int>[];

  /// 探索引（读索引的那类短范围请求）。
  final Set<int> _probes = <int>{};

  /// 预取窗口该锚在哪个块。**只有 [decide] 返回 [ReaderDemand.anchor] 时才变。**
  int get anchor => _anchor;

  /// 当前读取器（推动锚点的那个）。没有时为 `null`。
  int? get currentReader => _current;

  /// 在放片子的读取器个数（诊断用）。
  int get streamReaderCount => _streams.length;

  /// 这个请求范围够不够长，够长才可能是在放片子。
  ///
  /// 短范围（读文件尾的 `Cues`）是**探索引**：它读一两块就走，让它推动锚点会把
  /// 窗口整个挪到文件末尾，正在播的位置立刻饿死。
  bool isStream(int rangeLength) => rangeLength >= minStreamBytes;

  /// 登记一个读取器。[stream] 为 true 表示它在放片子（范围够长）。
  ///
  /// **最新到达的「在放片子」读取器成为当前读取器。**
  void attach(int readerId, {required bool stream}) {
    if (!stream) {
      _probes.add(readerId);
      return;
    }
    _streams
      ..remove(readerId)
      ..add(readerId);
    _current = readerId;
  }

  /// 一个读取器结束了（连接断了 / 那条范围读完了）。
  ///
  /// 当前读取器走了必须让位给下一个，否则锚点再没人推动、窗口冻在原地 ——
  /// 表现是「画面停住不动，日志里却没有任何错误」。
  void release(int readerId) {
    _probes.remove(readerId);
    _streams.remove(readerId);
    if (_current == readerId) {
      _current = _streams.isEmpty ? null : _streams.last;
    }
  }

  /// 把锚点摆到一个初值上（续播点换算来的字节偏移）。
  ///
  /// 只影响「第一个读取器到达之前」的预取方向；读取器一到就会按规则 1/5 接管。
  void seed(int index) {
    _anchor = index < 0 ? 0 : index;
  }

  /// 判定这次请求。
  ReaderDemand decide({required int readerId, required int index}) {
    final current = _current;
    // ⑤ 没人当家：起播的第一个读取器，或上一个当前读取器已经结束。
    if (current == null) {
      _anchor = index;
      return ReaderDemand.anchor;
    }

    // ① 就是当家的那个：顺读推进；它自己跳远了就是 seek，直接换锚点。
    if (current == readerId) {
      _anchor = index;
      return ReaderDemand.anchor;
    }

    final delta = index - _anchor;
    // ② 就在窗口里：同一条流的并行连接。可以往前推，绝不往回拖。
    if (delta.abs() <= window) {
      if (delta > 0) _anchor = index;
      return ReaderDemand.serve;
    }

    // ④ 探索引：照常服务，但不动锚点。
    if (_probes.contains(readerId)) return ReaderDemand.serve;

    // ③ 被抛弃的旧连接：不动锚点，需求降级。
    return ReaderDemand.stale;
  }
}
