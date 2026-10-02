import 'dart:convert';

/// 一个「片头区间」。
///
/// 两种来源，**优先级由调用方定**（`IntroMarkerDetector` 只负责识别文件里的
/// 那个，库里手标的那个由仓储读出来）：
///   - 文件自带的章节标记（MKV 的 chapter，名字像 `Opening` / `片头`）；
///   - 用户在播放器里手标一次、落库到「作品」的那一份。
///
/// 精度只到秒级：跳过片头本来就是「别让我看这 90 秒」，差 0.3 秒没有意义，
/// 而秒级能让它落库成一个干净的整数（毫秒列）。
class IntroMarker {
  const IntroMarker({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get length => end - start;

  /// 区间是否成立。
  ///
  /// ⚠️ **每个使用点都必须先过这一关**。反过来的区间（`end <= start`）不会
  /// 报错，只会让「跳过片头」变成一次**向后跳** —— 用户看到的是画面突然倒回
  /// 片头，然后卡在那儿，比不跳糟得多。
  bool get isValid => end > start;

  bool contains(Duration position) => position >= start && position < end;

  /// 从数据库里的毫秒值构造。
  ///
  /// 任何一个为 `null` / 非正数 / 区间不成立 → `null`（＝「这一部没有片头标记」）。
  /// 把「半条标记」（只标了起点没标终点）也当没有：半个区间没法跳。
  static IntroMarker? fromMilliseconds(int? startMs, int? endMs) {
    if (startMs == null || endMs == null) return null;
    if (startMs < 0 || endMs <= 0) return null;
    final marker = IntroMarker(
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
    );
    return marker.isValid ? marker : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntroMarker && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() =>
      'IntroMarker(${start.inSeconds}s→${end.inSeconds}s)';
}

/// 容器里的一个章节标记。
///
/// 只保留「名字」与「起点」：mpv 的 `chapter-list` **不给终点** ——
/// 一个章节的终点就是**下一个章节的起点**，最后一个章节的终点是片长。
/// 所以「片头到哪儿结束」这件事只能靠下一个章节推出来，而最后一个章节
/// 永远推不出终点（见 [IntroMarkerDetector.detect]）。
class IntroChapter {
  const IntroChapter({required this.title, required this.start});

  final String title;
  final Duration start;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntroChapter && other.title == title && other.start == start;

  @override
  int get hashCode => Object.hash(title, start);

  @override
  String toString() => 'IntroChapter("$title" @${start.inSeconds}s)';
}

/// mpv `chapter-list` 属性的解析。
///
/// ## 格式是**量出来的**，不是猜的
///
/// 2026-10-02 用产物里的**真** libmpv（`Mpv.framework`，用 Python ctypes
/// 拉起，`vo=null ao=null`）打开一个带 3 个章节的 mkv，`mpv_get_property_string
/// ("chapter-list")` 读回来是：
///
/// ```
/// [{"title":"Opening","time":-0.023000},{"title":"Part A","time":9.977000},
///  {"title":"Ending","time":39.977000}]
/// ```
///
/// 三条实测结论，每条都影响这里的写法：
///
///   1. **就是合法 JSON**（mpv 把 node 转字符串时按 JSON 写）。所以主路径是
///      `jsonDecode`，正则只是兜底 —— 上一版凭「mpv 的 node 字符串形式大概
///      不是标准 JSON」的推断写正则，是错的方向。
///   2. **没有章节时返回 `[]`**，不是空串、也不是 null。而且**打开文件之前
///      也是 `[]`** —— 也就是说「还没解析完」与「这个文件就是没章节」在字符串
///      上**无法区分**。所以读取时机必须落在容器解析完成之后（播放器那边用
///      「position 已经大于 0」当信号），读早了会把「还没解析」当成「没有」。
///   3. `time` 可以是**负数**（首章实测 `-0.023`，容器时间戳有偏移）。夹到 0。
abstract final class MpvChapterList {
  const MpvChapterList._();

  /// 解析 mpv 给的那串 JSON。**任何畸形输入都返回空列表，不抛异常** ——
  /// 「章节读不出来」只该让跳片头不生效，不该把播放搞挂。
  static List<IntroChapter> parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text == '[]') return const [];

    final decoded = _tryDecodeJson(text);
    if (decoded != null) return decoded;

    // 兜底：万一某个版本的 mpv 换了排版（比如不写引号、或者写成
    // `title=Opening`），按「title/time 成对出现」硬扫一遍。宁可少认几个章节，
    // 也不要因为格式变了就整条路失效。
    return _parseLoose(text);
  }

  static List<IntroChapter>? _tryDecodeJson(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! List) return null;
      final out = <IntroChapter>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final title = item['title'];
        final time = item['time'];
        final seconds = time is num ? time.toDouble() : null;
        if (seconds == null) continue;
        out.add(
          IntroChapter(
            title: title is String ? title : '',
            // 负时间夹到 0：见类文档第 3 条。
            start: _secondsToDuration(seconds),
          ),
        );
      }
      return out;
    } on FormatException {
      return null;
    }
  }

  /// 秒（可为负 / 可为小数）→ 时长。负数一律当 0。
  static Duration _secondsToDuration(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return Duration.zero;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// 兜底用的两个模式。
  ///
  /// 写成 `title["\s]*[:=]` 而不是 `title"?:`，是为了**同时**吃下 JSON 排版
  /// （`"title":"Opening"`）与「键值对」排版（`title="Opening"`）——
  /// 兜底路径存在的意义就是「格式变了还能用」，只认一种等于没兜住。
  static final RegExp _titlePattern =
      RegExp(r'title["\s]*[:=]\s*"([^"]*)"');
  static final RegExp _timePattern = RegExp(r'time["\s]*[:=]\s*(-?[\d.]+)');

  static List<IntroChapter> _parseLoose(String text) {
    final titles = _titlePattern.allMatches(text).map((m) => m.group(1)!).toList();
    final times = _timePattern
        .allMatches(text)
        .map((m) => double.tryParse(m.group(1)!))
        .toList();

    final out = <IntroChapter>[];
    for (var i = 0; i < times.length; i++) {
      final seconds = times[i];
      if (seconds == null) continue;
      out.add(
        IntroChapter(
          title: i < titles.length ? titles[i] : '',
          start: _secondsToDuration(seconds),
        ),
      );
    }
    return out;
  }
}

