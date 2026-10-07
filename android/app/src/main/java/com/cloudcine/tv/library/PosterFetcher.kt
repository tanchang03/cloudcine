package com.cloudcine.tv.library

import android.util.Log
import java.io.File

/**
 * 刮削海报的**下载**。
 *
 * ## 为什么 Android 端现在才需要它
 *
 * [PosterStore] 的类文档写着「**不做下载**：海报是随备份包一起搬过来的」——
 * 那条约定在「刮削只发生在 PC 端」时是成立的。现在电视上也能刮削了，刮完必须
 * 自己把海报拉下来，否则用户看到的是「已刮削：某某」而墙上还是一块灰。
 *
 * ## 命名与 PC 端逐字一致
 *
 * 用 [PosterNaming.fileNameFor]（`{归一化键}_{URL散列}.jpg`）。这不是审美问题：
 * 备份包把整个海报目录原样搬来搬去，两端算法差一个字符，对方就一张都认不出来
 * —— 而「认不出来」的表现是「海报全没了」，不报任何错。
 *
 * ## 线程
 *
 * ⛔ 阻塞（网络 + 磁盘）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
 */
class PosterFetcher(
    private val dir: File,
    private val http: ScrapeHttpLike = ScrapeHttp,
    private val timeoutMs: Int = TIMEOUT_MS,
) {

    /**
     * 下载一张海报，返回**相对文件名**（可直接写进 `media_works.poster_file`）；
     * 失败返回 `null`。
     *
     * ⛔ 失败**不抛异常**：海报是增强，主流程（元数据已经落库）已经成功了。
     *    为了一张图报错会让用户以为整个刮削失败 —— 而他明明已经看到新标题了。
     */
    fun fetch(workKey: String, url: String): String? {
        val u = url.trim()
        if (u.isEmpty()) return null
        val name = PosterNaming.fileNameFor(workKey, u)
        val target = File(dir, name)
        // 盘上已有就直接用 —— 同一个地址的图内容不会变（与 PC 端 `PosterCache`
        // 用「文件是否存在」当缓存判据是同一条推理）。
        if (target.isFile && target.length() > 0) return name

        val bytes = try {
            http.getBytes(u, headersFor(u), timeoutMs)
        } catch (t: Throwable) {
            Log.w(TAG, "海报下载失败（$u）：${t.message}")
            return null
        }
        if (bytes == null || bytes.isEmpty()) {
            Log.w(TAG, "海报下载失败（空响应）：$u")
            return null
        }
        return try {
            if (!dir.exists() && !dir.mkdirs()) {
                Log.w(TAG, "海报目录建不出来：${dir.absolutePath}")
                return null
            }
            // ⛔ 先写 `.part` 再改名：直接写目标文件时进程被杀会留下**半张图**，
            //    而它下次会被当成有效缓存直接显示（PC 端同一条规矩）。
            val tmp = File(dir, "$name.part")
            tmp.writeBytes(bytes)
            if (target.exists()) target.delete()
            if (tmp.renameTo(target)) {
                Log.i(TAG, "海报已缓存：$name（${bytes.size} 字节）")
                name
            } else {
                Log.w(TAG, "海报改名失败：$name")
                tmp.delete()
                null
            }
        } catch (t: Throwable) {
            Log.w(TAG, "海报写盘失败：${t.message}")
            null
        }
    }

    /**
     * 这个地址要带什么请求头。
     *
     * ⛔ 豆瓣的图**必须带 `Referer`**：2026-10-02 实测 `qnmob3-sign.doubanio.com`
     *    带 Referer 返回 200、不带返回 418。TMDB 的图带 Referer 无害，所以只按
     *    域名决定要不要带。
     */
    private fun headersFor(url: String): Map<String, String> {
        val host = try {
            java.net.URL(url).host.orEmpty()
        } catch (t: Throwable) {
            return emptyMap()
        }
        if (!host.endsWith("doubanio.com")) return emptyMap()
        return mapOf(
            "Referer" to DoubanScraper.REFERER,
            "User-Agent" to DoubanScraper.UA,
        )
    }

    companion object {
        private const val TAG = "CloudCine"

        /** 海报比 JSON 大得多，给足超时（一张 w500 约 50~150 KB）。 */
        private const val TIMEOUT_MS = 20_000
    }
}
