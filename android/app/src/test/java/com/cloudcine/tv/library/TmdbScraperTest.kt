package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * TMDB 刮削器 —— **解析** + **两个接口的分支**。
 *
 * ## 为什么这一组必须钉死
 *
 * 类文档里列了三个「配错了不报错」的点，加上两条跨端契约：
 *
 * 1. `poster_path` 是**以 `/` 开头**的相对路径，而 `imageBase` 形如
 *    `https://image.tmdb.org/t/p`（不带结尾斜杠）。多拼或少拼一个斜杠都得到
 *    404 —— 而 404 在界面上只是「没有海报」，与「这部片子本来就没海报」
 *    长得一模一样。
 * 2. **电影与剧集是两套字段名**（`title`/`name`、`release_date`/`first_air_date`）。
 *    只读一套的话，剧集那一批候选**整批**没有标题 ⇒ 被 `continue` 掉 ⇒
 *    「TMDB 搜不到剧」。
 * 3. `year` 是**硬过滤**：带一个错的年份会把正主直接筛掉。所以只钉「有年份才带」。
 * 4. `onlineId` 的中间段（`movie`/`tv`）是跨端共享的**类型证据**，写错会让
 *    分类判定跟着错。
 */
class TmdbScraperTest {

    private val imageBase = TmdbScraper.DEFAULT_IMAGE_BASE

    // ==================================================================
    // 图片地址拼接
    // ==================================================================

    /** 基准：`base` + `/` + `size` + `/` + `path`（path 的开头斜杠要吃掉）。 */
    @Test
    fun `图片地址拼接只有一个斜杠`() {
        assertEquals(
            "https://image.tmdb.org/t/p/w500/abc.jpg",
            TmdbParsing.imageUrl(imageBase, "w500", "/abc.jpg"),
        )
    }

    /**
     * ⛔ 用户填的反代地址**结尾带斜杠是常态**（从浏览器地址栏复制来的）。
     *    不 `trimEnd('/')` 就会拼出 `//w500/`，服务端回 404 ——
     *    而表现只是「海报全是灰块」。
     */
    @Test
    fun `反代地址结尾的斜杠被吃掉`() {
        assertEquals(
            "https://my-proxy.example.com/t/p/w500/abc.jpg",
            TmdbParsing.imageUrl("https://my-proxy.example.com/t/p/", "w500", "/abc.jpg"),
        )
    }

    /** `poster_path` 缺失 / 为空 ⇒ `null`（不是拼一个指向根路径的地址）。 */
    @Test
    fun `没有 path 时返回 null`() {
        assertNull(TmdbParsing.imageUrl(imageBase, "w500", null))
        assertNull(TmdbParsing.imageUrl(imageBase, "w500", ""))
        assertNull(TmdbParsing.imageUrl(imageBase, "w500", "   "))
    }

    // ==================================================================
    // 搜索解析
    // ==================================================================

    /**
     * ⛔ **电影接口给 `title` / `release_date`**。
     */
    @Test
    fun `电影搜索结果读 title 与 release_date`() {
        val body = """
            { "page": 1, "results": [
              { "id": 843527, "title": "流浪地球2", "release_date": "2023-01-22",
                "poster_path": "/p1.jpg", "overview": "太阳危机。" }
            ] }
        """.trimIndent()

        val out = TmdbParsing.candidates(body, "movie", imageBase, "w154")
        val c = out.single()
        assertEquals("tmdb", c.source)
        assertEquals("843527", c.sourceId)
        assertEquals("流浪地球2", c.title)
        assertEquals(2023, c.year)
        assertEquals("movie", c.type)
        assertEquals("https://image.tmdb.org/t/p/w154/p1.jpg", c.posterUrl)
        assertEquals("2023 · 电影", c.subtitle)
    }

    /**
     * ⛔ **剧集接口给 `name` / `first_air_date`**，字段名完全不同。
     *
     * 只读 `title` 的话这里整批被跳过 —— 表现是「TMDB 搜不到剧」，而日志里
     * 一条错误都没有。
     */
    @Test
    fun `剧集搜索结果读 name 与 first_air_date`() {
        val body = """
            { "page": 1, "results": [
              { "id": 1396, "name": "绝命毒师", "first_air_date": "2008-01-20",
                "poster_path": "/p2.jpg" }
            ] }
        """.trimIndent()

        val c = TmdbParsing.candidates(body, "tv", imageBase, "w154").single()
        assertEquals("绝命毒师", c.title)
        assertEquals(2008, c.year)
        assertEquals("tv", c.type)
        assertEquals("2008 · 剧集", c.subtitle)
    }

