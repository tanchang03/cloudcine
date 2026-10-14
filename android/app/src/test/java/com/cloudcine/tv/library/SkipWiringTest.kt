package com.cloudcine.tv.library

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 片头 / 片尾这条链路的**接线守卫**（读源文件，与 `ProgressWiringTest` /
 * `LibraryActivityWiringTest` 同一套路）。
 *
 * ## 为什么必须用静态检查
 *
 * 这条链路上最要命的一种漏法**不是算错，而是「读了但没用」**：
 *
 * ```
 * LibraryDb 读出来 → Work.outroOffsetMs → 简介页显示「片尾 距末尾 01:20（手动标注）」
 *                                      ↘ 播放器：从来不看这一列
 * ```
 *
 * 界面一切正常、日志一切正常、单元测试（测的是纯函数）也全绿 —— 只有真正
 * 播到片尾时才发现「没跳」。这一条正是 2026-10-11 加 v19 手标片尾时实际
 * 漏掉的：`Work` 上写了「播放器**必须读**」，`PlayerActivity` 里却没读。
 *
 * ⛔ 所以这里钉的不是数值，而是**接线本身**：
 *
 *   1. `loadSkipConfig` 必须把 `outro_offset_ms`（手标）与
 *      `learned_outro_offset_ms`（学习）**两条支路都读进来**；
 *   2. `maybeHandleOutro` 必须走 `OutroSkip` 的取值链（手标 > 学习），
 *      而不是直接拿学习那一份；
 *   3. `Work.outroStart` / `learnedOutroStart` 必须委托给同一份换算实现
 *      —— 各写一遍迟早漂移成「手标的能跳、学出来的跳不了」。
 *
 * ⛔ **必须先剔掉注释**：本仓库的文档注释里到处写着 `` `outro_offset_ms` ``
 *    这种说明性引用，不剔的话「把赋值行注释掉」会被判成「还在」。
 */
class SkipWiringTest {

    private val appDir = File("src/main/java/com/cloudcine/tv")

    // ------------------------------------------------------------------
    // 1. 播放器：两条支路都要读
    // ------------------------------------------------------------------

    @Test
    fun `播放器把手标与学习两条片尾支路都读进来`() {
        val code = codeOnly(read("PlayerActivity.kt"))

        assertTrue(
            "PlayerActivity 里找不到 `manualOutroOffsetMs = work?.outroOffsetMs`。" +
                "手标那一列唯一的来源是 PC 端（电视上没有界面可写），不读的话" +
                "「在电脑上标了片尾，电视上不跳」—— 而两端都不报错，用户只觉得时灵时不灵。",
            code.contains("manualOutroOffsetMs = work?.outroOffsetMs"),
        )
        assertTrue(
            "PlayerActivity 里找不到 `learnedOutroOffsetMs = work?.learnedOutroOffsetMs`。" +
                "学习结论是电视上片尾唯一的来源，漏了它整个片尾学习功能等于没接上。",
            code.contains("learnedOutroOffsetMs = work?.learnedOutroOffsetMs"),
        )
    }

    @Test
    fun `换流时手标片尾也要归零`() {
        val code = codeOnly(read("PlayerActivity.kt"))
        val body = functionBody(code, "private fun loadSkipConfig(")
        assertTrue("抽不出 loadSkipConfig 的函数体 —— 正则已脱节", body.isNotEmpty())

        assertTrue(
            "loadSkipConfig 的「没有库记录」分支里没有把 `manualOutroOffsetMs` 归零。" +
                "换流不归零的话，上一条流的片尾偏移会打到新一集上 —— 表现是" +
                "「刚切过去画面自己跳一下」，而日志里看不出任何异常。",
            body.contains("manualOutroOffsetMs = null"),
        )
    }

    // ------------------------------------------------------------------
    // 2. 判定：必须走取值链，不能只看学习
    // ------------------------------------------------------------------

    @Test
    fun `片尾判定走 OutroSkip 的取值链`() {
        val code = codeOnly(read("PlayerActivity.kt"))
        val body = functionBody(code, "private fun maybeHandleOutro(")
        assertTrue("抽不出 maybeHandleOutro 的函数体 —— 正则已脱节", body.isNotEmpty())

        assertTrue(
            "maybeHandleOutro 里没有 `OutroSkip.effectiveOffsetMs(...)`。" +
                "手标优先于学习这条链只能有一份实现（`OutroSkip`）—— " +
                "各写一遍迟早漂移成「片头认手标、片尾只认学习」。",
            body.contains("OutroSkip.effectiveOffsetMs("),
        )
        assertTrue(
            "maybeHandleOutro 里没有 `OutroSkip.startMs(...)`。" +
                "片尾存的是「距末尾偏移」，落点必须用这一集的片长现算 —— " +
                "片长未知 / 偏移比片长还大时返回 null（不跳也不提示）。",
            body.contains("OutroSkip.startMs("),
        )
        assertTrue(
            "maybeHandleOutro 里又出现了裸的 `learnedOutroOffsetMs ?: return` —— " +
                "那就是 2026-10-11 那个 bug 的原样（手标被完全绕过）。",
            !body.contains("learnedOutroOffsetMs ?:"),
        )
    }

    // ------------------------------------------------------------------
    // 3. 换算：两条支路共用同一份实现
    // ------------------------------------------------------------------

    @Test
    fun `Work 的两个片尾落点都委托给 OutroSkip`() {
        val code = codeOnly(read("library/LibraryModels.kt"))

        for (name in listOf("outroStart", "learnedOutroStart")) {
            assertTrue(
                "Work.$name 没有委托给 `OutroSkip.startMs`。读的是两组**独立**的列，" +
                    "但「片长 - 偏移」这条换算规则只能有一份 —— 各写一遍的典型症状是" +
                    "「手标的能跳、学出来的跳不了」（或反过来），而两边都不报错。",
                Regex("""fun\s+$name\s*\([^)]*\)\s*:\s*Long\?\s*=\s*\n?\s*OutroSkip\.startMs\(""")
                    .containsMatchIn(code),
            )
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private fun read(rel: String): String {
        val f = File(appDir, rel)
        assertTrue(
            "读不到源文件：${f.absolutePath}（当前目录 ${File(".").absolutePath}）。\n" +
                "本测试依赖 Gradle 的 test 工作目录 = 模块目录（android/app）。",
            f.isFile,
        )
        return f.readText()
    }

    /**
     * 剔除注释后的源码。
     *
     * ⛔ 行级过滤而不是正则剥块注释：源文件里有网盘 URL 之类的字符串字面量，
     *    按 `//` 粗暴切断会把 `"https://…"` 的后半截连同引号一起吃掉。
     */
    private fun codeOnly(src: String): String =
        src.lines().filterNot { line ->
            val t = line.trimStart()
            t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
        }.joinToString("\n")

    /** 取一个函数的函数体：从声明到下一个「同缩进的 `}`」。 */
    private fun functionBody(code: String, header: String): String {
        val start = code.indexOf(header)
        if (start < 0) return ""
        val open = code.indexOf('{', start)
        if (open < 0) return ""
        var depth = 0
        for (i in open until code.length) {
            when (code[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return code.substring(open, i + 1)
                }
            }
        }
        return code.substring(open)
    }
}
