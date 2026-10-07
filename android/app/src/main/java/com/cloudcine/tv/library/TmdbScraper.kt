package com.cloudcine.tv.library

import android.util.Log

/**
 * TMDB 刮削器。
 *
 * ## 与 PC 端的源顺序一致：TMDB 在前
 *
 * ⛔ 但**顺序不影响可用性**：`api.themoviedb.org` 与 `image.tmdb.org` 在境内
 *    不可达（DNS 污染 + SNI 阻断，2026-10-01 实测），没配反代时 [enabled]
 *    为 `false`，这个源**一个候选都不产出** —— 列表里就只剩豆瓣。
 *    所以「TMDB 在前」对没配反代的绝大多数电视毫无影响，而配了反代的用户
 *    能优先看到元数据更全的 TMDB 结果。
 *
 * ## 三个「配错了不报错」的点
 *
 * 1. **API 与图片是**两个域名**（`api.themoviedb.org` / `image.tmdb.org`），
 *    反代经常只覆盖其中一个。所以 [apiBase] 与 [imageBase] **分开配置** ——
 *    合成一个的话，「API 通了但图片下不来」就没法修（海报全是灰块）。
 * 2. **`year` 是硬过滤**，不是加权。带一个错的年份会把正主**直接筛掉**，
 *    所以只在用户真的填了年份时才带。
 * 3. **电影与剧集是两套接口**（`/movie` vs `/tv`），字段名也不同
 *    （`title`/`name`、`release_date`/`first_air_date`）。解析必须按 [kind] 分支。
 *
 * ## 线程
 *
 * ⛔ 所有方法都**阻塞**（网络）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
 */
