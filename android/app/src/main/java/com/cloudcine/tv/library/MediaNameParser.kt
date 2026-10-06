package com.cloudcine.tv.library

/**
 * 从文件名里解析出「片名 / 年份 / 季集 / 分部 / 技术标记」——
 * 移植 PC 端 `lib/core/utils/filename_parser.dart` 的**点分风格**那一支。
 *
 * ## 为什么必须照抄而不是「写个大概」
 *
 * 解析结果直接决定 `group_key`，而 `group_key` 决定**哪些文件被归成同一部作品**。
 * 差一个字符就会把一部剧拆成两部（或把两部并成一部），而这件事
 * **不会报错**：用户看到的是「媒体库里多了一部只有一集的剧」，很难联想到
 * 是文件名解析的问题。
 *
 * ## 移植范围
 *
 * 只移植**扫描期需要**的部分：片名 / 年份 / 季集 / 分部 / 容器 / 分辨率 /
 * 来源 / 编码 / 音轨 / 标记 / 花絮判定。**没有**移植：
 *   * `_parseBracketed`（`[组名][片名][01][1080p]` 那种动漫命名）——
 *     它对 `group_key` 的影响可以通过目录级归组覆盖，收益小于风险；
 *   * `cjkTitle` / `latinTitle` 拆分 —— 那两个字段**库里没有列**
 *     （见 `LibrarySchema.mediaItems`），PC 端只用它们拼刮削查询词。
 *
 * ## ⛔ 一条最容易踩的边界：`E6` 不是集号
 *
 * `格力空调显示E6如何维修.mp4` 里的 `E6` 是**故障代码**。若 `EP?(\d+)` 的前置
 * 守卫只排除 `[0-9a-z]`，紧跟在汉字后面的 `E6` 就会通过守卫 —— 片名被截断、
 * 集号记成 6。家电 / 汽车 / 医疗教程里 `E1`~`E9` 是成表的，会成片误判
 * （PC 端 2026-10-02 的真实事故）。所以守卫必须**连汉字一起排除**。
 */
object MediaNameParser {

    /** 解析结果。字段名与 `media_items` 的列一一对应。 */
    data class Parsed(
        val rawName: String,
        /** `movie` / `episode` / `unknown` —— 存库的就是这三个字符串。 */
        val kind: String,
        val title: String?,
        val year: Int?,
        val season: Int?,
        val episode: Int?,
        val episodeEnd: Int?,
        val part: Int?,
        val partLabel: String?,
        val resolution: String?,
        val source: String?,
        val videoCodec: String?,
        val audioCodec: String?,
        val flags: List<String>,
        val releaseGroup: String?,
        val isSampleOrExtra: Boolean,
        val isDiscImage: Boolean,
    ) {

        /**
         * 作品分组键 —— 与 PC 端 `ParsedMediaName.groupKey` **逐字同口径**。
         *
         * ⛔ 剧集**不含年份**：`S01` 与 `S02` 要落在同一部剧下，年份只作为
         *    「同名不同版」的区分（`2012` 有 2009 与 2024 两版）。
         */
        val groupKey: String
            get() {
                val t = (title ?: VideoFormats.baseName(rawName)).lowercase()
                val cleaned = t.replace(Regex("[^a-z0-9\\u4e00-\\u9fff]"), "")
                val yearPart = year?.let { "#$it" } ?: ""
                return if (kind == "episode") cleaned else "$cleaned$yearPart"
            }

        /**
         * 这个片名**能不能当作品名用**。
         *
         * ⛔ `a.mkv` 不该建出一部叫「a」的作品。判据是「含至少一个字母或汉字」，
         *    纯数字 / 纯符号的片名一律不算。
         */
        val hasUsableTitle: Boolean
            get() {
                val t = title?.trim()
                if (t.isNullOrEmpty()) return false
                return Regex("[a-z\\u4e00-\\u9fff]", RegexOption.IGNORE_CASE).containsMatchIn(t)
            }
    }

    // ------------------------------------------------------------------
    // 技术标记
    // ------------------------------------------------------------------

