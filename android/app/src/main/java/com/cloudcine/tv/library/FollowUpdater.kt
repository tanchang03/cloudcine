package com.cloudcine.tv.library

import android.util.Log

/**
 * **追更检查**：把已追剧作品名下的目录各过一遍，算出「新入库了几条」。
 *
 * 与 PC 端 `domain/services/follow_service.dart` 的 `FollowService` 逐条对应。
 *
 * ## 它解决什么问题
 *
 * 网盘上用户追的剧更新了第 13 集。全盘扫描（[LibraryScanner.scan]）能发现，
 * 但代价是遍历几千个目录、几分钟、一次被限流的风险 —— 而这个动作在用户
 * 心里是「点一下看看有没有」。
 *
 * 追更检查只列**已追剧作品名下的那几个目录**（去重后通常 1~5 个），秒级完成，
 * 而且**只增不减**：不写续扫游标、不做陈旧清理。
 *
 * ## 三条判据（全部基于已有的 `media_items.first_seen_at`）
 *
 * ```
 * ① 「本次新扫到的条」   = first_seen_at > follow_checked_at   → 累加进角标
 * ② 「追剧以来新增的条」 = first_seen_at > follow_started_at   → 剧集行 NEW 标签
 * ③ 「这一集还没看过」   = max_position_ms IS NULL
 * ```
 *
 * ② ∧ ③ 由 `Work.isNewSinceFollow` 在**渲染时**现算，这里不写任何东西。
 *
 * ⛔ **刻意不用 `media_items.modified_at`**：那是网盘给的文件修改时间，
 *    **替换文件（换一版更高码率）也会变** —— 用它当判据会把「换了个版本」
 *    误报成「更新了最新一集」。
 *
 * ## 线程
 *
 * ⛔ **必须在后台线程调**（[com.cloudcine.tv.pan.Bg]）。它会发网盘请求，
 *    也会写库 —— 在主线程上跑就是 ANR。
 */