class TmdbScraper(
    private val http: ScrapeHttpLike = ScrapeHttp,
    private val apiKey: String = "",
    private val apiBase: String = DEFAULT_API_BASE,
    private val imageBase: String = DEFAULT_IMAGE_BASE,
    private val language: String = DEFAULT_LANGUAGE,
    private val timeoutMs: Int = TIMEOUT_MS,
) : MetadataScraper {

    override val id: String get() = ID

    override val displayName: String get() = "TMDB"

    /**
     * ⛔ 没配 API Key 就是不可用 —— 这不是「配了也必然失败」，而是**根本发不出去**
     *    （服务端一定回 401）。与豆瓣那条放宽是两回事。
     */
    override val enabled: Boolean get() = apiKey.isNotBlank()

    override fun search(query: ScrapeQuery): List<ScrapeCandidate> {
        if (!enabled) return emptyList()
        val title = query.title.trim()
        if (title.isEmpty()) return emptyList()

        // ⛔ 类型未知时**两个都搜**（综艺 / 纪录片在文件名里常常解析不出季集号，
        //    落到 `unknown`）。硬猜一个方向会把它们搜到完全无关的条目上。
        val kinds = when (query.wantsTv) {
            true -> listOf("tv")
            false -> listOf("movie")
            null -> listOf("tv", "movie")
        }
        val out = ArrayList<ScrapeCandidate>(20)
        for (k in kinds) {
            out += searchOne(k, title, query.year)
        }
        Log.i(TAG, "TMDB 搜「$title」：${out.size} 条候选（$kinds）")
        return out
    }

    private fun searchOne(kind: String, title: String, year: Int?): List<ScrapeCandidate> {
        val params = ArrayList<Pair<String, String>>(6)
        params += "language" to language
        params += "include_adult" to "false"
        params += "page" to "1"
        params += "query" to title
        // ⛔ 只在有年份时带：TMDB 的 year 是**硬过滤**，错的年份会把正主筛掉。
        if (year != null) {
            params += (if (kind == "tv") "first_air_date_year" else "year") to year.toString()
        }
        val res = try {
            http.get(url("/search/$kind", params), authHeaders(), timeoutMs)
        } catch (t: Throwable) {
            Log.w(TAG, "TMDB 搜索失败：${t.message}")
            return emptyList()
        }
        if (!res.ok) {
            Log.w(TAG, "TMDB 搜索 HTTP ${res.code}（反代地址=$apiBase）")
            return emptyList()
        }
        return TmdbParsing.candidates(res.body, kind, imageBase, LIST_IMAGE_SIZE)
    }

    override fun resolve(candidate: ScrapeCandidate): ScrapedMetadata? {
        if (candidate.source != id || !enabled) return null
        val kind = if (candidate.type == "tv") "tv" else "movie"
        val res = try {
            http.get(
                url("/$kind/${candidate.sourceId}", listOf("language" to language)),
                authHeaders(),
                timeoutMs,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "TMDB 详情失败：${t.message}")
            return null
        }
        if (!res.ok) return null
        val meta = TmdbParsing.detail(res.body, kind, imageBase, candidate.title)
        if (meta == null) Log.w(TAG, "TMDB 详情解析不出条目（${candidate.uid}）")
        return meta
    }

    // ------------------------------------------------------------------
    // 鉴权（★ 两种 Key 的送法**完全不同**，见 [isV4Token]）
    // ------------------------------------------------------------------

    /**
     * 鉴权头：只有 v4 令牌才带，v3 Key 是空的（它走查询参数）。
     */
    private fun authHeaders(): Map<String, String> =
        if (isV4Token(apiKey)) mapOf("Authorization" to "Bearer ${apiKey.trim()}")
        else emptyMap()

    /**
     * 拼 URL。
     *
     * ⛔ v3 的 `api_key` 在这里被当成**普通查询参数**插在最前面 —— 它和
     *    `query` / `language` 走同一套编码，不能靠字符串拼接单独处理。
     */
    private fun url(path: String, params: List<Pair<String, String>>): String {
        val all =
            if (isV4Token(apiKey)) params
            else listOf("api_key" to apiKey.trim()) + params
        // ⛔ 空查询串不要留一个光秃秃的 `?`：`/configuration?` 虽然多数服务端也认，
        //    但它会让「URL 长什么样」这件事在日志与单测里变得难比对。
        val query = if (all.isEmpty()) "" else
            "?" + all.joinToString("&") { "${it.first}=${DoubanScraper.enc(it.second)}" }
        return apiBase.trimEnd('/') + path + query
    }

    /**
     * 探一次 TMDB，把「**地址通不通**」与「**Key 对不对**」分开告诉用户。
     *
     * ## 为什么打 `/configuration`
     *
     * 它**不需要查询词**，只要地址与 Key 都对就回 200 —— 是能区分这两类失败的
     * **最小**请求。（拿 `/search/movie?query=x` 探的话，「这个词零命中」会混进来，
     * 而那与「接口不通」在结果上长得一模一样。）
     *
     * ⛔ 用输入框里**当前**的值构造（调用方传进来），不是已保存的设置：
     *    用户改完还没点「保存」就想先试试，是最自然的操作顺序。与 PC 端
     *    设置页的 `_probeTmdb` 同一条。
     */
    fun probe(): ScrapeProbe {
        if (apiKey.isBlank()) return ScrapeProbe(false, "还没填 API Key。")
        val res = try {
            http.get(url("/configuration", emptyList()), authHeaders(), PROBE_TIMEOUT_MS)
        } catch (t: Throwable) {
            return ScrapeProbe(
                false,
                "连不上 $apiBase —— 网络层失败（${t.message}）。" +
                    "境内直连官方地址多为 DNS 污染，请填一个可达的反代地址。",
            )
        }
        return when {
            res.ok -> ScrapeProbe(true, "连接正常：地址与 Key 都可用。")
            res.code == 401 -> ScrapeProbe(
                false,
                "地址可达，但 Key 被拒绝（401）—— 检查 Key 是否填错或已失效。" +
                    if (isV4Token(apiKey)) {
                        "当前按 v4 读取令牌送（`Authorization: Bearer`），送法是对的。"
                    } else {
                        "当前按 v3 Key 送（`api_key` 查询参数）。" +
                            "如果你从 TMDB 官网复制的是 `eyJ` 开头的长串，那是 **v4 读取令牌**，" +
                            "填进来即可 —— 程序会自己换送法。"
                    },
            )
            else -> ScrapeProbe(false, "地址可达，但返回 HTTP ${res.code}。")
        }
    }

    companion object {
        const val ID = "tmdb"

        /** 官方地址。境内不可达，用户可在设置里指向自建反代。 */
        const val DEFAULT_API_BASE = "https://api.themoviedb.org/3"

        /** 图片 CDN。⛔ 与 [DEFAULT_API_BASE] **是两个域名**，必须分开配。 */
        const val DEFAULT_IMAGE_BASE = "https://image.tmdb.org/t/p"

        /**
         * 这个 Key 是不是 **v4 读取令牌**（`eyJ…` 开头的 JWT）。
         *
         * ## ⛔ 这是本类最容易踩的一个坑
         *
         * TMDB 有**两代** Key，用户从官网复制到的那个串长得完全不一样，
         * 而**送法也不同**：
         *
         *   * **v4 Read Access Token** —— `eyJhbGciOi…` 的 JWT，200+ 字符
         *     ⇒ 必须走 `Authorization: Bearer`
         *   * **v3 API Key** —— 32 位十六进制
         *     ⇒ 走 `api_key` 查询参数
         *
         * 把 v4 令牌塞进 `api_key=` 会拿到 **401 `Invalid API key`** ——
         * 而它看起来与「Key 填错了」**一模一样**，用户只会反复重贴、
         * 永远查不出原因。
         *
         * 2026-10-07 实测（同一个令牌）：
         * ```
         * GET /3/configuration?api_key=<JWT>            → 401 {"status_code":7,…}
         * GET /3/configuration  Authorization: Bearer   → 200
         * ```
         *
         * 判据与 PC 端 `tmdb_client.dart` 的 `_apiKey.startsWith('eyJ')`
         * **逐字一致** —— 两端必须认同一个形状，否则「电脑上能用、电视上 401」。
         */
        fun isV4Token(key: String): Boolean = key.trim().startsWith("eyJ")

        private const val DEFAULT_LANGUAGE = "zh-CN"

        /** 候选列表里的小图（约 100×150）。 */
        private const val LIST_IMAGE_SIZE = "w154"

        private const val TIMEOUT_MS = 12_000

        /** 「测试凭证」的超时。比刮削短：设置页里等超过 10 秒用户会以为死机了。 */
        private const val PROBE_TIMEOUT_MS = 10_000

        private const val TAG = "CloudCine"
    }
}

