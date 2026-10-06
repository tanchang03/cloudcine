package com.cloudcine.tv.library

/**
 * 没有在线刮削结果时，靠**目录名 / 片名 / 结构**猜分类 ——
 * 移植 PC 端 `lib/core/utils/media_category.dart` 的 `MediaCategoryGuesser`。
 *
 * ## 为什么必须能离线判定
 *
 * 本项目的硬约束是「本地解析永远可用，在线刮削是增强」。分类如果不满足这一条，
 * 那么没配刮削来源的用户看到的媒体库会是**一整个「其他」栏** —— 分类栏就成了
 * 装饰品。
 *
 * ## 判定顺序：先看内容语义，再看结构
 *
 * 顺序不能反。综艺的命名大多是 `奔跑吧.2026-09-27.第12期.mkv`，解析器提不出
 * 季集号，`kind` 会是 `unknown`；如果先按 kind 落到「其他」，关键词表就永远
 * 没机会生效。
 *
 * ## 为什么关键词表这么短
 *
 * 长表看着更「聪明」，实际更脆：片名里什么词都可能出现（《动画人生》、
 * 《纪录片之死》都是真实存在的片名）。表里只放**几乎不可能出现在片名中段**的词，
 * 并且优先匹配目录路径 —— 用户整理网盘时几乎一定把动漫放进 `动漫/` 目录，
 * 那个信号比片名可靠得多。
 */
object MediaCategoryGuesser {

    private val ANIME = listOf(
        "动漫", "动画", "番剧", "新番", "国漫", "日漫", "美漫",
        "剧场版", "anime", "animation", "ova", "ona",
    )

    private val VARIETY = listOf(
        "综艺", "真人秀", "脱口秀", "访谈", "晚会", "盛典", "颁奖",
        "variety", "reality", "talkshow", "talk show",
    )

    private val VARIETY_EPISODE = Regex("(第\\s*\\d+\\s*期|\\d{6,8}\\s*期)")

    private val DOCUMENTARY = listOf(
        "纪录片", "纪实", "纪录", "bbc", "discovery", "national geographic",
        "nat.geo", "nhk", "history channel", "documentary",
    )

    private val ASCII_ONLY = Regex("^[a-z0-9 ._-]+$")
    private val CJK = Regex("[\\u4e00-\\u9fff]")

    /**
     * 主入口。
     *
     * [dirPath] 的权重最高（用户分目录的习惯最稳定），其次是片名，
     * 最后才是文件名（含技术标记，噪音最多）。
     */
    fun guess(
        kind: String,
        title: String?,
        fileName: String?,
        dirPath: String?,
        genres: List<String> = emptyList(),
    ): String {
        fromGenres(genres)?.let { return it }

        val dir = (dirPath ?: "").lowercase()
        if (hit(dir, ANIME)) return MediaCategoryNames.ANIME
        if (hit(dir, VARIETY) || VARIETY_EPISODE.containsMatchIn(dir)) {
            return MediaCategoryNames.VARIETY
        }
        if (hit(dir, DOCUMENTARY)) return MediaCategoryNames.DOCUMENTARY

        val name = "${title ?: ""} ${fileName ?: ""}".lowercase()
        if (hit(name, ANIME)) return MediaCategoryNames.ANIME
        if (hit(name, VARIETY) || VARIETY_EPISODE.containsMatchIn(name)) {
            return MediaCategoryNames.VARIETY
        }
        if (hit(name, DOCUMENTARY)) return MediaCategoryNames.DOCUMENTARY

        return when (kind) {
            "movie" -> MediaCategoryNames.MOVIE
            "episode" -> MediaCategoryNames.SERIES
            else -> MediaCategoryNames.OTHER
        }
    }

    /**
     * 已刮削拿到的类型名 → 分类。
     *
     * ⛔ 与 [guess] 的**优先级相反**：这里有真实的类型数据，比关键词准，
     *    所以调用方要先问它。
     */
    fun fromGenres(genres: List<String>): String? {
        for (raw in genres) {
            val g = raw.trim().lowercase()
            if (g.isEmpty()) continue
            if (g.contains("动画") || g.contains("anime") || g.contains("animation")) {
                return MediaCategoryNames.ANIME
            }
            if (g.contains("纪录") || g.contains("documentary")) {
                return MediaCategoryNames.DOCUMENTARY
            }
            if (g.contains("真人秀") || g.contains("脱口秀") ||
                g.contains("reality") || g.contains("talk")
            ) {
                return MediaCategoryNames.VARIETY
            }
        }
        return null
    }

    /**
     * 关键词命中判定。
     *
     * ⛔ 两类词的匹配方式**不同**，不能统一：
     *   * **中文词**（`动漫` / `纪录片`）：直接 `contains`。中文没有词间空格，
     *     加边界反而会漏（`动漫合集` 里的「动漫」后面跟着「合」）；
     *   * **ASCII 词**（`anime` / `ova` / `bbc`）：必须卡在非字母数字的边界上。
     *     不卡的话 `ova` 会命中 `Nova`、`anime` 会命中 `Animated.Movie` ——
     *     而误判的后果是「我的电影跑到动漫栏里不见了」，比漏判难发现得多。
     */
    private fun hit(haystack: String, needles: List<String>): Boolean {
        if (haystack.isEmpty()) return false
        for (n in needles) {
            if (ASCII_ONLY.matches(n)) {
                if (tokenPattern(n).containsMatchIn(haystack)) return true
            } else if (haystack.contains(n)) {
                return true
            }
        }
        return false
    }

    private val tokenCache = HashMap<String, Regex>()

    private fun tokenPattern(token: String): Regex = tokenCache.getOrPut(token) {
        Regex("(?<![a-z0-9])${Regex.escape(token)}(?![a-z0-9])")
    }

    /** 只有测试与诊断用得到。 */
    internal fun isCjk(s: String) = CJK.containsMatchIn(s)
}
