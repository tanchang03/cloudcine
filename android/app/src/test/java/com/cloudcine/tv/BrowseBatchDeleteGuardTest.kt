package com.cloudcine.tv

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「**文件列表多选删除**」的接线守卫（`BrowseActivity`）。
 *
 * ## 为什么这条路径比媒体库那条更需要守卫
 *
 * 它删的是**网盘上真实存在的文件**，而且是**批量**。四个「写了但不生效」的点
 * 在这里的后果都是不可逆的：
 *
 *   1. 菜单入口没接 —— 功能不可达（用户找不到「多选删除」）；
 *   2. 多选态下 OK 还是进目录 / 播放 —— 勾一部就跳走一次，勾选白做；
 *   3. 返回键先退目录而不是先退多选 —— 用户以为「不选了」，其实已经退出一层；
 *   4. 清索引不按 `onBatch` 回调走 —— 网盘没删掉的项，媒体库里先没了。
 *
 * 与 `LibraryBatchRemoveGuardTest` 同一套办法（读源文件、剔注释、花括号配对），
 * 不引 Robolectric。⛔ **必须先剔注释再匹配**：本仓库的文档注释里到处是
 * 说明性引用（`` `if (selecting)` `` 这种），不剔注释的话守卫会在最需要它的
 * 那一刻放行。
 */
class BrowseBatchDeleteGuardTest {

    private val activityFile = File("src/main/java/com/cloudcine/tv/BrowseActivity.kt")
    private val planFile = File("src/main/java/com/cloudcine/tv/library/DriveBatchDeletePlan.kt")
    private val deleterFile = File("src/main/java/com/cloudcine/tv/library/BatchFileDeleter.kt")

    /** MENU 里必须有一条多选入口，且它真的进多选。 */
    @Test
    fun `菜单里有单条删除和多选删除两个入口`() {
        val code = codeOnly(readSource(activityFile))
        val menu = braceBlock(code, "private fun openMenu() {")
        assertTrue(
            "没能抽出 `openMenu` —— 正则已与源文件脱节，请修正本测试",
            menu.isNotEmpty(),
        )
        assertTrue(
            "`openMenu` 里没有「删除「…」（网盘，不可撤销）…」这一项。",
            menu.contains("（网盘，不可撤销）…\" to { confirmDeleteEntry("),
        )
        assertTrue(
            "`openMenu` 里没有「多选删除（网盘，不可撤销）…」这一项。\n" +
                "没有它，这条功能在电视上完全不可达。",
            menu.contains("多选删除（网盘，不可撤销）"),
        )
        assertTrue(
            "多选那一项没有调 `enterSelection()`（动作没接，点了什么都不发生）。",
            menu.contains("enterSelection()"),
        )
        assertTrue(
            "多选入口必须在单条入口**之后**：单条是常用动作，批量是「清一层」的重手动作，\n" +
                "重的那个不该抢走菜单里第一次按下的位置。",
            menu.indexOf("confirmDeleteEntry(") < menu.indexOf("多选删除（网盘，不可撤销）"),
        )
    }

    /**
     * 多选态下 OK 点一行 = 勾选，**不是**进目录 / 播放。
     *
     * `onEntry` 同时服务遥控器 OK（ListView 的 click）与触摸点击，所以勾一支就够，
     * 但**顺序要对**：`if (selecting)` 必须在 `when { e.isDir -> ... }` 之前。
     */
    @Test
    fun `多选态下 OK 点一行是勾选而不是进目录`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun onEntry(e: DriveEntry) {")
        assertTrue(
            "没能抽出 `onEntry` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`onEntry` 里没有 `if (selecting)` 分支。\n" +
                "多选态下点一行会直接进目录或起播：勾一项就跳走一次，「批量」变成逐个翻。",
            fn.contains("if (selecting)"),
        )
        assertTrue(
            "`onEntry` 的多选分支没有调 `toggleSelected(...)`。",
            fn.contains("toggleSelected("),
        )
        assertTrue(
            "`if (selecting)` 必须排在 `e.isDir -> open(` 之前 —— 写在后面这一支永远进不去，\n" +
                "而且不报错。",
            fn.indexOf("if (selecting)") < fn.indexOf("e.isDir -> open("),
        )
    }

