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
import com.cloudcine.tv.pan.DriveClient
import com.cloudcine.tv.pan.DriveClients
import com.cloudcine.tv.pan.DriveEntry
import com.cloudcine.tv.pan.DriveException
import com.cloudcine.tv.pan.DriveProviders
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.formatSize
import com.cloudcine.tv.library.BatchFileDeleter
import com.cloudcine.tv.library.DriveBatchDeletePlan
import com.cloudcine.tv.library.DriveBatchTarget
import com.cloudcine.tv.library.DriveDeletePlan
import com.cloudcine.tv.library.DriveDeleteTarget
import com.cloudcine.tv.library.FolderSortMode
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.ProgressStore
import com.cloudcine.tv.library.LibraryScanner
import com.cloudcine.tv.library.MediaNameParser
import com.cloudcine.tv.library.dirPathOf
import com.cloudcine.tv.library.fullPathOf
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

    /**
     * 当前操作的网盘客户端（`quark` / `baidu`）。
     *
     * ⛔ 类型是 [DriveClient] 而不是 `PanApi`：这个页面的每一件事（列目录、
     *    取缩略图、发现）都只用到接口里那六个方法，没有任何一处需要夸克
     *    特有的能力。绑死 `PanApi` 就等于「百度账号进不来」。
     */
    private lateinit var api: DriveClient

    /** 本页正在操作哪家网盘 —— 决定 `EXTRA_PROVIDER` 与 Cookie 取哪一份。 */
    private var provider: String = DriveProviders.QUARK

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

    /**
     * 是否有删除正在跑。
     *
     * ⛔ 与 [discovering] 分开：删除是**不可逆**的，重复触发等于对同一个 fid
     *    发两次永久删除请求。而 `Busy` 那种全局闸门在这里没有意义 —— 发现
     *    跑到一半时用户完全可以去删一个不相干的文件。
     */
    private var deleting = false

    /**
     * 多选删除态。
     *
     * ⛔ 与媒体库页（`LibraryActivity.selecting`）同一套交互语言：OK 勾选 /
     *    取消、菜单 全选与删除、返回 退出。用户在两个页面学到的是同一件事，
     *    不必再猜一次「这个页面的多选怎么退出」。
     * ⛔ 按 **fid** 记而不是按下标：删掉几项之后 `entries` 会整体前移，
     *    按下标记的话「已选 3 项」里可能有两个已经不是原来那两个了。
     */
    private var selecting = false
    private val selectedFids = LinkedHashSet<String>()

    private lateinit var hint: TextView

    private lateinit var listView: ListView
    private lateinit var title: TextView
    private lateinit var status: TextView

    /**
     * 状态行上方那句「上一次操作的结果」。
     *
     * ⛔ 存在的理由：删完之后必须重列（[reloadHere] → [open] → [paintStatus]），
     *    而 `paintStatus` 会把整行改写成本层统计 —— 结果提示就这么被冲掉了。
     *    实测：删 7 项、2 项失败，用户看到的只有「夸克 · 共 12 项」，失败那两条
     *    **没有任何地方**再说过一次。
     * ⛔ 只在**导航**时清（进目录 / 上一层 / 切网盘 / 重新登录），重列时保留
     *    （[open] 的 `keepNote`）。
     */
    private var statusNote: String? = null

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
        // ⛔ 厂家由 `activeProvider` 决定（两家可以同时登录，页头/菜单里能切）。
        provider = store.activeProvider
        api = DriveClients.create(provider, store)
        db = LibraryDb.shared(
            LibraryPaths.dbFile(this),
            progress = ProgressStore.shared(LibraryPaths.progressFile(this)),
        )
        // ⛔ `provider` 必须传下去：条目主键是 `provider:fileId`，扫描器用错了
        //    厂家就会把百度的文件写成夸克的条目（或反过来），而这是**静默的** ——
        //    表现为「媒体库里同一部片子出现两格，其中一格点开播不了」。
        scanner = LibraryScanner(api = api, db = db, provider = provider)

        // ⛔ `anyLoggedIn` 而不是 `loggedIn`：后者只问夸克。只看夸克的话，
        //    只登录了百度的用户会被直接踢回登录页，永远进不了文件列表。
        if (!store.anyLoggedIn) {
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

        // ⛔ 底部提示行必须是**字段**：多选态下整行字要换（见 [paintHint]）。
        //    原来它是就地 `addView(TextView(...))`，进多选之后底部还写着
        //    「OK 进入/播放」，而那时 OK 已经是勾选 —— 屏幕上唯一一处说明
        //    按键的地方在骗人。
        hint = TextView(this).apply {
            setTextColor(0xFF6B7280.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(48), dp(6), dp(48), dp(20))
        }
        column.addView(hint)
        paintHint()

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

        // ⛔ 根标识**按厂家取**：夸克是 `"0"`、百度是 `"/"`。写死任一个，
        //    另一家的第一次列目录就会落在一个不存在的目录上。
        open(api.rootId, "云影")
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
        // ⛔ 多选态下菜单**整份换掉**：这时候「发现」「切网盘」「重新登录」
        //    都不该出现 —— 勾完 8 项再去发现一次，列表会重列，勾选全丢，
        //    而用户以为是自己勾错了。
        if (selecting) {
            openSelectionMenu()
            return
        }
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
            // ⛔ 栈空 = **根目录那一层还没读出来**（最常见的原因是列目录失败，
            //    比如凭证失效）。此时「本目录」就是网盘根，不能拿空串去
            //    `doDiscover` —— 那只会得到一句「拿不到这个目录的标识」，
            //    把真正的失败原因（登录失效）盖掉，而用户此刻唯一能做的
            //    恰恰是去重新登录。
            // ⛔ 根的标识两家不同（夸克 `"0"` / 百度 `"/"`）⇒ 取 `api.rootId`。
            val atRoot = stack.isEmpty()
            val scopeLabel = if (atRoot) "网盘根目录" else "「$here」"
            actions.add(
                "发现本目录$scopeLabel（含子目录）" to {
                    doDiscover(
                        stack.lastOrNull()?.first ?: api.rootId,
                        if (atRoot) "/" else pathOfStack(),
                        true,
                        if (atRoot) "根目录" else "本目录",
                    )
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

        // ── 删除这一项（网盘 + 媒体库索引）────────────────────────────
        // ⛔ 只在**夸克**下出现：电视端对百度只读（`BaiduApi` 上根本没有删除
        //    方法），给百度用户一个按下去必然失败的选项是纯粹的欺骗。
        // ⛔ 排在「发现」之后、「媒体库」之前：它是**针对光标那一行**的动作，
        //    与上面三项同类；放到页面级入口后面会被读成全局操作。
        if (!discovering && cur != null && canDeleteHere) {
            actions.add("删除「${cur.name}」（网盘，不可撤销）…" to { confirmDeleteEntry(cur) })
        }

        // ── 多选删除（清一整个目录、或一次删几部片子）────────────────────
        // ⛔ 只在**夸克**下出现，理由同上面那条单选（百度只读）。
        // ⛔ 排在单选之后：单条是常用动作，批量是「清一层」的重手动作，
        //    重的那个要往后放，别让它在菜单里抢走第一次按下的位置。
        if (!discovering && !deleting && canDeleteHere && entries.isNotEmpty()) {
            actions.add("多选删除（网盘，不可撤销）…" to { enterSelection() })
        }

        actions.add("媒体库" to { gotoLibrary() })

        // ── 网盘切换 / 重新登录 ──────────────────────────────────────
        // ⛔ 只在「另一家已登录」时才出现切换项：没登录过的那家点进去也是
        //    去登录页，而「重新登录」那条已经把路留好了。
        val other = if (provider == DriveProviders.BAIDU) {
            DriveProviders.QUARK
        } else {
            DriveProviders.BAIDU
        }
        if (store.loggedIn(other)) {
            actions.add("切换到${DriveProviders.displayName(other)}" to { switchProvider(other) })
        } else {
            actions.add("登录${DriveProviders.displayName(other)}" to { switchProvider(other) })
        }
        actions.add(
            "重新登录${DriveProviders.displayName(provider)}" to { relogin() },
        )

        showOverlay(titleText = DriveProviders.displayName(provider), labels = actions.map { it.first }) { index ->
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

    /** 重新登录：**只**清当前这一家的凭证，回登录页。 */
    private fun relogin() {
        // ⛔ 不再 `store.clear()`（那是两家一起退）：另一家的凭证没惹事，
        //    一起清掉等于「换个号把另一个网盘也登出了」。
        store.clearProvider(provider)
        startActivity(
            Intent(this, LoginActivity::class.java)
                .putExtra(LoginActivity.EXTRA_PROVIDER, provider),
        )
        finish()
    }

    /**
     * 切到另一家网盘（两家可以同时登录，这里只换「现在操作谁」）。
     *
     * ⛔ 换的是 `activeProvider` + 本页的 `api` / `scanner`，**不是**只改个标题：
     *    列表、缩略图、发现全都绑在 `api` 上，只换标题会让「标题写百度、
     *    列表还是夸克」。
     */
    private fun switchProvider(next: String) {
        if (next == provider) return
        if (!store.loggedIn(next)) {
            // 没登录过就先登录 —— 登完 `LoginActivity` 会把它设成 active 并进媒体库。
            startActivity(
                Intent(this, LoginActivity::class.java)
                    .putExtra(LoginActivity.EXTRA_PROVIDER, next),
            )
            finish()
            return
        }
        Log.i(TAG, "切换网盘：$provider → $next")
        provider = next
        store.activeProvider = next
        api = DriveClients.create(provider, store)
        scanner = LibraryScanner(api = api, db = db, provider = provider)
        stack.clear()
        entries.clear()
        adapter.notifyDataSetChanged()
        open(api.rootId, "云影")
    }

    // ------------------------------------------------------------------

    /**
     * 列目录并接管当前层。
     *
     * @param keepNote 重列（[reloadHere]）时传 `true`：这时状态行上那句
     *   「上一次删除的结果」还要留着。用户主动导航时保持默认 `false` ——
     *   换了一层还顶着上一层的删除结果，读起来像是这一层刚删过东西。
     */
    private fun open(fid: String, name: String, keepNote: Boolean = false) {
        if (!keepNote) statusNote = null
        status.text = "加载中…"
        Bg.run({ api.listDirectory(fid) }) { list, err ->
            if (err != null) {
                // ⛔ 凭证失效要给**下一步动作**，不能只回一句 `errno=-6`：
                //    电视上没有地址栏也没有刷新按钮，用户能做的只有菜单。
                status.text = if (err is DriveException && err.needsReauth) {
                    "登录已失效：按「菜单 → 重新登录${DriveProviders.displayName(provider)}」"
                } else {
                    "加载失败：${err.message}"
                }
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
            paintStatus()
            listView.setSelection(0)
            listView.requestFocus()
        }
    }

    private fun onEntry(e: DriveEntry) {
        // ⛔ 多选态下点一行 = 勾选 / 取消，**不是**进目录或播放。
        //    与媒体库页作品墙同一个取舍：勾了 6 项又点进一部片子里是纯干扰，
        //    而且退回来之后勾选还在、用户已经忘了自己勾到哪。
        if (selecting) {
            toggleSelected(e.fid)
            return
        }
        when {
            e.isDir -> open(e.fid, e.name)
            e.isVideo -> startActivity(
                Intent(this, PlayerActivity::class.java)
                    .putExtra(PlayerActivity.EXTRA_FID, e.fid)
                    .putExtra(PlayerActivity.EXTRA_NAME, e.name)
                    // ⛔ Cookie 按**当前厂家**取（夸克要把 `Video-Auth` 拼进去，
                    //    百度不需要）。取错那一份的表现是「列表能刷、一播 412/-6」。
                    .putExtra(PlayerActivity.EXTRA_HEADERS, store.requestCookie(provider))
                    // ⛔ 把**当前目录**的 fid 一起带过去 —— 播放页靠它扫同目录的
                    //    外挂字幕。单个文件的 fid 推不出父目录，网盘也没有
                    //    「查父目录」的接口，所以只能在这里给。
                    //    目录栈的栈顶就是当前列表，`onEntry` 只会在它上面被调用。
                    .putExtra(PlayerActivity.EXTRA_PDIR, stack.lastOrNull()?.first.orEmpty())
                    // ── 厂家 + 两条路径（百度要用）──────────────────────
                    // 百度没有「fid → 路径」的反查接口，而取链的兜底路由全是
                    // 按路径来的。这里顺手把「完整文件路径」和「父目录路径」
                    // 都算好带过去，播放页就不必再打一次 xpan（那正是 `-6`
                    // 风控最常见的来源）。
                    .putExtra(PlayerActivity.EXTRA_PROVIDER, provider)
                    .putExtra(
                        PlayerActivity.EXTRA_PATH,
                        fullPathOf(pathOfStack(), e.name),
                    )
                    .putExtra(PlayerActivity.EXTRA_PDIR_PATH, dirPathOf(pathOfStack()))
                    // ⛔ 「选集」的唯一入口（与媒体库播放同口径）：播放页靠它查出
                    //    同一作品下的其它文件。文件列表本身就是「按目录实时列文件」，
                    //    没有媒体库的 `work.key` 可用，只能**现算**一个 `group_key`
                    //    —— 用和扫描器同一支 `MediaNameParser`，从「当前目录 + 文件名」
                    //    推出来。库里扫过的片子，这里推出来的 key 与库里的 `group_key`
                    //    逐字一致 ⇒ 选集正常；没扫过的，推出来也查不到兄弟集，
                    //    只是这一行不出现，播放本身不受影响。
                    .putExtra(
                        PlayerActivity.EXTRA_GROUP_KEY,
                        MediaNameParser.parse(e.name, pathOfStack()).groupKey,
                    ),
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
        //    给播放页传 `EXTRA_PDIR` 是同一个理由）。栈空 = 根目录，fid 取 `api.rootId`。
        val dirId = stack.lastOrNull()?.first ?: api.rootId
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

    /**
     * 当前这一层的状态行文案。
     *
     * ⛔ 抽出来是因为它有两个写入口（列目录成功、确认框关掉之后要把被借走的
     *    那一行还回去）。两处各写一遍的话，某一处漏了「目录 N」就再也不会回来，
     *    而用户只会觉得「这个页面有时候数得不对」。
     *
     * ⛔ 带上厂家短名：两家同时登录时，用户只能靠这一处分辨「我现在看的是
     *    哪个网盘」。
     * ⛔ 上面可能还压着一句 [statusNote]（上一次删除的结果）：删完必然重列，
     *    而重列成功就会走到这里 —— 不把它带上，那句「已删除 7 项 / 2 项失败」
     *    只会闪一下，失败的那两条再没有任何地方说过。
     */
    private fun paintStatus() {
        val base = "${DriveProviders.shortName(provider)} · 共 ${entries.size} 项" +
            "（目录 ${entries.count { it.isDir }}）"
        val note = statusNote
        status.text = if (note.isNullOrEmpty()) base else "$note\n$base"
    }

    // ------------------------------------------------------------------
    // 删除网盘条目（并把媒体库里的索引一起清掉）
    // ------------------------------------------------------------------

    /** 这家网盘现在能不能删。电视端只有夸克能删（`PanApi.deleteFiles`）。 */
    private val canDeleteHere: Boolean
        get() = provider == DriveProviders.QUARK && api is PanApi

    /**
     * 光标那一行 ⇒ 先数清媒体库里牵连几条，再弹确认。
     *
     * ## ⛔ 必须先数、再问
     *
     * 「媒体库里有 N 条会一起清掉」是用户判断「这一下会动多少」的唯一依据 ——
     * 删一个 200 集的目录，库里就是 200 条索引。先弹框后统计的话，那句只能
     * 省略，而用户按下去之后才发现媒体库里少了一整季。
     *
     * ## ⛔ 目录要按**当前这一层的路径**算前缀
     *
     * `childPath(name)` 而不是网盘条目自带的路径：列目录拿到的条目里那个字段
     * 通常是空的，拿它去匹配会**静默地一条都匹配不到**，而那些死索引会留在库里。
     */
    private fun confirmDeleteEntry(e: DriveEntry) {
        if (!canDeleteHere) {
            status.text = "${DriveProviders.displayName(provider)} 只读，不支持删除"
            return
        }
        if (deleting) {
            status.text = "正在删除，请稍候…"
            return
        }
        val prefix = if (e.isDir) childPath(e.name) else null
        // ⛔ 清掉上一次的结果再统计：下面会 `paintStatus()`，留着旧 note 的话
        //    屏幕上会顶着「上一次删了 N 项」，而这一次还没开始。
        statusNote = null
        status.text = "正在统计「${e.name}」在媒体库里的条目…"
        Bg.run({ db.countDriveEntry(provider, e.fid, prefix) }) { count, err ->
            if (err != null) {
                Log.e(TAG, "统计媒体库条目失败", err)
                status.text = "统计失败：${err.message}"
                return@run
            }
            // 统计完把状态行还回去：停在「正在统计…」上，而屏幕上已经弹着
            // 确认框了，用户会以为还有东西在跑。
            paintStatus()
            val plan = DriveDeletePlan(
                target = DriveDeleteTarget(
                    fid = e.fid,
                    name = e.name,
                    isDir = e.isDir,
                    sizeBytes = e.sizeBytes,
                ),
                providerName = DriveProviders.displayName(provider),
                libraryItems = count ?: 0,
            )
            showOverlay(
                titleText = planText(plan),
                // ⛔ 「取消」在第一位：`showOverlay` 的光标从 0 开始，用户按 OK
                //    落在取消上 —— 一次顺手确认不该删掉一季的片子。
                labels = listOf("取消", plan.confirmLabel),
            ) { index ->
                hideOverlay()
                if (index == 1) doDeleteEntry(plan, prefix)
            }
        }
    }

    /** 确认框正文：按「删什么 → 能不能回来 → 连带什么 → 腾多少 → 库里几条」排。 */
    private fun planText(plan: DriveDeletePlan): String = listOfNotNull(
        plan.title,
        plan.irreversible,
        plan.folderWarning,
        plan.freedLabel,
        plan.libraryLine,
    ).joinToString("\n")

    /**
     * 真删：先网盘、后索引。
     *
     * ⛔ 顺序不能反：索引一删，`media_items` 里那条 `provider:fileId` 就没了，
     *    而它正是网盘要删的那个 fid 的唯一来源。
     * ⛔ 网盘删除**失败时不清索引**：留着索引，用户下次扫描还能看见它；清掉的
     *    话会变成「文件还在网盘上，媒体库里却没了」—— 要回来得重扫一遍。
     * ⛔ 只有真的删掉了才重列：失败时重列，列表一动不动，用户会以为界面没反应。
     */
    private fun doDeleteEntry(plan: DriveDeletePlan, dirPathPrefix: String?) {
        if (deleting) return
        deleting = true
        status.text = "正在删除「${plan.target.name}」…"
        Bg.run({
            val pan = api as? PanApi
            val ok = pan?.deleteFiles(listOf(plan.target.fid)) ?: emptyList()
            // ⛔ 只有确认删掉的才清索引（理由见方法文档第二段）。
            val removed =
                if (ok.isNotEmpty()) {
                    db.purgeDriveEntry(provider, plan.target.fid, dirPathPrefix)
                } else {
                    0
                }
            ok.size to removed
        }) { out, err ->
            deleting = false
            val deleted = out?.first ?: 0
            val removed = out?.second ?: 0
            if (err != null) Log.e(TAG, "删除网盘条目失败：${plan.target.name}", err)
            Log.i(
                TAG,
                "删除网盘条目「${plan.target.name}」：deleted=$deleted，" +
                    "媒体库清掉 $removed 条",
            )
            val msg = plan.resultMessage(deleted, removed, err?.let { explainDriveError(it) })
            // ⛔ 同时写进 [statusNote]：删成功会立刻 reloadHere，而重列走
            //    `paintStatus` —— 不留在 note 上，这句只闪一下就没了。
            statusNote = msg
            status.text = msg
            if (deleted > 0) reloadHere()
        }
    }

    /** 把「再试也没用」的错误翻成用户能照做的一句话。 */
    private fun explainDriveError(err: Throwable): String = when {
        err is DriveException && err.needsReauth ->
            "登录已失效（菜单 → 重新登录${DriveProviders.displayName(provider)}）"
        else -> err.message ?: err.javaClass.simpleName
    }

    // ------------------------------------------------------------------
    // 多选删除（清一整个目录、或一次删几部片子）
    //
    // 交互语言与媒体库页的作品墙多选**逐条对齐**：OK 勾选/取消、菜单 全选与
    // 删除、返回 退出。用户在两个页面学到的是同一件事。
    //
    // ⛔ 为什么这个页面需要它：单条删除一次只能删一个，而真实用法是
    //    「这一层全是预告片，全清了」—— 20 个文件就要按 20 次「删除 → 确认」，
    //    每一次都是不可逆确认，按到第 5 次就没人再看确认框了。
    // ------------------------------------------------------------------

    /**
     * 底部提示行。
     *
     * ⛔ 必须跟着 [selecting] 换字：多选态下 OK 是**勾选**，而常态下 OK 是
     *    「进入/播放」。不换的话，屏幕上唯一一处说明按键的地方在骗人。
     * ⛔ 「已选 N 项」写在这一行而**不是**状态行：状态行归 [paintStatus] 所有，
     *    被借用之后退出多选时必须记得还回去 —— 媒体库页就是漏了这一步，
     *    退出后右上角永远停在「已选 N 部」（那边有专门的注释记着这个坑）。
     *    这一行没有第二个写入口，借用不存在归还问题。
     */
    private fun paintHint() {
        hint.text = when {
            selecting && selectedFids.isEmpty() ->
                "多选删除：OK 勾选 / 取消 · 菜单 全选或删除 · 返回 退出" +
                    "（本层共 ${entries.size} 项）"
            selecting ->
                "多选删除：已选 ${selectedFids.size} 项 · OK 勾选 / 取消 · " +
                    "菜单 全选或删除 · 返回 退出"
            else -> "↑↓ 选择 · OK 进入/播放 · 返回 上一层 · 菜单 发现/更多"
        }
    }

    /** 进入多选（菜单 → 「多选删除」）。⛔ 清空上一次的选择再进。 */
    private fun enterSelection() {
        selecting = true
        selectedFids.clear()
        listView.requestFocus()
        refreshSelectionUi()
        Log.i(TAG, "多选删除：进入（${entries.size} 项可见）")
    }

    /** 退出多选并清空选择。三个出口：返回键、菜单里的「退出多选」、删完之后。 */
    private fun exitSelection() {
        selecting = false
        selectedFids.clear()
        refreshSelectionUi()
    }

    /** 勾选 / 取消勾选一项（多选态下 OK 点行、或点触摸屏都走这里）。 */
    private fun toggleSelected(fid: String) {
        if (!selectedFids.add(fid)) selectedFids.remove(fid)
        refreshSelectionUi()
    }

    /** 「全选」选的是**当前这一层可见的**，不是整个网盘 —— 与媒体库页同口径。 */
    private fun selectAllVisible() {
        selectedFids.addAll(entries.map { it.fid })
        refreshSelectionUi()
    }

    /**
     * 多选态变化之后的统一重画。
     *
     * ⛔ 列表与提示行必须一起刷：只刷列表的话，底部还写着上一次的「已选 N 项」；
     *    只刷提示行的话，刚勾的那一行没有勾。
     */
    private fun refreshSelectionUi() {
        adapter.notifyDataSetChanged()
        paintHint()
    }

    /** 多选态下的菜单（比常态少得多：勾选期间「发现」「切网盘」都不该出现）。 */
    private fun openSelectionMenu() {
        val actions = ArrayList<Pair<String, () -> Unit>>()
        actions.add("全选本层（${entries.size} 项）" to { selectAllVisible() })
        if (selectedFids.isNotEmpty()) {
            actions.add("清空已选（${selectedFids.size} 项）" to {
                selectedFids.clear()
                refreshSelectionUi()
            })
        }
        // ⛔ 不可逆的那一项**排在最后**：菜单光标从第 0 项开始，一次顺手的
        //    OK 落在「全选」上无害，落在「删除 30 项」上就是灾难。
        if (selectedFids.isNotEmpty()) {
            actions.add("删除已选 ${selectedFids.size} 项（网盘，不可撤销）…" to {
                confirmBatchDelete()
            })
        }
        actions.add("退出多选" to { exitSelection() })

        showOverlay(titleText = "多选删除", labels = actions.map { it.first }) { index ->
            val act = actions.getOrNull(index) ?: return@showOverlay
            hideOverlay()
            act.second()
        }
    }

    /**
     * 勾选集合 ⇒ 待删目标。
     *
     * ⛔ 名字与体积从 [entries] 反查，查不到就用 fid 顶上：勾选之后列表不会
     *    重列（多选期间没有任何路径会改 `entries`），所以正常情况一定查得到；
     *    用 fid 兜底是为了「文案里出现一个空名字」这种更难查的故障不发生。
     */
    private fun buildBatchPlan(): DriveBatchDeletePlan {
        val targets = selectedFids.map { fid ->
            val e = entries.firstOrNull { it.fid == fid }
            DriveBatchTarget(
                fid = fid,
                name = e?.name ?: fid,
                isDir = e?.isDir ?: false,
                sizeBytes = e?.sizeBytes ?: 0L,
            )
        }
        return DriveBatchDeletePlan(
            targets = targets,
            providerName = DriveProviders.displayName(provider),
        )
    }

    /**
     * 每个目标在媒体库里的**路径前缀**：目录算整棵子树，文件为 `null`。
     *
     * ⛔ 必须在**主线程**算（读 [stack]），不能塞进 `Bg.run` 里：目录栈是
     *    主线程独占的状态，后台线程读它是在赌内存可见性。
     * ⛔ 用 [childPath] 而不是网盘条目自带的路径（那个字段列目录时通常是空的，
     *    拿它去匹配会**静默**一条都匹配不到，而死索引会留在库里）。
     */
    private fun libraryPrefixes(targets: List<DriveBatchTarget>): Map<String, String?> =
        targets.associate { it.fid to if (it.isDir) childPath(it.name) else null }

    /**
     * 「删除已选 N 项」⇒ 先数清媒体库牵连几条，再弹确认。
     *
     * ⛔ 顺序不能反：先弹框后统计的话，那句「媒体库里会一起清掉 N 条」只能
     *    省略或猜一个 —— 而它正是用户判断「这一下动多少」的唯一依据。
     */
    private fun confirmBatchDelete() {
        if (selectedFids.isEmpty()) {
            status.text = "先勾选要删除的项"
            return
        }
        if (deleting) {
            status.text = "正在删除，请稍候…"
            return
        }
        val plan = buildBatchPlan()
        val prefixes = libraryPrefixes(plan.targets)
        // ⛔ 理由同单条那条：统计完会 `paintStatus()`，旧 note 会跟着回来。
        statusNote = null
        status.text = "正在统计这 ${plan.count} 项在媒体库里的条目…"
        Bg.run({
            plan.targets.sumOf { t -> db.countDriveEntry(provider, t.fid, prefixes[t.fid]) }
        }) { count, err ->
            // 统计完把状态行还回去：停在「正在统计…」上、而屏幕上已经弹着确认框，
            // 用户会以为还有东西在跑。
            paintStatus()
            if (err != null) {
                Log.e(TAG, "统计媒体库条目失败（批量）", err)
                status.text = "统计失败：${err.message}"
                return@run
            }
            val full = plan.copy(libraryItems = count ?: 0)
            showOverlay(
                titleText = full.body,
                // ⛔ 「取消」在第一位：光标从 0 开始，顺手一下不该删掉一整个目录。
                labels = listOf("取消", full.confirmLabel),
            ) { index ->
                hideOverlay()
                if (index == 1) doBatchDelete(full, prefixes)
            }
        }
    }

    /**
     * 真删：网盘按 100 个一批发，**每一批确认删掉之后**才清对应的索引。
     *
     * ⛔ 顺序与单条那条一致（先网盘、后索引），理由也一样：索引一删，
     *    `provider:fileId` 就没了，而它是网盘要删的那个 fid 的唯一来源。
     * ⛔ 只清 `onBatch` 回调里给出的那些：`BatchFileDeleter` 只在**整批成功**
     *    时才回调（网盘只回个数，部分成功时不知道是哪几个），清早了会得到
     *    「文件还在网盘上、库里却没了」—— 那要重扫一遍才能回来。
     * ⛔ 清索引失败**不能**算成「网盘删除失败」：文件确实已经没了，报失败会让
     *    用户以为还在。只记一条日志，留一条死索引让下次扫描自愈。
     */
    private fun doBatchDelete(plan: DriveBatchDeletePlan, prefixes: Map<String, String?>) {
        if (deleting) return
        deleting = true
        status.text = "正在删除 ${plan.count} 项…"
        Bg.run({
            val pan = PanApi(store)
            var removed = 0
            val result = BatchFileDeleter.delete(
                fids = plan.targets.map { it.fid },
                onProgress = { done, total ->
                    runOnUiThread {
                        if (deleting) status.text = "正在删除 $done / $total 项…"
                    }
                },
                onBatch = { chunk, _ ->
                    for (fid in chunk) {
                        runCatching { db.purgeDriveEntry(provider, fid, prefixes[fid]) }
                            .onSuccess { removed += it }
                            .onFailure { Log.w(TAG, "清理索引失败：$fid", it) }
                    }
                },
                deleteBatch = { chunk -> pan.deleteFiles(chunk).size },
            )
            result to removed
        }) { out, err ->
            deleting = false
            val res = out?.first
            val removed = out?.second ?: 0
            val msg = plan.resultMessage(
                deleted = res?.deleted ?: 0,
                failed = res?.failed ?: 0,
                libraryRemoved = removed,
                error = res?.error ?: err?.let { explainDriveError(it) },
            )
            Log.i(TAG, "批量删除 ${plan.count} 项：$msg")
            statusNote = msg
            status.text = msg
            // ⛔ 删完必须退出多选：集合里躺着的是已经不存在的 fid，留着的话
            //    再按一次「删除已选」会对着一批死 id 发请求。
            // ⛔ 顺序是「先写 note、再 exitSelection、最后 reloadHere」：
            //    `exitSelection` 只动提示行与列表（不碰状态行），重列才会覆盖它。
            exitSelection()
            if ((res?.deleted ?: 0) > 0) reloadHere()
        }
    }

    /**
     * 重列**当前这一层**（删完一项之后用）。
     *
     * ⛔ 不能直接 `open(...)`：那个会往栈里再压一层 —— 删完一项按返回会回到
     *    同一个目录、再按一次才真的上去。先弹出栈顶再 open，栈深不变。
     */
    private fun reloadHere() {
        val top = if (stack.isNotEmpty()) {
            stack.removeAt(stack.size - 1)
        } else {
            // 栈空 = 根目录还没读出来（列目录失败过）。此时重列根。
            api.rootId to "云影"
        }
        entries.clear()
        adapter.notifyDataSetChanged()
        // ⛔ `keepNote = true`：调用方（删除路径）刚把结果写进 [statusNote]，
        //    这里重列之后状态行还要带着它。
        open(top.first, top.second, keepNote = true)
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

        // ── 多选态：返回 退出、菜单 全选/删除、↑ 在首行不再进排序胶囊 ──
        // ⛔ 必须排在排序胶囊分支**之前**：多选态下 OK 是「勾选」，而胶囊的
        //    OK 是「重排」。放行的话，用户在首行按 ↑ 会进到一个按 OK 就重排
        //    列表的地方，而他以为自己在勾第一项。
        // ⛔ 不接管 OK：那一键交给 `ListView` 的 click → [onEntry] → 勾选，
        //    自己再判一次就会出现「按一下勾两次」。
        if (selecting) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_BACK -> {
                    exitSelection()
                    return true
                }
                KeyEvent.KEYCODE_MENU -> {
                    openMenu()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_UP -> {
                    if (listView.selectedItemPosition == 0) return true
                }
            }
            return super.dispatchKeyEvent(event)
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

            // ── 勾选角标（第 0 个子 View）──
            // ⛔ 位置固定在最左、**永远存在**（非多选态用 `INVISIBLE` 而不是
            //    `GONE`）：`GONE` 会让片名在进/出多选时整体左右跳 30dp，而
            //    `getChildAt` 的下标也会跟着变（下面三个列都按下标取）。
            val tick = row.getChildAt(0) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                gravity = Gravity.CENTER
                layoutParams = LinearLayout.LayoutParams(dp(30), ViewGroup.LayoutParams.WRAP_CONTENT)
                row.addView(this)
            }
            val name = row.getChildAt(1) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                row.addView(this)
            }
            val meta = row.getChildAt(2) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextColor(0xFF9AA3B2.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.END
                row.addView(this)
            }
            // 修改时间列：与 PC 端 `ModifiedTimeColumn` 同一口径 —— 固定宽度、
            // 右对齐、显示相对时间（`3 天前`），0 / 缺失显示 `—`。`updatedAtMs`
            // 已是毫秒，直接喂 [Fmt.relativeTime]。
            val time = row.getChildAt(3) as? TextView ?: TextView(this@BrowseActivity).apply {
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

            // ⛔ 勾选角标必须在**每一帧**重设：`convertView` 复用时上一行的
            //    勾会留在这一行上，表现是「没勾的项自己打上了勾」。
            val picked = selecting && selectedFids.contains(e.fid)
            tick.text = if (picked) "☑" else "☐"
            tick.setTextColor(if (picked) BRAND_TINT else 0xFF6B7280.toInt())
            tick.visibility = if (selecting) View.VISIBLE else View.INVISIBLE

            // 勾中的行给一层暗底：电视上离得远，光靠一个 ☑ 分不清「勾了」和
            // 「光标停在这」—— 那是两个不同的东西（勾了会删，光标只是位置）。
            // ⛔ 焦点行仍然优先（用更亮的 BRAND_SELECT），否则光标在勾过的行上
            //    会看不见。
            val focusedRow = listView.isFocused && listView.selectedItemPosition == position
            row.setBackgroundColor(
                when {
                    focusedRow -> BRAND_SELECT
                    picked -> BRAND_PICKED
                    else -> Color.TRANSPARENT
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

        /** 已勾选（但光标不在）的行底色：比 [BRAND_SELECT] 更暗，两者不能混。 */
        const val BRAND_PICKED = 0xFF232038.toInt()
    }
}
