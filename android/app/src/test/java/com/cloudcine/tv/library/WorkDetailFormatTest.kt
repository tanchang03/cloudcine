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
     * 五颗胶囊的文案与顺序。
     *
     * ⛔ 顺序**必须**与 `LibraryActivity.buildDetailActions` 逐项一致 ——
     *    光标位置就是按这个下标存的，顺序错了就是「点了 A 执行 B」。
     *
     * ⚠️ 与设计文档 §5.2(d) 的**有意偏离**：「追剧」在第 2 位（紧挨播放），
     *    不是追加到末尾。理由见 [WorkDetailFormat.actionLabels] 的文档 ——
     *    「选集」必须留在最后（它是这一行的出口，`focusItemsList`）。
     *    这条断言就是那个位置的**唯一真源**：位置一改，它先红。
     */
    @Test
    fun `动作胶囊的顺序与文案`() {
        val labels = WorkDetailFormat.actionLabels(resumable = false, itemCount = 12)
        assertEquals(5, labels.size)
        assertEquals("▶ 播放", labels[0].first)
        assertEquals("☆ 追剧", labels[1].first)
        assertEquals("手动刮削", labels[2].first)
        assertEquals("刮削设置", labels[3].first)
        assertEquals("选集（12）", labels[4].first)
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
     * ⛔ 「追剧」也**不受影响**：一部还没入库任何文件的剧正是最该追的
     *    （网盘上刚建了个空目录）。
     */
    @Test
    fun `没有可播文件时只有播放与选集置灰`() {
        val labels = WorkDetailFormat.actionLabels(resumable = false, itemCount = 0)
        assertFalse("播放", labels[0].second)
        assertTrue("追剧不受影响", labels[1].second)
        assertTrue("手动刮削不受影响", labels[2].second)
        assertTrue("刮削设置不受影响", labels[3].second)
        assertFalse("选集", labels[4].second)
        // 文案里的计数仍然是 0（不是「选集（0 个）」那种别扭写法）。
        assertEquals("选集（0）", labels[4].first)
    }

    /** 有可播文件时五颗全亮。 */
    @Test
    fun `有可播文件时全部可用`() {
        assertTrue(WorkDetailFormat.actionLabels(resumable = true, itemCount = 1).all { it.second })
    }

    // ==================================================================
    // 追剧（schema v17）
    // ==================================================================

    /**
     * 「追剧」胶囊的三态。
     *
     * ⛔ 三个都**必须返回非空文案**（胶囊置灰不消失，红线）—— 所以这里钉的是
     *    文案，不是「有没有这一颗」。
     */
    @Test
    fun `追剧胶囊的三态文案`() {
        assertEquals("☆ 追剧", WorkDetailFormat.followLabel(followed = false, newCount = 0))
        // ⛔ 没追剧时**不缀**「0 新」：`new_item_count` 在没追时恒为 0，
        //    写出来是纯噪音。
        assertEquals("☆ 追剧", WorkDetailFormat.followLabel(followed = false, newCount = 5))
        assertEquals("★ 已追剧", WorkDetailFormat.followLabel(followed = true, newCount = 0))
        assertEquals("★ 已追剧 · 2 新", WorkDetailFormat.followLabel(followed = true, newCount = 2))
    }

    /**
     * 剧集行的「新集」前缀。
     *
     * ⛔ 不是新集时是**空串**而不是 `null`：调用方要拿它直接拼
     *    `SpannableString`，`null` 会把「拼 / 不拼」拆成两个分支。
     * ⛔ 前缀必须**自带尾随空白**：`■ NEW黑亚当.S01E13.mkv` 在沙发距离下
     *    会连成一片（方块字符与英文之间没有天然的字距）。
     */
    @Test
    fun `新集前缀`() {
        assertEquals("", WorkDetailFormat.newEpisodePrefix(isNew = false))
        val p = WorkDetailFormat.newEpisodePrefix(isNew = true)
        assertEquals("■ NEW  ", p)
        assertTrue("前缀必须自带尾随空白", p.endsWith(" "))
    }

    // ==================================================================
    // 「谁在发光」—— 简介页的三层光标态
    // ==================================================================

    /**
     * ⛔ **本组是这次修复的核心**（2026-10-11 用户反馈）。
     *
     * 简介页默认落在**动作胶囊**上（「▶ 播放」亮着），而焦点永远留在
     * 剧集列表上 —— 所以「列表选中行」与「胶囊光标态」会同时为真。
     * 两块都是亮品牌色实心，用户的原话是「有冲突……有干扰」。
     *
     * 不变量：**同一时刻只有一层在发光**。
     */
    @Test
    fun `胶囊持光标时列表选中行不发光`() {
        // 默认状态：焦点在列表（恒真）+ 光标在动作胶囊 + 首行是选中行。
        assertFalse(
            "光标在动作胶囊上时列表行还在发光 —— 屏幕上就有两块品牌色了",
            WorkDetailFormat.itemRowHighlighted(
                listFocused = true,
                actionsFocused = true,
                itemsSortFocused = false,
                isSelectedRow = true,
            ),
        )
        // 排序胶囊同理：它也是「胶囊行」，与动作行是同一种东西。
        assertFalse(
            "光标在排序胶囊上时列表行还在发光",
            WorkDetailFormat.itemRowHighlighted(
                listFocused = true,
                actionsFocused = false,
                itemsSortFocused = true,
                isSelectedRow = true,
            ),
        )
    }

    /** 光标交回列表（按 ↓ / 选中「选集」）⇒ 选中行的高亮必须**恢复**。 */
    @Test
    fun `光标交回列表后选中行恢复发光`() {
        assertTrue(
            "光标回到列表了，选中行却不亮 —— 用户会以为列表没有选中项",
            WorkDetailFormat.itemRowHighlighted(
                listFocused = true,
                actionsFocused = false,
                itemsSortFocused = false,
                isSelectedRow = true,
            ),
        )
    }

    /**
     * ⛔ 只有**选中那一行**发光。判据里 `isSelectedRow` 掉了的话，
     *    整个列表会一起亮起来（这个错在真机上极刺眼，但在纯逻辑上「多亮几行」
     *    看着毫无问题）。
     */
    @Test
    fun `未选中的行永远不发光`() {
        assertFalse(
            WorkDetailFormat.itemRowHighlighted(
                listFocused = true,
                actionsFocused = false,
                itemsSortFocused = false,
                isSelectedRow = false,
            ),
        )
    }

    /**
     * ⛔ 覆盖层（菜单 / 筛选面板 / 退出确认框）弹出时列表已经**失去焦点**，
     *    这时不许再画高亮 —— 否则覆盖层底下那层会「偷偷发光」。
     *    判据里省掉 `listFocused` 的话这一条就会漏。
     */
    @Test
    fun `列表失去焦点时不发光`() {
        assertFalse(
            WorkDetailFormat.itemRowHighlighted(
                listFocused = false,
                actionsFocused = false,
                itemsSortFocused = false,
                isSelectedRow = true,
            ),
        )
    }

    // ==================================================================
    // 片头 / 片尾那一行（schema v18）
    // ==================================================================

    /**
     * ⛔ **什么都没学出来时必须是 `null`**（整行 `GONE`），不能是空串。
     *    返回空串的话调用方会画出一行「高度还在、内容没有」的空白 ——
     *    简介页头部本来就挤，这一行空白是纯浪费。
     */
    @Test
    fun `没学出来时不画那一行`() {
        assertNull(WorkDetailFormat.skipLine(work()))
    }

    /**
     * 半条标记（只学到终点、没学到起点）当**没有** —— 判据与
     * `IntroMarker.fromMilliseconds` 共用一份实现。各写一套的话，症状是
     * 「手标的能跳、学出来的跳不了」。
     */
    @Test
    fun `半条标记不算学出来`() {
        assertNull(WorkDetailFormat.skipLine(work(learnedIntroEndMs = 92_000L)))
    }

    @Test
    fun `学出来的片头标成自动学习`() {
        assertEquals(
            "片头 00:00–01:32（自动学习）",
            WorkDetailFormat.skipLine(
                work(learnedIntroStartMs = 0L, learnedIntroEndMs = 92_000L),
            ),
        )
    }

    /**
     * ⛔ **手标优先**：库里两组列可以同时有值，生效的是手标那一条
     *    （取值链在 `IntroSession.marker`，这里只如实说出来）。压反了会让
     *    「我明明标过，它却按自己学的显示」。
     */
    @Test
    fun `手标压过学习`() {
        assertEquals(
            "片头 00:00–01:45（手动标注）",
            WorkDetailFormat.skipLine(
                work(
                    introStartMs = 0L,
                    introEndMs = 105_000L,
                    learnedIntroStartMs = 0L,
                    learnedIntroEndMs = 92_000L,
                ),
            ),
        )
    }

    /**
     * ⛔ 片尾写「距末尾 X」而不是绝对时间：各集片长不同，绝对时间在同一部剧
     *    里对不上。这一行上印绝对时间是**没有意义的数**。
     */
    @Test
    fun `片尾写距末尾的偏移`() {
        assertEquals(
            "片尾 距末尾 01:20（自动学习）",
            WorkDetailFormat.skipLine(work(learnedOutroOffsetMs = 80_000L)),
        )
    }

    /**
     * v19：**手标**的片尾优先于学出来的那条 —— 与片头那一半同一条取值链
     * （手标 > 学习），而括号里必须如实说「手动标注」。
     *
     * ⛔ 两条链各判各的：片头手标、片尾学习是完全合法的组合（用户在 PC 上
     *    只标了片头），不能因为片头是手标就把片尾也写成手标。
     */
    @Test
    fun `手标片尾压过学出来的片尾，且如实地标成手动标注`() {
        assertEquals(
            "片尾 距末尾 01:20（手动标注）",
            WorkDetailFormat.skipLine(
                work(outroOffsetMs = 80_000L, learnedOutroOffsetMs = 95_000L),
            ),
        )
    }

    @Test
    fun `片头手标 + 片尾学习：两个括号各说各的来源`() {
        assertEquals(
            "片头 00:00–01:00（手动标注） · 片尾 距末尾 01:35（自动学习）",
            WorkDetailFormat.skipLine(
                work(
                    introStartMs = 0L,
                    introEndMs = 60_000L,
                    learnedOutroOffsetMs = 95_000L,
                ),
            ),
        )
    }

    @Test
    fun `片头与片尾同时有值用间隔号连起来`() {
        assertEquals(
            "片头 00:00–01:32（自动学习） · 片尾 距末尾 01:20（自动学习）",
            WorkDetailFormat.skipLine(
                work(
                    learnedIntroStartMs = 0L,
                    learnedIntroEndMs = 92_000L,
                    learnedOutroOffsetMs = 80_000L,
                ),
            ),
        )
    }

    /** 偏移为 0 是「片尾就在最末尾」—— 跳它毫无意义，当没学过。 */
    @Test
    fun `片尾偏移为零不算数`() {
        assertNull(WorkDetailFormat.skipLine(work(learnedOutroOffsetMs = 0L)))
    }

    /**
     * ⛔ 「清除学习」只看**学习**结论，不看手标：手标是用户自己在电脑上标的，
     *    电视既改不了也不该由电视清掉 —— 给一颗点了没反应的菜单项比不给更糟。
     */
    @Test
    fun `只有手标时不提供清除学习的入口`() {
        assertFalse(
            WorkDetailFormat.canClearLearnedSkip(work(introStartMs = 0L, introEndMs = 105_000L)),
        )
    }

    @Test
    fun `学过片头或片尾才提供清除学习的入口`() {
        assertTrue(
            WorkDetailFormat.canClearLearnedSkip(
                work(learnedIntroStartMs = 0L, learnedIntroEndMs = 92_000L),
            ),
        )
        assertTrue(WorkDetailFormat.canClearLearnedSkip(work(learnedOutroOffsetMs = 80_000L)))
        assertFalse(WorkDetailFormat.canClearLearnedSkip(work()))
    }

    // ==================================================================
    // 片尾落点（schema v19）—— 手标与学习是两条独立支路
    // ==================================================================
    //
    // ⛔ 这两个方法**读的是两组不同的列**（`outro_offset_ms` vs
    //    `learned_outro_offset_ms`）。这里防的不是「换算写错」（那在
    //    `OutroSkipTest` 里），而是**读错列**：把 `outroStart` 实现成读学习那份，
    //    表现就是「在电脑上标了片尾，电视上不跳」。

    @Test
    fun `手标片尾落点用这一集的片长现算`() {
        val duration = 45 * 60_000L

        assertEquals(
            "存的是「距末尾 90 秒」，不是绝对时间 —— 各集片长不同",
            duration - 90_000L,
            work(outroOffsetMs = 90_000L).outroStart(duration),
        )
    }

    @Test
    fun `没标过片尾就没有落点`() {
        val duration = 45 * 60_000L

        assertNull(work().outroStart(duration))
        assertNull(work().learnedOutroStart(duration))
    }

    @Test
    fun `手标与学习各读各的列`() {
        val duration = 45 * 60_000L
        val w = work(outroOffsetMs = 120_000L, learnedOutroOffsetMs = 90_000L)

        assertEquals(
            "手标那份归 outroStart",
            duration - 120_000L,
            w.outroStart(duration),
        )
        assertEquals(
            "学习那份归 learnedOutroStart —— 合成一个方法就把优先级链藏起来了",
            duration - 90_000L,
            w.learnedOutroStart(duration),
        )
    }

    @Test
    fun `片长未知或偏移过大时片尾没有落点`() {
        assertNull(work(outroOffsetMs = 90_000L).outroStart(0L))
        assertNull(
            "偏移 ≥ 片长说明数据坏了（比如换了一集更短的），不跳比乱跳好",
            work(outroOffsetMs = 90_000L).outroStart(60_000L),
        )
        assertNull(work(learnedOutroOffsetMs = 90_000L).learnedOutroStart(60_000L))
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
        introStartMs: Long? = null,
        introEndMs: Long? = null,
        outroOffsetMs: Long? = null,
        learnedIntroStartMs: Long? = null,
        learnedIntroEndMs: Long? = null,
        learnedOutroOffsetMs: Long? = null,
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
        introStartMs = introStartMs,
        introEndMs = introEndMs,
        outroOffsetMs = outroOffsetMs,
        learnedIntroStartMs = learnedIntroStartMs,
        learnedIntroEndMs = learnedIntroEndMs,
        learnedOutroOffsetMs = learnedOutroOffsetMs,
    )
}
