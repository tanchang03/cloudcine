package com.cloudcine.tv.library

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「**归一并集口径**」的接线守卫。
 *
 * ## 为什么这组断言值得写
 *
 * 归一（`mergeWorksInto`）只给**源作品行**打一个 `merged_into` 标记，
 * **从不改写 `media_items.group_key`**。于是「这部作品有哪些文件」= 自己名下的
 * ∪ 所有折进来的源名下的。任何一处漏掉并集都**不报错、不崩**，只是数字变小：
 *
 *   · 简介页列表少文件（2026-10-07 真机：「遮天」PC 端 13 个，TV 端 1 个）；
 *   · 卡片写「1 集」而详情页列着 13 行 —— 同一个数字两处自相矛盾；
 *   · 追剧检查明明发现了新集，页面上却看不见。
 *
 * ## 为什么是「读源文件」而不是跑 SQL
 *
 * 本工程刻意不引 Robolectric，`LibraryDb` 依赖 `android.database.sqlite`，
 * JVM 单测里跑不起来。而这里要守的三条恰好都是**源码形状**：
 * SQL 是不是并集、并集写在了哪一层、UI 有没有重读。静态检查反而更直接。
 *
 * ⛔ **必须先剔掉注释再匹配**：本仓库的文档注释里到处写着 `` `merged_into = ?` ``
 *    这类**说明性引用**，不剔注释的话，「把并集删掉、只留注释里的例子」会被
 *    判成「还在」—— 守卫在最需要它的那一刻放行，等于没有守卫。
 */
class LibraryUnionGuardTest {

    private val dbFile = File("src/main/java/com/cloudcine/tv/library/LibraryDb.kt")
    private val activityFile = File("src/main/java/com/cloudcine/tv/LibraryActivity.kt")

    /**
     * `itemsForWork` 必须是并集。
     *
     * 这是用户 2026-10-07 报的那个现象的直接根因：TV 端简介页只显示 1 个文件，
     * 而 PC 端有 13 个（真库：`z遮天` 12 条 `merged_into = shroudingtheheavens`，
     * 后者自己名下 1 条）。
     */
    @Test
    fun `itemsForWork 必须并上折进来的源作品`() {
        val code = codeOnly(dbSource())
        assertTrue(
            "LibraryDb 的代码区里找不到 `merged_into = ?`。\n" +
                "`itemsForWork` 必须查「自己名下 ∪ 所有 merged_into = 自己的源名下」。\n" +
                "只查 `group_key = ?` 会漏掉全部折进来的文件 —— 真机现场：「遮天」" +
                "PC 端 13 个文件、TV 端简介页只有 1 个。",
            code.contains("merged_into = ?"),
        )
    }

    /**
     * ⛔⛔ 性能红线：`WORK_COLUMNS` 里那个**逐行**的进度子查询只能是等值。
     *
     * 真库实测（201 部 / 2866 条）：等值 `i.group_key = media_works.key` 时
     * SQLite 会给 `media_items.group_key` 建**自动索引**，500 行 **21ms**；
     * 一旦改成 `IN (SELECT …)` 变成 **7.5 秒**，`… OR … IN (SELECT …)` 是
     * **4.9 秒**（逐行全表扫）。
     *
     * 所以并集口径的进度必须由**页级**查询（`withUnionStats`）补，不能塞进这条
     * 相关子查询。这个坑**不报错、不崩**，只是媒体库打开一次要等 7 秒。
     */
    @Test
    fun `WORK_COLUMNS 的进度子查询必须走等值`() {
        val code = codeOnly(dbSource())
        val start = code.indexOf("private const val WORK_COLUMNS =")
        assertTrue(
            "没能从 LibraryDb.kt 的代码区里找到 `private const val WORK_COLUMNS =` —— " +
                "常量改名了请同步改本测试，别让它静默绿灯。",
            start >= 0,
        )
        val end = code.indexOf("private const val ", start + 1)
        assertTrue("没找到 WORK_COLUMNS 之后的常量声明（本测试靠它切出片段）。", end > start)
        val seg = code.substring(start, end)

        assertTrue(
            "WORK_COLUMNS 的 resume_fraction 不再是等值 `i.group_key = media_works.key`。\n" +
                "真库实测：等值 500 行 21ms；`IN (SELECT …)` 7.5 秒、`OR` 版 4.9 秒" +
                "（自动索引用不上，逐行全表扫）。\n" +
                "并集口径的进度要放到页级查询 `withUnionStats` 里算（实测 4ms）。",
            seg.contains("i.group_key = media_works.key"),
        )
        assertTrue(
            "WORK_COLUMNS 里出现了 `IN (SELECT` —— 这会让 SQLite 用不上 " +
                "media_items.group_key 的自动索引，媒体库打开从 21ms 退化到数秒。",
            !seg.contains("IN (SELECT"),
        )
    }

