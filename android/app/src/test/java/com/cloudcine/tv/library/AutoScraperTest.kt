package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/**
 * 扫描后的**自动刮削** —— [AutoScraper]。
 *
 * ## 为什么这一组必须钉死
 *
 * 这是全工程唯一会「无人值守地跑很久」的动作：一次扫描之后可能连着刮几百部。
 * 它出错的方式全是**静默**的 ——
 *
 * 1. **把片子刮错**：没有闸门就会把 PC 端 2026-10-01 那次事故复制到整库
 *    （查询词带 `2026`，刮成 1994 年的片子）。所以这里钉住「年份差太远必须拒」。
 * 2. **卡死不走**：源全挂了还在那儿一部部等超时（电视上最常见的结局 ——
 *    TMDB 官方地址被 DNS 污染）。所以这里钉住两条提前退出的路。
 * 3. **该走不走 / 不该走乱走**：`GIVE_UP_AFTER` 那条的附加条件是「至今零成功」，
 *    而且**认不出片名不算源的问题** —— 少一个条件，一库自制视频会让它一开机
 *    就放弃，用户看到的却是「刮削提前停止」。
 *
 * ⛔ 循环逻辑全靠**假库 + 假源**验，不碰 `LibraryDb`（JVM 单测里
 *    `SQLiteDatabase` 起不来）：真库上造不出「145 部作品 + 源全挂」的现场。
 */
class AutoScraperTest {

    // ==================================================================
    // 基本口径
    // ==================================================================

    /** 没有待刮的作品 ⇒ 一句话说清，不报错。 */
    @Test
    fun `没有待刮的作品时直接收工`() {
        val store = FakeStore(emptyList(), emptyMap())
        val out = scraper(store, listOf(source("tmdb"))).run()

        assertEquals(0, out.total)
        assertEquals(0, out.done)
        assertFalse(out.stopped)
        assertFalse(out.cancelled)
        assertEquals("没有需要刮削的作品（都已刮过）", out.message)
    }

    /**
     * ⛔ 一次最多处理 500 部（`WORK_LIMIT`）。
     *
     * 库大的用户第一次扫描会有几千部待刮，一次跑完既不现实也浪费时间
     * （用户可能马上又要扫描）。这个上限是**分批**的保证。
     */
    @Test
    fun `查待刮作品时带上分批上限`() {
        val store = FakeStore(listOf(work("a")), mapOf("a" to listOf(item("流浪地球.2019.mkv"))))
        scraper(store, listOf(source("tmdb"))).run()
        assertEquals(500, store.lastLimit)
    }

    /** 成功一部：落库 + 回写海报文件名。 */
    @Test
    fun `命中一部会落库并下载海报`() {
        val dir = Files.createTempDirectory("autoscraper-poster").toFile()
        val store = FakeStore(
            listOf(work("a")),
            mapOf("a" to listOf(item("流浪地球.2019.1080p.mkv"))),
        )
        val tmdb = source("tmdb").apply {
            results = listOf(listOf(cand("tmdb", "1", "流浪地球", 2019)))
            resolveResult = meta("流浪地球", 2019, poster = "https://img.example.com/a.jpg")
        }

        val out = scraper(store, listOf(tmdb), posterDir = dir).run()

        assertEquals(1, out.scraped)
        assertEquals(1, out.total)
        assertFalse(out.stopped)
        assertNotNull(store.updated["a"])
        assertEquals("流浪地球", store.updated.getValue("a").title)
        // 海报文件名回写 —— 墙上那一块才会从灰变亮。
        assertNotNull(store.posters["a"])
        assertEquals(1, store.posters.size)
    }

    /** 海报下不下来**不影响**元数据落库（海报只是增强）。 */
    @Test
    fun `海报下载失败仍然算命中`() {
        val store = FakeStore(
            listOf(work("a")),
            mapOf("a" to listOf(item("流浪地球.2019.1080p.mkv"))),
        )
        val tmdb = source("tmdb").apply {
            results = listOf(listOf(cand("tmdb", "1", "流浪地球", 2019)))
            resolveResult = meta("流浪地球", 2019, poster = "https://img.example.com/a.jpg")
        }

        val out = scraper(store, listOf(tmdb), posterBytes = null).run()

        assertEquals(1, out.scraped)
        assertNotNull(store.updated["a"])
        assertTrue(store.posters.isEmpty())
    }

