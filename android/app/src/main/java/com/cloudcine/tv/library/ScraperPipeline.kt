package com.cloudcine.tv.library

import android.util.Log

/**
 * 刮削流水线 —— 向所有启用的源要候选，**按源的优先级拼接**。
 *
 * ## 为什么是「拼接」而不是「竞速」
 *
 * PC 端的自动刮削是「并发起跑、按优先级取第一个成功的」（只需要一个答案）。
 * 手动刮削是**用户要自己挑**，所以每个源的候选都必须给出来，一个都不丢。
 *
 * ## 为什么串行
 *
 * 豆瓣的额度按**搜索词**计（匿名约 10 个），并发起跑会让两个源同时消耗额度，
 * 而手动刮削一次只点一下，量很小 —— 省那几百毫秒不值得多烧一个额度。
 *
 * ## 源顺序
 *
 * 与 PC 端一致：`[TMDB, 豆瓣]`。⛔ 但**顺序不影响可用性** —— 没配 API Key /
 * 反代时 [MetadataScraper.enabled] 为 `false`，那个源自然一个候选都不产出，
 * 列表里就只剩豆瓣。配了反代的用户则能同时看到两个源的候选。
 */
class ScraperPipeline(val scrapers: List<MetadataScraper>) {

    /**
     * 当前**能出候选**的源（已启用）。UI 用它渲染「只在某个源里搜」的选择器。
     *
     * ⛔ 不可用的源不出现在这里 —— 让用户能选中一个必然返回空的源，比不给这个
     *    选项更让人困惑。
     */
    val availableSources: List<Pair<String, String>>
        get() = scrapers.filter { it.enabled }.map { it.id to it.displayName }

    /** 按 id 查展示名。找不到返回 `null`（UI 那边用 `?: source` 兜底）。 */
    fun displayNameOf(sourceId: String): String? =
        scrapers.firstOrNull { it.id == sourceId }?.displayName

    /**
     * 搜候选。
     *
     * [sourceId] 非空时**只搜那一个源** —— 用户在刮削页选了「只在豆瓣搜」时，
     * 没必要把 TMDB 的额度也花掉。
     *
     * ⛔ 一个源搜挂了**不该让整个列表空掉** —— 其他源的结果照样有用。
     */
    fun search(query: ScrapeQuery, sourceId: String? = null): List<ScrapeCandidate> {
        val out = ArrayList<ScrapeCandidate>(24)
        for (s in scrapers) {
            if (!s.enabled) continue
            if (sourceId != null && s.id != sourceId) continue
            val found = try {
                s.search(query)
            } catch (t: Throwable) {
                Log.w(TAG, "${s.id} 候选搜索失败，跳过：${t.message}")
                emptyList()
            }
            if (found.isNotEmpty()) out += found
        }
        Log.i(TAG, "刮削候选：「${query.title}」共 ${out.size} 条" + (sourceId?.let { "（仅 $it）" } ?: ""))
        return out
    }

    /**
     * 用户选中的候选 → 完整元数据。**按来源找回对应的刮削器**。
     *
     * ⛔ 不缓存实例、也不按 id 建表：来源就是 `scrapers` 里的 `id`，直接线性找。
     *    列表只有两三项，建表反而多一处要保持同步的状态。
     */
    fun resolve(candidate: ScrapeCandidate): ScrapedMetadata? {
        val s = scrapers.firstOrNull { it.id == candidate.source }
        if (s == null) {
            Log.w(TAG, "候选来源 ${candidate.source} 不在当前流水线里，忽略")
            return null
        }
        return try {
            s.resolve(candidate)
        } catch (t: Throwable) {
            Log.w(TAG, "${s.id} 解析候选失败：${t.message}")
            null
        }
    }

    companion object {
        private const val TAG = "CloudCine"

        /**
         * 从库里的设置构造流水线。
         *
         * ⛔ **每次刮削都要重新构造**，不能缓存实例：用户可能在刮削页里刚填完
         *    Cookie 回来就点了搜索，而缓存的实例拿的还是旧值 —— 表现是
         *    「填了 Cookie 还是刮不到」，重启才好。
         *
         * ⛔ 三个键名与 PC 端 `SettingKeys` **逐字一致**（`tmdb_api_key` /
         *    `tmdb_api_base` / `tmdb_image_base` / `douban_cookie`）。它们存在
         *    库的 `settings` 表里，因此**随备份包一起跨端走** —— 在电脑上配好的
         *    反代地址，同步到电视上直接可用（见 `LibraryBackupService`）。
         */
        fun fromSettings(db: LibraryDb): ScraperPipeline {
            val s = db.settingsMap()
            return ScraperPipeline(
                listOf(
                    TmdbScraper(
                        apiKey = s[LibrarySettings.TMDB_API_KEY].orEmpty(),
                        apiBase = s[LibrarySettings.TMDB_API_BASE].orNullIfBlank()
                            ?: TmdbScraper.DEFAULT_API_BASE,
                        imageBase = s[LibrarySettings.TMDB_IMAGE_BASE].orNullIfBlank()
                            ?: TmdbScraper.DEFAULT_IMAGE_BASE,
                    ),
                    DoubanScraper(
                        cookie = s[LibrarySettings.DOUBAN_COOKIE].orEmpty(),
                    ),
                ),
            )
        }

        private fun String?.orNullIfBlank(): String? =
            this?.trim()?.takeIf { it.isNotEmpty() }
    }
}
