package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [PlayTarget] 的取舍规则单测 —— 与 PC 端 `play_target_test.dart` 同口径。
 *
 * ## 为什么这一组是必测的
 *
 * 「点海报播哪一条」错了**不会报错、不会崩**，只是播了一集用户不想看的：
 *   * 播到花絮 ⇒ 用户点《流浪地球 2》看到 40 秒预告片；
 *   * 播到第一集，而他看到第 20 集了 ⇒ 每次都要手动翻回去；
 *   * 猜「下一集」猜错 ⇒ 把用户丢到一集他根本没看过的内容上。
 * 这三种都只能靠用户投诉发现，所以规则本身要钉死。
 */
class PlayTargetTest {

    /** 造一条最小可用的条目。 */
    private fun item(
        name: String,
        resumeMs: Long? = null,
        lastPlayedAt: Long? = null,
        sample: Boolean = false,
    ) = LibraryItem(
        id = name,
        provider = "quark",
        fileId = "fid-$name",
        dirId = "dir",
        name = name,
        dirPath = "/x/",
        groupKey = "work",
        kind = "episode",
        title = null,
        year = null,
        season = 1,
        episode = null,
        episodeEnd = null,
        part = null,
        partLabel = null,
        container = "mkv",
        resolution = null,
        sizeBytes = null,
        durationMs = null,
        resumePositionMs = resumeMs,
        maxPositionMs = null,
        lastPlayedAt = lastPlayedAt,
        thumbUrl = null,
        faceAnchorX = null,
        videoWidth = null,
        videoHeight = null,
        isSampleOrExtra = sample,
    )

    @Test
    fun `作品下没有条目时返回 null`() {
        assertNull(PlayTarget.resolve(emptyList()))
    }

    @Test
    fun `只有一条时就是它`() {
        val only = item("E01")
        assertEquals(only, PlayTarget.resolve(listOf(only)))
    }

    @Test
    fun `一条都没播过时播第一条`() {
        val items = listOf(item("E01"), item("E02"), item("E03"))
        assertEquals("E01", PlayTarget.resolve(items)?.name)
    }

    /**
     * ⛔ **最高优先级**：还留着续播点的那一集。
     *
     * 用户点卡片最常见的意图就是「接着上次看」—— 哪怕他后来又点开过别的集。
     */
    @Test
    fun `有续播点时优先播那一集 —— 而不是第一条`() {
        val items = listOf(item("E01"), item("E02", resumeMs = 600_000), item("E03"))
        assertEquals("E02", PlayTarget.resolve(items)?.name)
    }

    /**
     * 多个续播点时取**最近播过的**那一个（`lastPlayedAt` 最大）。
     *
     * ⛔ 不是「列表里最后一个」：用户可能回头补第 3 集，那第 20 集的续播点
     *    仍然在，而他要接着看的还是第 20 集。
     */
    @Test
    fun `多个续播点时取最近播放的那一条`() {
        val items = listOf(
            item("E03", resumeMs = 100, lastPlayedAt = 1_000),
            item("E20", resumeMs = 100, lastPlayedAt = 9_000),
            item("E21", resumeMs = 100, lastPlayedAt = 5_000),
        )
        assertEquals("E20", PlayTarget.resolve(items)?.name)
    }

    /**
     * 续播点存在、但**一个播放时刻都没有**（老库 / 手工导入的位置）时，
     * 退到列表顺序的最后一个 —— 也就是集号最大的那一集。
     *
     * ⛔ 不是「第一条」：那等于把「他看到第 20 集」这件事抹掉。
     */
    @Test
    fun `续播点存在但没有播放时刻时退到列表最后一个`() {
        val items = listOf(
            item("E01"),
            item("E02", resumeMs = 100),
            item("E03", resumeMs = 100),
        )
        assertEquals("E03", PlayTarget.resolve(items)?.name)
    }

    /**
     * ⛔ 有播放记录、但那一集**已经看完**（续播点被清成 null）⇒ 仍然回到那一集。
     *
     * 关键是**不要去猜「下一集」**：`lastPlayedAt` 有值 + 没有续播点，既可能是
     * 「看完了」，也可能是「点开 3 秒就关了」。猜错会把用户丢到一集他根本没看过的
     * 内容上，而猜错的代价远大于「重看一集的开头」。
     */
    @Test
    fun `看完的那一集仍然播它 不猜下一集`() {
        val items = listOf(
            item("E01", resumeMs = null, lastPlayedAt = 1_000),
            item("E02", resumeMs = null, lastPlayedAt = 8_000),
            item("E03", resumeMs = null, lastPlayedAt = 2_000),
        )
        assertEquals("E02", PlayTarget.resolve(items)?.name)
    }

    /**
     * ⛔ **花絮 / 样片 / 预告必须被滤掉**。
     *
     * 不滤的话用户点《流浪地球 2》会看到 40 秒的预告片 —— 而预告片的
     * `lastPlayedAt` 往往比正片新（刚才点开过），所以「不滤」甚至会让
     * 优先级①直接命中它。
     */
    @Test
    fun `花絮不参与挑选 即使它的播放时刻最新`() {
        val items = listOf(
            item("E01"),
            item("E02"),
            item("预告片", sample = true, resumeMs = 5_000, lastPlayedAt = 99_000),
        )
        assertEquals("E01", PlayTarget.resolve(items)?.name)
    }

    /**
     * 整组都是花絮时**退回全部** —— 只有花絮的作品也该能点开，
     * 否则那些条目在媒体库界面上等于不存在。
     */
    @Test
    fun `整组都是花絮时仍然能选出一条`() {
        val items = listOf(item("花絮1", sample = true), item("花絮2", sample = true))
        assertEquals("花絮1", PlayTarget.resolve(items)?.name)
    }

    @Test
    fun `列表顺序就是季集顺序 第一条即第一集`() {
        // `LibraryDb.itemsForWork` 的承诺是「季 → 部 → 集 → 名称」，
        // 这里刻意**不重排**（重排就多一份可能与仓储层不一致的实现）。
        val items = listOf(item("S01E01"), item("S01E02"), item("S02E01"))
        assertEquals("S01E01", PlayTarget.resolve(items)?.name)
    }
}
