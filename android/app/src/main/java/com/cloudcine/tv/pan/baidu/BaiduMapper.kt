package com.cloudcine.tv.pan.baidu

import com.cloudcine.tv.pan.DriveEntry

/**
 * 百度响应 JSON ↔ 工程模型的映射（纯函数，无 IO，可单测）。
 *
 * ⛔ **不直接用 `org.json`**：本文件是跨端契约的「解释层」，必须能被纯 JVM
 * 单测覆盖（`android.jar` 空壳下 `org.json` 方法体被抹掉）。解析统一走
 * [com.cloudcine.tv.library.MiniJson]（`Map` / `List` / `Long` / `Double` /
 * `String` / `Boolean` / `null`）。
 *
 * 与 PC 端 `baidu_models.dart` 的 `BaiduMapper` 逐条对应 —— 两边的判据
 * （认哪些字段、四种位置都找、保守兜底）必须一致，否则同一个响应在 PC 与
 * 电视上会解析出不同的东西。
 */
object BaiduMapper {

    // ------------------------------------------------------------------
    // 列表项
    // ------------------------------------------------------------------

    /**
     * 从响应里捞出列表项，**四种位置都认**。
     *
     * 顺序是「顶层优先」：百度的实际形状是顶层（`list` / `info`），
     * 顶层没有才去 `data` 里找（防御未来改版）。
     */
    fun listItemsOf(json: Map<String, Any?>?): List<Map<String, Any?>> {
        if (json == null) return emptyList()
        for (key in listOf("list", "info")) {
            @Suppress("UNCHECKED_CAST")
            val items = (json[key] as? List<*>)?.filterIsInstance<Map<String, Any?>>()
            if (!items.isNullOrEmpty()) return items
        }
        val data = json["data"]
        if (data is Map<*, *>) {
            @Suppress("UNCHECKED_CAST")
            val list = (data["list"] as? List<*>)?.filterIsInstance<Map<String, Any?>>()
            if (!list.isNullOrEmpty()) return list
        }
        if (data is List<*>) {
            @Suppress("UNCHECKED_CAST")
            return data.filterIsInstance<Map<String, Any?>>()
        }
        return emptyList()
    }

    /** 从 `gettemplatevariable` / `get/template` 的响应里捞 `bdstoken`（两层都找）。 */
    fun bdstokenOf(json: Map<String, Any?>?): String? {
        if (json == null) return null
        (json["bdstoken"] as? String)?.takeIf { it.isNotEmpty() }?.let { return it }
        @Suppress("UNCHECKED_CAST")
        val result = json["result"] as? Map<String, Any?>
        return (result?.get("bdstoken") as? String)?.takeIf { it.isNotEmpty() }
    }

    /**
     * 解析 `isdir` 判定是否为目录。
     *
     * ⚠️ **`isdir` 的语义与夸克的 `file_type` 相反**：百度 `1` = 目录。
     * 照着夸克抄会把整个目录树反过来。
     * 保守兜底：判成文件（最多漏扫一层），不判成目录（BFS 队列会爆炸）。
     */
    fun parseIsDirectory(json: Map<String, Any?>): Boolean = when (val v = json["isdir"]) {
        is Boolean -> v
        is Number -> v.toInt() != 0
        is String -> when (val lower = v.trim().lowercase()) {
            "true" -> true
            "false" -> false
            else -> lower.toIntOrNull()?.let { it != 0 } ?: false
        }
        else -> false
    }

    /**
     * 单个列表项 → [DriveEntry]。缺关键字段时返回 `null`（跳过脏数据）。
     *
     * ⚠️ `parentId` 恒为 `null`：百度列表项不带父 ID，只有完整 `path`。
     * 扫描器的 `dir_id` 取自**遍历栈**（父目录 id），不靠这个字段。
     */
    fun toEntry(json: Map<String, Any?>): DriveEntry? {
        val id = fsIdOf(json) ?: return null
        val name = asString(json["server_filename"])
            ?: asString(json["filename"])
            ?: asString(json["name"])
        if (name.isNullOrEmpty()) return null

        val isDir = parseIsDirectory(json)
        @Suppress("UNCHECKED_CAST")
        val thumbs = json["thumbs"] as? Map<String, Any?>
        return DriveEntry(
            fid = id,
            name = name,
            isDir = isDir,
            sizeBytes = if (isDir) 0L else asLong(json["size"]) ?: 0L,
            updatedAtMs = parseTimestampMs(json["server_mtime"] ?: json["local_mtime"]),
            // 百度列表项不带父 ID（只有完整 path），见方法文档。
            parentId = null,
            // 百度直接给完整路径（`/电影/xxx.mkv`）。缩略图三档：url1 最小、
            // url3 最大。⛔ 字段缺失时绝不自己拼 URL。
            previewUrl = if (isDir) null else thumbUrl(thumbs, listOf("url3", "url2", "url1")),
            videoWidth = if (isDir) null else positiveInt(json["width"]),
            videoHeight = if (isDir) null else positiveInt(json["height"]),
            durationMs = if (isDir) null else parseDurationMs(json["duration"]),
        )
    }

