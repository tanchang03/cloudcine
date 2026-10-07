package com.cloudcine.tv

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.text.Cue
import androidx.media3.common.util.Consumer
import androidx.media3.extractor.text.CuesWithTiming
import androidx.media3.extractor.text.SubtitleParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Ignore
import org.junit.Test
import java.nio.charset.Charset

/**
 * [ExternalSubtitle] 的单测。
 *
 * ## ⛔ 这里测的是**我们自己的那一段**，不是 Media3 的解析器
 *
 * Media3 1.5.1 的 `SubripParser` / `SsaParser` / `WebvttParser` 造出来的是
 * **`Spanned` 富文本**（`SubripParser.buildCue` 的入参类型就是
 * `android.text.Spanned`），一路依赖 `SpannableStringBuilder` / `SpannableString` /
 * `StyleSpan` / `ForegroundColorSpan` / `SparseArray` 一整套 Android 框架类。
 * 而 JVM 单测跑的是 AGP 生成的 `mockable-android-*.jar`（空壳，方法一律返回
 * 默认值），在它上面跑真解析器只有两种结局：
 *
 *   * **死循环** —— `WebvttParser` 里 `while (!TextUtils.isEmpty(readLine()))`，
 *     空壳 `isEmpty` 恒 `false` ⇒ 永远转下去（见
 *     `src/test/java/android/text/TextUtils.java` 的完整复盘）；
 *   * **NPE** —— `Cue` 构造器要求「`text` 为 `null` 时 `bitmap` 必须非 `null`」，
 *     空壳造出来的 `text` 正是 `null`。
 *
 * 要真跑真解析器得上 Robolectric（工程明确不引，见 `app/build.gradle.kts`）
 * 或真机仪器化测试。所以这里改成**注入假解析器**，把 `ExternalSubtitle` 真正
 * 拥有的那几段逻辑钉死 —— 它们恰好全是「写错了不报错、只是行为不对」的类型：
 *
 * 1. **编码**（[ExternalSubtitle.toUtf8]，本文件的重点）—— media3 只认 UTF-8。
 *    中文 `.srt` 大量是 GBK，喂错了得到满屏 `锟斤拷` 而**不抛异常**，
 *    看起来像「字体缺字」。
 * 2. **时间轴顺序** —— `cuesAt` 用二分，前提是升序。解析器不保证输出有序
 *    （ASS 的 Dialogue 行可以乱序），排错的表现是「字幕偶尔跳回前几句」。
 * 3. **cue 时长缺失** —— `durationUs` 可能是 `C.TIME_UNSET`。直接
 *    `start + duration` 得到一个天文数字，于是这条字幕**永远不消失**。
 *
 * 真解析器的行为由 [真解析器在 JVM 上跑不了] 记录（`@Ignore`），交给真机回归。
 *
 * 另外 [ExternalSubtitle.normalize] 是「自动识别同目录字幕」的唯一判据，
 * 它丢掉哪些词直接决定「能不能配上」—— 用真实世界的文件名当用例。
 */
class ExternalSubtitleTest {

    // ── 编码：GBK / BOM ──────────────────────────────────────────

    /**
     * ⛔ 本文件的**头号用例**。media3 只认 UTF-8，GBK 必须由 `toUtf8` 先转过来。
     *
     * 断言的是「**交到解析器手上的字节**」，不是假解析器回放出来的文本 ——
     * 后者是自证。所以假解析器会把收到的字节按 UTF-8 解回文本再变成一条 cue，
     * 一路走到 `cuesAt`。`toUtf8` 不转的话这里拿到的是 `锟斤拷` 那一串。
     */
    @Test
    fun `GBK 编码的中文 SRT 会被转成 UTF-8 再交给解析器`() {
        val zh = "我们要夺回那座城"
        val gbk = zh.toByteArray(Charset.forName("GB18030"))
        // 前提：GB18030 的字节不是合法 UTF-8 —— 否则这个用例什么都没验到。
        assertNotEquals(zh, String(gbk, Charsets.UTF_8))

        val fake = FakeFactory()
        val sub = ExternalSubtitle.parse("中文字幕.srt", gbk, fake)

        assertEquals(zh, fake.receivedText())
        assertEquals(zh, textAt(sub, 500L))
    }

