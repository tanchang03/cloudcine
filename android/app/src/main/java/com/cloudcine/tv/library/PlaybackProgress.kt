package com.cloudcine.tv.library

/*
 * 播放进度的**独立存储模型** —— 纯数据 + 纯合并，不碰 IO。
 *
 * 与 PC 端 `lib/domain/services/playback_progress.dart` 是**同一份契约**：
 * 同一个 JSON 结构、同一套合并规则、同一套单位。两端的 `playback_progress.json`
 * 必须能被对方逐条读出来，否则「电脑上看了一半、电视上接着看」就是假的。
 *
 * ## 为什么要有它（而不继续只用 `media_items` 的三列）
 *
 * 进度原先只存在媒体库索引库 `cloudcine.sqlite` 的 `media_items` 里
 * （`resume_position_ms` / `max_position_ms` / `last_played_at`）。那个位置
 * 有两个**必然丢数据**的缺口：
 *
 *   1. **清空索引库**（`LibraryDb.wipeIndex()`）删的正是 `media_items` ——
 *      进度跟着一起没了；
 *   2. **恢复媒体库备份**（`.ccbak`）装的是 `cloudcine.sqlite` 的**原始字节**，
 *      恢复 = 整文件替换 —— 本地进度被备份里那份旧进度覆盖。
 *
 * 这两件事都是用户**主动**做的、而且都合理（重建索引 / 换机器），所以不能靠
 * 「劝用户别做」来规避。唯一的出路是**把进度挪出那个文件**：本模型落盘的
 * `playback_progress.json` 与 `cloudcine.sqlite` **互不隶属**。
 *
 * ## 它同时是跨端同步的载荷
 *
 * 进度天然是**逐条**的（一条 = 一个文件看到哪儿了），而媒体库同步是**整份**的
 * LWW。用整份 LWW 同步进度有一个立刻能撞上的坏处：A 机器在看第 1 集、B 机器在
 * 看第 2 集，两边各推一次整份，后推的那份会把对方那一集抹掉。
 *
 * 所以这里按**条目**做 LWW（[ProgressEntry.mergedWith]），而
 * [ProgressBook.mergeFrom] 只把「远程更权威」的那些条目换过来。
 *
 * ## ⛔ 单位一律是「毫秒 / Unix 秒」，与库里那三列逐字对齐
 *
 *   * [ProgressEntry.resumeMs] / [ProgressEntry.maxMs] —— **毫秒**
 *     （库里是 `resume_position_ms` / `max_position_ms`）；
 *   * [ProgressEntry.playedAtSec] / [ProgressEntry.updatedAtSec] —— **Unix 秒**
 *     （库里的 `last_played_at` 是 Unix 秒，见 `LibraryDb` 类注释）。
 *
 * 混用毫秒和秒是这类字段最容易犯、又**最不容易被发现**的错：写成毫秒的
 * 「秒」列落在 1970 年附近，排序看着「有值」，只是永远垫底。
 */

/**
 * 一个媒体项的进度条目。
 *
 * 三个业务字段与库里的三列一一对应，[updatedAtSec] 是**同步用的**第四项。
 *
 * ⛔ 三个业务字段都是 `Long?` 而不是 `Long`：`null` 是它们**真实的取值**
 *    （「没有可续的点」「从没播过」），不是「没填」。用 `0` 代替 `null` 会让
 *    `resumePositions` 里多出一个恒假的条目，而且跨端比不出差异。
 */
