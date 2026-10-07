package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.DriveEntry
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.formatSize
import com.cloudcine.tv.library.FolderSortMode
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.LibraryScanner
import com.cloudcine.tv.library.sortListing

/**
 * 文件列表 —— 「文件列表」这一块的唯一实现。
 *
 * 刻意用框架自带的 `ListView`：它**天生支持 D-pad**（上下移动选中项、
 * OK 触发 `onItemClick`），不需要 RecyclerView（那还得引
 * `androidx.recyclerview`，本机 Gradle 缓存里没有）。
 *
 * 目录栈是本地维护的（`fid` + 显示名），返回键弹一层 ——
 * 不调任何「取父目录」的接口，少一次往返也少一个出错点。
 */
class BrowseActivity : Activity() {

    private lateinit var store: CredStore
    private lateinit var api: PanApi

    /**
     * 媒体库索引库 —— **只为「发现」服务**。
     *
     * ⛔ 这个页面**不读**它：列表是网盘实时目录，不是本地索引。所以它不进任何
     *    渲染路径，只有 [doDiscover] / [doDiscoverFile] 往里写。
     */
    private lateinit var db: LibraryDb
    private lateinit var scanner: LibraryScanner

    /**
     * 是否有发现正在跑。
     *
     * ⛔ 与媒体库页的 `scanCancel` 同一取向：发现的节流器是**每个实例独立**的
     *    （见 `LibraryScanner` 的类文档），并发跑两次等于把实际 QPS 翻倍，
     *    而两边各自的限流都以为自己守住了。
     */
    private var discovering = false

    private lateinit var listView: ListView
    private lateinit var title: TextView
    private lateinit var status: TextView

    private lateinit var overlay: LinearLayout
    private lateinit var overlayTitle: TextView
    private lateinit var overlayRowsBox: LinearLayout
    private lateinit var overlayScroll: ScrollView
    private lateinit var overlayScrim: FrameLayout

    /**
     * 覆盖层（菜单）的状态。可见时方向键 / OK / 返回**全部**由
     * [dispatchKeyEvent] 接管 —— 不走焦点系统，因为电视遥控器的焦点
     * 遍历在动态加进去的 View 上不可控（`TvOsdView` 同一套做法）。
     */
    private var overlayVisible = false
    private var overlayIndex = 0
    private var overlayLabels: List<String> = emptyList()
    private var overlayOnPick: ((Int) -> Unit)? = null

    private val stack = ArrayList<Pair<String, String>>() // (fid, 显示名)
    private val entries = ArrayList<DriveEntry>()
    private lateinit var adapter: EntryAdapter

    // ── 目录视图的排序胶囊 ──
    // ⛔ **默认「修改时间」倒序**：目录视图存在的意义就是「我新传的东西在哪」，
    //    默认把最新的排在第一行。排序在客户端做（[sortListing]），不重打网络。
    private var sortMode: FolderSortMode = FolderSortMode.MODIFIED_TIME
    private var sortCursor: Int = FolderSortMode.entries.indexOf(FolderSortMode.MODIFIED_TIME)
    private var sortFocused = false
    private lateinit var sortBox: LinearLayout
    private lateinit var sortScroll: HorizontalScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = CredStore(this)
        api = PanApi(store)
        db = LibraryDb(LibraryPaths.dbFile(this))
        scanner = LibraryScanner(api = api, db = db)

        if (!store.loggedIn) {
            startActivity(Intent(this, LoginActivity::class.java))
            finish()
            return
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101216"))
        }

