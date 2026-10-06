package com.cloudcine.tv.library

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.util.UUID

/**
 * 这台设备的标识与显示名 —— 写进备份清单的 `deviceId` / `deviceName`。
 *
 * ## 为什么 `deviceId` 不能是随机数
 *
 * 它是 [BackupManifest.conflictsWith] 的唯一依据：**同一台设备永远不算冲突**
 * （自己先后备份两次，时间接近是常态）。每次启动都换一个随机 ID 的话，
 * 用户每次「刚备份完又同步」都会看到一个没有意义的冲突提示。
 *
 * 所以优先用 `Settings.Secure.ANDROID_ID`：它在同一台设备 + 同一个签名下
 * 是稳定的，且**不需要任何权限**（Android 8 起按签名隔离，正是我们要的粒度）。
 * 取不到时才退回一个持久化的随机 UUID。
 *
 * ⛔ 别用 `Build.SERIAL`：Android 10 起普通应用拿不到，返回值是 `unknown` ——
 *    那样所有设备会共用同一个 ID，「冲突检测」彻底失效。
 */
object DeviceIdentity {

    private const val PREFS = "cloudcine_device"
    private const val KEY_FALLBACK_ID = "device_id"

    fun id(context: Context): String {
        val androidId = runCatching {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        }.getOrNull()
        if (!androidId.isNullOrBlank() && androidId != "9774d56d682e549c") {
            // 9774d56d682e549c 是早期 ROM 的著名「同一台设备」默认值，
            // 见到它说明这个值不可信，宁可退回 UUID。
            return "tv-$androidId"
        }
        val sp = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        sp.getString(KEY_FALLBACK_ID, null)?.let { return it }
        val generated = "tv-${UUID.randomUUID()}"
        sp.edit().putString(KEY_FALLBACK_ID, generated).apply()
        return generated
    }

    /**
     * 设备名。**只用于展示**（「这份备份来自 小米电视」），不参与任何判定 ——
     * 所以 `Build.MODEL` 取不到时给个「Android TV」就够了，不值得为它做兜底存储。
     */
    fun name(): String = Build.MODEL?.trim()?.takeIf { it.isNotEmpty() } ?: "Android TV"
}
