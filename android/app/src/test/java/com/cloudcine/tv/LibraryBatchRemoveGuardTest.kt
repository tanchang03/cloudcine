package com.cloudcine.tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「**媒体库批量移除**」（TV 端多选）的接线守卫。
 *
 * ## 为什么需要这个测试
 *
 * 这条路径上有四个「写了但不生效」的点，共同特点是**不编译报错、不崩、
 * 日志干净**，只有人坐在电视前才看得见：
 *
 *   1. 菜单入口没接（用户找不到「批量移除」在哪）；
 *   2. 多选模式下 OK 还是进简介页（点了半天选不中）；
 *   3. 返回键一路退到导航栏 / 退出确认（用户想的只是「不选了」）；
 *   4. 勾选角标没画 / 工具条没换成多选动作（勾了却看不出勾没勾）。
 *
 * 与 `LibraryActivityWiringTest` 同一套办法（读源文件、剔注释、抽代码块），
 * 不引 Robolectric。⛔ **必须先剔注释再匹配** —— 本仓库的文档注释里到处是
 * 说明性引用（`` `if (selecting)` `` 这种），不剔注释的话守卫会在最需要它
 * 的那一刻放行。
 */
class LibraryBatchRemoveGuardTest {

    private val activityFile = File("src/main/java/com/cloudcine/tv/LibraryActivity.kt")
    private val dbFile = File("src/main/java/com/cloudcine/tv/library/LibraryDb.kt")

    /** MENU 里必须有一条「批量移除」入口，且它真的进多选。 */
    @Test
    fun `菜单里有批量移除入口并且进多选`() {
        val code = codeOnly(readSource(activityFile))
        assertTrue(
            "LibraryActivity 的代码区里找不到菜单项「批量移除（从媒体库）」。\n" +
                "电视遥控器没有长按，PC 端「长按卡片进多选」那条路在电视上无处安放 ——\n" +
                "唯一的入口就是 MENU 里这一项，缺了它整个功能不可达。",
            code.contains("批量移除（从媒体库）"),
        )
        val menu = braceBlock(code, "private fun openMenu() {")
        assertTrue(
            "没能抽出 `openMenu` 函数体，或它没有调 `enterSelection()`。\n" +
                "菜单项在、动作没接的话，点下去什么都不发生。",
            menu.isNotEmpty() && menu.contains("enterSelection()"),
        )
    }

    /**
     * 多选模式下 OK 点卡片 = 勾选，**不是**进简介页。
     *
     * 这是这条功能的根：`onWorkRow` 同时服务遥控器 OK（dispatchKeyEvent）
     * 与触摸点击（OnItemClickListener），所以勾一支就够，但**顺序要对**
     * —— `selecting` 分支必须在 `openWork` 之前。
     */
    @Test
    fun `多选模式下 OK 点卡片是勾选而不是进简介页`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun onWorkRow(position: Int) {")
        assertTrue(
            "没能抽出 `onWorkRow` 函数体 —— 正则已与源文件脱节，请修正本测试",
            fn.contains("works.getOrNull(position)"),
        )
        assertTrue(
            "`onWorkRow` 里没有 `if (selecting)` 分支。\n" +
                "多选模式下点卡片会直接进简介页：用户勾一部就跳走一次，\n" +
                "「批量」变成「逐个翻片子」，比没有这个功能更糟。",
            fn.contains("if (selecting)"),
        )
        assertTrue(
            "`onWorkRow` 的多选分支没有调 `toggleSelected(...)`。",
            fn.contains("toggleSelected("),
        )
    }

    /** 返回键在多选模式下 = 退出多选，不是「退一层页面」。 */
    @Test
    fun `返回键先退多选再退页面`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun handleBack() {")
        assertTrue(
            "没能抽出 `handleBack` 函数体 —— 正则已与源文件脱节，请修正本测试",
            fn.contains("level == Level.ITEMS"),
        )
        assertTrue(
            "`handleBack` 里没有 `if (selecting) { exitSelection() }`。\n" +
                "没有这一条，用户在多选里按返回会一路退到导航栏、再按一次弹退出确认，\n" +
                "而他想做的只是「不选了」。",
            fn.contains("if (selecting)") && fn.contains("exitSelection()"),
        )
        // ⛔ 还必须退在「回作品墙」**之前**：多选只存在于作品墙，顺序写反的
        // 后果是这一支永远进不去（虽然不报错）。
        assertTrue(
            "`exitSelection()` 必须排在 `backToWorks()` 之前。",
            fn.indexOf("exitSelection()") < fn.indexOf("backToWorks()"),
        )
    }

    /**
     * 多选态变化必须**四处一起重画**。
     *
     * 只刷卡片 → 工具条还写着上一次的「已选 N」；只刷工具条 → 刚勾的那张卡
     * 没有勾。两条都是「勾了但看不出」。
     */
    @Test
    fun `多选态变化会一起重画卡片工具条和提示行`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun refreshSelectionUi() {")
        assertTrue(
            "没能抽出 `refreshSelectionUi` 函数体 —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`refreshSelectionUi` 没有重画卡片（`worksAdapter.notifyDataSetChanged()`）。\n" +
                "只刷工具条的话，刚勾的那张卡没有勾 —— 用户以为没选上，再点一次。",
            fn.contains("worksAdapter.notifyDataSetChanged()"),
        )
        assertTrue(
            "`refreshSelectionUi` 没有重画工具条（`paintBar()`）。\n" +
                "只刷卡片的话，「已选 N 部 / 移除 N 部」还是上一次的数字。",
            fn.contains("paintBar()"),
        )
    }

