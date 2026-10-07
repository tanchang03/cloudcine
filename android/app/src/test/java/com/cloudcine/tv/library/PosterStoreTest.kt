package com.cloudcine.tv.library

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PosterStore.fileFor] 的判据单测。
 *
 * ## 为什么这一组必须有
 *
 * 一个作品键在盘上**可能有好几张图**：网盘自己生成的视频截图（`thumb_url`）
 * 与刮削拿到的海报各存一份，文件名只差第二段（URL 散列）。而
 * [PosterStore.buildIndex] 对每个键**只留一张**（`listFiles()` 顺序里的第一个）——
 * 这是刻意的（见该函数的注释），但它意味着「索引命中」不等于「挑对了图」。
 *
 * 2026-10-07 的真机事故就是这么来的：电视上装的构建里 [PosterStore.fileFor]
 * **只有 ①`poster_file` + ③索引**，而 PC 端刮削从不回写 `poster_file`
 * （实测 128 部全空），于是全部落到索引 —— 129 部里 **58 部**的键下有多张图，
 * 它们显示的是网盘截图而不是刮削海报（「生死时限」「阿凡达：火与烬」…）。
 *
 * 所以「按**当前** `poster_url` 现算文件名」这一步（②）不是优化，是**正确性**：
 * 它保证显示的永远是库里记着的那张海报。删掉它，这组用例立刻变红。
 */
class PosterStoreTest {

    private val key = "生z死z时z限#2026"

    /** 网盘自己生成的视频截图（刮削之前先用它兜底）。 */
    private val thumbUrl = "https://drive-pc.quark.cn/1/clouddrive/file/video/preview?fid=abc"

    /** 刮削拿到的 TMDB 海报。 */
    private val scrapedUrl = "https://image.tmdb.org/t/p/w500/67HuUq4XAKs1NVaLF2bY2Yv8hHG.jpg"

    private fun tempDir(): File = Files.createTempDirectory("posters").toFile()

    /**
     * 造出「同一个键下两张图」的现场。
     *
     * ⛔ **先写兜底图、后写刮削海报**：`listFiles()` 在新建目录里基本按创建顺序
     *    返回，所以索引会留住**先写的**那张（= 网盘截图）。这正是真机上的现场。
     */
    private fun dirWithTwoImages(): Pair<File, Pair<String, String>> {
        val dir = tempDir()
        val thumbName = PosterNaming.fileNameFor(key, thumbUrl)
        val scrapedName = PosterNaming.fileNameFor(key, scrapedUrl)
        File(dir, thumbName).writeBytes(byteArrayOf(1, 2, 3))
        File(dir, scrapedName).writeBytes(byteArrayOf(4, 5, 6))
        return dir to (thumbName to scrapedName)
    }

    private fun work(
        posterUrl: String?,
        posterFile: String? = null,
    ): Work = Work(
        key = key,
        kind = "movie",
        category = "movie",
        title = "生死时限",
        originalTitle = null,
        year = 2026,
        overview = null,
        posterUrl = posterUrl,
        posterFile = posterFile,
        posterFaceX = null,
        rating = null,
        genres = emptyList(),
        source = "online",
        itemCount = 1,
        totalBytes = 0L,
        seasonCount = 1,
        lastModifiedAt = null,
        firstSeenAt = null,
        lastPlayedAt = null,
        resumeFraction = null,
    )

    // ------------------------------------------------------------------
    // ① 库里记着的文件名
    // ------------------------------------------------------------------

    @Test
    fun `poster_file 有值且文件存在时最优先`() {
        val (dir, names) = dirWithTwoImages()
        val (thumbName, _) = names
        val store = PosterStore(dir, 1 shl 20)
        store.buildIndex()

        // 故意记成「兜底图」——只要这一列有值，就必须听它的，
        // 否则 Android 端刮削完回写的 `poster_file` 会被无视。
        assertEquals(File(dir, thumbName), store.fileFor(work(posterUrl = scrapedUrl, posterFile = thumbName)))
    }

    @Test
    fun `poster_file 指向的文件不在盘上时不能卡住`() {
        val (dir, names) = dirWithTwoImages()
        val (_, scrapedName) = names
        val store = PosterStore(dir, 1 shl 20)
        store.buildIndex()

        // 记着一个不存在的名字（换了机器 / 缓存被清）⇒ 必须继续往下找，
        // 而不是返回 null 让卡片变成空白。
        assertEquals(
            File(dir, scrapedName),
            store.fileFor(work(posterUrl = scrapedUrl, posterFile = "不存在_00000000.jpg")),
        )
    }

    // ------------------------------------------------------------------
    // ② 按当前 poster_url 现算 —— 本次事故的回归点
    // ------------------------------------------------------------------

