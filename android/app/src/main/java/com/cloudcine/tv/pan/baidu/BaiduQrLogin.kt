package com.cloudcine.tv.pan.baidu

import android.util.Log
import java.net.URLDecoder
import java.security.SecureRandom

/**
 * 百度网盘**扫码登录**（passport 域，四跳）。
 *
 * 逐条照抄 PC 端 `lib/data/auth/baidu_qr_login.dart`（那边有完整实测记录）。
 * 链路：
 *
 * ```
 * 1. GET passport/v2/api/getqrcode?lp=pc&qrloginfrom=pc&gid=…
 *      → {errno:0, sign, imgurl}，imgurl 是**协议相对地址**，要补 https:
 * 2. GET passport/channel/unicast?channel_id=<sign>&gid=…&tpl=netdisk…
 *      → channel_v 是被**二次编码的 JSON 字符串**：status=1 已扫 / 0 已确认 / 2 取消
 * 3. GET passport/v2/api/bdusslogin?tt&bduss=<v>&u&qrcode=1&tpl=netdisk
 *      → 302 + Set-Cookie（**BDUSS 在 Set-Cookie 里**）
 * 4. 跟着 Location 逐跳走一遍 pan.baidu.com（网盘域的 Cookie 只在这一跳下发）
 * 5. GET passport/v3/login/api/auth?bduss=&ptoken= → netdisk 专用 STOKEN
 * ```
 *
 * ## 五个踩过的坑（照抄 PC 结论，别重新试）
 *
 * - ⛔ **`unicast` 无事件时会挂约 30 秒**：网络超时是**正常等待态**，
 *   不是失败。当成失败会让「连续失败 3 次就报错」在用户掏手机前就触发。
 * - ⛔ **主线是 `GET /v2/api/bdusslogin`，不带 `loginVersion`**。
 *   把风控分支 `POST /v3/login/main/qrbdusslogin` + `loginVersion=v5`
 *   当主线会拿到一套**网盘侧不认**的会话（现象：扫码成功、紧接着
 *   `/api/account/uinfo` 回 `errno=-6`）。
 * - ⛔ **换票那一跳不能自动跟重定向**：凭证在 3xx 的 `Set-Cookie` 里。
 * - ⛔ **必须真的访问落点**（`u` 指向的 pan.baidu.com）：网盘域 Cookie
 *   只由那一跳下发，漏掉它等于「手机显示授权成功、电视端登录失败」。
 * - ⛔ **`-6` 一码多义**：没 Cookie / Cookie 废 / 缺 bdstoken / 风控。
 *   日志里必须留服务端原话（`show_msg`）。
 */
class BaiduQrLogin(private val http: BaiduHttpLike = BaiduHttpClient) {

    /** 一次扫码会话。 */
    data class Session(
        val sign: String,
        val imgUrl: String,
        val gid: String,
        val createdAtMs: Long,
    ) {
        /** 是否已过有效期（5 分钟）。 */
        fun isExpired(nowMs: Long): Boolean = nowMs - createdAtMs > SESSION_TTL_MS
    }

    /** 一次轮询的结果。 */
    sealed class Poll {
        /** 还没人扫。**这是正常态**，继续轮询。 */
        object Waiting : Poll()

        /** 已扫码，等待手机确认（夸克没有这一态）。 */
        object Scanned : Poll()

        /** 已确认，可以换票。 */
        data class Confirmed(val v: String, val u: String) : Poll()

        /** 用户在手机上取消了。 */
        object Cancelled : Poll()

        /** 二维码失效（服务端明确说不认这张了）。 */
        data class Expired(val message: String) : Poll()

        /** 真的出错（HTTP / 解析 / 业务码）。 */
        data class Error(val message: String, val errno: Int? = null) : Poll()
    }

    /** 换票结果。 */
    data class Result(
        val cookies: Map<String, String>,
        /** 落点那一跳收到的 Cookie 名（不在固定名单里，必须放行）。 */
        val panCookieNames: List<String>,
    ) {
        val keys: List<String> get() = cookies.keys.sorted()
    }

    class LoginException(message: String) : Exception(message)

    /** 认证会话的 Cookie 罐（`BAIDUID` 等，三跳要带回去）。 */
    private val jar = LinkedHashMap<String, String>()

