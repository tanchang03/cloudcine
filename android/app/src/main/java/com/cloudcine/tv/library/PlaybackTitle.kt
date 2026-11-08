package com.cloudcine.tv.library

/**
 * 播放页控制栏第〇行（标题行）的文字口径 —— **唯一**生成处（纯函数，
 * 由 JVM 单测钉死，见 `app/src/test/.../PlaybackTitleTest.kt`）。
 *
 * 定稿要求（2026-11-08 用户）：播放/暂停时控制栏亮起，显示
 * 「媒体库的影片名 + 当前集数」；集数认不出来时退回**文件全名** ——
 * 同一部片的 1080p / 2160p 两个版本只靠文件名分得开，只显示媒体名
 * 会把版本信息抹掉。
 */
object PlaybackTitle {

    /**
     * 算标题行的文字。
     *
     * @param workTitle 刮削后的作品名（媒体库 `Work.title`）。**优先级最高**：
     *   本地文件名常是 `Dune.Part.Two.2160p.mkv` 这类脏字符串，媒体库的
     *   规范名可读性远胜它。没读库 / 没刮到时为 null。
     * @param item 当前正在播的那一条入库条目；没入库（对照路径直播）、
     *   库还没读到时为 null。
     * @param fileName 文件全名（含扩展名，来自 intent）。**总兜底**：
     *   上面两个名字全都拿不到时就是它。
     */
    fun label(workTitle: String?, item: LibraryItem?, fileName: String): String {
        val file = fileName.trim()
        // 媒体名：作品名优先，没刮到才退本地解析的片名（`LibraryItem.title`）。
        val media = workTitle?.trim()?.takeUnless { it.isEmpty() }
            ?: item?.title?.trim()?.takeUnless { it.isEmpty() }
        // ⛔ 集数认不出（电影 / 花絮 / 番外 / 没入库 / 媒体库还没读完）⇒
        //    文件全名；文件名不含媒体名时把媒体名补在最前面，帮用户对上号。
        val episode = item?.episode
        return when {
            item == null || episode == null ->
                if (media == null) file else decorate(file, media)
            // 荒腔走板到「连媒体名都是空的」不太可能，但文件名总还有 —— 兜住。
            media == null -> file
            else -> {
                // 同一文件跨两集的合并条目写「第 1-2 集」。
                val merged = item.episodeEnd?.takeIf { it > episode }
                val season = item.season?.takeIf { it >= 2 }
                buildString {
                    append(media)
                    append(" · ")
                    if (season != null) {
                        append('S').append(season).append(" · ")
                    }
                    append("第 ").append(episode)
                    if (merged != null) append('-').append(merged)
                    append(" 集")
                }
            }
        }
    }

    /**
     * 文件名不含媒体名时，把媒体名补在最前面；含得话原样保留，别重复。
     * 比较**忽略大小写**：`dune.2021.2160p.mkv` 对 "Dune" 也算含了。
     */
    private fun decorate(file: String, media: String): String =
        if (file.contains(media, ignoreCase = true)) file else "$media $file"
}