    /** 作品墙卡片的三个计数 + 进度必须换成并集值（与 PC 端 `_withUnionStats` 同一条）。 */
    @Test
    fun `listWorks 的计数与进度走页级并集`() {
        val code = codeOnly(dbSource())
        assertTrue(
            "listWorks 没有把结果交给 `withUnionStats(...)` —— 卡片上的「N 集 / N 个文件」" +
                "会是库里的**存值**（自己名下的数），与点进去看到的列表长度对不上。",
            code.contains("withUnionStats(queryWorks("),
        )
    }

    /**
     * 站在简介页上时，追剧检查完成后要**原地重读当前这一部**。
     *
     * 2026-10-07 现场：用户在这部剧的简介页上点「⟳ 检查追剧更新」，提示
     * 「有 1 部剧更新了（共 2 集）」，而眼前这个列表**一个都没多**。库写对了，
     * 错的是这一页没人通知它重读（旧代码只 `loadWorks()`，那会把用户踢回作品墙）。
     */
    @Test
    fun `追剧检查完成后简介页要原地重读`() {
        val code = codeOnly(activitySource())
        val hits = Regex("""reloadCurrentItems\(""").findAll(code).count()
        assertTrue(
            "LibraryActivity 的代码区里 `reloadCurrentItems(` 只出现 $hits 次" +
                "（至少要有「定义」与「调用」两处）。\n" +
                "少了调用：用户站在简介页上点「检查追剧更新」，提示说有新集，" +
                "而列表一个都不多 —— 与 2026-10-07 现场一模一样。",
            hits >= 2,
        )
    }

    /**
     * 详情页头部那行元数据（`2024 · 2 季 · 13 集 · …`）读的是 `Work.itemCount` /
     * `seasonCount`。库里存的是**自己名下**的数，所以详情页必须用并集口径的作品行。
     *
     * 只把**列表**改成并集的话，用户会看到头部写「1 集」、下面列着 13 行。
     * 三条会重设 `currentWork` 的路径（进详情 / 刮削后刷新 / 开关追剧）都要走它。
     */
    @Test
    fun `详情页重读作品行要用并集口径`() {
        val code = codeOnly(activitySource())
        val hits = Regex("""db\.workForDetail\(""").findAll(code).count()
        assertTrue(
            "LibraryActivity 里 `db.workForDetail(` 只出现 $hits 次（三条重读路径都要用：" +
                "openWork / refreshAfterScrape / toggleFollow）。\n" +
                "用 `db.workByKey(...)` 会把并集口径的「13 集」打回存值「1 集」，\n" +
                "于是简介页头部与下面那张列表自相矛盾。",
            hits >= 3,
        )
    }

    // ── 读源文件 ─────────────────────────────────────────────────────

    /** 行级剔注释：只丢**整行**是注释的行，不碰行尾（源里有 `"https://…"` 之类字面量）。 */
    private fun codeOnly(src: String): String =
        src.lines().filterNot { line ->
            val t = line.trimStart()
            t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
        }.joinToString("\n")

    private fun dbSource(): String = read(dbFile)

    private fun activitySource(): String = read(activityFile)

    private fun read(f: File): String {
        assertTrue(
            "读不到源文件：${f.absolutePath}（当前目录 ${File(".").absolutePath}）。\n" +
                "本测试依赖 Gradle 的 test 工作目录 = 模块目录（android/app），路径变了要同步改。",
            f.isFile,
        )
        return f.readText()
    }
}
