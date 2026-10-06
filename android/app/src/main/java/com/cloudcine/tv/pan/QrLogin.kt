package com.cloudcine.tv.pan

import android.util.Log
import java.net.URLEncoder

/**
 * 网盘**扫码登录**（CAS 流程）。
 *
 * 链路（与云影 `lib/data/auth/quark_qr_login.dart` 完全一致，那条路 2026-09-24
 * 真机跑通；本工程在 Mac 侧又复现了一次）：
 *
 * ```
 * 1. GET uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532
 * 2. token 装进二维码，手机 App 扫码并确认
 * 3. GET uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?token=…&client_id=532
 * 4. GET pan.quark.cn/account/info?st=<ticket>
 *      → 该响应的 Set-Cookie 里下发 __pus
 * ```
 *
 * ## 三个踩过的坑（照抄云影的结论，别重新试）
 *
 * - ⛔ **`client_id` 必须两端一致**：取票带了 `client_id`、轮询就必须带，
 *   两边都不带也行，**混着用会 `50004002 Token Not Found`**。
 * - ⛔ **第 4 跳不能用 `/cas/ajax/loginWithServiceTicket`**：那是给浏览器
 *   整页跳转用的旧 CAS 端点，AJAX 语义下只回 `ctoken`/`_UP_*`，
 *   **不下发账号 Cookie**。网页版的真实做法是直接 GET `/account/info?st=`。
 * - ⛔ **`50004001` 是「还没扫」的正常态**，不是错误。当失败处理会导致
 *   疯狂重取票，二维码永远停在初始状态。
 *
 * ## 关于 `__puus`
 *
 * `/account/info` 只给 `__pus`/`__kp`/`__kps`/`__ktd`/`__uid`，**不给 `__puus`**。
 * 实测本轮补跳首页也没拿到（只多了 `web-grey-id`）。
 * **不影响使用** —— 第一次调网盘接口时服务端会在 `Set-Cookie` 里下发，
 * [PanApi.absorbCookies] 会把它回填进 [CredStore]。
 */
class QrLogin(private val store: CredStore) {

    /** 一次扫码会话。 */
    data class Session(val token: String, val qrUrl: String)

    sealed class Poll {
        /** 还没人扫。**这是正常态**，继续轮询。 */
        object Waiting : Poll()

        /** 已确认，[ticket] 非空。 */
        data class Confirmed(val ticket: String) : Poll()

        /** token 失效（通常是 `client_id` 没收对，或超时）。 */
        data class Expired(val message: String) : Poll()

        data class Error(val message: String) : Poll()
    }

    /** 取一个二维码 token 并拼出二维码内容。 */
    fun start(): Session {
        val res = PanHttp.get(
            url = "$CAS$PATH_QR_TOKEN",
            query = mapOf("client_id" to CLIENT_ID),
            headers = casHeaders(),
        )
        val token = res.json
            ?.optJSONObject("data")
            ?.optJSONObject("members")
            ?.optString("token")
            .orEmpty()
        if (token.isEmpty()) {
            throw IllegalStateException(
                "认证服务没有返回二维码 token（status=${res.bizCode}）",
            )
        }
        Log.i(TAG, "已取到二维码 token（${token.take(6)}…）")
        return Session(token = token, qrUrl = buildQrUrl(token))
    }

    /**
     * 二维码里装的是**「端内登录确认页」地址**，不是登录页 ——
     * 手机扫了之后打开的是它。
     *
     * ⛔ `platform` 写 `mac`：与云影一致（网页端 `client_id=532` + `platform=mac`
     * 实测可扫）。桌面客户端的 `client_id` 是 `533`，**两个端不能混**。
     */
    private fun buildQrUrl(token: String): String = buildString {
        append(QR_LOGIN_PAGE)
        append("?uc_param_str=")
        append("&token=").append(URLEncoder.encode(token, "UTF-8"))
        append("&client_id=").append(CLIENT_ID)
        append("&uc_biz_str=").append(QR_BIZ_STR)
        append("&platform=mac")
    }

