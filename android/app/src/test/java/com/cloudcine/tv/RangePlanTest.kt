package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [RangePlan] 的边界值单测。
 *
 * ## 为什么这一组是必测的
 *
 * 分块算错**不会崩**，只会静默地少下 / 多下几个字节 —— 表现成
 * 「播到某处花屏」或「最后几秒卡住」，在电视上排查一次要十分钟。
 * 所以断言一律写**具体数字**，不用「非空」「大概」糊过去。
 *
 * 坐标口径见 [RangePlan] 的类注释：全部是**绝对文件偏移**、**闭区间**。
 */
class RangePlanTest {

    // ── chunk ─────────────────────────────────────────────────────

    @Test
    fun `第一块从 base 开始 长度恰好是 chunkBytes`() {
        val c = RangePlan.chunk(0, base = 0, limit = 99, chunkBytes = 40)!!
        assertEquals(0L, c.start)
        assertEquals(39L, c.endInclusive)
        assertEquals(40L, c.length)
    }

    @Test
    fun `末块被 limit 截断`() {
        // 0..99 共 100 字节、40 一块 ⇒ 第 2 块是 80..99（不是 80..119）
        val c = RangePlan.chunk(2, base = 0, limit = 99, chunkBytes = 40)!!
        assertEquals(80L, c.start)
        assertEquals(99L, c.endInclusive)
        assertEquals(20L, c.length)
    }

    @Test
    fun `越界返回 null`() {
        assertNull(RangePlan.chunk(3, base = 0, limit = 99, chunkBytes = 40))
    }

    @Test
    fun `start 恰好等于 limit 时还剩最后一个字节`() {
        // ⛔ 这是 `start >= limit` 与 `start > limit` 的分水岭。
        //    写成 `>=` 就会漏掉文件的**最后一个字节** —— 而它正好是文件结尾，
        //    表现是「播到最后几秒解码失败」。
        val c = RangePlan.chunk(1, base = 0, limit = 100, chunkBytes = 100)!!
        assertEquals(100L, c.start)
        assertEquals(100L, c.endInclusive)
        assertEquals(1L, c.length)
    }

    @Test
    fun `base 不为 0 时按 base 偏移`() {
        val c0 = RangePlan.chunk(0, base = 1000, limit = 2000, chunkBytes = 500)!!
        assertEquals(1000L, c0.start)
        assertEquals(1499L, c0.endInclusive)

        val c2 = RangePlan.chunk(2, base = 1000, limit = 2000, chunkBytes = 500)!!
        assertEquals(2000L, c2.start)
        assertEquals(2000L, c2.endInclusive)
        assertEquals(1L, c2.length)

        assertNull(RangePlan.chunk(3, base = 1000, limit = 2000, chunkBytes = 500))
    }

    @Test
    fun `长度未知时每块都是满块`() {
        val c = RangePlan.chunk(1, base = 0, limit = -1, chunkBytes = 40)!!
        assertEquals(40L, c.start)
        assertEquals(79L, c.endInclusive)
        assertEquals(40L, c.length)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `块号不能为负`() {
        RangePlan.chunk(-1, base = 0, limit = 99, chunkBytes = 40)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `块大小必须为正`() {
        RangePlan.chunk(0, base = 0, limit = 99, chunkBytes = 0)
    }

    // ── chunkCount ────────────────────────────────────────────────

    @Test
    fun `块数向上取整`() {
        assertEquals(3L, RangePlan.chunkCount(0, 99, 40))    // 100 / 40 = 2.5 → 3
        assertEquals(1L, RangePlan.chunkCount(0, 0, 100))    // 1 字节 / 100 → 1
        assertEquals(2L, RangePlan.chunkCount(0, 100, 100))  // 101 / 100 → 2
        assertEquals(100L, RangePlan.chunkCount(0, 99, 1))
        assertEquals(4L, RangePlan.chunkCount(0, 262143, 65536)) // 正好整除
    }

    @Test
    fun `长度未知时块数为 -1`() {
        assertEquals(-1L, RangePlan.chunkCount(0, -1, 40))
    }

    @Test
    fun `空区间块数为 0`() {
        assertEquals(0L, RangePlan.chunkCount(100, 99, 40))
    }

    // ── connections ───────────────────────────────────────────────

    @Test
    fun `已知长度按块数收敛 不为读文件头开满连接`() {
        // 3 块就只开 3 条。为几百 KiB 的文件头开 8 条，5 条会立刻收到 416，
        // 白建 5 次连接（还要付 TLS/首包延迟）。
        assertEquals(3, RangePlan.connections(0, 99, 40, max = 8))
        assertEquals(1, RangePlan.connections(0, 0, 100, max = 8))
        assertEquals(2, RangePlan.connections(0, 100, 100, max = 8))
    }

    @Test
    fun `块数多于 max 时取 max`() {
        assertEquals(2, RangePlan.connections(0, 99, 40, max = 2))
        assertEquals(8, RangePlan.connections(0, 10_000_000, 1024, max = 8))
    }

    @Test
    fun `长度未知时给满 max`() {
        // 长度未知的多半就是主播放段 —— 它才是要加速的对象。
        assertEquals(8, RangePlan.connections(0, -1, 40, max = 8))
    }

    @Test
    fun `空区间也至少 1 条连接`() {
        assertEquals(1, RangePlan.connections(100, 99, 40, max = 8))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `连接数至少 1`() {
        RangePlan.connections(0, 99, 40, max = 0)
    }

    // ── Content-Range 解析 ────────────────────────────────────────

    @Test
    fun `从 Content-Range 取总长`() {
        assertEquals(1048576L, RangePlan.totalFromContentRange("bytes 0-1023/1048576"))
        assertEquals(5000L, RangePlan.totalFromContentRange("bytes 4999-4999/5000"))
        // 416 的形态：`bytes *\/total`
        assertEquals(131072L, RangePlan.totalFromContentRange("bytes */131072"))
    }

    @Test
    fun `拿不到总长一律 -1 不许退化成 0`() {
        // ⛔ 0 会被下游当成「空文件」⇒ 整个流立刻被当成 EOF，
        //    表现是「一开播就结束」。宁可留 -1（= 还不知道）。
        assertEquals(-1L, RangePlan.totalFromContentRange(null))
        assertEquals(-1L, RangePlan.totalFromContentRange("bytes 0-1023/*"))
        assertEquals(-1L, RangePlan.totalFromContentRange("bytes 0-1023/"))
        assertEquals(-1L, RangePlan.totalFromContentRange("bytes 0-1023/0"))
        assertEquals(-1L, RangePlan.totalFromContentRange("随便什么东西"))
    }

    @Test
    fun `从 Content-Range 取本段起点`() {
        assertEquals(0L, RangePlan.startFromContentRange("bytes 0-1023/1048576"))
        assertEquals(1000L, RangePlan.startFromContentRange("bytes 1000-2000/9999"))
    }

    @Test
    fun `拿不到起点一律 -1`() {
        assertEquals(-1L, RangePlan.startFromContentRange(null))
        assertEquals(-1L, RangePlan.startFromContentRange("bytes */1000"))
        assertEquals(-1L, RangePlan.startFromContentRange("bytes -100/1000"))
        assertEquals(-1L, RangePlan.startFromContentRange("nonsense"))
    }
}
