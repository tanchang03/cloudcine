package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [PosterNaming] 的判据单测 —— 与 PC 端 `lib/data/scrape/poster_cache.dart` **逐字对拍**。
 *
 * ## 为什么这一组是必测的
 *
 * 海报文件名是 Android 与 PC 之间的**唯一约定**：`media_works.poster_file` 那一列
 * 实测 128 部**全是空**（PC 端自己从不回写），所以「作品 → 文件」只能靠文件名反推。
 * 命名规则一旦有**任何一个字符**与 Dart 侧不一致，症状不是崩溃，而是
 * **海报一张都不显示** —— 在电视上排查一次要十几分钟（要装机、要点进媒体库、
 * 要抓日志），而且看起来「像没下载过海报」。
 *
 * ## 参考值怎么来的（三重独立验证）
 *
 * 下面每个常量都经三条**互相独立**的路径算出，三者完全一致：
 *   1. 逐字搬运 Dart 源码到 `/tmp/cc_hashcheck.dart`，`dart run` 输出；
 *   2. 用 Python 重新实现一遍 FNV-1a（按 UTF-16 码元），结果相同；
 *   3. Kotlin 实现（本文件断言）。
 *
 * ⛔ **不要**「觉得某个值是随手写的就改掉」—— 改之前请重新跑一遍上面第 1 条。
 */
class PosterNamingTest {

    // ------------------------------------------------------------------
    // hash8：与 Dart `_hash8` 对拍
    // ------------------------------------------------------------------

    @Test
    fun `hash8 与 Dart 实现逐例一致`() {
        // ⛔ 断言值来自 `dart run cc_hashcheck.dart`，不是手算。
        assertEquals("690cfb22", PosterNaming.hash8("https://example.com/a.jpg"))
        assertEquals(
            "67cb0348",
            PosterNaming.hash8("https://video-play-h-zb.drive.quark.cn/media.m3u8?auth_key=1"),
        )
        assertEquals(
            "aced184c",
            PosterNaming.hash8(
                "https://img9.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg",
            ),
        )
        assertEquals("bba9eaa5", PosterNaming.hash8("凡人修仙传"))
        assertEquals("17e02210", PosterNaming.hash8("电影 2024 奥德赛"))
        assertEquals(
            "2b4be337",
            PosterNaming.hash8("x".repeat(61)),
        )
    }

    /**
     * ⛔ **代理对（emoji）必须按 UTF-16 码元散列，不是按码点。**
     *
     * Dart 的 `String.codeUnits` 给的是 UTF-16 码元（emoji = 两个码元），
     * Kotlin 的 `Char` 也是 UTF-16 码元 —— 两边天然一致。但若谁「顺手」把
     * Kotlin 改成遍历 `codePoints`（看起来更现代），emoji 作品的散列就会变，
     * 那部分海报**静默失效**。所以这里专门钉一条。
     */
    @Test
    fun `hash8 对代理对按 UTF-16 码元散列`() {
        assertEquals("d9537fe8", PosterNaming.hash8("emoji\uD83D\uDE00x"))
    }

    /**
     * ⛔ **初始值 `0x811C9DC5` 超过 `Int.MAX_VALUE`。**
     *
     * Kotlin 里直接写 `0x811C9DC5` 会被推成 `Long`，`xor`/`*=` 的溢出回绕语义
     * 就与 Dart 的 `& 0xFFFFFFFF` 分家了。实现里必须写 `0x811C9DC5L.toInt()`。
     * 这条用一个**必然走到溢出**的输入来暴露这个坑：单字符 `"a"`。
     * 期望值 = `(0x811C9DC5 ^ 0x61) * 0x01000193 mod 2^32` = `e40c292c`
     * （来自 `dart run`，不是手算 —— 手算这条我第一次就写错了）。
     */
    @Test
    fun `hash8 在溢出回绕下仍与 Dart 一致`() {
        assertEquals("e40c292c", PosterNaming.hash8("a"))
    }

