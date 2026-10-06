package com.cloudcine.tv

import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * 把 [ParallelRangeReader] 包成 Media3 的 [DataSource]。
 *
 * 上层（`DefaultMediaSourceFactory` / `Extractor`）拿到的仍是一个普通的
 * 顺序字节流 —— **它完全不知道底下开了几条连接**。
 *
 * ## 为什么连接数是 `() -> Int` 而不是 `Int`
 *
 * 播放器是**建一次、长期复用**的（换档走 `setMediaItem`，不重建 ExoPlayer），
 * 而 `DataSource.Factory` 是在建播放器时就交出去的。想让「连接数」在菜单里
 * 改完立刻生效，Factory 就必须**在每次 `open()` 时现读**。
 *
 * ## 为什么 `open()` 先 `close()`
 *
 * Media3 约定一个 DataSource 实例同一时刻只服务一次 load；但它**可能**在没
 * 调 `close()` 的情况下再次 `open()`（`DefaultHttpDataSource` 就是这么防的）。
 * 不先关掉旧的，上一轮的 N 条连接会变成**幽灵线程**继续吃带宽 —— 换档几次
 * 之后速率读数会莫名其妙地翻倍，很难查。
 */
class ParallelRangeDataSource(
    private val defaultHeaders: Map<String, String>,
    private val connections: () -> Int,
    private val chunkBytes: Int,
    private val connectTimeoutMs: Int,
    private val readTimeoutMs: Int,
) : DataSource {

    private var reader: ParallelRangeReader? = null
    private var uri: Uri? = null

    override fun open(dataSpec: DataSpec): Long {
        close()
        val n = connections().coerceAtLeast(1)
        val base = dataSpec.position
        // ⛔ `DataSpec.length` 是**长度**，不是终点。终点（含）= base + length - 1。
        //    少减这个 1 会让最后一块多要一个字节 ⇒ 上游 416 ⇒ 被当成 EOF，
        //    文件正好短 1 字节，末帧解码失败。
        // ⛔ `C.LENGTH_UNSET` 是 **Int**（-1），而 `dataSpec.length` 是 **Long** ——
        //    直接 `==` 编不过，必须 `.toLong()`。
        val knownLength = dataSpec.length != C.LENGTH_UNSET.toLong()
        val limit = if (knownLength) base + dataSpec.length - 1 else -1L

        val h = LinkedHashMap<String, String>(defaultHeaders)
        h.putAll(dataSpec.httpRequestHeaders)

        reader = ParallelRangeReader(
            url = dataSpec.uri.toString(),
            headers = h,
            base = base,
            limit = limit,
            connections = n,
            chunkBytes = chunkBytes,
            connectTimeoutMs = connectTimeoutMs,
            readTimeoutMs = readTimeoutMs,
        ).also { it.start() }
        uri = dataSpec.uri
        Log.i(
            TAG,
            "并行源打开：pos=$base len=${if (knownLength) dataSpec.length.toString() else "未知"}" +
                " 连接=$n 每块=${chunkBytes / 1024}KiB",
        )
        return dataSpec.length
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        reader?.read(buffer, offset, length) ?: -1

    override fun getUri(): Uri? = uri

    override fun getResponseHeaders(): Map<String, List<String>> = emptyMap()

    /** 本源不发 transfer 事件：速率由外层 [CountingDataSourceFactory] 数 `read()`。 */
    override fun addTransferListener(transferListener: TransferListener) = Unit

    override fun close() {
        reader?.close()
        reader = null
    }

    companion object {
        private const val TAG = "CloudCine"
    }
}

/**
 * 造 [ParallelRangeDataSource]。
 *
 * @param headers     默认请求头（Cookie / UA / Referer）。`DataSpec` 里自带的优先。
 * @param connections 连接数**取值器**（见 [ParallelRangeDataSource] 的类注释）。
 * @param chunkBytes  每块字节数。⛔ 别往大调：它同时是**单槽缓冲的大小**，
 *                    窗口内存 = `connections × chunkBytes`。
 *                    8 × 2 MiB = 16 MiB，在本机 192 MiB 的 Java 堆里和
 *                    ExoPlayer 自己要的 48 MiB 能共存。
 */
class ParallelRangeDataSourceFactory(
    private val headers: Map<String, String>,
    private val connections: () -> Int,
    private val chunkBytes: Int = DEFAULT_CHUNK_BYTES,
    private val connectTimeoutMs: Int = DEFAULT_TIMEOUT_MS,
    private val readTimeoutMs: Int = DEFAULT_TIMEOUT_MS,
) : DataSource.Factory {

    override fun createDataSource(): DataSource = ParallelRangeDataSource(
        defaultHeaders = headers,
        connections = connections,
        chunkBytes = chunkBytes,
        connectTimeoutMs = connectTimeoutMs,
        readTimeoutMs = readTimeoutMs,
    )

    companion object {
        /**
         * 2 MiB。选它的理由：
         *   * 8 × 2 MiB = **16 MiB** 窗口，对 192 MiB 堆友好；
         *   * 每连接 1 MiB/s 时一块要 2 秒 —— 与主工程回归测试里那条
         *     「首字节预算」同量级（`chunkSize / 0.6MiB < 5000ms`）；
         *   * 首字节延迟与它**无关**（边收边发），所以没必要为延迟调小。
         */
        const val DEFAULT_CHUNK_BYTES = 2 * 1024 * 1024

        /** 与 [StreamSpec.DEFAULT_TIMEOUT_MS] 一致（Media3 默认值，故意沿用）。 */
        const val DEFAULT_TIMEOUT_MS = StreamSpec.DEFAULT_TIMEOUT_MS
    }
}
