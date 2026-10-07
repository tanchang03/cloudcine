package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [FollowPlan] 的纯决策判据。
 *
 * 与 PC 端 `test/domain/follow_plan_test.dart` 用例**一一对应** —— 两端这套
 * 判据必须同口径，否则「电脑上追的剧会提醒、电视上不会」这种差异会变成
 * 一个没人能复现的玄学问题。
 *
 * ## 为什么这几条值得写
 *
 * 这个类里每一步的错法都是**静默的**：
 *
 *   * 目录没去重 → 12 集发 12 次列目录请求（会被夸克限流，但不报错）；
 *   * 失败目录也推进水位线 → 那批新集被永久划进「已读」，用户再也不会被提醒；
 *   * 一个目录覆盖多部作品却没全部回写 → `/电影/` 里同时更新的另外几部
 *     永远收不到提醒，而检查日志上一切正常。
 *
 * 三种都不会抛异常，只会在几周后表现成「这功能好像坏了」。所以判据必须在
 * **不碰 IO 的 JVM 单测**里被钉死 —— 这个类里没有 `LibraryDb`、没有网盘、
 * 没有时钟，正是为了这个。
 */
class FollowPlanTest {

    private fun dir(id: String, path: String, works: List<String>) =
        FollowDir(dirId = id, dirPath = path, workKeys = works.toSet())

    // ------------------------------------------------------------------
    // 去重与合并
    // ------------------------------------------------------------------

    @Test
    fun `同一个目录出现多次只列一次，且作品取并集`() {
        val plan = FollowPlan.of(
            listOf(
                dir("d1", "/剧集/黑亚当/", listOf("adam")),
                dir("d2", "/电影/", listOf("nolan")),
                // 12 集同目录：仓储层本该已去重，这里再喂一遍重复输入 ——
                // 计划本身必须是可信的（单测直接喂脏输入也应该得到对的计划）。
                dir("d1", "/剧集/黑亚当/", listOf("adam")),
                dir("d1", "/剧集/黑亚当/", listOf("adam")),
            ),
        )

        assertEquals(
            "同一部剧的 12 集通常在一个目录里，不去重就是 12 次列目录请求",
            2,
            plan.requestCount,
        )
        assertEquals(
            "顺序 = 首次出现顺序",
            listOf("d1", "d2"),
            plan.dirs.map { it.dirId },
        )
        assertEquals(setOf("d1"), plan.dirsByWork["adam"])
    }

    @Test
    fun `同一个目录的多个 workKeys 合并成并集`() {
        // 仓储层已经按 fid 聚合过，但 FollowPlan 自己也要兜住 ——
        // 一个目录同时被两部在追作品覆盖时，两份 workKeys 必须并起来。
        val plan = FollowPlan.of(
            listOf(
                dir("movies", "/电影/", listOf("a")),
                dir("movies", "/电影/", listOf("b")),
            ),
        )

        assertEquals(1, plan.requestCount)
        assertEquals(setOf("movies"), plan.dirsByWork["a"])
        assertEquals(setOf("movies"), plan.dirsByWork["b"])
    }

    @Test
    fun `路径取首次出现的那个（重复输入的路径不一致时不抖动）`() {
        val plan = FollowPlan.of(
            listOf(
                dir("d1", "/剧集/黑亚当/", listOf("adam")),
                dir("d1", "/剧集/黑亚当", listOf("adam")),
            ),
        )
        assertEquals("/剧集/黑亚当/", plan.dirs.single().dirPath)
    }

    // ------------------------------------------------------------------
    // 回写范围（红线 5：按目录回写，不是按发起者）
    // ------------------------------------------------------------------

    @Test
    fun `一个目录覆盖多部作品时全部推进`() {
        // `/电影/` 是平铺的：一个目录里几十部片子。
        val plan = FollowPlan.of(listOf(dir("movies", "/电影/", listOf("a", "b", "c"))))

        assertEquals(
            "只回写「发起检查的那一部」的话，同一个目录里同时更新的另外几部" +
                "永远收不到提醒 —— 而检查日志一切正常",
            setOf("a", "b", "c"),
            plan.checkedWorks(emptySet()),
        )
    }

    @Test
    fun `目录失败时它覆盖的作品都不推进，其它作品照常推进`() {
        val plan = FollowPlan.of(
            listOf(
                dir("movies", "/电影/", listOf("a", "b")),
                dir("tv", "/剧集/黑亚当/", listOf("adam")),
            ),
        )

        assertEquals(setOf("adam"), plan.checkedWorks(setOf("movies")))
    }

    // ------------------------------------------------------------------
    // 失败目录不推进水位线（红线 6）
    // ------------------------------------------------------------------

    @Test
    fun `一部作品有多个目录其中一个失败则整部不推进`() {
        val plan = FollowPlan.of(
            listOf(
                dir("d1", "/剧集/黑亚当/", listOf("adam")),
                dir("d2", "/剧集/黑亚当 S02/", listOf("adam")),
            ),
        )

        assertTrue(
            "水位线是「这里已经看过了」的承诺。d2 没读到，那批新集可能正好" +
                "在里面 —— 推进等于把它们永久划进「已读」，用户再也不会被提醒",
            plan.checkedWorks(setOf("d2")).isEmpty(),
        )
        assertEquals("两个目录都成功才推进", setOf("adam"), plan.checkedWorks(emptySet()))
    }

    @Test
    fun `失败的目录与任何作品都无关时不影响别人`() {
        val plan = FollowPlan.of(
            listOf(
                dir("movies", "/电影/", listOf("a")),
                dir("tv", "/剧集/黑亚当/", listOf("adam")),
            ),
        )
        assertEquals(setOf("a"), plan.checkedWorks(setOf("tv")))
    }

    // ------------------------------------------------------------------
    // 边界
    // ------------------------------------------------------------------

    @Test
    fun `一个目录都没有的作品不在结果里`() {
        // 在追的作品可能一条 media_items 都没有（或 dir_id 全是空串）。
        val plan = FollowPlan.of(emptyList())
        assertTrue(
            "我们什么都没检查，推进水位线等于凭空宣称「查过了」—— " +
                "之后它永远不会再被检查",
            plan.checkedWorks(emptySet()).isEmpty(),
        )
    }

    @Test
    fun `workKeys 为空集的目录照常要列但不推进任何作品`() {
        val plan = FollowPlan.of(listOf(dir("d1", "/电影/", emptyList())))
        assertEquals(1, plan.requestCount)
        assertTrue(plan.checkedWorks(emptySet()).isEmpty())
    }

    @Test
    fun `toString 不炸且带上两个计数`() {
        val plan = FollowPlan.of(listOf(dir("d1", "/电影/", listOf("a"))))
        assertTrue(plan.toString().contains("目录 1"))
        assertTrue(plan.toString().contains("作品 1"))
    }
}
