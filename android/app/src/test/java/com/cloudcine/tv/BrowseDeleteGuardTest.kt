package com.cloudcine.tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「文件列表里删网盘条目」的**接线守卫**（读源文件，与 `LibraryBatchRemoveGuardTest`
 * 同一套路：先剔注释、再做花括号配对，不引 Robolectric）。
 *
 * ## 这条路径上「写了但不生效」的点
 *
 * 它们全都**不编译报错、不崩、日志干净**，只有坐到电视前按一遍才看得见：
 *
 *   1. 菜单里没有入口（用户找不到怎么删）；
 *   2. 先弹确认、后统计（确认框上那句「媒体库有 N 条」写不出来，或者写个猜的）；
 *   3. 顺序反了（先清索引再删网盘 ⇒ fid 已经没了，网盘上一个都删不掉）；
 *   4. 删失败却重列（列表纹丝不动，用户以为界面没反应）；
 *   5. 重列时又压了一层栈（删完按返回回到同一个目录）。
 */
class BrowseDeleteGuardTest {

    private val browseFile = File("src/main/java/com/cloudcine/tv/BrowseActivity.kt")
    private val dbFile = File("src/main/java/com/cloudcine/tv/library/LibraryDb.kt")

    /** MENU 里必须有一条删除入口，且它真的走确认。 */
    @Test
    fun `菜单里有删除入口并走确认`() {
        val code = codeOnly(readSource(browseFile))
        val menu = braceBlock(code, "private fun openMenu() {")
        assertTrue(
            "没能抽出 `openMenu` —— 正则已与源文件脱节，请修正本测试",
            menu.isNotEmpty(),
        )
        assertTrue(
            "`openMenu` 里没有「删除「…」（网盘，不可撤销）」这一项。\n" +
                "电视上没有长按也没有右键，菜单是唯一的删除入口 —— 缺了它整个功能不可达。",
            menu.contains("删除「") && menu.contains("网盘，不可撤销"),
        )
        assertTrue(
            "菜单项没有调 `confirmDeleteEntry(`（动作没接，点了什么都不发生）。",
            menu.contains("confirmDeleteEntry("),
        )
    }

    /**
     * 删除入口必须只对**可写**网盘出现。
     *
     * 百度在电视端是只读接入（`BaiduApi` 上没有删除方法），给它一个按下去
     * 必然失败的选项是纯粹的欺骗。
     */
    @Test
    fun `删除入口只在可写网盘出现`() {
        val code = codeOnly(readSource(browseFile))
        assertTrue(
            "`BrowseActivity` 里找不到 `canDeleteHere` 这个判据。",
            code.contains("canDeleteHere"),
        )
        assertTrue(
            "`canDeleteHere` 必须同时判「当前是夸克」与「客户端是 PanApi」。\n" +
                "只判厂家的话，切到百度之后菜单里仍会出现删除项，而它必然失败。",
            code.contains("provider == DriveProviders.QUARK && api is PanApi"),
        )
        val menu = braceBlock(code, "private fun openMenu() {")
        assertTrue(
            "`openMenu` 里那一项没有用 `canDeleteHere` 守着。",
            menu.contains("canDeleteHere"),
        )
    }

    /** 统计必须在弹窗之前，且走后台（查库）。 */
    @Test
    fun `统计在弹窗之前且走后台`() {
        val code = codeOnly(readSource(browseFile))
        val fn = braceBlock(code, "private fun confirmDeleteEntry(e: DriveEntry) {")
        assertTrue(
            "没能抽出 `confirmDeleteEntry` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`confirmDeleteEntry` 没有数媒体库里的条目（`db.countDriveEntry(`）。\n" +
                "不数的话，确认框上那句「媒体库有 N 条会一起清掉」只能省略 —— " +
                "而删掉一个 200 集的目录，库里就是 200 条索引。",
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
            "目录的前缀必须由 `childPath(` 算（当前这一层的路径 + 目录名）。\n" +
                "拿网盘条目自带的路径字段去匹配会静默地一条都匹配不到 —— 那些死索引会留在库里。",
            fn.contains("childPath("),
        )
        assertTrue(
            "确认框里「取消」必须排在删除之前：光标默认落在第一档，反了等于一次顺手确认就永久删掉一季。",
            fn.indexOf("\"取消\"") in 0 until fn.indexOf("plan.confirmLabel"),
        )
    }