data class ProgressEntry(
    /** 续播点（毫秒）。`null` = 没有可续的点（没播过 / 已看完 / 关了「记住播放进度」）。 */
    val resumeMs: Long? = null,

    /** 历史最大播放位置（毫秒，**只增不减**）。`null` = 从没播过。 */
    val maxMs: Long? = null,

    /**
     * 最后一次播放时刻（Unix 秒）。`null` = 没播过。
     *
     * ⚠️ 它同时是「已读回执」：用户在列表里**点开**一集（哪怕只看了 3 秒）
     * 就会写它，剧集行的 `■ NEW` 与追剧角标都靠它消失。
     */
    val playedAtSec: Long? = null,

    /**
     * 这一条**最后一次被写入**的时刻（Unix 秒）。
     *
     * ## 为什么必须单独存一份，而不是复用 [playedAtSec]
     *
     * 两者在「播放中」高度重合（每 10 秒一次进度回报会同时推进它们），
     * 但**不是同一件事**：
     *
     *   * [playedAtSec] 是**业务语义**（什么时候看的），要跟着备份跨端走；
     *   * [updatedAtSec] 是**合并语义**（哪一份更新），只服务于 LWW。
     *
     * 分开的直接好处：「看完清续播点」这一步只改 [resumeMs] 与 [updatedAtSec]，
     * 不会把 [playedAtSec] 往前推 —— 否则「最近播放」的排序会被一次清理动作扰动。
     */
    val updatedAtSec: Long,
) {

    /** 三个业务字段全空 = 这一条什么信息都没有。 */
    val isEmpty: Boolean
        get() = resumeMs == null && maxMs == null && playedAtSec == null

    /**
     * 只有「已读」而没有「位置」—— 用户在列表里点开过，但没播够 10 秒。
     *
     * 追剧的 NEW 判定要区分「点过」与「看过」。
     */
    val isReadOnly: Boolean
        get() = playedAtSec != null && resumeMs == null && maxMs == null

    /**
     * 与 [other] 合并，返回**胜出**的那一份。
     *
     * ## 规则（三条，缺一条就会丢进度）
     *
     *   1. **[updatedAtSec] 大的一方赢**，拿走 `resumeMs` 与 `playedAtSec`；
     *      相等时**保留自己**（`>=`）—— 这样两台设备在同一秒各写一次时，结果
     *      在两台机器上是**同一个**（都保留自己的那份，而两份在这一刻本来就
     *      等价），不会来回抖。
     *   2. **[maxMs] 取两边的较大值**，与谁赢无关。它是「历史最远位置」，
     *      **只增不减**是它的定义 —— 用 LWW 会让「另一台机器看得更远」这件事
     *      被一次较晚的、位置较浅的写入抹掉，而用户看到的是进度条倒退。
     *   3. **[playedAtSec] 也取较大值**，理由同上：「最近播放」不该倒退。
     *
     * ⛔ 规则 2 / 3 与规则 1 **方向相反**是刻意的：可加合的量取并集，有状态的量
     *    取 LWW。把 `maxMs` 也交给 LWW 是最容易犯的那个错。
     */
    fun mergedWith(other: ProgressEntry): ProgressEntry {
        val winner = if (updatedAtSec >= other.updatedAtSec) this else other
        return ProgressEntry(
            resumeMs = winner.resumeMs,
            maxMs = maxOrNull(maxMs, other.maxMs),
            playedAtSec = maxOrNull(playedAtSec, other.playedAtSec),
            updatedAtSec = winner.updatedAtSec,
        )
    }

    /** 这一条与 [other] 是否**内容相同**（含 [updatedAtSec]）。 */
    fun sameAs(other: ProgressEntry): Boolean =
        resumeMs == other.resumeMs &&
            maxMs == other.maxMs &&
            playedAtSec == other.playedAtSec &&
            updatedAtSec == other.updatedAtSec

    /**
     * 序列化成一个紧凑的 JSON 对象（`null` 的字段直接省掉）。
     *
     * 省字段不是为了好看：一份进度文件动辄几千条，每条少三个键就是几百 KB 的
     * 差别，而这个文件每 30 分钟就要传一次。键名（`r`/`m`/`p`/`u`）与 PC 端
     * **逐字一致**。
     */
    fun toJson(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>(4)
        resumeMs?.let { out["r"] = it }
        maxMs?.let { out["m"] = it }
        playedAtSec?.let { out["p"] = it }
        out["u"] = updatedAtSec
        return out
    }

    override fun toString(): String =
        "ProgressEntry(resume=$resumeMs, max=$maxMs, played=$playedAtSec, updated=$updatedAtSec)"

    companion object {

        /**
         * 从 JSON 反序列化。**任何一处不合法就返回 `null`**（整条丢弃）。
         *
         * ⛔ 宁可丢一条，也不要带着一个「字段类型不对」的条目进入合并 ——
         *    那会让 [mergedWith] 在比较时抛，而它跑在同步路径上，一次抛就整轮
         *    同步失败，且用户看不到任何原因。
         */
        fun fromJson(raw: Any?): ProgressEntry? {
            val map = raw as? Map<*, *> ?: return null
            // 没有合并判据的条目无法参与 LWW，只能丢。
            val updated = asLong(map["u"]) ?: return null
            return ProgressEntry(
                resumeMs = asLong(map["r"]),
                maxMs = asLong(map["m"]),
                playedAtSec = asLong(map["p"]),
                updatedAtSec = updated,
            )
        }

        /**
         * JSON 数字 → `Long?`。
         *
         * ⛔ [MiniJson] 解析整数回 `Long`、带小数点/指数的回 `Double`，而
         *    `1e3` / `1000.0` 这种写法在别的实现里完全可能出现 —— 一律接受，
         *    否则一条「1000.0 毫秒」的进度会被整条丢掉。
         */
        private fun asLong(v: Any?): Long? = when (v) {
            is Long -> v
            is Int -> v.toLong()
            is Short -> v.toLong()
            is Byte -> v.toLong()
            is Double -> if (v.isFinite()) v.toLong() else null
            is Float -> if (v.isFinite()) v.toLong() else null
            else -> null
        }

        internal fun maxOrNull(a: Long?, b: Long?): Long? {
            if (a == null) return b
            if (b == null) return a
            return if (a >= b) a else b
        }
    }
}

