package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 「选集 / 文件列表」每一行的口径 —— [EpisodeLabels] 就是播放页 OSD 的「选集」
 * 与作品简介页的文件列表**共同**用的那几个函数。
 *
 * ## 为什么这一组必须钉死
 *
 * 2026-10-07 用户原话：「文件列表应该重点凸显的是文件名，而不是全部都是媒体名，
 * 否则剧集列表都是媒体名，看起来体验非常不好」—— 当时简介页那一行写的是
 * `displayTitle`（优先返回**作品标题**），于是 12 集全叫「黑亚当」。
 *
 * 这类错误**一个都不会报错**，页面上也不缺东西 —— 只是每一行长得一样。
 * 所以规则钉在这里，而不是靠真机上拿眼睛看。
 */
class EpisodeLabelsTest {

    // ==================================================================
    // 主标题 = 文件名（去扩展名）
    // ==================================================================

    /** 只砍**最后一个**点：砍第一个点会砍成 `黑亚当`，那正是要避免的结果。 */
    @Test
    fun `文件名只砍最后一个点`() {
        val it = item(name = "黑亚当.2022.S01E03.1080p.WEB-DL.mkv")
        assertEquals("黑亚当.2022.S01E03.1080p.WEB-DL", EpisodeLabels.fileLabel(it))
    }

    /**
     * ⛔ 这一条是本次修复的核心：`title`（作品标题）**不能**参与。
     *
     * 库里 12 集全被归到同一部作品，`title` 都是「黑亚当」；主标题必须来自
     * 文件名，否则整列一模一样。
     */
    @Test
    fun `主标题取文件名而不是作品标题`() {
        val a = item(name = "黑亚当.2022.S01E03.1080p.mkv", title = "黑亚当")
        val b = item(name = "黑亚当.2022.S01E04.1080p.mkv", title = "黑亚当")
        assertEquals("黑亚当.2022.S01E03.1080p", EpisodeLabels.fileLabel(a))
        assertEquals("黑亚当.2022.S01E04.1080p", EpisodeLabels.fileLabel(b))
        // 两行必须长得不一样 —— 这就是「剧集列表都是媒体名」要修掉的东西。
        assertNotEquals(EpisodeLabels.fileLabel(a), EpisodeLabels.fileLabel(b))
        // 顺便钉住：`displayTitle` 正是那个会把整列印成同一句话的东西。
        assertEquals(a.displayTitle, b.displayTitle)
    }

    /** 同一部电影的多版本（`1080p` / `2160p`）也必须能分开。 */
    @Test
    fun `同片多版本靠文件名区分`() {
        val a = item(name = "流浪地球2.2023.1080p.mkv", title = "流浪地球2", year = 2023)
        val b = item(name = "流浪地球2.2023.2160p.mkv", title = "流浪地球2", year = 2023)
        assertEquals("流浪地球2.2023.1080p", EpisodeLabels.fileLabel(a))
        assertEquals("流浪地球2.2023.2160p", EpisodeLabels.fileLabel(b))
    }

    /** 没有点（`第01集`）：原样返回，不能抛也不能截成空串。 */
    @Test
    fun `没有扩展名时原样返回`() {
        assertEquals("第01集", EpisodeLabels.fileLabel(item(name = "第01集")))
        assertEquals("01.国语", EpisodeLabels.fileLabel(item(name = "01.国语.mp4")))
    }

    /**
     * 点在最前是**隐藏文件名**，不是扩展名 ⇒ 原样返回。
     *
     * 钉住 `dot <= 0` 这一支：写成 `dot < 0` 的话 `.gitignore` 会变成空串。
     */
    @Test
    fun `点在最前不当作扩展名`() {
        assertEquals(".gitignore", EpisodeLabels.fileLabel(item(name = ".gitignore")))
    }

    /**
     * 点后面超过 4 位就**不砍** —— 那是名字里本来就有的点。
     *
     * ⛔ 门槛从 5 改成 4 就是为了这一条：`Mr. Robot` 点后正好 5 位，
     *    门槛写 5 的话会被砍成 `Mr`。
     */
    @Test
    fun `点后超过四位不当作扩展名`() {
        assertEquals("Mr. Robot", EpisodeLabels.fileLabel(item(name = "Mr. Robot")))
        assertEquals("Mr. Robot S01E01", EpisodeLabels.fileLabel(item(name = "Mr. Robot S01E01.mkv")))
        // 4 位的真实扩展名照砍（`webm` / `m2ts`）。
        assertEquals("片段.1080p", EpisodeLabels.fileLabel(item(name = "片段.1080p.webm")))
        assertEquals("片段.1080p", EpisodeLabels.fileLabel(item(name = "片段.1080p.m2ts")))
    }

    /** 光盘镜像（`.iso`）也在库里，一样要砍掉扩展名。 */
    @Test
    fun `光盘镜像去掉扩展名`() {
        assertEquals("演唱会.2019.BD", EpisodeLabels.fileLabel(item(name = "演唱会.2019.BD.iso")))
    }

    // ==================================================================
    // 副标题里的进度 = 历史最大位置
    // ==================================================================

