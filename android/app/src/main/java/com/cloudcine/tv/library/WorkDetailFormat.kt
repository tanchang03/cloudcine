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
     *
     * ## 五颗的排布，以及「追剧」为什么在**第 2 位**
     *
     * ```
     * [▶ 播放] [☆ 追剧] [手动刮削] [刮削设置] [选集（N）]
     * ```
     *
     * ⚠️ 设计文档 §5.2(d) 写的是「新增第 5 颗」，字面读是**追加到末尾**。
     *    这里**有意偏离**，理由是「选集」必须留在最后：
     *
     *   * 「选集」不是一个动作，而是**把光标交给下面那张列表**（`focusItemsList`）
     *     —— 它是这一行的**出口**。后面再挂一颗开关，用户按 → 走过出口又回到
     *     一个动作上，方向感就断了。
     *   * 电视上这一行只有一屏宽，末尾那颗要按四次 → 才够得着。而「追剧」是
     *     这个功能的**主入口**，把它埋在刮削那两颗后面是本末倒置。
     *
     * 两处（这里 + `buildDetailActions`）仍然必须同序 —— 偏离的只是位置，
     * 不是「两处要一起改」这条规矩。
     */
    fun actionLabels(
        resumable: Boolean,
        itemCount: Int,
        followed: Boolean = false,
        newCount: Int = 0,
    ): List<Pair<String, Boolean>> =
        listOf(
            playLabel(resumable) to (itemCount > 0),
            followLabel(followed, newCount) to true,
            "手动刮削" to true,
            "刮削设置" to true,
            "选集（$itemCount）" to (itemCount > 0),
        )

    // ------------------------------------------------------------------
    // 追剧（schema v17）
    // ------------------------------------------------------------------

    /**
     * 「追剧」那颗动作胶囊的文案。
     *
     * ⛔ **已追剧时也返回文案**（而不是空串）：胶囊要**置灰不消失**（红线）。
     *    与「▶ 播放」在没文件时置灰是同一条规矩 —— 一个凭空消失的按钮，
     *    用户只会以为这个页面坏了。
     *
     * ⛔ `newCount > 0` 时缀上「· N 新」：用户点开简介页最常见的目的就是
     *    「看看更新了什么」，把数字印在按钮上省掉一次点进去再退出来的往返。
     *    但**只在已追剧时缀** —— 没追的剧 `new_item_count` 恒为 0，
     *    那时写「· 0 新」是噪音。
     */
    fun followLabel(followed: Boolean, newCount: Int): String = when {
        !followed -> "☆ 追剧"
        newCount > 0 -> "★ 已追剧 · $newCount 新"
        else -> "★ 已追剧"
    }

    /**
     * 剧集行行首的「新集」前缀；不是新集时是**空串**。
     *
     * ⛔ 空串而不是 `null`：调用方要拿它去拼 `SpannableString`，
     *    `null` 会让「拼前缀」和「不拼」分成两个分支，而这两个分支的
     *    区别只有一处 —— 拆开写迟早只改一边。
     *
     * ⛔ 「■」是**实心方块**（U+25A0），不是「▍」那种半高块：电视上
     *    18sp 的半高块只剩一条细线，与「不描边、靠实心面明度」的整套
     *    视觉语言也不一致。
     *
     * ⛔ 判据**不在这里** —— 它由 `Work.isNewSinceFollow(item)` 给
     *    （`first_seen_at > follow_started_at` ∧ 从没播过）。这里只负责
     *    「怎么说」，与 [metaLine] 同一分工。
     */
    fun newEpisodePrefix(isNew: Boolean): String = if (isNew) "■ NEW  " else ""
}
