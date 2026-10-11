package com.cloudcine.tv

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LibraryActivity] 的**接线守卫**。
 *
 * ## 为什么需要这个测试
 *
 * `LibraryActivity` 是**纯代码搭 UI**（没有布局 XML），依赖与视图全部声明成
 * `lateinit var`，在 `onCreate` / `buildContent()` 里逐个赋值。漏掉一个：
 *
 *   · **不编译报错** —— `lateinit` 的语义就是「我保证会赋值」；
 *   · **不会崩** —— 只在那条路径**第一次真的跑到**时抛
 *     `UninitializedPropertyAccessException`；
 *   · **界面上一切正常** —— 因为它多半发生在后台线程里，被 `Bg.run` 的兜底
 *     catch 接住，只写一行 W 级日志。
 *
 * 三者叠加的结果是「**功能静默失效**」：2026-10-07 真机部署时实际踩到 ——
 * `followUpdater` 声明了却从未赋值，进媒体库后日志里只有一句
 * `追剧检查失败 / lateinit property followUpdater has not been initialized`，
 * 而海报墙、分类栏、状态行看起来全对，追剧角标则永远不涨。
 *
 * ## 为什么是「读源文件」而不是 Robolectric
 *
 * 本工程刻意不引 Robolectric（见 `build.gradle.kts` 的依赖清单）。而静态检查
 * 反而**更准**：它覆盖的是「赋值语句被删掉 / 被注释掉」这个动作本身，不依赖
 * 运行时是否恰好走到那条分支。
 *
 * ⛔ **必须先把注释剔掉再找赋值**：本文件的中文文档注释里到处写着
 *    `` `followUpdater = FollowUpdater(...)` `` 这种**说明性引用**，不剔注释的
 *    话，一次「把赋值行注释掉」的误操作会被判成「已赋值」—— 守卫在最需要它
 *    的那一刻放行，等于没有守卫。
 *
 * 代价是它对源文件路径有依赖，所以路径取不到时会**明确失败**而不是静默通过。
 */
class LibraryActivityWiringTest {

    private val sourceFile = File("src/main/java/com/cloudcine/tv/LibraryActivity.kt")

    /** 每个 `lateinit var` 都必须在**代码区**（非注释）里被赋值过。 */
    @Test
    fun `每个 lateinit 属性都有赋值语句`() {
        val code = codeOnly(readSource())
        val declared = DECL.findAll(code).map { it.groupValues[1] }.toList()

        // 一个都没抽到 = 正则与源文件脱节了（比如属性改成了 `private var x: X? = null`）。
        // ⛔ 这种「测试自己坏了」必须报出来，否则它会一直绿灯。
        assertTrue(
            "没能从 LibraryActivity.kt 的代码区里抽出任何 lateinit 属性 —— " +
                "正则已与源文件脱节，请修正本测试",
            declared.isNotEmpty(),
        )

        val unassigned = declared.filterNot { name -> hasAssignment(code, name) }

        assertTrue(
            "这些 lateinit 属性声明了但从未赋值：$unassigned\n" +
                "它们不会编译报错、不会崩，只会在第一次用到时静默失败（见本测试类文档）。",
            unassigned.isEmpty(),
        )
    }

    /**
     * 追剧检查的执行器必须在 `onCreate` 里建好。
     *
     * 单列一条是因为它是**唯一一条在 `onCreate` 结束后 1.5 秒就会自动跑到**的
     * 路径（`root.postDelayed({ maybeAutoCheckFollow() }, …)`），其余 lateinit
     * 属性都要等用户操作。上面那条通用断言在它被误删时也会红，但这条能直接
     * 说清「为什么这个属性尤其不能漏」。
     */
    @Test
    fun `followUpdater 在 onCreate 里被初始化`() {
        val code = codeOnly(readSource())
        assertTrue(
            "LibraryActivity 的代码区里没有 `followUpdater = FollowUpdater(...)`。\n" +
                "少了它，进媒体库 1.5 秒后的自动追更检查会抛 " +
                "UninitializedPropertyAccessException，被 Bg.run 兜底吞掉后只留一行 W 日志 —— " +
                "用户看到的是「追剧功能没反应」。",
            hasAssignment(code, "followUpdater"),
        )
    }

    /**
     * 点一集去播放 ⇒ **当场**写已读回执，回来还要重读这一页。
     *
     * ## 为什么这两件事必须一起在
     *
     * 2026-10-07 现场：TV 端点了带 `■ NEW` 的一集、打开播放，返回后标记还在。
     *
     *   · 已读回执原先**只由播放页**在退出时补写，而它开头是
     *     `if (positionMs <= 0L) return` —— 短看几秒就退出的那次一个字都没写；
     *   · 而且这一页从播放页返回后**不重读**，列表里那份 `LibraryItem` 还是
     *     播放前的快照，`isNewSinceFollow` 自然照旧为真。
     *
     * 缺任何一条，标记都会赖着不走：
     *   · 只在返回时重读、不在点击时写 ⇒ 短看的那一集永远不消；
     *   · 只在点击时写、返回时不重读 ⇒ 库里对了，屏幕上还是旧的。
     */
    @Test
    fun `点播放会写已读回执并在返回时重读简介页`() {
        val code = codeOnly(readSource())
        assertTrue(
            "`play(...)` 里没有 `db.markPlayed(` —— 已读回执只由播放页在退出时补写的话，" +
                "短看几秒就退出的那一集一个字都不会写（播放页开头 `positionMs <= 0` 就 return），" +
                "NEW 标记会一直挂着。",
            code.contains("db.markPlayed("),
        )
        assertTrue(
            "`onActivityResult` 没有处理 `REQ_PLAYER`（`requestCode == REQ_PLAYER`）—— " +
                "从播放页回来时没人重读这一页，库里的已读回执改了也看不出来。",
            code.contains("requestCode == REQ_PLAYER"),
        )
        assertTrue(
            "找不到 `REQ_PLAYER = 1002` —— 播放页必须用 `startActivityForResult` 启动，" +
                "否则 [onActivityResult] 根本不会被回调。",
            code.contains("REQ_PLAYER = 1002"),
        )
    }

