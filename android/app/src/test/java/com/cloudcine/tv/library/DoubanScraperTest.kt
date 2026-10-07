package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 豆瓣刮削器 —— **解析** + **熔断**。
 *
 * ## 为什么这两块必须钉死
 *
 * 类文档里列了五个坑，每一个的特征都是「**不报错，只是结果变空 / 变错**」：
 * 少读一段搜索来源 ⇒ 搜「繁花」搜不到正主；`target_type` 不剔 ⇒ 列表里混进书
 * 和音乐；拿搜索的 `cover_url` 当海报 ⇒ 每张海报都是 120px 横条；类型按请求
 * 路径判 ⇒ 所有剧集被记成电影；业务码判在状态码之后 ⇒ 额度耗尽被读成「网络
 * 抖了一下」，然后继续烧额度。
 *
 * 熔断那一组还多一条：**熔断必须会过期**。写死一个「本次进程内不再试」的开关，
 * 用户按提示去贴了 Cookie 回来仍然刮不到，只有重启才恢复 —— 那是最伤人的一种
 * bug，而且完全没有报错。
 */
class DoubanScraperTest {

    // ==================================================================
    // 搜索解析
    // ==================================================================

    /**
     * ⛔ **坑 #1**：`subjects.items` 与 `smart_box` **两处都要读**，而且两处
     * 形状不同（前者 `{items:[…]}`，后者直接是数组）。
     *
     * 实测搜「繁花」：`subjects.items` 里只有两本书和一个 2028 年的影版，
     * 真正的剧集只在 `smart_box` 里。只读一处会**静默刮错片子**。
     */
    @Test
    fun `subjects 与 smart_box 两处候选都要读`() {
        val body = """
            {
              "subjects": { "items": [
                { "target_type": "movie", "target": { "id": 111, "title": "影版繁花", "year": "2028" } }
              ] },
              "smart_box": [
                { "target_type": "tv", "target": { "id": "222", "title": "繁花", "year": "2023" } }
              ]
            }
        """.trimIndent()

        val out = DoubanParsing.candidates(body)
        assertEquals(listOf("111", "222"), out.map { it.sourceId })
        assertEquals(listOf("影版繁花", "繁花"), out.map { it.title })
    }

    /**
     * ⛔ **坑 #2**：`type=movie` 不是过滤器，返回里照样混着 `book` / `music`，
     * 必须自己按 `target_type` 剔。
     */
    @Test
    fun `非影视条目被剔掉`() {
        val body = """
            { "subjects": { "items": [
              { "target_type": "book", "target": { "id": 1, "title": "书" } },
              { "target_type": "music", "target": { "id": 2, "title": "专辑" } },
              { "target_type": "game", "target": { "id": 3, "title": "游戏" } },
              { "target_type": "tv",   "target": { "id": 4, "title": "剧" } }
            ] } }
        """.trimIndent()

        assertEquals(listOf("4"), DoubanParsing.candidates(body).map { it.sourceId })
    }

    /** `layout: more_results` 这类占位项**没有 `target`** —— 要跳过，不是崩。 */
    @Test
    fun `没有 target 的占位项被跳过`() {
        val body = """
            { "subjects": { "items": [
              { "layout": "more_results" },
              { "target_type": "tv", "target": { "id": 7, "title": "正常项" } }
            ] } }
        """.trimIndent()

        assertEquals(listOf("7"), DoubanParsing.candidates(body).map { it.sourceId })
    }

