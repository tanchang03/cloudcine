package com.cloudcine.tv.library

/**
 * 「这批作品名下有几个网盘文件、几个删不了、几部是别名行」—— 一次统计的账。
 *
 * 与 PC 端 `DriveFileTally` + `LibraryBatchDeletePlan` 里那三个数字**同口径**：
 *
 *   * [deletable] —— 落在**可写**网盘（夸克）上的文件数，勾「一并删网盘」时
 *     被删掉的正是这些；
 *   * [undeletable] —— 落在**只读**网盘（百度）上的文件数，只能从媒体库移除；
 *   * [aliases] —— 勾选的这几部里有几部是**别名行**（`merged_into` 非空）。
 *
 * ## 为什么要在**弹窗之前**数清楚
 *
 * 电视端的确认框是一个菜单（取消 / 只移除索引 / 一并删除网盘文件），用户在
 * **按下去之前**必须看见「会删掉多少个文件」。不数的话，那一档只能写成
 * 「一并删除网盘文件」—— 用户没法判断这一下子会动 3 个还是 300 个，而它是
 * 不可逆的。
 *
 * ## 为什么收成纯值对象
 *
 * 数字与措辞各有几处容易写错的地方（下面每条都有注释），收在这里之后
 * `RemovalPlanTest` 能**不碰 SQLite、不碰 Activity** 地钉住它们 —— 这类错
 * 的形态是「看着很正常，但少说了一句关键的」，靠肉眼看电视界面发现不了。
 */
data class RemovalTally(
    val deletable: Int = 0,
    val undeletable: Int = 0,
    val aliases: Int = 0,
) {
    /** 名下有没有**能删**的文件 —— 决定「一并删除网盘文件」这一档出不出来。 */
    val hasDeletable: Boolean get() = deletable > 0

    companion object {
        /**
         * 从「(媒体项 id, provider)」列表里数出来。
         *
         * ⛔ **按 id 去重**：勾选里同时有别名行和它的目标作品时，同一集会被
         *    两次 `itemsForWork` 拿到（那是并集口径）。不去重的话「会删 N 个」
         *    会虚高，而用户没有任何办法核对。
         *
         * ⛔ provider 只认 [com.cloudcine.tv.pan.DriveProviders.QUARK] 为可删：
         *    百度在电视端是**只读**接入（`BaiduApi` 上没有删除方法），把它们
         *    算进 [deletable] 会让用户在弹窗上看见一个永远删不掉的数字。
         */
        fun of(
            files: Iterable<Pair<String, String>>,
            aliases: Int = 0,
            canDeleteProvider: (String) -> Boolean = { it == QUARK },
        ): RemovalTally {
            val seen = HashSet<String>()
            var deletable = 0
            var undeletable = 0
            for ((id, provider) in files) {
                if (!seen.add(id)) continue
                if (canDeleteProvider(provider)) deletable++ else undeletable++
            }
            return RemovalTally(deletable, undeletable, aliases)
        }

        private const val QUARK = "quark"
    }
}

/** 网盘那一侧的账。没勾「一并删网盘」时整个对象是 `null`，**不是** 0/0。 */
data class DriveRemoval(
    val deleted: Int,
    val failed: Int,
    val error: String? = null,
) {
    /** 一个文件都没碰到（名下没有可删的、或适配器缺失）。 */
    val isEmpty: Boolean get() = deleted == 0 && failed == 0
}

/**
 * 一次「从媒体库移除」的完整结果。
 *
 * ⛔ [drive] 为 `null` 与 `DriveRemoval(0, 0)` 是**两件事**：前者是「这次没
 *    打算删网盘」，提示里该说「网盘文件未动」；后者是「想删但一个都没匹配
 * 到」，说成「未动」会让用户以为自己的选择没生效。
 */
data class RemovalOutcome(
    val removedItems: Int,
    val drive: DriveRemoval? = null,
)

/**
 * 「从媒体库移除这批作品」的**档位与措辞** —— 与 PC 端
 * `LibraryBatchDeletePlan` 逐句对齐。
 *
 * ## 为什么单独一个对象，而不是把字符串写在 Activity 里
 *
 * 这条路径上最重的两句话都是**说错了不会报错**的那种：
 *
 *   1. 「网盘文件原样保留」—— 用户对「移除」的预期是「文件也没了」，
 *      必须把它说成一件好事；但**勾了一并删之后这句话就是假话**，不能同时出现；
 *   2. 「会删 N 个，不可撤销」—— 少这一句，用户按下去之后才发现，而那时
 *      已经没有回头路。
 *
 * 收在这里，`RemovalPlanTest` 就能逐句钉住；写在 Activity 里只能靠人在电视上
 * 一条条读。
 *
 * ## 电视端与 PC 端的形态差别（刻意保留）
 *
 * PC 用「默认关闭的复选框」，电视用「两档菜单」：遥控器上没有可靠的勾选控件，
 * 而**光标默认停在第一档**这件事正好是免费的「默认不删网盘」。所以
 * [labels] 的顺序是红线 —— 见那里的注释。
 */
object RemovalPlan {

    /** 只清索引那一档的按钮字。**必须**带上「网盘文件保留」。 */
    const val LABEL_LOCAL_ONLY = "只移除索引（网盘文件保留）"

    /** 取消。排在第一位 ⇒ 光标默认停在它上面（见 [labels]）。 */
    const val LABEL_CANCEL = "取消"

