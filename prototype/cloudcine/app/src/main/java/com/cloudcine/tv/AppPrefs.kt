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

    /**
     * 多连接并行下载的**连接数**（`1` = 关掉并行，退回单连接）。
     *
     * 为什么默认 8：夸克对**单条连接**限速约 1 MiB/s（2026-10-06 实测：单连接
     * 稳态 1016~1022 KB/s、波动 <0.3%），而 4K 原画要 3.67 MiB/s ——
     * 单连接只有 27.8%，必然「播一会卡一会」。8 条连接实测 120 秒稳态
     * **8.03 MiB/s**（`8.03/8 = 1.004 MiB/s` 每连接，与单连接逐位吻合），
     * 对原画余量 2.19×。
     *
     * 保留 `1` 是为了能**现场做 A/B**：菜单里 1 ↔ 8 一换，「卡」与「不卡」
     * 是肉眼可见的差别 —— 这比任何日志都有说服力。
     */
    var parallelConnections: Int
        get() = sp.getInt(KEY_PARALLEL_CONNECTIONS, DEFAULT_PARALLEL_CONNECTIONS)
        set(v) = sp.edit().putInt(KEY_PARALLEL_CONNECTIONS, v).apply()

    companion object {
        /** 8 条是实测过的稳态点（见 [parallelConnections] 注释）。 */
        const val DEFAULT_PARALLEL_CONNECTIONS = 8

        /** 菜单里可选的档。 */
        val PARALLEL_CHOICES = intArrayOf(1, 2, 4, 8)

        private const val KEY_DEBUG_OVERLAY = "debug_overlay"
        private const val KEY_PARALLEL_CONNECTIONS = "parallel_connections"
    }
}