    /**
     * 豆瓣的 `id` 有时是数字、有时是字符串 —— 两种都收，统一成字符串。
     *
     * ⛔ 两个条目的 id 要**不同**：`candidates` 会按 `uid` 去重，用同一个 id 的话
     *    第二条会被合并掉，测的就不是「两种形态都收」了。
     */
    @Test
    fun `id 数字与字符串两种形态都收`() {
        val body = """
            { "subjects": { "items": [
              { "target_type": "movie", "target": { "id": 1292052, "title": "数字 id" } },
              { "target_type": "movie", "target": { "id": "1292053", "title": "字符串 id" } }
            ] } }
        """.trimIndent()

        val out = DoubanParsing.candidates(body)
        assertEquals(listOf("1292052", "1292053"), out.map { it.sourceId })
        // ⛔ 数字 id 必须变成 `1292052`，**不能是** `1292052.0`：JSON 解析把整数
        //    读成 Double 是常态，而带小数点的 id 拼出来的 `onlineId` 与 PC 端
        //    对不上 —— 而那一列是跨端共享的归一化判据（`autoMergeByOnlineId`）。
        assertTrue(out.none { it.sourceId.contains('.') })
    }

    /** 同一条目可能两处都出现 ⇒ 去重，且**保序**（源顺序就是展示顺序）。 */
    @Test
    fun `重复条目去重且保序`() {
        val body = """
            {
              "subjects": { "items": [
                { "target_type": "tv", "target": { "id": 5, "title": "甲" } }
              ] },
              "smart_box": [
                { "target_type": "tv", "target": { "id": 5, "title": "甲" } },
                { "target_type": "tv", "target": { "id": 6, "title": "乙" } }
              ]
            }
        """.trimIndent()

        assertEquals(listOf("5", "6"), DoubanParsing.candidates(body).map { it.sourceId })
    }

    /** 响应不是 JSON（网关报错页、空响应）时返回空列表，**不抛**。 */
    @Test
    fun `非 JSON 响应返回空列表`() {
        assertTrue(DoubanParsing.candidates("<html>502 Bad Gateway</html>").isEmpty())
        assertTrue(DoubanParsing.candidates("").isEmpty())
        assertTrue(DoubanParsing.candidates("{}").isEmpty())
    }

    /**
     * ⛔ **坑 #3**：搜索结果的 `cover_url` 是 120px 横条，**不能落库**。
     *    这里只钉住「它原样带出来（给列表画小图）」+「详情那条会被改写」。
     */
    @Test
    fun `候选缩略图原样带出 海报只从详情取`() {
        val body = """
            { "subjects": { "items": [
              { "target_type": "movie", "target": {
                  "id": 1, "title": "片",
                  "cover_url": "https://img9.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg"
              } }
            ] } }
        """.trimIndent()

        val c = DoubanParsing.candidates(body).single()
        // 候选阶段**不**改写：它本来就不是海报，改写了反而让人以为能当海报用。
        assertTrue(c.posterUrl!!.contains("img9.doubanio.com"))
    }

    // ==================================================================
    // 详情解析
    // ==================================================================

    /**
     * ⛔ **坑 #4**：`/movie/{id}` 对剧集会 301 到 `/tv/{id}`，类型只能读**响应体**
     *    里的 `type`。
     *
     * 判错的后果是 `onlineId` 记成 `douban/movie/…` —— 而那一列是跨端共享的
     * 类型证据，写错会让分类判定跟着错，且**没有任何报错**。
     */
    @Test
    fun `类型读响应体而不是请求路径`() {
        // 注意：请求走的是 /movie/{id}，响应体里却是 "type":"tv"。
        val body = detailBody(id = "34874646", type = "tv", title = "繁花")

        val meta = DoubanParsing.detail(body, "繁花")
        assertNotNull(meta)
        assertEquals("douban/tv/34874646", meta!!.onlineId)
        assertEquals("tv", structureOf(meta.onlineId))
    }

    @Test
    fun `电影条目的 onlineId 中间段是 movie`() {
        val meta = DoubanParsing.detail(
            detailBody(id = "1292052", type = "movie", title = "肖申克的救赎"),
            "肖申克的救赎",
        )
        assertEquals("douban/movie/1292052", meta!!.onlineId)
    }

