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
    /**
     * 该作品**看得最远的那一集**的进度，`0.0~1.0`；没有可续的进度时为 `null`。
     *
     * ⛔ 判据与「继续观看」一致（`LibraryDb.lastUnfinished`）：只看
     *    `resume_position_ms > 0` 且 `duration_ms > 0` 的项。看完的项 PC 端会把
     *    `resume_position_ms` 清成 NULL，所以这里**天然不会**出现 1.0 的进度条。
     * ⛔ 取的是 **max 而不是最近一集**：进度条表达的是「这部剧我看到哪了」，
     *    用户看完第 3 集、回头补第 1 集时，条子不该往回缩。
     * ⛔ 超过 1.0 要钳住 —— 时长是刮削/探测来的，片尾曲会让 position 越过 duration。
     */
    val resumeFraction: Double?,
) {
    /**
     * 卡片副标题。
     *
     * 口径照 PC 端 `MediaWork.subtitleLine`：
     *   1. **分类用中文标签**（`movie` ⇒ 「电影」），不是库里的枚举名；
     *   2. **只有 `seasonCount >= 2` 才画季数** —— 电影和单季剧显示「1 季」是噪音；
     *   3. `itemCount > 0` 就画，剧集写「N 集」、其它写「N 个文件」。
     *
     * ⚠️ 与 PC 端唯一的**有意偏离**：PC 把 `rating` 也接在这条尾巴上，
     *    而这里评分已经画在海报**右上角的角标**里了。同一条信息印两遍
     *    在电视上会显得卡片很吵，所以副标题不再重复它。
     */
    val subtitle: String
        get() {
            val parts = ArrayList<String>(4)
            parts.add(MediaCategoryNames.label(category))
            if (year != null && year > 0) parts.add("$year")
            if (seasonCount >= 2) parts.add("$seasonCount 季")
            if (itemCount > 0) {
                parts.add(if (kind == "episode") "$itemCount 集" else "$itemCount 个文件")
            }
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
    /**
     * 花絮 / 样片 / 预告。
     *
     * ⛔ 点作品卡片直接播放时**必须先滤掉它们**（见 [PlayTarget]）——
     *    否则用户点《流浪地球 2》会看到 40 秒的预告片。
     */
    val isSampleOrExtra: Boolean,
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
