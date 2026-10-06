package com.cloudcine.tv

/**
 * 缓冲额度怎么分：**前向 + 后向共用一份字节预算**，后缓冲只许占其中一小块。
 *
 * ## 为什么需要这个文件（2026-10-06 实测）
 *
 * ExoPlayer 的 `DefaultLoadControl` 有两套互不相干的单位：
 * - `setTargetBufferBytes(n)` —— **字节**上限，管的是 `DefaultAllocator` 里
 *   那些 `new byte[]`，也就是**前向与后向一起**算（`getTotalBytesAllocated()`）。
 * - `setBackBuffer(ms, retain)` —— **秒**数，管后缓冲保留多久。
 *
 * 两边单位不同，写死秒数就必然在某个码率上失衡。实测这台电视：
 * 预算 48 MiB，而后缓冲写的是 30 秒 ——
 * 超清档（0.31 MiB/s）只要 9 MiB，放得下；
 * **原画档（3.67 MiB/s）却要 110 MiB，是预算的 2.3 倍**。
 *
 * 后果不是「后缓冲小一点」，而是**前向被饿死**：
 * - 播放中：前向只剩 2~7s，速率呈锯齿（`15.35 → 0.98 → 3.00 → 12.79 → 0 MB/s`）；
 * - **暂停时**：播放头不动 ⇒ 后缓冲样本永不回收 ⇒ 分配器恒满 ⇒
 *   `shouldContinueLoading` 恒 false ⇒ **一个字节都不读**。
 *   用户看到的就是「暂停之后不缓冲了」。
 *
 * ## 规则
 *
 * 后缓冲**最多占预算的 [BACK_BUFFER_FRACTION]**，秒数由当前码率反算 ——
 * 于是前向在任何码率下都稳拿剩下的 3/4，秒数自动伸缩。
 *
 * ⛔ 别用 `setPrioritizeTimeOverSizeThresholds(true)` 去「按秒保住」后缓冲：
 * 那个开关的字面意思就是**允许突破字节上限**，而字节上限正是 10-04
 * `OutOfMemoryError` 崩溃的护栏。它是不许动的红线。
 */
object BufferPlan {

    /** 后缓冲最多占字节预算的比例。剩下的给前向。 */
    const val BACK_BUFFER_FRACTION = 0.25

    /**
     * 后缓冲时长下限：2 秒。
     *
     * 再小就等于关掉后缓冲（任何回拖都要重下）；2 秒是「回拖一两次
     * 不用重下」与「别占太多额度」的折中。
     */
    const val MIN_BACK_BUFFER_MS = 2_000L

    /**
     * 后缓冲时长上限：30 秒。
     *
     * 只对低码率档生效（超清档算出来 ≈ 39s，钳到 30s）——
     * 那种档位下 30s 媒体才 9 MiB，预算富余。
     */
    const val MAX_BACK_BUFFER_MS = 30_000L

    /**
     * 拿不到档位码率时假设的值（MiB/s），取原画量级。
     *
     * 宁可让后缓冲**偏小**：偏小的代价是「回拖几秒要重下」，
     * 偏大的代价是「前向饿死、暂停后一个字节都不读」—— 后者严重得多。
     */
    const val ASSUMED_BITRATE_MIBPS = 3.0

    /**
     * 按字节预算与码率反算后缓冲时长（毫秒），钳在 [MIN_BACK_BUFFER_MS, MAX_BACK_BUFFER_MS]。
     *
     * @param bufferBytes [com.cloudcine.tv.PlayerActivity.startPlayer] 里按堆算出的总预算
     *   （`min(heap/4, 64MiB)`，这台电视是 48 MiB）
     * @param bitrateMibps 当前档位码率（MiB/s）。**0 / 负数 / NaN / 无穷都退回
     *   [ASSUMED_BITRATE_MIBPS]**，不抛异常 —— 这条路径上「播放器起不来」比
     *   「后缓冲小几秒」严重得多。
     */
    fun backBufferMs(bufferBytes: Long, bitrateMibps: Double): Int {
        val budgetMiB = bufferBytes * BACK_BUFFER_FRACTION / 1048576.0
        val rate = bitrateMibps.takeIf { it.isFinite() && it > 0.0 } ?: ASSUMED_BITRATE_MIBPS
        val ms = (budgetMiB / rate * 1000.0).toLong()
        return ms.coerceIn(MIN_BACK_BUFFER_MS, MAX_BACK_BUFFER_MS).toInt()
    }
}