/**
 * 一部作品的**片头 / 片尾**记录（进度文件 v2）。
 *
 * 与 PC 端 `WorkSkipEntry`（`lib/domain/services/playback_progress.dart`）
 * 是**同一份契约**：同样的键名、同样的合并规则、同样的单位。
 *
 * ## 它为什么住在进度文件里，而不是跟着 `.ccbak` 走
 *
 * 片头 / 片尾是**播放行为**的产物（用户拖一下、或学到一次结论），而媒体库
 * 备份（`.ccbak`）是**手动**的 —— 用户得去点「上传备份 / 从网盘恢复」。
 * 让「看了几集攒出来的片头」等一次手动备份才能到另一台设备上，这个功能
 * 就等于半残。所以它与播放进度共用同一条**静默**通道。
 *
 * `media_works` 上那几列因此退化成**物化投影**（与进度三列同一种角色）：
 * 播放器与 SQL 查询读它，而真源是这个文件。
 *
 * ## ⛔ 两组字段、两个时间戳
 *
 * 手标与学习是**两条独立支路**（`media_works` 里也是两组列），所以合并时
 * 也各判各的：
 *
 * | 组 | 字段 | 判据 |
 * |---|---|---|
 * | 手标 | [introStartMs] / [introEndMs] / [outroOffsetMs] | [manualUpdatedAtSec] |
 * | 学习 | [learnedIntroEndMs] / [learnedOutroOffsetMs] / [learnedSamples] | [learnedUpdatedAtSec] |
 *
 * ⛔ 合成一个时间戳的话，「A 机手标了片头、B 机学出了片尾」会变成互相覆盖
 *    —— 而两台机器都显示同步成功，用户只会觉得「有时候同步丢东西」。
 *
 * ## ⛔ 单位
 *
 * 三个毫秒字段一律**毫秒**（与 `media_works` 的列逐字对齐）；
 * 两个时间戳一律 **Unix 秒**（与 [ProgressEntry.updatedAtSec] 同口径）。
 * 片尾存的是**距末尾的偏移**，不是绝对时间 —— 各集片长不同，绝对时间跨集
 * 不可比。
 */
