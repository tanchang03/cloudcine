package com.cloudcine.tv.library

import android.util.Log
import java.io.File
import java.util.Collections

/**
 * 未刮削作品的**封面兜底** —— 把网盘自带的缩略图拉下来当封面。
 *
 * ## 它修的是什么
 *
 * 扫描时 `LibraryScanner` 已经把缩略图地址写进了 `media_works.poster_url`
 * （来源是夸克列目录时下发的 `preview_url`，见 `DriveEntry.previewUrl`），
 * 但 [PosterStore.fileFor] 的三级查找**每一级都要求本地真有文件**，
 * 而**没有任何组件负责把它下载下来**：
 *
 *   * [PosterFetcher] 只服务**刮削海报**，而且只被 `ScrapeActivity` 调；
 *   * `EpisodeThumbs` 有完整的按需下载能力，但它只被播放页用来画集列表，
 *     而且落在另一个目录（`filesDir/thumbs`）、另一套命名。
 *
 * 结果就是用户看到的那一幕：**没有刮削过的作品在墙上一块封面都没有**，
 * 只有一个「首字」占位块。
 *
 * ## 为什么落在**海报目录**，而不是另开一个缩略图缓存
 *
 * [PosterStore.fileFor] 是「这部作品有没有封面」的**唯一判据** —— 作品墙、
 * 简介页、以及「只看有海报」筛选全都读它。另开一个缓存就要把这条判据改成
 * 「两处取并集」，而 `posterOnly` 的语义会跟着变得说不清（网盘缩略图算不算
 * 「有海报」？）。落在海报目录里，这三处一行都不用改。
 *
 * 顺带的好处：缩略图会**随备份包一起搬走** —— 在新电视上恢复备份之后，
 * 未刮削的作品当场就有封面，不必等它把几百张图重新拉一遍。
 *
 * ## 与 PC 端 `PosterCache` 是同一条口径
 *
 * PC 端做的是同一件事（`lib/data/scrape/poster_cache.dart`）：`pathFor(key, url)`
 * 拿「文件是否存在」当缓存判据，未命中才带 Cookie 发一次请求，先写 `.part`
 * 再改名。这里的 [fetch] 逐条对应 —— **文件名算法、缓存判据、原子写三步
 * 都必须一致**，否则同一部作品在电脑上缓存得到、在电视上缓存不到，
 * 而两边都不报错。
 *
 * ## 命名必须与 `fileFor` 的第②级一致
 *
 * 用 [PosterNaming.fileNameFor]（`{归一化键}_{URL散列}.jpg`），与
 * [PosterFetcher] 同一个函数。这不是审美问题：文件名对不上，`fileFor` 就找不到
 * 刚下下来的这张图，表现是「下完了还是不显示」，且不报任何错。
 *
 * ## 两个内存里的去重集合
 *
 * 作品墙的 `getView` 会被反复调用（每次滚动、每次 `notifyDataSetChanged`）：
 * 没有 [inFlight] 的话同一张图会被并发拉好几次；没有 [failed] 的话，
 * 一张取不到的图会在每次滚动时重试一遍 —— 而夸克有 QPS 限制。
 *
 * ⛔ 阻塞（网络 + 磁盘）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
 *
 * @param thumbBytes 取字节的函数。生产环境传 `{ api.thumbBytes(it) }`
 *   （`PanApi` 那个版本会带上网盘 Cookie）；单测传一个假的。
 *   做成函数类型而不是直接吃 [PanApi]，是因为 `PanApi` 要凭证与真实 HTTP，
 *   在 JVM 单测里起不来 —— 而这里**唯一**需要被验证的东西（命名、去重、
 *   失败记忆、`.part` 原子写）全都不需要真网络。
 */
