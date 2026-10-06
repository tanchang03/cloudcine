package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BufferPlan] 的边界值单测。
 *
 * ## 为什么这一组是必测的
 *
 * 后缓冲算错的症状**不是崩溃，是「暂停后进度条不动」**——
 * 看起来像网络卡了，实际是分配器被后缓冲占满。这种 bug 在电视上
 * 排查一次要十几分钟（要插 adb、要暂停、要盯日志），所以这里把
 * 「每个档位该拿到多少毫秒」钉成具体数字，改坏了立刻红。
 *
 * 档位码率取 [com.cloudcine.tv.pan.Quality.requiredMbPerSec] 的实测值：
 * 原画 3.67 / `4k` 0.63 / 超清 0.31 / `high` 0.09（MiB/s）。
 */
class BufferPlanTest {

    /** 这台电视的预算：`min(192MiB / 4, 64MiB)`。 */
    private val budget48 = 48L * 1024 * 1024

    /** 大堆机型（512MiB）的预算。 */
    private val budget64 = 64L * 1024 * 1024

    // ── 各档位实际拿到的秒数 ────────────────────────────────────

    @Test
    fun `原画档 后缓冲只占 12MiB 折合 3 秒 剩下的全给前向`() {
        // 12 MiB ÷ 3.67 MiB/s = 3.27s。
        // 这正是「暂停后一个字节都不读」的修复点：改前写死 30s，
        // 要 110 MiB，把 48 MiB 的额度全吃光。
        assertEquals(3_269L, BufferPlan.backBufferMs(budget48, 3.67).toLong())
    }

    @Test
    fun `4k 转码档 后缓冲拿到 19 秒`() {
        // 12 MiB ÷ 0.63 = 19.05s。码率低 5 倍，同样 12 MiB 就能存 5 倍时长。
        assertEquals(19_047L, BufferPlan.backBufferMs(budget48, 0.63).toLong())
    }

    @Test
    fun `超清档 算出来 38 秒但被上限钳到 30 秒`() {
        // 12 MiB ÷ 0.31 = 38.7s > MAX(30s)。
        // 钳顶是安全的：30s × 0.31 = 9.3 MiB，仍然低于 12 MiB 额度。
        assertEquals(BufferPlan.MAX_BACK_BUFFER_MS, BufferPlan.backBufferMs(budget48, 0.31).toLong())
    }

    @Test
    fun `high 档 同样钳在 30 秒`() {
        assertEquals(BufferPlan.MAX_BACK_BUFFER_MS, BufferPlan.backBufferMs(budget48, 0.09).toLong())
    }

    @Test
    fun `大堆机型预算翻倍时 后缓冲秒数也翻倍`() {
        // 16 MiB ÷ 3.67 = 4.36s —— 预算涨，秒数跟着涨，比例不变。
        assertEquals(4_359L, BufferPlan.backBufferMs(budget64, 3.67).toLong())
    }

    // ── 码率拿不到时的兜底 ──────────────────────────────────────

    @Test
    fun `码率为 0 时用兜底码率 不抛异常`() {
        // 对照路径（-e url）没有档位信息，assumedBitrateMibps() 返回 0。
        assertEquals(4_000L, BufferPlan.backBufferMs(budget48, 0.0).toLong())
    }

    @Test
    fun `码率是 NaN 或无穷或负数时同样用兜底`() {
        val fallback = BufferPlan.backBufferMs(budget48, BufferPlan.ASSUMED_BITRATE_MIBPS).toLong()
        assertEquals(fallback, BufferPlan.backBufferMs(budget48, Double.NaN).toLong())
        assertEquals(fallback, BufferPlan.backBufferMs(budget48, Double.POSITIVE_INFINITY).toLong())
        assertEquals(fallback, BufferPlan.backBufferMs(budget48, Double.NEGATIVE_INFINITY).toLong())
        assertEquals(fallback, BufferPlan.backBufferMs(budget48, -1.0).toLong())
    }

    // ── 钳位 ────────────────────────────────────────────────────

    @Test
    fun `预算极小时钳到下限 不会变成 0 秒`() {
        // 1 MiB 预算 ⇒ 0.25 MiB 额度 ⇒ 3.67 MiB/s 下只有 68ms。
        // 钳到 2s 是刻意的：后缓冲短于 2s 等于没有，回拖一下就要重下。
        assertEquals(BufferPlan.MIN_BACK_BUFFER_MS, BufferPlan.backBufferMs(1L * 1024 * 1024, 3.67).toLong())
    }

    @Test
    fun `预算为 0 或负数时也不崩 钳到下限`() {
        assertEquals(BufferPlan.MIN_BACK_BUFFER_MS, BufferPlan.backBufferMs(0L, 3.67).toLong())
        assertEquals(BufferPlan.MIN_BACK_BUFFER_MS, BufferPlan.backBufferMs(-budget48, 3.67).toLong())
    }

    @Test
    fun `码率高到 12MiB 撑不住 2 秒时 下限优先于比例`() {
        // 8K 级原画假设 20 MiB/s：12 MiB ÷ 20 = 0.6s < 2s ⇒ 钳到 2s。
        // 这时后缓冲会占到 40 MiB（超过 1/4 预算）—— 刻意的取舍，
        // 因为「回拖 2 秒都要重下」的体验比多占几 MiB 差得多。
        assertEquals(BufferPlan.MIN_BACK_BUFFER_MS, BufferPlan.backBufferMs(budget48, 20.0).toLong())
    }

    // ── 性质：这条规则到底保证了什么 ─────────────────────────────

    @Test
    fun `未被下限钳住时 后缓冲占用永远不超过预算的四分之一`() {
        // 这是本规则的核心承诺：**前向稳拿 3/4**。
        // 逐一验证各档位（含钳顶的低码率档 —— 钳顶只会让它占得更少）。
        val rates = listOf(3.67, 2.0, 1.0, 0.63, 0.5, 0.31, 0.09)
        for (rate in rates) {
            val ms = BufferPlan.backBufferMs(budget48, rate)
            val usedMiB = rate * (ms / 1000.0)
            assertTrue(
                "码率 $rate MiB/s 时后缓冲占用 ${"%.2f".format(usedMiB)} MiB，" +
                    "超过了 48 MiB 预算的 1/4（12 MiB）",
                usedMiB <= budget48 / 1024.0 / 1024.0 * BufferPlan.BACK_BUFFER_FRACTION + 0.01,
            )
        }
    }

    @Test
    fun `后缓冲秒数随码率单调不增`() {
        // 码率越高，同样的字节额度只能存越短 —— 这是反算规则的单调性，
        // 破了说明公式写反了（比如把 ÷ 写成 ×）。
        val rates = listOf(0.09, 0.31, 0.63, 1.0, 2.0, 3.67)
        var previous = Int.MAX_VALUE
        for (rate in rates) {
            val ms = BufferPlan.backBufferMs(budget48, rate)
            assertTrue("码率 $rate 时后缓冲 $ms ms 反而变长了", ms <= previous)
            previous = ms
        }
    }
}
