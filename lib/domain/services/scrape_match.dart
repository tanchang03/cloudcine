/// 刮削结果的匹配闸门 —— **宁可漏刮，也不要刮错**。
///
/// ## 为什么必须有这道闸门
///
/// 2026-10-01 实测：网盘目录
/// `/来自：分享/超z级z马z力z欧z银z河z大z电影aa(2026) 4K HDR & Dv/`
/// （片名被插了 `z` 做规避，真实片名是《超级马力欧银河大电影》）
/// 被刮成了 **《低俗小说》(1994)**。
///
/// 原因不是数据源错了，而是**代码从没校验过结果**：`TmdbScraper._searchOne`
/// 直接取 `results.first`。TMDB 的 `/search/movie` 是**模糊搜索** ——
/// 它返回的是「按相关度排序的猜测」，不是「精确命中」。查询词再离谱也可能
/// 有返回，于是「查不到」被静默地变成了「查到了另一部片子」。
///
/// 更荒谬的是：查询里明明带了 `year=2026`，而返回的是 1994 年的片子，
/// **代码完全没有察觉** —— 年份差 32 年，这是这里最廉价也最可靠的判据。
///
/// ## 两道闸门，都只看「查询词」与「结果」本身
///
///   1. **年份硬闸门**：两边都有年份且相差 ≥ [ScrapeMatch.maxYearGap] → 淘汰；
///   2. **标题相似度**：精确 / 前缀 / 包含 / 字符 bigram 的 Dice 系数。
///
/// ## 为什么是「宁可漏刮」
///
/// 漏刮只是没有在线海报（还有夸克缩略图兜底，用户仍看得到画面）；
/// 刮错是**静默地**把标题、简介、评分、海报全换成另一部片子的 ——
/// 用户要过很久才发现，而且会连带污染按作品聚合的视图。
/// 两者的代价不对称，所以阈值定得偏严，并且详情页留了「手动指定片名」
/// 那条人工通道给用户自己纠正。
library;

/// 归一化：只留小写字母数字与汉字。
///
/// 与 `DoubanScraper` 里候选打分用的归一化**必须同口径** ——
/// 两处不一致会出现「豆瓣选中了、TMDB 却拒了」这种极难排查的不一致。
String normalizeForMatch(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

final RegExp _cjkRe = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]');

bool _hasCjk(String s) => _cjkRe.hasMatch(s);