    /** 合法 UTF-8 **不能**被当成 GBK 再转一遍（转了就成乱码）。 */
    @Test
    fun `合法 UTF-8 会原样透传`() {
        val zh = "第一行\n第二行"
        val fake = FakeFactory()
        ExternalSubtitle.parse("a.srt", zh.toByteArray(Charsets.UTF_8), fake)
        assertEquals(zh, fake.receivedText())
    }

    @Test
    fun `带 UTF-8 BOM 的 SRT 不会把 BOM 当成正文`() {
        val body = "1\n00:00:01,000 --> 00:00:03,000\nHello world\n"
        val bytes = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) +
            body.toByteArray(Charsets.UTF_8)
        val fake = FakeFactory()
        ExternalSubtitle.parse("bom.srt", bytes, fake)
        // BOM 三个字节被切掉，正文一字不差。
        assertEquals(body, fake.receivedText())
    }

    /** UTF-16 的两种 BOM 也要认（`FF FE` = LE、`FE FF` = BE）。 */
    @Test
    fun `UTF-16 的两种 BOM 都能转成 UTF-8`() {
        val zh = "我们要夺回那座城"
        val le = byteArrayOf(0xFF.toByte(), 0xFE.toByte()) +
            zh.toByteArray(Charsets.UTF_16LE)
        val be = byteArrayOf(0xFE.toByte(), 0xFF.toByte()) +
            zh.toByteArray(Charsets.UTF_16BE)

        val fakeLe = FakeFactory()
        ExternalSubtitle.parse("a.srt", le, fakeLe)
        assertEquals(zh, fakeLe.receivedText())

        val fakeBe = FakeFactory()
        ExternalSubtitle.parse("a.srt", be, fakeBe)
        assertEquals(zh, fakeBe.receivedText())
    }

    // ── 时间轴：排序 / 命中 / 间隙 ────────────────────────────────

    /** 基本命中与间隙：间隙必须是空的，否则字幕会一直挂在画面上。 */
    @Test
    fun `按时间命中且间隙为空`() {
        val sub = ExternalSubtitle.parse(
            "a.srt",
            "x".toByteArray(),
            FakeFactory.of(
                CueSpec(1_000_000, "Hello world", 2_000_000),
                CueSpec(4_000_000, "Second line", 2_500_000),
                CueSpec(10_000_000, "Third line", 2_000_000),
            ),
        )
        assertEquals(3, sub.cueCount)
        assertEquals("Hello world", textAt(sub, 2_000L))
        assertEquals("", textAt(sub, 3_500L))
        assertEquals("Second line", textAt(sub, 5_000L))
        assertEquals("", textAt(sub, 9_000L))
        assertEquals("Third line", textAt(sub, 11_000L))
        // 片头之前、片尾之后都不该有东西。
        assertEquals("", textAt(sub, 0L))
        assertEquals("", textAt(sub, 60_000L))
    }

    /**
     * ⛔ 解析器的输出顺序**不保证**按时间（ASS 的 Dialogue 行可以乱序），
     * 而 [ExternalSubtitle.cuesAt] 的二分前提是升序。
     *
     * 乱序喂进去，命中必须仍然对。不排序的话二分会在错的位置停下 ——
     * 表现是「字幕偶尔跳回前几句」，很难往「顺序」上想。
     */
    @Test
    fun `乱序喂进去也会先按时间排好再二分`() {
        val sub = ExternalSubtitle.parse(
            "a.ass",
            "x".toByteArray(),
            FakeFactory.of(
                CueSpec(10_000_000, "C", 1_000_000),
                CueSpec(1_000_000, "A", 1_000_000),
                CueSpec(5_000_000, "B", 1_000_000),
            ),
        )
        assertEquals("A", textAt(sub, 1_500L))
        assertEquals("B", textAt(sub, 5_500L))
        assertEquals("C", textAt(sub, 10_500L))
        // 覆盖率也说明排过序：最后一条的结束时间撑到了 `spanMs`。
        assertEquals(11_000L, sub.spanMs)
    }

    /** 重叠的 cue 要**一起**返回（ASS 的 `{\an8}` 注释行、拆成两条的句子）。 */
    @Test
    fun `重叠的 cue 会一起返回且按开始时间升序`() {
        val sub = ExternalSubtitle.parse(
            "a.ass",
            "x".toByteArray(),
            FakeFactory.of(
                CueSpec(1_000_000, "A", 9_000_000),
                CueSpec(4_000_000, "B", 2_000_000),
            ),
        )
        assertEquals("A|B", textAt(sub, 5_000L))
    }

    // ── 结束时间兜底（`endOf`）────────────────────────────────────

    /**
     * ⛔ `durationUs` 是 `C.TIME_UNSET`（负数）时，`start + duration` 会得到一个
     * 天文数字 ⇒ 这条字幕**永远不消失**。兜底口径是「下一条的开始时间」。
     */
    @Test
    fun `时长缺失时用下一条的开始时间收尾`() {
        val sub = ExternalSubtitle.parse(
            "a.srt",
            "x".toByteArray(),
            FakeFactory.of(
                CueSpec(1_000_000, "A", C.TIME_UNSET),
                CueSpec(5_000_000, "B", 1_000_000),
            ),
        )
        // 到下一条开始之前一直显示 A —— 而不是永远显示。
        assertEquals("A", textAt(sub, 4_999L))
        assertEquals("B", textAt(sub, 5_000L))
    }

    /** 时长**超过上限**（120 秒）的一律当脏数据，同样退回「下一条的开始时间」。 */
    @Test
    fun `离谱的时长会被当成脏数据丢掉`() {
        val sub = ExternalSubtitle.parse(
            "a.srt",
            "x".toByteArray(),
            FakeFactory.of(
                CueSpec(1_000_000, "A", 3_600_000_000L /* 1 小时 */),
                CueSpec(5_000_000, "B", 1_000_000),
            ),
        )
        assertEquals("A", textAt(sub, 4_999L))
        assertEquals("B", textAt(sub, 5_000L))
    }

    /** 最后一条拿不到时长时，给 8 秒（[ExternalSubtitle] 里的 `TAIL_CUE_US`）。 */
    @Test
    fun `最后一条的时长兜底是八秒`() {
        val sub = ExternalSubtitle.parse(
            "a.srt",
            "x".toByteArray(),
            FakeFactory.of(CueSpec(1_000_000, "A", C.TIME_UNSET)),
        )
        assertEquals("A", textAt(sub, 8_999L))
        assertEquals("", textAt(sub, 9_000L))
    }

    // ── 拒绝路径 ────────────────────────────────────────────────

    @Test(expected = IllegalArgumentException::class)
    fun `不支持的扩展名直接拒绝`() {
        ExternalSubtitle.parse("a.sub", "x".toByteArray(), FakeFactory())
    }

    /** ⛔ 格式认得出但**一条都没解出来**时要抛，不能返回一个空壳 ——
     *  空壳会让菜单里出现一条「选了没反应」的字幕。 */
    @Test(expected = IllegalStateException::class)
    fun `格式对但一条都没解出来时报错而不是返回空`() {
        ExternalSubtitle.parse("a.srt", "这不是字幕".toByteArray(Charsets.UTF_8), FakeFactory.of())
    }

    /** 工厂说这个 MIME 它不管（例如 media3 被裁掉了某个解析器）。 */
    @Test(expected = IllegalArgumentException::class)
    fun `工厂不支持这个格式时直接拒绝`() {
        ExternalSubtitle.parse("a.srt", "x".toByteArray(), FakeFactory(supported = false))
    }

    // ── 格式判定 ────────────────────────────────────────────────

    @Test
    fun `sub 不在支持范围内 —— 它会被解析器静默吞掉`() {
        assertTrue(ExternalSubtitle.isSupported("a.srt"))
        assertTrue(ExternalSubtitle.isSupported("A.SRT"))
        assertTrue(ExternalSubtitle.isSupported("a.ass"))
        assertTrue(ExternalSubtitle.isSupported("a.ssa"))
        assertTrue(ExternalSubtitle.isSupported("a.vtt"))
        assertTrue(ExternalSubtitle.isSupported("a.ttml"))
        // MicroDVD / SubViewer：media3 没有解析器，塞进去会「成功返回 0 条」。
        assertFalse(ExternalSubtitle.isSupported("a.sub"))
        assertFalse(ExternalSubtitle.isSupported("a.idx"))
        assertFalse(ExternalSubtitle.isSupported("a.sup"))
        assertFalse(ExternalSubtitle.isSupported("a.mp4"))
    }

    // ── 自动配对 ────────────────────────────────────────────────

    @Test
    fun `发行标签会被丢掉，同一部片的不同命名能配上`() {
        val video = ExternalSubtitle.normalize("Furiosa.2024.2160p.WEB-DL.DDP5.1.Atmos.HDR.mkv")
        assertEquals("furiosa2024", video)

        // 这四种是真实会同时出现在一个目录里的命名方式。
        assertEquals(video, ExternalSubtitle.normalize("Furiosa.2024.2160p.WEB-DL.srt"))
        assertEquals(video, ExternalSubtitle.normalize("Furiosa.2024.中英双语.srt"))
        assertEquals(video, ExternalSubtitle.normalize("Furiosa.2024.1080p.BluRay.x265.ass"))
        assertEquals(video, ExternalSubtitle.normalize("Furiosa 2024.chs&eng.vtt"))
    }

    /**
     * ⛔ 中文标签经常**连写**（`中英双语`），而标签表里只有拆开的形态
     * （`中英` / `双语`）。只做「整词相等」的话这一整段会被拼进主干 ⇒
     * **同一部片的字幕配不上，而且不报错**（表现是「自动挑不到字幕」）。
     */
    @Test
    fun `连写的中文标签整词也会被丢掉`() {
        assertEquals("furiosa2024", ExternalSubtitle.normalize("Furiosa.2024.中英双语.srt"))
        assertEquals("furiosa2024", ExternalSubtitle.normalize("Furiosa.2024.简繁字幕.ass"))
        // 但**不能被「包含」判据误伤**：`简爱` 只含标签词 `简` 的一个字，
        // 它是片名，丢掉它会让两部不同的片子归一化成同一个主干。
        assertEquals("简爱2011", ExternalSubtitle.normalize("简爱.2011.mkv"))
    }

    @Test
    fun `不同年份或不同片名不会被误配`() {
        val video = ExternalSubtitle.normalize("Furiosa.2024.2160p.mkv")
        assertFalse(video == ExternalSubtitle.normalize("Furiosa.2015.2160p.srt"))
        assertFalse(video == ExternalSubtitle.normalize("Dune.2024.2160p.srt"))
    }

    @Test
    fun `归一化后太短的主干不能作为配对依据`() {
        // `1080p.srt` 归一化后是空串 —— 它跟任何片子都不该被判成「配上」。
        assertEquals("", ExternalSubtitle.normalize("1080p.srt"))
        assertFalse(ExternalSubtitle.isMatchable(""))
        assertFalse(ExternalSubtitle.isMatchable("1"))
        assertTrue(ExternalSubtitle.isMatchable("furiosa2024"))
    }

    // ── 未覆盖的部分（写在这里，别让它悄悄消失）────────────────────

    /**
     * ⛔ 这一条**故意 `@Ignore`**：它要的是真解析器，而真解析器在 JVM 上跑不了
     * （理由见类文档）。留着它是为了三件事：
     *
     *   1. 「真 `.srt` / `.ass` / `.vtt` 能被解出条目」这件事**确实没人验**，
     *      别以为上面那些用例覆盖了它；
     *   2. 哪天工程引了 Robolectric，把 `@Ignore` 去掉就能直接跑；
     *   3. 真机回归时照着这段文本肉眼对一遍排版（`\N` 硬换行、`{\an8}` 定位）。
     */
    @Ignore("真解析器依赖 android.text.Spanned 等一整套框架类，JVM 单测跑不了；见类文档")
    @Test
    fun `真解析器在 JVM 上跑不了`() {
        val srt = "1\n00:00:01,000 --> 00:00:03,000\nHello world\n"
        val sub = ExternalSubtitle.parse("a.srt", srt.toByteArray(Charsets.UTF_8))
        assertEquals(1, sub.cueCount)
        assertEquals("Hello world", textAt(sub, 2_000L))
    }

    // ── 辅助 ────────────────────────────────────────────────────

    /** 把某一时刻的 cue 文字拼起来（多条时用 `|` 分隔），空则为空串。 */
    private fun textAt(sub: ExternalSubtitle, positionMs: Long): String =
        sub.cuesAt(positionMs).joinToString("|") { it.text?.toString().orEmpty() }
}

