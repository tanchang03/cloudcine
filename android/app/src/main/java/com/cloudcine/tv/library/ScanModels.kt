package com.cloudcine.tv.library

/**
 * 扫描期用的两个**写入模型**。
 *
 * ## 为什么不复用 [LibraryItem] / [Work]
 *
 * 那两个是**只读视图模型**（从库里读出来、给界面用），它们带着一堆
 * 「只有读的时候才有意义」的东西：`resumePositionMs`、`maxPositionMs`、
 * `durationMs`、`rating`、`genres`、`resumeFraction` …
 *
 * 而扫描要写的是**另一组列**：它写「文件事实」（大小 / 修改时间 / 容器 /
 * 分辨率 / 编码 / 花絮标记），**一个字都不碰**播放进度与刮削结果
 * （理由见 [LibraryDb.applyScanItems]）。
 *
 * 混用一个类的话，「扫描会不会覆盖我的播放进度」这个问题就没法从类型上看出来
 * 了 —— 只能靠人去读那条 SQL。分开之后，**没写就是没写**。
 */

/**
 * 一个待入库的视频文件。
 *
 * 字段与 `media_items` 的列一一对应，单位也照库里的口径：
 * 时间一律 **Unix 秒**（不是毫秒）。
 */
data class ScanItem(
    /** 主键，`provider:fileId`。 */
    val id: String,
    val provider: String,
    val fileId: String,
    val name: String,
    /**
     * 文件所在目录的 fid。
     *
     * ⛔ 起播时**必须**把它一起传给播放页 —— 播放页靠它扫同目录的外挂字幕。
     *    单个文件的 fid 推不出父目录，所以只能列目录时顺手记下来。
     */
    val dirId: String,
    /** 完整目录路径，**带尾斜杠**（`/动漫/进击的巨人/S01/`；根是 `/`）。 */
    val dirPath: String,
    /** 作品分组键，来自 [MediaNameParser.Parsed.groupKey]。 */
    val groupKey: String,
    /** `movie` / `episode` / `unknown`。 */
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
    /** 网盘修改时间，**Unix 秒**（库里存的就是秒，别再乘 1000）。 */
    val modifiedAtSec: Long?,
    /** 时长（毫秒）。夸克 `duration` 下发的是秒，[LibraryScanner] 已经乘过 1000。 */
    val durationMs: Long?,
    /** 服务端读文件头得到的宽 / 高（比文件名里的 `2160p` 可靠）。 */
    val videoWidth: Int?,
    val videoHeight: Int?,
    val source: String?,
    val videoCodec: String?,
    val audioCodec: String?,
    val flags: List<String>,
    val releaseGroup: String?,
    /** 花絮 / 样片 / 预告。⛔ 入库，但起播前必须滤掉（见 [PlayTarget]）。 */
    val isSampleOrExtra: Boolean,
    /**
     * 网盘服务端缩略图（夸克 `preview_url`）。
     *
     * 它只是**没有在线刮削海报时的兜底** —— 真的海报由 PC 端刮削后随备份包
     * 搬过来，Android 端不下载海报（见 [PosterStore]）。
     */
    val thumbUrl: String?,
    /**
     * 竖版封面的裁切锚点（0~1，人物水平位置）。
     *
     * ⚠️ 目前**恒为 null**：夸克那个 `cover_face_boundary` 字段的解析器
     * （PC 端 `FaceAnchor.parseX`）还没移植过来。留着这个字段是为了
     * 「扫描 → 入库」这条链路的形状完整，将来补上解析器时只改一处。
     * 代价只是「用网盘缩略图当封面时按正中裁」而不是「按人物裁」。
     */
    val faceAnchorX: Double? = null,
) {
    companion object {
        /** `id` 的拼法。⛔ 与 PC 端 `MediaItem.id` 必须逐字一致。 */
        fun idOf(provider: String, fileId: String): String = "$provider:$fileId"
    }
}

/**
 * 一部待**补建**的作品行。
 *
 * ⛔ 只用于「库里还没有这一部」的情况。已有作品行**绝不覆盖**
 *    （上面挂着刮削结果与用户手改的分类）—— 见 [LibraryDb.insertMissingWorks]。
 */
data class ScanWork(
    val key: String,
    val provider: String,
    val kind: String,
    val category: String,
    val title: String,
    val year: Int?,
    /**
     * 封面兜底：分组里**第一条有缩略图**的文件的网盘预览图地址。
     *
     * ⛔ 它只是兜底，优先级低于在线刮削海报（PC 端 `WorkSeedBook.build` 里
     *    `scrapedPoster ?? seed.posterUrl`）。没有它的话，一部「只在 Android
     *    上扫过、还没刮削」的作品在墙上就是一块灰 —— 而夸克其实给了画面。
     */
    val posterUrl: String?,
    val itemCount: Int,
    val totalBytes: Long,
    val seasonCount: Int,
    val lastModifiedAt: Long?,
)
