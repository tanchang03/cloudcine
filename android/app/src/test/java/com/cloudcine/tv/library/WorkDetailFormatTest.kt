package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 作品简介页（Android TV）的**口径** —— [WorkDetailFormat] 就是
 * `LibraryActivity` 画那一页时用的那几个函数。
 *
 * ## 为什么这一组必须钉死
 *
 * 简介页上的每一个词都是一条**跨端口径**，而写错它们**全都不会报错**：
 *
 *   * 「已刮削」判成「有海报」⇒ 刮了但没下到图的作品写着「未刮削」，
 *     用户会再刮一遍（而再刮一遍还是写着未刮削）；
 *   * 季数门槛写成 `>= 1` ⇒ 每部电影、每部单季剧的元数据行都多一个
 *     「1 季」，看起来像分类判错了；
 *   * 类型不截断 ⇒ 类型多的片子把这一行折成两排，把简介正文挤出屏幕；
 *   * 「原名」不做 `!= title` 判断 ⇒ 中文片名没刮到时，标题连着印两遍。
 *
 * 这些在真机上都是「多一个词 / 少一个词」级别的差别，靠眼睛扫一遍很难发现，
 * 所以规则钉在这里。
 */
class WorkDetailFormatTest {

    // ==================================================================
    // 元数据行
    // ==================================================================

    /** 完整的一行：顺序 = 年份 → 季 → 集 → 分类 → 评分 → 来源 → 类型。 */
    @Test
    fun `元数据行的顺序与内容`() {
        val w = work(
            kind = "episode",
            category = MediaCategoryNames.SERIES,
            year = 2024,
            seasonCount = 2,
            itemCount = 12,
            rating = 8.74,
            source = "online",
            genres = listOf("剧情", "犯罪"),
        )
        assertEquals("2024 · 2 季 · 12 集 · 剧集 · ★ 8.7 · 已刮削 · 剧情/犯罪", WorkDetailFormat.metaLine(w))
    }

    /**
     * ⛔ 「已刮削」的判据是 `source == "online"`，**不是**「有海报」。
     *
     * 这一条单独钉：把 `source` 换成 `local` 时，哪怕别的字段一模一样，
     * 也必须写「未刮削」。判据写成「有海报」的话，这里就会漏。
     */
    @Test
    fun `已刮削只看 source 不看有没有海报`() {
        val online = work(source = "online")
        val local = work(source = "local")
        assertTrue(WorkDetailFormat.metaLine(online).contains("已刮削"))
        assertTrue(WorkDetailFormat.metaLine(local).contains("未刮削"))
        assertFalse(WorkDetailFormat.metaLine(local).contains("已刮削"))
    }

    /**
     * ⛔ 季数门槛是 `>= 2`：电影和单季剧**不画**「1 季」。
     *
     * 写成 `>= 1` 的话，一部电影也会顶着「1 季」，看起来像分类判错了。
     */
    @Test
    fun `季数少于两季时不画季数`() {
        assertFalse(WorkDetailFormat.metaLine(work(seasonCount = 0)).contains("季"))
        assertFalse(WorkDetailFormat.metaLine(work(seasonCount = 1)).contains("季"))
        assertTrue(WorkDetailFormat.metaLine(work(seasonCount = 2)).contains("2 季"))
    }

    /** 剧集写「N 集」、电影写「N 个文件」—— 口径与卡片副标题一致。 */
    @Test
    fun `集数与文件数按 kind 分开`() {
        assertTrue(
            WorkDetailFormat.metaLine(work(kind = "episode", itemCount = 3)).contains("3 集"),
        )
        assertTrue(
            WorkDetailFormat.metaLine(work(kind = "movie", itemCount = 3)).contains("3 个文件"),
        )
        // itemCount = 0 时**不画**：那是「库里还没数出来」，不是「0 集」。
        assertFalse(WorkDetailFormat.metaLine(work(itemCount = 0)).contains("0 "))
    }

    /** 年份 / 评分的 0 与 null 都是「没刮到」，不画（0 分不是 0 分，是未知）。 */
    @Test
    fun `年份与评分为零或空时不画`() {
        assertFalse(WorkDetailFormat.metaLine(work(year = null, rating = null)).contains("★"))
        assertFalse(WorkDetailFormat.metaLine(work(year = 0)).contains("0 ·"))
        assertFalse(WorkDetailFormat.metaLine(work(rating = 0.0)).contains("★"))
        assertTrue(WorkDetailFormat.metaLine(work(year = 1999, rating = 7.0)).contains("1999"))
        assertTrue(WorkDetailFormat.metaLine(work(year = 1999, rating = 7.0)).contains("★ 7.0"))
    }

    /**
     * 类型最多 [WorkDetailFormat.MAX_GENRES] 个。
     *
     * ⛔ 多了这一行会折成两排，把下面的简介正文挤出屏幕（电视横屏逻辑高只有
     *    540dp，这一块本来就紧）。
     */
    @Test
    fun `类型最多显示四个`() {
        val w = work(genres = listOf("剧情", "犯罪", "悬疑", "惊悚", "动作", "科幻"))
        val line = WorkDetailFormat.metaLine(w)
        assertTrue(line.endsWith("剧情/犯罪/悬疑/惊悚"))
        assertFalse(line.contains("动作"))
        assertFalse(line.contains("科幻"))
    }

