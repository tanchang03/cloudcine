package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 播放页 OSD 的**光标判据** —— [OsdFocus] 就是 `TvOsdView` 画右侧纵向列表时
 * 用的那一条。
 *
 * ## 为什么这一条必须钉死
 *
 * 写错它**不会报错、不会崩、日志里一个字都没有** —— 表现只是「菜单一打开，
 * 右半边有一块亮色」，而按键其实管的是左栏。2026-10-11 用户的原话：
 *
 * > 「默认菜单打开后，看起来焦点在选集列表，但是实际上在导航菜单」
 *
 * 这类「看起来对、按下去不对」的错，在真机上要按几下才反应得过来，
 * 所以判据落在这里。
 */
class OsdFocusTest {

    /**
     * ⛔ **本组是这次修复的核心**：默认打开菜单时光标在左栏（`inList == false`），
     * 纵向列表里那一项**不许**画光标态 —— 否则屏幕上就有两块亮色，
     * 用户会以为焦点在列表里。
     */
    @Test
    fun `没进列表时纵向列表项不画光标`() {
        assertFalse(
            "光标在左栏、却把列表项画成光标 —— 用户会以为 ↑↓ 是在列表里选",
            OsdFocus.listItemIsCursor(position = 0, cursor = 0, inList = false),
        )
    }

    /** 按 →/OK 进了列表 ⇒ 那一项必须**立刻**亮起来，否则用户不知道能上下选。 */
    @Test
    fun `进了列表后光标所在项发光`() {
        assertTrue(
            OsdFocus.listItemIsCursor(position = 3, cursor = 3, inList = true),
        )
    }

    /**
     * ⛔ 只有**光标那一项**发光。判据里 `position == cursor` 掉了的话，
     *    整列会一起亮（真机上极刺眼，但纯逻辑上「多亮几行」看着毫无问题）。
     */
    @Test
    fun `列表里非光标项永远不发光`() {
        assertFalse(
            OsdFocus.listItemIsCursor(position = 2, cursor = 3, inList = true),
        )
    }

    /**
     * ⛔ 这条守住「退出列表要收掉高亮」：← 退回左栏之后（`inList = false`），
     *    哪怕 `selChip` 还停在原来那一项上，也不能再发光。
     *    `selChip` 在退出列表时**刻意不复位**（下次进列表要停在原地），
     *    所以「位置对得上」这件事本身不足以说明它是光标。
     */
    @Test
    fun `退回左栏后原光标项不再发光`() {
        assertFalse(
            OsdFocus.listItemIsCursor(position = 5, cursor = 5, inList = false),
        )
    }

    // ==================================================================
    // 光标的可见性（纵向列表怎么滚）
    // ==================================================================

    /**
     * ⛔ **本组是「焦点看起来没动、数据在滚」那个反馈的核心。**
     *
     * 光标还在可视区里时，列表**一格都不许滚** —— 高亮自己往下走。
     * 判据写错（比如退化成「总是滚到第一行」）的后果就是原话里的现象：
     * 高亮框钉在第一行，底下的内容整体平移。
     */
    @Test
    fun `光标在可视区内时不滚动`() {
        assertEquals(
            "光标从第 1 行挪到第 2 行（可视区 0~5），列表不该滚",
            OsdFocus.ListScroll.KEEP,
            OsdFocus.listScrollFor(cursor = 1, firstVisible = 0, lastVisible = 5),
        )
        assertEquals(
            "可视区正中间挪一格，同样不该滚",
            OsdFocus.ListScroll.KEEP,
            OsdFocus.listScrollFor(cursor = 4, firstVisible = 2, lastVisible = 6),
        )
    }

    /** 撞到下边界 ⇒ 光标留在底行，内容往上滚。 */
    @Test
    fun `光标越过下边界时滚到底行`() {
        assertEquals(
            OsdFocus.ListScroll.TO_BOTTOM,
            OsdFocus.listScrollFor(cursor = 7, firstVisible = 2, lastVisible = 6),
        )
    }

    /** 撞到上边界 ⇒ 光标留在首行，内容往下滚。 */
    @Test
    fun `光标越过上边界时滚到首行`() {
        assertEquals(
            OsdFocus.ListScroll.TO_TOP,
            OsdFocus.listScrollFor(cursor = 1, firstVisible = 2, lastVisible = 6),
        )
    }

    /**
     * ⛔ 边界值必须算「在区内」：`cursor == firstVisible` 与
     *    `cursor == lastVisible` 都**不该**触发滚动 —— 差一格的判据
     *    （写成 `<=` / `>=`）会让光标每挪到边界就白滚一次，
     *    手感立刻变成「一顿一顿」。
     */
    @Test
    fun `正好在可视区两端时也不滚动`() {
        assertEquals(
            OsdFocus.ListScroll.KEEP,
            OsdFocus.listScrollFor(cursor = 2, firstVisible = 2, lastVisible = 6),
        )
        assertEquals(
            OsdFocus.ListScroll.KEEP,
            OsdFocus.listScrollFor(cursor = 6, firstVisible = 2, lastVisible = 6),
        )
    }
}
