package com.cloudcine.tv.library

import android.util.Log

/**
 * [AutoScraper] 需要的**全部**库操作 —— 就这四个。
 *
 * ## 为什么要有这个接口，而不是直接吃 [LibraryDb]
 *
 * `LibraryDb` 是 `android.database.sqlite.SQLiteDatabase` 的一层皮，在 JVM 单测里
 * **起不来**（android.jar 是空壳实现）。而 [AutoScraper] 里最值得测的东西恰恰
 * 不是 SQL —— 是**那个循环**：三种结论怎么计数、三条提前退出的路什么时候生效、
 * 进度怎么上报。这些全都能在一个假库上验证，而真库上要造出「145 部作品 + 源全挂」
 * 的现场几乎不可能。
 *
 * ⛔ 接口**刻意只有四个方法**：多一个就多一处「生产环境与测试假库不一致」的风险。
 *    生产环境的实现在 [AutoScraper.forLibrary] 里，是一层直通 [LibraryDb] 的转发。
 */
interface AutoScrapeStore {
    /** 待刮的作品，按最近修改倒序。见 [LibraryDb.worksNeedingScrape]。 */
    fun worksNeedingScrape(limit: Int): List<Work>

    /** 一部作品名下的媒体项（用来重新解析查询词）。 */
    fun itemsForWork(workKey: String): List<LibraryItem>

    /** 把刮到的元数据合并进作品行。作品不存在时返回 `null`。 */
    fun updateWorkScrape(workKey: String, meta: ScrapedMetadata): Work?

    /** 回写海报缓存文件名。 */
    fun setWorkPosterFile(workKey: String, fileName: String)
}

/**
 * **扫描之后的自动刮削** —— 串行把「还没刮过」的作品补齐在线元数据。
 *
 * ## 它做什么
 *
 * 对每一部待刮的作品：
 *
 *   1. 用 [ScrapeQueryBuilder] 从**文件名**重新解析出查询词（不是从库里已存的
 *      标题 —— 否则第二次刮的是上一次刮来的名字，越刮越偏）；
 *   2. 逐个在线源搜候选（TMDB → 豆瓣，与 PC 端同序）；
 *   3. **过 [ScrapeMatch] 闸门**挑出第一条可信的候选；
 *   4. 解析成完整元数据 → [LibraryDb.updateWorkScrape] 落库；
 *   5. 把海报拉下来（[PosterFetcher]）并回写 `poster_file`。
 *
 * ## ⛔ 第 3 步是**不能省**的
 *
 * 手动刮削不需要闸门（候选是用户亲手挑的）。而自动刮削是**无人值守**的 ——
 * 没有闸门就会把 PC 端 2026-10-01 那次事故复制到整库：查询词
 * `超z级z马z力z欧z银z河z大z电影aa(2026)` 被刮成 **《低俗小说》(1994)**，
 * 而年份差了 32 年代码完全没察觉。闸门宁可漏刮也不刮错，理由见 [ScrapeMatch]。
 *
 * ## 三条提前退出的路
 *
 * 批量刮削是唯一会「跑很久」的刮削，所以每一条退路都要显式写出来：
 *
 *   * **用户取消**（[LibraryScanner.Cancellation]）—— 在**每部作品之间**检查，
 *     不是每次网络请求。一部作品的刮削只有几秒，没必要把取消做成可中断的；
 *   * **所有在线源都被摘掉**（见 [ScrapeSourceBudget]）—— 再跑下去只是白等
 *     超时。这是电视上最常见的结局（TMDB 官方地址被 DNS 污染）；
 *   * **连续 [GIVE_UP_AFTER] 部一部都没命中，且至今零成功** —— 源没被摘掉但
 *     显然也不可用（比如凭证被拒：请求**很快**返回 401，不算「慢」，所以
 *     摘不掉）。这时继续跑完 145 部只是浪费用户的时间。
 *
 * ## 与 PC 端的分工
 *
 * PC 端 `ScanService` 把刮削放在遍历之后单独跑、**只刮还没刮过的作品**，
 * 并且默认**关**（设置项 `auto_scrape_on_scan`，理由是豆瓣匿名额度只有约 10 个
 * 搜索词）。Android 端沿用同一套口径与同一个设置键 —— 键名逐字一致，
 * 因为它在 `settings` 表里、随备份包跨端走。
 *
 * ⛔ 阻塞（网络 + 磁盘 + 数据库）。调用方负责放到 [com.cloudcine.tv.pan.Bg]。
 */
