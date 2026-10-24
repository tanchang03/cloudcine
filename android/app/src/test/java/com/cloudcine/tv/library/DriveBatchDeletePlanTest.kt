package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「多选删除」的**文案与判据**（`DriveBatchDeletePlan`）—— 不碰网盘、不碰 SQLite。
 *
 * ## 与单选那一份（`DriveDeletePlanTest`）的差别只有一句
 *
 * 单选一次删一项，标题里就有名字。批量必须**额外**说清「删的是哪几个」：
 * 多选态下光标只停在**一行**上，其余几个是靠 ☑ 记着的，而电视上离得远、
 * 勾选角标又小。用户按确认前唯一能核对的，就是那句名单。
 */
class DriveBatchDeletePlanTest {

    private fun target(name: String, isDir: Boolean = false, size: Long = 0) =
        DriveBatchTarget(fid = "fid-$name", name = name, isDir = isDir, sizeBytes = size)

    private fun plan(vararg targets: DriveBatchTarget, libraryItems: Int = 0) =
        DriveBatchDeletePlan(
            targets = targets.toList(),
            providerName = "夸克网盘",
            libraryItems = libraryItems,
        )

    private fun files(n: Int, size: Long = 0) =
        Array(n) { target("E%02d.mkv".format(it + 1), size = size) }

    // ------------------------------------------------------------------
    // 标题
    // ------------------------------------------------------------------

    @Test
    fun `标题带项数`() {
        assertEquals("要删除这 3 项吗？（3 个文件）", plan(*files(3)).title)
    }

    /** ⛔ 有目录时必须把「几个文件 · 几个目录」拆开：一句「5 项」读不出里面有没有目录。 */
    @Test
    fun `有目录时标题拆开数`() {
        val t = plan(*files(2), target("进击的巨人", isDir = true))
        assertEquals("要删除这 3 项吗？（2 个文件 · 1 个目录）", t.title)
    }

    // ------------------------------------------------------------------
    // 名单（批量独有的那一句）
    // ------------------------------------------------------------------

    @Test
    fun `名单列出全部名字`() {
        val text = plan(*files(2)).listing
        assertTrue(text.contains("「E01.mkv」"))
        assertTrue(text.contains("「E02.mkv」"))
        assertFalse("只有两项时不该出现省略号", text.contains("…"))
    }

    /** ⛔ 超过三个要收尾：名单一长，确认框就顶到屏幕外，而它是不能滚的。 */
    @Test
    fun `超过三项用等 N 项收尾`() {
        val text = plan(*files(7)).listing
        assertTrue(text.contains("「E01.mkv」"))
        assertTrue(text.contains("「E03.mkv」"))
        assertFalse("第四个不该列出来", text.contains("「E04.mkv」"))
        assertTrue(text.contains("…等 7 项"))
    }

    @Test
    fun `空名单不产出空白名单句`() {
        assertEquals("", plan().listing)
    }

    // ------------------------------------------------------------------
    // 不可撤销 / 目录连带 / 体积 / 媒体库
    // ------------------------------------------------------------------

    @Test
    fun `不可撤销那句带上网盘名`() {
        val text = plan(*files(2)).irreversible
        assertTrue(text.contains("不可撤销"))
        assertTrue(text.contains("夸克网盘"))
        assertTrue(text.contains("无法恢复"))
    }

    @Test
    fun `只有目录才警告连带删除`() {
        assertNull(plan(*files(3)).folderWarning)
        assertTrue(plan(*files(2), target("S01", isDir = true)).folderWarning!!.contains("1 个目录"))
        assertTrue(
            plan(target("S01", isDir = true), target("S02", isDir = true))
                .folderWarning!!.contains("2 个目录"),
        )
    }