    /**
     * 简介页**动作行**上按 ↑ 绝不能离开这一页。
     *
     * ## 为什么这条要单独立一个守卫
     *
     * 2026-10-11 用户反馈：「媒体简介页面中，焦点在默认位置时，为啥点击遥控器上键
     * 会推出简介页面？这个体验非常糟糕」。
     *
     * 根因不是写错了，而是**理由过期了**：动作行是简介页最上面那一层，于是当初
     * 顺手把 ↑ 接成了 `backToWorks()`（「再往上没有东西了，与返回键同义」）。
     * 但 [openWork] 末尾调的 [focusDetailActions] 会把**默认光标放在动作行**——
     * 用户刚进页面按一下 ↑ 就被弹回作品墙。
     *
     * 这类事故的特点：**不编译报错、不崩、日志干净**，只有人坐在电视前才看得见。
     * 所以用静态守卫把「方向键不许做破坏性跳转」这条规矩钉住。
     *
     * ⛔ 断言的是**整段分支**而不是某一行：`KEYCODE_DPAD_UP -> …` 的写法随时可能
     *    改成 `when { … }` / 提前 `return`，钉行号会立刻脱节；钉「这一段里不许出现
     *    `backToWorks`」则与写法无关。
     */
    @Test
    fun `动作行上按上键不会退出简介页`() {
        val code = codeOnly(readSource())
        val block = braceBlock(code, "if (actionsFocused) {")

        // 抽不到 / 抽错段落 = 守卫自己坏了。⛔ 必须报出来，否则它会一直绿灯。
        assertTrue(
            "没能从 LibraryActivity.kt 的代码区里抽出 `if (actionsFocused) { … }` 这一段 —— " +
                "正则/配对已与源文件脱节，请修正本测试",
            block.contains("KEYCODE_DPAD_DOWN") && block.contains("applyAction"),
        )
        assertTrue(
            "简介页动作行的按键分支里出现了 `backToWorks()`。\n" +
                "进简介页时默认光标就落在动作行（openWork 末尾调 focusDetailActions），" +
                "所以 ↑ 一旦接了「回作品墙」，用户刚进来按一下上键就被踢出去（2026-10-11 反馈）。\n" +
                "「离开这一页」是返回键的职责（handleBack 第一步 `level == Level.ITEMS` 已覆盖），" +
                "方向键不该有破坏性副作用。",
            !block.contains("backToWorks"),
        )
    }

    /**
     * 剔除注释后的源码。
     *
     * 用**行级**过滤而不是正则剥块注释：`LibraryActivity.kt` 里有网盘 URL 之类的
     * 字符串字面量，按 `//` 粗暴切断会把 `"https://…"` 的后半截连同字符串引号
     * 一起吃掉，反而制造出「代码被破坏」的假象。行首判定只看这一行**是不是**
     * 注释行，不碰行尾内容，所以 `val u = "https://…"` 原样保留。
     */
    private fun codeOnly(src: String): String =
        src.lines().filterNot { line ->
            val t = line.trimStart()
            t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
        }.joinToString("\n")

    /**
     * 从 `head` 那个 `{` 开始做花括号配对，返回**整段**（含首尾花括号）。
     *
     * ⛔ 只在**剔除注释后**的源码上调用：注释里的 `{` / `}`（本文件到处是这种
     *    说明性引用）会把配对算歪。抽不到时返回空串 —— 调用方必须把它当成
     *    「守卫坏了」报出来，不能当成「检查通过」。
     */
    private fun braceBlock(code: String, head: String): String {
        val start = code.indexOf(head)
        if (start < 0) return ""
        val open = code.indexOf('{', start)
        if (open < 0) return ""
        var depth = 0
        for (i in open until code.length) {
            when (code[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return code.substring(start, i + 1)
                }
            }
        }
        return ""
    }

    /** 代码区里是否存在 `name = …`（行首赋值，允许 `this.` 前缀）。 */
    private fun hasAssignment(code: String, name: String): Boolean =
        Regex(
            """^\s*(?:this\.)?""" + Regex.escape(name) + """\s*=(?!=)""",
            RegexOption.MULTILINE,
        ).containsMatchIn(code)

    private fun readSource(): String {
        assertTrue(
            "读不到源文件：${sourceFile.absolutePath}（当前目录 ${File(".").absolutePath}）。\n" +
                "本测试依赖 Gradle 的 test 工作目录 = 模块目录（android/app），路径变了要同步改。",
            sourceFile.isFile,
        )
        return sourceFile.readText()
    }

    private companion object {
        /** `private lateinit var scanner: LibraryScanner` → `scanner`。 */
        val DECL = Regex("""lateinit\s+var\s+(\w+)\s*:""")
    }
}
