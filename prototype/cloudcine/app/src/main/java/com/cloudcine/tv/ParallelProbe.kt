package com.cloudcine.tv

import android.util.Log

/**
 * 用**与播放同构**的多连接去量一次真实带宽。
 *
 * ## 为什么必须换成这个（旧探测是错的）
 *
 * 旧探测走 [com.cloudcine.tv.pan.PanHttp.probeThroughput]：**单连接**、`maxBytes=12 MiB`
 * / `maxMillis=2000`。电视上实测它量到 **`12.00 MiB / 1.97s = 6.08 MiB/s`**，
 * 于是判「原画（需 3.67 MiB/s）余量 40%」→ 选原画 → 播 1 分钟后掉到 **1021 KB/s**
 * → 一直卡。
 *
 * 错在两点，缺一不可：
 *   1. **连接数不对**：夸克按**连接**限速（单连接稳态 1016~1022 KB/s，波动 <0.3%；
 *      8 连接 120s 稳态 8.03 MiB/s）。用 1 条连接量到的数，与播放实际会用几条
 *      完全无关 —— 除非播放也只用 1 条。
 *   2. **窗口落在突发里**：新连接前约 10 秒能跑 2.26~2.89 MiB/s，之后掉到 1.01。
 *      2 秒的窗口**从头到尾都在突发段内**，量到的是上界不是稳态。
 *
 * 所以这里直接复用 [ParallelRangeReader] —— **探测与播放是同一条代码路径、
 * 同一个连接数**，量到的数就是播放能拿到的数（唯一差别是窗口短，仍偏乐观，
 * 所以 [com.cloudcine.tv.PlayerActivity.chooseQuality] 里那 30% 余量继续留着）。
 *
 * ## 为什么不把窗口拉长到「看到拐点」
 *
 * 拐点在**约 114 秒**（实测：首帧 14:36:15 → 14:38:06 全速 → 14:38:09 掉到
 * 1021 KB/s）。让用户起播前干等两分钟不可接受。于是改用**结构性判据**：
 * 只要连接数 = 播放连接数，N 条连接的稳态下限就是 `N × 1.0 MiB/s`
 * （每条连接的限速是硬的），突发只会让它更高 ⇒ **不会低估**。
 * 剩下的「高估」由 30% 余量吸收。
 */
object ParallelProbe {

    private const val TAG = "CloudCine"

    /** 一次探测的读数。 */
    data class Result(
        val mibPerSec: Double,
        val bytes: Long,
        val millis: Long,
        val connections: Int,
        /** 探测期间是否出过错（出错时读数偏小，调用方应保守处理）。 */
        val failed: Boolean,
        val stats: String,
    ) {
        override fun toString(): String =
            "%.2f MiB / %.2fs = %.2f MiB/s（%d 连接）".format(
                bytes / 1048576.0,
                millis / 1000.0,
                mibPerSec,
                connections,
            )
    }

    /**
     * 量一次。
     *
     * ⛔ **必须在后台线程调用**（内部是阻塞读）。调用方统一走
     * `Bg.run { ... }`。
     *
     * @param maxBytes 最多读这么多字节（也是 Range 的上限）。默认 12 MiB：
     *                 8 连接 × 1 MiB/块 = 12 块，恰好能把 8 条连接都喂上活。
     * @param maxMillis 时间上限。默认 3 秒 —— 8 MiB/s 时 12 MiB 只需 1.5s，
     *                  3 秒是给「网速更差」留的余量，不是常态等待时间。
     * @param chunkBytes 探测用的小块。⛔ 故意比播放的 2 MiB 小：探测只要
     *                  「每条连接都动起来」，块小 ⇒ 更快铺满 8 条连接。
     */
    fun measure(
        url: String,
        headers: Map<String, String>,
        connections: Int,
        maxBytes: Long = 12L * 1024 * 1024,
        maxMillis: Long = 3_000,
        chunkBytes: Int = 1 * 1024 * 1024,
        connectTimeoutMs: Int = StreamSpec.DEFAULT_TIMEOUT_MS,
        readTimeoutMs: Int = StreamSpec.DEFAULT_TIMEOUT_MS,
    ): Result {
        val n = connections.coerceAtLeast(1)
        val reader = ParallelRangeReader(
            url = url,
            headers = headers,
            base = 0L,
            limit = maxBytes - 1,
            connections = n,
            chunkBytes = chunkBytes,
            connectTimeoutMs = connectTimeoutMs,
            readTimeoutMs = readTimeoutMs,
        )
        reader.start()

        val buf = ByteArray(256 * 1024)
        var got = 0L
        var err: String? = null
        val t0 = System.currentTimeMillis()
        try {
            while (got < maxBytes) {
                val k = reader.read(buf, 0, buf.size)
                if (k < 0) break
                got += k
                if (System.currentTimeMillis() - t0 > maxMillis) break
            }
        } catch (e: Exception) {
            err = e.message
            Log.w(TAG, "并行带宽探测中断：$err")
        } finally {
            reader.close()
        }

        val dt = (System.currentTimeMillis() - t0).coerceAtLeast(1)
        val used = reader.connectionsUsed
        val r = Result(
            mibPerSec = (got / 1048576.0) / (dt / 1000.0),
            bytes = got,
            millis = dt,
            connections = used,
            failed = err != null,
            stats = reader.statsLine(),
        )
        Log.i(TAG, "★ 并行带宽探测：$r${if (err == null) "" else "（中断：$err）"} · ${r.stats}")
        return r
    }
}
