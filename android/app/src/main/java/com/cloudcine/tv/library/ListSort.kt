package com.cloudcine.tv.library

import com.cloudcine.tv.pan.DriveEntry

/**
 * 两份「文件列表」的排序 —— 与 PC 端 `lib/domain/services/item_sort.dart`
 * 和 `folder_sort.dart` **逐条同口径**。
 *
 * ## 哪两份列表
 *
 *   1. **媒体库里某部作品的文件列表**（`LibraryActivity` 的「文件列表」）；
 *   2. **网盘目录浏览**（`BrowseActivity`）。
 *
 * ⛔ 两处的**边界口径必须一致**，否则同一个网盘在同一台机器上会排出两种顺序：
 *
 *   * `modifiedAtMs` 为 `null` 的条目**垫底**（两个方向都垫底）；
 *   * 时间**完全相同**的两条按名称自然序定序（网盘对一次批量上传只给到秒）。
 *
 * 所以两条比较函数都委托给同一个 [compareByModifiedTime]，而不是各写一份。
 */
object ListSort {

    // ------------------------------------------------------------------
    // 自然序（“第2期” 在 “第10期” 前面）
    // ------------------------------------------------------------------

    /**
     * 自然序比较：名字里的**连续数字段按数值比**，其余按字符比。
     *
     * ⛔ 不能用 `String.compareTo`：目录里全是 `第2期` / `第10期` / `S01` / `S10`
     *    这种名字，逐字符比较会把 `第10期` 排在 `第2期` **前面**（`'1' < '2'`），
     *    而用户扫一眼列表时按的正是数字顺序。
     *
     * 三条口径（与 PC 端 `naturalCompare` 一致）：
     *   * **大小写不敏感** —— 否则大写会整批挤到前面；
     *   * **前导零不影响数值** —— `007` 与 `7` 数值相等；
     *   * **位数多的更大** —— 按字符串长度比而不是解析成 `Long`，避免超长
     *     数字段溢出（文件名里的数字段长度是不受控的）。
     */
    fun naturalCompare(a: String, b: String): Int {
        val la = a.lowercase()
        val lb = b.lowercase()
        var i = 0
        var j = 0
        while (i < la.length && j < lb.length) {
            val ca = la[i].code
            val cb = lb[j].code
            val digitA = isAsciiDigit(ca)
            val digitB = isAsciiDigit(cb)

            if (digitA && digitB) {
                // 前导零：先各自跳过，`007` 与 `7` 才能比出「相等」而不是位数不同。
                var startA = i
                var startB = j
                while (startA < la.length && la[startA].code == 0x30) startA++
                while (startB < lb.length && lb[startB].code == 0x30) startB++
                var endA = startA
                var endB = startB
                while (endA < la.length && isAsciiDigit(la[endA].code)) endA++
                while (endB < lb.length && isAsciiDigit(lb[endB].code)) endB++

                val lenA = endA - startA
                val lenB = endB - startB
                if (lenA != lenB) return lenA - lenB
                for (k in 0 until lenA) {
                    val d = la[startA + k].code - lb[startB + k].code
                    if (d != 0) return d
                }
                // 数值相同（`7` vs `007`）就往后看 —— 后面还有内容。
                i = endA
                j = endB
                continue
            }

            if (ca != cb) return ca - cb
            i++
            j++
        }

        val rest = (la.length - i) - (lb.length - j)
        if (rest != 0) return rest

        // 小写后完全一样（`ABC` vs `abc`）：用原串定序，否则两个不同的名字会被
        // 排成「相等」，而排序不保证稳定 ⇒ 列表每次重建都可能换位置。
        return a.compareTo(b)
    }

    private fun isAsciiDigit(code: Int): Boolean = code in 0x30..0x39

    // ------------------------------------------------------------------
    // 边界口径（两份列表共用）
    // ------------------------------------------------------------------

