package com.cloudcine.kuake.quark

/**
 * 网盘条目。
 *
 * ⛔ 判定目录**只认 `dir` 布尔位**，`file_type` 仅作兜底 ——
 * `file_type=0` 是目录、`1` 是文件，与直觉相反。云影早期把 `1` 当目录，
 * 结果是 BFS 队列爆炸。字段名也不统一：是 `fid` / `pdir_fid` / `file_name`，
 * 不是 `id` / `parent_id` / `name`。
 */
data class DriveEntry(
    val fid: String,
    val name: String,
    val isDir: Boolean,
    val sizeBytes: Long,
    val updatedAtMs: Long,
) {
    /** 只用来决定「点 OK 是进目录还是起播」。 */
    val isVideo: Boolean
        get() = !isDir && VIDEO_EXT.any { name.lowercase().endsWith(it) }

    val isSubtitle: Boolean
        get() = !isDir && SUB_EXT.any { name.lowercase().endsWith(it) }

    companion object {
        private val VIDEO_EXT = listOf(
            ".mp4", ".mkv", ".avi", ".mov", ".ts", ".m2ts", ".wmv",
            ".flv", ".webm", ".mpg", ".mpeg", ".rmvb", ".iso", ".m4v",
        )
        private val SUB_EXT = listOf(".srt", ".ass", ".ssa", ".vtt", ".sub")
    }
}

/**
 * 一个可播档位。
 *
 * 夸克给两类东西，**必须分清楚**：
 *   - `video_list[]` 是**转码档**（`play/info` 下发），体积小得多；
 *   - `/file/audioplay` 给的是**原文件本身**（[isOriginal]）。
 *
 * 以 `黑亚当 2160p` 为例（时长 7490s，实测）：
 *
 * | 档位 | 分辨率 | 体积 | **需要带宽** |
 * |---|---|---|---|
 * | 原画 | 3840×1606 | 21.9 GiB | **3.00 MB/s** |
 * | 4k | 3840×1606 | 4.6 GiB | **0.63 MB/s** |
 * | super | 1440×602 | 1.03 GiB | 0.14 MB/s |
 * | high | 960×402 | 678 MiB | 0.09 MB/s |
 *
 * 差 5 倍。**这就是「夸克流畅、云影卡」的全部秘密**（见 `docs/` 的对照记录）。
 */
data class Quality(
    val id: String,
    val label: String,
    val width: Int,
    val height: Int,
    val bitrateKbps: Int,
    val sizeBytes: Long,
    val url: String,
    val isOriginal: Boolean,
    val durationMs: Long,
) {
    /**
     * 这条流要「实时播」需要多少 MB/s。
     *
     * 判据是「体积 ÷ 时长」而不是声明码率 —— 后者单位在夸克这里是 kbps，
     * 且个别档位缺失（`4k` 档的 `bitrate` 字段就与体积对不上）。
     */
    val requiredMbPerSec: Double
        get() = if (durationMs <= 0) 0.0 else sizeBytes / 1048576.0 / (durationMs / 1000.0)

    /** 菜单里那一行副标题：`3840×1606 · 5.2 Mbps · 需 0.63 MB/s`。 */
    val detail: String
        get() {
            val parts = mutableListOf<String>()
            if (width > 0 && height > 0) parts.add("${width}×$height")
            if (bitrateKbps > 0) parts.add("%.1f Mbps".format(bitrateKbps / 1000.0))
            if (requiredMbPerSec > 0) parts.add("需 %.2f MB/s".format(requiredMbPerSec))
            return parts.joinToString(" · ")
        }
}

/** 一次起播需要的全部信息。 */
data class PlayInfo(
    val fileName: String,
    val durationMs: Long,
    /** 夸克自己认为该播哪一档（`default_resolution`）。 */
    val defaultQualityId: String,
    /** 原画在最前（若有），其余按分辨率降序。 */
    val qualities: List<Quality>,
) {
    fun qualityById(id: String?): Quality? =
        qualities.firstOrNull { it.id == id } ?: qualities.firstOrNull()

    /** 菜单里默认该选中的那一档。 */
    val defaultQuality: Quality?
        get() = qualityById(defaultQualityId)
}

/** 把「体积」写成 `21.9 GiB` / `678 MiB`。 */
fun formatSize(bytes: Long): String = when {
    bytes <= 0 -> "—"
    bytes >= 1L shl 30 -> "%.2f GiB".format(bytes / 1073741824.0)
    bytes >= 1L shl 20 -> "%.0f MiB".format(bytes / 1048576.0)
    bytes >= 1024 -> "%.0f KiB".format(bytes / 1024.0)
    else -> "$bytes B"
}
