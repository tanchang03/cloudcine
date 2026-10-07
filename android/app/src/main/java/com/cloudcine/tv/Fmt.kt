package com.cloudcine.tv

import java.util.Calendar
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

    // ------------------------------------------------------------------
    // 时间（两份「文件列表」共用 —— 与 PC 端 `format.dart` 同口径）
    // ------------------------------------------------------------------

    /**
     * 相对时间：`刚刚` / `3 分钟前` / `2 天前` / `2026-09-01`。
     *
     * ## 为什么列表里显示相对时间
     *
     * 这份列表要回答的是「新不新」，不是「精确到分是哪一刻」。完整时刻
     * （[dateTimeMinute]）比很多文件名还长，印进那一列会喧宾夺主。
     * 与 PC 端 `formatRelativeTime` 逐条一致 —— 一处写 `3 天前`、另一处写
     * `2026-10-03 16:41`，用户会以为是两个不同的字段。
     *
     * ⛔ 超过 30 天退回**日期**而不是继续说「N 个月前」：月份长度不定，
     *    「2 个月前」在 1 月 31 日与 3 月 1 日差一天却差两个字。
     * ⛔ [nowMs] 由调用方给，是为了让这个纯函数能被单测。
     */
    fun relativeTime(ms: Long, nowMs: Long): String {
        if (ms <= 0L) return "—"
        val diffSec = (nowMs - ms) / 1000
        if (diffSec < 0) return "刚刚"
        if (diffSec < 60) return "刚刚"
        val min = diffSec / 60
        if (min < 60) return "$min 分钟前"
        val hour = min / 60
        if (hour < 24) return "$hour 小时前"
        val day = hour / 24
        if (day < 30) return "$day 天前"
        return dateOnly(ms)
    }

    /** 精确到分钟的时刻：`2026-10-03 16:41`。 */
    fun dateTimeMinute(ms: Long): String {
        if (ms <= 0L) return "—"
        val c = cal
        c.timeInMillis = ms
        return String.format(
            Locale.US,
            "%04d-%02d-%02d %02d:%02d",
            c.get(Calendar.YEAR),
            c.get(Calendar.MONTH) + 1,
            c.get(Calendar.DAY_OF_MONTH),
            c.get(Calendar.HOUR_OF_DAY),
            c.get(Calendar.MINUTE),
        )
    }

    /** `2026-09-01`。只在 [relativeTime] 超过 30 天时给。 */
    private fun dateOnly(ms: Long): String {
        val c = cal
        c.timeInMillis = ms
        return String.format(
            Locale.US, "%04d-%02d-%02d",
            c.get(Calendar.YEAR),
            c.get(Calendar.MONTH) + 1,
            c.get(Calendar.DAY_OF_MONTH),
        )
    }

    /**
     * 复用的日历实例 —— **单线程用**（这两个函数只在主线程上被调用）。
     *
     * ⛔ 不每次 new：`Calendar.getInstance()` 要读时区数据库，在 `getView`
     *    里每行调一次就是几十次，而这份列表一屏有十几行、滚动时每行都要重画。
     * ⛔ **每次使用前先 `timeInMillis = ms`**：这个 getter 故意在每次取用时
     *    把实例重置回 epoch，所以绝不能直接 `cal.get(...)`，一定要先设值再读。
     */
    private val cal: Calendar = Calendar.getInstance()
        get() {
            field.timeInMillis = 0 // 占位，真正的值由调用方 setTimeInMillis
            return field
        }
}
