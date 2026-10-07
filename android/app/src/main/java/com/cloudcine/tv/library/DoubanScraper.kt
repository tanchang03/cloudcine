package com.cloudcine.tv.library

import android.util.Log
import java.net.URLEncoder

/**
 * 豆瓣刮削器 —— 走 rexxar 接口（移动端 H5 在用的那一套）。
 *
 *   * 搜索：`/rexxar/api/v2/search?q=<词>&type=movie&for_mobile=1`
 *   * 详情：`/rexxar/api/v2/movie/{id}?for_mobile=1`
 *
 * 官方 App 的 `frodo.douban.com` 要签名、公开 apikey 已作废，所以那条路是死的。
 * rexxar 只要带 `Referer: https://movie.douban.com/` 就能匿名调用。
 *
 * ## 与 PC 端 `DoubanScraper` 的关系
 *
 * 同一套接口、同一批坑（见下），但**有一处刻意的放宽**：这里不要求配 Cookie
 * （理由见 [enabled]）。
 *
 * ## 五个「改错了不报错、只是结果变空 / 变错」的坑
 *
 * 1. **搜索结果是三段，不是一段。** 正片条目经常**不在** `subjects.items` 里
 *    —— 实测搜「繁花」，`subjects.items` 只有两本书和一个 2028 年的影版，
 *    真正的剧集只在 `smart_box` 里。只读 `subjects` 会**静默刮错片子**。
 * 2. **`type` 参数不是过滤器。** 传 `type=movie`，返回里照样混着
 *    `book` / `music`。必须自己按 `target_type` 剔掉非影视条目。
 * 3. **搜索结果的 `cover_url` 不能当海报。** 它被服务端套了
 *    `imageView2/…/h/120/format/jpg`，是一条 120px 高的横条；海报只能取
 *    **详情接口**的 `cover_url`（`m_ratio_poster`，实测 540×803 = 2:3）。
 * 4. **详情接口对剧集会 301 到 `/tv/{id}`。** 所以类型不能靠请求路径判断，
 *    要读**最终响应体**里的 `type`（`movie` / `tv`）。
 * 5. **限流是显式的，但 HTTP 状态码不稳定。** 额度耗尽返回
 *    `{"msg":"need_login","code":103}`，实测**既见过 200 也见过 403**。
 *    所以判成功必须在解析业务码**之后**。
 *
 * ## 额度与熔断
 *
 * 匿名额度实测约 **10 个不同的搜索词**，之后就是 `103 need_login`；
 * 而同一个词连打多次会命中服务端缓存（不扣额度），所以「多打几次看看」
 * 这种排查方式会得出完全错误的结论。
 *
 * 见到 `103` 立刻熔断一段时间（[latch]）。⛔ 熔断**必须会过期** —— 用户
 * 「去设置里贴个 Cookie 再回来」是很正常的操作，一次性的永久熔断会让他在
 * 修好之后依然刮不到，且只有重启应用才恢复。
 *
 * ## 线程
 *
 * ⛔ 所有方法都**阻塞**（网络）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
 */