    /**
     * ⛔ 标题**只**来自响应体，**不许拿查询词兜底**（PC 端踩过这个坑）。
     *
     * 兜底会把「详情没拿到」伪装成「刮削成功」：标题有、海报简介一个都没有，
     * 而且 `source` 记成 online ⇒ 界面显示「已刮削」。排查时最难想到根因在这里。
     */
    @Test
    fun `标题拿不到时返回 null 而不是拿查询词兜底`() {
        assertNull(DoubanParsing.detail("""{"id":"1","type":"movie"}""", "查询词"))
        assertNull(DoubanParsing.detail("""{"id":"1","title":""}""", "查询词"))
        assertNull(DoubanParsing.detail("""{"id":"1","title":"   "}""", "查询词"))
        assertNull(DoubanParsing.detail("not json", "查询词"))
    }

    @Test
    fun `详情字段全部落位`() {
        val meta = DoubanParsing.detail(
            detailBody(id = "34874646", type = "tv", title = "繁花"),
            "繁花",
        )!!

        assertEquals("繁花", meta.title)
        assertEquals(2023, meta.year)
        assertEquals("Blossoms Shanghai", meta.originalTitle)
        assertEquals(8.5, meta.rating!!, 0.001)
        assertEquals(listOf("剧情", "爱情"), meta.genres)
        assertEquals(ScrapeSource.online, meta.source)
        assertEquals("繁花", meta.matchedQuery)
        // 豆瓣详情没有独立的剧照字段（`pic` 是同一张海报的大小档），所以背景图留空。
        assertNull(meta.backdropUrl)
    }

    /**
     * 海报地址在落库前就被改写（坑 #5 的姊妹坑，见 [DoubanParsing.rewritePosterUrl]）。
     *
     * ⛔ 落在 `ScrapedMetadata.posterUrl` 上的**必须是改写后的**地址：库里那一列
     *    会被 Android 端拿去下载海报，而 `img*` 子域即使带对 `Referer` 也回 403。
     */
    @Test
    fun `详情里的海报地址已被改写`() {
        val meta = DoubanParsing.detail(
            detailBody(id = "1", type = "movie", title = "片"),
            "片",
        )!!
        assertTrue(
            "期望改写后的地址，实际=${meta.posterUrl}",
            meta.posterUrl!!.startsWith("https://qnmob3-sign.doubanio.com/"),
        )
    }

    /** 国产片的 `original_title` 实测是空串（不是缺失）⇒ 读成 `null`，不是 `""`。 */
    @Test
    fun `空 original_title 读成 null`() {
        val body = """
            { "id": "1", "type": "movie", "title": "流浪地球2", "original_title": "" }
        """.trimIndent()
        assertNull(DoubanParsing.detail(body, "流浪地球2")!!.originalTitle)
    }

    // ==================================================================
    // need_login 判定
    // ==================================================================

    /** ⛔ **坑 #5**：业务码可能是数字 `103`、也可能是字符串 `"103"`。 */
    @Test
    fun `业务码 103 的两种写法都认`() {
        assertTrue(DoubanParsing.isNeedLogin("""{"msg":"need_login","code":103}"""))
        assertTrue(DoubanParsing.isNeedLogin("""{"code":"103"}"""))
        assertTrue(DoubanParsing.isNeedLogin("""{"msg":"need_login"}"""))
    }

    @Test
    fun `正常响应与空响应都不算 need_login`() {
        assertFalse(DoubanParsing.isNeedLogin("""{"id":"1","title":"片"}"""))
        assertFalse(DoubanParsing.isNeedLogin(""))
        assertFalse(DoubanParsing.isNeedLogin("<html>403</html>"))
        // ⛔ `code` 是别的业务码时不能误判 —— 否则一次普通失败会把源熔断十分钟。
        assertFalse(DoubanParsing.isNeedLogin("""{"code":404,"msg":"not found"}"""))
    }

