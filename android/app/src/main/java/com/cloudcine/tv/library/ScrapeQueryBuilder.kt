package com.cloudcine.tv.library

/**
 * 从作品的文件里构造**刮削查询词**。
 *
 * ## 为什么必须收敛成一个函数
 *
 * 现在有**两个**地方要发刮削请求：手动刮削页的预填（`ScrapeActivity`）与
 * 扫描后的自动刮削（[AutoScraper]）。两处只要有一处换了挑文件的口径
 * （比如忘了滤花絮），同一个作品就会「手动刮出来是 A、自动刮出来是 B」——
 * 而这是**静默的**，用户只会觉得「这个刮削有时候不准」。
 *
 * PC 端为同一件事专门写了 `ScrapeQuery.fromParsed` 这个工厂，理由逐字相同。
 *
 * ## 挑法与「播放」按钮一致：**跳过花絮 / 样片**
 *
 * `-trailer.mkv` 解析出来的片名常常带着 `trailer`，拿它去搜只会搜到一堆
 * 不相关的东西。所以先滤 `isSampleOrExtra`，滤空了再退回全集
 * （一个作品全是花絮时，总比没有查询词强）。
 *
 * ## ⛔ `dirPath` 必须传
 *
 * [MediaNameParser.parse] 的第二参是**这个文件所在的目录**（带尾斜杠），
 * 不是末级目录名。扫描期（`LibraryScanner`）就是按这个口径解析的 ——
 * 两处不一致会让同一个作品「扫描期刮出来是 A、点按钮刮出来是 B」。
 */
object ScrapeQueryBuilder {

    /**
     * 片名能不能当查询词用：**含至少一个字母或汉字**（纯数字 / 纯符号不算）。
     *
     * ⛔ 与 [MediaNameParser.Parsed.hasUsableTitle] **同一口径**，也与 PC 端
     *    `ParsedMediaName.hasUsableTitle` 一致。这里再写一份是给「手上只有
     *    一个字符串、没有 `Parsed`」的调用方用的（设置页、测试）。
     *
     * ⛔ 它和「要不要建作品行」是**同一个门槛**，而和「要不要刮削」不是：
     *    不刮削只是没有海报简介，不建作品则是这条媒体在库里**永久看不到**。
     */
    fun hasUsableTitle(title: String): Boolean =
        Regex("[a-z\\u4e00-\\u9fff]", RegexOption.IGNORE_CASE).containsMatchIn(title)

    /**
     * 从一部作品的文件里取出查询词。取不到返回 `null`（**没有可查的东西**）。
     *
     * 返回 `null` 的两种情形：
     *   * 一条文件都没有（作品行还在、文件已被清理）；
     *   * 所有文件都解析不出可信片名（`S01E01.1080p.mkv` 这种只剩技术标记的）。
     *
     * ## 与 PC 端的**一处看似缺失**（其实是等价的）
     *
     * PC 端 `ScrapeQuery.fromParsed` 有一条 `kind == unknown → null`。
     * Android 端**不需要**再判一次：[MediaNameParser.parse] 只有在
     * `title` 为空时才给 `unknown`，而空标题已经被 [hasUsableTitle] 挡掉了。
     * 两处写同一个判据会让人以为「少写了一条就会漏刮」，所以这里显式说明。
     */
    fun forItems(items: List<LibraryItem>): ScrapeQuery? {
        val features = items.filter { !it.isSampleOrExtra }
        val pool = if (features.isNotEmpty()) features else items
        for (item in pool) {
            val q = forItem(item)
            if (q != null) return q
        }
        return null
    }

    /** 单个文件的查询词。片名不可信时返回 `null`。 */
    fun forItem(item: LibraryItem): ScrapeQuery? {
        val parsed = MediaNameParser.parse(item.name, item.dirPath)
        val title = parsed.title?.trim().orEmpty()
        if (title.isEmpty() || !hasUsableTitle(title)) return null
        return ScrapeQuery(
            title = title,
            year = parsed.year,
            kind = parsed.kind,
            requireExactTitle = requiresExactTitle(parsed.kind, parsed.year),
        )
    }

    /**
     * 该不该走「**只认精确同名**」的宽松档。
     *
     * ⛔ 与 PC 端 `ScrapeQuery.fromParsed` 的 `relaxed = !parsed.isConfident`
     *    是同一条，只是把那边的三个条件逐个化简掉了：
     *
     * ```
     * isConfident = kind != unknown && title 非空 && (year != null || kind == episode)
     * ```
     *
     *   * `kind != unknown` 与 `title 非空` —— 调用方已经判过（见 [forItems]）；
     *   * 剩下的**只有一种**：**电影且没有年份**。
     *
     * 为什么这一档要更紧：宽松档没有年份硬闸门兜底，只剩标题相似度，而
     * 严格档的 0.6 阈值是**为「有年份」定的** —— 它会让前缀误配无条件通过
     * （`奥德赛` → `奥德赛：归来` 0.86）。详见 [ScrapeMatch]。
     */
    fun requiresExactTitle(kind: String, year: Int?): Boolean =
        kind == KIND_MOVIE && year == null

    /** [MediaNameParser.Parsed.kind] 里「电影」的取值。 */
    const val KIND_MOVIE = "movie"
}
