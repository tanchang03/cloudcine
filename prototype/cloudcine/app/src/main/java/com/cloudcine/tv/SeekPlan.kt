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
}