    // ==================================================================
    // 海报地址改写
    // ==================================================================

    @Test
    fun `img 子域被改写到 qnmob3-sign`() {
        val raw = "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p123.jpg"
        assertEquals(
            "https://qnmob3-sign.doubanio.com/view/photo/m_ratio_poster/public/p123.jpg",
            DoubanParsing.rewritePosterUrl(raw),
        )
        // 其它 img* 子域同理（实测 img3 / img9 都会 403/418）。
        assertTrue(
            DoubanParsing.rewritePosterUrl(
                "https://img9.doubanio.com/view/photo/m_ratio_poster/public/p9.jpg",
            )!!.startsWith("https://qnmob3-sign.doubanio.com/"),
        )
    }

    /** 已经是目标域名时**原样返回**（幂等）—— 详情接口有时直接给的就是它。 */
    @Test
    fun `已是目标域名时幂等`() {
        val raw = "https://qnmob3-sign.doubanio.com/view/photo/x.jpg"
        assertEquals(raw, DoubanParsing.rewritePosterUrl(raw))
    }

    /**
     * ⛔ **不误伤 TMDB**：这个函数在豆瓣的解析里，但 TMDB 的海报地址也会经过
     *    `ScrapedMetadata.posterUrl` 这条线（跨端同形），改错了就是「TMDB 刮到
     *    了但海报全是灰块」。
     */
    @Test
    fun `非豆瓣域名原样返回`() {
        val tmdb = "https://image.tmdb.org/t/p/w500/abc.jpg"
        assertEquals(tmdb, DoubanParsing.rewritePosterUrl(tmdb))
        // 只是**含有** `doubanio.com` 字样的域名不算豆瓣的子域。
        val lookalike = "https://notdoubanio.com/x.jpg"
        assertEquals(lookalike, DoubanParsing.rewritePosterUrl(lookalike))
        val pathLike = "https://example.com/img3.doubanio.com/x.jpg"
        assertEquals(pathLike, DoubanParsing.rewritePosterUrl(pathLike))
    }

    @Test
    fun `空地址与畸形地址不抛`() {
        assertNull(DoubanParsing.rewritePosterUrl(null))
        assertNull(DoubanParsing.rewritePosterUrl(""))
        assertNull(DoubanParsing.rewritePosterUrl("   "))
        // 解析不出 host 的原样返回（不是 null）——「有值但没法改写」与「没有值」
        // 是两件事，调用方按空处理即可，别在这里替它决定。
        assertEquals("不是个 URL", DoubanParsing.rewritePosterUrl("不是个 URL"))
    }

    // ==================================================================
    // 熔断
    // ==================================================================

    /**
     * 额度耗尽（`103`）要熔断，**而且熔断必须会过期**。
     *
     * 时间轴（初始冷却 30s，每次翻倍）：
     *   t=0     第一次搜 → 拿到 103 → 熔断到 30s
     *   t=10s   熔断期内 → **不发请求**
     *   t=31s   已过期 → 重新发（这是「用户去贴了 Cookie 回来」的路径）
     */
    @Test
    fun `额度耗尽会熔断 且熔断会过期`() {
        var t = 0L
        val http = FakeHttp { ScrapeResponse(200, """{"code":103,"msg":"need_login"}""") }
        val scraper = DoubanScraper(http = http, now = { t })

        assertTrue(scraper.search(query()).isEmpty())
        assertEquals(1, http.urls.size)

        t = 10_000
        assertTrue(scraper.search(query()).isEmpty())
        assertEquals("熔断期内不该再发请求（继续烧额度）", 1, http.urls.size)

        t = 31_000
        assertTrue(scraper.search(query()).isEmpty())
        assertEquals("熔断过期后必须重新允许尝试", 2, http.urls.size)
    }

