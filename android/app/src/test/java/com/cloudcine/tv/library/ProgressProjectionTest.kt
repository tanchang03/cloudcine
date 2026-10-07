package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [ProgressProjection] —— 「回填时怎么夹」这三条规则的单测。
 *
 * 它是从 `LibraryDb.applyProgressSnapshot` 里抽出来的**纯函数**。抽出来的理由：
 * 那个方法跑在真的 SQLite 上（JVM 单测覆盖不到），而这三条规则写错的后果全是
 * **静默**的 —— 进度条倒退、排序被扰动、每次启动白写几千行。
 */
class ProgressProjectionTest {

    private fun want(
        resume: Long? = null,
        max: Long? = null,
        played: Long? = null,
        updated: Long = 1,
    ) = ProgressEntry(resumeMs = resume, maxMs = max, playedAtSec = played, updatedAtSec = updated)

    @Test
    fun `三条都一致 → 返回 null（调用方据此跳过 UPDATE）`() {
        assertNull(
            ProgressProjection.next(
                haveResumeMs = 1000,
                haveMaxMs = 5000,
                havePlayedAtSec = 100,
                want = want(resume = 1000, max = 5000, played = 100),
            ),
        )
    }

    @Test
    fun `库里那一行三列全空 + 真源有值 → 必须写`() {
        val next = ProgressProjection.next(
            haveResumeMs = null,
            haveMaxMs = null,
            havePlayedAtSec = null,
            want = want(resume = 1000, max = 5000, played = 100),
        )
        assertNotNull(next)
        assertEquals(1000L, next!!.resumeMs)
        assertEquals(5000L, next.maxMs)
        assertEquals(100L, next.playedAtSec)
    }

    @Test
    fun `resume 直接覆盖 —— 它本来就可清可改，不是单调量`() {
        // 真源里已经清掉了续播点（看完），库里还留着旧的。
        val next = ProgressProjection.next(
            haveResumeMs = 60_000,
            haveMaxMs = 60_000,
            havePlayedAtSec = 100,
            want = want(max = 60_000, played = 100),
        )
        assertNotNull("清掉续播点也是一次真实的改变", next)
        assertNull("必须真的清成 NULL，而不是保留旧值", next!!.resumeMs)
        assertEquals("另一列没变就不动", 60_000L, next.maxMs)
    }

    @Test
    fun `max 只增不减 —— 真源更浅时保留库里更深的`() {
        val next = ProgressProjection.next(
            haveResumeMs = null,
            haveMaxMs = 90_000,
            havePlayedAtSec = null,
            want = want(max = 5_000, played = 10),
        )
        assertNotNull(next)
        assertEquals("回填不能把历史最远位置往回拉", 90_000L, next!!.maxMs)
        assertEquals(10L, next.playedAtSec)
    }

    @Test
    fun `played 只前进 —— 最近播放不该倒退`() {
        val next = ProgressProjection.next(
            haveResumeMs = null,
            haveMaxMs = null,
            havePlayedAtSec = 2000,
            want = want(resume = 100, played = 100),
        )
        assertNotNull(next)
        assertEquals(2000L, next!!.playedAtSec)
        assertEquals("续播点仍按真源写", 100L, next.resumeMs)
    }

    @Test
    fun `真源里的 0 与负数一律归 null（与写侧口径一致）`() {
        val next = ProgressProjection.next(
            haveResumeMs = 1000,
            haveMaxMs = 1000,
            havePlayedAtSec = null,
            want = want(resume = 0, max = -5),
        )
        assertNotNull(next)
        assertNull("0 不是「续播到 0 毫秒」，是「没有可续的点」", next!!.resumeMs)
        assertEquals(
            "负数归 null 之后，max 那条「只增不减」的规则照旧生效（保留库里更深的）",
            1000L,
            next.maxMs,
        )
    }

    @Test
    fun `真源里的 0 与负数在库里也为空时落成 null`() {
        val next = ProgressProjection.next(
            haveResumeMs = null,
            haveMaxMs = null,
            havePlayedAtSec = null,
            want = want(resume = 0, max = -5, played = null),
        )
        assertNull("三条都没变 ⇒ 不用写", next)
    }

    @Test
    fun `真源里三列全空且库里也全空 → 不用写`() {
        assertNull(
            ProgressProjection.next(
                haveResumeMs = null,
                haveMaxMs = null,
                havePlayedAtSec = null,
                want = want(),
            ),
        )
    }

    @Test
    fun `真源里三列全空但库里有值 → 只清 resume，单调两列保持`() {
        val next = ProgressProjection.next(
            haveResumeMs = 1000,
            haveMaxMs = 1000,
            havePlayedAtSec = 100,
            want = want(),
        )
        assertNotNull(next)
        assertNull(next!!.resumeMs)
        assertEquals(1000L, next.maxMs)
        assertEquals(100L, next.playedAtSec)
    }
}