    /**
     * 技术标记的起点正则。
     *
     * 顺序无所谓 —— 取的是**所有匹配里位置最小的那个**。每个正则都用
     * `(?<![0-9a-z])` / `(?![0-9a-z])` 卡边界，避免把 `Se7en`、片名里的
     * `1080`、`Web` 误当标记。
     */
    private val MARKER_PATTERNS: List<Regex> = listOf(
        Regex("(?<![0-9])(?:19\\d{2}|20\\d{2})(?![0-9])"),
        Regex("(?<![0-9a-z])\\d{3,4}[pi](?![0-9a-z])", RegexOption.IGNORE_CASE),
        Regex("(?<![0-9a-z])[248]k(?![0-9a-z])", RegexOption.IGNORE_CASE),
        Regex("(?<![0-9a-z])\\d{3,4}\\s*[x×]\\s*\\d{3,4}(?![0-9a-z])", RegexOption.IGNORE_CASE),
        Regex("(?<![0-9a-z])s\\d{1,2}\\s*e\\d{1,3}(?![0-9a-z])", RegexOption.IGNORE_CASE),
        Regex("(?<![0-9a-z])\\d{1,2}x\\d{2,3}(?![0-9a-z])"),
        // ⛔ 守卫必须连汉字一起排除（见类文档里 `E6` 的事故）。
        Regex("(?<![0-9a-z\\u4e00-\\u9fff])e(?:p)?\\d{1,3}(?![0-9a-z])", RegexOption.IGNORE_CASE),
        Regex("第\\s*\\d{1,4}\\s*[集话話]"),
        Regex("(?<![0-9a-z])s\\d{1,2}(?![0-9a-z])", RegexOption.IGNORE_CASE),
        Regex("season\\s*\\d{1,2}", RegexOption.IGNORE_CASE),
        Regex("第\\s*[一二三四五六七八九十\\d]{1,3}\\s*季"),
        Regex("第\\s*[一二三四五六七八九十\\d]{1,3}\\s*[部篇]"),
        Regex("特别篇|特別篇|剧场版|劇場版"),
        Regex("上部|下部|前篇|后篇|後篇"),
        Regex(
            "(?<![0-9a-z])(?:blu-?ray|bluray|bd-?remux|remux|bd-?rip|br-?rip|bd|" +
                "web-?dl|webdl|web-?rip|web|hdtv|hd-?rip|dvd-?rip|dvd|uhd|hddvd|" +
                "tv-?rip|hdtc|cam|ts)(?![0-9a-z])",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            "(?<![0-9a-z])(?:x264|x265|h\\.?264|h\\.?265|hevc|avc|av1|vp9|xvid|" +
                "divx|mpeg-?2|mpeg-?4|10bit|8bit|hi10p)(?![0-9a-z])",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            "(?<![0-9a-z])(?:dts-?hd|dts-?x|dts|truehd|atmos|eac3|ac3|ddp|dd\\+|" +
                "aac|flac|opus|mp3|lpcm|pcm|dd5\\.?1|5\\.1|7\\.1)(?![0-9a-z])",
            RegexOption.IGNORE_CASE,
        ),
        Regex(
            "(?<![0-9a-z])(?:hdr10\\+|hdr10|hdr|dolby\\s?vision|dovi|dv|sdr|3d|" +
                "hsbs|imax|remastered|extended|uncut|repack|proper|complete|multi|" +
                "dual)(?![0-9a-z])",
            RegexOption.IGNORE_CASE,
        ),
    )

    private val YEAR_RE = Regex("(?<![0-9])(19\\d{2}|20\\d{2})(?![0-9])")
    private val DATE_TAIL_RE = Regex("^\\s*[-_.]\\s*\\d{1,2}\\s*[-_.]\\s*\\d{1,2}(?![0-9])")
    private val PURE_NUMBER_RE = Regex("^\\d+$")
    private val CJK_DIGITS = mapOf(
        '一' to 1, '二' to 2, '三' to 3, '四' to 4, '五' to 5,
        '六' to 6, '七' to 7, '八' to 8, '九' to 9,
    )

    // ------------------------------------------------------------------
    // 入口
    // ------------------------------------------------------------------