    /** 候选解析不出完整信息 ⇒ 按未命中处理，不落库。 */
    @Test
    fun `候选解析不出信息时按未命中处理`() {
        val store = FakeStore(
            listOf(work("a")),
            mapOf("a" to listOf(item("流浪地球.2019.1080p.mkv"))),
        )
        val tmdb = source("tmdb").apply {
            results = listOf(listOf(cand("tmdb", "1", "流浪地球", 2019)))
            resolveResult = null
        }

        val out = scraper(store, listOf(tmdb)).run()

        assertEquals(1, out.notFound)
        assertTrue(store.updated.isEmpty())
    }

    // ==================================================================
    // 闸门
    // ==================================================================

    /**
     * ⛔ **年份差太远必须拒** —— 这就是 PC 端 2026-10-01 那次事故的形状。
     *
     * 查询词带 `2025`，源返回了 1994 年的同名条目；没有年份硬闸门时
     * 它会被当成命中写进库里，而用户看到的是「这部片子刮到了另一部」。
     */
    @Test
    fun `年份差太远的候选会被闸门拒掉`() {
        val store = FakeStore(
            listOf(work("a")),
            mapOf("a" to listOf(item("阿凡达：火与烬.2025.2160p.WEB-DL.mkv"))),
        )
        val tmdb = source("tmdb").apply {
            results = listOf(listOf(cand("tmdb", "1", "阿凡达：火与烬", 1994)))
            resolveResult = meta("阿凡达：火与烬", 1994)
        }

        val out = scraper(store, listOf(tmdb)).run()

        assertEquals(1, out.notFound)
        assertTrue("被闸门拒掉的候选绝不能落库", store.updated.isEmpty())
    }

    /**
     * 闸门取的是**第一条过得了的**候选，不是第一条候选。
     *
     * 源的相关度排序里，同名但年份不符的条目排在同名同年份之前是常见情况
     * （重制版 / 同名老片）。跳过它、继续往下找，才不至于「因为第一条不合格
     * 就整部放弃」。
     */
    @Test
    fun `闸门跳过不合格的候选继续往下找`() {
        val store = FakeStore(
            listOf(work("a")),
            mapOf("a" to listOf(item("阿凡达：火与烬.2025.2160p.WEB-DL.mkv"))),
        )
        val tmdb = source("tmdb").apply {
            results = listOf(
                listOf(
                    cand("tmdb", "1", "阿凡达：火与烬", 1994),
                    cand("tmdb", "2", "阿凡达：火与烬", 2025),
                ),
            )
            resolveResult = meta("阿凡达：火与烬", 2025)
        }

        val out = scraper(store, listOf(tmdb)).run()

        assertEquals(1, out.scraped)
        assertEquals(2025, store.updated.getValue("a").year)
    }

    /**
     * ⛔ **认不出片名不是源的错**，不能累加「连续零命中」。
     *
     * 库里堆一批 `S01E01.1080p.mkv` 这种解析不出片名的文件时，如果不排除它们，
     * 连续 12 部就会触发提前收工 —— 而源其实一次都没被问过。
     */
    @Test
    fun `认不出片名的作品不会把源拖成提前收工`() {
        val works = (1..20).map { work("w$it") }
        // 文件名只剩技术标记 ⇒ 没有可查的东西。
        val items = works.associate { it.key to listOf(item("S01E01.1080p.mkv", dirPath = "/")) }
        val store = FakeStore(works, items)
        val tmdb = source("tmdb")

        val out = scraper(store, listOf(tmdb)).run()

        assertEquals(20, out.noQuery)
        assertEquals(20, out.done)
        assertFalse("认不出片名不该触发提前收工", out.stopped)
        assertEquals("一个候选都不该问", 0, tmdb.calls)
    }

    // ==================================================================
    // 三条提前退出的路
    // ==================================================================

    /** 用户取消：在**作品之间**生效，已刮好的那几部保留。 */
    @Test
    fun `用户取消后立刻收工并保留已刮的成果`() {
        val works = (1..10).map { work("w$it") }
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)
        val cancel = LibraryScanner.Cancellation()
        val tmdb = source("tmdb").apply {
            results = listOf(listOf(cand("tmdb", "1", "流浪地球", 2019)))
            resolveResult = meta("流浪地球", 2019)
            onSearch = { cancel.cancel() }
        }

        val out = scraper(store, listOf(tmdb), cancel = cancel).run()

