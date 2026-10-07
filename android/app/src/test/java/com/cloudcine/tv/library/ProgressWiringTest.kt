package com.cloudcine.tv.library

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 播放进度这条链路的**接线守卫**（读源文件，与 `LibraryActivityWiringTest` 同一套路）。
 *
 * ## 为什么必须用静态检查
 *
 * 这条链路上每一个「漏了」都是**静默**的：
 *
 *   * 某个 Activity 忘了把 `ProgressStore` 传给 `LibraryDb` ⇒ 那一页写的进度
 *     只进库列、不进独立进度库 ⇒ 下次「清空索引库 / 恢复备份」时那一批进度
 *     就没了（而界面上一切正常）；
 *   * `MainActivity` 忘了 `ProgressStore.shared(...)` ⇒ 进度库实例由第一个
 *     建它的页面决定，`ProgressStore.peek()` 之类的路径可能拿到 null；
 *   * `libraryModifiedAt()` 又把 `last_played_at` 算进去 ⇒ 看一集就上传一整份
 *     `.ccbak`，而且常开机的电视永远赢 LWW；
 *   * 某个写入口忘了 `progress?.record…` ⇒ 那一种进度永远同步不出去。
 *
 * 这些都不会编译报错、不会崩、界面上也看不出来 —— 只能靠静态检查守。
 *
 * ⛔ **必须先剔掉注释**：本仓库的文档注释里到处写着 `` `LibraryDb(...)` `` 这种
 *    说明性引用，不剔的话「把赋值行注释掉」会被判成「还在」。
 */
class ProgressWiringTest {

    private val appDir = File("src/main/java/com/cloudcine/tv")

    // ------------------------------------------------------------------
    // 1. 每一个 LibraryDb 构造点都必须注入进度库
    // ------------------------------------------------------------------

    @Test
    fun `每个 LibraryDb 构造点都注入了 ProgressStore`() {
        val files = appDir.listFiles { f -> f.isFile && f.name.endsWith(".kt") }
            ?.sortedBy { it.name }
            ?: emptyList()
        assertTrue("读不到源目录：${appDir.absolutePath}", files.isNotEmpty())

        val offenders = ArrayList<String>()
        var sites = 0

        for (f in files) {
            // ⛔ 跳过 `LibraryDb.kt` 自己 —— 那里的是**类声明** `class LibraryDb(`。
            if (f.name == "LibraryDb.kt") continue
            val code = codeOnly(f.readText())
            var from = 0
            while (true) {
                val at = code.indexOf("LibraryDb(", from)
                if (at < 0) break
                from = at + 1
                val call = balanced(code, at)
                sites++
                if (!call.contains("progress =")) {
                    offenders.add("${f.name}: ${call.replace('\n', ' ').take(120)}")
                }
            }
        }

        assertTrue(
            "一个构造点都没扫到 —— 正则已与源文件脱节（是不是都改成了别名/工厂？），请修正本测试",
            sites > 0,
        )
        assertTrue(
            "这些 LibraryDb(...) 没有注入进度库：\n${offenders.joinToString("\n")}\n" +
                "少了它，那一页写的进度只进库列、不进独立进度库 —— 下次「清空索引库 / " +
                "恢复备份」时这批进度就没了，而界面上一切正常。",
            offenders.isEmpty(),
        )
    }

    // ------------------------------------------------------------------
    // 2. 单例零点 + 触发时机
    // ------------------------------------------------------------------

    @Test
    fun `MainActivity 建好单例与「本次启动」的零点`() {
        val code = codeOnly(read("MainActivity.kt"))
        assertTrue(
            "MainActivity 没有 `ProgressStore.shared(...)`。它是 LAUNCHER 入口，" +
                "只有在这里建才能保证「进程内只有一个进度库实例」在任何页面写进度之前成立" +
                "（播放页也可能被「文件列表」直接拉起）。",
            code.contains("ProgressStore.shared("),
        )
        assertTrue(
            "MainActivity 没有 `ProgressSyncGate.beginLaunch()`。少了它，" +
                "从「文件列表」返回媒体库会**重建**该页并再同步一次。",
            code.contains("ProgressSyncGate.beginLaunch()"),
        )
    }

    @Test
    fun `LibraryActivity 挂上了三个触发时机`() {
        val code = codeOnly(read("LibraryActivity.kt"))
        assertTrue(
            "LibraryActivity 没有建 `ProgressSync(...)`",
            code.contains("progressSync = ProgressSync("),
        )
        assertTrue(
            "找不到启动那次同步（`syncProgressSilently(\"启动\")`）",
            code.contains("""syncProgressSilently("启动")"""),
        )
        assertTrue(
            "找不到退出播放器那次同步（`syncProgressSilently(\"退出播放器\")`）",
            code.contains("""syncProgressSilently("退出播放器")"""),
        )
        assertTrue(
            "找不到 30 分钟的定时器（`progressSyncTick`）",
            code.contains("progressSyncTick"),
        )
        // ⛔ 三个延迟/周期触发的 Runnable **每一个**都要在 onDestroy 里取消。
        //    漏掉哪个，页面销毁后它才跑，而 `syncSilently` 第一步就读库 ⇒
        //    `LibraryDb.require()` 把**刚 close() 的库重新打开**，留下一个再也
        //    没人关的句柄（本工程每个页面一个 Activity，来回切几次就攒几个）。
        //    这也逼着它们必须是**具名字段**：匿名 lambda 根本 removeCallbacks 不掉。
        for (name in listOf("progressSyncTick", "progressLaunchSync", "progressAfterPlayerSync")) {
            assertTrue(
                "onDestroy 里没有 `root.removeCallbacks($name)` —— 这个 Runnable 会读库，" +
                    "页面销毁后跑起来会把已 close() 的 LibraryDb 重新打开且永不关闭。",
                code.contains("root.removeCallbacks($name)"),
            )
            assertTrue(
                "`$name` 必须是**具名字段**（`private val $name = Runnable { … }`）：" +
                    "写成 `postDelayed({ … })` 里的匿名 lambda 就拿不到引用、" +
                    "`removeCallbacks` 不掉它。",
                Regex("""val\s+$name\s*=\s*(object\s*:\s*Runnable|Runnable)""").containsMatchIn(code),
            )
        }
        assertTrue(
            "找不到 `backfillProgress(` —— 清空索引库 / 恢复备份 / 重新扫描之后" +
                "没人把独立进度库贴回库列，用户会以为「进度全没了」。",
            code.contains("backfillProgress("),
        )
    }

