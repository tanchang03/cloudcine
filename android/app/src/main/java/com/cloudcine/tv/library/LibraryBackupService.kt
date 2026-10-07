package com.cloudcine.tv.library

import android.util.Log
import com.cloudcine.tv.pan.PanApi
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * 媒体库备份的**上传 / 下载 / 恢复 / 同步**。
 *
 * 与 PC 端 `LibraryBackupService` 是同一套流程、同一个字节格式、同一条
 * 同步判据 —— 只有这样，电脑上扫出来的库才能在电视上被原样读出来，
 * 电视上看了一半的进度才能回到电脑上接着看。
 *
 * ## 三条通道（对应 UI 上的三个入口）
 *
 * | 入口 | 方法 | 行为 |
 * |---|---|---|
 * | 上传备份 | [uploadBackup] | 无条件把本地库推上去，文件名带时间戳 |
 * | 从网盘恢复 | [restoreLatest] | 无条件拉最新的一份下来覆盖本地 |
 * | 同步 | [sync] | 按 [SyncDecision] 判方向，两边都可能被改 |
 *
 * ⛔ **三个入口都要给用户看到「这次到底动了哪一边」**。同步的错法是静默的：
 *    它永远会显示「成功」，只是可能把其中一边的库换成了另一边的。
 *    所以每个方法都返回一句可以原样上屏的说明。
 *
 * ## 线程模型
 *
 * 全部阻塞（网络 + 磁盘）。**调用方负责放到 [com.cloudcine.tv.pan.Bg]**。
 */
