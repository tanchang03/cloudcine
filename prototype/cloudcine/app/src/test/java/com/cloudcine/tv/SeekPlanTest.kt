package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SeekPlan] 的单测。
 *
 * ## 为什么这一组值得测
 *
 * 这段算术是「连续快进」的**唯一**逻辑，而它有两个写错了**不会报错**、
 * 只会让手感变怪的点：
 *
 * 1. **基准取错** —— 拿 `currentPosition` 当基准累加，连续按 10 次右键
 *    只走 10 秒。看起来像「按键失灵」，而日志上每次 seek 都成功了。
 * 2. **上界取错** —— 时长未知时 `Player.duration` 是 `C.TIME_UNSET`（`-1`）。
 *    直接 `coerceIn(0, -1)` 会抛 `IllegalArgumentException`（`min > max`），
 *    崩在一句纯算术上。
 *
 * 另外它守护的是**内存**：实测一次拖拽 2 秒内 28 次 `seekTo`，每次都新建
 * 一个 `8 × 2 MiB` 的并行读取器，把 192 MiB 的堆打满 ⇒ `OutOfMemoryError`。
 * 防抖能不能把 28 次并成 1 次，取决于「目标累加」这一步算得对不对 ——
 * 算错了（比如每次都从 `currentPosition` 起算），用户就会按不到想去的
 * 位置，然后**反复按**，正好把 seek 风暴又招回来。
 */
class SeekPlanTest {

    private val min = 60_000L
    private val hour = 3_600_000L

    // ── 累加 ────────────────────────────────────────────────────

    @Test
    fun `没有待提交目标时从当前位置起算`() {
        assertEquals(
            90_000L,
            SeekPlan.step(SeekPlan.NO_PENDING, currentMs = 80_000L, deltaMs = 10_000L, durationMs = hour),
        )
        assertEquals(
            70_000L,
            SeekPlan.step(SeekPlan.NO_PENDING, currentMs = 80_000L, deltaMs = -10_000L, durationMs = hour),
        )
    }

    @Test
    fun `有待提交目标时必须从它起算而不是从当前位置`() {
        // ⛔ 这条是核心：连按 3 次右键，播放器位置一直停在 80s（还没提交），
        //    目标应当是 80 → 90 → 100 → 110。若从 currentPosition 起算，
        //    三次都算成 90s —— 用户看到的就是「按了不动」。
        var pending = SeekPlan.NO_PENDING
        val current = 80_000L
        pending = SeekPlan.step(pending, current, 10_000L, hour)
        assertEquals(90_000L, pending)
        pending = SeekPlan.step(pending, current, 10_000L, hour)
        assertEquals(100_000L, pending)
        pending = SeekPlan.step(pending, current, 10_000L, hour)
        assertEquals(110_000L, pending)
        // 播放器位置始终没变，这正是「防抖期间不 seek」的体现。
        assertEquals(80_000L, current)
    }

    @Test
    fun `往回按同样要累加`() {
        var pending = SeekPlan.NO_PENDING
        pending = SeekPlan.step(pending, 80_000L, -10_000L, hour)
        assertEquals(70_000L, pending)
        pending = SeekPlan.step(pending, 80_000L, -10_000L, hour)
        assertEquals(60_000L, pending)
    }

    @Test
    fun `累加可以跨越当前位置`() {
        // 按 10 次右键 = 100 秒，应落到 180s。
        var pending = SeekPlan.NO_PENDING
        repeat(10) { pending = SeekPlan.step(pending, 80_000L, 10_000L, hour) }
        assertEquals(180_000L, pending)
    }

    // ── 下界 ────────────────────────────────────────────────────

    @Test
    fun `往前按过头夹到 0`() {
        assertEquals(0L, SeekPlan.step(SeekPlan.NO_PENDING, 30_000L, -60_000L, hour))
        assertEquals(0L, SeekPlan.step(5_000L, 80_000L, -30_000L, hour))
        assertEquals(0L, SeekPlan.step(0L, 80_000L, -30_000L, hour))
    }

    // ── 上界 ────────────────────────────────────────────────────

    @Test
    fun `往后按过头夹到片长`() {
        assertEquals(hour, SeekPlan.step(SeekPlan.NO_PENDING, hour - 5_000L, 30_000L, hour))
        assertEquals(hour, SeekPlan.step(hour, 0L, 10_000L, hour))
    }

    @Test
    fun `时长未知时不做上界夹取且不抛异常`() {
        // ⛔ 这是「不会报错的坑」那条：`C.TIME_UNSET` 是 -1。
        //    若实现写成 `coerceIn(0, durationMs)`，这里会抛
        //    IllegalArgumentException（min > max），崩在一句纯算术上。
        assertEquals(
            Long.MAX_VALUE,
            SeekPlan.step(Long.MAX_VALUE - 1L, 0L, 10_000L, durationMs = -1L),
        )
        // 0 与负数都算「还不知道」，一律按无上界处理。
        assertEquals(
            90_000L,
            SeekPlan.step(SeekPlan.NO_PENDING, 80_000L, 10_000L, durationMs = 0L),
        )
        assertEquals(
            90_000L,
            SeekPlan.step(SeekPlan.NO_PENDING, 80_000L, 10_000L, durationMs = -5L),
        )
    }

    // ── 溢出兜底 ────────────────────────────────────────────────

    @Test
    fun `正向溢出夹到上界而不是翻成负数`() {
        // 片长未知（上界 = Long.MAX_VALUE）时，再往前加就会溢出。
        // ⛔ 不兜底的话 `base + delta` 会翻成**负数**，然后被夹到 0 ——
        //    用户按「快进」却跳回片头。这条就是防它。
        val r = SeekPlan.step(Long.MAX_VALUE, 0L, 1_000L, durationMs = -1L)
        assertEquals(Long.MAX_VALUE, r)
    }

