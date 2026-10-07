package com.cloudcine.tv.library

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 剧集行的「■ NEW」判据 —— [Work.isNewSinceFollow]。
 *
 * ## 为什么这一组必须钉死
 *
 * 这条判据错了**不会报错、不会崩**，只是那一行的前缀多一个词或少一个词：
 *
 *   * 判得太宽 ⇒ 追剧之后入库的**老集**也挂 NEW（刚开追剧就把 12 集全标上）；
 *   * 判得太严 ⇒ 用户点开看过一集，回来还挂着 NEW，而**他没有任何办法清掉它**
 *     （2026-10-07 现场：用户点开 `Z 遮 天 E184` 看了 3 秒就关窗，
 *     那一行一直写着「■ NEW」，海报上「更新 2」也不动）。
 *
 * 第二种是本次修复的对象。它之所以发生，是因为「看过没有」原先只看
 * `max_position_ms`，而那一列只在 `p.duration > 0` 时写 —— 时长探测不出来
 * （转码流、探测失败）就一个字都不写。现在改成
 * **`maxPositionMs` 与 `lastPlayedAt` 两条取或**（与 PC 端
 * `lib/domain/services/follow_read.dart` 的 `isItemWatched` 同源）。
 */
class FollowReadTest {

    // ==================================================================
    // 第 1 条：firstSeenAt 水位线
    // ==================================================================

    @Test
    fun `追剧之前入库的集不算新集`() {
        val w = work(followStartedAt = 1_000L)
        assertFalse(
            "追剧之前就在库里的集，开启追剧那一刻不该被标成 NEW",
            w.isNewSinceFollow(item(firstSeenAt = 999L)),
        )
    }

    @Test
    fun `水位线正好相等不算新集`() {
        val w = work(followStartedAt = 1_000L)
        assertFalse(
            "同一秒入库的算「之前」—— 否则刚开追剧的那一次检查会把自己扫到的算成更新",
            w.isNewSinceFollow(item(firstSeenAt = 1_000L)),
        )
    }

    @Test
    fun `追剧之后入库的集算新集`() {
        val w = work(followStartedAt = 1_000L)
        assertTrue(w.isNewSinceFollow(item(firstSeenAt = 1_001L)))
    }

    @Test
    fun `没在追剧时一条都不算`() {
        val w = work(followStartedAt = null)
        assertFalse(w.isNewSinceFollow(item(firstSeenAt = 9_999L)))
    }

    @Test
    fun `firstSeenAt 缺失时不算`() {
        val w = work(followStartedAt = 1_000L)
        assertFalse(w.isNewSinceFollow(item(firstSeenAt = null)))
    }

    // ==================================================================
    // 第 2 条：「看过没有」= 两条记录取或
    // ==================================================================

    @Test
    fun `从没播过 —— 两条都空才是新集`() {
        val w = work(followStartedAt = 1_000L)
        assertTrue(
            w.isNewSinceFollow(
                item(firstSeenAt = 1_001L, maxPositionMs = null, lastPlayedAt = null),
            ),
        )
    }

    @Test
    fun `进度有值 —— 看过，不是新集`() {
        val w = work(followStartedAt = 1_000L)
        assertFalse(
            w.isNewSinceFollow(item(firstSeenAt = 1_001L, maxPositionMs = 600_000L)),
        )
    }

    @Test
    fun `只有已读回执 —— 也算看过（本次修复的核心）`() {
        val w = work(followStartedAt = 1_000L)
        assertFalse(
            "点开看一眼就关窗时，max_position_ms 可能压根没被写过" +
                "（进度落库要 duration > 0），但 markPlayed 一定写了 last_played_at。" +
                "少了这一条，用户点过的集永远挂着 NEW，而他清不掉。",
            w.isNewSinceFollow(
                item(firstSeenAt = 1_001L, maxPositionMs = null, lastPlayedAt = 1_500L),
            ),
        )
    }

    @Test
    fun `两条都有 —— 当然也不是新集`() {
        val w = work(followStartedAt = 1_000L)
        assertFalse(
            w.isNewSinceFollow(
                item(firstSeenAt = 1_001L, maxPositionMs = 600_000L, lastPlayedAt = 1_500L),
            ),
        )
    }

    @Test
    fun `续播点不算数 —— 看完会被清成 null，用它会让看完的集变回 NEW`() {
        val w = work(followStartedAt = 1_000L)
        assertTrue(
            "resume_position_ms 刻意不参与判据：看完的一集它会被清掉，" +
                "拿它当判据的话「看完的一集」会重新变成 NEW。",
            w.isNewSinceFollow(
                item(
                    firstSeenAt = 1_001L,
                    resumePositionMs = null,
                    maxPositionMs = null,
                    lastPlayedAt = null,
                ),
            ),
        )
    }

    // ==================================================================
    // 夹具
    // ==================================================================

    private fun work(followStartedAt: Long?) = Work(
        key = "shroudingtheheavens",
        kind = "episode",
        category = MediaCategoryNames.SERIES,
        title = "遮天",
        originalTitle = null,
        year = 2023,
        overview = null,
        posterUrl = null,
        posterFile = null,
        posterFaceX = null,
        rating = null,
        genres = emptyList(),
        source = "quark",
        itemCount = 0,
        totalBytes = 0L,
        seasonCount = 1,
        lastModifiedAt = null,
        firstSeenAt = null,
        lastPlayedAt = null,
        resumeFraction = null,
        followed = true,
        followStartedAt = followStartedAt,
    )

    private fun item(
        firstSeenAt: Long?,
        maxPositionMs: Long? = null,
        lastPlayedAt: Long? = null,
        resumePositionMs: Long? = null,
    ) = LibraryItem(
        id = "quark:fid",
        provider = "quark",
        fileId = "fid",
        dirId = "dir",
        name = "EP184.mkv",
        dirPath = "/动画/遮天/",
        groupKey = "shroudingtheheavens",
        kind = "episode",
        title = null,
        year = null,
        season = 1,
        episode = 184,
        episodeEnd = null,
        part = null,
        partLabel = null,
        container = "mkv",
        resolution = "1080p",
        sizeBytes = null,
        durationMs = null,
        resumePositionMs = resumePositionMs,
        maxPositionMs = maxPositionMs,
        lastPlayedAt = lastPlayedAt,
        thumbUrl = null,
        faceAnchorX = null,
        videoWidth = null,
        videoHeight = null,
        isSampleOrExtra = false,
        firstSeenAt = firstSeenAt,
    )
}
