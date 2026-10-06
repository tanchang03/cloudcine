package com.cloudcine.tv

import android.net.Uri
import android.util.Log
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
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
 *
 * ## 用户跳转后必须**重新锚定**（2026-10-06 补）
 *
 * ⛔ [nextPositionBytes] **只往前走**，而「领先太多就等播放头」那段逻辑
 *    只会**等**、不会**回看**。所以只要用户把进度条拖到预取前沿之外，
 *    预取器就会继续下**用户刚刚跳过的那一段**（现在落在播放头**后面**）——
 *    白占带宽、白占磁盘，而且播放头前方一个字节都不下。
 *
 * 修法是 [reanchor]：跳转时由播放器（主线程）告诉它新的字节位置，
 * 它**只往前锚**（往回跳时已经下好的那段仍然有用，靠「领先太多就等」
 * 自然处理），并**打断正在写的那一块**，让新位置立刻开始下。
 *
 * ⚠️ 打断的代价：被打断的 span **不会** `commitFile`，那部分数据被丢弃
 *    （最多一整块 = [CHUNK_BYTES] ≈ 11 MiB/s 下 12 秒）。这是有意的取舍 ——
 *    让播放头前方**立刻**开始下，比省下这 12 秒更值。
 */
class DiskPrefetcher(
    private val cache: Cache,
    private val dataSourceFactory: DataSource.Factory,
    private val uri: Uri,
    /**
     * 缓存键。**由调用方注入**，且必须与播放器 `CacheDataSource` 用**同一个**
     * —— 否则预取下的东西播放器一个字节都命中不了。
     *
     * ⛔ **不要退回「按 uri 现算」**（`CacheKeyFactory.DEFAULT`）。夸克直链是
     *    每次起播现取的带签名地址，按 URL 算键会让磁盘缓存**跨不了会话**：
     *    实测重开后同一部片 `磁盘 本片` 从 972 MiB 掉到 0 B，用户看到的就是
     *    「同一部片下次打开还要重新缓冲」。稳定键是 `quark:<fid>:<画质档 id>`，
     *    见 `PlayerActivity.stableCacheKey`。
     *
     * 对外可见是为了让播放器能按**同一个键**去 `Cache.getCachedSpans(key)`
     * 查「本片在盘上覆盖了哪些区间」（进度条那层淡蓝要用）—— 见
     * `PlayerActivity.diskCacheSnapshot()`。
     */
    val cacheKey: String,
    /** 从哪开始预取（字节）。一般是起播位置。 */
    private val startPositionBytes: Long,
    /** 文件总长（字节）；**负数 = 未知**。 */
    private val totalBytes: Long,
    /** 允许领先播放头多少字节 —— 超过就停下等播放头追上来。 */
    val maxLeadBytes: Long,
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

    /**
     * 串起「启停预取线程」的那把锁。
     *
     * ⛔ 必需：[reanchor] 与线程收工的 `finally` **都可能**发现「有锚点、
     *    但线程已经收工」，各判各的就会**同时**拉起两条预取线程 ——
     *    两条线程往同一个 span 里写，`SimpleCache.startFile` 会拒绝第二个
     *    写者，于是两边反复重试、白跑。同理 [cancel] 与「重启」也必须互斥，
     *    否则会在 `onDestroy` 之后漏下一条活着的线程。
     */
    private val startLock = Any()

    /**
     * 预取线程是否已经收工（正常下到末尾、或异常退出）。
     *
     * 存在它是为了让 [restartIfIdle] 能**把死掉的预取器叫起来**：预取是增强
     * 功能，万一它因为某个没预料到的异常停了，用户下一次跳转就该把它重新拉
     * 起来 —— 否则「暂停后不缓冲」会**悄无声息**地回来，而那正是这个需求要
     * 消灭的现象。
     */
    @Volatile
    private var finished = false

    /**
     * 待处理的「重新锚定」请求（字节）；**`<= 0` 表示没有**。
     *
     * ⛔ 不能直接改 [nextPositionBytes]：正在写的那一块结束后会执行
     *    `nextPositionBytes = from + actual`，把外面写进去的值**覆盖回旧位置**。
     *    所以这里只登记「想去哪」，由循环自己在**块与块之间**消费 ——
     *    那是唯一不会跟 in-flight 块打架的时刻。
     */
    @Volatile
    private var pendingAnchorBytes: Long = -1L

    /** 已经下到哪（字节，绝对偏移）。跳转后会直接挪到新锚点。 */
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
     * 当前**领先播放头**多少字节（`nextPositionBytes - 播放头`）。
     *
     * 调试面板要看的就是它：它贴着 [maxLeadBytes] 就是「已经下满、在等播放头」，
     * 远小于它就是「还在追」。跳转之后这个值会瞬间从正变负再爬回来 ——
     * 那一眼就能确认「预取器有没有跟过去」。
     */
    val leadBytes: Long get() = nextPositionBytes - playheadBytes()

    fun start() {
        synchronized(startLock) {
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
                } finally {
                    finished = true
                    // ⛔ 收工的**同一刻**可能正好有人登记了新锚点：那时
                    //    [reanchor] 读到的 `finished` 还是 false，不会帮我们重启，
                    //    锚点就**没人消费**了 —— 表现就是「拖完进度条，缓冲再也不涨」。
                    //    在这里补一次检查把这个窗口堵上。
                    restartIfIdle()
                }
            }, "cc-prefetch")
            t.isDaemon = true
            thread = t
            t.start()
        }
    }

    fun cancel() {
        val t: Thread?
        synchronized(startLock) {
            cancelled = true
            t = thread
        }
        runCatching { currentWriter?.cancel() }
        // ⛔ 关数据源才能把卡在 socket 读上的线程踢出来（见 currentSource 的注释）。
        runCatching { currentSource?.close() }
        t?.let { runCatching { it.join(JOIN_TIMEOUT_MS) } }
        synchronized(startLock) { thread = null }
    }

    /**
     * 告诉预取器「播放头跳到这儿了」，让它跟着走。
     *
     * **只往前锚**：往回跳时已经下好的那段（在播放头前方）仍然有用，
     * 靠循环里「领先太多就等播放头追上来」自然处理；往前跳到预取前沿之外
     * 则必须跟过去，否则会继续下用户刚跳过的那一段。
     *
     * 由**主线程**调用（跳转回调里）。可以随便多调 —— 位置没越过前沿
     * 就是空操作。
     */
    fun reanchor(positionBytes: Long) {
        if (cancelled) return
        if (positionBytes <= 0L) return
        if (positionBytes <= nextPositionBytes) return
        pendingAnchorBytes = positionBytes
        // 打断正在写的那一块：不打断的话，得等它写完（最多 12 秒）才会看新锚点，
        // 而这段时间播放头前方一个字节都下不动。
        runCatching { currentWriter?.cancel() }
        runCatching { currentSource?.close() }
        restartIfIdle()
    }

    /**
     * 「有待处理锚点、但线程已经收工」⇒ 把预取重新拉起来。
     *
     * ⛔ 必须**串在 [startLock] 里判**：[reanchor] 与线程收工的 `finally`
     *    都可能看到这个状态，各判各的就会同时拉起两条线程（见 [startLock]）。
     */
    private fun restartIfIdle() {
        synchronized(startLock) {
            if (cancelled) return
            if (pendingAnchorBytes <= 0L) return
            if (!finished) return
            finished = false
            thread = null
            Log.i(TAG, "预取线程已收工且有待处理跳转 ⇒ 重新拉起")
            start()
        }
    }

    private fun loop() {
        Log.i(
            TAG,
            "预取器启动：起点 ${nextPositionBytes / 1048576} MiB · " +
                "分块 ${CHUNK_BYTES / 1048576} MiB · 领先上限 ${maxLeadBytes / 1048576} MiB",
        )
        while (!cancelled) {
            // ── 用户跳转 ⇒ 重新锚定 ────────────────────────────────
            // ⛔ 必须放在「到文件末尾」与「领先太多」两道判断**之前**：
            //    跳转后的新位置可能正好越过 EOF 判断用的旧 frontier，
            //    也可能让 `lead` 变成负数（播放头跑到前沿前面去了）。
            //    先把锚点落实，后面两道的读数才是新的。
            val anchor = pendingAnchorBytes
            if (anchor > 0L) {
                pendingAnchorBytes = -1L
                if (anchor > nextPositionBytes) {
                    Log.i(
                        TAG,
                        "预取重新锚定：${nextPositionBytes / 1048576} → " +
                            "${anchor / 1048576} MiB（用户跳转，丢弃被打断的那一块）",
                    )
                    nextPositionBytes = anchor
                }
            }
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
                // ⛔ 分清「我们主动打断」和「真失败」：
                //    主动打断（[reanchor] 关掉了数据源）不该退避 2 秒 ——
                //    那等于让用户跳转后白白多等 2 秒才开始下新位置。
                //    这里什么都不做，循环回到顶部就会消费新锚点。
                if (pendingAnchorBytes > 0L) {
                    Log.i(TAG, "预取第 ${chunks + 1} 块被跳转打断，改从新位置继续")
                } else {
                    // ⛔ 单块失败**不退出**：夸克偶发 4xx/断流很常见，
                    //    重试同一块即可（CacheWriter 内部走的是 ParallelRangeReader，
                    //    它自己已经做了断点续传与重试）。这里只做退避。
                    Log.w(
                        TAG,
                        "预取第 ${chunks + 1} 块失败（${from / 1048576} MiB 起，" +
                            "${length / 1048576} MiB）：${e.message} —— 2 秒后重试",
                    )
                    if (!sleep(RETRY_BACKOFF_MS)) return
                }
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
        // ⛔ 等待也要能被**跳转**提前打断：否则用户拖完进度条最多要等
        //    1 秒（WAIT_SLICE）／2 秒（退避）才轮到新位置开始下。
        while (left > 0 && !cancelled && pendingAnchorBytes <= 0L) {
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