data class WorkSkipEntry(
    /** 手标片头起点（毫秒）。`null` = 没标。 */
    val introStartMs: Long? = null,

    /** 手标片头终点（毫秒）。与 [introStartMs] 成对，半条当没有。 */
    val introEndMs: Long? = null,

    /**
     * 手标**片尾偏移**（毫秒，距末尾）。`null` = 没标。
     *
     * ⛔ 存偏移不存绝对时间：用户在第 1 集标「41:30」，第 2 集片长不同，
     *    绝对时间搬过去就错了；而「离结尾还有 90 秒」是同一件事。
     */
    val outroOffsetMs: Long? = null,

    /** 手标那一组最后一次被写入（Unix 秒）。`0` = 从没手标过。 */
    val manualUpdatedAtSec: Long = 0,

    /** 学习出的片头**终点**（毫秒）。起点恒为 `0`（片头总在开头），不单独存。 */
    val learnedIntroEndMs: Long? = null,

    /** 学习出的片尾偏移（毫秒，距末尾）。 */
    val learnedOutroOffsetMs: Long? = null,

    /** 学习结论背后的样本数。纯说明性数字，不参与合并判据。 */
    val learnedSamples: Int = 0,

    /** 学习那一组最后一次被写入（Unix 秒）。`0` = 从没学过。 */
    val learnedUpdatedAtSec: Long = 0,
) {

    /** 手标那一组有没有内容。 */
    val hasManual: Boolean
        get() = introStartMs != null || introEndMs != null || outroOffsetMs != null

    /** 学习那一组有没有内容。 */
    val hasLearned: Boolean
        get() = learnedIntroEndMs != null || learnedOutroOffsetMs != null

    /** 两组都空 = 这一条什么信息都没有（落盘与上传时直接丢掉）。 */
    val isEmpty: Boolean get() = !hasManual && !hasLearned

    /**
     * 与 [other] 合并，返回**胜出**的那一份。
     *
     * ⛔ 两组**各判各的**（见类文档）。组内是**整体** LWW，不是逐字段 ——
     *    一次「清除」与一次「设定」都是整组替换，逐字段合并会让清除动作
     *    只清掉一半，而界面上看起来是「清不干净」。
     *
     * 相等时**保留自己**（`>=`）：两台设备在同一秒各写一次时，结果在两台
     * 机器上是同一个，不会来回抖（与 [ProgressEntry.mergedWith] 同一条）。
     */
    fun mergedWith(other: WorkSkipEntry): WorkSkipEntry {
        val manualWins = manualUpdatedAtSec >= other.manualUpdatedAtSec
        val m = if (manualWins) this else other
        val learnedWins = learnedUpdatedAtSec >= other.learnedUpdatedAtSec
        val l = if (learnedWins) this else other
        return WorkSkipEntry(
            introStartMs = m.introStartMs,
            introEndMs = m.introEndMs,
            outroOffsetMs = m.outroOffsetMs,
            manualUpdatedAtSec = m.manualUpdatedAtSec,
            learnedIntroEndMs = l.learnedIntroEndMs,
            learnedOutroOffsetMs = l.learnedOutroOffsetMs,
            learnedSamples = l.learnedSamples,
            learnedUpdatedAtSec = l.learnedUpdatedAtSec,
        )
    }

    /** 内容是否与 [other] 完全相同（含两个时间戳）。合并后据此判断要不要上传。 */
    fun sameAs(other: WorkSkipEntry): Boolean =
        introStartMs == other.introStartMs &&
            introEndMs == other.introEndMs &&
            outroOffsetMs == other.outroOffsetMs &&
            manualUpdatedAtSec == other.manualUpdatedAtSec &&
            learnedIntroEndMs == other.learnedIntroEndMs &&
            learnedOutroOffsetMs == other.learnedOutroOffsetMs &&
            learnedSamples == other.learnedSamples &&
            learnedUpdatedAtSec == other.learnedUpdatedAtSec

    /**
     * 序列化成紧凑 JSON（`null` 字段与 `0` 时间戳都省掉）。
     *
     * ⛔ 键名（`is`/`ie`/`oo`/`mu`/`le`/`lo`/`ls`/`lu`）与 PC 端**逐字一致** ——
     *    两端读的是同一个文件，错一个键就是「那一半同步不过去」。
     */
    fun toJson(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>(8)
        introStartMs?.let { out["is"] = it }
        introEndMs?.let { out["ie"] = it }
        outroOffsetMs?.let { out["oo"] = it }
        if (manualUpdatedAtSec > 0L) out["mu"] = manualUpdatedAtSec
        learnedIntroEndMs?.let { out["le"] = it }
        learnedOutroOffsetMs?.let { out["lo"] = it }
        if (learnedSamples > 0) out["ls"] = learnedSamples
        if (learnedUpdatedAtSec > 0L) out["lu"] = learnedUpdatedAtSec
        return out
    }

    override fun toString(): String =
        "WorkSkipEntry(手标 $introStartMs→$introEndMs / 距末尾 $outroOffsetMs @$manualUpdatedAtSec, " +
            "学习 →$learnedIntroEndMs / 距末尾 $learnedOutroOffsetMs " +
            "($learnedSamples 样本) @$learnedUpdatedAtSec)"

    companion object {

        /**
         * 从 JSON 反序列化。
         *
         * ⛔ **两组都空的条目一律丢掉**：它不带任何信息，留着只会在合并与上传
         *    时让「两边其实都没东西」也判定为有差异。
         *
         * ⚠️ 与 [ProgressEntry.fromJson] 不同，这里**不要求时间戳非零**：
         *    手标组可能来自 `LibraryDb.skipMarkerSnapshot` 的播种，而
         *    `media_works` 上**没有手标时刻这一列**（只有学习那条路有
         *    `learned_at`）。丢掉它们等于「老用户升级前标好的片头永远同步
         *    不出去」，而那正是播种要解决的问题。
         */
        fun fromJson(raw: Any?): WorkSkipEntry? {
            val map = raw as? Map<*, *> ?: return null
            val entry = WorkSkipEntry(
                introStartMs = asLong(map["is"]),
                introEndMs = asLong(map["ie"]),
                outroOffsetMs = asLong(map["oo"]),
                manualUpdatedAtSec = asLong(map["mu"]) ?: 0L,
                learnedIntroEndMs = asLong(map["le"]),
                learnedOutroOffsetMs = asLong(map["lo"]),
                learnedSamples = asLong(map["ls"])?.coerceAtLeast(0L)?.toInt() ?: 0,
                learnedUpdatedAtSec = asLong(map["lu"]) ?: 0L,
            )
            return if (entry.isEmpty) null else entry
        }

        /** JSON 数字 → `Long?`。与 `ProgressEntry.asLong` 同一套（接受 `1000.0`）。 */
        private fun asLong(v: Any?): Long? = when (v) {
            is Long -> v
            is Int -> v.toLong()
            is Short -> v.toLong()
            is Byte -> v.toLong()
            is Double -> if (v.isFinite()) v.toLong() else null
            is Float -> if (v.isFinite()) v.toLong() else null
            else -> null
        }
    }
}

