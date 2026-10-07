package com.cloudcine.tv.library

/**
 * 刮削的**三个模型**。
 *
 * ⛔ 与 PC 端 `domain/services/scraper.dart` 里的 `ScrapedMetadata` /
 *    `ScrapeCandidate` / `ScrapeQuery` 是同一组概念，字段口径必须对齐 ——
 *    刮削结果最终要写进**两端共用的那张 `media_works` 表**，任何一边多一个
 *    「只有自己懂的」字段，另一边读出来就是 null。
 *
 * ⛔ 与 [ScanItem] / [Work] 的分工：那两个是**库的写模型 / 读模型**，
 *    这里的是**网络层的模型** —— 它描述的是「数据源给了我们什么」，
 *    还没跟库里已有的行合并（合并是 `LibraryDb.updateWorkScrape` 的事）。
 */

/** 元数据的来源。 */
enum class ScrapeSource(val id: String) {
    /**
     * 在线刮削（豆瓣 / TMDB）。
     *
     * ⛔ `media_works.source = 'online'` 是「已刮削」的**唯一判据**
     *    （PC 端 `work_detail_page` 与 Android 端筛选项都按它算）。
     *    写错这一列，用户会看到「已刮削」但海报简介一个都没有。
     */
    online("online"),

    /**
     * 文件名解析（本地兜底）。
     *
     * ⚠️ Android 端**不产出**这个值：本地兜底那条路是 PC 端
     *    `LocalFilenameScraper` 的职责，而它在扫描期就已经把片名写进
     *    `media_works.title` 了。留着这个枚举值是为了让
     *    [ScrapedMetadata.source] 与 PC 端同形，避免将来合并两端代码时
     *    出现「这边少一个取值」。
     */
    local("local");

    companion object {
        /** 认不出来时退回 [online]（在线结果才是刮削的常态）。 */
        fun parse(raw: String?): ScrapeSource =
            entries.firstOrNull { it.id == raw } ?: online
    }
}

/**
 * 一条**搜索候选** —— 手动刮削列表里的一行。
 *
 * ⛔ 候选里**没有完整元数据**：豆瓣的搜索结果既没有完整海报也没有简介，
 *    必须用户选中之后再打一次详情接口（见 [MetadataScraper.resolve]）。
 *    所以这个类刻意只有「让用户认出这是哪一部」所需要的字段。
 */
data class ScrapeCandidate(
    /** 源 id：`tmdb` / `douban`。与 [MetadataScraper.id] 同一个取值域。 */
    val source: String,
    /** 源内的条目 id。豆瓣是数字串，TMDB 也是 —— 都当**字符串**存。 */
    val sourceId: String,
    val title: String,
    val year: Int?,
    /** `movie` / `tv`。源认不出时 `null`（不是「其它」，是「这条证据没意见」）。 */
    val type: String?,
    /** 列表里画的那张小图。**不等于海报**（见豆瓣那条 120px 横条的坑）。 */
    val posterUrl: String?,
    val overview: String? = null,
) {
    /** 列表行副标题：`2023 · 剧集`。 */
    val subtitle: String
        get() = buildString {
            if (year != null && year > 0) append(year)
            val t = when (type) {
                "tv" -> "剧集"
                "movie" -> "电影"
                else -> null
            }
            if (t != null) {
                if (isNotEmpty()) append(" · ")
                append(t)
            }
        }

    /** 候选的唯一键（去重 / 选中态判断用）。 */
    val uid: String get() = "$source/$sourceId"
}

/**
 * 刮到的**完整元数据**。
 *
 * ⛔ 字段名与 `media_works` 的列一一对应（`posterUrl` → `poster_url`、
 *    `onlineId` → `online_id`），写库时不做过多的名字翻译 —— 翻译层越多，
 *    「刮到的东西没进库」这类静默问题越难查。
 */
data class ScrapedMetadata(
    val title: String,
    /** 外语原名。豆瓣对国产片给空串（不是缺失），由调用方按空处理。 */
    val originalTitle: String? = null,
    val year: Int? = null,
    val overview: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val rating: Double? = null,
    val genres: List<String> = emptyList(),
    /**
     * 在线条目的全局 id，形如 `douban/tv/34874646` / `tmdb/movie/843527`。
     *
     * ⛔ 中间那一段（`movie` / `tv`）是**类型证据**：手动刮削时用户在候选里
     *    亲手确认过条目，那时「这条是电影还是剧集」比文件名结构可信 ——
     *    文件名只剩 `2026.2160p.WEB-DL.mkv` 时结构上认不出（会落到「其他」），
     *    而这一条能把它救回来。见 [structureOf]。
     */
    val onlineId: String? = null,
    val source: ScrapeSource = ScrapeSource.online,
    /** 实际用于命中的查询词。排查「刮错了片子」时先看它 —— 多半是解析错了。 */
    val matchedQuery: String? = null,
)

