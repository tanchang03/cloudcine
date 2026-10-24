package com.cloudcine.tv.library

import com.cloudcine.tv.pan.formatSize

/**
 * 多选删除里的**一个**目标（文件或目录）。
 *
 * 与 [DriveDeleteTarget] 同形，但**不复用**：那个是「这一条」的单选路径用的，
 * 它的文档与文案都建立在「只有一个」上；混用会让「目录连带子树」那句警告
 * 在批量语境下读起来像在说某一条。
 */
data class DriveBatchTarget(
    val fid: String,
    val name: String,
    val isDir: Boolean,
    /** 网盘给的体积；**目录一律当 0**（夸克列目录不给目录体积）。 */
    val sizeBytes: Long = 0,
)

/**
 * 「要删掉这 N 个网盘条目吗」—— 文案与判据（纯值对象，可 JVM 单测）。
 *
 * ## 与单选那一份的差别，只有「多了哪几句话」
 *
 * 单选（[DriveDeletePlan]）说三件事：不可撤销 / 目录连带 / 媒体库牵连。
 * 批量必须再加一句 **[listing]** —— **删的是哪几项**。
 *
 * ⛔ 这一句不能省。单选的标题里就有名字（「要删除「S01E07.mkv」吗？」），
 *    批量如果只写「要删除这 7 项吗」，用户手上没有任何东西能核对「我勾的
 *    是不是我以为的那七个」。多选态下光标只停在**一行**上，其余六行是靠
 *    ☑ 记着的，而电视上离得远、勾选角标又小。
 *
 * ## ⛔ 顺序也是固定的
 *
 * [title] → [listing] → [irreversible] → [folderWarning] → [freedLabel]
 * → [libraryLine]：先「删什么」、再「删哪几个」、然后「能不能回来」、
 * 「连带什么」、「腾多少」、「库里几条」。与单选同一套决策顺序。
 */
data class DriveBatchDeletePlan(
    val targets: List<DriveBatchTarget>,
    /** 网盘显示名（「夸克网盘」/「百度网盘」），用在不可撤销那句里。 */
    val providerName: String,
    /** 这些条目在媒体库里一共有几条索引行；`0` = 都没入库。 */
    val libraryItems: Int = 0,
) {
    val count: Int get() = targets.size
    val dirCount: Int get() = targets.count { it.isDir }
    val fileCount: Int get() = count - dirCount

    /**
     * 选中项里**已知**的总体积（只算文件）。
     *
     * ⛔ 目录的体积网盘不给，所以它永远不进这个数 —— 把它当 0 加进去不会出错，
     *    但会让人误以为「目录不要空间」。
     */
    val knownBytes: Long
        get() = targets.filter { !it.isDir }.sumOf { it.sizeBytes.coerceAtLeast(0L) }

    /** 对话框标题。写成问句，与 [confirmLabel] 区分开。 */
    val title: String
        get() = if (dirCount > 0) {
            "要删除这 $count 项吗？（$fileCount 个文件 · $dirCount 个目录）"
        } else {
            "要删除这 $count 项吗？（$fileCount 个文件）"
        }

    /**
     * 删的是哪几项 —— **最多列三个**，多的用「…等 N 项」收尾。
     *
     * ⛔ 上限不是排版洁癖：电视上这段字一多，菜单卡片就会顶到屏幕外，
     *    而确认框里的档位是**不能滚**的（滚了就分不清「我在选第几档」）。
     *    三个名字足够用户认出「这是我刚勾的那一批」。
     */
    val listing: String
        get() {
            if (targets.isEmpty()) return ""
            val head = targets.take(LIST_LIMIT).joinToString("、") { "「${it.name}」" }
            return if (targets.size > LIST_LIMIT) {
                "$head…等 $count 项"
            } else {
                head
            }
        }

    /** 不可逆警告。**这条不能省，也不能改软**。 */
    val irreversible: String
        get() = "删除后不可撤销：$providerName 侧按永久删除处理，本应用无法恢复。"

    /** 含目录才有的一句；全是文件时返回 `null`。 */
    val folderWarning: String?
        get() = if (dirCount <= 0) {
            null
        } else if (dirCount == 1) {
            "其中 1 个目录会连同里面的全部文件一起删掉（这里不会逐个列出来）。"
        } else {
            "其中 $dirCount 个目录会连同里面的全部文件一起删掉（这里不会逐个列出来）。"
        }

    /**
     * 「能腾出多少」。
     *
     * ⛔ 三种说法对应三种**事实**：有目录时不能说「释放约 X」（X 只是文件那部分，
     *    而目录里往往才是大头）；一个体积都没拿到时说「释放 0 B」会被读成
     *    「删了也没用」。
     */
    val freedLabel: String
        get() = when {
            knownBytes <= 0L -> "释放空间未知（网盘没提供这些项的体积）"
            dirCount > 0 -> "选中的文件合计约 ${formatSize(knownBytes)}；目录里的体积网盘不给，不计入。"
            else -> "释放约 ${formatSize(knownBytes)}"
        }

    /** 媒体库那一句。`0` 条时也要说 —— 否则用户会以为「库里那份还在」。 */
    val libraryLine: String
        get() = if (libraryItems <= 0) {
            "媒体库里没有它们的索引（都没入库，或不是视频文件），这一侧不用清。"
        } else {
            "媒体库里有 $libraryItems 条索引指向它们，会一起清掉" +
                "（续播进度与播放偏好也随之没了）。"
        }

    /** 确认按钮。带项数 + 「不可撤销」：按钮是最后一眼看到的东西。 */
    val confirmLabel: String get() = "删除这 $count 项（不可撤销）"

    /** 确认框整段正文（Activity 一行调用，顺序在类文档里）。 */
    val body: String
        get() = listOfNotNull(title, listing, irreversible, folderWarning, freedLabel, libraryLine)
            .joinToString("\n")

    /**
     * 结果提示。
     *
     * ⛔ 三个数缺一不可（删掉几项 / 失败几项 / 媒体库清掉几条）：只说成功的话
     *    用户以为网盘上干净了，而失败的那几项原样还在；只说失败的话，又像是
     *    一次都没动。
     * ⛔ 一项都没删掉时**不能说成删掉了**。
     */
    fun resultMessage(deleted: Int, failed: Int, libraryRemoved: Int, error: String?): String {
        if (deleted <= 0) {
            val why = error ?: "网盘拒绝了删除请求"
            return "删除失败：$why —— 网盘上原样还在，媒体库未动"
        }
        val library = if (libraryRemoved > 0) {
            "，媒体库同步清掉 $libraryRemoved 条"
        } else {
            "（媒体库里本来就没有它们的索引）"
        }
        if (failed <= 0) return "已删除 $deleted 项$library"
        val why = error ?: "网盘拒绝了部分请求"
        return "已删除 $deleted 项 / $failed 项失败（$why）$library"
    }

    private companion object {
        /** 正文里最多列几个名字（见 [listing] 的注释）。 */
        const val LIST_LIMIT = 3
    }
}
