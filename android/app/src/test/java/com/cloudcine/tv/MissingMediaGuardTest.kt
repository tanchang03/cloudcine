package com.cloudcine.tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「播放页发现文件没了 → 回媒体库问要不要清掉死索引」的**接线守卫**。
 *
 * 与 `BrowseDeleteGuardTest` / `LibraryBatchRemoveGuardTest` 同一套路：读源文件、
 * 剔注释、花括号配对，不引 Robolectric。
 *
 * ## 这条链路上「写了但不生效」的点
 *
 * 全都**不编译报错、不崩、日志干净**，只有坐到电视前走一遍才看得见：
 *
 *   1. 判据放宽（把网络失败也当「文件没了」）⇒ 一次误报清掉一条好索引；
 *   2. 播放页不带回执 ⇒ 用户永远看不到那个确认框；
 *   3. 媒体库页不读回执 ⇒ 同上；
 *   4. 库里本来就没有这一行却照样弹框 ⇒ 按下去什么都不发生；
 *   5. 清完不判断作品还在不在 ⇒ 停在一个「0 个文件」的空简介页上。
 */
class MissingMediaGuardTest {

    private val playerFile = File("src/main/java/com/cloudcine/tv/PlayerActivity.kt")
    private val libraryFile = File("src/main/java/com/cloudcine/tv/LibraryActivity.kt")
    private val panFile = File("src/main/java/com/cloudcine/tv/pan/PanApi.kt")

    /**
     * ⛔ 判据只能是 `notFound`。
     *
     * 取链失败有很多种（凭证失效 / 网络 / 限流 / 直链 4xx），它们的共同点是
     * **文件还在**。拿这种失败去问「要不要移除」，用户一点确认，一条好好的
     * 索引就没了 —— 而原因只是刚才断了一下网。
     */
    @Test
    fun `只把 notFound 当成文件没了`() {
        val code = codeOnly(readSource(playerFile))
        assertTrue(
            "`PlayerActivity` 里没有 `isMissingFile` 判据。",
            code.contains("private fun isMissingFile(err: Throwable)"),
        )
        assertTrue(
            "`isMissingFile` 不是「DriveException 且 notFound」：\n" +
                "放宽到 `needsReauth` / 网络失败，会把一次断网变成一条索引被清掉。",
            code.contains("err is DriveException && err.notFound"),
        )
        assertTrue(
            "`isMissingFile(` 必须被取链失败分支用上（`if (isMissingFile(`）。",
            code.contains("if (isMissingFile("),
        )
    }

    /** 夸克那一侧必须真的能产出 `notFound`，否则上面那条判据在夸克上永远为假。 */
    @Test
    fun `夸克在 404 时标 notFound`() {
        val code = codeOnly(readSource(panFile))
        val fn = braceBlock(code, "private fun ensureOk(res: PanResponse, what: String) {")
        assertTrue(
            "没能抽出 `ensureOk` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`ensureOk` 没有给 `ApiException` 传 `notFound`（`notFound = res.status == 404`）。\n" +
                "不传的话，夸克上的死索引永远走不到那个确认框 —— 而夸克是电视端的主力。",
            fn.contains("notFound = res.status == 404"),
        )
        assertFalse(
            "⛔ 不能把「业务码非 0」一律当 notFound：限流、签名失效都会被报成「文件被删了」。",
            fn.contains("notFound = true"),
        )
    }

    /**
     * 回执必须走**进程内的槽位**，不能挂在 `startActivityForResult` 上。
     *
     * 播放页是 `singleTask`：结果协议不保证留到用户退出那一刻（系统可能在
     * 起播时就回一个 `RESULT_CANCELED`）。挂在那条协议上的表现是「有时问、
     * 有时不问」，而且不报错。
     */
    @Test
    fun `播放页把死索引写进回执槽位`() {
        val code = codeOnly(readSource(playerFile))
        val fn = braceBlock(code, "private fun resolveAndPlay(fid: String) {")
        assertTrue(
            "没能抽出 `resolveAndPlay` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "失败分支里没有 `MissingReceipts.put(`：用户回到媒体库什么都不会被问。",
            fn.contains("MissingReceipts.put("),
        )
        assertTrue(
            "回执里没有带上 `groupKey`：媒体库页就算想问也拼不出「还剩几集」。",
            fn.contains("groupKey = "),
        )
        assertTrue(
            "`MissingReceipts.put(` 必须排在 `isMissingFile(` 之后（只有「文件没了」才留）。",
            fn.indexOf("isMissingFile(") in 0 until fn.indexOf("MissingReceipts.put("),
        )
        assertTrue(
            "取链成功时没有撤掉回执（`MissingReceipts.clear()`）。\n" +
                "换集时前一集可能已经报过「文件没了」，不撤的话用户会被问一个**已经能播的**文件。",
            fn.contains("MissingReceipts.clear()"),
        )
        assertFalse(
            "⛔ 不要再往 `setResult` 上挂：`singleTask` 的结果协议不可靠（见 `MissingReceipt`）。",
            fn.contains("setResult("),
        )
    }