/**
 * TMDB 响应的**纯解析**。
 *
 * ⛔ 与网络分开（同豆瓣那边）：这一层是「接口改版时唯一要改的地方」，
 *    且必须能被纯 JVM 单测覆盖。
 */
object TmdbParsing {

    /** 海报尺寸：卡片墙的格子约 170×255 逻辑像素，w500 在 2 倍屏下够。 */
    const val POSTER_SIZE = "w500"

    /** 背景图尺寸。 */
    const val BACKDROP_SIZE = "w780"

    /**
     * 搜索结果 → 候选。
     *
     * ⛔ 电影与剧集的字段名不同（`title`/`name`、`release_date`/`first_air_date`），
     *    两边都要读，[kind] 决定 [ScrapeCandidate.type]。
     */
    fun candidates(
        body: String,
        kind: String,
        imageBase: String,
        imageSize: String,
    ): List<ScrapeCandidate> {
        val root = try {
            MiniJson.parseObject(body)
        } catch (t: Throwable) {
            return emptyList()
        }
        val results = root["results"] as? List<*> ?: return emptyList()
        val out = ArrayList<ScrapeCandidate>(results.size)
        for (item in results) {
            val m = item as? Map<*, *> ?: continue
            val id = intOf(m["id"]) ?: continue
            // ⛔ 两个名字都读：`/search/movie` 给 `title`，`/search/tv` 给 `name`。
            val title = strOf(m["title"]) ?: strOf(m["name"]) ?: continue
            out += ScrapeCandidate(
                source = TmdbScraper.ID,
                sourceId = id.toString(),
                title = title,
                year = yearOf(strOf(m["release_date"]) ?: strOf(m["first_air_date"])),
                type = kind,
                posterUrl = imageUrl(imageBase, imageSize, strOf(m["poster_path"])),
                overview = strOf(m["overview"]),
            )
        }
        return out
    }