    /** 批量映射，自动跳过脏数据。 */
    fun toEntries(items: List<Map<String, Any?>>): List<DriveEntry> =
        items.mapNotNull { toEntry(it) }

    /**
     * 从**原始 JSON 列表项**里抽 `fs_id → path`（列表项自带 `path`）。
     *
     * 适配器用它维护路径缓存：百度的列目录 / 取直链都要**路径**，而调用方
     * 手里只有 `fs_id`。列表项自带 `path`，所以每列一次目录就白捡一批。
     */
    fun pathIndexOfJson(items: List<Map<String, Any?>>): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (item in items) {
            val id = fsIdOf(item) ?: continue
            val path = asString(item["path"])?.takeIf { it.isNotEmpty() } ?: continue
            out[id] = path
        }
        return out
    }

    /** 取 `fs_id` 并转成稳定的字符串（数字走整数分支，避开科学计数法）。 */
    fun fsIdOf(json: Map<String, Any?>): String? {
        for (key in listOf("fs_id", "fsid", "id")) {
            when (val v = json[key]) {
                is String -> if (v.isNotEmpty()) return v
                is Number -> {
                    val d = v.toDouble()
                    return if (d == Math.floor(d) && !d.isInfinite()) {
                        d.toLong().toString()
                    } else {
                        d.toString()
                    }
                }
            }
        }
        return null
    }

    /** `thumbs` 字典按优先级取第一个非空地址。 */
    private fun thumbUrl(
        thumbs: Map<String, Any?>?,
        keys: List<String>,
    ): String? {
        if (thumbs == null) return null
        for (k in keys) {
            (thumbs[k] as? String)?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        // 字典里任何非空的都行（字段名可能变）。
        for (v in thumbs.values) {
            (v as? String)?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    // ------------------------------------------------------------------
    // 账号信息
    // ------------------------------------------------------------------

    /** 会员档位解析。认不出来时返回 [BaiduVipType.NORMAL]（不抛错）。 */
    fun parseVipType(json: Map<String, Any?>?): Int {
        val data = nested(json, "data") ?: json ?: return BaiduVipType.NORMAL
        for (key in listOf("vip_type", "vipType", "member_type")) {
            val n = asInt(data[key])
            if (n != null) {
                return when {
                    n >= BaiduVipType.SVIP -> BaiduVipType.SVIP
                    n == BaiduVipType.VIP -> BaiduVipType.VIP
                    else -> BaiduVipType.NORMAL
                }
            }
        }
        // 字符串形态：`svip` / `vip2` / `vip` 之类。
        for (key in listOf("product_name", "detail_cluster", "cluster")) {
            val s = asString(data[key])?.lowercase() ?: continue
            if (s.contains("svip") || s.contains("super")) return BaiduVipType.SVIP
            if (s.contains("vip")) return BaiduVipType.VIP
        }
        return BaiduVipType.NORMAL
    }

    /** 昵称（`data` 层与顶层都找）。 */
    fun nicknameOf(json: Map<String, Any?>?): String? {
        val data = nested(json, "data") ?: json ?: return null
        for (key in listOf("netdisk_name", "baidu_name", "username", "nickname")) {
            asString(data[key])?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        return null
    }

    // ------------------------------------------------------------------
    // 取直链
    // ------------------------------------------------------------------

    /**
     * 从取链响应里解析出 `dlink`（三种位置 + 五个候选字段都认）。
     *
     * 返回 `null` 表示响应里没有可用直链（调用方据此换下一条路由）。
     */
    fun parseDlink(json: Map<String, Any?>?): String? {
        for (item in listItemsOf(json)) {
            dlinkOf(item)?.let { return it }
        }
        // 有些路由把地址直接放顶层。
        json?.let { dlinkOf(it) }?.let { return it }
        return null
    }

    /** 从单个对象里取 `dlink`（也认 `url` / `download_url` / `link`）。 */
    fun dlinkOf(item: Map<String, Any?>): String? {
        for (key in listOf("dlink", "download_url", "downloadUrl", "url", "link")) {
            val v = asString(item[key])?.takeIf { it.isNotEmpty() } ?: continue
            // ⛔ 协议相对地址（`//d.pcs.…`）必须补 scheme —— 直接当绝对地址
            //    用会让播放器拿到一个没有 scheme 的 URI。
            if (v.startsWith("//")) {
                val fixed = "https:$v"
                if (fixed.length > "https:".length) return fixed
                continue
            }
            if (v.contains("://")) return v
        }
        return null
    }

    /**
     * 直链请求头的**实测形状**。
     *
     * - `User-Agent: netdisk`：CDN 第二跳的 `sign` 是按 UA 签的，换 UA 必 403；
     * - `Cookie`：无 `origin` 的普通通道直链靠 Cookie 认领用户（只在第一跳需要，
     *   但带上无害）；`origin=dlna` 的直链自带 `vuk`，带不带都行。
     *
     * ⛔ 这是**按路由分的方言**，没有官方文档。改这里之前先看 PC 端
     * `BaiduAdapter._dlinkHeaders` 的三轮实测记录。
     */
    fun dlinkHeaders(cookieHeader: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        out["User-Agent"] = BaiduEndpoints.NETDISK_DLINK_UA
        out["Accept"] = "*/*"
        if (cookieHeader.isNotEmpty()) out["Cookie"] = cookieHeader
        return out
    }

    /** 从取链响应里解析出**服务端认定的文件类型**（`category`）。 */
    fun categoryOf(json: Map<String, Any?>?): Int? {
        for (item in listItemsOf(json)) {
            asInt(item["category"])?.let { return it }
        }
        return null
    }

    /** 从取链响应里捞体积（`size`）。 */
    fun contentLengthOf(json: Map<String, Any?>?): Long? {
        for (item in listItemsOf(json)) {
            val n = asLong(item["size"])
            if (n != null && n > 0) return n
        }
        return null
    }

    /**
     * 从取链 / 列表响应里捞**时长（毫秒）**；`null` = 服务端没给。
     *
     * ⛔ 它不只是「显示用」：`Quality.requiredMbPerSec`（体积 ÷ 时长）是
     *    「这一档要不要自动降级」的**唯一判据**。缺了它，原画那档会被算成
     *    「不需要带宽」，自动选档就会一直挑原画，然后在 4K remux 上卡死。
     */
    fun durationMsOf(json: Map<String, Any?>?): Long? {
        for (item in listItemsOf(json)) {
            parseDurationMs(item["duration"])?.let { return it }
        }
        return parseDurationMs(json?.get("duration"))
    }

    /** 从取链响应里解析出 `fs_id → path`（`filemetas` 响应里带 `path`）。 */
    fun parsePathIndex(json: Map<String, Any?>?): Map<String, String> =
        pathIndexOfJson(listItemsOf(json))

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    fun asString(v: Any?): String? = when (v) {
        is String -> v
        null -> null
        else -> v.toString()
    }

    fun asInt(v: Any?): Int? = when (v) {
        is Number -> v.toInt()
        is String -> v.trim().toIntOrNull()
        else -> null
    }

    fun asLong(v: Any?): Long? = when (v) {
        is Number -> v.toLong()
        is String -> v.trim().toLongOrNull()
        else -> null
    }

    private fun positiveInt(v: Any?): Int? = asInt(v)?.takeIf { it > 0 }

    /** 时间戳 → 毫秒（`<= 99999999999` 视为秒）。 */
    fun parseTimestampMs(v: Any?): Long {
        val n = asLong(v) ?: return 0L
        return if (n in 1..99_999_999_999L) n * 1000 else n
    }

    /** 时长 → 毫秒（秒级输入乘 1000；毫秒级原样）。 */
    fun parseDurationMs(v: Any?): Long? {
        val n = asLong(v)?.takeIf { it > 0 } ?: return null
        return if (n > 999_999L) n else n * 1000
    }

    /** 宽容布尔解析（服务端可能给 `true` / `1` / `"1"`）。 */
    fun asBool(v: Any?): Boolean? = when (v) {
        is Boolean -> v
        is Number -> v.toInt() != 0
        is String -> when (val s = v.trim().lowercase()) {
            "true", "1" -> true
            "false", "0" -> false
            else -> null
        }
        else -> null
    }

    @Suppress("UNCHECKED_CAST")
    fun nested(json: Map<String, Any?>?, key: String): Map<String, Any?>? =
        (json?.get(key) as? Map<String, Any?>)
}
