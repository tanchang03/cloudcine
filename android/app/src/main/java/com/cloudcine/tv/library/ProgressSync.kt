package com.cloudcine.tv.library

import android.util.Log

/**
 * 媒体库为进度同步提供的**两件事**。
 *
 * ## ⛔ 为什么是接口，而不是直接依赖 [LibraryDb]
 *
 * `LibraryDb` 跑在**真的 SQLite** 上，而本工程的 JVM 单测跑在 `android.jar` 的
 * 空壳实现上（`android.database.sqlite` 的方法体全被抹掉）。直接依赖它的话，
 * 这个功能里最要紧的那段逻辑 —— **合并方向与上传判据** —— 就一条都测不了，
 * 只能靠真机。
 *
 * 收成接口之后，单测用一个 Map 就能覆盖全部分支，而 `LibraryDb` 天然满足它
 * （两个方法的签名就是照着它写的）。PC 端是同一取舍（那边依赖
 * `MediaRepository` 抽象）。
 */
interface ProgressLibrary {

    /** 把库里三列的**现有投影**读成一份进度书（播种用）。 */
    fun progressSnapshot(): ProgressBook

    /** 把一份进度书回填进库里三列；返回被更新的行数。 */
    fun applyProgressSnapshot(book: ProgressBook): Int
}

/**
 * 播放进度的**静默同步**：与媒体库备份完全无关的一条小通道。
 *
 * 与 PC 端 `lib/data/db/progress_sync.dart` 的 `ProgressSyncService` 是同一套
 * 流程、同一套判据。
 *
 * ## 它做的四件事（顺序不能换）
 *
 *   1. **播种** —— 把媒体库行里已有的进度读进进度库（[ProgressLibrary.progressSnapshot]）。
 *      老用户升级上来的那一刻，进度文件还不存在，而库里已经攒了几百条；不播种
 *      的话那批进度永远留在本地，同步不到别的设备。
 *   2. **下载** —— 取网盘上的 `云影备份/playback_progress.json`。
 *   3. **合并** —— 逐条 LWW（[ProgressBook.mergeFrom]）。**不是**整份覆盖：
 *      两台设备各看一集，两条都该留下。
 *   4. **回填** —— 把合并后的结果写回 `media_items` 的三列
 *      （[ProgressLibrary.applyProgressSnapshot]），让二十多处 SQL 查询立刻
 *      看到新进度。
 *
 * 最后才决定要不要上传：**只有当合并后的状态与网盘上那份不同**才传。
 *
 * ## ⛔ 「静默」是硬要求
 *
 * 这个方法**绝不弹窗、绝不抛异常、绝不阻塞播放**。它挂在启动、退出播放器、
 * 以及一个 30 分钟的定时器上；任何一次失败都只该在日志里留一行，下一轮自己
 * 会重试。
 *
 * 尤其是：**下载失败时绝不上传**。读不到远程就传本地，等于用「本机知道的那部分
 * 进度」把网盘上另一台设备的进度**整个覆盖掉** —— 而那正是这个功能最不能出的错。
 *
 * ## 为什么网盘那一步是**两个回调**
 *
 * 那个真正干活的 `LibraryBackupService` 要构造出一个可用实例得先有一整套
 * `PanApi`（而且它在单测里造不出来，见 [ProgressLibrary] 的文档）。这里真正需要
 * 的只有「读一个文件」和「写一个文件」两件事，收成回调之后单测用一个
 * `ByteArray?` 变量就能覆盖全部合并分支。
 *
 * ## 线程模型
 *
 * [syncSilently] / [backfill] 都是**阻塞**的（网络 + 磁盘）。调用方负责放到
 * [com.cloudcine.tv.pan.Bg]。
 */
