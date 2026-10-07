package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 刮削匹配闸门的**判据** —— [ScrapeMatch] / [titleSimilarity]。
 *
 * ## 为什么这一组必须钉死
 *
 * 这些阈值与档位是**跨端口径**：PC 端 `scrape_match.dart` 与这里算出的
 * 相似度只要差一点，同一个作品就会出现「电脑上刮得到、电视上刮不到」
 * （或反过来）—— 而这是**静默的**，用户只会觉得「电视上的刮削有时候不准」。
 *
 * 更要紧的是：闸门是自动刮削**唯一的**质量保证。它松一格，整库就会出现
 * 「片名 / 简介 / 海报被换成了另一部片子」这种用户很久才发现的问题
 * （下面 `182` 与「超级马力欧」两条用例都是真事故）。
 */
class ScrapeMatchTest {

    // ==================================================================
    // 归一化与相似度
    // ==================================================================

    /** 只留小写字母数字与汉字 —— 标点、空格、大小写都不参与比较。 */
    @Test
    fun `归一化只留字母数字与汉字`() {
        assertEquals("thewanderingearthii2", normalizeForMatch("The Wandering Earth II 2"))
        assertEquals("阿凡达火与烬", normalizeForMatch("阿凡达：火与烬"))
        assertEquals("", normalizeForMatch("—— · ——"))
    }

    /** 精确同名（归一化后相等）**无条件**给 1 —— 这是宽松档唯一的放行条件。 */
    @Test
    fun `归一化后相等即 1`() {
        assertEquals(1.0, titleSimilarity("阿凡达：火与烬", "阿凡达 火与烬"), 1e-9)
        assertEquals(1.0, titleSimilarity("Interstellar", "interstellar"), 1e-9)
    }

    /**
     * ⛔ 片名就叫《2012》《1917》的电影**照样刮得到**。
     *
     * 「纯数字不算名字」那条判据在精确相等**之后**才生效 —— 顺序反了的话，
     * 这两部电影会永远刮不出来。
     */
    @Test
    fun `纯数字片名精确相等时仍然通过`() {
        assertEquals(1.0, titleSimilarity("2012", "2012"), 1e-9)
        assertEquals(1.0, titleSimilarity("1917", "1917"), 1e-9)
    }

    /**
     * ⛔ PC 端 2026-10-02 真实事故：备用词 `182` 是希腊纪录片
     * 《1821: Οι Ήρωες》的前缀 ⇒ 0.9125 ⇒ 通过，整部家电维修教程被刮成了
     * 那部纪录片。**数字与数字之间没有语义关系**，一律不给分。
     */
    @Test
    fun `数字靠前缀沾边另一个数字不给分`() {
        assertEquals(0.0, titleSimilarity("182", "1821: Οι Ήρωες"), 1e-9)
        assertEquals(0.0, titleSimilarity("1080", "1080p"), 1e-9)
    }

    /** 前缀档：`仙逆` → `仙逆第一季`。同一部作品的分季命名都落在这一档。 */
    @Test
    fun `前缀档的公式是 0_65 加 0_35 乘长度比`() {
        assertEquals(0.79, titleSimilarity("仙逆", "仙逆第一季"), 1e-9)
        // 与文档里那两个「静默刮错」的现场读数一致（它们正是靠宽松档挡住的）。
        assertEquals(0.86, titleSimilarity("奥德赛", "奥德赛：归来"), 1e-9)
        assertEquals(0.825, titleSimilarity("英雄", "英雄本色"), 1e-9)
    }

    /** 包含档：查询带副标题而结果只有主名（或反过来）。 */
    @Test
    fun `包含档的公式是 0_55 加 0_25 乘长度比`() {
        // 「大电影」包含在「超级马力欧银河大电影」里。
        assertEquals(0.55 + 0.25 * (3.0 / 10.0), titleSimilarity("大电影", "超级马力欧银河大电影"), 1e-9)
    }

    /** 既非前缀也非包含时退回字符 bigram 的 Dice 系数（顺序不同但字符重合）。 */
    @Test
    fun `bigram 的 Dice 系数`() {
        // abcdef → ab,bc,cd,de,ef；abxcdef → ab,bx,xc,cd,de,ef；交集 4，共 11。
        assertEquals(8.0 / 11.0, titleSimilarity("abcdef", "abxcdef"), 1e-9)
    }

