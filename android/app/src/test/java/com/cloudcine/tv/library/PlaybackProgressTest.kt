package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 进度模型（[ProgressEntry] / [WorkSkipEntry] / [ProgressBook]）的**纯逻辑**单测。
 *
 * 这里覆盖的是这个功能里最不能出错的一段：**合并方向**。它一旦错了，表现是
 * 「两台设备各看一集，其中一集的进度莫名消失」，而且两边都显示同步成功 ——
 * 没有任何报错可以查。
 *
 * ## ⛔ 为什么专门测「跨端 JSON 形状」
 *
 * 这份 JSON 是**跨端契约**：电视写、电脑读，反之亦然。字段名（`r`/`m`/`p`/`u`、
 * 作品段的 `is`/`ie`/`oo`/`mu`/`le`/`lo`/`ls`/`lu`、顶层 `v`/`items`/`works`）
 * 与 PC 端 `playback_progress.dart` **逐字对齐**，改一个字母就会变成「两端的
 * 进度永远合不到一起」，而两边各自的自测全绿。
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

    private fun skip(
        introStart: Long? = null,
        introEnd: Long? = null,
        outroOffset: Long? = null,
        manualAt: Long = 0,
        learnedIntroEnd: Long? = null,
        learnedOutroOffset: Long? = null,
        learnedSamples: Int = 0,
        learnedAt: Long = 0,
    ) = WorkSkipEntry(
        introStartMs = introStart,
        introEndMs = introEnd,
        outroOffsetMs = outroOffset,
        manualUpdatedAtSec = manualAt,
        learnedIntroEndMs = learnedIntroEnd,
        learnedOutroOffsetMs = learnedOutroOffset,
        learnedSamples = learnedSamples,
        learnedUpdatedAtSec = learnedAt,
    )

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
        //    ⚠️ 顶层 `v` 是**格式版本**（v2 起多了 `works` 段），两端只在字段
        //    增删时才动它 —— 改了这里就必须同步改 `playback_progress.dart`。
        assertEquals("""{"v":2,"items":{"quark:F1":{"r":1000,"m":5000,"p":100,"u":200}}}""", book.toJsonString())
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

    // ------------------------------------------------------------------
    // WorkSkipEntry.mergedWith：两组各判各的
    // ------------------------------------------------------------------

    @Test
    fun `手标组与学习组各判各的 —— 手标时间戳大就手标赢，与学习无关`() {
        // ⛔ 这是「合成一个时间戳」最容易踩的那个坑：A 机手标了片头（manual 更新），
        //    B 机学出了片尾（learned 更新）。合成一个的话，后写的那次会把前一次
        //    整个抹掉，而两台机器都显示同步成功。
        val mine = skip(introStart = 0, introEnd = 95_000, manualAt = 900)
        val theirs = skip(learnedIntroEnd = 88_000, learnedSamples = 4, learnedAt = 100)

        val merged = mine.mergedWith(theirs)

        assertEquals("手标组：本机更新 ⇒ 本机的留下", 95_000L, merged.introEndMs)
        assertEquals(900L, merged.manualUpdatedAtSec)
        assertEquals("学习组：远程更新 ⇒ 远程的合进来", 88_000L, merged.learnedIntroEndMs)
        assertEquals(4, merged.learnedSamples)
        assertEquals(100L, merged.learnedUpdatedAtSec)
    }

    @Test
    fun `学习组更新时整组替换 —— 清除动作必须能赢`() {
        // 场景：用户点了「清除自动学习的结论」。清除写的是「空组 + 时间戳前进」，
        // 若按字段合并，清除只会清掉一半，界面上看起来是「清不干净」。
        val mine = skip(learnedIntroEnd = 88_000, learnedOutroOffset = 70_000, learnedSamples = 4, learnedAt = 100)
        val cleared = skip(learnedAt = 500) // 学习组整组为空，但时刻前进

        val merged = mine.mergedWith(cleared)

        assertNull("片头结论被清掉", merged.learnedIntroEndMs)
        assertNull("片尾结论也一起清掉（整组替换）", merged.learnedOutroOffsetMs)
        assertEquals(0, merged.learnedSamples)
        assertEquals("清除留下的时刻要保住，否则下一轮又会输给旧结论", 500L, merged.learnedUpdatedAtSec)
        assertFalse("清干净之后这条就什么都不是了", merged.hasLearned)
    }

    @Test
    fun `两组时间戳都相等时保留自己（同秒写入不会来回抖）`() {
        val mine = skip(introStart = 0, introEnd = 111, manualAt = 500, learnedIntroEnd = 111, learnedAt = 500)
        val theirs = skip(introStart = 0, introEnd = 222, manualAt = 500, learnedIntroEnd = 222, learnedAt = 500)

        val merged = mine.mergedWith(theirs)

        assertEquals(111L, merged.introEndMs)
        assertEquals(111L, merged.learnedIntroEndMs)
    }

    @Test
    fun `hasManual 与 hasLearned 的边界 —— 半条手标也算有内容`() {
        // ⚠️ 与 PC 端 `WorkSkipFormat` 的「半条不算一条完整片头」是**两个判据**：
        //    那边管的是「要不要显示这一行」，这边管的是「要不要把这一组同步出去」。
        //    半条手标（只有起点）仍然要同步 —— 否则用户在 PC 上标了一半、电视上
        //    看不到。
        assertTrue("只有起点也算有内容", skip(introStart = 0).hasManual)
        assertTrue("只有片尾也算有内容", skip(outroOffset = 70_000).hasManual)
        assertFalse("时间戳不算内容", skip(manualAt = 500).hasManual)
        assertTrue(skip(learnedOutroOffset = 70_000).hasLearned)
        assertFalse("样本数不算内容", skip(learnedSamples = 9).hasLearned)
        assertTrue("两组都空 ⇒ 整条空", skip().isEmpty)
        assertFalse(skip(introStart = 0).isEmpty)
    }

    // ------------------------------------------------------------------
    // WorkSkipEntry 的 JSON 形状（跨端契约）
    // ------------------------------------------------------------------

    @Test
    fun `作品段的短键与 PC 端逐字一致`() {
        val json = skip(
            introStart = 0,
            introEnd = 90_000,
            outroOffset = 70_000,
            manualAt = 111,
            learnedIntroEnd = 88_000,
            learnedOutroOffset = 66_000,
            learnedSamples = 4,
            learnedAt = 222,
        ).toJson()

        // ⛔ 断的是**序列化出来的文本**而不是 Map 的相等：`Map.equals` 会拿
        //    `Int` 与 `Long` 的装箱类型去比，两边打印一模一样却判不相等 ——
        //    而真正跨端的东西本来就是这串文本（PC 端 `jsonDecode` 读的是它）。
        assertEquals(
            """{"is":0,"ie":90000,"oo":70000,"mu":111,"le":88000,"lo":66000,"ls":4,"lu":222}""",
            MiniJson.write(json),
        )
    }

    @Test
    fun `零时间戳与空字段都省掉（几千部作品也撑得住体积）`() {
        // 只有手标、从没学过 ⇒ 学习那四个键一个都不该出现。
        assertEquals(
            mapOf("ie" to 90_000L),
            skip(introEnd = 90_000, manualAt = 0).toJson(),
        )
        // ⛔ `mu` 为 0 时省掉，而不是写一个 0：0 的语义是「有内容但没有时间依据」，
        //    显式写出来会让人误以为它是个真实的时刻（1970 年）。
        assertEquals(
            mapOf("le" to 88_000L, "lu" to 7L),
            skip(learnedIntroEnd = 88_000, learnedSamples = 0, learnedAt = 7).toJson(),
        )
    }

    @Test
    fun `能读懂 PC 端写出来的作品段字面量 JSON`() {
        // ⛔ 这一串是照 `playback_progress.dart` 的 `WorkSkipEntry.toJson()` 手写的。
        //    别改成「自己序列化的结果」—— 那样两端同时改错也会过。
        val fromPc = """
            {"v":2,"items":{},"works":{
              "quark:G1":{"is":0,"ie":90000,"oo":70000,"mu":1791285373},
              "quark:G2":{"le":88000,"lo":66000,"ls":4,"lu":1791285400},
              "quark:G3":{"is":0}
            }}
        """.trimIndent()

        val book = ProgressBook.fromJsonString(fromPc)

        assertEquals(0, book.length)
        assertEquals(3, book.workCount)
        val g1 = book.skipFor("quark:G1")!!
        assertEquals(0L, g1.introStartMs)
        assertEquals(90_000L, g1.introEndMs)
        assertEquals(70_000L, g1.outroOffsetMs)
        assertEquals(1_791_285_373L, g1.manualUpdatedAtSec)
        assertFalse("G1 只有手标组", g1.hasLearned)

        val g2 = book.skipFor("quark:G2")!!
        assertFalse("G2 只有学习组", g2.hasManual)
        assertEquals(88_000L, g2.learnedIntroEndMs)
        assertEquals(4, g2.learnedSamples)

        assertTrue("G3 半条手标也要读进来", book.skipFor("quark:G3")!!.hasManual)
    }

    @Test
    fun `作品段两组全空的条目整条丢弃（不留空壳）`() {
        // ⛔ 留着空壳的话，「两边其实都没东西」会被判成有差异 ⇒ 每 30 分钟白传一次。
        val book = ProgressBook.fromJsonString(
            """{"v":2,"items":{},"works":{"w1":{"mu":5},"w2":{"ls":3},"w3":{"ie":90000}}}""",
        )
        assertEquals(1, book.workCount)
        assertNull(book.skipFor("w1"))
        assertNull("只有样本数不算内容", book.skipFor("w2"))
        assertEquals(90_000L, book.skipFor("w3")!!.introEndMs)
    }

    @Test
    fun `v1 老文件（没有 works 键）照读 —— 缺键是空段，不是空书`() {
        // ⛔ 老版本的进度文件就是这个形状。把「缺 works」当成「整份文件无效」
        //    会让所有老用户升级后进度全丢。
        val v1 = """{"v":1,"items":{"quark:F1":{"r":1000,"u":100}}}"""
        val book = ProgressBook.fromJsonString(v1)

        assertEquals(1, book.length)
        assertEquals(0, book.workCount)
        assertEquals(1000L, book["quark:F1"]!!.resumeMs)
        assertTrue("items 段还在 ⇒ 不是空书", book.isNotEmpty)
    }

    @Test
    fun `作品段为空时整个 works 键省掉`() {
        val book = ProgressBook()
        book["quark:F1"] = entry(resume = 1000, updated = 100)
        assertEquals(
            """{"v":2,"items":{"quark:F1":{"r":1000,"u":100}}}""",
            book.toJsonString(),
        )
    }

    @Test
    fun `putSkip 写入空条目等于删除`() {
        val book = ProgressBook()
        book.putSkip("w1", skip(introEnd = 90_000, manualAt = 5))
        assertEquals(1, book.workCount)

        book.putSkip("w1", skip())
        assertEquals(0, book.workCount)
        assertNull(book.skipFor("w1"))
    }

    // ------------------------------------------------------------------
    // ProgressBook.mergeFrom：两段都算
    // ------------------------------------------------------------------

    @Test
    fun `mergeFrom 把作品段的改动也算进返回值 —— 0 意味着不用上传`() {
        val mine = ProgressBook()
        mine.putSkip("w1", skip(introEnd = 90_000, manualAt = 5))

        val same = ProgressBook()
        same.putSkip("w1", skip(introEnd = 90_000, manualAt = 5))
        assertEquals("只改过片头标记也必须算出来，否则同步永远不触发", 0, mine.mergeFrom(same))

        val newer = ProgressBook()
        newer.putSkip("w1", skip(introEnd = 95_000, manualAt = 9))
        newer.putSkip("w2", skip(learnedIntroEnd = 88_000, learnedAt = 9))
        assertEquals("一条覆盖 + 一条新增", 2, mine.mergeFrom(newer))

        assertEquals(95_000L, mine.skipFor("w1")!!.introEndMs)
        assertEquals(88_000L, mine.skipFor("w2")!!.learnedIntroEndMs)
    }

    @Test
    fun `作品段与条目段互不干扰 —— 两段的键长得像也不能串`() {
        // ⛔ `items` 的键是 `provider:fileId`、`works` 的键是 `provider:groupId`。
        //    同名不同段的两条必须各归各的。
        val book = ProgressBook()
        book["quark:X"] = entry(resume = 60_000, updated = 100)
        book.putSkip("quark:X", skip(introEnd = 90_000, manualAt = 100))

        assertEquals(1, book.length)
        assertEquals(1, book.workCount)
        assertEquals(60_000L, book["quark:X"]!!.resumeMs)
        assertEquals(90_000L, book.skipFor("quark:X")!!.introEndMs)

        val parsed = ProgressBook.fromJsonString(book.toJsonString())
        assertEquals(60_000L, parsed["quark:X"]!!.resumeMs)
        assertEquals(90_000L, parsed.skipFor("quark:X")!!.introEndMs)
    }
}
