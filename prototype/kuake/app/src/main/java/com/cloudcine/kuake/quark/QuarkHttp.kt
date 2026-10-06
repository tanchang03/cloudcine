package com.cloudcine.kuake.quark

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * 一次 HTTP 响应。
 *
 * ⛔ **不引 OkHttp**。理由与不引 `media3-ui` 相同：本工程要能离线构建，
 * 而 `HttpURLConnection` 对「发几个 GET/POST、读 JSON、带 Cookie」完全够用。
 * 少一个依赖就少一处「换机器就编不过」。
 */
class QuarkResponse(
    val status: Int,
    val body: String,
    val setCookies: List<String> = emptyList(),
    val contentType: String? = null,
    val contentLength: Long = -1L,
) {
    val json: JSONObject? by lazy {
        try {
            JSONObject(body)
        } catch (_: Exception) {
            null
        }
    }

    /** 夸克信封的业务码。`code=0` 才是成功。 */
    val code: Int get() = json?.optInt("code", NO_CODE) ?: NO_CODE

    /**
     * 业务码，**兼容两套信封**。
     *
     * ⛔ 网盘端点（`drive-pc`）用 `code`，而 CAS 认证端点（`uop.quark.cn`）
     * 用 **`status`** —— 响应形如 `{"status":50004001,"message":"Query result is empty"}`。
     * 只读 `code` 会一律得到 `-1`，于是「还没扫码」这个**正常态**
     * 会被当成「未预期的业务码」，二维码永远停在初始状态、也不会被刷新。
     */
    val bizCode: Int
        get() {
            val j = json ?: return NO_CODE
            return if (j.has("status")) j.optInt("status", NO_CODE) else j.optInt("code", NO_CODE)
        }

    val message: String get() = json?.optString("message").orEmpty()

    val data: JSONObject? get() = json?.optJSONObject("data")

    val dataArray: JSONArray? get() = json?.optJSONArray("data")

    /** `data` 里的 `list` 数组（列目录 / 搜索的形态）。 */
    val dataList: JSONArray? get() = data?.optJSONArray("list")

    val isOk: Boolean get() = status in 200..299 && code == 0

    /** 从 `Set-Cookie` 里取某个键的值（`Video-Auth` 走这条路）。 */
    fun cookieValue(name: String): String? {
        for (line in setCookies) {
            val semi = line.indexOf(';')
            val pair = if (semi < 0) line else line.substring(0, semi)
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            if (pair.substring(0, eq).trim() == name) return pair.substring(eq + 1).trim()
        }
        return null
    }

    companion object {
        const val NO_CODE = -1
    }
}

/**
 * 极简 HTTP 客户端。**所有请求都绕开系统代理** —— 夸克的接口与直链都必须
 * 走真实网络，被代理劫持的表现是「一直转圈」或「412」，很难往代理上想。
 *
 * 线程模型：全部是阻塞调用，**调用方负责放到后台线程**（本工程统一用
 * [QuarkApi.executor]）。这一点与云影相反 —— 那边所有网络都在 Dart 主
 * isolate 上，那正是要对照的东西。
 */
object QuarkHttp {

    private const val TAG = "KuakeProto"

    /** 与 `quark_endpoints.dart` 的 `userAgent` 同款（PoC 实测可用）。 */
    const val UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    const val REFERER = "https://pan.quark.cn/"
    const val ORIGIN = "https://pan.quark.cn"
    const val ACCEPT = "application/json, text/plain, */*"
    const val ACCEPT_LANGUAGE = "zh-CN,zh;q=0.9"

    /**
     * 发一次请求。
     *
     * ⛔ `useCaches = false` 不能省：`HttpURLConnection` 默认会复用连接池
     * 并可能命中缓存，而夸克的 `play/info` 每次返回的地址都不同（带签名），
     * 命中缓存会拿到过期地址 —— 表现是「列目录正常、一播就 403」。
     */
    private fun call(
        url: String,
        method: String,
        query: Map<String, String> = emptyMap(),
        body: String? = null,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Int = 20_000,
    ): QuarkResponse {
        val full = if (query.isEmpty()) url else "$url?${encodeQuery(query)}"
        val conn = (URL(full).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            useCaches = false
            instanceFollowRedirects = true
            setRequestProperty("Accept", ACCEPT)
            setRequestProperty("Accept-Language", ACCEPT_LANGUAGE)
            setRequestProperty("User-Agent", UA)
            setRequestProperty("Referer", REFERER)
            for ((k, v) in headers) {
                if (v.isNotEmpty()) setRequestProperty(k, v)
            }
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json;charset=UTF-8")
            }
        }

        try {
            if (body != null) {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = conn.responseCode
            val stream: InputStream? =
                if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.use { readAll(it) }.orEmpty()
            val setCookies = conn.headerFields["Set-Cookie"].orEmpty()
            return QuarkResponse(
                status = status,
                body = text,
                setCookies = setCookies,
                contentType = conn.contentType,
                contentLength = conn.contentLengthLong,
            )
        } finally {
            conn.disconnect()
        }
    }

    fun get(
        url: String,
        query: Map<String, String> = emptyMap(),
        cookie: String = "",
        headers: Map<String, String> = emptyMap(),
    ): QuarkResponse = call(url, "GET", query = query, headers = withCookie(cookie, headers))

    fun postJson(
        url: String,
        query: Map<String, String> = emptyMap(),
        body: JSONObject,
        cookie: String = "",
        headers: Map<String, String> = emptyMap(),
    ): QuarkResponse =
        call(url, "POST", query = query, body = body.toString(), headers = withCookie(cookie, headers))

    /** 只读响应体前若干字节 —— 用来量「单连接真实带宽」。 */
    fun probeThroughput(
        url: String,
        cookie: String,
        headers: Map<String, String> = emptyMap(),
        maxBytes: Long = 24L * 1024 * 1024,
        maxMillis: Long = 8_000,
    ): Throughput {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 15_000
            useCaches = false
            setRequestProperty("User-Agent", UA)
            setRequestProperty("Referer", REFERER)
            setRequestProperty("Range", "bytes=0-${maxBytes - 1}")
            if (cookie.isNotEmpty()) setRequestProperty("Cookie", cookie)
            for ((k, v) in headers) if (v.isNotEmpty()) setRequestProperty(k, v)
        }
        var got = 0L
        val t0 = System.currentTimeMillis()
        try {
            conn.inputStream.use { input ->
                val buf = ByteArray(256 * 1024)
                while (got < maxBytes) {
                    val n = input.read(buf)
                    if (n < 0) break
                    got += n
                    if (System.currentTimeMillis() - t0 > maxMillis) break
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "带宽探测中断：${e.message}")
        } finally {
            conn.disconnect()
        }
        val dt = (System.currentTimeMillis() - t0).coerceAtLeast(1)
        return Throughput(bytes = got, millis = dt, status = runCatching { conn.responseCode }.getOrDefault(-1))
    }

    /** 一次带宽探测的读数。 */
    data class Throughput(val bytes: Long, val millis: Long, val status: Int) {
        val mibPerSec: Double get() = (bytes / 1048576.0) / (millis / 1000.0)
        override fun toString(): String =
            "%.2f MiB / %.2fs = %.2f MiB/s".format(bytes / 1048576.0, millis / 1000.0, mibPerSec)
    }

    private fun withCookie(cookie: String, extra: Map<String, String>): Map<String, String> {
        if (cookie.isEmpty()) return extra
        val out = LinkedHashMap(extra)
        out["Cookie"] = cookie
        return out
    }

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