class DoubanScraper(
    private val http: ScrapeHttpLike = ScrapeHttp,
    private val cookie: String = "",
    private val baseUrl: String = DEFAULT_BASE_URL,
    private val timeoutMs: Int = TIMEOUT_MS,
    private val now: () -> Long = { System.currentTimeMillis() },
) : MetadataScraper {

    override val id: String get() = ID

    override val displayName: String get() = "豆瓣"

    /**
     * ⛔ 与 PC 端**刻意不同**：这里**不要求配 Cookie**。
     *
     * PC 端 `DoubanScraper.isEnabled` 要求 Cookie 非空，理由是「不给『配了也
     * 必然失败』的默认」。Android 端放宽，因为两条现实：
     *
     *   1. 电视上用遥控器敲 Cookie 是**真的难**，把它设成前置条件等于「这个功能
     *      默认不可用」；
     *   2. 手动刮削是**低频、用户主动**的动作（一次点一部），匿名额度约 10 个
     *      搜索词够用很久 —— 而 PC 端担心的那件事是「扫描期自动刮 145 部」，
     *      那个场景 Android 端根本不存在（这里只有手动）。
     *
     * 配了 Cookie 额度更宽，不配也能跑；耗尽了由 [latch] 熔断并提示去配 Cookie。
     */
    override val enabled: Boolean get() = true

    /** 额度熔断的截止时刻（毫秒）。 */
    private var needLoginUntil = 0L

    /** 下一次熔断的时长（每次翻倍，封顶 [MAX_BACKOFF_MS]）。 */
    private var needLoginBackoffMs = INITIAL_BACKOFF_MS

    /** 现在是否处于熔断期。 */
    private val latched: Boolean get() = now() < needLoginUntil

    override fun search(query: ScrapeQuery): List<ScrapeCandidate> {
        val word = query.title.trim()
        if (word.isEmpty()) return emptyList()
        if (latched) {
            Log.i(TAG, "豆瓣在熔断期内（还剩 ${(needLoginUntil - now()) / 1000}s），跳过搜索")
            return emptyList()
        }
        val res = try {
            http.get(
                "$baseUrl/search?q=${enc(word)}&type=movie&for_mobile=1",
                headers(),
                timeoutMs,
            )
        } catch (t: Throwable) {
            // 网络抖动 = 「这次没搜到」，不是错误。对话框那边无论哪种原因都只能说
            // 「换个词再试」，区分了对用户没有额外价值。
            Log.w(TAG, "豆瓣搜索失败：${t.message}")
            return emptyList()
        }
        // ⛔ 业务码判在状态码**之前**（理由见类文档坑 #5）。
        if (DoubanParsing.isNeedLogin(res.body)) {
            latch()
            return emptyList()
        }
        if (!res.ok) {
            Log.w(TAG, "豆瓣搜索 HTTP ${res.code}")
            return emptyList()
        }
        val out = DoubanParsing.candidates(res.body)
        Log.i(TAG, "豆瓣搜「$word」：${out.size} 条候选")
        return out
    }

    override fun resolve(candidate: ScrapeCandidate): ScrapedMetadata? {
        if (candidate.source != id) return null
        if (latched) return null
        val res = try {
            http.get(
                "$baseUrl/movie/${enc(candidate.sourceId)}?for_mobile=1",
                headers(),
                timeoutMs,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "豆瓣详情失败：${t.message}")
            return null
        }
        if (DoubanParsing.isNeedLogin(res.body)) {
            latch()
            return null
        }
        if (!res.ok) return null
        val meta = DoubanParsing.detail(res.body, candidate.title)
        if (meta == null) Log.w(TAG, "豆瓣详情解析不出条目（${candidate.uid}）")
        return meta
    }

    /**
     * 探一次豆瓣，把「**接口通不通** / **Cookie 是不是登录态** /
     * **有没有被限流**」分开告诉用户。
     *
     * ## 为什么必须有它
     *
     * 用户填完 Cookie 之后，原本唯一的验证方式是「刮一部看看」—— 而那要等
     * TMDB 先超时十来秒，最后只给一句「未命中」。三种完全不同的原因
     * （地址不通 / Cookie 无效 / 被限流）在结果上长得一模一样，用户只能反复试。
     *
     * ⛔ **不碰熔断**（不调 [latch]）：这是用户手动触发的单次询问，结论已经
     *    直接回给他了；顺手把刮削熔断掉会让「刚测完就去刮」莫名其妙搜不动。
     *
     * ⛔ 判据与文案对齐 PC 端 `douban_client.dart` 的 `probe()`：同样的
     *    `PROBE_WORD`、同样的「含不含 dbcl2」二分。
     */
    fun probe(): ScrapeProbe {
        if (cookie.isBlank()) {
            return ScrapeProbe(
                false,
                "还没填 Cookie。豆瓣匿名额度实测只有约 $ANON_QUOTA 个搜索词，" +
                    "全盘刮会中途耗尽 —— 建议先填。",
            )
        }
        val res = try {
            http.get(
                "$baseUrl/search?q=${enc(PROBE_WORD)}&type=movie&for_mobile=1",
                headers(),
                timeoutMs,
            )
        } catch (t: Throwable) {
            return ScrapeProbe(
                false,
                "连不上 $baseUrl —— 网络层失败（${t.message}）。" +
                    "豆瓣境内一般可直连；若电视上开了代理，检查它是否把 " +
                    "m.douban.com 也劫持了。",
            )
        }
        // ⛔ 业务码判在状态码**之前**（理由见类文档坑 #5）。
        if (DoubanParsing.isNeedLogin(res.body)) {
            return ScrapeProbe(
                false,
                "接口可达，但豆瓣回了 $NEED_LOGIN_CODE need_login（HTTP ${res.code}）—— " +
                    "当前出口 IP 被限流，或这个 Cookie 已失效。" +
                    if (cookieHasLoginToken(cookie)) {
                        "你填的 Cookie 含 dbcl2，形状是对的，多半是被限流；过一会儿再试。"
                    } else {
                        "你填的 Cookie 里没有 dbcl2，多半不是登录态 —— " +
                            "要从已登录的浏览器里复制整条 Cookie。"
                    },
            )
        }
        if (!res.ok) {
            return ScrapeProbe(false, "接口可达，但返回 HTTP ${res.code}。")
        }
        val hits = DoubanParsing.candidates(res.body).size
        if (hits == 0) {
            return ScrapeProbe(
                false,
                "接口可达、Cookie 未被拒，但搜「$PROBE_WORD」零结果 —— " +
                    "多半是接口改版了，请提 issue。",
            )
        }
        return ScrapeProbe(
            true,
            "连接正常：搜「$PROBE_WORD」返回 $hits 条。" +
                if (cookieHasLoginToken(cookie)) {
                    "Cookie 含 dbcl2，是登录态，额度宽。"
                } else {
                    "Cookie 里没有 dbcl2 —— 走的是匿名额度（约 $ANON_QUOTA 个搜索词）。"
                },
        )
    }

    /**
     * 进入熔断，并把下一次的时长翻倍（封顶）。
     *
     * ⛔ 时长**必须会过期**（见类文档）。写死一个「本次进程内不再试」的开关，
     *    用户按提示去贴了 Cookie 回来仍然刮不到 —— 那是最伤人的一种 bug。
     */
    private fun latch() {
        val wait = needLoginBackoffMs
        needLoginUntil = now() + wait
        needLoginBackoffMs = (wait * 2).coerceAtMost(MAX_BACKOFF_MS)
        Log.w(
            TAG,
            "豆瓣返回 $NEED_LOGIN_CODE（need_login）：额度耗尽或触发风控，" +
                "冷却 ${wait / 1000}s 后再试（下次 ${needLoginBackoffMs / 1000}s）。" +
                "匿名额度实测约 10 个搜索词，到「刮削设置」粘贴登录后的 Cookie 可继续。",
        )
    }

    private fun headers(): Map<String, String> = buildMap {
        // ⛔ `Referer` 必带：少了它接口直接拒绝。
        put("Referer", REFERER)
        put("Accept", "application/json")
        // 实测用桌面版 UA 就能通；换成移动 UA 没有额外好处，反而多一个变量。
        put("User-Agent", UA)
        if (cookie.isNotBlank()) put("Cookie", cookie.trim())
    }

    companion object {
        /** 与 [ScrapeCandidate.source] 同一个取值域。 */
        const val ID = "douban"

        /** rexxar 接口的根。**没有版本号之外的前缀**，路径直接接在后面。 */
        const val DEFAULT_BASE_URL = "https://m.douban.com/rexxar/api/v2"

        /** 必带的 `Referer`。少了它接口直接拒绝。 */
        const val REFERER = "https://movie.douban.com/"

        /** 服务端要求登录的业务码。 */
        const val NEED_LOGIN_CODE = 103

        /**
         * 探测用的搜索词。
         *
         * ⛔ **必须选一个必定有结果的词**，否则区分不出「接口通但这个词零命中」
         *    与「接口不通」。与 PC 端 `DoubanScraper.probeWord` 同一个词。
         */
        const val PROBE_WORD = "流浪地球"

        /** 匿名额度（个搜索词）。**实测值**，写进提示里给用户一个量级感。 */
        const val ANON_QUOTA = 10

        /**
         * Cookie 里有没有登录态标志（`dbcl2=<uid>:<token>`）。
         *
         * ⛔ **只判形状，不验真伪** —— 真伪只有服务端说了算。它的价值是在用户
         *    贴错东西（只贴了 `bid`、或把整个 `Cookie: xxx` 前缀也贴进来）时
         *    立刻给一句提示，而不是让他等一次刮削失败。
         *
         * 按「分号 + 可选空格」切分，所以 `ll="1";dbcl2=x` 与 `ll="1"; dbcl2=x`
         * 都能认出来；而 `xdbcl2=` **不会**误判（`(^|;)` 把前缀钉死了）。
         * 判据与 PC 端 `cookieHasLoginToken` 逐字一致。
         */
        fun cookieHasLoginToken(cookie: String): Boolean =
            LOGIN_TOKEN_RE.containsMatchIn(cookie)

        /** 用户把 `Cookie: ` 前缀一起贴进来是很常见的一种错法。 */
        fun looksLikeRawHeader(cookie: String): Boolean =
            RAW_HEADER_RE.containsMatchIn(cookie)

        private val LOGIN_TOKEN_RE = Regex("(^|;)\\s*dbcl2=")

        private val RAW_HEADER_RE = Regex("^\\s*cookie\\s*:", RegexOption.IGNORE_CASE)

        /** 桌面版 UA。⛔ `internal` 是因为 [PosterFetcher] 下载豆瓣图时也要带它。 */
        internal const val UA =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        private const val TIMEOUT_MS = 12_000

        /** 首次熔断 30 秒：够短，用户贴完 Cookie 回来就能试。 */
        private const val INITIAL_BACKOFF_MS = 30_000L

        private const val MAX_BACKOFF_MS = 10 * 60_000L

        private const val TAG = "CloudCine"

        /** URL 参数编码。⛔ 片名里有 `&` / `+` / 空格是常态，不编码会直接搜错。 */
        fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
    }
}

