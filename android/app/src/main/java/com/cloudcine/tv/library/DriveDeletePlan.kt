package com.cloudcine.tv.library

import com.cloudcine.tv.pan.formatSize

/**
 * 要删掉的那**一个**网盘条目（文件或目录）。
 *
 * 与 `DriveEntry` 分开写：那个是列目录的模型（还带着缩略图地址、宽高、父 fid
 * 等一堆与删除无关的字段），而这里只需要「叫什么、是不是目录、多大」——
 * 收窄之后 `DriveDeletePlan` 才能在 JVM 单测里构造，不必造一个假的网盘条目。
 */
data class DriveDeleteTarget(
    val fid: String,
    val name: String,
    val isDir: Boolean,
    /** 网盘给的体积；**目录一律当 0**（夸克列目录不给目录体积）。 */
    val sizeBytes: Long = 0,
)

/**
 * 「要删掉这一个网盘条目吗」—— 文案与判据（纯值对象，可 JVM 单测）。
 *
 * 与 PC 端 `DriveDeletePlan` / `DriveDeleteDialog` 同一套说法，只多了一句
 * **「媒体库里那几条会一起清掉」**（见 [libraryLine]）：电视端删完立刻重列，
 * 用户看不到「库里还留着死索引」这件事，所以必须在按下去之前说。
 *
 * ## 为什么三句话一句都不能少
 *
 *   1. **不可撤销**（[irreversible]）—— 用户对「删除」的预期常常是「进回收站，
 *      还能捞回来」，而这条路径是永久删除。写成「不可撤销」而不是「请确认」，
 *      是因为后者读起来像一句客套话；
 *   2. **目录连带整棵子树**（[folderWarning]）—— 用户以为自己在删「一个文件夹
 *      图标」，实际连里面几百 GB 的片子一起没了，而列表里只写着一个目录名；
 *   3. **媒体库里的索引也会走**（[libraryLine]）—— 不说的话，用户下次打开
 *      媒体库会看到一部点开就报错的死卡片，而他会以为是这个删除功能的 bug。
 *
 * ⛔ 顺序也是固定的：[title] → [irreversible] → [folderWarning] → [freedLabel]
 *    → [libraryLine]。用户就是按「删什么 → 能不能回来 → 连带什么 → 腾多少」
 *    这个顺序做决定的。
 */
data class DriveDeletePlan(
    val target: DriveDeleteTarget,
    /** 网盘显示名（「夸克网盘」/「百度网盘」），用在不可撤销那句里。 */
    val providerName: String,
    /** 这个条目在媒体库里有几条索引行；`0` = 没入库（或只是非视频文件）。 */
    val libraryItems: Int = 0,
) {
    /** 对话框标题。写成问句，与 [confirmLabel] 区分开（两处都写「删除」会重复）。 */
    val title: String get() = "要删除「${target.name}」吗？"

    /** 不可逆警告。**这条不能省，也不能改软**。 */
    val irreversible: String
        get() = "删除后不可撤销：$providerName 侧按永久删除处理，本应用无法恢复。"

    /** 目录才有的一句；文件返回 `null`。 */
    val folderWarning: String?
        get() = if (!target.isDir) {
            null
        } else {
            "整个目录会连同里面的全部文件一起删掉（这里不会逐个列出来）。"
        }

    /**
     * 「能腾出多少」。
     *
     * ⛔ 三种说法对应三种**事实**：目录的体积网盘不给，说成「释放 0 B」会被
     *    读成「删了也没用」；只有真的拿到文件大小时才敢写「约」。
     */
    val freedLabel: String
        get() = when {
            target.isDir || target.sizeBytes <= 0 ->
                "释放空间未知（网盘没提供这一项的体积）"
            else -> "释放约 ${formatSize(target.sizeBytes)}"
        }

    /** 媒体库那一句。`0` 条时也要说 —— 否则用户会以为「库里那份还在」。 */
    val libraryLine: String
        get() = if (libraryItems <= 0) {
            "媒体库里没有它的索引（没入库，或不是视频文件），这一侧不用清。"
        } else {
            "媒体库里有 $libraryItems 条索引指向它，会一起清掉" +
                "（续播进度与播放偏好也随之没了）。"
        }

    /** 确认按钮。带「不可撤销」而不是光写「删除」：按钮是最后一眼看到的东西。 */
    val confirmLabel: String get() = "删除（不可撤销）"

    /**
     * 结果提示。
     *
     * ⛔ 失败时**不能说成删掉了**：用户会以为网盘上已经没了，而它原样还在。
     * ⛔ 成功时要把媒体库那一侧的数字说出来 —— 那是这次操作的第二半，
     *    不说的话用户不知道库里清没清。
     */
    fun resultMessage(deleted: Int, libraryRemoved: Int, error: String?): String {
        if (deleted <= 0) {
            val why = error ?: "网盘拒绝了删除请求"
            return "删除失败：$why —— 网盘上原样还在，媒体库未动"
        }
        val head = "已删除「${target.name}」"
        return if (libraryRemoved > 0) {
            "$head，媒体库同步清掉 $libraryRemoved 条"
        } else {
            "$head（媒体库里本来就没有它的索引）"
        }
    }
}
