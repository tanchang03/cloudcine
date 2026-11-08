package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 播放页控制栏第〇行（标题行）文字的口径钉子 —— 全部走 [PlaybackTitle.label]。
 *
 * ⛔ 口径改动必须过这里：退回链（媒体名没刮到 → 本地片名 → 文件全名）每一环
 *   都是用户体验层面看得见的，错一环「媒体名不显示」的排查就变成玄学。
 */
class PlaybackTitleTest {

    /** 标准剧集条目。 */
    private fun item(
        title: String? = null,
        season: Int? = null,
        episode: Int? = null,
        episodeEnd: Int? = null,
    ) = LibraryItem(
        id = "quark:fid-1",
        provider = "quark",
        fileId = "fid-1",
        dirId = "dir-1",
        name = "Dune.S02E08.2160p.mkv",
        dirPath = "/dune",
        groupKey = "quark:dir-1",
        kind = "episode",
        title = title,
        year = null,
        season = season,
        episode = episode,
        episodeEnd = episodeEnd,
        part = null,
        partLabel = null,
        container = "mkv",
        resolution = "2160p",
        sizeBytes = 1_200_000_000L,
        durationMs = null,
        resumePositionMs = null,
        maxPositionMs = null,
        lastPlayedAt = null,
        thumbUrl = null,
        faceAnchorX = null,
        videoWidth = null,
        videoHeight = null,
        isSampleOrExtra = false,
    )

    @Test
    fun `作品名 + 集`() {
        assertEquals(
            "沙丘 · 第 8 集",
            PlaybackTitle.label("沙丘", item(episode = 8), "Dune.S01E08.2160p.mkv"),
        )
    }

    @Test
    fun `第 2 季起带 S 前缀`() {
        assertEquals(
            "沙丘 · S2 · 第 8 集",
            PlaybackTitle.label("沙丘", item(season = 2, episode = 8), "e.mkv"),
        )
        assertEquals(
            "沙丘 · 第 3 集",
            PlaybackTitle.label("沙丘", item(season = 1, episode = 3), "e.mkv"),
        )
    }

    @Test
    fun `合并集写 第 N-M 集`() {
        assertEquals(
            "沙丘 · S2 · 第 5-6 集",
            PlaybackTitle.label("沙丘", item(season = 2, episode = 5, episodeEnd = 6), "e.mkv"),
        )
    }

    @Test
    fun `没刮到作品名时用条目本地片名`() {
        assertEquals(
            "本地解析名 · 第 4 集",
            PlaybackTitle.label(null, item(title = "本地解析名", episode = 4), "e.mkv"),
        )
    }

    @Test
    fun `集数认不出时退文件全名`() {
        // 条目在但 episode 为空（电影 / 花絮解析不出）
        assertEquals(
            "沙丘 Dune.2160p.mkv",
            PlaybackTitle.label("沙丘", item(episode = null), "Dune.2160p.mkv"),
        )
        // 没入库（对照路径直播间 / 库还没读完）
        assertEquals(
            "Dune.2160p.mkv",
            PlaybackTitle.label(null, null, "Dune.2160p.mkv"),
        )
    }

    @Test
    fun `文件名已含媒体名时不重复补`() {
        // 大小写不同的「Dune」也算含了 —— 原样保留，不重复补「Dune DUNE...」。
        assertEquals(
            "DUNE.2021.2160p.mkv",
            PlaybackTitle.label("Dune", item(episode = null), "DUNE.2021.2160p.mkv"),
        )
    }

    @Test
    fun `文件名正是媒体名时不重复`() {
        assertEquals(
            "沙丘.mkv",
            PlaybackTitle.label("沙丘", null, "沙丘.mkv"),
        )
    }

    @Test
    fun `全空兜底成空串`() {
        assertEquals("", PlaybackTitle.label(null, null, "  "))
        assertEquals("", PlaybackTitle.label(" ", item(episode = null), ""))
    }

    @Test
    fun `作品名空白串和不刮到同义`() {
        assertEquals(
            "本地名 · 第 2 集",
            PlaybackTitle.label("   ", item(title = "本地名", episode = 2), "e.mkv"),
        )
    }
}