    /**
     * 解析一个文件名。
     *
     * [dirPath] 是**完整目录路径**（`/动漫/进击的巨人/S01/`）。给了它就会做
     * 目录级归组 —— 见下面第二段。
     */
    fun parse(fileName: String, dirPath: String? = null): Parsed {
        val base = VideoFormats.baseName(fileName)
        val isSample = VideoFormats.isSampleOrExtra(base)
        val isDisc = VideoFormats.isDiscImage(fileName)

        val cleaned = stripSiteTags(base)
        val markerStart = markerStartOf(cleaned)
        val rawTitle = when {
            markerStart < 0 -> cleaned
            markerStart <= 0 -> ""
            else -> cleaned.substring(0, markerStart)
        }
        var title = cleanTitle(rawTitle)
        var year = pickYear(cleaned, markerStart)
        val tv = matchEpisode(cleaned.lowercase())
        val resolution = VideoFormats.resolutionFromName(cleaned)
        var kind = when {
            tv != null -> "episode"
            !title.isNullOrEmpty() -> "movie"
            else -> "unknown"
        }
        val lower = cleaned.lowercase()

        // ── 目录级归组 ──────────────────────────────────────────────
        //
        // 「同目录多视频 → 作为系列整体归类，不作为独立电影存在」（用户定的口径）。
        // ⛔ 但**只在文件名自己说不清楚时**才用目录名顶掉它：`天龙八部…S01E01.1997…`
        //    这种自带年份或季集结构的，用目录名去顶只会把 S01E01 抹掉。
        // ⛔ 目录名与片名是同一个名字时也不顶：那个目录只是「这部作品的发行
        //    文件夹」，不是「装着许多集的容器」—— 顶掉它会把电影改成剧集。
        var season = tv?.season
        var episode = tv?.episode
        var episodeEnd = tv?.episodeEnd
        if (!dirPath.isNullOrEmpty()) {
            val series = DirectoryTitle.seriesTitleOf(dirPath)
            if (series != null &&
                !isStandaloneRelease(kind, title, year) &&
                normalizeName(title) != normalizeName(series)
            ) {
                title = series
                year = year ?: pickYear(series, -1)
                kind = "episode"
                // 季集号来自**单个文件**，归组后它不再代表「这部剧的第几集」，
                // 而且 `E6` 这类故障代码正是从这里混进来的。
                season = null
                episode = null
                episodeEnd = null
            }
        }

        val part = partOf(lower)
        return Parsed(
            rawName = fileName,
            kind = kind,
            title = title,
            year = year,
            season = season,
            episode = episode,
            episodeEnd = episodeEnd,
            part = part.first,
            partLabel = part.second,
            resolution = resolution,
            source = sourceOf(lower),
            videoCodec = videoCodecOf(lower),
            audioCodec = audioCodecOf(lower),
            flags = flagsOf(lower),
            releaseGroup = releaseGroupOf(base),
            isSampleOrExtra = isSample,
            isDiscImage = isDisc,
        )
    }

    // ------------------------------------------------------------------
    // 片名清洗
    // ------------------------------------------------------------------

    /** 去掉裸网址与「含域名特征的括号组」（`[www.xxx.com]`）。 */
    private fun stripSiteTags(input: String): String {
        var s = input
        s = s.replace(Regex("https?://\\S+", RegexOption.IGNORE_CASE), " ")
        s = s.replace(Regex("www\\.[\\w-]+\\.[a-z]{2,}", RegexOption.IGNORE_CASE), " ")
        val domainLike = Regex(
            "[\\w-]+\\.(?:com|net|org|cc|tv|me|io|cn|xyz|top|info|biz|pw|la|us)",
            RegexOption.IGNORE_CASE,
        )
        s = Regex("\\[[^\\]]*\\]|【[^】]*】|\\([^)]*\\)").replace(s) { m ->
            if (domainLike.containsMatchIn(m.value)) " " else m.value
        }
        return s
    }

    private fun markerStartOf(cleaned: String): Int {
        var start = -1
        for (p in MARKER_PATTERNS) {
            val m = p.find(cleaned) ?: continue
            if (start < 0 || m.range.first < start) start = m.range.first
        }
        return start
    }

