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
    // 作用域发现（只增不减）
    // ------------------------------------------------------------------

    /**
     * 一次**作用域发现**的结果。
     *
     * 与 [Outcome] 的差别不只是字段多少 —— 那边带着 `itemsPruned`，
     * 因为全盘扫描会清理陈旧记录；这里**没有这个字段**，因为发现根本不清理
     * （理由见 [discover]）。字段的缺席本身就是一条约定。
     */
    data class Discovery(
        val dirs: Int,
        val files: Int,
        /** 这次看到的可入库视频文件数（**含早已在库的**）。 */
        val found: Int,
        /**
         * 其中**之前不在库里**的条数。
         *
         * 与 [existing] 相加等于 [found]。分开报的理由与 PC 端
         * `DiscoveryOutcome` 一致：用户点「发现」时最想知道的是「有没有新东西」，
         * 只报「发现 12 个媒体文件」而 12 个都是旧的，会让人以为这次什么都没做
         * （其实它把元数据刷新了一遍）。
         */
        val added: Int,
        /** 其中已经在库里的条数。 */
        val existing: Int,
        /** 本次涉及的分组数（会写成作品行）。 */
        val works: Int,
        /** 因超时 / 限流被跳过的目录数。**不为 0 时结果是不完整的**。 */
        val failedDirs: Int,
        val cancelled: Boolean,
        val error: String?,
    ) {
        /** 给状态行用的一句话。 */
        val message: String
            get() {
                if (error != null) return "发现失败：$error"
                // ⛔ 「一个都没发现」必须说清楚是「这里没有视频」而不是「失败」——
                //    合成一句「发现 0 个媒体文件」用户会以为网盘上真没有。
                if (found == 0) return "这个目录里没有可入库的视频"
                val head = if (cancelled) "发现已取消" else "发现完成"
                return buildString {
                    append(head)
                    append("：媒体 ").append(found)
                    append("（新增 ").append(added)
                    append(" / 已有 ").append(existing).append("）")
                    if (works > 0) append(" · 作品 ").append(works)
                    if (failedDirs > 0) append(" · 跳过 ").append(failedDirs).append(" 个目录")
                }
            }
    }

    /**
     * **作用域发现**：只走用户指定的那一片（某个目录，可选含子目录）。
     *
     * ## 它解决什么问题
     *
     * 网盘是个持续变化的目录：用户今天往 `/电影/` 里丢了一部新片。这时让他为了
     * 这一部片子跑一次 [scan]（全盘），代价是遍历几千个目录、好几分钟，
     * 以及一次被限流的风险。发现只走那一小片，几秒完成。
     *
     * ## 与全盘扫描的三条硬区别（缺一条都会静默损坏媒体库）
     *
     * 1. **绝不清理陈旧记录**。全盘扫描扫完会拿「本次见到的 id」当白名单，
     *    删掉网盘侧已删除的行；发现只看到一棵子树，拿它当白名单等于把子树
     *    之外的**全部**媒体项删光。所以这里根本不调 [LibraryDb.pruneMissingItems]。
     * 2. **绝不写续扫游标**。`scan_cursors` 描述的是全盘扫描的 BFS 队列与分页
     *    位置；发现往里写一笔，用户下次「从上次中断处继续」就会从一个错的队列
     *    开始 —— 表现是「续扫之后少了一大半片子」，而这两件事在用户眼里毫无关联。
     * 3. **不递归时只看这一层**。`recursive = false` 只处理 `rootFid` 本身，
     *    子目录一个都不入队（PC 端目录行那个「只发现这一个目录」就是它）。
     *
     * ## 共用的部分
     *
     * 条目解析（[toItem]）、归组（[accumulate] / [toWork]）、分页列目录（[listAll]）
     * 与全盘扫描**是同一份实现** —— 两处各写一遍会让同一个文件走两条路得到不同的
     * `groupKey` 或分类，而那是静默的。
     *
     * ## 线程
     *
     * ⛔ 与 [scan] 一样**必须在后台线程调**（[com.cloudcine.tv.pan.Bg]）。
     *
     * @param rootFid 发现目标的 fid（目录）。
     * @param rootPath 发现目标的完整路径。**会归一成带尾斜杠**（`/电影/`），
     *   因为 `dirPath` 要参与 `groupKey` 的计算，两个调用点传进来的形态
     *   （带 / 不带尾斜杠）必须收敛到同一份。
     */
    fun discover(
        rootFid: String,
        rootPath: String,
        recursive: Boolean = true,
        cancel: Cancellation = Cancellation(),
        onProgress: (Progress) -> Unit = {},
    ): Discovery {
        val root = normalizeDirPath(rootPath)
        val seeds = LinkedHashMap<String, Seed>(64)
        val buf = ArrayList<ScanItem>(FLUSH_AT)
        val queue = ArrayDeque<Dir>()
        queue.add(Dir(rootFid, root))

        var dirs = 0
        var files = 0
        var found = 0
        var failedDirs = 0
        var added = 0
        var existing = 0
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

        fun flush() {
            if (buf.isEmpty()) return
            // ⛔ 先查已有分组键再写（同 [scan]）：库里那些行可能是 PC 端按**它自己的**
            //    解析器分好的组，不复用会把整库拆成两份。
            // ⛔ 这一次查询顺手当「新增 / 已有」的判据 —— 同一个 id 在遍历里不会出现
            //    两次，所以不会重复计数。
            val known = db.groupKeysOf(buf.map { it.id })
            for (raw in buf) {
                val old = known[raw.id]
                if (old == null) added++ else existing++
                val item = if (old != null && old != raw.groupKey) {
                    raw.copy(groupKey = old)
                } else {
                    raw
                }
                accumulate(seeds, item)
            }
            db.applyScanItems(buf)
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
                    Log.w(TAG, "发现：列目录失败，跳过：${dir.path}（${e.message}）")
                    sleepQuietly(FAIL_BACKOFF_MS)
                    report("发现", dir.path)
                    continue
                }
                dirs++
                for (e in entries) {
                    if (e.isDir) {
                        // ⛔ 不递归时**不入队**子目录 —— 这正是「只发现这一层」。
                        //    放在这里而不是循环外：根目录自己还是要处理的。
                        if (!recursive) continue
                        queue.add(Dir(e.fid, joinPath(dir.path, e.name)))
                        continue
                    }
                    files++
                    if (!VideoFormats.isVideoFile(e.name)) continue
                    if (VideoFormats.isDiscImage(e.name)) continue
                    found++
                    buf.add(toItem(e, dir))
                }
                if (buf.size >= FLUSH_AT) flush()
                report("发现", dir.path)
                if (dirs >= MAX_DIRS) {
                    Log.w(TAG, "发现：目录数达到上限 $MAX_DIRS，停止遍历")
                    break
                }
            }
        } catch (t: Throwable) {
            error = t.message ?: t.toString()
            Log.e(TAG, "发现中断", t)
        } finally {
            runCatching { flush() }.onFailure { Log.e(TAG, "发现：尾批入库失败", it) }
        }

        // ---- 入库收尾：补建作品行 + 重算冗余计数（与 [scan] 同一套）----
        report("入库", "", force = true)
        var works = 0
        try {
            val known = db.workKeys()
            val fresh = seeds.keys.filter { it !in known }
            db.insertMissingWorks(fresh.map { toWork(it, seeds.getValue(it)) })
            db.refreshWorkStats(seeds.keys)
            works = seeds.size
        } catch (t: Throwable) {
            error = error ?: (t.message ?: t.toString())
            Log.e(TAG, "发现：作品入库失败", t)
        }

        report(if (cancelled) "已取消" else "完成", "", force = true)
        Log.i(
            TAG,
            "发现 $root${if (recursive) "（含子目录）" else "（仅本层）"}：" +
                "媒体 $found（新增 $added / 已有 $existing）· 作品 $works · 目录 $dirs",
        )
        return Discovery(
            dirs = dirs,
            files = files,
            found = found,
            added = added,
            existing = existing,
            works = works,
            failedDirs = failedDirs,
            cancelled = cancelled,
            error = error,
        )
    }

    /**
     * 目录路径归一化：**一律带尾斜杠**。
     *
     * ⛔ 与 PC 端 `drivePathWithTrailingSlash` 同口径。根目录是 `/`（不是空串）——
     *    空串拼出来的 `groupKey` 与 `/` 拼出来的不同，那会让根目录下的片子
     *    在墙上多出一格。
     */
    private fun normalizeDirPath(path: String): String {
        val p = path.trim()
        if (p.isEmpty() || p == ROOT_PATH) return ROOT_PATH
        return if (p.endsWith("/")) p else "$p/"
    }

    /**
     * 发现**单个文件** —— 文件列表里视频行那个「加入媒体库」。
     *
     * 与 [discover] 的差别只有作用域：这里只入库这一个文件，不列它的兄弟。
     * 不这么做的话，「把这一集加进媒体库」会把整个目录的几百个文件一起拖进来，
     * 而用户在目录视图里点的是**某一行**，他期待的就是那一行。
     *
     * 顺带把同目录的字幕配进来是**额外一次列目录**，这里没做：Android 端的外挂
     * 字幕由播放页在起播时现扫（`PlayerActivity` 拿 `dirId` 干的就是这件事），
     * 库里的 `subtitle_refs` 只用来做「有没有字幕」的提示。少这一次往返，
     * 换来的代价只是提示可能晚一步 —— 而它下次全盘扫描会补上。
     *
     * ⛔ 非视频 / 镜像文件**直接返回零结果**，不写库（`a.jpg` 不该变成「一个视频」）。
     */
    fun discoverFile(entry: DriveEntry, dirPath: String, dirId: String): Discovery {
        val empty = Discovery(0, 1, 0, 0, 0, 0, 0, false, null)
        if (!VideoFormats.isVideoFile(entry.name) || VideoFormats.isDiscImage(entry.name)) {
            Log.i(TAG, "发现文件：跳过非视频 ${entry.name}")
            return empty
        }
        val root = normalizeDirPath(dirPath)
        val item = toItem(entry, Dir(dirId, root))
        val known = db.groupKeysOf(listOf(item.id))
        val oldKey = known[item.id]
        val isNew = oldKey == null
        // 归组用**库里已有的** group_key（与 [discover] 的 flush 同一口径）。
        val grouped = if (oldKey != null && oldKey != item.groupKey) {
            item.copy(groupKey = oldKey)
        } else {
            item
        }

        val seeds = LinkedHashMap<String, Seed>(1)
        accumulate(seeds, grouped)
        db.applyScanItems(listOf(item))

        var works = 0
        try {
            val knownWorks = db.workKeys()
            val fresh = seeds.keys.filter { it !in knownWorks }
            db.insertMissingWorks(fresh.map { toWork(it, seeds.getValue(it)) })
            db.refreshWorkStats(seeds.keys)
            works = seeds.size
        } catch (t: Throwable) {
            Log.e(TAG, "发现文件：作品入库失败", t)
            return Discovery(0, 1, 1, 0, 0, 0, 0, false, t.message ?: t.toString())
        }
        Log.i(TAG, "发现文件「${entry.name}」：${if (isNew) "新增" else "已在库（元数据已刷新）"}")
        return Discovery(
            dirs = 0,
            files = 1,
            found = 1,
            added = if (isNew) 1 else 0,
            existing = if (isNew) 0 else 1,
            works = works,
            failedDirs = 0,
            cancelled = false,
            error = null,
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