    /** 返回键在多选态下 = 退出多选，不是「退一层目录」。 */
    @Test
    fun `返回键先退多选再退目录`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "override fun dispatchKeyEvent(event: KeyEvent): Boolean {")
        assertTrue(
            "没能抽出 `dispatchKeyEvent` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`dispatchKeyEvent` 里没有多选分支（找不到 `if (selecting)`）。\n" +
                "多选态下按返回会直接弹一层目录，而用户想做的只是「不选了」。",
            fn.contains("if (selecting)"),
        )
        assertTrue(
            "多选分支里没有 `exitSelection()`。",
            fn.contains("exitSelection()"),
        )
        assertTrue(
            "`exitSelection()` 必须排在 `goUp()` 之前：反过来的话返回键永远走「退一层目录」，\n" +
                "多选态根本退不出来（而用户会以为是自己按错了）。",
            fn.indexOf("exitSelection()") < fn.indexOf("goUp()"),
        )
        assertTrue(
            "多选分支必须排在排序胶囊分支（`if (sortFocused)`）之前：\n" +
                "多选态下 OK 是「勾选」，胶囊的 OK 是「重排」。放行的话，用户在首行按 ↑\n" +
                "会进到一个按 OK 就重排列表的地方，而他以为自己在勾第一项。",
            fn.indexOf("if (selecting)") < fn.indexOf("if (sortFocused)"),
        )
    }

    /** 多选态下菜单整份换掉：勾选期间「发现」「切网盘」不该出现。 */
    @Test
    fun `多选态下菜单换成全选与删除`() {
        val code = codeOnly(readSource(activityFile))
        val menu = braceBlock(code, "private fun openMenu() {")
        assertTrue(
            "没能抽出 `openMenu` —— 正则已与源文件脱节，请修正本测试",
            menu.isNotEmpty(),
        )
        assertTrue(
            "`openMenu` 开头没有 `if (selecting) { openSelectionMenu() }` 的分流。\n" +
                "勾完 8 项再「发现」一次，列表会重列、勾选全丢，而用户以为是自己勾错了。",
            menu.contains("openSelectionMenu()"),
        )
        val sel = braceBlock(code, "private fun openSelectionMenu() {")
        assertTrue(
            "没能抽出 `openSelectionMenu` —— 正则已与源文件脱节，请修正本测试",
            sel.isNotEmpty(),
        )
        for (action in listOf("selectAllVisible()", "confirmBatchDelete()", "exitSelection()")) {
            assertTrue(
                "`openSelectionMenu` 里没有 `$action`。\n" +
                    "电视上没有可见的多选工具条，全选 / 删除 / 退出只能在这个菜单里。",
                sel.contains(action),
            )
        }
        assertTrue(
            "「删除已选…」必须排在「退出多选」**之前**、并且排在全选之后 —— 不可逆的那一项\n" +
                "不该是菜单里第一眼（光标默认落点）能按到的东西。",
            sel.indexOf("全选本层") < sel.indexOf("confirmBatchDelete()"),
        )
    }

    /**
     * 删除前必须先统计媒体库牵连几条，且统计走后台。
     *
     * 那句「媒体库里有 N 条索引会一起清掉」是用户判断「这一下动多少」的唯一
     * 依据；而统计是查库（一个目录可能几百条），放主线程会直接卡帧。
     */
    @Test
    fun `先统计再弹确认且统计走后台`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun confirmBatchDelete() {")
        assertTrue(
            "没能抽出 `confirmBatchDelete` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`confirmBatchDelete` 没有调 `db.countDriveEntry(`。\n" +
                "不统计的话，确认框上写不出「库里会清掉几条」，而这是不可逆的。",
            fn.contains("db.countDriveEntry("),
        )
        assertTrue(
            "统计必须包在 `Bg.run(` 里：它是查库，放主线程会卡帧。",
            fn.indexOf("Bg.run(") in 0 until fn.indexOf("showOverlay("),
        )
        assertTrue(
            "「取消」必须排在确认档之前：`showOverlay` 的光标从 0 开始，\n" +
                "一次顺手确认不该删掉一整个目录。",
            fn.indexOf("listOf(\"取消\"") in 0 until fn.indexOf("full.confirmLabel"),
        )
        assertTrue(
            "确认框正文没有用 `full.body`（值对象的六段正文）。",
            fn.contains("full.body"),
        )
    }

    /**
     * 只有**确认删掉**的那些才清索引。
     *
     * ⛔ 清早了会得到「文件还在网盘上、媒体库里却没了」—— 那要重扫一遍才能
     *    回来。`BatchFileDeleter` 只在**整批成功**时回调 `onBatch`，所以清理
     *    必须写在 `onBatch` 里，而不是循环外面。
     */
    @Test
    fun `只按批次回调清索引且清索引失败不算删除失败`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun doBatchDelete(plan: DriveBatchDeletePlan, prefixes: Map<String, String?>) {")
        assertTrue(
            "没能抽出 `doBatchDelete` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`doBatchDelete` 没有走 `BatchFileDeleter.delete(`。\n" +
                "分批 / 失败计数 / 进度那条逻辑在它里面，绕过去就只剩一份没人测的循环。",
            fn.contains("BatchFileDeleter.delete("),
        )
        assertTrue(
            "`doBatchDelete` 里没有 `onBatch = ` 回调。",
            fn.contains("onBatch = "),
        )
        assertTrue(
            "`db.purgeDriveEntry(` 必须在 `onBatch = ` **之后**（即在回调里）。\n" +
                "写在循环外面的话，网盘没删掉的项会先在媒体库里消失。",
            fn.indexOf("onBatch = ") < fn.indexOf("db.purgeDriveEntry("),
        )
        assertTrue(
            "清索引没有用 `runCatching` 包住。\n" +
                "它一抛，`BatchFileDeleter` 会把这一批记成「删除失败」—— 而文件其实已经没了。",
            fn.contains("runCatching { db.purgeDriveEntry("),
        )
        assertTrue(
            "删网盘走的是 `deleteBatch = { chunk -> pan.deleteFiles(chunk).size }`。\n" +
                "`pan` 必须是 `PanApi(store)`：本页的 `api` 可能是只读的百度客户端。",
            fn.contains("PanApi(store)") && fn.contains("deleteFiles("),
        )
        assertTrue(
            "进度回调没有接给 `BatchFileDeleter`（找不到 `onProgress =`）。\n" +
                "几百个文件要打好几批，屏幕不动的「正在删除…」在电视上等价于卡死。",
            fn.contains("onProgress ="),
        )
    }

    /** 删完必须退出多选并重列：集合里躺着的是已经不存在的 fid。 */
    @Test
    fun `删完退出多选并重列`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun doBatchDelete(plan: DriveBatchDeletePlan, prefixes: Map<String, String?>) {")
        assertTrue(
            "没能抽出 `doBatchDelete` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`doBatchDelete` 结束后没有 `exitSelection()`。\n" +
                "留着的话，再按一次「删除已选」会对着一批已经不存在的 fid 发请求。",
            fn.contains("exitSelection()"),
        )
        assertTrue(
            "`doBatchDelete` 删成功之后没有 `reloadHere()`（列表会一直显示已经删掉的行）。",
            fn.contains("reloadHere()"),
        )
        assertTrue(
            "`reloadHere()` 必须包在「真的删掉了」的判断里 —— 全失败时重列，列表一动不动，\n" +
                "用户会以为界面没反应。",
            fn.contains("if ((res?.deleted ?: 0) > 0) reloadHere()"),
        )
    }

    /**
     * 删除结果不能被重列冲掉。
     *
     * `reloadHere()` → `open()` → `paintStatus()` 会把状态行整行改写成本层统计。
     * 实测：删 7 项、2 项失败，用户看到的只有「夸克 · 共 12 项」，失败那两条
     * 没有任何地方再说过一次。
     */
    @Test
    fun `删除结果在重列之后仍然看得见`() {
        val code = codeOnly(readSource(activityFile))
        val paint = braceBlock(code, "private fun paintStatus() {")
        assertTrue(
            "没能抽出 `paintStatus` —— 正则已与源文件脱节，请修正本测试",
            paint.isNotEmpty(),
        )
        assertTrue(
            "`paintStatus` 没有把 `statusNote` 带上。\n" +
                "现象：删完的结果只闪一下，随后被「夸克 · 共 N 项」覆盖。",
            paint.contains("statusNote"),
        )
        val reload = braceBlock(code, "private fun reloadHere() {")
        assertTrue(
            "没能抽出 `reloadHere` —— 正则已与源文件脱节，请修正本测试",
            reload.isNotEmpty(),
        )
        assertTrue(
            "`reloadHere` 调 `open(...)` 时没有 `keepNote = true`：\n" +
                "`open` 默认会清掉 note，删除结果照样丢。",
            reload.contains("keepNote = true"),
        )
        val fn = braceBlock(code, "private fun doBatchDelete(plan: DriveBatchDeletePlan, prefixes: Map<String, String?>) {")
        assertTrue(
            "`doBatchDelete` 没有把结果写进 `statusNote`。",
            fn.contains("statusNote = msg"),
        )
    }

    /** 列表行要有勾选角标，且必须**每一帧**重设（convertView 会复用）。 */
    @Test
    fun `列表行有勾选角标并且每帧重设`() {
        val code = codeOnly(readSource(activityFile))
        val getView = braceBlock(
            code,
            "override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {",
        )
        assertTrue(
            "没能抽出 `EntryAdapter.getView` —— 正则已与源文件脱节，请修正本测试",
            getView.contains("val e = entries[position]"),
        )
        assertTrue(
            "`getView` 里没有画勾选角标（找不到 `☑` / `☐`）。\n" +
                "多选态下没有任何「已勾选」的线索，用户只能靠数。",
            getView.contains("\"☑\"") && getView.contains("\"☐\""),
        )
        assertTrue(
            "`getView` 里没有每一帧重设角标显隐（`tick.visibility =`）。\n" +
                "⛔ convertView 复用时旧值会留在视图上 —— 表现是「没勾的项自己打上了勾」。",
            getView.contains("tick.visibility ="),
        )
        assertTrue(
            "非多选态必须用 `INVISIBLE` 而不是 `GONE`：`GONE` 会让片名在进出多选时\n" +
                "整体左右跳 30dp，下面三列的下标也会跟着变。",
            getView.contains("View.INVISIBLE"),
        )
    }

    /** 值对象那一侧：确认框正文的顺序与「名单」这件事本身（见 `DriveBatchDeletePlanTest`）。 */
    @Test
    fun `确认框正文包含名单与不可撤销`() {
        val code = codeOnly(readSource(planFile))
        // ⛔ `body` 是 `val ... get() = ...`（没有花括号），不能用 `braceBlock`。
        val body = code.substringAfter("val body: String", "")
            .substringBefore("fun resultMessage", "")
        assertTrue(
            "没能抽出 `DriveBatchDeletePlan.body` —— 正则已与源文件脱节，请修正本测试",
            body.isNotEmpty(),
        )
        assertTrue(
            "正文里没有 `listing`（「删的是哪几个」）。\n" +
                "多选态下光标只停在一行上，其余几个是靠 ☑ 记着的 —— 没有名单，\n" +
                "用户按确认前无法核对。",
            body.contains("listing"),
        )
        assertTrue(
            "正文里没有 `irreversible`。",
            body.contains("irreversible"),
        )
        assertTrue(
            "`listing` 必须排在 `irreversible` 之前（先「删哪几个」、再「能不能回来」），\n" +
                "顺序反了的话名单会被挤到不可撤销那句下面。",
            body.indexOf("listing") < body.indexOf("irreversible"),
        )
    }

    /** `BatchFileDeleter` 的 `onBatch` 只在整批成功时触发（否则索引清早了）。 */
    @Test
    fun `批次回调只在成功后触发`() {
        val code = codeOnly(readSource(deleterFile))
        val at = code.indexOf("fun delete(")
        assertTrue(
            "没能定位 `BatchFileDeleter.delete` —— 正则已与源文件脱节，请修正本测试",
            at >= 0,
        )
        // ⛔ 不能用 `braceBlock(code, "fun delete(")`：签名里那几个参数默认值
        //    （`= { _, _ -> }`）**本身就是花括号块**，配对会在第一个默认值上就
        //    结束，拿到的是一个没有函数体的签名 —— 于是「没有 onBatch」误报。
        //    从 `): Result {` 起配对才是函数体。
        val fn = braceBlock(code.substring(at), "): Result {")
        assertTrue(
            "没能抽出 `BatchFileDeleter.delete` 的函数体 —— 正则已与源文件脱节",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`delete` 里没有调 `onBatch(`。",
            fn.contains("onBatch("),
        )
        assertTrue(
            "`onBatch(` 必须在 `deleteBatch(` 之后、且在 `catch` 之前 ——\n" +
                "它只该在**这一批成功**时触发；写进 catch 里等于「失败也算删掉了」。",
            fn.indexOf("deleteBatch(") < fn.indexOf("onBatch("),
        )
        assertTrue(
            "`onBatch(` 不该出现在 `catch (e: Exception)` 分支里。",
            fn.indexOf("onBatch(") < fn.indexOf("catch (e: Exception)"),
        )
        assertFalse(
            "`delete` 里出现了两处 `onBatch(` —— 只该有一处（成功之后）。",
            Regex("onBatch\\(").findAll(fn).count() > 2,
        )
    }

    // ------------------------------------------------------------------
    // 工具（与 LibraryBatchRemoveGuardTest 同一套，复制而非共享：两个测试类
    // 各自独立，改一个不该连带另一个红）
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