    /** 没有 `id` 的条目没法解析详情 ⇒ 跳过。 */
    @Test
    fun `缺 id 的条目被跳过`() {
        val body = """
            { "results": [ { "title": "没有 id" }, { "id": 1, "title": "正常" } ] }
        """.trimIndent()
        assertEquals(listOf("1"), TmdbParsing.candidates(body, "movie", imageBase, "w154").map { it.sourceId })
    }

    /** 缺标题（两套名字都没有）的条目跳过 —— 列表里没法让人认出它是哪一部。 */
    @Test
    fun `缺标题的条目被跳过`() {
        val body = """{ "results": [ { "id": 1 } ] }"""
        assertTrue(TmdbParsing.candidates(body, "movie", imageBase, "w154").isEmpty())
    }

    @Test
    fun `非 JSON 响应返回空列表`() {
        assertTrue(TmdbParsing.candidates("", "movie", imageBase, "w154").isEmpty())
        assertTrue(TmdbParsing.candidates("""{"status_code":7}""", "movie", imageBase, "w154").isEmpty())
    }

    // ==================================================================
    // 详情解析
    // ==================================================================

    /**
     * 详情用 `genres: [{id, name}]` 而不是搜索结果的 `genre_ids`（数字）。
     *
     * ⛔ 用数字 id 就得再维护一张 id→名字的表 —— 那是一个**会过期**的映射，
     *    过期后不报错，只是类型越来越不对。
     */
    @Test
    fun `详情字段全部落位 类型取名字不是 id`() {
        val body = """
            {
              "id": 843527, "title": "流浪地球2", "original_title": "The Wandering Earth II",
              "release_date": "2023-01-22", "overview": "太阳危机。",
              "poster_path": "/p1.jpg", "backdrop_path": "/b1.jpg",
              "vote_average": 7.2,
              "genres": [ { "id": 878, "name": "科幻" }, { "id": 18, "name": "剧情" } ]
            }
        """.trimIndent()

        val meta = TmdbParsing.detail(body, "movie", imageBase, "流浪地球2")!!
        assertEquals("流浪地球2", meta.title)
        assertEquals("The Wandering Earth II", meta.originalTitle)
        assertEquals(2023, meta.year)
        assertEquals(7.2, meta.rating!!, 0.001)
        assertEquals(listOf("科幻", "剧情"), meta.genres)
        assertEquals("tmdb/movie/843527", meta.onlineId)
        assertEquals(ScrapeSource.online, meta.source)
        assertEquals("流浪地球2", meta.matchedQuery)
        // 海报与背景图用**不同**的尺寸档。
        assertEquals("https://image.tmdb.org/t/p/w500/p1.jpg", meta.posterUrl)
        assertEquals("https://image.tmdb.org/t/p/w780/b1.jpg", meta.backdropUrl)
    }

    /** 剧集详情的 `onlineId` 中间段必须是 `tv` —— 它是跨端共享的类型证据。 */
    @Test
    fun `剧集详情的 onlineId 中间段是 tv`() {
        val body = """
            { "id": 1396, "name": "绝命毒师", "original_name": "Breaking Bad",
              "first_air_date": "2008-01-20", "genres": [ { "id": 18, "name": "剧情" } ] }
        """.trimIndent()

        val meta = TmdbParsing.detail(body, "tv", imageBase, "绝命毒师")!!
        assertEquals("tmdb/tv/1396", meta.onlineId)
        assertEquals("tv", structureOf(meta.onlineId))
        assertEquals("Breaking Bad", meta.originalTitle)
        assertEquals(2008, meta.year)
    }

    /**
     * ⛔ 与豆瓣同一条规矩：标题拿不到就是**无效条目**，绝不拿查询词兜底。
     *
     * 兜底会把「详情没拿到」伪装成「刮削成功」（标题有、海报简介一个都没有，
     * 且 `source` 记成 online）⇒ 界面显示「已刮削」。
     */
    @Test
    fun `标题拿不到时返回 null 而不是拿查询词兜底`() {
        assertNull(TmdbParsing.detail("""{"id":1}""", "movie", imageBase, "查询词"))
        assertNull(TmdbParsing.detail("""{"id":1,"title":""}""", "movie", imageBase, "查询词"))
        assertNull(TmdbParsing.detail("not json", "movie", imageBase, "查询词"))
    }

