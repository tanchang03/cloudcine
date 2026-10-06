package com.cloudcine.tv

import android.os.SystemClock
import java.util.ArrayDeque

/**
 * 把「累计已下载字节」变成「当前下载速率（字节/秒）」。
 *
 * ## 为什么要自己算，而不直接用 `BandwidthMeter.getBitrateEstimate()`
 *
 * `DefaultBandwidthMeter` 给的是一个**加权滑动平均**的**带宽估计**，不是
 * 「此刻在下载多少」。它有两个问题：
 *   - 数值偏乐观：它取的是历史样本的最大值方向，缓冲区已经填满、网络已经
 *     停下来的时候，它仍然报着上一次的高值 —— 于是「缓冲中」那行会一直
 *     显示一个假的快速度。
 *   - 单位是 bit/s，而用户看的是 MB/s，来回换容易出错。
 *
 * 这里改用**累计字节数的差分**：只要把「到现在为止一共下载了多少字节」
 * 丢进来，[ratePerSec] 就能用最近 [windowMs] 窗口内的增量算出真实速率。
 *
 * ⛔ **窗口里没有新字节时必须回落到 0**，不能保留上一次的读数。做法是每次
 * [ratePerSec] 都补一个「到此刻为止还是这么多字节」的采样点，于是窗口的
 * 分子不变、分母变大，速率自然衰减到 0。这正是「卡住不动」和「在下载」
 * 的区分点 —— 也是用户要看的那个数。
 *
 * ⚠️ 只在**主线程**用（ExoPlayer 的 analytics 回调与 View 的 ticker 都在主
 * 线程），所以没有加锁。别挪到后台线程去调。
 */
class NetRateMeter(private val windowMs: Long = 1_500L) {

    /** 采样时间戳（`elapsedRealtime`），与 [bytes] 一一对应。 */
    private val times = ArrayDeque<Long>()
    private val bytes = ArrayDeque<Long>()

    /** 最后一次见到的累计字节数。 */
    private var latestBytes = 0L

    /**
     * 喂一个**累计**字节数。
     *
     * ⛔ 换片/换档后 ExoPlayer 的计数器会**归零**，这时要整体重置而不是当成
     * 负数增量 —— 否则会出现一个巨大的负速率，界面上闪一下就没，很难查。
     */
    fun onCumulativeBytes(total: Long) {
        if (total < latestBytes) {
            reset()
        }
        latestBytes = total
        push(SystemClock.elapsedRealtime(), total)
    }

    /** 当前速率（字节/秒）。无数据、或窗口内零字节时返回 0。 */
    fun ratePerSec(): Long {
        val now = SystemClock.elapsedRealtime()
        push(now, latestBytes)
        if (times.size < 2) return 0
        val dt = times.last() - times.first()
        if (dt <= 0) return 0
        val db = bytes.last() - bytes.first()
        return if (db <= 0) 0 else db * 1000 / dt
    }

    fun reset() {
        times.clear()
        bytes.clear()
        latestBytes = 0L
    }

    private fun push(t: Long, b: Long) {
        times.addLast(t)
        bytes.addLast(b)
        // 至少留两点，否则窗口被清空后永远算不出速率。
        while (times.size > 2 && t - times.first() > windowMs) {
            times.removeFirst()
            bytes.removeFirst()
        }
    }
}