    /** 待兑换的确认回执。 */
    private var confirmed: Poll.Confirmed? = null

    /** 最近一次会话。 */
    private var session: Session? = null

    /** 二维码图片缓存（页面每 2 秒轮询重建一次，不缓存会反复下载）。 */
    private var qrImage: ByteArray? = null

    // ------------------------------------------------------------------
    // 第 1 跳：取二维码
    // ------------------------------------------------------------------

    fun start(): Session {
        // 新一次登录 = 新罐：上一轮遗留的 BAIDUID 是**另一次**会话的标识。
        jar.clear()
        qrImage = null
        confirmed = null

        val gid = newGid()
        val res = http.get(
            url = BaiduEndpoints.PASSPORT_HOST + BaiduEndpoints.GET_QRCODE,
            query = linkedMapOf(
                "lp" to "pc",
                "qrloginfrom" to BaiduEndpoints.QRLOGIN_FROM,
                "gid" to gid,
            ),
            headers = passportHeaders(),
            timeoutMs = DEFAULT_TIMEOUT_MS,
        )
        // `getqrcode` 会下发 BAIDUID（实测），后续两跳要带回去。
        absorb(res.setCookies)

        if (res.status !in 200..299) {
            throw LoginException("认证服务返回 HTTP ${res.status}")
        }
        val json = res.json ?: throw LoginException("认证服务返回了无法解析的内容")
        val errno = BaiduMapper.asInt(json["errno"]) ?: 0
        if (errno == BaiduErrorCode.QR_FETCH_LIMIT) {
            throw LoginException("获取二维码过于频繁，请稍后再试")
        }
        if (errno != 0) throw LoginException("获取二维码失败（errno=$errno）")

        val sign = BaiduMapper.asString(json["sign"])?.takeIf { it.isNotEmpty() }
            ?: throw LoginException("认证服务没有返回二维码")
        val imgRaw = BaiduMapper.asString(json["imgurl"])?.takeIf { it.isNotEmpty() }
            ?: throw LoginException("认证服务没有返回二维码")

        Log.i(TAG, "百度已取到二维码（sign=${mask(sign)}，gid=$gid，Cookie 键=${jar.keys}）")
        return Session(
            sign = sign,
            imgUrl = normalizeImgUrl(imgRaw),
            gid = gid,
            createdAtMs = System.currentTimeMillis(),
        ).also { session = it }
    }

    /** 取二维码图片的原始字节。`null` 表示这次取不到（页面据此展示「点击重试」）。 */
    fun fetchQrImage(session: Session): ByteArray? {
        qrImage?.let { return it }
        return try {
            val bytes = http.getBytes(
                url = session.imgUrl,
                headers = passportHeaders(),
                maxBytes = 2 * 1024 * 1024,
            )
            // ⛔ 只缓存成功的结果：把 null 也缓存下来会让一次 CDN 抖动变成
            //    「二维码永远加载不出来」。
            qrImage = bytes
            bytes
        } catch (e: Exception) {
            Log.w(TAG, "百度二维码图片下载失败：${e.message}")
            null
        }
    }

    // ------------------------------------------------------------------
    // 第 2 跳：长轮询
    // ------------------------------------------------------------------

