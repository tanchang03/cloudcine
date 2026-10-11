package com.cloudcine.tv

/**
 * 磁盘预取器的**纯决策层**：一块下多大、首块之后跳到哪、续播点换算成字节。
 *
 * ## 为什么单独抽出来（2026-10-11）
 *
 * 起因是一次评估：用户报「明明缓冲了一大片，拖进缓冲区间里还是要缓冲」。
 * 查下来预取器有两个**只看代码看不出来、跑起来也不报错**的毛病：
 *
 * ① **提交粒度 = 请求粒度**。`CacheWriter.cache()` 一次请求
 *    [CHUNK_BYTES]，而 `CacheDataSink` 只在**整块读完**才 `commitFile`
 *    ⇒ 盘上那最多 128 MiB 是「下了但读不到」（`CacheDataSource` 未命中）。
 *    按媒体时间算，原画档 ≈ 35 s，低码率档（0.24 MiB/s）≈ **9 分钟**。
 *    ⇒ 修法是给 `CacheDataSink` 开 [FRAGMENT_BYTES]，把「请求粒度」与
 *    「提交粒度」**解耦**：请求仍然 128 MiB（连接复用不退化），
 *    但每 8 MiB 就落一次盘。
 *
 * ② **续播时从字节 0 爬**。预取器只会**往前**挪锚点，而挪锚点只在
 *    **用户跳转**时发生；续播那次 `seekTo` 打过来时预取器还没建好，
 *    于是它老老实实从 0 往下灌 —— 灌的全是用户**已经看过**的那一段。
 *    ⇒ 修法是首块下 [HEAD_BYTES]（把文件头 / `moov` / 索引落盘，这是当初
 *    从 0 起步的**唯一**理由），然后立刻跳到续播点。
 *
 * 这三件事都是「算错了不崩、只是白下/白等」，所以判据下沉到这里，
 * 由 `PrefetchPlanTest` 钉住；`DiskPrefetcher` 只负责调它。
 */
object PrefetchPlan {

    /**
     * 单个 `CacheWriter.cache()` 请求的长度。
     *
     * ⛔ 别再靠它控制提交粒度 —— 那是 [FRAGMENT_BYTES] 的事。
     * 它只决定「一次 `open()` 覆盖多远」，也就是 8 条连接的**复用效率**：
     * 太小 ⇒ 反复重建连接（实测 8 连接铺开 12 MiB 要 1.05 s，开销吃掉带宽）。
     */
    const val CHUNK_BYTES = 128L * 1024 * 1024

    /**
     * 一次 `CacheDataSink` **提交**的粒度（media3 的 `setFragmentSize`）。
     *
     * ⛔ 这个值直接决定两件事，别随手调大：
     *   · **前沿可见性**：预取前沿后面这一段在提交前对播放器不可见，
     *     拖进去就是未命中 ⇒ 回网络。8 MiB 在原画档 ≈ 2.2 s、
     *     低码率档（0.24 MiB/s）≈ 33 s。
     *   · **跳转丢弃量**：`reanchor` 会打断正在写的那一块，**已提交的片段
     *     会留下、只有当前那个片段丢掉**。所以「拖一次丢多少」= 这个值，
     *     而不是 [CHUNK_BYTES]。改大之前先想清楚这一条。
     * ⚠️ 代价：span 数变多（每 128 MiB 从 1 个变 16 个）。
     *   `PlayerActivity.diskCacheSnapshot()` 每拍要 `getCachedSpans` 一次，
     *   几百个 span 仍可忽略；**再往下调到 1~2 MiB 就得先给它降频**。
     */
    const val FRAGMENT_BYTES = 8L * 1024 * 1024

    /**
     * 首块（文件头）下多少。
     *
     * 取一个 [FRAGMENT_BYTES] 是**故意**的：首块正好凑成一个完整片段，
     * 于是「文件头落盘」与「跳到续播点」之间只隔一次提交，不用等第二个片段。
     * ⛔ 别小于它：faststart 的 `moov` 在长片上有几 MiB，下不全等于没下。
     */
    const val HEAD_BYTES = FRAGMENT_BYTES

    /** [jumpAfterHead] 的返回值：**不跳**，原地继续。 */
    const val NO_JUMP = -1L

    /**
     * 第 `chunksDone` 块该请求多少字节（`chunksDone` 从 0 数）。
     *
     * 首块且**有**续播锚点时只下 [HEAD_BYTES]（只为把文件头落盘），
     * 其余一律 [CHUNK_BYTES]。
     * 没有锚点（`jumpAfterHeadBytes <= 0`）时首块也走 [CHUNK_BYTES] ——
     * 那正是「从头看」的场景，预取器本来就该一路往前灌。
     */
    fun chunkSpan(chunksDone: Int, jumpAfterHeadBytes: Long): Long =
        if (chunksDone == 0 && jumpAfterHeadBytes > 0L) HEAD_BYTES else CHUNK_BYTES

    /**
     * 首块下完之后要不要跳到续播点；返回 [NO_JUMP] 表示不跳。
     *
     * @param frontierBytes 首块下完后的前沿（= 已提交到哪）。
     * ⛔ 必须比**前沿**大才跳：锚点比前沿小的话，跳过去等于把已下的那段
     *    重新下一遍（`DiskPrefetcher.reanchor` 也只在往前时才动）。
     * ⛔ 只在 `chunksDone == 1` 时生效 —— 后面每块都跳一次就成了原地打转。
     */
    fun jumpAfterHead(chunksDone: Int, frontierBytes: Long, jumpAfterHeadBytes: Long): Long =
        if (chunksDone == 1 && jumpAfterHeadBytes > frontierBytes) jumpAfterHeadBytes else NO_JUMP

    /**
     * 续播点（毫秒）→ 文件里的**字节**位置；拿不到就返回 [NO_JUMP]。
     *
     * @param bytesPerSec 当前档位的码率（**字节/秒**，不是 MiB/s）。
     *   调用方用 `码率 MiB/s × 1048576` 得到 —— 单位搞混会让锚点差 100 万倍，
     *   而现象只是「预取器跑到文件外面去了」，不报错。
     *
     * ⛔ 判 `bytesPerSec` 必须**先 `isFinite()`**：`NaN <= 0.0` 是 false，
     *    光写 `<= 0` 会让 NaN 一路穿过去，`toLong()` 得到 0 ⇒ 静默退化成
     *    「不跳」。与 `DiskCachePlan.totalBytes` 同一条规矩。
     * ⛔ `<= 0` 的续播点（含 `resumeAtMs = 0` 与未知的 -1）一律不跳：
     *    从头看的时候跳反而是错的。
     */
    fun resumeAnchorBytes(resumeAtMs: Long, bytesPerSec: Double): Long {
        if (resumeAtMs <= 0L) return NO_JUMP
        if (!bytesPerSec.isFinite() || bytesPerSec <= 0.0) return NO_JUMP
        val bytes = resumeAtMs / 1000.0 * bytesPerSec
        if (!bytes.isFinite() || bytes <= 0.0) return NO_JUMP
        return bytes.toLong()
    }
}