    /**
     * ⛔ 业务码判在**状态码之前**：`103` 实测既见过 200 也见过 403。
     *
     * 只看状态码的话，403 那一次会被读成「网络抖了一下」⇒ 不熔断 ⇒ 继续烧额度
     * ⇒ 用户看到的是「豆瓣一条都刮不到」，而日志里全是普通的 HTTP 403。
     */
    @Test
    fun `HTTP 403 带 103 业务码时同样熔断`() {
        var t = 0L
        val http = FakeHttp { ScrapeResponse(403, """{"code":103,"msg":"need_login"}""") }
        val scraper = DoubanScraper(http = http, now = { t })

        scraper.search(query())
        assertEquals(1, http.urls.size)

        t = 1_000
        scraper.search(query())
        assertEquals("403 里的 103 没被识别成熔断信号", 1, http.urls.size)
    }

    /** 反向断言：**普通的** 403（body 里没有 103）不该熔断，否则一次网关抽风就停十分钟。 */
    @Test
    fun `普通 403 不熔断`() {
        var t = 0L
        val http = FakeHttp { ScrapeResponse(403, "forbidden") }
        val scraper = DoubanScraper(http = http, now = { t })

        scraper.search(query())
        scraper.search(query())
        assertEquals(2, http.urls.size)
    }

    // ==================================================================
    // 请求形状
    // ==================================================================

    /** ⛔ `Referer` 必带：少了它接口直接拒绝（实测）。 */
    @Test
    fun `请求必带 Referer`() {
        val http = FakeHttp { ScrapeResponse(200, "{}") }
        DoubanScraper(http = http).search(query())

        assertEquals(DoubanScraper.REFERER, http.headers["Referer"])
        assertNotNull(http.headers["User-Agent"])
    }

    /** 配了 Cookie 才带 Cookie —— 空串时**不能**带一个空的 `Cookie:` 头。 */
    @Test
    fun `Cookie 配了才带`() {
        val without = FakeHttp { ScrapeResponse(200, "{}") }
        DoubanScraper(http = without, cookie = "").search(query())
        assertFalse(without.headers.containsKey("Cookie"))

        val with = FakeHttp { ScrapeResponse(200, "{}") }
        DoubanScraper(http = with, cookie = " bid=abc ").search(query())
        assertEquals("bid=abc", with.headers["Cookie"])
    }

    /** 片名里的 `&` / `+` / 空格必须编码，否则搜的是完全不同的词。 */
    @Test
    fun `搜索词被 URL 编码`() {
        val http = FakeHttp { ScrapeResponse(200, "{}") }
        DoubanScraper(http = http).search(ScrapeQuery("A&B + C"))

        val url = http.urls.single()
        assertTrue(url, url.contains("q=A%26B+%2B+C"))
    }

    /** 空搜索词直接返回空，**不发请求**（不然白烧一个额度）。 */
    @Test
    fun `空搜索词不发请求`() {
        val http = FakeHttp { ScrapeResponse(200, "{}") }
        assertTrue(DoubanScraper(http = http).search(ScrapeQuery("   ")).isEmpty())
        assertEquals(0, http.urls.size)
    }

    /** 详情请求走的是 `/movie/{id}`（剧集会由服务端 301 过去），且带上 `for_mobile=1`。 */
    @Test
    fun `详情请求的路径与参数`() {
        val http = FakeHttp { ScrapeResponse(200, detailBody("1", "movie", "片")) }
        DoubanScraper(http = http).resolve(
            ScrapeCandidate("douban", "1292052", "片", null, "movie", null),
        )

        val url = http.urls.single()
        assertTrue(url, url.endsWith("/movie/1292052?for_mobile=1"))
    }

    /** 来源不是豆瓣的候选，本刮削器**不接**（避免流水线串源）。 */
    @Test
    fun `非本源的候选返回 null`() {
        val http = FakeHttp { ScrapeResponse(200, detailBody("1", "movie", "片")) }
        assertNull(
            DoubanScraper(http = http).resolve(
                ScrapeCandidate("tmdb", "1", "片", null, "movie", null),
            ),
        )
        assertEquals(0, http.urls.size)
    }