    /**
     * 按修改时间比较两条。**两份列表共用这一份**，理由见类注释。
     *
     * @param descending 只翻转**时间**那一项：`null` 垫底与同名定序在两个方向
     *   上一致 —— 「网盘没给时间」是「不知道」，不是「最旧」；把它排到正序的
     *   第一行会造出一堆假装很旧的条目。
     */
    fun compareByModifiedTime(
        aTime: Long?,
        bTime: Long?,
        aName: String,
        bName: String,
        descending: Boolean,
    ): Int {
        // 时间未知的**垫底**，与海报墙的 `Sort.recentModified` 同一口径。
        // 把它们当成 1970 年排到最前面的话，第一屏会变成一堆「不知道什么时候
        // 传的」条目 —— 而用户点这个排序正是想先看最新的。
        if (aTime == null && bTime == null) return naturalCompare(aName, bName)
        if (aTime == null) return 1
        if (bTime == null) return -1

        val byTime = if (descending) bTime.compareTo(aTime) else aTime.compareTo(bTime)
        if (byTime != 0) return byTime

        // 同一时刻必须再用名字定序。网盘对「一次批量上传」给出的时间戳精度只到
        // 秒，整批会撞在同一个值上；不定序的话它们的相对位置取决于排序算法的
        // 内部行为，**每次重新列目录都可能换位置** —— 用户看到的是「列表在乱跳」，
        // 而且找不到任何原因。
        return naturalCompare(aName, bName)
    }
}

/**
 * 作品下「文件列表」的排序方式。
 *
 * ## 为什么是「三档」而不是「一个方向开关」
 *
 * 这份列表**原本只有一种顺序** —— `itemsForWork` 排好的「季 → 部 → 集 → 名称」。
 * 加了按时间排之后，如果只给「正序 / 倒序」两个选项，就等于**把原有的剧集顺序
 * 弄丢了**：看剧时最常用的动作（顺着集号往下看）会变成「每次进来都得先手动
 * 切一次排序」。所以 [EPISODE_ORDER] 是一个**真正的选项**，而不是「没排序」。
 */
enum class ItemSortMode(val label: String) {

    /** 季 → 部 → 集 → 名称。**沿用仓储层排好的顺序**，这里不重排。 */
    EPISODE_ORDER("剧集顺序"),

    /** 按网盘修改时间**倒序**（新 → 旧）。**默认**。 */
    MODIFIED_DESC("修改时间倒序"),

    /** 按网盘修改时间**正序**（旧 → 新）。 */
    MODIFIED_ASC("修改时间正序"),
    ;

    /**
     * 存进设置库的稳定字符串 = **枚举名本身**（与 PC 端 `ItemSortMode.value`
     * 同一口径）。
     *
     * ⚠️ 改它等于让已经存下来的设置**静默失效**（读不懂就退回默认），
     *    用户只会觉得「我设的排序自己变回去了」，不会有任何报错。
     */
    val value: String get() = name

    companion object {
        /**
         * 从设置里读到的值还原；读不懂一律退回 [MODIFIED_DESC]（默认值）。
         *
         * ⛔ **不要**在这里抛异常：一个坏掉的设置值不该让详情页打不开。
         */
        fun parse(raw: String?): ItemSortMode =
            entries.firstOrNull { it.value == raw } ?: MODIFIED_DESC
    }
}

/**
 * 按 [mode] 排一组条目，返回**新列表**（不动入参）。
 *
 * ⛔ [ItemSortMode.EPISODE_ORDER] 是「原样返回」而不是重排一遍：
 *    「季 → 部 → 集 → 名称」这条规则的**唯一实现**在 `LibraryDb.itemsForWork`。
 *    这里再排一次就等于抄了第二份 —— 两处一旦分叉，会出现「列表第一行不是
 *    第 1 集」这种对不上的情况，而且不报错。
 */
