package com.cloudcine.tv

import android.net.Uri
import android.util.Log
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.datasource.cache.CacheWriter

/**
 * 旁路预取器：**绕开 ExoPlayer 的缓冲预算**，把数据直接写进磁盘缓存。
 *
 * ## 为什么必须「旁路」
 *
 * 这是整个磁盘方案的关键认知 ——
 * **光把数据源换成 `CacheDataSource` 解决不了「暂停后不缓冲」**。
 * 因为 `CacheDataSource` 仍然长在 loader 路径上：
 * ```
 * CacheDataSource → SampleQueue(48 MiB, 受 LoadControl 管) → 解码器
 * ```
 * 队列一满，`shouldContinueLoading` 就返回 false，loader 根本不调 `read()`，
 * 缓存自然也不会写。**瓶颈在 loader 是否被允许读，不在数据源是哪种。**
 *
 * 所以这里另起一条线程，直接用 [CacheWriter] 往 [Cache] 里灌数据：
 * ```
 * 预取线程 → ParallelRangeReader(8 连接) → CacheWriter → SimpleCache(磁盘)
 * ```
 * 它不经过 `SampleQueue`，因此**暂停时照样往前下**。
 *
 * ## 与播放器的分工（不抢同一个 span）
 *
 * - **播放器**：`CacheDataSource` 正常读写 —— 它读过的段会落盘，
 *   所以「已经播过的部分」回拖时能命中。
 * - **预取器**：只下**播放头前方**的那一段，并用 [playheadBytes] 控制领先量。
 *
 * 两边偶尔撞到同一段时，`SimpleCache.startFile` 会拒绝第二个写者，
 * `CacheDataSource` / `CacheWriter` 都会把它当普通 IO 失败降级处理
 * （一个继续走网络、一个重试），**不会崩**。
 *
 * ## 分块大小为什么是 128 MiB
 *
 * [CacheWriter] 一次 `cache()` 调用写一个 span，而每个 span 都要
 * `open()` 一次数据源 —— 对我们的 [ParallelRangeDataSource] 就是
 * 「重建 8 条连接」。实测 8 连接铺开 12 MiB 要 1.05s，
 * 分块太小会让连接建立开销吃掉带宽。
 *
 * 128 MiB 在 11 MiB/s 下约 12 秒一块，开销可忽略；
 * 同时它也是 LRU 的淘汰粒度 —— 太大则一次扔太多，太小则文件碎片多。
 */
