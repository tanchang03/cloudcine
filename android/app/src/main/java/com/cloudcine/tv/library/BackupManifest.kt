package com.cloudcine.tv.library

import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone

/**
 * 备份清单（`manifest.json`）。
 *
 * ⛔ 这是 Android 与 PC 端之间**最容易写错、也最不该「改进」**的一块。
 * 字段名、时间格式、以及 [effectiveModifiedAt] 的退化规则，都是照
 * `lib/domain/services/library_backup.dart` 逐条对齐的 —— 因为同步方向
 * 完全由它决定：写错一个字段的后果不是报错，而是**新机器一同步就把网盘上
 * 的好备份覆盖成空库**，而且两边都显示「同步成功」。
 *
 * ## 跨机同步的判据
 *
 * 基于 [effectiveModifiedAt] 做 Last-Write-Wins：
 * 远程比本地新 → 拉下来覆盖本地；本地比远程新 → 推上去覆盖远程。
 *
 * ## ⚠️ 为什么「谁新」不能用 [createdAt]
 *
 * [createdAt] 是**这份备份文件生成的时间**，也就是「现在」。拿它比大小，
 * 本机在任何时刻都必然比远程新 —— 于是同步永远只会上传，
 * 而**新机器一同步就会把网盘上的好备份覆盖成空库**。
 *
 * 真正的判据是 [libraryModifiedAt]：**这台机器的媒体库最后一次内容变更
 * 的时间**。空库没有这个时间（[hasLibraryContent] 为 false），
 * 同步逻辑会**显式**走「让远程赢」那条分支 —— 见 [SyncDecision.decide]。
 */
