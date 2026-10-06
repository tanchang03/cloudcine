package com.cloudcine.kuake.quark

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 夸克 PC 自用接口（`drive-pc.quark.cn`，靠网页登录态 Cookie 鉴权）。
 *
 * ⛔ **不是**官方开放平台 `open-api-drive.quark.cn` —— 那套要 OAuth
 * `access_token`，两者不可混用。
 *
 * ## 所有请求都必须带 `pr=ucpro&fr=pc`
 *
 * 实测：漏掉公共参数时 `batch/file/play/info` 直接回
 * `HTTP 401 code=31001 require login [guest]` —— 看起来像「没登录」，
 * 实际是「请求缺参数，服务端把你当游客」。这条在 Mac 侧探针上踩过一次。
 *
 * ## `__puus` 是直链的硬门槛（实测）
 *
 * 同一条已签名的 CDN 直链，四种 Cookie 组合的结果：
 *
 * | 请求带的 Cookie | 结果 |
 * |---|---|
 * | 最新 `__puus` | **206** |
 * | 陈旧 `__puus` | **206**（陈旧也行） |
 * | 有 `__pus` 等会话 Cookie，**缺** `__puus` | **412** |
 * | 完全不带 Cookie | **206** |
 *
 * 即「要么不带 Cookie，要么必须带 `__puus`」。**带一半是最坏的**：
 * 服务端认得你是登录用户，却过不了防重放校验，于是 412 ——
 * 表现是「列表能刷、一播就转圈」。所以本类在每个响应后都回填
 * `Set-Cookie` 里的 `__puus`（[absorbCookies]）。
 */
class QuarkApi(private val store: QuarkStore) {

    /** 网盘业务错误。`needsReauth` 时上层应回登录页。 */
    class ApiException(
        val code: Int,
        override val message: String,
        val needsReauth: Boolean = false,
    ) : Exception(message)

    // ------------------------------------------------------------------
    // 列目录
    // ------------------------------------------------------------------

