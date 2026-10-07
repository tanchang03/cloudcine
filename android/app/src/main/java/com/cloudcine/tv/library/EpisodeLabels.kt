package com.cloudcine.tv.library

/**
 * 「选集」列表里每一条怎么显示 —— **文件名 + 历史播放进度**。
 *
 * ## 用在哪
 *
 *   * 播放页 OSD 的「选集」行（`PlayerActivity.episodeRow`）；
 *   * **作品简介页的文件列表**（`LibraryActivity.ItemsAdapter`）—— 2026-10-07
 *     起也走这里，两边口径必须一致，改一处就是改两处。
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
 * 它是纯函数，所以可以直接单测（`EpisodeLabelsTest`）。
 */
object EpisodeLabels {

    /**
     * 认作「扩展名」的点后面最多几个字符。
     *
     * ⛔ 4，不是 5：真实视频扩展名最长 4 位（`mkv` / `mp4` / `webm` / `m2ts`），
     *    而 5 会把 `Mr. Robot` 这种「名字里带点、根本没扩展名」的文件砍成 `Mr`。
     */
    private const val MAX_EXT_LEN = 4

    /**
     * 主标题：**文件名**（去掉扩展名）。
     *
     * ⛔ 用文件名而不是 `item.displayTitle`：`displayTitle` 优先返回**作品标题**，
     *    于是整列都是同一句话（「黑亚当」），一个字的信息量都没有 ——
     *    2026-10-07 简介页就是这个症状。
     *
     * 与 PC 端 `baseNameOf` 同口径：砍掉**最后一个** `.` 之后的部分。
     * ⛔ 只砍最后一个点：`黑亚当.2022.S01E03.1080p.mkv` → `黑亚当.2022.S01E03.1080p`；
     *    按第一个点砍会砍成 `黑亚当`。
     * ⛔ 点后面超过 [MAX_EXT_LEN] 个字符就**不砍** —— 那多半是标题里本来就有的点
     *    （`Mr. Robot`），而不是扩展名。⚠️ 真实视频扩展名最长 4 位
     *    （`mkv` / `mp4` / `webm` / `m2ts`），所以这个门槛卡在 4 不会误伤；
     *    写成 5 的话 `Mr. Robot`（点后正好 5 位）会被砍成 `Mr`。
     */
    fun fileLabel(item: LibraryItem): String {
        val name = item.name
        val dot = name.lastIndexOf('.')
        if (dot <= 0 || name.length - dot - 1 > MAX_EXT_LEN) return name
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
     * 进度百分比：`62%`；**没有可算的进度时返回 `null`**。
     *
     * 用在作品简介页文件列表那一**列**（`LibraryActivity.ItemsAdapter`）。
     *
     * ⛔ 与 [progressFraction] 同源（读 `max_position_ms`）—— 列表里那个数字和
     *    播放页选集里那根进度条必须永远说同一件事，两处各算一次迟早会分叉。
     * ⛔ 看了一点点（不足 0.5%，四舍五入会变成 `0%`）写成 **`<1%`**：
     *    写成 `0%` 的话，用户再也分不出「点开过一秒」和「一帧都没看过」——
     *    而后者这一列写的是 `—`（由调用方给，`null` 即没看过）。
     */
    fun progressPercent(item: LibraryItem): String? {
        val f = progressFraction(item) ?: return null
        val pct = kotlin.math.round(f * 100).toInt()
        return if (pct <= 0) "<1%" else "$pct%"
    }

    /**
     * 进度摘要：`12:34 / 45:00`（日志与 OSD 用；列表里画的是百分比那一列）。
     *
     * 只在**有历史进度**时给 —— `null` 时调用方不要写「看到 」这种半句话。
     *
     * ⛔ 与 [progressFraction] 一样要**钳到总时长**：`max_position_ms` 可能越过
     *    `duration_ms`（片尾曲 / 时长是探测来的），不钳的话界面上会出现
     *    「看到 50:00 / 45:00」这种一眼假的东西。
     */
    fun progressLabel(item: LibraryItem): String? {
        val at = item.maxPositionMs ?: return null
        if (at <= 0L) return null
        val total = item.durationMs ?: return null
        if (total <= 0L) return null
        return "${clock(at.coerceAtMost(total))} / ${clock(total)}"
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