class LibraryBackupService(
    private val db: LibraryDb,
    private val api: PanApi,
    /** 海报缓存目录（PC 端是 `<support>/posters`）。不存在时按空目录处理。 */
    private val posterDir: File,
    private val deviceId: String,
    private val deviceName: String,
    private val now: () -> Long = { System.currentTimeMillis() },
) {

    private val tag = "CloudCine"

    /** 网盘上的一份备份。 */
    data class RemoteBackup(
        val fileId: String,
        val name: String,
        val sizeBytes: Long,
        val modifiedAtMs: Long,
    )

    /** 一次同步的结果。[message] 可以直接上屏。 */
    data class SyncOutcome(
        val action: SyncDecision.Action,
        /** 恢复时被采纳的远程文件名；上传时为 `null`。 */
        val remoteName: String? = null,
        /** 上传后的 fid；恢复时为 `null`。 */
        val uploadedFileId: String? = null,
    ) {
        val message: String get() = action.message
        val restores: Boolean get() = action.restores
        val uploads: Boolean get() = action.uploads
    }

    /**
     * 启动时那次**只读探测**的结果：网盘上最新的备份是什么、按 [SyncDecision]
     * 该往哪边走。
     *
     * ⛔ 探测**不动任何一边**（不传、不覆盖），拿到的只是一个方向。
     *    真正动手要用户点「立即同步」，那才会走 [sync]。
     */
    data class Probe(
        val action: SyncDecision.Action,
        /** 网盘备份目录里最新的那一份；目录不存在 / 是空的时为 `null`。 */
        val latest: RemoteBackup? = null,
        /** 上面那一份的清单（只读了包头的几十 KB）。 */
        val remoteManifest: BackupManifest? = null,
        /** 本机库的内容变更时间（Unix 秒，`null` = 空库）。给提示文案用。 */
        val localModifiedAtSec: Long? = null,
    )

    // ------------------------------------------------------------------
    // 导出 / 导入（本地，不碰网盘）
    // ------------------------------------------------------------------

    /**
     * 把本地媒体库打包成备份字节流。
     *
     * ⛔ [includeSettings] 与 PC 端一样**只是清单上的标注**：导出的是整个
     *    数据库文件的原始字节，在字节层面剔掉一张表做不到。传 `false` 的
     *    后果只有两条：日志里多一行、`note` 变成「不含设置」。设置照样在包里。
     *
     * ⛔ 读库内容变更时间**必须排在 [LibraryDb.rawBytes] 之前** ——
     *    后者会关掉连接，之后再查会重新打开一次（能work，但白开一次库）。
     */
    fun exportBackup(
        includePosters: Boolean = true,
        includeSettings: Boolean = true,
        note: String? = null,
    ): ByteArray {
        val modifiedAtSec = db.libraryModifiedAt()
        val dbBytes = db.rawBytes()

        // 海报：只有**真的有文件**时才打包并写进 fileNames。
        // ⛔ 空目录也写 `posters/` 的话，导入端会拿一段 4 字节的终止标记
        //    去解包 —— 不报错、解出 0 个文件，只是白跑一趟。
        var posterBytes: ByteArray? = null
        var posterCount = 0
        if (includePosters) {
            posterCount = posterDir.listFiles()?.count { it.isFile } ?: 0
            if (posterCount > 0) posterBytes = BackupPackage.packDirectory(posterDir)
        }

        val manifest = BackupManifest(
            deviceId = deviceId,
            deviceName = deviceName,
            createdAt = now(),
            // ⛔ 秒 → 毫秒：库里的时间列是 Unix **秒**，而 manifest 走 ISO 毫秒。
            libraryModifiedAt = modifiedAtSec?.let { it * 1000L },
            schemaVersion = LibrarySchema.VERSION,
            fileNames = buildList {
                add(BackupManifest.DB_ENTRY)
                if (posterBytes != null) add(BackupManifest.POSTERS_ENTRY)
            },
            note = note ?: if (includeSettings) null else "不含设置",
        )

        val out = BackupPackage.build(manifest, dbBytes, posterBytes)
        Log.i(
            tag,
            "[备份] 导出 ${out.size} 字节（库 ${dbBytes.size}、海报 $posterCount 个 " +
                "${posterBytes?.size ?: 0} 字节）；库内容变更时间=" +
                (modifiedAtSec?.let { "${it}s" } ?: "无（空库）"),
        )
        return out
    }

    /**
     * 用备份字节流**覆盖**本地媒体库。
     *
     * ⛔ 这是**破坏性**操作（本地未备份的改动会没）。UI 必须二次确认，
     *    而 [sync] 那条路只在判定「远程赢」时才调它。
     */
    fun importBackup(bytes: ByteArray) {
        val parsed = BackupPackage.parse(bytes)
        val m = parsed.manifest

        // ⛔ 来自更高版本的库只**警告**，不拦。拦下来的后果是「用户拿新版电脑
        //    备份的库，在电视上恢复不了」；而放行的后果只是「多出来的列被忽略」
        //    （`ensureSchema` 只补不删）。与 PC 端同一取舍。
        if (m.schemaVersion > LibrarySchema.VERSION) {
            Log.w(
                tag,
                "[备份] 这份备份来自更高版本（schemaVersion=${m.schemaVersion} > " +
                    "${LibrarySchema.VERSION}），多出来的列会被忽略",
            )
        }

        db.replaceWithRawBytes(parsed.dbBytes)
        // `ensureSchema` 已经在 open() 里跑过：缺的表/列补齐、user_version 对齐。

        val posters = parsed.posterBytes
        if (posters != null) {
            val n = BackupPackage.unpackDirectory(posters, posterDir)
            Log.i(tag, "[备份] 恢复海报 $n 个 → ${posterDir.absolutePath}")
        }

        Log.i(
            tag,
            "[备份] 恢复完成：库 ${parsed.dbBytes.size} 字节，" +
                "库内容变更时间=${m.libraryModifiedAt ?: "无（空库）"}，来自「${m.deviceName}」",
        )
    }

    // ------------------------------------------------------------------
    // 网盘
    // ------------------------------------------------------------------

    /**
     * 列出网盘备份目录里的备份包，**按修改时间倒序**（最新在前）。
     *
     * 目录不存在时会**创建**它 —— 这是本类唯一的写副作用，且只在
     * 「列一份还没有的备份」时发生。
     */
    fun listRemoteBackups(dirName: String = BackupPackage.BACKUP_DIR_NAME): List<RemoteBackup> =
        listIn(api.ensureFolder(PanApi.ROOT, dirName))

    /** 列一个已确定的目录 fid 里的备份包，按修改时间倒序。 */
    private fun listIn(dirFid: String): List<RemoteBackup> =
        api.listDirectory(dirFid, page = 1, size = 200)
            .filter { !it.isDir && it.name.endsWith(BackupPackage.EXTENSION) }
            .map { RemoteBackup(it.fid, it.name, it.sizeBytes, it.updatedAtMs) }
            .sortedByDescending { it.modifiedAtMs }

    /**
     * 把备份推上网盘，返回新文件的 fid。
     *
     * ⛔ 同名文件**先删后传**（与 PC 端一致）。所以调用方给的文件名
     *    **必须带时间戳**（[defaultFileName] 就是干这个的）—— 用固定名的话，
     *    一次失败的上传会把上一份好备份也一起带走，而中间那段空窗期里
     *    网盘上是**什么都没有**。
     */
    fun uploadBackup(
        bytes: ByteArray,
        dirName: String = BackupPackage.BACKUP_DIR_NAME,
        fileName: String = defaultFileName(),
        onProgress: ((sent: Int, total: Int) -> Unit)? = null,
    ): String {
        val dirFid = api.ensureFolder(PanApi.ROOT, dirName)

        api.listDirectory(dirFid, page = 1, size = 200)
            .firstOrNull { !it.isDir && it.name == fileName }
            ?.let {
                Log.i(tag, "[备份] 同名文件已存在，先删除旧文件 fid=${it.fid}")
                api.deleteFiles(listOf(it.fid))
            }

        val fid = api.uploadFile(dirFid, fileName, bytes, onProgress)
        Log.i(tag, "[备份] 上传完成「$fileName」→ fid=$fid")
        return fid
    }

    /** 下载一份备份的原始字节。 */
    fun downloadBackup(fileId: String): ByteArray = api.fileBytes(fileId)

    // ------------------------------------------------------------------
    // 播放进度文件（`云影备份/playback_progress.json`）
    //
    // ⛔ 它是**独立的第二条通道**，与 `.ccbak` 备份包互不隶属：
    //    * 备份包装的是 `cloudcine.sqlite` 的原始字节，每次上传都是**新文件名**
    //      （带时间戳），所以目录里会攒下一串历史；
    //    * 进度文件是**当前状态**，**固定名、覆盖写** —— 攒历史毫无意义，
    //      而且恢复时还得挑「哪一份才是最新的」。
    //    两者的生命周期完全不同，混在一起只会让「恢复备份」顺手把进度也换了。
    // ------------------------------------------------------------------

    /**
     * 读网盘备份目录里的进度文件。
     *
     * `null` = **网盘上还没有这份文件**（全新用户 / 另一台设备还没同步过）——
     * 这是**正常情况**，不是错误。
     *
     * ⛔ 目录不存在时**不创建**（走 [PanApi.findFolder]）：从没同步过进度的用户，
     *    不该每开一次电视就被塞一个空目录。
     *
     * ⚠️ 网络失败 / 限流会**抛**（由 [PanApi] 抛）。调用方必须据此放弃上传 ——
     *    见 [ProgressSync] 的类文档。
     *
     * 阻塞（网络）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
     */
    fun downloadProgressFile(
        dirName: String = BackupPackage.BACKUP_DIR_NAME,
        maxBytes: Int = MAX_PROGRESS_BYTES,
    ): ByteArray? {
        val dirFid = api.findFolder(PanApi.ROOT, dirName) ?: return null
        val entry = api.listDirectory(dirFid, page = 1, size = 200)
            .firstOrNull { !it.isDir && it.name == ProgressStore.FILE_NAME }
            ?: return null
        val bytes = api.fileBytes(entry.fid, maxBytes)
        Log.i(tag, "[进度] 已下载网盘进度文件（${bytes.size} 字节，fid=${entry.fid}）")
        return bytes
    }

    /**
     * 覆盖写网盘上的进度文件。目录不存在时会**创建**它。
     *
     * ⛔ 同名文件**先删后传**（与 [uploadBackup] 同一套）。夸克的上传不会覆盖
     *    同名文件，不删的话目录里会攒出两个同名文件，而下次下载拿到的可能是
     *    旧的那个 —— 表现是「同步说成功，进度却一直不变」。
     *
     * 阻塞（网络）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
     */
    fun uploadProgressFile(
        bytes: ByteArray,
        dirName: String = BackupPackage.BACKUP_DIR_NAME,
    ) {
        val dirFid = api.ensureFolder(PanApi.ROOT, dirName)
        api.listDirectory(dirFid, page = 1, size = 200)
            .firstOrNull { !it.isDir && it.name == ProgressStore.FILE_NAME }
            ?.let {
                Log.i(tag, "[进度] 同名进度文件已存在，先删除旧文件 fid=${it.fid}")
                api.deleteFiles(listOf(it.fid))
            }
        val fid = api.uploadFile(dirFid, ProgressStore.FILE_NAME, bytes)
        Log.i(tag, "[进度] 上传完成「${ProgressStore.FILE_NAME}」（${bytes.size} 字节）→ fid=$fid")
    }

    /** 下载**最新**的一份并恢复本地；没有任何备份时返回 `null`。 */
    fun restoreLatest(dirName: String = BackupPackage.BACKUP_DIR_NAME): RemoteBackup? {
        val latest = listRemoteBackups(dirName).firstOrNull() ?: return null
        Log.i(tag, "[备份] 从网盘恢复最新备份「${latest.name}」（${latest.sizeBytes} 字节）")
        importBackup(downloadBackup(latest.fileId))
        return latest
    }

    // ------------------------------------------------------------------
    // 启动探测（只读）
    // ------------------------------------------------------------------

    /**
     * 问一句「网盘上有没有比本机更新的备份」—— **只读，两边都不动**。
     *
     * 与 [sync] 的区别只在最后一步：`sync` 拿到方向之后会真的传 / 真的覆盖，
     * 这里只把方向交回去。启动时**必须**是这一条 —— 在用户点头之前动他的库，
     * 不管往哪边动都是错的。
     *
     * ## ⛔ 三处刻意的「不」
     *
     * 1. **不创建备份目录**（走 [PanApi.findFolder] 而不是 `ensureFolder`）：
     *    从没备份过的用户，每开一次电视就被塞一个空目录。
     * 2. **不整包下载**：清单在包的最前面，只读头部 [MANIFEST_HEAD_BYTES] 字节
     *    （见 [readRemoteManifest]）。
     * 3. **不读库文件字节**（走 [lightLocalManifest]）：[exportBackup] 会调
     *    `LibraryDb.rawBytes()`，而那个方法为了拿到自洽的库文件会**先 close()**
     *    连接 —— 启动路径上主线程刚 `loadWorks()` 完，撞上就是
     *    「already-closed object」。
     *
     * 阻塞（网络）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
     */
    fun probeRemote(dirName: String = BackupPackage.BACKUP_DIR_NAME): Probe {
        val localSec = db.libraryModifiedAt()
        val local = lightLocalManifest(localSec)

        val latest = api.findFolder(PanApi.ROOT, dirName)?.let { listIn(it).firstOrNull() }
        val remote = latest?.let { readRemoteManifest(it) }

        val action = SyncDecision.decide(local, remote)
        Log.i(
            tag,
            "[备份] 启动探测：${action.name}（本地=" +
                (localSec?.let { "${it}s" } ?: "无（空库）") +
                "，远程=${remote?.effectiveModifiedAt ?: "无"}）" +
                "，最新备份=「${latest?.name ?: "无"}」",
        )
        return Probe(action, latest, remote, localSec)
    }

    /**
     * 本地清单的**轻量**版本 —— 只够 [SyncDecision] 做判断，**不读库文件字节**。
     *
     * ⛔ 判据必须与 [exportBackup] 产出的那份清单**逐项等价**：
     *    [SyncDecision.decide] 只用到 `hasLibraryContent`（= `libraryModifiedAt != null`）、
     *    `effectiveModifiedAt`、`deviceId` 三项，而它们分别来自
     *    [LibraryDb.libraryModifiedAt] 与构造参数里的 `deviceId` ——
     *    这里一个都没换口径。
     *
     * `createdAt` 取「现在」只是为了「万一 `libraryModifiedAt` 为 null 时有个
     * 合理的退化值」；那条路已经被 `decide` 的「本地空库」分支挡在前面了
     * （它排在「比时间」之前，见 [SyncDecision.decide] 的注释）。
     */
    private fun lightLocalManifest(modifiedAtSec: Long?): BackupManifest = BackupManifest(
        deviceId = deviceId,
        deviceName = deviceName,
        createdAt = now(),
        // ⛔ 秒 → 毫秒：库里的时间列是 Unix **秒**，manifest 走 ISO 毫秒。
        libraryModifiedAt = modifiedAtSec?.let { it * 1000L },
        schemaVersion = LibrarySchema.VERSION,
        fileNames = listOf(BackupManifest.DB_ENTRY),
    )

    /**
     * 读一份远程备份的清单 —— **先只读头部**，读不出来才整包下载。
     *
     * ⛔ 兜底那条路必须留着：`Range` 是服务端的自愿行为（它也可能直接回整份
     *    200，那就只能拿到前 [MANIFEST_HEAD_BYTES] 字节），而**清单长度是
     *    未知的**（理论上有人可以手工塞一个超长 `note`）。头部里读不出清单时，
     *    整包下载一次总比「探测不到、永远不提示」好。
     */
    private fun readRemoteManifest(backup: RemoteBackup): BackupManifest {
        val head = runCatching { api.fileHeadBytes(backup.fileId, MANIFEST_HEAD_BYTES) }
            .getOrNull()
        if (head != null) {
            val m = runCatching { BackupPackage.extractManifest(head) }.getOrNull()
            if (m != null) return m
            Log.i(
                tag,
                "[备份] 「${backup.name}」头部 ${head.size} 字节里读不到清单，改为整包下载",
            )
        } else {
            Log.i(tag, "[备份] 「${backup.name}」头部读取失败，改为整包下载")
        }
        return BackupPackage.extractManifest(downloadBackup(backup.fileId))
    }

    // ------------------------------------------------------------------
    // 同步
    // ------------------------------------------------------------------

    /**
     * 双向同步。方向由 [SyncDecision] 决定，**两边都可能被改**。
     *
     * 分支顺序与 PC 端 `LibraryBackupService.sync()` **一字不差**，
     * 也与 [SyncDecision.decide] 一字不差 —— 这里是它唯一的调用方。
     */
    fun sync(
        dirName: String = BackupPackage.BACKUP_DIR_NAME,
        includePosters: Boolean = true,
        includeSettings: Boolean = true,
        onProgress: ((sent: Int, total: Int) -> Unit)? = null,
    ): SyncOutcome {
        // 1. 本地清单。⛔ 不含海报：这一步只为了比时间戳，而海报可能有几十 MB。
        val localBytes = exportBackup(includePosters = false, includeSettings = false)
        val localManifest = BackupPackage.extractManifest(localBytes)

        // 2. 远程列表 + 最新那一份的清单
        val remotes = listRemoteBackups(dirName)
        val latest = remotes.firstOrNull()
        val remoteBytes = latest?.let { downloadBackup(it.fileId) }
        val remoteManifest = remoteBytes?.let { BackupPackage.extractManifest(it) }

        // 3. 决策
        val action = SyncDecision.decide(localManifest, remoteManifest)
        Log.i(
            tag,
            "[备份] 同步决策：${action.name}（本地=${localManifest.effectiveModifiedAt}，" +
                "远程=${remoteManifest?.effectiveModifiedAt ?: "无"}）→ ${action.message}",
        )

        return when (action) {
            // 远程没有备份 / 远程是空备份 / 本地更新 → 上传本地
            SyncDecision.Action.uploadFirst,
            SyncDecision.Action.uploadRemoteEmpty,
            SyncDecision.Action.uploadLocalNewer,
            -> {
                val bytes = exportBackup(
                    includePosters = includePosters,
                    includeSettings = includeSettings,
                )
                val fid = uploadBackup(bytes, dirName = dirName, onProgress = onProgress)
                SyncOutcome(action, uploadedFileId = fid)
            }

            // 本地空库 / 远程更新 → 恢复
            SyncDecision.Action.restoreLocalEmpty,
            SyncDecision.Action.restoreRemoteNewer,
            -> {
                // ⛔ 这里**不能**重新下载：`remoteBytes` 已经在手上，
                //    再下一次既慢又可能拿到另一份（用户刚好又备份了一次）。
                val bytes = remoteBytes
                    ?: throw IllegalStateException("决策要恢复远程，但远程字节没拿到")
                importBackup(bytes)
                SyncOutcome(action, remoteName = latest?.name)
            }

            // 冲突 / 无变化 → 什么都不动
            SyncDecision.Action.conflict,
            SyncDecision.Action.unchanged,
            -> SyncOutcome(action, remoteName = latest?.name)
        }
    }

    companion object {

        /**
         * 启动探测时，从备份包头部读多少字节去找清单。
         *
         * 清单是几百字节的 JSON（`deviceId` / 时间 / `fileNames` / 可选 `note`），
         * 64 KiB 留了两个数量级的余量；就算读到的是整包（服务端不认 `Range`），
         * 也只是一次 64 KiB 的读取。
         */
        const val MANIFEST_HEAD_BYTES = 64 * 1024

        /**
         * 进度文件下载的上限字节。
         *
         * 一份几千条的进度大约几百 KB；32 MiB 留了两个数量级。设上限的意义是
         * **挡住把别的文件当成进度文件下下来**（同名目录里万一被人手工放了个
         * 大文件），而不是真的会用到这个数。
         *
         * 与 PC 端 `downloadProgressFile(maxBytes = 32 MiB)` 同一个数。
         */
        const val MAX_PROGRESS_BYTES = 32 * 1024 * 1024

        /**
         * 默认备份文件名：`cloudcine_backup_2026-10-06T19-16-13.ccbak`。
         *
         * ⛔ 格式与 PC 端逐字一致（`DateTime.toIso8601String()` 去掉毫秒、
         *    把 `:` 换成 `-`），且**必须带时间戳** —— 上传是「先删后传」，
         *    固定名会在失败时把上一份好备份一起带走。
         */
        fun defaultFileName(epochMillis: Long = System.currentTimeMillis()): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH-mm-ss", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            return "cloudcine_backup_${fmt.format(Date(epochMillis))}${BackupPackage.EXTENSION}"
        }
    }
}
