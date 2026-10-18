package com.cloudcine.tv.pan.baidu

import com.cloudcine.tv.library.MiniJson
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * 一次百度 HTTP 响应。
 *
 * ⛔ 与夸克那套 [com.cloudcine.tv.pan.PanResponse] **故意不共用**：百度的
 * 信封是**顶层 `errno`**（不是 `code`），且登录链要靠 `Location` 与
 * `Set-Cookie` 办事。硬套夸克那个会把「顶层 errno」读成 `code=-1`，
 * 于是每次响应都像失败。
 */
class BaiduResponse(
    val status: Int,
    /** 响应体。**空串 = 没有内容**（3xx 的跳转响应常常没有 body）。 */
    val body: String = "",
    val setCookies: List<String> = emptyList(),
    /** 3xx 的 `Location`（换票那一跳要靠它）。跟不跟重定向由调用方定。 */
    val location: String? = null,
) {
    /** 解析出的 JSON 对象；解析不了为 `null`（调用方按「没有可用内容」处理）。 */
    val json: Map<String, Any?>? by lazy {
        val parsed = parseJsonpObject(body) ?: return@lazy null
        @Suppress("UNCHECKED_CAST")
        parsed as? Map<String, Any?>
    }

    /**
     * 顶层 `errno`。没有该字段时返回 [BaiduErrorCode.OK]（轮询的正常态是 `errno:1`）。
     *
     * ⛔ 缺失时**不能**当成失败：百度的长轮询在没有事件时只回一个空对象。
     */
    val errno: Int get() = (json?.get("errno") as? Number)?.toInt() ?: OK_FALLBACK

    /** 服务端原话（`show_msg` / `errmsg`）。`-6` 一码多义，日志里必须留它。 */
    val showMsg: String get() =
        (json?.get("show_msg") as? String)?.takeIf { it.isNotEmpty() }
            ?: (json?.get("errmsg") as? String).orEmpty()

    val isSuccess: Boolean get() = status in 200..299 && errno == BaiduErrorCode.OK

    /** 从 `Set-Cookie` 里取某个键的值。 */
    fun cookieValue(name: String): String? = parseSetCookies(setCookies)[name]

    companion object {
        /** `errno` 字段缺失时的回落值。 */
        const val OK_FALLBACK = 0
    }
}

/** 解析 `Set-Cookie` 行 → 键值对（只取第一段 `k=v`，丢掉 `Path`/`HttpOnly` 等）。 */
fun parseSetCookies(lines: List<String>): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    for (line in lines) {
        val semi = line.indexOf(';')
        val pair = if (semi < 0) line else line.substring(0, semi)
        val eq = pair.indexOf('=')
        if (eq <= 0) continue
        val k = pair.substring(0, eq).trim()
        val v = pair.substring(eq + 1).trim()
        // ⛔ 删 Cookie（`BDUSS=; Max-Age=0`）的值是空的 —— 收下它会覆盖掉
        //    好值，而它本身不携带任何会话信息。
        if (k.isNotEmpty() && v.isNotEmpty()) out[k] = v
    }
    return out
}

/**
 * 解析 jsonp 响应：`cb({...})` / 裸 JSON 都认。
 *
 * passport 域的端点（`unicast`）一律包一层 `cb(...)`；网盘域是裸 JSON。
 * 读不懂返回 `null` —— 调用方按「内容不可用」处理，不抛。
 */
fun parseJsonpObject(body: String): Map<String, Any?>? {
    val trimmed = body.trim()
    if (trimmed.isEmpty()) return null
    parseJsonObjectOrNull(trimmed)?.let { return it }
    val open = trimmed.indexOf('(')
    val close = trimmed.lastIndexOf(')')
    if (open < 0 || close <= open) return null
    val inner = trimmed.substring(open + 1, close).trim()
    if (inner.isEmpty()) return null
    return parseJsonObjectOrNull(inner)
}

private fun parseJsonObjectOrNull(text: String): Map<String, Any?>? = try {
    val v = MiniJson.parse(text)
    @Suppress("UNCHECKED_CAST")
    v as? Map<String, Any?>
} catch (_: Exception) {
    null
}

/**
 * 极简 HTTP 客户端（百度专用）。
 *
 * ⛔ **不引 OkHttp**（与 `PanHttp` 同一条规矩：离线构建 + 几个 GET/POST
 * 就够用）。⛔ 所有请求**绕开系统代理**：`useCaches=false`、
 * 直链带签名，命中缓存会拿到过期地址。
 * ⛔ 阻塞调用，**调用方负责放后台线程**（本工程统一用 `Bg`）。
 *
 * 与夸克 `PanHttp` 的关键差异：
 *  1. **默认头不带**（夸克那套 UA/Referer 是夸克域的，带给百度会被风控
 *     多看一眼）—— 一律由调用方显式给；
 *  2. 支持 `followRedirects=false`（换票要自己读 `Set-Cookie` + `Location`）；
 *  3. 超时可调（长轮询要 45s，默认 20s 会让它每次都「超时」）。
 */