    /**
     * ⛔ **本用例就是 2026-10-07 那次「电视上是网盘截图」的回归测试。**
     *
     * ## 为什么断言是**两条成对**的
     *
     * 索引对每个键只留一张图，而它留的是 `listFiles()` 顺序里的第一个 ——
     * **顺序不可控**（APFS 与 ext4 还不一样）。所以「返回刮削海报」这一条单独看
     * 是不可靠的：万一索引恰好也留了刮削海报，没有第 ② 步照样通过。
     *
     * 但下面两条**合起来**就绕不过去：索引只有一格，不可能同时等于两张图。
     * 想让两条都绿，`fileFor` 就必须真的按 `poster_url` 现算文件名。
     */
    @Test
    fun `同一个键下有两张图时 按 poster_url 各取所需`() {
        val (dir, names) = dirWithTwoImages()
        val (thumbName, scrapedName) = names
        // 前提：两张图确实是两个不同的文件（文件名第二段是 URL 散列）。
        assertNotEquals(thumbName, scrapedName)

        val store = PosterStore(dir, 1 shl 20)
        store.buildIndex()
        // 前提：索引把两张图**压成了一条**（这就是「索引命中 ≠ 挑对图」的根源）。
        assertEquals("索引应当只为一个键留一张图", 1, store.indexedCount)

        assertEquals(
            "库里记着刮削海报时，显示的必须是它，不是网盘截图",
            File(dir, scrapedName),
            store.fileFor(work(posterUrl = scrapedUrl)),
        )
        // 反向：库里记着的是**兜底图**时也不能自作主张去挑海报 ——
        // 那种「聪明」的做法会让「用户手动换过的封面」永远显示不出来。
        assertEquals(
            "库里记着兜底图时必须听库里的",
            File(dir, thumbName),
            store.fileFor(work(posterUrl = thumbUrl)),
        )
    }

    // ------------------------------------------------------------------
    // ③ 退回索引：PC 端刮的、随备份搬过来的那些作品
    // ------------------------------------------------------------------

    /**
     * PC 端刮削时 `poster_url` 可能为空（只有文件在盘上），这时只能靠索引。
     *
     * ⛔ 键要过 [PosterNaming.sanitize] —— 索引里的键是「文件名反推出来的归一化键」，
     *    拿**原始键**去查表在键里有空白/斜杠时会查不到（症状还是「海报不显示」）。
     */
    @Test
    fun `poster_url 为空时退回目录索引`() {
        val dir = tempDir()
        val name = PosterNaming.fileNameFor("电影 2024 奥德赛", "https://example.com/a.jpg")
        File(dir, name).writeBytes(byteArrayOf(1))

        val store = PosterStore(dir, 1 shl 20)
        store.buildIndex()

        val w = work(posterUrl = null).copy(key = "电影 2024 奥德赛")
        assertEquals(File(dir, name), store.fileFor(w))
    }

    @Test
    fun `poster_url 是空串时也要退回索引 不能拿空串算文件名`() {
        val (dir, names) = dirWithTwoImages()
        val (thumbName, scrapedName) = names
        val store = PosterStore(dir, 1 shl 20)
        store.buildIndex()

        // 空白必须当成「没有」——拿它去 `fileNameFor` 会算出一个不存在的名字，
        // 然后静默退化成「没有海报」。
        //
        // ⛔ 这里**不能**断言拿到哪一张：索引留哪张取决于 `listFiles()` 顺序。
        //    只钉「它仍然是这个键下的一张图」。
        val f = store.fileFor(work(posterUrl = "  "))
        assertNotNull("空白 poster_url 不该让查找失败", f)
        assertTrue(
            "应当落到该键下的某一张图上，实际是 ${f?.name}",
            f!!.name == thumbName || f.name == scrapedName,
        )
    }

    @Test
    fun `目录里一张图都没有时返回 null`() {
        val store = PosterStore(tempDir(), 1 shl 20)
        store.buildIndex()
        assertEquals(0, store.indexedCount)
        assertNull(store.fileFor(work(posterUrl = scrapedUrl)))
    }

    /**
     * ⛔ 索引没建过（`buildIndex` 还没跑）时，第 ② 步**仍然要能命中**。
     *
     * 这一条保证「海报在不在」不依赖 `buildIndex` 的时机 —— 它是后台线程跑的，
     * 而 `getView` 在主线程上，两者没有同步关系。
     */
    @Test
    fun `未建索引时 poster_url 命中仍然有效`() {
        val (dir, names) = dirWithTwoImages()
        val (_, scrapedName) = names
        val store = PosterStore(dir, 1 shl 20)
        // 刻意不调 buildIndex()
        assertEquals(File(dir, scrapedName), store.fileFor(work(posterUrl = scrapedUrl)))
    }

    /**
     * ⛔ 键里带 `#` 与中文时，文件名要能原样落盘并被索引认出来。
     *
     * 真机上的作品键长这样（`therunner#2026`、`阿z凡z达火z与z烬#2025`）——
     * `#` 在 URI 里是片段分隔符，PC 端打包用的是 `File.uri.pathSegments.last`，
     * 这里钉住「落到磁盘上的名字就是算出来的名字」，别让编码在中间插一手。
     */
    @Test
    fun `键里的井号与中文能原样落盘`() {
        val (dir, names) = dirWithTwoImages()
        val (_, scrapedName) = names
        assertTrue("文件名里应当保留井号", scrapedName.contains('#'))
        assertTrue(File(dir, scrapedName).isFile)

        val store = PosterStore(dir, 1 shl 20)
        store.buildIndex()
        assertEquals(1, store.indexedCount)
    }
}
