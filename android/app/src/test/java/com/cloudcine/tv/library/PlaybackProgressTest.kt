package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 进度模型（[ProgressEntry] / [ProgressBook]）的**纯逻辑**单测。
 *
 * 这里覆盖的是这个功能里最不能出错的一段：**合并方向**。它一旦错了，表现是
 * 「两台设备各看一集，其中一集的进度莫名消失」，而且两边都显示同步成功 ——
 * 没有任何报错可以查。
 *
 * ## ⛔ 为什么专门测「跨端 JSON 形状」
 *
 * 这份 JSON 是**跨端契约**：电视写、电脑读，反之亦然。字段名（`r`/`m`/`p`/`u`、
 * 顶层 `v`/`items`）与 PC 端 `playback_progress.dart` **逐字对齐**，改一个字母
 * 就会变成「两端的进度永远合不到一起」，而两边各自的自测全绿。
 * 所以下面用**手写的字面量 JSON**（模拟对面写出来的字节）来验，而不是只做
 * 「自己序列化 → 自己反序列化」的往返 —— 那种往返在两端都改错时一样会过。
 */
class PlaybackProgressTest {

    private fun entry(
        resume: Long? = null,
        max: Long? = null,
        played: Long? = null,
        updated: Long,
    ) = ProgressEntry(resumeMs = resume, maxMs = max, playedAtSec = played, updatedAtSec = updated)

    // ------------------------------------------------------------------
    // mergedWith：三条规则
    // ------------------------------------------------------------------

    @Test
    fun `updatedAtSec 大的一方拿走续播点与已读时间`() {
        val mine = entry(resume = 1000, played = 100, updated = 100)
        val theirs = entry(resume = 9000, played = 200, updated = 200)

        val merged = mine.mergedWith(theirs)

        assertEquals("远程的 u 更大 ⇒ 它的续播点赢", 9000L, merged.resumeMs)
        assertEquals("已读时间也归它", 200L, merged.playedAtSec)
        assertEquals(200L, merged.updatedAtSec)
    }

    @Test
    fun `updatedAtSec 相等时保留自己（两台机器同秒写入不会来回抖）`() {
        val mine = entry(resume = 111, played = 1, updated = 500)
        val theirs = entry(resume = 222, played = 2, updated = 500)

        val merged = mine.mergedWith(theirs)

        assertEquals("相等时自己赢（`>=`）", 111L, merged.resumeMs)
        assertEquals("已读时间走的是「取较大值」那条规则，与谁赢无关", 2L, merged.playedAtSec)
    }

    @Test
    fun `maxMs 取两边的较大值 —— 与谁赢无关`() {
        // ⛔ 这条与规则 1 **方向相反**是刻意的。把 maxMs 也交给 LWW 的话，
        //    「另一台机器看得更远」会被一次较晚、位置较浅的写入抹掉，
        //    而用户看到的是**进度条倒退**。
        val mine = entry(max = 60_000, updated = 100) // 自己旧，但看得更远
        val theirs = entry(max = 5_000, updated = 900) // 对方新，但只看了开头

        val merged = mine.mergedWith(theirs)

        assertEquals("更远的那份留下", 60_000L, merged.maxMs)
        assertEquals("合并依据仍是更新的那一方", 900L, merged.updatedAtSec)
    }

    @Test
    fun `playedAtSec 也取较大值 —— 最近播放不该倒退`() {
        val mine = entry(played = 9000, updated = 100)
        val theirs = entry(played = 10, updated = 900)

        val merged = mine.mergedWith(theirs)

        assertEquals(9000L, merged.playedAtSec)
    }

    @Test
    fun `null 与 null 相加仍是 null，不编出 0`() {
        // 自己是更新的那一方，而对方三个业务字段全空 ⇒ 合并后仍是自己那份。
        val merged = entry(resume = 10, updated = 2).mergedWith(entry(updated = 1))
        assertNull("对方没看过 ⇒ max 保持 null（不能编出 0）", merged.maxMs)
        assertNull(merged.playedAtSec)
        assertEquals("赢的那方有续播点", 10L, merged.resumeMs)
    }

    // ------------------------------------------------------------------
    // JSON 形状（跨端契约）
    // ------------------------------------------------------------------

    @Test
    fun `序列化省略 null 字段并只用短键`() {
        val json = entry(resume = 1000, max = 5000, played = 100, updated = 200).toJson()
        assertEquals(mapOf("r" to 1000L, "m" to 5000L, "p" to 100L, "u" to 200L), json)

        // 只有「已读回执」的那一条（点开没看够 10 秒）：三个业务字段只写一个。
        val readOnly = entry(played = 7, updated = 8).toJson()
        assertEquals(mapOf("p" to 7L, "u" to 8L), readOnly)
    }

    @Test
    fun `能读懂 PC 端写出来的字面量 JSON`() {
        // 这一串是照 `playback_progress.dart` 的 `toJson()` 手写的：顶层
        // `v` + `items`，每条短键。⛔ 别改成「自己序列化的结果」—— 那样两端
        // 同时改错也会过。
        val fromPc = """
            {"v":1,"items":{
              "quark:F1":{"r":123456,"m":999999,"p":1791285373,"u":1791285400},
              "quark:F2":{"p":1791285374,"u":1791285374},
              "quark:F3":{"u":1791285375}
            }}
        """.trimIndent()

        val book = ProgressBook.fromJsonString(fromPc)

        assertEquals(3, book.length)
        assertEquals(123456L, book["quark:F1"]!!.resumeMs)
        assertEquals(999999L, book["quark:F1"]!!.maxMs)
        assertEquals(1791285373L, book["quark:F1"]!!.playedAtSec)
        assertNull("F2 只点开过 ⇒ 没有位置", book["quark:F2"]!!.resumeMs)
        assertTrue("F2 是「只有已读」", book["quark:F2"]!!.isReadOnly)
        assertTrue("F3 三个业务字段全空", book["quark:F3"]!!.isEmpty)
    }

