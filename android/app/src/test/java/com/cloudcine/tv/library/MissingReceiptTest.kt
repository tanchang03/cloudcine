package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test

/**
 * 回执槽位的语义：**取走即清空**。
 *
 * 这条不变量看着琐碎，错了的表现却很显眼：媒体库页每次 `onResume` 都会取一次，
 * 槽位不清的话用户之后每进出一次别的页面，就被问一遍「这个文件没了，要移除吗」
 * —— 而那个文件他早就处理过了。
 */
class MissingReceiptTest {

    private val receipt = MissingReceipt(
        fid = "f1",
        provider = "quark",
        name = "S01E07.mkv",
        groupKey = "g1",
    )

    @Before
    fun clean() {
        MissingReceipts.resetForTest()
    }

    /** 空槽位取出来是 `null`（首次 `onCreate` 之后 `onResume` 就会走到）。 */
    @Test
    fun `空槽位取出 null`() {
        assertNull(MissingReceipts.take())
    }

    /** 放进去、取出来、再取就没了 —— 这条是防「反复追问」。 */
    @Test
    fun `取走即清空`() {
        MissingReceipts.put(receipt)
        assertSame(receipt, MissingReceipts.take())
        assertNull("第二次 `take()` 必须拿不到 —— 否则每进出一次页面就问一遍", MissingReceipts.take())
    }

    /** 取链又成功了要能撤掉（换集时前一集的回执不该留着）。 */
    @Test
    fun `clear 之后取不到`() {
        MissingReceipts.put(receipt)
        MissingReceipts.clear()
        assertNull(MissingReceipts.take())
    }

    /** 后一张覆盖前一张：只关心「最后一次失败的那一条」。 */
    @Test
    fun `后写入的覆盖前一张`() {
        MissingReceipts.put(receipt)
        val next = receipt.copy(fid = "f2")
        MissingReceipts.put(next)
        assertSame(next, MissingReceipts.take())
    }

    /** `itemId` 是跨端契约的形状（`media_items.id`）—— 拼错就一条都查不到。 */
    @Test
    fun `itemId 是 provider 冒号 fileId`() {
        assertEquals("quark:f1", receipt.itemId)
        assertEquals("baidu:f1", receipt.copy(provider = "baidu").itemId)
    }
}