/**
 * 豆瓣响应的**纯解析**。
 *
 * ⛔ 与网络分开是刻意的：这一层是「接口改版时唯一要改的地方」，而它必须能被
 *    纯 JVM 单测覆盖（工程里 `org.json` 在单测下是空壳，所以用 [MiniJson]）。
 */
object DoubanParsing {

    /** 豆瓣海报 CDN 的目标子域（见 [rewritePosterUrl]）。 */
    private const val TARGET_HOST = "qnmob3-sign.doubanio.com"

    /**
     * 从搜索响应里取候选。
     *
     * ⛔ **两个来源都要读**（坑 #1），且 `subjects` 与 `smart_box` 的**形状不同**
     *    —— `subjects` 是 `{items:[…]}`，而 `smart_box` 直接就是数组。
     *    写两个解析器很容易只维护其中一个。
     */
    fun candidates(body: String): List<ScrapeCandidate> {
        val root = try {
            MiniJson.parseObject(body)
        } catch (t: Throwable) {
            return emptyList()
        }
        val out = ArrayList<ScrapeCandidate>(24)
        out += candidatesOf(root["subjects"])
        out += candidatesOf(root["smart_box"])
        // 同一条目可能在两处都出现；去重（`distinctBy` 保序）。
        return out.distinctBy { it.uid }
    }

