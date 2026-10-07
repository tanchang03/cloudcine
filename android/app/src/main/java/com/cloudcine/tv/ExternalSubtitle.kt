package com.cloudcine.tv

import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.text.Cue
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/**
 * **外挂字幕** —— 网盘上的一个 `.srt` / `.ass` / `.vtt` 文件，加载后按时序供 cue。
 *
 * ## 为什么不把字幕塞给 ExoPlayer（`SubtitleConfiguration` / `MergingMediaSource`）
 *
 * 两条路都能把外挂字幕弄上屏，但把字幕挂到 `MediaItem` 上意味着**重建 media
 * source**（`setMediaSource` 会重新 `prepare()`）。而本工程这条流不是普通 HTTP：
 * 它是 `ParallelRangeDataSource`（1 条 Range 拆 8 连接）+ 磁盘预取。
 * 重建一次 = 重新握手、重新分配 8 条连接、`DiskPrefetcher` 重新锚定 ——
 * 在一部 4K 片上就是一次实打实的重新缓冲。**换个字幕不该让画面卡一下。**
 *
 * 所以这里走「自己拉字节、自己解析、自己按时序喂 `SubtitleOverlayView`」：
 * 播放器**一个字节都不动**，切字幕是瞬时的，来回切也不会有任何副作用。
 *
 * ## 解析器是 media3 自带的，不是自己写的
 *
 * `media3-extractor`（`media3-exoplayer` 的传递依赖，**零新依赖**）里有
 * `DefaultSubtitleParserFactory` + `SubRipParser` / `SubStationAlphaParser` /
 * `WebVttParser` / `TtmlParser`。自己写 SRT 解析当然简单，但 ASS 的
 * `\N` 硬换行、`{\an8}` 定位、样式继承是另一个量级的工作量 ——
 * 而且自己写的那份**永远不会**和 ExoPlayer 的内嵌字幕表现一致，
 * 于是同一个片源切内嵌/外挂会看到两种排版。
 *
 * ## 编码：中文 `.srt` 大量是 GBK
 *
 * media3 的解析器**只认 UTF-8**（内部走 `Util.fromUtf8Bytes`）。中文外挂字幕
 * 里 GBK/GB18030 的占比很高，直接喂进去会得到满屏 `锟斤拷`，而且**不报错**。
 * 所以 [toUtf8] 先判 BOM、再拿严格 UTF-8 试一次，不合法才退回 GB18030 ——
 * 顺序不能反：GB18030 几乎能把任意字节序列解出「字」，先试它就没有回头路。
 */