    /** 单字符之间没有 bigram，也就算不出相似度。 */
    @Test
    fun `单字符算不出 bigram 相似度`() {
        assertEquals(0.0, titleSimilarity("a", "b"), 1e-9)
    }

    // ==================================================================
    // 严格档：年份硬闸门 + 相似度分档
    // ==================================================================

    /**
     * ⛔ PC 端 2026-10-01 真实事故：查询带 `year=2026`，返回的是 1994 年的
     * 《低俗小说》，**代码完全没有察觉**。年份差 32 年 —— 这是最廉价也最
     * 可靠的判据，闸门就是被它抓到的。
     */
    @Test
    fun `年份差 32 年被硬闸门淘汰`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "超z级z马z力z欧z银z河z大z电影aa",
            queryYear = 2026,
            resultTitle = "低俗小说",
            resultYear = 1994,
        )
        assertEquals(ScrapeMatchVerdict.rejectYear, r.verdict)
        assertFalse(r.accepted)
        assertEquals(32, r.yearGap)
    }

    /** 阈值是「达到就淘汰」，差满 2 年即出局（发布年与首播年差 1 年是常态，不能误伤）。 */
    @Test
    fun `年份差达到阈值即淘汰`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "某某电影",
            queryYear = 2024,
            resultTitle = "某某电影",
            resultYear = 2022,
        )
        assertEquals(ScrapeMatchVerdict.rejectYear, r.verdict)
        assertEquals(2, r.yearGap)
    }

    /** 差 1 年**不**误伤：标题精确、年份差 1 ⇒ 通过。 */
    @Test
    fun `年份差一年不误伤`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "流浪地球",
            queryYear = 2019,
            resultTitle = "流浪地球",
            resultYear = 2018,
        )
        assertTrue(r.accepted)
        assertEquals(1, r.yearGap)
    }

    /** 严格档：相似度到 0.6 就无条件接受（前缀档 0.79 也在此列）。 */
    @Test
    fun `严格档相似度过 0_6 即接受`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "仙逆",
            queryYear = 2024,
            resultTitle = "仙逆第一季",
            resultYear = 2023,
        )
        assertTrue(r.accepted)
        assertEquals(0.79, r.similarity, 1e-9)
    }

    /**
     * 严格档：0.35~0.6 的「沾边」**必须有年份兜底**（差 0 或 1 年）。
     *
     * 《阿凡达：水之道》与《阿凡达：火与烬》相似度 0.40（只共前缀两个字），
     * 正好落在这条「沾边」带里 —— 有年份就能过，没年份一律拒。
     */
    @Test
    fun `严格档沾边时靠年份兜底`() {
        assertEquals(0.4, titleSimilarity("阿凡达水之道", "阿凡达火与烬"), 1e-9)

        val close = ScrapeMatch.evaluate(
            queryTitle = "阿凡达水之道",
            queryYear = 2022,
            resultTitle = "阿凡达火与烬",
            resultYear = 2022,
        )
        assertTrue(close.accepted)

        // 同样的相似度，但查询侧没有年份 ⇒ 兜不住 ⇒ 拒绝。
        val noYear = ScrapeMatch.evaluate(
            queryTitle = "阿凡达水之道",
            resultTitle = "阿凡达火与烬",
        )
        assertEquals(ScrapeMatchVerdict.rejectTitle, noYear.verdict)
        assertNull(noYear.yearGap)
    }

    /**
     * 相似度低于 0.35 且不跨书写系统 ⇒ 标题对不上。
     *
     * ⚠️ 这里**刻意不给年份**：给了年份的话先被硬闸门拦掉，测不到这条。
     */
    @Test
    fun `严格档相似度过低即拒绝`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "流浪地球",
            resultTitle = "星际穿越",
        )
        assertEquals(ScrapeMatchVerdict.rejectTitle, r.verdict)
        assertEquals(0.0, r.similarity, 1e-9)
    }

    /**
     * 跨书写系统：用英文备用词搜、结果是中文标题时字符集毫无交集，
     * 相似度天然为 0，只能靠年份兜底 —— 而且**必须真的有年份**。
     */
    @Test
    fun `跨书写系统时靠年份兜底`() {
        val withYear = ScrapeMatch.evaluate(
            queryTitle = "Interstellar",
            queryYear = 2014,
            resultTitle = "星际穿越",
            resultYear = 2014,
        )
        assertTrue(withYear.accepted)
        assertEquals(0.0, withYear.similarity, 1e-9)

        val noYear = ScrapeMatch.evaluate(
            queryTitle = "Interstellar",
            resultTitle = "星际穿越",
        )
        assertEquals(ScrapeMatchVerdict.rejectTitle, noYear.verdict)
    }

    // ==================================================================
    // 宽松档：无年份的电影只认精确同名
    // ==================================================================

    /**
     * ⛔ 宽松档的**全部意义**：无年份时前缀档会把 `奥德赛` 配到
     * 《奥德赛：归来》（0.86），而严格档的 0.6 阈值会让它无条件通过。
     */
    @Test
    fun `宽松档挡住前缀误配`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "奥德赛",
            resultTitle = "奥德赛：归来",
            requireExactTitle = true,
        )
        assertEquals(ScrapeMatchVerdict.rejectTitle, r.verdict)
        assertEquals(0.86, r.similarity, 1e-9)
    }

    /** 宽松档里精确同名照样放行（无年份的电影不能因此一部都刮不到）。 */
    @Test
    fun `宽松档放行精确同名`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "奥德赛",
            resultTitle = "奥德赛",
            requireExactTitle = true,
        )
        assertTrue(r.accepted)
        assertEquals(1.0, r.similarity, 1e-9)
    }

    /** 宽松档**不放松**年份硬闸门 —— 它是独立的一道，跑在前面。 */
    @Test
    fun `宽松档仍然先过年份硬闸门`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "奥德赛",
            queryYear = 2026,
            resultTitle = "奥德赛",
            resultYear = 1997,
            requireExactTitle = true,
        )
        assertEquals(ScrapeMatchVerdict.rejectYear, r.verdict)
    }

    // ==================================================================
    // 备用词与原名
    // ==================================================================

    /** 中文名搜不到时用英文备用词 —— 两边**四四组合取最高**。 */
    @Test
    fun `备用词参与比较`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "沙丘",
            queryAlternateTitle = "Dune",
            queryYear = 2021,
            resultTitle = "沙丘",
            resultYear = 2021,
        )
        assertTrue(r.accepted)

        // 中文名完全对不上、但备用词对上了原名 ⇒ 仍然通过。
        val byAlternate = ScrapeMatch.evaluate(
            queryTitle = "完全不相干的中文",
            queryAlternateTitle = "Interstellar",
            queryYear = 2014,
            resultTitle = "星际穿越",
            resultOriginalTitle = "Interstellar",
            resultYear = 2014,
        )
        assertTrue(byAlternate.accepted)
        assertEquals(1.0, byAlternate.similarity, 1e-9)
    }

    /** 空白备用词 / 空白原名不算一条候选（否则会拉低最高分）。 */
    @Test
    fun `空白的备用词与原名被忽略`() {
        val r = ScrapeMatch.evaluate(
            queryTitle = "沙丘",
            queryAlternateTitle = "   ",
            resultTitle = "沙丘",
            resultOriginalTitle = "",
        )
        assertTrue(r.accepted)
        assertEquals(1.0, r.similarity, 1e-9)
    }

    // ==================================================================
    // 跨端常量
    // ==================================================================

    /** 三个阈值是**跨端契约**，改这里必须同时改 PC 端 `scrape_match.dart`。 */
    @Test
    fun `三个阈值钉死`() {
        assertEquals(2, ScrapeMatch.MAX_YEAR_GAP)
        assertEquals(0.6, ScrapeMatch.STRONG_SIMILARITY, 1e-9)
        assertEquals(0.35, ScrapeMatch.WEAK_SIMILARITY, 1e-9)
    }

    /** 给日志看的一句话 —— 排查「为什么这部没刮到」时全靠它。 */
    @Test
    fun `结论理由说得清原因`() {
        val ok = ScrapeMatch.evaluate(queryTitle = "沙丘", queryYear = 2021, resultTitle = "沙丘", resultYear = 2021)
        assertTrue(ok.reason.startsWith("通过（相似度 1.00，年份差 0）"))

        val bad = ScrapeMatch.evaluate(queryTitle = "沙丘", queryYear = 2021, resultTitle = "沙丘", resultYear = 1984)
        assertEquals("年份差 37 年", bad.reason)
    }
}
