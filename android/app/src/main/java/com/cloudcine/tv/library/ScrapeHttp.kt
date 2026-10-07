package com.cloudcine.tv.library

import java.net.HttpURLConnection
import java.net.URL

/** 一次刮削 HTTP 响应。 */
data class ScrapeResponse(
    val code: Int,
    val body: String,
) {
    /** 状态码在 2xx。⛔ **它不等于「业务成功」** —— 豆瓣的额度耗尽可能带 200。 */
    val ok: Boolean get() = code in 200..299
}

/**
 * 刮削用的 HTTP 客户端契约。
 *
 * ⛔ 抽成接口**只为可测性**：单测里塞一个按 URL 返回固定 JSON 的假实现，
 *    就能把「搜索 → 解析 → 候选」整条链路跑起来而不碰网络。
 *    （纯解析函数另有单测，见 `DoubanScraperTest` / `TmdbScraperTest`。）
 */
interface ScrapeHttpLike {
    fun get(url: String, headers: Map<String, String>, timeoutMs: Int): ScrapeResponse

    /**
     * 下载**二进制**（海报）。
     *
     * ⛔ 不能复用 [get]：那个把响应体读成 `String`，而图片是二进制 ——
     *    按 UTF-8 解码再编码回去必然损坏字节。失败返回 `null`，不抛。
     */
    fun getBytes(url: String, headers: Map<String, String>, timeoutMs: Int): ByteArray?
}

/**
 * 真实的 HTTP GET。
 *
 * ⛔ **不引 OkHttp**（工程约定，与 `PanHttp` 同一条）。用 `HttpURLConnection`。
 *
 * ⛔ 与 `PanHttp` **刻意不合并**：那个类带着夸克特有的规矩（Cookie 轮换、
 *    `pr=ucpro&fr=pc`、`useCaches` 为什么不能省…）。刮削站一条都用不上，
 *    混在一起会让「改网盘逻辑顺手改坏刮削」变成可能 —— 而刮削坏掉的表现是
 *    「刮不到」，与网络不通长得一样，最难查。
 */
object ScrapeHttp : ScrapeHttpLike {

    override fun get(url: String, headers: Map<String, String>, timeoutMs: Int): ScrapeResponse {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            // ⛔ 必须关缓存：响应会变，而 `HttpURLConnection` 会走进程里的
            //    `HttpResponseCache`（若装了）。与 PanHttp 同一条规矩。
            conn.useCaches = false
            conn.instanceFollowRedirects = true
            for ((k, v) in headers) conn.setRequestProperty(k, v)

            val code = conn.responseCode
            // ⛔ **错误流也要读**：豆瓣的 `103 need_login` 既可能带 200 也可能带
            //    403，而熔断信号在 body 里 —— 只看状态码会把 403 那次漏掉，
            //    于是「额度耗尽」被读成「网络抖了一下」，然后继续烧额度。
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            return ScrapeResponse(code, body)
        } finally {
            conn.disconnect()
        }
    }

    override fun getBytes(url: String, headers: Map<String, String>, timeoutMs: Int): ByteArray? {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.useCaches = false
            conn.instanceFollowRedirects = true
            for ((k, v) in headers) conn.setRequestProperty(k, v)
            if (conn.responseCode !in 200..299) return null
            // 不用 `contentLength` 预分配：豆瓣/TMDB 都可能用 chunked 传输，
            // 那时它是 -1，预分配会抛。`readBytes` 自己按需扩容。
            return conn.inputStream.use { it.readBytes() }
        } finally {
            conn.disconnect()
        }
    }
}