/// 两个标题的相似度，范围 `0..1`。
///
/// 分档而不是只算一个距离：三种情形在真实数据里都很常见，且各自需要不同的
/// 判定强度 —— 精确命中可以无条件接受，而「沾一点边」必须靠年份兜底。
double titleSimilarity(String a, String b) {
  final na = normalizeForMatch(a);
  final nb = normalizeForMatch(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;

  // 纯数字不是名字。前缀档的下界是 `0.65`，而「无条件接受」阈值是 `0.6` ——
  // 也就是说**只要短的是长的前缀，多短都会通过**。2026-10-02 实测事故：
  // 备用词 `182` 是希腊纪录片《1821: Οι Ήρωες》的前缀 → 0.9125 → 通过，
  // 整部家电维修教程被刮成了那部纪录片。
  //
  // 前缀档本身是对的（`仙逆` → `仙逆第一季` 正是它要救的），问题在于它把
  // 「数字」当成了「名字」：`182` 与 `1821` 之间没有任何语义关系。
  // 比例也分不开这两者（0.75 vs 0.40），只有字符类型能。
  //
  // ⚠️ 精确相等在上面已经返回 1 —— 所以片名就叫《2012》《1917》的电影
  // 照样刮得到，被挡掉的只是「数字靠沾边命中另一个数字」。
  if (_allDigits(na) || _allDigits(nb)) return 0;

  final shorter = na.length <= nb.length ? na : nb;
  final longer = na.length <= nb.length ? nb : na;
  final ratio = shorter.length / longer.length;

  // 前缀：`仙逆` → `仙逆第一季`。同一部作品的分季命名都落在这一档。
  if (longer.startsWith(shorter)) return 0.65 + 0.35 * ratio;
  // 包含：查询带副标题而结果只有主名（或反过来）。
  if (longer.contains(shorter)) return 0.55 + 0.25 * ratio;

  return _diceBigram(na, nb);
}

/// 字符 bigram 的 Dice 系数。用于「顺序不同但字符高度重合」的情形
/// （`The Wandering Earth II` 与 `Wandering Earth II The`）。
double _diceBigram(String a, String b) {  if (a.length < 2 || b.length < 2) return 0;
  final ba = _bigrams(a);
  final bb = _bigrams(b);
  if (ba.isEmpty || bb.isEmpty) return 0;

  final pool = <String, int>{};
  for (final g in bb) {
    pool[g] = (pool[g] ?? 0) + 1;
  }
  var inter = 0;
  for (final g in ba) {
    final n = pool[g] ?? 0;
    if (n > 0) {
      inter++;
      pool[g] = n - 1;
    }
  }
  return 2 * inter / (ba.length + bb.length);
}

List<String> _bigrams(String s) => [
      for (var i = 0; i + 1 < s.length; i++) s.substring(i, i + 2),
    ];

/// 归一化之后是不是一串纯数字。**数字不是名字** —— 见 [titleSimilarity]。
bool _allDigits(String s) => RegExp(r'^[0-9]+$').hasMatch(s);

/// 闸门结论。
enum ScrapeMatchVerdict {
  /// 通过。
  accept,

  /// 标题对不上（且年份不足以兜底）。
  rejectTitle,

  /// 年份差得太多。
  rejectYear,
}

/// 一次判定的结果。带上中间量，便于日志与测试断言「为什么」。
class ScrapeMatchResult {
  const ScrapeMatchResult(this.verdict, this.similarity, this.yearGap);

  final ScrapeMatchVerdict verdict;

  /// 最高标题相似度（`0..1`）。
  final double similarity;

  /// 年份差；任一边没有年份时为 `null`。
  final int? yearGap;

  bool get accepted => verdict == ScrapeMatchVerdict.accept;

  /// 给日志用的一句话。
  String get reason => switch (verdict) {
        ScrapeMatchVerdict.accept => '通过（相似度 ${similarity.toStringAsFixed(2)}'
            '${yearGap == null ? "" : "，年份差 $yearGap"}）',
        ScrapeMatchVerdict.rejectTitle =>
          '标题对不上（相似度 ${similarity.toStringAsFixed(2)}'
              '${yearGap == null ? "" : "，年份差 $yearGap"}）',
        ScrapeMatchVerdict.rejectYear => '年份差 $yearGap 年',
      };
}

/// 判定「这条结果配不配得上这个查询」。
///
/// [queryAlternateTitle] 是中文名搜不到时用的备用词（通常是英文名）。
/// 结果里的 `title` 与 `originalTitle` **都要比**：用英文名搜的时候，
/// `language=zh-CN` 会让结果标题是中文，而原名才是英文。
class ScrapeMatch {
  const ScrapeMatch._();

  /// 年份差达到这个数就淘汰。
  ///
  /// 定 2 而不是 1：发布组标「发行年」、数据源记「首播年」差一年是常态
  /// （与 `DoubanScraper` 的打分口径一致）。而本次事故是 32 年，
  /// 离阈值远得很 —— 这道闸门不会因为「差一年」误伤。
  static const int maxYearGap = 2;

  /// 到这个相似度就无条件接受。
  static const double strongSimilarity = 0.6;

  /// 到这个相似度算「沾边」，必须有年份兜底才接受。
  static const double weakSimilarity = 0.35;

  static ScrapeMatchResult evaluate({
    required String queryTitle,
    String? queryAlternateTitle,
    int? queryYear,
    required String resultTitle,
    String? resultOriginalTitle,
    int? resultYear,
  }) {
    final gap = (queryYear != null && resultYear != null)
        ? (queryYear - resultYear).abs()
        : null;

    // 1) 年份硬闸门。最廉价、最可靠 —— 本次事故就是被它抓到的。
    if (gap != null && gap >= maxYearGap) {
      return ScrapeMatchResult(ScrapeMatchVerdict.rejectYear, 0, gap);
    }

    // 2) 标题相似度：查询词 × 结果标题 两两比，取最高。
    final queries = <String>[
      queryTitle,
      if ((queryAlternateTitle ?? '').trim().isNotEmpty) queryAlternateTitle!,
    ];
    final results = <String>[
      resultTitle,
      if ((resultOriginalTitle ?? '').trim().isNotEmpty) resultOriginalTitle!,
    ];

    var best = 0.0;
    for (final q in queries) {
      for (final r in results) {
        final s = titleSimilarity(q, r);
        if (s > best) best = s;
      }
    }

    if (best >= strongSimilarity) {
      return ScrapeMatchResult(ScrapeMatchVerdict.accept, best, gap);
    }

    final yearClose = gap != null && gap <= 1;

    if (best >= weakSimilarity) {
      return ScrapeMatchResult(
        yearClose ? ScrapeMatchVerdict.accept : ScrapeMatchVerdict.rejectTitle,
        best,
        gap,
      );
    }

    // 3) 跨书写系统：用英文备用词搜的时候，结果是中文标题，两边的字符集
    //    毫无交集。这时标题相似度天然为 0，只能靠年份兜底 —— 而且
    //    **必须真的有年份**，否则等于没有判据。
    if (_crossScript(queryTitle, resultTitle) && yearClose) {
      return ScrapeMatchResult(ScrapeMatchVerdict.accept, best, gap);
    }

    return ScrapeMatchResult(ScrapeMatchVerdict.rejectTitle, best, gap);
  }

  /// 一边有汉字、另一边没有。
  static bool _crossScript(String a, String b) => _hasCjk(a) != _hasCjk(b);
}