/// 从章节清单里认出「片头」。
abstract final class IntroMarkerDetector {
  const IntroMarkerDetector._();

  /// 命中即认为是片头的关键词（**全小写**，比对前会把标题也转小写）。
  ///
  /// ## 为什么中文词按「包含」、英文词按「词边界」
  ///
  /// 中文没有词边界，`片头曲` / `片头` / `[片头]` 都该命中，所以按包含比对。
  /// 英文则**必须卡词边界** —— 这个坑本项目踩过一次（`ova` 会命中
  /// `Nova.2023`）：`op` 作为子串会命中 `Operation`、`Chapter 01 Opening`
  /// 倒是没问题，但 `Reopen` 就会被误判。所以英文词用
  /// [RegExp] 的 `\b` 卡住。
  ///
  /// ## 刻意**不**包含的词
  ///
  ///   - `前情提要`：中文剧集里它确实常在片头位置，但它**不是片头**
  ///     （很多用户会跳片头但会看前情提要）。把它算进来等于替用户做了
  ///     一个他没要求的决定，而且跳错了没有任何提示。
  ///   - `片尾` / `ending` / `preview` / `预告`：这些是**片尾**，
  ///     跳过它们是另一个功能（而且「跳片尾」应当直接跳下一集，
  ///     与「跳片头」的落点完全不同）。
  static const List<String> chineseKeywords = [
    '片头',
    '片头曲',
    '开场',
    '序幕',
    '主题曲',
  ];

  /// 英文 / 日文关键词。比对时按 `\b` 词边界匹配（理由见上）。
  ///
  /// `ncop` 单独列一条而不是靠 `op` 命中：「无字幕片头」在番剧片源里写作
  /// `NCOP`，而 `\bop\b` **匹配不到它**（C 与 O 之间没有词边界）。
  /// 这正是「短词卡边界」的代价 —— 边界挡住了 `Operation`，也挡住了 `NCOP`，
  /// 只能把真正常见的那一个显式补回来。
  static const List<String> asciiKeywords = [
    'intro',
    'opening',
    'op',
    'ncop',
    'opening credits',
    'main title',
    'title sequence',
    'オープニング',
  ];

  static final List<RegExp> _asciiPatterns = [
    for (final k in asciiKeywords)
      // `\b` 对 `op` 这种短词是必需的；对 `オープニング` 这类非 ASCII
      // 词，`\b` 在 Dart 里按 ASCII 词字符判定，所以单独一条不做边界。
      k.codeUnits.any((c) => c > 0x7f)
          ? RegExp(RegExp.escape(k), caseSensitive: false)
          : RegExp('\\b${RegExp.escape(k)}\\b', caseSensitive: false),
  ];