    /** `genres` 缺失 / 元素没有 `name` 时给空列表，**不是**一堆 `null`。 */
    @Test
    fun `genres 缺失或畸形时给空列表`() {
        assertTrue(TmdbParsing.detail("""{"id":1,"title":"片"}""", "movie", imageBase, "片")!!.genres.isEmpty())
        assertTrue(
            TmdbParsing.detail(
                """{"id":1,"title":"片","genres":[{"id":1},{"name":""}]}""",
                "movie", imageBase, "片",
            )!!.genres.isEmpty(),
        )
    }

    // ==================================================================
    // 搜索：类型未知时两个接口都搜
    // ==================================================================

    /**
     * ⛔ `kind` 认不出（综艺 / 纪录片常见）时**两个接口都搜**。
     *
     * 硬猜一个方向会把它们搜到完全无关的条目上 —— 而「搜不到」至少还能让用户
     * 自己改搜索词。
     */
    @Test
    fun `类型未知时电影与剧集两个接口都搜`() {
        val http = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = http, apiKey = "k").search(ScrapeQuery("某某综艺"))

        assertEquals(2, http.urls.size)
        assertTrue(http.urls[0], http.urls[0].contains("/search/tv"))
        assertTrue(http.urls[1], http.urls[1].contains("/search/movie"))
    }

    @Test
    fun `有季集号时只搜剧集接口`() {
        val http = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = http, apiKey = "k").search(ScrapeQuery("繁花", kind = "episode"))

        assertEquals(1, http.urls.size)
        assertTrue(http.urls[0], http.urls[0].contains("/search/tv"))
    }

    /** ⛔ `year` 是**硬过滤**：带一个错的年份会把正主直接筛掉 ⇒ 只在有值时带。 */
    @Test
    fun `有年份才带年份参数 且剧集用 first_air_date_year`() {
        val withYear = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = withYear, apiKey = "k")
            .search(ScrapeQuery("繁花", year = 2023, kind = "episode"))
        assertTrue(withYear.urls.single(), withYear.urls.single().contains("first_air_date_year=2023"))

        val noYear = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = noYear, apiKey = "k").search(ScrapeQuery("繁花", kind = "episode"))
        assertTrue(noYear.urls.single(), !noYear.urls.single().contains("year="))
    }

    /** 没配 Key 时**一个请求都不发**（发了服务端必回 401，白跑一趟）。 */
    @Test
    fun `没配 Key 时不发请求`() {
        val http = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        assertTrue(TmdbScraper(http = http, apiKey = "").search(ScrapeQuery("片")).isEmpty())
        assertEquals(0, http.urls.size)
    }

    /** 详情请求按候选的 `type` 走 `/movie` 或 `/tv`。 */
    @Test
    fun `详情按候选类型选接口`() {
        val movie = FakeHttp { ScrapeResponse(200, """{"id":1,"title":"片"}""") }
        TmdbScraper(http = movie, apiKey = "k")
            .resolve(ScrapeCandidate("tmdb", "1", "片", null, "movie", null))
        assertTrue(movie.urls.single(), movie.urls.single().contains("/movie/1?"))

        val tv = FakeHttp { ScrapeResponse(200, """{"id":1,"name":"剧"}""") }
        TmdbScraper(http = tv, apiKey = "k")
            .resolve(ScrapeCandidate("tmdb", "1", "剧", null, "tv", null))
        assertTrue(tv.urls.single(), tv.urls.single().contains("/tv/1?"))
    }

    /** 来源不是 TMDB 的候选，本刮削器**不接**。 */
    @Test
    fun `非本源的候选返回 null`() {
        val http = FakeHttp { ScrapeResponse(200, """{"id":1,"title":"片"}""") }
        assertNull(
            TmdbScraper(http = http, apiKey = "k")
                .resolve(ScrapeCandidate("douban", "1", "片", null, "movie", null)),
        )
        assertEquals(0, http.urls.size)
    }

    // ==================================================================
    // 流水线
    // ==================================================================

    /**
     * 一个源挂了**不该让整个列表空掉** —— 其他源的候选照样有用。
     *
     * ⛔ 手动刮削是「用户要自己挑」，所以这里必须**拼接**而不是「取第一个成功的」。
     */
    @Test
    fun `一个源抛异常不影响另一个源的候选`() {
        val pipeline = ScraperPipeline(
            listOf(
                ThrowingScraper("tmdb"),
                StubScraper("douban", listOf(ScrapeCandidate("douban", "1", "片", null, "movie", null))),
            ),
        )
        assertEquals(listOf("1"), pipeline.search(ScrapeQuery("片")).map { it.sourceId })
    }

    /** 未启用的源**不产出候选**，也不出现在「搜索源」选择器里。 */
    @Test
    fun `未启用的源被跳过且不出现在选择器里`() {
        val pipeline = ScraperPipeline(
            listOf(
                StubScraper("tmdb", emptyList(), enabled = false),
                StubScraper("douban", emptyList()),
            ),
        )
        assertEquals(listOf("douban" to "豆瓣"), pipeline.availableSources)
        pipeline.search(ScrapeQuery("片"))
    }

    /** 指定来源时只搜那一个 —— 没必要把另一个源的额度也花掉。 */
    @Test
    fun `指定来源时只搜那一个`() {
        val a = StubScraper("tmdb", listOf(ScrapeCandidate("tmdb", "1", "A", null, "movie", null)))
        val b = StubScraper("douban", listOf(ScrapeCandidate("douban", "2", "B", null, "movie", null)))
        val pipeline = ScraperPipeline(listOf(a, b))

        assertEquals(listOf("1"), pipeline.search(ScrapeQuery("片"), sourceId = "tmdb").map { it.sourceId })
        assertEquals(1, a.calls)
        assertEquals(0, b.calls)
    }

    /** 候选的来源不在流水线里时返回 `null`，**不猜**（猜就会用错源去解析）。 */
    @Test
    fun `候选来源不在流水线里时返回 null`() {
        val pipeline = ScraperPipeline(listOf(StubScraper("douban", emptyList())))
        assertNull(pipeline.resolve(ScrapeCandidate("tmdb", "1", "片", null, "movie", null)))
    }

    @Test
    fun `展示名查不到时返回 null 由调用方兜底`() {
        val pipeline = ScraperPipeline(listOf(StubScraper("douban", emptyList())))
        assertEquals("豆瓣", pipeline.displayNameOf("douban"))
        assertNull(pipeline.displayNameOf("tmdb"))
    }

    // ==================================================================
    // 鉴权：两种 Key 的送法（★ 2026-10-07 血案）
    // ==================================================================

    /**
     * 一个形状正确的 **v4 读取令牌**：`eyJ` 开头 + 三段。
     *
     * ⛔ 内容是编的，只有**形状**重要 —— 判据是前缀，不是真伪。
     */
    private val v4Token =
        "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIxZjI4NDIiLCJzdWIiOiJ4In0.abcdefghijklmnopqrstuvwxyz01"

    /** v3 的 32 位十六进制 Key。 */
    private val v3Key = "0123456789abcdef0123456789abcdef"

    /**
     * ⛔ **v4 读取令牌必须走 `Authorization: Bearer`，且不能同时塞进 `api_key`。**
     *
     * 2026-10-07 用用户的真令牌实测：
     * ```
     * GET /3/configuration?api_key=<JWT>            → 401 Invalid API key
     * GET /3/configuration  Authorization: Bearer   → 200
     * ```
     * 现象就是「明明有 token 还是刮不到」，而 401 看起来完全像「Key 填错了」——
     * 用户只会反复重贴，永远查不出原因。
     */
    @Test
    fun `v4 读取令牌走 Authorization 头且不带 api_key`() {
        val http = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = http, apiKey = v4Token).search(ScrapeQuery("片"))

        assertEquals("Bearer $v4Token", http.headers["Authorization"])
        assertFalse("v4 令牌不该同时出现在 api_key 里", http.urls.any { it.contains("api_key=") })
    }

    /** v3 的 32 位 Key 反过来：走 `api_key` 查询参数，**不带** Authorization 头。 */
    @Test
    fun `v3 Key 走 api_key 查询参数且不带 Authorization`() {
        val http = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = http, apiKey = v3Key).search(ScrapeQuery("片"))

        assertTrue(http.urls.any { it.contains("api_key=$v3Key") })
        assertNull(http.headers["Authorization"])
    }

    /**
     * 反代地址**结尾带斜杠是常态**（从浏览器地址栏复制来的）。
     * 不 `trimEnd('/')` 就会拼出 `//search/movie`，服务端 404 ——
     * 而表现只是「TMDB 搜不到」，与「没这个片」长得一样。
     */
    @Test
    fun `反代地址结尾的斜杠被吃掉不拼出双斜杠`() {
        val http = FakeHttp { ScrapeResponse(200, """{"results":[]}""") }
        TmdbScraper(http = http, apiKey = v3Key, apiBase = "https://proxy.example.com/3/")
            .search(ScrapeQuery("片"))

        assertTrue(http.urls.isNotEmpty())
        assertTrue(http.urls.all { !it.contains("//search") })
    }

    /** 判据只看 `eyJ` 前缀 —— 两端（PC / Android）必须认同同一个形状。 */
    @Test
    fun `v4 令牌的判据只看 eyJ 前缀`() {
        assertTrue(TmdbScraper.isV4Token(v4Token))
        assertTrue(TmdbScraper.isV4Token("  eyJx.y.z  "))
        assertFalse(TmdbScraper.isV4Token(v3Key))
        assertFalse(TmdbScraper.isV4Token(""))
    }

    // ==================================================================
    // 测试凭证（probe）
    // ==================================================================

    /**
     * 401 ⇒ 必须说清「**地址通了、Key 被拒**」。
     *
     * ⛔ 这两种失败必须分开：一个要换地址，一个要换 Key，是**两个完全不同的
     *    动作**。合成一句「测试失败」，用户只能瞎改。
     */
    @Test
    fun `probe 打 configuration 且 401 时说 Key 被拒`() {
        val http = FakeHttp { ScrapeResponse(401, """{"status_code":7}""") }
        val r = TmdbScraper(http = http, apiKey = v4Token).probe()

        assertFalse(r.ok)
        assertTrue("要带上状态码，用户才能对上文档", r.message.contains("401"))
        assertTrue("要打最小请求 /configuration", http.urls.single().endsWith("/configuration"))
    }

    /** 200 = 地址与 Key 都对。 */
    @Test
    fun `probe 200 即通过`() {
        val http = FakeHttp { ScrapeResponse(200, "{}") }
        assertTrue(TmdbScraper(http = http, apiKey = v3Key).probe().ok)
    }

    /**
     * 网络层失败要说「**连不上**」并指向反代 —— 境内直连官方地址被 DNS 污染
     * 就长这样（请求一直挂到超时），而它与「Key 无效」在界面上原本无法区分。
     */
    @Test
    fun `probe 网络失败时指出地址不可达`() {
        val http = FakeHttp { throw java.net.UnknownHostException("api.themoviedb.org") }
        val r = TmdbScraper(http = http, apiKey = v3Key).probe()

        assertFalse(r.ok)
        assertTrue(r.message.contains("连不上"))
        assertTrue(r.message.contains("反代"))
    }

    /** 空 Key 必定 401 ⇒ 一个包都不该发出去（否则白等 10 秒）。 */
    @Test
    fun `probe 没填 Key 时不发请求`() {
        val http = FakeHttp { ScrapeResponse(200, "{}") }
        val r = TmdbScraper(http = http, apiKey = "").probe()

        assertFalse(r.ok)
        assertEquals(0, http.urls.size)
    }

    // ==================================================================
    // 夹具
    // ==================================================================

    private class FakeHttp(private val responder: (String) -> ScrapeResponse) : ScrapeHttpLike {
        val urls = ArrayList<String>()

        /** 最后一次请求的头。用来钉「v4 令牌走 `Authorization: Bearer`」。 */
        var headers: Map<String, String> = emptyMap()
            private set

        override fun get(url: String, headers: Map<String, String>, timeoutMs: Int): ScrapeResponse {
            urls += url
            this.headers = headers
            return responder(url)
        }

        override fun getBytes(url: String, headers: Map<String, String>, timeoutMs: Int): ByteArray? = null
    }

    private class StubScraper(
        override val id: String,
        private val result: List<ScrapeCandidate>,
        override val enabled: Boolean = true,
    ) : MetadataScraper {
        var calls = 0
            private set

        override val displayName: String get() = if (id == "douban") "豆瓣" else "TMDB"

        override fun search(query: ScrapeQuery): List<ScrapeCandidate> {
            calls++
            return result
        }

        override fun resolve(candidate: ScrapeCandidate): ScrapedMetadata? = null
    }

    private class ThrowingScraper(override val id: String) : MetadataScraper {
        override val displayName: String get() = "会抛的源"
        override val enabled: Boolean get() = true
        override fun search(query: ScrapeQuery): List<ScrapeCandidate> =
            throw IllegalStateException("这个源挂了")
        override fun resolve(candidate: ScrapeCandidate): ScrapedMetadata? =
            throw IllegalStateException("这个源挂了")
    }
}
