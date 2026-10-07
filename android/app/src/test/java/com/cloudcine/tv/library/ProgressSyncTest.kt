package com.cloudcine.tv.library

import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [ProgressSync] 的**合并方向**与**上传判据**单测。
 *
 * 这个功能最不能出的错是「拿本机知道的那部分进度，把网盘上另一台设备的进度
 * 整个覆盖掉」—— 而它不报错、两边都显示同步成功。所以下面把「什么时候必须
 * 不传」单独测了一遍。
 *
 * ⛔ 用 [FakeLibrary] 而不是真的 [LibraryDb]：后者跑在真的 SQLite 上，而 JVM
 *    单测里的 `android.database.sqlite` 是空壳（见 [ProgressLibrary] 的文档）。
 *    网盘那一步同理收成两个闭包。
 */
class ProgressSyncTest {

    private lateinit var dir: File
    private lateinit var store: ProgressStore

    @Before
    fun setUp() {
        dir = File.createTempFile("cloudcine_progress_sync", "").let {
            it.delete()
            it.mkdirs()
            it
        }
        store = ProgressStore(
            file = File(dir, ProgressStore.FILE_NAME),
            clock = { 1_791_285_373L },
            flushDelayMs = 0L,
        )
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    /** 一个「只会往前推」的假媒体库，行为与 `LibraryDb.applyProgressSnapshot` 同构。 */
    private class FakeLibrary(knownIds: List<String>) : ProgressLibrary {

        val known = knownIds.toMutableSet()

        /** 库列上的物化投影。 */
        val projection = ProgressBook()

        var snapshotCalls = 0
        var applyCalls = 0

        override fun progressSnapshot(): ProgressBook {
            snapshotCalls++
            return ProgressBook(LinkedHashMap(projection.items))
        }

        override fun applyProgressSnapshot(book: ProgressBook): Int {
            applyCalls++
            var changed = 0
            for ((id, want) in book.items) {
                // 库里没有这一行 → 没有落点，不新建行。
                if (id !in known) continue
                val have = projection[id]
                val next = ProgressProjection.next(
                    haveResumeMs = have?.resumeMs,
                    haveMaxMs = have?.maxMs,
                    havePlayedAtSec = have?.playedAtSec,
                    want = want,
                ) ?: continue
                projection[id] = ProgressEntry(
                    resumeMs = next.resumeMs,
                    maxMs = next.maxMs,
                    playedAtSec = next.playedAtSec,
                    updatedAtSec = want.updatedAtSec,
                )
                changed++
            }
            return changed
        }
    }

    private fun sync(
        library: ProgressLibrary,
        download: () -> ByteArray?,
        upload: (ByteArray) -> Unit = {},
    ) = ProgressSync(
        store = store,
        library = library,
        downloadRemote = download,
        uploadRemote = upload,
    )

    private fun remoteBook(vararg pairs: Pair<String, ProgressEntry>): ByteArray {
        val book = ProgressBook()
        for ((k, v) in pairs) book[k] = v
        return book.toBytes()
    }

    // ------------------------------------------------------------------

    @Test
    fun `网盘上还没有进度文件 + 本地库已有进度 → 播种并上传`() {
        val lib = FakeLibrary(listOf("e1"))
        lib.projection["e1"] = ProgressEntry(
            resumeMs = 60_000,
            maxMs = 60_000,
            playedAtSec = 1000,
            updatedAtSec = 1000,
        )

        var uploaded: ByteArray? = null
        val out = sync(lib, download = { null }, upload = { uploaded = it }).syncSilently()

        assertTrue(out.ok)
        assertEquals("播种 1 条", 1, out.seeded)
        assertTrue("本机有东西可给 ⇒ 必须上传", out.uploaded)
        assertNotNull("网盘上那份进度文件必须被写出来", uploaded)
        assertEquals(
            "传上去的就是本地那份（逐字相同）",
            store.book.toJsonString(),
            ProgressBook.fromBytes(uploaded!!).toJsonString(),
        )
    }

    @Test
    fun `网盘上另一台机器的进度被合进来，并回填进媒体项行`() {
        store.recordResume("e1", 1000) // 本机：第 1 集看到 1 秒

        val lib = FakeLibrary(listOf("e1", "e2"))
        lib.projection["e1"] = ProgressEntry(
            resumeMs = 1000, maxMs = 1000, playedAtSec = 1000, updatedAtSec = 1000,
        )

        val remote = remoteBook(
            // ⛔ 时间戳必须**明显在本机时钟之后**：本机 `recordResume` 写的是「此刻」
            //    的 Unix 秒（1_791_285_373），用一个 2001 年的值会输掉 LWW，
            //    测出来的就不是「远程赢」这条规则了（PC 端的同名用例也踩过同一个坑）。
            "e1" to ProgressEntry(resumeMs = 9000, maxMs = 9000, playedAtSec = 1_791_285_400L, updatedAtSec = 1_791_285_400L),
            "e2" to ProgressEntry(resumeMs = 5000, maxMs = 5000, playedAtSec = 1_791_285_400L, updatedAtSec = 1_791_285_400L),
        )

        val out = sync(lib, download = { remote }).syncSilently()

        assertTrue(out.ok)
        assertEquals("远程 2 条都合进来", 2, out.mergedIn)
        assertTrue("远程更新 ⇒ 必须回填库列", out.applied >= 1)
        assertEquals("远程的续播点赢", 9000L, store.book["e1"]!!.resumeMs)
        assertEquals("另一台看的那一集也留下来了", 5000L, lib.projection["e2"]!!.resumeMs)
        assertFalse("两边内容已经一致 ⇒ 不需要再传", out.uploaded)
    }

    @Test
    fun `⛔ 下载失败时绝不上传（否则会覆盖掉另一台设备的进度）`() {
        store.recordResume("e1", 1000)

        val lib = FakeLibrary(listOf("e1"))
        var uploadCalled = false

        val out = sync(
            lib,
            download = { throw RuntimeException("网络断了") },
            upload = { uploadCalled = true },
        ).syncSilently()

        assertFalse(out.ok)
        assertFalse("读不到远程就传本地 = 把对方那份整个覆盖掉", uploadCalled)
        assertTrue("但本地该落盘的照落", store.isLoaded)
    }

    @Test
    fun `两边内容一致 → 不传（空同步不该在网盘上走一遍「先删后传」）`() {
        store.recordResume("e1", 1000)
        store.flush()

        val lib = FakeLibrary(listOf("e1"))
        val remote = remoteBook("e1" to store.book["e1"]!!)

        var uploadCalled = false
        val out = sync(lib, download = { remote }, upload = { uploadCalled = true }).syncSilently()

        assertTrue(out.ok)
        assertFalse(uploadCalled)
        assertEquals(0, out.mergedIn)
    }

    @Test
    fun `本地新看了一集、远程一无所知 → 必须上传（mergedIn 为 0 也要传）`() {
        // ⛔ 判据不能用 `mergedIn > 0`：那说的是「远程有没有东西给我」，而这里
        //    要问的是「我有没有东西要给远程」。
        val lib = FakeLibrary(listOf("e1"))
        val remote = remoteBook(
            "e1" to ProgressEntry(resumeMs = 100, maxMs = 100, playedAtSec = 100, updatedAtSec = 100),
        )
        val base = ProgressBook()
        base["e1"] = ProgressEntry(resumeMs = 100, maxMs = 100, playedAtSec = 100, updatedAtSec = 100)
        store.mergeFrom(base)
        store.recordResume("e2", 7000) // 本地刚看的

        var uploaded: ByteArray? = null
        val out = sync(lib, download = { remote }, upload = { uploaded = it }).syncSilently()

        assertTrue(out.uploaded)
        assertNotNull(uploaded)
        assertEquals(7000L, ProgressBook.fromBytes(uploaded!!)["e2"]!!.resumeMs)
    }

    @Test
    fun `上传失败 → 本地不丢，返回失败（下一轮重试）`() {
        store.recordResume("e1", 1000)

        val lib = FakeLibrary(listOf("e1"))
        val out = sync(
            lib,
            download = { null },
            upload = { throw RuntimeException("限流") },
        ).syncSilently()

        assertFalse(out.ok)
        assertEquals("本地那份还在", 1000L, store.book["e1"]!!.resumeMs)
        assertEquals(1, store.book.length)
    }

    @Test
    fun `本地是空的、网盘上也没有 → 什么都不传（不留一个空文件在网盘上）`() {
        val lib = FakeLibrary(emptyList())
        var uploadCalled = false
        val out = sync(lib, download = { null }, upload = { uploadCalled = true }).syncSilently()

        assertTrue(out.ok)
        assertFalse(uploadCalled)
    }

    @Test
    fun `backfill 只动本地，一次网都不碰`() {
        // 场景：刚恢复完备份 / 刚重扫完 ⇒ **库列里没有进度**（三列全 NULL），
        // 而独立进度库里有。backfill 要把它贴回去。
        store.recordResume("e1", 12_000)
        store.recordMax("e1", 12_000)

        val lib = FakeLibrary(listOf("e1"))

        val sync = sync(
            lib,
            download = { throw AssertionError("backfill 不该下载") },
            upload = { throw AssertionError("backfill 不该上传") },
        )

        val n = sync.backfill()

        assertEquals("库列那一行被贴回来", 1, n)
        assertEquals(12_000L, store.book["e1"]!!.resumeMs)
        assertEquals("库列被贴回来了", 12_000L, lib.projection["e1"]!!.resumeMs)
        assertEquals(12_000L, lib.projection["e1"]!!.maxMs)
    }

    @Test
    fun `backfill 之后库列里那份「更浅的旧进度」不会把真源拉回去`() {
        // 场景：恢复了一份旧备份 ⇒ 库列里的进度比独立进度库里的旧。
        store.recordResume("e1", 90_000)
        store.recordMax("e1", 90_000)

        val lib = FakeLibrary(listOf("e1"))
        lib.projection["e1"] = ProgressEntry(
            resumeMs = 5_000, maxMs = 5_000, playedAtSec = 100, updatedAtSec = 100,
        )

        sync(lib, download = { null }).backfill()

        assertEquals("真源里的续播点赢", 90_000L, lib.projection["e1"]!!.resumeMs)
        assertEquals("最大位置只增不减", 90_000L, lib.projection["e1"]!!.maxMs)
    }

    @Test
    fun `库里没有这一行 → 回填跳过，不新建行`() {
        store.recordResume("ghost", 1000)
        val lib = FakeLibrary(emptyList()) // 这条媒体项已经被清空索引库删掉了

        val out = sync(lib, download = { null }).syncSilently()

        assertNull("不该凭空造出一条媒体项", lib.projection["ghost"])
        assertTrue("但进度本身要留在独立进度库里", store.book.isNotEmpty)
        assertTrue(out.ok)
    }

    @Test
    fun `防叠加 —— 上一轮没跑完时第二次调用直接跳过`() {
        // 场景：30 分钟的定时器撞上「退出播放器」。两个线程同时进 `run` 的后果是
        // **两份合并交叉写同一个文件**。这里用一个「下载里再进一次」的闭包模拟。
        val lib = FakeLibrary(listOf("e1"))

        var syncRef: ProgressSync? = null
        var nested: ProgressSync.Outcome? = null
        val sync = ProgressSync(
            store = store,
            library = lib,
            downloadRemote = {
                nested = syncRef!!.syncSilently()
                null
            },
            uploadRemote = {},
        )
        syncRef = sync

        val out = sync.syncSilently()

        assertTrue(out.ok)
        assertNotNull("重入的那一次必须被挡下", nested)
        assertTrue(
            "重入返回的应该是「跳过」，而不是又跑了一轮：${nested!!.message}",
            nested!!.message.contains("还没跑完"),
        )
        assertFalse("跑完之后标志必须放掉", sync.isRunning)
    }
}