    /**
     * ⛔ 分类与来源**恒在**，所以这一行永不为空串。
     *
     * 分类认不出来（`""` = 还没判定过）时兜底「其他」，来源写成「未刮削」——
     * 与 PC 端那两枚 chip 恒在一致。这一条同时钉住「调用方不用判空」这个前提：
     * `LibraryActivity.paintDetailHead` 就是按这个假设写的。
     */
    @Test
    fun `分类与来源恒在所以这一行不会为空`() {
        val line = WorkDetailFormat.metaLine(work(category = ""))
        assertEquals("其他 · 未刮削", line)
        assertTrue(line.isNotEmpty())
        assertEquals("电影 · 未刮削", WorkDetailFormat.metaLine(work()))
    }

    // ==================================================================
    // 原名 / 简介
    // ==================================================================

    /**
     * ⛔ 原名与标题**相同**时不画 —— 判据照 PC 端 `_InfoColumn`。
     *
     * 中文片名没刮到时两者会一模一样，那时画出来就是同一行字印两遍。
     */
    @Test
    fun `原名与标题相同或为空时返回 null`() {
        assertNull(WorkDetailFormat.originalLine(work(title = "黑亚当", originalTitle = "黑亚当")))
        assertNull(WorkDetailFormat.originalLine(work(title = "黑亚当", originalTitle = "  ")))
        assertNull(WorkDetailFormat.originalLine(work(title = "黑亚当", originalTitle = null)))
        assertEquals(
            "Black Adam",
            WorkDetailFormat.originalLine(work(title = "黑亚当", originalTitle = "Black Adam")),
        )
    }

    /** 简介要**压平空白**：源里常带换行与连续空格，直接画会撑出很多空行。 */
    @Test
    fun `简介压平空白`() {
        val w = work(overview = "  第一段。\n\n  第二段\t带制表符。 ")
        assertEquals("第一段。 第二段 带制表符。", WorkDetailFormat.overviewText(w))
    }

    /** 空 / 只有空白的简介返回 `null`（调用方据此把这一块 GONE 掉）。 */
    @Test
    fun `空简介返回 null`() {
        assertNull(WorkDetailFormat.overviewText(work(overview = null)))
        assertNull(WorkDetailFormat.overviewText(work(overview = "")))
        assertNull(WorkDetailFormat.overviewText(work(overview = " \n\t ")))
    }

    // ==================================================================
    // 动作胶囊
    // ==================================================================

    /**
     * 四颗胶囊的文案与顺序。
     *
     * ⛔ 顺序**必须**与 `LibraryActivity.buildDetailActions` 逐项一致 ——
     *    光标位置就是按这个下标存的，顺序错了就是「点了 A 执行 B」。
     */
    @Test
    fun `动作胶囊的顺序与文案`() {
        val labels = WorkDetailFormat.actionLabels(resumable = false, itemCount = 12)
        assertEquals(4, labels.size)
        assertEquals("▶ 播放", labels[0].first)
        assertEquals("手动刮削", labels[1].first)
        assertEquals("刮削设置", labels[2].first)
        assertEquals("选集（12）", labels[3].first)
        // 有续播进度时第一颗换成「续播」—— 这是「点卡片之后第一下按 OK」会播的
        // 那一条，用户得能一眼看出来它不是从头开始。
        assertEquals(
            "▶ 续播",
            WorkDetailFormat.actionLabels(resumable = true, itemCount = 12)[0].first,
        )
    }

    /**
     * ⛔ 没有可播文件时，播放 / 选集**置灰而不是消失**。
     *
     * 按钮凭空消失的话，用户只会以为这个页面坏了 —— 他需要看到的是一个
     * 灰着的按钮加上一句解释（`LibraryActivity.applyAction` 会给）。
     * 刮削 / 设置**不受影响**：库里一条视频都没有，恰恰是最该去刮的时候。
     */
    @Test
    fun `没有可播文件时只有播放与选集置灰`() {
        val labels = WorkDetailFormat.actionLabels(resumable = false, itemCount = 0)
        assertFalse(labels[0].second)
        assertTrue(labels[1].second)
        assertTrue(labels[2].second)
        assertFalse(labels[3].second)
        // 文案里的计数仍然是 0（不是「选集（0 个）」那种别扭写法）。
        assertEquals("选集（0）", labels[3].first)
    }

    /** 有可播文件时四颗全亮。 */
    @Test
    fun `有可播文件时全部可用`() {
        assertTrue(WorkDetailFormat.actionLabels(resumable = true, itemCount = 1).all { it.second })
    }

    // ==================================================================

    /**
     * 造一部作品。
     *
     * ⛔ 只给会被 [WorkDetailFormat] 读到的字段传参，其余一律给「空」——
     *    默认值**故意选成「什么都没刮到」**（`year = null`、`source = local`、
     *    `genres` 空），这样每条用例想验的字段都必须自己写出来，
     *    不会因为「默认值恰好是对的」而蒙混过关。
     */
    private fun work(
        kind: String = "movie",
        category: String = MediaCategoryNames.MOVIE,
        title: String = "片名",
        originalTitle: String? = null,
        year: Int? = null,
        overview: String? = null,
        rating: Double? = null,
        genres: List<String> = emptyList(),
        source: String = "local",
        itemCount: Int = 0,
        seasonCount: Int = 0,
        resumeFraction: Double? = null,
    ) = Work(
        key = "quark:abc",
        kind = kind,
        category = category,
        title = title,
        originalTitle = originalTitle,
        year = year,
        overview = overview,
        posterUrl = null,
        posterFile = null,
        posterFaceX = null,
        rating = rating,
        genres = genres,
        source = source,
        itemCount = itemCount,
        totalBytes = 0L,
        seasonCount = seasonCount,
        lastModifiedAt = null,
        firstSeenAt = null,
        lastPlayedAt = null,
        resumeFraction = resumeFraction,
    )
}
