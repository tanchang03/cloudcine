package com.cloudcine.tv.library

/**
 * 视频容器 / 分辨率 / 「花絮」判定 —— 移植 PC 端 `lib/core/utils/video_formats.dart`。
 *
 * ## 为什么这些规则必须逐字照抄 PC 端
 *
 * 扫描出来的 `container` / `resolution` 是**写进库里的值**，而库是两端共享的。
 * 这里放宽一点（比如多认一个扩展名），Android 扫出来的库就与 PC 扫出来的不同 ——
 * 用户会看到「同一批文件，在电视上扫一遍之后容器列变了」，而这种差异
 * **不会报错**，只会让「按容器筛」这类功能悄悄对不上。
 */
object VideoFormats {

    /** 扩展名 → 展示用的容器名（存库的就是这些**枚举名**，不是 label）。 */
    private val BY_EXTENSION: Map<String, String> = mapOf(
        "mp4" to "mp4", "m4v" to "mp4", "mp4v" to "mp4", "3gp" to "mp4", "3g2" to "mp4",
        "mkv" to "matroska", "mk3d" to "matroska",
        "webm" to "webm",
        "avi" to "avi", "divx" to "avi",
        "mov" to "quicktime", "qt" to "quicktime",
        "wmv" to "asf", "asf" to "asf",
        "flv" to "flash", "f4v" to "flash",
        "ts" to "mpegTs", "m2ts" to "mpegTs", "mts" to "mpegTs", "tp" to "mpegTs",
        "mpg" to "mpegPs", "mpeg" to "mpegPs", "m2v" to "mpegPs",
        "vob" to "vob",
        "rmvb" to "realMedia", "rm" to "realMedia",
        "ogv" to "ogg", "ogm" to "ogg",
        "iso" to "other", "mxf" to "other",
    )

    val extensions: Set<String> get() = BY_EXTENSION.keys

    /** 取扩展名（小写、不含点）。`null` = 没有扩展名或点在开头/结尾。 */
    fun extensionOf(fileName: String): String? {
        val dot = fileName.lastIndexOf('.')
        if (dot <= 0 || dot == fileName.length - 1) return null
        return fileName.substring(dot + 1).lowercase()
    }

    fun isVideoFile(fileName: String): Boolean =
        extensionOf(fileName)?.let { BY_EXTENSION.containsKey(it) } ?: false

    /** 存进 `media_items.container` 的**枚举名**。认不出回 `other`。 */
    fun containerOf(fileName: String): String =
        extensionOf(fileName)?.let { BY_EXTENSION[it] } ?: "other"

    fun isDiscImage(fileName: String): Boolean {
        val ext = extensionOf(fileName) ?: return false
        return ext == "iso" || ext == "img"
    }

    // ------------------------------------------------------------------
    // 分辨率
    // ------------------------------------------------------------------

    /** 短边 → 档位。`null` = 认不出（小于 360 也算认不出）。 */
    private val SHORT_AXIS = listOf(480 to "sd480", 720 to "hd720", 1080 to "fhd1080",
        1440 to "qhd1440", 2160 to "uhd2160", 4320 to "uhd4320")

    private val LONG_AXIS = listOf(854 to "sd480", 1280 to "hd720", 1920 to "fhd1080",
        2560 to "qhd1440", 3840 to "uhd2160", 7680 to "uhd4320")

    private fun byShortAxis(pixels: Int?): String? {
        if (pixels == null || pixels < 360) return null
        var best: String? = null
        for ((h, name) in SHORT_AXIS) if (h <= pixels) best = name
        return best
    }

    private fun byLongSide(longSide: Int?): String? {
        if (longSide == null) return null
        var best: String? = null
        for ((w, name) in LONG_AXIS) if (w <= longSide) best = name
        return best
    }

    private val DIM = Regex("(\\d{3,4})\\s*[x×]\\s*(\\d{3,4})")
    private val SCAN = Regex("(?<!\\d)(\\d{3,4})\\s*[pi](?!\\w)")
    private val MARKETING = Regex("(?<![a-z0-9])([248])\\s*k(?![a-z0-9])")

