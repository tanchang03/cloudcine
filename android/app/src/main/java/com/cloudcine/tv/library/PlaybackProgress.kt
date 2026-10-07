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
) {

    val length: Int get() = items.size

    val isEmpty: Boolean get() = items.isEmpty()

    val isNotEmpty: Boolean get() = items.isNotEmpty()

    /** 取一条；没有返回 `null`。 */
    operator fun get(itemId: String): ProgressEntry? = items[itemId]

    /** 写入 / 覆盖一条。 */
    operator fun set(itemId: String, entry: ProgressEntry) {
        items[itemId] = entry
    }

    /**
     * 把 [other] 合进**自己**，返回**被改变（或新增）的条目数**。
     *
     * 返回 0 意味着两边已经一致 —— 调用方据此决定「不用上传」。这个判据很重要：
     * 没有它的话，每 30 分钟一次的空同步都会在网盘上走一遍「先删后传」，而那是
     * **有失败风险**的（见 `LibraryBackupService.uploadBackup` 的文档）。
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
        return changed
    }

    /** 序列化为 JSON 文本。 */
    fun toJsonString(): String = MiniJson.write(toJson())

    /** 序列化为 UTF-8 字节（上传网盘用）。 */
    fun toBytes(): ByteArray = toJsonString().toByteArray(Charsets.UTF_8)

    fun toJson(): Map<String, Any?> {
        val body = LinkedHashMap<String, Any?>(items.size)
        for ((k, v) in items) body[k] = v.toJson()
        return linkedMapOf("v" to FORMAT_VERSION, "items" to body)
    }

    override fun toString(): String = "ProgressBook(${items.size} 条)"

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
         */
        const val FORMAT_VERSION = 1

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
            val raw = map["items"] as? Map<*, *> ?: return out
            for ((k, v) in raw) {
                val key = k as? String ?: continue
                if (key.isEmpty()) continue
                val entry = ProgressEntry.fromJson(v) ?: continue
                out.items[key] = entry
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