    private fun cleanTitle(raw: String): String? {
        var s = raw
        // 分隔符统一成空格；`-` 保留（`Spider-Man` 是片名的一部分）。
        s = s.replace(Regex("[._]+"), " ")
        s = s.replace(Regex("[\\[(（【]\\s*[\\])）】]"), " ")
        // 只有开括号、没有配对闭括号的尾巴（发布组常这么写）。
        s = s.replace(Regex("[\\[(（【][^\\])）】]*$"), " ")
        s = s.replace(Regex("^[\\s\\-–—\\[(（【]+"), "")
        s = s.replace(Regex("[\\s\\-–—\\])）】]+$"), "")
        s = s.replace(Regex("\\s{2,}"), " ").trim()
        return if (s.isEmpty()) null else s
    }

    private fun normalizeName(s: String?): String =
        (s ?: "").lowercase().replace(Regex("[^a-z0-9\\u4e00-\\u9fff]"), "")

    // ------------------------------------------------------------------
    // 年份 / 季集 / 分部
    // ------------------------------------------------------------------

    /**
     * 挑年份。
     *
     * ⛔ 只认**标记区里**的年份（`markerStart` 之后）。片名区里的四位数是片名
     *    的一部分：`2012.2009.1080p.mkv` 是「片名 2012、年份 2009」，
     *    取错就会得到「2012 年的《2012》」。
     * ⛔ 还要排掉 `2024-09-27` 这种**日期**：综艺的命名里它极常见，而它出现在
     *    片名区，被当成上映年份会让整季综艺归到「2024 年」。
     */
    private fun pickYear(cleaned: String, markerStart: Int): Int? {
        for (m in YEAR_RE.findAll(cleaned)) {
            val start = m.range.first
            if (isDatePart(cleaned, start)) continue
            if (markerStart < 0 || start >= markerStart) return m.value.toInt()
        }
        return null
    }

    /** 这个位置的年份是不是「`2024-09-27` 这种完整日期」的头一段？ */
    private fun isDatePart(cleaned: String, start: Int): Boolean {
        val after = cleaned.substring(start + 4)
        return DATE_TAIL_RE.containsMatchIn(after)
    }

    private data class Tv(val season: Int?, val episode: Int?, val episodeEnd: Int?)

    private fun matchEpisode(lower: String): Tv? {
        // S01E02 / s1e2 / S01E02E03 / S01E02-E05
        Regex("s(\\d{1,2})\\s*e(\\d{1,3})(?:\\s*[-~]\\s*e?(\\d{1,3}))?").find(lower)?.let { m ->
            val season = m.groupValues[1].toIntOrNull()
            val episode = m.groupValues[2].toIntOrNull()
            var end = m.groupValues[3].toIntOrNull()
            if (end == null) {
                // `S01E02E03` —— 没有连字符的连集写法
                val more = Regex("e(\\d{1,3})(?=\\s*e\\d{1,3})").findAll(lower)
                    .mapNotNull { it.groupValues[1].toIntOrNull() }.toList()
                if (more.isNotEmpty()) end = (more + listOfNotNull(episode)).maxOrNull()
            }
            return Tv(season, episode, end)
        }
        // 1x02 / 01x02
        Regex("(?<![0-9a-z])(\\d{1,2})x(\\d{2,3})(?![0-9a-z])").find(lower)?.let { m ->
            return Tv(m.groupValues[1].toIntOrNull(), m.groupValues[2].toIntOrNull(), null)
        }
        // 第01集 / 第1-3集
        Regex("第\\s*(\\d{1,4})\\s*(?:[-~至]\\s*(\\d{1,4})\\s*)?[集话話]").find(lower)?.let { m ->
            return Tv(null, m.groupValues[1].toIntOrNull(), m.groupValues[2].toIntOrNull())
        }
        // EP01 / E06（守卫连汉字一起排除）
        Regex("(?<![0-9a-z\\u4e00-\\u9fff])ep?(\\d{1,3})(?![0-9a-z])").find(lower)?.let { m ->
            return Tv(null, m.groupValues[1].toIntOrNull(), null)
        }
        // 只有季号：S02 / Season 2（整季包）
        Regex("(?<![0-9a-z])s(\\d{1,2})(?![0-9a-z])").find(lower)?.let { m ->
            return Tv(m.groupValues[1].toIntOrNull(), null, null)
        }
        Regex("season\\s*(\\d{1,2})").find(lower)?.let { m ->
            return Tv(m.groupValues[1].toIntOrNull(), null, null)
        }
        Regex("第\\s*([一二三四五六七八九十\\d]{1,3})\\s*季").find(lower)?.let { m ->
            return Tv(chineseToInt(m.groupValues[1]), null, null)
        }
        return null
    }

