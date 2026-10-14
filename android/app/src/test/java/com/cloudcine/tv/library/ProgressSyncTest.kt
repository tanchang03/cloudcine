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
    private class FakeLibrary(
        knownIds: List<String>,
        /**
         * 库里**已经有**的作品行（`media_works.key`）。
         *
         * ⛔ 与媒体项那份分开：片头 / 片尾回填**不新建行**（标记不决定一部作品
         *    存不存在，那是扫描的事），所以「书里有、库里没有」必须能单独构造出来。
         */
        knownWorks: List<String> = emptyList(),
    ) : ProgressLibrary {

        val known = knownIds.toMutableSet()

        val knownWorkKeys = knownWorks.toMutableSet()

        /** 库列上的物化投影。 */
        val projection = ProgressBook()

        /**
         * `media_works` 上的片头 / 片尾投影。
         *
         * ⚠️ 结构**照着 `LibraryDb.SkipProjection` 抄**（多一个
         *    `learnedIntroStartMs` —— 学习出的片头起点恒为 `0`，它是 `saveLearnedSkip`
         *    顺手写的，不属于进度文件的契约）。少了这一列，「回填有没有把它写对」
         *    就测不出来。
         */
        val skipProjection = HashMap<String, SkipProjection>()

        var snapshotCalls = 0
        var applyCalls = 0
        var skipSnapshotCalls = 0
        var skipApplyCalls = 0

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

        /**
         * 与 `LibraryDb.skipMarkerSnapshot` 同构：只收「两组里有任意一列非空」的行，
         * 且 [WorkSkipEntry.manualUpdatedAtSec] 一律 **0**（`media_works` 上没有
         * 手标时刻这一列）。
         */
        override fun skipMarkerSnapshot(): ProgressBook {
            skipSnapshotCalls++
            val out = ProgressBook()
            for (key in knownWorkKeys + skipProjection.keys) {
                val row = rowOf(key) ?: continue
                val entry = WorkSkipEntry(
                    introStartMs = row.introStartMs,
                    introEndMs = row.introEndMs,
                    outroOffsetMs = row.outroOffsetMs,
                    manualUpdatedAtSec = 0L,
                    learnedIntroEndMs = row.learnedIntroEndMs,
                    learnedOutroOffsetMs = row.learnedOutroOffsetMs,
                    learnedSamples = row.learnedSamples,
                    learnedUpdatedAtSec = row.learnedAtSec ?: 0L,
                )
                if (entry.isEmpty) continue
                out.putSkip(key, entry)
            }
            return out
        }

        /**
         * 与 `LibraryDb.applySkipMarkerSnapshot` 同构：**只写「有内容」的那一组**，
         * 另一组原样保留；库里没有这一行就跳过（不新建）。
         */
        override fun applySkipMarkerSnapshot(book: ProgressBook): Int {
            skipApplyCalls++
            var changed = 0
            for ((key, entry) in book.works) {
                // 库里没有这部作品 → 没有落点。**不新建行**：片头标记不决定一部
                // 作品存不存在，那是扫描的事。
                val have = rowOf(key) ?: continue
                val want = SkipProjection(
                    introStartMs = if (entry.hasManual) entry.introStartMs else have.introStartMs,
                    introEndMs = if (entry.hasManual) entry.introEndMs else have.introEndMs,
                    outroOffsetMs = if (entry.hasManual) entry.outroOffsetMs else have.outroOffsetMs,
                    learnedIntroStartMs = if (entry.hasLearned) {
                        if (entry.learnedIntroEndMs == null) null else 0L
                    } else {
                        have.learnedIntroStartMs
                    },
                    learnedIntroEndMs = if (entry.hasLearned) {
                        entry.learnedIntroEndMs
                    } else {
                        have.learnedIntroEndMs
                    },
                    learnedOutroOffsetMs = if (entry.hasLearned) {
                        entry.learnedOutroOffsetMs
                    } else {
                        have.learnedOutroOffsetMs
                    },
                    learnedSamples = if (entry.hasLearned) {
                        entry.learnedSamples
                    } else {
                        have.learnedSamples
                    },
                    learnedAtSec = if (entry.hasLearned) {
                        if (entry.learnedUpdatedAtSec > 0L) {
                            entry.learnedUpdatedAtSec
                        } else {
                            have.learnedAtSec
                        }
                    } else {
                        have.learnedAtSec
                    },
                )
                if (want == have) continue
                skipProjection[key] = want
                changed++
            }
            return changed
        }

        /**
         * 库里这一行的片头 / 片尾列值；**行不存在时返回 `null`**。
         *
         * 行存在但一列没标（刚扫出来的作品）⇒ 返回一个全空白的 [SkipProjection]
         * —— 与 `media_works` 里那一行八列全 NULL 是同一件事。
         */
        private fun rowOf(key: String): SkipProjection? {
            if (key !in knownWorkKeys && key !in skipProjection) return null
            return skipProjection[key] ?: SkipProjection()
        }
    }

    /** `media_works` 上一行片头 / 片尾投影。字段与 `LibraryDb.SkipProjection` 逐字对齐。 */
    private data class SkipProjection(
        val introStartMs: Long? = null,
        val introEndMs: Long? = null,
        val outroOffsetMs: Long? = null,
        val learnedIntroStartMs: Long? = null,
        val learnedIntroEndMs: Long? = null,
        val learnedOutroOffsetMs: Long? = null,
        val learnedSamples: Int = 0,
        val learnedAtSec: Long? = null,
    )

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

    /** 造一份「只带作品段」的远程进度文件（v2 的 `works`）。 */
    private fun remoteSkipBook(vararg pairs: Pair<String, WorkSkipEntry>): ByteArray {
        val book = ProgressBook()
        for ((k, v) in pairs) book.putSkip(k, v)
        return book.toBytes()
    }

    private fun skipBook(vararg pairs: Pair<String, WorkSkipEntry>): ProgressBook {
        val book = ProgressBook()
        for ((k, v) in pairs) book.putSkip(k, v)
        return book
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

    // ------------------------------------------------------------------
    // 作品段（v2 的 `works`）：片头 / 片尾的播种、合并、回填
    // ------------------------------------------------------------------

    @Test
    fun `网盘上还没有进度文件 + 库里已有片头标记 → 播种并上传`() {
        // 场景：老用户升级上来。片头是上一个版本在库行里标好的，而进度文件
        // 还不存在 —— 不播种的话它们永远同步不到别的设备。
        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        lib.skipProjection["w1"] = SkipProjection(introStartMs = 0, introEndMs = 90_000)

        var uploaded: ByteArray? = null
        val out = sync(lib, download = { null }, upload = { uploaded = it }).syncSilently()

        assertTrue(out.ok)
        assertEquals("播种 1 部作品", 1, out.seeded)
        assertTrue("本机有东西可给 ⇒ 必须上传", out.uploaded)

        val sent = ProgressBook.fromBytes(uploaded!!)
        assertEquals("库里标好的片头必须被播种进进度库并传出去", 90_000L, sent.skipFor("w1")!!.introEndMs)
        assertEquals("手标组没有时刻依据 ⇒ 只能是 0", 0L, sent.skipFor("w1")!!.manualUpdatedAtSec)
    }

    @Test
    fun `⛔ 网盘上只有片头标记、本机完全同意 → 不传`() {
        // ⛔ 上传判据的 union 若只放 `items` 段，这一条会判成「远程是空的 ⇒ 我全都
        //    要上传」，于是每 30 分钟在网盘上白走一遍「先删后传」—— 而上传是**有
        //    失败风险**的动作（PC 端踩过同一个坑）。
        val entry = WorkSkipEntry(introStartMs = 0, introEndMs = 60_000, manualUpdatedAtSec = 500)
        val remote = remoteSkipBook("w1" to entry)

        store.mergeFrom(skipBook("w1" to entry))
        store.flush()

        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        var uploadCalled = false
        val out = sync(lib, download = { remote }, upload = { uploadCalled = true }).syncSilently()

        assertTrue(out.ok)
        assertEquals("两边内容一致", 0, out.mergedIn)
        assertFalse("不许每 30 分钟白传一次", uploadCalled)
    }

    @Test
    fun `本机学出了片头、远程只有进度条目 → 必须上传（mergedIn 为 0 也要传）`() {
        // ⛔ 判据的 union 若只放 `items`，这一条会漏传：远程那一段**非空**（有 e1），
        //    而本机的东西全在 `works` 里。
        val remote = remoteBook(
            "e1" to ProgressEntry(resumeMs = 100, maxMs = 100, playedAtSec = 100, updatedAtSec = 100),
        )
        store.recordLearnedSkip("w1", introEndMs = 88_000, outroOffsetMs = 70_000, samples = 3)

        val lib = FakeLibrary(listOf("e1"), knownWorks = listOf("w1"))
        var uploaded: ByteArray? = null
        val out = sync(lib, download = { remote }, upload = { uploaded = it }).syncSilently()

        assertTrue(out.uploaded)
        val sent = ProgressBook.fromBytes(uploaded!!)
        assertEquals(88_000L, sent.skipFor("w1")!!.learnedIntroEndMs)
        assertEquals(70_000L, sent.skipFor("w1")!!.learnedOutroOffsetMs)
        assertEquals(3, sent.skipFor("w1")!!.learnedSamples)
    }

    @Test
    fun `手标组与学习组各判各的 —— A 机手标、B 机学习，合并后两组都在`() {
        // ⛔ 两组共用一个时间戳的话，后到的那一组会把先到的那一组整个抹掉，
        //    而两台机器都显示同步成功、用户只会觉得「有时候同步丢东西」。
        val remote = remoteSkipBook(
            "w1" to WorkSkipEntry(
                learnedIntroEndMs = 88_000,
                learnedOutroOffsetMs = 70_000,
                learnedSamples = 4,
                learnedUpdatedAtSec = 1_791_285_400L,
            ),
        )
        store.mergeFrom(
            skipBook(
                "w1" to WorkSkipEntry(
                    introStartMs = 0,
                    introEndMs = 95_000,
                    manualUpdatedAtSec = 1_791_285_100L,
                ),
            ),
        )

        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        val out = sync(lib, download = { remote }, upload = {}).syncSilently()

        assertTrue(out.ok)
        assertEquals("远程的学习组是新的 ⇒ 合进来", 1, out.mergedIn)
        val merged = store.book.skipFor("w1")!!
        assertEquals("本机的手标组原样留下", 95_000L, merged.introEndMs)
        assertEquals(1_791_285_100L, merged.manualUpdatedAtSec)
        assertEquals("远程的学习组合进来", 88_000L, merged.learnedIntroEndMs)
        assertEquals(1_791_285_400L, merged.learnedUpdatedAtSec)
        assertTrue("两组都在 ⇒ 这条不该被判成空壳", merged.hasManual && merged.hasLearned)
    }

    @Test
    fun `学习结论回填进作品行，且学习起点写成 0`() {
        // 场景：电视上学出了结论 ⇒ 库行必须当场跟上，否则简介页读的是旧值。
        store.recordLearnedSkip("w1", introEndMs = 88_000, outroOffsetMs = 70_000, samples = 3)

        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        val out = sync(lib, download = { null }, upload = {}).syncSilently()

        assertTrue(out.ok)
        assertEquals("1 部作品被回填", 1, out.applied)
        val row = lib.skipProjection["w1"]!!
        assertEquals("学习出的片头终点", 88_000L, row.learnedIntroEndMs)
        assertEquals("学习出的片头起点恒为 0（与 saveLearnedSkip 同口径）", 0L, row.learnedIntroStartMs)
        assertEquals(70_000L, row.learnedOutroOffsetMs)
        assertEquals(3, row.learnedSamples)
        assertEquals("learned_at 用进度文件里的 lu", 1_791_285_373L, row.learnedAtSec)
    }

    @Test
    fun `回填只动「有内容」的那一组 —— 手标组不许被静默清空`() {
        // ⛔ 这是与进度三列最大的区别：那里 `null` 就是「没有可续的点」，可以照抄；
        //    这里「书里没有手标组」可能有两种意思 —— 「用户清除了」和「这台机器
        //    根本不知道」。照抄会把第二种变成静默清空。
        store.recordLearnedSkip("w1", introEndMs = 88_000, outroOffsetMs = null, samples = 2)

        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        lib.skipProjection["w1"] = SkipProjection(
            introStartMs = 0,
            introEndMs = 95_000,
            // 库行里那份手标时刻是「上一个版本标的」，库里根本没有这一列，
            // 所以它只能靠库里的现有值保留下来。
        )

        sync(lib, download = { null }, upload = {}).syncSilently()

        val row = lib.skipProjection["w1"]!!
        assertEquals("学习组被回填", 88_000L, row.learnedIntroEndMs)
        assertEquals("手标组的起点原样保留", 0L, row.introStartMs)
        assertEquals("手标组的终点也原样保留 —— 绝不能被静默清空", 95_000L, row.introEndMs)
    }

    @Test
    fun `backfill 把进度库里的学习结论贴回作品行（含恒为 0 的学习起点）`() {
        // 场景：刚恢复完一份老备份 ⇒ 库行里那份结论是旧的，而进度库里的才是新的。
        store.recordLearnedSkip("w1", introEndMs = 88_000, outroOffsetMs = 70_000, samples = 3)

        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        lib.skipProjection["w1"] = SkipProjection(learnedIntroEndMs = 60_000, learnedAtSec = 100)

        val sync = sync(
            lib,
            download = { throw AssertionError("backfill 不该下载") },
            upload = { throw AssertionError("backfill 不该上传") },
        )
        val n = sync.backfill()

        assertEquals("作品行被回填", 1, n)
        val row = lib.skipProjection["w1"]!!
        assertEquals("真源里的结论赢（LWW 判的是 learned_at）", 88_000L, row.learnedIntroEndMs)
        assertEquals(70_000L, row.learnedOutroOffsetMs)
        assertEquals("学习起点恒为 0", 0L, row.learnedIntroStartMs)
        assertEquals("learned_at 跟到进度库那份", 1_791_285_373L, row.learnedAtSec)
    }

    @Test
    fun `backfill 之后库行里那份「更旧的学习结论」不会把真源拉回去`() {
        store.recordLearnedSkip("w1", introEndMs = 88_000, outroOffsetMs = null, samples = 2)

        val lib = FakeLibrary(emptyList(), knownWorks = listOf("w1"))
        // 恢复回来的旧备份：结论更浅、时刻更早。
        lib.skipProjection["w1"] = SkipProjection(
            learnedIntroEndMs = 30_000,
            learnedAtSec = 100,
        )

        sync(lib, download = { null }).backfill()

        assertEquals("真源里的结论不变", 88_000L, store.book.skipFor("w1")!!.learnedIntroEndMs)
        assertEquals("库行被真源纠正", 88_000L, lib.skipProjection["w1"]!!.learnedIntroEndMs)
    }

    @Test
    fun `库里没有这部作品 → 片头标记不落地，也不新建作品行`() {
        store.recordLearnedSkip("ghost", introEndMs = 88_000, outroOffsetMs = null, samples = 2)
        val lib = FakeLibrary(emptyList()) // 这部作品已经被删掉了

        val out = sync(lib, download = { null }).syncSilently()

        assertNull("不该凭空造出一部作品", lib.skipProjection["ghost"])
        assertTrue("但结论本身要留在进度库里", store.book.skipFor("ghost") != null)
        assertTrue(out.ok)
    }

    @Test
    fun `作品段为空时整个 works 键不上传 —— 不白占字节`() {
        store.recordResume("e1", 1000)
        val lib = FakeLibrary(listOf("e1"))

        var uploaded: ByteArray? = null
        sync(lib, download = { null }, upload = { uploaded = it }).syncSilently()

        assertNotNull(uploaded)
        assertFalse(
            "只有进度条目时不该写出空的 works 段（这份文件每 30 分钟传一次）",
            String(uploaded!!, Charsets.UTF_8).contains("works"),
        )
    }
}
