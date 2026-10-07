package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「发现」入仓的**白名单判据** —— `LibraryScanner.discover` / `discoverFile`
 * 决定「哪些文件能进媒体库」时用的就是这几个函数。
 *
 * ## 为什么这一组必须钉死
 *
 * 「发现」与「全盘扫描」是两条路，但**入仓的白名单是同一条**：
 *
 *   * 判宽了（比如把 `.srt` / `.jpg` 也收进来）⇒ 库里多出一堆「一个视频」，
 *     它们在作品墙上是一格空白海报，用户没法删、只能清库重扫；
 *   * 判窄了 ⇒ 用户点了「发现本目录」，结果什么都没发生 —— 而界面只能说
 *     「这个目录里没有可入库的视频」（见 `Discovery.message`），
 *     看起来像**功能没做**。
 *
 * 而且这两类错都**不报错**，所以规则必须钉在测试里。
 *
 * ## ⛔ 一个容易忽略的交互
 *
 * `.iso` 在 [VideoFormats.BY_EXTENSION] 里是**有**的（映射到 `other`），
 * 所以 `isVideoFile("x.iso") == true`。真正把它挡在外面的是
 * `isDiscImage` —— 只看前者会以为「镜像文件已经被排除了」。
 * 见 [光盘镜像被单独挡住]。
 */
class DiscoveryIngestRulesTest {

    // ==================================================================
    // 视频白名单
    // ==================================================================

    /** 常见容器都要认 —— 这是「发现」能不能用的下限。 */
    @Test
    fun `常见视频容器都在白名单里`() {
        val names = listOf(
            "电影.mp4", "电影.mkv", "电影.webm", "电影.avi", "电影.mov",
            "电影.wmv", "电影.flv", "电影.ts", "电影.m2ts", "电影.mpg",
            "电影.vob", "电影.rmvb", "电影.ogv", "电影.m4v", "电影.3gp",
        )
        for (n in names) {
            assertTrue("应当收：$n", VideoFormats.isVideoFile(n))
        }
    }

    /** 扩展名大小写不影响判定（发布组写 `MKV` 是常态）。 */
    @Test
    fun `扩展名大小写不敏感`() {
        assertTrue(VideoFormats.isVideoFile("电影.MKV"))
        assertTrue(VideoFormats.isVideoFile("电影.Mp4"))
        assertEquals(VideoFormats.containerOf("电影.MKV"), VideoFormats.containerOf("电影.mkv"))
    }

    /**
     * ⛔ **字幕、图片、音频、压缩包一律不收**。
     *
     * 收进来的后果不是「多几行数据」：它们在作品墙上各自变成一格没有海报的
     * 卡片，而用户没有任何办法把它删掉（清库重扫是唯一出路）。
     */
    @Test
    fun `字幕图片音频与压缩包都不收`() {
        val names = listOf(
            "电影.srt", "电影.ass", "电影.ssa", "电影.sub", "电影.vtt",
            "海报.jpg", "海报.png", "海报.webp", "fanart.jpeg",
            "原声.flac", "原声.mp3", "原声.aac", "原声.mka",
            "打包.zip", "打包.rar", "打包.7z", "信息.nfo", "种子.torrent",
        )
        for (n in names) {
            assertFalse("不该收：$n", VideoFormats.isVideoFile(n))
        }
    }

    /** 没有扩展名 / 点在开头 / 点在结尾 ⇒ 都不算视频，**不抛**。 */
    @Test
    fun `畸形文件名不抛且不算视频`() {
        assertFalse(VideoFormats.isVideoFile("没有扩展名"))
        assertFalse(VideoFormats.isVideoFile(""))
        assertFalse(VideoFormats.isVideoFile(".mkv"))     // 隐藏文件，不是视频
        assertFalse(VideoFormats.isVideoFile("电影."))     // 点结尾
        assertNull(VideoFormats.extensionOf("没有扩展名"))
        assertNull(VideoFormats.extensionOf(".mkv"))
        assertNull(VideoFormats.extensionOf("电影."))
    }

    /**
     * ⛔ 光盘镜像必须被**单独**挡住。
     *
     * 两个扩展名被挡的理由**不一样**，这点很容易记错：
     *
     *   * `.iso` **在**白名单里（`BY_EXTENSION` 把它映射到 `other` 容器），
     *     所以 `isVideoFile("x.iso") == true` —— 它**只能**靠 [VideoFormats.isDiscImage]
     *     拦下来。去掉那半个条件，用户点一个 40 GB 的 `.iso`「加入媒体库」，
     *     它就成了库里一个永远播不动的条目。
     *   * `.img` **不在**白名单里，所以它被拦了两次（`isVideoFile` 为 false
     *     已经够了）。`isDiscImage` 仍然认它，是为了让判据在语义上完整 ——
     *     哪天白名单加回 `.img`，拦截不会跟着失效。
     *
     * `discoverFile` 的判据是 `!isVideoFile(name) || isDiscImage(name)`，
     * 两个条件缺一不可。
     */
    @Test
    fun `光盘镜像被单独挡住`() {
        assertTrue("前提：iso 在视频白名单里", VideoFormats.isVideoFile("蓝光原盘.iso"))
        assertFalse("前提：img 不在视频白名单里", VideoFormats.isVideoFile("镜像.img"))

        assertTrue(VideoFormats.isDiscImage("蓝光原盘.iso"))
        assertTrue(VideoFormats.isDiscImage("镜像.img"))

        // 普通视频不是镜像。
        assertFalse(VideoFormats.isDiscImage("电影.mkv"))
        assertFalse(VideoFormats.isDiscImage("没有扩展名"))

        // 把两个条件合成一个判据，逐项验证「哪些会被收」。
        fun accepted(name: String) = VideoFormats.isVideoFile(name) && !VideoFormats.isDiscImage(name)
        assertFalse("iso 不该被收", accepted("蓝光原盘.iso"))
        assertFalse("img 不该被收", accepted("镜像.img"))
        assertTrue("普通视频该被收", accepted("电影.mkv"))
    }

