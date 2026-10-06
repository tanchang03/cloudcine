package com.cloudcine.tv.library

import android.util.Log
import com.cloudcine.tv.pan.DriveEntry
import com.cloudcine.tv.pan.PanApi

/**
 * 全盘扫描器：**遍历网盘 → 解析文件名 → 归组 → 入库**。
 *
 * ## 它做什么、不做什么
 *
 * | | 做 | 不做 |
 * |---|---|---|
 * | 网盘 | 广度优先遍历所有目录 | 下载 / 上传任何文件 |
 * | 库 | 写 `media_items`（文件事实）+ 补建 `media_works`（缺的） | **不覆盖**已有作品行、**不碰**播放进度 |
 * | 元数据 | 文件名解析出的片名 / 年份 / 季集 / 分类 | **不刮削**（那是另一件事，见下方「刮削」） |
 *
 * ## 刮削为什么不在这一步
 *
 * 遍历阶段只可能拿到**本地信息**（文件名 + 网盘给的缩略图 / 尺寸 / 时长）。
 * 在线元数据（海报 / 简介 / 评分）要发网络请求，而且是「一部作品一次」——
 * 把它塞进遍历循环里会让「扫目录」和「等 TMDB」互相拖累，也会让「只重扫
 * 不重刮」这种很常见的诉求做不到。所以两件事分成两个动作，
 * **扫描只负责让作品出现在墙上**（没海报时用网盘缩略图兜底）。
 *
 * ## 线程
 *
 * ⛔ **必须在后台线程调**（[com.cloudcine.tv.pan.Bg]）。它会发几百上千次网络
 *    请求，还会在同一个事务里写几千行 —— 放在主线程就是「应用无响应」。
 *
 * ## 幂等性
 *
 * 重复扫描是安全的：已存在的媒体项只更新「文件事实」那几列，
 * 已存在的作品行**一个字都不改**。见 [LibraryDb.applyScanItems] /
 * [LibraryDb.insertMissingWorks] 里的说明。
 */
