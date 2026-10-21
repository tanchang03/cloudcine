package com.cloudcine.tv

import com.cloudcine.tv.library.BatchFileDeleter
import com.cloudcine.tv.pan.DriveException
import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 分批删网盘文件的那段循环。
 *
 * ## 为什么这条测试比别的守卫更值钱
 *
 * `LibraryBatchRemoveGuardTest` 只能证明「Activity 里写了 `deleteFiles(`，
 * 且排在 `deleteWorks(` 前面」—— 它读的是**源码文本**，跑不了。真正会算错
 * 的是这几个数：一批带多少、失败的那一批算不算走完、总共动了多少个。算错
 * 的表现全是「提示里的数字不对」，而数字不对没人会当成 bug 报上来。
 *
 * 抽成 [BatchFileDeleter] 之后这一段不碰 SQLite、不碰真网盘，可以在这里
 * 用假的 `deleteBatch` 把边界跑一遍 —— **不必真的删片子**。
 */
class BatchFileDeleterTest {

    private fun fids(n: Int): List<String> = (1..n).map { "f$it" }

    /** 每批大小与 PC 的 `driveMaxFidsPerRequest` 必须同数。 */
    @Test
    fun `每批 100 个`() {
        assertEquals(
            "改这个数之前先看 PC 侧 driveMaxFidsPerRequest：两边不一致的话，" +
                "同一批作品在电脑上分 3 批、在电视上分 2 批，超时行为就不一样了",
            100,
            BatchFileDeleter.FIDS_PER_BATCH,
        )
    }

    @Test
    fun `250 个文件分三批 100 100 50`() {
        val batches = mutableListOf<List<String>>()
        val r = BatchFileDeleter.delete(fids(250)) { chunk ->
            batches.add(chunk)
            chunk.size
        }

        assertEquals(listOf(100, 100, 50), batches.map { it.size })
        assertEquals(250, r.deleted)
        assertEquals(0, r.failed)
        assertNull(r.error)
    }

    /**
     * 分母必须**早于第一批**报出来。
     *
     * 报晚了（比如第一批回来才知道总数）屏幕上那个数字会先跳一下 ——
     * 用户看到的是「删着删着总数变了」，像数错了。
     */
    @Test
    fun `进度先报 0 再逐批推进到满`() {
        val seen = mutableListOf<Pair<Int, Int>>()
        BatchFileDeleter.delete(fids(250), onProgress = { d, t -> seen.add(d to t) }) { it.size }

        assertEquals(0 to 250, seen.first())
        assertEquals(listOf(0, 100, 200, 250), seen.map { it.first })
        assertEquals(
            "总数必须一直是同一个数（不能随批次变化）",
            listOf(250, 250, 250, 250),
            seen.map { it.second },
        )
        assertEquals(250, seen.last().first)
    }

    /**
     * 某一批失败：只算那一批，后面继续发。
     *
     * 中止的话用户会以为「全都没删」；不计数的话提示会说「全部成功」。
     * 两种都比慢一点更糟。
     */
    @Test
    fun `某一批失败只算那一批 后面继续发`() {
        val seen = mutableListOf<Pair<Int, Int>>()
        var calls = 0
        val r = BatchFileDeleter.delete(fids(250), onProgress = { d, t -> seen.add(d to t) }) { chunk ->
            calls++
            if (calls == 2) throw IllegalStateException("被限流")
            chunk.size
        }

        assertEquals(3, calls)
        assertEquals(150, r.deleted)
        assertEquals(100, r.failed)
        assertEquals("被限流", r.error)
        assertEquals(
            "失败的那一批也算走完 —— 卡在它上面不动，屏幕上就是死机",
            listOf(0, 100, 200, 250),
            seen.map { it.first },
        )
    }

    /**
     * 凭证失效：**只发第一批**，剩下的直接算失败。
     *
     * 换一批 fid 还是同样的 401，继续打只会把限流线顶穿，用户还得干等
     * 几十次超时。与 PC 的 `LibraryRemovalController` 同口径。
     */
    @Test
    fun `凭证失效只发第一批 剩下的算失败`() {
        var calls = 0
        val seen = mutableListOf<Pair<Int, Int>>()
        val r = BatchFileDeleter.delete(fids(250), onProgress = { d, t -> seen.add(d to t) }) {
            calls++
            throw DriveException(message = "登录已失效", needsReauth = true)
        }

        assertEquals("凭证失效之后不该再发第二批", 1, calls)
        assertEquals(0, r.deleted)
        assertEquals(
            "没发出去的那 150 个也算失败 —— 它们确实没删掉，报成成功是撒谎",
            250,
            r.failed,
        )
        assertEquals("登录已失效", r.error)
        assertEquals(
            "中止时进度要推到满格：停在 100/250 上关窗，看起来像被掐断了",
            250 to 250,
            seen.last(),
        )
    }

    /** 断网与凭证失效同一条处置（`IOException` 换一批还是失败）。 */
    @Test
    fun `断网也中止 不再打后面的批次`() {
        var calls = 0
        val r = BatchFileDeleter.delete(fids(250)) {
            calls++
            throw IOException("timeout")
        }

        assertEquals(1, calls)
        assertEquals(250, r.failed)
        assertEquals("timeout", r.error)
    }

    @Test
    fun `全部失败时 deleted 是 0 error 是第一条`() {
        val r = BatchFileDeleter.delete(fids(150)) { throw IllegalStateException("断网") }

        assertEquals(0, r.deleted)
        assertEquals(150, r.failed)
        assertEquals("断网", r.error)
    }

    /** 一批都没有时不该发请求、也不该往屏幕上写「0/0」。 */
    @Test
    fun `空列表不发请求也不报进度`() {
        var calls = 0
        var reported = false
        val r = BatchFileDeleter.delete(
            emptyList(),
            onProgress = { _, _ -> reported = true },
        ) {
            calls++
            it.size
        }

        assertEquals(0, calls)
        assertTrue("空列表还报进度的话，屏幕上会闪一下「正在删除网盘文件 0/0…」", !reported)
        assertEquals(0, r.deleted)
        assertEquals(0, r.failed)
        assertNull(r.error)
    }
}
