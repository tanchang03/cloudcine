package com.cloudcine.tv

import android.content.Context

/**
 * 原型的**全局参数**（与登录态分开存）。
 *
 * ⛔ **不放进 `CredStore`**：那个类有 `clear()`（重新登录时整份清掉），
 *    把界面偏好混进去，一登出开关就跟着丢了 —— 而这是个「全局参数」，
 *    跟登不登录没关系。
 */
class AppPrefs(context: Context) {

    private val sp = context.applicationContext
        .getSharedPreferences("cloudcine_prefs", Context.MODE_PRIVATE)

    /**
     * 左上角那块调试浮层（帧率 / CPU / 内存 / 按键延迟）。
     *
     * **默认关**：它是给「对照实验」用的，平时看片挡着画面。
     * 要看的时候按 MENU → 调试 → 开启，**跨影片、跨重启都记得**。
     */
    var debugOverlay: Boolean
        get() = sp.getBoolean(KEY_DEBUG_OVERLAY, false)
        set(v) = sp.edit().putBoolean(KEY_DEBUG_OVERLAY, v).apply()

    private companion object {
        const val KEY_DEBUG_OVERLAY = "debug_overlay"
    }
}
