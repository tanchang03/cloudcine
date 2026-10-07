package com.cloudcine.tv.library

/**
 * 刮削结果的匹配闸门 —— **宁可漏刮，也不要刮错**。
 *
 * ## 为什么必须有这道闸门
 *
 * PC 端 2026-10-01 实测事故：网盘目录
 * `/来自：分享/超z级z马z力z欧z银z河z大z电影aa(2026) 4K HDR & Dv/`
 * （片名被插了 `z` 做规避，真实片名是《超级马力欧银河大电影》）
 * 被刮成了 **《低俗小说》(1994)**。
 *
 * 原因不是数据源错了，而是**代码从没校验过结果**：`TmdbScraper._searchOne`
 * 直接取 `results.first`。TMDB 的 `/search/movie` 是**模糊搜索** ——
 * 它返回的是「按相关度排序的猜测」，不是「精确命中」。查询词再离谱也可能
 * 有返回，于是「查不到」被静默地变成了「查到了另一部片子」。
 *
 * 更荒谬的是：查询里明明带了 `year=2026`，而返回的是 1994 年的片子，
 * **代码完全没有察觉** —— 年份差 32 年，这是这里最廉价也最可靠的判据。
 *
 * ## 为什么 Android 端现在才需要它
 *
 * 手动刮削**不需要**闸门：候选是用户自己挑的，他做过判断了。所以
 * `ScrapeActivity` 一直没用它。而「扫描后自动刮削」是**无人值守**的 ——
 * 它必须自己决定「这一条配不配得上这个查询词」。没有闸门就上自动刮削，
 * 等于把这个事故复制到整库（145 部作品，错一部用户很久才发现）。
 *
 * ## 两道闸门，都只看「查询词」与「结果」本身
 *
 *   1. **年份硬闸门**：两边都有年份且相差 >= [ScrapeMatch.MAX_YEAR_GAP] → 淘汰；
 *   2. **标题相似度**：精确 / 前缀 / 包含 / 字符 bigram 的 Dice 系数。
 *
 * ## 无年份的电影走第三道：**只认精确同名**
 *
 * 上面第 1 道在「查询侧没年份」时**完全失效**，于是只剩标题相似度。而
 * 第 2 道的 0.6 档是**为「有年份」定的**，前缀档（0.65+）在那里无条件通过
 * —— 无年份时它会把 `奥德赛` 配到 `奥德赛：归来`、`英雄` 配到 `英雄本色`。
 * 所以这类查询改用 [ScrapeMatch.evaluate] 的 `requireExactTitle`：精确同名才放行，
 * 且由调用方再加「排第一位」。命中不了就退回手动通道 ——
 * 与「宁可漏刮」同一条口径。
 *
 * ## 为什么是「宁可漏刮」
 *
 * 漏刮只是没有在线海报（还有夸克缩略图兜底，用户仍看得到画面）；
 * 刮错是**静默地**把标题、简介、评分、海报全换成另一部片子的 ——
 * 用户要过很久才发现，而且会连带污染按作品聚合的视图。
 * 两者的代价不对称，所以阈值定得偏严，并且详情页留了「手动指定片名」
 * 那条人工通道给用户自己纠正。
 *
 * ⛔ 口径与 PC 端 `lib/domain/services/scrape_match.dart` **逐条对齐**：
 *    两边算出的相似度只要差一点，同一个作品在电脑上刮得到、在电视上刮不到
 *    （或反过来），而这是**静默的**。
 */

/**
 * 归一化：只留小写字母数字与汉字。
 *
 * 与 `DoubanScraper` 里候选打分用的归一化**必须同口径** ——
 * 两处不一致会出现「豆瓣选中了、TMDB 却拒了」这种极难排查的不一致。
 */
fun normalizeForMatch(s: String): String =
    s.lowercase().replace(Regex("[^a-z0-9\\u4e00-\\u9fff]"), "")

private val CJK_RE = Regex("[\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff]")

private fun hasCjk(s: String): Boolean = CJK_RE.containsMatchIn(s)

/**
 * 两个标题的相似度，范围 `0..1`。
 *
 * 分档而不是只算一个距离：三种情形在真实数据里都很常见，且各自需要不同的
 * 判定强度 —— 精确命中可以无条件接受，而「沾一点边」必须靠年份兜底。
 */
