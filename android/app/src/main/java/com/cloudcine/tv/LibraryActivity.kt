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
import android.widget.AdapterView
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.GridView
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import com.cloudcine.tv.library.DeviceIdentity
import com.cloudcine.tv.library.LibraryBackupService
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryItem
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.LibraryScanner
import com.cloudcine.tv.library.MediaCategoryNames
import com.cloudcine.tv.library.PlayTarget
import com.cloudcine.tv.library.PosterStore
import com.cloudcine.tv.library.Work
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.formatSize
import java.io.File

/**
 * 媒体库 —— **海报墙**（不是文件列表）。
 *
 * ## 它和 [BrowseActivity] 是两种东西
 *
 * | | 文件列表 | 媒体库 |
 * |---|---|---|
 * | 数据来源 | 网盘**实时**目录 | **本地索引**（`cloudcine.sqlite`） |
 * | 组织方式 | 目录 → 文件 | **作品 → 文件**（刮削过的） |
 * | 有网才能用 | 是 | **否**（库是同步下来的） |
 * | 登录态 | 必需 | 浏览**不需要**（只有备份三个动作需要） |
 *
 * ## 三层导航
 *
 * `作品墙` → `某部作品的剧集列表` → [PlayerActivity]。返回键退一层。
 * MENU 键开覆盖层菜单（排序 / 筛选 / 同步 / 备份）。
 *
 * ## 界面结构（自上而下）
 *
 * ```
 * [logo] 媒体库                        128 部作品 · 全部
 * 全部 电影 剧集 动漫 综艺 纪录片 其他          ← 分类标签（←→ 选、OK 生效）
 * [排序：最近修改] [只看未看完 12] [只看有海报]  ← 筛选行（MENU 里改）
 * ┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐
 * │海报││海报││海报││海报││海报││海报││海报││海报│   ← 海报墙（GridView）
 * └────┘└────┘└────┘└────┘└────┘└────┘└────┘└────┘
 *  片名  片名  片名  片名  片名  片名  片名  片名
 *  2024·8.7 …
 * 选中作品的简介 / 类型                        ← infoLine
 * ↑↓←→ 选择 · OK 播放 · 返回 · 菜单 排序/筛选/备份
 * ```
 *
 * ## 按键：分类标签**自己管**，海报墙交给框架
 *
 * 海报墙用 `GridView`（和文件列表同一个理由：**天生支持 D-pad**，上下左右 +
 * OK 都不用写）。但分类标签是**动态加进去的一行 `TextView`**，在电视上让框架
 * 去给它们排焦点是不可靠的（`requestFocus()` 会静默失败）——
 * 所以标签行只做两件事：**自己接管 ←→**（见 [dispatchKeyEvent]），
 * 以及用 `requestFocus()` 让海报墙的选中框消失。
 */
class LibraryActivity : Activity() {

    // ── 依赖 ────────────────────────────────────────────────────────
    private lateinit var store: CredStore
    private lateinit var api: PanApi
    private lateinit var db: LibraryDb
    private lateinit var service: LibraryBackupService
    private lateinit var posters: PosterStore
    private lateinit var scanner: LibraryScanner

    // ── 扫描 ────────────────────────────────────────────────────────
    //
    // ⛔ 用「非 null 的取消开关」当「正在扫描」的判据，而不是另一个布尔量：
    //    两个变量迟早会有一个忘了同步（比如取消时清了标志、忘了清开关），
    //    表现是「返回键再也停不下扫描」。
    private var scanCancel: LibraryScanner.Cancellation? = null

    // ── 视图 ────────────────────────────────────────────────────────
    private lateinit var root: FrameLayout
    private lateinit var worksGrid: GridView
    private lateinit var itemsList: ListView
    private lateinit var title: TextView
    private lateinit var status: TextView
    private lateinit var tabsBox: LinearLayout
    private lateinit var tabsScroll: HorizontalScrollView
    private lateinit var filterBox: LinearLayout
    private lateinit var barScroll: HorizontalScrollView
    private lateinit var infoLine: TextView
    private lateinit var overlay: LinearLayout
    private lateinit var overlayTitle: TextView
    private lateinit var overlayRowsBox: LinearLayout
    private lateinit var overlayScroll: ScrollView
    private lateinit var overlayScrim: FrameLayout

    // ── 状态 ────────────────────────────────────────────────────────
    private enum class Level { WORKS, ITEMS }

    private var level = Level.WORKS
    private var currentWork: Work? = null
    private var sort = LibraryDb.Sort.recentModified
    private var playedOnly = false
    private var posterOnly = false

    // ── 状态行工具条（排序 / 筛选 / 只看有海报 / 清空）───────────────
    //
    // ⛔ 状态行**必须能拿焦点**。它上面就写着「排序：最近修改」，用户拿遥控器
    //    对着它按了半天却动不了 —— 一个「长得像控件、又真的写着当前设置」的
    //    东西不可操作，比把它藏进菜单里更让人恼火。
    private var barFocused = false
    private var barIndex = 0
    private var barItems: List<BarItem> = emptyList()

    // ── 筛选面板的生效条件（与 PC 端 `LibraryFilter` 同口径）──────────
    /** 「已刮削」开关（判据 `source = 'online'`，不是「有海报」）。 */
    private var scrapedOnly = false

    /** 年份多选。**项间是「或」**（一部作品只有一个年份，取交集恒空）。 */
    private var years: MutableSet<Int> = LinkedHashSet()

    /** 类型多选。**项间是「或」**（一部片子只有一两个类型）。 */
    private var genres: MutableSet<String> = LinkedHashSet()

    /** 生效的筛选条件数（给状态行与菜单上的角标用）。 */
    private val selectedFilterCount: Int
        get() = (if (scrapedOnly) 1 else 0) + years.size + genres.size

    /** 当前分类（`null` = 全部）。**存库里的枚举名**（`movie`/`series`/…），不存中文。 */
    private var category: String? = null

    private var counts: Map<String, Int> = emptyMap()

    /** 播过的作品数（「最近播放」的角标）。 */
    private var playedCount = 0

    /** 分面选项的角标：作用域是「分类 / 最近播放 / 已刮削 / 搜索词」，**不含**自己。 */
    private var yearCounts: Map<Int, Int> = emptyMap()
    private var genreCounts: Map<String, Int> = emptyMap()

    private var busy = false
    private var busyWhat = ""

    private val works = ArrayList<Work>()
    private val items = ArrayList<LibraryItem>()
    private lateinit var worksAdapter: WorksAdapter
    private lateinit var itemsAdapter: ItemsAdapter

    /** 单张卡片的宽度（像素），由 [computeGrid] 算一次，`getView` 反复用。 */
    private var cardW = 0

    /** 分类标签行是否拿到了焦点（此时 ←→ 归它，海报墙的选中框要藏起来）。 */
    private var tabsFocused = false

    /** 导航带上的**光标**位置（`navItems` 的下标）。⛔ 与「已生效的分类」是两个东西。 */
    private var navIndex = 0

    // ── 覆盖层状态 ──────────────────────────────────────────────────
    private var overlayVisible = false
    private var overlayIndex = 0
    private var overlayLabels: List<String> = emptyList()
    private var overlayOnPick: ((Int) -> Unit)? = null

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        store = CredStore(this)
        api = PanApi(store)
        db = LibraryDb(LibraryPaths.dbFile(this))
        service = LibraryBackupService(
            db = db,
            api = api,
            posterDir = LibraryPaths.posterDir(this),
            deviceId = DeviceIdentity.id(this),
            deviceName = DeviceIdentity.name(),
        )
        posters = PosterStore(LibraryPaths.posterDir(this), POSTER_CACHE_BYTES)
        scanner = LibraryScanner(api = api, db = db)

        root = FrameLayout(this).apply { setBackgroundColor(BG) }
        root.addView(buildContent(), matchParent())
        root.addView(buildOverlay(), matchParent())
        root.addView(buildFilter(), matchParent())
        setContentView(root)