    fun poll(session: Session): Poll {
        val res = try {
            http.get(
                url = BaiduEndpoints.PASSPORT_HOST + BaiduEndpoints.UNICAST,
                query = linkedMapOf(
                    "channel_id" to session.sign,
                    "gid" to session.gid,
                    "tpl" to BaiduEndpoints.PRODUCT,
                    "_sdkFrom" to "1",
                    "apiver" to "v3",
                    "tt" to System.currentTimeMillis().toString(),
                    "callback" to "cb",
                ),
                headers = passportHeaders(withCookies = true),
                // 长轮询专用超时：服务端会挂 ~30s，20s 会每次「超时」。
                timeoutMs = POLL_TIMEOUT_MS,
            )
        } catch (e: Exception) {
            // ⛔ 超时 / 断网**不是失败**：长轮询本来就会挂住。
            Log.d(TAG, "百度扫码轮询网络未返回（按等待处理）：${e.message}")
            return Poll.Waiting
        }
        absorb(res.setCookies)

        if (res.status !in 200..299) {
            return Poll.Error("认证服务返回 HTTP ${res.status}", res.status)
        }
        val json = res.json ?: return Poll.Error("认证服务返回了无法解析的内容")
        val errno = BaiduMapper.asInt(json["errno"]) ?: 0
        val channel = parseChannelV(json["channel_v"])
            // 没有事件载荷（`errno:1` 就是「还没有事件」，不是错误）。
            ?: return Poll.Waiting

        return when (BaiduMapper.asString(channel["status"])) {
            "1" -> Poll.Scanned
            "0" -> {
                val v = BaiduMapper.asString(channel["v"])?.takeIf { it.isNotEmpty() }
                    ?: return Poll.Error("扫码回执不完整，请重新扫码")
                val u = BaiduMapper.asString(channel["u"]).orEmpty()
                Log.i(TAG, "百度扫码已确认（v=${mask(v)}）")
                Poll.Confirmed(v, u).also { confirmed = it }
            }
            "2" -> Poll.Cancelled
            else -> {
                if (errno != 0) Log.d(TAG, "百度扫码轮询 errno=$errno，继续等待")
                Poll.Waiting
            }
        }
    }

    // ------------------------------------------------------------------
    // 第 3~5 跳：换 BDUSS + 落地网盘域 + 补 STOKEN
    // ------------------------------------------------------------------

    fun exchange(confirmed: Poll.Confirmed): Result {
        // 主线：GET，**不带** loginVersion。
        val mainline = exchangeVia(
            path = BaiduEndpoints.BDUSS_LOGIN_MAINLINE,
            isPost = false,
            loginVersion = null,
            confirmed = confirmed,
        )
        if (mainline != null) {
            val panNames = settleOnPan(mainline.location)
            absorbNetdiskStoken()
            return Result(jar.toMap(), panNames)
        }

        Log.w(TAG, "百度主线换票未拿到 BDUSS，降级试风控分支（v4）")
        val risk = exchangeVia(
            path = BaiduEndpoints.QR_BDUSS_LOGIN,
            isPost = true,
            loginVersion = "v4",
            confirmed = confirmed,
        )
        if (risk != null) {
            val panNames = settleOnPan(risk.location)
            absorbNetdiskStoken()
            return Result(jar.toMap(), panNames)
        }

        throw LoginException("扫码已确认，但换取登录凭证失败（服务端没有下发 BDUSS）")
    }

    private class ExchangeOutcome(val setCookie: List<String>, val location: String?)

    private fun exchangeVia(
        path: String,
        isPost: Boolean,
        loginVersion: String?,
        confirmed: Poll.Confirmed,
    ): ExchangeOutcome? {
        val now = System.currentTimeMillis()
        // `u` 是落点。为空时退回客户端写死的 `https://pan.baidu.com/` ——
        // 空串会让服务端按「无落点」签发，可能拿到网盘侧用不了的凭证。
        val u = confirmed.u.takeIf { it.isNotEmpty() } ?: BaiduEndpoints.POST_LOGIN_URL
        val query = linkedMapOf(
            "tt" to now.toString(),
            "bduss" to confirmed.v,
            "u" to u,
            "qrcode" to "1",
            "tpl" to BaiduEndpoints.PRODUCT,
        )
        if (isPost) {
            query["v"] = now.toString()
            if (loginVersion != null) query["loginVersion"] = loginVersion
            query["maskId"] = ""
            query["fileId"] = ""
        }

        val res = if (isPost) {
            http.post(
                url = BaiduEndpoints.PASSPORT_HOST + path,
                query = query,
                headers = passportHeaders(withCookies = true),
            )
        } else {
            http.get(
                url = BaiduEndpoints.PASSPORT_HOST + path,
                query = query,
                headers = passportHeaders(withCookies = true),
                // ⛔ 不跟重定向：凭证在 3xx 的 Set-Cookie 里。
                followRedirects = false,
            )
        }

        // 2xx 与 3xx 都接受（服务端可能用 302 下发 Cookie）。
        val acceptable = res.status in 200..399
        absorb(res.setCookies)
        val cookies = parseSetCookies(res.setCookies)
        Log.i(
            TAG,
            "百度换票（$path，${if (isPost) "POST" else "GET"}）→ HTTP ${res.status}，" +
                "SetCookie 键=${cookies.keys}",
        )
        if (!acceptable) return null

        // 业务判据：`errInfo.no == 0 || data.errno == 0`，**外加顶层 errno == 0**
        // （主线用顶层 errno，只认前两个会把无效回执误判成失败）。
        res.json?.let { json ->
            val errInfo = BaiduMapper.nested(json, "errInfo")
            val no = BaiduMapper.asInt(errInfo?.get("no"))
            val data = BaiduMapper.nested(json, "data")
            val dataErrno = BaiduMapper.asInt(data?.get("errno"))
            val topErrno = BaiduMapper.asInt(json["errno"])
            val ok = no == 0 || dataErrno == 0 || topErrno == 0
            if (!ok) {
                if (no == BaiduErrorCode.QR_RISK_CONTROL ||
                    dataErrno == BaiduErrorCode.QR_RISK_CONTROL ||
                    topErrno == BaiduErrorCode.QR_RISK_CONTROL
                ) {
                    throw LoginException("百度账号触发了安全验证，请先在手机百度网盘 App 内确认后重试")
                }
                Log.w(TAG, "百度换票（$path）业务失败：no=$no data.errno=$dataErrno errno=$topErrno")
                return null
            }
        }

        if (cookies["BDUSS"].isNullOrEmpty()) {
            Log.w(TAG, "百度换票（$path）未下发 BDUSS，拿到键=${cookies.keys}")
            return null
        }
        return ExchangeOutcome(res.setCookies, res.location)
    }

