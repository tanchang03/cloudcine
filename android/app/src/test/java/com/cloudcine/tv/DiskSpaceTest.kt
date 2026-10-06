package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [DiskSpace] 的边界值单测。
 *
 * ## 为什么这一组是必测的
 *
 * 这条规则算错**不会崩，只会把电视撑爆或者白占空间**：
 * - 算大了 ⇒ 缓存把 `/data` 吃到只剩几十 MB ⇒ 系统开始杀后台、
 *   日志写不进去、其他 App 起不来。而且**是在用户家里、事后才发生**。
 * - 算小了 ⇒ 干脆别开（返回 0），至少是安全的。
 *
 * 所以这里把「每个可用空间对应多少上限」钉成具体数字。
 * 基准是这台电视的实测值：
 * ```
 * /dev/block/mmcblk0p37  20G  8.3G  12G  42%  /data
 * ```
 */
class DiskSpaceTest {

    private val gib = 1024L * 1024 * 1024

    // ── 实测那台电视 ────────────────────────────────────────────

    @Test
    fun `可用 12GiB 时给出 5GiB 上限`() {
        // (12 - 2) ÷ 2 = 5 GiB。没撞到 6 GiB 硬顶。
        assertEquals(5L * gib, DiskSpace.cacheLimitBytes(12L * gib))
    }

    @Test
    fun `可用 8GiB 时给出 3GiB 上限`() {
        // (8 - 2) ÷ 2 = 3 GiB。
        assertEquals(3L * gib, DiskSpace.cacheLimitBytes(8L * gib))
    }

    // ── 硬顶 ────────────────────────────────────────────────────

    @Test
    fun `空间再大也不超过 6GiB 硬顶`() {
        // 32 GiB 可用本来能算到 15 GiB —— 那是浪费，缓存根本用不到那么多，
        // 而用户可能还想在这台电视上装别的 App。
        assertEquals(DiskSpace.HARD_MAX_BYTES, DiskSpace.cacheLimitBytes(32L * gib))
    }

    @Test
    fun `硬顶可以被参数覆盖 便于省空间模式`() {
        assertEquals(1L * gib, DiskSpace.cacheLimitBytes(12L * gib, hardMaxBytes = 1L * gib))
    }

    // ── 让路：留不够就不开 ──────────────────────────────────────

    @Test
    fun `可用刚好 2GiB 时返回 0 一个字节都不占`() {
        // 2 GiB 正好等于要留的余量 ⇒ 没有「多余空间」可分。
        assertEquals(0L, DiskSpace.cacheLimitBytes(2L * gib))
    }

    @Test
    fun `可用 2_5GiB 时仍然返回 0 因为算出来不够最小可用量`() {
        // (2.5 - 2) ÷ 2 = 0.25 GiB = 256 MiB < 512 MiB 下限。
        // ⛔ 这时**不能**给 256 MiB：连一次回拖都兜不住，
        //    白写盘还让人以为「开了缓存怎么还卡」。
        assertEquals(0L, DiskSpace.cacheLimitBytes(2L * gib + gib / 2))
    }

    @Test
    fun `可用 3GiB 时刚好给到 512MiB 下限`() {
        // (3 - 2) ÷ 2 = 512 MiB，正好等于 MIN_USABLE_BYTES。
        assertEquals(DiskSpace.MIN_USABLE_BYTES, DiskSpace.cacheLimitBytes(3L * gib))
    }

    @Test
    fun `可用空间为 0 或负数时返回 0 不抛异常`() {
        // 负数 = StatFs 读不出来（见 PrefetchCache.availableBytes）。
        // 「不知道有多少空间」时不该赌，直接不开。
        assertEquals(0L, DiskSpace.cacheLimitBytes(0L))
        assertEquals(0L, DiskSpace.cacheLimitBytes(-1L))
    }

    // ── 性质 ────────────────────────────────────────────────────

    @Test
    fun `结果要么是 0 要么不小于最小可用量 不给中间值`() {
        // 从 1 GiB 到 20 GiB 逐个步进扫一遍。
        var available = 1L * gib
        while (available <= 20L * gib) {
            val limit = DiskSpace.cacheLimitBytes(available)
            assertTrue(
                "可用 ${available / gib} GiB 时算出 $limit 字节 —— " +
                    "既不是 0 也不到 512 MiB 下限，属于「开了等于没开」的中间值",
                limit == 0L || limit >= DiskSpace.MIN_USABLE_BYTES,
            )
            available += gib / 4
        }
    }

    @Test
    fun `结果永远不超过硬顶 且不超过可用空间的一半`() {
        var available = 1L * gib
        while (available <= 40L * gib) {
            val limit = DiskSpace.cacheLimitBytes(available)
            assertTrue("超过硬顶", limit <= DiskSpace.HARD_MAX_BYTES)
            assertTrue("超过了可用空间的一半（会把系统逼到低存储）", limit <= available / 2)
            available += gib / 4
        }
    }

    @Test
    fun `可用空间越多上限单调不减`() {
        var previous = 0L
        var available = 1L * gib
        while (available <= 40L * gib) {
            val limit = DiskSpace.cacheLimitBytes(available)
            assertTrue(
                "可用 ${available / gib} GiB 时上限 $limit 反而比上一档 $previous 小",
                limit >= previous,
            )
            previous = limit
            available += gib / 4
        }
    }
}
