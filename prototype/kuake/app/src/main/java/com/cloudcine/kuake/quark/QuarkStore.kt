package com.cloudcine.kuake.quark

import android.content.Context

/**
 * 登录态的**唯一落点**。
 *
 * 只存 Cookie 字符串，不存账号密码、不做加密 —— 原型要的是「能跑通、能对照」，
 * 不是把云影那套 `EncryptedFileSecretBackend` 重做一遍。
 *
 * ⛔ 判据用 `__pus=` 而不是 `isNotEmpty()`：空 Cookie 与「有一串但没登录」
 * 是两回事，前者只是没登录，后者可能是拿到了 `_UP_*` / `ctoken` 这类
 * **跟网盘无关**的 Cookie（兑换接口会顺带回一堆）。用 `__pus` 才等价于
 * 「网盘会话可用」。
 */
class QuarkStore(context: Context) {

    private val sp = context.applicationContext
        .getSharedPreferences("quark_proto", Context.MODE_PRIVATE)

    /** 完整的 `Cookie:` 头值。 */
    var cookie: String
        get() = sp.getString(KEY_COOKIE, "").orEmpty()
        set(v) = sp.edit().putString(KEY_COOKIE, v).apply()

    /** 转码档的 m3u8 不带签名，鉴权全靠它。见 [QuarkApi.playInfo]。 */
    var videoAuth: String
        get() = sp.getString(KEY_VIDEO_AUTH, "").orEmpty()
        set(v) = sp.edit().putString(KEY_VIDEO_AUTH, v).apply()

    /** 会员昵称，只在列表页标题栏显示，纯装饰。 */
    var nickname: String
        get() = sp.getString(KEY_NICK, "").orEmpty()
        set(v) = sp.edit().putString(KEY_NICK, v).apply()

    val loggedIn: Boolean get() = cookie.contains("$ESSENTIAL=")

    /** 发请求用的 Cookie —— 把 `Video-Auth` 拼进去（它不在登录 Cookie 里）。 */
    fun requestCookie(): String {
        if (videoAuth.isEmpty()) return cookie
        if (cookie.contains("Video-Auth=")) return cookie
        return "$cookie; Video-Auth=$videoAuth"
    }

    fun clear() = sp.edit().clear().apply()

    private companion object {
        const val KEY_COOKIE = "cookie"
        const val KEY_VIDEO_AUTH = "video_auth"
        const val KEY_NICK = "nickname"

        /** 会话必需 Cookie，缺它即视为未登录。 */
        const val ESSENTIAL = "__pus"
    }
}