/** 一条预设 cue：开始时间（微秒）、文本、时长（微秒）。 */
private data class CueSpec(val startUs: Long, val text: String, val durationUs: Long)

/**
 * 假解析器工厂：**不碰任何 Android 类**，把预设的 cue 直接回放给
 * [ExternalSubtitle.parse]。
 *
 * 默认行为（[FakeFactory] 无参构造）是「把收到的字节按 UTF-8 解回文本，
 * 变成一条 0~1 秒的 cue」—— 这样断言「交到解析器手上的字节」时，
 * 结果会一路走到 `cuesAt`，而不是在假解析器里自证。
 *
 * ⛔ 生产代码**永远**走 `DefaultSubtitleParserFactory`（`parse` 的默认参数），
 * 这个类只存在于测试源集里。
 */
private class FakeFactory(
    private val supported: Boolean = true,
    private val script: (String) -> List<CueSpec> = { text ->
        listOf(CueSpec(0L, text, 1_000_000L))
    },
) : SubtitleParser.Factory {

    /** 解析器**实际收到**的字节。 */
    var receivedBytes: ByteArray? = null
        private set

    /** 把收到的字节按 UTF-8 解回文本 —— 用来验 [ExternalSubtitle.toUtf8]。 */
    fun receivedText(): String = String(receivedBytes ?: ByteArray(0), Charsets.UTF_8)

    override fun supportsFormat(format: Format): Boolean = supported

    // `ExternalSubtitle.parse` 不读这个值（它决定「新 cue 是否顶掉旧的」，是
    // ExoPlayer 内嵌字幕的语义），假解析器返回什么都可以。
    override fun getCueReplacementBehavior(format: Format): Int = 0

    override fun create(format: Format): SubtitleParser = object : SubtitleParser {
        override fun getCueReplacementBehavior(): Int = 0

        override fun parse(
            data: ByteArray,
            offset: Int,
            length: Int,
            outputOptions: SubtitleParser.OutputOptions,
            output: Consumer<CuesWithTiming>,
        ) {
            val bytes = data.copyOfRange(offset, offset + length)
            receivedBytes = bytes
            for (spec in script(String(bytes, Charsets.UTF_8))) {
                output.accept(
                    CuesWithTiming(
                        listOf(Cue.Builder().setText(spec.text).build()),
                        spec.startUs,
                        spec.durationUs,
                    ),
                )
            }
        }
    }

    companion object {
        /** 回放一组固定 cue（不关心收到的字节）。 */
        fun of(vararg cues: CueSpec): FakeFactory = FakeFactory { cues.toList() }
    }
}
