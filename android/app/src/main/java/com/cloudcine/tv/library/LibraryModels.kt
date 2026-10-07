package com.cloudcine.tv.library

/**
 * 媒体库的**只读视图模型**。
 *
 * ⛔ 只映射 UI 真的会用到的列。**不要**为了「完整」把 `media_works` 的 31 列
 * 全搬进来 —— 每多一列就多一处与 PC 端 schema 脱钩的风险，而真正需要
 * 完整列的场景（迁移、刮削）Android 端现在不做。
 *
 * 时间单位与库里一致：**Unix 秒**（不是毫秒）。展示前自己乘 1000。
 */
data class Work(
    val key: String,
    val kind: String,
    val category: String,
    val title: String,
    val originalTitle: String?,
    val year: Int?,
    val overview: String?,
    val posterUrl: String?,
    val posterFile: String?,
    val posterFaceX: Double?,
    val rating: Double?,
    val genres: List<String>,
    val source: String,
    val itemCount: Int,
    val totalBytes: Long,
    val seasonCount: Int,
    val lastModifiedAt: Long?,
    val firstSeenAt: Long?,
    val lastPlayedAt: Long?,
    /**
     * 该作品**看得最远的那一集**的进度，`0.0~1.0`；没有可续的进度时为 `null`。
     *
     * ⛔ 判据与「继续观看」一致（`LibraryDb.lastUnfinished`）：只看
     *    `resume_position_ms > 0` 且 `duration_ms > 0` 的项。看完的项 PC 端会把
     *    `resume_position_ms` 清成 NULL，所以这里**天然不会**出现 1.0 的进度条。
     * ⛔ 取的是 **max 而不是最近一集**：进度条表达的是「这部剧我看到哪了」，
     *    用户看完第 3 集、回头补第 1 集时，条子不该往回缩。
     * ⛔ 超过 1.0 要钳住 —— 时长是刮削/探测来的，片尾曲会让 position 越过 duration。
     */
    val resumeFraction: Double?,
    /**
     * 是否在追剧（schema v17）。
     *
     * 只映射 UI 真的会用到的三列：这一列（追剧胶囊 / 追剧栏）、
     * [newItemCount]（海报墙角标）、[followStartedAt]（剧集行 NEW 标签）。
     *
     * ⛔ `follow_checked_at` **刻意不映射** —— 它是检查期的**水位线**，
     *    只在 `LibraryDb` 的增量 SQL 里出现，界面从来不看它。
     *    与「不要为了完整把 31 列全搬进来」是同一条规矩。
     */
    val followed: Boolean = false,
    /**
     * **追剧起点**（Unix 秒）；`null` = 没在追剧。
     *
     * ⛔ 只在用户开启追剧时写一次，之后任何检查都不推进它 —— 它是剧集行
     *    NEW 标签的基线（见 [isNewSinceFollow]）。
     */
    val followStartedAt: Long? = null,
    /**
     * 未读新增条数（海报墙角标上的数字）。
     *
     * ⛔ 由 `LibraryDb.applyFollowCheck` **增量累加**，`clearFollowBadge` 清零。
     *    清零**不动** [followStartedAt] —— 否则剧集行的 NEW 标签会跟着消失，
     *    而用户还没看。
     */
    val newItemCount: Int = 0,
) {
    /** 有未读更新（海报墙角标据此决定画不画）。 */
    val hasUpdate: Boolean get() = newItemCount > 0

    /**
     * 这一条媒体项算不算「追剧之后才出现的新集」。
     *
     * 两个条件缺一不可：
     *   1. `firstSeenAt > followStartedAt` —— 追剧**之后**才入库的；
     *      没有这一条的话，刚开启追剧那一刻会把已有的 12 集全标成 NEW；
     *   2. **没播过** —— 见下面那段。
     *
     * ## ⛔ 第 2 条是**两条记录取或**，不是只看进度（2026-10-07）
     *
     * ```
     * 没播过 = maxPositionMs == null  ∧  lastPlayedAt == null
     * ```
     *
     * 原先只看 `max_position_ms`。那一列是「**看到哪儿了**」，只在**进度落库**
     * 时写 —— 而进度落库要 `p.duration > 0`（`PlayerActivity.reportProgress`
     * 里 `if (totalMs > 0L) db.saveMaxPosition(...)`）。时长探测不出来时
     * （转码流、探测失败）**一个字都不写**，于是「点开看了一会儿再退出」
     * 的那一集仍旧挂着 NEW。
     *
     * `last_played_at` 是**已读回执**：`markPlayed` 每次落库都写它，
     * 与时长无关。两条取或之后，「**只要播过就去掉 NEW**」才真的成立
     * （PC 端口径见 `lib/domain/services/follow_read.dart` 的 `isItemWatched`，
     * 两边必须同源）。
     *
     * ⛔ 仍**不能**用 `resume_position_ms`：它看完会被清成 `NULL`，拿它当判据
     *    的话「看完的一集」会重新变成 NEW。
     *
     * ⛔ 也**不能**起播时往 `max_position_ms` 写个 1 毫秒充数：那一列是位置，
     *    列表里每一条点过的都会画出一条 0% 的进度槽，而且与「播了不足 1 秒 =
     *    从没播过」的定义自相矛盾。已读归 `last_played_at`，位置归
     *    `max_position_ms`，两列各司其职。
     *
     * 因为第 2 条，**播过就自动消失，不需要任何额外写入** —— 这也是为什么
     * 剧集行不需要一张「已读」表。
     */
    fun isNewSinceFollow(item: LibraryItem): Boolean {
        val since = followStartedAt ?: return false
        val seen = item.firstSeenAt ?: return false
        if (seen <= since) return false
        return item.maxPositionMs == null && item.lastPlayedAt == null
    }

    /**
     * 卡片副标题。
     *
     * 口径照 PC 端 `MediaWork.subtitleLine`：
     *   1. **分类用中文标签**（`movie` ⇒ 「电影」），不是库里的枚举名；
     *   2. **只有 `seasonCount >= 2` 才画季数** —— 电影和单季剧显示「1 季」是噪音；
     *   3. `itemCount > 0` 就画，剧集写「N 集」、其它写「N 个文件」。
     *
     * ⚠️ 与 PC 端唯一的**有意偏离**：PC 把 `rating` 也接在这条尾巴上，
     *    而这里评分已经画在海报**右上角的角标**里了。同一条信息印两遍
     *    在电视上会显得卡片很吵，所以副标题不再重复它。
     */
    val subtitle: String
        get() {
            val parts = ArrayList<String>(4)
            parts.add(MediaCategoryNames.label(category))
            if (year != null && year > 0) parts.add("$year")
            if (seasonCount >= 2) parts.add("$seasonCount 季")
            if (itemCount > 0) {
                parts.add(if (kind == "episode") "$itemCount 集" else "$itemCount 个文件")
            }
            return parts.joinToString(" · ")
        }

    /**
     * 卡片**副标题（精简版）**：只保留「类型 · 年份」。
     *
     * ⛔ 2026-10-07 用户要求卡片少呈现信息、只显示「影片名称 / 类型 / 年份」，
     *    于是把原来的 [subtitle]（分类·年份·季数·集数）砍掉季数和集数，类型也
     *    从「分类枚举标签」换成更贴近语义的 **genres**（如「动作 · 科幻」）。
     * ⛔ [genres] 为空（未刮削）时回退到 [MediaCategoryNames.label]，否则未
     *    刮削的片子副标题会是空的、卡片看着缺一块。
     */
    val cardMeta: String
        get() {
            val g = genres.filter { it.isNotBlank() }
            val type = if (g.isNotEmpty()) g.joinToString(" · ") else MediaCategoryNames.label(category)
            val parts = ArrayList<String>(2)
            parts.add(type)
            if (year != null && year > 0) parts.add("$year")
            return parts.joinToString(" · ")
        }
    }

