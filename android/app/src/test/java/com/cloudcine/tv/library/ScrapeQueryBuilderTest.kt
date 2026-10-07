package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 刮削查询词的**构造口径** —— [ScrapeQueryBuilder]。
 *
 * ## 为什么这一组必须钉死
 *
 * 它同时被**手动刮削页的预填**（`ScrapeActivity.prefill`）与**扫描后的自动刮削**
 * （`AutoScraper`）使用。两处只要有一处换了挑文件的口径（比如忘了滤花絮、
 * 或者漏传 `dirPath`），同一个作品就会「手动刮出来是 A、自动刮出来是 B」——
 * 而这是**静默的**，用户只会觉得「这个刮削有时候不准」。
 *
 * 其中 `requireExactTitle` 最要紧：它决定闸门走哪一档。少设这一个 `true`，
 * 无年份的电影会**静默刮错**（`奥德赛` → 《奥德赛：归来》），而不是刮不到。
 */
class ScrapeQueryBuilderTest {

    // ==================================================================
    // 片名能不能用
    // ==================================================================

    /** 含至少一个字母或汉字才算了名字；纯数字 / 纯符号不算。 */
    @Test
    fun `可信片名要求含字母或汉字`() {
        assertTrue(ScrapeQueryBuilder.hasUsableTitle("阿凡达"))
        assertTrue(ScrapeQueryBuilder.hasUsableTitle("Dune"))
        assertTrue(ScrapeQueryBuilder.hasUsableTitle("流浪地球2"))
        assertFalse(ScrapeQueryBuilder.hasUsableTitle("182"))
        assertFalse(ScrapeQueryBuilder.hasUsableTitle("1080"))
        assertFalse(ScrapeQueryBuilder.hasUsableTitle("—— · ——"))
        assertFalse(ScrapeQueryBuilder.hasUsableTitle(""))
    }

    // ==================================================================
    // 该走哪一档闸门
    // ==================================================================

    /**
     * ⛔ 「电影且没有年份」⇒ 只认精确同名。
     *
     * 这一类没有年份硬闸门兜底，只剩标题相似度，而严格档的 0.6 阈值是为
     * 「有年份」定的 —— 它会让 `奥德赛` 配到《奥德赛：归来》（0.86）通过。
     */
    @Test
    fun `电影没有年份时要求精确同名`() {
        assertTrue(ScrapeQueryBuilder.requiresExactTitle(ScrapeQueryBuilder.KIND_MOVIE, null))
    }

    /** 有年份的电影走严格档：年份硬闸门自己就能消歧。 */
    @Test
    fun `电影有年份时不要求精确同名`() {
        assertFalse(ScrapeQueryBuilder.requiresExactTitle(ScrapeQueryBuilder.KIND_MOVIE, 1997))
    }

    /** 剧集不靠年份消歧（季集号自己就能定位），一律走严格档。 */
    @Test
    fun `剧集不要求精确同名`() {
        assertFalse(ScrapeQueryBuilder.requiresExactTitle("episode", null))
        assertFalse(ScrapeQueryBuilder.requiresExactTitle("episode", 2024))
    }

    /**
     * `unknown` 不要求精确同名 —— 它在 Android 的解析器里**只出现在片名为空时**，
     * 而空片名已经被 [ScrapeQueryBuilder.hasUsableTitle] 挡在前面了。
     * 这里钉住「它不会走宽松档」，避免有人以为漏了一条判据。
     */
    @Test
    fun `unknown 不要求精确同名`() {
        assertFalse(ScrapeQueryBuilder.requiresExactTitle("unknown", null))
    }

    // ==================================================================
    // 从作品的文件里取查询词
    // ==================================================================

    /** 一部普通电影：片名与年份都从文件名解析出来，走严格档。 */
    @Test
    fun `普通电影取到片名与年份`() {
        val q = ScrapeQueryBuilder.forItems(listOf(item("阿凡达：火与烬.2025.2160p.WEB-DL.mkv")))
        assertNotNull(q)
        assertEquals("阿凡达：火与烬", q!!.title)
        assertEquals(2025, q.year)
        assertEquals(ScrapeQueryBuilder.KIND_MOVIE, q.kind)
        assertFalse(q.requireExactTitle)
    }