    /**
     * 第 4 跳：把会话**落地**到网盘域（客户端是 WebView 跟着 302 跳）。
     *
     * ⛔ 自己逐跳走：自动跟随只留最后一跳的头，会把中途每一跳的
     * `Set-Cookie` 全丢掉 —— 而我们要的恰恰是它们。
     * ⛔ 失败**只记日志**，绝不让整次登录失败（它是加分项，不是前提）。
     */
    private fun settleOnPan(location: String?): List<String> {
        var url = settleTarget(location)
        val visited = HashSet<String>()
        val collected = LinkedHashSet<String>()

        for (hop in 0 until MAX_SETTLE_HOPS) {
            if (!visited.add(url)) {
                Log.d(TAG, "百度落地网盘域出现环（$url），停止")
                break
            }
            val res = try {
                http.get(
                    url = url,
                    headers = passportHeaders(withCookies = true) + mapOf(
                        // 这一步是**页面导航**而不是 XHR（客户端是 WebView 跳转）。
                        "Accept" to BaiduEndpoints.PAGE_ACCEPT,
                        "Referer" to url,
                    ),
                    followRedirects = false,
                )
            } catch (e: Exception) {
                Log.w(TAG, "百度落地网盘域异常（不影响登录）：${e.message}")
                break
            }
            val added = parseSetCookies(res.setCookies)
            absorb(res.setCookies)
            collected.addAll(added.keys)
            if (added.isEmpty() && res.status !in 300..399) break
            val next = redirectTarget(res, url) ?: break
            url = next
        }
        Log.i(TAG, "百度落地网盘域：新增 Cookie 键=$collected")
        return collected.toList().sorted()
    }

    /** 第 5 跳：换 netdisk 专用 STOKEN（能换到就覆盖，换不到沿用换票下发值）。 */
    private fun absorbNetdiskStoken() {
        val bduss = jar["BDUSS"] ?: jar["BDUSS_BFESS"] ?: return
        val ptoken = jar["PTOKEN"] ?: jar["PTOKEN_BFESS"]
        try {
            val res = http.get(
                url = BaiduEndpoints.PASSPORT_HOST + BaiduEndpoints.STOKEN_AUTH,
                query = linkedMapOf(
                    "bduss" to bduss,
                    "ptoken" to (ptoken ?: ""),
                ),
                headers = passportHeaders(),
            )
            if (res.status !in 200..299) {
                Log.w(TAG, "百度 netdisk STOKEN 换取 HTTP ${res.status}，沿用现有值")
                return
            }
            val token = netdiskStokenOf(res.json)
            if (token.isNullOrEmpty()) {
                Log.w(TAG, "百度 netdisk STOKEN 未返回 netdisk 条目，沿用换票下发值")
                return
            }
            jar["STOKEN"] = token
            Log.i(TAG, "百度已换到 netdisk 专用 STOKEN（覆盖换票下发值）")
        } catch (e: Exception) {
            Log.w(TAG, "百度 netdisk STOKEN 换取异常（不影响登录）：${e.message}")
        }
    }