    /**
     * 从文件名猜分辨率。
     *
     * ⛔ 三条判据的**顺序**不能换（照抄 PC 端）：先看 `1920x1080` 这种真实尺寸，
     *    再看 `1080p`，最后才看营销词 `4K`。反过来的话 `2160p` 会被 `4K`
     *    抢先命中 —— 结果一样，但 `1080p` 与 `1920x1080` 并存时就会取错。
     */
    fun resolutionFromName(fileName: String): String? {
        val lower = fileName.lowercase()

        DIM.find(lower)?.let { m ->
            val a = m.groupValues[1].toIntOrNull()
            val b = m.groupValues[2].toIntOrNull()
            val short = if (a == null || b == null) (a ?: b) else minOf(a, b)
            byShortAxis(short)?.let { return it }
        }
        SCAN.find(lower)?.let { m ->
            byShortAxis(m.groupValues[1].toIntOrNull())?.let { return it }
        }
        MARKETING.find(lower)?.let { m ->
            return when (m.groupValues[1]) {
                "8" -> "uhd4320"
                "4" -> "uhd2160"
                else -> "qhd1440"
            }
        }
        return null
    }

    /** 档位高低的名次（下标即名次，与 `SHORT_AXIS` 的声明顺序一致）。 */
    private val RANK: Map<String, Int> =
        SHORT_AXIS.mapIndexed { i, p -> p.second to i }.toMap()

    /**
     * 从**实测尺寸**猜分辨率（夸克 `video_width` / `video_height`）。
     *
     * ⛔ 必须长边、短边各算一次再取**较高**的那一档，不能只用一边：
     *   * 只用长边 —— 宽银幕正确（`3840x1632` 的 4K 片），但漏掉 4:3 老内容；
     *   * 只用短边（高度）—— 实测样本里宽银幕裁切占 40%，会把 `3840x1632`
     *     的 4K 片标成 1440P，进而让「多版本排序」把 4K 版排到后面。
     *
     * 这个口径**与文件名解析相反**（那边保守、宁可标低）：尺寸是服务端读文件头
     * 得到的，可信；文件名里的数字是发布组自己写的，可能有水分。
     *
     * ⚠️ 只给了一边时，把它当档位数字读（`1080` 就是 1080P）。实战里夸克两边
     * 都给（实测 427/427），这条只是兜底。
     */
    fun resolutionFromDimensions(width: Int?, height: Int?): String? {
        val w = width?.takeIf { it > 0 }
        val h = height?.takeIf { it > 0 }
        if (w == null && h == null) return null
        if (w == null || h == null) return byShortAxis(w ?: h)

        val byLong = byLongSide(maxOf(w, h))
        val byShort = byShortAxis(minOf(w, h))
        if (byLong == null) return byShort
        if (byShort == null) return byLong
        return if ((RANK[byLong] ?: 0) >= (RANK[byShort] ?: 0)) byLong else byShort
    }

    // ------------------------------------------------------------------
    // 花絮 / 样片 / 预告
    // ------------------------------------------------------------------

    private val EXTRA_MARKERS = listOf(
        "sample", "trailer", "preview", "teaser", "screener-sample", "proof",
        "featurette", "deleted.scenes", "behind.the.scenes", "interview",
        "片花", "预告", "花絮", "样片", "彩蛋",
    )

    private val CJK = Regex("[\\u4e00-\\u9fff]")
    private val NON_WORD = Regex("[^a-z0-9\\u4e00-\\u9fff]+")

    /**
     * 是不是花絮 / 样片 / 预告。
     *
     * ⛔ 判据必须**按词**而不是 `contains`：`sample` 不加边界会命中
     *    `Samples.Of.Sound`，`proof` 会命中 `Waterproof` —— 而误判的后果是
     *    **这个文件从播放候选里消失**（`PlayTarget` 会先滤掉花絮），症状是
     *    「点了海报没反应」，极难反查到判定这一层。
     */
    fun isSampleOrExtra(fileName: String): Boolean {
        val base = baseName(fileName).lowercase()
        val tokens = base.split(NON_WORD).filter { it.isNotEmpty() }
        for (marker in EXTRA_MARKERS) {
            if (CJK.containsMatchIn(marker)) {
                // 中文没有词间空格，直接 contains（与 PC 端同口径）。
                if (base.contains(marker)) return true
            } else if (markerHits(tokens, marker)) {
                return true
            }
        }
        return false
    }

    private fun markerHits(tokens: List<String>, marker: String): Boolean {
        val parts = marker.split(Regex("[^a-z0-9]+")).filter { it.isNotEmpty() }
        if (parts.isEmpty()) return false
        for (i in 0..(tokens.size - parts.size)) {
            var hit = true
            for (j in parts.indices) {
                if (tokens[i + j] != parts[j]) {
                    hit = false
                    break
                }
            }
            if (hit) return true
        }
        return false
    }

    fun baseName(fileName: String): String {
        val dot = fileName.lastIndexOf('.')
        return if (dot <= 0) fileName else fileName.substring(0, dot)
    }
}