        // 页头：品牌图标 + 面包屑。图标放在这一行的最左，是列表页唯一的
        // 品牌露出位（页面本身只有文字，不放就完全看不出是哪个 App）。
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(48), dp(24), dp(48), dp(4))
        }
        head.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(34), dp(34)),
        )
        title = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setPadding(dp(12), 0, 0, 0)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.START
        }
        head.addView(
            title,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        column.addView(head)

        status = TextView(this).apply {
            setTextColor(0xFF9AA3B2.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(48), 0, dp(48), dp(8))
        }
        column.addView(status)

        // ── 目录视图排序胶囊（列表上方）──
        // 与媒体库胶囊同一套样式语言（实心面明度区分「生效 / 光标 / 常态」，不描边）。
        // ↑ 从列表首行进、↓ 回列表；←→ 移光标，OK 生效。
        sortBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(48), dp(6), dp(48), dp(2))
            isFocusable = false
            isFocusableInTouchMode = false
        }
        sortScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            clipToPadding = false
            clipChildren = false
        }
        sortScroll.addView(
            sortBox,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        column.addView(sortScroll, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ))

        adapter = EntryAdapter()
        listView = ListView(this).apply {
            adapter = this@BrowseActivity.adapter
            divider = null
            dividerHeight = 0
            setBackgroundColor(Color.parseColor("#101216"))
            setOnItemClickListener { _, _, position, _ -> onEntry(entries[position]) }
            isFocusable = true
            isFocusableInTouchMode = true
        }
        column.addView(listView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ))

        column.addView(TextView(this).apply {
            text = "↑↓ 选择 · OK 进入/播放 · 返回 上一层 · 菜单 发现/更多"
            setTextColor(0xFF6B7280.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(48), dp(6), dp(48), dp(20))
        })

        // 菜单用覆盖层而不是弹 Dialog：Dialog 会另起一个 Window，遥控器焦点
        // 会跑到新 Window 上，返回键也要多按一次；覆盖层留在本 Window 里，
        // 按键全部由 dispatchKeyEvent 直接分派。
        val frame = FrameLayout(this).apply { setBackgroundColor(Color.parseColor("#101216")) }
        frame.addView(
            column,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        frame.addView(
            buildOverlay(),
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        setContentView(frame)

        open(PanApi.ROOT, "云影")
    }

    override fun onDestroy() {
        super.onDestroy()
        // ⛔ 与媒体库页同一条规矩：库连接必须关。留着的话，下一次 `rawBytes()`
        //    （备份导出）会读到一份「少最后几次写入」的库 —— 那是静默的数据丢失。
        runCatching { db.close() }
    }

    // ------------------------------------------------------------------
    // 覆盖层菜单
    // ------------------------------------------------------------------

    private fun buildOverlay(): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0xB3000000.toInt())
            isClickable = true
            visibility = View.GONE
        }
        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // 与媒体库的菜单同一套：**不描边**（线框在深色 UI 里只剩一条细线），
            // 层次靠比背景亮一档的实心面 + 更大的圆角。
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(0xFF1E232C.toInt())
            }
            setPadding(dp(16), dp(20), dp(16), dp(14))
        }
        overlayTitle = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(12), 0, dp(12), dp(12))
        }
        overlay.addView(overlayTitle)
        overlayRowsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        // ⛔ 菜单**必须能滚**：加了「发现」之后最多有六七项，行高约 45dp，
        //    而 1080p 电视只有 540dp 高 —— 溢出时 `LinearLayout` 不会滚，
        //    **最后几项永远选不到**（遥控器按到底就停在那儿），而这个缺陷在
        //    开发机上根本看不出来。
        // ⛔ 滚动条自己**不能拿焦点**：焦点在菜单行上，`ScrollView` 一旦可聚焦
        //    就会在按 ↑↓ 时把光标吸走。
        overlayScroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            addView(
                overlayRowsBox,
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        overlay.addView(
            overlayScroll,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        scrim.addView(
            overlay,
            FrameLayout.LayoutParams(dp(520), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.CENTER
            },
        )
        overlayScrim = scrim
        return scrim
    }

    private fun showOverlay(titleText: String, labels: List<String>, onPick: (Int) -> Unit) {
        overlayTitle.text = titleText
        overlayLabels = labels
        overlayOnPick = onPick
        overlayIndex = 0
        overlayRowsBox.removeAllViews()
        for (label in labels) {
            // ⛔ 走 MenuRow（与媒体库菜单**同一套实现**）：选中 = 实心圆角块 +
            //    左侧竖条，未选中 = 透明底。这里**不要**自己 setBackgroundColor
            //    造直角色块 —— 那是上一版的样式，用户明确说「太难看」。
            overlayRowsBox.addView(
                MenuRow.create(this, label),
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(2) },
            )
        }
        paintOverlaySelection()
        overlayScrim.visibility = View.VISIBLE
        overlayVisible = true
        overlayScroll.post { overlayScroll.scrollTo(0, 0) }
    }

    private fun paintOverlaySelection() {
        for (i in 0 until overlayRowsBox.childCount) {
            MenuRow.paint(overlayRowsBox.getChildAt(i), i == overlayIndex)
        }
        revealOverlayRow()
    }

    /**
     * 把光标所在菜单行滚进可视区。
     *
     * ⛔ 菜单行自己**不可聚焦**（按键由 `dispatchKeyEvent` 分派），所以
     *    `ScrollView` 不会替我们滚 —— 不手动滚的话，第 7 项之后的行虽然能选中，
     *    但用户在屏幕上**看不见自己在选什么**。
     */
    private fun revealOverlayRow() {
        val row = overlayRowsBox.getChildAt(overlayIndex) ?: return
        overlayScroll.post {
            val pad = dp(8)
            val viewport = overlayScroll.height
            if (viewport <= 0) return@post
            val want = when {
                row.top - pad < overlayScroll.scrollY -> row.top - pad
                row.bottom + pad > overlayScroll.scrollY + viewport ->
                    row.bottom + pad - viewport
                else -> -1
            }
            if (want >= 0) overlayScroll.smoothScrollTo(0, want)
        }
    }

    private fun hideOverlay() {
        overlayScrim.visibility = View.GONE
        overlayVisible = false
        overlayOnPick = null
        overlayLabels = emptyList()
        listView.requestFocus()
    }

    /**
     * 菜单。
     *
     * ⛔ 用「`标签 to 动作` 的列表」而不是「`labels` + 一长串 `when(index)`」：
     *    菜单项现在是**按当前选中的那一行动态生成**的（目录行多两项、视频行多
     *    一项），按下标硬编码会在某一行上「点了 A 执行了 B」，而**下标错了不会
     *    编译失败** —— 上一版媒体库页就是这么翻的车。
     */
    private fun openMenu() {
        val actions = ArrayList<Pair<String, () -> Unit>>()
        val cur = entries.getOrNull(listView.selectedItemPosition)
        val here = stack.lastOrNull()?.second.orEmpty()

        // ── 发现：作用域 = 当前目录（与 PC 端页头那个「发现本目录」同一作用域）──
        if (discovering) {
            actions.add(
                "发现进行中…（等它跑完）" to {
                    status.text = "发现还在跑，等它结束再操作"
                },
            )
        } else {
            actions.add(
                "发现本目录「$here」（含子目录）" to {
                    doDiscover(stack.lastOrNull()?.first.orEmpty(), pathOfStack(), true, "本目录")
                },
            )
        }

        // ── 针对**光标所在那一行**的入口 ──
        // ⛔ 只在这一行真的存在时出现：光标停在空列表上时 `cur` 是 null，
        //    硬拼一个「发现「null」」出来只会让人以为界面坏了。
        if (!discovering && cur != null && cur.isDir) {
            // 「只发现这一层」= 不递归。用户点它往往是因为「我知道新片就在这层，
            // 别去翻我几百个子目录」（PC 端目录行那个按钮的同一诉求）。
            actions.add(
                "只发现「${cur.name}」这一层" to {
                    doDiscover(cur.fid, childPath(cur.name), false, "「${cur.name}」")
                },
            )
            actions.add(
                "发现「${cur.name}」（含子目录）" to {
                    doDiscover(cur.fid, childPath(cur.name), true, "「${cur.name}」")
                },
            )
        }
        if (!discovering && cur != null && cur.isVideo) {
            actions.add("把「${cur.name}」加入媒体库" to { doDiscoverFile(cur) })
        }

        actions.add("媒体库" to { gotoLibrary() })
        actions.add("重新登录" to { relogin() })

        showOverlay(titleText = "云影", labels = actions.map { it.first }) { index ->
            val act = actions.getOrNull(index) ?: return@showOverlay
            hideOverlay()
            act.second()
        }
    }

    /**
     * 去媒体库。
     *
     * ⛔ 用 `CLEAR_TOP` 而不是 `startActivity + finish`：媒体库现在是 App 首页，
     *    通常在栈里已经有一份。`CLEAR_TOP` 会**复用**那一份（同时把它上面的都
     *    弹掉），而不会越堆越多层；从别处直接打开网盘目录时（比如 adb 调试），
     *    栈里没有媒体库，`CLEAR_TOP` 就会新建一个 —— 两种情况都对。
     */
    private fun gotoLibrary() {
        startActivity(
            Intent(this, LibraryActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
        finish()
    }

    /** 重新登录：清凭证回登录页。本 App 上「退出登录」的唯一入口。 */
    private fun relogin() {
        store.clear()
        startActivity(Intent(this, LoginActivity::class.java))
        finish()
    }

    // ------------------------------------------------------------------

    private fun open(fid: String, name: String) {
        status.text = "加载中…"
        Bg.run({ api.listDirectory(fid) }) { list, err ->
            if (err != null) {
                status.text = "加载失败：${err.message}"
                Log.e(TAG, "列目录失败", err)
                return@run
            }
            val data = list ?: emptyList()
            stack.add(fid to name)
            entries.clear()
            // ⛔ 用 [sortListing] 而不是「目录在前、文件在后」：它在此之上还按
            //    当前排序档分组排（目录 / 视频 / 其它文件），与 PC 端 `folder_browser`
            //    同一口径；默认档是「修改时间倒序」，所以进目录就是最新的排最前。
            entries.addAll(sortListing(data, sortMode))
            adapter.notifyDataSetChanged()
            buildSortBar()
            title.text = stack.joinToString(" / ") { it.second }
            status.text = "共 ${entries.size} 项（目录 ${entries.count { it.isDir }}）"
            listView.setSelection(0)
            listView.requestFocus()
        }
    }

    private fun onEntry(e: DriveEntry) {
        when {
            e.isDir -> open(e.fid, e.name)
            e.isVideo -> startActivity(
                Intent(this, PlayerActivity::class.java)
                    .putExtra(PlayerActivity.EXTRA_FID, e.fid)
                    .putExtra(PlayerActivity.EXTRA_NAME, e.name)
                    .putExtra(PlayerActivity.EXTRA_HEADERS, store.requestCookie())
                    // ⛔ 把**当前目录**的 fid 一起带过去 —— 播放页靠它扫同目录的
                    //    外挂字幕。单个文件的 fid 推不出父目录，网盘也没有
                    //    「查父目录」的接口，所以只能在这里给。
                    //    目录栈的栈顶就是当前列表，`onEntry` 只会在它上面被调用。
                    .putExtra(PlayerActivity.EXTRA_PDIR, stack.lastOrNull()?.first.orEmpty()),
            )
            e.isSubtitle -> status.text = "字幕文件：${e.name}\n（在视频里用「字幕」那一行选）"
            else -> status.text = "不是视频：${e.name}"
        }
    }

    // ------------------------------------------------------------------
    // 发现（把这一片里的媒体补进媒体库）
    // ------------------------------------------------------------------

    /**
     * 当前目录的完整路径，**带尾斜杠**（根是 `/`）。
     *
     * ⛔ 目录栈里存的是 `(fid, 显示名)`，所以路径只能靠显示名拼 —— 网盘没有
     *    「查父目录」的接口。栈底那项是根，显示名是「云影」而**网盘根就是 `/`**，
     *    所以它不参与拼接；把它拼进去会让根目录下的片子拿到一个错的 `dirPath`，
     *    而 `dirPath` 是 `groupKey` 的一部分 —— 表现是「同一部片子出现两格」。
     */
    private fun pathOfStack(): String {
        val parts = stack.drop(1).map { it.second }
        return if (parts.isEmpty()) "/" else "/" + parts.joinToString("/") + "/"
    }

    /** 当前目录下某个子项的路径（`/动漫/进击的巨人/`）。 */
    private fun childPath(name: String): String {
        val base = pathOfStack()
        return if (base == "/") "/$name/" else "$base$name/"
    }

    /**
     * 跑一次**作用域发现**。
     *
     * ⛔ 与媒体库菜单里的「重新扫描媒体库」是两件事：那个走全盘、会清理陈旧记录；
     *    这个只走用户指定的这一片，且**只增不减**（见 [LibraryScanner.discover]）。
     *    所以它**不需要二次确认** —— 最坏的结果也只是「多发现了几个文件」，
     *    没有任何不可逆的破坏。多一次确认反而会让「发现」这个日常动作变重。
     *
     * ⛔ 进度回调在**后台线程**上（同媒体库页的 `doScan`），碰 `status` 必须回主线程。
     */
    private fun doDiscover(fid: String, path: String, recursive: Boolean, what: String) {
        if (discovering) {
            status.text = "发现还在跑，等它结束再操作"
            return
        }
        if (fid.isEmpty()) {
            status.text = "发现失败：拿不到这个目录的标识"
            return
        }
        discovering = true
        val label = "$what${if (recursive) "（含子目录）" else "（仅本层）"}"
        status.text = "发现$label：准备中…"
        Log.i(TAG, "发现开始：$path$label")
        Bg.run({
            scanner.discover(fid, path, recursive) { p ->
                runOnUiThread { if (discovering) status.text = "发现$label：${p.text}" }
            }
        }) { out, err ->
            discovering = false
            if (err != null) {
                status.text = "发现失败：${err.message}"
                Log.e(TAG, "发现失败", err)
                return@run
            }
            val msg = out?.message ?: "发现完成"
            Log.i(TAG, "发现结束：$msg")
            status.text = msg
        }
    }

    /** 把**单个**视频文件加进媒体库（不碰它的兄弟）。 */
    private fun doDiscoverFile(e: DriveEntry) {
        if (discovering) {
            status.text = "发现还在跑，等它结束再操作"
            return
        }
        discovering = true
        status.text = "正在把「${e.name}」加入媒体库…"
        // ⛔ 用**当前目录**的 fid / path：文件自己推不出父目录（与 [onEntry] 里
        //    给播放页传 `EXTRA_PDIR` 是同一个理由）。
        val dirId = stack.lastOrNull()?.first.orEmpty()
        val path = pathOfStack()
        Bg.run({ scanner.discoverFile(e, path, dirId) }) { out, err ->
            discovering = false
            if (err != null) {
                status.text = "加入失败：${err.message}"
                Log.e(TAG, "加入媒体库失败", err)
                return@run
            }
            status.text = out?.message ?: "已加入媒体库"
        }
    }

    /** 返回键弹一层目录栈；已在根目录则退出。 */
    private fun goUp(): Boolean {
        if (stack.size <= 1) return false
        stack.removeAt(stack.size - 1)
        val (fid, name) = stack.removeAt(stack.size - 1)
        entries.clear()
        adapter.notifyDataSetChanged()
        open(fid, name)
        return true
    }

    // ------------------------------------------------------------------
    // 目录视图的排序胶囊
    //
    // 与媒体库胶囊同一套样式语言（实心面明度区分「生效 / 光标 / 常态」，不描边），
    // 光标态与生效态分离（←→ 只移光标，OK 才重排），与媒体库一级导航一致。
    // ------------------------------------------------------------------

    /** 重画排序胶囊。当前档 = 生效（亮品牌色实心 + 深字）；光标所在 = 暗品牌色。 */
    private fun buildSortBar() {
        val modes = FolderSortMode.entries
        sortBox.removeAllViews()
        for ((i, mode) in modes.withIndex()) {
            sortBox.addView(
                sortChip(
                    mode,
                    isCurrent = mode == sortMode,
                    isCursor = sortFocused && i == sortCursor,
                ),
            )
        }
        revealChip(sortScroll, sortBox, sortCursor)
    }

    private fun sortChip(mode: FolderSortMode, isCurrent: Boolean, isCursor: Boolean): TextView =
        TextView(this).apply {
            text = mode.label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(14), dp(8), dp(14), dp(8))
            maxLines = 1
            isSingleLine = true
            isFocusable = false
            isFocusableInTouchMode = false
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(
                    when {
                        isCurrent -> BRAND_TINT
                        isCursor -> 0xFF4A4278.toInt()
                        else -> 0x14FFFFFF
                    },
                )
            }
            setTextColor(
                when {
                    isCurrent -> 0xFF1A1533.toInt()
                    isCursor -> Color.WHITE
                    else -> 0xFFB9C0CC.toInt()
                },
            )
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { rightMargin = dp(8) }
        }

    /** ←→ 在排序胶囊里移光标。**不重排**。 */
    private fun moveSort(delta: Int) {
        val modes = FolderSortMode.entries
        sortCursor = (sortCursor + delta + modes.size) % modes.size
        buildSortBar()
    }

    /** OK：把光标所在档设为当前排序，重排当前目录、回到第一行、焦点还给列表。 */
    private fun applySort() {
        val mode = FolderSortMode.entries.getOrNull(sortCursor) ?: return
        if (mode == sortMode) {
            focusList()
            return
        }
        Log.i(TAG, "目录排序：${sortMode.label} → ${mode.label}")
        sortMode = mode
        val sorted = sortListing(entries, mode)
        entries.clear()
        entries.addAll(sorted)
        adapter.notifyDataSetChanged()
        listView.setSelection(0)
        buildSortBar()
        focusList()
    }

    /** ↑ 从列表首行进排序胶囊：胶囊吃光标态。 */
    private fun focusSort() {
        sortFocused = true
        buildSortBar()
        status.text = "OK 应用排序 · ↓ 返回列表"
    }

    private fun focusList() {
        sortFocused = false
        buildSortBar()
        listView.requestFocus()
    }

    /** 把光标所在胶囊滚进可视区（胶囊 `isFocusable = false`，框架不会自动滚）。 */
    private fun revealChip(scroll: HorizontalScrollView, box: LinearLayout, index: Int) {
        val chip = box.getChildAt(index) ?: return
        scroll.post {
            val pad = dp(24)
            val viewport = scroll.width
            if (viewport > 0) {
                val want = when {
                    chip.left - pad < scroll.scrollX -> chip.left - pad
                    chip.right + pad > scroll.scrollX + viewport -> chip.right + pad - viewport
                    else -> -1
                }
                if (want >= 0) scroll.smoothScrollTo(want, 0)
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)

        // 覆盖层可见时**独占**按键：上下移动、OK 生效、返回/菜单 关闭。
        // ⛔ 不依赖焦点系统：动态加进 ViewGroup 的 TextView 在电视上
        //    不一定拿得到焦点，`requestFocus()` 也常静默失败。
        if (overlayVisible) {
            if (overlayLabels.isEmpty()) {
                hideOverlay()
                return true
            }
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP -> {
                    overlayIndex = (overlayIndex - 1 + overlayLabels.size) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    overlayIndex = (overlayIndex + 1) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                    // ⛔ 先取出来再回调：回调里 `hideOverlay()` 会把
                    //    `overlayOnPick` 置空，直接调用会空指针。
                    val pick = overlayOnPick
                    pick?.invoke(overlayIndex)
                    return true
                }
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_MENU -> {
                    hideOverlay()
                    return true
                }
            }
            // 覆盖层开着时吞掉其它键，避免误触到底层列表。
            return true
        }

        // ── 排序胶囊拿到光标：←→ 移光标、OK 生效、↓/返回 回列表、↑ 无更上层 ──
        // ⛔ 放在通用分支之前优先吃掉这些键，避免泄漏到底层列表。
        // ⛔ 本函数开头已 `return` 掉非 DOWN 事件，这里只处理按下，不需要 `down` 守卫。
        if (sortFocused) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> { moveSort(-1); return true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { moveSort(1); return true }
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> { applySort(); return true }
                KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_BACK,
                -> { focusList(); return true }
                // ↑ 在胶囊上已是顶层，吞掉避免又跳回列表首行。
                KeyEvent.KEYCODE_DPAD_UP -> return true
                KeyEvent.KEYCODE_MENU -> { openMenu(); return true }
            }
            return true
        }

        when (event.keyCode) {
            KeyEvent.KEYCODE_BACK -> if (goUp()) return true
            KeyEvent.KEYCODE_MENU -> {
                openMenu()
                return true
            }
            // 列表首行 ↑ 进排序胶囊：胶囊在列表上方。
            KeyEvent.KEYCODE_DPAD_UP -> {
                if (listView.selectedItemPosition == 0) {
                    focusSort()
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    // ------------------------------------------------------------------

    private inner class EntryAdapter : BaseAdapter() {
        override fun getCount() = entries.size
        override fun getItem(position: Int) = entries[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val row = (convertView as? LinearLayout) ?: LinearLayout(this@BrowseActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(48), dp(12), dp(48), dp(12))
            }
            val e = entries[position]

            val name = row.getChildAt(0) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                row.addView(this)
            }
            val meta = row.getChildAt(1) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextColor(0xFF9AA3B2.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.END
                row.addView(this)
            }
            // 修改时间列：与 PC 端 `ModifiedTimeColumn` 同一口径 —— 固定宽度、
            // 右对齐、显示相对时间（`3 天前`），0 / 缺失显示 `—`。`updatedAtMs`
            // 已是毫秒，直接喂 [Fmt.relativeTime]。
            val time = row.getChildAt(2) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.END
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(dp(96), ViewGroup.LayoutParams.WRAP_CONTENT)
                row.addView(this)
            }

            name.text = (if (e.isDir) "▸ " else "  ") + e.name
            meta.text = if (e.isDir) "目录" else formatSize(e.sizeBytes)
            time.text = Fmt.relativeTime(e.updatedAtMs, System.currentTimeMillis())
            time.setTextColor(if (e.updatedAtMs > 0) 0xFF9AA3B2.toInt() else 0xFF4B5563.toInt())
            // 目录/视频用不同颜色，遥控器上远看也能分清（品牌紫色系）
            name.setTextColor(
                when {
                    e.isDir -> BRAND_TINT
                    e.isVideo -> Color.WHITE
                    else -> 0xFF6B7280.toInt()
                },
            )
            // 选中态：ListView 默认不改行背景（divider=null 时看不出选中），
            // 这里自己给一层高亮，否则遥控器上「按了没反应」。
            row.setBackgroundColor(
                if (listView.isFocused && listView.selectedItemPosition == position) {
                    BRAND_SELECT
                } else {
                    Color.TRANSPARENT
                },
            )
            return row
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private companion object {
        const val TAG = "CloudCine"

        /** 品牌主色 `#7F77DD` 在深底上的可读版本。 */
        const val BRAND_TINT = 0xFFA9A3F5.toInt()

        /** 选中行底色：品牌色的深色调，既要能看出选中、又不能刺眼。 */
        const val BRAND_SELECT = 0xFF332C63.toInt()
    }
}
