package com.cloudcine.tv.library

/**
 * 「续播点」的取舍判据 —— 与 PC 端 `lib/domain/services/playback_resume.dart`
 * **逐条同口径**。
 *
 * ## 它管两件事
 *
 * 1. 多小的位置**不值得续**（[minResumeMs]）；
 * 2. 多接近片尾才算**看完了**（[isFinished]）—— 看完了要把续播点**清掉**，
 *    而不是留着。
 *
 * ## ⛔ 为什么「清掉」比「留着」重要
 *
 * 留着的后果不是「多续一次」，是**用户以为片子坏了**：他下次打开会直接从
 * 「还差一分钟」开始，看两秒就出字幕 —— 而界面上没有任何东西告诉他
 * 「这一集你已经看完了」。PC 端为此专门写过注释，两边是同一个坑。
 *
 * ## ⛔ 为什么判不了的时候要当「没看完」
 *
 * 续播点是用户自己攒出来的。误判成「看完了」会把他的进度清掉，
 * 代价比多续一次大得多 —— 所以时长未知、或片子比尾巴还短时，
 * [finishedThreshold] 一律返回 `null`，调用方当没看完。
 */
object PlaybackResume {

    /**
     * 小于这个位置不值得续（毫秒）—— 当作没看过。
     *
     * 5 秒是个折中：进度按 10 秒整点上报，所以真实存下来的位置会是
     * 0 / 10 / 20…，而「> 0」本来就意味着「至少看了十秒」。留 5 秒只是
     * 让规则在**将来把上报粒度调细**之后依然成立，也顺手挡掉「误触一下就关」。
     */
    const val MIN_RESUME_MS = 5_000L

    /** 「看完了」的最小尾巴长度。 */
    private const val FINISHED_TAIL_MS = 2 * 60 * 1_000L

    /** 「看完了」的尾巴占全片比例。 */
    private const val FINISHED_RATIO = 0.02

    /**
     * 「已看完」的位置阈值；判不了返回 `null`。
     *
     * 两种判不了的情况都返回 `null` 而不是 0：
     *   * 时长未知（网盘没给、还没解析出来）—— 拿不到分母；
     *   * 片子比尾巴还短（比如 3 秒的自检视频）—— 那样任何位置都会被判成
     *     「看完了」，等于把续播功能关掉。
     *
     * ⛔ 尾巴取**比例与固定值中的较大者**：短片（几分钟的花絮）用两分钟太宽，
     *    长片（三小时的电影）用两分钟又太窄，所以两条一起用。
     */
    fun finishedThreshold(totalMs: Long): Long? {
        if (totalMs <= 0L) return null
        val byRatio = (totalMs * FINISHED_RATIO).toLong()
        val tail = maxOf(byRatio, FINISHED_TAIL_MS)
        val threshold = totalMs - tail
        if (threshold <= 0L) return null
        return threshold
    }

    /** 这个位置算不算「已经看完了」。时长未知时一律 `false`。 */
    fun isFinished(positionMs: Long, totalMs: Long): Boolean {
        if (positionMs <= 0L) return false
        val threshold = finishedThreshold(totalMs) ?: return false
        return positionMs >= threshold
    }

    /**
     * 这个位置值不值得存成续播点。
     *
     * ⛔ 必须同时看 `totalMs`：位置已经进到「看完」区间时，存下去的等于
     *    「下次从差一分钟开始」，那正是要清掉的情况 —— 所以这里直接返回
     *    `false`，让调用方 `saveResumePosition(null)`。
     */
    fun worthKeeping(positionMs: Long, totalMs: Long): Boolean =
        positionMs >= MIN_RESUME_MS && !isFinished(positionMs, totalMs)
}
