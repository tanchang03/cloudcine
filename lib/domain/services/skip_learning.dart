import 'dart:math' as math;

/// 片头还是片尾。
///
/// 存名字而不是序号（见 `SkipSamples.kind`）：加一种类型时序号会整体错位，
/// 旧数据会**静默**变成另一种类型。
enum SkipKind {
  intro('片头'),
  outro('片尾');

  const SkipKind(this.label);

  final String label;

  /// 解析数据库里的字符串。认不出来返回 `null`（= 这条样本作废，
  /// 而不是「当成片头」—— 猜错会污染整个聚合）。
  static SkipKind? parse(String? raw) {
    for (final k in SkipKind.values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

/// 一条**原始落点样本**。
///
/// ## 它记的是「用户做了什么」，不是「片头在哪儿」
///
/// 单条样本**不足以**推出片头 —— 用户可能只是随便拖了一下。所以这一层
/// 只负责如实记录，判断交给 [SkipLearning.learn] 的跨集聚合。
class SkipSample {
  const SkipSample({
    required this.id,
    required this.itemId,
    required this.workKey,
    required this.kind,
    required this.anchor,
    required this.duration,
    this.negative = false,
    this.device = '',
    required this.createdAt,
  });

  /// 主键：`itemId#kind#毫秒时间戳`（见 [idFor]）。
  final String id;

  final String itemId;
  final String workKey;
  final SkipKind kind;

  /// 落点。片头 = 从开头跳到的位置；片尾 = 「不想再看」的位置。
  final Duration anchor;

  /// 这次播放的总时长。
  final Duration duration;

  /// 负样本（用户撤销 / 回拖作废）。不参与聚合。
  final bool negative;

  /// 产生这条样本的设备（只用于排查，不参与聚合）。
  final String device;

  final DateTime createdAt;

  /// 距末尾的偏移。**片尾聚合用的就是它** ——
  /// 各集片长不同（正片 45 分钟、特辑 60 分钟），绝对时间跨集不可比，
  /// 而「离结尾还有多久开始是片尾」这个量是稳定的。
  Duration get offset => duration - anchor;

  /// 生成主键。
  ///
  /// ⛔ 用「媒体项 + 类型 + 毫秒时间戳」而不是自增 id：两端各自生成 id 时
  ///    不会撞车（备份合并之后仍然唯一），而自增 id 在合并两份库时**必然**
  ///    冲突 —— 而冲突的表现是「样本被覆盖」，不报错。
  ///
  /// ⚠️ 同一毫秒内对同一个媒体项、同一种类型采样两次会得到同一个 id
  ///    （后者覆盖前者）。这在现实中不可能发生：一次播放里每类锚点
  ///    最多产出一次（见 [SkipAnchorCollector]）。
  static String idFor({
    required String itemId,
    required SkipKind kind,
    required DateTime at,
  }) =>
      '$itemId#${kind.name}#${at.millisecondsSinceEpoch}';

  @override
  String toString() =>
      'SkipSample(${kind.name}, ${anchor.inSeconds}s/${duration.inSeconds}s'
      '${negative ? ", 负样本" : ""})';
}

/// 采集器产出的**有效落点**。
///
/// 「有效」的定义见 [SkipAnchorCollector]：用户在这个位置**停下来看了
/// 一会儿**，而不是拖过去又拖走。
class SkipAnchor {
  const SkipAnchor({
    required this.anchor,
    required this.duration,
    required this.playStart,
  });

  final Duration anchor;
  final Duration duration;

  /// 这次播放**是从哪儿开始的**。
  ///
  /// 判片头必须用它：续播（从上次位置继续）时「0 → 落点」这个区间
  /// 根本不成立 —— 用户没看过那段，也就谈不上「跳过」。
  final Duration playStart;

  /// 落点距末尾的偏移。判片尾用它（各集片长不同，绝对时间不可比）。
  Duration get offset => duration - anchor;

  @override
  String toString() =>
      'SkipAnchor(${anchor.inSeconds}s, 起播 ${playStart.inSeconds}s)';
}

/// 一次 seek 的观测。
class SeekObservation {
  const SeekObservation({
    required this.from,
    required this.to,
    required this.duration,
    required this.rate,
  });

  /// 跳转**前**的播放头位置。
  final Duration from;

  /// 跳转**后**的目标位置。
  final Duration to;

  final Duration duration;

  /// 当时的播放倍速。
  final double rate;
}

/// 把「用户拖了一下」变成「用户决定在这儿看」的**状态机**。
///
/// ## 为什么必须有这一层
///
/// 用户在进度条上拖一次，动机是**多义**的：跳片头、跳片尾、回看刚才那段、
/// 拖错了再拖一次、找位置。直接把每次拖拽的目标记下来求平均，会被「随便拖」
/// 严重污染 —— 学出一个并不存在的片头，然后播放器照着它**自动跳过去**，
/// 用户莫名其妙丢了内容，且没有任何提示。
///
/// ## 判据：只有「停下来连续观看」的落点才有信息量
///
/// 一次 seek 之后，如果从落点起**连续自然播放**超过 [stableWatch] 且
/// 期间没有新的 seek，那个落点才被确认。于是：
///
///   * 「拖来拖去」自动被过滤 —— 中间那些落点都因为「很快就又拖了」而不成立；
///   * 「回拖」（落点之后又往回跳）直接作废；
///   * 「拖到末尾然后**看完**」也被作废（见 [notePosition]）—— 那是用户想看
///     那段内容，那里不是片尾。
///
/// ⛔ 一个实例对应**一次播放**。换集 / 换清晰度 / 重开流都要 [reset] ——
///    漏了它的后果是 `_pending` 带着上一集的落点，把下一集的锚点算错。
class SkipAnchorCollector {
  SkipAnchorCollector({
    this.stableWatch = SkipLearning.stableWatch,
    this.minSeekDelta = SkipLearning.minSeekDelta,
  });

  /// 落点之后要连续观看多久才算「停下来了」。
  final Duration stableWatch;

  /// 小于这个幅度的 seek 不记（防抖、防误触）。
  final Duration minSeekDelta;

  Duration? _pending;
  Duration? _pendingDuration;
  Duration _playStart = Duration.zero;

  bool _introEmitted = false;
  bool _outroEmitted = false;

  /// 当前有没有一个待确认的落点。测试与排查用。
  Duration? get pending => _pending;

  /// 这次播放是从哪儿开始的（判片头要用）。
  Duration get playStart => _playStart;

  /// 这次播放**正式开始**（第一次拿到非零位置）时调一次。
  ///
  /// ⛔ 起播位置就是**第一次**拿到的位置，不是「续播点」—— 用户可能手动
  ///    拖到第 5 分钟才开始看，那也不算从头起播。所以这个值只写一次。
  void notePlayStart(Duration position) {
    if (_playStart != Duration.zero) return;
    _playStart = position;
  }

  /// 用户拖了一次（或按了一次快进）。**只记录待确认的落点，不产出锚点。**
  ///
  /// 过滤掉的三类：
  ///   * **倍速**：`rate != 1.0` 时「位置」的语义变了（用户在扫剧），
  ///     锚点与其他集不可比；
  ///   * **幅度太小**：`to - from < minSeekDelta`，是误触或防抖抖动；
  ///   * **后退**：`to <= from`，用户想回看，不是想跳过什么。
  void noteSeek(SeekObservation obs) {
    // 任何一次 seek 都先作废上一个待确认落点：用户在那儿没停下来。
    _pending = null;
    _pendingDuration = null;

    if (obs.rate != 1.0) return;
    if (obs.duration <= Duration.zero) return;
    if (obs.to <= obs.from) return;
    if (obs.to - obs.from < minSeekDelta) return;

    _pending = obs.to;
    _pendingDuration = obs.duration;
  }

  /// 播放头动了。**片头锚点唯一被确认的地方。**
  ///
  /// 两个分支：
  ///   1. `position < pending` ⇒ 用户**回拖**了 ⇒ 待确认落点作废
  ///      （这正是「拖拽点不在片头片尾」里最麻烦的那一类）；
  ///   2. `position - pending >= stableWatch` ⇒ 用户在那儿停下来看了 ⇒ 确认。
  ///
  /// ## ⛔ 这里**不产出片尾锚点**，哪怕落点落在片尾窗口里
  ///
  /// 「看了 15 秒」不足以说明「这里不是片尾」：用户完全可能拖到片尾前
  /// 一分钟、看 20 秒、然后把整集看完 —— 那说明那 60 秒里有内容，
  /// 不是片尾。而停留确认是**不可撤回**的（确认完 `_pending` 就清了），
  /// 所以这里一旦产出就没法再纠正。
  ///
  /// 片尾走的是另一条更强的信号：[noteEpisodeSwitch]。用户「不想看了」
  /// 这个意图在**切下一集**这个动作上表达得比任何 seek 都清楚，而且它是
  /// 终态 —— 没有「再看一会儿」的可能，也就不需要停留确认。
  SkipAnchor? notePosition(Duration position) {
    final pending = _pending;
    if (pending == null) return null;

    if (position < pending) {
      _pending = null;
      _pendingDuration = null;
      return null;
    }

    if (position - pending < stableWatch) return null;

    final duration = _pendingDuration!;
    _pending = null;
    _pendingDuration = null;

    final anchor = SkipAnchor(
      anchor: pending,
      duration: duration,
      playStart: _playStart,
    );
    if (SkipLearning.classify(anchor) != SkipKind.intro) return null;
    if (_introEmitted) return null;
    _introEmitted = true;
    return anchor;
  }

  /// 用户**切到了下一集**（或退出播放）。
  ///
  /// ## 为什么这是片尾最强、也是唯一的信号
  ///
  /// 用户「跳过片尾」的动作通常不是「拖到末尾」，而是**从某个位置直接切下一集**
  /// ——「我不想看了」这个意图在切集这个动作上表达得比任何 seek 都清楚。
  ///
  /// ⛔ 它**不需要** [stableWatch] 确认：切集是终态，没有「再看一会儿」的
  ///    可能。这恰好补上了 [notePosition] 的短板 —— 停留确认**不可撤回**，
  ///    而「拖到片尾看完」和「拖到片尾切集」在停留那一刻长得一模一样，
  ///    只有等到切集时才分得清。
  ///
  /// ⛔ 传的是**切集那一刻**的播放头位置，不是「用户之前拖到哪儿」。
  ///    语义是「用户不想看最后这一段」，而那一段的起点就是他按下切集时
  ///    所在的位置。传拖拽落点会把中间看过的内容也算进片尾。
  ///
  /// ⚠️ 返回的锚点仍然要过 [SkipLearning.classify]：
  ///   * 用户看了 10 秒就切集（既不构成片头也不构成片尾）→ `null`；
  ///   * 一集自然播完、自动连播下一集（位置 ≈ 片长、偏移 ≈ 0）→ `null`。
  SkipAnchor? noteEpisodeSwitch({
    required Duration position,
    required Duration duration,
  }) {
    _pending = null;
    _pendingDuration = null;
    if (duration <= Duration.zero) return null;

    final anchor = SkipAnchor(
      anchor: position,
      duration: duration,
      playStart: _playStart,
    );
    if (SkipLearning.classify(anchor) != SkipKind.outro) return null;
    if (_outroEmitted) return null;
    _outroEmitted = true;
    return anchor;
  }

  /// 换集 / 换清晰度 / 重开流。**保留不了任何东西** ——
  /// 起播位置也要重记，否则下一集会被当成「从头起播」而其实不是。
  void reset() {
    _pending = null;
    _pendingDuration = null;
    _playStart = Duration.zero;
    _introEmitted = false;
    _outroEmitted = false;
  }
}

/// 学习出的**片头**：`[0, end]`。
class LearnedIntro {
  const LearnedIntro({
    required this.end,
    required this.samples,
    required this.spread,
  });

  /// 片头终点。起点恒为 `0`（片头总在开头）。
  final Duration end;

  /// 参与聚合的样本数。
  final int samples;

  /// 中位绝对偏差（MAD）—— 「各集落点有多集中」。越小越可信。
  final Duration spread;

  @override
  String toString() =>
      'LearnedIntro(0→${end.inSeconds}s, $samples 样本, 散布 ${spread.inSeconds}s)';
}

/// 学习出的**片尾**：只有「距末尾的偏移」一个数。
class LearnedOutro {
  const LearnedOutro({
    required this.offset,
    required this.samples,
    required this.spread,
  });

  /// 距末尾的偏移。播放时用 `duration - offset` 算落点。
  final Duration offset;

  final int samples;
  final Duration spread;

  @override
  String toString() =>
      'LearnedOutro(末尾前 ${offset.inSeconds}s, $samples 样本, '
      '散布 ${spread.inSeconds}s)';
}

/// 一次完整的学习结果（片头 + 片尾，各自可能没有）。
class SkipLearningOutcome {
  const SkipLearningOutcome({this.intro, this.outro});

  final LearnedIntro? intro;
  final LearnedOutro? outro;

  /// 写进 `media_works.learned_samples` 的那个数：取两者的**较大值**。
  ///
  /// 用一个数而不是两个，是因为 UI 上只需要回答「这个结果有多少集撑着」——
  /// 而片头与片尾的样本常常就是同一批集（用户既跳片头也跳片尾）。
  int get samples => math.max(intro?.samples ?? 0, outro?.samples ?? 0);

  /// 什么都没学出来。
  bool get isEmpty => intro == null && outro == null;

  @override
  String toString() =>
      'SkipLearningOutcome(intro=$intro, outro=$outro)';
}

/// 「跳过片头 / 片尾」的学习规则。
///
/// ## 全部是纯函数
///
/// 抽成纯函数不是为了好看，是因为它要在**两个播放器**（主窗口内置播放页 +
/// 独立播放窗口）里各用一遍，而这两处跑在不同的 Flutter 引擎里、够不到
/// 对方的代码。规则散成两份就会变成「内置页学得对、独立窗口学得怪」——
/// 与 `IntroSkip` 抽出来的理由完全一样。
///
/// ## 为什么用中位数 + MAD，而不是均值 + 标准差
///
/// 拖错一次就产生一个离群点：均值会被拽偏，标准差会被拉爆（一个 5 分钟的
/// 离群点就能让「12 集都很一致」的片头看起来完全不可信）。中位数与
/// 中位绝对偏差（MAD）对离群点**免疫**。
///
/// ## 认不出来就什么都不做
///
/// 每一条门槛不满足时都返回 `null`，而不是「取一个近似值」。这与
/// `IntroMarkerDetector.detect` 的取舍一致：**宁可不生效，也不勉强生效**。
/// 用户手动拖一次的成本，远低于被自动跳到错误位置的成本（那是不可逆的）。
abstract final class SkipLearning {
  const SkipLearning._();

  // ------------------------------------------------------------------
  // 采集侧阈值
  // ------------------------------------------------------------------

  /// 落点之后要连续观看多久才算「停下来了」。
  ///
  /// ⚠️ **这是最需要真机校准的一个参数**。太短挡不住探索性拖拽；
  /// 太长会让「跳完片头紧接着又跳片尾」的连续操作互相干扰。
  /// 15 秒是估计值：足够长到排除「拖过去瞄一眼」，足够短到不打断正常观看。
  static const Duration stableWatch = Duration(seconds: 15);

  /// 小于这个幅度的 seek 不记（防抖、防误触）。
  static const Duration minSeekDelta = Duration(seconds: 3);

  // ------------------------------------------------------------------
  // 分类窗口
  // ------------------------------------------------------------------

  /// 片头落点的下界。比这更短的「片头」跳过去毫无意义，只是让画面抖一下。
  static const Duration introMinAnchor = Duration(seconds: 15);

  /// 片头落点的上界。**再晚就不是片头了。**
  ///
  /// 一集电视剧的片头总在开头，3 分钟这个值取得很宽松（连「冷开场 2 分半
  /// 的长片头」都容得下）。它的作用是挡住「用户拖到第 20 分钟看剧情」
  /// 被当成片头 —— 那种情况下自动跳过去会让用户直接丢掉半集内容。
  static const Duration introMaxAnchor = Duration(minutes: 3);

  /// 只有起播位置早于这个值，才认为这一集是**从头起播**的。
  ///
  /// 续播（从上次位置继续）不产生片头锚点：用户没看过开头，
  /// 「0 → 落点」这个区间根本不成立。
  static const Duration fromStartMax = Duration(seconds: 30);

  /// 片尾偏移的下界（`duration - anchor`）。
  static const Duration outroMinOffset = Duration(seconds: 10);

  /// 片尾偏移的上界。距末尾超过 5 分钟的落点**不是片尾**，是「跳到中后段」。
  static const Duration outroMaxOffset = Duration(minutes: 5);

  /// 短于这个时长的片子**不学习**。
  ///
  /// 片头窗口（`0~3min`）与片尾窗口（`duration-5min ~ duration-10s`）在
  /// `duration < 8min` 时会重叠，判定不可靠。宁可挡掉短视频，
  /// 也不要在两个窗口之间猜。
  static const Duration minDuration = Duration(minutes: 8);

  // ------------------------------------------------------------------
  // 聚合侧阈值
  // ------------------------------------------------------------------

  /// 最少样本数。3 集是「不是偶然」的最低门槛。
  static const int minSamples = 3;

  /// 片头落点的最大中位绝对偏差。
  static const Duration introMaxSpread = Duration(seconds: 8);

  /// 片尾偏移的最大中位绝对偏差。
  ///
  /// 比片头松 2 秒：片尾的落点比片头随意（用户可能看到字幕开始才切，
  /// 也可能提前几秒切），这个量天生更散。
  static const Duration outroMaxSpread = Duration(seconds: 10);

  // ------------------------------------------------------------------
  // 分类
  // ------------------------------------------------------------------

  /// 把一个有效落点分到片头 / 片尾；都不在窗口内返回 `null`。
  ///
  /// ⛔ **先判片尾再判片头**。两个窗口在短片上会重叠，而 `minDuration`
  ///    已经挡掉了那种情况 —— 所以这里的顺序只影响「恰好同时满足」的
  ///    边角情形，而片尾的窗口更窄（10s~5min 距末尾），更可信。
  static SkipKind? classify(SkipAnchor anchor) {
    final duration = anchor.duration;
    if (duration < minDuration) return null;

    final offset = duration - anchor.anchor;
    if (offset >= outroMinOffset && offset <= outroMaxOffset) {
      return SkipKind.outro;
    }

    // 片头必须**从头起播**：续播时用户没看过开头。
    if (anchor.playStart > fromStartMax) return null;
    if (anchor.anchor < introMinAnchor) return null;
    if (anchor.anchor > introMaxAnchor) return null;
    return SkipKind.intro;
  }

  // ------------------------------------------------------------------
  // 聚合
  // ------------------------------------------------------------------

  /// 一批样本 → 学习结果。
  static SkipLearningOutcome learn(List<SkipSample> samples) =>
      SkipLearningOutcome(
        intro: learnIntro(samples),
        outro: learnOutro(samples),
      );

  /// 学出片头区间（`[0, end]`）。认不出来返回 `null`。
  static LearnedIntro? learnIntro(List<SkipSample> samples) {
    final anchors = <Duration>[
      for (final s in samples)
        if (s.kind == SkipKind.intro && !s.negative) s.anchor,
    ];
    if (anchors.length < minSamples) return null;

    final center = median(anchors)!;
    final spread = medianAbsoluteDeviation(anchors, center);
    if (spread > introMaxSpread) return null;
    if (center < introMinAnchor || center > introMaxAnchor) return null;

    return LearnedIntro(
      end: center,
      samples: anchors.length,
      spread: spread,
    );
  }

  /// 学出片尾偏移。认不出来返回 `null`。
  static LearnedOutro? learnOutro(List<SkipSample> samples) {
    // ⛔ 用 `offset`（距末尾）而不是 `anchor`（绝对时间）：
    //    各集片长不同，绝对时间跨集不可比。
    final offsets = <Duration>[
      for (final s in samples)
        if (s.kind == SkipKind.outro && !s.negative) s.offset,
    ];
    if (offsets.length < minSamples) return null;

    final center = median(offsets)!;
    final spread = medianAbsoluteDeviation(offsets, center);
    if (spread > outroMaxSpread) return null;
    if (center < outroMinOffset || center > outroMaxOffset) return null;

    return LearnedOutro(
      offset: center,
      samples: offsets.length,
      spread: spread,
    );
  }

  /// 中位数。空列表返回 `null`。
  ///
  /// 偶数个取中间两个的**平均**（而不是任取一个）：取平均不会偏向任何一侧，
  /// 而「取较小的那个」在样本数为 4 时会系统性地偏小。
  static Duration? median(List<Duration> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return Duration(
      microseconds:
          (sorted[mid - 1].inMicroseconds + sorted[mid].inMicroseconds) ~/ 2,
    );
  }

  /// 中位绝对偏差（MAD）：每个值与 [center] 的距离，再取中位数。
  ///
  /// 它是「这批落点有多集中」的直接度量 —— 比标准差抗离群点。
  /// 空列表返回 [Duration.zero]（调用方已经先过 `minSamples`）。
  static Duration medianAbsoluteDeviation(
    List<Duration> values,
    Duration center,
  ) {
    if (values.isEmpty) return Duration.zero;
    final deviations = <Duration>[
      for (final v in values)
        v >= center ? v - center : center - v,
    ];
    return median(deviations) ?? Duration.zero;
  }
}