    // ------------------------------------------------------------------
    // 小工具
    // ------------------------------------------------------------------

    private fun passportHeaders(withCookies: Boolean = false): Map<String, String> {
        val out = linkedMapOf(
            "User-Agent" to BaiduEndpoints.PASSPORT_USER_AGENT,
            "Accept" to BaiduEndpoints.ACCEPT,
            "Accept-Language" to BaiduEndpoints.ACCEPT_LANGUAGE,
            "Referer" to BaiduEndpoints.PASSPORT_REFERER,
        )
        if (withCookies && jar.isNotEmpty()) {
            out["Cookie"] = BaiduEndpoints.cookieHeader(jar)
        }
        return out
    }

    private fun absorb(setCookieLines: List<String>) {
        jar.putAll(parseSetCookies(setCookieLines))
    }

    /** `channel_v` 是**被二次编码的 JSON 字符串**（`u` 还要再 URL 解码一次）。 */
    private fun parseChannelV(raw: Any?): Map<String, Any?>? {
        if (raw == null) return null
        if (raw is Map<*, *>) {
            @Suppress("UNCHECKED_CAST")
            return raw as? Map<String, Any?>
        }
        val s = (raw as? String)?.trim().orEmpty()
        if (s.isEmpty()) return null
        // ⛔ 复制成可变的：`parseJsonpObject` 给的是只读 `Map`，直接往里写
        //    `parsed["u"] = ...` 编译期就报「没有 set 运算符」。
        val parsed = (parseJsonpObject(s) ?: return null).toMutableMap()
        if (parsed.isEmpty()) return null
        val u = parsed["u"] as? String
        if (!u.isNullOrEmpty()) {
            parsed["u"] = try {
                URLDecoder.decode(u, "UTF-8")
            } catch (_: Exception) {
                u
            }
        }
        return parsed
    }

    /** 落点必须落在 `baidu.com` 域内（凭据不能被伪造的 Location 带去外站）。 */
    private fun settleTarget(location: String?): String {
        val raw = location?.trim()
        if (raw.isNullOrEmpty()) return BaiduEndpoints.POST_LOGIN_URL
        val absolute = if (raw.startsWith("http://") || raw.startsWith("https://")) {
            raw
        } else if (raw.startsWith("/")) {
            BaiduEndpoints.PASSPORT_HOST + raw
        } else {
            raw
        }
        return if (isBaiduHost(absolute)) absolute else BaiduEndpoints.POST_LOGIN_URL
    }

    private fun redirectTarget(res: BaiduResponse, currentUrl: String): String? {
        if (res.status !in 300..399) return null
        val raw = res.location?.trim()
        if (raw.isNullOrEmpty()) return null
        val absolute = when {
            raw.startsWith("http://") || raw.startsWith("https://") -> raw
            raw.startsWith("/") -> {
                val base = runCatching { java.net.URI(currentUrl) }.getOrNull()
                val origin = base?.let { "${it.scheme}://${it.host}" }
                    ?: BaiduEndpoints.PASSPORT_HOST
                origin + raw
            }
            else -> return null
        }
        if (!isBaiduHost(absolute)) {
            Log.w(TAG, "百度落点跳到非 baidu 域，拒绝跟随：$absolute")
            return null
        }
        return absolute
    }

    private fun isBaiduHost(url: String): Boolean {
        val host = runCatching { java.net.URI(url).host }.getOrNull() ?: return false
        return host == "baidu.com" || host.endsWith(".baidu.com")
    }