class ProgressSync(
    private val store: ProgressStore,
    private val library: ProgressLibrary,
    /** 读网盘上的进度文件。`null` = 网盘上还没有这份文件（**不是错误**）。抛异常 = 这次读不到。 */
    private val downloadRemote: () -> ByteArray?,
    /** 覆盖写网盘上的进度文件。 */
    private val uploadRemote: (ByteArray) -> Unit,
) {

    /** 一轮静默同步的结果。**只用于日志与诊断**，不上屏。 */
    data class Outcome(
        /** 这一轮有没有成功（跳过也算成功 —— 没出事）。 */
        val ok: Boolean,
        val message: String,
        /** 从媒体库播种进进度库的条数。 */
        val seeded: Int = 0,
        /** 从远程合进来的条数。 */
        val mergedIn: Int = 0,
        /** 回填进媒体库的行数。 */
        val applied: Int = 0,
        val downloaded: Boolean = false,
        val uploaded: Boolean = false,
    )

    private var running = false

    @Volatile private var lastOkAtMs: Long? = null

    @Volatile private var lastFailure: String? = null

    /** 有没有一轮正在跑。调度器用它避免叠加（30 分钟的定时器撞上「退出播放器」）。 */
    val isRunning: Boolean get() = running

    /** 上一次**成功**跑完的时刻（Unix 毫秒）；从没成功过时为 `null`。 */
    val lastSuccessAtMs: Long? get() = lastOkAtMs

    /** 上一次失败的原因；从没失败过时为 `null`。 */
    val lastError: String? get() = lastFailure

    /**
     * 跑一轮。**绝不抛**。
     *
     * ⛔ `running` 防叠加是 `@Synchronized` 的：它同时被界面线程（退出播放器）
     *    与定时器线程（30 分钟）碰，而两个线程同时进 `_run` 的后果是**两份合并
     *    交叉写同一个文件**。
     */
    fun syncSilently(): Outcome {
        synchronized(this) {
            if (running) return Outcome(ok = true, message = "上一轮还没跑完")
            running = true
        }
        try {
            val outcome = run()
            if (outcome.ok) {
                lastOkAtMs = System.currentTimeMillis()
                lastFailure = null
            } else {
                lastFailure = outcome.message
            }
            return outcome
        } catch (t: Throwable) {
            // 兜底：`run` 内部已经把每一步都包了，但「绝不让同步拖垮调用方」这条
            // 承诺值得再兜一层 —— 它挂在启动路径与播放器退出路径上。
            lastFailure = t.toString()
            Log.e(TAG, "[进度] 进度同步异常：$t")
            return Outcome(ok = false, message = t.toString())
        } finally {
            synchronized(this) { running = false }
        }
    }

    private fun run(): Outcome {
        store.load()

        // 1. 播种：库里的投影 → 进度库。只有第一次（或恢复备份之后）会真的合进
        //    东西，之后这一步恒为 0。
        var seeded = 0
        try {
            seeded = store.mergeFrom(library.progressSnapshot())
        } catch (e: Exception) {
            Log.w(TAG, "[进度] 从媒体库播种进度失败（继续走远程那一步）：$e")
        }

        // 2. 下载。`null` = 网盘上还没有这份文件（**不是错误**）。
        var remoteBytes: ByteArray? = null
        var remoteReadable = false
        try {
            remoteBytes = downloadRemote()
            remoteReadable = true
        } catch (e: Exception) {
            Log.w(TAG, "[进度] 下载远程进度失败，本轮不上传：$e")
        }

        if (!remoteReadable) {
            // ⛔ 读不到远程就**不传**（理由见类文档）。但本地该做的两件事照做：
            //    合出来的进度仍然是本机最全的一份，回填之后界面是对的。
            store.flush()
            applyToLibrary()
            return Outcome(ok = false, message = "下载远程进度失败，本轮未上传", seeded = seeded)
        }

        // 3. 合并（逐条 LWW）。
        var mergedIn = 0
        if (remoteBytes != null) {
            mergedIn = store.mergeFrom(ProgressBook.fromBytes(remoteBytes))
        }

        store.flush()
        val applied = applyToLibrary()

        // 4. 要不要上传？判据是「合并后的状态与网盘上那份是否不同」。
        //
        // ⛔ 不用 `mergedIn > 0` 当判据：那说的是「远程有没有东西给我」，而这里
        //    要问的是「我有没有东西要给远程」。本地新看了一集、远程一无所知时
        //    `mergedIn == 0`，但**必须上传**。
        val needUpload: Boolean = if (remoteBytes == null) {
            store.book.isNotEmpty
        } else {
            val union = ProgressBook(LinkedHashMap(ProgressBook.fromBytes(remoteBytes).items))
            union.mergeFrom(store.book) > 0
        }

        var uploaded = false
        if (needUpload) {
            try {
                uploadRemote(store.book.toBytes())
                uploaded = true
            } catch (e: Exception) {
                Log.w(TAG, "[进度] 上传进度文件失败（本地已合并，下一轮重试）：$e")
                return Outcome(
                    ok = false,
                    message = "上传失败：$e",
                    seeded = seeded,
                    mergedIn = mergedIn,
                    applied = applied,
                    downloaded = remoteBytes != null,
                )
            }
        }

        Log.i(
            TAG,
            "[进度] 同步完成：本地 ${store.book.length} 条 ｜ 播种 $seeded、" +
                "合入 $mergedIn、回填 $applied 条 ｜ ${if (uploaded) "已上传" else "无需上传"}",
        )
        return Outcome(
            ok = true,
            message = if (uploaded) "已同步并上传" else "已同步（无需上传）",
            seeded = seeded,
            mergedIn = mergedIn,
            applied = applied,
            downloaded = remoteBytes != null,
            uploaded = uploaded,
        )
    }

    /**
     * **只做本地那一半**：播种 + 落盘 + 回填，不碰网盘。
     *
     * 给「清空索引库 / 恢复备份 / 重新扫描」之后调 —— 那三种情况下库里的
     * `media_items` 刚被整批换掉，而进度真源在别处，必须当场把它贴回来，
     * 否则用户看到的是「刚恢复完，所有进度都没了」（要等下一轮同步才回来）。
     *
     * 返回回填的行数。**绝不抛**。
     */
    fun backfill(): Int {
        return try {
            store.load()
            store.mergeFrom(library.progressSnapshot())
            store.flush()
            applyToLibrary()
        } catch (t: Throwable) {
            Log.w(TAG, "[进度] 进度回填失败（下一轮同步会再试）：$t")
            0
        }
    }

    /** 把进度库回填进媒体库；返回被更新的行数。失败不抛。 */
    private fun applyToLibrary(): Int = try {
        library.applyProgressSnapshot(store.book)
    } catch (e: Exception) {
        Log.w(TAG, "[进度] 回填媒体库失败（进度已落盘，下次再试）：$e")
        0
    }

    private companion object {
        const val TAG = "CloudCine"
    }
}

