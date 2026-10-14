package com.cloudcine.tv.library

/**
 * 一个「片头区间」。
 *
 * 精度只到秒级：跳过片头本来就是「别让我看这 90 秒」，差 0.3 秒没有意义。
 *
 * ⛔ 与 PC 端 `lib/domain/services/intro_marker.dart` 的 `IntroMarker` 同源。
 */
data class IntroMarker(val startMs: Long, val endMs: Long) {
    val lengthMs: Long get() = endMs - startMs

    /**
     * 区间是否成立。
     *
     * ⚠️ **每个使用点都必须先过这一关**。反过来的区间（`end <= start`）不会
     * 报错，只会让「跳过片头」变成一次**向后跳** —— 用户看到的是画面突然倒回
     * 片头，然后卡在那儿，比不跳糟得多。
     */
    val isValid: Boolean get() = endMs > startMs

    companion object {
        /**
         * 从数据库里的毫秒值构造。
         *
         * 任何一个为 `null` / 非正数 / 区间不成立 → `null`（＝「这一部没有片头
         * 标记」）。把「半条标记」（只标了起点没标终点）也当没有：半个区间没法跳。
         */
        fun fromMilliseconds(startMs: Long?, endMs: Long?): IntroMarker? {
            if (startMs == null || endMs == null) return null
            if (startMs < 0L || endMs <= 0L) return null
            val marker = IntroMarker(startMs, endMs)
            return if (marker.isValid) marker else null
        }
    }
}

/**
 * 「现在该不该跳片头」的纯函数判据。
 *
 * ⛔ 与 PC 端 `IntroSkip.shouldSkip` 同源。
 */
object IntroSkip {
    /**
     * @param minRemainingMs 距终点还剩不到这么多就不跳了 —— 否则一次跳转
     *   几乎不移动画面，只让进度条抖一下。
     */
    fun shouldSkip(
        positionMs: Long,
        marker: IntroMarker?,
        skipped: Boolean,
        minRemainingMs: Long = 1_000L,
    ): Boolean {
        if (marker == null || !marker.isValid) return false
        if (skipped) return false
        if (positionMs <= 0L) return false
        if (positionMs < marker.startMs) return false
        if (positionMs >= marker.endMs - minRemainingMs) return false
        return true
    }
}

/**
 * **片尾偏移**的取值链与落点换算（纯函数，无状态）。
 *
 * ## 与片头的关系
 *
 * 片头那边把「手标 > 学习」这条链放在 [IntroSession.marker] 里，因为片头还有
 * 「跳过」这个状态要一起管。片尾没有区间、只有一个偏移，也不需要 `skipped`
 * 那样的状态，所以链单独放在这里。
 *
 * ⛔ 两条链必须**同形**（都是 `手标 ?: 学习`）。各写各的话迟早漂移成
 *    「片头认手标、片尾只认学习」—— 而用户完全看不出是哪一层在生效。
 *
 * ## 为什么是「距末尾偏移」而不是绝对时间
 *
 * 各集片长不同（正片 45 分钟、特辑 60 分钟），绝对时间跨集不可比，而
 * 「离结尾还有多久开始是片尾」是稳定的。落点一律用 `片长 - 偏移` **现算**。
 */
object OutroSkip {
    /**
     * 生效的片尾偏移：**手标优先，学习兜底**。
     *
     * 非正数一律当「没标 / 没学过」：偏移 ≤ 0 意味着片尾从片长那一刻才开始，
     * 也就是「没有片尾」。与 [IntroMarker.fromMilliseconds] 对非正数的口径一致。
     *
     * @return 两个都是 `null` / 非正数时返回 `null`（＝不跳也不提示）。
     */
    fun effectiveOffsetMs(manualMs: Long?, learnedMs: Long?): Long? {
        val manual = manualMs?.takeIf { it > 0L }
        if (manual != null) return manual
        return learnedMs?.takeIf { it > 0L }
    }

    /**
     * 片尾起点落点（`durationMs - offsetMs`）。
     *
     * @return 没偏移、时长未知、或算出来 ≤ 0 时返回 `null`。
     *   ⛔ 算出来 ≤ 0 说明偏移比片长还大 —— 数据坏了（比如换了一集更短的）。
     *      返回 `null` 就是「不跳也不提示」，比跳到 0 秒好得多。
     */
    fun startMs(durationMs: Long, offsetMs: Long?): Long? {
        val offset = offsetMs?.takeIf { it > 0L } ?: return null
        if (durationMs <= 0L) return null
        val start = durationMs - offset
        return if (start > 0L) start else null
    }
}