    // ------------------------------------------------------------------
    // sanitize：字符替换
    // ------------------------------------------------------------------

    @Test
    fun `sanitize 只换路径分隔符与 Windows 保留字符 中文保留`() {
        assertEquals("电影_2024_奥德赛", PosterNaming.sanitize("电影 2024 奥德赛"))
        assertEquals(
            "a_b_c_d_e_f_g_h_i",
            PosterNaming.sanitize("a/b:c*d?e\"f<g>h|i"),
        )
        assertEquals("动画片", PosterNaming.sanitize("动画片"))
    }

    /**
     * ⛔ **Dart 的 `\s` 比 Java 的宽。**
     *
     * Dart `RegExp(r'\s')` 走 ECMAScript 语义，除 `[ \t\n\x0B\f\r]` 外**还包含**
     * `\u00A0`(NBSP)、`\u1680`、`\u2000-\u200A`、`\u2028`、`\u2029`、`\u202F`、
     * `\u205F`、`\u3000`(全角空格)、`\uFEFF`(BOM)。Kotlin 若图省事写
     * `Regex("\\s")` 或 `Character.isWhitespace()`，**全角空格与 NBSP 不会被替换**，
     * 文件名就与 PC 端对不上。
     *
     * ⛔ 作品键里的全角空格**真的会出现**：夸克目录名常是「凡人修仙传　第一季」
     *    （中间是全角空格），刮削归一化不一定会把它压成半角。
     */
    @Test
    fun `sanitize 必须覆盖 ECMAScript 的宽空白`() {
        // 全角空格 U+3000
        assertEquals("多_空_白_与_不换行", PosterNaming.sanitize("多 空 白\u3000与\u00A0不换行"))
        // 逐个验证 ECMAScript 空白集合里的每一个
        val wideSpaces = listOf(
            '\u00A0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005',
            '\u2006', '\u2007', '\u2008', '\u2009', '\u200A', '\u2028', '\u2029', '\u202F',
            '\u205F', '\u3000', '\uFEFF',
        )
        for (c in wideSpaces) {
            assertEquals(
                "宽空白 U+%04X 没被替换".format(c.code),
                "x_y",
                PosterNaming.sanitize("x${c}y"),
            )
        }
        // 反面：U+200B(零宽空格) 与 U+200C 不在 ECMAScript `\s` 里，**不该**被替换。
        // ⛔ 别「顺手」把零宽字符也加了 —— 那会让本实现与 PC 端分家。
        assertEquals("x\u200By", PosterNaming.sanitize("x\u200By"))
    }

    /**
     * ⛔ **截断后补的散列是「原键」的散列，不是「已替换过的串」的散列。**
     *
     * Dart：`'${cleaned.substring(0, 60)}_${_hash8(key)}'` —— 注意 `_hash8(key)`
     * 用的是**入参 key**。抄成 `_hash8(cleaned)` 时，键里只要有空格/斜杠就会
     * 静默算出另一个文件名。
     */
    @Test
    fun `超长键截断到 60 字符并补原键散列`() {
        val long = "很长很长".repeat(30) // 120 字符
        assertEquals(120, long.length)
        // ⛔ 60 个 UTF-16 码元 = `很长` × 30，**不是 × 15** —— 我第一次就写成 15 了。
        //    更阴的是 JUnit 的 `ComparisonCompactor` 会把长串**压成 20 字符上下文**
        //    再显示，报错里看到的前缀是假的，照着它改会越改越错。所以下面**先断言长度**。
        val expected = "很长".repeat(30) + "_9dbbf335"
        assertEquals(69, expected.length)
        val actual = PosterNaming.sanitize(long)
        assertEquals("截断后长度不对（散列是 9 位，60+1+8=69）", 69, actual.length)
        assertEquals(expected, actual)

        // 边界：正好 60 字符**不截断**（Dart 是 `<= 60` 直接返回）
        val exact = "a".repeat(60)
        assertEquals(exact, PosterNaming.sanitize(exact))
        // 61 字符才截断
        assertEquals(
            "a".repeat(60) + "_" + PosterNaming.hash8("a".repeat(61)),
            PosterNaming.sanitize("a".repeat(61)),
        )
    }