    private fun candidatesOf(node: Any?): List<ScrapeCandidate> {
        val raw: List<Any?> = when (node) {
            is Map<*, *> -> (node["items"] as? List<*>) ?: return emptyList()
            is List<*> -> node
            else -> return emptyList()
        }
        val out = ArrayList<ScrapeCandidate>(raw.size)
        for (entry in raw) {
            val e = entry as? Map<*, *> ?: continue
            // `layout: more_results` 这类占位项没有 `target`。
            val target = e["target"] as? Map<*, *> ?: continue
            out += candidateOf(target, e["target_type"]) ?: continue
        }
        return out
    }

    private fun candidateOf(target: Map<*, *>, targetType: Any?): ScrapeCandidate? {
        val type = (targetType as? String).orEmpty()
        // ⛔ 坑 #2：`type=movie` **不是过滤器**，必须自己按 `target_type` 剔。
        if (type != "movie" && type != "tv") return null
        // `id` 有时是数字、有时是字符串 —— 两种都收。
        val id = strOf(target["id"]) ?: intOf(target["id"])?.toString() ?: return null
        val title = strOf(target["title"]) ?: return null
        return ScrapeCandidate(
            source = DoubanScraper.ID,
            sourceId = id,
            title = title,
            year = yearOf(strOf(target["year"])),
            type = type,
            // ⚠️ 坑 #3：这条只是候选列表的缩略图（120px 横条），**不能落库**。
            posterUrl = strOf(target["cover_url"]),
            overview = strOf(target["intro"]),
        )
    }