/**
 * **一次播放**里的片头状态。
 *
 * ## 与 PC 端的差异（有意为之）
 *
 * PC 端还有一层「文件章节」：mpv 能读 `chapter-list`，那是**发布者标的**、
 * 与这一集的实际内容严格对应，所以它排在手标与学习之前。
 *
 * ⛔ Android 端**读不到章节** —— Media3 / ExoPlayer 不暴露容器章节
 *    （`MediaMetadata` 里没有 chapter 字段）。所以这边的取值链只有两级：
 *
 * ```
 * 手标 > 学习
 * ```
 *
 * 这也让「学习」在电视上的价值远大于 PC 端：网盘上的剧集绝大多数没有章节，
 * 而用户又不会一集一集去手标。
 *
 * ## 生命周期
 *
 * 一个实例对应**一条流**。换集 / 换清晰度 / 重新取链都要 [reset]。
 */
class IntroSession(
    private var manual: IntroMarker? = null,
    private var learned: IntroMarker? = null,
    private var enabled: Boolean = true,
) {
    private var skipped = false

    /** 设置里那一项。关掉时一次都不跳。 */
    val isEnabled: Boolean get() = enabled

    /** 用户手标的那一份（UI 要靠它决定「清除标记」这一项显不显示）。 */
    val manualMarker: IntroMarker? get() = manual

    /** 学习出来的那一份（UI 用它显示「这是自动学的」）。 */
    val learnedMarker: IntroMarker? get() = learned

    /**
     * 当前生效的区间：**手标优先，学习兜底**。
     *
     * 顺序不能反。手标是用户明确指定的；学习是**推断**出来的。推断压过明确
     * 指定，会出现「我明明标过，它却按自己学的跳」—— 而用户完全没有办法知道
     * 是哪一层在生效。
     */
    val marker: IntroMarker? get() = manual ?: learned

    /** 生效的那一份是不是**学习**出来的。 */
    val isFromLearned: Boolean get() = manual == null && learned != null

    /** 本次流是否已经跳过片头。 */
    val hasSkipped: Boolean get() = skipped

    /** 换一条流（换集 / 切清晰度 / 重开）时归零。 */
    fun reset(
        manual: IntroMarker? = null,
        learned: IntroMarker? = null,
        enabled: Boolean = true,
    ) {
        this.manual = manual
        this.learned = learned
        this.enabled = enabled
        this.skipped = false
    }

    /**
     * 这次播放结束了（播放器停止 / 播放页退出）。
     *
     * 与 [reset] 的区别：**保留**手标区间与开关。它们是「这一部作品的播放
     * 偏好」，与「这次播放结束了」无关 —— 一起清掉会让「退出播放页再进来」
     * 第一次不跳片头。
     */
    fun endStream() {
        skipped = false
    }

    /**
     * 用户手标了片头区间（或取消标记）后同步进来。
     *
     * 标记变了就**重新给一次机会**（`skipped` 归零）：用户刚标完区间，紧接着
     * 的那次播放应当跳 —— 否则他会以为标记没生效，于是再标一次。
     */
    fun setManual(marker: IntroMarker?) {
        if (manual == marker) return
        manual = marker
        skipped = false
    }

    /**
     * 学习结果变了之后同步进来。
     *
     * 与 [setManual] 同一条理由：标记变了就**重新给一次机会** —— 否则用户看到
     * 的是「学出来了，但这一集不跳」，而他不知道要退出重进才生效。
     */
    fun setLearned(marker: IntroMarker?) {
        if (learned == marker) return
        learned = marker
        skipped = false
    }

    /**
     * 播放头到了该跳的位置就返回**要跳到的位置**，否则 `null`。
     *
     * ## 为什么返回目标位置而不是一个 bool
     *
     * 因为它同时把「这一次已经跳过」置位掉了。返回 bool 的话，调用方必须在
     * `seekTo` 之前记得自己置位 —— 而 `seekTo` 是一次异步往返，这期间位置流
     * 还会再报几条（都还在区间内），晚置位会连发好几次 seek，表现是画面往前
     * 窜、进度条乱跳。把置位收进这里，调用方就没有写错的机会。
     */
    fun takeSkipTarget(positionMs: Long): Long? {
        if (!enabled) return null
        val m = marker
        if (!IntroSkip.shouldSkip(positionMs, m, skipped)) return null
        skipped = true
        return m!!.endMs
    }
}
