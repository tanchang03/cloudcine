package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「从媒体库移除」的**档位与措辞**（`RemovalPlan`）—— 不碰 SQLite、不碰
 * Activity、不碰真网盘。
 *
 * ## 为什么这些字值得单独测
 *
 * 这条路径上最重的两句话都是**说错了不报错**的那种：
 *
 *   1. 「网盘文件原样保留」—— 它是「移除」这个词最需要被解释的一件事，
 *      但勾了一并删之后它就是假话；
 *   2. 「会删 N 个，不可撤销」—— 少这一句，用户按下去之后才发现，而那时
 *      已经没有回头路。
 *
 * 靠人在电视上逐条读是读不出「少了一句」的（看着都很正常），所以钉在这里。
 */
class RemovalPlanTest {

    private val quark = "quark"
    private val baidu = "baidu"

    // ------------------------------------------------------------------
    // 统计
    // ------------------------------------------------------------------

    /** 夸克算可删、百度算只读，且**按 id 去重**。 */
    @Test
    fun `统计把夸克算可删百度算只读并按 id 去重`() {
        val t = RemovalTally.of(
            listOf(
                "quark:1" to quark,
                "quark:2" to quark,
                // 同一集被两次 `itemsForWork` 拿到（并集口径）—— 只算一次。
                "quark:2" to quark,
                "baidu:9" to baidu,
            ),
            aliases = 1,
        )
        assertEquals("夸克上的可删文件数", 2, t.deletable)
        assertEquals("百度上的只读文件数", 1, t.undeletable)
        assertEquals("别名行数", 1, t.aliases)
    }

    /** 名下没有文件时 [RemovalTally.hasDeletable] 为假 —— 那一档不该出现。 */
    @Test
    fun `没有可删文件时 hasDeletable 为假`() {
        assertFalse(RemovalTally().hasDeletable)
        assertFalse(RemovalTally.of(emptyList()).hasDeletable)
        assertTrue(RemovalTally.of(listOf("q:1" to quark)).hasDeletable)
    }

    // ------------------------------------------------------------------
    // 档位
    // ------------------------------------------------------------------

    /**
     * 顺序是红线：取消 → 只移除索引 → 一并删网盘。
     *
     * `showOverlay` 的光标从 0 开始，第一个非取消项就是按 OK 直接落到的
     * 那一档 —— 反过来排等于让一次顺手确认永久删掉一季的片子。
     */
    @Test
    fun `档位顺序是取消只移除索引再一并删网盘`() {
        val labels = RemovalPlan.labels(3, RemovalTally(deletable = 7), canDeleteFromDrive = true)
        assertEquals(3, labels.size)
        assertEquals("第 0 档必须是取消（光标默认停在这里）", RemovalPlan.LABEL_CANCEL, labels[0])
        assertTrue(
            "第 1 档必须是「只移除索引」，且要写出「网盘文件保留」",
            labels[1].startsWith("只移除索引") && labels[1].contains("网盘文件保留"),
        )
        assertTrue(
            "第 2 档要带上**会删几个**：用户按下去之前唯一的判断依据",
            labels[2].contains("一并删除网盘文件") && labels[2].contains("7 个") &&
                labels[2].contains("不可撤销"),
        )
    }

    /** 没有可删文件（或当前网盘删不了）时**不给**那一档：一个什么都不做的开关比没有更糟。 */
    @Test
    fun `删不了的时候不给一并删那一档`() {
        val labels = RemovalPlan.labels(2, RemovalTally(deletable = 4), canDeleteFromDrive = false)
        assertEquals(2, labels.size)
        assertTrue(labels.none { it.contains("一并删除") })
    }

    // ------------------------------------------------------------------
    // 正文
    // ------------------------------------------------------------------

    /** 能删时：说清删多少 + 不可逆 + 本应用救不回来。 */
    @Test
    fun `能删时正文写清文件数与不可撤销`() {
        val text = RemovalPlan.title(2, RemovalTally(deletable = 5), canDeleteFromDrive = true)
        assertTrue("要有部数", text.contains("要从媒体库移除这 2 部吗？"))
        assertTrue("要说出会删几个", text.contains("5 个文件"))
        assertTrue("要写不可撤销", text.contains("不可撤销"))
        assertTrue("要写本应用恢复不了", text.contains("恢复不了"))
        // 好消息也不能丢：它解释的是「不勾那档会发生什么」。
        assertTrue("要说清默认只动索引", text.contains("重新扫描"))
    }