class FollowUpdater(
    private val db: LibraryDb,
    private val scanner: LibraryScanner,
    private val clock: () -> Long = LibraryDb::nowSec,
) {

    /** 检查进度快照（给状态行用）。 */
    data class Progress(val done: Int, val total: Int, val currentDir: String)

    /** 一次追更检查的结果。 */
    data class Outcome(
        /** 被节流窗口挡掉了（一次网盘请求都没发）。 */
        val skipped: Boolean = false,
        /** 在追的作品数。 */
        val followedWorks: Int = 0,
        /** 成功列完的目录数。 */
        val dirsChecked: Int = 0,
        /** 列失败的目录数。**不为 0 时结果是不完整的**。 */
        val dirsFailed: Int = 0,
        /** 本次**水位线被推进**的作品数。 */
        val worksChecked: Int = 0,
        /** 其中**真的查出有新集**的作品数。 */
        val updatedWorks: Int = 0,
        /** 本次新发现的总条数。 */
        val newItems: Int = 0,
        val cancelled: Boolean = false,
        /** 面向用户的失败原因（`null` = 正常跑完）。 */
        val error: String? = null,
    ) {
        /**
         * 有东西要告诉用户吗（决定要不要刷海报墙 / 状态行）。
         *
         * ⛔ 「没查出更新」**不是**「有东西要说」—— 每次进媒体库都写一句
         *    「没有更新」是最典型的噪音，而电视上的状态行本来就窄。
         */
        val hasNews: Boolean get() = newItems > 0

        /** 给状态行用的一句话。 */
        val message: String
            get() = when {
                skipped -> ""
                error != null -> "检查更新失败：$error"
                cancelled -> "检查已取消"
                newItems > 0 -> "$updatedWorks 部剧有更新（共 $newItems 集）"
                dirsFailed > 0 -> "检查完成，但有 $dirsFailed 个目录没读到"
                else -> ""
            }
    }

    /**
     * 跑一次检查。
     *
     * @param force `true` = 手动入口：无视节流窗口、也无视 `follow_auto_check`
     *   是不是 `off`（用户明确要求了）。
     * @param windowSec 节流窗口。启动检查传
     *   [FollowAutoCheck.LAUNCH_WINDOW_SEC]，手动入口传 `null`。
     * @param cancel 协作式取消。取消**不回滚已经推进的水位线** ——
     *   那部分是真实检查过的，留着是对的。
     */
    fun check(
        force: Boolean = false,
        windowSec: Long? = null,
        cancel: LibraryScanner.Cancellation? = null,
        onProgress: ((Progress) -> Unit)? = null,
    ): Outcome {
        val startedAt = clock()

        // ---- 1. 节流闸 ----
        val window = if (force) null else (windowSec ?: FollowAutoCheck.LAUNCH_WINDOW_SEC)
        if (window != null && window > 0) {
            val lastSec = db.getSetting(LibrarySettings.FOLLOW_LAST_CHECK_AT)?.toLongOrNull()
            if (lastSec != null && startedAt - lastSec < window) {
                Log.i(TAG, "追剧：距上次检查 ${startedAt - lastSec}s，未到窗口 ${window}s，跳过")
                return Outcome(skipped = true)
            }
        }

        // ---- 2. 追剧清单 ----
        //
        // ⛔ 空清单要**提前返回**：一部都没在追时，后面每一步都是零成本的空转，
        //    但第 4 步会真的去发网盘请求 —— 提前返回就是「一次请求都不发」。
        val keys = db.followedWorkKeys()
        if (keys.isEmpty()) {
            markChecked(startedAt)
            Log.i(TAG, "追剧：没有在追的作品，跳过")
            return Outcome()
        }

        // ---- 3. 目录集合（并集口径，含被折叠的源作品名下的文件）----
        val plan = FollowPlan.of(db.dirsForWorks(keys))
        Log.i(TAG, "追剧：开始检查，在追 ${keys.size} 部 · 目录 ${plan.requestCount} 个")

        if (plan.requestCount == 0) {
            // 一部在追的作品一个目录都没有（文件行的 dir_id 全是空串）。
            // ⛔ **不能**推进它们的水位线：我们什么都没检查。
            markChecked(startedAt)
            return Outcome(followedWorks = keys.size)
        }

        // ---- 4. 逐个目录跑局部发现 ----
        //
        // ⛔ `recursive = true`：剧集常在 `S01/` 子目录里，只看一层会永远
        //    发现不了新集（设计文档红线 3）。
        val failed = HashSet<String>()
        var done = 0
        var cancelled = false
        var error: String? = null
        for (dir in plan.dirs) {
            if (cancel?.isCancelled == true) {
                cancelled = true
                break
            }
            done++
            onProgress?.invoke(Progress(done, plan.requestCount, dir.dirPath))
            try {
                val discovery = scanner.discover(
                    rootFid = dir.dirId,
                    rootPath = dir.dirPath,
                    recursive = true,
                )
                // ⛔ 判据是「这一次列目录完整吗」，不是「有没有新东西」。
                //    `failedDirs > 0` 时结果是不完整的（子目录超时/限流），
                //    那批新集可能正好在没读到的子目录里 —— 推进水位线等于把
                //    它们永久划进「已读」，用户再也不会被提醒，而且不报错。
                if (discovery.error != null || discovery.failedDirs > 0 || discovery.cancelled) {
                    failed.add(dir.dirId)
                    Log.w(
                        TAG,
                        "追剧：目录未读完整，本次不推进水位线 ${dir.dirPath}" +
                            "（跳过 ${discovery.failedDirs} 个子目录，取消=${discovery.cancelled}，" +
                            "错误=${discovery.error}）",
                    )
                }
            } catch (t: Throwable) {
                // 单个目录失败不该毁掉整次检查 —— 其它目录的结果照样有效。
                failed.add(dir.dirId)
                Log.w(TAG, "追剧：列目录失败 ${dir.dirPath}", t)
            }
        }

        // ⛔⛔ 水位线取的是**发现跑完之后**的时刻，不是检查开始那一刻。
        //
        // 发现的产物是 `media_items.first_seen_at`（那一刻写进去的），而水位线
        // 是「我们已经看到这里了」的承诺。用**开始**时刻当水位线的话，这次检查
        // 自己刚插进去的那些行（`first_seen_at` 晚于开始时刻）在下一次检查里
        // 会**被再数一遍** —— 角标翻倍，而且不报错。
        //
        // 反过来用**结束**时刻也不会漏：这次数过的行 `first_seen_at <= 结束时刻`，
        // 下次的判据 `first_seen_at > 结束时刻` 对它们为假。
        //
        // ⚠️ 已知的 1 秒竞态：全库时间列都是**秒**，所以「恰好在结束那一秒里、
        //    且没被这次列目录看到」的新文件会被划进「已读」。要触发它需要一次
        //    并发的扫描/发现正好落在那一秒 —— 概率极低，且修它只能靠毫秒时间列
        //    （跨端契约，代价远大于收益）。
        val checkedAt = clock()

        // ---- 5. 回写（一个事务）----
        //
        // ⛔ **按目录**回写，不是按「发起检查的那一部」：`/电影/` 是平铺的，
        //    一个目录含几十部作品。只回写发起者的话，同一个目录里同时更新的
        //    另外几部就永远收不到提醒。
        val checked = plan.checkedWorks(failed)
        var updatedWorks = 0
        var newItems = 0
        if (checked.isNotEmpty()) {
            // ⚠️ 这里读的是**旧**水位线（还没写回去），所以「本次新增」的判据
            //    `first_seen_at > 旧水位线` 正好把这次发现插进来的行算进去。
            val counts = db.pendingNewItemCounts(checked)
            val increments = HashMap<String, Int>()
            for ((key, n) in counts) if (n > 0) increments[key] = n
            // ⛔ 即使 `increments` 是空的**也要写**：`checkedKeys` 的语义是
            //    「这些作品这次被完整检查过了」，水位线要跟着推进 —— 不推进的话
            //    下一次会把同一批老条目重新数一遍。
            db.applyFollowCheck(increments, checked, checkedAt)
            updatedWorks = increments.size
            newItems = increments.values.sum()
        }

        // ---- 6. 节流零点 ----
        markChecked(checkedAt)

        val outcome = Outcome(
            followedWorks = keys.size,
            dirsChecked = plan.requestCount - failed.size,
            dirsFailed = failed.size,
            worksChecked = checked.size,
            updatedWorks = updatedWorks,
            newItems = newItems,
            cancelled = cancelled,
            error = error,
        )
        Log.i(TAG, "追剧：检查结束 ${outcome.message.ifEmpty { "无更新" }}")
        return outcome
    }

    /**
     * 推进全局节流零点（Unix 秒的十进制字符串）。
     *
     * ⛔ 放在 `settings` 表（`follow_last_check_at`），**不是** `media_works`
     *    的任何一列 —— 同步判据 `libraryModifiedAt()` 不含 `settings` 表，
     *    写它不会让本机「看起来更新」。写进 `media_works` 的话，每次自动检查
     *    都会改同步判据，本机永远赢下 LWW 比较、把另一台设备的进度盖掉。
     */
    private fun markChecked(atSec: Long) {
        db.setSetting(LibrarySettings.FOLLOW_LAST_CHECK_AT, atSec.toString())
    }

    companion object {
        private const val TAG = "CloudCine"
    }
}
