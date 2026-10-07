package com.cloudcine.tv.library

/**
 * 一次追更检查的**纯决策**：从「要查哪些目录」推出「哪些作品的水位线可以推进」。
 *
 * 与 PC 端 `domain/services/follow_plan.dart` 的 `FollowPlan` 逐条对应。
 *
 * ## 为什么把它从 [FollowUpdater] 里抽出来
 *
 * 与 `SyncDecision` / `ScrapeMatch` 同一条理由：这一步的错法**全是静默的** ——
 *
 *   * 目录少查一个 → 那部剧永远不提醒；
 *   * 水位线推早一步 → 新集被永久划进「已经看过」，用户再也不会被提醒；
 *   * 折叠过的作品没翻译回目标 key → 每检查一次就把同一批新集重报一次。
 *
 * 三种都不会报错，只会在几周后表现成「这功能好像坏了」。所以判据必须能被
 * **不碰 IO 的 JVM 单测**钉住 —— 这个类里没有 `LibraryDb`、没有网盘、没有时钟。
 *
 * ## 一次检查的两半
 *
 * ```
 * ① FollowPlan.of(dirs)        → 要列哪些目录（去重后）
 * ② plan.checkedWorks(failed)  → 哪些作品这次真的被完整检查过了
 * ```
 *
 * 中间那一步（真的去列目录）是 [FollowUpdater] 的活，不属于这里。
 */
data class FollowPlan(
    /** 要列目录的目录，**已按 fid 去重**，顺序 = 输入里首次出现的顺序。 */
    val dirs: List<FollowDir>,
    /**
     * 作品 key → 它名下**全部**目录 id。
     *
     * ⛔ 判「这部作品这次能不能推进水位线」用的就是它：只要有**一个**目录
     *    没列成功，就不能推进 —— 那批新集可能正好在没列到的那个目录里。
     *    宁可这次不报、下次重来，也不能把没看到的划进「已读」。
     */
    val dirsByWork: Map<String, Set<String>>,
) {
    /** 这次要发多少个列目录请求（= [dirs] 的长度）。 */
    val requestCount: Int get() = dirs.size

    /**
     * 这次检查结束后，**哪些作品的水位线可以推进**。
     *
     * 判据：它名下的目录**一个都没失败**。
     *
     * ## ⛔ 「一个目录都没有」的作品不在结果里
     *
     * 一部在追的作品可能一个目录都没有（文件行的 `dir_id` 全是空串、或者
     * 它名下一条 `media_items` 都没有）。这时**不能**推进它的水位线 ——
     * 我们什么都没检查，推进等于凭空宣称「查过了」。
     *
     * 代价是它每次都会被重新考虑一遍，但那是零成本的：没有目录就一次网盘
     * 请求都不发。而反过来（推进）会让它**永远**不再被检查。
     */
    fun checkedWorks(failedDirs: Set<String>): Set<String> {
        val out = HashSet<String>(dirsByWork.size * 2)
        for ((key, dirs) in dirsByWork) {
            if (dirs.none { it in failedDirs }) out.add(key)
        }
        return out
    }

    companion object {
        /**
         * 从「目录 → 它覆盖的作品」反推出整个计划。
         *
         * [dirs] 里同一个 fid 出现多次时**合并** `workKeys`（取并集），路径取
         * 首次出现的那个。仓储实现已经去过重，这里再兜一次是为了让这个类
         * **自己**就是可信的 —— 单测直接喂重复输入也应该得到正确的计划。
         */
        fun of(dirs: Iterable<FollowDir>): FollowPlan {
            val byId = LinkedHashMap<String, FollowDir>()
            for (d in dirs) {
                val prev = byId[d.dirId]
                byId[d.dirId] = if (prev == null) {
                    d
                } else {
                    FollowDir(d.dirId, prev.dirPath, prev.workKeys + d.workKeys)
                }
            }

            val dirsByWork = HashMap<String, MutableSet<String>>()
            for (d in byId.values) {
                for (key in d.workKeys) {
                    dirsByWork.getOrPut(key) { HashSet() }.add(d.dirId)
                }
            }

            return FollowPlan(
                dirs = byId.values.toList(),
                dirsByWork = dirsByWork.mapValues { it.value.toSet() },
            )
        }
    }

    override fun toString(): String = "FollowPlan(目录 ${dirs.size}，作品 ${dirsByWork.size})"
}