        assertTrue(out.cancelled)
        assertFalse(out.stopped)
        assertEquals(1, out.done)
        assertEquals(1, out.scraped)
        assertTrue(out.message.startsWith("刮削已停止"))
    }

    /**
     * 源**全部**被摘掉 ⇒ 提前收工。
     *
     * 判据是「慢且空」（[ScrapeSourceBudget]）：连续 3 次超时且无结果才算
     * 「这个源连不上」。电视上最常见的结局就是这一条 —— TMDB 官方地址
     * 被 DNS 污染，每次都要烧完 12 秒超时。
     */
    @Test
    fun `所有源都连不上时提前收工`() {
        val works = (1..10).map { work("w$it") }
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)
        val tmdb = source("tmdb")
        val douban = source("douban", name = "豆瓣")

        val out = scraper(
            store,
            listOf(tmdb, douban),
            clock = FakeClock(step = 9_000L),
        ).run()

        assertTrue(out.stopped)
        assertFalse(out.cancelled)
        assertEquals("两个源各 3 次超时后收工", 3, out.done)
        assertEquals(listOf("TMDB", "豆瓣"), out.droppedSources)
        assertTrue(out.message.contains("连不上"))
    }

    /**
     * ⛔ **凭证被拒**那条路：请求**很快**返回 401，所以「慢」的启发式摘不掉它，
     * 只能靠「连续 12 部零命中且至今零成功」兜住。
     *
     * 少了这一条，用户填错 Key 之后要瞪着进度条看完几百部作品。
     */
    @Test
    fun `凭证被拒时靠连续零命中提前收工`() {
        val works = (1..30).map { work("w$it") }
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)
        // 快且空：请求立刻返回、没有候选 —— 源摘不掉。
        val tmdb = source("tmdb")

        val out = scraper(store, listOf(tmdb)).run()

        assertTrue(out.stopped)
        assertEquals(12, out.done)
        assertEquals(12, out.notFound)
        assertEquals(0, out.scraped)
        assertTrue("源没被摘掉，不该说「连不上」", out.droppedSources.isEmpty())
    }

    /**
     * ⛔ 「至今零成功」这个附加条件不能省：中途成功过一次，说明源是好的，
     * 后面的零命中只是「这些片子源里没有」，不该提前收工。
     */
    @Test
    fun `成功过一次之后不再因连续零命中收工`() {
        val works = (1..20).map { work("w$it") }
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)
        val tmdb = source("tmdb").apply {
            // 第 6 部与第 18 部命中，其余为空。
            results = (1..20).map { n ->
                if (n == 6 || n == 18) listOf(cand("tmdb", "$n", "流浪地球", 2019)) else emptyList()
            }
            resolveResult = meta("流浪地球", 2019)
        }

        val out = scraper(store, listOf(tmdb)).run()

        assertEquals("第 12 部时连续零命中只有 6 次，不该收工", 20, out.done)
        assertEquals(2, out.scraped)
        assertFalse(out.stopped)
    }

    // ==================================================================
    // 容错
    // ==================================================================

    /** 一个源搜挂了，另一个源的候选照样用（与 `ScraperPipeline` 同一取向）。 */
    @Test
    fun `一个源搜挂不影响另一个源`() {
        val store = FakeStore(
            listOf(work("a")),
            mapOf("a" to listOf(item("流浪地球.2019.1080p.mkv"))),
        )
        val broken = source("tmdb").apply { throwOnSearch = true }
        val douban = source("douban", name = "豆瓣").apply {
            results = listOf(listOf(cand("douban", "1", "流浪地球", 2019)))
            resolveResult = meta("流浪地球", 2019)
        }

        val out = scraper(store, listOf(broken, douban)).run()

        assertEquals(1, out.scraped)
        assertEquals(1, broken.calls)
    }

    /** 查待刮作品这一步挂了 ⇒ 返回带 `error` 的结果，**不抛异常**。 */
    @Test
    fun `查库失败时返回错误而不抛异常`() {
        val store = FakeStore(emptyList(), emptyMap()).apply { listThrows = true }

        val out = scraper(store, listOf(source("tmdb"))).run()

        assertNotNull(out.error)
        assertTrue(out.message.startsWith("刮削失败："))
    }

    /** 某一部刮的时候抛了 ⇒ 记成未命中继续往下走，不中断整批。 */
    @Test
    fun `单部作品异常不会中断整批`() {
        val works = listOf(work("a"), work("b"))
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)
        val tmdb = source("tmdb").apply {
            // 两部都有候选，但第一部解析时炸掉。
            results = listOf(
                listOf(cand("tmdb", "1", "流浪地球", 2019)),
                listOf(cand("tmdb", "2", "流浪地球", 2019)),
            )
            resolveResult = meta("流浪地球", 2019)
            failResolveTimes = 1
        }

        val out = scraper(store, listOf(tmdb)).run()

        assertEquals(2, out.done)
        assertEquals(1, out.scraped)
        assertEquals(1, out.notFound)
    }

    // ==================================================================
    // 进度
    // ==================================================================

    /**
     * 进度必须是「**第几部 / 共几部**」+ 当前片名。
     *
     * 状态行是标题栏右侧的单行 `TextView` —— 用户靠它判断「还要多久」与
     * 「有没有卡死」。只有百分比的话，一次几百部的刮削看起来就像卡住了。
     */
    @Test
    fun `进度回调带上总数与当前片名`() {
        val works = listOf(work("a", title = "流浪地球"), work("b", title = "沙丘"))
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)
        val tmdb = source("tmdb").apply {
            results = listOf(listOf(cand("tmdb", "1", "流浪地球", 2019)))
            resolveResult = meta("流浪地球", 2019)
        }

        val seen = ArrayList<AutoScraper.Progress>()
        scraper(store, listOf(tmdb)).run { seen += it }

        assertEquals("开工前先报一次，进度条才有总数", 0, seen.first().done)
        assertEquals(2, seen.first().total)
        assertEquals("刮削 0/2 · 成功 0", seen.first().text)
        assertEquals(2, seen.last().done)
        assertEquals("沙丘", seen.last().title)
        assertEquals("刮削 2/2 · 成功 2 · 沙丘", seen.last().text)
    }

    /** 源被摘掉之后，进度行改说「哪些源跳过了」—— 比片名有用。 */
    @Test
    fun `源被摘掉后进度行显示跳过的源`() {
        val works = (1..5).map { work("w$it") }
        val items = works.associate { it.key to listOf(item("流浪地球.2019.1080p.mkv")) }
        val store = FakeStore(works, items)

        val seen = ArrayList<AutoScraper.Progress>()
        scraper(
            store,
            listOf(source("tmdb")),
            clock = FakeClock(step = 9_000L),
        ).run { seen += it }

        assertTrue(seen.last().droppedSources.contains("TMDB"))
        assertTrue(seen.last().text.contains("TMDB 已跳过"))
    }

    // ==================================================================
    // 测试脚手架
    // ==================================================================

    /**
     * 一个**可编程的时钟**：每次读都往前走 [step] 毫秒。
     *
     * [AutoScraper] 用「一次 `search` 花了多久」判断源是不是挂了，而真实等待
     * 在单测里没法接受（`SLOW_MS` 是 8 秒）。把时钟换成步进器之后，
     * 「慢且空」与「快且空」这两条路都能在毫秒内复现。
     */
    private class FakeClock(private val step: Long) {
        private var now = 0L
        fun now(): Long {
            val v = now
            now += step
            return v
        }
    }

    /** 可编程的刮削源：按调用次序吐出预设的候选列表。 */
    private class FakeSource(
        override val id: String,
        override val displayName: String,
        override val enabled: Boolean = true,
    ) : MetadataScraper {
        /** 第 n 次 `search` 返回什么；用完了就重复最后一项。 */
        var results: List<List<ScrapeCandidate>> = listOf(emptyList())
        var resolveResult: ScrapedMetadata? = null
        var throwOnSearch = false

        /** 第几次 `resolve` 开始抛（用来验「单部异常不中断整批」）。 */
        var failResolveTimes = 0

        /** 每次 `search` 之后跑一下 —— 测试用它来「在中途按取消」。 */
        var onSearch: (() -> Unit)? = null

        var calls = 0
            private set

        override fun search(query: ScrapeQuery): List<ScrapeCandidate> {
            calls++
            onSearch?.invoke()
            if (throwOnSearch) throw RuntimeException("源挂了")
            val idx = minOf(calls - 1, results.size - 1)
            return results[idx]
        }

        override fun resolve(candidate: ScrapeCandidate): ScrapedMetadata? {
            if (failResolveTimes > 0) {
                failResolveTimes--
                throw RuntimeException("解析挂了")
            }
            return resolveResult
        }
    }

    /** 假的库：只实现 [AutoScrapeStore] 那四个方法。 */
    private class FakeStore(
        private val works: List<Work>,
        private val items: Map<String, List<LibraryItem>>,
    ) : AutoScrapeStore {
        val updated = LinkedHashMap<String, ScrapedMetadata>()
        val posters = LinkedHashMap<String, String>()
        var listThrows = false
        var lastLimit = -1

        override fun worksNeedingScrape(limit: Int): List<Work> {
            lastLimit = limit
            if (listThrows) throw RuntimeException("db 挂了")
            return works.take(limit)
        }

        override fun itemsForWork(workKey: String): List<LibraryItem> = items[workKey].orEmpty()

        override fun updateWorkScrape(workKey: String, meta: ScrapedMetadata): Work? {
            updated[workKey] = meta
            return works.firstOrNull { it.key == workKey }
        }

        override fun setWorkPosterFile(workKey: String, fileName: String) {
            posters[workKey] = fileName
        }
    }

    /** 假的图片下载：固定吐一份字节（或 `null` 表示下载失败）。 */
    private class FakeBytesHttp(private val bytes: ByteArray?) : ScrapeHttpLike {
        override fun get(url: String, headers: Map<String, String>, timeoutMs: Int) =
            ScrapeResponse(200, "")

        override fun getBytes(url: String, headers: Map<String, String>, timeoutMs: Int) = bytes
    }

    private fun source(id: String, name: String = "TMDB") = FakeSource(id, name)

    private fun scraper(
        store: AutoScrapeStore,
        sources: List<MetadataScraper>,
        cancel: LibraryScanner.Cancellation = LibraryScanner.Cancellation(),
        clock: FakeClock = FakeClock(step = 0L),
        posterDir: java.io.File? = null,
        posterBytes: ByteArray? = byteArrayOf(1, 2, 3),
    ): AutoScraper {
        val dir = posterDir ?: Files.createTempDirectory("autoscraper-poster").toFile()
        return AutoScraper(
            store = store,
            pipeline = ScraperPipeline(sources),
            posterFetcher = PosterFetcher(dir, FakeBytesHttp(posterBytes)),
            cancel = cancel,
            clock = clock::now,
            // ⛔ 节流在单测里毫无意义，还会让 30 部作品的用例慢 6 秒。
            sleep = {},
        )
    }

    private fun work(key: String, title: String = key) = Work(
        key = key,
        kind = "movie",
        category = "movie",
        title = title,
        originalTitle = null,
        year = null,
        overview = null,
        posterUrl = null,
        posterFile = null,
        posterFaceX = null,
        rating = null,
        genres = emptyList(),
        source = "local",
        itemCount = 1,
        totalBytes = 0L,
        seasonCount = 1,
        lastModifiedAt = null,
        firstSeenAt = null,
        lastPlayedAt = null,
        resumeFraction = null,
    )

    private fun cand(source: String, id: String, title: String, year: Int?) = ScrapeCandidate(
        source = source,
        sourceId = id,
        title = title,
        year = year,
        type = "movie",
        posterUrl = null,
    )

    private fun meta(title: String, year: Int?, poster: String? = null) = ScrapedMetadata(
        title = title,
        year = year,
        posterUrl = poster,
        onlineId = "tmdb/movie/1",
        source = ScrapeSource.online,
    )

    /** 造一条媒体项；[AutoScraper] 只看 `name` / `dirPath` / `isSampleOrExtra`。 */
    private fun item(
        name: String,
        dirPath: String = "/",
        sample: Boolean = false,
    ): LibraryItem = LibraryItem(
        id = "quark:$name",
        provider = "quark",
        fileId = "fid-$name",
        dirId = "dir",
        name = name,
        dirPath = dirPath,
        groupKey = "work",
        kind = "movie",
        title = null,
        year = null,
        season = null,
        episode = null,
        episodeEnd = null,
        part = null,
        partLabel = null,
        container = "mkv",
        resolution = null,
        sizeBytes = null,
        durationMs = null,
        resumePositionMs = null,
        maxPositionMs = null,
        lastPlayedAt = null,
        thumbUrl = null,
        faceAnchorX = null,
        videoWidth = null,
        videoHeight = null,
        isSampleOrExtra = sample,
    )
}