    /**
     * 详情响应 → 完整元数据。**响应不是一个条目时返回 `null`**。
     *
     * [matchedQuery] 是实际用于命中的查询词（排查「刮错了」时看它）。
     */
    fun detail(body: String, matchedQuery: String): ScrapedMetadata? {
        val d = try {
            MiniJson.parseObject(body)
        } catch (t: Throwable) {
            return null
        }
        val id = strOf(d["id"])
        // ⛔ 坑 #4：类型读**响应体**，不是请求路径 —— `/movie/{id}` 对剧集会
        //    301 到 `/tv/{id}`，按路径判断会把所有剧集都记成电影。
        val type = strOf(d["type"]) ?: "movie"
        val isTv = type == "tv"

        // ⛔ 标题**只能**来自响应体，**不许拿查询词兜底**（PC 端踩过这个坑）：
        //    兜底会把「详情没拿到」伪装成「刮削成功」—— 标题有、海报简介一个都
        //    没有，而且 `source` 记成 online。用户看到「已刮削」，与「刮削成功但
        //    没有封面」这类现象完全一样，排查时最难想到根因在这里。
        val title = strOf(d["title"])
        if (title.isNullOrEmpty()) return null

        return ScrapedMetadata(
            title = title,
            // 国产片的 `original_title` 实测是空串（不是缺失），所以按空处理。
            // 不从 `aka` 里猜外语原名：实测「流浪地球2」的 `aka` 首项是
            // `流浪地球2(3D版)`，猜出来只会是错的。
            originalTitle = strOf(d["original_title"]),
            year = yearOf(strOf(d["year"])),
            overview = strOf(d["intro"]),
            posterUrl = rewritePosterUrl(strOf(d["cover_url"])),
            // 豆瓣详情里没有独立的剧照字段（`pic` 是同一张海报的大小档），
            // 所以背景图留空 —— 用同一张海报当背景只会糊成一片。
            backdropUrl = null,
            rating = doubleOf((d["rating"] as? Map<*, *>)?.get("value")),
            genres = strListOf(d["genres"]),
            // ⛔ 把解析出的类型编进 `onlineId`：少了那一段，「这部电影」与
            //    「这部剧」在库里就无法区分了。
            onlineId = id?.let { "douban/${if (isTv) "tv" else "movie"}/$it" },
            source = ScrapeSource.online,
            matchedQuery = matchedQuery,
        )
    }

