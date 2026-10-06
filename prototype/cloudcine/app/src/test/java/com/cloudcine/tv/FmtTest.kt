package com.cloudcine.tv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [Fmt] 的单测。
 *
 * ## 为什么这一组值得测
 *
 * 它不是装饰：**控制栏与调试浮层会同时出现在同一屏上**（一个贴底、
 * 一个在左上角）。两处的时长/字节/速率一旦对不上，用户会认为其中一个在骗人，
 * 而排查方向会被带偏到「哪份数据是错的」—— 其实只是格式化不一致。
 *
 * 更要紧的是 **`MiB` 的进制**：整个项目的对账（3.67 MiB/s × 时长、
 * 48 MiB 缓冲预算、5 GiB 缓存上限）都建立在 1048576 上。把 `MiB` 写成
 * 1000 进制，48 MiB 会变成 50.3「MB」，4.8% 的差额足以让「够不够」判反。
 */
class FmtTest {

    private val mib = 1024L * 1024

    // ── 时长 ────────────────────────────────────────────────────

    @Test
    fun `一小时以内用 mm_ss`() {
        assertEquals("00:00", Fmt.time(0L))
        assertEquals("00:09", Fmt.time(9_999L))
        assertEquals("01:00", Fmt.time(60_000L))
        assertEquals("59:59", Fmt.time(3_599_000L))
    }

    @Test
    fun `满一小时改用 h_mm_ss`() {
        // 1:32:05 —— 实测那部 4K 片的时长。
        assertEquals("1:32:05", Fmt.time(92 * 60_000L + 5_000L))
        assertEquals("1:00:00", Fmt.time(3_600_000L))
    }

    @Test
    fun `负数一律当成不知道`() {
        // ⛔ `C.TIME_UNSET` 是 `Long.MIN_VALUE + 1`。不能让它算成
        //    「-2562047788:-00:-08」这种东西，也不能当成 0（那会显示 00:00，
        //    看起来像「已经播到片头」）。
        assertEquals("--:--", Fmt.time(Long.MIN_VALUE + 1))
        assertEquals("--:--", Fmt.time(-1L))
    }

    // ── 字节：1048576 进制 ──────────────────────────────────────

    @Test
    fun `字节按 GiB_MiB_KiB 进位`() {
        assertEquals("0 B", Fmt.bytes(0L))
        assertEquals("0 B", Fmt.bytes(-5L))
        assertEquals("1 KiB", Fmt.bytes(1024L))
        assertEquals("1 MiB", Fmt.bytes(mib))
        assertEquals("1.00 GiB", Fmt.bytes(1024L * mib))
    }

    @Test
    fun `实测那台电视的缓存上限读作 4_96 GiB`() {
        // 5081 MiB 是实测算出的上限。若按 1000 进制会读成 5.33「GB」，
        // 与「可用 12210 MiB 给系统留 2048 后取一半」这句对不上账。
        assertEquals("4.96 GiB", Fmt.bytes(5081L * mib))
    }

    @Test
    fun `mib 取整与 bytes 的分母同源`() {
        // 「43/48 MiB」这种写法：分子分母都走 mib()，不各格式一遍。
        assertEquals(43L, Fmt.mib(43L * mib))
        assertEquals(43L, Fmt.mib(43L * mib + mib - 1))
        assertEquals(0L, Fmt.mib(0L))
    }

    // ── 速率 ────────────────────────────────────────────────────

    @Test
    fun `速率按 1MiB每秒 分档`() {
        assertEquals("0 KB/s", Fmt.speed(0L))
        // ⛔ 0 不能写成「--」：窗口内没有新字节 ⇒ 0 是**真实读数**
        //    （「卡住了」与「在下载」的区分点），写成不知道就丢掉了这个信息。
        assertEquals("0 KB/s", Fmt.speed(-1L))
        assertEquals("512 KB/s", Fmt.speed(512L * 1024))
        assertEquals("12.40 MB/s", Fmt.speed((12.4 * mib).toLong()))
        assertEquals("1.00 MB/s", Fmt.speed(mib))
    }

    @Test
    fun `速率分档的边界就在 1MiB`() {
        assertEquals("1024 KB/s", Fmt.speed(mib - 1))
        assertEquals("1.00 MB/s", Fmt.speed(mib))
    }

    // ── 性质 ────────────────────────────────────────────────────

    @Test
    fun `任何非负输入下输出都不是空串`() {
        val cases = listOf(0L, 1L, 1023L, 1024L, mib, 1024L * mib, Long.MAX_VALUE)
        for (v in cases) {
            assertTrue("bytes($v) 是空串", Fmt.bytes(v).isNotBlank())
            assertTrue("speed($v) 是空串", Fmt.speed(v).isNotBlank())
            assertTrue("time($v) 是空串", Fmt.time(v).isNotBlank())
        }
    }

    @Test
    fun `字节按量级选单位 边界不串档`() {
        // ⛔ 边界写错会让 1023 MiB 显示成「0.99 GiB」这种读不出量级的东西，
        //    而这几档正是「48 MiB 预算 / 5 GiB 上限」的常用区间。
        assertTrue(Fmt.bytes(mib - 1).endsWith("KiB"))
        assertTrue(Fmt.bytes(mib).endsWith("MiB"))
        assertTrue(Fmt.bytes(1024L * mib - 1).endsWith("MiB"))
        assertTrue(Fmt.bytes(1024L * mib).endsWith("GiB"))
    }
}