    @Test
    fun `恢复备份与扫描之后都会回填进度`() {
        val code = codeOnly(read("LibraryActivity.kt"))
        assertTrue(
            "恢复备份之后没有 `backfillProgress(`。恢复 = 整份替换 `cloudcine.sqlite`，" +
                "备份里那份旧进度会盖掉本机的进度列 —— 不贴回来用户就看到「进度全没了」。",
            code.contains("""backfillProgress("恢复备份后")"""),
        )
        assertTrue(
            "扫描之后没有 `backfillProgress(`。新入库的媒体项三列全是 NULL" +
                "（进度不在那个文件里），不贴的话「清空索引库 → 重扫」之后进度条全空。",
            code.contains("""backfillProgress("扫描后")"""),
        )
    }

    // ------------------------------------------------------------------
    // 3. LibraryDb 的写透与判据
    // ------------------------------------------------------------------

    @Test
    fun `三个写入口都写透到独立进度库`() {
        val code = codeOnly(read("library/LibraryDb.kt"))
        for (call in listOf(
            "progress?.recordPlayed(",
            "progress?.recordResume(",
            "progress?.recordMax(",
        )) {
            assertTrue(
                "LibraryDb 里找不到 `$call`。少一条，那一种进度就永远同步不出去" +
                    "（库列里有、进度库里没有 ⇒ 清空/恢复时丢）。",
                code.contains(call),
            )
        }
    }

    @Test
    fun `libraryModifiedAt 不再把播放进度算进「库内容变更」`() {
        val code = codeOnly(read("library/LibraryDb.kt"))
        val body = functionBody(code, "fun libraryModifiedAt()")
        assertTrue("抽不出 libraryModifiedAt 的函数体 —— 正则已脱节", body.isNotEmpty())
        assertTrue(
            "libraryModifiedAt() 里又出现了 `last_played_at`。把它算进「库内容变更」" +
                "有两个立刻能撞上的坏处：① 看一集就上传一整份 `.ccbak`；" +
                "② 常开机的电视每天把水位线往前推，于是电脑上刚扫好的库会被判成「更旧」而被覆盖。",
            !body.contains("last_played_at"),
        )
        assertTrue(
            "libraryModifiedAt() 里应当同时看 `media_works.updated_at` 与 " +
                "`media_items.first_seen_at`（与 PC 端逐项一致）。",
            body.contains("updated_at") && body.contains("first_seen_at"),
        )
    }

    // ------------------------------------------------------------------
    // 4. 网盘通道
    // ------------------------------------------------------------------

    @Test
    fun `备份服务提供进度文件的上传下载，且用固定文件名`() {
        val code = codeOnly(read("library/LibraryBackupService.kt"))
        assertTrue("找不到 downloadProgressFile", code.contains("fun downloadProgressFile("))
        assertTrue("找不到 uploadProgressFile", code.contains("fun uploadProgressFile("))
        assertTrue(
            "进度文件必须用 `ProgressStore.FILE_NAME`（固定名、覆盖写）—— " +
                "备份包那套「带时间戳的新文件名」是给**历史**用的，进度是**当前状态**。",
            code.contains("ProgressStore.FILE_NAME"),
        )
        assertTrue(
            "downloadProgressFile 必须走 `findFolder`（**不创建**目录）：" +
                "从没同步过进度的用户不该每开一次电视就被塞一个空目录。",
            code.contains("api.findFolder("),
        )
    }

    @Test
    fun `进度文件不进备份包`() {
        val code = codeOnly(read("library/LibraryBackupService.kt"))
        val body = functionBody(code, "fun exportBackup(")
        assertTrue("抽不出 exportBackup 的函数体 —— 正则已脱节", body.isNotEmpty())
        assertTrue(
            "exportBackup 里出现了进度文件名。进度**必须**在备份包之外 —— " +
                "这正是「恢复备份不丢进度」的全部实现方式。",
            !body.contains("FILE_NAME"),
        )
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

    /** 从 `LibraryDb(` 的 `(` 起，取到配对的 `)`。 */
    private fun balanced(code: String, at: Int): String {
        val open = code.indexOf('(', at)
        if (open < 0) return ""
        var depth = 0
        for (i in open until code.length) {
            when (code[i]) {
                '(' -> depth++
                ')' -> {
                    depth--
                    if (depth == 0) return code.substring(open, i + 1)
                }
            }
        }
        return code.substring(open)
    }

    /** 取一个函数（含 KDoc 之外的）的函数体：从声明到下一个「同缩进的 `}`」。 */
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