    /** 没看过 ⇒ `null`（调用方连「看到 」都不写），不是 `0:00 / 45:00`。 */
    @Test
    fun `没有历史进度时返回空`() {
        assertNull(EpisodeLabels.progressLabel(item(name = "a.mkv")))
        assertNull(EpisodeLabels.progressLabel(item(name = "a.mkv", maxPositionMs = 0L, durationMs = 2_700_000L)))
        // ⛔ 时长未知（探测失败 / 刮削没给）时也给 `null`：分母没有，别硬凑。
        assertNull(EpisodeLabels.progressLabel(item(name = "a.mkv", maxPositionMs = 60_000L)))
        assertNull(EpisodeLabels.progressFraction(item(name = "a.mkv", maxPositionMs = 60_000L)))
    }

    /**
     * ⛔ 读的是 `max_position_ms`（看完**不清**），不是 `resume_position_ms`
     *   （看完清成 NULL）—— 这一条就是「看完的那一集显示成 0%」的防线。
     */
    @Test
    fun `看完的一集仍显示进度`() {
        val watched = item(
            name = "a.mkv",
            maxPositionMs = 2_700_000L,
            durationMs = 2_700_000L,
            resumePositionMs = null,
        )
        assertEquals("45:00 / 45:00", EpisodeLabels.progressLabel(watched))
        assertEquals(1.0, EpisodeLabels.progressFraction(watched)!!, 1e-9)
    }

    /** `02:03` / `1:02:03` —— 与 PC 端 `tvClockLabel` 同口径（小时位不补零）。 */
    @Test
    fun `进度的时钟格式`() {
        assertEquals("12:34 / 45:00", EpisodeLabels.progressLabel(item(name = "a.mkv", maxPositionMs = 754_000L, durationMs = 2_700_000L)))
        assertEquals(
            "1:02:03 / 2:00:00",
            EpisodeLabels.progressLabel(item(name = "a.mkv", maxPositionMs = 3_723_000L, durationMs = 7_200_000L)),
        )
    }

    /**
     * 越过总时长要**钳住** —— 片尾曲 / 时长是探测来的，不钳会出现
     * 「看到 50:00 / 45:00」这种一眼假的东西。
     */
    @Test
    fun `进度越过总时长时钳住`() {
        val over = item(name = "a.mkv", maxPositionMs = 3_000_000L, durationMs = 2_700_000L)
        assertEquals("45:00 / 45:00", EpisodeLabels.progressLabel(over))
        assertEquals(1.0, EpisodeLabels.progressFraction(over)!!, 1e-9)
    }

    // ==================================================================
    // 进度百分比（简介页文件列表那一列）
    // ==================================================================

    /** 四舍五入到整数百分比；`100%` 是「看完了」。 */
    @Test
    fun `进度百分比取整`() {
        assertEquals("62%", EpisodeLabels.progressPercent(item(name = "a.mkv", maxPositionMs = 1_674_000L, durationMs = 2_700_000L)))
        assertEquals("100%", EpisodeLabels.progressPercent(item(name = "a.mkv", maxPositionMs = 2_700_000L, durationMs = 2_700_000L)))
        assertEquals("50%", EpisodeLabels.progressPercent(item(name = "a.mkv", maxPositionMs = 1_350_000L, durationMs = 2_700_000L)))
    }

    /**
     * ⛔ 没看过 ⇒ `null`（界面上写 `—`），**不是** `0%`。
     *
     * `0%` 与 `—` 混在一起的话，「一帧都没看过」和「点开过一秒」长得一样。
     */
    @Test
    fun `没看过时不给百分比`() {
        assertNull(EpisodeLabels.progressPercent(item(name = "a.mkv")))
        assertNull(EpisodeLabels.progressPercent(item(name = "a.mkv", maxPositionMs = 0L, durationMs = 2_700_000L)))
    }

    /**
     * 看过一点点（四舍五入会变成 `0%`）要写成 `<1%`。
     *
     * ⛔ 写成 `0%` 就是把「看过」说成「没看过」—— 这一列是给人竖着扫的，
     *    扫出来的结论必须是准的。
     */
    @Test
    fun `看过一点点写成小于百分之一`() {
        val peeked = item(name = "a.mkv", maxPositionMs = 5_000L, durationMs = 2_700_000L)
        assertEquals("<1%", EpisodeLabels.progressPercent(peeked))
        // 与「没看过」必须**长得不一样**（这一条才是这个用例存在的理由）。
        assertNotEquals(EpisodeLabels.progressPercent(peeked), EpisodeLabels.progressPercent(item(name = "a.mkv")))
    }

    // ==================================================================

    /** 只填与 [EpisodeLabels] 有关的几列，其余给能过编译的最小值。 */
    private fun item(
        name: String,
        title: String? = null,
        year: Int? = null,
        maxPositionMs: Long? = null,
        durationMs: Long? = null,
        resumePositionMs: Long? = null,
    ) = LibraryItem(
        id = "quark:fid-1",
        provider = "quark",
        fileId = "fid-1",
        dirId = "dir-1",
        name = name,
        dirPath = "/来自：分享/黑亚当",
        groupKey = "quark:dir-1",
        kind = "episode",
        title = title,
        year = year,
        season = 1,
        episode = 3,
        episodeEnd = null,
        part = null,
        partLabel = null,
        container = "mkv",
        resolution = "1080p",
        sizeBytes = 1_200_000_000L,
        durationMs = durationMs,
        resumePositionMs = resumePositionMs,
        maxPositionMs = maxPositionMs,
        lastPlayedAt = null,
        thumbUrl = null,
        faceAnchorX = null,
        videoWidth = null,
        videoHeight = null,
        isSampleOrExtra = false,
    )
}
