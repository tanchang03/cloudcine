package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [DiskCachePlan] 的边界值单测。
 *
 * ## 为什么这一组是必测的
 *
 * 它是**唯一**把「磁盘上覆盖了哪些字节」翻译成「进度条画在哪儿」的地方，
 * 而这两者的单位不同（字节 ↔ 时间比例），桥梁是**估算**出来的码率。
 * 算错的后果不是崩，而是**界面撒谎**：
 * - 跳转留下空洞却画成连成一片 ⇒ 用户回拖时以为不用重新缓冲，结果卡住；
 * - 比例不夹到 [0,1] ⇒ 直接画出界（VBR 片源尾巴码率高，末段止点必然超总长）；
 * - 拿不到码率却画到 0 ⇒ 进度条那层淡蓝永远不出现，用户以为缓存没生效。
 *
 * 最后一条是**实测踩过的**（2026-10-06）：控制栏写着「磁盘 2.2 GiB」、
 * 进度条却一片空白 —— 就是因为文字和进度条读的是两套账本。
 */
class DiskCachePlanTest {

    private val mib = 1024L * 1024

    // ── totalBytes：拿不到就返回 0，不许瞎猜 ────────────────────

    @Test
    fun `码率与时长都正常时给出估算总长`() {
        // 1 MiB/s × 3600s = 3600 MiB。
        assertEquals(
            3600.0 * mib,
            DiskCachePlan.totalBytes(1048576.0, 3600_000L),
            1.0,
        )
    }

    @Test
    fun `原画档 3_67MiB每秒 的 105 分钟估算`() {
        // 实测的 4K 原画档：3.67 MiB/s（`Quality.requiredMbPerSec`）。
        // 105 分钟 ⇒ 约 22.6 GiB —— 这正是「整片装不下 5 GiB 缓存」的那个量级。
        val total = DiskCachePlan.totalBytes(3.67 * mib, 105 * 60_000L)
        assertEquals(22.58, total / 1024 / 1024 / 1024, 0.05)
    }

    @Test
    fun `拿不到码率时返回 0`() {
        // `-e url` 那条对照路径没有档位信息，返回 0 ⇒ 这里也该是「算不了」。
        assertEquals(0.0, DiskCachePlan.totalBytes(0.0, 3600_000L), 0.0)
        assertEquals(0.0, DiskCachePlan.totalBytes(-1.0, 3600_000L), 0.0)
        assertEquals(0.0, DiskCachePlan.totalBytes(Double.NaN, 3600_000L), 0.0)
        assertEquals(0.0, DiskCachePlan.totalBytes(Double.POSITIVE_INFINITY, 3600_000L), 0.0)
    }

    @Test
    fun `拿不到时长时返回 0`() {
        // 直播/未知时长 ⇒ `duration` 是 `C.TIME_UNSET`（Long.MIN_VALUE + 1）。
        // ⛔ 负数一律当「不知道」：真算下去会得到一个负的总长，
        //    后面每一次除法都变成负比例。
        val timeUnset = Long.MIN_VALUE + 1
        assertEquals(0.0, DiskCachePlan.totalBytes(1048576.0, timeUnset), 0.0)
        assertEquals(0.0, DiskCachePlan.totalBytes(1048576.0, 0L), 0.0)
        assertEquals(0.0, DiskCachePlan.totalBytes(1048576.0, -1L), 0.0)
    }

    // ── rangesToRatios：空洞必须留着 ────────────────────────────

    @Test
    fun `单段区间换算成比例`() {
        // 总长 1000 字节，缓存覆盖 [0, 500) ⇒ 前半段。
        val r = DiskCachePlan.rangesToRatios(longArrayOf(0L, 500L), 1000.0)
        assertEquals(2, r.size)
        assertEquals(0.0f, r[0], 1e-6f)
        assertEquals(0.5f, r[1], 1e-6f)
    }

