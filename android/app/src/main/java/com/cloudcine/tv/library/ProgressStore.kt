package com.cloudcine.tv.library

import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.Timer
import java.util.TimerTask

/**
 * 播放进度的**独立落盘存储**。
 *
 * ## 一句话
 *
 * 它是一个**只装进度**的 JSON 文件（`<filesDir>/playback_progress.json`），与
 * 媒体库索引库 `cloudcine.sqlite` **互不隶属**。清空索引库删的是后者的几张表、
 * 恢复备份换的是后者的整个文件字节 —— 两条路都碰不到这个文件。
 *
 * ## 为什么是 JSON 文件，而不是第二个 SQLite 库
 *
 * 三条理由，按重要性排：
 *
 *   1. **它就是同步载荷**。上传到网盘的那份字节与本地这份**逐字相同**，于是
 *      「本地存了什么」和「网上存了什么」永远是同一个格式、同一段序列化代码
 *      —— 少一处能让两边悄悄分叉的地方。
 *   2. **没有 codegen 依赖**。本工程用裸 `SQLiteDatabase`（没有 Room），再开
 *      一张「进度表」就要多一套 DDL 与迁移；而这份数据的全部操作就是「读一整个
 *      Map、写一整个 Map」。
 *   3. **写频率与体积都撑得住**。进度每 10 秒变一次（播放中的进度回报），一次
 *      全量重写。几千条约几百 KB，写在电视的内部存储上是一次毫秒级的写；而
 *      真正常见的规模是几百条。
 *
 * ## ⛔ 写入是「防抖 + 原子替换」
 *
 *   * **防抖**（[flushDelayMs]）：一次播放中每 10 秒就有三处写入
 *     （`markPlayed` / `saveResumePosition` / `saveMaxPosition`），每次都落盘是
 *     三次全量重写。合并成一次，用户感受不到差别。
 *   * **原子替换**：先写 `<path>.tmp` 再 `rename`。直接覆写原文件的话，写到一半
 *     被杀（电视上很常见）会留下一份**截断的 JSON** —— 下次读回来整份进度都没
 *     了，而用户只会看到「所有进度凭空消失」。`rename` 在同一文件系统内是原子
 *     的，读到的要么是旧的完整文件、要么是新的完整文件。
 *
 * ## ⛔ 写之前**一定**先 [load]
 *
 * 两处都做了保证（[flush] 与 [mergeFrom] 各自先 [load]），因为「先写、后读」
 * 的后果是**静默的**：内存里只有刚写的那一条，落盘时把整个文件覆盖成「只有
 * 一条」，用户磁盘上原有的几百条进度全没了。
 *
 * ## 线程模型
 *
 * 单进程内**只有一个实例**（[shared]）。写入口来自三条不同的线程：界面（点一集
 * 就写已读回执）、播放页的后台线程（每 10 秒一次进度回报）、同步线程（合入远程
 * 并回填）。所以所有公开方法都是 `@Synchronized` 的 —— 内部那个 `LinkedHashMap`
 * 不是线程安全的，而并发改 Map 的后果是**抛 `ConcurrentModificationException`
 * 或悄悄丢条目**，两者都发生在「用户正在看片」的时候。
 *
 * ⛔ 落盘是**阻塞 IO**，调用方负责放到 [com.cloudcine.tv.pan.Bg]（本工程统一约定）。
 */