    // ==================================================================
    // 测试凭证（probe）
    // ==================================================================

    /** 一条**含 `dbcl2`** 的 Cookie —— 形状上就是登录态。 */
    private val loginCookie = "ll=\"108304\"; bid=VNskJTU3PRo; dbcl2=\"1234567:abcdef\""

    /** 一份「正常」的搜索响应（有一条影视候选）。 */
    private fun searchBody() = """
        {
          "subjects": { "items": [
            { "target_type": "movie", "target": { "id": 1292052, "title": "流浪地球", "year": "2019" } }
          ] }
        }
    """.trimIndent()

    /**
     * 正常时要说清「搜到几条」+「**Cookie 是不是登录态**」。
     *
     * ⛔ 后半句是关键：额度宽不宽只由 `dbcl2` 决定，而用户从界面上看不出
     *    自己贴的是登录态还是匿名串。
     */
    @Test
    fun `probe 正常时报告条数并认出登录态`() {
        val http = FakeHttp { ScrapeResponse(200, searchBody()) }
        val r = DoubanScraper(http = http, cookie = loginCookie).probe()

        assertTrue(r.ok)
        assertTrue("要提到探针词，用户才知道它真的搜了", r.message.contains(DoubanScraper.PROBE_WORD))
        assertTrue("要认出 dbcl2", r.message.contains("登录态"))
    }

    /** 没有 `dbcl2` ⇒ 走匿名额度，必须提醒（约 10 个搜索词就会耗尽）。 */
    @Test
    fun `probe 无 dbcl2 时提示是匿名额度`() {
        val http = FakeHttp { ScrapeResponse(200, searchBody()) }
        val r = DoubanScraper(http = http, cookie = "ll=\"108304\"; bid=x").probe()

        assertTrue(r.ok)
        assertTrue(r.message.contains("匿名"))
    }

    /**
     * ⛔ `103 need_login` 是**第三种**失败（额度耗尽 / 被风控），
     *    与「网络不通」「Cookie 形状不对」的处置办法完全不同。
     */
    @Test
    fun `probe 遇到 103 时说清是限流还是 Cookie 失效`() {
        val http = FakeHttp { ScrapeResponse(200, """{"code":103,"msg":"need_login"}""") }
        val r = DoubanScraper(http = http, cookie = loginCookie).probe()

        assertFalse(r.ok)
        assertTrue(r.message.contains("103"))
        assertTrue("含 dbcl2 时应指出多半是被限流", r.message.contains("限流"))
    }

    /** 不带 `dbcl2` 却拿到 103 ⇒ 要指向「Cookie 不是登录态」，而不是让用户干等。 */
    @Test
    fun `probe 遇到 103 且无 dbcl2 时指向 Cookie 形状`() {
        val http = FakeHttp { ScrapeResponse(200, """{"code":103,"msg":"need_login"}""") }
        val r = DoubanScraper(http = http, cookie = "bid=x").probe()

        assertFalse(r.ok)
        assertTrue(r.message.contains("dbcl2"))
    }

    /** 网络层失败要说「连不上」，而不是笼统的「测试失败」。 */
    @Test
    fun `probe 网络失败时说连不上`() {
        val http = FakeHttp { throw java.net.SocketTimeoutException("timeout") }
        val r = DoubanScraper(http = http, cookie = loginCookie).probe()

        assertFalse(r.ok)
        assertTrue(r.message.contains("连不上"))
    }

    /** 接口通、Cookie 没被拒，但探针词零结果 ⇒ 多半是接口改版，要说出来。 */
    @Test
    fun `probe 零结果时指向接口改版`() {
        val http = FakeHttp { ScrapeResponse(200, """{"subjects":{"items":[]}}""") }
        val r = DoubanScraper(http = http, cookie = loginCookie).probe()

        assertFalse(r.ok)
        assertTrue(r.message.contains("零结果"))
    }