object BaiduHttp {

    /** 从响应里读**原始 `Set-Cookie` 行**（全部，不是第一条）。 */
    internal fun collectSetCookies(conn: HttpURLConnection): List<String> {
        val out = ArrayList<String>(4)
        for ((key, values) in conn.headerFields) {
            // ⛔ 键要判空：`headerFields` 第一项是状态行，键是 null。
            if (key == null || !key.equals("Set-Cookie", ignoreCase = true)) continue
            if (values == null) continue
            for (v in values) if (v.isNotEmpty()) out.add(v)
        }
        return out
    }

    private fun open(
        url: String,
        method: String,
        query: Map<String, String>,
        headers: Map<String, String>,
        timeoutMs: Int,
        followRedirects: Boolean,
    ): HttpURLConnection {
        val full = if (query.isEmpty()) url else "$url?${encodeQuery(query)}"
        return (URL(full).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            useCaches = false
            instanceFollowRedirects = followRedirects
            // ⛔ 调用方给的 header 一律自己带全（UA / Cookie / Origin / Referer）。
            for ((k, v) in headers) {
                if (v.isNotEmpty()) setRequestProperty(k, v)
            }
        }
    }

    /**
     * 发一次 GET。
     *
     * @param followRedirects false 时把 3xx 原样交回（`location` 字段），
     *   由调用方逐跳走 —— 自动跟随会丢掉中途每一跳的 `Set-Cookie`。
     */
    fun get(
        url: String,
        query: Map<String, String> = emptyMap(),
        headers: Map<String, String> = emptyMap(),
        followRedirects: Boolean = true,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
    ): BaiduResponse {
        val conn = open(url, "GET", query, headers, timeoutMs, followRedirects)
        try {
            val status = conn.responseCode
            val stream: InputStream? =
                if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.use { readAll(it) }.orEmpty()
            // ⛔ `Set-Cookie` 必须在 `disconnect()` 之前读。
            val setCookies = collectSetCookies(conn)
            val location = runCatching { conn.getHeaderField("Location") }.getOrNull()
            return BaiduResponse(
                status = status,
                body = text,
                setCookies = setCookies,
                location = location?.takeIf { status in 300..399 },
            )
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 发一次 POST。
     *
     * ⛔ 参数走 **query**（URL），不带 body —— 与 PC 端 dio 的
     * `post(url, queryParameters: query)` 逐字一致。风控分支
     * （`/v3/login/main/qrbdusslogin`）是这个形状。
     */
    fun post(
        url: String,
        query: Map<String, String> = emptyMap(),
        headers: Map<String, String> = emptyMap(),
        followRedirects: Boolean = false,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
    ): BaiduResponse {
        val conn = open(url, "POST", query, headers, timeoutMs, followRedirects)
        try {
            val status = conn.responseCode
            val stream: InputStream? =
                if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.use { readAll(it) }.orEmpty()
            val setCookies = collectSetCookies(conn)
            val location = runCatching { conn.getHeaderField("Location") }.getOrNull()
            return BaiduResponse(
                status = status,
                body = text,
                setCookies = setCookies,
                location = location?.takeIf { status in 300..399 },
            )
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 读一个 URL 的**全部字节**（二维码图片、缩略图、字幕小文件）。
     *
     * ⛔ 读**字节**不是字符串：二维码是 PNG，字幕可能是 GBK。
     */
    fun getBytes(
        url: String,
        headers: Map<String, String> = emptyMap(),
        maxBytes: Int = 8 * 1024 * 1024,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
    ): ByteArray {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            useCaches = false
            instanceFollowRedirects = true
            for ((k, v) in headers) {
                if (v.isNotEmpty()) setRequestProperty(k, v)
            }
        }
        try {
            val status = conn.responseCode
            if (status !in 200..299) {
                throw IOException("HTTP $status ${conn.responseMessage.orEmpty()}".trim())
            }
            val out = ByteArrayOutputStream()
            conn.inputStream.use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > maxBytes) {
                        throw IOException("响应超过 ${maxBytes / 1048576} MiB，不像图片/字幕")
                    }
                }
            }
            return out.toByteArray()
        } finally {
            conn.disconnect()
        }
    }

    const val DEFAULT_TIMEOUT_MS = 20_000

    private fun encodeQuery(query: Map<String, String>): String =
        query.entries.joinToString("&") { (k, v) -> "${enc(k)}=${enc(v)}" }

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

    private fun readAll(input: InputStream): String {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toString("UTF-8")
    }
}
