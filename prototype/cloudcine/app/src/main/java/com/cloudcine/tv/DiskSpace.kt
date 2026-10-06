package com.cloudcine.tv

/**
 * 磁盘缓存该占多少：**看设备当下有多少空闲，而不是写死一个数**。
 *
 * ## 为什么不能写死
 *
 * 同一个 APK 要装到各种电视上：有的 8G 存储、有的 32G，有的用户塞满了
 * 网盘下载、有的几乎空着。写死「6 GB 缓存」在 8G 机上直接把系统撑爆，
 * 在 32G 机上又浪费。
 *
 * 实测这台电视（2026-10-06）：
 * ```
 * /dev/block/mmcblk0p37  20G  8.3G  12G  42%  /data
 * 连续写速 131.6 MB/s（200MB/1.593s）—— 写盘不是瓶颈，空间才是
 * ```
 *
 * ## 规则（三层约束取最小）
 *
 * 1. **先扣掉 [MIN_FREE_BYTES]** —— 这是给系统和其他 App 的**绝对余量**，
 *    不是比例。存储快满时 Android 会开始杀后台、写不进日志，比缓存失效严重。
 * 2. 剩下的**只吃 [USABLE_FRACTION]**（一半）—— 留出播放期间系统自己增长的空间。
 * 3. 再封顶 [HARD_MAX_BYTES]。
 *
 * 算下来这台电视是 5 GB ≈ **23 分钟原画**（3.67 MiB/s）。
 * ⛔ 别指望「整集缓存」：整集原画 22.82 GiB，而全盘可用只有 12 GB ——
 * 物理上装不下，只能是滚动缓存。
 *
 * ⛔ 算出来小于 [MIN_USABLE_BYTES] 时**返回 0（直接关掉缓存）**，
 * 而不是给个很小的值：几百 MB 的缓存连一次回拖都兜不住，
 * 白写盘、白占空间，还让人以为「开了缓存怎么还卡」。
 */
object DiskSpace {

    /** 缓存硬上限：再空也不许多占。 */
    const val HARD_MAX_BYTES = 6L * 1024 * 1024 * 1024

    /**
     * 必须留给系统的绝对空闲量。
     *
     * 2 GB 是经验值：这台电视系统可用内存只有 2.5 GB、系统分区本身还在
     * 长日志，留 2 GB 是「不会因为缓存把系统逼到低存储告警」的下限。
     */
    const val MIN_FREE_BYTES = 2L * 1024 * 1024 * 1024

    /** 扣掉 [MIN_FREE_BYTES] 之后，再按这个比例取用。 */
    const val USABLE_FRACTION = 0.5

    /**
     * 低于这个量就别开缓存了。
     *
     * 512 MiB 是「至少能兜住一次回拖」的量级（原画 3.67 MiB/s ≈ 2.3 分钟）。
     */
    const val MIN_USABLE_BYTES = 512L * 1024 * 1024

    /**
     * 按设备可用空间算缓存上限（字节）。
     *
     * @param availableBytes `StatFs.availableBytes`；**读不到时传负数**，
     *   这里返回 0（关掉缓存）—— 读不到就当作「不知道有多少空间」，
     *   不该赌。
     * @param hardMaxBytes 覆盖硬上限（单测与将来的「省空间模式」用）
     * @return 可用的缓存字节数；**0 表示不要开缓存**
     */
    fun cacheLimitBytes(availableBytes: Long, hardMaxBytes: Long = HARD_MAX_BYTES): Long {
        if (availableBytes <= 0) return 0
        val spare = availableBytes - MIN_FREE_BYTES
        if (spare <= 0) return 0
        val usable = (spare * USABLE_FRACTION).toLong()
        if (usable < MIN_USABLE_BYTES) return 0
        return minOf(usable, hardMaxBytes)
    }
}
