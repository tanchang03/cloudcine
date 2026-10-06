package com.cloudcine.tv

import java.util.Locale

/**
 * 界面与日志共用的数字格式化。**纯函数，不碰 Android。**
 *
 * ## 为什么单独抽出来
 *
 * 贴底控制栏（[PlayerControlsView]）与调试浮层（[StatsOverlay]）都要写
 * 「时长 / 字节 / 速率」。两边各写一套必然漂移 —— 而这两个地方的字**会同时
 * 出现在同一屏上**（控制栏在底、浮层在左上），口径不一致（一个 `MiB`
 * 一个 `MB`、一个进位一个不进位）会被当成 bug 去追，浪费一轮排查。
 *
 * ## ⛔ 字节一律 1048576 进制
 *
 * 单位写 `GiB/MiB/KiB`。写成 `GB/MB` 会让人以为是 1000 进制，
 * 白送 4.8% 的错觉 —— 而这个项目里到处都在拿「3.67 MiB/s × 时长」
 * 与「48 MiB 缓冲预算」「5 GiB 缓存上限」对账，那 4.8% 会把账算歪。
 *
 * 唯一的例外是 [speed]：它沿用控制栏既有的 `MB/s` 文案（用户已经习惯看这个
 * 字了），但**换算基数仍是 1048576**。
 */
object Fmt {

    /** `mm:ss`；满一小时用 `h:mm:ss`。**负数一律当成「不知道」** ⇒ `--:--`。 */
    fun time(ms: Long): String {
        if (ms < 0) return "--:--"
        val t = ms / 1000
        val h = t / 3600
        val m = (t % 3600) / 60
        val s = t % 60
        return if (h > 0) {
            String.format(Locale.US, "%d:%02d:%02d", h, m, s)
        } else {
            String.format(Locale.US, "%02d:%02d", m, s)
        }
    }

    /**
     * 速率。`<= 0` 写 `0 KB/s`（**不写 `--`**：窗口内没有新字节就衰减到 0
     * 是这个读数要表达的语义，见 `NetRateMeter`）。
     */
    fun speed(bytesPerSec: Long): String = when {
        bytesPerSec <= 0 -> "0 KB/s"
        bytesPerSec >= 1L shl 20 -> "%.2f MB/s".format(bytesPerSec / 1048576.0)
        else -> "%.0f KB/s".format(bytesPerSec / 1024.0)
    }

    /** 字节量：`GiB` / `MiB` / `KiB`。 */
    fun bytes(b: Long): String = when {
        b <= 0L -> "0 B"
        b >= 1L shl 30 -> "%.2f GiB".format(b / 1073741824.0)
        b >= 1L shl 20 -> "%.0f MiB".format(b / 1048576.0)
        else -> "%.0f KiB".format(b / 1024.0)
    }

    /**
     * 取整到 MiB，给「`43/48 MiB`」这种**分子分母同单位**的写法用。
     *
     * ⛔ 别在这里顺手 `%.0f` 再拼 `MiB`：那样两处各格式化一次，
     *    一旦有人改了 [bytes] 的精度，分子分母就不同源了。
     */
    fun mib(b: Long): Long = b / 1048576
}