data class BackupManifest(
    /** 创建备份的设备唯一标识。 */
    val deviceId: String,
    /** 创建备份的设备名称（用户可读，如「小米电视」）。 */
    val deviceName: String,
    /** 备份**文件**的创建时间（epoch 毫秒，UTC）。只用于展示「这份备份是什么时候做的」。 */
    val createdAt: Long,
    /** 本地媒体库**最后一次内容变更**的时间（epoch 毫秒，UTC）。同步的 LWW 判据。空库为 `null`。 */
    val libraryModifiedAt: Long?,
    /** 数据库 schema 版本号（与 [LibrarySchema.VERSION] 对齐）。 */
    val schemaVersion: Int,
    /** 备份包内包含的文件名列表（`cloudcine.sqlite` / `posters/`）。 */
    val fileNames: List<String>,
    /** 用户备注（可选）。 */
    val note: String? = null,
) {

    /**
     * 同步比较用的时间。
     *
     * ⛔ 退化目标是 [createdAt]，**不是 0**。这一点与直觉相反（也与我自己的
     * 第一版实现相反），但它就是 PC 端的口径：`libraryModifiedAt ?? createdAt`。
     * 只对**老版本备份**（那时还没有这个字段）生效 —— 那种备份没有更好的
     * 信息可用，用它至少能让「明显更晚做的备份」赢。
     *
     * ⛔ 不要「顺手改成 0 更安全」：那会让所有老备份都恒定「比本地旧」，
     * 于是本地永远上传、老备份永远不被采纳。
     */
    val effectiveModifiedAt: Long get() = libraryModifiedAt ?: createdAt

    /**
     * 这份备份是否记录了**库内容**（即导出时库里确实有东西）。
     *
     * 同步两侧都要看这个标志：
     *   - 本地没有内容 → 让远程赢（新机器的正路）；
     *   - 远程没有内容 → **绝不拿它覆盖本地**，否则会用一个空库
     *     把本地攒好的媒体库清掉。
     */
    val hasLibraryContent: Boolean get() = libraryModifiedAt != null

    /** 两份清单是否来自同一台设备。 */
    fun sameDevice(other: BackupManifest): Boolean = deviceId == other.deviceId

    /** 这份清单是否比 [other] 新（比的是 [effectiveModifiedAt]）。 */
    fun isNewerThan(other: BackupManifest): Boolean =
        effectiveModifiedAt > other.effectiveModifiedAt

    /**
     * 是否构成「同时修改冲突」：**不同设备**且库内容变更时间差在 60 秒内。
     *
     * ⛔ 同一台设备**永远不算冲突**：那就是自己先后备份两次，机器名一样、
     * 时间接近是常态。漏了 `sameDevice` 这一句，用户每次「刚备份完又同步」
     * 都会看到冲突提示。
     */
    fun conflictsWith(other: BackupManifest): Boolean {
        if (sameDevice(other)) return false
        val diff = Math.abs(effectiveModifiedAt - other.effectiveModifiedAt)
        return diff < 60_000L
    }

    // ------------------------------------------------------------------
    // 序列化
    // ------------------------------------------------------------------

    fun toJson(): Map<String, Any?> {
        val m = LinkedHashMap<String, Any?>()
        m["deviceId"] = deviceId
        m["deviceName"] = deviceName
        m["createdAt"] = IsoTime.format(createdAt)
        // ⛔ 空库时**不写这个键**（与 Dart 的 `if (libraryModifiedAt != null)` 一致）。
        // 写成 null 的话 Dart 那边读出来仍是 null、行为一样，但会让
        // 「这份备份有没有库内容」在人工看 JSON 时需要推理，没必要。
        if (libraryModifiedAt != null) m["libraryModifiedAt"] = IsoTime.format(libraryModifiedAt)
        m["schemaVersion"] = schemaVersion
        m["fileNames"] = fileNames
        if (note != null) m["note"] = note
        return m
    }

    fun toBytes(): ByteArray = MiniJson.write(toJson()).toByteArray(Charsets.UTF_8)

    companion object {
        /** 备份包内数据库的文件名。 */
        const val DB_ENTRY = "cloudcine.sqlite"

        /** 备份包内海报目录的标记名（出现在 `fileNames` 里）。 */
        const val POSTERS_ENTRY = "posters/"

        /**
         * 从 JSON 反序列化。
         *
         * 口径照 Dart 的 `BackupManifest.fromJson`：**每个字段都退默认值**，
         * 不抛。理由与那边一致 —— 这是一份用户可能手工改过、也可能是旧版本
         * 生成的本地文件，为一个畸形值把整次恢复拦下来不值得。
         */
        fun fromJson(json: Map<String, Any?>): BackupManifest = BackupManifest(
            deviceId = json.str("deviceId") ?: "unknown",
            deviceName = json.str("deviceName") ?: "未知设备",
            createdAt = IsoTime.parse(json.str("createdAt")) ?: 0L,
            libraryModifiedAt = IsoTime.parse(json.str("libraryModifiedAt")),
            schemaVersion = json.int("schemaVersion") ?: 1,
            fileNames = json.list("fileNames"),
            note = json.str("note"),
        )

        fun fromBytes(bytes: ByteArray): BackupManifest =
            fromJson(MiniJson.parseObject(String(bytes, Charsets.UTF_8)))

        private fun Map<String, Any?>.str(key: String): String? =
            (this[key] as? String)?.takeIf { it.isNotEmpty() }

        private fun Map<String, Any?>.int(key: String): Int? = when (val v = this[key]) {
            is Int -> v
            is Long -> v.toInt()
            is Double -> v.toInt()
            is String -> v.toIntOrNull()
            else -> null
        }

        private fun Map<String, Any?>.list(key: String): List<String> =
            (this[key] as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
    }
}

/**
 * ISO-8601 时间字符串（UTC）的读写。
 *
 * ## 为什么不用 `SimpleDateFormat` / `java.time`
 *
 *   * `java.time` 要 **API 26**，而本工程 `minSdk = 21` —— 用了会被
 *     `NewApi` lint 拦下（这个工程**没有**关掉那条 lint，2026-10-06 就是靠
 *     它抓到 `PanHttp` 里一个 API 24 的方法）。
 *   * `SimpleDateFormat` 对「小数位数不定」的输入（Dart 的 `toIso8601String()`
 *     在微秒非零时输出 **6 位**小数）没法用一个 pattern 吃下。
 *
 * 所以这里手写：格式固定，解析容忍。
 *
 * ⛔ 输出的格式必须能被 Dart 的 `DateTime.tryParse` 读懂 ——
 * 即 `2026-10-06T11:16:13.123Z`。少一个 `Z` 的话，Dart 会把它当成**本地时间**，
 * 于是「谁新」的比较会偏掉整整一个时区。
 */
object IsoTime {

    private const val PATTERN = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"

    fun format(epochMillis: Long): String {
        val fmt = java.text.SimpleDateFormat(PATTERN, Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(java.util.Date(epochMillis))
    }

    /**
     * 解析。读不懂返回 `null`（不抛）。
     *
     * 接受的形态：
     *   * `2026-10-06T11:16:13Z`
     *   * `2026-10-06T11:16:13.1Z` / `.123` / `.123456` / `.123456789`
     *   * `2026-10-06T11:16:13+08:00` / `+0800`
     *   * 不带时区后缀 → 按 **UTC** 处理
     *
     * ⚠️ 最后一条与 Dart 不同（Dart 会把无后缀的当本地时间）。这里选 UTC 是因为
     * **我们的 manifest 永远带 `Z`**（两端都先 `toUtc()`），无后缀只会出现在
     * 手工编辑过的文件里，而那种情况下「当 UTC」比「当电视所在时区」更可预测。
     */
    fun parse(raw: String?): Long? {
        if (raw.isNullOrBlank()) return null
        val s = raw.trim()

        // 1. 切出时区后缀
        var offsetMinutes = 0
        var body = s
        when {
            body.endsWith("Z") || body.endsWith("z") -> body = body.dropLast(1)
            else -> {
                // 从末尾往前找 + / -。⚠️ 不能写成 `indexOfLast { ... }` 再在
                // lambda 里用 `body.indexOf(it)` 定位 —— 那个 lambda 只拿到字符、
                // 拿不到下标，`indexOf` 会给回**第一次**出现的位置（也就是日期里
                // 的 `-`），于是时区后缀永远找不到。
                // 日期里的 `-` 都在前 10 个字符内，所以只从第 10 位往后找。
                var idx = -1
                for (i in body.indices.reversed()) {
                    val c = body[i]
                    if ((c == '+' || c == '-') && i > 9) {
                        idx = i
                        break
                    }
                }
                if (idx > 9) {
                    val tz = body.substring(idx)
                    body = body.substring(0, idx)
                    val sign = if (tz[0] == '-') -1 else 1
                    val digits = tz.drop(1).replace(":", "")
                    if (digits.length < 2) return null
                    val hh = digits.substring(0, 2).toIntOrNull() ?: return null
                    val mm = if (digits.length >= 4) digits.substring(2, 4).toIntOrNull() ?: 0 else 0
                    offsetMinutes = sign * (hh * 60 + mm)
                }
            }
        }

        // 2. 切出小数秒
        var fractionMs = 0
        val dot = body.indexOf('.')
        if (dot >= 0) {
            val frac = body.substring(dot + 1)
            body = body.substring(0, dot)
            if (frac.any { !it.isDigit() }) return null
            // 取前 3 位当毫秒（多余的位数截断，不足的补 0）
            val head = frac.take(3).padEnd(3, '0')
            fractionMs = head.toIntOrNull() ?: return null
        }

        // 3. 日期与时间
        val parts = body.split('T', 't')
        if (parts.size != 2) return null
        val d = parts[0].split('-')
        val t = parts[1].split(':')
        if (d.size != 3 || t.size < 2) return null
        val year = d[0].toIntOrNull() ?: return null
        val month = d[1].toIntOrNull() ?: return null
        val day = d[2].toIntOrNull() ?: return null
        val hour = t[0].toIntOrNull() ?: return null
        val minute = t[1].toIntOrNull() ?: return null
        val second = if (t.size >= 3) t[2].toIntOrNull() ?: 0 else 0
        if (month !in 1..12 || day !in 1..31 || hour !in 0..23 || minute !in 0..59) return null

        val cal = GregorianCalendar(TimeZone.getTimeZone("UTC")).apply {
            clear()
            set(year, month - 1, day, hour, minute, second)
            set(Calendar.MILLISECOND, fractionMs)
        }
        return cal.timeInMillis - offsetMinutes * 60_000L
    }
}