    /**
     * 体积三分支：未知 / 有目录（只报文件那部分）/ 全是文件。
     *
     * ⛔ 有目录时说「释放约 X」是撒谎 —— X 只是文件那部分，而目录里往往才是大头。
     */
    @Test
    fun `体积三种说法`() {
        assertTrue(plan(*files(2)).freedLabel.contains("未知"))
        val withDir = plan(*files(1, size = 1024L), target("S01", isDir = true)).freedLabel
        assertTrue(withDir.contains("合计约"))
        assertTrue("要说清目录不计入", withDir.contains("不计入"))
        assertFalse("有目录时不能说「释放约」", withDir.contains("释放约"))
        val pureFiles = plan(*files(2, size = 1024L * 1024 * 1024)).freedLabel
        assertTrue(pureFiles.contains("释放约"))
        assertTrue("单位交给 formatSize，别自己拼", pureFiles.contains("GiB"))
    }

    @Test
    fun `媒体库条数两种说法`() {
        assertTrue(plan(*files(2)).libraryLine.contains("媒体库里没有它们的索引"))
        val many = plan(*files(2), libraryItems = 24).libraryLine
        assertTrue(many.contains("24 条"))
        assertTrue(many.contains("一起清掉"))
    }

    /** 确认按钮是最后一眼看到的东西：项数 + 不可撤销都要在上面。 */
    @Test
    fun `确认按钮带项数与不可撤销`() {
        val label = plan(*files(5)).confirmLabel
        assertTrue(label.contains("5 项"))
        assertTrue(label.contains("不可撤销"))
    }

    // ------------------------------------------------------------------
    // 正文顺序
    // ------------------------------------------------------------------

    /**
     * ⛔ 顺序固定：删什么 → 删哪几个 → 能不能回来 → 连带什么 → 腾多少 → 库里几条。
     *
     * 与单选同一套决策顺序；打乱之后最坏的情况是「不可撤销」被挤到名单下面，
     * 而名单可能有三行 —— 用户读到第二行就按了。
     */
    @Test
    fun `正文顺序与单选一致`() {
        val t = plan(*files(4), target("S01", isDir = true), libraryItems = 3)
        val body = t.body
        val order = listOf(t.title, t.listing, t.irreversible, t.folderWarning!!, t.freedLabel, t.libraryLine)
        var cursor = -1
        for (part in order) {
            val at = body.indexOf(part)
            assertTrue("正文里缺少这一段：$part", at >= 0)
            assertTrue("顺序不对：$part 出现在上一段之前", at > cursor)
            cursor = at
        }
    }

    // ------------------------------------------------------------------
    // 结果提示
    // ------------------------------------------------------------------

    @Test
    fun `全部成功`() {
        val msg = plan(*files(3), libraryItems = 3)
            .resultMessage(deleted = 3, failed = 0, libraryRemoved = 3, error = null)
        assertTrue(msg.contains("已删除 3 项"))
        assertTrue(msg.contains("3 条"))
    }

    @Test
    fun `成功但库里本来没有时要说明`() {
        val msg = plan(*files(2)).resultMessage(deleted = 2, failed = 0, libraryRemoved = 0, error = null)
        assertTrue(msg.contains("已删除 2 项"))
        assertTrue(msg.contains("本来就没有"))
    }

    /** ⛔ 部分失败必须两个数都报：只说成功，用户以为网盘上干净了。 */
    @Test
    fun `部分失败两个数都要说`() {
        val msg = plan(*files(5))
            .resultMessage(deleted = 3, failed = 2, libraryRemoved = 3, error = "限流")
        assertTrue(msg.contains("已删除 3 项"))
        assertTrue(msg.contains("2 项失败"))
        assertTrue(msg.contains("限流"))
    }

    /** ⛔ 一项都没删掉时不能说成删掉了，也不能说媒体库清过。 */
    @Test
    fun `全失败时说清原样还在`() {
        val msg = plan(*files(4)).resultMessage(deleted = 0, failed = 4, libraryRemoved = 0, error = "登录已失效")
        assertTrue(msg.contains("删除失败"))
        assertTrue(msg.contains("登录已失效"))
        assertTrue(msg.contains("原样还在"))
        assertTrue(msg.contains("媒体库未动"))
    }

    @Test
    fun `全失败但没有错误信息时给出兜底原因`() {
        val msg = plan(*files(1)).resultMessage(deleted = 0, failed = 1, libraryRemoved = 0, error = null)
        assertTrue(msg.contains("网盘拒绝了删除请求"))
    }
}