class DiskPrefetcher(
    private val cache: Cache,
    private val dataSourceFactory: DataSource.Factory,
    private val uri: Uri,
    /** 从哪开始预取（字节）。一般是起播位置。 */
    private val startPositionBytes: Long,
    /** 文件总长（字节）；**负数 = 未知**。 */
    private val totalBytes: Long,
    /** 允许领先播放头多少字节 —— 超过就停下等播放头追上来。 */
    private val maxLeadBytes: Long,
    /** 播放头当前在文件里的字节位置（由播放器位置 × 码率换算）。 */
    private val playheadBytes: () -> Long,
) {

    @Volatile
    private var cancelled = false

    @Volatile
    private var currentWriter: CacheWriter? = null

    /**
     * 当前正在用的数据源。
     *
     * ⛔ 留着它是为了 [cancel] 能**打断阻塞中的 `read()`** ——
     * `CacheWriter.cancel()` 只置一个标志位，而线程多半正卡在 socket 读上，
     * 光置标志要等到下一次 `read()` 返回才生效（可能是几十秒后）。
     * 关掉数据源才能真正把它踢出来。
     */
    @Volatile
    private var currentSource: CacheDataSource? = null

    private var thread: Thread? = null

    /** 已经下到哪（字节，绝对偏移）。 */
    @Volatile
    var nextPositionBytes: Long = startPositionBytes
        private set

    /** 累计写进缓存的字节数（含被 LRU 淘汰掉的）。 */
    @Volatile
    var writtenBytes: Long = 0L
        private set

    /** 完成的分块数。 */
    @Volatile
    var chunks: Int = 0
        private set

    /**
     * 缓存键。**必须与播放器 `CacheDataSource` 用的一致**，
     * 否则预取下的东西播放器一个字节都命中不了 —— 两边都用默认的
     * [CacheKeyFactory.DEFAULT]（按 uri 生成），所以这里也用它。
     */
    private val cacheKey: String by lazy {
        CacheKeyFactory.DEFAULT.buildCacheKey(DataSpec(uri))
    }

    fun start() {
        if (thread != null) return
        val t = Thread({
            // ⛔ 整个循环包一层兜底：预取是**增强功能**，任何异常都只该让预取
            //    停下，绝不该把播放器进程带走。
            //    踩过（2026-10-06）：在预取线程里读 `player.currentPosition`
            //    ⇒ `IllegalStateException: Player is accessed on the wrong thread`
            //    ⇒ 进程闪退，用户看到的是「无法打开影片」。
            try {
                loop()
            } catch (t: Throwable) {
                Log.e(TAG, "预取线程异常退出（播放不受影响）：${t.message}", t)
            }
        }, "cc-prefetch")
        t.isDaemon = true
        thread = t
        t.start()
    }

    fun cancel() {
        cancelled = true
        runCatching { currentWriter?.cancel() }
        // ⛔ 关数据源才能把卡在 socket 读上的线程踢出来（见 currentSource 的注释）。
        runCatching { currentSource?.close() }
        thread?.let { runCatching { it.join(JOIN_TIMEOUT_MS) } }
        thread = null
    }

    private fun loop() {
        Log.i(
            TAG,
            "预取器启动：起点 ${nextPositionBytes / 1048576} MiB · " +
                "分块 ${CHUNK_BYTES / 1048576} MiB · 领先上限 ${maxLeadBytes / 1048576} MiB",
        )
        while (!cancelled) {
            // ── 到文件末尾就收工 ────────────────────────────────
            if (totalBytes > 0 && nextPositionBytes >= totalBytes) {
                Log.i(TAG, "预取完成：已到文件末尾（${nextPositionBytes / 1048576} MiB）")
                return
            }
            // ── 领先太多就等播放头追上来 ─────────────────────────
            // ⛔ 这里是「等」不是「退出」：用户暂停时预取器应该一直下到
            //    领先上限，然后原地待命 —— 一旦恢复播放就继续。
            val lead = nextPositionBytes - playheadBytes()
            if (lead > maxLeadBytes) {
                if (!sleep(WAIT_SLICE_MS)) return
                continue
            }
            val end = if (totalBytes > 0) {
                minOf(nextPositionBytes + CHUNK_BYTES, totalBytes)
            } else {
                nextPositionBytes + CHUNK_BYTES
            }
            val length = end - nextPositionBytes
            if (length <= 0) return

            val from = nextPositionBytes
            // ⛔ 两个坑都在这一处：
            //    1. `CacheWriter` 的第一个参数是 **CacheDataSource**，不是 DataSource；
            //    2. `CacheDataSource` **不会自动写缓存** —— 不给
            //       `setCacheWriteDataSinkFactory`，读到的数据一个字节都不落盘，
            //       预取器就退化成「白下载一遍」。
            val source = CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(dataSourceFactory)
                .setCacheWriteDataSinkFactory(CacheDataSink.Factory().setCache(cache))
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
                .createDataSource()
            // ⛔ `DataSpec` 必须自带 key：`CacheWriter.cache()` 一进来就
            //    `checkNotNull(dataSpec.key)`。key 必须与播放器用同一个
            //    [CacheKeyFactory.DEFAULT]，否则播放器一个字节都命中不了。
            val writer = CacheWriter(
                source,
                // ⛔ 用 4 参构造把 key 一起带上（没有 `withKey()` 这个方法）。
                DataSpec(uri, from, length, cacheKey),
                ByteArray(CacheWriter.DEFAULT_BUFFER_SIZE_BYTES),
                null,
            )
            currentWriter = writer
            currentSource = source
            try {
                // ⛔ `cache()` **无参** —— 缓存对象是在构造 `CacheDataSource` 时
                //    给进去的，不是在这里传。
                writer.cache()
                // ⛔ 不能把「请求了 length」当成「下到了 length」：上游提前 EOF 时
                //    `CacheWriter` 只提交真正读到的那些字节，位置若直接往前跳
                //    一整块，就会**留下一个永远补不上的空洞**（之后每块都错位）。
                //    所以按缓存里**真实连续覆盖**的字节数推进。
                val actual = cache.getCachedBytes(cacheKey, from, length)
                nextPositionBytes = from + actual
                writtenBytes += actual
                chunks++
                Log.i(
                    TAG,
                    "预取第 ${chunks} 块：${from / 1048576} → " +
                        "${(from + actual) / 1048576} MiB（${actual / 1048576} MiB）· " +
                        "累计 ${writtenBytes / 1048576} MiB · " +
                        "缓存 ${PrefetchCache.usedBytes() / 1048576} MiB",
                )
                if (actual < length) {
                    Log.i(
                        TAG,
                        "预取结束：本块只拿到 ${actual / 1048576} MiB，判定已到文件末尾",
                    )
                    return
                }
            } catch (e: Exception) {
                if (cancelled) return
                // ⛔ 单块失败**不退出**：夸克偶发 4xx/断流很常见，
                //    重试同一块即可（CacheWriter 内部走的是 ParallelRangeReader，
                //    它自己已经做了断点续传与重试）。这里只做退避。
                Log.w(
                    TAG,
                    "预取第 ${chunks + 1} 块失败（${from / 1048576} MiB 起，" +
                        "${length / 1048576} MiB）：${e.message} —— 2 秒后重试",
                )
                if (!sleep(RETRY_BACKOFF_MS)) return
            } finally {
                currentWriter = null
                runCatching { source.close() }
                currentSource = null
            }
        }
    }

    /** @return false 表示已被取消，调用方应立即退出 */
    private fun sleep(ms: Long): Boolean {
        var left = ms
        while (left > 0 && !cancelled) {
            val step = minOf(left, 100L)
            runCatching { Thread.sleep(step) }
            left -= step
        }
        return !cancelled
    }

    companion object {
        private const val TAG = "CloudCine"

        /** 单个 span 的大小。见类注释里「为什么是 128 MiB」。 */
        const val CHUNK_BYTES = 128L * 1024 * 1024

        private const val WAIT_SLICE_MS = 1_000L
        private const val RETRY_BACKOFF_MS = 2_000L
        private const val JOIN_TIMEOUT_MS = 2_000L
    }
}