/**
 * 全量进度：`itemId -> ProgressEntry`。
 *
 * `itemId` 的口径与 `media_items.id` **逐字一致**（`provider:fileId`，见
 * `ScanItem.idOf`），这是它能与媒体库对上的唯一依据。
 *
 * ## ⛔ 为什么键用 `provider:fileId` 而不是路径或文件名
 *
 * 跨端同步要求「两台设备对同一个文件算出同一个键」。文件名会被改、目录会被
 * 移动，而 `fileId` 是网盘侧给文件分配的稳定 id —— 只要文件还在网盘上，两边
 * 算出来就是同一个字符串。
 *
 * 代价是**删掉再重新上传同一个文件**会换一个 `fileId`，那条进度就找不回来
 * （它变成一条永不匹配的孤儿）。这个代价是接受的：另一种做法（按路径）在改
 * 目录名时丢得更频繁，而重新上传本来就是「换了一个文件」。
 */
class ProgressBook(
    /** 全部条目。**直接持有这个 Map**（不做防御性拷贝）—— 它只在同步路径上流转。 */
    val items: MutableMap<String, ProgressEntry> = LinkedHashMap(),

    /**
     * 作品级的片头 / 片尾记录：`media_works.key -> WorkSkipEntry`（v2 新增）。
     *
     * 键的口径与 `media_works.key` **逐字一致**（`provider:groupId`），
     * 与 [items] 的 `provider:fileId` 不是一回事 —— 别互相塞。
     */
    val works: MutableMap<String, WorkSkipEntry> = LinkedHashMap(),
) {

    val length: Int get() = items.size

    /** 作品级记录数。 */
    val workCount: Int get() = works.size

    val isEmpty: Boolean get() = items.isEmpty() && works.isEmpty()

    val isNotEmpty: Boolean get() = items.isNotEmpty() || works.isNotEmpty()

    /** 取一条；没有返回 `null`。 */
    operator fun get(itemId: String): ProgressEntry? = items[itemId]

    /** 写入 / 覆盖一条。 */
    operator fun set(itemId: String, entry: ProgressEntry) {
        items[itemId] = entry
    }

    /** 取一部作品的片头 / 片尾记录；没有返回 `null`。 */
    fun skipFor(workKey: String): WorkSkipEntry? = works[workKey]

    /**
     * 写入 / 覆盖一部作品的片头 / 片尾记录。
     *
     * ⛔ 内容是空（两组都空）时**直接删掉这一条**，而不是留一个空壳：
     *    空壳会一直参与合并与上传，让「两边其实都没东西」也判定为有差异。
     */
    fun putSkip(workKey: String, entry: WorkSkipEntry) {
        if (entry.isEmpty) works.remove(workKey) else works[workKey] = entry
    }

    /**
     * 把 [other] 合进**自己**，返回**被改变（或新增）的条目数**。
     *
     * 返回 0 意味着两边已经一致 —— 调用方据此决定「不用上传」。这个判据很重要：
     * 没有它的话，每 30 分钟一次的空同步都会在网盘上走一遍「先删后传」，而那是
     * **有失败风险**的（见 `LibraryBackupService.uploadBackup` 的文档）。
     *
     * ⛔ 两段（[items] / [works]）都算进返回值：只算前者的话，一次「只改了
     *    片头标记」的同步会判定为「无需上传」，用户看到的是标记同步不过去。
     */
    fun mergeFrom(other: ProgressBook): Int {
        var changed = 0
        for ((key, value) in other.items) {
            val mine = items[key]
            if (mine == null) {
                items[key] = value
                changed++
                continue
            }
            val merged = mine.mergedWith(value)
            if (!merged.sameAs(mine)) {
                items[key] = merged
                changed++
            }
        }
        for ((key, value) in other.works) {
            val mine = works[key]
            if (mine == null) {
                works[key] = value
                changed++
                continue
            }
            val merged = mine.mergedWith(value)
            if (!merged.sameAs(mine)) {
                works[key] = merged
                changed++
            }
        }
        return changed
    }

    /** 序列化为 JSON 文本。 */
    fun toJsonString(): String = MiniJson.write(toJson())

    /** 序列化为 UTF-8 字节（上传网盘用）。 */
    fun toBytes(): ByteArray = toJsonString().toByteArray(Charsets.UTF_8)

    fun toJson(): Map<String, Any?> {
        val body = LinkedHashMap<String, Any?>(items.size)
        for ((k, v) in items) body[k] = v.toJson()
        val out = LinkedHashMap<String, Any?>(3)
        out["v"] = FORMAT_VERSION
        out["items"] = body
        // ⛔ `works` 为空时**整个键省掉**：绝大多数用户的绝大多数时候这一段
        //    是空的，而这一项每 30 分钟就要序列化 + 上传一次。
        //    读回来时缺键 = 空（见 [fromJsonString]），两端都认。
        if (works.isNotEmpty()) {
            val worksBody = LinkedHashMap<String, Any?>(works.size)
            for ((k, v) in works) worksBody[k] = v.toJson()
            out["works"] = worksBody
        }
        return out
    }

    override fun toString(): String = "ProgressBook(${items.size} 条 + ${works.size} 部作品)"

    companion object {

        /**
         * 进度文件的**格式版本**，写在 JSON 顶层的 `v`。
         *
         * ⚠️ 与媒体库的 `LibrarySchema.VERSION`（17）**不是一回事**，别混：
         *   * 那个是「SQLite 表结构」的版本，改它要两端同改 DDL；
         *   * 这个是「这个 JSON 长什么样」的版本，两端只在**字段增删**时才动它。
         *
         * 读取端目前**不校验**这个值（字段是向后兼容的：认不出来的键直接忽略，
         * 缺的键按 `null` 处理），留着是为了将来真要做破坏性变更时有个抓手。
         *
         * 版本沿革：
         *   * **v1** —— 只有 `items`（逐条播放进度）。
         *   * **v2** —— 多了 `works`（作品级片头 / 片尾，见 [WorkSkipEntry]）。
         */
        const val FORMAT_VERSION = 2

        /**
         * 从 JSON 文本解析。
         *
         * ⛔ **绝不抛**。文件可能被截断（写入一半断电 —— 电视上很常见）、可能是
         *    别的程序放在同名位置的垃圾、也可能是未来版本写的、字段更多。任何
         *    一种都只该导致「这一次同步什么都没读到」，而不是让应用启动失败。
         *
         * 单条不合法只丢那一条（见 [ProgressEntry.fromJson]），整个文件不合法
         * 才退回空书。
         */
        fun fromJsonString(text: String): ProgressBook {
            val root = runCatching { MiniJson.parse(text) }.getOrNull() ?: return ProgressBook()
            val map = root as? Map<*, *> ?: return ProgressBook()
            val out = ProgressBook()
            val raw = map["items"] as? Map<*, *>
            if (raw != null) {
                for ((k, v) in raw) {
                    val key = k as? String ?: continue
                    if (key.isEmpty()) continue
                    val entry = ProgressEntry.fromJson(v) ?: continue
                    out.items[key] = entry
                }
            }
            // ⛔ `works` 缺失 ⇒ 空映射，**不是**空书 —— v1 的文件里没有这一
            //    段，那是合法的老文件，它的 items 必须照读。
            val rawWorks = map["works"] as? Map<*, *>
            if (rawWorks != null) {
                for ((k, v) in rawWorks) {
                    val key = k as? String ?: continue
                    if (key.isEmpty()) continue
                    val entry = WorkSkipEntry.fromJson(v) ?: continue
                    out.works[key] = entry
                }
            }
            return out
        }

        /** 从字节解析（下载来的文件）。 */
        fun fromBytes(bytes: ByteArray): ProgressBook {
            val text = runCatching { String(bytes, Charsets.UTF_8) }.getOrNull()
                ?: return ProgressBook()
            return fromJsonString(text)
        }
    }
}

