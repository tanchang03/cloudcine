package com.cloudcine.tv.library

/**
 * 「这一条文件已经不在网盘上了」—— 播放页回来后问用户要不要从媒体库移除它。
 *
 * 与 PC 端 `MissingMediaPlan` / `MissingMediaDialog` 同一个场景（那边是播放失败
 * 弹窗，这边是**回执**：播放页只把「哪个 fid 没了」带回来，问话留在媒体库页），
 * 但**范围刻意更窄**：
 *
 * ## 为什么只给「移除这一条」，不给「移除整部」
 *
 * PC 那个弹窗要用户二选一（这一集 / 整部），因为它在播放页上、用户刚刚才被
 * 打断。电视这边不一样：用户是**退回媒体库之后**才被问的，眼前就是这部剧的
 * 文件列表 —— 他能看见「还有 23 集在」。这时候再给一个「移除整部」的选项，
 * 等于把一次误触变成灾难（PC 端那个弹窗的文档里也写着同一句话）。
 *
 * ⛔ 所以这里**不出现**「整部」这个词，也不出现任何数量选项。
 *
 * ## 为什么必须说「只影响这台电视上的索引」
 *
 * 用户对「移除」的预期是「文件也没了」。这一条的文件本来就已经没了，所以那句话
 * 在这里更要说 —— 否则他会以为这个按钮会去网盘上再删一次。
 */
data class MissingMediaPlan(
    /** 那一条文件的显示名（`LibraryItem.displayTitle`）。 */
    val fileName: String,
    /** 它属于哪一部作品。 */
    val workTitle: String,
    /** 同一部作品里**除它之外**还剩几条；`0` = 它是最后一条。 */
    val remainingItems: Int,
) {
    /** 标题。把文件名放在最前：用户刚从播放页回来，认得的是那个文件名。 */
    val title: String get() = "「$fileName」已经不在网盘上了"

    /** 正文。说清「为什么问」+「点了会发生什么」。 */
    val detail: String
        get() = "它可能被删掉了或移走了，所以播不了。" +
            "要把这一条的索引从媒体库移除吗？只影响这台电视上的索引，" +
            "网盘那边不会再删任何东西。"

    /**
     * 「其余几集还在」/「这是最后一条」。
     *
     * ⛔ 两条必须分开写：最后一条被移除之后，整部作品会从作品墙上消失
     *    （`purgeDriveEntry` 会删掉变空的作品行）。不提前说，用户会以为
     *    「我只删了一集，怎么整部都没了」。
     */
    val remainingLine: String
        get() = if (remainingItems > 0) {
            "同一部作品还有 $remainingItems 条会留在库里。"
        } else {
            "这是《$workTitle》的最后一条，移除之后它也会从作品墙上消失。"
        }

    /** 确认按钮。写「这一条」而不是「移除」：范围是用户最该核对的东西。 */
    val confirmLabel: String get() = "移除这一条"

    /**
     * 确认框的整段正文（标题 + 原因 + 后果）。
     *
     * ⛔ 三句必须**一起**出现。只给 [title] 的话，用户知道「文件没了」，但不知道
     *    「点下去只动这台电视」；只给 [detail] 的话，他连是哪个文件都不知道。
     *    合成一个字符串是为了让 `MissingMediaPlanTest` 能钉住「三句都在」，
     *    而不是靠人在电视上读一遍。
     */
    val body: String get() = "$title\n$detail\n$remainingLine"

    /**
     * 确认框的档位。**顺序是红线**：`showOverlay` 的光标从第 0 档开始，
     * 取消排第一 ⇒ 用户按 OK 什么都不会发生（与 `RemovalPlan.labels` 同一条）。
     */
    fun labels(): List<String> = listOf(CANCEL, confirmLabel)

    /** 结果提示。 */
    fun doneMessage(removed: Int): String = if (removed > 0) {
        if (remainingItems > 0) {
            "已从媒体库移除「$fileName」（《$workTitle》还有 $remainingItems 条）"
        } else {
            "已从媒体库移除「$fileName」，《$workTitle》已从作品墙移除"
        }
    } else {
        "「$fileName」本来就不在媒体库里，没有可移除的"
    }

    companion object {
        /** 取消。排在第一位 ⇒ 光标默认停在它上面（见 [labels]）。 */
        const val CANCEL = "取消"
    }
}