class CloudCoverFetcher(
    private val dir: File,
    private val thumbBytes: (String) -> ByteArray,
) {

    /** 正在拉的 `键|地址`。 */
    private val inFlight: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /**
     * 拉失败过的 `键|地址`。
     *
     * ⛔ 记的是「这一次运行内」的结论，**不落盘**：夸克的 `preview_url` 会过期
     *    （服务端签名），下次启动重试一次是应该的。落盘记死的话，一次网络抖动
     *    会让这部作品**永久**没有封面。
     */
    private val failed: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /**
     * 下载一张网盘缩略图，返回**相对文件名**（可直接写进 `media_works.poster_file`）；
     * 不需要下载或失败时返回 `null`。
     *
     * 「不需要下载」的三种情形：
     *   * [url] 是空的，或者不是 http(s)（**绝不自己拼地址**：服务端只对已经
     *     生成过预览图的文件下发这个字段，实测覆盖约 70%，拼出来的对剩下的
     *     只会拿到 404/401）；
     *   * 盘上已经有同名文件（同一个地址的图内容不会变 —— 与 [PosterFetcher]
     *     用「文件是否存在」当缓存判据是同一条推理）；
     *   * 这次运行里已经试过且失败了。
     *
     * ⛔ 失败**不抛异常**：封面是增强，作品本身已经正常入库了。
     */
    fun fetch(workKey: String, url: String?): String? {
        // ⛔ 文件名必须用**原样**的 URL 算，不能先把首尾空白 trim 掉再算：
        //    [PosterStore.fileFor] 的第②级是拿 `work.posterUrl` **原样**去算的。
        //    两边差一个字符就是两个散列 ⇒ 图下下来了但 `fileFor` 认不出它，
        //    表现是「下完还是不显示」；而在简介页上还会变成**无限重画**
        //    （每次重画都发现「没有文件」→ 再下一次 → 还是没有）。
        val raw = url.orEmpty()
        val u = raw.trim()
        if (u.isEmpty() || !u.startsWith("http")) return null

        val name = PosterNaming.fileNameFor(workKey, raw)
        val target = File(dir, name)
        if (target.isFile && target.length() > 0) return name

        val token = "$workKey|$raw"
        if (failed.contains(token)) return null
        if (!inFlight.add(token)) return null

        try {
            // 请求用 trim 过的地址（首尾空白进不了 HTTP 行）。
            return download(u, name, target, token)
        } finally {
            inFlight.remove(token)
        }
    }

    /**
     * @param token 去重用的 `键|地址`。失败时**必须记这个 token**（不是文件名）——
     *   两边算出来的键不一致的话，`failed` 永远命中不了，那张取不到的图会在每次
     *   滚动时被重试一遍。
     */
    private fun download(url: String, name: String, target: File, token: String): String? {
        // ⛔ 必须走 `PanApi.thumbBytes`（带 Cookie）：裸链回
        //    `401 code=31001 require login`（实测）。所以这里**不能**复用
        //    [PosterFetcher] —— 它用的是不带网盘凭证的 `ScrapeHttp`。
        val bytes = try {
            thumbBytes(url)
        } catch (t: Throwable) {
            Log.w(TAG, "网盘封面下载失败（$url）：${t.message}")
            failed.add(token)
            return null
        }
        if (bytes.isEmpty()) {
            Log.w(TAG, "网盘封面下载失败（空响应）：$url")
            failed.add(token)
            return null
        }
        return try {
            if (!dir.exists() && !dir.mkdirs()) {
                Log.w(TAG, "海报目录建不出来：${dir.absolutePath}")
                return null
            }
            // ⛔ 先写 `.part` 再改名：直接写目标文件时进程被杀会留下**半张图**，
            //    而它下次会被当成有效缓存直接显示（与 [PosterFetcher] 同一条规矩）。
            val tmp = File(dir, "$name.part")
            tmp.writeBytes(bytes)
            if (target.exists()) target.delete()
            if (tmp.renameTo(target)) {
                Log.i(TAG, "网盘封面已缓存：$name（${bytes.size} 字节）")
                name
            } else {
                Log.w(TAG, "网盘封面改名失败：$name")
                tmp.delete()
                null
            }
        } catch (t: Throwable) {
            Log.w(TAG, "网盘封面写盘失败：${t.message}")
            failed.add(token)
            null
        }
    }

    companion object {
        private const val TAG = "CloudCine"
    }
}