class LibraryScanner(
    private val api: PanApi,
    private val db: LibraryDb,
    private val provider: String = PROVIDER,
) {

    /**
     * 协作式取消开关。
     *
     * ⛔ 与 PC 端 `ScanCancellation` 同一套思路：**只置一个 volatile 标志**，
     *    由扫描循环在每个目录开头自己查。不做线程中断 —— 中断可能正好落在
     *    「事务已经开始、还没提交」的位置上，而 `endTransaction` 在
     *    `finally` 里，中断会让回滚路径本身抛异常。
     *
     * ⛔ 取消**不回滚已经入库的部分**：那部分是真实扫到的数据，留着是对的。
     *    代价是取消后**不做陈旧清理**（白名单不完整，见 [scan]）。
     */
    class Cancellation {
        @Volatile
        private var flag = false

        val isCancelled: Boolean get() = flag

        fun cancel() {
            flag = true
        }
    }

    /** 进度快照。UI 侧每 400ms 左右收到一次。 */
    data class Progress(
        /** `遍历` / `入库`。 */
        val phase: String,
        val dirs: Int,
        val files: Int,
        val found: Int,
        val failedDirs: Int,
        val pendingDirs: Int,
        val currentDir: String,
    ) {
        val text: String
            get() = buildString {
                append(phase)
                append("：目录 ").append(dirs)
                append(" · 文件 ").append(files)
                append(" · 媒体 ").append(found)
                if (failedDirs > 0) append(" · 跳过 ").append(failedDirs)
            }
    }

    /** 一次扫描的结果。 */
    data class Outcome(
        val itemsInserted: Int,
        val itemsUpdated: Int,
        val itemsPruned: Int,
        val worksCreated: Int,
        val worksRefreshed: Int,
        val dirs: Int,
        val files: Int,
        val found: Int,
        val failedDirs: Int,
        val cancelled: Boolean,
        val error: String?,
    ) {
        /** 给状态行用的一句话。 */
        val message: String
            get() {
                if (error != null) return "扫描失败：$error"
                val head = if (cancelled) "扫描已取消" else "扫描完成"
                return buildString {
                    append(head)
                    append("：媒体 ").append(found)
                    append("（新增 ").append(itemsInserted)
                    append(" / 更新 ").append(itemsUpdated).append("）")
                    append(" · 作品 +").append(worksCreated)
                    if (itemsPruned > 0) append(" · 清理 ").append(itemsPruned)
                    if (failedDirs > 0) append(" · 跳过 ").append(failedDirs).append(" 个目录")
                }
            }
    }

    // ------------------------------------------------------------------
    // 入口
    // ------------------------------------------------------------------

    /**
     * 从网盘根目录开始全盘扫描。
     *
     * ## 陈旧清理的三个前置条件（缺一不可）
     *
     * 扫完会把「库里在、这次没扫到」的媒体项删掉。但白名单式删除在
     * **白名单本身不完整**时是有害的 —— 那会把「明明还在、只是这次没扫到」
     * 的文件连同它们的播放进度一起删掉。所以只在：
     *
     *   1. **没被取消**（取消时白名单只覆盖了一部分目录）；
     *   2. **没有出错**；
     *   3. **一个目录都没列失败**（超时是最常见的失败原因，而超时的目录里
     *      往往正是那批会被误判成「已删除」的文件）；
     *   4. **这次至少扫到一个媒体**（适配器异常返回空页时，不至于把整个库清空）。
     *
     * 这四条与 PC 端 `ScanService` 的 `pruneStale && startedFresh &&
     * cursor.isComplete && error == null` 是同一个取向。
     *
     * ⚠️ 少了第 3 条会有一个很隐蔽的后果：某次扫描恰好有个目录超时，
     *    那个目录下的文件全部被删，用户看到的是「媒体库莫名少了几十部」，
     *    而日志里只有一行「列目录失败，跳过」。
     */
    fun scan(
        cancel: Cancellation = Cancellation(),
        onProgress: (Progress) -> Unit = {},
    ): Outcome {
        val seeds = LinkedHashMap<String, Seed>(512)
        val seen = HashSet<String>(8192)
        val buf = ArrayList<ScanItem>(FLUSH_AT)
        val queue = ArrayDeque<Dir>()
        queue.add(Dir(PanApi.ROOT, ROOT_PATH))

        var dirs = 0
        var files = 0
        var found = 0
        var failedDirs = 0
        var inserted = 0
        var updated = 0
        var error: String? = null
        var cancelled = false
        var lastReport = 0L

        fun report(phase: String, current: String, force: Boolean = false) {
            val now = System.currentTimeMillis()
            if (!force && now - lastReport < REPORT_EVERY_MS) return
            lastReport = now
            runCatching {
                onProgress(Progress(phase, dirs, files, found, failedDirs, queue.size, current))
            }
        }

        /** 攒够一批就落库：一次扫描可能几千个文件，全留在内存里没必要。 */
        fun flush() {
            if (buf.isEmpty()) return
            // ⛔ 先查已有分组键再写：库里那些行是 PC 端按**它自己的**解析器
            //    分好的组，而 Android 侧是移植版 —— 两边对同一个文件给出不同的
            //    `group_key` 完全可能。不复用的话，一次重扫会把整库拆成两份。
            val existing = db.groupKeysOf(buf.map { it.id })
            for (raw in buf) {
                val old = existing[raw.id]
                val item = if (old != null && old != raw.groupKey) {
                    raw.copy(groupKey = old)
                } else {
                    raw
                }
                accumulate(seeds, item)
            }
            val (ins, upd) = db.applyScanItems(buf)
            inserted += ins
            updated += upd
            buf.clear()
        }

        try {
            while (queue.isNotEmpty()) {
                if (cancel.isCancelled) {
                    cancelled = true
                    break
                }
                val dir = queue.removeFirst()
                val entries = try {
                    listAll(dir.fid)
                } catch (e: Throwable) {
                    failedDirs++
                    Log.w(TAG, "列目录失败，跳过：${dir.path}（${e.message}）")
                    // 失败往往是限流 / 超时，连续失败时退一步再继续，
                    // 别把剩下的几百个目录也一起撞死。
                    sleepQuietly(FAIL_BACKOFF_MS)
                    report("遍历", dir.path)
                    continue
                }
                dirs++
                for (e in entries) {
                    if (e.isDir) {
                        queue.add(Dir(e.fid, joinPath(dir.path, e.name)))
                        continue
                    }
                    files++
                    if (!VideoFormats.isVideoFile(e.name)) continue
                    // ⛔ 镜像文件（`.iso`）不入库：它是「一张光盘」，不是一个可播的
                    //    视频流。收进来只会让媒体库多出一批点开就报错的条目。
                    if (VideoFormats.isDiscImage(e.name)) continue
                    found++
                    val item = toItem(e, dir)
                    seen.add(item.id)
                    buf.add(item)
                }
                if (buf.size >= FLUSH_AT) flush()
                report("遍历", dir.path)
                if (dirs >= MAX_DIRS) {
                    Log.w(TAG, "目录数达到上限 $MAX_DIRS，停止遍历")
                    break
                }
            }
        } catch (t: Throwable) {
            error = t.message ?: t.toString()
            Log.e(TAG, "扫描中断", t)
        } finally {
            // 缓冲区里那部分已经扫到的数据照样入库 —— 它是真实的，扔掉没道理。
            runCatching { flush() }.onFailure { Log.e(TAG, "尾批入库失败", it) }
        }

        // ---- 入库收尾：补建作品行 + 重算冗余计数 ----
        report("入库", "", force = true)
        var worksCreated = 0
        var refreshed = 0
        try {
            val known = db.workKeys()
            val fresh = seeds.keys.filter { it !in known }
            worksCreated = db.insertMissingWorks(fresh.map { toWork(it, seeds.getValue(it)) })
            db.refreshWorkStats(seeds.keys)
            refreshed = seeds.size
        } catch (t: Throwable) {
            error = error ?: (t.message ?: t.toString())
            Log.e(TAG, "作品入库失败", t)
        }

        // ---- 陈旧清理 ----
        var pruned = 0
        val canPrune = !cancelled && error == null && failedDirs == 0 && seen.isNotEmpty()
        if (canPrune) {
            try {
                pruned = db.pruneMissingItems(provider, seen)
                if (pruned > 0) {
                    // 文件被删掉的作品，计数要跟着掉到 0（作品行本身不删 ——
                    // 上面挂着刮削结果和用户手改的分类）。
                    db.refreshWorkStats(db.workKeys())
                }
            } catch (t: Throwable) {
                Log.e(TAG, "陈旧清理失败", t)
            }
        } else if (!cancelled && error == null && failedDirs > 0) {
            Log.w(TAG, "有 $failedDirs 个目录列失败，本次不做陈旧清理")
        }

        report(if (cancelled) "已取消" else "完成", "", force = true)
        return Outcome(
            itemsInserted = inserted,
            itemsUpdated = updated,
            itemsPruned = pruned,
            worksCreated = worksCreated,
            worksRefreshed = refreshed,
            dirs = dirs,
            files = files,
            found = found,
            failedDirs = failedDirs,
            cancelled = cancelled,
            error = error,
        )
    }

    // ------------------------------------------------------------------
    // 遍历
    // ------------------------------------------------------------------

    private class Dir(val fid: String, val path: String)

    /**
     * 列完一个目录的**全部**页。
     *
     * ⛔ 必须翻页：`listDirectory` 一次只给 100 条（服务端对每页条数有上限），
     *    而「影视」这种目录下几百个文件是常态。只取第一页的话，症状是
     *    「扫描总是少一批文件」，而且少的是**排序靠后的**那些 —— 看起来像
     *    随机丢数据，极难反查。
     *
     * ⛔ 必须有兜底跳出：万一服务端忽略了 `_page`（永远返回同一页），
     *    翻页循环就永远不结束。所以记下上一页的第一条 fid，重复即判定
     *    「服务端没在翻页」并停下。
     */
    private fun listAll(fid: String): List<DriveEntry> {
        val out = ArrayList<DriveEntry>(128)
        var page = 1
        var prevFirst: String? = null
        while (page <= MAX_PAGES_PER_DIR) {
            val batch = api.listDirectory(fid, page = page, size = PAGE_SIZE)
            if (batch.isEmpty()) break
            if (page > 1 && batch.first().fid == prevFirst) {
                Log.w(TAG, "列目录没有翻页（fid=$fid page=$page），停止")
                break
            }
            prevFirst = batch.first().fid
            out.addAll(batch)
            if (batch.size < PAGE_SIZE) break
            page++
        }
        return out
    }

    /** 一个文件 → 待入库的媒体项。 */
    private fun toItem(e: DriveEntry, dir: Dir): ScanItem {
        val parsed = MediaNameParser.parse(e.name, dir.path)
        return ScanItem(
            id = ScanItem.idOf(provider, e.fid),
            provider = provider,
            fileId = e.fid,
            name = e.name,
            dirId = dir.fid,
            dirPath = dir.path,
            groupKey = parsed.groupKey,
            kind = parsed.kind,
            title = parsed.title,
            year = parsed.year,
            season = parsed.season,
            episode = parsed.episode,
            episodeEnd = parsed.episodeEnd,
            part = parsed.part,
            partLabel = parsed.partLabel,
            container = VideoFormats.containerOf(e.name),
            // 三级判据，顺序照 PC 端 `MediaItem.fromEntry`：
            // 实测尺寸 → 文件名解析 → 文件名里的营销词。
            resolution = VideoFormats.resolutionFromDimensions(e.videoWidth, e.videoHeight)
                ?: parsed.resolution
                ?: VideoFormats.resolutionFromName(e.name),
            sizeBytes = e.sizeBytes.takeIf { it > 0 },
            // ⛔ 库里存的是 **Unix 秒**，而 `updatedAtMs` 是毫秒。
            modifiedAt = e.updatedAtMs.takeIf { it > 0 }?.let { it / 1000L },
            durationMs = e.durationMs,
            videoWidth = e.videoWidth,
            videoHeight = e.videoHeight,
            source = parsed.source,
            videoCodec = parsed.videoCodec,
            audioCodec = parsed.audioCodec,
            flags = parsed.flags,
            releaseGroup = parsed.releaseGroup,
            isSampleOrExtra = parsed.isSampleOrExtra,
            thumbUrl = e.previewUrl,
            // ⚠️ 人脸锚点还没移植解析器（夸克 `cover_face_boundary`），
            //    见 [ScanItem.faceAnchorX]。代价只是按正中裁而不是按人物裁。
            faceAnchorX = null,
        )
    }

    /** 把 `path` 与目录名拼成完整路径。**一律带尾斜杠**（与 PC `drivePathJoin` 同口径）。 */
    private fun joinPath(base: String, name: String): String =
        if (base == ROOT_PATH) "/$name/" else "$base$name/"

    // ------------------------------------------------------------------
    // 归组
    // ------------------------------------------------------------------

    /**
     * 一部作品在遍历期的**种子**。
     *
     * 与 PC 端 `WorkSeed` 一一对应。攒种子而不是「一个文件一部作品」的原因：
     * 一部剧几十集要合成一条作品行，而海报 / 集数 / 季数 / 最后修改时间
     * 都是**跨文件聚合**出来的。
     */
    private class Seed(
        val kind: String,
        val title: String,
        val year: Int?,
        val category: String,
    ) {
        var itemCount = 0
        var totalBytes = 0L
        val seasons = HashSet<Int>(4)
        var lastModifiedAt: Long? = null
        var posterUrl: String? = null
    }

    /**
     * 把一条媒体项累进它所属的种子。
     *
     * ⛔ 片名提不出来的项**不归组**（返回时就不建种子）：`a.mkv` 不该建出一部
     *    叫「a」的作品。它仍然会作为媒体项入库，只是墙上没有它的格子。
     *    这与 PC 端 `WorkSeedBook.add` 的 `hasUsableTitle` 门槛一致。
     */
    private fun accumulate(seeds: MutableMap<String, Seed>, item: ScanItem) {
        val title = item.title
        if (title.isNullOrBlank() || !hasUsableTitle(title)) return

        val seed = seeds.getOrPut(item.groupKey) {
            Seed(
                kind = item.kind,
                title = title,
                year = item.year,
                // 分类判定用「文件名 + 目录路径 + 片名」三处证据，与 PC 一致 ——
                // 网盘上「动漫」这类信息几乎总是写在目录名里（`/动漫/进击的巨人/`），
                // 只看片名会大面积漏判。
                category = MediaCategoryGuesser.guess(
                    kind = item.kind,
                    title = title,
                    fileName = item.name,
                    dirPath = item.dirPath,
                ),
            )
        }
        // ⛔ 缩略图只取分组里**第一条有图的**。一部剧几十集，每集都存一份地址
        //    没有意义；而且用户认的是「这部剧」，不是「第 7 集的那一帧」。
        if (seed.posterUrl == null && item.thumbUrl != null) {
            seed.posterUrl = item.thumbUrl
        }
        seed.itemCount++
        seed.totalBytes += item.sizeBytes ?: 0L
        // ⛔ 季号攒 `Set` 而不是计数器：一季里几十集，计数器会把「12 集」
        //    当成「12 季」。`0` 代表「未标季」，[ScanWork.seasonCount] 不算它。
        seed.seasons.add(item.season ?: 0)
        val m = item.modifiedAt
        if (m != null && (seed.lastModifiedAt == null || m > seed.lastModifiedAt!!)) {
            seed.lastModifiedAt = m
        }
    }

    /** 片名能不能当作品名用：**含至少一个字母或汉字**。纯数字 / 纯符号不算。 */
    private fun hasUsableTitle(title: String): Boolean =
        Regex("[a-z\\u4e00-\\u9fff]", RegexOption.IGNORE_CASE).containsMatchIn(title)

    private fun toWork(key: String, seed: Seed): ScanWork = ScanWork(
        key = key,
        provider = provider,
        kind = seed.kind,
        category = seed.category,
        title = seed.title,
        year = seed.year,
        posterUrl = seed.posterUrl,
        itemCount = seed.itemCount,
        totalBytes = seed.totalBytes,
        // 只数 > 0 的季（`0` 是「未标季」那一桶）。
        seasonCount = seed.seasons.count { it > 0 },
        lastModifiedAt = seed.lastModifiedAt,
    )

    private fun sleepQuietly(ms: Long) {
        try {
            Thread.sleep(ms)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    companion object {
        private const val TAG = "云影扫描"

        /** 与 PC 端 `DriveProvider.quark.id` 必须一致（主键前缀就是它）。 */
        const val PROVIDER = "quark"

        private const val ROOT_PATH = "/"

        /** 一页 100 条 —— 服务端对每页条数有上限，超了不报错、只是返回变少。 */
        private const val PAGE_SIZE = 100

        /** 单个目录最多翻这么多页（兜底，防服务端忽略 `_page`）。 */
        private const val MAX_PAGES_PER_DIR = 200

        /** 全局目录数上限（兜底，防符号链接式的死循环）。 */
        private const val MAX_DIRS = 50_000

        /** 攒够这么多条媒体项就落库一次。 */
        private const val FLUSH_AT = 200

        /** 进度回调的最小间隔。**不能每条目录都回调** —— 那会把主线程刷爆。 */
        private const val REPORT_EVERY_MS = 400L

        /** 列目录失败后的退避（限流 / 超时的常见应对）。 */
        private const val FAIL_BACKOFF_MS = 500L
    }
}
