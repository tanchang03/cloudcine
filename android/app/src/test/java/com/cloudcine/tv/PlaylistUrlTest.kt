package com.cloudcine.tv

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaylistUrl] 的判据单测。
 *
 * ## 为什么这一组是必测的
 *
 * 判错的症状**不是崩溃，是「播放失败：Source error」**，而栈里报的是
 * 「不是 TS」—— 看起来像片源坏了。真机上排查一次要十几分钟，
 * 所以这里把「哪些地址算播放列表」钉死。
 *
 * 真机实测的地址（2026-10-06，`179.mkv` 的 4K 档）：
 * `https://video-play-h-zb.drive.quark.cn/…/media.m3u8?auth_key=…`
 */
class PlaylistUrlTest {

    @Test
    fun `夸克转码档的 media_m3u8 算播放列表`() {
        assertTrue(
            PlaylistUrl.isPlaylist(
                "https://video-play-h-zb.drive.quark.cn/xxx/media.m3u8?auth_key=1-2-3-abc&t=123",
            ),
        )
    }

    @Test
    fun `后缀判断必须落在路径上 —— query 里出现 m3u8 不算`() {
        // ⛔ 夸克直链带签名。若拿整串结尾去判，`…/media.mp4?next=x.m3u8`
        //    会被误判成播放列表 ⇒ 整文件被按分片解 ⇒ 必然失败。
        assertFalse(
            PlaylistUrl.isPlaylist(
                "https://cdn.example.com/a/media.mp4?redirect=a/b.m3u8",
            ),
        )
    }

    @Test
    fun `fragment 也要切掉`() {
        assertFalse(PlaylistUrl.isPlaylist("https://cdn.example.com/a/movie.mkv#t=12.m3u8"))
        assertTrue(PlaylistUrl.isPlaylist("https://cdn.example.com/a/media.m3u8#seg1"))
    }

    @Test
    fun `原画直链不算播放列表`() {
        assertFalse(PlaylistUrl.isPlaylist("https://cdn.example.com/a/179.mkv?auth_key=zzz"))
        assertFalse(PlaylistUrl.isPlaylist("https://cdn.example.com/a/179.mp4"))
    }

    @Test
    fun `DASH 的 mpd 同样算播放列表`() {
        assertTrue(PlaylistUrl.isPlaylist("https://cdn.example.com/a/manifest.mpd"))
    }

    @Test
    fun `大小写不敏感`() {
        assertTrue(PlaylistUrl.isPlaylist("https://cdn.example.com/a/MEDIA.M3U8"))
    }

    @Test
    fun `没有文件名（以斜杠结尾或空）不算`() {
        assertFalse(PlaylistUrl.isPlaylist("https://cdn.example.com/"))
        assertFalse(PlaylistUrl.isPlaylist(""))
        assertFalse(PlaylistUrl.isPlaylist("m3u8"))
    }
}
