package com.cloudcine.tv.library

/**
 * 作品简介页（Android TV）的**纯格式化**。
 *
 * ## 为什么这些字符串要搬出 Activity
 *
 * 它们每一条都是**与 PC 端对齐的口径**：
 *
 *   * 「已刮削」的判据是 `source == 'online'`，**不是**「有海报」；
 *   * 季数的门槛是 `>= 2`（电影和单季剧不显示「1 季」）；
 *   * 元数据行的顺序、类型最多显示几个。
 *
 * 写错任何一条都**不会报错** —— 表现只是「页面上少了一个词」或者
 * 「明明刮过却写着未刮削」，真机上拿眼睛看才发现。而
 * [com.cloudcine.tv.LibraryActivity] 里的东西在 JVM 单测里跑不起来，
 * 所以口径必须落在能测的纯函数里（与 [PlayTarget] / [PosterNaming] 同一套做法）。
 */
object WorkDetailFormat {

    /** 类型最多显示几个。⛔ 多了这一行会折成两排，把简介正文挤掉。 */
    const val MAX_GENRES = 4

    /**
     * 元数据行：`2024 · 2 季 · 12 集 · 剧集 · ★ 8.7 · 已刮削 · 剧情/犯罪`。
     *
     * ⛔ 顺序照 PC 端 `work_detail_page.dart` 的 `_InfoColumn` chip 行
     *    （年份 → 评分 → 来源 → 类型），把「季 / 集数」插在年份后面 ——
     *    电视上比 PC 更需要一眼看到「这部剧有多少集」。
     * ⛔ 这一行**永远不会是空串**：分类（认不出来时兜底「其他」）与来源
     *    （「已刮削 / 未刮削」）两项恒在，与 PC 端那两枚 chip 恒在一致。
     *    调用方因此不需要判空。
     */
    fun metaLine(w: Work): String {
        val parts = ArrayList<String>(MAX_GENRES + 4)
        w.year?.takeIf { it > 0 }?.let { parts.add("$it") }
        if (w.seasonCount >= 2) parts.add("${w.seasonCount} 季")
        if (w.itemCount > 0) {
            parts.add(if (w.kind == "episode") "${w.itemCount} 集" else "${w.itemCount} 个文件")
        }
        parts.add(MediaCategoryNames.label(w.category))
        w.rating?.takeIf { it > 0 }?.let { parts.add("★ %.1f".format(it)) }
        parts.add(if (w.source == "online") "已刮削" else "未刮削")
        if (w.genres.isNotEmpty()) parts.add(w.genres.take(MAX_GENRES).joinToString("/"))
        return parts.joinToString(" · ")
    }

    /**
     * 「原名」那一行要不要画。
     *
     * ⛔ 判据照 PC 端 `_InfoColumn`：`originalTitle != work.title`。
     *    中文片名没刮到时两者会一模一样，那时画出来就是同一行字印两遍。
     */
    fun originalLine(w: Work): String? =
        w.originalTitle?.takeIf { it.isNotBlank() && it != w.title }

    /** 简介正文。压平空白（源里常带换行与连续空格），空则 `null`。 */
    fun overviewText(w: Work): String? =
        w.overview?.replace(Regex("\\s+"), " ")?.trim()?.takeIf { it.isNotEmpty() }

    /** 播放胶囊的文案。有续播进度时是「▶ 续播」，否则「▶ 播放」。 */
    fun playLabel(resumable: Boolean): String = if (resumable) "▶ 续播" else "▶ 播放"

    /**
     * 动作胶囊的**文案 + 可用性**（`Pair(文案, 可用)`，不含动作本身）。
     *
     * ⛔ 顺序与 [com.cloudcine.tv.LibraryActivity.buildDetailActions] **必须**
     *    逐项一致 —— 光标位置就是按这个下标存的，顺序错了就是「点了 A 执行 B」。
     * ⛔ 库里一条可播文件都没有时，播放 / 选集**置灰而不是从列表里消失**：
     *    用户最需要看到的恰恰是一个灰着的按钮加上一句解释；按钮凭空消失
     *    他只会以为这个页面坏了。
     * ⛔ 「选集（N）」里的 N 是**这一部作品下的文件数**（= 列表行数），
     *    不是季数、也不是集数 —— 列表里花絮/样片也在，用户按 ↓ 能看到的
     *    就是 N 行。
     */
    fun actionLabels(resumable: Boolean, itemCount: Int): List<Pair<String, Boolean>> =
        listOf(
            playLabel(resumable) to (itemCount > 0),
            "手动刮削" to true,
            "刮削设置" to true,
            "选集（$itemCount）" to (itemCount > 0),
        )
}
