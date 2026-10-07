package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * 未刮削作品的**封面兜底** —— [CloudCoverFetcher]。
 *
 * ## 为什么这一组必须钉死
 *
 * 它出错的每一种方式都是**静默**的：
 *
 * 1. **文件名算错** ⇒ 图下下来了，但 `PosterStore.fileFor` 的第②级认不出它，
 *    表现是「下完还是不显示」。而在简介页上还会变成**无限重画**
 *    （每次重画都发现「没有文件」→ 再下一次 → 还是没有）。
 *    所以这里逐字钉住「文件名 = `PosterNaming.fileNameFor(key, url)`」。
 * 2. **失败不记忆** ⇒ 一张取不到的图会在每次滚动时重试一遍，而夸克有 QPS 限制。
 * 3. **半张图被当成有效缓存** ⇒ 下次直接显示一张损坏的图（所以要 `.part` + 改名）。
 * 4. **自己拼地址** ⇒ 服务端只对已经生成过预览图的文件下发 `preview_url`
 *    （实测覆盖约 70%），拼出来的对剩下的只会拿到 404/401。
 *
 * ⛔ 取字节那一步做成函数类型（[CloudCoverFetcher] 的构造参数），所以这里
 *    不用 `PanApi`、不用凭证、不碰网络。
 */
class CloudCoverFetcherTest {

    // ==================================================================
    // 什么时候**不该**去下
    // ==================================================================

    /** 地址为空 / 不是 http(s) ⇒ 直接放弃，**绝不自己拼地址**。 */
    @Test
    fun `地址不可用时不下任何东西`() {
        var calls = 0
        val f = fetcher { calls++; byteArrayOf(1) }

        assertNull(f.fetch("k", null))
        assertNull(f.fetch("k", ""))
        assertNull(f.fetch("k", "   "))
        assertNull(f.fetch("k", "/preview/123.jpg"))
        assertNull(f.fetch("k", "ftp://x/y.jpg"))
        assertEquals("一次网络请求都不该发", 0, calls)
    }

    /**
     * 盘上已经有同名文件 ⇒ **直接返回文件名**，不重复下载。
     *
     * 判据是「文件存在」而不是「下过一次」：与 PC 端 `PosterCache.pathFor` 同一条
     * 推理（同一个地址的图内容不会变），而且这样**跨进程重启也有效**。
     */
    @Test
    fun `已有同名文件时直接命中不下载`() {
        val dir = tempDir()
        val url = "https://p.quark.cn/preview/a.jpg"
        val name = PosterNaming.fileNameFor("电影_2024_流浪地球", url)
        File(dir, name).writeBytes(byteArrayOf(9, 9, 9))

        var calls = 0
        val f = CloudCoverFetcher(dir) { calls++; byteArrayOf(1, 2, 3) }

        assertEquals(name, f.fetch("电影_2024_流浪地球", url))
        assertEquals("缓存命中不该发请求", 0, calls)
    }

    // ==================================================================
    // 下载与命名
    // ==================================================================

    /**
     * ⛔ **文件名必须与 [PosterNaming.fileNameFor] 逐字一致**。
     *
     * `PosterStore.fileFor` 的第②级就是拿 `PosterNaming.fileNameFor(work.key,
     * work.posterUrl)` 现算的。差一个字符，图就永远显示不出来 ——
     * 而且**不报任何错**。
     */
    @Test
    fun `落盘文件名与 fileFor 的算法一致`() {
        val dir = tempDir()
        val url = "https://p.quark.cn/preview/a.jpg"
        val key = "剧集_2024_进击的巨人"
        val f = fetcher(dir) { byteArrayOf(7, 7) }

        val name = f.fetch(key, url)

        assertEquals(PosterNaming.fileNameFor(key, url), name)
        val written = File(dir, name!!)
        assertTrue("文件必须真的落盘", written.isFile)
        assertEquals(2, written.length())
    }

    /**
     * ⛔ 带**首尾空白**的地址：文件名按**原样**算（与 `fileFor` 对齐），
     *    请求才用 trim 过的串。
     *
     * 这条看起来吹毛求疵，但它是「下完还是不显示」这类问题里最难查的一种 ——
     * 两边的散列只差一个空格，肉眼完全看不出来。
     */
    @Test
    fun `文件名用原样地址算请求用 trim 过的`() {
        val dir = tempDir()
        val raw = "  https://p.quark.cn/preview/a.jpg  "
        var requested: String? = null
        val f = CloudCoverFetcher(dir) { requested = it; byteArrayOf(5) }

        val name = f.fetch("k", raw)

        assertEquals(PosterNaming.fileNameFor("k", raw), name)
        assertEquals("请求要用 trim 过的地址", "https://p.quark.cn/preview/a.jpg", requested)
    }