    /** ⛔ 先删网盘、再清索引；网盘没删掉就不许清索引。 */
    @Test
    fun `先删网盘再清索引且失败不清`() {
        val code = codeOnly(readSource(browseFile))
        val fn = braceBlock(code, "private fun doDeleteEntry(plan: DriveDeletePlan, dirPathPrefix: String?) {")
        assertTrue(
            "没能抽出 `doDeleteEntry` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`doDeleteEntry` 没有调 `deleteFiles(`。",
            fn.contains("deleteFiles("),
        )
        assertTrue(
            "`deleteFiles(` 必须排在 `purgeDriveEntry(` 之前。\n" +
                "反过来的话 `media_items` 里那条 `provider:fileId` 已经没了，" +
                "网盘上一个都删不掉，而且不报错。",
            fn.indexOf("deleteFiles(") < fn.indexOf("purgeDriveEntry("),
        )
        assertTrue(
            "`purgeDriveEntry(` 必须被「真的删掉了」这个条件守着（`if (ok.isNotEmpty())`）。\n" +
                "失败也清索引的话，用户会得到「文件还在网盘上、媒体库里却没了」。",
            fn.contains("if (ok.isNotEmpty())"),
        )
        assertTrue(
            "只有 `deleted > 0` 才重列。失败时重列，列表一动不动，用户以为界面没反应。",
            fn.contains("if (deleted > 0) reloadHere()"),
        )
    }

    /** 重列不能又压一层栈，否则删完按返回会回到同一个目录。 */
    @Test
    fun `重列不重复压栈`() {
        val code = codeOnly(readSource(browseFile))
        val fn = braceBlock(code, "private fun reloadHere() {")
        assertTrue(
            "没能抽出 `reloadHere` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`reloadHere` 里没有先弹出栈顶（`stack.removeAt(`）。\n" +
                "`open(...)` 会往栈里压一层，删完一项按返回就会回到同一个目录、再按一次才上去。",
            fn.contains("stack.removeAt("),
        )
        assertTrue(
            "`stack.removeAt(` 必须排在 `open(` 之前。",
            fn.indexOf("stack.removeAt(") < fn.indexOf("open("),
        )
    }

    /** 仓储层：两条路径（按 fid / 按目录前缀）+ 事务 + 变空的作品行。 */
    @Test
    fun `仓储层按 fid 或目录前缀清索引且在事务里`() {
        val code = codeOnly(readSource(dbFile))
        val fn = braceBlock(code, "fun purgeDriveEntry(provider: String, fileId: String, dirPathPrefix: String?): Int {")
        assertTrue(
            "没能抽出 `LibraryDb.purgeDriveEntry` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`purgeDriveEntry` 没有 `beginTransaction()`。\n" +
                "媒体项与作品行分两条语句执行，中途失败会留下「文件行删了、作品行还在」的半删状态。",
            fn.contains("beginTransaction()") && fn.contains("setTransactionSuccessful()"),
        )
        assertTrue(
            "`purgeDriveEntry` 没有把因此变空的作品行一起删掉（`itemsForWork(` + `deleteWorks(`）。\n" +
                "留着它，海报墙上就是一张点开就报错的死卡片，而没有任何界面会报错。",
            fn.contains("itemsForWork(") && fn.contains("deleteWorks("),
        )
        val rows = braceBlock(
            code,
            "private fun driveEntryRows(\n        d: SQLiteDatabase,",
        )
        assertTrue(
            "没能抽出 `driveEntryRows` —— 正则已与源文件脱节，请修正本测试",
            rows.isNotEmpty(),
        )
        assertTrue(
            "`driveEntryRows` 里目录那条不是按前缀匹配（找不到 `substr(dir_path`）。",
            rows.contains("substr(dir_path"),
        )
        assertTrue(
            "⛔ 目录前缀**不能**用 `LIKE`：目录名里的 `_` / `%` 会被当通配符，" +
                "少匹配或多匹配都是静默的。",
            !rows.contains("LIKE"),
        )
        assertTrue(
            "`driveEntryRows` 没有按 `provider:fileId` 点查文件那一支。",
            rows.contains("\$provider:\$fileId"),
        )
    }

    // ------------------------------------------------------------------
    // 工具（与 LibraryBatchRemoveGuardTest 同一套，复制而非共享）
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
