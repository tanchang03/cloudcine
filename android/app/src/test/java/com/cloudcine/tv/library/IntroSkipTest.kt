package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [IntroMarker] / [IntroSkip] / [IntroSession] 的单测 —— 与 PC 端
 * `test/domain/intro_session_test.dart` 同口径。
 *
 * ## 为什么这一组必测
 *
 * 跳片头错了**不会报错、不会崩**：要么「点了没反应」（用户以为功能坏了），
 * 要么「画面突然倒回片头然后卡住」（区间反了）。两种都只能靠用户投诉发现。
 *
 * ⛔ 与 PC 端唯一的**有意差异**：这边没有「文件章节」那一层（Media3 读不到
 *    容器章节），所以取值链只有 `手标 > 学习` 两级。
 */
class IntroSkipTest {

    private val m92 = IntroMarker(0L, 92_000L)

    // ------------------------------------------------------------------
    // IntroMarker
    // ------------------------------------------------------------------

    @Test
    fun `半条标记当没有`() {
        assertNull(IntroMarker.fromMilliseconds(null, 92_000L))
        assertNull(IntroMarker.fromMilliseconds(0L, null))
    }

    @Test
    fun `反过来的区间当没有`() {
        assertNull(
            "end <= start 不会报错，只会让「跳过片头」变成一次向后跳",
            IntroMarker.fromMilliseconds(92_000L, 30_000L),
        )
        assertNull(IntroMarker.fromMilliseconds(50_000L, 50_000L))
    }

    @Test
    fun `终点非正当没有`() {
        assertNull(IntroMarker.fromMilliseconds(0L, 0L))
        assertNull(IntroMarker.fromMilliseconds(-1_000L, 92_000L))
    }

    @Test
    fun `正常区间能构造出来`() {
        assertEquals(IntroMarker(0L, 92_000L), IntroMarker.fromMilliseconds(0L, 92_000L))
    }

    // ------------------------------------------------------------------
    // IntroSkip.shouldSkip
    // ------------------------------------------------------------------

    @Test
    fun `区间内且没跳过就要跳`() {
        assertTrue(IntroSkip.shouldSkip(10_000L, m92, skipped = false))
    }

    @Test
    fun `已经跳过就不跳`() {
        assertFalse(IntroSkip.shouldSkip(10_000L, m92, skipped = true))
    }

    @Test
    fun `还没进区间不跳`() {
        assertFalse(
            "position < start 时不该跳（start 通常就是 0，这一条挡的是非零 start）",
            IntroSkip.shouldSkip(-1L, IntroMarker(5_000L, 92_000L), skipped = false),
        )
    }

    @Test
    fun `位置为 0 不跳`() {
        assertFalse(IntroSkip.shouldSkip(0L, m92, skipped = false))
    }

    @Test
    fun `快到终点就不跳了`() {
        assertFalse(
            "只剩不到 1 秒时再跳，画面几乎不动、进度条只抖一下",
            IntroSkip.shouldSkip(91_500L, m92, skipped = false),
        )
    }

    @Test
    fun `没有区间就不跳`() {
        assertFalse(IntroSkip.shouldSkip(10_000L, null, skipped = false))
    }

    // ------------------------------------------------------------------
    // IntroSession
    // ------------------------------------------------------------------

    @Test
    fun `手标优先于学习`() {
        val s = IntroSession(
            manual = IntroMarker(0L, 60_000L),
            learned = IntroMarker(0L, 92_000L),
        )

        assertEquals(60_000L, s.marker?.endMs)
        assertFalse("生效的是手标，不是学习", s.isFromLearned)
    }

    @Test
    fun `没有手标时用学习`() {
        val s = IntroSession(learned = IntroMarker(0L, 92_000L))

        assertEquals(92_000L, s.marker?.endMs)
        assertTrue(s.isFromLearned)
    }

    @Test
    fun `都没有时不跳`() {
        val s = IntroSession()

        assertNull(s.marker)
        assertNull(s.takeSkipTarget(10_000L))
    }

    @Test
    fun `关掉开关时一次都不跳`() {
        val s = IntroSession(learned = IntroMarker(0L, 92_000L), enabled = false)

        assertNull(s.takeSkipTarget(10_000L))
        assertFalse(s.hasSkipped)
    }

    @Test
    fun `取一次目标之后就置位，第二次返回 null`() {
        val s = IntroSession(learned = IntroMarker(0L, 92_000L))

        assertEquals(
            "把置位收进 takeSkipTarget：seek 是异步往返，晚置位会连发几次 seek",
            92_000L,
            s.takeSkipTarget(10_000L),
        )
        assertNull(s.takeSkipTarget(11_000L))
        assertTrue(s.hasSkipped)
    }