    /** 媒体库页必须在 `onResume` 里消费回执。 */
    @Test
    fun `媒体库页在 onResume 里取回执并问话`() {
        val code = codeOnly(readSource(libraryFile))
        val fn = braceBlock(code, "override fun onResume() {")
        assertTrue(
            "没能抽出 `onResume` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`onResume` 里没有 `MissingReceipts.take()`。\n" +
                "播放页留下的回执没人取，那个确认框永远不会出现。",
            fn.contains("MissingReceipts.take()"),
        )
        assertTrue(
            "取到回执之后没有调 `confirmMissingItem(`。",
            fn.contains("confirmMissingItem("),
        )
        assertTrue(
            "`onResume` 里必须先调 `super.onResume()`。",
            fn.indexOf("super.onResume()") in 0 until fn.indexOf("MissingReceipts.take()"),
        )
    }

    /**
     * 先数、再问；库里没有这一行就**不弹**。
     *
     * ⛔ 弹一个「移除这一条」而按下去什么都不发生，是这个功能最容易被说成
     *    「时灵时不灵」的地方。
     */
    @Test
    fun `先核对再问且没有就不弹`() {
        val code = codeOnly(readSource(libraryFile))
        val fn = braceBlock(code, "private fun confirmMissingItem(receipt: MissingReceipt) {")
        assertTrue(
            "没能抽出 `confirmMissingItem` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`confirmMissingItem` 没有数库里的行（`db.countDriveEntry(`）。",
            fn.contains("db.countDriveEntry("),
        )
        assertTrue(
            "`db.countDriveEntry(` 必须排在 `showOverlay(` 之前（先数、再问）。",
            fn.indexOf("db.countDriveEntry(") < fn.indexOf("showOverlay("),
        )
        assertTrue(
            "`db.countDriveEntry(` 必须包在 `Bg.run(` 里：它是查库，放主线程会卡帧。",
            fn.indexOf("Bg.run(") in 0 until fn.indexOf("showOverlay("),
        )
        assertTrue(
            "没有「库里 0 行就不弹」那一条（`if (pair.second <= 0)`）。",
            fn.contains("pair.second <= 0"),
        )
        assertTrue(
            "`remainingItems` 不是按「除它之外还剩几条」算的（`siblings.count { it.id != id }`）。\n" +
                "算错的话，「这是最后一条」会提前或延后出现，而用户据此判断要不要按下去。",
            fn.contains("siblings.count { it.id != id }"),
        )
        assertTrue(
            "档位没有走 `plan.labels()`（顺序在 `MissingMediaPlan` 里，取消必须排第一）。",
            fn.contains("plan.labels()"),
        )
    }

    /**
     * 清完要判断作品还在不在。
     *
     * `purgeDriveEntry` 会顺手删掉因此变空的作品行；作品没了还去
     * `reloadCurrentItems()` 的话，用户会停在一个「0 个文件」的空简介页上。
     */
    @Test
    fun `清完作品没了就回作品墙`() {
        val code = codeOnly(readSource(libraryFile))
        val fn = braceBlock(
            code,
            "private fun removeMissingItem(provider: String, fid: String, plan: MissingMediaPlan) {",
        )
        assertTrue(
            "没能抽出 `removeMissingItem` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`removeMissingItem` 没有调 `purgeDriveEntry(`。",
            fn.contains("db.purgeDriveEntry("),
        )
        assertTrue(
            "没有判断作品还在不在（`db.workForDetail(`）。",
            fn.contains("db.workForDetail("),
        )
        assertTrue(
            "作品还在就 `reloadCurrentItems(`、没了就 `loadWorks(` —— 少了后者会停在空页面上。",
            fn.contains("if (alive) reloadCurrentItems(") && fn.contains("else loadWorks("),
        )
        assertTrue(
            "⛔ 这条路径**不该**碰网盘：`purgeDriveEntry` 只动本地库。\n" +
                "去删一个服务端说不在的文件，最好的结果是白打一次请求。",
            !fn.contains("deleteFiles("),
        )
    }

    // ------------------------------------------------------------------
    // 工具（与 BrowseDeleteGuardTest 同一套，复制而非共享）
    // ------------------------------------------------------------------

    private fun readSource(file: File): String {
        assertTrue(
            "读不到源文件：${file.absolutePath}（当前目录 ${File(".").absolutePath}）。\n" +
                "本测试依赖 Gradle 的 test 工作目录 = 模块目录（android/app）。",
            file.isFile,
        )
        return file.readText()
    }

    /** 剔除注释后的源码（行级过滤，不碰行尾的字符串字面量）。 */
    private fun codeOnly(src: String): String =
        src.lines().filterNot { line ->
            val t = line.trimStart()
            t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
        }.joinToString("\n")

    /** 从 `head` 那个 `{` 开始做花括号配对，返回整段（含首尾花括号）。 */
    private fun braceBlock(code: String, head: String): String {
        val start = code.indexOf(head)
        if (start < 0) return ""
        val open = code.indexOf('{', start)
        if (open < 0) return ""
        var depth = 0
        for (i in open until code.length) {
            when (code[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return code.substring(start, i + 1)
                }
            }
        }
        return ""
    }
}