    /** 成功后不留 `.part` —— 留下的话它会被当成一张「多出来的图」。 */
    @Test
    fun `成功后不留下 part 文件`() {
        val dir = tempDir()
        val f = fetcher(dir) { byteArrayOf(1, 2, 3) }
        f.fetch("k", "https://x/a.jpg")

        assertFalse(File(dir, "${PosterNaming.fileNameFor("k", "https://x/a.jpg")}.part").exists())
    }

    /** 目录不存在时自己建（首次运行、或用户手工清过海报目录）。 */
    @Test
    fun `目录不存在时自己建`() {
        val dir = File(tempDir(), "nested/posters")
        assertFalse(dir.exists())

        val f = fetcher(dir) { byteArrayOf(1) }
        assertNotNull(f.fetch("k", "https://x/a.jpg"))
        assertTrue(dir.isDirectory)
    }

    // ==================================================================
    // 失败
    // ==================================================================

    /** 取字节抛异常 ⇒ 返回 `null`，**不向上抛**（封面是增强，不该拖垮调用方）。 */
    @Test
    fun `取字节抛异常时返回 null 不抛`() {
        val f = fetcher(tempDir()) { throw RuntimeException("网盘 401") }
        assertNull(f.fetch("k", "https://x/a.jpg"))
    }

    /** 空响应 ⇒ `null`（不能把 0 字节当成一张有效图落盘）。 */
    @Test
    fun `空响应不算成功`() {
        val dir = tempDir()
        val f = fetcher(dir) { ByteArray(0) }

        assertNull(f.fetch("k", "https://x/a.jpg"))
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }

    /**
     * ⛔ **失败要记在内存里**：同一张取不到的图不该在每次滚动时重试一遍。
     *
     * ⛔ 但它**不落盘** —— 夸克的 `preview_url` 是带签名的、会过期，
     *    下次启动重试一次是应该的。
     */
    @Test
    fun `失败过的地址不会重复重试`() {
        var calls = 0
        val f = fetcher(tempDir()) { calls++; throw RuntimeException("挂了") }

        assertNull(f.fetch("k", "https://x/a.jpg"))
        assertNull(f.fetch("k", "https://x/a.jpg"))
        assertNull(f.fetch("k", "https://x/a.jpg"))
        assertEquals("同一地址只该试一次", 1, calls)
    }

    /** 换了一个地址（比如重新扫描后拿到了新的签名）⇒ 重新试一次。 */
    @Test
    fun `换地址之后会重新试`() {
        var calls = 0
        val f = fetcher(tempDir()) { calls++; throw RuntimeException("挂了") }

        f.fetch("k", "https://x/a.jpg?v=1")
        f.fetch("k", "https://x/a.jpg?v=2")
        assertEquals(2, calls)
    }

    /** 另一部作品失败不影响这一部 —— 去重键是 `键|地址`，不是地址。 */
    @Test
    fun `失败记忆按作品隔离`() {
        var calls = 0
        val f = fetcher(tempDir()) { calls++; throw RuntimeException("挂了") }

        f.fetch("a", "https://x/a.jpg")
        f.fetch("b", "https://x/a.jpg")
        assertEquals(2, calls)
    }

    // ==================================================================
    // 并发去重
    // ==================================================================

    /**
     * ⛔ 同一张图**在下载中**时再问一次 ⇒ 立刻返回 `null`，不发第二个请求。
     *
     * 作品墙的 `getView` 会被反复调用（滚动、`notifyDataSetChanged`），
     * 没有这道闸的话同一张图会被并发拉好几次，而夸克有 QPS 限制。
     *
     * 这里用「取字节时**重入**地再问一次」来制造并发窗口：与真实并发走的是
     * 同一个 `inFlight` 判据，但**完全确定性**（不靠线程调度）。
     */
    @Test
    fun `下载中再问一次不会发第二个请求`() {
        val dir = tempDir()
        var calls = 0
        var reentrant: String? = "没跑"
        lateinit var f: CloudCoverFetcher
        f = CloudCoverFetcher(dir) {
            calls++
            reentrant = f.fetch("k", "https://x/a.jpg")
            byteArrayOf(1)
        }

        val name = f.fetch("k", "https://x/a.jpg")

        assertNotNull(name)
        assertEquals(1, calls)
        assertNull("下载中的那一次必须立刻返回 null", reentrant)
    }

    /** 下载结束后 `inFlight` 要清掉 —— 否则这张图在本进程内再也拉不到了。 */
    @Test
    fun `下载失败后仍可在同一地址上重试另一部作品`() {
        val dir = tempDir()
        var calls = 0
        val f = CloudCoverFetcher(dir) { calls++; if (calls == 1) ByteArray(0) else byteArrayOf(3) }

        assertNull(f.fetch("a", "https://x/a.jpg"))
        // 同一个地址、另一部作品：`a` 的失败不该把 `b` 也一起记死。
        assertNotNull(f.fetch("b", "https://x/a.jpg"))
    }

    // ==================================================================
    // 测试脚手架
    // ==================================================================

    private fun tempDir(): File = Files.createTempDirectory("cloud-cover").toFile()

    private fun fetcher(
        dir: File = tempDir(),
        bytes: (String) -> ByteArray,
    ) = CloudCoverFetcher(dir, bytes)
}
