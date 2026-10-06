package com.cloudcine.tv

/**
 * 「连续快进」的**纯计算层**：待提交目标该怎么累加、怎么夹。
 *
 * ## 为什么单独抽出来
 *
 * 遥控器方向键是**自动重复**的（按住约 20 次/秒）。这些按键**不能**每个都
 * 真发一次 `seekTo` —— 2026-10-06 真机实测，一次拖拽 2 秒内发起 28 次 seek：
 *
 *   * **卡顿、不跟手**：每次 `seekTo` 都要拆掉当前 load、重开数据源、
 *     重建解码管线，20 次/秒地拆建，画面根本来不及出；
 *   * **OOM 崩溃**：每次重开数据源都新建一个 `ParallelRangeReader`，
 *     它一次性分配 `8 × 2 MiB = 16 MiB`，堆被打到 `192MB/192MB` 且
 *     GC `freed 0(0B)`（全部强可达）⇒ `OutOfMemoryError`。
 *
 * 所以按键只累加「待提交目标」（UI 立刻跟手），真跳转由防抖后**只发一次**。
 * 累加与夹取这段算术是本文件唯一的职责 —— 抽成纯函数才能被单测覆盖，
 * 而它恰好有两个**很容易写错、又不会报错**的点：
 *
 * ⛔ **基准必须是「待提交目标」而不是 `currentPosition`**。连续按右键时
 *    播放器位置还停在老地方（上一次的 seek 还没提交），拿它累加会让
 *    「按 10 次右键只走 10 秒」—— 表现是「按了没反应」，很难查。
 *
 * ⛔ **时长未知时不能拿 -1 去夹**。`Player.duration` 在 `C.TIME_UNSET`
 *    （`-1`）或未就绪时是非正数，若直接 `coerceIn(0, -1)` 会抛
 *    `IllegalArgumentException`（`min > max`）—— 崩在一个纯算术上。
 */
object SeekPlan {

    /** `pendingMs` 用这个值表示「没有待提交的跳转」。 */
    const val NO_PENDING = -1L

    /**
     * 一次按键之后的待提交目标（毫秒）。
     *
     * @param pendingMs  当前待提交目标；[NO_PENDING] = 没有
     * @param currentMs  播放器当前位置（仅在 [pendingMs] 为 [NO_PENDING] 时作基准）
     * @param deltaMs    本次按键的步进（`+10_000` = 快进 10 秒，可为负）
     * @param durationMs 媒体总时长；**`<= 0` 表示还不知道**（不做上界夹取）
     * @return 夹到 `[0, durationMs]` 之后的新目标
     */
    fun step(pendingMs: Long, currentMs: Long, deltaMs: Long, durationMs: Long): Long {
        val base = if (pendingMs > NO_PENDING) pendingMs else currentMs
        val upper = if (durationMs > 0L) durationMs else Long.MAX_VALUE
        val raw = base + deltaMs
        // ⛔ 溢出兜底。真实片长到不了会让 Long 溢出的量级，但这条判断只要
        //    两行，而一旦真溢出就是「跳到一个天文数字」这种莫名其妙的故障。
        if (deltaMs > 0L && raw < base) return upper
        if (deltaMs < 0L && raw > base) return 0L
        return raw.coerceIn(0L, upper)
    }

    // ------------------------------------------------------------------
    // 加速加成
    // ------------------------------------------------------------------

    /**
     * 按住快进时的**加速倍率**：按住越久，每一步跨得越多。
     *
     * ## 为什么需要它
     *
     * 遥控器方向键的自动重复约 20 次/秒，基础步进 10 秒 ⇒ 每按一秒只走
     * **200 秒**。一部 2 小时的片子要按住 **36 秒**才到底 —— 电视上这是个
     * 很折磨人的操作（而且中途手一抖就前功尽弃）。
     *
     * ## 为什么不能一步到位给个大倍率
     *
     * 用户的原话是「不要太快，否则没有反应时间就拖完」。所以设计成
     * **前 2 秒严格 ×1** —— 那 2 秒是留给「我要精确落在这里」的：
     * 40 次按键 × 10 秒 = 400 秒的调整范围，落点精度仍是 10 秒。
     * 之后才逐级加速。
     *
     * 按 20 次/秒估算的累计效果（2 小时片长）：
     * ```
     * 0~2s  ×1  →   400s
     * 2~4s  ×2  →  1200s
     * 4~6s  ×4  →  2800s
     * 6~9s  ×8  →  7600s  ← 已越过 2 小时，约 9 秒到底
     * 9s+   ×12
     * ```
     *
     * ⛔ 档位表**故意写死在纯函数里**（不读配置）：它是手感的一部分，
     *    跟着单测一起锁定；改它必须同时改 [SeekPlanTest] 里那条
     *    「前 2 秒必须不加速」的断言。
     */
    fun multiplier(holdMs: Long): Int = when {
        holdMs < 2_000L -> 1
        holdMs < 4_000L -> 2
        holdMs < 6_000L -> 4
        holdMs < 9_000L -> 8
        else -> 12
    }

    /**
     * 把基础步进按 [multiplier] 放大。
     *
     * ⛔ **符号必须原样保留**：快退传进来的是负数，乘法天然保号，
     *    但别在这里做任何 `abs()`/夹取 —— 那会把「往回拖」变成「往前拖」。
     */
    fun acceleratedDelta(baseDeltaMs: Long, holdMs: Long): Long =
        baseDeltaMs * multiplier(holdMs)
}
