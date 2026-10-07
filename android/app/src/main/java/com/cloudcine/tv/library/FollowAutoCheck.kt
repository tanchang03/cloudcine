package com.cloudcine.tv.library

/**
 * 自动追更检查的策略。
 *
 * 取值与 PC 端 `domain/services/follow_auto_check.dart` 的 `FollowAutoCheck`
 * **逐字一致**（`off` / `on_launch` / `every_6h`），因为它存在 `settings` 表的
 * `follow_auto_check` 键里、随 `.ccbak` 备份包跨端走 —— 在电脑上选了「关闭」，
 * 电视上不该还在偷偷发请求。
 *
 * ## 与「节流窗口」的分工
 *
 * 这个枚举回答「**什么时候想起来要检查**」，节流窗口回答「**检查得够不够密**」。
 * 两者不能互相替代：没有窗口，`ON_LAUNCH` 会在每次重启电视时都跑一遍；
 * 没有这个枚举，`OFF` 就表达不出来（窗口没法表达「永不」）。
 *
 * | 取值 | 启动时 | 定时 | 节流窗口 |
 * |---|---|---|---|
 * | [OFF] | 否 | 否 | — |
 * | [ON_LAUNCH]（默认） | 是 | 否 | 6 小时 |
 * | [EVERY_6H] | 是 | 每 6 小时 | 6 小时 |
 *
 * ⚠️ [ON_LAUNCH] 与 [EVERY_6H] 的窗口**相同**，差别只在定时器：前者在一次
 *    会话里只检查一次，后者会周期性检查。这不是笔误。
 *
 * ⚠️ 与 PC 端的一处**有意偏离**：设计文档给电视的启动检查窗口写的是
 *    **30 分钟**（电视常被反复唤醒，6 小时窗口会让「进媒体库」这个动作
 *    大多数时候什么都不做）。所以 [LibraryActivity] 的启动检查用
 *    `LAUNCH_WINDOW_SEC`，而不是这里的 [windowSec]。
 *    两个数字都只是「多久算一次」的取舍，不涉及任何数据语义。
 *
 * ## 手动入口无视这一切
 *
 * 用户点「检查追剧更新」时不看窗口、也不看这里是不是 [OFF]：他明确要求了。
 */
enum class FollowAutoCheck(val id: String, val label: String) {
    /** 不自动检查（手动入口仍然可用）。 */
    OFF("off", "关闭"),

    /** 启动时检查一次（受节流窗口约束）。 */
    ON_LAUNCH("on_launch", "启动时检查"),

    /** 启动时 + 每 6 小时各检查一次。 */
    EVERY_6H("every_6h", "每 6 小时检查");

    /**
     * 自动检查的节流窗口（秒）。`null` = 不自动检查。
     *
     * ⚠️ 手动入口**不要**用这个值做判断（见类文档最后一条）。
     */
    val windowSec: Long?
        get() = when (this) {
            OFF -> null
            ON_LAUNCH -> 6 * 3600L
            EVERY_6H -> 6 * 3600L
        }

    /** 是否要在会话里挂一个周期定时器。 */
    val runsOnTimer: Boolean get() = this == EVERY_6H

    companion object {
        /**
         * 「进媒体库」那一次启动检查用的窗口。
         *
         * ⛔ 与 [windowSec] 是两个数：电视常被反复唤醒（待机 → 进媒体库），
         *    6 小时的窗口会让绝大多数唤醒都什么都不做，用户会觉得「这功能
         *    根本没在跑」。30 分钟是「一天最多几十次轻量列目录」的量级。
         */
        const val LAUNCH_WINDOW_SEC = 30 * 60L

        /**
         * 解析设置值。
         *
         * ⛔ 判据**只写在这里一处**：`null`（老库没有这个键）、空串、写坏的
         *    值、将来被改名的取值，一律退回 [ON_LAUNCH]。在别处再写一遍
         *    `== "on_launch"` 只会多出一份会漂移的默认值真源 ——
         *    而漂移的后果是「用户在设置页选了关闭，重启之后又开始检查了」。
         */
        fun parse(raw: String?): FollowAutoCheck = when (raw) {
            OFF.id -> OFF
            EVERY_6H.id -> EVERY_6H
            else -> ON_LAUNCH
        }
    }
}