/**
 * **回填**（真源 → 库列投影）时那三条夹取规则 —— 纯函数，可单测。
 *
 * 抽出来是因为 [LibraryDb.applyProgressSnapshot] 跑在真的 SQLite 上（JVM 单测
 * 覆盖不到），而这三条规则一旦写错，表现全是**静默**的：
 *
 *   * 少夹 `max` ⇒ 「回填」变成「把进度往回拉」，用户看到进度条倒退；
 *   * 少夹 `played` ⇒ 「最近播放」的排序被一次回填扰动；
 *   * 不判「有没有变化」⇒ 每次启动都无条件 UPDATE 几千行。
 */
object ProgressProjection {

    /** 回填后的三列取值。 */
    data class Applied(
        val resumeMs: Long?,
        val maxMs: Long?,
        val playedAtSec: Long?,
    )

    /**
     * 把真源里的 [want] 夹到库列现有值（`have*`）上。
     *
     * 返回 `null` = **三条都一致，不用写**（调用方据此跳过 UPDATE）。
     *
     * ## 三条规则
     *
     *   1. `resume` 直接覆盖（它本来就可清可改，不是单调量）；
     *   2. `max` **只增不减**（与 `saveMaxPosition` 的那条 SQL 同一语义）；
     *   3. `played` **只前进**（「最近播放」不该倒退）。
     *
     * ⛔ `null` 与 `<= 0` 在写侧一律归 `null`（见 `saveResumePosition` 的口径），
     *    所以 `want.resumeMs = 0` 会被当成「清掉续播点」而不是「续播到 0 毫秒」。
     */
    fun next(
        haveResumeMs: Long?,
        haveMaxMs: Long?,
        havePlayedAtSec: Long?,
        want: ProgressEntry,
    ): Applied? {
        val wantResume = want.resumeMs?.takeIf { it > 0L }
        val wantMax = want.maxMs?.takeIf { it > 0L }

        val nextMax = if (haveMaxMs != null && (wantMax == null || haveMaxMs >= wantMax)) {
            haveMaxMs
        } else {
            wantMax
        }

        val wantPlayed = want.playedAtSec
        val nextPlayed = if (havePlayedAtSec != null &&
            (wantPlayed == null || havePlayedAtSec >= wantPlayed)
        ) {
            havePlayedAtSec
        } else {
            wantPlayed
        }

        if (haveResumeMs == wantResume &&
            haveMaxMs == nextMax &&
            havePlayedAtSec == nextPlayed
        ) {
            return null
        }
        return Applied(resumeMs = wantResume, maxMs = nextMax, playedAtSec = nextPlayed)
    }
}
