package com.cloudcine.kuake

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.util.concurrent.atomic.AtomicLong

/**
 * 累计已下载字节数。
 *
 * ⛔ **为什么要自己数，而不是用 `AnalyticsListener.onBandwidthEstimate`**：
 *    那个回调只在**一次传输结束**时才发（`DefaultBandwidthMeter` 在
 *    `onTransferEnd` 里通知），渐进式 MP4 一次 load 能跑好几秒 —— 于是
 *    「缓冲中」那行大部分时间拿不到新样本，速率算出来是 0，界面上就只剩
 *    一个「缓冲中」。实测就是这个现象：**偶尔闪一下速率，绝大多数时间没有**。
 *
 * 数 `read()` 的返回值就没有这个问题：字节是**连续**进来的，1.5 秒窗口
 * 里一定有增量；而网络真的卡住时 `read()` 阻塞、增量归零，速率自然掉到 0。
 * 这正是用户要区分的两件事。
 *
 * 线程模型：`read()` 在 ExoPlayer 的 loader 线程，界面在主线程 ⇒ 用
 * [AtomicLong]（`@Volatile` 的 `+=` 不是原子操作，会丢字节）。
 */
class ByteCounter {
    private val total = AtomicLong(0)

    val bytes: Long get() = total.get()

    fun add(n: Int) {
        if (n > 0) total.addAndGet(n.toLong())
    }

    fun reset() {
        total.set(0)
    }
}

/**
 * 把任意 `DataSource.Factory` 包成「会数字节」的。
 *
 * 只包一层 `read()` 转发，**不改任何行为** —— 请求头、重定向、超时都还是
 * 原来那套。这一层存在的唯一理由就是给界面提供真实速率。
 */
class CountingDataSourceFactory(
    private val upstream: DataSource.Factory,
    private val counter: ByteCounter,
) : DataSource.Factory {
    override fun createDataSource(): DataSource =
        CountingDataSource(upstream.createDataSource(), counter)
}

private class CountingDataSource(
    private val upstream: DataSource,
    private val counter: ByteCounter,
) : DataSource {

    override fun addTransferListener(transferListener: TransferListener) =
        upstream.addTransferListener(transferListener)

    override fun open(dataSpec: DataSpec): Long = upstream.open(dataSpec)

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val n = upstream.read(buffer, offset, length)
        if (n > 0) counter.add(n)
        return n
    }

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() = upstream.close()
}
