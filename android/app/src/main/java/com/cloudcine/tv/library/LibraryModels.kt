package com.cloudcine.tv.library

/**
 * 媒体库的**只读视图模型**。
 *
 * ⛔ 只映射 UI 真的会用到的列。**不要**为了「完整」把 `media_works` 的 31 列
 * 全搬进来 —— 每多一列就多一处与 PC 端 schema 脱钩的风险，而真正需要
 * 完整列的场景（迁移、刮削）Android 端现在不做。
 *
 * 时间单位与库里一致：**Unix 秒**（不是毫秒）。展示前自己乘 1000。
 */
data class Work(
    val key: String,
    val kind: String,
    val category: String,
    val title: String,
    val originalTitle: String?,
    val year: Int?,
    val overview: String?,
    val posterUrl: String?,
    val posterFile: String?,
    val posterFaceX: Double?,
    val rating: Double?,
    val genres: List<String>,
    val source: String,
    val itemCount: Int,
    val totalBytes: Long,
    val seasonCount: Int,
    val lastModifiedAt: Long?,
    val firstSeenAt: Long?,
    val lastPlayedAt: Long?,
) {
    /**
     * 卡片副标题。
     *
     * 口径照 PC 端 `MediaWork.subtitleLine`：**只有 `seasonCount >= 2` 才画季数**
     * —— 电影和单季剧显示「1 季」是噪音。`itemCount` 同理只在剧集上画。
     */
    val subtitle: String
        get() {
            val parts = ArrayList<String>(4)
            if (category.isNotEmpty()) parts.add(category)
            if (year != null && year > 0) parts.add("$year")
            if (seasonCount >= 2) parts.add("$seasonCount 季")
            if (itemCount > 1 && kind == "episode") parts.add("$itemCount 集")
            if (parts.isEmpty() && itemCount > 1) parts.add("$itemCount 个文件")
            return parts.joinToString(" · ")
        }
}

/**
 * 媒体项（文件级）。
 *
 * ⛔ [id] 与 [fileId] 是两个东西：`id` 是 `provider:fileId` 拼出来的主键，
 * `fileId` 才是网盘 fid —— 起播要的是后者。
 */
data class LibraryItem(
    val id: String,
    val provider: String,
    val fileId: String,
    /**
     * 文件所在目录的 fid。
     *
     * ⛔ 起播时**必须**把它一起传给播放页 —— 播放页靠它扫同目录的外挂字幕。
     *    单个文件的 fid **推不出**父目录，网盘也没有「查父目录」的接口，
     *    所以这个值只能从库里带过去（PC 端是实时列目录时顺手记下的）。
     */
    val dirId: String,
    val name: String,
    val dirPath: String,
    val groupKey: String,
    val kind: String,
    val title: String?,
    val year: Int?,
    val season: Int?,
    val episode: Int?,
    val episodeEnd: Int?,
    val part: Int?,
    val partLabel: String?,
    val container: String,
    val resolution: String?,
    val sizeBytes: Long?,
    val durationMs: Long?,
    val resumePositionMs: Long?,
    val maxPositionMs: Long?,
    val lastPlayedAt: Long?,
    val thumbUrl: String?,
    val faceAnchorX: Double?,
    val videoWidth: Int?,
    val videoHeight: Int?,
) {
    /** 列表里那一行标题：优先作品给的标题，退回文件名。 */
    val displayTitle: String get() = title?.takeIf { it.isNotBlank() } ?: name

    /** `S01E03` 这种编号（有季/集号时才拼）。 */
    val episodeTag: String?
        get() {
            val s = season ?: return null
            val e = episode ?: return null
            val end = episodeEnd
            val ep = if (end != null && end > e) "E%02d-E%02d".format(e, end) else "E%02d".format(e)
            return "S%02d%s".format(s, ep)
        }
}