    @Test
    fun `跳转留下的空洞必须画成两段`() {
        // ⛔ 这是本次改动的**核心断言**：用户在 20% 处拖到 60%，
        //    磁盘上就是 [0,20%) ∪ [60%,80%) 两段，中间 40% 真的没有数据。
        //    画成「从片头连到 80%」会让用户以为回拖那一段不用重新缓冲。
        val r = DiskCachePlan.rangesToRatios(longArrayOf(0L, 200L, 600L, 800L), 1000.0)
        assertEquals(4, r.size)
        assertEquals(0.0f, r[0], 1e-6f)
        assertEquals(0.2f, r[1], 1e-6f)
        assertEquals(0.6f, r[2], 1e-6f)
        assertEquals(0.8f, r[3], 1e-6f)
    }

    @Test
    fun `区间乱序也要按起点排好`() {
        // `SimpleCache.getCachedSpans` 给的是有序集合，但纯函数不该假设调用方
        // 一定按顺序传 —— 顺序错了就会画出「从 0.6 到 0.2」这种反着的矩形。
        val r = DiskCachePlan.rangesToRatios(longArrayOf(600L, 800L, 0L, 200L), 1000.0)
        assertEquals(0.0f, r[0], 1e-6f)
        assertEquals(0.2f, r[1], 1e-6f)
        assertEquals(0.6f, r[2], 1e-6f)
        assertEquals(0.8f, r[3], 1e-6f)
    }

    @Test
    fun `超出估算总长的末段被夹到 1`() {
        // ⛔ 码率是估算的（VBR 片源尾巴码率高，或档位码率估低了），
        //    末段的止点超过 totalBytes 是常态。不夹就会画出界。
        val r = DiskCachePlan.rangesToRatios(longArrayOf(0L, 2000L), 1000.0)
        assertEquals(0.0f, r[0], 1e-6f)
        assertEquals(1.0f, r[1], 1e-6f)
    }

    @Test
    fun `整段都在总长之外时两端都夹到 1`() {
        // 起点也超了：夹完是 [1,1] —— 宽度 0，画不出东西，但**不能是 NaN 或负数**。
        val r = DiskCachePlan.rangesToRatios(longArrayOf(1500L, 2000L), 1000.0)
        assertEquals(1.0f, r[0], 1e-6f)
        assertEquals(1.0f, r[1], 1e-6f)
    }