class AutoScraper(
    private val store: AutoScrapeStore,
    private val pipeline: ScraperPipeline,
    private val posterFetcher: PosterFetcher,
    private val cancel: LibraryScanner.Cancellation = LibraryScanner.Cancellation(),
    private val budget: ScrapeSourceBudget = ScrapeSourceBudget(),
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
) {

    /** 一部作品的处理结论。 */
    private enum class Verdict {
        /** 在线源命中并落库。 */
        scraped,

        /** 所有源都问了，没有一条候选过得了闸门。 */
        notFound,

        /** 文件名解析不出可信片名 —— 没有可查的东西。 */
        noQuery,
    }

    /**
     * 进度快照。
     *
     * [done] / [total] 是给进度条用的（「第几部 / 共几部」），[title] 是当前
     * 正在处理的那一部的片名 —— 用户看到「刮削 12/145 · 流浪地球」时，既知道
     * 还要多久，也知道它没有卡死。
     */
    data class Progress(
        val done: Int,
        val total: Int,
        val title: String,
        val scraped: Int,
        val notFound: Int,
        val noQuery: Int,
        /** 已被摘掉的源的展示名（「TMDB」「豆瓣」）。 */
        val droppedSources: List<String>,
    ) {
        /** 状态行上那一行字。**刻意短**：它是标题栏右侧的单行 `TextView`。 */
        val text: String
            get() = buildString {
                append("刮削 ").append(done).append("/").append(total)
                append(" · 成功 ").append(scraped)
                if (droppedSources.isNotEmpty()) {
                    append(" · ").append(droppedSources.joinToString("/")).append(" 已跳过")
                } else if (title.isNotEmpty()) {
                    append(" · ").append(title)
                }
            }
    }

    /** 一次自动刮削的结果。 */
    data class Outcome(
        val total: Int,
        val done: Int,
        val scraped: Int,
        val notFound: Int,
        val noQuery: Int,
        val cancelled: Boolean,
        /** 因为「源全不可用」或「连续零命中」提前收工。 */
        val stopped: Boolean,
        val droppedSources: List<String>,
        val error: String? = null,
    ) {
        /** 给状态行用的一句话。 */
        val message: String
            get() {
                if (error != null) return "刮削失败：$error"
                if (total == 0) return "没有需要刮削的作品（都已刮过）"
                return buildString {
                    append(
                        when {
                            cancelled -> "刮削已停止"
                            stopped -> "刮削提前停止"
                            else -> "刮削完成"
                        },
                    )
                    append("：成功 ").append(scraped).append("/").append(total)
                    if (notFound > 0) append(" · 未命中 ").append(notFound)
                    if (noQuery > 0) append(" · 认不出片名 ").append(noQuery)
                    if (droppedSources.isNotEmpty()) {
                        append(" · ").append(droppedSources.joinToString("/"))
                        append(" 连不上，已跳过（去「刮削设置」测一下凭证）")
                    }
                }
            }
    }

    /**
     * 跑一轮自动刮削。**不抛异常** —— 网络抖动、源挂了、解析崩了都记成
     * 「这一部没命中」继续往下走。这是给一次扫描收尾用的动作，抛异常只会
     * 把已经刮好的那几十部也一起丢掉。
     */
    fun run(onProgress: (Progress) -> Unit = {}): Outcome {
        val works = try {
            store.worksNeedingScrape(WORK_LIMIT)
        } catch (t: Throwable) {
            Log.e(TAG, "自动刮削：查待刮作品失败", t)
            return Outcome(
                total = 0, done = 0, scraped = 0, notFound = 0, noQuery = 0,
                cancelled = false, stopped = false, droppedSources = emptyList(),
                error = t.message ?: t.toString(),
            )
        }

        val total = works.size
        val sourceCount = pipeline.availableSources.size
        Log.i(TAG, "自动刮削：待刮 $total 部，在线源 $sourceCount 个")

        var done = 0
        var scraped = 0
        var notFound = 0
        var noQuery = 0
        var consecutiveMiss = 0
        var cancelled = false
        var stopped = false
        var current = ""

        fun report() {
            runCatching {
                onProgress(
                    Progress(done, total, current, scraped, notFound, noQuery, budget.droppedNames),
                )
            }
        }

        report()

        for (w in works) {
            if (cancel.isCancelled) {
                cancelled = true
                break
            }
            current = w.title

            val verdict = try {
                scrapeOne(w)
            } catch (t: Throwable) {
                Log.w(TAG, "自动刮削：${w.key} 失败，按未命中处理", t)
                Verdict.notFound
            }

            when (verdict) {
                Verdict.scraped -> {
                    scraped++
                    consecutiveMiss = 0
                }
                Verdict.notFound -> {
                    notFound++
                    consecutiveMiss++
                }
                // 认不出片名**不是**源的错（这一部本来就没得查），
                // 所以不累加「连续零命中」——否则一库自制视频会把它顶到提前收工。
                Verdict.noQuery -> noQuery++
            }

            done++
            report()

            if (sourceCount > 0 && budget.droppedNames.size >= sourceCount) {
                Log.w(TAG, "自动刮削：所有在线源都不可用，提前收工（已处理 $done/$total）")
                stopped = true
                break
            }
            if (scraped == 0 && consecutiveMiss >= GIVE_UP_AFTER) {
                Log.w(
                    TAG,
                    "自动刮削：连续 $GIVE_UP_AFTER 部零命中且至今零成功，提前收工" +
                        "（源没超时，多半是凭证被拒 —— 去「刮削设置」测一下）",
                )
                stopped = true
                break
            }
            if (done < total) sleep(THROTTLE_MS)
        }

        val out = Outcome(
            total = total,
            done = done,
            scraped = scraped,
            notFound = notFound,
            noQuery = noQuery,
            cancelled = cancelled,
            stopped = stopped,
            droppedSources = budget.droppedNames,
        )
        Log.i(TAG, "自动刮削：${out.message}")
        return out
    }

    /** 刮一部作品并落库。 */
    private fun scrapeOne(w: Work): Verdict {
        val q = ScrapeQueryBuilder.forItems(store.itemsForWork(w.key))
        if (q == null) {
            Log.i(TAG, "自动刮削：${w.key} 文件名解析不出可信片名，跳过")
            return Verdict.noQuery
        }

        val candidate = searchOne(q) ?: return Verdict.notFound
        val meta = pipeline.resolve(candidate)
        if (meta == null) {
            Log.i(TAG, "自动刮削：${w.key} 候选 ${candidate.uid} 解析不出完整信息")
            return Verdict.notFound
        }
        store.updateWorkScrape(w.key, meta) ?: return Verdict.notFound

        // 海报与元数据在**同一个后台任务**里下：用户看到「成功 N」时海报也应该
        // 已经在盘上了。失败不影响主流程（元数据已经落库），只是墙上那块还是灰的。
        val posterUrl = meta.posterUrl?.takeIf { it.isNotBlank() }
        if (posterUrl != null) {
            val file = posterFetcher.fetch(w.key, posterUrl)
            if (file != null) store.setWorkPosterFile(w.key, file)
        }

        Log.i(
            TAG,
            "自动刮削：${w.key} → ${meta.title}" +
                (meta.year?.let { "（$it）" } ?: "") + " · 源=${candidate.source}",
        )
        return Verdict.scraped
    }

    /**
     * 按源顺序搜一遍，返回**第一条过得了闸门**的候选。
     *
     * ⛔ 一个源搜挂了不该让整部作品空掉 —— 另一个源的候选照样有用
     *    （与 [ScraperPipeline.search] 同一条取向）。
     */
    private fun searchOne(q: ScrapeQuery): ScrapeCandidate? {
        for ((id, name) in pipeline.availableSources) {
            if (budget.isDropped(id)) continue

            val t0 = clock()
            val found = try {
                pipeline.search(q, sourceId = id)
            } catch (t: Throwable) {
                Log.w(TAG, "自动刮削：$name 搜索失败，跳过这个源", t)
                emptyList()
            }
            val elapsed = clock() - t0

            if (budget.record(id, name, found.isNotEmpty(), elapsed)) {
                Log.w(
                    TAG,
                    "自动刮削：$name 连续 ${ScrapeSourceBudget.MAX_CONSECUTIVE_FAILURES} 次" +
                        "超时且无结果（最近一次 ${elapsed}ms），本次批量不再问它",
                )
            }

            if (found.isEmpty()) continue
            pickVerified(q, found)?.let { return it }
        }
        return null
    }

    /**
     * 闸门：从候选里挑**第一条**「配得上这个查询词」的。
     *
     * ## 为什么取第一条而不是「相似度最高的那条」
     *
     * 源返回的列表**本身就是按相关度排的**（TMDB 与豆瓣都是），再按相似度重排
     * 等于用我们这套粗糙的字符相似度去覆盖数据源的排序 —— 而 PC 端的口径是
     * 「**第一位**必须是精确同名」（见 [ScrapeMatch] 的类文档）。
     * 取第一条能过闸门的，天然满足这一条：宽松档下只有精确同名才过得了。
     *
     * 被拒的每一条都记一行日志 —— 排查「这部为什么没刮到」时全靠它。
     */
    private fun pickVerified(q: ScrapeQuery, found: List<ScrapeCandidate>): ScrapeCandidate? {
        for (c in found) {
            val r = ScrapeMatch.evaluate(
                queryTitle = q.title,
                queryYear = q.year,
                resultTitle = c.title,
                resultYear = c.year,
                requireExactTitle = q.requireExactTitle,
            )
            if (r.accepted) {
                Log.i(TAG, "自动刮削闸门：${c.source}「${c.title}」${r.reason}")
                return c
            }
            Log.i(TAG, "自动刮削闸门：${c.source}「${c.title}」被拒 —— ${r.reason}")
        }
        return null
    }

    companion object {
        private const val TAG = "CloudCine"

        /**
         * 生产环境的构造：把 [LibraryDb] 转发成 [AutoScrapeStore]。
         *
         * ⛔ 转发层放在这里、而不是让 `LibraryDb` 直接实现接口：`LibraryDb` 的
         *    `updateWorkScrape` 带着两个默认参数（`categoryOverride` / `nowSec`），
         *    而 Kotlin 的接口方法**不允许带默认值** —— 硬要实现的话得改 `LibraryDb`
         *    的公开签名，为了测试去动生产接口是本末倒置。
         */
        fun forLibrary(
            db: LibraryDb,
            pipeline: ScraperPipeline,
            posterFetcher: PosterFetcher,
            cancel: LibraryScanner.Cancellation = LibraryScanner.Cancellation(),
        ): AutoScraper = AutoScraper(
            store = object : AutoScrapeStore {
                override fun worksNeedingScrape(limit: Int) = db.worksNeedingScrape(limit)
                override fun itemsForWork(workKey: String) = db.itemsForWork(workKey)
                override fun updateWorkScrape(workKey: String, meta: ScrapedMetadata) =
                    db.updateWorkScrape(workKey, meta)
                override fun setWorkPosterFile(workKey: String, fileName: String) =
                    db.setWorkPosterFile(workKey, fileName)
            },
            pipeline = pipeline,
            posterFetcher = posterFetcher,
            cancel = cancel,
        )

        /** 一次自动刮削最多处理多少部。见 [LibraryDb.worksNeedingScrape]。 */
        private const val WORK_LIMIT = 500

        /**
         * 两部作品之间的间隔。
         *
         * 不是为了配额（豆瓣按**搜索词**计费，隔多久都算一个），而是别把
         * 网盘 / 刮削源当靶子打。145 部 × 200ms 才 29 秒，不影响体感。
         */
        private const val THROTTLE_MS = 200L

        /**
         * 连续这么多部零命中、且至今**一部都没成功**，就提前收工。
         *
         * 针对的是「凭证被拒」这一类：请求**很快**返回 401 / 103，耗时远低于
         * [ScrapeSourceBudget.SLOW_MS]，所以源摘不掉，但继续跑完 145 部纯粹
         * 是浪费用户时间。零成功这个附加条件很重要 —— 库里有一批自制视频时
         * 连续零命中是正常的。
         */
        private const val GIVE_UP_AFTER = 12
    }
}