    /** 轮询一次。 */
    fun poll(session: Session): Poll {
        val res = runCatching {
            PanHttp.get(
                url = "$CAS$PATH_QR_TICKET",
                query = mapOf("token" to session.token, "client_id" to CLIENT_ID),
                headers = casHeaders(),
            )
        }.getOrElse { return Poll.Error("网络不可用：${it.message}") }

        if (res.status !in 200..299) return Poll.Error("认证服务返回 HTTP ${res.status}")

        // ⛔ 用 `bizCode` 而不是 `code`：CAS 端点的字段名是 `status`。
        return when (res.bizCode) {
            STATUS_OK -> {
                val ticket = res.json
                    ?.optJSONObject("data")
                    ?.optJSONObject("members")
                    ?.optString("service_ticket")
                    .orEmpty()
                if (ticket.isEmpty()) Poll.Error("已确认但没拿到 service_ticket")
                else Poll.Confirmed(ticket)
            }
            STATUS_NOT_SCANNED -> Poll.Waiting
            STATUS_TOKEN_NOT_FOUND -> Poll.Expired(res.message)
            else -> Poll.Error("未预期的业务码 status=${res.bizCode} ${res.message}")
        }
    }

    /**
     * 票据 → 账号 Cookie。
     *
     * ⛔ 响应的 `Set-Cookie` 必须**自己解析**：这里**不能跟重定向**
     * （云影 `http_client.dart:52` 的注释：跟了重定向就拿不到 Set-Cookie）。
     */
    fun exchange(ticket: String): String {
        val res = PanHttp.get(
            url = ACCOUNT_INFO,
            query = mapOf("st" to ticket),
            headers = casHeaders(),
        )
        if (res.status !in 200..299) throw IllegalStateException("兑换票据返回 HTTP ${res.status}")

        val json = res.json
        if (json != null && !json.optBoolean("success", true)) {
            throw IllegalStateException("票据兑换被拒绝：${res.message}")
        }

        val cookies = LinkedHashMap<String, String>()
        for (line in res.setCookies) {
            val semi = line.indexOf(';')
            val pair = if (semi < 0) line else line.substring(0, semi)
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            val k = pair.substring(0, eq).trim()
            val v = pair.substring(eq + 1).trim()
            if (k.isNotEmpty() && v.isNotEmpty()) cookies[k] = v
        }
        Log.i(TAG, "兑换 /account/info → HTTP ${res.status} cookie 键=${cookies.keys.sorted()}")

        // ⛔ `__pus` 是硬必需：没有它等于没登录。
        val pus = cookies["__pus"]
        if (pus.isNullOrEmpty()) {
            throw IllegalStateException("票据兑换未返回会话凭证（__pus）")
        }

        // 只留已知 + 必需项：兑换会顺带回 `_UP_*` / `ctoken` 这类与网盘无关的
        // 凭据，全带上只会让日志更难读（且它们对直链没有帮助）。
        val keep = listOf("__pus", "__puus", "__kuus", "__uid", "__kp", "__kps", "__ktd", "__kui")
        val header = keep.mapNotNull { k -> cookies[k]?.let { "$k=$it" } }.joinToString("; ")
        store.cookie = header
        Log.i(TAG, "登录完成，落库 Cookie 键=${header.split("; ").map { it.substringBefore('=') }}")
        return header
    }

    private fun casHeaders(): Map<String, String> = mapOf(
        "Accept" to PanHttp.ACCEPT,
        "User-Agent" to PanHttp.UA,
        "Referer" to PanHttp.REFERER,
    )

    companion object {
        private const val TAG = "CloudCine"

        const val CAS = "https://uop.quark.cn"
        const val PATH_QR_TOKEN = "/cas/ajax/getTokenForQrcodeLogin"
        const val PATH_QR_TICKET = "/cas/ajax/getServiceTicketByQrcodeToken"
        const val ACCOUNT_INFO = "https://pan.quark.cn/account/info"

        /** 网页端的 `client_id`。桌面客户端是 `533`，别混。 */
        const val CLIENT_ID = "532"

        /** 二维码里装的「端内登录确认页」。 */
        const val QR_LOGIN_PAGE = "https://su.quark.cn/4_eMHBJ"

        /** 照抄桌面客户端的 `uc_biz_str`：只影响确认页长相，与取票无关。 */
        const val QR_BIZ_STR =
            "S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401" +
                "%7COPT%3ABACK_BTN_STYLE%400"

        const val STATUS_OK = 2000000
        const val STATUS_NOT_SCANNED = 50004001
        const val STATUS_TOKEN_NOT_FOUND = 50004002
    }
}
