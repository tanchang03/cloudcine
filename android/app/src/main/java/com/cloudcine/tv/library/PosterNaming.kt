package com.cloudcine.tv.library

/**
 * 海报缓存文件名 —— 与 PC 端 `lib/data/scrape/poster_cache.dart` **逐字一致**。
 *
 * ## 为什么必须自己算文件名
 *
 * PC 端把海报存成 `{归一化作品键}_{URL 散列 8 位}.jpg` 落在 `<support>/posters/`，
 * 备份包把整个目录原样搬过来。而 `media_works.poster_file` 这一列
 * **实测 128 部全是空**（2026-10-06 真机日志：`有 poster_file 0 · 海报目录 325 个文件`）
 * —— PC 端自己也从不回写它（见 `poster_cache.dart` `_download` 的注释：
 * 「**没有任何代码把下载结果写回那一列**」）。所以 Android 端想显示海报，
 * **只能自己把文件名算出来**；算错一个字符就是「一张都不显示」，且不报任何错。
 *
 * ## 两个反直觉点（都是踩过的）
 *
 * 1. **归一化的「空白」比 Java 的 `\s` 宽**。Dart 的 `RegExp(r'\s')` 按
 *    ECMAScript 定义，连 `\u00A0`（不换行空格）、`\u3000`（全角空格）、
 *    `\uFEFF` 都算；而 Java/Kotlin 的 `\s` 只有 `[ \t\n\x0B\f\r]`。
 *    作品名里出现一个全角空格，两边文件名就对不上 —— 所以这里**逐字符列举**，
 *    不图省事用 `\s`。
 * 2. **截断后补的是「原键」的散列，不是「已归一化字符串」的散列**
 *    （`_hash8(key)` 而不是 `_hash8(cleaned)`）。两者在长键上结果不同。
 */
object PosterNaming {

    /** 归一化后超过这个长度就截断（多数文件系统 255 字节，中文一个字符 3 字节）。 */
    private const val MAX_SAFE_LEN = 60

    private const val SUFFIX = ".jpg"

    /**
     * 作品键 → 文件系统安全形式。
     *
     * 中文**保留**（便于人工排查缓存），只替换路径分隔符、Windows 保留字符
     * 与空白。
     */
    fun sanitize(key: String): String {
        val cleaned = StringBuilder(key.length)
        for (c in key) cleaned.append(if (isUnsafe(c)) '_' else c)
        if (cleaned.length <= MAX_SAFE_LEN) return cleaned.toString()
        return cleaned.substring(0, MAX_SAFE_LEN) + "_" + hash8(key)
    }

    /** 完整缓存文件名：`{归一化键}_{URL 散列 8 位}.jpg`。 */
    fun fileNameFor(key: String, url: String): String = "${sanitize(key)}_${hash8(url)}$SUFFIX"

    /**
     * 从缓存文件名反推**作品键的归一化形式**（建目录索引用）。
     *
     * 名字形如 `电影_2024_奥德赛_1a2b3c4d.jpg` ⇒ 砍掉扩展名、再砍掉**最后一个**
     * `_` 之后的那段散列 ⇒ `电影_2024_奥德赛`。
     *
     * ⛔ 只能砍**最后一段**：归一化本身会把不安全字符换成 `_`，
     *    所以前缀里出现 `_` 是常态，按第一个 `_` 切会把键切碎。
     *
     * @return 认不出形状（没有 `_`、没有扩展名、散列段不是 8 位十六进制）时返回 null。
     */
    fun indexKeyOf(fileName: String): String? {
        if (!fileName.endsWith(SUFFIX, ignoreCase = true)) return null
        val stem = fileName.substring(0, fileName.length - SUFFIX.length)
        val cut = stem.lastIndexOf('_')
        if (cut <= 0) return null
        val hash = stem.substring(cut + 1)
        if (hash.length != 8 || !hash.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) {
            return null
        }
        return stem.substring(0, cut)
    }

    /**
     * FNV-1a 32 位 → 8 位小写十六进制。
     *
     * ⛔ 作用在 **UTF-16 码元**上（Dart `String.codeUnits` / Kotlin `Char` 迭代），
     *    不是字节、也不是码点 —— 中文键上三者结果完全不同。
     * ⛔ 不用 `String.hashCode()`：PC 端特意避开它，因为「跨 Dart 版本/平台
     *    不保证一致」，换一次运行时整库缓存就全失效。
     */
    fun hash8(input: String): String {
        // 0x811C9DC5 = 2166136261 > Int.MAX_VALUE ⇒ 必须走 Long 再截断。
        var hash = 0x811C9DC5L.toInt()
        for (c in input) {
            hash = hash xor c.code
            // Kotlin 的 Int 乘法**溢出即回绕**（保留低 32 位），
            // 与 Dart 的 `(x * 0x01000193) & 0xFFFFFFFF` 逐位等价。
            hash *= 0x01000193
        }
        return (hash.toLong() and 0xFFFFFFFFL).toString(16).padStart(8, '0')
    }

    /**
     * PC 端会替换成 `_` 的字符。
     *
     * ⛔ 这是 **ECMAScript 的 `\s`**（Dart 用的就是它），不是 Java 的 `\s`。
     *    漏掉 `\u00A0` / `\u3000` 这类空格，文件名就会差一个字符。
     */
    private fun isUnsafe(c: Char): Boolean = when (c) {
        '\\', '/', ':', '*', '?', '"', '<', '>', '|' -> true
        // ECMAScript WhiteSpace + LineTerminator 里的 ASCII 部分。
        ' ', '\t', '\n', '\u000B', '\u000C', '\r' -> true
        // 其余空白：NBSP / OGHAM / 行分隔 / 段分隔 / 窄 NBSP / 中等数学空格 /
        // 全角空格 / ZWNBSP。
        '\u00A0', '\u1680', '\u2028', '\u2029', '\u202F', '\u205F', '\u3000', '\uFEFF' -> true
        // EN QUAD … HAIR SPACE。
        in '\u2000'..'\u200A' -> true
        else -> false
    }
}