    /** 没填 Cookie ⇒ **不发请求**（探针本身要烧额度，空 Cookie 必定失败）。 */
    @Test
    fun `probe 没填 Cookie 时不发请求`() {
        val http = FakeHttp { ScrapeResponse(200, searchBody()) }
        val r = DoubanScraper(http = http, cookie = "").probe()

        assertFalse(r.ok)
        assertEquals(0, http.urls.size)
    }

    /**
     * ⛔ `probe` **不碰熔断**。
     *
     * 它是用户手动问的一句，结论已经直接回在设置页上了；顺手把刮削也熔断掉，
     * 会让「刚测完就去刮」莫名其妙搜不动 —— 而用户完全无从归因。
     */
    @Test
    fun `probe 遇到 103 不熔断后续搜索`() {
        val http = FakeHttp { ScrapeResponse(200, """{"code":103,"msg":"need_login"}""") }
        val scraper = DoubanScraper(http = http, cookie = loginCookie)

        scraper.probe()
        scraper.search(query())

        assertEquals("probe 不该把刮削也熔断掉", 2, http.urls.size)
    }

    /** 登录态判据：`dbcl2=` 才算；`xdbcl2=` **不算**（前缀被 `(^|;)` 钉死）。 */
    @Test
    fun `登录态判据认 dbcl2 且不被 xdbcl2 误判`() {
        assertTrue(DoubanScraper.cookieHasLoginToken("ll=\"1\";dbcl2=x"))
        assertTrue(DoubanScraper.cookieHasLoginToken("ll=\"1\"; dbcl2=x"))
        assertFalse(DoubanScraper.cookieHasLoginToken("ll=\"1\"; xdbcl2=x"))
        assertFalse(DoubanScraper.cookieHasLoginToken("bid=abc"))
    }

    /**
     * 把 `Cookie: ` 前缀一起贴进来是很常见的错法。
     *
     * ⛔ 必须**在发请求之前**认出来：它会让服务端回 `103`，而 103 看起来像
     *    「被限流」，用户会往完全错误的方向查。
     */
    @Test
    fun `能认出把 Cookie 前缀一起贴进来的错法`() {
        assertTrue(DoubanScraper.looksLikeRawHeader("Cookie: ll=\"1\"; bid=x"))
        assertTrue(DoubanScraper.looksLikeRawHeader("  cookie :ll=1"))
        assertFalse(DoubanScraper.looksLikeRawHeader("ll=\"1\"; bid=x"))
    }

    // ==================================================================
    // 夹具
    // ==================================================================

    private fun query(title: String = "繁花") = ScrapeQuery(title)

    /** 一份「正常」的详情响应。 */
    private fun detailBody(id: String, type: String, title: String) = """
        {
          "id": "$id",
          "type": "$type",
          "title": "$title",
          "original_title": "Blossoms Shanghai",
          "year": "2023",
          "intro": "九十年代的上海。",
          "cover_url": "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg",
          "rating": { "value": 8.5, "count": 100 },
          "genres": ["剧情", "爱情"]
        }
    """.trimIndent()

    /** 按 URL 返回固定响应的假 HTTP；同时记下请求过的 URL 与最后一次的请求头。 */
    private class FakeHttp(private val responder: (String) -> ScrapeResponse) : ScrapeHttpLike {
        val urls = ArrayList<String>()
        var headers: Map<String, String> = emptyMap()
            private set

        override fun get(url: String, headers: Map<String, String>, timeoutMs: Int): ScrapeResponse {
            urls += url
            this.headers = headers
            return responder(url)
        }

        override fun getBytes(url: String, headers: Map<String, String>, timeoutMs: Int): ByteArray? {
            urls += url
            this.headers = headers
            return null
        }
    }
}