    /** 响应体是不是「额度耗尽 / 需要登录」。 */
    fun isNeedLogin(body: String): Boolean {
        if (body.isEmpty()) return false
        val j = try {
            MiniJson.parseObject(body)
        } catch (t: Throwable) {
            return false
        }
        val code = j["code"]
        if (code is Number && code.toInt() == DoubanScraper.NEED_LOGIN_CODE) return true
        if (code is String && code == DoubanScraper.NEED_LOGIN_CODE.toString()) return true
        return j["msg"] == "need_login"
    }

    /**
     * 把 `img*.doubanio.com` 的海报地址改写成 `qnmob3-sign.doubanio.com`。
     *
     * 2026-10-02 实测：豆瓣启用了新的 CDN 防盗链，`img3` / `img9` 等子域
     * **即使带正确 `Referer`** 也返回 403/418；而搜索结果缩略图一直用的
     * `qnmob3-sign.doubanio.com` 同图同头返回 200。详情接口给的 `cover_url`
     * 用的正是 `img*` 子域，所以落库前改写过去。
     *
     * **只换域名，路径不变**：`/view/photo/m_ratio_poster/public/pXXX.jpg`
     * 是服务端按图 ID 给的，换到 `qnmob3-sign` 后仍然有效。
     *
     * 已经是目标域名的原样返回（幂等）；非豆瓣域名原样返回（**不误伤 TMDB**）。
     */
    fun rewritePosterUrl(url: String?): String? {
        val raw = url?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val host = try {
            java.net.URL(raw).host.orEmpty()
        } catch (t: Throwable) {
            return raw
        }
        if (host.isEmpty()) return raw
        if (host == TARGET_HOST) return raw
        if (host != "doubanio.com" && !host.endsWith(".doubanio.com")) return raw
        // ⛔ 用 `indexOf` + 拼接做**字面量**替换，不用 `replaceFirst`：
        //    后者第一个参数是**正则**，而域名里的 `.` 在正则里是通配符 ——
        //    这里恰好不出错（`. ` 匹配 `.`），但它会去匹配「第一个长得像
        //    域名的片段」，而不是「域名本身」。字面量替换没有这个歧义。
        val at = raw.indexOf(host)
        if (at < 0) return raw
        return raw.substring(0, at) + TARGET_HOST + raw.substring(at + host.length)
    }

    // ------------------------------------------------------------------
    // 取值助手：全部「读不懂就给 null」，绝不抛
    // ------------------------------------------------------------------

    private fun strOf(v: Any?): String? =
        (v as? String)?.trim()?.takeIf { it.isNotEmpty() }

    private fun intOf(v: Any?): Int? = when (v) {
        is Int -> v
        is Long -> v.toInt()
        is Double -> v.toInt()
        is String -> v.trim().toIntOrNull()
        else -> null
    }

    private fun doubleOf(v: Any?): Double? = when (v) {
        is Double -> v
        is Int -> v.toDouble()
        is Long -> v.toDouble()
        is String -> v.trim().toDoubleOrNull()
        else -> null
    }

    /**
     * 从字符串里取 4 位年份。
     *
     * 豆瓣的 `year` 实测是 `"2023"`（不是 `"2023-01-01"`），但 TMDB 给的是
     * 完整日期 —— 两边共用这个「找前 4 位数字」的实现，省掉一处口径分叉。
     */
    private fun yearOf(s: String?): Int? {
        val t = s?.trim().orEmpty()
        if (t.isEmpty()) return null
        val m = Regex("(18|19|20)\\d{2}").find(t) ?: return null
        return m.value.toIntOrNull()
    }

    private fun strListOf(v: Any?): List<String> =
        (v as? List<*>)?.mapNotNull { it as? String }?.filter { it.isNotBlank() }
            ?: emptyList()
}
