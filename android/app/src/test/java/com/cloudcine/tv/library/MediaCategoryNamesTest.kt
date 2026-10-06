package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [MediaCategoryNames] 与 PC 端 `MediaCategory` 的口径对拍。
 *
 * ## 为什么这一组值得测
 *
 * 这里每一个取值都是**跨端共享**的：`media_works.category` 存的是这些
 * 字符串，PC 端写、Android 端读（反之亦然）。任何一处走样都不会报错，
 * 只会让某一端显示错分类 —— 而且往往要等用户把备份同步过来才发现：
 *
 *   * [normalize] 把陌生值抛异常 ⇒ 同步来一个 PC 新加的分类，整个媒体库崩；
 *   * [normalize] 做了 `lowercase()` ⇒ 两端对同一个值给出不同结论；
 *   * [label] 直接回显库里的英文 ⇒ 电视上印出 `movie · 2026`（**真实
 *     出现过的 bug**），用户看到的是数据库字段名；
 *   * [displayOrder] 顺序变了 ⇒ 「其他」跑到中间，把正常分类挤到右边。
 */
class MediaCategoryNamesTest {

    // ------------------------------------------------------------------
    // normalize —— 认不出来一律降级，绝不抛
    // ------------------------------------------------------------------

    @Test
    fun `六个合法值原样返回`() {
        for (name in MediaCategoryNames.displayOrder) {
            assertEquals(name, MediaCategoryNames.normalize(name))
        }
    }

    @Test
    fun `null 与空串回 other`() {
        // ⛔ `media_works.category` 的默认值就是空串（= 还没判定过），
        //    所以这一条是**常态路径**，不是边界情况。
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize(null))
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize(""))
    }

    @Test
    fun `陌生值回 other 而不是抛异常`() {
        // PC 端将来加分类（比如 `short`）时，Android 旧版本必须能读旧库。
        // 分类是**展示维度**，降级显示远好于让整个媒体库打不开。
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize("short"))
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize("动画"))
    }

    @Test
    fun `大小写敏感 —— 与 PC fromName 逐字对齐`() {
        // PC 端是 `c.name == name`（大小写敏感）。这里若擅自 `lowercase()`，
        // 两端对同一个库值就会给出不同结论：PC 显示「其他」，Android 显示「电影」。
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize("Movie"))
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize("MOVIE"))
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.normalize(" movie"))
    }

    @Test
    fun `normalize 幂等`() {
        // 角标计数、筛选条件、卡片副标题三处都会 normalize 一次结果，
        // 二次 normalize 必须不变，否则「筛选条件」与「显示」会对不上。
        for (raw in listOf(null, "", "movie", "anime", "short")) {
            val once = MediaCategoryNames.normalize(raw)
            assertEquals(once, MediaCategoryNames.normalize(once))
        }
    }

    // ------------------------------------------------------------------
    // displayOrder —— 「其他」必须垫底
    // ------------------------------------------------------------------

    @Test
    fun `displayOrder 六项且无重复`() {
        val order = MediaCategoryNames.displayOrder
        assertEquals(6, order.size)
        assertEquals(order.size, order.toSet().size)
    }

    @Test
    fun `其他垫底`() {
        // ⛔ 不按 enum 声明顺序取：PC 端把 `other` 声明在最后是**为了
        //    `fromName` 的兜底读起来顺**，而不是为了排序。摆到中间会
        //    把正常分类挤到右边。
        assertEquals(MediaCategoryNames.OTHER, MediaCategoryNames.displayOrder.last())
    }

    @Test
    fun `顺序与 PC MediaCategory 声明顺序一致`() {
        // 顺序是**用户可见**的（分类栏从左到右），两端不一致会让用户
        // 以为「同步之后分类被改了」。
        assertEquals(
            listOf("movie", "series", "anime", "variety", "documentary", "other"),
            MediaCategoryNames.displayOrder,
        )
    }

    // ------------------------------------------------------------------
    // label —— 修掉「印出数据库字段名」
    // ------------------------------------------------------------------

    @Test
    fun `六个分类的中文标签`() {
        assertEquals("电影", MediaCategoryNames.label(MediaCategoryNames.MOVIE))
        assertEquals("剧集", MediaCategoryNames.label(MediaCategoryNames.SERIES))
        assertEquals("动漫", MediaCategoryNames.label(MediaCategoryNames.ANIME))
        assertEquals("综艺", MediaCategoryNames.label(MediaCategoryNames.VARIETY))
        assertEquals("纪录片", MediaCategoryNames.label(MediaCategoryNames.DOCUMENTARY))
        assertEquals("其他", MediaCategoryNames.label(MediaCategoryNames.OTHER))
    }

    @Test
    fun `label 不可能是英文枚举名`() {
        // 这条是那个真实 bug 的**回归测试**：卡片副标题曾经直接印
        // `work.category`，电视上显示 `movie · 2026`。
        // 断言「输出里不含 ASCII 字母」比逐个比字符串更能挡住这类回归。
        for (raw in listOf(null, "", "movie", "series", "anime", "variety", "documentary", "other", "short")) {
            val text = MediaCategoryNames.label(raw)
            assertTrue(
                "label(${raw?.let { "\"$it\"" } ?: "null"}) 应为纯中文，实际「$text」",
                text.isNotEmpty() && text.none { it.code in 'a'.code..'z'.code || it.code in 'A'.code..'Z'.code },
            )
        }
    }

    @Test
    fun `陌生值的 label 回其他`() {
        assertEquals("其他", MediaCategoryNames.label(null))
        assertEquals("其他", MediaCategoryNames.label(""))
        assertEquals("其他", MediaCategoryNames.label("short"))
    }
}