    /**
     * 详情响应 → 完整元数据。**响应不是一个条目时返回 `null`**。
     *
     * 用详情接口而不是搜索结果，是为了 `genres`：搜索只给 `genre_ids`
     * （数字），要换成名字还得再维护一张 id→名字的类型表；详情直接给
     * `genres: [{id, name}]`，且 `name` 已按 [language] 本地化。
     */
    fun detail(
        body: String,
        kind: String,
        imageBase: String,
        matchedQuery: String,
    ): ScrapedMetadata? {
        val d = try {
            MiniJson.parseObject(body)
        } catch (t: Throwable) {
            return null
        }
        val id = intOf(d["id"])
        val title = strOf(d["title"]) ?: strOf(d["name"])
        // ⛔ 与豆瓣同一条规矩：标题拿不到就是**无效条目**，绝不拿查询词兜底
        //    （那会把「详情没拿到」伪装成「刮削成功」）。
        if (title.isNullOrEmpty()) return null

        return ScrapedMetadata(
            title = title,
            originalTitle = strOf(d["original_title"]) ?: strOf(d["original_name"]),
            year = yearOf(strOf(d["release_date"]) ?: strOf(d["first_air_date"])),
            overview = strOf(d["overview"]),
            posterUrl = imageUrl(imageBase, POSTER_SIZE, strOf(d["poster_path"])),
            backdropUrl = imageUrl(imageBase, BACKDROP_SIZE, strOf(d["backdrop_path"])),
            rating = doubleOf(d["vote_average"]),
            genres = genresOf(d["genres"]),
            onlineId = id?.let { "tmdb/$kind/$it" },
            source = ScrapeSource.online,
            matchedQuery = matchedQuery,
        )
    }

    /**
     * 拼图片地址。
     *
     * ⛔ `poster_path` 是**以 `/` 开头**的相对路径，而 `imageBase` 形如
     *    `https://image.tmdb.org/t/p`（**不带**结尾斜杠）—— 直接相加即可。
     *    多拼一个或少拼一个斜杠都会得到 404，而 404 在界面上只是「没有海报」，
     *    与「这部片子本来就没海报」长得一样。
     */
    fun imageUrl(imageBase: String, size: String, path: String?): String? {
        val p = path?.trim().orEmpty()
        if (p.isEmpty()) return null
        val base = imageBase.trimEnd('/')
        return "$base/$size/${p.trimStart('/')}"
    }

    private fun genresOf(v: Any?): List<String> =
        (v as? List<*>)?.mapNotNull { e ->
            (e as? Map<*, *>)?.let { strOf(it["name"]) }
        }?.filter { it.isNotBlank() } ?: emptyList()

    private fun strOf(v: Any?): String? =
        (v as? String)?.trim()?.takeIf { it.isNotEmpty() }

    private fun intOf(v: Any?): Int? = when (v) {
        is Int -> v
        is Long -> v.toInt()
        is Double -> v.toInt()
        is String -> v.trim().toIntOrNull()
        else -> null
    }

    private fun doubleOf(v: Any?): Double? = when (v) {
        is Double -> v
        is Int -> v.toDouble()
        is Long -> v.toDouble()
        is String -> v.trim().toDoubleOrNull()
        else -> null
    }

    private fun yearOf(s: String?): Int? {
        val t = s?.trim().orEmpty()
        if (t.isEmpty()) return null
        val m = Regex("(18|19|20)\\d{2}").find(t) ?: return null
        return m.value.toIntOrNull()
    }
}