    @Test
    fun `长度为零或负的区间被丢掉`() {
        // `SimpleCache` 里正在写、还没 `commitFile` 的 span 长度是
        // `C.LENGTH_UNSET`（-1）—— 落到这里就是负数。丢掉它，
        // 否则会画出一个起点在终点右边的「负宽度」矩形。
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(500L, 500L), 1000.0).size)
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(600L, 400L), 1000.0).size)
    }

    @Test
    fun `拿不到总长时返回空数组而不是画到 0`() {
        // ⛔ 返回空 ⇒ 那层淡蓝**不画**。若返回 [0,0] 语义上也是「不画」，
        //    但返回 [0,1] 就是满格，用户会以为整片都在盘上。
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(0L, 500L), 0.0).size)
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(0L, 500L), -1.0).size)
        // ⛔ NaN 这一条是**实测抓出来的**：`NaN <= 0.0` 是 `false`，
        //    光写 `<= 0` 会让 NaN 一路穿到 `coerceIn`，而 `coerceIn` 也拦不住
        //    （NaN 与任何数比较都是 false）⇒ 直接返回一个 NaN 矩形。
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(0L, 500L), Double.NaN).size)
        assertEquals(
            0,
            DiskCachePlan.rangesToRatios(longArrayOf(0L, 500L), Double.POSITIVE_INFINITY).size,
        )
    }

    @Test
    fun `空数组与残缺数组都不崩`() {
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(), 1000.0).size)
        assertEquals(0, DiskCachePlan.rangesToRatios(longArrayOf(0L), 1000.0).size)
        // 末尾多一个孤立数字：只用完整的一对，不崩。
        val r = DiskCachePlan.rangesToRatios(longArrayOf(0L, 500L, 999L), 1000.0)
        assertEquals(2, r.size)
        assertEquals(0.5f, r[1], 1e-6f)
    }

    // ── snapshot：文字与进度条同源 ──────────────────────────────

    @Test
    fun `快照的 usedBytes 只数有效区间`() {
        // 128 MiB + 0 长度 + 128 MiB = 256 MiB。0 长度那个不许算进去，
        // 否则文字会比进度条多报 0 字节 —— 现在还看不出来，但它是这个 bug 的形状。
        val r = longArrayOf(0L, 128 * mib, 500L, 500L, 256 * mib, 384 * mib)
        val snap = DiskCachePlan.snapshot(r, 1048576.0, 3600_000L)
        assertEquals(256 * mib, snap.usedBytes)
        // 总长 3600 MiB ⇒ 区间 [0,128) 与 [256,384) MiB。
        assertEquals(4, snap.ranges.size)
        assertEquals(0.0f, snap.ranges[0], 1e-6f)
        assertEquals(128f / 3600f, snap.ranges[1], 1e-6f)
        assertEquals(256f / 3600f, snap.ranges[2], 1e-6f)
        assertEquals(384f / 3600f, snap.ranges[3], 1e-6f)
    }

    @Test
    fun `一个字节都没下时返回空快照`() {
        val snap = DiskCachePlan.snapshot(longArrayOf(), 1048576.0, 3600_000L)
        assertEquals(0L, snap.usedBytes)
        assertEquals(0, snap.ranges.size)
    }

    @Test
    fun `只有未提交的区间时算不出比例 但字节数照样报`() {
        // 拿不到码率 ⇒ 画不出来，但「盘上有 512 MiB」这个事实不该被吞掉。
        val snap = DiskCachePlan.snapshot(longArrayOf(0L, 512 * mib), 0.0, 3600_000L)
        assertEquals(512 * mib, snap.usedBytes)
        assertEquals(0, snap.ranges.size)
    }

    // ── 段数与「最远到哪」（调试浮层要写这两个）──────────────────

    @Test
    fun `段数就是有效区间的个数`() {
        // 跳转一次多一段 —— 调试浮层写「2 段」时，用户一眼能确认
        // 「预取器确实跟到新位置了、中间那段真的没下」。
        assertEquals(1, DiskCachePlan.snapshot(longArrayOf(0L, 100L), 1048576.0, 3600_000L).segments)
        assertEquals(
            2,
            DiskCachePlan.snapshot(
                longArrayOf(0L, 128 * mib, 256 * mib, 384 * mib),
                1048576.0,
                3600_000L,
            ).segments,
        )
        assertEquals(0, DiskCachePlan.snapshot(longArrayOf(), 1048576.0, 3600_000L).segments)
    }

    @Test
    fun `最远时间取更靠后那一段的末尾`() {
        // ⛔ 不是「第一段」也不是「播放头前方那一段」，而是**最靠后**的末尾：
        //    跳转后的两段里，用户要看的是「下到哪儿了」。
        //    1 MiB/s ⇒ 字节数 ÷ 1048576 = 秒数。
        val snap = DiskCachePlan.snapshot(
            longArrayOf(0L, 100 * mib, 200 * mib, 500 * mib),
            1048576.0,
            3600_000L,
        )
        assertEquals(500_000L, snap.endMs)
    }

    @Test
    fun `拿不到码率时最远时间留 0 不瞎给`() {
        // 宁可写 0（浮层那一项不显示），也不要给一个错的「到 58:47」——
        // 那种读数错一次就没人再信这一行了。
        val snap = DiskCachePlan.snapshot(longArrayOf(0L, 500 * mib), 0.0, 3600_000L)
        assertEquals(0L, snap.endMs)
        assertEquals(500 * mib, snap.usedBytes)
    }

    @Test
    fun `空快照的段数与最远时间都是 0`() {
        assertEquals(0, DiskCacheSnapshot.EMPTY.segments)
        assertEquals(0L, DiskCacheSnapshot.EMPTY.endMs)
        assertEquals(0L, DiskCacheSnapshot.EMPTY.usedBytes)
    }

    // ── covers：跳转这一下到底要不要重新缓冲 ────────────────────

    @Test
    fun `落在已提交区间里才算命中`() {
        // 总长 3600 MiB，磁盘上有 [0,128) 与 [256,384) 两段。
        val snap = DiskCachePlan.snapshot(
            longArrayOf(0L, 128 * mib, 256 * mib, 384 * mib),
            1048576.0,
            3600_000L,
        )
        assertTrue("0 应该在缓存里", snap.covers(0L))
        assertTrue("127 MiB 应该在缓存里", snap.covers(127 * mib))
        assertTrue("256 MiB 应该在新那段里", snap.covers(256 * mib))
        // ⛔ 空洞必须**不**命中：这正是「拖了进度条之后会不会从当前位置重来」
        //    要能验证的东西 —— 跳进空洞就是要重新缓冲。
        assertTrue("128 MiB 是空洞，不该命中", !snap.covers(128 * mib))
        assertTrue("200 MiB 是空洞，不该命中", !snap.covers(200 * mib))
        assertTrue("384 MiB 之后还没下到", !snap.covers(384 * mib))
    }

    @Test
    fun `区间终点是开区间`() {
        // `CacheSpan` 的 `[position, position + length)` 与这里一致：
        // 终点那一字节**不在**里面。写成闭区间会让「刚好压在边界上」的跳转
        // 被判成命中，而播放器去读时又落空。
        val snap = DiskCachePlan.snapshot(longArrayOf(0L, 100L), 1048576.0, 3600_000L)
        assertTrue(snap.covers(99L))
        assertTrue(!snap.covers(100L))
    }

    @Test
    fun `垃圾区间不会误报命中`() {
        // 零长度、倒序：`SimpleCache` 里未提交的 span 长度是 -1，会变成倒序。
        val snap = DiskCachePlan.snapshot(
            longArrayOf(0L, 500L, 600L, 600L, 900L, 700L),
            1048576.0,
            3600_000L,
        )
        assertTrue(snap.covers(100L))
        assertTrue(!snap.covers(600L))
        assertTrue(!snap.covers(800L))
    }

    @Test
    fun `空快照对任何位置都不命中`() {
        assertTrue(!DiskCachePlan.snapshot(longArrayOf(), 1048576.0, 3600_000L).covers(0L))
        // 拿不到码率时**比例**画不出来，但**字节区间仍然要在** ——
        // 「某个位置在不在盘上」用不着码率，跳转日志靠它。
        val snap = DiskCachePlan.snapshot(longArrayOf(0L, 100L), 0.0, 3600_000L)
        assertEquals(0, snap.ranges.size)
        assertTrue(snap.covers(50L))
    }

    // ── 性质 ────────────────────────────────────────────────────

    @Test
    fun `任何输入下输出的比例都落在 0 到 1 之间`() {
        val cases = listOf(
            longArrayOf(0L, 1L),
            longArrayOf(0L, Long.MAX_VALUE / 2),
            longArrayOf(Long.MAX_VALUE / 2, Long.MAX_VALUE / 2 + 1),
            longArrayOf(-5L, 5L),
            longArrayOf(0L, 200L, 600L, 800L),
        )
        for (ranges in cases) {
            val r = DiskCachePlan.rangesToRatios(ranges, 1000.0)
            for (v in r) {
                assertTrue("比例 $v 越界（输入 ${ranges.toList()}）", v in 0f..1f)
                assertTrue("比例是 NaN（输入 ${ranges.toList()}）", !v.isNaN())
            }
        }
    }

    @Test
    fun `快照的 usedBytes 等于所有有效区间长度之和`() {
        val ranges = longArrayOf(0L, 100L, 300L, 450L, 900L, 900L)
        val snap = DiskCachePlan.snapshot(ranges, 1048576.0, 3600_000L)
        assertEquals(100L + 150L, snap.usedBytes)
    }

    @Test
    fun `usedBytes 永远不超过所有区间长度之和`() {
        var i = 0L
        while (i < 40L) {
            val a = i * 1000L
            val b = a + i * 37L
            val snap = DiskCachePlan.snapshot(longArrayOf(a, b), 1048576.0, 3600_000L)
            assertTrue("算出 ${snap.usedBytes} 超过区间长度 ${b - a}", snap.usedBytes <= b - a)
            i++
        }
    }
}
