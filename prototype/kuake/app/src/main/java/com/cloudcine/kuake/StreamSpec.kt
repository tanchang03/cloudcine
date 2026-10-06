package com.cloudcine.kuake

import android.content.Intent

/**
 * 一条要播的流。
 *
 * ## 为什么超时是可配的（而且默认值刻意保持 Media3 的 8 秒）
 *
 * 云影真机上 ExoPlayer 三次都报 `ExoPlaybackException: Source error`，而当时本地中继
 * 用的是 **8 MiB 块**，首块要 15~16 秒才下发（日志 `logs/cloudcine-log-android-*.txt`）。
 * Media3 `DefaultHttpDataSource` 的默认连接 / 读取超时都是 **8000ms** —— 时间上完全对得上。
 *
 * 所以这里的默认值**就是 8000/8000**：第一轮先复现失败，第二轮再用
 * `--ei connectMs 30000 --ei readMs 30000` 验证「是不是超时」。
 * 把默认值直接调大就测不出这个结论了。
 */
data class StreamSpec(
    val url: String,
    val headers: Map<String, String>,
    val connectTimeoutMs: Int = DEFAULT_TIMEOUT_MS,
    val readTimeoutMs: Int = DEFAULT_TIMEOUT_MS,
) {
    companion object {
        /** Media3 `DefaultHttpDataSource` 的默认值，故意沿用。 */
        const val DEFAULT_TIMEOUT_MS = 8000

        const val EXTRA_URL = "url"
        const val EXTRA_HEADERS = "headers"
        const val EXTRA_CONNECT_MS = "connectMs"
        const val EXTRA_READ_MS = "readMs"

        /**
         * 从 intent 取流。`url` 为空时返回 null —— 调用方据此决定「去输入页」。
         *
         * 支持两种传法，因为测试路径有两条：
         *   * `--es url "http://127.0.0.1:44151/s2"`：云影**开着中继**时最省事的一条，
         *     不需要任何请求头（中继自己带）；
         *   * `--es url <夸克直链> --es headers "Cookie: __pus=…\nUser-Agent: …"`：
         *     绕过中继直连，用来对照「中继是不是瓶颈」。
         */
        fun fromIntent(intent: Intent?): StreamSpec? {
            // ⛔ 必须**先**判空再取字段：写成 `intent?.getStringExtra(...)` 之后，
            //    编译器只能推断出「url 非空」，推不出「intent 非空」（空 intent 也会
            //    得到 url=""），后面 `intent.getStringExtra` 就编不过。
            if (intent == null) return null
            val url = intent.getStringExtra(EXTRA_URL)?.trim().orEmpty()
            if (url.isEmpty()) return null

            val raw = intent.getStringExtra(EXTRA_HEADERS).orEmpty()
            val connect = intent.getIntExtra(EXTRA_CONNECT_MS, DEFAULT_TIMEOUT_MS)
            val read = intent.getIntExtra(EXTRA_READ_MS, DEFAULT_TIMEOUT_MS)
            return StreamSpec(
                url = url,
                headers = parseHeaders(raw),
                connectTimeoutMs = connect,
                readTimeoutMs = read,
            )
        }

        /**
         * 解析「每行一条 `Key: Value`」的请求头。
         *
         * 按**第一个冒号**切，不按 `split(":")`：`Cookie` 的值里本身带冒号
         * （`__puus=…;` 之后可能还有），按全部冒号切会把值切断，而且**不报错**，
         * 只表现为「服务端 403」。
         */
        fun parseHeaders(raw: String): Map<String, String> {
            if (raw.isBlank()) return emptyMap()
            val out = LinkedHashMap<String, String>()
            for (line in raw.split('\n', '\r')) {
                val t = line.trim()
                if (t.isEmpty()) continue
                val i = t.indexOf(':')
                if (i <= 0) continue
                val key = t.substring(0, i).trim()
                val value = t.substring(i + 1).trim()
                if (key.isNotEmpty() && value.isNotEmpty()) out[key] = value
            }
            return out
        }
    }
}