fun titleSimilarity(a: String, b: String): Double {
    val na = normalizeForMatch(a)
    val nb = normalizeForMatch(b)
    if (na.isEmpty() || nb.isEmpty()) return 0.0
    if (na == nb) return 1.0

    // 纯数字不是名字。前缀档的下界是 `0.65`，而「无条件接受」阈值是 `0.6` ——
    // 也就是说**只要短的是长的前缀，多短都会通过**。PC 端 2026-10-02 实测事故：
    // 备用词 `182` 是希腊纪录片《1821: Οι Ήρωες》的前缀 → 0.9125 → 通过，
    // 整部家电维修教程被刮成了那部纪录片。
    //
    // 前缀档本身是对的（`仙逆` → `仙逆第一季` 正是它要救的），问题在于它把
    // 「数字」当成了「名字」：`182` 与 `1821` 之间没有任何语义关系。
    // 比例也分不开这两者（0.75 vs 0.40），只有字符类型能。
    //
    // ⚠️ 精确相等在上面已经返回 1 —— 所以片名就叫《2012》《1917》的电影
    // 照样刮得到，被挡掉的只是「数字靠沾边命中另一个数字」。
    if (allDigits(na) || allDigits(nb)) return 0.0

    val shorter = if (na.length <= nb.length) na else nb
    val longer = if (na.length <= nb.length) nb else na
    val ratio = shorter.length.toDouble() / longer.length

    // 前缀：`仙逆` → `仙逆第一季`。同一部作品的分季命名都落在这一档。
    if (longer.startsWith(shorter)) return 0.65 + 0.35 * ratio
    // 包含：查询带副标题而结果只有主名（或反过来）。
    if (longer.contains(shorter)) return 0.55 + 0.25 * ratio

    return diceBigram(na, nb)
}

/**
 * 字符 bigram 的 Dice 系数。用于「顺序不同但字符高度重合」的情形
 * （`The Wandering Earth II` 与 `Wandering Earth II The`）。
 */
private fun diceBigram(a: String, b: String): Double {
    if (a.length < 2 || b.length < 2) return 0.0
    val ba = bigrams(a)
    val bb = bigrams(b)
    if (ba.isEmpty() || bb.isEmpty()) return 0.0

    val pool = HashMap<String, Int>(bb.size * 2)
    for (g in bb) pool[g] = (pool[g] ?: 0) + 1
    var inter = 0
    for (g in ba) {
        val n = pool[g] ?: 0
        if (n > 0) {
            inter++
            pool[g] = n - 1
        }
    }
    return 2.0 * inter / (ba.size + bb.size)
}

private fun bigrams(s: String): List<String> =
    (0 until s.length - 1).map { s.substring(it, it + 2) }

/** 归一化之后是不是一串纯数字。**数字不是名字** —— 见 [titleSimilarity]。 */
private fun allDigits(s: String): Boolean = s.isNotEmpty() && s.all { it in '0'..'9' }

/** 闸门结论。 */
enum class ScrapeMatchVerdict {
    /** 通过。 */
    accept,

    /** 标题对不上（且年份不足以兜底）。 */
    rejectTitle,

    /** 年份差得太多。 */
    rejectYear,
}

/**
 * 一次判定的结果。带上中间量，便于日志与测试断言「为什么」。
 */
class ScrapeMatchResult(
    val verdict: ScrapeMatchVerdict,
    /** 最高标题相似度（`0..1`）。 */
    val similarity: Double,
    /** 年份差；任一边没有年份时为 `null`。 */
    val yearGap: Int?,
) {
    val accepted: Boolean get() = verdict == ScrapeMatchVerdict.accept

    /** 给日志用的一句话。 */
    val reason: String
        get() = when (verdict) {
            ScrapeMatchVerdict.accept ->
                "通过（相似度 ${"%.2f".format(similarity)}" +
                    (if (yearGap == null) "" else "，年份差 $yearGap") + "）"
            ScrapeMatchVerdict.rejectTitle ->
                "标题对不上（相似度 ${"%.2f".format(similarity)}" +
                    (if (yearGap == null) "" else "，年份差 $yearGap") + "）"
            ScrapeMatchVerdict.rejectYear -> "年份差 $yearGap 年"
        }
}

/**
 * 判定「这条结果配不配得上这个查询」。
 *
 * [queryAlternateTitle] 是中文名搜不到时用的备用词（通常是英文名）。
 * 结果里的 `title` 与 `originalTitle` **都要比**：用英文名搜的时候，
 * `language=zh-CN` 会让结果标题是中文，而原名才是英文。
 *
 * ## 两档判据
 *
 *   - **严格档**（[requireExactTitle] 为 `false`，默认）：年份硬闸门 +
 *     标题相似度分档（[STRONG_SIMILARITY] / [WEAK_SIMILARITY]）。适用于
 *     「查询里带年份」或「剧集（季集号自能定位）」；
 *   - **宽松档**（[requireExactTitle] 为 `true`）：**只认精确同名**。
 *     适用于无年份的电影 —— 它没有年份可消歧，沿用 0.6 档会让前缀误配
 *     无条件通过（`奥德赛` → `奥德赛：归来` 0.86）。见 [ScrapeQuery.requireExactTitle]。
 *
 * ⚠️ 宽松档只解决「闸门放不放行」，**不解决歧义**：多条精确同名
 * （PC 端实测「奥德赛」TMDB 4 条、豆瓣 2 条）时闸门本身分辨不了，
 * 得由调用方加「**第一位**必须是精确同名」这条。
 */