class ProgressStore(
    /** 落盘路径。 */
    val file: File,
    /** 取「现在」的 Unix 秒。单测注入固定时钟用。 */
    private val clock: () -> Long = { System.currentTimeMillis() / 1000L },
    /**
     * 防抖窗口（毫秒）。`<= 0` = **不挂定时器**，必须显式 [flush]。
     *
     * 单测用后者：定时器线程会让「哪一刻落了盘」变得不可预测。
     */
    private val flushDelayMs: Long = DEFAULT_FLUSH_DELAY_MS,
) {

    private val data = ProgressBook()

    @Volatile private var loaded = false
    @Volatile private var dirty = false
    @Volatile private var disposed = false

    /**
     * 防抖定时器。**进程内只建一个线程**，靠取消 [flushTask] 而不是取消 Timer
     * 来实现「重复调用只重置计时器」—— `Timer.cancel()` 是**终局**的，取消过的
     * Timer 不能再 `schedule`。
     *
     * ⛔ `by lazy` 而不是在构造里建：`flushDelayMs <= 0`（单测）时一个线程都不该
     *    冒出来，否则「哪一刻落了盘」会变得不可预测。
     */
    private val timer: Timer by lazy { Timer("cloudcine-progress-flush", true) }
    private var flushTask: TimerTask? = null

    /** 落盘路径（诊断日志用）。 */
    val path: String get() = file.absolutePath

    /** 内存里的那份。**只读用途**（同步服务拿它序列化上传）。 */
    val book: ProgressBook get() = data

    /** 是否已经读过磁盘（[load] 跑过）。 */
    val isLoaded: Boolean get() = loaded

    /** 有没有还没落盘的改动。 */
    val isDirty: Boolean get() = dirty

    // ------------------------------------------------------------------
    // 读
    // ------------------------------------------------------------------

    /**
     * 从磁盘读一次。重复调用是幂等的。
     *
     * ⛔ **读进来的内容是「合进」内存那份，不是「替换」**：调用方可能在 [load]
     *    之前就已经写过几条（启动路径上读盘与「播放页回报进度」是并发的）。
     *    直接替换会把这几条悄悄丢掉。合并用的是同一套 LWW，内存里刚写的那条
     *    `u` 最新，自然赢。
     *
     * ⛔ 文件不存在 / 内容损坏**都不算错误**：前者是全新安装，后者最坏也只是
     *    「这一次读不到进度」。抛出去的话，它挂在启动路径上，一次坏文件就会让
     *    应用起不来 —— 而进度本来就是**可再生的**数据。
     */
    @Synchronized
    fun load() {
        if (loaded) return
        try {
            if (!file.exists()) {
                Log.i(TAG, "[进度] 进度文件不存在，从空开始：$path")
            } else {
                val loadedBook = ProgressBook.fromBytes(file.readBytes())
                val added = data.mergeFrom(loadedBook)
                Log.i(
                    TAG,
                    "[进度] 已载入进度文件：磁盘 ${loadedBook.length} 条、" +
                        "合入 $added 条（内存共 ${data.length} 条）",
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "[进度] 读取进度文件失败，从空开始：$e")
        } finally {
            loaded = true
        }
    }

    // ------------------------------------------------------------------
    // 写（内存 + 防抖落盘）
    // ------------------------------------------------------------------

    /**
     * 记一次「播放过」（已读回执 + 最近播放排序）。
     *
     * 返回是否**真的改了东西**（内容没变就不落盘、也不触发同步）。
     *
     * ⛔ 时间戳只前进：设备时钟回拨时不该让「最近播放」倒退。
     */
    @Synchronized
    fun recordPlayed(itemId: String, atSec: Long): Boolean {
        if (itemId.isEmpty()) return false
        val old = data[itemId]
        if (old?.playedAtSec != null && old.playedAtSec >= atSec) return false
        return put(
            itemId,
            ProgressEntry(
                resumeMs = old?.resumeMs,
                maxMs = old?.maxMs,
                playedAtSec = atSec,
                updatedAtSec = nextUpdated(old),
            ),
        )
    }

    /**
     * 写续播点（毫秒）。`null` / `<= 0` 一律记成「没有可续的点」。
     *
     * 与 `LibraryDb.saveResumePosition` 同一口径：**不写 0**，`null` 才是这一列
     * 真正的「没有可续的点」。
     */
    @Synchronized
    fun recordResume(itemId: String, resumeMs: Long?): Boolean {
        if (itemId.isEmpty()) return false
        val value = if (resumeMs == null || resumeMs <= 0L) null else resumeMs
        val old = data[itemId]
        if (old?.resumeMs == value) return false
        return put(
            itemId,
            ProgressEntry(
                resumeMs = value,
                maxMs = old?.maxMs,
                playedAtSec = old?.playedAtSec,
                updatedAtSec = nextUpdated(old),
            ),
        )
    }

    /**
     * 把「历史最大播放位置」往上顶到 [positionMs]（**只增不减**）。
     *
     * ⛔ 只增不减的判据与 `LibraryDb.saveMaxPosition` 那条 SQL 逐字一致
     *    （`max(COALESCE(max_position_ms,0), ?)`）—— 两处判据一旦不同，「哪一边
     *    赢」就会随写入顺序变。
     */
    @Synchronized
    fun recordMax(itemId: String, positionMs: Long): Boolean {
        if (itemId.isEmpty() || positionMs <= 0L) return false
        val old = data[itemId]
        if (old?.maxMs != null && old.maxMs >= positionMs) return false
        return put(
            itemId,
            ProgressEntry(
                resumeMs = old?.resumeMs,
                maxMs = positionMs,
                playedAtSec = old?.playedAtSec,
                updatedAtSec = nextUpdated(old),
            ),
        )
    }

    /**
     * 把一份**远程**（或从库里导出）的进度合进来。
     *
     * 返回被改变的条目数（0 = 无需上传）。会先 [load]，理由见类文档。
     */
    @Synchronized
    fun mergeFrom(other: ProgressBook): Int {
        load()
        val changed = data.mergeFrom(other)
        if (changed > 0) markDirty()
        return changed
    }

    // ------------------------------------------------------------------
    // 落盘
    // ------------------------------------------------------------------

    /** 安排一次防抖落盘。重复调用只会重置计时器。 */
    private fun markDirty() {
        dirty = true
        if (disposed || flushDelayMs <= 0L) return
        flushTask?.cancel()
        val task = object : TimerTask() {
            override fun run() {
                flush()
            }
        }
        flushTask = task
        timer.schedule(task, flushDelayMs)
    }

    /**
     * 立刻落盘（若有改动）。同步服务在上传之前**必须**先调它，否则上传的会是
     * 「内存里比磁盘新」的那一份 —— 两端内容对不上。
     */
    @Synchronized
    fun flush() {
        flushTask?.cancel()
        flushTask = null
        // ⛔ 先保证读过磁盘：不读就写会把文件覆盖成「只有内存里那几条」。
        load()
        if (!dirty) return
        writeNow()
    }

    /**
     * 关掉计时器并做最后一次落盘。**单测用**。
     *
     * ⛔ 生产代码里**不要**对 [shared] 那个单例调它：`disposed` 一旦置位，
     *    之后所有写入都不会再自动落盘（只能靠显式 [flush]）。页面退出时该调的是
     *    [flush]。
     */
    @Synchronized
    fun dispose() {
        disposed = true
        flushTask?.cancel()
        flushTask = null
        flush()
    }

    private fun writeNow() {
        val tmp = File(file.absolutePath + ".tmp")
        try {
            tmp.parentFile?.mkdirs()
            FileOutputStream(tmp).use { out ->
                out.write(data.toBytes())
                out.flush()
                // ⛔ 必须 fsync：`rename` 保证的是「指向哪个 inode」是原子的，
                //    不保证内容已经落到介质上。断电时会出现「新名字 + 空内容」，
                //    而那份文件读回来是**合法的空书** —— 进度静默全丢。
                out.fd.sync()
            }
            if (!tmp.renameTo(file)) {
                // 极少数情况下（目标被占用）`renameTo` 会失败。删掉再试一次，
                // 仍然失败就留着 `.tmp` 报错 —— 至少不破坏原文件。
                file.delete()
                if (!tmp.renameTo(file)) {
                    throw IllegalStateException("rename 失败：${tmp.absolutePath} → $path")
                }
            }
            // ⛔ 只有写成功才清 `dirty`。写失败时留着它，下一次写入会再试一次
            //    —— 清掉的话这次改动就永远只活在内存里，而进程一退就没了。
            dirty = false
        } catch (e: Exception) {
            Log.e(TAG, "[进度] 进度文件写入失败（${data.length} 条）：$e")
        }
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    private fun put(itemId: String, entry: ProgressEntry): Boolean {
        data[itemId] = entry
        markDirty()
        return true
    }

    /**
     * 这一条新的 `updatedAtSec`：取「现在」与「旧值」的较大者。
     *
     * ⛔ 不取 `max` 的话，一次时钟回拨会让新写入的 `u` 小于网盘上那份旧的 `u`，
     *    于是**本地刚看的进度在合并时输给远程的旧进度** —— 表现是「看完一集
     *    回到电脑上，进度又退回去了」，而且两边都显示同步成功。
     */
    private fun nextUpdated(prev: ProgressEntry?): Long {
        val now = clock()
        val old = prev?.updatedAtSec ?: 0L
        return if (now > old) now else old
    }

    companion object {

        private const val TAG = "CloudCine"

        /**
         * 本地进度文件名。与网盘上那份**同名**
         * （见 [LibraryBackupService.PROGRESS_FILE_NAME]），也与 PC 端
         * `ProgressStore.fileName` 逐字一致。
         */
        const val FILE_NAME = "playback_progress.json"

        /** 默认防抖窗口。与 PC 端 `ProgressStore` 的 `flushDelay = 2s` 一致。 */
        const val DEFAULT_FLUSH_DELAY_MS = 2_000L

        @Volatile
        private var instance: ProgressStore? = null

        /**
         * 进程内**唯一**的进度库实例。
         *
         * ## ⛔ 为什么必须是单例
         *
         * 本工程每个页面是一个独立 Activity，各自 `LibraryDb(LibraryPaths.dbFile(this))`
         * —— 同一个库文件会被打开好几个句柄（这是有意为之，见 `LibraryDb` 的类
         * 文档）。但进度库**不能**照抄这个模式：它是「读一整个 Map、写一整个
         * Map」，两个实例各持一份内存副本的话，后落盘的那份会把先落盘的整个覆盖
         * 掉 —— 而两边都显示「写入成功」。
         *
         * ⛔ 零点在 [com.cloudcine.tv.MainActivity]（App 的真正入口）：它保证
         *    实例在任何页面写进度之前就已经存在。播放页也可能被
         *    [com.cloudcine.tv.BrowseActivity] 直接拉起，那条路上媒体库页未必
         *    建过 —— 靠「媒体库页会建」是不够的。
         */
        @Synchronized
        fun shared(file: File): ProgressStore {
            instance?.let { return it }
            return ProgressStore(file).also { instance = it }
        }

        /** 已经建好的实例；没建过时为 `null`（单测里就是这个状态）。 */
        fun peek(): ProgressStore? = instance
    }
}
