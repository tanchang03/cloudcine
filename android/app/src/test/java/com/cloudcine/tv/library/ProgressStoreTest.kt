package com.cloudcine.tv.library

import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [ProgressStore] 的落盘单测。
 *
 * ## 为什么这里最该测「写之前先读」
 *
 * 这个类有两个**静默**的错法，两个都会让用户磁盘上的几百条进度一次性没掉，
 * 而且**没有任何报错**：
 *
 *   1. **先写后读** —— 内存里只有刚写的那一条，落盘时把整个文件覆盖成
 *      「只有一条」；
 *   2. **非原子写** —— 直接覆写原文件，写到一半被杀（电视上很常见）留下一份
 *      截断的 JSON，下次读回来整份都没了。
 *
 * 所以下面各有一条用例守着它们。
 *
 * ⛔ 所有用例都用 `flushDelayMs = 0`（不挂定时器），显式调 [ProgressStore.flush]
 *    —— 定时器线程会让「哪一刻落了盘」变得不可预测。
 */
class ProgressStoreTest {

    private lateinit var dir: File
    private lateinit var file: File

    /** 可控时钟（Unix 秒）。 */
    private var now = 1_791_285_373L

    @Before
    fun setUp() {
        dir = File.createTempFile("cloudcine_progress", "").let {
            it.delete()
            it.mkdirs()
            it
        }
        file = File(dir, ProgressStore.FILE_NAME)
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun makeStore() = ProgressStore(file = file, clock = { now }, flushDelayMs = 0L)

    // ------------------------------------------------------------------

    @Test
    fun `写 → 落盘 → 新实例读回来，内容一致`() {
        val s = makeStore()
        s.recordPlayed("a", 1000)
        s.recordResume("a", 12_000)
        s.recordMax("a", 12_000)
        s.flush()

        val again = makeStore()
        again.load()
        assertEquals(1, again.book.length)
        val e = again.book["a"]!!
        assertEquals(12_000L, e.resumeMs)
        assertEquals(12_000L, e.maxMs)
        assertEquals(1000L, e.playedAtSec)
    }

    @Test
    fun `⛔ 写之前一定先读 —— 否则整个文件被覆盖成「只有刚写的那一条」`() {
        val first = makeStore()
        first.recordResume("old1", 100)
        first.recordResume("old2", 200)
        first.flush()

        // 第二个实例**不显式 load**，直接写 —— flush 内部必须先读回来。
        val second = makeStore()
        second.recordResume("fresh", 300)
        second.flush()

        val third = makeStore()
        third.load()
        assertEquals("两条老进度不能被覆盖掉", 3, third.book.length)
        assertEquals(100L, third.book["old1"]!!.resumeMs)
        assertEquals(300L, third.book["fresh"]!!.resumeMs)
    }

    @Test
    fun `recordMax 只增不减`() {
        val s = makeStore()
        assertTrue(s.recordMax("a", 5000))
        assertFalse("更小的位置是无操作", s.recordMax("a", 1000))
        assertEquals(5000L, s.book["a"]!!.maxMs)
        assertTrue(s.recordMax("a", 9000))
        assertEquals(9000L, s.book["a"]!!.maxMs)
    }

    @Test
    fun `recordMax 的 0 与负数是无操作 —— 不能把「播了 0 秒」当成绩录下来`() {
        val s = makeStore()
        assertFalse(s.recordMax("a", 0))
        assertFalse(s.recordMax("a", -1))
        assertNull(s.book["a"])
    }

    @Test
    fun `recordResume 的 null 与 0 都记成「没有可续的点」`() {
        val s = makeStore()
        s.recordResume("a", 5000)
        assertEquals(5000L, s.book["a"]!!.resumeMs)

        // 看完 ⇒ 清掉续播点（口径与 `LibraryDb.saveResumePosition` 一致）。
        s.recordResume("a", null)
        assertNull(s.book["a"]!!.resumeMs)
        assertFalse("重复写同一个值不算改动", s.recordResume("a", 0))
        assertNull(s.book["a"]!!.resumeMs)
    }

    @Test
    fun `recordPlayed 只前进（时钟回拨不该让「最近播放」倒退）`() {
        val s = makeStore()
        assertTrue(s.recordPlayed("a", 2000))
        assertFalse(s.recordPlayed("a", 1500))
        assertEquals(2000L, s.book["a"]!!.playedAtSec)

        now = 500L // 时钟被回拨到 1970 年
        s.recordResume("a", 777)
        assertEquals(
            "新写入的 u 不能小于旧值，否则本机进度会输给远程的旧进度",
            1_791_285_373L,
            s.book["a"]!!.updatedAtSec,
        )
    }

    @Test
    fun `坏文件、空文件 → 从空开始，不抛`() {
        file.writeText("{ 这不是 JSON")
        val s = makeStore()
        s.load()
        assertEquals(0, s.book.length)
        assertTrue(s.isLoaded)

        // 坏文件之后照样能正常写（不会因为读失败就永远不落盘）。
        s.recordResume("a", 100)
        s.flush()
        val again = makeStore()
        again.load()
        assertEquals(1, again.book.length)
    }

    @Test
    fun `落盘之后不留 tmp（原子替换的中间文件必须被 rename 走）`() {
        val s = makeStore()
        s.recordResume("a", 1)
        s.flush()
        assertTrue(file.exists())
        assertFalse(File("${file.absolutePath}.tmp").exists())
    }

    @Test
    fun `mergeFrom 把远程合进来并标脏`() {
        val s = makeStore()
        s.recordResume("mine", 100)

        val remote = ProgressBook()
        // ⛔ 时间戳必须**明显在现在之后**：`recordResume` 写的是「此刻」的 Unix 秒，
        //    用一个 2001 年的值会输掉 LWW，测出来的就不是「远程赢」这条规则了。
        remote["mine"] = ProgressEntry(resumeMs = 999, updatedAtSec = 4_000_000_000L)
        remote["theirs"] = ProgressEntry(resumeMs = 200, updatedAtSec = 4_000_000_000L)

        val changed = s.mergeFrom(remote)
        assertEquals("一条被更新的远程覆盖、一条是新增", 2, changed)
        assertEquals(999L, s.book["mine"]!!.resumeMs)
        assertTrue(s.isDirty)

        s.flush()
        val again = makeStore()
        again.load()
        assertEquals(2, again.book.length)
    }

    @Test
    fun `mergeFrom 内容一致时不标脏 —— 空同步不该在网盘上走一遍「先删后传」`() {
        val s = makeStore()
        s.recordResume("a", 100)
        s.flush()
        assertFalse(s.isDirty)

        val same = ProgressBook(LinkedHashMap(s.book.items))
        assertEquals(0, s.mergeFrom(same))
        assertFalse(s.isDirty)
    }

    @Test
    fun `dispose 之后仍会把内存里的改动落盘，但不再自动落盘`() {
        val s = makeStore()
        s.recordResume("a", 42)
        s.dispose()

        val again = makeStore()
        again.load()
        assertEquals("dispose 里的最后一次 flush 必须写下去", 42L, again.book["a"]!!.resumeMs)
    }

    @Test
    fun `文件名与网盘上那份同名`() {
        assertEquals("playback_progress.json", ProgressStore.FILE_NAME)
        assertEquals("playback_progress.json", file.name)
    }
}