object ScrapeMatch {

    /**
     * 年份差达到这个数就淘汰。
     *
     * 定 2 而不是 1：发布组标「发行年」、数据源记「首播年」差一年是常态
     * （与 `DoubanScraper` 的打分口径一致）。而那次事故是 32 年，
     * 离阈值远得很 —— 这道闸门不会因为「差一年」误伤。
     */
    const val MAX_YEAR_GAP = 2

    /**
     * 到这个相似度就无条件接受。
     *
     * ⚠️ **只在严格档生效**。它是**为「有年份」定的档** —— 那里有年份硬闸门
     * 兜底，标题相似度只是辅助，所以前缀档可以放得松。无年份的电影走
     * [requireExactTitle] 那条（精确同名），**不用**这个阈值。
     */
    const val STRONG_SIMILARITY = 0.6

    /**
     * 到这个相似度算「沾边」，必须有年份兜底才接受。
     *
     * ⚠️ 同样**只在严格档生效**。
     */
    const val WEAK_SIMILARITY = 0.35

    fun evaluate(
        queryTitle: String,
        resultTitle: String,
        queryAlternateTitle: String? = null,
        queryYear: Int? = null,
        resultOriginalTitle: String? = null,
        resultYear: Int? = null,
        requireExactTitle: Boolean = false,
    ): ScrapeMatchResult {
        val gap = if (queryYear != null && resultYear != null) {
            kotlin.math.abs(queryYear - resultYear)
        } else {
            null
        }

        // 1) 年份硬闸门。最廉价、最可靠 —— 那次事故就是被它抓到的。
        if (gap != null && gap >= MAX_YEAR_GAP) {
            return ScrapeMatchResult(ScrapeMatchVerdict.rejectYear, 0.0, gap)
        }

        // 2) 标题相似度：查询词 × 结果标题 两两比，取最高。
        val queries = ArrayList<String>(2).apply {
            add(queryTitle)
            if (!queryAlternateTitle.isNullOrBlank()) add(queryAlternateTitle)
        }
        val results = ArrayList<String>(2).apply {
            add(resultTitle)
            if (!resultOriginalTitle.isNullOrBlank()) add(resultOriginalTitle)
        }

        var best = 0.0
        for (q in queries) {
            for (r in results) {
                val s = titleSimilarity(q, r)
                if (s > best) best = s
            }
        }

        // 3) **宽松档**（无年份的电影）：只认**精确同名**。
        //
        //    `titleSimilarity == 1` 当且仅当归一化后完全相等（见那边的实现：
        //    相等早退返回 1，其余各档都够不到 1）。
        //
        //    为什么不能沿用下面的 0.6 档：那个阈值是**为「有年份」定的**
        //    —— 那里的主力判据是上面的年份硬闸门，标题相似度只是辅助。
        //    没有年份时它挡不住前缀误配：PC 端实测 `奥德赛` → `奥德赛：归来`
        //    0.86、`英雄` → `英雄本色` 0.825，全部无条件通过 —— 而那正是
        //    「静默刮错」。
        if (requireExactTitle) {
            return ScrapeMatchResult(
                if (best >= 1.0) ScrapeMatchVerdict.accept else ScrapeMatchVerdict.rejectTitle,
                best,
                gap,
            )
        }

        if (best >= STRONG_SIMILARITY) {
            return ScrapeMatchResult(ScrapeMatchVerdict.accept, best, gap)
        }

        val yearClose = gap != null && gap <= 1

        if (best >= WEAK_SIMILARITY) {
            return ScrapeMatchResult(
                if (yearClose) ScrapeMatchVerdict.accept else ScrapeMatchVerdict.rejectTitle,
                best,
                gap,
            )
        }

        // 3) 跨书写系统：用英文备用词搜的时候，结果是中文标题，两边的字符集
        //    毫无交集。这时标题相似度天然为 0，只能靠年份兜底 —— 而且
        //    **必须真的有年份**，否则等于没有判据。
        if (crossScript(queryTitle, resultTitle) && yearClose) {
            return ScrapeMatchResult(ScrapeMatchVerdict.accept, best, gap)
        }

        return ScrapeMatchResult(ScrapeMatchVerdict.rejectTitle, best, gap)
    }

    /** 一边有汉字、另一边没有。 */
    private fun crossScript(a: String, b: String): Boolean = hasCjk(a) != hasCjk(b)
}
