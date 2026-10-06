package com.cloudcine.tv.library

/**
 * 「选集」列表里每一条怎么显示 —— **文件名 + 历史播放进度**。
 *
 * ## ⛔ 为什么主标题是文件名、不是「第 N 集」
 *
 * 2026-10-06 用户原话：「选集中不要显示第x个，太难看，直接显示网盘文件名 +
 * 最大播放历史进度」。两条理由都成立：
 *
 *   1. **集号只在少数条目上真实存在**。`episode` 没解析出来时只能退化成
 *      「第 N 个」—— 那是**下标**，而列表里混着花絮 / 预告 / 多版本，
 *      按下标编号会把「第 13 集」这个名字送给一条 40 秒的预告片。
 *   2. **文件名才是唯一不会说谎的标识**。它同时回答「哪一集」和「哪个版本」
 *      （`1080p` / `WEB-DL` / 压制组），而集号连第二个问题都答不了。
 *
 * ## ⛔ 为什么进度读 `max_position_ms` 而不是 `resume_position_ms`
 *
 * 这是 PC 端 `saveMaxPosition` 与 `saveResumePosition` 的分工（详见那两个方法
 * 的注释），别弄反：
 *
 * | 列 | 回答什么 | 会不会被清 |
 * |---|---|---|
 * | `max_position_ms` | 「这一集看过没有 / 看到哪儿了」 | **永不回退、永不清除** |
 * | `resume_position_ms` | 「下次从哪儿接着播」 | 看完就清成 NULL |
 *
 * 用续播点画进度的话，**看完的一集会显示成 0%** —— 正是 PC 端注释里点名的
 * 那个后果。所以这里读 `max_position_ms`。
 *
 * 它是纯函数，所以可以直接单测。
 */
object EpisodeLabels {

    /**
     * 主标题：**文件名**（去掉扩展名）。
     *
     * ⛔ 用文件名而不是 `item.displayTitle`：`displayTitle` 优先返回**作品标题**，
     *    于是整列都是同一句话（「黑亚当」），一个字的信息量都没有。
     *
     * 与 PC 端 `baseNameOf` 同口径：砍掉**最后一个** `.` 之后的部分。
     * ⛔ 只砍最后一个点：`黑亚当.2022.S01E03.1080p.mkv` → `黑亚当.2022.S01E03.1080p`；
     *    按第一个点砍会砍成 `黑亚当`。
     * ⛔ 点后面超过 5 个字符就**不砍**（那多半是标题里本来就有的点，
     *    比如 `Mr. Robot`）—— PC 端 `baseNameOf` 用的是同一条长度判据。
     */
    fun fileLabel(item: LibraryItem): String {
        val name = item.name
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || name.length - dot - 1 > 5) return name
        return name.substring(0, dot)
    }

    /**
     * 历史进度占全片的比例（`0.0~1.0`）；**没有可画的进度时返回 `null`**。
     *
     * ⛔ `null` 与 `0.0` 必须分开：没有进度该把进度条**藏起来**，而不是画一条
     *    空的槽（一整列空槽看着像「全都卡在加载中」）。
     * ⛔ 超过 1.0 要钳住 —— 时长是刮削/探测来的，片尾曲会让 position 越过 duration。
     */
    fun progressFraction(item: LibraryItem): Double? {
        val at = item.maxPositionMs ?: return null
        if (at <= 0L) return null
        val total = item.durationMs ?: return null
        if (total <= 0L) return null
        return (at.toDouble() / total.toDouble()).coerceIn(0.0, 1.0)
    }

    /**
     * 进度摘要：`12:34 / 45:00`（日志用；界面上画的是进度条）。
     *
     * 只在**有历史进度**时给。
     */
    fun progressLabel(item: LibraryItem): String? {
        val at = item.maxPositionMs ?: return null
        if (at <= 0L) return null
        val total = item.durationMs ?: return null
        if (total <= 0L) return null
        return "${clock(at)} / ${clock(total)}"
    }

    /** `1:02:03` / `02:03` —— 与 PC 端 `tvClockLabel` 同口径。 */
    private fun clock(ms: Long): String {
        val total = ms / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) {
            "%d:%02d:%02d".format(h, m, s)
        } else {
            "%02d:%02d".format(m, s)
        }
    }
}