/**
 * 媒体项（文件级）。
 *
 * ⛔ [id] 与 [fileId] 是两个东西：`id` 是 `provider:fileId` 拼出来的主键，
 * `fileId` 才是网盘 fid —— 起播要的是后者。
 */
data class LibraryItem(
    val id: String,
    val provider: String,
    val fileId: String,
    /**
     * 文件所在目录的 fid。
     *
     * ⛔ 起播时**必须**把它一起传给播放页 —— 播放页靠它扫同目录的外挂字幕。
     *    单个文件的 fid **推不出**父目录，网盘也没有「查父目录」的接口，
     *    所以这个值只能从库里带过去（PC 端是实时列目录时顺手记下的）。
     */
    val dirId: String,
    val name: String,
    val dirPath: String,
    val groupKey: String,
    val kind: String,
    val title: String?,
    val year: Int?,
    val season: Int?,
    val episode: Int?,
    val episodeEnd: Int?,
    val part: Int?,
    val partLabel: String?,
    val container: String,
    val resolution: String?,
    val sizeBytes: Long?,
    val durationMs: Long?,
    val resumePositionMs: Long?,
    val maxPositionMs: Long?,
    val lastPlayedAt: Long?,
    /**
     * 网盘上的**修改时间**（毫秒）；网盘没给时 `null`。
     *
     * ⛔ 库里 `media_items.modified_at` 存的是 **Unix 秒**（全库时间列统一口径），
     *    读出来时已乘 1000 —— 目的只有一个：与网盘那边的 `updatedAtMs`
     *    **同单位**。两个来源单位不同的话，`sortItems` / `compareEntries`
     *    排出来的顺序会差一百万倍，而且不报错。
     *
     * ⛔ **字段名里的 `Ms` 不是装饰**：2026-10-07 简介页的时间列又乘了一次
     *    1000，得到公元 5 万年的时刻，`Fmt.relativeTime` 于是把**每一行**都
     *    写成「刚刚」（用户报的是「修改时间不是网盘文件的修改时间」）。
     *    写界面时先看清楚这个后缀。
     *
     * ⛔ `null` 必须能在界面上表达成「—」，不能当 0：0 会被读成
     *    「1970 年传的」，那是撒谎。
     */
    val modifiedAtMs: Long? = null,
    val thumbUrl: String?,
    val faceAnchorX: Double?,
    val videoWidth: Int?,
    val videoHeight: Int?,
    /**
     * 花絮 / 样片 / 预告。
     *
     * ⛔ 点作品卡片直接播放时**必须先滤掉它们**（见 [PlayTarget]）——
     *    否则用户点《流浪地球 2》会看到 40 秒的预告片。
     */
    val isSampleOrExtra: Boolean,
    /**
     * 这一条**首次入库**时间（Unix 秒）。schema v1 就有这一列，只是到 v17
     * 才被界面用到（追剧的「新集」标签）。
     *
     * ⛔ 它只在**行首次插入**时写（`LibraryDb.applyScanItems` 的新行分支），
     *    重扫不刷新 —— 这正是「新集」的定义。
     *    **不能用 `modifiedAtMs` 代替**：那是网盘给的文件修改时间，
     *    **替换文件（换一版更高码率）也会变**，用它当判据会把「换了个版本」
     *    误报成「更新了最新一集」。
     *
     * ⛔ 单位是**秒**（与库里其它时间列一致），不是 [modifiedAtMs] 那种毫秒。
     */
    val firstSeenAt: Long? = null,
) {
    /** 列表里那一行标题：优先作品给的标题，退回文件名。 */
    val displayTitle: String get() = title?.takeIf { it.isNotBlank() } ?: name

    /** `S01E03` 这种编号（有季/集号时才拼）。 */
    val episodeTag: String?
        get() {
            val s = season ?: return null
            val e = episode ?: return null
            val end = episodeEnd
            val ep = if (end != null && end > e) "E%02d-E%02d".format(e, end) else "E%02d".format(e)
            return "S%02d%s".format(s, ep)
        }
}

