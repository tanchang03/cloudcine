package com.cloudcine.tv.library

/**
 * 「点开这部作品，该播哪一条」的取舍规则 —— 与 PC 端
 * `lib/domain/services/play_target.dart` 的 `PlayTarget.resolve` **逐条同口径**。
 *
 * ## 它解决的是哪个问题
 *
 * 媒体库卡片点下去要**直接开始播**（VidHub / Infuse 一类的标准行为：
 * 用户点海报的意图是看片，不是先看一页简介）。但一个作品下面挂着的东西
 * 可能有很多种：电影有多个版本、剧集有几十条跨季、还有花絮与预告。
 *
 * 随便挑一条会踩两个坑：
 *   1. 挑到花絮 —— 用户点《流浪地球 2》看到 40 秒的预告片；
 *   2. 挑到第一集，而他已经看到第 20 集了 —— 每次都要手动翻回去。
 *
 * ## 为什么放在 `library/` 而不是 Activity 里
 *
 * 它要在**至少两处**用同一套口径（海报墙卡片、剧集列表的「继续」入口）。
 * 两处各写一份的话，「从海报墙点进去」和「从列表点进去」会落到不同的
 * 一集 —— 而这种不一致极难被发现。它是纯函数，所以可以直接单测。
 *
 * ## 输入契约
 *
 * [items] 必须**已按「季 → 部 → 集 → 名称」排序**（[LibraryDb.itemsForWork]
 * 的承诺）。这里不重排，是为了让排序规则只有一份实现。
 */
object PlayTarget {

    /**
     * 选出该播的那一条。作品下没有任何条目时返回 `null`。
     *
     * ⛔ **优先级顺序不能改**（与 PC 端一致）：
     *    ① 还留着续播点的那一集（最高优先 —— 用户点卡片最常见的意图就是
     *    「接着上次看」）→ ② 有播放记录但已看完的那一集 → ③ 第一条。
     */
    fun resolve(items: List<LibraryItem>): LibraryItem? {
        val playable = playable(items)
        if (playable.isEmpty()) return null
        if (playable.size == 1) return playable.first()

        // ① 「接着看」：最近播过、且**还留着续播点**的那一集。
        //
        // ⛔ 要求「还留着续播点」而不是「最近播过」：看完的那一集续播点会被
        //    清掉 —— 那种情况下从片头重播那一集并不是用户想要的。
        val withResume = playable.filter { (it.resumePositionMs ?: 0L) > 0L }
        if (withResume.isNotEmpty()) {
            // 拿不到播放时刻（老库、或位置是手工导入的）时退到列表顺序的
            // 最后一个，也就是集号最大的那一集 —— 比「列表第一个」更接近
            // 「他看到哪儿了」。
            return mostRecentlyPlayed(withResume) ?: withResume.last()
        }

        // ② 有播放记录、但那一集已经看完（续播点被清）→ 仍然回到那一集。
        //
        // ⛔ **不要去猜「下一集」**：`lastPlayedAt` 有值 + 没有续播点，既可能是
        //    「看完了」，也可能是「点开 3 秒就关了」。猜错会直接把用户丢到
        //    一集他根本没看过的内容上，而猜错的代价远大于「重看一集的开头」。
        mostRecentlyPlayed(playable)?.let { return it }

        // ③ 一集都没播过 → 第一集。
        return playable.first()
    }

    /**
     * 从候选里挑「最近播放」的那一条；全都没播过时返回 `null`。
     *
     * ⛔ 排序键是 `lastPlayedAt` 降序，**同一时刻时保留先出现的**（列表里
     *    更靠前的一集）—— 所以比较用严格大于。全都没播过时返回 null，
     *    而不是随 Map 迭代顺序抖动。
     */
    private fun mostRecentlyPlayed(candidates: List<LibraryItem>): LibraryItem? {
        var best: LibraryItem? = null
        var bestAt: Long? = null
        for (item in candidates) {
            val at = item.lastPlayedAt ?: continue
            if (bestAt == null || at > bestAt) {
                best = item
                bestAt = at
            }
        }
        return best
    }

    /**
     * 可播条目：优先正片；一个正片都没有（整组都是花絮）时退回全部。
     *
     * ⛔ **不做「正片为空就返回空」** —— 只有花絮的作品也该能点开，
     *    否则那些条目在媒体库界面上等于不存在。
     */
    private fun playable(items: List<LibraryItem>): List<LibraryItem> {
        val features = items.filter { !it.isSampleOrExtra }
        return features.ifEmpty { items }
    }
}
