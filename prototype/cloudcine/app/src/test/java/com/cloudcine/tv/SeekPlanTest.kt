package com.cloudcine.tv

import org.junit.Assert.assertEquals
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
}