    /**
     * 确认框的正文。
     *
     * @param count 勾选的部数（单部删除时传 1）。
     * @param singleTitle 单部删除时那部作品的名字（`null` = 批量）。
     * @param canDeleteFromDrive 这次能不能真的删网盘。判据是
     *   **[RemovalTally.hasDeletable] && 夸克已登录** —— ⛔ **不是**「当前激活的
     *   网盘是不是夸克」：媒体库不按网盘分区，同一部作品可能横跨两家，而
     *   删除走的是夸克那一侧（`PanApi`），与用户此刻在文件列表里浏览哪一家无关。
     *
     * ⛔ [canDeleteFromDrive] 与 [RemovalTally.hasDeletable] 是两个判据，
     *    正文对三种组合各有一套说法（见下面三支）—— 只按其中一个分支写，
     *    就会出现「说会删、但档位没出来」或者「有文件可删却一个字都不提」。
     */
    fun title(
        count: Int,
        tally: RemovalTally,
        canDeleteFromDrive: Boolean,
        singleTitle: String? = null,
    ): String {
        val head = if (singleTitle != null) {
            "要从媒体库移除《$singleTitle》吗？"
        } else {
            "要从媒体库移除这 $count 部吗？"
        }
        val sb = StringBuilder(head)
        sb.append("\n只移除这台电视上的索引：作品、集数、播放进度都会没。")
        sb.append("\n网盘上的文件不受影响，之后「重新扫描」就能找回来。")

        // ① 能删：把「删多少 / 不可逆 / 本应用救不回来」一次说完。
        //    少任何一句，用户按下去之后才发现，而那时已经没有回头路。
        if (canDeleteFromDrive) {
            sb.append(
                "\n选「一并删除网盘文件」会把网盘上的 ${tally.deletable} 个文件永久删除，" +
                    "不可撤销，本应用也恢复不了。",
            )
        } else if (tally.hasDeletable) {
            // ② 有文件可删、但这次删不了（夸克没登录）。
            //    ⛔ 不能一声不响：用户会以为「这台电视不支持删网盘」，然后去
            //    文件列表里一个个手删。
            //    ⛔ 这里**不能说「当前网盘不支持删除」** —— 媒体库不是按网盘
            //    分区的（同一部作品可能横跨夸克与百度），能不能删只取决于
            //    「夸克登没登录」，与用户此刻在文件列表里看的是哪一家无关。
            //    把这两件事混在一起，就会出现「我在夸克的文件列表里明明能删，
            //    回到媒体库却说我不支持」这种自相矛盾（2026-10-24 现场）。
            sb.append(
                "\n这批作品在网盘上有 ${tally.deletable} 个文件，但夸克网盘没有登录，" +
                    "所以这次只能移除索引（登录夸克后可以一并删除）。",
            )
        }

        // ③ 只读网盘上的那几个：它们**怎么都删不掉**，必须单独说一句，
        //    否则用户会以为一并删之后网盘上就干净了。
        if (tally.undeletable > 0) {
            sb.append(
                "\n另有 ${tally.undeletable} 个文件在百度网盘上（只读），" +
                    "只会从媒体库移除，网盘上原样保留。",
            )
        }

        // ④ 别名行会跟着目标一起走 —— 界面上看不出这件事（`deleteWorks` 的口径）。
        if (tally.aliases > 0) {
            sb.append(
                if (tally.aliases == 1) {
                    "\n其中 1 部是合并出来的别名行，会连同目标作品一起移除。"
                } else {
                    "\n其中 ${tally.aliases} 部是合并出来的别名行，会连同各自的目标作品一起移除。"
                },
            )
        }
        return sb.toString()
    }

    /**
     * 确认框的档位。
     *
     * ⛔ **顺序是红线**：`showOverlay` 的 `overlayIndex` 从 0 开始，第一个
     *    非取消项就是光标默认落的那一档。把「一并删网盘」排在前面，等于让
     *    一次顺手确认永久删掉一季的片子。
     *
     * ⛔ 没有可删文件时**不给**这一档：一个按下去什么都不会发生的选项，
     *    比没有更糟（用户会以为网盘那侧也清了）。
     */
    fun labels(count: Int, tally: RemovalTally, canDeleteFromDrive: Boolean): List<String> {
        val out = ArrayList<String>(3)
        out.add(LABEL_CANCEL)
        out.add(LABEL_LOCAL_ONLY)
        if (canDeleteFromDrive) {
            out.add("一并删除网盘文件（${tally.deletable} 个，不可撤销）")
        }
        return out
    }

    /**
     * 结果提示。
     *
     * ⛔ 三个数字缺一不可（部数 / 文件行数 / 网盘成功与失败）：只说成功的话
     *    用户以为清干净了，而网盘上还占着几十 GB；只说失败的话，又像是一次
     *    都没动。不删网盘那一支**必须**保留「网盘文件未动」—— 它才是用户对
     *    「移除」这个词最需要被告知的一件事。
     */
    fun message(works: Int, outcome: RemovalOutcome): String {
        val files = if (outcome.removedItems == 1) "1 个文件" else "${outcome.removedItems} 个文件"
        val head = "已移除 $works 部（$files）"
        val drive = outcome.drive ?: return "$head，网盘文件未动"

        if (drive.isEmpty) {
            return "$head，但没有可删的网盘文件（可能已经不在网盘上了）"
        }
        if (drive.failed == 0) {
            return "$head，网盘上 ${drive.deleted} 个文件已删除"
        }
        val why = drive.error ?: "网盘拒绝了删除请求"
        if (drive.deleted == 0) {
            return "$head，但网盘文件一个都没删掉（$why）—— 重新扫描会再出现"
        }
        return "$head，网盘 ${drive.deleted} 个成功 / ${drive.failed} 个失败" +
            "（$why，可再试一次）"
    }
}