    // ==================================================================
    // 容器名（写进 media_items.container 的**枚举名**）
    // ==================================================================

    /**
     * ⛔ 存库的是**枚举名**（`matroska` / `mpegTs`），不是扩展名也不是展示标签。
     *
     * 这一列是**跨端共享**的：Android 写 `mkv`、PC 写 `matroska` 的话，
     * 「按容器筛」在两端就会给出不同结果 —— 而且不报错。
     */
    @Test
    fun `容器名是枚举名且同一容器归一`() {
        assertEquals("mp4", VideoFormats.containerOf("a.mp4"))
        assertEquals("mp4", VideoFormats.containerOf("a.m4v"))
        assertEquals("matroska", VideoFormats.containerOf("a.mkv"))
        assertEquals("matroska", VideoFormats.containerOf("a.mk3d"))
        assertEquals("mpegTs", VideoFormats.containerOf("a.ts"))
        assertEquals("mpegTs", VideoFormats.containerOf("a.m2ts"))
        assertEquals("quicktime", VideoFormats.containerOf("a.mov"))
        assertEquals("realMedia", VideoFormats.containerOf("a.rmvb"))
        // 认不出的扩展名回 `other`，**不抛**、也不回空串。
        assertEquals("other", VideoFormats.containerOf("a.xyz"))
        assertEquals("other", VideoFormats.containerOf("没有扩展名"))
    }

    // ==================================================================
    // 分辨率（入仓时一起写库）
    // ==================================================================

    /**
     * 三条判据的**顺序**不能换：先 `1920x1080` 这种真实尺寸，再 `1080p`，
     * 最后才是营销词 `4K`。
     */
    @Test
    fun `分辨率按尺寸 扫描行 营销词的顺序判`() {
        assertEquals("fhd1080", VideoFormats.resolutionFromName("电影.1920x1080.mkv"))
        assertEquals("fhd1080", VideoFormats.resolutionFromName("电影.1080p.WEB-DL.mkv"))
        assertEquals("uhd2160", VideoFormats.resolutionFromName("电影.2160p.mkv"))
        assertEquals("uhd2160", VideoFormats.resolutionFromName("电影.4K.HDR.mkv"))
        assertEquals("uhd4320", VideoFormats.resolutionFromName("电影.8K.mkv"))
        assertEquals("qhd1440", VideoFormats.resolutionFromName("电影.2K.mkv"))
    }

    /** 认不出返回 `null` —— 那是「这条证据没意见」，**不是**「标清」。 */
    @Test
    fun `认不出分辨率时返回 null`() {
        assertNull(VideoFormats.resolutionFromName("电影.mkv"))
        assertNull(VideoFormats.resolutionFromName("电影.2023.mkv"))
    }

    /**
     * ⛔ 营销词 `4K` 的判定**不能咬到数字中间**：`(?<![a-z0-9])4k(?![a-z0-9])`。
     *
     * 否则 `S04K01` 这类（`4K` 是集号的一部分）会被读成 4K 片源 ——
     * 而后果是「多版本排序」把这一版排到最前。
     */
    @Test
    fun `营销词不咬到字母数字中间`() {
        assertNull(VideoFormats.resolutionFromName("Show.S04K01.mkv"))
        assertNull(VideoFormats.resolutionFromName("x4k9.mkv"))
    }

    /**
     * ⛔ 实测尺寸必须长边短边各算一次再取**较高**档。
     *
     * 宽银幕裁切的 4K（`3840x1632`）只看高度会被标成 1440P ——
     * 而实测样本里这种裁切占 40%，后果是 4K 版在「多版本排序」里排到后面。
     */
    @Test
    fun `实测尺寸长边短边取较高档`() {
        assertEquals("uhd2160", VideoFormats.resolutionFromDimensions(3840, 1632))
        assertEquals("uhd2160", VideoFormats.resolutionFromDimensions(3840, 2160))
        assertEquals("fhd1080", VideoFormats.resolutionFromDimensions(1920, 1080))
        // 4:3 老内容：只看长边会漏，只看短边也对 —— 取较高的那档。
        assertEquals("fhd1080", VideoFormats.resolutionFromDimensions(1440, 1080))
    }

    @Test
    fun `尺寸缺失或非法时返回 null 而不是崩`() {
        assertNull(VideoFormats.resolutionFromDimensions(null, null))
        assertNull(VideoFormats.resolutionFromDimensions(0, 0))
        assertNull(VideoFormats.resolutionFromDimensions(-1, -1))
        // 小于 360 的短边算认不出。
        assertNull(VideoFormats.resolutionFromDimensions(320, 240))
    }
}