class ExternalSubtitle private constructor(
    /** 原始文件名（含扩展名），菜单与日志都用它。 */
    val name: String,
    private val cues: List<CuesWithTiming>,
    /** 每条 cue 的**结束时间**（微秒），与 [cues] 同下标。见 [endOf]。 */
    private val ends: LongArray,
) {

    val cueCount: Int get() = cues.size

    /** 覆盖的时间跨度（毫秒），只进日志 —— 用来一眼看出「解析出来的是不是全片」。 */
    val spanMs: Long
        get() = if (cues.isEmpty()) 0L else (ends[ends.size - 1] / 1000L)

    /**
     * [positionMs] 这一刻该显示的 cue。
     *
     * ⛔ 用**二分**而不是线性扫：一部长片的外挂字幕有两三千条，而这里
     *    每 100ms 被问一次（见 `PlayerActivity.subtitleTick`）。线性扫在
     *    这台 4 核电视上是每秒几十万次比较，白白抢解码的 CPU。
     *
     * ⛔ 允许**多条同时命中**：ASS 的 `{\an8}` 注释行、以及压制组把一句话拆成
     *    两条 cue 是常见写法。只取「最后一条开始的」会丢行。
     */
    fun cuesAt(positionMs: Long): List<Cue> {
        if (cues.isEmpty()) return emptyList()
        val pos = positionMs * 1000L

        // 最后一条 startTime <= pos 的 cue。
        var lo = 0
        var hi = cues.size - 1
        var found = -1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            if (cues[mid].startTimeUs <= pos) {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if (found < 0) return emptyList()

        // 从它往回找仍然盖住 pos 的（重叠 / 多行）。上限两道：条数与回溯时长，
        // 都是为了让「某条 cue 的 duration 是天文数字」这种脏数据不至于把
        // 整个列表翻一遍。
        val hits = ArrayList<CuesWithTiming>(2)
        var i = found
        var steps = 0
        while (i >= 0 && steps < MAX_BACK_SCAN) {
            val c = cues[i]
            if (pos < ends[i]) hits.add(c)
            if (pos - c.startTimeUs > MAX_LOOKBACK_US) break
            i--
            steps++
        }
        hits.reverse()

        val out = ArrayList<Cue>(hits.size * 2)
        for (h in hits) out.addAll(h.cues)
        return out
    }

    companion object {

        /** 单条 cue 的时长上限（微秒）。超过它一律当脏数据，改用下一条的开始时间。 */
        private const val MAX_CUE_US = 120L * 1_000_000L

        /** 往回找重叠 cue 的最大回溯时长（微秒）。 */
        private const val MAX_LOOKBACK_US = 120L * 1_000_000L

        /** 往回找重叠 cue 的最大条数。 */
        private const val MAX_BACK_SCAN = 64

        /**
         * [isTagComposite] 只看这么长的词。
         *
         * 标签串现实里就 2~6 个字（`中英双语` / `简繁英`）。不设上限的话，
         * 一个长片名每个词都要跑一遍 O(n²) 完全切分 —— 结果是「更慢，且答案
         * 还是 false」（片名不可能整词由标签拼成）。
         */
        private const val MAX_TAG_COMPOSITE_LEN = 8

        /** 拿不到时长、又是最后一条时，给它撑多久（微秒）。 */
        private const val TAIL_CUE_US = 8L * 1_000_000L

        /**
         * 扩展名 → media3 认的 MIME。
         *
         * ⛔ `.sub` **故意不认**。它是 MicroDVD（`{0}{25}文字`）或 SubViewer
         *    （`00:00:01.00,00:00:04.00`）的容器，media3 没有对应解析器；
         *    硬塞给 SubRip 解析器会「成功返回 0 条」—— 表现为「选了字幕没反应」，
         *    比直接说「不支持」难查得多。见 [isSupported] 的用法。
         * ⛔ `.idx`/`.sup`（VobSub / PGS 图形字幕）同理：它们是位图，得配
         *    同名的 `.sub` 才有意义，本工程不处理。
         */
        fun mimeFor(fileName: String): String? {
            val n = fileName.lowercase()
            return when {
                n.endsWith(".srt") -> MimeTypes.APPLICATION_SUBRIP
                n.endsWith(".ass") || n.endsWith(".ssa") -> MimeTypes.TEXT_SSA
                n.endsWith(".vtt") || n.endsWith(".webvtt") -> MimeTypes.TEXT_VTT
                n.endsWith(".ttml") || n.endsWith(".dfxp") -> MimeTypes.APPLICATION_TTML
                else -> null
            }
        }

        /** 本工程解得开吗。**列目录时就用它筛**，别把选不了的文件摆进菜单。 */
        fun isSupported(fileName: String): Boolean = mimeFor(fileName) != null

        /**
         * 解析一份字幕字节。
         *
         * @param factory 解析器工厂。**生产调用一律不传**（用 Media3 的默认工厂）；
         *   它存在的唯一理由是单测要注入一个假工厂 —— 见下面的「⛔ 为什么单测
         *   必须能换掉解析器」。
         *
         * @throws IllegalArgumentException 格式不认识
         * @throws IllegalStateException 认得出格式但一条都没解出来
         *
         * ## ⛔ 为什么单测必须能换掉解析器
         *
         * Media3 1.5.1 的 `SubripParser` / `SsaParser` / `WebvttParser` 造出来的
         * 是 **`Spanned` 富文本**（`SubripParser.buildCue` 的入参类型就是
         * `android.text.Spanned`），一路依赖 `SpannableStringBuilder` /
         * `SpannableString` / `StyleSpan` / `ForegroundColorSpan` / `SparseArray`
         * 一整套 Android 框架类。而 JVM 单测跑的是 AGP 生成的
         * `mockable-android-*.jar`（空壳，方法一律返回默认值）——
         * 在它上面跑真解析器**只有两种结局**：死循环（`TextUtils.isEmpty` 恒
         * `false`，见 `src/test/java/android/text/TextUtils.java`）或者
         * `Cue` 构造器里的 `checkNotNull(bitmap)` 抛 NPE（`text` 是空壳造出来的
         * `null`）。要真跑得上 Robolectric（工程明确不引）或真机仪器化测试。
         *
         * 所以单测**只验我们自己写的那一段**：编码判定（BOM / GBK）、按
         * `startTimeUs` 排序、结束时间兜底（[endOf]）、[cuesAt] 的二分。
         * Media3 解析器本身的行为交给真机回归 —— 那也是唯一能真验的地方。
         */
        fun parse(
            name: String,
            raw: ByteArray,
            factory: SubtitleParser.Factory = DefaultSubtitleParserFactory(),
        ): ExternalSubtitle {
            val mime = mimeFor(name)
                ?: throw IllegalArgumentException("不支持的字幕格式：$name")

            val bytes = toUtf8(raw)
            val format = Format.Builder().setSampleMimeType(mime).build()
            if (!factory.supportsFormat(format)) {
                throw IllegalArgumentException("media3 里没有 $mime 的解析器")
            }

            val parsed = ArrayList<CuesWithTiming>()
            val parser: SubtitleParser = factory.create(format)
            // `allCues()` = 一次全给。字幕文件是**非流式**的，逐条回调没有意义，
            // 而且这里要的是「能随机查任意时刻」的完整时间轴。
            parser.parse(bytes, 0, bytes.size, SubtitleParser.OutputOptions.allCues()) { cwt ->
                if (cwt.cues.isNotEmpty()) parsed.add(cwt)
            }

            if (parsed.isEmpty()) {
                throw IllegalStateException(
                    "没解出任何字幕（可能是 MicroDVD/图形字幕，或文件损坏）",
                )
            }
            // ⛔ 必须排序：解析器的输出顺序**不保证**按时间（ASS 的 Dialogue 行
            //    可以乱序），而 cuesAt 的二分前提是升序。排错的表现是
            //    「字幕偶尔跳到前面几句」，很难往「顺序」上想。
            parsed.sortBy { it.startTimeUs }

            val ends = LongArray(parsed.size) { endOf(parsed, it) }
            return ExternalSubtitle(name, parsed, ends)
        }

        /**
         * 一条 cue 的结束时间（微秒）。
         *
         * ⛔ `durationUs` 可能是 `C.TIME_UNSET`（负数）或 0 —— 直接
         *    `start + duration` 会得到一个天文数字，于是这条字幕**永远不消失**。
         *    拿不到时长时退化成「下一条的开始时间」（最后一条给 [TAIL_CUE_US]），
         *    这也是 SRT 解析器内部的兜底口径。
         */
        private fun endOf(list: List<CuesWithTiming>, i: Int): Long {
            val c = list[i]
            val d = c.durationUs
            if (d > 0L && d < MAX_CUE_US) return c.startTimeUs + d
            return if (i + 1 < list.size) list[i + 1].startTimeUs else c.startTimeUs + TAIL_CUE_US
        }

        /**
         * 把任意编码的字幕字节转成 UTF-8。
         *
         * 判定顺序（**不能调换**）：
         *   1. BOM —— 有就照它解，这是最硬的证据；
         *   2. **严格** UTF-8 试解一次 —— 失败抛 [CharacterCodingException]；
         *   3. 退回 GB18030。
         *
         * ⛔ 别用 `String(bytes, UTF_8)` 试探：那个**从不报错**，非法字节被换成
         *    `\uFFFD`，于是任何 GBK 文件都会被判成「UTF-8」并留下满屏替换符。
         * ⛔ 别把 GB18030 放在前面：它几乎能解出任何字节序列，先试它就没有
         *    回头路了。
         */
        private fun toUtf8(raw: ByteArray): ByteArray {
            if (raw.size >= 3 &&
                raw[0] == 0xEF.toByte() && raw[1] == 0xBB.toByte() && raw[2] == 0xBF.toByte()
            ) {
                return raw.copyOfRange(3, raw.size)
            }
            if (raw.size >= 2 && raw[0] == 0xFF.toByte() && raw[1] == 0xFE.toByte()) {
                return String(raw, 2, raw.size - 2, Charsets.UTF_16LE).toByteArray(Charsets.UTF_8)
            }
            if (raw.size >= 2 && raw[0] == 0xFE.toByte() && raw[1] == 0xFF.toByte()) {
                return String(raw, 2, raw.size - 2, Charsets.UTF_16BE).toByteArray(Charsets.UTF_8)
            }

            val strict = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            return try {
                strict.decode(ByteBuffer.wrap(raw))
                raw
            } catch (_: CharacterCodingException) {
                String(raw, Charset.forName("GB18030")).toByteArray(Charsets.UTF_8)
            }
        }

        /**
         * 发行标签 —— 归一化时要丢掉的词。
         *
         * 这些是压制组命名里的「噪音」：`Furiosa.2024.2160p.WEB-DL.DDP5.1.Atmos.HDR.mkv`
         * 和 `Furiosa.2024.2160p.WEB-DL.srt` 是同一部片，但**文件名主干并不相等**。
         * 只做「去扩展名」的精确比较会漏掉绝大多数真实情况。
         *
         * ⚠️ 这张表是**启发式**，不是规范。它只影响「自动挑哪条」，挑错了用户
         *    在菜单里换一条即可 —— 所以宁可多丢几个词，也不要为了保真而漏配。
         */
        private val TAGS = setOf(
            // 分辨率 / 画质
            "480p", "576p", "720p", "1080p", "1440p", "2160p", "4320p",
            "4k", "8k", "uhd", "fhd", "hq",
            // 来源
            "web", "dl", "webdl", "webrip", "bluray", "blu", "ray", "bdrip", "brrip",
            "hdtv", "dvdrip", "hdrip", "remux", "tvrip", "hdtc",
            // 编码
            "x264", "x265", "h264", "h265", "avc", "hevc", "xvid", "divx", "av1", "vp9",
            "10bit", "8bit", "hi10p",
            // 音频
            "aac", "ac3", "eac3", "ddp", "dts", "dtshd", "dtsx", "truehd", "atmos",
            "flac", "mp3", "opus", "ddp5", "ddp7",
            // HDR
            "hdr", "hdr10", "hdr10plus", "dovi", "sdr", "hlg",
            // 版本
            "proper", "repack", "internal", "extended", "remastered", "imax",
            "uncut", "unrated", "limited", "complete",
            // 语言 / 字幕标记（中文场景大量出现）
            "chs", "cht", "chinese", "eng", "english", "jpn", "japanese", "kor", "korean",
            "简", "繁", "简繁", "简体", "繁体", "中英", "中字", "英字", "双语",
            "字幕", "字幕组", "sub", "subs", "subtitle", "subtitles", "forced", "sdh",
        )

        /**
         * 归一化文件名主干，用于「视频 ↔ 字幕」配对。
         *
         * 步骤：去扩展名 → 小写 → 按非字母数字切词 → 丢掉 [TAGS]、[isTagComposite]
         * 认出的标签串、以及纯数字短词（`DDP5.1` 会被切成 `ddp5` 和 `1`，
         * 后者是噪音）→ 拼起来。
         *
         * 例：`Furiosa.2024.2160p.WEB-DL.DDP5.1.Atmos.HDR.mkv` → `furiosa2024`
         */
        fun normalize(fileName: String): String {
            val base = fileName.substringBeforeLast('.', fileName)
            val sb = StringBuilder(base.length)
            for (t in base.lowercase().split(SEPARATORS)) {
                if (t.isEmpty()) continue
                if (t in TAGS) continue
                if (isTagComposite(t)) continue
                if (t.length <= 2 && t.all { it.isDigit() }) continue
                sb.append(t)
            }
            return sb.toString()
        }

        /**
         * 这个词能不能**整词**由 [TAGS] 里的词拼出来。
         *
         * ⛔ 必须有这一条：中文压制组的标签经常**连写**，而 [TAGS] 里只有拆开的
         *    形态 —— `Furiosa.2024.中英双语.srt` 切出来的词是 `中英双语`，
         *    它既不在 [TAGS]（那里只有 `中英` 和 `双语`），也不含数字，于是整段
         *    被拼进主干，得到 `furiosa2024中英双语` ≠ 视频的 `furiosa2024`
         *    ⇒ **同一部片的字幕配不上，而且不报错**（表现是「自动挑不到字幕」）。
         *
         * ⛔ 判据是**整词可切分**，不是「包含某个标签」：`中` 单字是标签词的一部分
         *    吗？`中国机长` 里含 `中`，用「包含」判会直接把片名丢掉 —— 那是比漏配
         *    更糟的错（两部不同的片子会被归一化成同一个主干）。
         *
         * 用最朴素的 O(n²) 完全切分，n 是词长（现实里 ≤ 8）：一次 `normalize`
         * 要跑几百个词，但每个词的 n² 都在常数级，实测无感。
         */
        private fun isTagComposite(token: String): Boolean {
            val n = token.length
            if (n < 2 || n > MAX_TAG_COMPOSITE_LEN) return false
            // `ok[i]` = 前 i 个字符能被 TAGS 完整切分。
            val ok = BooleanArray(n + 1)
            ok[0] = true
            for (i in 0 until n) {
                if (!ok[i]) continue
                for (j in i + 1..n) {
                    if (ok[j]) continue
                    if (token.substring(i, j) in TAGS) ok[j] = true
                }
            }
            return ok[n]
        }

        /**
         * 归一化后的主干是否够「有信息」。
         *
         * ⛔ 必须有这道闸：`1080p.srt` 这种文件归一化后是空串，而任何一部
         *    归一化后也为空串的片子（不可能，但要防）会被判成「配上了」。
         *    太短的主干（`1`、`a`）同样不能作为配对依据。
         */
        fun isMatchable(normalized: String): Boolean = normalized.length >= 3

        private val SEPARATORS = Regex("[^\\p{L}\\p{N}]+")
    }
}