    /**
     * 卡片上要有勾选角标，且必须**按 `posterBox` 的下标**取。
     *
     * `getChildAt(4)` 这个下标与 `buildCard` 的追加顺序是**跨函数的隐式
     * 契约**（红线 9）：改一侧漏一侧不报错，只会把角标画到别的东西上。
     */
    @Test
    fun `卡片上有勾选角标并且按下标取`() {
        val code = codeOnly(readSource(activityFile))
        val getView = braceBlock(
            code,
            "override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {",
        )
        assertTrue(
            "没能抽出 `WorksAdapter.getView` —— 正则已与源文件脱节，请修正本测试",
            getView.contains("works[position]"),
        )
        assertTrue(
            "`getView` 里没有取勾选角标（`posterBox.getChildAt(4)`）。\n" +
                "多选时卡片上没有任何「已勾选」的线索，用户只能靠数。",
            getView.contains("getChildAt(4)"),
        )
        assertTrue(
            "`getView` 里没有设置勾选角标的显隐（`tick.visibility =`）。\n" +
                "⛔ convertView 复用时旧值会留在视图上，必须每一帧重设。",
            getView.contains("tick.visibility ="),
        )
        val buildCard = braceBlock(code, "private fun buildCard(): LinearLayout {")
        assertTrue(
            "`buildCard` 里没有追加勾选角标（`text = \"✓\"`，下标 4）。\n" +
                "⛔ 它必须加在 posterBox 的**末尾**：插在中间会把评分 / 更新角标顶错位，\n" +
                "而且不报错（红线 9）。",
            buildCard.contains("text = \"✓\""),
        )
    }

    /** 多选模式下工具条整行换成多选动作（排序 / 筛选在这时候没有意义）。 */
    @Test
    fun `多选时工具条换成全选取消移除退出`() {
        val code = codeOnly(readSource(activityFile))
        val fn = braceBlock(code, "private fun buildBar() {")
        assertTrue(
            "没能抽出 `buildBar` 函数体 —— 正则已与源文件脱节，请修正本测试",
            fn.contains("BarItem("),
        )
        for (action in listOf("selectAllVisible()", "confirmRemoveSelected()", "exitSelection()")) {
            assertTrue(
                "`buildBar` 的多选分支里没有 `$action`。\n" +
                    "工具条是电视上「全选 / 移除 / 退出」的唯一容身之处（没有可见的\n" +
                    "多选页头），缺一项用户就少一条路。",
                fn.contains(action),
            )
        }
    }

    // ------------------------------------------------------------------
    // 仓储层
    // ------------------------------------------------------------------

    /** `deleteWorks` 必须存在，且四张表一起删。 */
    @Test
    fun `deleteWorks 删四张表`() {
        val code = codeOnly(readSource(dbFile))
        val fn = braceBlock(code, "fun deleteWorks(keys: List<String>): Int {")
        assertTrue(
            "没能抽出 `LibraryDb.deleteWorks` —— 正则已与源文件脱节，请修正本测试",
            fn.contains("beginTransaction"),
        )
        for (table in listOf("media_items", "media_works", "subtitle_refs", "playback_prefs")) {
            assertTrue(
                "`deleteWorks` 没有删 `$table`。\n" +
                    "漏任何一张都会留下**孤儿行**：海报墙上多一部点开就报错的死卡片，\n" +
                    "或者一条永远看不见的播放偏好。而两者在任何界面上都不报错。",
                fn.contains("\"$table\""),
            )
        }
    }

    /**
     * 必须带上 `merged_into` 折进来的源作品，且整段在事务里。
     *
     * 少这一条 = 「移除整部剧」只删一半文件（2026-10-07 真机踩过的同款
     * 并集口径问题，见 `LibraryUnionGuardTest`）。
     */
    @Test
    fun `deleteWorks 带上 merged 源作品并在事务里执行`() {
        val code = codeOnly(readSource(dbFile))
        val fn = braceBlock(code, "fun deleteWorks(keys: List<String>): Int {")
        assertTrue(
            "没能抽出 `LibraryDb.deleteWorks` —— 正则已与源文件脱节，请修正本测试",
            fn.isNotEmpty(),
        )
        assertTrue(
            "`deleteWorks` 没有解析 `merged_into`。\n" +
                "合并过的作品是「一部 + 若干别名行」，只删目标自己的话，别名行名下的\n" +
                "文件会留在库里 —— 用户看到的是「移除过了，墙上还有它」。",
            fn.contains("merged_into IN"),
        )
        assertTrue(
            "`deleteWorks` 没有 `beginTransaction()`。\n" +
                "四张表分四条语句执行，中途失败会留下半删状态，而界面只会说「移除失败」。",
            fn.contains("beginTransaction()") && fn.contains("setTransactionSuccessful()"),
        )
    }

    // ------------------------------------------------------------------
    // 工具（与 LibraryActivityWiringTest 同一套，复制而非共享：两个测试类
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