    /** ⛔ 无年份的电影走**宽松档** —— 这一个 `true` 是防「静默刮错」的开关。 */
    @Test
    fun `无年份的电影走宽松档`() {
        val q = ScrapeQueryBuilder.forItems(listOf(item("奥德赛.1080p.mkv")))
        assertNotNull(q)
        assertEquals("奥德赛", q!!.title)
        assertNull(q.year)
        assertTrue(q.requireExactTitle)
    }

    /** 剧集：片名在文件名里，季集号不该混进查询词。 */
    @Test
    fun `剧集取到干净的片名`() {
        val q = ScrapeQueryBuilder.forItems(
            listOf(item("进击的巨人.S01E01.1080p.mkv", dirPath = "/动漫/进击的巨人/")),
        )
        assertNotNull(q)
        assertEquals("进击的巨人", q!!.title)
        assertEquals("episode", q.kind)
        assertFalse(q.requireExactTitle)
    }

    /**
     * ⛔ **花絮 / 样片必须先滤掉**。
     *
     * `-trailer.mkv` 解析出来的片名常常带着 `trailer`，拿它去搜只会搜到一堆
     * 不相关的东西。挑法与详情页「播放」按钮一致。
     */
    @Test
    fun `跳过花絮与样片`() {
        val q = ScrapeQueryBuilder.forItems(
            listOf(
                item("阿凡达：火与烬.2025.预告片.mkv", sample = true),
                item("阿凡达：火与烬.2025.1080p.mkv"),
            ),
        )
        assertNotNull(q)
        assertEquals("阿凡达：火与烬", q!!.title)
    }

    /** 整个作品只有花絮时退回全集 —— 总比没有查询词强。 */
    @Test
    fun `只有花絮时退回全集`() {
        val q = ScrapeQueryBuilder.forItems(
            listOf(item("阿凡达：火与烬.2025.预告片.mkv", sample = true)),
        )
        assertNotNull(q)
        assertEquals("阿凡达：火与烬", q!!.title)
    }

    /**
     * ⛔ **`dirPath` 必须传**：片名常常只写在目录上（`/动漫/进击的巨人/01.mp4`）。
     *
     * 漏传不会报错，只会让这一类作品永远刮不到 —— 而且同一部作品在
     * 「手动刮削」里（那边传了 `dirPath`）刮得到，自动刮削里刮不到。
     */
    @Test
    fun `传了目录名才能从目录里救回片名`() {
        val withDir = ScrapeQueryBuilder.forItems(
            listOf(item("01.mp4", dirPath = "/动漫/进击的巨人/")),
        )
        assertNotNull(withDir)
        assertEquals("进击的巨人", withDir!!.title)

        // 不传目录 ⇒ 片名退化成 `01` ⇒ 不是名字 ⇒ 没有可查的东西。
        assertNull(ScrapeQueryBuilder.forItems(listOf(item("01.mp4", dirPath = "/"))))
    }

    /** 只剩技术标记的文件名（`S01E01.1080p.mkv`）解析不出片名 ⇒ 没有可查的东西。 */
    @Test
    fun `只剩技术标记的文件名给出空查询`() {
        assertNull(ScrapeQueryBuilder.forItems(listOf(item("S01E01.1080p.mkv", dirPath = "/"))))
        assertNull(ScrapeQueryBuilder.forItems(listOf(item("1080p.mkv", dirPath = "/"))))
    }

    /** 一部文件都没有（作品行还在、文件已被清理）⇒ 空查询。 */
    @Test
    fun `没有文件时给出空查询`() {
        assertNull(ScrapeQueryBuilder.forItems(emptyList()))
    }

    /**
     * 一条文件解析不出片名、下一条能 —— 应当**继续往下找**，而不是直接放弃。
     *
     * 真实场景：一部剧里混着 `S01E01.1080p.mkv`（无片名）与
     * `进击的巨人.S01E02.1080p.mkv`（有片名）。
     */
    @Test
    fun `逐条往下找到第一个可信片名`() {
        val q = ScrapeQueryBuilder.forItems(
            listOf(
                item("S01E01.1080p.mkv", dirPath = "/"),
                item("流浪地球.2019.1080p.mkv", dirPath = "/"),
            ),
        )
        assertNotNull(q)
        assertEquals("流浪地球", q!!.title)
    }

    // ==================================================================
    // 测试脚手架
    // ==================================================================

    /**
     * 造一条媒体项。
     *
     * ⛔ 只填**本测试用得到**的字段，其余给默认值：`ScrapeQueryBuilder` 只看
     *    `name` / `dirPath` / `isSampleOrExtra` 三项（其余都靠重新解析）。
     */
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