    /**
     * 列一层目录。`fid` 为 `"0"` 表示根。
     *
     * ⛔ `_size` 别开太大：夸克对每页条数有上限，超了不报错、只是返回条数变少，
     * 表现为「有些文件看不到」。100 是实测稳的值。
     */
    fun listDirectory(fid: String, page: Int = 1, size: Int = 100): List<DriveEntry> {
        val res = QuarkHttp.get(
            url = "$PC$PATH_FILE_SORT",
            query = commonQuery() + mapOf(
                "pdir_fid" to if (fid.isEmpty()) ROOT else fid,
                "_page" to "$page",
                "_size" to "$size",
                "_fetch_total" to "1",
                // 目录优先、更新时间倒序。夸克用 `file_type:asc` 表示目录在前。
                "_sort" to "file_type:asc,updated_at:desc",
                "_is_hl" to "1",
            ),
            cookie = store.requestCookie(),
        )
        absorbCookies(res)
        ensureOk(res, "列目录")

        val list = res.dataList ?: return emptyList()
        val out = ArrayList<DriveEntry>(list.length())
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            val name = o.optString("file_name").ifEmpty { o.optString("file_name_display") }
            if (name.isEmpty()) continue
            out.add(
                DriveEntry(
                    fid = o.optString("fid").ifEmpty { o.optString("id") },
                    name = name,
                    isDir = isDir(o),
                    sizeBytes = o.optLong("size", 0L),
                    updatedAtMs = normalizeTimestamp(o.optLong("updated_at", 0L)),
                ),
            )
        }
        return out
    }

    /** 用户信息，只在标题栏显示昵称。失败不抛 —— 它纯装饰。 */
    fun fetchNickname(): String? = runCatching {
        val res = QuarkHttp.get("$PC$PATH_MEMBER", commonQuery(), store.requestCookie())
        absorbCookies(res)
        res.data?.optString("nickname")?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    /** 最轻量的连通性探测。用来判断「凭证还在不在」。 */
    fun ping(): Boolean = runCatching {
        val res = QuarkHttp.get("$PC$PATH_CONFIG", commonQuery(), store.requestCookie())
        absorbCookies(res)
        res.isOk
    }.getOrDefault(false)

    // ------------------------------------------------------------------
    // 取链
    // ------------------------------------------------------------------

    /**
     * 取一次起播需要的全部流：**转码阶梯 + 原画**。
     *
     * 两条来源是**并列**的、不是备选：
     *   - `batch/file/play/info` → `video_list[]`，转码阶梯，**唯一能拿到档位列表的路由**；
     *   - `file/audioplay` → 原文件本身，**不受 50 MiB 限制**（`file/download` 会 23018）。
     *
     * ⛔ 解析 `video_list` 时**必须跳过 `audio_list`**：那条是纯音频流
     * （`dolby_eac3`），没有分辨率字段，很容易被当成「原画」——
     * 而原画永远排最前，于是默认播了一条**没有视频轨**的流：
     * 有声音、进度条在走、**没有画面、不报任何错**。云影踩过这个坑。
     */
    fun resolve(fid: String): PlayInfo {
        val info = fetchPlayInfo(fid)
        val original = fetchOriginal(fid)

        val qualities = ArrayList<Quality>()
        original?.let { qualities.add(it) }
        qualities.addAll(info.second)
        if (qualities.isEmpty()) {
            throw ApiException(-1, "服务端没给出任何可用地址（转码档与原画都是空的）")
        }

        // 原画在最前；其余按分辨率降序（高的在前）。
        val sorted = qualities.sortedWith(
            compareByDescending<Quality> { it.isOriginal }
                .thenByDescending { it.height }
                .thenByDescending { it.bitrateKbps },
        )
        return PlayInfo(
            fileName = info.first,
            durationMs = info.third,
            defaultQualityId = original?.let { if (info.second.isEmpty()) ORIGIN else info.fourth }
                ?: info.fourth,
            qualities = sorted,
        )
    }

    /**
     * @return `(文件名, 转码档列表, 时长ms, 服务端默认档位)`
     */
    private fun fetchPlayInfo(fid: String): Quad<String, List<Quality>, Long, String> {
        val body = JSONObject().apply {
            // 照抄客户端：`resolutions` 声明梯度，顺序从低到高。
            // 少了 `fetch_play_video_resolution_setting` 等开关，响应会变瘦、
            // 档位列表就是空的。
            put("resolutions", RESOLUTION_TIERS)
            put("fetch_credits_setting", 1)
            put("fetch_play_video_resolution_setting", 1)
            put("fetch_play_audio_type_setting", 1)
            put("support_resolution_free_limit_ab", 1)
            put("fetch_pdir", 1)
            put("support_right", "trial_1080P_zhizhen_pc")
            put("supports", "")
            put("fids", JSONArray().put(fid))
        }
        val res = QuarkHttp.postJson(
            url = "$PC$PATH_PLAY_INFO",
            query = commonQuery() + mapOf("uc_param_str" to "utfrpr"),
            body = body,
            cookie = store.requestCookie(),
        )
        absorbCookies(res)
        ensureOk(res, "取播放信息")

        val node = pickNode(res.data, fid) ?: return Quad("", emptyList(), 0L, "")
        val fileName = node.optString("file_name")
        val durationMs = node.optJSONObject("meta")?.optLong("duration", 0L)
            ?.times(1000L) ?: 0L

        val out = ArrayList<Quality>()
        val list = node.optJSONArray("video_list")
        if (list != null) {
            for (i in 0 until list.length()) {
                val item = list.optJSONObject(i) ?: continue
                val info = item.optJSONObject("video_info") ?: continue
                val url = info.optString("url")
                if (url.isEmpty()) continue
                // ⛔ 只认 `video_list`；`audio_list` 已在 pickNode 之外被排除。
                val id = item.optString("resolution").ifEmpty { info.optString("resolution") }
                if (id.isEmpty()) continue
                out.add(
                    Quality(
                        id = id,
                        label = tierLabel(id),
                        width = info.optInt("width"),
                        height = info.optInt("height"),
                        bitrateKbps = info.optInt("bitrate"),
                        sizeBytes = info.optLong("size", 0L),
                        url = url,
                        isOriginal = false,
                        durationMs = info.optLong("duration", 0L) * 1000L,
                    ),
                )
            }
        }
        Log.i(TAG, "play/info 档位=${out.joinToString { "${it.id}(${it.width}x${it.height},${it.bitrateKbps}kbps,${it.requiredMbPerSec}MB/s)" }}")
        return Quad(fileName, out, durationMs, node.optString("default_resolution"))
    }

    /** 原画：`file/audioplay` 返回的是**原文件本身**（名字叫 audio，视频照样给）。 */
    private fun fetchOriginal(fid: String): Quality? {
        val res = runCatching {
            QuarkHttp.get(
                url = "$PC$PATH_AUDIOPLAY",
                query = commonQuery() + mapOf("fid" to fid),
                cookie = store.requestCookie(),
            )
        }.getOrNull() ?: return null
        absorbCookies(res)
        if (!res.isOk) {
            Log.w(TAG, "audioplay 失败 code=${res.code} ${res.message}（原画这一档不可用，不影响转码档）")
            return null
        }
        val d = res.data ?: return null
        val url = d.optString("audio_url")
        if (url.isEmpty()) return null
        val size = d.optLong("size", 0L)
        val durationMs = d.optLong("duration", 0L) * 1000L
        return Quality(
            id = ORIGIN,
            label = "原画",
            width = d.optInt("video_width"),
            height = d.optInt("video_height"),
            bitrateKbps = if (durationMs > 0) (size * 8 / durationMs).toInt() else 0,
            sizeBytes = size,
            url = url,
            isOriginal = true,
            durationMs = durationMs,
        )
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    /**
     * 把响应里轮换的 `__puus` 回填进 [QuarkStore]。
     *
     * ⛔ 不能省。夸克在每个 API 响应的 `Set-Cookie` 里轮换下发 `__puus`，
     * 而直链要求「要么不带 Cookie，要么带 `__puus`」。少了它，列表能刷、
     * 一直播就 412。
     */
    private fun absorbCookies(res: QuarkResponse) {
        val puus = res.cookieValue("__puus")
        if (!puus.isNullOrEmpty()) {
            val cur = store.cookie
            store.cookie = if (cur.contains("__puus=")) {
                cur.replace(Regex("__puus=[^;]*"), "__puus=$puus")
            } else {
                "$cur; __puus=$puus"
            }
        }
        res.cookieValue("Video-Auth")?.takeIf { it.isNotEmpty() }?.let { store.videoAuth = it }
    }

    private fun ensureOk(res: QuarkResponse, what: String) {
        if (res.isOk) return
        // 31001 = require login [guest]：缺公共参数或凭证失效。
        val reauth = res.code == 31001 || res.status == 401
        throw ApiException(
            res.code,
            "$what 失败：HTTP ${res.status} code=${res.code} ${res.message}".trim(),
            needsReauth = reauth,
        )
    }

    /**
     * `data` 可能是 `{fid: {...}}` 也可能是 `[{...}]`，两种都认。
     *
     * 按 fid 取键优先，取不到就退化成「第一个对象」—— 服务端改形状时
     * 至少还能播，而不是整个菜单空掉。
     */
    private fun pickNode(data: JSONObject?, fid: String): JSONObject? {
        if (data == null) return null
        data.optJSONObject(fid)?.let { return it }
        val keys = data.keys()
        while (keys.hasNext()) {
            val o = data.optJSONObject(keys.next())
            if (o != null) return o
        }
        return null
    }

    /** 目录判定：**以 `dir` 为准**，`file_type` 只作兜底。 */
    private fun isDir(o: JSONObject): Boolean {
        if (o.has("dir")) {
            val d = o.opt("dir")
            if (d is Boolean) return d
            if (d is Number) return d.toInt() != 0
            if (d is String) return d == "true" || d == "1"
        }
        if (o.has("file_type")) return o.optInt("file_type") == 0
        return false
    }

    /** `updated_at` 秒/毫秒两种都可能，统一成毫秒。 */
    private fun normalizeTimestamp(v: Long): Long = if (v in 1..9_999_999_999L) v * 1000L else v

    private fun tierLabel(id: String): String = when (id.lowercase()) {
        "4k" -> "4K"
        "2k" -> "2K"
        "super" -> "超清"
        "high" -> "高清"
        "normal" -> "标清"
        "low" -> "流畅"
        else -> id
    }

    /** 四元组（Kotlin 的 `Triple` 装不下四个）。 */
    private data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)

    companion object {
        private const val TAG = "KuakeProto"

        const val PC = "https://drive-pc.quark.cn"

        const val PATH_CONFIG = "/1/clouddrive/config"
        const val PATH_MEMBER = "/1/clouddrive/member"
        const val PATH_FILE_SORT = "/1/clouddrive/file/sort"
        const val PATH_PLAY_INFO = "/1/clouddrive/batch/file/play/info"
        const val PATH_AUDIOPLAY = "/1/clouddrive/file/audioplay"

        const val ROOT = "0"

        /** 原画档的 id（转码档用的是 `4k`/`super` 这些）。 */
        const val ORIGIN = "origin"

        /** 照抄客户端的梯度声明，顺序从低到高。 */
        const val RESOLUTION_TIERS = "normal,low,high,super,2k,4k"

        /**
         * ⛔ `fr` 必须与账号类型匹配：写 `mac` 会得到
         * `code=31001 require login [guest]`（实测）。
         */
        fun commonQuery(): Map<String, String> = mapOf("pr" to "ucpro", "fr" to "pc")
    }
}
