package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SkipLearning] / [SkipAnchorCollector] 的单测 —— 与 PC 端
 * `test/domain/skip_learning_test.dart` **同一批用例**。
 *
 * ## 为什么这一组必须两端都跑
 *
 * 学习错了**不会报错、不会崩**，只是「跳到了不该跳的地方」或「明明该跳却不跳」。
 * 而更糟的是**两端不一致**：同一部剧在电脑上能学出片头、在电视上不能，用户看到
 * 的是「这功能时灵时不灵」，而两边的日志都干净。
 *
 * 所以这份用例是**镜像**的：Dart 那边加一条，这边就加一条。
 */
class SkipLearningTest {

    /** 一集 45 分钟的片子（学习门槛 `MIN_DURATION_MS = 8min` 之上）。 */
    private val episode = 45 * 60_000L

    private fun sample(
        kind: SkipKind,
        anchorMs: Long,
        durationMs: Long = episode,
        negative: Boolean = false,
        itemId: String = "q:1",
        workKey: String = "w",
    ) = SkipSample(
        id = SkipSample.idFor(itemId, kind, 0L),
        itemId = itemId,
        workKey = workKey,
        kind = kind,
        anchorMs = anchorMs,
        durationMs = durationMs,
        negative = negative,
        createdAtMs = 0L,
    )

    /** 用户拖了一次并**停下来看了**。 */
    private fun seekAndWatch(
        c: SkipAnchorCollector,
        fromMs: Long,
        toMs: Long,
        durationMs: Long = episode,
        rate: Double = 1.0,
        watchMs: Long = SkipLearning.STABLE_WATCH_MS,
    ): SkipAnchor? {
        c.noteSeek(SeekObservation(fromMs, toMs, durationMs, rate))
        return c.notePosition(toMs + watchMs)
    }

    // ------------------------------------------------------------------
    // 有效落点：只有「停下来看」才算
    // ------------------------------------------------------------------

    @Test
    fun `拖到 92 秒并停留，确认片头锚点`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val anchor = seekAndWatch(c, 0L, 92_000L)

