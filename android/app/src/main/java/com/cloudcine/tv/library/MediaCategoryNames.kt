package com.cloudcine.tv.library

/**
 * 媒体库**一级分类**的名称与展示标签 —— 与 PC 端
 * `lib/core/utils/media_category.dart` 的 `MediaCategory` 同口径。
 *
 * ## 为什么是「字符串常量 + 两个函数」而不是 enum
 *
 * 库里 `media_works.category` 存的是**枚举名字符串**（`movie` / `series` / …），
 * 而且是**跨端共享的 schema**：PC 端加一个分类时 Android 端可能还没更新。
 * 用 enum 的话，读到一个不认识的字符串要么抛异常、要么得写一堆
 * `fromName` 兜底；用字符串则**天然容错**，认不出来就落「其他」——
 * 与 PC 端 `MediaCategory.fromName` 的兜底规则一致（「分类是展示维度，
 * 读到一个陌生值时降级显示远好于抛异常」）。
 *
 * ⛔ **中文标签必须从这里取**。之前卡片副标题直接把库里的 `category`
 *    原样印出来，电视上显示成 `movie · 2026`、`anime · 2020` ——
 *    用户看到的是数据库字段名，不是分类名。
 */
object MediaCategoryNames {

    const val MOVIE = "movie"
    const val SERIES = "series"
    const val ANIME = "anime"
    const val VARIETY = "variety"
    const val DOCUMENTARY = "documentary"
    const val OTHER = "other"

    /**
     * 分类栏的固定顺序 —— **照抄 PC 端 `MediaCategory.displayOrder`**。
     *
     * ⛔ 「其他」**必须垫底**，不能按枚举声明顺序。它是个兜底桶，
     *    摆在中间会把正常分类挤到右边。
     */
    val displayOrder: List<String> =
        listOf(MOVIE, SERIES, ANIME, VARIETY, DOCUMENTARY, OTHER)

    /** 认不出来的（含 `null` / 空串）一律回 [OTHER]，与 PC 端 `fromName` 一致。 */
    fun normalize(name: String?): String =
        if (name != null && name in displayOrder) name else OTHER

    /** 界面展示名。 */
    fun label(name: String?): String = when (normalize(name)) {
        MOVIE -> "电影"
        SERIES -> "剧集"
        ANIME -> "动漫"
        VARIETY -> "综艺"
        DOCUMENTARY -> "纪录片"
        else -> "其他"
    }
}
