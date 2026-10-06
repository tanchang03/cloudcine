package com.cloudcine.tv.pan

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
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
class PanResponse(
    val status: Int,
    val body: String,
    val setCookies: List<String> = emptyList(),
) {
    val json: JSONObject? by lazy {
        try {
            JSONObject(body)
        } catch (_: Exception) {
            null
        }
    }

    /** 网盘信封的业务码。`code=0` 才是成功。 */
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
 * 一次**原始** HTTP 响应 —— 给 OSS 分片上传用。
 *
 * ⛔ 与 [PanResponse] 分开是有原因的，不是重复：[PanResponse] 面向
 * 「网盘的信封 JSON」（`code` / `message` / `data`），而 OSS 的响应
 * **既不是 JSON、也不带信封** —— 分片 PUT 成功时 body 是空的，
 * 唯一的产出是响应头里的 **`ETag`**，而 `ETag` 是后面
 * `CompleteMultipartUpload` XML 的必要输入。拿不到它整次上传就白做。
 *
 * ⛔ 响应头**只留几个真正要用的**，键统一转小写。不整份拷贝
 * `HttpURLConnection.headerFields` 是因为那张表里可能有 `null` 键
 * （第一行是状态行），在 Kotlin 里迭代解构会直接 NPE。
 */
class RawResponse(
    val status: Int,
    val body: String,
    /** 只含 [CAPTURED_HEADERS] 里那几个，键**已转小写**。 */
    val headers: Map<String, String> = emptyMap(),
) {
    /** 取响应头，大小写不敏感。 */
    fun header(name: String): String? = headers[name.lowercase()]

    val isOk: Boolean get() = status in 200..299

    /** 失败时拿来拼错误信息 —— body 可能很长（OSS 会回一大段 XML）。 */
    fun brief(max: Int = 300): String = body.take(max)

    companion object {
        val CAPTURED_HEADERS = listOf("ETag", "Content-Type", "Content-Length")
    }
}

/**
 * 一次**二进制** GET 的结果：字节 + 响应里全部的 `Set-Cookie` 行。
 *
 * ⛔ 与 [PanResponse] 分开：那条路的 `body` 是 UTF-8 解出来的 `String`，
 *    对图片是**破坏性的**（WebP 里的任意字节序列过一遍字符解码再编回去，
 *    长度和内容都不再一样）。图片只能走字节。
 * ⛔ 与 [RawResponse] 也分开：那个只留 `ETag` / `Content-Type` / `Content-Length`
 *    三个头，而这里真正要的是 `Set-Cookie`（见 [PanHttp.getBytesWithCookies]）。
 */
class BytesResponse(
    val bytes: ByteArray,
    /** 原始 `Set-Cookie` 行，**未解析**（解析在 `PanApi.absorbSetCookies`）。 */
    val setCookies: List<String> = emptyList(),
)

/**
 * 极简 HTTP 客户端。**所有请求都绕开系统代理** —— 网盘的接口与直链都必须
 * 走真实网络，被代理劫持的表现是「一直转圈」或「412」，很难往代理上想。
 *
 * 线程模型：全部是阻塞调用，**调用方负责放到后台线程**（本工程统一用
 * [PanApi.executor]）。这一点与云影相反 —— 那边所有网络都在 Dart 主
 * isolate 上，那正是要对照的东西。
 */
object PanHttp {

    private const val TAG = "CloudCine"

    /** 与 `quark_endpoints.dart` 的 `userAgent` 同款（PoC 实测可用）。 */
    const val UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    const val REFERER = "https://pan.quark.cn/"
    const val ORIGIN = "https://pan.quark.cn"
    const val ACCEPT = "application/json, text/plain, */*"
    const val ACCEPT_LANGUAGE = "zh-CN,zh;q=0.9"

    /** 网盘那套 JSON 接口的 Content-Type。OSS 那边用的是 `application/xml`。 */
    const val JSON_CONTENT_TYPE = "application/json;charset=UTF-8"

    /**
     * 发一次请求。
     *
     * ⛔ `useCaches = false` 不能省：`HttpURLConnection` 默认会复用连接池
     * 并可能命中缓存，而 `play/info` 每次返回的地址都不同（带签名），
     * 命中缓存会拿到过期地址 —— 表现是「列目录正常、一播就 403」。
     */
    /**
     * 建立连接。`call` 与 [callRaw] 共用这一段 —— 少一处「改了 UA 忘了改另一边」
     * 的机会。
     */
    private fun open(
        url: String,
        method: String,
        query: Map<String, String>,
        hasBody: Boolean,
        contentType: String?,
        headers: Map<String, String>,
        timeoutMs: Int,
    ): HttpURLConnection {
        val full = if (query.isEmpty()) url else "$url?${encodeQuery(query)}"
        return (URL(full).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            useCaches = false
            instanceFollowRedirects = true
            setRequestProperty("Accept", ACCEPT)
            setRequestProperty("Accept-Language", ACCEPT_LANGUAGE)
            setRequestProperty("User-Agent", UA)
            setRequestProperty("Referer", REFERER)
            if (hasBody && contentType != null) {
                setRequestProperty("Content-Type", contentType)
            }
            // ⛔ 调用方给的 header 放在**最后**，这样它能覆盖上面的默认值
            //    （分片 PUT 要自己指定 `Content-Type: application/octet-stream`）。
            for ((k, v) in headers) {
                if (v.isNotEmpty()) setRequestProperty(k, v)
            }
        }
    }

    private fun call(
        url: String,
        method: String,
        query: Map<String, String> = emptyMap(),
        body: String? = null,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Int = 20_000,
    ): PanResponse {
        val conn = open(
            url = url,
            method = method,
            query = query,
            hasBody = body != null,
            contentType = if (body != null) JSON_CONTENT_TYPE else null,
            headers = headers,
            timeoutMs = timeoutMs,
        )

        try {
            if (body != null) {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val status = conn.responseCode
            val stream: InputStream? =
                if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.use { readAll(it) }.orEmpty()
            val setCookies = conn.headerFields["Set-Cookie"].orEmpty()
            return PanResponse(
                status = status,
                body = text,
                setCookies = setCookies,
            )
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 发一次请求，**把响应头一起带回来**（分片上传要读 `ETag`）。
     *
     * ⛔ 响应头必须在 `disconnect()` **之前**读 —— 断开之后再
     *    `getHeaderField` 拿不到值（连接已经归还连接池）。
     */
    private fun callRaw(
        url: String,
        method: String,
        query: Map<String, String> = emptyMap(),
        body: ByteArray? = null,
        contentType: String? = null,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Int = 20_000,
    ): RawResponse {
        val conn = open(
            url = url,
            method = method,
            query = query,
            hasBody = body != null,
            contentType = contentType,
            headers = headers,
            timeoutMs = timeoutMs,
        )
        try {
            if (body != null) {
                // ⛔ 必须 `use {}`（关流才真正发出请求）。分片是 4 MiB，
                //    不关流的话 `responseCode` 会一直等下去。
                conn.outputStream.use { it.write(body) }
            }
            val status = conn.responseCode
            val stream: InputStream? =
                if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.use { readAll(it) }.orEmpty()

            val heads = LinkedHashMap<String, String>()
            for (name in RawResponse.CAPTURED_HEADERS) {
                // 用 `getHeaderField(name)` 而不是遍历 `headerFields`：
                // 前者大小写不敏感且不会碰到状态行那个 null 键。
                conn.getHeaderField(name)?.let { heads[name.lowercase()] = it }
            }
            return RawResponse(status = status, body = text, headers = heads)
        } finally {
            conn.disconnect()
        }
    }

    fun get(
        url: String,
        query: Map<String, String> = emptyMap(),
        cookie: String = "",
        headers: Map<String, String> = emptyMap(),
    ): PanResponse = call(url, "GET", query = query, headers = withCookie(cookie, headers))

    fun postJson(
        url: String,
        query: Map<String, String> = emptyMap(),
        body: JSONObject,
        cookie: String = "",
        headers: Map<String, String> = emptyMap(),
    ): PanResponse =
        call(url, "POST", query = query, body = body.toString(), headers = withCookie(cookie, headers))

    /**
     * `PUT` 一段原始字节（OSS 分片上传）。
     *
     * ⛔ **不带 Cookie** —— 这是往阿里云 OSS 发，不是往夸克发。鉴权全靠
     *    `Authorization` 头（夸克用 `file/upload/auth` 现签的 `auth_key`）。
     *    带上夸克的 Cookie 反而会被 OSS 当成无关头。
     */
    fun putBytes(
        url: String,
        body: ByteArray,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Int = 180_000,
    ): RawResponse = callRaw(url, "PUT", body = body, headers = headers, timeoutMs = timeoutMs)

    /**
     * `POST` 一段原始字节（OSS `CompleteMultipartUpload` 要发 XML）。
     *
     * ⛔ `Content-Type` 走 [headers]，**不**用 [JSON_CONTENT_TYPE] ——
     *    OSS 对合并请求要求 `application/xml`，而且那个值会参与签名计算
     *    （见 `OssAuth.completeAuthMeta` 的第三行），写错就是 403。
     */
    fun postBytes(
        url: String,
        body: ByteArray,
        headers: Map<String, String> = emptyMap(),
        timeoutMs: Int = 180_000,
    ): RawResponse = callRaw(url, "POST", body = body, headers = headers, timeoutMs = timeoutMs)

    /**
     * 把一个 URL 的**全部字节**读回来（外挂字幕走这条）。
     *
     * ⛔ 不能用 [get]：那条路把响应体按 **UTF-8** 解成 `String`
     *    （`out.toString("UTF-8")`）。而中文 `.srt` 大量是 **GBK/GB18030**，
     *    按 UTF-8 解出来全是 `锟斤拷`，而且**不报错** —— 表现为「字幕加载成功、
     *    上屏全是乱码」。字节必须先原样拿回来，再由 `ExternalSubtitle`
     *    统一做编码判定。
     *
     * ⛔ [maxBytes] 是**防呆**不是限制：字幕文件通常几十 KiB。真的返回了几
     *    MB，说明拿到的不是字幕（比如地址被换成了视频直链），此时宁可报错，
     *    也不要把它读进堆里 —— 这台电视只有 512 MB Java 堆。
     */
    fun getBytes(
        url: String,
        cookie: String = "",
        headers: Map<String, String> = emptyMap(),
        maxBytes: Int = 8 * 1024 * 1024,
        timeoutMs: Int = 20_000,
    ): ByteArray = getBytesWithCookies(url, cookie, headers, maxBytes, timeoutMs).bytes

    /**
     * 同 [getBytes]，但**额外把响应里的 `Set-Cookie` 带回来**。
     *
     * ## ⛔ 为什么不能只用 [getBytes]
     *
     * 夸克在**每个**响应的 `Set-Cookie` 里轮换 `__puus`，而 `__puus` 是
     * 「直链 / 缩略图能不能过防重放校验」的唯一凭据（见 `PanApi.headersForCdn`
     * 那张四种组合的实测表：**带一半的 Cookie 最坏** —— 列表能刷、一播就 412）。
     *
     * 原来 `getBytes` 只回字节、把响应头整份丢掉。对**外挂字幕**没影响
     * （它用的是 `file/audioplay` 现签的临时地址，不依赖 `__puus`），
     * 但**网盘缩略图**依赖 —— 而且缩略图是一张一张按需拉的，几十次请求
     * 足够让服务端轮换好几轮。丢掉的那些新 `__puus` 会让**下一次取链**
     * 用一个过期值，表现是「翻了一圈选集，再点播放就 412」。
     *
     * 所以这里把 `Set-Cookie` 原样交回给调用方（`PanApi.thumbBytes` 会
     * 用 `absorbSetCookies` 收下）。
     */
    fun getBytesWithCookies(
        url: String,
        cookie: String = "",
        headers: Map<String, String> = emptyMap(),
        maxBytes: Int = 8 * 1024 * 1024,
        timeoutMs: Int = 20_000,
    ): BytesResponse {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            // 同 [call]：直链带签名，命中缓存会拿到过期地址。
            useCaches = false
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", UA)
            setRequestProperty("Referer", REFERER)
            if (cookie.isNotEmpty()) setRequestProperty("Cookie", cookie)
            for ((k, v) in headers) {
                if (v.isNotEmpty()) setRequestProperty(k, v)
            }
        }
        try {
            val status = conn.responseCode
            if (status !in 200..299) {
                throw IOException("HTTP $status ${conn.responseMessage.orEmpty()}".trim())
            }
            // ⛔ 读**字节**之前先把 Set-Cookie 抄下来：`headerFields` 在
            //    `disconnect()` 之后就是空的，而下面那个 `finally` 一定会调它。
            val setCookies = collectSetCookies(conn)
            val out = ByteArrayOutputStream()
            conn.inputStream.use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > maxBytes) {
                        throw IOException("响应超过 ${maxBytes / 1048576} MiB，不像是图片/字幕")
                    }
                }
            }
            return BytesResponse(out.toByteArray(), setCookies)
        } finally {
            conn.disconnect()
        }
    }

    /**
     * 抄下响应里全部 `Set-Cookie` 行。
     *
     * ⛔ 不能用 `conn.getHeaderField("Set-Cookie")` —— 它**只回第一条**，
     *    而夸克一次响应里能同时下 `__puus` 与 `Video-Auth`，漏掉哪一条都会
     *    让后续请求莫名其妙地失败。必须走 `headerFields` 拿全部。
     * ⛔ 键要判空：`headerFields` 的迭代里第一项是状态行，键是 `null`，
     *    在 Kotlin 里解构会直接 NPE。
     */
    private fun collectSetCookies(conn: HttpURLConnection): List<String> {
        val out = ArrayList<String>(2)
        for ((key, values) in conn.headerFields) {
            if (key == null || !key.equals("Set-Cookie", ignoreCase = true)) continue
            if (values == null) continue
            for (v in values) if (v.isNotEmpty()) out.add(v)
        }
        return out
    }

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
