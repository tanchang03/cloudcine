package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PrefetchPlan] 的用例。
 *
 * ## 为什么这几条值得钉住
 *
 * 2026-10-11 那次评估的结论是：用户报的「明明缓冲了一大片、拖进缓冲区间里
 * 还是要缓冲」，其中两条成因**都不会崩、也不会报错**，只是「白下 / 白等」：
 *
 *   · **提交粒度**：不给 `CacheDataSink` 设 `setFragmentSize`，一个
 *     128 MiB 的请求只在整块读完才落盘 ⇒ 前沿那 128 MiB 播放器读不到。
 *   · **续播锚点**：预取器从字节 0 起、又只在用户跳转时才挪锚点 ⇒
 *     续播时它把用户**已经看过**的那一段从头灌一遍。
 *
 * 所以这里只测「算错也不报错」的那几个判据，不去测线程与 IO。
 */
class PrefetchPlanTest {

    // ------------------------------------------------------------------
    // resumeAnchorBytes：续播点 → 字节
    // ------------------------------------------------------------------

    /**
     * ⛔ 单位契约：入参是**字节/秒**，不是 MiB/s。
     *
     * 调用方要自己乘 `1048576`（`PlayerActivity` 里那个 `bytesPerSec` 就是
     * 这么来的）。函数里**再乘一次**的话锚点会大 100 万倍，现象只是
     * 「预取器跑到文件外面去了」—— 不报错，只能靠这条钉住。
     */
    @Test
    fun `入参是字节每秒 函数自己不再做 MiB 换算`() {
        // 1 秒 × 1 字节/秒 = 1 字节。若函数内部偷偷乘了 1048576，这里会得到 1048576。
        assertEquals(1L, PrefetchPlan.resumeAnchorBytes(1_000L, 1.0))
    }

    /** 正常换算：60 秒 × 1 MB/s = 60 MB。 */
    @Test
    fun `续播点按码率换算成字节`() {
        assertEquals(60_000_000L, PrefetchPlan.resumeAnchorBytes(60_000L, 1_000_000.0))
    }

    /** 真实口径复算：1880 秒 × 0.25 MiB/s = 470 MiB。 */
    @Test
    fun `按 MiB 每秒换算的结果与手算一致`() {
        val bytesPerSec = 0.25 * 1048576.0
        assertEquals(492_830_720L, PrefetchPlan.resumeAnchorBytes(1_880_000L, bytesPerSec))
    }

    /**
     * ⛔ `resumeAtMs <= 0` ⇒ **不跳**。
     *
     * 从头看的场景（库里没有续播记录时传 0，未知时传 -1）本来就该一路往前灌，
     * 这时候「跳」是错的 —— 会把片头那一段跳过不下了。
     */
    @Test
    fun `零或负的续播点都不跳`() {
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.resumeAnchorBytes(0L, 1_000_000.0))
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.resumeAnchorBytes(-1L, 1_000_000.0))
    }

    /**
     * ⛔ 码率拿不到 ⇒ **不跳**（`0` 与 `NaN` 都要挡住）。
     *
     * `NaN <= 0.0` 是 `false`，光写 `<= 0` 会让 NaN 一路穿到 `toLong()` 得 0
     * —— 那时返回的是「跳 0 字节」而不是「不跳」，语义完全不同。
     * 与 `DiskCachePlan.totalBytes` 是同一条规矩。
     */
    @Test
    fun `码率为零或 NaN 时不跳`() {
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.resumeAnchorBytes(60_000L, 0.0))
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.resumeAnchorBytes(60_000L, -1.0))
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.resumeAnchorBytes(60_000L, Double.NaN))
    }

    // ------------------------------------------------------------------
    // chunkSpan：一块下多大
    // ------------------------------------------------------------------

    /**
     * ★ 有续播锚点 ⇒ **首块只下文件头**。
     *
     * 这是「续播不从 0 爬到播放头」的全部实现：首块小 ⇒ 很快落盘 ⇒
     * 立刻跳到续播点。若首块仍是 128 MiB，跳转要等一整块下完（低码率档
     * 下是几分钟），修了等于没修。
     */
    @Test
    fun `有续播锚点时首块只下文件头`() {
        assertEquals(
            PrefetchPlan.HEAD_BYTES,
            PrefetchPlan.chunkSpan(chunksDone = 0, jumpAfterHeadBytes = 500L * 1024 * 1024),
        )
        assertTrue(
            "首块必须显著小于整块，否则『首块下完就跳』要等太久",
            PrefetchPlan.HEAD_BYTES < PrefetchPlan.CHUNK_BYTES,
        )
    }

    /**
     * ⛔ **没有**续播锚点（从头看）⇒ 首块就走整块。
     *
     * 别为了「统一」把它也钳成文件头：那会让每次起播都多一次
     * 「重建 8 条连接」（实测 8 连接铺开 12 MiB 要 1.05 s），
     * 而从头看的场景本来就不需要跳。
     */
    @Test
    fun `没有续播锚点时首块就是整块`() {
        assertEquals(PrefetchPlan.CHUNK_BYTES, PrefetchPlan.chunkSpan(0, PrefetchPlan.NO_JUMP))
        assertEquals(PrefetchPlan.CHUNK_BYTES, PrefetchPlan.chunkSpan(0, 0L))
    }

    /** 第二块起一律整块 —— 只有首块特殊。 */
    @Test
    fun `第二块起都是整块`() {
        assertEquals(PrefetchPlan.CHUNK_BYTES, PrefetchPlan.chunkSpan(1, 500L * 1024 * 1024))
        assertEquals(PrefetchPlan.CHUNK_BYTES, PrefetchPlan.chunkSpan(7, 500L * 1024 * 1024))
    }

    // ------------------------------------------------------------------
    // jumpAfterHead：首块之后跳不跳
    // ------------------------------------------------------------------

    /** 首块下完、锚点在前面 ⇒ 跳。 */
    @Test
    fun `首块下完就跳到续播点`() {
        val head = PrefetchPlan.HEAD_BYTES
        assertEquals(500L * 1024 * 1024, PrefetchPlan.jumpAfterHead(1, head, 500L * 1024 * 1024))
    }

    /**
     * ⛔ **只跳一次**：`chunksDone != 1` 一律不跳。
     *
     * 不挡的话每下完一块就跳一次 ⇒ 永远在续播点附近原地打转，播放头前方
     * 一个字节都推进不了。
     */
    @Test
    fun `只有首块之后才跳`() {
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.jumpAfterHead(0, 0L, 500L * 1024 * 1024))
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.jumpAfterHead(2, 0L, 500L * 1024 * 1024))
    }

    /**
     * ⛔ 锚点**不比前沿大**就不跳 —— 否则等于把已经下好的那段重下一遍
     * （`DiskPrefetcher.reanchor` 也只往前锚）。
     *
     * 现实里会出现：续播点很近（比如第 3 秒），而首块已经下到 8 MiB。
     */
    @Test
    fun `锚点不在前沿之前就不跳`() {
        val frontier = 100L * 1024 * 1024
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.jumpAfterHead(1, frontier, frontier))
        assertEquals(PrefetchPlan.NO_JUMP, PrefetchPlan.jumpAfterHead(1, frontier, 1L))
    }

    /** 没有锚点（[PrefetchPlan.NO_JUMP]）⇒ 不跳。 */
    @Test
    fun `没有锚点时不跳`() {
        assertEquals(
            PrefetchPlan.NO_JUMP,
            PrefetchPlan.jumpAfterHead(1, PrefetchPlan.HEAD_BYTES, PrefetchPlan.NO_JUMP),
        )
    }
}
