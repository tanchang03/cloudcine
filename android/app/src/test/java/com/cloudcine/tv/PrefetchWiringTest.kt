package com.cloudcine.tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 磁盘预取器那条链路的**接线守卫**。
 *
 * ## 为什么需要它
 *
 * 2026-10-11 的评估结论是：用户报的「明明缓冲了一大片、拖进缓冲区间里还是要
 * 缓冲」，成因全是**「删掉/改掉一行也不会报错」**的那种：
 *
 * | 少了什么 | 现象 |
 * |---|---|
 * | `setFragmentSize` | 前沿那 128 MiB 下了也读不到（未提交的 span 不算已缓存），用户拖进去就是回网络 |
 * | `PrefetchPlan.chunkSpan` | 首块又变成 128 MiB ⇒「首块下完就跳」要等几分钟，等于没修 |
 * | `PrefetchPlan.jumpAfterHead` | 续播时预取器又从字节 0 灌用户看过的那一段 |
 * | 续播点没传下去 | 同上（`jumpAfterHeadBytes` 恒为「不跳」） |
 *
 * 四件事都**不编译报错、不崩、日志干净**，只有人坐在电视前拖进度条才看得出来。
 * 所以用静态守卫钉住。风格与理由同 [LibraryActivityWiringTest]。
 *
 * ⛔ **必须先剔注释再找**：上面每一条的名字都在这两个源文件的文档注释里被
 *    **引用过**（「修法：给 `CacheDataSink` 加 `setFragmentSize(...)`」这种）。
 *    不剔的话，一次「把代码行删掉」的误操作会被判成「还在」—— 守卫在最需要
 *    它的那一刻放行，等于没有守卫。
 *
 * ⚠️ 断言的是 media3 的名字 `setFragmentSize`（**不是** ExoPlayer 2.x 的
 *    `setFragmentFileSize`）—— 写错名字**编译不过**，这条守卫钉的是
 *    「有人把这一行删了」，不是「有人拼错方法名」。
 */
class PrefetchWiringTest {

    private val prefetcherFile =
        File("src/main/java/com/cloudcine/tv/DiskPrefetcher.kt")
    private val playerFile =
        File("src/main/java/com/cloudcine/tv/PlayerActivity.kt")

    /**
     * 预取器的 `CacheDataSink` 必须开**增量提交**。
     *
     * 不开的话，一个 128 MiB 的 `DataSpec` 只在整块读完才 `commitFile`；
     * 在此之前那个 span `isCached = false` ⇒ 进度条不画、播放器读它 = 未命中。
     * 按媒体时间算，低码率档（0.24 MiB/s）下那是 **9 分钟**的视频。
     */
    @Test
    fun `预取器的 CacheDataSink 开了增量提交`() {
        val code = codeOnly(read(prefetcherFile))
        assertTrue(
            "DiskPrefetcher 的代码区里没有 `setFragmentSize(`。\n" +
                "少了它，预取前沿后面那最多一整块（128 MiB）是「下了但读不到」的：" +
                "进度条那层淡蓝不画它、播放器 CacheDataSource 读它必然未命中 ⇒ 回网络。",
            code.contains("setFragmentSize("),
        )
    }

    /**
     * 块长必须走 [PrefetchPlan.chunkSpan]，不能直接写 `CHUNK_BYTES`。
     *
     * 直接写就丢掉了「首块只下文件头」这一条 ⇒ 续播时要么不跳、要么跳之前
     * 先等一整块（低码率档下几分钟）。
     */
    @Test
    fun `块长走 PrefetchPlan 的判据`() {
        val code = codeOnly(read(prefetcherFile))
        assertTrue(
            "DiskPrefetcher 的代码区里没有 `PrefetchPlan.chunkSpan(` —— " +
                "「首块只下 HEAD_BYTES」这条判据被绕过了。",
            code.contains("PrefetchPlan.chunkSpan("),
        )
    }

    /** 首块下完必须走 [PrefetchPlan.jumpAfterHead] 去登记续播锚点。 */
    @Test
    fun `首块下完会跳到续播点`() {
        val code = codeOnly(read(prefetcherFile))
        assertTrue(
            "DiskPrefetcher 的代码区里没有 `PrefetchPlan.jumpAfterHead(` —— " +
                "续播时预取器会从字节 0 一路灌用户已经看过的那一段。",
            code.contains("PrefetchPlan.jumpAfterHead("),
        )
    }

    /**
     * `PlayerActivity` 必须把**续播点**换算成字节传进预取器。
     *
     * ⛔ 两件都要在：`resumeAnchorBytes(`（换算，含单位与 NaN 的判据）
     *    与 `jumpAfterHeadBytes =`（传参）。只留一个的话参数恒为默认值，
     *    功能静默失效 —— 而日志里那句「首块 … 后继续往前（无续播点）」
     *    是唯一能看出这件事的地方。
     */
    @Test
    fun `PlayerActivity 把续播点传给了预取器`() {
        val code = codeOnly(read(playerFile))
        assertTrue(
            "PlayerActivity 的代码区里没有 `PrefetchPlan.resumeAnchorBytes(` —— " +
                "续播点没换算成字节（单位搞错会让锚点差 100 万倍，且不报错）。",
            code.contains("PrefetchPlan.resumeAnchorBytes("),
        )
        assertTrue(
            "PlayerActivity 构造 DiskPrefetcher 时没有传 `jumpAfterHeadBytes =` —— " +
                "续播锚点恒为默认值，等于没修。",
            code.contains("jumpAfterHeadBytes ="),
        )
    }

    /**
     * 剔除注释后的源码。
     *
     * 与 [LibraryActivityWiringTest] 同一条规矩：**行级**过滤，只看这一行
     * 是不是注释行，不碰行尾内容 —— 按 `//` 粗暴切断会把 `"https://…"`
     * 这类字符串字面量的后半截吃掉，反而制造出「代码被破坏」的假象。
     */
    private fun codeOnly(src: String): String =
        src.lines().filterNot { line ->
            val t = line.trimStart()
            t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
        }.joinToString("\n")

    private fun read(f: File): String {
        assertTrue(
            "读不到源文件：${f.absolutePath}（当前目录 ${File(".").absolutePath}）。\n" +
                "本测试依赖 Gradle 的 test 工作目录 = 模块目录（android/app），路径变了要同步改。",
            f.isFile,
        )
        return f.readText()
    }
}
