import 'intro_marker.dart';

/// **一次播放**里的片头状态。
///
/// ## 为什么要有这个类，而不是两边各存几个字段
///
/// 「该不该跳」是纯函数（[IntroSkip.shouldSkip]），但「什么时候去读文件章节」
/// 「这一次已经跳过了没有」「章节和手标哪一份生效」是**状态**。两个播放器
/// （主窗口内置播放页、独立播放窗口）各存一份、各写一遍转移，迟早会漂移成
/// 「内置页跳得对、独立窗口跳得怪」—— 而它们跑在不同的 Flutter 引擎里，
/// 用户根本不会想到这是两套代码。
///
/// 所以状态与转移全部收在这里，两个播放器各自只做三件事：
/// 取数据（手标区间来自请求 / 库，章节来自 mpv）、问状态、按回答去 seek。
///
/// ## 生命周期
///
/// 一个实例对应**一条流**。换集 / 切清晰度 / 重新取链都要 [reset] ——
/// 漏了它的后果很隐蔽：`_probed` 留着 true，于是换集之后**永远不再读章节**，
/// 表现成「只有第一集跳片头」，而第一集恰好是最不需要跳的那一集。
class IntroSession {
  IntroSession({IntroMarker? manual, bool enabled = true})
      : _manual = manual,
        _enabled = enabled;

  /// 从**库里 / 请求里**来的手标区间（兜底）。
  IntroMarker? _manual;

  /// 从**文件章节**里认出来的区间（优先）。
  IntroMarker? _chapter;

  /// 设置里那一项。关掉时连章节都不读（省一次属性查询）。
  bool _enabled;

  bool _probed = false;
  bool _skipped = false;

  bool get enabled => _enabled;

  /// 用户手标的那一份（与 [fromChapters] 无关 —— UI 要靠它决定
  /// 「清除标记」这一项显不显示）。
  IntroMarker? get manual => _manual;

  /// 当前生效的区间：**文件章节优先，手标兜底**。
  ///
  /// 顺序不能反。文件章节是压制者标的，与**这一集**的实际内容严格对应；
  /// 手标是「这一部作品」级别的一次性标记（`MediaWork.introStartMs`），
  /// 各集片长不同时会有偏差。只有在文件里读不到章节时 —— 绝大多数网盘
  /// 片源都是这样 —— 手标才有意义。
  IntroMarker? get marker => _chapter ?? _manual;

  /// 生效的那一份是不是来自文件章节。UI 的文案要按它分岔：
  /// 「发布者标的」与「你自己标的」是两件不同的事。
  bool get fromChapters => _chapter != null;

  /// 本次流是否已经跳过片头。
  bool get skipped => _skipped;

  /// 换一条流（换集 / 切清晰度 / 重开）时归零。
  void reset({IntroMarker? manual, bool enabled = true}) {
    _manual = manual;
    _enabled = enabled;
    _chapter = null;
    _probed = false;
    _skipped = false;
  }

  /// 这次播放结束了（播放器停止 / 播放页退出）。
  ///
  /// 与 [reset] 的区别：**保留**手标区间与开关。它们是「这一部作品的播放
  /// 偏好」，与「这次播放结束了」无关 —— 一起清掉会让「退出播放页再进来」
  /// 第一次不跳片头。
  void endStream() {
    _chapter = null;
    _probed = false;
    _skipped = false;
  }

  /// 用户手标了片头区间（或取消标记）后同步进来。
  ///
  /// 标记变了就**重新给一次机会**（`_skipped` 归零）：用户刚标完区间，
  /// 紧接着的那次播放应当跳 —— 否则他会以为标记没生效，于是再标一次。
  void setManual(IntroMarker? marker) {
    if (_manual == marker) return;
    _manual = marker;
    _skipped = false;
  }

  /// 现在该不该去读文件章节。
  ///
  /// 三个条件：
  ///   1. 本次流**还没读过** —— `chapter-list` 是一次属性查询，一次就够；
  ///   2. 设置里开着跳片头 —— 关掉时连这一次查询都省了；
  ///   3. `position > 0` —— 这是**唯一能证明容器已经解析完**的信号。
  ///      `open()` 返回时读到的恒是 `[]`，而「还没解析完」与「这个文件没有
  ///      章节」在字符串上无法区分（实测结论，见 `MpvChapters` 的类文档）。
  ///
  /// 抽成纯函数是为了能脱离 mpv 单测 —— 这一条判错不会报错，只会让跳片头
  /// 时灵时不灵，是最难从用户反馈里定位的一类问题。
  bool shouldProbe(Duration position) =>
      _enabled && !_probed && position > Duration.zero;

  /// 标记「已经探测过了」。
  ///
  /// ⚠️ 必须在**第一个 `await` 之前**调（见两个播放器里的调用点）：
  /// 位置流每 ~100ms 来一条，不先置位的话同一帧内连着来的几条会各起一个
  /// 探测任务，把 `chapter-list` 读上十几次。
  void markProbed() => _probed = true;

  /// 章节探测的结果回来了。`null` = 没认出片头（**不覆盖**手标那一份）。
  ///
  /// 调用方要负责挡住「探测期间用户已经换集」这个竞态（比对 itemId /
  /// 片名），否则晚到的结果会让下一集顶着这一集的片头区间跳。
  void setChapter(IntroMarker? marker) => _chapter = marker;

  /// 播放头到了该跳的位置就返回**要跳到的位置**，否则 `null`。
  ///
  /// ## 为什么返回目标位置而不是一个 bool
  ///
  /// 因为它同时把「这一次已经跳过」置位掉了（[IntroSkip.shouldSkip] 的
  /// 第 2 条）。返回 bool 的话，调用方必须在 `seek` 之前记得自己置位 ——
  /// 而 `seek` 是一次异步往返，这期间位置流还会再报几条（都还在区间内），
  /// 晚置位会连发好几次 seek，表现是画面往前窜、进度条乱跳。
  /// 把置位收进这里，调用方就没有写错的机会。
  Duration? takeSkipTarget(Duration position) {
    if (!_enabled) return null;
    final m = marker;
    if (!IntroSkip.shouldSkip(
      position: position,
      marker: m,
      skipped: _skipped,
    )) {
      return null;
    }
    _skipped = true;
    return m!.end;
  }
}