fun sortItems(items: List<LibraryItem>, mode: ItemSortMode): List<LibraryItem> {
    if (mode == ItemSortMode.EPISODE_ORDER) return items.toList()
    val descending = mode == ItemSortMode.MODIFIED_DESC
    return items.sortedWith { a, b ->
        ListSort.compareByModifiedTime(a.modifiedAtMs, b.modifiedAtMs, a.name, b.name, descending)
    }
}

/**
 * 网盘**目录视图**的排序方式。
 *
 * 默认 [MODIFIED_TIME]（倒序）：目录视图存在的意义就是回答「我新传的东西在哪」，
 * 所以默认把最新的排在第一行 —— 名称升序要一直翻到最后才看得见刚传的片子，
 * 那正是用户最想第一眼看到的东西。
 */
enum class FolderSortMode(val label: String) {

    /** 按修改时间**倒序**（新 → 旧）。**默认**。 */
    MODIFIED_TIME("修改时间"),

    /** 按名称**自然序**升序（`第2期` 在 `第10期` 前面）。 */
    FILE_NAME("名称"),
    ;

    /** 存进设置库的稳定字符串 = 枚举名本身，见 [ItemSortMode.value]。 */
    val value: String get() = name

    companion object {
        /** 读不懂一律退回 [MODIFIED_TIME]（默认值）。 */
        fun parse(raw: String?): FolderSortMode =
            entries.firstOrNull { it.value == raw } ?: MODIFIED_TIME
    }
}

/**
 * 网盘给的修改时间（毫秒）；**没给（`<= 0`）时返回 `null`**。
 *
 * ⛔ 夸克对少数条目不下发 `updated_at`，`PanApi` 里那个字段就落成 0。
 *    把 0 当成一个真实时刻会把它排到 **1970 年**（正序第一条），
 *    而正确的语义是「不知道」—— 见 `ListSort.compareByModifiedTime` 的
 *    「null 垫底」那一段。
 */
private fun DriveEntry.modifiedMsOrNull(): Long? = updatedAtMs.takeIf { it > 0 }

/** 两条网盘条目之间的比较。 */
fun compareEntries(a: DriveEntry, b: DriveEntry, mode: FolderSortMode): Int = when (mode) {
    FolderSortMode.FILE_NAME -> ListSort.naturalCompare(a.name, b.name)
    FolderSortMode.MODIFIED_TIME -> ListSort.compareByModifiedTime(
        aTime = a.modifiedMsOrNull(),
        bTime = b.modifiedMsOrNull(),
        aName = a.name,
        bName = b.name,
        descending = true,
    )
}

/**
 * 一层目录的内容：**目录在前、视频居中、其它文件在后**，三组内部各自按 [mode] 排。
 *
 * ## 组间顺序为什么是「结构」而不是「顺序」
 *
 * 目录永远在前与排序模式无关：用户按修改时间找片子时，仍然要先能一眼看到
 * 有哪些子目录可以进；把子目录冲散到列表各处，等于把「导航」这件事弄丢了。
 *
 * 其它文件（字幕 / 图片 / 文档 / 压缩包…）永远垫底：它们是**附属物** ——
 * 同一个目录里往往一部片子配 3 条字幕 + 2 张图，混进视频里会把
 * 「这一层有几部片子」这件事冲散。
 */
fun sortListing(
    all: List<DriveEntry>,
    mode: FolderSortMode,
): List<DriveEntry> {
    val folders = ArrayList<DriveEntry>()
    val videos = ArrayList<DriveEntry>()
    val others = ArrayList<DriveEntry>()
    for (e in all) when {
        e.isDir -> folders.add(e)
        e.isVideo -> videos.add(e)
        else -> others.add(e)
    }
    val cmp = Comparator<DriveEntry> { a, b -> compareEntries(a, b, mode) }
    return ArrayList<DriveEntry>(all.size).apply {
        addAll(folders.sortedWith(cmp))
        addAll(videos.sortedWith(cmp))
        addAll(others.sortedWith(cmp))
    }
}