    // ------------------------------------------------------------------
    // fileNameFor / indexKeyOf：往返
    // ------------------------------------------------------------------

    @Test
    fun `fileNameFor 与 Dart 输出逐字一致`() {
        assertEquals(
            "电影_2024_奥德赛_690cfb22.jpg",
            PosterNaming.fileNameFor("电影 2024 奥德赛", "https://example.com/a.jpg"),
        )
    }

    @Test
    fun `indexKeyOf 能反推出归一化作品键`() {
        assertEquals(
            "电影_2024_奥德赛",
            PosterNaming.indexKeyOf("电影_2024_奥德赛_690cfb22.jpg"),
        )
    }

    /**
     * ⛔ **作品键自己带下划线是常态**（`剧集_凡人修仙传_S01`、`电影_2024_…`）。
     *
     * 所以切割只能砍**最后一段**（`lastIndexOf('_')`）。若谁写成 `indexOf('_')`
     * 或按 `split('_')` 取头，绝大多数键都会被切残 —— 而症状还是「海报不显示」。
     */
    @Test
    fun `键里带下划线时只砍最后一段`() {
        assertEquals(
            "剧集_凡人修仙传_S01",
            PosterNaming.indexKeyOf("剧集_凡人修仙传_S01_deadbeef.jpg"),
        )
        assertEquals(
            "电影_2024_奥德赛",
            PosterNaming.indexKeyOf("电影_2024_奥德赛_690cfb22.JPG"),
        )
        // 大写散列也认（文件系统可能改过大小写）
        assertEquals(
            "电影_2024_奥德赛",
            PosterNaming.indexKeyOf("电影_2024_奥德赛_690CFB22.jpg"),
        )
    }

    @Test
    fun `indexKeyOf 拒绝不像海报文件的名字`() {
        assertNull("没有下划线", PosterNaming.indexKeyOf("海报.jpg"))
        assertNull("后缀不对", PosterNaming.indexKeyOf("电影_2024_奥德赛_690cfb22.png"))
        assertNull("散列位数不对", PosterNaming.indexKeyOf("电影_abc.jpg"))
        assertNull("散列不是十六进制", PosterNaming.indexKeyOf("电影_zzzzzzzz.jpg"))
        assertNull("散列前没有键", PosterNaming.indexKeyOf("_690cfb22.jpg"))
        assertNull("目录里的其它文件", PosterNaming.indexKeyOf("README.txt"))
        assertNull(PosterNaming.indexKeyOf(""))
    }

    /**
     * 往返：`fileNameFor` 产出的名字，必须能被 `indexKeyOf` 反推回**同一个键**。
     *
     * ⛔ 注意反推回来的是 `sanitize(key)` 而不是 `key` —— 因为文件系统里存的就是
     *    替换过的形式，而 `PosterStore` 查表用的键也是 `sanitize(work.key)`。
     *    两边都过同一个函数，这才是索引能命中的前提。
     */
    @Test
    fun `文件名往返一致`() {
        val cases = listOf(
            "电影 2024 奥德赛" to "https://example.com/a.jpg",
            "剧集|凡人修仙传|S01" to "https://img.example.com/p2.jpg",
            "多 空 白\u3000与\u00A0不换行" to "https://img.example.com/p3.jpg",
        )
        for ((key, url) in cases) {
            val file = PosterNaming.fileNameFor(key, url)
            assertEquals(
                "往返失败：$file",
                PosterNaming.sanitize(key),
                PosterNaming.indexKeyOf(file),
            )
        }
    }
}