        loadWorks()
    }

    override fun onDestroy() {
        // ⛔ 先停扫描再关库：扫描线程可能正卡在一次 `applyScanItems` 的写事务里，
        //    而 `close()` 与正在跑的语句之间没有保护（见 `LibraryDb` 类文档）。
        //    置了标志之后它最多再跑完当前那个目录。
        scanCancel?.cancel()
        super.onDestroy()
        // ⛔ 必须关：留着连接的话，下次 `rawBytes()` 会读到一份「少最后几次写入」
        //    的库（理由见 `LibraryDb.rawBytes` 的文档）。
        runCatching { db.close() }
    }

    // ------------------------------------------------------------------
    // 视图构建
    // ------------------------------------------------------------------

    private fun buildContent(): View {
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        // ── 页头：品牌图标 + 标题 + 右侧计数 ──
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(GRID_PAD_DP), dp(18), dp(GRID_PAD_DP), dp(2))
        }
        head.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(30), dp(30)),
        )
        title = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setPadding(dp(10), 0, 0, 0)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.START
        }
        head.addView(title, LinearLayout.LayoutParams(0, WRAP, 1f))
        status = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            gravity = Gravity.END
            maxLines = 1
        }
        head.addView(status)
        column.addView(head)

        // ── 分类标签行 ──
        tabsBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(GRID_PAD_DP), dp(2), dp(GRID_PAD_DP), dp(2))
            // ⛔ 只有它能拿焦点：拿到焦点 = 海报墙的选中框消失（见类文档）。
            //    方向键不靠框架遍历，全部由 dispatchKeyEvent 自己分派。
            isFocusable = true
            isFocusableInTouchMode = true
        }
        // ⛔ **必须能横向滚动**。分类有 8 颗胶囊（全部/最近播放/五个分类/文件列表），
        //    宽度随「片名计数」和系统字体缩放变化，装不下时 `LinearLayout` 会把
        //    最后一颗压扁 ⇒ 文字折成两行（实测「文件列表」变成「文件列/表」，
        //    整条导航带的高度被顶起来，海报墙少一行）。
        //    滚动条本身不画（电视上看不见也按不到），焦点也不给它 —— 位置
        //    完全由 `navIndex` 驱动，见 [revealNavChip]。
        tabsScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            clipToPadding = false
            clipChildren = false
        }
        tabsScroll.addView(
            tabsBox,
            FrameLayout.LayoutParams(WRAP, WRAP),
        )
        column.addView(
            tabsScroll,
            LinearLayout.LayoutParams(MATCH, WRAP),
        )

        // ── 状态行工具条（排序 / 筛选 / 只看有海报 / 清空）──
        //
        // ⛔ 这一行**是可操作的**（`isFocusable = true`），不再是「只显示状态」。
        //    之前的版本把它做成纯标签，用户对着「排序：最近修改」按遥控器
        //    一点反应都没有 —— 而它恰恰写着当前排序，看起来就是个控件。
        //    改条件的入口**同时**保留在 MENU 里（两处都通，不冲突）。
        filterBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(GRID_PAD_DP), dp(2), dp(GRID_PAD_DP), dp(6))
            isFocusable = true
            isFocusableInTouchMode = true
        }
        // 与导航带同一个理由：控件数随状态变化（「清空筛选」只在有条件时出现），
        // 装不下时**横向滚动**，不许折行把海报墙顶掉一行。
        barScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            clipToPadding = false
            clipChildren = false
        }
        barScroll.addView(filterBox, FrameLayout.LayoutParams(WRAP, WRAP))
        column.addView(barScroll, LinearLayout.LayoutParams(MATCH, WRAP))

        // ── 海报墙 ──
        worksAdapter = WorksAdapter()
        worksGrid = GridView(this).apply {
            adapter = worksAdapter
            // ⛔ 选中框自己画（见 WorksAdapter.getView）：框架的 selector 在
            //    `divider` 类的属性上不可控，而卡片是圆角的，套一个方框很丑。
            setSelector(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
            isFocusable = true
            isFocusableInTouchMode = true
            setPadding(dp(GRID_PAD_DP), dp(4), dp(GRID_PAD_DP), dp(4))
            clipToPadding = false
            // ⛔ 选中卡片会放大 1.05，**必须关掉子视图裁剪**，否则多出来的那圈
            //    会被格子切掉，看起来像海报被裁了一块。
            clipChildren = false
            verticalSpacing = dp(GRID_GAP_DP)
            setOnItemClickListener { _, _, position, _ -> onWorkRow(position) }
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(p: AdapterView<*>?, v: View?, position: Int, id: Long) {
                    showInfo(works.getOrNull(position))
                    // ⛔ 移动选中项必须**重画一遍可见卡片**：焦点效果（描边 / 变暗 /
                    //    放大）是在 `getView` 里按 `selectedItemPosition` 算的，
                    //    而 `GridView` 不会因为选中项变了就重绑旧的那一张 ——
                    //    不重画的话，旧卡片的边框会一直留在屏幕上。
                    // ⛔ 用 `post`：在 `onItemSelected` 里直接
                    //    `notifyDataSetChanged()` 会在布局过程中再次请求布局。
                    worksGrid.post { worksAdapter.notifyDataSetChanged() }
                }

                override fun onNothingSelected(p: AdapterView<*>?) {
                    showInfo(null)
                    worksGrid.post { worksAdapter.notifyDataSetChanged() }
                }
            }
        }
        column.addView(worksGrid, LinearLayout.LayoutParams(MATCH, 0, 1f))

        // ── 剧集列表（进作品后才显示）──
        itemsAdapter = ItemsAdapter()
        itemsList = ListView(this).apply {
            adapter = itemsAdapter
            divider = null
            dividerHeight = 0
            setBackgroundColor(BG)
            visibility = View.GONE
            setOnItemClickListener { _, _, position, _ -> onItemRow(position) }
            isFocusable = true
            isFocusableInTouchMode = true
        }
        column.addView(itemsList, LinearLayout.LayoutParams(MATCH, 0, 1f))

        // ── 底部：选中作品的信息 + 按键提示 ──
        infoLine = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(GRID_PAD_DP), dp(6), dp(GRID_PAD_DP), 0)
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        column.addView(infoLine)

        column.addView(TextView(this).apply {
            text = "↑↓←→ 选择 · OK 直接播放 · ↑ 到状态行（排序 / 筛选）· 菜单 更多"
            setTextColor(0xFF6B7280.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(GRID_PAD_DP), dp(4), dp(GRID_PAD_DP), dp(16))
        })

        // 卡片宽度要按屏幕算，`onCreate` 里控件还没量过宽 —— 直接用屏幕宽度，
        // 本页是全屏横屏，两者一致。
        computeGrid()
        return column
    }

    /**
     * 按屏幕宽度算「几列、每列多宽」。
     *
     * ⛔ **不要写死列数**：电视的 `density` 从 1.0 到 2.0 都有，写死 6 列在
     *    低密度屏上是巨卡、在高密度屏上是一排小豆腐块。目标卡宽给 dp，
     *    列数由实际像素宽度反算，再钳到 [4, 9]。
     */
    private fun computeGrid() {
        val spacing = dp(GRID_GAP_DP)
        val avail = resources.displayMetrics.widthPixels - dp(GRID_PAD_DP * 2)
        var cols = (avail + spacing) / (dp(TARGET_CARD_DP) + spacing)
        cols = cols.coerceIn(4, 9)
        cardW = (avail - spacing * (cols - 1)) / cols
        worksGrid.numColumns = cols
        worksGrid.horizontalSpacing = spacing
        worksGrid.columnWidth = cardW
        Log.i(TAG, "海报墙：${cols} 列 × ${cardW}px（屏宽 ${resources.displayMetrics.widthPixels}px）")
    }

    private fun buildOverlay(): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0xB3000000.toInt())
            isClickable = true
            visibility = View.GONE
        }
        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // ⛔ 卡片**不描边**（用户明确说过线框不好看）。层次靠「比背景亮一档的
            //    实心面 + 更大的圆角」，而不是轮廓线 —— 深色 UI 里后者只会
            //    变成一条看不清的细线。
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
        // ⛔ 菜单**必须能滚**。行高约 45dp，而 1080p 电视只有 540dp 高 ——
        //    菜单长到十一二项（作品页现在是这个数）就会溢出，而 `LinearLayout`
        //    不会滚：**最后几项永远选不到**，遥控器按到底就停在那儿。
        //    这种缺陷在开发机上（窗口更高、密度不同）根本看不出来。
        // ⛔ 滚动条自己**不能拿焦点**：焦点在菜单行上，`ScrollView` 一旦可聚焦
        //    就会在按 ↑↓ 时把光标吸走。
        overlayScroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            addView(
                overlayRowsBox,
                ViewGroup.LayoutParams(MATCH, WRAP),
            )
        }
        overlay.addView(overlayScroll, LinearLayout.LayoutParams(MATCH, WRAP))

        scrim.addView(
            overlay,
            FrameLayout.LayoutParams(dp(560), WRAP).apply { gravity = Gravity.CENTER },
        )
        overlayScrim = scrim
        return scrim
    }

    // ------------------------------------------------------------------
    // 读库
    // ------------------------------------------------------------------

    /** 一次读库要拿的全部东西（**必须在同一个后台任务里取**，见 [loadWorks]）。 */
    private data class Snapshot(
        val works: List<Work>,
        val hasContent: Boolean,
        val counts: Map<String, Int>,
        val played: Int,
        val years: Map<Int, Int>,
        val genres: Map<String, Int>,
    )

    private fun loadWorks(keepStatus: String? = null) {
        if (keepStatus == null) status.text = "读取媒体库…"
        // ⛔ 所有查询都在**同一个后台任务**里：`hasContent()` / `categoryCounts()`
        //    也都是查库，挪到下面的回调里（那个回调在主线程）就是主线程读 SQLite。
        // ⛔ `buildIndex()` 也要放这儿：它要 `listFiles()` 扫海报目录（实测 325 个）。
        Bg.run({
            posters.buildIndex()
            Snapshot(
                works = db.listWorks(
                    sort = sort,
                    playedOnly = playedOnly,
                    category = category,
                    years = years,
                    genres = genres,
                    scrapedOnly = scrapedOnly,
                ),
                hasContent = db.hasContent(),
                counts = db.categoryCounts(),
                played = db.playedCount(),
                // ⛔ 分面角标的作用域**不含 years / genres 自己**：否则用户每勾一个
                //    类型，剩下的类型角标就跟着变，勾到第二个时列表已经空了 ——
                //    而面板唯一的承诺是「点下去至少有一条结果」。
                years = db.yearCounts(category, playedOnly, scrapedOnly),
                genres = db.genreCounts(category, playedOnly, scrapedOnly),
            )
        }) { snap, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                Log.e(TAG, "读媒体库失败", err)
                return@run
            }
            val s = snap ?: return@run
            counts = s.counts
            playedCount = s.played
            yearCounts = s.years
            genreCounts = s.genres
            level = Level.WORKS
            currentWork = null
            applyWorks(s.works, keepStatus ?: defaultStatus(s))
            Log.i(
                TAG,
                "媒体库：${s.works.size} 部（分类=${category ?: "全部"}" +
                    (if (playedOnly) "·最近播放" else "") +
                    (if (scrapedOnly) "·已刮削" else "") +
                    (if (years.isNotEmpty()) "·年份$years" else "") +
                    (if (genres.isNotEmpty()) "·类型$genres" else "") +
                    "）· 海报索引 ${posters.indexedCount} 个文件 · 命中 " +
                    "${s.works.count { posters.fileFor(it) != null }}",
            )
        }
    }

    private fun defaultStatus(s: Snapshot): String = when {
        s.works.isEmpty() && s.hasContent -> "这个分类/筛选下没有作品"
        s.works.isEmpty() -> "媒体库是空的 —— 菜单 → 从网盘恢复，把电脑上的库同步下来"
        else -> "共 ${s.works.size} 部"
    }

    /** 换一批作品：**先过客户端筛选，再交给适配器**。 */
    private fun applyWorks(list: List<Work>, statusText: String) {
        val visible = if (posterOnly) list.filter { posters.fileFor(it) != null } else list
        works.clear()
        works.addAll(visible)
        level = Level.WORKS
        currentWork = null
        worksGrid.visibility = View.VISIBLE
        itemsList.visibility = View.GONE
        // ⛔ 收起/展开的是**滚动容器**，不是里面的 `LinearLayout`：
        //    只把子视图设成 GONE 的话，外面那层 `HorizontalScrollView` 还在，
        //    它会留一条高度为 0 却仍然参与焦点搜索的空壳。
        tabsScroll.visibility = View.VISIBLE
        barScroll.visibility = View.VISIBLE
        title.text = "媒体库"
        status.text = statusText
        paintTabs()
        paintBar()
        worksAdapter.notifyDataSetChanged()
        // ⛔ **不要把焦点从导航带 / 状态行上抢回来**。之前这里无条件
        //    `requestFocus()`，于是用户按 ←→ 切分类的瞬间焦点就被弹回海报墙
        //    —— 表现就是「一级导航点不动 / 切不了」；状态行上的排序同理，
        //    每改一次排序焦点就丢掉，用户得重新走一遍方向键。
        //    焦点归谁只由 [focusTabs] / [focusBar] / [focusGrid] 决定。
        // ⛔ 筛选面板开着时也不能抢：面板是覆盖层，底下的墙拿焦点会让面板失焦。
        if (!tabsFocused && !barFocused && !filterVisible && !overlayVisible) {
            worksGrid.setSelection(0)
            worksGrid.requestFocus()
            showInfo(works.firstOrNull())
        }
    }

    private fun openWork(w: Work) {
        status.text = "读取「${w.title}」…"
        Bg.run({ db.itemsForWork(w.key) }) { list, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                return@run
            }
            items.clear()
            items.addAll(list ?: emptyList())
            level = Level.ITEMS
            currentWork = w
            itemsAdapter.notifyDataSetChanged()
            worksGrid.visibility = View.GONE
            itemsList.visibility = View.VISIBLE
            // ⛔ 进作品后分类/筛选行**必须收起来**：它们的作用域是「作品墙」，
            //    留在屏幕上会让人以为还能按分类过滤剧集（实际不会）。
            tabsScroll.visibility = View.GONE
            barScroll.visibility = View.GONE
            // ⛔ 焦点标志也要一起清掉：它们俩现在是不可见视图，`requestFocus()`
            //    到一个 GONE 的视图会失败，之后所有按键都会掉进「谁也不管」的
            //    空隙里（`barFocused` 还是 true，于是 dispatch 一直往那一支走）。
            tabsFocused = false
            barFocused = false
            title.text = "媒体库 / ${w.title}"
            status.text = "${w.subtitle.ifEmpty { "${items.size} 个文件" }} · ${items.size} 个文件"
            itemsList.setSelection(0)
            itemsList.requestFocus()
            infoLine.text = w.overview?.takeIf { it.isNotBlank() }?.let { brief(it) } ?: ""
        }
    }

    /** 回到作品墙。返回键在 [Level.ITEMS] 上会调它。 */
    private fun backToWorks() {
        level = Level.WORKS
        currentWork = null
        items.clear()
        loadWorks()
    }

    /** 选中卡片的简介行。 */
    private fun showInfo(w: Work?) {
        if (w == null) {
            infoLine.text = ""
            return
        }
        val parts = ArrayList<String>(4)
        parts.add(w.title)
        w.year?.takeIf { it > 0 }?.let { parts.add("$it") }
        w.rating?.takeIf { it > 0 }?.let { parts.add("★ %.1f".format(it)) }
        if (w.genres.isNotEmpty()) parts.add(w.genres.take(3).joinToString("/"))
        val head = parts.joinToString(" · ")
        val body = w.overview?.takeIf { it.isNotBlank() }?.let { brief(it) }
        infoLine.text = if (body.isNullOrEmpty()) head else "$head\n$body"
    }

    private fun brief(text: String): String =
        text.replace(Regex("\\s+"), " ").trim().let { if (it.length > 90) it.take(90) + "…" else it }

    // ------------------------------------------------------------------
    // 分类标签 / 筛选行
    // ------------------------------------------------------------------

    /**
     * 导航带上的一项。
     *
     * ⛔ **数组顺序 = 用户按 ←→ 的顺序**，所以「最近播放」紧跟「全部」。
     *    口径照 PC 端 `_CategoryBar`（也是 VidHub 的口径）：一级入口是
     *    「全部 / 最近播放 / 电影 / 剧集 / 动漫 / 综艺 / 纪录片 / 其他」。
     *
     * ⛔ 「最近播放」**不是一个分类，而是一个视图**（`playedOnly`），
     *    它跟在这排里是因为用户找它的位置就是这里；它与分类**互斥** ——
     *    点它会退出当前分类，点分类会退出它。
     */
    private inner class NavItem(
        val label: String,
        /** 角标数量；`-1` = 不画角标（「文件列表」那种纯入口）。 */
        val count: Int,
        /** 图标字符（只有「最近播放」「文件列表」用 —— 把它们和真分类区分开）。 */
        val icon: String?,
        val isCurrent: Boolean,
        val onPick: () -> Unit,
    )

    private var navItems: List<NavItem> = emptyList()

    /**
     * 重建导航带。**每次 `paintTabs()` 前调一次**（计数会随库变化）。
     *
     * ⛔ 光标位置只在**用户没在导航带上**时才跟随「当前生效项」。
     *    否则用户按 ←→ 移光标的同时触发一次重读，光标会被弹回原位 ——
     *    表现就是「按了没反应」（这正是之前那一版的毛病）。
     */
    private fun buildNav() {
        val total = counts.values.sum()
        val items = ArrayList<NavItem>(10)

        items.add(NavItem("全部", total, null, category == null && !playedOnly) {
            category = null
            playedOnly = false
            loadWorks()
        })
        items.add(NavItem("最近播放", playedCount, "◷", playedOnly) {
            category = null
            playedOnly = true
            loadWorks()
        })
        for (c in MediaCategoryNames.displayOrder) {
            items.add(
                NavItem(MediaCategoryNames.label(c), counts[c] ?: 0, null, category == c && !playedOnly) {
                    category = c
                    playedOnly = false
                    loadWorks()
                },
            )
        }
        // 文件列表是**另一个页面**（网盘实时目录），不是分类 —— 所以排在最后，
        // 用图标与前面的分类拉开距离。它就是用户找不到的那个入口。
        //
        // ⛔ **不 `finish()`**：媒体库现在是 App 的首页，用户从这儿去网盘目录找
        //    一个还没入库的文件，按返回键应该回到媒体库。`finish()` 掉的话返回键
        //    会直接退出 App，而用户以为只是「退回上一层」。
        items.add(NavItem("文件列表", -1, "▤", false) {
            startActivity(Intent(this, BrowseActivity::class.java))
        })

        navItems = items
        if (!tabsFocused) {
            val current = items.indexOfFirst { it.isCurrent }
            if (current >= 0) navIndex = current
        }
        navIndex = navIndex.coerceIn(0, items.size - 1)
    }

    private fun paintTabs() {
        buildNav()
        tabsBox.removeAllViews()
        for ((i, item) in navItems.withIndex()) {
            tabsBox.addView(navChip(item, isCursor = tabsFocused && i == navIndex))
        }
        // ⛔ **不给导航带画整体外框**。之前焦点在导航带上时会套一个贯通整行的
        //    长方形描边，用户明确说「太难看了」。而且它是多余的：光标所在的那颗
        //    胶囊自己就是实心高亮，「←→ 现在管的是这一行」由每一颗胶囊表达，
        //    不需要再在外面画一个框把八颗胶囊圈起来。
        tabsBox.background = null
        revealChip(tabsScroll, tabsBox, navIndex)
    }

    /**
     * 把光标所在的那一颗胶囊滚进可视区。
     *
     * ⛔ 导航带与状态行都是 [HorizontalScrollView]（分类数会变、控件数会随
     *    状态变、字体缩放也会变，装不下是常态）。而滚动的**唯一驱动**是
     *    `navIndex` / `barIndex` —— 胶囊自己 `isFocusable = false`，框架的
     *    「聚焦即滚动」不会发生，所以必须手动滚。不滚的话，用户按 ←→ 走到
     *    屏幕外的项时**什么都看不见**，看起来像按键失灵。
     */
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

    /**
     * 导航带上的一颗胶囊。
     *
     * 三种状态**靠实心面的明度**区分，不靠描边：
     *   * **生效中**（`isCurrent`）：亮品牌色实心 + **深色字** —— 最强，一眼看出
     *     「现在筛的就是它」；
     *   * **光标所在**（`isCursor`）：暗品牌色实心 + 亮色字 —— 「准备按 OK」；
     *   * 都没有：极淡实心 + 次级文字，数量为 0 时再压暗一档。
     *
     * ⛔ 不要改回描边：深色主题 + 沙发距离下，1~2px 的描边只剩一条细线，
     *    既看不清也不高级（用户明确反馈过）。
     */
    private fun navChip(item: NavItem, isCursor: Boolean): TextView {
        val text = buildString {
            if (item.icon != null) append(item.icon).append(' ')
            append(item.label)
            if (item.count > 0) append(' ').append(item.count)
        }
        return TextView(this).apply {
            this.text = text
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setPadding(dp(18), dp(10), dp(18), dp(10))
            // ⛔ **必须单行**。装不下时宁可被滚动条截掉、也不能折行：
            //    折行会把整条导航带顶高一行，海报墙跟着少一行（实测过）。
            maxLines = 1
            isSingleLine = true
            isFocusable = false
            isFocusableInTouchMode = false
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                setColor(
                    when {
                        item.isCurrent -> BRAND_TINT
                        isCursor -> 0xFF4A4278.toInt()
                        else -> 0x14FFFFFF
                    },
                )
            }
            setTextColor(
                when {
                    item.isCurrent -> 0xFF1A1533.toInt()
                    isCursor -> Color.WHITE
                    item.count == 0 -> 0xFF4B5563.toInt()
                    else -> 0xFFB9C0CC.toInt()
                },
            )
            val lp = LinearLayout.LayoutParams(WRAP, WRAP).apply { rightMargin = dp(8) }
            layoutParams = lp
        }
    }

    /**
     * 状态行工具条上的一项。
     *
     * ⛔ 与 [NavItem] 分开是**刻意的**：导航带是「单选组」（选中的那一个就是
     *    当前分类），而这一行是**动作**（排序 / 筛选 / 开关 / 清空），按下就
     *    发生一件事，没有「当前」这个概念。塞进同一个模型的话，
     *    `isCurrent` 那一套高亮逻辑会在这里全部失效（而失效得很安静）。
     */
    private inner class BarItem(
        val label: String,
        /** 这一项**正在生效**（比如「只看有海报」已经打开）—— 高亮成强调色。 */
        val active: Boolean,
        /** 光标停在这一项时，底部提示行显示什么。电视上没有 tooltip，只有这一行。 */
        val hint: String,
        val onPick: () -> Unit,
    )

    /**
     * 重建状态行工具条。
     *
     * ⛔ 控件数量**随状态变**（「退出最近播放」只在最近播放里出现，
     *    「清空筛选」只在有条件时出现），所以每次都重建，不能只改文字。
     */
    private fun buildBar() {
        val items = ArrayList<BarItem>(6)
        items.add(
            BarItem("⇅ 排序：${sort.label}", false, "OK 打开排序菜单") { openSortMenu() },
        )
        items.add(
            BarItem(
                if (selectedFilterCount > 0) "⚙ 筛选 $selectedFilterCount" else "⚙ 筛选",
                selectedFilterCount > 0,
                if (selectedFilterCount > 0) {
                    "OK 打开筛选面板（已生效 $selectedFilterCount 项）"
                } else {
                    "OK 打开筛选面板（年份 / 类型 / 已刮削）"
                },
            ) { openFilter() },
        )
        items.add(
            BarItem(
                if (posterOnly) "▣ 只看有海报 ✓" else "▣ 只看有海报",
                posterOnly,
                if (posterOnly) "OK 取消「只看有海报」" else "OK 只显示有海报的作品",
            ) {
                posterOnly = !posterOnly
                loadWorks()
            },
        )
        if (playedOnly) {
            items.add(
                BarItem("◷ 退出最近播放", true, "OK 回到全部分类") {
                    playedOnly = false
                    category = null
                    loadWorks()
                },
            )
        }
        if (selectedFilterCount > 0) {
            items.add(
                BarItem("✕ 清空筛选", true, "OK 清掉年份 / 类型 / 已刮削（分类与排序不动）") {
                    scrapedOnly = false
                    years.clear()
                    genres.clear()
                    loadWorks()
                },
            )
        }
        barItems = items
        barIndex = barIndex.coerceIn(0, items.size - 1)
    }

    /**
     * 画状态行工具条。
     *
     * ⛔ 三种状态**靠实心面的明度**区分，与导航带、菜单行同一套语言：
     *    光标 = 暗品牌色 + 白字 / 生效 = 半透明品牌色 + 品牌色字 / 常态 = 极淡实心。
     *    ⛔ 不描边。
     */
    private fun paintBar() {
        buildBar()
        filterBox.removeAllViews()
        for ((i, item) in barItems.withIndex()) {
            filterBox.addView(barChip(item, isCursor = barFocused && i == barIndex))
        }
        revealChip(barScroll, filterBox, barIndex)
    }

    private fun barChip(item: BarItem, isCursor: Boolean): TextView = TextView(this).apply {
        text = item.label
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
                    isCursor -> 0xFF4A4278.toInt()
                    item.active -> 0x33A9A3F5
                    else -> 0x14FFFFFF
                },
            )
        }
        setTextColor(
            when {
                isCursor -> Color.WHITE
                item.active -> BRAND_TINT
                else -> 0xFFB9C0CC.toInt()
            },
        )
        layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { rightMargin = dp(8) }
    }

    /** ←→ 在状态行里移光标。**按下就生效**（都是即时动作，没有「待确认」）。 */
    private fun moveBar(delta: Int) {
        if (barItems.isEmpty()) return
        barIndex = (barIndex + delta + barItems.size) % barItems.size
        paintBar()
        infoLine.text = barItems[barIndex].hint
    }

    /** OK：执行状态行上光标所在的动作。 */
    private fun applyBar() {
        barItems.getOrNull(barIndex)?.onPick()
    }

    /**
     * 排序子菜单。
     *
     * ⛔ 不做成「按 OK 循环切下一档」：有六档，从「最近修改」切到「标题」要按
     *    五次，每一次都会重查库 + 重排整个海报墙 —— 用户根本不知道自己按到
     *    哪一档，只看到列表在乱跳。列出来一次选完。
     *
     * ⛔ 当前档位前面打勾而不是只换颜色：深色底上颜色差异有限，而「现在按的是
     *    哪个」必须一眼可辨。
     */
    private fun openSortMenu() {
        val all = LibraryDb.Sort.entries
        val labels = all.map { if (it == sort) "✓ ${it.label}" else "    ${it.label}" }
        showOverlay(titleText = "排序", labels = labels) { index ->
            hideOverlay()
            all.getOrNull(index)?.let { picked ->
                Log.i(TAG, "排序：${sort.label} → ${picked.label}")
                sort = picked
                loadWorks()
            }
        }
    }

    /**
     * ←→ 只**移光标**，不生效。
     *
     * ⛔ 这是刻意的：分类切换会重查库、重排整个海报墙。跟着光标一路切过去，
     *    用户从「电影」按到「其他」会连触发六次全量查询 + 六次布局 ——
     *    电视上就是一路卡顿加闪屏。而 PC 端 `_CategoryChip` 也是「点一下才生效」。
     */
    private fun moveTab(delta: Int) {
        if (navItems.isEmpty()) return
        navIndex = (navIndex + delta + navItems.size) % navItems.size
        paintTabs()
        val item = navItems[navIndex]
        infoLine.text = if (item.count < 0) {
            "OK 进入「${item.label}」（网盘实时目录）"
        } else {
            "OK 切到「${item.label}」" + if (item.count == 0) "（这个分类下没有作品）" else ""
        }
    }

    /** 生效光标所在的导航项。 */
    private fun applyTab() {
        val item = navItems.getOrNull(navIndex) ?: return
        Log.i(TAG, "一级导航：生效「${item.label}」")
        item.onPick()
    }

    /**
     * 三层焦点：导航带 → 状态行 → 海报墙。
     *
     * ⛔ 三个 `focus*` 函数**必须互相清掉对方的标志位**。它们各自驱动一份
     *    「谁在发光」的重绘，漏清一个就会出现「两行同时高亮」（用户完全
     *    不知道按键现在管的是哪一行）。
     *
     * ⛔ 顺序**照屏幕上的物理位置**：分类栏在最上、状态行在它下面、海报墙
     *    在最下。所以 ↓ 是「往下走一层」、↑ 是「往上走一层」，与直觉一致。
     */
    private fun focusTabs() {
        barFocused = false
        tabsFocused = true
        paintTabs()
        paintBar()
        tabsBox.requestFocus()
        infoLine.text = "←→ 选分类 · OK 生效 · ↓ 到状态行"
    }

    /** 状态行（排序 / 筛选 / 只看有海报 / 清空）。 */
    private fun focusBar() {
        tabsFocused = false
        barFocused = true
        paintTabs()
        paintBar()
        filterBox.requestFocus()
        infoLine.text = barItems.getOrNull(barIndex)?.hint ?: "←→ 选控件 · OK 生效"
    }

    private fun focusGrid() {
        tabsFocused = false
        barFocused = false
        paintTabs()
        paintBar()
        worksGrid.requestFocus()
        showInfo(works.getOrNull(worksGrid.selectedItemPosition))
    }

    // ------------------------------------------------------------------
    // 点播
    // ------------------------------------------------------------------

    /**
     * 点作品卡片 —— **直接播放**（VidHub / Infuse 的标准行为）。
     *
     * ⛔ 播哪一条由 [PlayTarget] 决定：**先续播点、再看过的最后一条、最后才
     *    第一条**。用户点海报的意图是看片，不是先看一页列表 —— 剧集列表
     *    改由 MENU →「剧集列表」进入。
     * ⛔ 取条目要在**后台**读（`itemsForWork` 是查库，剧集一部能有两百条）。
     */
    private fun onWorkRow(position: Int) {
        works.getOrNull(position)?.let { playWork(it) }
    }

    private fun playWork(w: Work) {
        status.text = "准备播放「${w.title}」…"
        Bg.run({ db.itemsForWork(w.key) }) { list, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                Log.e(TAG, "取播放目标失败：${w.key}", err)
                return@run
            }
            val target = PlayTarget.resolve(list ?: emptyList())
            if (target == null) {
                status.text = "「${w.title}」下没有可播放的文件"
                return@run
            }
            Log.i(
                TAG,
                "点卡片直接播：${w.title} → ${target.name}" +
                    "（续播 ${target.resumePositionMs ?: 0}ms · 最近播 ${target.lastPlayedAt ?: 0}）",
            )
            status.text = "播放「${target.displayTitle}」"
            play(target)
        }
    }

    private fun onItemRow(position: Int) {
        items.getOrNull(position)?.let { play(it) }
    }

    /**
     * 交给 [PlayerActivity] 起播。
     *
     * ⛔ `EXTRA_PDIR` 必须给：播放页靠它扫**同目录**的外挂字幕。库里的
     *    `dir_id` 就是电脑扫描时记下的父目录 fid —— 单个文件的 fid
     *    **推不出**父目录，网盘也没有「查父目录」的接口。
     */
    private fun play(item: LibraryItem) {
        startActivity(
            Intent(this, PlayerActivity::class.java)
                .putExtra(PlayerActivity.EXTRA_FID, item.fileId)
                .putExtra(PlayerActivity.EXTRA_NAME, item.name)
                .putExtra(PlayerActivity.EXTRA_HEADERS, store.requestCookie())
                .putExtra(PlayerActivity.EXTRA_PDIR, item.dirId)
                // ⛔ 「选集」的唯一入口：播放页靠它查出同一作品下的其它文件。
                //    没有它 → 播放中换不了集（网盘没有「查兄弟文件」的接口，
                //    靠文件名猜同作品必错）。详见 `PlayerActivity.EXTRA_GROUP_KEY`。
                .putExtra(PlayerActivity.EXTRA_GROUP_KEY, item.groupKey)
                // ⛔ 续播点：在这里取、在这里传。「最近播放的那一集」由
                //    `PlayTarget.resolve` 早已挑好，它的续播点就是这条 extra；
                //    播放页只管照着跳，不再自己查一次库。
                .putExtra(PlayerActivity.EXTRA_RESUME_MS, item.resumePositionMs ?: 0L),
        )
    }

    // ------------------------------------------------------------------
    // 覆盖层
    // ------------------------------------------------------------------

    private fun showOverlay(titleText: String, labels: List<String>, onPick: (Int) -> Unit) {
        overlayTitle.text = titleText
        overlayLabels = labels
        overlayOnPick = onPick
        overlayIndex = 0
        overlayRowsBox.removeAllViews()
        for (label in labels) {
            overlayRowsBox.addView(
                MenuRow.create(this, label),
                LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(2) },
            )
        }
        paintOverlaySelection()
        overlayScrim.visibility = View.VISIBLE
        overlayVisible = true
        clampOverlayHeight()
    }

    /**
     * 把菜单卡片的可滚区域夹到屏幕内。
     *
     * ⛔ 要在 `post` 里做：`overlayRowsBox.height` 只有测量完才有值，而
     *    `showOverlay` 这一帧刚 `addView` 完，还没测量。在 `post` 里量到的
     *    是真实高度 —— 也就不需要在代码里硬编码「一行多少 dp」。
     */
    private fun clampOverlayHeight() {
        overlayScroll.post {
            val cap = resources.displayMetrics.heightPixels - dp(OVERLAY_TOP_BOTTOM_DP)
            val used = overlayTitle.height + overlay.paddingTop + overlay.paddingBottom
            val h = minOf(overlayRowsBox.height, (cap - used).coerceAtLeast(dp(120)))
            val lp = overlayScroll.layoutParams
            if (lp.height != h) {
                lp.height = h
                overlayScroll.layoutParams = lp
            }
        }
    }

    /** 把光标所在那一行滚进可视区。滚动条自己不会滚（它不可聚焦）。 */
    private fun revealOverlayRow() {
        val row = overlayRowsBox.getChildAt(overlayIndex) ?: return
        overlayScroll.post {
            val top = row.top
            val bottom = top + row.height
            when {
                top < overlayScroll.scrollY -> overlayScroll.scrollTo(0, top)
                bottom > overlayScroll.scrollY + overlayScroll.height ->
                    overlayScroll.scrollTo(0, bottom - overlayScroll.height)
            }
        }
    }

    private fun paintOverlaySelection() {
        for (i in 0 until overlayRowsBox.childCount) {
            MenuRow.paint(overlayRowsBox.getChildAt(i), i == overlayIndex)
        }
        revealOverlayRow()
    }

    private fun hideOverlay() {
        overlayScrim.visibility = View.GONE
        overlayVisible = false
        overlayOnPick = null
        overlayLabels = emptyList()
        restoreFocus()
    }

    /**
     * 覆盖层 / 面板关掉之后，焦点还给**打开它的那一层**。
     *
     * ⛔ 不能无条件还给海报墙：从状态行点开「排序」、选完关掉，焦点应该还在
     *    状态行上（用户接着可能还要改筛选）；弹回海报墙的话，每改一次设置都
     *    要重新按一遍方向键才能回到刚才那一行。
     */
    private fun restoreFocus() {
        when {
            barFocused -> filterBox.requestFocus()
            tabsFocused -> tabsBox.requestFocus()
            level == Level.ITEMS -> itemsList.requestFocus()
            else -> worksGrid.requestFocus()
        }
    }

    // ------------------------------------------------------------------
    // 筛选面板（年份 / 类型 / 刮削）
    // ------------------------------------------------------------------

    /**
     * 筛选面板的一行。
     *
     * ⛔ 面板是**一维列表**（不是「组内 Wrap 多列」的二维网格）。
     *    电视遥控器只有上下左右，二维网格要自己维护「行内列号 + 换行时落到
     *    哪一列」这套状态，而年份有三四十项、类型十几项，折行位置还会随
     *    数量变化 —— 那是电视 UI 里最容易出「按右键跳得莫名其妙」的地方。
     *    一维列表 + 滚动条反而更快找到东西。
     */
    private sealed interface FRow {
        /** 分组标题。**不可选中**（↑↓ 会跳过它）。 */
        class Section(val title: String) : FRow

        /** 可切换的筛选项（年份 / 类型 / 刮削开关）。 */
        class Toggle(
            val label: String,
            val count: Int?,
            val selected: Boolean,
            /** 已选中、但**当前范围里一条都没有**（`无结果`）。 */
            val stale: Boolean,
            val onTap: () -> Unit,
        ) : FRow

        /** 底部动作（清空筛选 / 关闭）。 */
        class Action(val label: String, val enabled: Boolean, val onTap: () -> Unit) : FRow
    }

    private var filterRows: List<FRow> = emptyList()
    private var filterIndex = 0
    private var filterVisible = false
    private lateinit var filterScrim: FrameLayout
    private lateinit var filterScroll: android.widget.ScrollView
    private lateinit var filterRowsBox: LinearLayout

    private fun buildFilter(): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0xCC000000.toInt())
            isClickable = true
            visibility = View.GONE
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // 与菜单卡片同一套：**不描边**，靠比背景亮一档的实心面 + 大圆角分层。
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(0xFF1E232C.toInt())
            }
        }
        card.addView(TextView(this).apply {
            text = "筛选与排序"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(30), dp(22), dp(26), dp(12))
        })
        filterRowsBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(26), 0, dp(26), dp(18))
        }
        filterScroll = android.widget.ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            addView(filterRowsBox, ViewGroup.LayoutParams(MATCH, WRAP))
        }
        card.addView(filterScroll, LinearLayout.LayoutParams(MATCH, 0, 1f))
        // ⛔ 高度按**屏幕**算，不写死 dp：电视的 density 从 1.0 到 2.0 都有，
        //    写死 600dp 在高密度屏上会直接顶出屏幕。
        val h = (resources.displayMetrics.heightPixels * 0.84).toInt()
        scrim.addView(
            card,
            FrameLayout.LayoutParams(dp(660), h).apply { gravity = Gravity.CENTER },
        )
        filterScrim = scrim
        return scrim
    }

    private fun openFilter() {
        filterRows = buildFilterRows()
        filterIndex = 0
        while (filterIndex < filterRows.size && filterRows[filterIndex] is FRow.Section) filterIndex++
        paintFilter()
        filterScrim.visibility = View.VISIBLE
        filterVisible = true
    }

    private fun hideFilter() {
        filterScrim.visibility = View.GONE
        filterVisible = false
        restoreFocus()
    }

    /**
     * 组装面板的行。
     *
     * ## 这里是**唯一的条件中心**
     *
     * 面板要能覆盖 PC 端 `LibraryFilter` 的**每一个维度**：
     * `category` / `playedOnly` / `sort` / `scrapedOnly` / `years` / `genres`
     * （`query` 是自由文本，在状态行的「搜索」里）。
     * 少一维的后果不是「少个功能」，而是**用户在这里找不到那个条件，就以为
     * 它不存在** —— 而列表正被它筛着（角标对不上时最难查）。
     *
     * ⛔ 分类 / 排序 / 只看有海报**共用页面级状态**（`category` / `playedOnly`
     *    / `sort` / `posterOnly`），不另存一份：两处各存一份的话，从面板改了
     *    分类，导航带上的高亮不会跟着动，用户看到的是两个互相矛盾的界面。
     *
     * ⛔ **「已选但当前范围里没有」的项也要画出来**（[FRow.Toggle.stale]）。
     *    选项是按当前分类收窄的，而选中的条件**不会**跟着切分类被清掉：
     *    用户在「电影」里选了 1995，切到「动漫」—— 动漫里一部 1995 的都没有，
     *    这一项就不在计数里了。只画计数里有的项，那颗 chip 会**整个消失**，
     *    而它仍然生效（列表为空正因为它）⇒ 用户看到「已选 2 项」却找不到
     *    第二个条件在哪，唯一的出路是「清空筛选」，把想留的也一起抹掉。
     */
    private fun buildFilterRows(): List<FRow> {
        val rows = ArrayList<FRow>(96)

        // ── 分类（含「最近播放」这个视图）──
        rows.add(FRow.Section("分类"))
        rows.add(FRow.Toggle("全部", null, category == null && !playedOnly, false) {
            category = null
            playedOnly = false
        })
        rows.add(FRow.Toggle("最近播放", playedCount, playedOnly, false) {
            category = null
            playedOnly = true
        })
        for (c in MediaCategoryNames.displayOrder) {
            rows.add(
                FRow.Toggle(
                    MediaCategoryNames.label(c),
                    counts[c] ?: 0,
                    category == c && !playedOnly,
                    false,
                ) {
                    category = c
                    playedOnly = false
                },
            )
        }

        // ── 排序（六档，与 PC 端 `WorkSort` 同序）──
        rows.add(FRow.Section("排序"))
        for (s in LibraryDb.Sort.entries) {
            rows.add(FRow.Toggle(s.label, null, s == sort, false) { sort = s })
        }

        // ── 显示 ──
        rows.add(FRow.Section("显示"))
        rows.add(FRow.Toggle("只看有海报", null, posterOnly, false) { posterOnly = !posterOnly })

        // ── 刮削 ──
        rows.add(FRow.Section("刮削"))
        // 只有一颗、也**不给数量角标**：年份/类型那些数字的承诺是「点下去至少
        // 有这么条结果」，而这是个开关 —— 多印一个数字只会让人以为它也能多选。
        rows.add(FRow.Toggle("已刮削", null, scrapedOnly, false) { scrapedOnly = !scrapedOnly })

        // ── 年份 ──
        rows.add(FRow.Section("年份"))
        val yc = yearCounts
        if (yc.isEmpty() && years.isEmpty()) {
            rows.add(FRow.Section("还没有带年份的作品。刮削一次就能拿到上映年份。"))
        }
        for (y in yc.keys.sortedDescending()) {
            rows.add(FRow.Toggle("$y", yc[y], years.contains(y), false) { toggleYear(y) })
        }
        for (y in years.filter { !yc.containsKey(it) }.sortedDescending()) {
            rows.add(FRow.Toggle("$y", null, true, true) { toggleYear(y) })
        }

        // ── 类型 ──
        rows.add(FRow.Section("类型"))
        val gc = genreCounts
        if (gc.isEmpty() && genres.isEmpty()) {
            rows.add(FRow.Section("还没有类型信息。刮削之后类型会出现在这里。"))
        }
        for (g in gc.keys.sortedWith(compareByDescending<String> { gc[it] ?: 0 }.thenBy { it })) {
            rows.add(FRow.Toggle(g, gc[g], genres.contains(g), false) { toggleGenre(g) })
        }
        for (g in genres.filter { !gc.containsKey(it) }.sorted()) {
            rows.add(FRow.Toggle(g, null, true, true) { toggleGenre(g) })
        }

        // ── 底部：先报「已选了几项」，再给两个动作 ──
        // ⛔ 这句状态**必须有**：角标散在六组里，用户勾完几项之后就数不清了，
        //    而列表是不是空的正是由这个总数决定的（PC 端面板底部同款）。
        rows.add(
            FRow.Section(if (selectedFilterCount > 0) "已选 $selectedFilterCount 项" else "未选条件"),
        )
        rows.add(FRow.Action("清空筛选", selectedFilterCount > 0) {
            scrapedOnly = false
            years.clear()
            genres.clear()
        })
        rows.add(FRow.Action("关闭", true) { hideFilter() })
        return rows
    }

    private fun toggleYear(y: Int) {
        if (!years.remove(y)) years.add(y)
    }

    private fun toggleGenre(g: String) {
        if (!genres.remove(g)) genres.add(g)
    }

    private fun paintFilter() {
        filterRowsBox.removeAllViews()
        for ((i, row) in filterRows.withIndex()) {
            filterRowsBox.addView(
                when (row) {
                    is FRow.Section -> filterSectionView(row.title)
                    is FRow.Toggle -> filterToggleView(row, i == filterIndex)
                    is FRow.Action -> filterActionView(row, i == filterIndex)
                },
            )
        }
        // 把光标滚进可视区。`post` 是必须的：刚 addView 完还没有测量过，
        // 此时 `v.top`/`v.bottom` 全是 0，直接算会滚错位置。
        filterRowsBox.getChildAt(filterIndex)?.let { v ->
            filterScroll.post {
                val top = v.top
                val bottom = v.bottom
                val h = filterScroll.height
                when {
                    top < filterScroll.scrollY -> filterScroll.smoothScrollTo(0, top)
                    bottom > filterScroll.scrollY + h ->
                        filterScroll.smoothScrollTo(0, bottom - h + dp(8))
                }
            }
        }
    }

    private fun filterSectionView(title: String): View = TextView(this).apply {
        text = title
        setTextColor(0xFF6B7280.toInt())
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        letterSpacing = 0.06f
        setPadding(dp(2), dp(14), 0, dp(6))
    }

    private fun filterToggleView(row: FRow.Toggle, cursor: Boolean): View = TextView(this).apply {
        val mark = if (row.selected) "✓ " else ""
        val countText = when {
            row.stale -> "  无结果"
            row.count != null && row.count > 0 -> "  ${row.count}"
            else -> ""
        }
        text = "$mark${row.label}$countText"
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        setPadding(dp(16), dp(12), dp(16), dp(12))
        // 实心分层，**不描边**（与导航带 / 菜单同一套视觉语言）。
        background = GradientDrawable().apply {
            cornerRadius = dp(10).toFloat()
            setColor(
                when {
                    cursor -> 0xFF4A4278.toInt()
                    row.selected -> 0xFF332C63.toInt()
                    else -> 0x14FFFFFF
                },
            )
        }
        setTextColor(
            when {
                row.stale -> 0xFF6B7280.toInt()
                cursor -> Color.WHITE
                row.selected -> BRAND_TINT
                else -> 0xFFC9D0DB.toInt()
            },
        )
        layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { bottomMargin = dp(6) }
    }

    private fun filterActionView(row: FRow.Action, cursor: Boolean): View = TextView(this).apply {
        text = row.label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
        gravity = Gravity.CENTER
        setPadding(dp(16), dp(12), dp(16), dp(12))
        background = GradientDrawable().apply {
            cornerRadius = dp(10).toFloat()
            setColor(if (cursor) 0xFF4A4278.toInt() else 0x14FFFFFF)
        }
        setTextColor(
            when {
                !row.enabled -> 0xFF4B5563.toInt()
                cursor -> Color.WHITE
                else -> 0xFFC9D0DB.toInt()
            },
        )
        layoutParams = LinearLayout.LayoutParams(MATCH, WRAP).apply { topMargin = dp(6) }
    }

    /** ↑↓ 移动光标，**跳过分组标题**（它不是选项）。 */
    private fun moveFilter(delta: Int) {
        if (filterRows.isEmpty()) return
        var i = filterIndex
        repeat(filterRows.size) {
            i = (i + delta + filterRows.size) % filterRows.size
            if (filterRows[i] !is FRow.Section) {
                filterIndex = i
                paintFilter()
                return
            }
        }
    }

    private fun confirmFilter() {
        when (val row = filterRows.getOrNull(filterIndex)) {
            is FRow.Toggle -> {
                row.onTap()
                afterFilterChange()
            }
            is FRow.Action -> {
                if (!row.enabled) return
                row.onTap()
                // 「关闭」会把面板收起来 —— 那时不能再重排（会把面板又画出来）。
                if (filterVisible) afterFilterChange()
            }
            else -> Unit
        }
    }

    /** 改完一个条件：重查列表 + 重排面板（角标与「无结果」都会变）。 */
    private fun afterFilterChange() {
        loadWorks()
        val keep = filterIndex
        filterRows = buildFilterRows()
        filterIndex = keep.coerceIn(0, filterRows.size - 1)
        if (filterRows[filterIndex] is FRow.Section) moveFilter(1) else paintFilter()
    }

    /**
     * MENU 菜单。
     *
     * ⛔ 用「`标签 to 动作` 的列表」而不是「`labels` + 一长串 `when(index)`」：
     *    之前那种写法在中间插一项就要重排所有下标，而**下标错了不会编译失败**
     *    —— 表现是「点了 A 执行了 B」，其中一项还是不可逆的「从网盘恢复」。
     */
    private fun openMenu() {
        val actions = ArrayList<Pair<String, () -> Unit>>()

        if (level == Level.ITEMS) {
            val cur = currentWork
            if (cur != null) actions.add("播放「${cur.title}」（续播）" to { playWork(cur) })
            actions.add("同步（本地 ↔ 网盘）" to { doSync() })
            actions.add("上传备份到网盘" to { doUpload() })
            actions.add("从网盘恢复（覆盖本地）" to { confirmRestore() })
            actions.add("返回作品墙" to { backToWorks() })
        } else {
            val cur = works.getOrNull(worksGrid.selectedItemPosition)
            if (cur != null) {
                actions.add("播放「${cur.title}」" to { playWork(cur) })
                actions.add("「${cur.title}」的剧集列表" to { openWork(cur) })
            }
            // ⛔ 排序**不在菜单里循环切**：六档要按五次才能到头，而每按一次都会
            //    重查库 + 重排整个海报墙。走子菜单，一次选完（状态行上的
            //    「排序」是同一个入口）。
            actions.add("排序：${sort.label}" to { openSortMenu() })
            actions.add(
                (if (selectedFilterCount > 0) {
                    "筛选与排序（$selectedFilterCount 项生效）"
                } else {
                    "筛选与排序（分类 / 排序 / 显示 / 刮削 / 年份 / 类型）"
                }) to { openFilter() },
            )
            actions.add(
                (if (posterOnly) "只看有海报：开" else "只看有海报：关") to {
                    posterOnly = !posterOnly
                    loadWorks()
                },
            )
            // ⛔ 「扫描 / 清空」放在**显示设置之后、备份之前**：前四项是「看什么」，
            //    这三项是「库里有什么」，最后三项是「和电脑同步」。按这个顺序
            //    分组，用户扫一眼就知道该往哪找。
            actions.add("重新扫描媒体库（网盘）" to { doScan() })
            actions.add("清空媒体库索引…" to { confirmWipe() })
            actions.add("同步（本地 ↔ 网盘）" to { doSync() })
            actions.add("上传备份到网盘" to { doUpload() })
            actions.add("从网盘恢复（覆盖本地）" to { confirmRestore() })
            actions.add("文件列表（网盘实时目录）" to {
                startActivity(Intent(this, BrowseActivity::class.java))
                finish()
            })
        }

        showOverlay(titleText = "媒体库", labels = actions.map { it.first }) { index ->
            val act = actions.getOrNull(index) ?: return@showOverlay
            hideOverlay()
            act.second()
        }
    }

    private fun confirmRestore() {
        showOverlay(
            titleText = "用网盘上的最新备份覆盖本地媒体库？\n（本机没上传过的改动会丢失）",
            labels = listOf("取消", "确认恢复"),
        ) { index ->
            hideOverlay()
            if (index == 1) doRestore()
        }
    }

    // ------------------------------------------------------------------
    // 备份 / 同步
    // ------------------------------------------------------------------

    /** 三个备份动作共用的前置检查：**只有它们**需要登录态。 */
    private fun requireLogin(): Boolean {
        if (store.loggedIn) return true
        status.text = "需要先登录网盘（返回 → 菜单 → 重新登录）"
        return false
    }

    private fun guard(what: String): Boolean {
        if (busy) {
            status.text = "正在${busyWhat}，请稍候…"
            return false
        }
        if (!requireLogin()) return false
        busy = true
        busyWhat = what
        status.text = "$what…"
        return true
    }

    private fun finishJob(message: String) {
        busy = false
        busyWhat = ""
        status.text = message
    }

    // ------------------------------------------------------------------
    // 扫描 / 清空
    // ------------------------------------------------------------------

    /**
     * 重新扫描媒体库（全盘遍历网盘 → 解析 → 归组 → 入库）。
     *
     * ⛔ **不是「重新刮削」**：它只把文件发现出来、按片名归组，在线元数据
     *    （海报 / 简介 / 评分）要另走刮削。分开的理由见 [LibraryScanner] 的类文档。
     *
     * ⛔ 扫完**必须** `loadWorks()`：集数 / 季数 / 封面兜底 / 年份与类型的分面
     *    角标全都可能变了。不重读的话，用户刚扫完看到的还是旧数字，
     *    只会以为「扫描没生效」。
     */
    private fun doScan() {
        if (!guard("扫描媒体库")) return
        val cancel = LibraryScanner.Cancellation()
        scanCancel = cancel
        status.text = "扫描：准备中…"
        Log.i(TAG, "扫描：开始")
        Bg.run({
            scanner.scan(cancel) { p ->
                // ⛔ 进度回调在**后台线程**上，碰 `status` 必须回主线程。
                // ⛔ 用 `=== cancel` 认「还是我这一次」：用户可能在扫描途中
                //    取消、又立刻发起第二次，晚到的旧回调会把新进度盖掉。
                // ⛔ 已请求取消时**不再刷新进度**：否则刚写上的
                //    「正在停止扫描…」会被下一批进度立刻覆盖回去，
                //    看起来像「按了返回没反应」。
                runOnUiThread {
                    if (scanCancel === cancel && !cancel.isCancelled) status.text = p.text
                }
            }
        }) { out, err ->
            scanCancel = null
            if (err != null) {
                Log.e(TAG, "扫描失败", err)
                finishJob("扫描失败：${err.message}")
                return@run
            }
            val msg = out?.message ?: "扫描完成"
            Log.i(
                TAG,
                "扫描：$msg（目录 ${out?.dirs} / 文件 ${out?.files} / 失败目录 ${out?.failedDirs}）",
            )
            finishJob(msg)
            loadWorks(msg)
        }
    }

    /** 「清空媒体库」的二次确认。 */
    private fun confirmWipe() {
        showOverlay(
            titleText = "清空本机媒体库索引？\n" +
                "只清这台电视上的索引：作品、集数、播放进度、筛选条件都会没。\n" +
                "网盘上的文件和已上传的备份**不受影响**，之后可以重新扫描或从网盘恢复。",
            labels = listOf("取消", "确认清空"),
        ) { index ->
            hideOverlay()
            if (index == 1) doWipe()
        }
    }

    /**
     * 清空本机索引（「重建媒体库」的第一步）。
     *
     * ⛔ **不需要登录**：这是纯本地动作，所以不走 [guard]（那个会先查登录态）。
     *    只借它的 `busy` 防重入。
     *
     * ⛔ **不删海报文件**：`wipeIndex()` 只清 4 张表（媒体项 / 作品 / 字幕引用 /
     *    续扫游标），海报目录原封不动 —— 重扫之后同名作品的封面会**直接回来**
     *    （海报文件名是从作品键算出来的，见 `PosterNaming`），不用重刮一遍。
     *
     * ⛔ 清完要**顺手把筛选条件复位**：库里已经一条都没有了，还留着
     *    「只看 2024 · 动画」的话，用户看到的是「这个分类下没有作品」——
     *    他会以为清空失败了。
     */
    private fun doWipe() {
        if (busy) {
            status.text = "正在${busyWhat}，请稍候…"
            return
        }
        busy = true
        busyWhat = "清空媒体库"
        status.text = "正在清空媒体库…"
        Bg.run({ db.wipeIndex() }) { _, err ->
            if (err != null) {
                Log.e(TAG, "清空媒体库失败", err)
                finishJob("清空失败：${err.message}")
                return@run
            }
            category = null
            playedOnly = false
            scrapedOnly = false
            years.clear()
            genres.clear()
            Log.i(TAG, "媒体库已清空")
            finishJob("媒体库已清空（网盘文件未动）")
            loadWorks("媒体库已清空 —— 菜单 → 重新扫描媒体库")
        }
    }

    private fun doSync() {
        if (!guard("同步")) return        Bg.run({
            service.sync(onProgress = { sent, total ->
                runOnUiThread { status.text = "同步：上传 $sent/$total" }
            })
        }) { out, err ->
            if (err != null) {
                Log.e(TAG, "同步失败", err)
                finishJob("同步失败：${err.message}")
                return@run
            }
            // ⛔ 无论上传还是恢复，都要重读列表：恢复会换掉整个库，
            //    上传虽然不动本地，但「最近修改」的时间戳变了、排序会变。
            finishJob(out?.message ?: "同步完成")
            loadWorks()
        }
    }

    private fun doUpload() {
        if (!guard("打包并上传")) return
        Bg.run({
            val bytes = service.exportBackup(includePosters = true, includeSettings = true)
            service.uploadBackup(bytes, onProgress = { sent, total ->
                runOnUiThread { status.text = "上传 $sent/$total 字节" }
            })
        }) { fid, err ->
            if (err != null) {
                Log.e(TAG, "上传备份失败", err)
                finishJob("上传失败：${err.message}")
                return@run
            }
            finishJob("已上传到网盘备份目录（fid=$fid）")
        }
    }

    private fun doRestore() {
        if (!guard("从网盘恢复")) return
        Bg.run({ service.restoreLatest() }) { latest, err ->
            if (err != null) {
                Log.e(TAG, "从网盘恢复失败", err)
                finishJob("恢复失败：${err.message}")
                return@run
            }
            if (latest == null) {
                finishJob("网盘备份目录里还没有任何备份")
                return@run
            }
            finishJob("已恢复「${latest.name}」（${formatSize(latest.sizeBytes)}）")
            loadWorks()
        }
    }

    // ------------------------------------------------------------------
    // 按键
    // ------------------------------------------------------------------

    /**
     * 按键分派 —— **全部自己处理，不依赖框架的焦点搜索**。
     *
     * ## ⛔ 为什么 OK 也要自己处理（不用 `OnItemClickListener`）
     *
     * `AbsListView` 的按键点击路径要穿过 `mSelectedPosition`、触摸模式、
     * `mTouchMode` 等一串内部状态，实测在这台电视上**按 OK 什么都不发生**
     * （`input keyevent 23` 之后既没有新 Activity、也没有任何日志）。
     * 这类「看起来接好了、其实没触发」的问题最难查 —— 而自己处理之后
     * 行为完全确定，代价只有十几行。
     *
     * ⛔ **DOWN 与 UP 都要吞掉**：只吞 DOWN 的话，UP 会继续走到
     *    `AbsListView.onKeyUp` 再触发一次 `performItemClick` ⇒ 一次按键播两遍。
     * ⛔ `OnItemClickListener` 仍然保留 —— 它管的是**触摸**（鼠标点、触屏），
     *    那条路径不经过 `dispatchKeyEvent`，两者互补。
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val down = event.action == KeyEvent.ACTION_DOWN

        // ⛔ 扫描进行中，返回键 = **停下扫描**，不是退出页面。
        //    扫描要跑几分钟，而 `guard` 已经把其它动作全挡住了 —— 没有这个
        //    出口，用户唯一的办法是杀应用（下次进来库还是半截的）。
        // ⛔ 只吞返回键：方向键照常放行，扫描期间还能翻墙看已有内容。
        scanCancel?.let { cancel ->
            if (down && event.keyCode == KeyEvent.KEYCODE_BACK) {
                cancel.cancel()
                status.text = "正在停止扫描…（已扫到的会保留）"
                return true
            }
        }

        // ⛔ 筛选面板排在菜单前面：它是**更靠上的**一层（从菜单里打开的），
        //    两层同时为真的可能性只有「打开筛选时菜单还没收干净」，
        //    此时应该听筛选面板的。
        if (filterVisible) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_DOWN -> if (down) moveFilter(1)
                KeyEvent.KEYCODE_DPAD_UP -> if (down) moveFilter(-1)
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> if (down) confirmFilter()
                // ⛔ 返回 / MENU 都是「关掉面板」，不是「执行当前项」。
                KeyEvent.KEYCODE_BACK,
                KeyEvent.KEYCODE_MENU,
                -> if (down) hideFilter()
                else -> return super.dispatchKeyEvent(event)
            }
            return true
        }

        if (overlayVisible) {
            if (!down) return true
            if (overlayLabels.isEmpty()) {
                hideOverlay()
                return true
            }
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    overlayIndex = (overlayIndex + 1) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_UP -> {
                    overlayIndex = (overlayIndex + overlayLabels.size - 1) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> {
                    // ⛔ 先取出来再回调：回调里 `hideOverlay()` 会把
                    //    `overlayOnPick` 置空，直接调用会空指针。
                    val pick = overlayOnPick
                    pick?.invoke(overlayIndex)
                    return true
                }
                // ⛔ 返回 / MENU 都是「关掉菜单」，不是「执行当前项」。
                //    菜单里有一项是不可逆的（从网盘恢复），手滑代价太大。
                KeyEvent.KEYCODE_BACK,
                KeyEvent.KEYCODE_MENU,
                -> {
                    hideOverlay()
                    return true
                }
            }
            return true // 菜单开着时吞掉其它按键，别让底下的墙跟着动
        }

        // ── 状态行拿到焦点：←→ 移光标、OK 执行、↑ 回分类栏、↓ 回海报墙 ──
        if (barFocused) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> if (down) moveBar(-1)
                KeyEvent.KEYCODE_DPAD_RIGHT -> if (down) moveBar(1)
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> if (down) applyBar()
                KeyEvent.KEYCODE_DPAD_UP -> if (down) focusTabs()
                KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_BACK,
                -> if (down) focusGrid()
                KeyEvent.KEYCODE_MENU -> if (down) openMenu()
                // ⛔ 不认识的键放行（音量、电源、HDMI…），别把遥控器全吞了。
                else -> return super.dispatchKeyEvent(event)
            }
            return true
        }

        // ── 一级导航拿到焦点：←→ 移光标、OK 生效、↓/返回 到状态行 ──
        if (tabsFocused) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> if (down) moveTab(-1)
                KeyEvent.KEYCODE_DPAD_RIGHT -> if (down) moveTab(1)
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> if (down) applyTab()
                KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_BACK,
                -> if (down) focusBar()
                KeyEvent.KEYCODE_MENU -> if (down) openMenu()
                // ⛔ 不认识的键放行（音量、电源、HDMI…），别把遥控器全吞了。
                else -> return super.dispatchKeyEvent(event)
            }
            return true
        }

        // ── 海报墙 / 剧集列表 ──
        when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER,
            KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_NUMPAD_ENTER,
            -> {
                if (down) onConfirm()
                return true
            }
            // ⛔ 只在**第一行**才把 ↑ 交给上面一行：否则「往上翻一行」会变成
            //    「跳去改排序」，遥控器上极其难用。
            // ⛔ 状态行在剧集列表（`Level.ITEMS`）下是**隐藏的**，那时不能把
            //    焦点交出去 —— 交给一个 `GONE` 的视图等于焦点凭空消失。
            KeyEvent.KEYCODE_DPAD_UP -> {
                if (down && level == Level.WORKS &&
                    worksGrid.selectedItemPosition < worksGrid.numColumns
                ) {
                    focusBar()
                    return true
                }
            }
            KeyEvent.KEYCODE_MENU -> {
                if (down) openMenu()
                return true
            }
            KeyEvent.KEYCODE_BACK -> if (down && level == Level.ITEMS) {
                backToWorks()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /** OK：作品墙 → **直接播**；剧集列表 → 播选中的那一集。 */
    private fun onConfirm() {
        when (level) {
            // `selectedItemPosition` 可能是 `INVALID_POSITION`(-1)，
            // `getOrNull` 会吃掉它（→ 什么都不做），不要改成 `[]`。
            Level.WORKS -> onWorkRow(worksGrid.selectedItemPosition)
            Level.ITEMS -> onItemRow(itemsList.selectedItemPosition)
        }
    }

    // ------------------------------------------------------------------
    // 海报墙渲染
    // ------------------------------------------------------------------

    /**
     * 卡片：海报 + 续播进度条 + 片名 + 副标题。
     *
     * ## ⛔ 为什么复用 `convertView` 时要按**下标**取子控件
     *
     * `GridView` 的回收视图就是同一个 `LinearLayout`，子控件顺序在
     * [buildCard] 里定死。用 `getChildAt(0..n)` 取比自己找 `tag` 快，
     * 也避免了「忘了设 tag」这种只在滚动到第 N 屏才暴露的 bug。
     */
    private inner class WorksAdapter : BaseAdapter() {
        override fun getCount() = works.size
        override fun getItem(position: Int) = position.toLong()
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val card = (convertView as? LinearLayout) ?: buildCard()
            val w = works[position]

            val posterBox = card.getChildAt(0) as FrameLayout
            val image = posterBox.getChildAt(0) as ImageView
            val placeholder = posterBox.getChildAt(1) as TextView
            val badge = posterBox.getChildAt(2) as TextView
            val strip = card.getChildAt(1) as LinearLayout
            val titleView = card.getChildAt(2) as TextView
            val metaView = card.getChildAt(3) as TextView

            // 海报高度按卡片宽度的 2:3 算 —— 每张卡片都重新设一次，
            // 因为 `cardW` 可能在旋转/换屏后变过。
            val posterH = cardW * 3 / 2
            posterBox.layoutParams = LinearLayout.LayoutParams(cardW, posterH)

            val file = posters.fileFor(w)
            val bmp = file?.let { posters.cached(it) }
            if (bmp != null) {
                image.setImageBitmap(bmp)
                image.visibility = View.VISIBLE
                placeholder.visibility = View.GONE
            } else {
                image.setImageDrawable(null)
                image.visibility = View.INVISIBLE
                // 没海报时给一个「首字」占位块 —— 一片灰比一个字更让人以为坏了。
                placeholder.text = w.title.take(1)
                placeholder.visibility = View.VISIBLE
                if (file != null) {
                    // ⛔ 解码绝不能在主线程做（`getView` 就在主线程上）。
                    Bg.run({ posters.decode(file, cardW) }) { bitmap, err ->
                        if (bitmap == null || err != null) return@run
                        posters.put(file, bitmap)
                        worksAdapter.notifyDataSetChanged()
                    }
                }
            }

            // 评分角标：只在真有评分时出现（0 分是「没刮到」，不是「0 分」）。
            val rating = w.rating ?: 0.0
            if (rating > 0) {
                badge.text = "★ %.1f".format(rating)
                badge.visibility = View.VISIBLE
            } else {
                badge.visibility = View.GONE
            }

            // 续播进度条：看了一半的片子才画。
            paintProgress(strip, w.resumeFraction)

            titleView.text = w.title
            metaView.text = w.subtitle

            // ── 焦点效果：**只用明度与大小，不画边框** ──────────────────
            //
            // ⛔ 之前选中态是「2dp 亮紫描边 + 紫色底」，用户看到的第一反应是
            //    「海报焦点时还是有边框样式，太丑了」。原因是**海报本身已经是
            //    一张完整的图**：再套一圈亮线，看起来像「图片被塞进了一个表格
            //    单元格」，而不是「这一张被选中了」。
            //
            // ⛔ 现在的做法（Apple TV / VidHub 同款，也是 PC 端海报墙的口径）：
            //    **没被选中的整片压暗**，选中的那张保持原亮度 + 放大 7%。
            //    对比度来自「谁更亮」，而不是「谁有框」—— 沙发距离下反而更醒目，
            //    而且不会在任何一张海报上加东西。
            //
            // ⛔ `card.background = null` **不能省**：`convertView` 是复用的，
            //    不显式清掉的话，上一轮那圈的背景会留在这张卡上（表现为
            //    「滚一下屏幕，选中框跑到别的海报上去了」）。
            val gridFocused = worksGrid.isFocused
            val selected = gridFocused && worksGrid.selectedItemPosition == position
            image.alpha = if (gridFocused && !selected) 0.58f else 1f
            placeholder.alpha = image.alpha
            // 评分角标跟着一起暗 —— 否则一排暗海报上浮着一堆亮角标，反而更乱。
            badge.alpha = image.alpha
            card.scaleX = if (selected) 1.07f else 1f
            card.scaleY = if (selected) 1.07f else 1f
            card.background = null
            titleView.setTextColor(if (selected) BRAND_TINT else Color.WHITE)
            metaView.setTextColor(if (selected) 0xFFB9B2FF.toInt() else MUTED)
            return card
        }
    }

    private fun buildCard(): LinearLayout {
        val card = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        val posterBox = FrameLayout(this)
        val image = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setBackgroundColor(0xFF232833.toInt())
        }
        posterBox.addView(image, FrameLayout.LayoutParams(MATCH, MATCH))
        posterBox.addView(
            TextView(this).apply {
                setTextColor(0xFF4B5563.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f)
                gravity = Gravity.CENTER
                setBackgroundColor(0xFF232833.toInt())
            },
            FrameLayout.LayoutParams(MATCH, MATCH),
        )
        posterBox.addView(
            TextView(this).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setPadding(dp(6), dp(3), dp(6), dp(3))
                background = GradientDrawable().apply {
                    cornerRadius = dp(10).toFloat()
                    setColor(0xCC000000.toInt())
                }
            },
            FrameLayout.LayoutParams(WRAP, WRAP).apply {
                gravity = Gravity.TOP or Gravity.END
                topMargin = dp(6)
                rightMargin = dp(6)
            },
        )
        card.addView(posterBox)

        // 进度条：外框是轨道，里面两个加权块（已看 / 剩余）。
        val strip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(0xFF2A303C.toInt())
        }
        strip.addView(View(this), LinearLayout.LayoutParams(0, MATCH, 0f))
        strip.addView(View(this), LinearLayout.LayoutParams(0, MATCH, 1f))
        card.addView(strip, LinearLayout.LayoutParams(MATCH, dp(3)))

        card.addView(TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(0, dp(6), 0, 0)
        })
        card.addView(TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        return card
    }

    /** 进度条：`fraction` ∈ [0,1]，0 或未知时整条藏起来。 */
    private fun paintProgress(strip: LinearLayout, fraction: Double?) {
        if (fraction == null || fraction <= 0.0) {
            strip.visibility = View.GONE
            return
        }
        strip.visibility = View.VISIBLE
        val f = fraction.coerceIn(0.0, 1.0)
        val done = strip.getChildAt(0)
        val rest = strip.getChildAt(1)
        (done.layoutParams as LinearLayout.LayoutParams).weight = f.toFloat()
        (rest.layoutParams as LinearLayout.LayoutParams).weight = (1.0 - f).toFloat()
        done.setBackgroundColor(BRAND_TINT)
        done.requestLayout()
        rest.requestLayout()
    }

    // ⛔ 这里曾经有个 `cardBackground(selected)`：选中 = 紫底 + 2dp 亮紫描边。
    //    已删除 —— 海报卡片的焦点效果改成**纯明度 + 缩放**（见 `WorksAdapter.getView`），
    //    用户明确说过「海报焦点时还是有边框样式，太丑了」。
    //    剧集列表行仍然用 `BRAND_SELECT`（那里是文字行，底色是它唯一的选中线索）。

    // ------------------------------------------------------------------
    // 剧集列表渲染
    // ------------------------------------------------------------------

    private inner class ItemsAdapter : BaseAdapter() {
        override fun getCount() = items.size
        override fun getItem(position: Int) = position.toLong()
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val row = (convertView as? LinearLayout) ?: LinearLayout(this@LibraryActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(GRID_PAD_DP), dp(12), dp(GRID_PAD_DP), dp(12))
            }
            val column = row.getChildAt(0) as LinearLayout
            val line1 = column.getChildAt(0) as TextView
            val line2 = column.getChildAt(1) as TextView
            val tag = row.getChildAt(1) as TextView

            // ⛔ 别把这个局部变量叫 `it`：下面 `?.let { … }` 的隐式参数也叫 `it`，
            //    两层同名会让「这行用的是哪个」纯靠规则推断，读代码时极易看错。
            val entry = items[position]
            tag.text = entry.episodeTag ?: ""
            tag.visibility = if (entry.episodeTag == null) View.GONE else View.VISIBLE
            line1.text = entry.displayTitle
            line2.text = buildString {
                entry.resolution?.takeIf { it.isNotEmpty() }?.let { append("$it · ") }
                append(formatSize(entry.sizeBytes ?: 0L))
                val resume = entry.resumePositionMs
                if (resume != null && resume > 0) append(" · 看到 ${clock(resume)}")
            }

            row.setBackgroundColor(
                if (itemsList.isFocused && itemsList.selectedItemPosition == position) {
                    BRAND_SELECT
                } else {
                    Color.TRANSPARENT
                },
            )
            return row
        }
    }

    // ------------------------------------------------------------------

    /** `1:23:45` / `12:34` —— 续播位置用，比「1234567 毫秒」有用。 */
    private fun clock(ms: Long): String {
        val total = ms / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun matchParent() = FrameLayout.LayoutParams(MATCH, MATCH)

    private companion object {
        const val TAG = "CloudCine"

        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        const val BG = 0xFF101216.toInt()
        const val MUTED = 0xFF9AA3B2.toInt()

        /** 品牌主色 `#7F77DD` 在深底上的可读版本。 */
        const val BRAND_TINT = 0xFFA9A3F5.toInt()

        /** 选中底色：品牌色的深色调，既要能看出选中、又不能刺眼。 */
        const val BRAND_SELECT = 0xFF332C63.toInt()

        /** 海报墙左右留白。 */
        const val GRID_PAD_DP = 32

        /** 卡片间距。 */
        const val GRID_GAP_DP = 12

        /** 目标卡宽（dp）—— 实际列数由屏幕像素宽度反算，见 `computeGrid`。 */
        const val TARGET_CARD_DP = 132

        /**
         * 海报缩略图缓存上限。
         *
         * ⛔ 必须封顶：一屏十几张 2:3 的图，RGB_565 下每张约 250 KB，
         *    没有上限的话「从头滚到尾」等于把整个海报墙留在堆里。
         */
        const val POSTER_CACHE_BYTES = 12 * 1024 * 1024

        /**
         * 覆盖层菜单上下留的呼吸位（dp，上下各一半）。
         *
         * ⛔ 不能贴边：电视有 overscan，最外面一圈在部分机器上根本看不到。
         */
        const val OVERLAY_TOP_BOTTOM_DP = 72
    }
}