    @Test
    fun `反向溢出夹到 0 而不是翻成正数`() {
        // 基准取到极负（`currentPosition` 理论上是非负的，但这是**纯函数**，
        // 不能假设调用方一定守规矩），再往回减就溢出。
        // ⛔ 不兜底的话会翻成**正数**，然后被夹到上界 —— 用户按「快退」
        //    却跳到了片尾。
        val r = SeekPlan.step(SeekPlan.NO_PENDING, Long.MIN_VALUE + 1L, -1_000L, hour)
        assertEquals(0L, r)
    }

    // ── 边界常量 ────────────────────────────────────────────────

    @Test
    fun `待提交目标恰好为 0 时算作有效目标`() {
        // `NO_PENDING` 是 -1，而 0 是**合法目标**（跳到片头）。
        // 若实现写成 `pendingMs >= 0` 之外别的判据（比如 `> 0`），
        // 会把「已经拖到片头」当成「没有待提交」，于是又退回 currentPosition。
        assertEquals(10_000L, SeekPlan.step(0L, 80_000L, 10_000L, hour))
    }

    @Test
    fun `步进为 0 时目标不变`() {
        assertEquals(80_000L, SeekPlan.step(SeekPlan.NO_PENDING, 80_000L, 0L, hour))
        assertEquals(55_000L, SeekPlan.step(55_000L, 80_000L, 0L, hour))
    }

    @Test
    fun `十分钟步进在一次内也能正确夹取`() {
        // 菜单里若把步进调大（比如 ±10 分钟），夹取同样要成立。
        val tenMin = 600_000L
        assertEquals(hour, SeekPlan.step(SeekPlan.NO_PENDING, hour - min, tenMin, hour))
        assertEquals(0L, SeekPlan.step(SeekPlan.NO_PENDING, min, -tenMin, hour))
    }

    // ── 加速加成 ────────────────────────────────────────────────

    @Test
    fun `前两秒必须不加速`() {
        // ⛔ 这是**手感约定**，不是随手取的数：用户原话是「不要太快，否则
        //    没有反应时间就拖完」。前 2 秒按 20 次/秒算 = 40 次 × 10 秒 =
        //    400 秒的可调范围，而落点精度仍是 10 秒 —— 那 2 秒是留给
        //    「我要精确停在这里」的。改倍率表就必须先改这条断言。
        assertEquals(1, SeekPlan.multiplier(0L))
        assertEquals(1, SeekPlan.multiplier(500L))
        assertEquals(1, SeekPlan.multiplier(1_999L))
        assertEquals(10_000L, SeekPlan.acceleratedDelta(10_000L, 1_999L))
    }

    @Test
    fun `倍率按按住时长逐级上升`() {
        assertEquals(2, SeekPlan.multiplier(2_000L))
        assertEquals(2, SeekPlan.multiplier(3_999L))
        assertEquals(4, SeekPlan.multiplier(4_000L))
        assertEquals(4, SeekPlan.multiplier(5_999L))
        assertEquals(8, SeekPlan.multiplier(6_000L))
        assertEquals(8, SeekPlan.multiplier(8_999L))
        assertEquals(12, SeekPlan.multiplier(9_000L))
        // 按住很久也**封顶** —— 不封顶就会变成「一按到底」，同样是
        // 「没有反应时间」。
        assertEquals(12, SeekPlan.multiplier(60_000L))
        assertEquals(12, SeekPlan.multiplier(Long.MAX_VALUE))
    }

    @Test
    fun `倍率单调不降`() {
        // 加速档位一旦回退，用户会看到「按着按着反而变慢了」。
        var prev = 0
        var t = 0L
        while (t < 20_000L) {
            val m = SeekPlan.multiplier(t)
            assertTrue("t=$t 倍率回退了：$prev → $m", m >= prev)
            prev = m
            t += 100L
        }
    }

    @Test
    fun `快退的加速必须保持负号`() {
        // ⛔ 这里错一次就是「按快退往前跳」。别在实现里做 abs()。
        assertEquals(-10_000L, SeekPlan.acceleratedDelta(-10_000L, 0L))
        assertEquals(-20_000L, SeekPlan.acceleratedDelta(-10_000L, 2_500L))
        assertEquals(-120_000L, SeekPlan.acceleratedDelta(-10_000L, 10_000L))
    }

    @Test
    fun `加速后的步进仍受片长夹取`() {
        // 加速只是把步长放大，夹取的责任仍在 step 里。
        val step = SeekPlan.acceleratedDelta(10_000L, 10_000L) // ×12 = 120s
        assertEquals(120_000L, step)
        assertEquals(
            hour,
            SeekPlan.step(SeekPlan.NO_PENDING, hour - 1_000L, step, hour),
        )
    }

    @Test
    fun `按二十次每秒估算两小时片长九秒左右到底`() {
        // 这条把「手感」变成可核对的算术：模拟 20 次/秒按住，看多久走完
        // 一部 2 小时的片子。**不是**精确规格，是防止有人把倍率表改到
        // 「要么拖不动、要么一按到底」的极端。
        val twoHours = 2 * hour
        var pending = SeekPlan.NO_PENDING
        var elapsed = 0L
        val tick = 50L
        while (elapsed < 30_000L && pending < twoHours) {
            val step = SeekPlan.acceleratedDelta(10_000L, elapsed)
            pending = SeekPlan.step(pending, 0L, step, twoHours)
            elapsed += tick
        }
        assertTrue("2 小时片长不该超过 15 秒才拖到底，实测 ${elapsed}ms", elapsed < 15_000L)
        assertTrue("也不该快到 3 秒以内（没有反应时间），实测 ${elapsed}ms", elapsed > 3_000L)
    }
}