    private fun netdiskStokenOf(json: Map<String, Any?>?): String? {
        if (json == null) return null
        val data = BaiduMapper.nested(json, "data") ?: json
        val stokenList = data["stoken_list"]
        if (stokenList is Map<*, *>) {
            (stokenList["netdisk"] as? String)?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        if (stokenList is List<*>) {
            for (item in stokenList) {
                if (item is Map<*, *>) {
                    (item["netdisk"] as? String)?.takeIf { it.isNotEmpty() }?.let { return it }
                }
            }
        }
        return null
    }

    /** 补全 `imgurl` 的 scheme（三种形态都见过，见 PC 端文档）。 */
    private fun normalizeImgUrl(raw: String): String {
        if (raw.startsWith("http://") || raw.startsWith("https://")) return raw
        if (raw.startsWith("//")) return "https:$raw"
        return "https://$raw"
    }

    private fun newGid(): String {
        val rnd = SecureRandom()
        val buf = StringBuilder(32)
        repeat(16) { buf.append(String.format("%02x", rnd.nextInt(256))) }
        return buf.toString()
    }

    private fun mask(secret: String): String =
        if (secret.length <= 6) "***" else "${secret.take(4)}…${secret.takeLast(2)}"

    companion object {
        private const val TAG = "CloudCine"

        /** 取码 / 换票的超时。 */
        const val DEFAULT_TIMEOUT_MS = 20_000

        /** 长轮询超时（> 客户端看门狗 35s）。 */
        const val POLL_TIMEOUT_MS = 45_000

        /** 二维码有效期。 */
        const val SESSION_TTL_MS = 5L * 60 * 1000

        /** 落地网盘域最多跟几跳。 */
        private const val MAX_SETTLE_HOPS = 5
    }
}

/**
 * 只留**已知 + 必需**的 Cookie，外加落点那一跳新增的名字。
 *
 * ⛔ 落点收到的 `PANWEB` / `PANPSC` 等不在固定名单里，丢掉它们与「没做落地」
 * 等价 —— 网盘侧不认会话（`/api/account/uinfo` 回 `-6`）。
 */
fun filterBaiduCookiesForCredential(
    cookies: Map<String, String>,
    extraNames: List<String> = emptyList(),
): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    for (name in BaiduEndpoints.KNOWN_COOKIE_NAMES + extraNames) {
        val v = cookies[name]
        if (!v.isNullOrEmpty()) out[name] = v
    }
    for (name in BaiduEndpoints.ESSENTIAL_COOKIE_NAMES) {
        val v = cookies[name]
        if (!v.isNullOrEmpty()) out[name] = v
    }
    return out
}

/**
 * 百度 HTTP 的最小接口（为了**可单测**：`BaiduApi` / 本类都只依赖它）。
 *
 * 默认实现是 [BaiduHttp]；单测注入假实现即可覆盖取链路由、错误映射、
 * 扫码状态机等判据，不必起真网络。
 */
interface BaiduHttpLike {
    fun get(
        url: String,
        query: Map<String, String> = emptyMap(),
        headers: Map<String, String> = emptyMap(),
        followRedirects: Boolean = true,
        timeoutMs: Int = BaiduHttp.DEFAULT_TIMEOUT_MS,
    ): BaiduResponse

    fun post(
        url: String,
        query: Map<String, String> = emptyMap(),
        headers: Map<String, String> = emptyMap(),
        followRedirects: Boolean = false,
        timeoutMs: Int = BaiduHttp.DEFAULT_TIMEOUT_MS,
    ): BaiduResponse

    fun getBytes(
        url: String,
        headers: Map<String, String> = emptyMap(),
        maxBytes: Int = 8 * 1024 * 1024,
        timeoutMs: Int = BaiduHttp.DEFAULT_TIMEOUT_MS,
    ): ByteArray
}

/** 让 [BaiduHttp] 这个单例直接满足 [BaiduHttpLike]。 */
object BaiduHttpClient : BaiduHttpLike {
    override fun get(
        url: String,
        query: Map<String, String>,
        headers: Map<String, String>,
        followRedirects: Boolean,
        timeoutMs: Int,
    ): BaiduResponse = BaiduHttp.get(url, query, headers, followRedirects, timeoutMs)

    override fun post(
        url: String,
        query: Map<String, String>,
        headers: Map<String, String>,
        followRedirects: Boolean,
        timeoutMs: Int,
    ): BaiduResponse = BaiduHttp.post(url, query, headers, followRedirects, timeoutMs)

    override fun getBytes(
        url: String,
        headers: Map<String, String>,
        maxBytes: Int,
        timeoutMs: Int,
    ): ByteArray = BaiduHttp.getBytes(url, headers, maxBytes, timeoutMs)
}