    private fun chineseToInt(s: String): Int? {
        s.toIntOrNull()?.let { return it }
        // 只处理个位与「十 / 十几 / 几十」这几种真实会出现的形态。
        if (s == "十") return 10
        if (s.startsWith("十")) return 10 + (CJK_DIGITS[s.getOrNull(1)] ?: return null)
        if (s.endsWith("十")) return (CJK_DIGITS[s[0]] ?: return null) * 10
        val idx = s.indexOf('十')
        if (idx > 0) {
            val tens = CJK_DIGITS[s[0]] ?: return null
            val ones = CJK_DIGITS[s.getOrNull(idx + 1)] ?: return null
            return tens * 10 + ones
        }
        return CJK_DIGITS[s.getOrNull(0)]
    }

    /** 分部（`第X部` / `特别篇` / `上部` / `CD1`）。返回 `(序号, 标签)`。 */
    private fun partOf(lower: String): Pair<Int?, String?> {
        if (Regex("特别篇|特別篇|剧场版|劇場版").containsMatchIn(lower)) {
            return null to "特别篇"
        }
        Regex("第\\s*([一二三四五六七八九十\\d]{1,3})\\s*[部篇]").find(lower)?.let { m ->
            val n = chineseToInt(m.groupValues[1])
            return n to "第${m.groupValues[1]}部"
        }
        if (Regex("上部|前篇").containsMatchIn(lower)) return 1 to "上部"
        if (Regex("下部|后篇|後篇").containsMatchIn(lower)) return 2 to "下部"
        Regex("(?<![0-9a-z])(?:cd|disc|disk|part|dvd)[\\s._-]*(\\d{1,2})(?![0-9a-z])")
            .find(lower)?.let { m ->
                return m.groupValues[1].toIntOrNull() to null
            }
        return null to null
    }

    // ------------------------------------------------------------------
    // 技术标记的值
    // ------------------------------------------------------------------

    private val SOURCE_TABLE = linkedMapOf(
        "bdremux" to "BluRay", "bluray" to "BluRay", "blu-ray" to "BluRay",
        "remux" to "Remux", "bdrip" to "BDRip", "brrip" to "BRRip",
        "webdl" to "WEB-DL", "web-dl" to "WEB-DL", "webrip" to "WEBRip",
        "web-rip" to "WEBRip", "web" to "WEB", "hdtv" to "HDTV", "hdrip" to "HDRip",
        "dvdrip" to "DVDRip", "dvd" to "DVD", "uhd" to "UHD", "hddvd" to "HDDVD",
        "tvrip" to "TVRip", "hdtc" to "HDTC", "cam" to "CAM",
    )

    private fun sourceOf(lower: String): String? {
        for ((k, v) in SOURCE_TABLE) {
            if (Regex("(?<![0-9a-z])${Regex.escape(k)}(?![0-9a-z])").containsMatchIn(lower)) {
                return v
            }
        }
        if (Regex("(?<![0-9a-z])bd(?![0-9a-z])").containsMatchIn(lower)) return "BluRay"
        return null
    }

    private fun videoCodecOf(lower: String): String? {
        fun hit(p: String) = Regex("(?<![0-9a-z])$p(?![0-9a-z])").containsMatchIn(lower)
        return when {
            hit("x265") || hit("h\\.?265") || hit("hevc") -> "H.265"
            hit("x264") || hit("h\\.?264") || hit("avc") -> "H.264"
            hit("av1") -> "AV1"
            hit("vp9") -> "VP9"
            hit("xvid") -> "Xvid"
            hit("divx") -> "DivX"
            hit("mpeg-?2") -> "MPEG-2"
            else -> null
        }
    }

