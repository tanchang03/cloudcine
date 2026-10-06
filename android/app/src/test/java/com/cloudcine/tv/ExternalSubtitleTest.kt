package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.Charset

/**
 * [ExternalSubtitle] 的单测。
 *
 * ## 为什么这一组值得测
 *
 * 外挂字幕这条链路上有三个**写错了不报错、只是行为不对**的点，而且都在
 * 真机上不好定位（硬件视频层下 `screencap` 全黑、`uiautomator dump` 也拿不到
 * 画面，只能靠肉眼看电视）：
 *
 * 1. **编码** —— media3 的解析器只认 UTF-8。中文 `.srt` 大量是 GBK，
 *    喂错了得到满屏 `锟斤拷` 而**不抛异常**，看起来像「字体缺字」。
 * 2. **时间轴顺序** —— `cuesAt` 用二分，前提是升序。解析器不保证输出有序
 *    （ASS 的 Dialogue 行可以乱序），排错的表现是「字幕偶尔跳回前几句」。
 * 3. **cue 时长缺失** —— `durationUs` 可能是 `C.TIME_UNSET`。直接
 *    `start + duration` 得到一个天文数字，于是这条字幕**永远不消失**。
 *
 * 另外 [ExternalSubtitle.normalize] 是「自动识别同目录字幕」的唯一判据，
 * 它丢掉哪些词直接决定「能不能配上」—— 用真实世界的文件名当用例。
 */
class ExternalSubtitleTest {

    // ── SRT ─────────────────────────────────────────────────────

    private val srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello world

        2
        00:00:04,000 --> 00:00:06,500
        Second line

        3
        00:00:10,000 --> 00:00:12,000
        Third line
    """.trimIndent()

    @Test
    fun `SRT 解析出全部条目并按时间命中`() {
        val sub = ExternalSubtitle.parse("a.srt", srt.toByteArray(Charsets.UTF_8))
        assertEquals(3, sub.cueCount)

        assertEquals("Hello world", textAt(sub, 2_000L))
        // 间隙必须是空的 —— 否则字幕会一直挂在画面上。
        assertEquals("", textAt(sub, 3_500L))
        assertEquals("Second line", textAt(sub, 5_000L))
        assertEquals("", textAt(sub, 9_000L))
        assertEquals("Third line", textAt(sub, 11_000L))
        // 片头之前、片尾之后都不该有东西。
        assertEquals("", textAt(sub, 0L))
        assertEquals("", textAt(sub, 60_000L))
    }

    @Test
    fun `GBK 编码的中文 SRT 不会被解成乱码`() {
        val zh = """
            1
            00:00:01,000 --> 00:00:04,000
            我们要夺回那座城
        """.trimIndent()
        // ⛔ 这是本用例的重点：media3 只认 UTF-8，GBK 必须由 toUtf8 先转过来。
        val gbk = zh.toByteArray(Charset.forName("GB18030"))
        val sub = ExternalSubtitle.parse("中文字幕.srt", gbk)
        assertEquals("我们要夺回那座城", textAt(sub, 2_000L))
    }

    @Test
    fun `带 UTF-8 BOM 的 SRT 不会把 BOM 当成正文`() {
        val bytes = ByteArray(3) { 0 }.also {
            it[0] = 0xEF.toByte(); it[1] = 0xBB.toByte(); it[2] = 0xBF.toByte()
        } + srt.toByteArray(Charsets.UTF_8)
        val sub = ExternalSubtitle.parse("bom.srt", bytes)
        assertEquals("Hello world", textAt(sub, 2_000L))
    }

    // ── ASS / VTT ───────────────────────────────────────────────

    @Test
    fun `ASS 解析出条目且硬换行不会让时间轴错位`() {
        val ass = """
            [Script Info]
            ScriptType: v4.00+

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,第一句
            Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,第一行\N第二行
        """.trimIndent()
        val sub = ExternalSubtitle.parse("a.ass", ass.toByteArray(Charsets.UTF_8))
        assertEquals(2, sub.cueCount)
        assertEquals("第一句", textAt(sub, 2_000L))
        // `\N` 是 ASS 的硬换行，media3 会把它变成真正的换行符。
        assertEquals("第一行\n第二行", textAt(sub, 5_000L))
    }

    @Test
    fun `VTT 能解析`() {
        val vtt = """
            WEBVTT

            00:00:01.000 --> 00:00:03.000
            VTT line one

            00:00:04.000 --> 00:00:06.000
            VTT line two
        """.trimIndent()
        val sub = ExternalSubtitle.parse("a.vtt", vtt.toByteArray(Charsets.UTF_8))
        assertEquals(2, sub.cueCount)
        assertEquals("VTT line one", textAt(sub, 2_000L))
        assertEquals("VTT line two", textAt(sub, 5_000L))
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

    @Test(expected = IllegalArgumentException::class)
    fun `不支持的扩展名直接拒绝`() {
        ExternalSubtitle.parse("a.sub", srt.toByteArray(Charsets.UTF_8))
    }

    @Test(expected = IllegalStateException::class)
    fun `格式对但内容不是字幕时报错而不是返回空`() {
        ExternalSubtitle.parse("a.srt", "这不是字幕".toByteArray(Charsets.UTF_8))
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

    // ── 辅助 ────────────────────────────────────────────────────

    /** 把某一时刻的 cue 文字拼起来（多条时用 `|` 分隔），空则为空串。 */
    private fun textAt(sub: ExternalSubtitle, positionMs: Long): String =
        sub.cuesAt(positionMs).joinToString("|") { it.text?.toString().orEmpty() }
}
