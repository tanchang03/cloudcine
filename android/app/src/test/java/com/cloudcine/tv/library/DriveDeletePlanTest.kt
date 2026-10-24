package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「删除网盘条目」的**文案与判据**（`DriveDeletePlan`）—— 不碰网盘、不碰 SQLite。
 *
 * ## 为什么这些字值得单独测
 *
 * 这条路径一次只删一项，但那一项可能是一个 200 集的目录。三句话缺任何一句，
 * 用户都是**按下去之后**才知道：
 *
 *   1. 不可撤销（他以为是回收站）；
 *   2. 目录连带整棵子树（他以为只删了个文件夹图标）；
 *   3. 媒体库里的索引也会走（否则下次打开媒体库是一张点开就报错的死卡片）。
 */
class DriveDeletePlanTest {

    private fun plan(
        isDir: Boolean = false,
        sizeBytes: Long = 0,
        libraryItems: Int = 0,
        name: String = "流浪地球2.2023.2160p.mkv",
    ) = DriveDeletePlan(
        target = DriveDeleteTarget(fid = "f1", name = name, isDir = isDir, sizeBytes = sizeBytes),
        providerName = "夸克网盘",
        libraryItems = libraryItems,
    )

    @Test
    fun `标题用书名号式引号且是问句`() {
        assertEquals("要删除「流浪地球2.2023.2160p.mkv」吗？", plan().title)
    }

    /** 不可撤销那句必须点到**厂家**：用户要能对上「是哪个网盘里没了」。 */
    @Test
    fun `不可撤销那句带上网盘名`() {
        val text = plan().irreversible
        assertTrue(text.contains("不可撤销"))
        assertTrue(text.contains("夸克网盘"))
        assertTrue("要说明本应用救不回来", text.contains("无法恢复"))
    }

    /** 文件不该出现「整棵子树」那句（出现了会让用户以为还删了别的东西）。 */
    @Test
    fun `只有目录才警告整棵子树`() {
        assertNull(plan(isDir = false).folderWarning)
        val dir = plan(isDir = true, name = "进击的巨人")
        assertTrue(dir.folderWarning!!.contains("整个目录"))
        assertTrue(dir.folderWarning!!.contains("全部文件"))
    }

    /**
     * 体积的三种说法对应三种事实。
     *
     * ⛔ 目录的体积网盘不给，说成「释放 0 B」会被读成「删了也没用」。
     */
    @Test
    fun `体积未知与已知说法不同`() {
        assertTrue(plan(isDir = true).freedLabel.contains("未知"))
        assertTrue("大小为 0 也要说未知，不能说 0 B", plan(sizeBytes = 0).freedLabel.contains("未知"))
        val known = plan(sizeBytes = 3L * 1024 * 1024 * 1024).freedLabel
        assertTrue(known.contains("释放约"))
        // `formatSize` 用的是二进制单位（`GiB`），不是 `GB` —— 写错一个字
        // 这条断言就会红，正好钉住「别自己拼单位」。
        assertTrue(known.contains("GiB"))
    }

    /** 媒体库那一句：0 条时也要说，否则用户会以为「库里那份还在」。 */
    @Test
    fun `媒体库条数两种说法`() {
        assertTrue(plan(libraryItems = 0).libraryLine.contains("媒体库里没有它的索引"))
        val many = plan(libraryItems = 24).libraryLine
        assertTrue(many.contains("24 条"))
        assertTrue(many.contains("一起清掉"))
    }

    @Test
    fun `确认按钮带不可撤销`() {
        assertTrue(plan().confirmLabel.contains("删除"))
        assertTrue(plan().confirmLabel.contains("不可撤销"))
    }

    // ------------------------------------------------------------------
    // 结果提示
    // ------------------------------------------------------------------

    @Test
    fun `成功时把媒体库清掉的条数说出来`() {
        val msg = plan(libraryItems = 3).resultMessage(deleted = 1, libraryRemoved = 3, error = null)
        assertTrue(msg.contains("已删除"))
        assertTrue(msg.contains("3 条"))
    }

    @Test
    fun `成功但库里本来没有时要说明`() {
        val msg = plan().resultMessage(deleted = 1, libraryRemoved = 0, error = null)
        assertTrue(msg.contains("已删除"))
        assertTrue(msg.contains("本来就没有"))
    }

    /** ⛔ 失败不能含糊：用户会以为网盘上已经没了，而它原样还在。 */
    @Test
    fun `失败时说清原因与原样还在`() {
        val msg = plan().resultMessage(deleted = 0, libraryRemoved = 0, error = "限流")
        assertTrue(msg.contains("删除失败"))
        assertTrue(msg.contains("限流"))
        assertTrue(msg.contains("原样还在"))
        assertTrue("失败时不能说媒体库动过", msg.contains("媒体库未动"))
    }

    /** 没有具体错误信息时也要给一句人话，不能是空字符串。 */
    @Test
    fun `失败但没有错误信息时给出兜底原因`() {
        val msg = plan().resultMessage(deleted = 0, libraryRemoved = 0, error = null)
        assertTrue(msg.contains("网盘拒绝了删除请求"))
    }
}
