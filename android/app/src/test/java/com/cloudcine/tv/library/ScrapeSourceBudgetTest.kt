package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 在线源预算的**判据** —— [ScrapeSourceBudget]。
 *
 * ## 为什么这一组必须钉死
 *
 * 它是「一次自动刮削要跑 30 秒还是 30 分钟」的唯一开关。
 *
 * 电视上实测过的那种现场（2026-10-07）：TMDB 的官方地址被 DNS 污染，每个请求
 * 都挂到 12 秒超时。没有预算的话，145 部作品 = 145 × 12s ≈ **29 分钟**，
 * 而界面只会显示「刮削 1/145」—— 用户会以为它卡死，然后拔电源。
 *
 * 判据的核心是**区分「源坏了」与「这片子源里没有」**：两者在 `search` 的
 * 返回值上长得一模一样（都是空列表），只有耗时能分开。这一组就是钉这个。
 */
class ScrapeSourceBudgetTest {

    // ==================================================================
    // 「快 + 空」不是失败
    // ==================================================================

    /**
     * ⛔ 一个**健康**的源答「没有」再多次也不该被摘掉。
     *
     * 库里有一批自制视频 / 演唱会 / 赛事时，连续十几次「源里没有收录」是常态。
     * 把它们当成「源坏了」，用户看到的是「刮了 3 部就停了」。
     */
    @Test
    fun `快而空不算失败`() {
        val b = ScrapeSourceBudget()
        repeat(20) {
            assertFalse(b.record("tmdb", "TMDB", hit = false, elapsedMs = 300))
        }
        assertFalse(b.isDropped("tmdb"))
        assertFalse(b.hasDropped)
    }

    /** 「慢 + 有结果」说明源只是慢，它活着 —— 计数清零。 */
    @Test
    fun `慢但有结果不算失败`() {
        val b = ScrapeSourceBudget()
        b.record("tmdb", "TMDB", hit = false, elapsedMs = 9_000)
        b.record("tmdb", "TMDB", hit = false, elapsedMs = 9_000)
        assertFalse(b.record("tmdb", "TMDB", hit = true, elapsedMs = 9_000))
        assertFalse(b.isDropped("tmdb"))
    }

    // ==================================================================
    // 「慢 + 空」连成串才摘
    // ==================================================================

    /** 前两次「慢 + 空」只是记账，第三次才摘。**必须连续**。 */
    @Test
    fun `连续三次慢而空才摘掉`() {
        val b = ScrapeSourceBudget()
        assertFalse(b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000))
        assertFalse(b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000))
        assertTrue(b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000))
        assertTrue(b.isDropped("tmdb"))
        assertEquals(listOf("TMDB"), b.droppedNames)
    }

    /**
     * ⛔ 中间只要有一次答上来（哪怕答的是「没有」但**很快**），计数就清零。
     *
     * 这条是「不误杀」的全部保障：一次网络抖动不该让整个源下线 —— 而一次抖动
     * 之后紧接着的那次正常响应，正是「它只是抖了一下」的证据。
     */
    @Test
    fun `中途一次快速响应就把计数清零`() {
        val b = ScrapeSourceBudget()
        b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000)
        b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000)
        // 抖了一下，恢复了。
        b.record("tmdb", "TMDB", hit = false, elapsedMs = 400)
        // 重新开始数。
        assertFalse(b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000))
        assertFalse(b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000))
        assertTrue(b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000))
    }

    /** 摘掉之后是**单向**的：再记多少次都不会「复活」，也不会重复报「刚摘掉」。 */
    @Test
    fun `摘掉之后不再改变状态`() {
        val b = ScrapeSourceBudget()
        repeat(3) { b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000) }
        assertTrue(b.isDropped("tmdb"))
        assertFalse(b.record("tmdb", "TMDB", hit = true, elapsedMs = 100))
        assertTrue(b.isDropped("tmdb"))
        assertEquals(listOf("TMDB"), b.droppedNames)
    }

    /** 两个源**各记各的**：TMDB 连不上不该影响豆瓣。 */
    @Test
    fun `两个源独立计数`() {
        val b = ScrapeSourceBudget()
        repeat(3) { b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000) }
        assertTrue(b.isDropped("tmdb"))
        assertFalse(b.isDropped("douban"))
        assertFalse(b.record("douban", "豆瓣", hit = false, elapsedMs = 200))
        assertEquals(listOf("TMDB"), b.droppedNames)
    }

    /** 被摘掉的顺序就是进列表的顺序 —— 报给用户时读起来才顺。 */
    @Test
    fun `多个源被摘时按摘除顺序报出`() {
        val b = ScrapeSourceBudget()
        repeat(3) { b.record("tmdb", "TMDB", hit = false, elapsedMs = 12_000) }
        repeat(3) { b.record("douban", "豆瓣", hit = false, elapsedMs = 12_000) }
        assertEquals(listOf("TMDB", "豆瓣"), b.droppedNames)
    }

    /** 恰好等于阈值算「慢」—— 判据是 `>=` 而不是 `>`。 */
    @Test
    fun `耗时正好等于阈值算慢`() {
        val b = ScrapeSourceBudget()
        repeat(3) { b.record("tmdb", "TMDB", hit = false, elapsedMs = ScrapeSourceBudget.SLOW_MS) }
        assertTrue(b.isDropped("tmdb"))
    }

    /** 差一毫秒就不算。 */
    @Test
    fun `耗时差一毫秒不算慢`() {
        val b = ScrapeSourceBudget()
        repeat(10) {
            b.record("tmdb", "TMDB", hit = false, elapsedMs = ScrapeSourceBudget.SLOW_MS - 1)
        }
        assertFalse(b.isDropped("tmdb"))
    }

    // ==================================================================
    // 跨端 / 参数契约
    // ==================================================================

    /**
     * 两个阈值是**跨端契约**：PC 端的 `ScanService` 用同一套口径决定「这个源
     * 还要不要问」。改这里必须同时改那边。
     */
    @Test
    fun `两个阈值钉死`() {
        assertEquals(3, ScrapeSourceBudget.MAX_CONSECUTIVE_FAILURES)
        assertEquals(8_000L, ScrapeSourceBudget.SLOW_MS)
    }

    /** 阈值可注入 —— 测试与将来的调参都靠它，不必改常量。 */
    @Test
    fun `阈值可以注入`() {
        val b = ScrapeSourceBudget(maxConsecutiveFailures = 1, slowMs = 100)
        assertTrue(b.record("tmdb", "TMDB", hit = false, elapsedMs = 100))
        assertTrue(b.isDropped("tmdb"))
    }
}