        assertNotNull(anchor)
        assertEquals(92_000L, anchor!!.anchorMs)
        assertEquals(SkipKind.INTRO, SkipLearning.classify(anchor))
    }

    @Test
    fun `停留不够长就不确认（探索性拖拽）`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val anchor = seekAndWatch(c, 0L, 92_000L, watchMs = 5_000L)

        assertNull("看 5 秒不算「停下来」", anchor)
        assertEquals("落点仍在待确认", 92_000L, c.pending)
    }

    @Test
    fun `拖了又拖，只有最后一个落点作数`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        c.noteSeek(SeekObservation(0L, 92_000L, episode, 1.0))
        // 还没停留够就又往前拖了一次 —— 第一个落点作废。
        val anchor = seekAndWatch(c, 92_000L, 110_000L)

        assertNotNull(anchor)
        assertEquals("用户最后停下来的位置才是有效落点", 110_000L, anchor!!.anchorMs)
    }

    @Test
    fun `回拖之后该落点作废`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        c.noteSeek(SeekObservation(0L, 92_000L, episode, 1.0))
        // 用户拖回去重看片头 —— 说明 92 秒不是他要跳过的位置。
        val anchor = c.notePosition(10_000L)

        assertNull(anchor)
        assertNull("回拖之后不该再留着待确认落点", c.pending)
    }

    @Test
    fun `后退方向的 seek 根本不记`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        c.noteSeek(SeekObservation(10 * 60_000L, 3 * 60_000L, episode, 1.0))

        assertNull(c.pending)
    }

    @Test
    fun `幅度太小的 seek 不记`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        c.noteSeek(SeekObservation(90_000L, 91_000L, episode, 1.0))

        assertNull(c.pending)
    }

    @Test
    fun `倍速播放时的 seek 不记`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        c.noteSeek(SeekObservation(0L, 92_000L, episode, 2.0))

        assertNull(c.pending)
    }

    // ------------------------------------------------------------------
    // 片头 / 片尾分类
    // ------------------------------------------------------------------

    @Test
    fun `落点在正片中间，既不是片头也不是片尾`() {
        val anchor = SkipAnchor(20 * 60_000L, episode, 0L)

        assertNull(SkipLearning.classify(anchor))
    }

    @Test
    fun `续播时不产生片头锚点`() {
        val anchor = SkipAnchor(92_000L, episode, 5 * 60_000L)

        assertNull("用户没看过开头，「0 → 落点」这个区间不成立", SkipLearning.classify(anchor))
    }

    @Test
    fun `落点距末尾 40 秒，判为片尾`() {
        val anchor = SkipAnchor(episode - 40_000L, episode, 0L)

        assertEquals(SkipKind.OUTRO, SkipLearning.classify(anchor))
    }

    @Test
    fun `短视频（8 分钟以内）不学习`() {
        val anchor = SkipAnchor(5 * 60_000L + 30_000L, 6 * 60_000L, 0L)

        assertNull(SkipLearning.classify(anchor))
    }

    // ------------------------------------------------------------------
    // 片尾靠「切下一集」确认，不靠停留
    // ------------------------------------------------------------------

    @Test
    fun `拖到片尾并停留，不产出片尾锚点`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val anchor = seekAndWatch(c, 10 * 60_000L, episode - 40_000L)

        assertNull("停留确认不可撤回，而「看完」与「切集」在那一刻分不清", anchor)
    }

    @Test
    fun `从距末尾 40 秒处切下一集，产出片尾锚点`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val anchor = c.noteEpisodeSwitch(episode - 40_000L, episode)

        assertNotNull(anchor)
        assertEquals(40_000L, anchor!!.offsetMs)
    }

    @Test
    fun `自然播完自动连播，不产出片尾锚点`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val anchor = c.noteEpisodeSwitch(episode - 1_000L, episode)

        assertNull("用户把结尾看完了，那里不是片尾", anchor)
    }

    @Test
    fun `看了 10 秒就切集，什么都不产出`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        assertNull(c.noteEpisodeSwitch(10_000L, episode))
    }

    @Test
    fun `同一次播放里片尾最多产一条`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val first = c.noteEpisodeSwitch(episode - 40_000L, episode)
        val second = c.noteEpisodeSwitch(episode - 30_000L, episode)

        assertNotNull(first)
        assertNull(second)
    }

    @Test
    fun `同一次播放里片头最多产一条`() {
        val c = SkipAnchorCollector()
        c.notePlayStart(0L)

        val first = seekAndWatch(c, 0L, 92_000L)
        val second = seekAndWatch(c, 0L, 95_000L)

        assertNotNull(first)
        assertNull(second)
    }

    // ------------------------------------------------------------------
    // 跨集聚合：中位数 + MAD
    // ------------------------------------------------------------------

    @Test
    fun `三集落点一致，学出片头`() {
        val samples = listOf(
            sample(SkipKind.INTRO, 90_000L, itemId = "q:1"),
            sample(SkipKind.INTRO, 92_000L, itemId = "q:2"),
            sample(SkipKind.INTRO, 91_000L, itemId = "q:3"),
        )

        val intro = SkipLearning.learnIntro(samples)

        assertNotNull(intro)
        assertEquals(91_000L, intro!!.endMs)
        assertEquals(3, intro.samples)
        assertEquals(1_000L, intro.spreadMs)
    }

    @Test
    fun `一个离群点不影响结论`() {
        val samples = listOf(
            sample(SkipKind.INTRO, 90_000L, itemId = "q:1"),
            sample(SkipKind.INTRO, 92_000L, itemId = "q:2"),
            sample(SkipKind.INTRO, 91_000L, itemId = "q:3"),
            // 用户在某集拖到了第 20 分钟看剧情 —— 均值会被拽到 6 分钟，
            // 中位数几乎不动。
            sample(SkipKind.INTRO, 20 * 60_000L, itemId = "q:4"),
        )

        val intro = SkipLearning.learnIntro(samples)

        assertNotNull(intro)
        assertEquals(
            "四个样本的中位数 = 中间两个(91s, 92s)的平均 = 91.5s",
            91_500L,
            intro!!.endMs,
        )
        assertEquals("MAD 只看到 1 秒的散布", 1_000L, intro.spreadMs)
    }

    @Test
    fun `落点散得厉害就拒绝建立`() {
        val samples = listOf(
            sample(SkipKind.INTRO, 20_000L, itemId = "q:1"),
            sample(SkipKind.INTRO, 90_000L, itemId = "q:2"),
            sample(SkipKind.INTRO, 160_000L, itemId = "q:3"),
        )

        assertNull(SkipLearning.learnIntro(samples))
    }

    @Test
    fun `样本不足 3 集就拒绝建立`() {
        val samples = listOf(
            sample(SkipKind.INTRO, 90_000L, itemId = "q:1"),
            sample(SkipKind.INTRO, 91_000L, itemId = "q:2"),
        )

        assertNull(SkipLearning.learnIntro(samples))
    }

    @Test
    fun `负样本不参与聚合`() {
        val samples = listOf(
            sample(SkipKind.INTRO, 90_000L, itemId = "q:1"),
            sample(SkipKind.INTRO, 91_000L, itemId = "q:2"),
            sample(SkipKind.INTRO, 30 * 60_000L, itemId = "q:3", negative = true),
        )

        assertNull("去掉负样本只剩 2 条，够不到门槛", SkipLearning.learnIntro(samples))
    }

    @Test
    fun `片尾用距末尾的偏移聚合，各集片长不同也能对齐`() {
        // 正片 45 分钟、特辑 60 分钟 —— 绝对时间差 15 分钟，
        // 但「离结尾 40 秒开始是片尾」是一致的。
        val samples = listOf(
            sample(SkipKind.OUTRO, episode - 40_000L, itemId = "q:1"),
            sample(SkipKind.OUTRO, episode - 42_000L, itemId = "q:2"),
            sample(SkipKind.OUTRO, 60 * 60_000L - 41_000L, 60 * 60_000L, itemId = "q:3"),
        )

        val outro = SkipLearning.learnOutro(samples)

        assertNotNull(outro)
        assertEquals(41_000L, outro!!.offsetMs)
        assertEquals(3, outro.samples)
    }

    @Test
    fun `片尾偏移超过 5 分钟就不是片尾`() {
        val samples = listOf(
            sample(SkipKind.OUTRO, episode - 12 * 60_000L, itemId = "q:1"),
            sample(SkipKind.OUTRO, episode - 12 * 60_000L, itemId = "q:2"),
            sample(SkipKind.OUTRO, episode - 12 * 60_000L, itemId = "q:3"),
        )

        assertNull(SkipLearning.learnOutro(samples))
    }

    @Test
    fun `片头与片尾一起学出来`() {
        val samples = listOf(
            sample(SkipKind.INTRO, 90_000L, itemId = "q:1"),
            sample(SkipKind.INTRO, 92_000L, itemId = "q:2"),
            sample(SkipKind.INTRO, 91_000L, itemId = "q:3"),
            sample(SkipKind.OUTRO, episode - 40_000L, itemId = "q:1"),
            sample(SkipKind.OUTRO, episode - 42_000L, itemId = "q:2"),
            sample(SkipKind.OUTRO, episode - 41_000L, itemId = "q:3"),
        )

        val outcome = SkipLearning.learn(samples)

        assertNotNull(outcome.intro)
        assertNotNull(outcome.outro)
        assertEquals("取两者的较大值", 3, outcome.samples)
        assertFalse(outcome.isEmpty)
    }

    @Test
    fun `什么都没传时结果为空`() {
        val outcome = SkipLearning.learn(emptyList())

        assertTrue(outcome.isEmpty)
        assertEquals(0, outcome.samples)
    }

    // ------------------------------------------------------------------
    // 中位数工具
    // ------------------------------------------------------------------

    @Test
    fun `中位数奇数个取中间`() {
        assertEquals(2_000L, SkipLearning.median(listOf(3_000L, 1_000L, 2_000L)))
    }

    @Test
    fun `中位数偶数个取中间两个的平均`() {
        assertEquals(
            2_500L,
            SkipLearning.median(listOf(1_000L, 2_000L, 3_000L, 4_000L)),
        )
    }

    @Test
    fun `中位数空列表返回 null`() {
        assertNull(SkipLearning.median(emptyList()))
    }

    @Test
    fun `MAD 空列表返回 0`() {
        assertEquals(0L, SkipLearning.medianAbsoluteDeviation(emptyList(), 0L))
    }

    // ------------------------------------------------------------------
    // 契约：与 PC 端必须同源
    // ------------------------------------------------------------------

    /**
     * 阈值是**跨端契约**，两端各改一处就会漂移成「电脑学得出来、电视学不出来」。
     *
     * ⛔ 改这里必须同步改 `lib/domain/services/skip_learning.dart` 的
     *    `SkipLearning` 常量，以及 Dart 侧的 `skip_learning_test.dart`。
     */
    @Test
    fun `阈值与 PC 端逐字一致`() {
        assertEquals(15_000L, SkipLearning.STABLE_WATCH_MS)
        assertEquals(3_000L, SkipLearning.MIN_SEEK_DELTA_MS)
        assertEquals(15_000L, SkipLearning.INTRO_MIN_ANCHOR_MS)
        assertEquals(180_000L, SkipLearning.INTRO_MAX_ANCHOR_MS)
        assertEquals(30_000L, SkipLearning.FROM_START_MAX_MS)
        assertEquals(10_000L, SkipLearning.OUTRO_MIN_OFFSET_MS)
        assertEquals(300_000L, SkipLearning.OUTRO_MAX_OFFSET_MS)
        assertEquals(480_000L, SkipLearning.MIN_DURATION_MS)
        assertEquals(3, SkipLearning.MIN_SAMPLES)
        assertEquals(8_000L, SkipLearning.INTRO_MAX_SPREAD_MS)
        assertEquals(10_000L, SkipLearning.OUTRO_MAX_SPREAD_MS)
    }

    /**
     * `kind` 落库用的是**字符串**（`skip_samples.kind`），而它的拼写是跨端契约。
     *
     * ⛔ 与 PC 端 `SkipKind.name`（Dart 枚举名，小写）逐字一致。写错的表现是
     *    「PC 学的片尾在电视上被当成片头」—— 两边看起来都正常。
     */
    @Test
    fun `kind 的落库字符串与 PC 端一致`() {
        assertEquals("intro", SkipKind.INTRO.dbName)
        assertEquals("outro", SkipKind.OUTRO.dbName)
        assertEquals(SkipKind.INTRO, SkipKind.parse("intro"))
        assertEquals(SkipKind.OUTRO, SkipKind.parse("outro"))
        assertNull("认不出来就当样本作废，不要猜", SkipKind.parse("Intro"))
        assertNull(SkipKind.parse(null))
    }

    @Test
    fun `样本主键在两端可复现`() {
        assertEquals("q:1#intro#1234", SkipSample.idFor("q:1", SkipKind.INTRO, 1234L))
    }
}