    /**
     * 有文件可删、但这次删不了（夸克没登录）。
     *
     * ⛔ 不能一声不响：用户会以为「这台电视不支持删网盘」，然后去文件列表里
     *    一个个手删。
     * ⛔ 也**不能说「当前网盘不支持删除」** —— 媒体库不按网盘分区，能不能删
     *    只取决于夸克登没登录。说成「当前网盘」的话，用户在夸克的文件列表里
     *    明明能删、回媒体库却被说成不支持（2026-10-24 现场）。
     */
    @Test
    fun `有文件可删但当前删不了时正文要解释`() {
        val text = RemovalPlan.title(1, RemovalTally(deletable = 4), canDeleteFromDrive = false)
        assertTrue(text.contains("4 个文件"))
        assertTrue("要说明是夸克没登录", text.contains("夸克网盘没有登录"))
        assertTrue("要给出下一步（去登录）", text.contains("登录夸克"))
        assertTrue(text.contains("只能移除索引"))
        assertTrue("这时候不能说会永久删除", !text.contains("不可撤销"))
        assertTrue(
            "⛔ 不能再说「当前网盘不支持删除」：媒体库与 activeProvider 无关。",
            !text.contains("当前网盘不支持"),
        )
    }

    /** 只读网盘上的那几个**怎么都删不掉**，必须单独说一句。 */
    @Test
    fun `只读网盘上的文件单独说一句`() {
        val text = RemovalPlan.title(1, RemovalTally(deletable = 2, undeletable = 3), canDeleteFromDrive = true)
        assertTrue(text.contains("另有 3 个文件"))
        assertTrue(text.contains("百度"))
        assertTrue(text.contains("原样保留"))
    }

    /** 别名行会跟着目标一起走 —— 界面上看不出这件事。 */
    @Test
    fun `别名行会额外说一句`() {
        val one = RemovalPlan.title(1, RemovalTally(aliases = 1), canDeleteFromDrive = false)
        assertTrue(one.contains("其中 1 部是合并出来的别名行"))
        val two = RemovalPlan.title(2, RemovalTally(aliases = 2), canDeleteFromDrive = false)
        assertTrue(two.contains("其中 2 部是合并出来的别名行"))
        val none = RemovalPlan.title(2, RemovalTally(), canDeleteFromDrive = false)
        assertTrue("没有别名行时不该出现这句", !none.contains("别名行"))
    }

    /** 单部删除用书名号，而不是「这 1 部」。 */
    @Test
    fun `单部删除的标题用书名号`() {
        val text = RemovalPlan.title(1, RemovalTally(), canDeleteFromDrive = false, singleTitle = "遮天")
        assertTrue(text.startsWith("要从媒体库移除《遮天》吗？"))
        assertTrue(!text.contains("这 1 部"))
    }

    // ------------------------------------------------------------------
    // 结果提示
    // ------------------------------------------------------------------

    /** 三个数字缺一不可：部数 / 文件行数 / 网盘成功与失败。 */
    @Test
    fun `结果提示把三个数字都说出来`() {
        val msg = RemovalPlan.message(
            2,
            RemovalOutcome(5, DriveRemoval(deleted = 4, failed = 1, error = "限流")),
        )
        assertTrue(msg.contains("已移除 2 部"))
        assertTrue(msg.contains("5 个文件"))
        assertTrue(msg.contains("4 个成功"))
        assertTrue(msg.contains("1 个失败"))
        assertTrue(msg.contains("限流"))
    }

    /** 没勾「一并删」时必须说「网盘文件未动」—— 那是用户最需要知道的一句。 */
    @Test
    fun `没删网盘时提示网盘文件未动`() {
        val msg = RemovalPlan.message(1, RemovalOutcome(2, null))
        assertTrue(msg.contains("已移除 1 部"))
        assertTrue(msg.contains("网盘文件未动"))
    }

    /** 一个都没删掉：不能说成「未动」，也不能说成删干净了。 */
    @Test
    fun `网盘一个都没删掉时要说清原因`() {
        val msg = RemovalPlan.message(
            1,
            RemovalOutcome(3, DriveRemoval(deleted = 0, failed = 3, error = "登录已失效")),
        )
        assertTrue(msg.contains("一个都没删掉"))
        assertTrue(msg.contains("登录已失效"))
        assertTrue("不能说成网盘文件未动 —— 用户会以为自己的选择没生效", !msg.contains("网盘文件未动"))
    }

    /**
     * 「想删但名下没有可删文件」与「没打算删网盘」是两件事。
     *
     * 前者说成「未动」会让用户以为勾选没生效；后者说成「没删掉」又像出错。
     */
    @Test
    fun `想删但没有可删文件时不说未动`() {
        val msg = RemovalPlan.message(1, RemovalOutcome(2, DriveRemoval(deleted = 0, failed = 0)))
        assertTrue(msg.contains("没有可删的网盘文件"))
        assertTrue(!msg.contains("网盘文件未动"))
    }
}