/**
 * 一次刮削的查询。
 *
 * ⛔ 与 [ScrapeCandidate] 一样是**网络层的形状**，不是库里的行。
 */
data class ScrapeQuery(
    val title: String,
    val year: Int? = null,
    /**
     * 文件名解析出来的结构：`movie` / `episode` / `unknown`。
     *
     * ⛔ 它是 [MediaNameParser.Parsed.kind] 的取值，**不是** `movie`/`tv`
     *    那套（那是条目结构）。两者混用会让「综艺」这类既不是电影也不是剧集的
     *    东西被硬塞进某一栏 —— 转换在 [wantsTv] 里做，且**只在明确时**才转。
     */
    val kind: String? = null,
) {
    /**
     * 搜索时该偏重「剧集」还是「电影」。
     *
     * `null` = **不偏**（两个都搜）。⛔ 这很重要：综艺、纪录片这类在
     *    [MediaNameParser] 里常常落到 `unknown`，硬猜一个方向会把它们
     *    搜到完全无关的条目上。
     */
    val wantsTv: Boolean? get() = when (kind) {
        "episode" -> true
        "movie" -> false
        else -> null
    }
}

/**
 * 在线条目 id 的**结构**解析。
 *
 * ⛔ 按**段**匹配而不是 `startsWith`：豆瓣那条多一层前缀
 *    （`douban/movie/678`），`startsWith("movie/")` 会漏掉它。
 *
 * 认不出来返回 `null` —— 那是「这条证据没意见」，不是「归到其他」。
 */
fun structureOf(onlineId: String?): String? {
    val id = onlineId?.trim()?.lowercase().orEmpty()
    if (id.isEmpty()) return null
    val parts = id.split('/')
    if (parts.contains("tv")) return "tv"
    if (parts.contains("movie")) return "movie"
    return null
}

/**
 * 一个元数据刮削器。
 *
 * 与 PC 端 `MetadataScraper` 同一份契约，但有**一处刻意的收窄**：
 * Android 端不实现本地兜底（理由见 [ScrapeSource.local]），所以这里只有
 * 「在线源」这一种实现。
 *
 * ⛔ 两个方法的失败语义都是「返回空 / `null`，**不抛异常**」：
 *    一部片子刮不到不该让整个界面崩掉，而网络抖动、限流、条目被删
 *    都属于「刮不到」。
 */
interface MetadataScraper {
    /** 稳定标识（`tmdb` / `douban`）。⛔ 它同时是 [ScrapeCandidate.source] 的取值。 */
    val id: String

    /** 展示名（「TMDB」「豆瓣」）。 */
    val displayName: String

    /**
     * 是否可用（在线源要检查 Key / Cookie 配了没有）。
     *
     * ⛔ 不可用时返回 `false` 而**不是抛异常** —— 上层据此跳过它，
     *    让整次刮削降级（少一个源）而不是失败。
     */
    val enabled: Boolean

    /**
     * 按关键词搜一批候选，供**用户手动挑选**。
     *
     * ⛔ 这里**不做匹配校验、也不自动选第一条** —— 用户要看到尽可能多的
     *    候选自己点。返回空列表表示「这个源给不出候选」，而不是「搜索失败」。
     */
    fun search(query: ScrapeQuery): List<ScrapeCandidate>

    /** 把用户选中的候选解析成完整元数据。取不到返回 `null`。 */
    fun resolve(candidate: ScrapeCandidate): ScrapedMetadata?
}

/**
 * 「测试凭证」的结论 —— 刮削设置页那两个测试按钮的回话。
 *
 * ## 为什么要有它（而不是「成功/失败」两个状态）
 *
 * 刮不到东西时，用户眼里只有一种现象，但底下至少有**三种互不相同**的原因：
 *
 *   * **地址不通** —— 境内直连 TMDB 官方地址会被 DNS 污染，请求一直挂到超时；
 *   * **凭证被拒** —— Key 填错 / 已失效 / 送法不对（见 `TmdbScraper.isV4Token`）；
 *   * **被限流** —— 豆瓣匿名额度约 10 个搜索词，耗尽后回 `103 need_login`。
 *
 * 三者对「下一步该改什么」的指向完全不同（换地址 / 换 Key / 贴 Cookie）。
 * 不把它们分开，用户只能反复重贴同一个串 —— 这正是 2026-10-07 那次
 * 「有 token 和 cookie 为啥还是失败」的全部内容。
 *
 * [message] 是**给人看的一整句话**，不是错误码：设置页直接把它显示出来，
 * 所以它必须自己说清「哪一层挂了、下一步干什么」。
 */
data class ScrapeProbe(
    /** 凭证可用。⛔ 只有**明确验证过**才为 `true`，拿不准一律 `false`。 */
    val ok: Boolean,
    /** 直接展示给用户的一整句结论。 */
    val message: String,
)