/**
 * 「**本次启动**的进度同步跑过了吗」—— 与 [StartupSync] 完全同一个套路。
 *
 * ## ⛔ 为什么需要它（而不是直接挂在媒体库页的 `onCreate` 上）
 *
 * 本工程每个页面是一个独立 Activity，**从「文件列表」/ 刮削页返回媒体库会重建
 * [com.cloudcine.tv.LibraryActivity]**。把启动同步直接挂在它的 `onCreate` 上，
 * 就变成「来回切一次同步一次」—— 每次都是一轮网盘列目录 + 下载。用户感知不到，
 * 但它是白花的流量与电。
 *
 * 零点与 [StartupSync] 一样在 [com.cloudcine.tv.MainActivity]（LAUNCHER 入口，
 * 自己 `finish()` 掉）—— 从电视桌面点一次图标就一定新建一次它。
 */
object ProgressSyncGate {

    @Volatile
    private var launched = false

    /** 「本次启动」的零点 —— 由 `MainActivity.onCreate` 调。 */
    fun beginLaunch() {
        launched = false
    }

    /**
     * 认领「本次启动的那一次同步」。
     *
     * 第一次返回 `true`，之后一律 `false`。⛔ 在**发起时**认领，不等它跑完：
     *    同步要走网络，慢的时候用户可能已经点进「文件列表」又退回来 —— 那时
     *    重建出来的媒体库页会**再发一次**。
     */
    @Synchronized
    fun claimLaunchSync(): Boolean {
        if (launched) return false
        launched = true
        return true
    }
}