  /// 章节名看起来像片头吗。
  static bool looksLikeIntro(String title) {
    final t = title.trim();
    if (t.isEmpty) return false;
    final lower = t.toLowerCase();
    for (final k in chineseKeywords) {
      if (lower.contains(k)) return true;
    }
    for (final p in _asciiPatterns) {
      if (p.hasMatch(t)) return true;
    }
    return false;
  }

  /// 片头章节起点的上界。**再晚就不是片头了。**
  ///
  /// 一集电视剧的片头总在开头，15 分钟这个值取得很宽松（连「冷开场 10 分钟
  /// 的长片头」都容得下）。它的作用是挡住「某个章节恰好叫 Opening，但它其实
  /// 是第 40 分钟的一整段」这种误判 —— 那种情况下跳过去会让用户直接丢掉
  /// 半集内容，是**不可逆**的伤害。
  static const Duration maxStart = Duration(minutes: 15);

  /// 片头区间的长度上下界。
  ///
  ///   - 下界 5 秒：比这更短的「片头」跳过去毫无意义，只是让画面抖一下；
  ///   - 上界 10 分钟：正常片头 30 秒 ~ 3 分钟。一个长达十几分钟的「Opening」
  ///     章节更可能是把正片整段命名成了 Opening，跳过去等于丢一集内容。
  static const Duration minLength = Duration(seconds: 5);
  static const Duration maxLength = Duration(minutes: 10);

  /// 从章节清单里推出片头区间；认不出来返回 `null`。
  ///
  /// ## 为什么必须有「下一个章节」
  ///
  /// mpv 的 `chapter-list` **不给章节终点**（见 [IntroChapter]）。片头到哪儿
  /// 结束只能取**下一个章节的起点**。所以：
  ///   - 片头章节是**最后一个**章节时 → 认不出来（没有下一个）。
  ///     这时宁可什么都不做：拿片长当终点会跳掉后面全部内容。
  ///   - 命中多个片头章节时取**第一个**（`Opening` 之后可能还有个
  ///     `Opening 2`，第一个才是要跳的那个）。
  static IntroMarker? detect(List<IntroChapter> chapters) {
    if (chapters.length < 2) return null;

    for (var i = 0; i < chapters.length - 1; i++) {
      final chapter = chapters[i];
      if (!looksLikeIntro(chapter.title)) continue;

      final marker = IntroMarker(start: chapter.start, end: chapters[i + 1].start);
      if (!_isPlausible(marker)) continue;
      return marker;
    }
    return null;
  }

  static bool _isPlausible(IntroMarker marker) {
    if (!marker.isValid) return false;
    if (marker.start > maxStart) return false;
    if (marker.length < minLength) return false;
    if (marker.length > maxLength) return false;
    return true;
  }
}

/// 「现在该不该跳片头」的判定。
///
/// 抽成纯函数是因为它要在**两个播放器**里各用一遍（内置播放页 + 独立播放
/// 窗口），而这两处跑在不同的引擎里、够不到对方的代码（见 `PlayerWindowApp`
/// 的类文档）。判定散成两份，就会变成「内置页跳得对、独立窗口跳得怪」。
abstract final class IntroSkip {
  const IntroSkip._();

  /// 需要跳到 [IntroMarker.end] 时返回 true。
  ///
  /// ## 五个条件，缺一不可
  ///
  ///   1. 有标记，且区间成立（[IntroMarker.isValid]）；
  ///   2. **本次播放还没跳过** —— 这条是「跳一次」的实现方式。少了它，
  ///      用户手动把进度条拖回片头想看 OP 时会被立刻再推走一次，
  ///      而且每次 position 回调都会推一次（表现为画面疯狂往前窜）；
  ///   3. 播放头已经进到区间里（`position >= start`）；
  ///   4. 还没走到区间末尾（`position < end - minRemaining`）—— 快到了就别跳，
  ///      否则「跳过」只是一次原地抖动，还会白触发一次 seek；
  ///   5. 时长未知（`Duration.zero`）时**不跳**：那是流还没解析完，
  ///      此时 `position` 不可信。
  static bool shouldSkip({
    required Duration position,
    required IntroMarker? marker,
    required bool skipped,
    Duration minRemaining = const Duration(seconds: 1),
  }) {
    if (marker == null || !marker.isValid) return false;
    if (skipped) return false;
    if (position <= Duration.zero) return false;
    if (position < marker.start) return false;
    if (position >= marker.end - minRemaining) return false;
    return true;
  }
}
