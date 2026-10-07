package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 刮削模型里**纯判断**的那几处：`structureOf` / `ScrapeQuery.wantsTv` /
 * `ScrapeCandidate.subtitle`。
 *
 * ## 为什么这三处值得单测
 *
 * 它们都不会抛异常，错了只是「结果偏了一格」：
 *   * [structureOf] 判错 ⇒ 一部剧被记成电影（分类落 `movie`），而界面上
 *     只表现为「分类不对」，没人会想到是这里；
 *   * [ScrapeQuery.wantsTv] 猜错 ⇒ 综艺被当成电影搜，搜出一堆无关条目；
 *   * [ScrapeCandidate.subtitle] 是用户挑选候选时**唯一的年份线索**，
 *     拼错了就是在让人挑错片子。
 *
 * ⛔ 三个都是**纯函数**，不需要网络、不需要 Android 运行时 —— 所以是这一组
 *    改动里性价比最高的测试。
 */
class ScrapeModelsTest {

    // ------------------------------------------------------------------
    // structureOf：在线条目 id 的结构证据
    // ------------------------------------------------------------------

    /**
     * ⛔ **按段匹配，不是 `startsWith`。**
     *
     * 豆瓣那条多一层前缀（`douban/movie/678`），`startsWith("movie/")` 会漏掉
     * 它 —— 而漏掉的表现是「分类退到其它判据」，静默。
     */
    @Test
    fun `豆瓣与 TMDB 两种前缀都能认出类型`() {
        assertEquals("tv", structureOf("douban/tv/34874646"))
        assertEquals("movie", structureOf("douban/movie/1292052"))
        assertEquals("movie", structureOf("tmdb/movie/843527"))
        assertEquals("tv", structureOf("tmdb/tv/1396"))
    }

    /** 大小写与前后空白都要吃掉 —— 这一列是字符串，来源不止一处。 */
    @Test
    fun `大小写与空白不影响判定`() {
        assertEquals("tv", structureOf("  Douban/TV/34874646  "))
        assertEquals("movie", structureOf("TMDB/Movie/1"))
    }

    /**
     * 认不出来返回 `null` —— 那是「这条证据没意见」，**不是**「归到其它」。
     *
     * ⛔ 这两者混同的后果：`updateWorkScrape` 会拿 `null` 去覆盖掉库里已有的
     *    正确分类。`categoryAfterScrape` 里「保持原值」那一支就是为它留的。
     */
    @Test
    fun `认不出结构时返回 null 而不是其它`() {
        assertNull(structureOf(null))
        assertNull(structureOf(""))
        assertNull(structureOf("   "))
        assertNull(structureOf("douban/123"))
        // `tvshow` / `movies` 这类**子串**不算命中 —— 必须是完整的一段。
        assertNull(structureOf("tmdb/tvshow/1"))
        assertNull(structureOf("tmdb/movies/1"))
    }

    // ------------------------------------------------------------------
    // ScrapeQuery.wantsTv
    // ------------------------------------------------------------------

    @Test
    fun `有季集号时偏重剧集`() {
        assertEquals(true, ScrapeQuery("繁花", kind = "episode").wantsTv)
    }

    @Test
    fun `认成电影时偏重电影`() {
        assertEquals(false, ScrapeQuery("流浪地球2", kind = "movie").wantsTv)
    }

    /**
     * ⛔ `unknown` / `null` 一律**不偏**（两个接口都搜）。
     *
     * 综艺、纪录片在 `MediaNameParser` 里常常落到 `unknown`；硬猜一个方向会把
     * 它们搜到完全无关的条目上 —— 而「搜不到」至少还能让用户改搜索词。
     */
    @Test
    fun `类型未知时不偏 两个接口都搜`() {
        assertNull(ScrapeQuery("某某综艺", kind = "unknown").wantsTv)
        assertNull(ScrapeQuery("某某综艺").wantsTv)
        assertNull(ScrapeQuery("某某综艺", kind = "").wantsTv)
    }

    // ------------------------------------------------------------------
    // ScrapeCandidate
    // ------------------------------------------------------------------

    @Test
    fun `候选副标题拼年份与类型`() {
        val c = candidate(year = 2023, type = "tv")
        assertEquals("2023 · 剧集", c.subtitle)
    }

    @Test
    fun `没有年份时副标题只剩类型`() {
        assertEquals("电影", candidate(year = null, type = "movie").subtitle)
    }

    /** 类型也认不出时副标题**整条空**，而不是留一个孤零零的分隔符。 */
    @Test
    fun `年份与类型都没有时副标题为空`() {
        assertEquals("", candidate(year = null, type = null).subtitle)
        assertEquals("", candidate(year = 0, type = null).subtitle)
    }

    /** `uid` 是去重与选中态的键：必须带上来源，否则 TMDB 与豆瓣的同一个数字 id 会撞。 */
    @Test
    fun `uid 带上来源前缀`() {
        assertEquals("douban/123", candidate(source = "douban", id = "123").uid)
        assertEquals("tmdb/123", candidate(source = "tmdb", id = "123").uid)
    }

    // ------------------------------------------------------------------
    // ScrapeSource
    // ------------------------------------------------------------------

    @Test
    fun `来源解析认不出一律退回 online`() {
        assertEquals(ScrapeSource.online, ScrapeSource.parse("online"))
        assertEquals(ScrapeSource.local, ScrapeSource.parse("local"))
        assertEquals(ScrapeSource.online, ScrapeSource.parse(null))
        assertEquals(ScrapeSource.online, ScrapeSource.parse("tmdb"))
    }

    // ------------------------------------------------------------------

    private fun candidate(
        source: String = "douban",
        id: String = "1",
        year: Int? = null,
        type: String? = null,
    ) = ScrapeCandidate(
        source = source,
        sourceId = id,
        title = "标题",
        year = year,
        type = type,
        posterUrl = null,
    )

    /** 一条冒烟断言：确保 `enabled` 这类接口属性没被写成反的。 */
    @Test
    fun `豆瓣源不要求 Cookie 也能用`() {
        assertTrue(DoubanScraper(cookie = "").enabled)
    }

    /** TMDB 没配 Key 就**根本发不出去**（服务端必回 401），所以必须不可用。 */
    @Test
    fun `TMDB 没配 Key 时不可用`() {
        assertFalse(TmdbScraper(apiKey = "").enabled)
        assertTrue(TmdbScraper(apiKey = "abc").enabled)
    }
}
