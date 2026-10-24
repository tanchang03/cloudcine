package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「这个文件已经不在网盘上了」那个确认框的**措辞与档位**。
 *
 * 这类错的形态是「看着很正常，但少说了一句关键的」：说漏「只动这台电视」，
 * 用户以为按钮会去网盘再删一次；说漏「这是最后一条」，用户以为只删了一集，
 * 回头发现整部都不见了。两条都**不报错、不崩、日志干净** —— 只能靠断言钉住。
 */
class MissingMediaPlanTest {

    private val last = MissingMediaPlan(
        fileName = "S01E07.mkv",
        workTitle = "漫长的季节",
        remainingItems = 0,
    )

    private val middle = last.copy(remainingItems = 23)

    /** 标题必须点名那个文件：用户刚从播放页回来，认得的是文件名。 */
    @Test
    fun `标题点名那个文件`() {
        assertTrue(
            "标题里没有文件名，用户没法确认问的是哪一个：${last.title}",
            last.title.contains("S01E07.mkv"),
        )
        assertTrue(
            "标题没说「不在网盘上了」，只说「播不了」的话用户会去查网络：${last.title}",
            last.title.contains("不在网盘上"),
        )
    }

    /**
     * ⛔ 必须说清「只动这台电视」。
     *
     * 用户对「移除」的预期是「文件也没了」。这一条的文件本来就没了，所以这句
     * 话更要说 —— 否则他会以为这个按钮会去网盘上再删一次（或者相反，以为
     * 按了也没用、因为文件已经没了）。
     */
    @Test
    fun `正文说清只动本机索引`() {
        assertTrue(
            "正文没有「只影响这台电视上的索引」这一句：${last.detail}",
            last.detail.contains("只影响这台电视上的索引"),
        )
        assertTrue(
            "正文没有「网盘那边不会再删任何东西」这一句：${last.detail}",
            last.detail.contains("不会再删任何东西"),
        )
    }

    /**
     * ⛔ 整段正文里**不能出现**「整部」。
     *
     * 范围刻意只到「这一条」：用户是退回媒体库之后才被问的，眼前就是文件列表，
     * 他能看见还有几集在。这时候给一个「移除整部」的选项，等于把一次误触
     * 变成灾难（见 `MissingMediaPlan` 类文档）。
     */
    @Test
    fun `正文不提供整部范围`() {
        assertFalse(
            "正文里出现了「整部」—— 这个确认框只该有「这一条」一个范围：${middle.body}",
            middle.body.contains("整部"),
        )
        assertFalse(
            "确认按钮里出现了「整部」：${middle.confirmLabel}",
            middle.confirmLabel.contains("整部"),
        )
        assertTrue(
            "确认按钮必须写「这一条」（范围是用户最该核对的东西）：${middle.confirmLabel}",
            middle.confirmLabel.contains("这一条"),
        )
    }

    /** 还有别的条目时，说「还有 N 条会留在库里」。 */
    @Test
    fun `还有别的条目时说还剩几条`() {
        assertTrue(
            "`remainingItems=23` 时没有说「还有 23 条」：${middle.remainingLine}",
            middle.remainingLine.contains("23"),
        )
        assertTrue(
            "没有「会留在库里」这半句，用户会以为剩下的也被删了：${middle.remainingLine}",
            middle.remainingLine.contains("留在库里"),
        )
    }

    /**
     * ⛔ 最后一条必须**单独**说「整部会从作品墙消失」。
     *
     * `purgeDriveEntry` 会把因此变空的作品行一起删掉。不提前说，用户会以为
     * 「我只删了一集，怎么整部都没了」—— 而那时已经回不去了。
     */
    @Test
    fun `最后一条时预告整部会消失`() {
        assertTrue(
            "最后一条没有预告「从作品墙上消失」：${last.remainingLine}",
            last.remainingLine.contains("从作品墙上消失"),
        )
        assertTrue(
            "预告里没有片名，用户不知道消失的是哪一部：${last.remainingLine}",
            last.remainingLine.contains("漫长的季节"),
        )
        assertFalse(
            "最后一条不该说「还有 N 条」：${last.remainingLine}",
            last.remainingLine.contains("留在库里"),
        )
    }

    /** 三句必须**一起**出现在 `body` 里（少一句就是一次误导）。 */
    @Test
    fun `正文把三句拼在一起`() {
        val body = middle.body
        assertTrue("`body` 里没有标题：$body", body.contains(middle.title))
        assertTrue("`body` 里没有原因那句：$body", body.contains(middle.detail))
        assertTrue("`body` 里没有「还剩几条」那句：$body", body.contains(middle.remainingLine))
    }

    /**
     * ⛔ 「取消」必须是第一档。
     *
     * `showOverlay` 的光标从第 0 档开始 —— 取消排第一 ⇒ 用户顺手按 OK 什么
     * 都不会发生。反了等于一次顺手确认就清掉一条索引（与 `RemovalPlan.labels`
     * 同一条红线）。
     */
    @Test
    fun `取消排在第一位`() {
        val labels = middle.labels()
        assertEquals("档位数不对（取消 + 移除这一条）：$labels", 2, labels.size)
        assertEquals("第一档不是取消：$labels", MissingMediaPlan.CANCEL, labels[0])
        assertEquals("第二档不是「移除这一条」：$labels", middle.confirmLabel, labels[1])
    }

    /** 结果提示三条分支：还有别的 / 最后一条 / 本来就不在库里。 */
    @Test
    fun `结果提示三条分支`() {
        val kept = middle.doneMessage(1)
        assertTrue("移除成功后没说文件名：$kept", kept.contains("S01E07.mkv"))
        assertTrue("还有别的条目时没说剩几条：$kept", kept.contains("还有 23 条"))

        val gone = last.doneMessage(1)
        assertTrue(
            "最后一条移除后没说作品已从作品墙移除：$gone",
            gone.contains("已从作品墙移除"),
        )

        val nothing = last.doneMessage(0)
        assertTrue(
            "一条都没删时却说「已移除」—— 用户会以为库变了：$nothing",
            nothing.contains("本来就不在媒体库里"),
        )
    }
}
