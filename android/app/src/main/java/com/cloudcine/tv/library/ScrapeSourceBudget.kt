package com.cloudcine.tv.library

/**
 * 在线源的**预算** —— 「这个源还值得问吗」。
 *
 * ## 为什么批量刮削必须有它
 *
 * 手动刮削一次只点一下，源挂了用户当场就看见了。而扫描后的自动刮削是
 * **串行跑整库**的：库里 145 部作品，每一部都要问一遍。
 *
 * 电视上实测过的那种情况（2026-10-07）：TMDB 的官方地址被 DNS 污染，
 * 每个请求都挂到 **12 秒**超时。没有预算的话，一次自动刮削 =
 * 145 × 12s ≈ **29 分钟**，全程界面只显示「刮削 1/145」，用户会以为它卡死了
 * —— 而实际上它只是在等一个永远不会来的响应。
 *
 * ## 判据：**「慢 + 空」才算失败，「快 + 空」是正常的**
 *
 * 区分「源坏了」和「这片子源里没有」是这里唯一的技术难点，而两者在
 * `search` 的返回值上**长得一模一样**（都是空列表 —— 见
 * [MetadataScraper] 的失败语义）。可用的信号只剩**耗时**：
 *
 *   * **健康**的源几百毫秒就答了 —— 答「有」还是答「没有」都说明它还活着，
 *     连续失败计数**清零**；
 *   * **坏掉**的源会把超时跑满（[SLOW_MS] 以上）—— 那才是「问不动了」。
 *
 * 连续 [MAX_CONSECUTIVE_FAILURES] 次「慢 + 空」就把这个源摘掉，
 * 本次批量不再问它。**必须连续**：中间答上来一次就说明它只是那一条没收录。
 *
 * ## 为什么摘掉而不是整批中止
 *
 * 两个源是互补的（TMDB 管外语片、豆瓣管国产剧）。TMDB 连不上时豆瓣照样能用，
 * 整批中止等于把能刮的那一半也扔了。
 *
 * ⛔ 摘掉是**本次批量内**的状态，不落盘：反代地址修好、Cookie 补上之后，
 *    下一次自动刮削必须重新试。
 */
class ScrapeSourceBudget(
    private val maxConsecutiveFailures: Int = MAX_CONSECUTIVE_FAILURES,
    private val slowMs: Long = SLOW_MS,
) {

    private val failures = HashMap<String, Int>(4)

    /** `源 id → 展示名`。用 `LinkedHashMap` 让「被摘掉的源」按摘除顺序报出来。 */
    private val dropped = LinkedHashMap<String, String>(4)

    fun isDropped(sourceId: String): Boolean = dropped.containsKey(sourceId)

    /** 被摘掉的源的**展示名**（「TMDB」「豆瓣」），给用户看的。 */
    val droppedNames: List<String> get() = dropped.values.toList()

    val hasDropped: Boolean get() = dropped.isNotEmpty()

    /**
     * 记一次搜索结果。
     *
     * @param hit 这个源**给出了候选**（不要求候选能过闸门 —— 给出候选就说明它活着）。
     * @param elapsedMs 这一次 `search` 花了多久。
     * @return 本次调用**刚刚**把它摘掉了（调用方据此在进度里提一句）。
     */
    fun record(sourceId: String, displayName: String, hit: Boolean, elapsedMs: Long): Boolean {
        if (isDropped(sourceId)) return false
        if (hit || elapsedMs < slowMs) {
            failures[sourceId] = 0
            return false
        }
        val n = (failures[sourceId] ?: 0) + 1
        failures[sourceId] = n
        if (n < maxConsecutiveFailures) return false
        dropped[sourceId] = displayName
        return true
    }

    companion object {
        /**
         * 连续几次「慢 + 空」就摘掉。
         *
         * 定 3 而不是 1：一次网络抖动不该让整个源下线。代价是「源真的坏了」时
         * 前 3 部作品要白等 3 个超时（约 36 秒）—— 换来的是「不误杀」。
         */
        const val MAX_CONSECUTIVE_FAILURES = 3

        /**
         * 超过这个耗时且没结果，就算一次失败。
         *
         * 实测口径：健康的 TMDB / 豆瓣搜索在 **0.3~2 秒**内返回；而超时是 12 秒
         * （`TmdbScraper.PROBE_TIMEOUT_MS` 同量级）。取 8 秒是为了卡在两者之间
         * —— 慢到不可能是「正常的慢」，又没到超时。
         */
        const val SLOW_MS = 8_000L
    }
}
