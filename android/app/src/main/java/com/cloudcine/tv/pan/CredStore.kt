package com.cloudcine.tv.pan

import android.content.Context

/**
 * 登录态的**唯一落点**（按网盘分账号）。
 *
 * 只存 Cookie 字符串，不存账号密码、不做加密 —— 它落在 App 私有目录
 * （`shared_prefs`），靠 Android 的应用沙箱隔离，够用。
 * ⚠️ 若将来要过更高的安全要求，这里应换成 `EncryptedSharedPreferences`。
 *
 * ## ⛔ 「已登录」的判据按厂家分
 *
 * - 夸克：`__pus=` —— 空 Cookie 与「有一串但没登录」是两回事，后者可能是
 *   拿到了 `_UP_*` / `ctoken` 这类**跟网盘无关**的 Cookie（兑换接口会顺带回）。
 * - 百度：`BDUSS=` —— 同上，兑换会带回 `BAIDUID` / `H_PS_*` / `ZFY`，
 *   只有 `BDUSS` 等价于「网盘会话可用」。
 *
 * ## ⛔ 两家账号是**并存**的
 *
 * 库里 `media_items.provider` 早就分厂家了，所以电视端可以同时登录夸克与
 * 百度（扫描各扫各的，条目互不覆盖 —— `pruneMissingItems` 也按 provider
 * 过滤）。[activeProvider] 只决定「文件列表 / 扫描 / 追更现在操作谁」。
 */
class CredStore(context: Context) {

    private val sp = context.applicationContext
        .getSharedPreferences("cloudcine_cred", Context.MODE_PRIVATE)

    // ------------------------------------------------------------------
    // Cookie
    // ------------------------------------------------------------------

    /** 某个网盘的完整 `Cookie:` 头值。 */
    fun cookie(provider: String): String =
        sp.getString(cookieKey(provider), "").orEmpty()

    fun setCookie(provider: String, value: String) {
        sp.edit().putString(cookieKey(provider), value).apply()
    }

    /** 兼容旧调用（默认夸克）。 */
    var cookie: String
        get() = cookie(DriveProviders.QUARK)
        set(v) = setCookie(DriveProviders.QUARK, v)

    /** 夸克转码档的 m3u8 不带签名，鉴权全靠它。见 `PanApi.fetchPlayInfo`。 */
    var videoAuth: String
        get() = sp.getString(KEY_VIDEO_AUTH, "").orEmpty()
        set(v) = sp.edit().putString(KEY_VIDEO_AUTH, v).apply()

    // ------------------------------------------------------------------
    // 账号
    // ------------------------------------------------------------------

    /** 昵称，只在列表页标题栏显示，纯装饰。 */
    fun nickname(provider: String): String =
        sp.getString(nicknameKey(provider), "").orEmpty()

    fun setNickname(provider: String, value: String) {
        sp.edit().putString(nicknameKey(provider), value).apply()
    }

    var nickname: String
        get() = nickname(DriveProviders.QUARK)
        set(v) = setNickname(DriveProviders.QUARK, v)

    /** 某个网盘是否已登录。判据见类文档。 */
    fun loggedIn(provider: String): Boolean {
        val cookie = cookie(provider)
        if (cookie.isEmpty()) return false
        return cookie.contains("${essentialOf(provider)}=")
    }

    /** 兼容旧调用：等价于「夸克已登录」。 */
    val loggedIn: Boolean get() = loggedIn(DriveProviders.QUARK)

    /** 任意一家已登录（`MainActivity` 用它决定要不要先进登录页）。 */
    val anyLoggedIn: Boolean
        get() = loggedIn(DriveProviders.QUARK) || loggedIn(DriveProviders.BAIDU)

    /** 已登录的网盘列表（顺序固定：夸克在前）。 */
    fun loggedInProviders(): List<String> = listOf(
        DriveProviders.QUARK, DriveProviders.BAIDU,
    ).filter { loggedIn(it) }

    /**
     * 当前操作的网盘（文件列表 / 扫描 / 追更 / 封面）。
     *
     * 取值规则：存的那个**且已登录**就用它；否则退到「第一个已登录的」；
     * 一个都没登录时返回存的那个（默认夸克），登录页据此预选。
     */
    var activeProvider: String
        get() {
            val stored = sp.getString(KEY_ACTIVE, "").orEmpty()
            if (stored.isNotEmpty() && loggedIn(stored)) return stored
            loggedInProviders().firstOrNull()?.let { return it }
            return if (stored.isNotEmpty()) stored else DriveProviders.QUARK
        }
        set(v) {
            sp.edit().putString(KEY_ACTIVE, v).apply()
        }

    /** 发请求用的 Cookie —— 夸克要把 `Video-Auth` 拼进去（它不在登录 Cookie 里）。 */
    fun requestCookie(provider: String = DriveProviders.QUARK): String {
        val cookie = cookie(provider)
        if (provider != DriveProviders.QUARK) return cookie
        if (videoAuth.isEmpty()) return cookie
        if (cookie.contains("Video-Auth=")) return cookie
        return "$cookie; Video-Auth=$videoAuth"
    }

    // ------------------------------------------------------------------
    // 清理
    // ------------------------------------------------------------------

    /** 只清某一家（重新登录那一家时用）。 */
    fun clearProvider(provider: String) {
        val edit = sp.edit()
            .remove(cookieKey(provider))
            .remove(nicknameKey(provider))
        if (provider == DriveProviders.QUARK) edit.remove(KEY_VIDEO_AUTH)
        if (sp.getString(KEY_ACTIVE, "") == provider) edit.remove(KEY_ACTIVE)
        edit.apply()
    }

    /** 全清（两家一起退出）。 */
    fun clear() = sp.edit().clear().apply()

    private fun cookieKey(provider: String): String =
        if (provider == DriveProviders.QUARK) KEY_COOKIE else "cookie_$provider"

    private fun nicknameKey(provider: String): String =
        if (provider == DriveProviders.QUARK) KEY_NICK else "nickname_$provider"

    /** 会话必需 Cookie，缺它即视为未登录。 */
    private fun essentialOf(provider: String): String =
        if (provider == DriveProviders.BAIDU) "BDUSS" else "__pus"

    private companion object {
        const val KEY_COOKIE = "cookie"
        const val KEY_VIDEO_AUTH = "video_auth"
        const val KEY_NICK = "nickname"
        const val KEY_ACTIVE = "active_provider"
    }
}