/**
 * 一部（或几部）作品名下的一个**网盘目录** —— 追更检查要列的就是这些目录，
 * 外加「这个目录覆盖到了哪些在追的作品」。
 *
 * 与 PC 端 `domain/entities/follow_dir.dart` 的 `FollowDir` 一一对应
 * （那边是 Dart class，这里是 data class，字段名逐字相同）。
 *
 * ⛔ [dirPath] **必须带尾斜杠**：它参与 `groupKey` 的计算
 *    （`ParsedMediaName` 拿目录路径当分组依据），少了斜杠会让「新集的
 *    groupKey」算成另一个作品 —— 症状是「检查到了新集，却挂到了不存在的
 *    作品上」，而媒体库里什么都不会出现。
 *
 * ## 为什么 [workKeys] 挂在目录上，而不是另开一张「作品 → 目录」表
 *
 * 检查回写要回答的是「**这个目录**列成功之后，哪些作品的水位线可以推进」
 * —— 一个目录可能覆盖**多部**作品（`/电影/` 是平铺的，一个目录几十部片子）。
 * 把归属关系挂在目录上，正好是回写循环的形状：
 *
 * ```
 * for (dir in dirs) if (dir 成功) for (key in dir.workKeys) 允许推进(key)
 * ```
 *
 * ⛔ 反过来「一部作品 → 它的目录」也要能反推出来（判「这部作品的目录是不是
 *    **全部**成功了」）—— 由 [FollowPlan] 在内存里求逆，不再查一次库。
 */
data class FollowDir(
    val dirId: String,
    val dirPath: String,
    /**
     * 这个目录**覆盖到的在追作品 key**。
     *
     * ⛔ 含**被折叠进它们的源作品**：跨目录归一从不改写 `media_items.group_key`，
     *    所以「这部作品的文件在哪些目录」的正确答案是并集 —— 只算目标自己的
     *    key，会让合并过的剧永远收不到更新提醒。这里已经把这些源作品的文件
     *    归到**目标 key** 上（不暴露源 key），因为水位线只写在目标行上。
     */
    val workKeys: Set<String>,
)