    @Test
    fun `我们写出来的字节 PC 端能读（顶层结构与短键逐字一致）`() {
        val book = ProgressBook()
        book["quark:F1"] = entry(resume = 1000, max = 5000, played = 100, updated = 200)

        // ⛔ 断的是**字面量**而不是「再解析回来」：PC 端 `jsonDecode` 读的就是
        //    这串文本，多一个空格/少一个字段都可能让它的 `as int?` 拿到 null。
        assertEquals("""{"v":1,"items":{"quark:F1":{"r":1000,"m":5000,"p":100,"u":200}}}""", book.toJsonString())
    }

    @Test
    fun `缺 u 的条目整条丢弃（没有合并判据）`() {
        val book = ProgressBook.fromJsonString("""{"v":1,"items":{"a":{"r":1},"b":{"u":2}}}""")
        assertEquals("只有 b 活下来", 1, book.length)
        assertNull(book["a"])
        assertEquals(2L, book["b"]!!.updatedAtSec)
    }

    @Test
    fun `字段类型不对时整条丢弃，绝不抛`() {
        // `u` 是字符串 / 是对象 / 是数组 —— 三种都不该让它进合并。
        val book = ProgressBook.fromJsonString(
            """{"v":1,"items":{"a":{"u":"x"},"b":{"u":{}},"c":{"u":[1]},"d":{"u":3}}}""",
        )
        assertEquals(1, book.length)
        assertEquals(3L, book["d"]!!.updatedAtSec)
    }

    @Test
    fun `浮点写法的数字也认（1000 点 0 不该被丢掉）`() {
        // 别的实现（或未来某个版本）完全可能把整数写成浮点。
        val book = ProgressBook.fromJsonString("""{"v":1,"items":{"a":{"r":1000.0,"u":2e3}}}""")
        assertEquals(1000L, book["a"]!!.resumeMs)
        assertEquals(2000L, book["a"]!!.updatedAtSec)
    }

    @Test
    fun `损坏、截断、空文件一律退回空书，不抛`() {
        assertEquals(0, ProgressBook.fromJsonString("").length)
        assertEquals(0, ProgressBook.fromJsonString("{").length)
        assertEquals(0, ProgressBook.fromJsonString("[]").length)
        assertEquals(0, ProgressBook.fromJsonString("这不是 JSON").length)
        assertEquals(0, ProgressBook.fromBytes(byteArrayOf(0xFF.toByte(), 0x00)).length)
    }

    // ------------------------------------------------------------------
    // ProgressBook.mergeFrom
    // ------------------------------------------------------------------

    @Test
    fun `mergeFrom 返回被改变的条数 —— 0 意味着不用上传`() {
        val mine = ProgressBook()
        mine["a"] = entry(resume = 1, updated = 10)

        val theirs = ProgressBook()
        theirs["a"] = entry(resume = 1, updated = 10) // 一模一样
        assertEquals("内容相同 ⇒ 0 条改变 ⇒ 不传", 0, mine.mergeFrom(theirs))

        val newer = ProgressBook()
        newer["a"] = entry(resume = 2, updated = 20)
        newer["b"] = entry(resume = 3, updated = 20)
        assertEquals("一条覆盖 + 一条新增", 2, mine.mergeFrom(newer))

        assertEquals("a 被更新的那份覆盖（续播点 2，不是合并依据 20）", 2L, mine["a"]!!.resumeMs)
        assertEquals("合并依据也跟过来", 20L, mine["a"]!!.updatedAtSec)
        assertEquals(3L, mine["b"]!!.resumeMs)
    }

    @Test
    fun `mergeFrom 不会因为对方更旧而把本地进度改小`() {
        val mine = ProgressBook()
        mine["a"] = entry(resume = 9000, max = 9000, played = 900, updated = 900)

        val older = ProgressBook()
        older["a"] = entry(resume = 100, max = 100, played = 100, updated = 100)

        assertEquals(0, mine.mergeFrom(older))
        assertEquals(9000L, mine["a"]!!.resumeMs)
        assertEquals(9000L, mine["a"]!!.maxMs)
    }

    @Test
    fun `两端各看一集 —— 两条都留下（逐条 LWW 的全部意义）`() {
        // 这是「整份 LWW」会出错的场景：后推的那份会把对方那一集抹掉。
        val deviceA = ProgressBook()
        deviceA["ep1"] = entry(resume = 60_000, updated = 1000)

        val deviceB = ProgressBook()
        deviceB["ep2"] = entry(resume = 30_000, updated = 2000)

        val merged = ProgressBook(LinkedHashMap(deviceA.items))
        merged.mergeFrom(deviceB)

        assertEquals(2, merged.length)
        assertEquals(60_000L, merged["ep1"]!!.resumeMs)
        assertEquals(30_000L, merged["ep2"]!!.resumeMs)
    }

    @Test
    fun `isEmpty 与 isReadOnly 的边界`() {
        assertTrue(entry(updated = 1).isEmpty)
        assertFalse(entry(resume = 1, updated = 1).isEmpty)
        assertTrue(entry(played = 1, updated = 1).isReadOnly)
        assertFalse("有位置就不是「只有已读」", entry(resume = 1, played = 1, updated = 1).isReadOnly)
        assertFalse("maxMs 也算位置", entry(max = 1, played = 1, updated = 1).isReadOnly)
    }
}