    private fun audioCodecOf(lower: String): String? {
        fun hit(p: String) = Regex("(?<![0-9a-z])$p(?![a-z])").containsMatchIn(lower)
        return when {
            hit("dts-?hd") -> "DTS-HD"
            hit("dts-?x") -> "DTS:X"
            hit("dts") -> "DTS"
            hit("truehd") -> "TrueHD"
            hit("atmos") -> "Atmos"
            hit("eac3") -> "EAC3"
            hit("ac3") -> "AC3"
            hit("dd[p+]?") -> "DDP"
            hit("aac") -> "AAC"
            hit("flac") -> "FLAC"
            hit("opus") -> "Opus"
            hit("mp3") -> "MP3"
            hit("lpcm") -> "LPCM"
            else -> null
        }
    }

    private fun flagsOf(lower: String): List<String> {
        val out = LinkedHashSet<String>()
        when {
            lower.contains("hdr10+") -> out.add("HDR10+")
            Regex("(?<![0-9a-z])hdr10(?![0-9a-z])").containsMatchIn(lower) -> out.add("HDR10")
            Regex("(?<![0-9a-z])hdr(?![0-9a-z])").containsMatchIn(lower) -> out.add("HDR")
        }
        if (Regex("dolby\\s?vision").containsMatchIn(lower) ||
            Regex("(?<![0-9a-z])(?:dovi|dv)(?![0-9a-z])").containsMatchIn(lower)
        ) {
            out.add("杜比视界")
        }
        if (Regex("(?<![0-9a-z])3d(?![0-9a-z])").containsMatchIn(lower)) out.add("3D")
        if (Regex("(?<![0-9a-z])imax(?![0-9a-z])").containsMatchIn(lower)) out.add("IMAX")
        if (lower.contains("remux")) out.add("Remux")
        if (Regex("(?<![0-9a-z])extended(?![0-9a-z])").containsMatchIn(lower)) out.add("加长版")
        if (Regex("(?<![0-9a-z])uncut(?![0-9a-z])").containsMatchIn(lower)) out.add("未删减")
        if (lower.contains("remastered")) out.add("重制版")
        if (Regex("10bit|hi10p").containsMatchIn(lower)) out.add("10bit")
        if (Regex("(?<![0-9a-z])repack(?![0-9a-z])").containsMatchIn(lower)) out.add("Repack")
        if (Regex("(?<![0-9a-z])proper(?![0-9a-z])").containsMatchIn(lower)) out.add("Proper")
        if (Regex("(?<![0-9a-z])complete(?![0-9a-z])").containsMatchIn(lower)) out.add("全集")
        return out.toList()
    }

    private fun releaseGroupOf(base: String): String? {
        val m = Regex("-([A-Za-z0-9][A-Za-z0-9._]{1,20})$").find(base) ?: return null
        val g = m.groupValues[1]
        if (PURE_NUMBER_RE.matches(g)) return null
        // 纯技术标记（`-x264`）不是发布组名。
        val lower = g.lowercase()
        if (SOURCE_TABLE.keys.any { lower.startsWith(it) }) return null
        if (Regex("^(x264|x265|h26[45]|hevc|av1|vp9|aac|ac3|dts|flac|10bit|hdr.*)$").matches(lower)) {
            return null
        }
        return g
    }

    /**
     * 这个文件名是否**自称一份独立发行物** —— 是的话目录名不许顶掉它。
     *
     * 两条都要满足：片名是「真名字」（含字母或汉字，纯数字要有年份），
     * 并且**自带年份或季集结构**。
     */
    private fun isStandaloneRelease(kind: String, title: String?, year: Int?): Boolean {
        val t = title?.trim()
        if (t.isNullOrEmpty()) return false
        if (!Regex("[a-z\\u4e00-\\u9fff]", RegexOption.IGNORE_CASE).containsMatchIn(t)) return false
        // 纯数字片名（`2012`）：只有自带年份时才当它是真名字。
        if (PURE_NUMBER_RE.matches(t) && year == null) return false
        return year != null || kind == "episode"
    }
}
