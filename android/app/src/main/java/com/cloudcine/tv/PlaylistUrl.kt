package com.cloudcine.tv

/**
 * 判断一个地址是**播放列表**（HLS 的 `.m3u8` / DASH 的 `.mpd`）还是**媒体文件本身**。
 *
 * ## 为什么这件小事值得单独一个文件
 *
 * 磁盘缓存与预取器的键是 `quark:<fid>:<档位>`，它成立的**前提**是
 * 「一个媒体 = 一条字节流」—— 原画/整文件直链确实如此，从头到尾一个 URL。
 *
 * 而**转码档不是**：2026-10-06 真机实测，夸克 4K 档给的是
 * `https://video-play-h-zb.drive.quark.cn/…/media.m3u8`，
 * 一个媒体变成「**一个播放列表 + N 个分片**」，每个 URL 都是**独立的字节流**。
 * 共用一个缓存键的后果是：预取器把播放列表的 125 KiB 文本写进了这个键，
 * 播放器取分片时命中缓存、拿到的是 m3u8 文本，于是
 * `TsExtractor` 报 `Cannot find sync byte. Most likely not a Transport Stream`。
 * 现象看起来像「片源坏了」，其实是我们自己把两条流串成了一条。
 *
 * ⇒ 判据必须**便宜、无 Android 依赖、可单测**（`android.net.Uri` 在 JVM 单测里
 *   是空壳，所以这里只做字符串处理）。
 */
object PlaylistUrl {

    /**
     * @param url 完整地址（可带 query / fragment）。
     * @return true = 这是播放列表，**不能**按「一个媒体一条流」去缓存。
     */
    fun isPlaylist(url: String): Boolean {
        // ⛔ 先切掉 `?query` 与 `#fragment`：夸克直链带签名，
        //    后缀判断必须落在**路径**上，不能落在整串的结尾。
        val path = url.substringBefore('?').substringBefore('#')
        val last = path.substringAfterLast('/')
        if (last.isEmpty()) return false
        val ext = last.lowercase()
        return ext.endsWith(".m3u8") || ext.endsWith(".mpd")
    }
}