    @Test
    fun `换集时 reset 把已跳过归零`() {
        val s = IntroSession(learned = IntroMarker(0L, 92_000L))
        assertEquals(92_000L, s.takeSkipTarget(10_000L))

        s.reset(learned = IntroMarker(0L, 92_000L))

        assertEquals(
            "漏了归零的表现是「只有第一集跳片头」—— 而第一集恰好最不需要跳",
            92_000L,
            s.takeSkipTarget(10_000L),
        )
    }

    @Test
    fun `endStream 保留区间只清已跳过`() {
        val s = IntroSession(learned = IntroMarker(0L, 92_000L))
        assertEquals(92_000L, s.takeSkipTarget(10_000L))

        s.endStream()

        assertEquals("退出播放页再进来，第一次仍然要跳", 92_000L, s.takeSkipTarget(10_000L))
    }

    @Test
    fun `新学出区间之后重新给一次机会`() {
        val s = IntroSession()
        assertNull(s.takeSkipTarget(10_000L))

        // 「当场学会」：用户第一次拖到片尾切集，样本就够了，结论立刻写回。
        // 不归零的话这一集就再也不会提示 —— 用户会觉得「刚学会的东西没生效」。
        s.setLearned(IntroMarker(0L, 92_000L))

        assertEquals(92_000L, s.takeSkipTarget(10_000L))
    }

    @Test
    fun `手标改了之后重新给一次机会`() {
        val s = IntroSession(manual = IntroMarker(0L, 60_000L))
        assertEquals(60_000L, s.takeSkipTarget(10_000L))

        s.setManual(IntroMarker(0L, 92_000L))

        assertEquals(92_000L, s.takeSkipTarget(10_000L))
    }

    // ------------------------------------------------------------------
    // OutroSkip —— 片尾偏移的取值链与落点换算（schema v19）
    // ------------------------------------------------------------------
    //
    // ⛔ 这一组防的是「**在电脑上标了片尾，电视上不跳**」：手标那一列唯一的
    //    来源是 PC 端（电视上没有界面可写），Android 只读得到学习出来的那份。
    //    不读手标的话两端都不报错，用户只会觉得「时灵时不灵」。

    @Test
    fun `片尾：手标优先于学习`() {
        assertEquals(
            "手标是用户明确指定的，学习是推断 —— 推断压过明确指定，用户没法知道哪层在生效",
            120_000L,
            OutroSkip.effectiveOffsetMs(manualMs = 120_000L, learnedMs = 90_000L),
        )
    }

    @Test
    fun `片尾：没有手标时用学习`() {
        assertEquals(90_000L, OutroSkip.effectiveOffsetMs(manualMs = null, learnedMs = 90_000L))
    }

    @Test
    fun `片尾：都没有时不提示`() {
        assertNull(OutroSkip.effectiveOffsetMs(manualMs = null, learnedMs = null))
    }

    @Test
    fun `片尾：非正当没标`() {
        assertNull(
            "偏移 ≤ 0 意味着片尾从片长那一刻才开始，也就是「没有片尾」",
            OutroSkip.effectiveOffsetMs(manualMs = 0L, learnedMs = -1L),
        )
        assertEquals(
            "手标是 0 等于没标，要落到学习那一份上，而不是整体当没有",
            90_000L,
            OutroSkip.effectiveOffsetMs(manualMs = 0L, learnedMs = 90_000L),
        )
    }

    @Test
    fun `片尾落点用片长现算`() {
        val duration = 45 * 60_000L

        assertEquals(
            "存的是「距末尾多久」，落点必须用这一集的片长现算 —— 各集片长不同",
            duration - 90_000L,
            OutroSkip.startMs(durationMs = duration, offsetMs = 90_000L),
        )
    }

    @Test
    fun `片尾：片长未知算不出落点`() {
        assertNull(
            "拿 0 当片长会让「跳片尾」变成「跳到 0 秒」",
            OutroSkip.startMs(durationMs = 0L, offsetMs = 90_000L),
        )
    }

    @Test
    fun `片尾：偏移比片长还大时不跳`() {
        assertNull(
            "偏移 ≥ 片长说明数据坏了（比如换了一集更短的）—— 不跳比乱跳好",
            OutroSkip.startMs(durationMs = 60_000L, offsetMs = 90_000L),
        )
        assertNull(
            "偏移恰好等于片长 ⇒ 落点 0 秒，同样不该跳",
            OutroSkip.startMs(durationMs = 90_000L, offsetMs = 90_000L),
        )
    }

    @Test
    fun `片尾：没有偏移就没有落点`() {
        assertNull(OutroSkip.startMs(durationMs = 45 * 60_000L, offsetMs = null))
        assertNull(OutroSkip.startMs(durationMs = 45 * 60_000L, offsetMs = 0L))
    }
}
