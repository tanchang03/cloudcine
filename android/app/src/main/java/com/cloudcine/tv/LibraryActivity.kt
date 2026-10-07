package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.BitmapShader
import android.graphics.Shader
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
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
import com.cloudcine.tv.library.AutoScraper
import com.cloudcine.tv.library.CloudCoverFetcher
import com.cloudcine.tv.library.DeviceIdentity
import com.cloudcine.tv.library.EpisodeLabels
import com.cloudcine.tv.library.FollowAutoCheck
import com.cloudcine.tv.library.FollowUpdater
import com.cloudcine.tv.library.LibraryBackupService
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryItem
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.LibrarySettings
import com.cloudcine.tv.library.ItemSortMode
import com.cloudcine.tv.library.LibraryScanner
import com.cloudcine.tv.library.MediaCategoryNames
import com.cloudcine.tv.library.PlayTarget
import com.cloudcine.tv.library.sortItems
import com.cloudcine.tv.library.PosterFetcher
import com.cloudcine.tv.library.PosterStore
import com.cloudcine.tv.library.ScrapeHttp
import com.cloudcine.tv.library.ScraperPipeline
import com.cloudcine.tv.library.StartupSync
import com.cloudcine.tv.library.SyncDecision
import com.cloudcine.tv.library.Work
import com.cloudcine.tv.library.WorkDetailFormat
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.formatSize
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

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
 * `作品墙` → `作品简介页（海报 + 简介 + 动作胶囊 + 剧集列表）` → [PlayerActivity]。
 * 返回键退一层。MENU 键开覆盖层菜单（排序 / 筛选 / 同步 / 备份）。
 *
 * ⛔ 2026-10-07 起 **OK 点卡片是「进简介页」，不是「直接播放」**（用户需求）。
 *    直接播等于替用户做了三个决定 —— 播哪一条（`PlayTarget`）、播哪一版、
 *    要不要先刮削；而用户点卡片时想做的经常是「看看这部是什么」「换一集」
 *    「刮一下海报」。简介页把这三件事都摆成胶囊，播放只是其中最显眼的一颗。
 *
 * ## 启动时会问一句「网盘上有更新的备份，要不要同步」
 *
 * 见 [probeRemoteBackupAtStartup]。**只读探测 + 只在「远程赢」时弹**，
 * 一个进程一次 —— 同步这个能力如果只藏在菜单里，等于不存在：用户不会想到
 * 去点它，于是电视上永远显示上周那份索引。
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
 * ↑↓←→ 选择 · OK 进简介页 · ↑ 到状态行 · 菜单 更多   ← hintBar
 * ```
 *
 * 进作品之后（`Level.ITEMS`）上半部分换成简介页：
 *
 * ```
 * [logo] 媒体库 / 片名                       剧集 · 12 个文件
 * ┌────┐  片名                                  ← 简介页头部（detailHead）
 * │海报│  原名 / Original Title
 * │96× │  2024 · 2 季 · 12 集 · 剧集 · ★ 8.7 · 已刮削 · 剧情/犯罪
 * └────┘  简介正文（最多三行，超出省略）
 * [▶ 续播] [手动刮削] [刮削设置] [选集（12）]      ← 动作胶囊（actionsScroll）
 * [修改时间倒序] [剧集顺序] [标题]                ← 排序胶囊（itemsSortScroll）
 * 第 1 集 …                                    ← 剧集列表（ListView）
 * 第 2 集 …
 * ←→ 换胶囊 · OK 播放 / 执行 · ↑↓ 换层 · 菜单 更多  ← hintBar
 * ```
 *
 * ## 按键：分类标签**自己管**，海报墙交给框架
 *
 * 海报墙用 `GridView`（和文件列表同一个理由：**天生支持 D-pad**，上下左右 +
 * OK 都不用写）。但分类标签是**动态加进去的一行 `TextView`**，在电视上让框架
 * 去给它们排焦点是不可靠的（`requestFocus()` 会静默失败）——
 * 所以标签行只做两件事：**自己接管 ←→**（见 [dispatchKeyEvent]），
 * 以及用 `requestFocus()` 让海报墙的选中框消失。
 *
 * ⛔ 简介页上的两行胶囊（动作 / 排序）是同一套做法，而且**焦点一直留在
 *    [itemsList] 上**：胶囊只吃「光标态」，靠 `actionsFocused` /
 *    `itemsSortFocused` 两个标志把方向键分流。焦点一挪到胶囊上，底下列表那行
 *    的高亮就没了，用户会以为列表被清空了。
 */
class LibraryActivity : Activity() {

    // ── 依赖 ────────────────────────────────────────────────────────
    private lateinit var store: CredStore
    private lateinit var api: PanApi
    private lateinit var db: LibraryDb
    private lateinit var service: LibraryBackupService
    private lateinit var posters: PosterStore
    private lateinit var scanner: LibraryScanner

    /**
     * 未刮削作品的**封面兜底** —— 把网盘自带的缩略图拉下来当封面。
     *
     * ⛔ 它与 [posters] 是两件事：`posters` 只**查找 + 解码**（从不下网络），
     *    这个负责把 `poster_url` 拉下来、**落进海报目录**。分开的理由见
     *    [CloudCoverFetcher] 的类文档。
     */
    private lateinit var cloudCovers: CloudCoverFetcher

    /**
     * **追更检查**的执行器（schema v17 的「追剧」）。
     *
     * ⛔ 它复用 [scanner] 的**局部发现**（`discover(recursive = true)`），
     *    **绝不**走 [LibraryScanner.scan] 全盘扫描 —— 后者会写续扫游标、
     *    会拿「本次见到的 id」当白名单跑陈旧清理。只看到一棵子树时拿它当
     *    白名单 = **把库清空**（红线 2）。
     */
    private lateinit var followUpdater: FollowUpdater

    /** 追更检查的取消开关（与 [scanCancel] 同一套「非 null = 正在跑」判据）。 */
    private var followCancel: LibraryScanner.Cancellation? = null

    // ── 扫描 ────────────────────────────────────────────────────────
    //
    // ⛔ 用「非 null 的取消开关」当「正在扫描」的判据，而不是另一个布尔量：
    //    两个变量迟早会有一个忘了同步（比如取消时清了标志、忘了清开关），
    //    表现是「返回键再也停不下扫描」。
    private var scanCancel: LibraryScanner.Cancellation? = null

    /**
     * 自动刮削的取消开关。与 [scanCancel] 同一套判据（非 null = 正在跑）。
     *
     * ⛔ 它**不能**与 [scanCancel] 合并：扫描与刮削是前后两段，扫描一结束
     *    第一段就清空了，而刮削可能还要跑好几分钟 —— 合并的话返回键会在
     *    最需要它的那段时间里失效。
     */
    private var scrapeCancel: LibraryScanner.Cancellation? = null

    /**
     * 已经为哪几部作品发起过网盘封面下载。
     *
     * ⛔ 需要它是因为**失败是记在内存里的**（`CloudCoverFetcher.failed`），
     *    而简介页每次重画都会再问一次 —— 万一文件名算不出来（`poster_url`
     *    里带了首尾空白之类），就会「没有文件 → 再下一次 → 还是没有」地
     *    无限重画。这一层是最后一道闸：**每部作品每个页面实例只试一次**。
     */
    private val cloudCoverTried = HashSet<String>()

    /**
     * 「有网盘封面刚下好，作品墙该重画了」。
     *
     * ⛔ 不能每下好一张就 `notifyDataSetChanged()`：首次进库时未刮削的作品
     *    可能有几百部，逐个重绑整墙等于把海报墙按住不让动。攒成一次。
     */
    private var cloudRefreshQueued = false

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

    // ── 作品简介页（`Level.ITEMS` 的头部）────────────────────────────
    //
    // ⛔ **点卡片先到这一页，不再直接播**（2026-10-07 用户需求：「点击媒体文件
    //    应该先进入简介页面」）。理由：直接播等于替用户做了三个决定 ——
    //    播哪一条（`PlayTarget`）、播哪一版、要不要先刮削。而用户点卡片时想做的
    //    经常是「看看这部是什么」「换一集」「刮一下海报」。
    //
    // 版式**对标 PC 端 `work_detail_page.dart` 的 `_InfoColumn`**：左海报、
    // 右侧「标题 / 原名 / 元数据行 / 简介」，下面一行动作胶囊。
    private lateinit var detailHead: LinearLayout
    private lateinit var detailPoster: ImageView
    private lateinit var detailPosterPlaceholder: TextView
    private lateinit var detailTitle: TextView
    private lateinit var detailOriginal: TextView
    private lateinit var detailMeta: TextView
    private lateinit var detailOverview: TextView

    // 简介页的**动作胶囊行**（播放 / 手动刮削 / 刮削设置 / 选集）。
    //
    // ⛔ 与「剧集排序胶囊」是**两行、两套光标态**（`actionsFocused` /
    //    `itemsSortFocused`），刻意不合并：动作行回答「对这一部作品做什么」，
    //    排序行回答「这一页的列表怎么排」。合成一行的话「播放」会和
    //    「修改时间倒序」并排，用户按 ←→ 路过时完全分不清哪颗是动作。
    private var actionsFocused = false
    private var actionsCursor = 0
    private lateinit var actionsBox: LinearLayout
    private lateinit var actionsScroll: HorizontalScrollView
    private var detailActions: List<DetailAction> = emptyList()

    /** 底部按键提示行。**随层级换文案**（作品墙 / 简介页管的键不一样）。 */
    private lateinit var hintBar: TextView

    /**
     * 简介页上的一颗动作胶囊。
     *
     * ⛔ 带 `enabled` 而不是「不可用时干脆不加进列表」：库里一条可播文件都没有
     *    时，用户最需要看到的恰恰是**一个灰着的「播放」**加上一句解释 ——
     *    按钮凭空消失的话，他只会以为这个页面坏了。
     */
    private class DetailAction(
        val label: String,
        val enabled: Boolean,
        val onPick: () -> Unit,
    )

    // ── 状态 ────────────────────────────────────────────────────────
    private enum class Level { WORKS, ITEMS }

    private var level = Level.WORKS
    private var currentWork: Work? = null

    /**
     * 从简介页返回作品墙时，**要把光标放回进来时那一张卡**。
     *
     * ⛔ `applyWorks` 末尾的 `setSelection(0)` 会把选中项打回第一张 —— 在 129 部的
     *    库里，用户从第 30 部的简介页按返回会被扔回开头，等于「我迷路了」。
     *    返回键的语义是「退一步」，光标必须还在原来那张卡上。
     * ⛔ 存的是**作品的 `key`**，不是下标：返回时列表可能已经被重查过
     *    （角标 / 计数 / 排序都会变），下标会错位，而 `key` 不会。
     * ⛔ 只在 [backToWorks] 里被填上；换分类 / 清筛选 / 返回首页这些路径都是
     *    `null` ⇒ 照旧回到第一张。
     */
    private var restoreSelectKey: String? = null

    private var sort = LibraryDb.Sort.recentModified
    private var playedOnly = false

    /**
     * 「追剧」视图 —— 与 [playedOnly] **完全同类**：它是一个**视图**，不是分类。
     *
     * ⛔ 与分类 / [playedOnly] **互斥**：点它会退出当前分类，点分类会退出它。
     *    两两互斥的三态（分类 / 最近播放 / 追剧）如果允许叠加，用户会看到
     *    「动漫 ∩ 追剧」这种既没有标签也没有解释的空结果，而角标数字
     *    （「追剧 5」）说的是全局，不是「动漫里的追剧」—— 两个数对不上。
     *
     * ⛔ 排序**照常由 [sort] 决定**，但仓储层在 `followedOnly` 时会把
     *    `new_item_count DESC` 拼在最前（见 `LibraryDb.listWorks`）——
     *    「有更新的排最前」是这个视图的意义所在，不能让它埋在「最近修改」里。
     */
    private var followedOnly = false

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

    /**
     * **有更新**的作品数（分类栏「追剧 N」的角标）。
     *
     * ⛔ 数的是 `new_item_count > 0` 而不是 `followed = 1` —— 与 PC 端
     *    `countUpdatedWorks` 逐字同口径。这个数字在电视上是一个**提醒**
     *    （有 N 部动了），不是「你追了 N 部」的收藏计数；后者是 0 时角标
     *    会消失，用户就再也不知道自己追了什么。
     */
    private var followedCount = 0

    /**
     * 「追剧自动检查」的**当前值**（真源是它，不是菜单上的字）。
     *
     * ⛔ 缓存在内存里而不是每次 `db.getSetting(...)`：读它发生在**主线程**上
     *    （`onCreate` 的 `postDelayed` 回调、`openMenu`），而主线程读 SQLite
     *    正是这个工程一直在避免的事（见 [loadWorks] 顶部那条注释）。
     *    由 [loadWorks] 的后台任务顺带刷新 —— 它本来就在读库。
     *
     * ⛔ 默认 [FollowAutoCheck.ON_LAUNCH]：老库 / 从电脑同步过来但那边没设过的
     *    库，`settings` 表里**根本没有这一行**。默认成 `OFF` 会让「追剧」这个
     *    功能在新机器上静默失效（判据只写一处，见 [FollowAutoCheck.parse]）。
     */
    private var followAutoCheck = FollowAutoCheck.ON_LAUNCH

    /** 分面选项的角标：作用域是「分类 / 最近播放 / 已刮削 / 搜索词」，**不含**自己。 */
    private var yearCounts: Map<Int, Int> = emptyMap()
    private var genreCounts: Map<String, Int> = emptyMap()

    private var busy = false
    private var busyWhat = ""

    private val works = ArrayList<Work>()
    private val items = ArrayList<LibraryItem>()
    private lateinit var worksAdapter: WorksAdapter
    private lateinit var itemsAdapter: ItemsAdapter

    // ── 剧集列表（作品详情页）的排序胶囊 ──
    // ⛔ **默认「修改时间倒序」**：用户要的默认就是它（见需求）。三档里
    //    [ItemSortMode.EPISODE_ORDER] 是「沿用仓储层排好的季→部→集→名称」，
    //    不是「没排序」，所以它是个**真正的选项**而不是默认值。
    private var itemsSortMode: ItemSortMode = ItemSortMode.MODIFIED_DESC
    private var itemsSortCursor: Int = ItemSortMode.entries.indexOf(ItemSortMode.MODIFIED_DESC)
    // ⛔ 光标态与生效态分离（与一级导航同一套语言）：←→ 只移光标，OK 才生效，
    //    避免跟着光标一路重排整个列表（电视上就是一路闪屏）。
    private var itemsSortFocused = false
    private lateinit var itemsSortBox: LinearLayout
    private lateinit var itemsSortScroll: HorizontalScrollView

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

    /**
     * 「要退出云影吗？」确认框（见 [handleBack] 的第 ③ 步）。
     *
     * ⛔ 媒体库是 App 的首页（`MainActivity` 启动完自己 `finish()` 了），所以
     *    这一页上的 `finish()` 就是**退出 App**。返回键一路退到最底下时不能
     *    直接退 —— 遥控器上没有「误触撤销」，而电视上的返回键是最高频的键。
     */
    private lateinit var exitDialog: ConfirmDialogView

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
        // ⛔ 必须在这里建，且必须**在建 [scanner] 之后**：`checkFollow` 是
        //    `onCreate` 结束后 1.5 秒（`postDelayed`）就会走到的路径。
        //    `lateinit` 忘了赋值**不会崩**，只在日志里留一句
        //    `UninitializedPropertyAccessException`（W 级），表现是
        //    「追剧功能静默失效」—— 角标永远不涨、状态行永远不说话。
        //    2026-10-07 真机部署时实际踩到：装机后进媒体库，日志里
        //    `追剧检查失败 / lateinit property followUpdater has not been
        //    initialized`，而界面上一切正常。
        followUpdater = FollowUpdater(db = db, scanner = scanner)
        // ⛔ 必须走 `api.thumbBytes`（带网盘 Cookie）：夸克的 `preview_url` 是
        //    直链，裸链回 `401 code=31001 require login`。所以这里**不能**复用
        //    [PosterFetcher] —— 那个用的是不带网盘凭证的 `ScrapeHttp`。
        cloudCovers = CloudCoverFetcher(
            dir = LibraryPaths.posterDir(this),
            thumbBytes = { api.thumbBytes(it) },
        )

        root = FrameLayout(this).apply { setBackgroundColor(BG) }
        root.addView(buildContent(), matchParent())
        root.addView(buildOverlay(), matchParent())
        root.addView(buildFilter(), matchParent())
        // ⛔ 退出确认框**最后加** —— 它是最上面那一层，黑幕要盖住海报墙、菜单、
        //    筛选面板的全部。加在 `setContentView` 之前，首帧不会闪一下黑幕。
        exitDialog = ConfirmDialogView(this)
        exitDialog.onCancel = { exitDialog.dismiss() }
        // ⛔ 这里就是「退出 App」：本页是 App 的首页（`MainActivity` 已经
        //    `finish()` 了），所以 Activity 一结束进程里就没有界面了。
        exitDialog.onConfirm = { finish() }
        root.addView(exitDialog, matchParent())
        setContentView(root)

        loadWorks()

        // ⛔ 用 `post` 而不是直接调：探测要走网络（列目录 + 读 64 KiB 头），
        //    放在 `onCreate` 里会让首帧等它。海报墙先画出来，探测随后就到 ——
        //    它本来就是「顺带问一句」，不该挡住用户看东西。
        root.post { probeRemoteBackupAtStartup() }

        // ── 进媒体库的静默追更检查 ────────────────────────────────────
        //
        // ⛔ 延迟 1.5 秒（`postDelayed`），不是 `post`：这条路径要列网盘目录，
        //    与首帧那批「读库 + 扫海报目录」抢的是同一个后台线程池。晚一点
        //    开始，海报墙就已经画完了 —— 而用户感知不到这 1.5 秒。
        // ⛔ **绝不弹对话框**（红线 12）：结果只体现在状态行一句话 + 海报墙
        //    角标 + 分类栏「追剧 N」。电视上弹窗会打断播放、抢焦点，还要用户
        //    摸遥控器去点「确定」。
        // ⛔ 窗口是 [FollowAutoCheck.LAUNCH_WINDOW_SEC]（30 分钟），**不是**
        //    `follow_auto_check` 的 6 小时：电视常被反复唤醒（待机 → 进媒体库），
        //    6 小时窗口会让绝大多数唤醒都什么都不做，用户会觉得「这功能没在跑」。
        root.postDelayed({ maybeAutoCheckFollow() }, FOLLOW_LAUNCH_DELAY_MS)
    }

    override fun onDestroy() {
        // ⛔ 先停扫描再关库：扫描线程可能正卡在一次 `applyScanItems` 的写事务里，
        //    而 `close()` 与正在跑的语句之间没有保护（见 `LibraryDb` 类文档）。
        //    置了标志之后它最多再跑完当前那个目录。
        scanCancel?.cancel()
        // 刮削同理：它可能正卡在一次搜索的超时里。
        scrapeCancel?.cancel()
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
        // ⛔ 高度压到 32dp（原 50dp）：`18dp` 的上留白 + `30dp` 图标是「品牌页头」
        //    的排场，但在电视上这 18dp 是**纯损耗** —— 它换不来任何信息，却等于
        //    海报墙少一条边。图标降到 22dp（与 20sp 标题同高），上留白降到 8dp。
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(GRID_PAD_DP), dp(8), dp(GRID_PAD_DP), dp(2))
        }
        head.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(22), dp(22)),
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
            // ⛔ 上下留白 4dp → 2dp：海报墙上沿紧贴分类栏，这 4px 的「呼吸」不值
            //    一条边。左右仍是 GRID_PAD_DP，与 `computeGrid` 的可用宽度对齐。
            setPadding(dp(GRID_PAD_DP), dp(2), dp(GRID_PAD_DP), dp(2))
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

        // ── 作品简介页头部（`Level.ITEMS` 才有；作品墙那一层整块 GONE）──
        //
        // 版式**对标 PC 端 `work_detail_page.dart` 的 `_InfoColumn`**：左海报
        // （2:3）、右侧「标题 / 原名 / 元数据 / 简介」，下面一行动作胶囊。
        //
        // ⛔ 海报尺寸**不照抄 PC 的 138×207**：电视横屏的逻辑高只有 540dp
        //    （1080p / density 2.0），207dp 的海报加上动作行、排序行、列表、
        //    底部两行提示会把这页撑爆 —— 列表只剩一行，而「选集」恰恰是这页的
        //    主要用途。收到 96×144 之后刚好放下三行简介 + 四行列表。
        detailHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(GRID_PAD_DP), dp(4), dp(GRID_PAD_DP), dp(4))
            visibility = View.GONE
        }
        val posterBox = FrameLayout(this)
        detailPoster = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setBackgroundColor(0xFF232833.toInt())
        }
        posterBox.addView(detailPoster, FrameLayout.LayoutParams(MATCH, MATCH))
        detailPosterPlaceholder = TextView(this).apply {
            setTextColor(0xFF4B5563.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 30f)
            gravity = Gravity.CENTER
            setBackgroundColor(0xFF232833.toInt())
        }
        posterBox.addView(detailPosterPlaceholder, FrameLayout.LayoutParams(MATCH, MATCH))
        detailHead.addView(posterBox, LinearLayout.LayoutParams(dp(96), dp(144)))

        val infoCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), 0, 0, 0)
        }
        detailTitle = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        infoCol.addView(detailTitle)
        detailOriginal = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(0, dp(3), 0, 0)
        }
        infoCol.addView(detailOriginal)
        detailMeta = TextView(this).apply {
            setTextColor(0xFFB9B2FF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(0, dp(7), 0, 0)
        }
        infoCol.addView(detailMeta)
        detailOverview = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            maxLines = 3
            ellipsize = android.text.TextUtils.TruncateAt.END
            setLineSpacing(dp(3).toFloat(), 1f)
            setPadding(0, dp(8), 0, 0)
        }
        infoCol.addView(detailOverview)
        detailHead.addView(infoCol, LinearLayout.LayoutParams(0, WRAP, 1f))
        column.addView(detailHead, LinearLayout.LayoutParams(MATCH, WRAP))

        // ── 简介页动作胶囊（播放 / 手动刮削 / 刮削设置 / 选集）──
        // 与排序胶囊同一套样式语言（实心面明度区分「光标 / 常态」，不描边）。
        // ⛔ 自己不吃焦点：光标态由 `actionsFocused` + `actionsCursor` 驱动，
        //    焦点始终留在 `itemsList` 上（见 [focusDetailActions]）。
        actionsBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(GRID_PAD_DP), dp(4), dp(GRID_PAD_DP), dp(4))
            isFocusable = false
            isFocusableInTouchMode = false
        }
        actionsScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            clipToPadding = false
            clipChildren = false
            visibility = View.GONE
        }
        actionsScroll.addView(actionsBox, FrameLayout.LayoutParams(WRAP, WRAP))
        column.addView(actionsScroll, LinearLayout.LayoutParams(MATCH, WRAP))

        // ── 剧集列表排序胶囊（进作品后才显示）──
        // 与一级导航的胶囊同一套样式语言（实心面明度区分「生效 / 光标 / 常态」，
        // 不描边）。放在列表上方，↑ 从首行进、↓ 回列表。
        itemsSortBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(GRID_PAD_DP), dp(4), dp(GRID_PAD_DP), dp(4))
            // ⛔ 胶囊自己不吃焦点：光标态由 `itemsSortFocused` + `itemsSortCursor`
            //    驱动，焦点全在 `itemsList` 上（见 [dispatchKeyEvent]）。
            isFocusable = false
            isFocusableInTouchMode = false
        }
        itemsSortScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            clipToPadding = false
            clipChildren = false
            visibility = View.GONE
        }
        itemsSortScroll.addView(itemsSortBox, FrameLayout.LayoutParams(WRAP, WRAP))
        column.addView(itemsSortScroll, LinearLayout.LayoutParams(MATCH, WRAP))

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
        // ⛔ 13sp/上留白 6dp → 12sp/4dp：这一块从 75px 压到 66px。
        //    **保留两行**（第二行是简介）——它是「不进简介页就能知道这部片讲什么」
        //    的唯一入口，砍掉它省下的 30px 换不回用户那一趟跳转。
        infoLine = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(GRID_PAD_DP), dp(4), dp(GRID_PAD_DP), 0)
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        column.addView(infoLine)

        // ⛔ 提示文案**随层级换**（[hintBar]）：作品墙上的 OK 是「进简介页」，
        //    简介页上的 OK 是「播放 / 应用」。写死一句话的话，两层里总有一层
        //    在骗人 —— 而遥控器上用户唯一的线索就是这行字。
        // ⛔ 12sp/上下 4+16dp → 11sp/2+10dp：67px → 49px。
        //    下留白**只收到 10dp**，不再往下压：电视有 overscan，最外一圈在部分
        //    机器上看不见，这行字是遥控器上唯一的操作线索，不能贴着边。
        hintBar = TextView(this).apply {
            setTextColor(0xFF6B7280.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setPadding(dp(GRID_PAD_DP), dp(2), dp(GRID_PAD_DP), dp(10))
        }
        column.addView(hintBar)

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
        /** 有更新的作品数（「追剧 N」的角标）。 */
        val followed: Int,
        /** 「追剧自动检查」设置项的**原始字符串**（`null` = 这一行不存在）。 */
        val followAuto: String?,
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
                    followedOnly = followedOnly,
                    category = category,
                    years = years,
                    genres = genres,
                    scrapedOnly = scrapedOnly,
                ),
                hasContent = db.hasContent(),
                counts = db.categoryCounts(),
                played = db.playedCount(),
                followed = db.followedUpdateCount(),
                // ⛔ 顺带读回来缓存进 [followAutoCheck]：`maybeAutoCheckFollow`
                //    与菜单都在**主线程**上问这个值，不能让它去读库。
                followAuto = db.getSetting(LibrarySettings.FOLLOW_AUTO_CHECK),
                // ⛔ 分面角标的作用域**不含 years / genres 自己**：否则用户每勾一个
                //    类型，剩下的类型角标就跟着变，勾到第二个时列表已经空了 ——
                //    而面板唯一的承诺是「点下去至少有一条结果」。
                years = db.yearCounts(category, playedOnly, scrapedOnly, followedOnly),
                genres = db.genreCounts(category, playedOnly, scrapedOnly, followedOnly),
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
            followedCount = s.followed
            followAutoCheck = FollowAutoCheck.parse(s.followAuto)
            yearCounts = s.years
            genreCounts = s.genres
            level = Level.WORKS
            currentWork = null
            applyWorks(s.works, keepStatus ?: defaultStatus(s))
            Log.i(
                TAG,
                "媒体库：${s.works.size} 部（分类=${category ?: "全部"}" +
                    (if (playedOnly) "·最近播放" else "") +
                    (if (followedOnly) "·追剧" else "") +
                    (if (scrapedOnly) "·已刮削" else "") +
                    (if (years.isNotEmpty()) "·年份$years" else "") +
                    (if (genres.isNotEmpty()) "·类型$genres" else "") +
                    "）· 海报索引 ${posters.indexedCount} 个文件 · 命中 " +
                    "${s.works.count { posters.fileFor(it) != null }}",
            )
        }
    }

    private fun defaultStatus(s: Snapshot): String = when {
        // ⛔ 追剧视图空的时候**不能**说「这个分类下没有作品」—— 那会让用户以为
        //    库里没东西。真正的原因是「你还没在追任何剧」，而出口在简介页。
        s.works.isEmpty() && followedOnly -> "还没有在追的剧集 —— 进作品简介页点「追剧」"
        s.works.isEmpty() && s.hasContent -> "这个分类/筛选下没有作品"
        s.works.isEmpty() -> "媒体库是空的 —— 菜单 → 从网盘恢复，把电脑上的库同步下来"
        followedOnly -> "在追 ${s.works.size} 部 · 其中 ${s.followed} 部有更新"
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
        // 简介页那一整块（海报 / 信息 / 动作胶囊）在作品墙上是 GONE。
        detailHead.visibility = View.GONE
        actionsScroll.visibility = View.GONE
        actionsFocused = false
        // ⛔ 收起/展开的是**滚动容器**，不是里面的 `LinearLayout`：
        //    只把子视图设成 GONE 的话，外面那层 `HorizontalScrollView` 还在，
        //    它会留一条高度为 0 却仍然参与焦点搜索的空壳。
        tabsScroll.visibility = View.VISIBLE
        barScroll.visibility = View.VISIBLE
        title.text = "媒体库"
        status.text = statusText
        hintBar.text = "↑↓←→ 选择 · OK 进简介页 · ↑ 到状态行（排序 / 筛选）· 菜单 更多"
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
            // ⛔ 还原「从简介页返回时那一张卡」（见 [restoreSelectKey]）：只有
            //    [backToWorks] 会填它，其它路径是 null ⇒ 回到第一张。
            // ⛔ 用完**立刻清掉**，否则它会在下一次无关的刷新里再命中一次，
            //    把用户刚翻到的地方又拽回去。
            val restore = restoreSelectKey
            restoreSelectKey = null
            val pos = restore?.let { k -> works.indexOfFirst { it.key == k } } ?: -1
            val target = if (pos >= 0) pos else 0
            worksGrid.setSelection(target)
            worksGrid.requestFocus()
            showInfo(works.getOrNull(target))
        }
    }

    /**
     * 进「作品简介页」。
     *
     * ⛔ 2026-10-07 起**点卡片走这里，不再直接播**（用户需求）。理由：直接播
     *    等于替用户做了三个决定 —— 播哪一条（[PlayTarget]）、播哪一版、
     *    要不要先刮削；而用户点卡片时想做的经常是「看看这部是什么」
     *    「换一集」「刮一下海报」。
     *
     * ⛔ 取条目要在**后台**读（`itemsForWork` 是查库，剧集一部能有两百条）。
     */
    private fun openWork(w: Work) {
        status.text = "读取「${w.title}」…"
        Bg.run({
            // ⛔ 进简介页 = 「我看到了」⇒ 清掉未读角标（红线 8）。
            //
            // 只清 `new_item_count`：**不动** `follow_started_at`（剧集行的 NEW
            // 标签靠它 —— 那是「哪几集是新的、我还没看」，与角标回答的不是同一个
            // 问题；动它会让还没看的那几集的 NEW 一起消失），也**不动**
            // `updated_at`（红线 1：它参与同步判据，写它会让本机永远「看起来更新」）。
            //
            // ⛔ 清完之后必须**重读这一行**：`currentWork` 上的 `newItemCount`
            //    还是旧值，不重读的话追剧胶囊会一直写着「已追剧 · 2 新」，
            //    而墙上那枚角标已经没了 —— 同一个数字在两个地方说法不一致。
            db.clearFollowBadge(w.key)
            // ⛔ 用 `workForDetail` 而**不是** `workByKey`：头部那行元数据
            //    （`N 集 / M 季`）读的是 `w.itemCount` / `w.seasonCount`，而库里
            //    存的是**自己名下**的数。归一并集后（如「遮天」存值 1 / 并集 13），
            //    用存值会让头部写「1 集」而下面列着 13 行 —— 同页自相矛盾。
            db.workForDetail(w.key) to db.itemsForWork(w.key)
        }) { pair, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                return@run
            }
            val fresh = pair?.first
            val list = pair?.second
            // ⛔ 别写成 `fresh ?: run { … return@run }`：内层 `run { }` 会把
            //    `@run` 这个标签**遮住**（见 `refreshAfterScrape` 里同一处坑）。
            //    行被删了（用户在别处移除了整部）时退回手上那份，页面照常打开。
            val work = fresh ?: w
            // ⛔ 进作品**默认按修改时间倒序**：这是用户要的默认排序（见需求）。
            //    [sortItems] 对 [ItemSortMode.EPISODE_ORDER] 原样返回、对两种时间档
            //    重排；这里先按默认档排好，胶囊再画「当前档 = 修改时间倒序」。
            itemsSortMode = ItemSortMode.MODIFIED_DESC
            itemsSortCursor = ItemSortMode.entries.indexOf(itemsSortMode)
            itemsSortFocused = false
            // ⛔ 保留 `items` 这个 `ArrayList` 本身（别重新赋值），只清空重填：
            //    适配器持有的是它。**也别先填一遍再清一遍** —— 那样
            //    `sortItems` 拿到的是空列表，剧集列表会永远是空的（不报错）。
            items.clear()
            items.addAll(sortItems(list ?: emptyList(), itemsSortMode))
            level = Level.ITEMS
            currentWork = work
            itemsAdapter.notifyDataSetChanged()
            worksGrid.visibility = View.GONE
            itemsList.visibility = View.VISIBLE
            // 简介页头部 + 动作胶囊 + 排序胶囊：三块都只在作品详情页出现。
            paintDetailHead()
            actionsCursor = 0
            buildDetailActions()
            actionsScroll.visibility = View.VISIBLE
            itemsSortScroll.visibility = View.VISIBLE
            buildItemsSortBar()
            // ⛔ 进作品后分类/筛选行**必须收起来**：它们的作用域是「作品墙」，
            //    留在屏幕上会让人以为还能按分类过滤剧集（实际不会）。
            tabsScroll.visibility = View.GONE
            barScroll.visibility = View.GONE
            // ⛔ 焦点标志也要一起清掉：它们俩现在是不可见视图，`requestFocus()`
            //    到一个 GONE 的视图会失败，之后所有按键都会掉进「谁也不管」的
            //    空隙里（`barFocused` 还是 true，于是 dispatch 一直往那一支走）。
            tabsFocused = false
            barFocused = false
            title.text = "媒体库 / ${work.title}"
            status.text = "${work.subtitle.ifEmpty { "${items.size} 个文件" }} · ${items.size} 个文件"
            hintBar.text = "←→ 换胶囊 · OK 播放 / 执行 · ↑↓ 换层 · 菜单 更多 · 返回 回作品墙"
            // ⛔ 焦点给列表、**光标**给动作行：列表拿到焦点它的选中高亮才画得出来，
            //    而 ←→ 这时归动作行管（见 [focusDetailActions] 的理由）。
            itemsList.setSelection(0)
            itemsList.requestFocus()
            focusDetailActions()
        }
    }

    /**
     * 站在简介页上时，把**当前这一部**的条目重读一遍（原地刷新）。
     *
     * ## 为什么需要它
     *
     * 2026-10-07 现场：用户在这部剧的简介页上点了「⟳ 检查追剧更新」，
     * 提示「有 1 部剧更新了（共 2 集）」，**而眼前这个列表一个都没多**。
     * 库确实写对了 —— 错的是这一页没人通知它重读。
     *
     * ⛔ 不能拿 [loadWorks] 顶替：它会 `level = Level.WORKS`，把正看着简介页的
     *    用户**踢回作品墙**（用户点的是「检查更新」，不是「返回」）。
     *    回作品墙那条路（[backToWorks]）本来就会重跑 `loadWorks`，所以墙上
     *    的角标不会因此变旧。
     *
     * ⛔ 两处「期间状态变了」都要挡：
     *    * 用户已经按返回回了作品墙（`level != Level.ITEMS`）；
     *    * 用户已经换到另一部作品（`currentWork?.key` 变了）。
     *    不挡的话，异步读库回来会把**上一部**的条目画进**下一部**的列表里 ——
     *    而它看起来完全正常（都是这部剧的文件），只是内容不对。
     *
     * ⛔ 保留光标位置：用户很可能正停在第 12 集上，刷新一下把他弹回第 1 集
     *    是另一种「莫名其妙」。
     */
    private fun reloadCurrentItems() {
        val cur = currentWork ?: return
        if (level != Level.ITEMS) return
        Bg.run({ db.itemsForWork(cur.key) to db.workForDetail(cur.key) }) { pair, err ->
            if (err != null) {
                Log.w(TAG, "原地刷新简介页失败：${cur.key}", err)
                return@run
            }
            if (level != Level.ITEMS) return@run
            if (currentWork?.key != cur.key) return@run
            val w = pair?.second ?: cur
            val keep = itemsList.selectedItemPosition
            items.clear()
            items.addAll(sortItems(pair?.first ?: emptyList(), itemsSortMode))
            currentWork = w
            itemsAdapter.notifyDataSetChanged()
            paintDetailHead()
            buildDetailActions()
            title.text = "媒体库 / ${w.title}"
            status.text =
                "${w.subtitle.ifEmpty { "${items.size} 个文件" }} · ${items.size} 个文件"
            if (keep in items.indices) itemsList.setSelection(keep)
            Log.i(TAG, "原地刷新简介页：${w.key} → ${items.size} 条（光标停在 $keep）")
        }
    }

    /** 回到作品墙。返回键在 [Level.ITEMS] 上会调它。 */
    private fun backToWorks() {
        // ⛔ 先记下「从哪一部进来的」：`applyWorks` 会把选中项打回第 0 张，
        //    不还原的话用户从第 30 部返回会被扔回开头。见 [restoreSelectKey]。
        restoreSelectKey = currentWork?.key
        level = Level.WORKS
        currentWork = null
        items.clear()
        // 离开详情页：简介页头部、动作胶囊、排序胶囊与它们的光标态都要复位，
        // 回作品墙时这三块都是不可见的。
        detailHead.visibility = View.GONE
        actionsScroll.visibility = View.GONE
        itemsSortScroll.visibility = View.GONE
        actionsFocused = false
        itemsSortFocused = false
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
    // 简介页头部（海报 + 标题 / 原名 / 元数据 / 简介）
    // ------------------------------------------------------------------

    /**
     * 把 [currentWork] 画进简介页头部。
     *
     * ⛔ 每次刮削回来必须重画（[refreshAfterScrape]）：标题 / 年份 / 类型 / 简介
     *    / 海报都会被改。不重画的表现是「刮成功了，页面上还是旧的」。
     * ⛔ 海报解码**绝不能在主线程做**（见 [PosterStore.decode]）：与海报墙
     *    同一套「先查缓存、未命中就丢后台解、解完再画」的流程。
     */
    private fun paintDetailHead() {
        val w = currentWork
        if (w == null) {
            detailHead.visibility = View.GONE
            return
        }
        detailHead.visibility = View.VISIBLE

        detailTitle.text = w.title
        // ⛔ 「原名」与「元数据行」的口径都封在 [WorkDetailFormat] 里（可单测），
        //    这里只负责把它们画上去 —— 别在这边再写一遍判据。
        val original = WorkDetailFormat.originalLine(w)
        detailOriginal.text = original ?: ""
        detailOriginal.visibility = if (original == null) View.GONE else View.VISIBLE

        // ⛔ 这一行**恒非空**（分类与来源恒在，见 [WorkDetailFormat.metaLine]），
        //    所以不判空、不设 GONE —— 元数据是这一页最该一眼看到的东西。
        detailMeta.text = WorkDetailFormat.metaLine(w)
        detailMeta.visibility = View.VISIBLE

        val overview = WorkDetailFormat.overviewText(w)
        detailOverview.text = overview ?: ""
        detailOverview.visibility = if (overview == null) View.GONE else View.VISIBLE

        paintDetailPoster(w)
    }

    /** 简介页海报。三级查找封在 [PosterStore.fileFor] 里，这里只管画。 */
    private fun paintDetailPoster(w: Work) {
        val file = posters.fileFor(w)
        val bmp = file?.let { posters.cached(it) }
        if (bmp != null) {
            detailPoster.setImageBitmap(bmp)
            detailPoster.visibility = View.VISIBLE
            detailPosterPlaceholder.visibility = View.GONE
            return
        }
        detailPoster.setImageDrawable(null)
        detailPoster.visibility = View.INVISIBLE
        // 没海报时给一个「首字」占位块 —— 一片灰比一个字更让人以为坏了。
        detailPosterPlaceholder.text = w.title.take(1)
        detailPosterPlaceholder.visibility = View.VISIBLE
        if (file == null) {
            // 本地一个文件都没有 ⇒ 未刮削的作品，去拉网盘自带的缩略图。
            // ⛔ 回来时重画的是**这一块**，不能靠 [queueCloudRefresh]（那个重画的
            //    是背后的作品墙，此刻还是 GONE）。
            fetchCloudCover(w) { if (currentWork?.key == w.key) paintDetailPoster(w) }
            return
        }
        // ⛔ 解码绝不能在主线程做（见 [PosterStore.decode]）。
        //    解完**只重画这一块**，不能 `notifyDataSetChanged()` 海报墙 ——
        //    那会连带重绑整个 `GridView`，而用户此刻正在看详情页。
        Bg.run({ posters.decode(file, dp(DETAIL_POSTER_DP * 2)) }) { bitmap, err ->
            if (bitmap == null || err != null) return@run
            posters.put(file, bitmap)
            // ⛔ 解码回来时用户可能已经退出这一页了 —— 那时 `currentWork`
            //    换人（或被清空），直接画上去就是**别人的海报**。
            if (currentWork?.key != w.key) return@run
            paintDetailPoster(w)
        }
    }

    /**
     * 未刮削的作品：把**网盘自带的缩略图**拉下来当封面。
     *
     * ## 为什么需要这一步
     *
     * 扫描时 `LibraryScanner` 已经把缩略图地址写进了 `media_works.poster_url`
     * （夸克列目录下发的 `preview_url`），但 [PosterStore.fileFor] 的三级查找
     * **每一级都要求本地真有文件** —— 而此前**没有任何组件负责下载它**。
     * 结果就是「没刮削过的作品在墙上一块封面都没有」，正是用户报的那一条。
     *
     * ## 几个刻意的选择
     *
     * ⛔ **走 `api.thumbBytes`**（带网盘 Cookie），不能用 [PosterFetcher] ——
     *    裸链回 `401 code=31001 require login`。
     * ⛔ **落海报目录**、用 [com.cloudcine.tv.library.PosterNaming.fileNameFor]
     *    命名：`fileFor` 的第②级零改动就能命中，而且缩略图会**随备份包搬走**。
     * ⛔ 每部作品每个页面实例**只试一次**（[cloudCoverTried]）：失败记忆在
     *    `CloudCoverFetcher` 里是内存态，而简介页每次重画都会再问一次。
     * ⛔ 写库（回写 `poster_file`）放在**后台**做，回主线程只 `notifyDataSetChanged`。
     *
     * @param onReady 落盘成功后在主线程回调一次（简介页用它重画自己那一块）。
     */
    private fun fetchCloudCover(w: Work, onReady: (() -> Unit)? = null) {
        val url = w.posterUrl?.takeIf { it.isNotBlank() } ?: return
        if (!cloudCoverTried.add(w.key)) return
        Bg.run({
            val name = cloudCovers.fetch(w.key, url)
            // ⛔ 回写 `poster_file`：`fileFor` 的第①级从此直接命中，不必每次都
            //    现算文件名；更重要的是这一列**随库一起进备份包**。
            if (name != null) runCatching { db.setWorkPosterFile(w.key, name) }
            name
        }) { name, err ->
            if (err != null || name == null) return@run
            queueCloudRefresh()
            onReady?.invoke()
        }
    }

    /**
     * 攒一次作品墙重画。
     *
     * ⛔ 不能每下好一张封面就 `notifyDataSetChanged()`：首次进库时未刮削的作品
     *    可能有几百部，逐个重绑整墙等于把海报墙按住不让动 —— 而用户此刻正想
     *    滚一滚看看扫出来了什么。攒 [CLOUD_REFRESH_MS] 毫秒统一重画一次。
     */
    private fun queueCloudRefresh() {
        if (cloudRefreshQueued) return
        cloudRefreshQueued = true
        worksGrid.postDelayed(
            {
                cloudRefreshQueued = false
                if (!isFinishing) worksAdapter.notifyDataSetChanged()
            },
            CLOUD_REFRESH_MS,
        )
    }

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

        items.add(
            NavItem("全部", total, null, category == null && !playedOnly && !followedOnly) {
                category = null
                playedOnly = false
                followedOnly = false
                loadWorks()
            },
        )
        items.add(
            NavItem("最近播放", playedCount, "◷", playedOnly) {
                category = null
                playedOnly = true
                followedOnly = false
                // ⛔ 进了「最近播放」必须把排序切到「按播放时间」—— 它只是一个
                //    **视图**（`playedOnly`），默认排序是 `recentModified`（按文件
                //    修改时间），不切的话刚看过的片子会按修改时间散落在列表里，
                //    根本不在最前（用户实机反馈）。
                sort = LibraryDb.Sort.recentPlayed
                loadWorks()
            },
        )
        // 追剧**紧跟「最近播放」**，与它同一种东西（视图，不是分类）。
        // ⛔ 角标是「有更新的作品数」而不是「在追的作品数」：它是提醒，不是收藏计数
        //    （与 PC 端 `countUpdatedWorks` 同口径）。所以 0 时它不亮，但**不消失**
        //    —— 用户得有个地方点进去看自己追了什么。
        items.add(
            NavItem("追剧", followedCount, "✦", followedOnly) {
                category = null
                playedOnly = false
                followedOnly = true
                loadWorks()
            },
        )
        for (c in MediaCategoryNames.displayOrder) {
            items.add(
                NavItem(
                    MediaCategoryNames.label(c),
                    counts[c] ?: 0,
                    null,
                    category == c && !playedOnly && !followedOnly,
                ) {
                    category = c
                    playedOnly = false
                    followedOnly = false
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
    /**
     * 胶囊 / 行的三态配色。**焦点 > 生效 > 常态**，层级必须靠明度拉开。
     *
     * ⛔ 之前 `isCurrent`(已生效) 用最亮品牌色、`isCursor`(真焦点) 用更暗品牌色，
     *    层级反了：焦点移走后已生效那颗仍最亮 ⇒ 看着像「焦点还在那」；焦点在
     *    导航上时光标位置反而比已生效项更暗 ⇒ 根本分不清焦点在哪。这里把
     *    `focused` 放最前、用最亮品牌实心，已生效只用淡品牌底（绝不抢焦点），
     *    常态再压一档。四类胶囊（导航 / 状态行 / 排序 / 动作）共用同一套语言。
     *
     * @param dimNormal 常态下是否再压暗文字（导航带里数量为 0 的分类）。
     */
    private fun chipColors(focused: Boolean, active: Boolean, dimNormal: Boolean = false): Pair<Int, Int> =
        when {
            focused -> BRAND_TINT to 0xFF1A1533.toInt()       // 亮品牌实心 + 深字（最强，唯一「真焦点」）
            active  -> 0x33A9A3F5.toInt() to BRAND_TINT       // 淡品牌底 + 品牌字（已生效，不抢焦点）
            else    -> 0x14FFFFFF.toInt() to if (dimNormal) 0xFF4B5563.toInt() else 0xFFB9C0CC.toInt()
        }

    /**
     * 剧集列表选中行的背景。
     *
     * ⛔ 之前只给选中行一层中等亮度的品牌实底（`BRAND_SELECT`），在深色列表里
     *    太弱、又和排序胶囊「已生效」的亮品牌色撞脸 ⇒ 三处焦点都分不清。这里在
     *    圆角品牌底之上再加一条 4dp 左侧强调条（与 [MenuRow] 同一语言），选中行
     *    一眼可辨，且不靠描边（深色 UI 里描边只剩一条细线，用户明确嫌过）。
     */
    private fun listRowFocusDrawable(selected: Boolean): Drawable {
        if (!selected) return ColorDrawable(Color.TRANSPARENT)
        val fill = BRAND_SELECT
        val bar = BRAND_TINT
        val barW = dp(4)
        val r = dp(10)
        return object : Drawable() {
            private val fillPaint = Paint().apply { color = fill; isAntiAlias = true }
            private val barPaint = Paint().apply { color = bar; isAntiAlias = true }
            override fun draw(c: Canvas) {
                c.drawRoundRect(
                    0f, 0f, bounds.width().toFloat(), bounds.height().toFloat(),
                    r.toFloat(), r.toFloat(), fillPaint,
                )
                c.drawRect(0f, 0f, barW.toFloat(), bounds.height().toFloat(), barPaint)
            }
            override fun setAlpha(a: Int) {}
            override fun setColorFilter(cf: ColorFilter?) {}
            override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
        }
    }

    /** 卡片的圆角 tile 底：选中=品牌色、常态=略亮深色，外圈这圈就是「卡」的边。 */
    private fun cardTile(fill: Int): Drawable = GradientDrawable().apply {
        cornerRadius = dp(14).toFloat()
        setColor(fill)
    }

    private fun navChip(item: NavItem, isCursor: Boolean): TextView {
        val text = buildString {
            if (item.icon != null) append(item.icon).append(' ')
            append(item.label)
            if (item.count > 0) append(' ').append(item.count)
        }
        return TextView(this).apply {
            this.text = text
            // ⛔ 15sp/上下 10dp → 13sp/上下 5dp：胶囊从 37dp 压到 25dp。
            //    形状不变（`cornerRadius = dp(20)` 本来就超过半高，一直是药丸），
            //    省下的 12dp 全给海报墙。
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(14), dp(5), dp(14), dp(5))
            // ⛔ **必须单行**。装不下时宁可被滚动条截掉、也不能折行：
            //    折行会把整条导航带顶高一行，海报墙跟着少一行（实测过）。
            maxLines = 1
            isSingleLine = true
            isFocusable = false
            isFocusableInTouchMode = false
            gravity = Gravity.CENTER
            val (navBg, navFg) = chipColors(focused = isCursor, active = item.isCurrent, dimNormal = item.count == 0)
            background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                setColor(navBg)
            }
            setTextColor(navFg)
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
        if (followedOnly) {
            items.add(
                BarItem("✦ 退出追剧", true, "OK 回到全部分类") {
                    followedOnly = false
                    category = null
                    loadWorks()
                },
            )
            // ⛔ 追剧视图里放一颗「检查更新」是**刻意的第二个入口**（第一个在
            //    菜单里）：用户切到这个视图就是为了看有没有新集，让他再按两次
            //    菜单键去够同一个动作，是在惩罚最常用的路径。两处调的是同一个
            //    [checkFollow]。
            items.add(
                BarItem("⟳ 检查更新", false, "OK 立刻检查在追的剧有没有新集（无视节流）") {
                    checkFollow(force = true)
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
        // ⛔ 与 [navChip] 同一理由：13sp/上下 8dp → 12sp/上下 4dp，胶囊 30dp → 22dp。
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setPadding(dp(12), dp(4), dp(12), dp(4))
        maxLines = 1
        isSingleLine = true
        isFocusable = false
        isFocusableInTouchMode = false
        gravity = Gravity.CENTER
        val (barBg, barFg) = chipColors(focused = isCursor, active = item.active)
        background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setColor(barBg)
        }
        setTextColor(barFg)
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

    // ------------------------------------------------------------------
    // 剧集列表（作品详情页）的排序胶囊
    //
    // 与一级导航的胶囊**同一套样式语言**（实心面明度区分「生效 / 光标 / 常态」，
    // 不描边），但**作用域不同**：它只在 `Level.ITEMS` 出现，且光标态和生效态
    // 分离（←→ 只移光标，OK 才重排），理由与一级导航一致（见 [moveTab]）。
    // ------------------------------------------------------------------

    /** 重画排序胶囊。当前档 = 生效（亮品牌色实心 + 深字）；光标所在 = 暗品牌色。 */
    private fun buildItemsSortBar() {
        val modes = ItemSortMode.entries
        itemsSortBox.removeAllViews()
        for ((i, mode) in modes.withIndex()) {
            itemsSortBox.addView(
                itemsSortChip(
                    mode,
                    isCurrent = mode == itemsSortMode,
                    isCursor = itemsSortFocused && i == itemsSortCursor,
                ),
            )
        }
        revealChip(itemsSortScroll, itemsSortBox, itemsSortCursor)
    }

    /** 一颗排序胶囊。尺寸/圆角/配色与 [barChip] 同款，只是多了「生效态」高亮。 */
    private fun itemsSortChip(mode: ItemSortMode, isCurrent: Boolean, isCursor: Boolean): TextView =
        TextView(this).apply {
            text = mode.label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(14), dp(8), dp(14), dp(8))
            maxLines = 1
            isSingleLine = true
            isFocusable = false
            isFocusableInTouchMode = false
            gravity = Gravity.CENTER
            val (sBg, sFg) = chipColors(focused = isCursor, active = isCurrent)
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(sBg)
            }
            setTextColor(sFg)
            layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { rightMargin = dp(8) }
        }

    /** ←→ 在排序胶囊里移光标。**不重排**：重排只发生在 OK 生效时。 */
    private fun moveItemsSort(delta: Int) {
        val modes = ItemSortMode.entries
        itemsSortCursor = (itemsSortCursor + delta + modes.size) % modes.size
        buildItemsSortBar()
    }

    /** OK：把光标所在档设为当前排序，重排列表、回到第一行、把焦点还给列表。 */
    private fun applyItemsSort() {
        val mode = ItemSortMode.entries.getOrNull(itemsSortCursor) ?: return
        if (mode == itemsSortMode) {
            focusItemsList()
            return
        }
        Log.i(TAG, "剧集排序：${itemsSortMode.label} → ${mode.label}")
        itemsSortMode = mode
        // ⛔ 保留 `items` 这个 `ArrayList` 本身（别重新赋值），只清空重填：
        //    列表适配器持有的是它，重新赋值会丢掉引用。
        val sorted = sortItems(items, mode)
        items.clear()
        items.addAll(sorted)
        itemsAdapter.notifyDataSetChanged()
        // ⛔ 回到第一行：重排后旧选中项的 position 已经失效，而「切排序 = 想看
        //    另一种顺序」通常就该从头扫，与海报墙切分类回第一行一致。
        itemsList.setSelection(0)
        buildItemsSortBar()
        focusItemsList()
    }

    // ------------------------------------------------------------------
    // 简介页动作胶囊（播放 / 手动刮削 / 刮削设置 / 选集）
    //
    // 与排序胶囊同一套语言（实心面明度区分「光标 / 常态」，不描边），但**不是
    // 同一个东西**：动作行回答「对这一部作品做什么」，排序行回答「这一页的
    // 列表怎么排」。两行、两套光标态，理由见字段区。
    // ------------------------------------------------------------------

    /**
     * 重建动作胶囊的**内容**。
     *
     * ⛔ 每次进作品 / 刮削回来都要重建：文案与 `enabled` 都依赖当前这份
     *    [currentWork] 与 [items]（「续播」只在真有进度时出现、播放按钮在
     *    一条可播文件都没有时置灰）。缓存一份的话，刮削换了标题之后按钮
     *    还是旧的。
     */
    private fun buildDetailActions() {
        val w = currentWork
        val actions = ArrayList<DetailAction>(5)
        if (w != null) {
            val resumable = (w.resumeFraction ?: 0.0) > 0.0
            // ⛔ 文案与可用性来自 [WorkDetailFormat]（可单测），这里只负责把
            //    「第几颗胶囊做什么」接上 —— 顺序必须与那边逐项一致，
            //    因为光标位置就是按这个下标存的。
            // ⛔ `followed` / `newItemCount` 一起传进去：「已追剧 · 2 新」那半句
            //    只在这两个值都对的时候才该出现（见 [WorkDetailFormat.followLabel]）。
            val labels = WorkDetailFormat.actionLabels(
                resumable = resumable,
                itemCount = items.size,
                followed = w.followed,
                newCount = w.newItemCount,
            )
            actions.add(DetailAction(labels[0].first, labels[0].second) { playWork(w) })
            // 追剧在第 2 位（紧挨播放），不是末尾 —— 理由见
            // [WorkDetailFormat.actionLabels] 的文档。
            actions.add(DetailAction(labels[1].first, labels[1].second) { toggleFollow(w) })
            actions.add(DetailAction(labels[2].first, labels[2].second) { openScrape(w) })
            actions.add(DetailAction(labels[3].first, labels[3].second) { openScrapeSettings() })
            // 「选集」不是一个动作，而是**把光标交给下面的列表** —— 它在电视上
            // 是「这一页怎么换集」的唯一说明；没有它，用户会以为这里只能播一条。
            // ⛔ 它必须留在**最后**：它是这一行的出口（同上）。
            actions.add(DetailAction(labels[4].first, labels[4].second) { focusItemsList() })
        }
        detailActions = actions
        actionsCursor = actionsCursor.coerceIn(0, (actions.size - 1).coerceAtLeast(0))
        paintDetailActions()
    }

    /** 重画动作胶囊。光标所在 = 亮品牌色实心 + 深字；不可用 = 压到几乎看不见。 */
    private fun paintDetailActions() {
        actionsBox.removeAllViews()
        for ((i, a) in detailActions.withIndex()) {
            actionsBox.addView(actionChip(a, isCursor = actionsFocused && i == actionsCursor))
        }
        revealChip(actionsScroll, actionsBox, actionsCursor)
    }

    /** 一颗动作胶囊。尺寸 / 圆角 / 配色与 [itemsSortChip] 同款（不描边）。 */
    private fun actionChip(a: DetailAction, isCursor: Boolean): TextView =
        TextView(this).apply {
            text = a.label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(14), dp(8), dp(14), dp(8))
            maxLines = 1
            isSingleLine = true
            isFocusable = false
            isFocusableInTouchMode = false
            gravity = Gravity.CENTER
            val (aBg, aFg) = if (!a.enabled) 0x0AFFFFFF.toInt() to 0xFF4B5563.toInt()
                              else chipColors(focused = isCursor, active = false)
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(aBg)
            }
            setTextColor(aFg)
            layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { rightMargin = dp(8) }
        }

    /** ←→ 在动作胶囊里移光标。**不执行**：动作只在 OK 时发生。 */
    private fun moveActions(delta: Int) {
        if (detailActions.isEmpty()) return
        actionsCursor = (actionsCursor + delta + detailActions.size) % detailActions.size
        paintDetailActions()
        val a = detailActions[actionsCursor]
        infoLine.text = if (a.enabled) "OK ${a.label}" else "${a.label}：现在没有可播的文件"
    }

    /** OK：执行光标所在的动作。 */
    private fun applyAction() {
        val a = detailActions.getOrNull(actionsCursor) ?: return
        if (!a.enabled) {
            infoLine.text = "${a.label}：现在没有可播的文件"
            return
        }
        Log.i(TAG, "简介页动作：${a.label}")
        a.onPick()
    }

    /**
     * ↑ 从排序胶囊进动作行（进作品时也走这里）。
     *
     * ⛔ **不抢焦点**（不 `requestFocus()`）：焦点留在 [itemsList] 上，列表的
     *    选中高亮才画得出来，动作行只吃「光标态」。与 [focusItemsSort] 同一套
     *    理由 —— 焦点一挪走，底下那行的高亮就没了，用户会以为列表被清空了。
     * ⛔ 这几个 `focus*` 函数**必须互相清掉对方的标志位**（与 [focusTabs] 那一组
     *    同一条规矩）：漏清一个就会出现「两行胶囊同时发光」，用户完全不知道
     *    按键现在管的是哪一行。
     */
    private fun focusDetailActions() {
        itemsSortFocused = false
        actionsFocused = true
        paintDetailActions()
        buildItemsSortBar()
        infoLine.text = "←→ 选动作 · OK 执行 · ↓ 到列表 · ↑ 回作品墙"
    }

    /** ↑ 从列表首行进排序胶囊：胶囊吃光标态，列表的选中高亮仍在（不抢焦点）。 */
    private fun focusItemsSort() {
        actionsFocused = false
        itemsSortFocused = true
        paintDetailActions()
        buildItemsSortBar()
        infoLine.text = "OK 应用排序 · ↑ 到动作 · ↓ 返回列表"
    }

    /** 把光标交回列表（两行胶囊都失去光标态），并恢复底部提示。 */
    private fun focusItemsList() {
        actionsFocused = false
        itemsSortFocused = false
        paintDetailActions()
        buildItemsSortBar()
        // ⛔ 光标在胶囊上时底部那行被改成了「OK 应用排序…」，交回列表要还原。
        //    简介正文现在画在**上面的头部**里（见 [paintDetailHead]），所以这行
        //    改成按键提示，不再是同一段简介在屏幕上印两遍。
        infoLine.text = "OK 播放这一集 · ↑ 到排序 / 动作 · 返回 回作品墙"
        itemsList.requestFocus()
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
     * 点作品卡片 —— **进简介页**（2026-10-07 起，不再是「直接播放」）。
     *
     * ⛔ 直接播等于替用户做了三个决定 —— 播哪一条（[PlayTarget]）、播哪一版、
     *    要不要先刮削；而用户点卡片时想做的经常是「看看这部是什么」「换一集」
     *    「刮一下海报」。简介页把这三件事都摆出来，播放只是其中最显眼的一颗胶囊。
     * ⛔ 因此 `onWorkRow` 与 `onItemRow` 现在是**两种语义**：前者进详情页
     *    （异步读库），后者直接起播（已经在详情页里，选的就是那一条）。
     */
    private fun onWorkRow(position: Int) {
        works.getOrNull(position)?.let { openWork(it) }
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
     *
     * ## ⛔ 点击这一刻就写「已读回执」（2026-10-07 现场）
     *
     * 现象：TV 端点了带 `■ NEW` 的一集、打开播放，返回后标记还在。
     * 两个原因叠在一起：
     *
     *   1. 已读回执**只由播放页**在退出时补写（`PlayerActivity.reportProgress`），
     *      而它开头就是 `if (positionMs <= 0L) return` —— 起播瞬间位置是 0，
     *      短看几秒就退出的那一次**一个字都没写**；
     *   2. 本页从播放页返回后**不重读**（见 [onActivityResult]），列表里那份
     *      `LibraryItem` 还是播放前的快照，`isNewSinceFollow` 自然照旧为真。
     *
     * 在**点击这一刻**写掉，第 1 条就不成立了 —— 与 PC 端 `_markOpened` 同一
     * 取舍：用户要的是「**点过就不再是 NEW**」，与看多久无关。
     *
     * ⛔ 只写 `markPlayed`（已读回执），**不写** `max_position_ms`：那一列是
     *    「看到哪儿了」，写个假极小值会让每一条点过的都画出一条 0% 的进度槽。
     * ⛔ 写库是磁盘 I/O，必须 `Bg.run` 丢到后台；失败只记日志，**不能**挡起播。
     */
    private fun play(item: LibraryItem) {
        Bg.run({ db.markPlayed(item.id) }) { _, err ->
            if (err != null) Log.w(TAG, "已读回执写入失败（不影响播放）：${item.id}", err)
        }
        // ⛔ 用 `startActivityForResult` 而**不是** `startActivity`：回来时要把
        //    这一页重读一遍，NEW 标签才会当场消失（见 [onActivityResult]）。
        @Suppress("DEPRECATION")
        startActivityForResult(
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
            REQ_PLAYER,
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

        // ── 分类（含「最近播放」「追剧」这两个视图）──
        rows.add(FRow.Section("分类"))
        rows.add(
            FRow.Toggle("全部", null, category == null && !playedOnly && !followedOnly, false) {
                category = null
                playedOnly = false
                followedOnly = false
            },
        )
        rows.add(
            FRow.Toggle("最近播放", playedCount, playedOnly, false) {
                category = null
                playedOnly = true
                followedOnly = false
                // ⛔ 与导航带同一条规矩：进「最近播放」按播放时间排。
                sort = LibraryDb.Sort.recentPlayed
            },
        )
        // ⛔ 角标 = 有更新的作品数（与导航带上那颗同口径）。
        rows.add(
            FRow.Toggle("追剧", followedCount, followedOnly, false) {
                category = null
                playedOnly = false
                followedOnly = true
            },
        )
        for (c in MediaCategoryNames.displayOrder) {
            rows.add(
                FRow.Toggle(
                    MediaCategoryNames.label(c),
                    counts[c] ?: 0,
                    category == c && !playedOnly && !followedOnly,
                    false,
                ) {
                    category = c
                    playedOnly = false
                    followedOnly = false
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
            if (cur != null) {
                actions.add("播放「${cur.title}」（续播）" to { playWork(cur) })
                // ⛔ 刮削入口紧跟在播放后面：它是**对这一部作品**的动作，
                //    和「同步 / 备份」那种全局动作不是一类。
                actions.add("手动刮削「${cur.title}」" to { openScrape(cur) })
            }
            actions.add("同步（本地 ↔ 网盘）" to { doSync() })
            actions.add("上传备份到网盘" to { doUpload() })
            actions.add("从网盘恢复（覆盖本地）" to { confirmRestore() })
            // ⛔ 设置项放在这里（而不是只在作品墙上）：用户看到「刮不出东西」
            //    的瞬间，想找的就是这一项，让他先退回作品墙是白走一步。
            actions.add("刮削设置（TMDB Key / 反代 / 豆瓣 Cookie）" to { openScrapeSettings() })
            actions.add("返回作品墙" to { backToWorks() })
        } else {
            val cur = works.getOrNull(worksGrid.selectedItemPosition)
            if (cur != null) {
                // ⛔ 「简介页」排在「播放」前面：它是**默认**的卡片行为（OK），
                //    菜单里的顺序与按键习惯保持一致，用户才不会觉得菜单是另一套。
                actions.add("「${cur.title}」简介页 / 选集" to { openWork(cur) })
                actions.add("播放「${cur.title}」（续播）" to { playWork(cur) })
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
            // ⛔ 追剧的自动检查开关放在这里（而不是塞进「刮削设置」那一页）：
            //    它是**媒体库**的行为，用户想找它时看的就是这张菜单。三档循环
            //    的一颗，与上面「只看有海报：开/关」是同一种东西。
            actions.add(
                "追剧自动检查：${followAutoCheck.label}（OK 切换）" to { cycleFollowAutoCheck() },
            )
            // ⛔ 「扫描 / 清空」放在**显示设置之后、备份之前**：前四项是「看什么」，
            //    这三项是「库里有什么」，最后三项是「和电脑同步」。按这个顺序
            //    分组，用户扫一眼就知道该往哪找。
            // ⛔ 「检查追剧更新」放在**显示设置之后、扫描之前**：它是「库里有什么」
            //    那一组的第一个动作，而且是**轻**的那个 —— 只列在追那几部剧的
            //    目录（通常 1~5 个，秒级），与下面那个要跑几分钟的全盘扫描
            //    放在一起，用户一眼能看出该先试哪个。
            actions.add("⟳ 检查追剧更新（只查在追的剧）" to { checkFollow(force = true) })
            actions.add("重新扫描媒体库（网盘）" to { doScan() })
            actions.add("清空媒体库索引…" to { confirmWipe() })
            actions.add("同步（本地 ↔ 网盘）" to { doSync() })
            actions.add("上传备份到网盘" to { doUpload() })
            actions.add("从网盘恢复（覆盖本地）" to { confirmRestore() })
            // ⛔ 也放在作品墙上：想先配好 TMDB 再刮的人，不该被迫先进一部作品。
            actions.add("刮削设置（TMDB Key / 反代 / 豆瓣 Cookie）" to { openScrapeSettings() })
            // ⛔ **不 `finish()`**（与一级导航上那颗「文件列表」同一条红线）：
            //    媒体库是 App 的首页，`finish()` 掉之后从文件列表按返回就是
            //    **退出 App**，而用户以为只是「退回上一层」。
            actions.add("文件列表（网盘实时目录）" to {
                startActivity(Intent(this, BrowseActivity::class.java))
            })
        }

        showOverlay(titleText = "媒体库", labels = actions.map { it.first }) { index ->
            val act = actions.getOrNull(index) ?: return@showOverlay
            hideOverlay()
            act.second()
        }
    }

    // ------------------------------------------------------------------
    // 手动刮削
    // ------------------------------------------------------------------

    /**
     * 打开手动刮削页（豆瓣 / TMDB 双源，与 PC 端同一套）。
     *
     * ⛔ 用 `startActivityForResult` 而不是 `startActivity`：刮完这一页手上那个
     *    [currentWork] 就成了**过期快照** —— 标题 / 年份 / 海报 / 分类 / 简介 /
     *    类型全都被改过。不刷新的表现是「明明刮成功了，详情页还是旧的」，
     *    用户会以为刮削没生效，然后再刮一次。
     */
    private fun openScrape(w: Work) {
        val intent = Intent(this, ScrapeActivity::class.java)
            .putExtra(ScrapeActivity.EXTRA_WORK_KEY, w.key)
            .putExtra(ScrapeActivity.EXTRA_WORK_TITLE, w.title)
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQ_SCRAPE)
    }

    /** 刮削设置（TMDB Key / 两个反代地址 / 豆瓣 Cookie）。只读回显，不需要结果。 */
    private fun openScrapeSettings() {
        startActivity(Intent(this, ScrapeSettingsActivity::class.java))
    }

    @Deprecated("与 minSdk 21 对齐的旧式回调；androidx 的 registerForActivityResult 本工程没引。")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_SCRAPE && resultCode == RESULT_OK) refreshAfterScrape()
        // 从播放页回来：把当前这一部重读一遍，`■ NEW` 标签才会当场消失。
        //
        // ⛔ **不判 `resultCode`**：播放页没有 `setResult`，退出时 `resultCode`
        //    恒为 `RESULT_CANCELED`；而且用户可能按 Home 键离开、或播放页被
        //    系统低内存杀掉，那时连 `onDestroy` 都不一定跑完。已读回执在
        //    [play] 里**点击那一刻**就写好了，所以这里只需无条件重读。
        // ⛔ 也**不能**只判 `RESULT_OK`：那样这条分支永远不会进。
        if (requestCode == REQ_PLAYER) reloadCurrentItems()
    }

    /**
     * 刮削回来后**把这一页重新读一遍**。
     *
     * ⛔ 必须重读库，不能在客户端改手上的 `Work`：刮削动的是 `media_works`
     *    一整行，而且分类那一列走的是「override → genres → onlineId 结构证据
     *    → 保持原值」四级判定（见 [LibraryDb.updateWorkScrape]）。在 UI 层
     *    拼一个「差不多的新 Work」= 把同一套合并规则写第二遍，两边迟早不一致。
     *
     * ⛔ `posters.buildIndex()` 也必须重跑：刮削换海报产生的是**新文件名**
     *    （第二段是 URL 散列，新旧两张图是两个文件）。[PosterStore.fileFor]
     *    的 ① 靠 `poster_file` 回写能命中，但那是**本机刮的**才有；索引不重建
     *    的话，③ 那条给「PC 端刮的、随备份搬过来」的兜底路径会看不到新图。
     */
    private fun refreshAfterScrape() {
        val cur = currentWork ?: return
        status.text = "刷新「${cur.title}」…"
        Bg.run({
            posters.buildIndex()
            // ⛔ `workForDetail` 而不是 `workByKey`：头部元数据行读 `itemCount` /
            //    `seasonCount`，用存值会把并集口径的「13 集」打回「1 集」。
            db.workForDetail(cur.key)
        }) { fresh, err ->
            if (err != null) {
                status.text = "刷新失败：${err.message}（刮削可能已经生效，退回作品墙看看）"
                Log.w(TAG, "刮削后刷新失败：${cur.key}", err)
                return@run
            }
            // ⛔ 别写成 `fresh ?: run { … return@run }`：内层 `run { }` 会把
            //    `@run` 这个标签**遮住**，`return@run` 于是从内层 run 返回
            //    （返回 Unit），整句的类型退化成 `Any` —— 报错信息是
            //    「actual type is kotlin.Any, but Work? was expected」，
            //    和真正的毛病（标签被遮）看起来毫无关系。
            val w = fresh
            if (w == null) {
                status.text = "「${cur.title}」在库里找不到了"
                return@run
            }
            currentWork = w
            // 剧集列表本身没变（刮削不碰 `media_items`），只重画标题、简介页头部
            // 与动作胶囊 —— 后者要重画是因为「▶ 播放 / ▶ 续播」的文案与
            // `enabled` 都跟着 `currentWork` 走。
            title.text = "媒体库 / ${w.title}"
            itemsAdapter.notifyDataSetChanged()
            paintDetailHead()
            buildDetailActions()
            status.text = buildString {
                append("已更新：").append(w.title)
                w.year?.takeIf { it > 0 }?.let { append("（").append(it).append("）") }
                append(" · ").append(MediaCategoryNames.label(w.category))
                if (w.genres.isNotEmpty()) append(" · ").append(w.genres.take(3).joinToString("/"))
                if (posters.fileFor(w) == null) append(" · ⚠ 没有海报文件")
            }
            Log.i(
                TAG,
                "刮削后刷新：${w.key} → ${w.title}（分类=${w.category}，" +
                    "source=${w.source}，海报=${posters.fileFor(w)?.name ?: "无"}）",
            )
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
     *    （海报 / 简介 / 评分）由扫完之后的 [startAutoScrape] 接手。分开的理由
     *    见 [LibraryScanner] 的类文档。
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
        // ⛔ 「边扫边显示」的判据是**库里作品总数**（`Progress.works`），不是
        //    「本次扫到几个文件」—— 前者变了才说明作品墙该重画。
        //    放在这里当局部变量：它只在**这一次**扫描里有意义。
        var lastWorks = -1
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
                // 作品数变了 ⇒ 原地重画作品墙（**不动层级 / 焦点 / 简介页**）。
                if (p.works != lastWorks) {
                    lastWorks = p.works
                    runOnUiThread { refreshWorksInPlace() }
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
            // ⛔ 扫完**接着**刮 —— 用户的原话是「扫描完毕后需要自动启动刮削」。
            //    排在 `loadWorks` **之后**：先把新扫到的作品画出来再开始刮，
            //    否则用户是对着一面空墙等刮削。
            startAutoScrape()
        }
    }

    /**
     * 扫描途中的**原地刷新**：只换列表内容，**不动**层级 / 焦点 / 简介页。
     *
     * ⛔ **不能用 [loadWorks]** —— 它会 `level = Level.WORKS`、
     *    `currentWork = null`、把简介页那一整块 GONE 掉。扫描要跑几分钟，
     *    用户完全可能在这期间点进一部作品看简介；被**踢回作品墙**是纯粹的打扰。
     *    同理也不能走 [applyWorks]（它一样重置层级与可见性）。
     *
     * ⛔ 只在 [Level.WORKS] 下动列表：简介页的剧集列表是另一份数据
     *    （`db.itemsForWork`），跟作品总数没关系。
     */
    private fun refreshWorksInPlace() {
        if (level != Level.WORKS) return
        Bg.run({
            db.listWorks(
                sort = sort,
                playedOnly = playedOnly,
                category = category,
                years = years,
                genres = genres,
                scrapedOnly = scrapedOnly,
            )
        }) { list, err ->
            if (err != null || list == null) return@run
            // ⛔ 查回来时用户可能已经进了简介页 —— 那时列表归 `itemsList` 管。
            if (level != Level.WORKS) return@run
            val visible = if (posterOnly) list.filter { posters.fileFor(it) != null } else list
            // ⛔ 键序完全一致就**不要** `notifyDataSetChanged()`：它会重置
            //    `GridView` 的滚动位置，扫描期间每秒闪一下用户就没法翻墙了。
            //    「作品总数变了、但当前筛选下没变」是常态（新扫到的是别的分类）。
            if (visible.size == works.size &&
                visible.withIndex().all { (i, w) -> w.key == works[i].key }
            ) {
                return@run
            }
            val selected = worksGrid.selectedItemPosition
            works.clear()
            works.addAll(visible)
            worksAdapter.notifyDataSetChanged()
            // 尽量还原选中项：`notifyDataSetChanged` 保住的是**下标**，
            // 而列表变长之后同一个下标可能已经指向另一部作品。
            if (selected in visible.indices) worksGrid.setSelection(selected)
        }
    }

    /**
     * 「扫描后自动刮削」开着吗。
     *
     * ⛔ 判据是「设置项**不是** `"false"`」而不是「等于 `"true"`」：这一列在
     *    PC 端的旧库里**根本不存在**（那边默认关），而缺失在电视上应当读成
     *    「开」（理由见 [startAutoScrape]）。写成相等判断的话，从电脑同步过来
     *    的库会在电视上默认关掉 —— 用户根本不知道有这么个功能。
     *
     * ⛔ 会读库，**只能在后台线程调**。
     */
    private fun autoScrapeEnabled(): Boolean =
        db.settingsMap()[LibrarySettings.AUTO_SCRAPE_ON_SCAN] != "false"

    /**
     * 扫描后的**自动刮削**。
     *
     * ⛔ 默认**开**，与 PC 端相反（那边默认关，理由是豆瓣匿名额度只有约 10 个
     *    搜索词）。电视上用户没法像在电脑前那样随手点一下「刮削」，而
     *    「扫完什么都没有、还得自己一部部刮」是更糟的体验。想关掉的话把
     *    `auto_scrape_on_scan` 写成 `"false"`。
     *
     * ⛔ 没有可用的在线源（没配 Key / Cookie）时**直接跳过**：跑一遍只会得到
     *    「成功 0/N」加一句废话。凭证在「刮削设置」里配。
     *
     * ⛔ 匹配闸门（[com.cloudcine.tv.library.ScrapeMatch]）是**必须**的：自动刮削
     *    没有人盯着，没有闸门就会把「查询词带 2026、刮成 1994 年的片子」这类
     *    事故复制到整库。
     */
    private fun startAutoScrape() {
        if (scrapeCancel != null || scanCancel != null) return
        val cancel = LibraryScanner.Cancellation()
        scrapeCancel = cancel
        status.text = "刮削：准备中…"
        Bg.run({
            if (!autoScrapeEnabled()) {
                null
            } else {
                // ⛔ 每次都重新构造流水线，不能缓存：用户可能刚在「刮削设置」里
                //    填完 Cookie 就回来了，缓存实例拿的还是旧值。
                val pipeline = ScraperPipeline.fromSettings(db)
                if (pipeline.availableSources.isEmpty()) {
                    Log.i(TAG, "自动刮削：没有可用的在线源（未配 TMDB Key / 豆瓣 Cookie），跳过")
                    null
                } else {
                    val fetcher = PosterFetcher(LibraryPaths.posterDir(this), ScrapeHttp)
                    AutoScraper.forLibrary(db, pipeline, fetcher, cancel).run { p ->
                        runOnUiThread { if (scrapeCancel === cancel) status.text = p.text }
                    }
                }
            }
        }) { out, err ->
            scrapeCancel = null
            if (err != null) {
                Log.e(TAG, "自动刮削失败", err)
                finishJob("自动刮削失败：${err.message}")
                return@run
            }
            val o = out
            if (o == null) {
                finishJob("扫描完成")
                return@run
            }
            finishJob(o.message)
            Log.i(TAG, "自动刮削：${o.message}")
            // 标题 / 海报 / 简介 / 分类都可能变了 ⇒ 整墙重读（这一次走 `loadWorks`，
            // 因为它还要重算分面角标）。
            if (o.scraped > 0) loadWorks(o.message)
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
            followedOnly = false
            scrapedOnly = false
            years.clear()
            genres.clear()
            Log.i(TAG, "媒体库已清空")
            finishJob("媒体库已清空（网盘文件未动）")
            loadWorks("媒体库已清空 —— 菜单 → 重新扫描媒体库")
        }
    }

    private fun doSync() {
        if (!guard("同步")) return
        Bg.run({
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
    // 启动时问一句「网盘上有更新的备份，要不要同步」
    // ------------------------------------------------------------------

    /**
     * 每次启动 App 问一次：**网盘上有没有比本机更新的媒体库备份**。
     *
     * ## 它解决的是哪件事
     *
     * 「同步」原本只藏在 MENU 菜单里。用户在家里电脑上扫完库、刮好海报、
     * 标好进度，回到电视上打开 App —— 屏幕上还是上周那份索引，而他不会想到
     * 要去菜单里点一下「同步」。于是「跨端同步」这个能力等于不存在。
     *
     * ## ⛔ 四条约束（缺一条这个功能就会变成骚扰）
     *
     * 1. **只在「远程赢」时问** —— 判据是 [StartupSync.shouldPrompt]。
     *    本地更新是常态（看一集就变了），每次启动都问「要不要上传」＝每次启动烦一次。
     * 2. **只读**：探测走 [LibraryBackupService.probeRemote]，不传不覆盖；
     *    真正动手要用户点「立即同步」。
     * 3. **失败静默**：没网、网盘抽风、凭证过期 —— 一律只写日志。
     *    启动路径上弹一个错误框，比「这次没同步」更让人烦，而且他也没法处理。
     * 4. **不抢已经开着的界面**：探测在后台跑，回来时用户可能已经打开了菜单 /
     *    筛选面板 / 正在扫描。那时只记日志 —— 抢着弹会打断他，还会把 overlay
     *    那层状态搅乱（`showOverlay` 会直接盖掉当前那层）。
     */
    private fun probeRemoteBackupAtStartup() {
        // ⛔ 「一个进程一次」由 [StartupSync] 记着，零点在 MainActivity（每次从
        //    桌面点图标启动都会新建它）。放这里的话，从「文件列表」返回会**重建**
        //    本页（每个页面是独立 Activity），变成来回切一次弹一次。
        if (StartupSync.probedThisLaunch) return
        StartupSync.markProbed()

        if (!store.loggedIn) {
            Log.i(TAG, "启动探测：未登录，跳过")
            return
        }
        Bg.run({ service.probeRemote() }) { probe, err ->
            if (err != null) {
                Log.w(TAG, "启动探测失败（不打扰用户）：${err.message}")
                return@run
            }
            if (probe == null || !StartupSync.shouldPrompt(probe.action)) {
                Log.i(TAG, "启动探测：${probe?.action?.name}，无需打扰用户")
                return@run
            }
            if (busy || overlayVisible || filterVisible || scanCancel != null) {
                Log.i(TAG, "启动探测：界面正忙（${busyWhat.ifEmpty { "面板开着" }}），这次不打扰")
                return@run
            }
            askStartupSync(probe)
        }
    }

    /** 把探测结果摊成两行能看懂的说明，让用户决定要不要同步。 */
    private fun askStartupSync(probe: LibraryBackupService.Probe) {
        val latest = probe.latest
        val remote = probe.remoteManifest

        val title = buildString {
            append("网盘上有更新的媒体库备份\n\n")
            append(backupTime(remote?.createdAt ?: latest?.modifiedAtMs ?: 0L))
            append(" · ")
            append(latest?.let { formatSize(it.sizeBytes) } ?: "大小未知")
            append(" · 来自「")
            append(remote?.deviceName?.takeIf { it.isNotBlank() } ?: "未知设备")
            append("」\n")
            append(
                if (probe.action == SyncDecision.Action.restoreLocalEmpty) {
                    // 新机器 / 刚清空过：说清楚「本机是空的」，不然用户会以为
                    // 自己点错了什么。
                    "本机还没有媒体库。\n"
                } else {
                    "本机媒体库比它旧。\n"
                },
            )
            append("同步会用网盘上那份覆盖本机（本机还没上传的改动会丢失）")
        }
        Log.i(
            TAG,
            "启动探测：提示用户（${probe.action.name}，备份「${latest?.name}」，" +
                "本机库内容变更时间=${probe.localModifiedAtSec?.let { "${it}s" } ?: "无（空库）"}）",
        )
        showOverlay(
            titleText = title,
            // ⛔ 默认项是「暂不同步」：恢复是**破坏性**的（本地未上传的改动会没），
            //    光标默认落在危险项上时，一次误触就把库换掉了。
            labels = listOf("暂不同步", "立即同步"),
        ) { index ->
            hideOverlay()
            // ⛔ 走 `doSync()` 而不是 `doRestore()`：菜单里那个「同步」是同一个
            //    入口，它会在真正动手前**重新判一次方向**（探测到现在可能过了
            //    几秒，用户也可能刚在别的设备上又备份了一次）。
            if (index == 1) doSync()
        }
    }

    /**
     * 备份时间上屏：`10-07 13:20`。
     *
     * ⛔ 用**本机时区**显示。manifest 里存的是 UTC 毫秒，直接显示会让
     *    「今天下午刚备份的」看起来像「今早八点」—— 用户对不上自己的钟。
     */
    private fun backupTime(epochMillis: Long): String {
        if (epochMillis <= 0L) return "时间未知"
        return SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(epochMillis))
    }

    // ------------------------------------------------------------------
    // 追剧（schema v17）
    // ------------------------------------------------------------------

    /**
     * 进媒体库时的**静默**追更检查。
     *
     * ⛔ 两道闸门在**主线程**（它们都是内存判断，不读库）：
     *
     *   1. **未登录**：没登录时列目录必失败，白跑一次还写日志。
     *   2. **界面正忙**（扫描 / 刮削 / 面板开着）：与 `probeRemoteBackupAtStartup`
     *      同一套判断 —— 扫描本身就在写同一批表，插进去只会互相拖慢。
     *
     * ⛔ 第三道闸门（`follow_auto_check = off`）**不在这里** —— 它要读库，
     *    见 [checkFollow] 里的说明。
     * ⛔ 它也**不检查 `busy`**：`busy` 是「正在做某个用户发起的动作」，而追更
     *    检查恰恰是**用户没发起**的那个。用 `busy` 当闸门会让它永远撞在
     *    「刚点完别的」上，等于随机失效。
     */
    private fun maybeAutoCheckFollow() {
        if (!store.loggedIn) {
            Log.i(TAG, "追剧：未登录，跳过")
            return
        }
        if (scanCancel != null || scrapeCancel != null || filterVisible || overlayVisible) {
            Log.i(TAG, "追剧：界面正忙，这次不检查")
            return
        }
        checkFollow(force = false)
    }

    /**
     * 跑一次追更检查。
     *
     * @param force `true` = 用户手动点的（菜单 / 状态行）：无视节流窗口。
     *   它**不**代表「无视 `follow_auto_check = off`」是错的 —— 手动入口本来
     *   就该在关掉自动检查时仍然可用（那是用户明确要求了），所以 `force`
     *   会同时跳过开关与窗口两道闸门。
     *
     * ⛔ **静默失败**（红线 12）：失败只写状态行一句话 + 日志，不弹窗、
     *    不重试。电视上弹一个错误框会打断播放、抢焦点，而且用户也没法处理。
     * ⛔ **不写 `updated_at`**（红线 1）：检查的结果只落在 `follow_checked_at`
     *    与 `new_item_count` 两列上，而它们**不参与**同步判据
     *    `libraryModifiedAt()`。写 `updated_at` 会让本机永远「看起来更新」，
     *    下次同步无条件上传、把另一台设备刚看的进度盖掉。
     */
    private fun checkFollow(force: Boolean) {
        if (followCancel != null) {
            if (force) status.text = "正在检查追剧更新…"
            return
        }
        val cancel = LibraryScanner.Cancellation()
        followCancel = cancel
        // ⛔ 只有**用户点的那一次**才写状态行。静默检查在结果出来之前不该
        //    动任何东西 —— 每次进媒体库都闪一句「检查追剧更新…」是噪音，
        //    而且大多数时候它什么都不会发现。
        if (force) status.text = "检查追剧更新…"
        Bg.run({
            // ⛔ `follow_auto_check` 的判定放在**后台**，不是主线程的
            //    [maybeAutoCheckFollow] 里。两个理由：
            //      1. 它要读库，而主线程读 SQLite 是这个工程一直在避免的事；
            //      2. 缓存的那份 [followAutoCheck] 在**首帧那批读库还没回来**
            //         时仍是默认的 `ON_LAUNCH` —— 用户明明设了「关闭」，延迟
            //         1.5 秒的自动检查却会跑起来。这条竞态只在慢设备上出现，
            //         而它恰好是「设置项看起来不生效」的经典形态。
            val mode = FollowAutoCheck.parse(db.getSetting(LibrarySettings.FOLLOW_AUTO_CHECK))
            if (!force && mode == FollowAutoCheck.OFF) {
                Log.i(TAG, "追剧：自动检查已关闭，跳过")
                FollowUpdater.Outcome(skipped = true)
            } else {
                followUpdater.check(
                    force = force,
                    // 启动检查用 30 分钟的窗口（不是 `follow_auto_check` 的 6 小时）：
                    // 电视常被反复唤醒（待机 → 进媒体库），6 小时窗口会让绝大多数
                    // 唤醒都什么都不做，用户会觉得「这功能没在跑」。
                    windowSec = if (force) null else FollowAutoCheck.LAUNCH_WINDOW_SEC,
                    cancel = cancel,
                    onProgress = { p ->
                        // ⛔ 回主线程再碰 View。`onProgress` 是在后台线程回调的。
                        if (force) {
                            runOnUiThread {
                                if (followCancel === cancel) {
                                    status.text = "检查追剧更新 ${p.done}/${p.total}"
                                }
                            }
                        }
                    },
                )
            }
        }) { outcome, err ->
            // ⛔ 先清开关再动界面：`followCancel === cancel` 那几处判断都靠它。
            followCancel = null
            if (err != null) {
                // 静默失败：只有状态行 + 日志。**不回滚已经推进的水位线** ——
                // 那部分是真实检查过的（见 `FollowUpdater.check` 的 `@param cancel`）。
                Log.w(TAG, "追剧检查失败", err)
                if (force) status.text = "检查追剧更新失败：${err.message}"
                return@run
            }
            val o = outcome ?: return@run
            if (o.skipped) {
                Log.i(TAG, "追剧：未到节流窗口或已关闭，跳过")
                return@run
            }
            Log.i(TAG, "追剧：${o.message.ifEmpty { "无更新" }}")
            // ⛔ 状态行只在**有话说**时改写：`message` 为空串（无更新）时保持
            //    原来的「共 N 部」—— 每次进媒体库都写一句「没有更新」是最典型的
            //    噪音，而电视上的状态行本来就窄。
            if (o.message.isNotEmpty()) status.text = o.message
            // ⛔ 只有**真查出新集**才重读整页：`loadWorks` 会重建导航带 + 重排
            //    海报墙 + 抢焦点（用户可能已经走到简介页了，被踢回墙上很烦）。
            //    没更新时角标一个都没变，重读纯属浪费一次全量查询。
            //
            // ⛔ 站在简介页上时走 [reloadCurrentItems] 而**不是** `loadWorks`：
            //    2026-10-07 现场 —— 用户在这部剧的简介页上点「检查追剧更新」，
            //    提示「有 1 部剧更新了（共 2 集）」，而眼前这个列表一个都没多。
            //    库写对了，只是这一页没人通知它重读。
            if (o.hasNews) {
                if (level == Level.ITEMS) reloadCurrentItems() else loadWorks()
            }
        }
    }

    /**
     * 循环切换「追剧自动检查」：`关闭 → 启动时检查 → 每 6 小时检查 → 关闭`。
     *
     * ⛔ 三档做成**循环的一颗**而不是子菜单：与同一张菜单里的「只看有海报：开/关」
     *    是同一种东西，而菜单本来就有十来项，再开一层只会让光标走得更远。
     * ⛔ 写的是 [FollowAutoCheck.id]（`off` / `on_launch` / `every_6h`），不是
     *    `label` —— id 要跨端走（随 `.ccbak` 到电脑上），label 只是显示。
     */
    private fun cycleFollowAutoCheck() {
        val next = when (followAutoCheck) {
            FollowAutoCheck.OFF -> FollowAutoCheck.ON_LAUNCH
            FollowAutoCheck.ON_LAUNCH -> FollowAutoCheck.EVERY_6H
            FollowAutoCheck.EVERY_6H -> FollowAutoCheck.OFF
        }
        // ⛔ 先改内存里的真源再落库：菜单上的文案读的就是它，而写库是异步的。
        followAutoCheck = next
        status.text = "追剧自动检查：${next.label}"
        Bg.run({ db.setSetting(LibrarySettings.FOLLOW_AUTO_CHECK, next.id) }) { _, err ->
            if (err != null) {
                Log.w(TAG, "追剧自动检查设置写库失败", err)
                status.text = "设置保存失败：${err.message}"
            }
        }
    }

    /**
     * 开 / 关当前这部作品的追剧。
     *
     * ⛔ 这是**用户显式动作** = 真实内容变更 ⇒ `LibraryDb.setFollowed` **要**写
     *    `updated_at`（该跨端同步：电脑上追了这部，电视上打开也该有）。
     *    与 [checkFollow] 恰好相反（红线 1）。
     *
     * ⛔ 开关之后**必须重读这一行**（不能在客户端改手上的 `Work`）：
     *    `setFollowed` 一次动 4 列（`followed` / `follow_started_at` /
     *    `follow_checked_at` / `new_item_count`），在 UI 层拼一个「差不多的新
     *    Work」等于把同一套规则写第二遍 —— 与 [refreshAfterScrape] 同一条理由。
     */
    private fun toggleFollow(w: Work) {
        val next = !w.followed
        status.text = if (next) "开启追剧…" else "取消追剧…"
        Bg.run({ db.setFollowed(w.key, next); db.workForDetail(w.key) }) { fresh, err ->
            if (err != null) {
                Log.e(TAG, "追剧开关失败：${w.key}", err)
                status.text = "追剧设置失败：${err.message}"
                return@run
            }
            val nw = fresh ?: return@run
            currentWork = nw
            // 剧集列表不用重查（`setFollowed` 不碰 `media_items`），但**行首的
            // NEW 标签**依赖 `followStartedAt` —— 刚开启追剧时基线是「现在」，
            // 已有的集都不算新，所以必须重画一次列表把标签清掉。
            itemsAdapter.notifyDataSetChanged()
            buildDetailActions()
            status.text = if (next) {
                "已开启追剧 —— 网盘上有新集时会在这里提醒"
            } else {
                "已取消追剧「${nw.title}」"
            }
            Log.i(TAG, "追剧：${w.key} → ${if (next) "开" else "关"}")
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

        // ── 退出确认框：**最优先**，连扫描 / 刮削的「停下」都要让位 ──────────
        //
        // ⛔ `if (!down) return true` 这一行不能省：框是在返回键的 **DOWN** 上
        //    弹出来的，紧接着的那个 UP 如果不吞掉，会第二次进这里、被框当成
        //    「取消」⇒ 框刚画出来就自己没了（屏幕上只闪一下）。OK 上踩过同一个坑。
        if (exitDialog.isShowing) {
            if (!down) return true
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP,
                KeyEvent.KEYCODE_DPAD_DOWN,
                KeyEvent.KEYCODE_DPAD_LEFT,
                KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                KeyEvent.KEYCODE_BACK,
                KeyEvent.KEYCODE_MENU,
                KeyEvent.KEYCODE_ESCAPE,
                -> return exitDialog.onKey(event.keyCode)
                // ⛔ 音量 / 电源 / HDMI 这类键放行：框开着的时候用户照样要能调音量。
                else -> return super.dispatchKeyEvent(event)
            }
        }

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

        // ⛔ 自动刮削同理：几百部作品可能还要跑好几分钟，而 `guard` 同样挡住了
        //    其它动作。没有这个出口，用户只能杀应用。
        // ⛔ 排在扫描后面：两段不会同时跑（`startAutoScrape` 在扫描结束之后才
        //    被调用），所以顺序在这里只是为了读起来顺。
        scrapeCancel?.let { cancel ->
            if (down && event.keyCode == KeyEvent.KEYCODE_BACK) {
                cancel.cancel()
                status.text = "正在停止刮削…（已刮到的会保留）"
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

        // ── 返回键：统一「逐层往上退」（见 [handleBack]）─────────────────
        //
        // ⛔ **必须排在这里、排在下面所有焦点分支之前**。下面每一支的 `when`
        //    末尾都是 `else -> return super.dispatchKeyEvent(event)`，返回键一旦
        //    落进去就会被系统当成「退出 Activity」直接关掉这一页 —— 而媒体库
        //    这一页就是 App 的首页，等于一按返回就退出 App。
        // ⛔ 又必须排在 `filterVisible` / `overlayVisible` **之后**：那两个是覆盖层，
        //    返回键在它们上面的语义是「关掉这一层」，不是「往上退一层页面」。
        // ⛔ DOWN 与 UP 都吞：只吞 DOWN 的话 UP 会继续走系统默认路径。
        if (event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (down) handleBack()
            return true
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
                // ⛔ 返回键**不在这里**：它由上面统一的 [handleBack] 处理。
                //    这一支是「方向键往下走一层」，返回键是「往上退一层页面」，
                //    两件事的语义不同，混在一起写就会出现「按返回往下走」。
                KeyEvent.KEYCODE_DPAD_DOWN -> if (down) focusGrid()
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
                // ⛔ 返回键同上，由 [handleBack] 统一处理。
                KeyEvent.KEYCODE_DPAD_DOWN -> if (down) focusBar()
                KeyEvent.KEYCODE_MENU -> if (down) openMenu()
                // ⛔ 不认识的键放行（音量、电源、HDMI…），别把遥控器全吞了。
                else -> return super.dispatchKeyEvent(event)
            }
            return true
        }

        // ── 简介页动作行拿到光标：←→ 移、OK 执行、↓ 到排序胶囊、↑/返回 回作品墙 ──
        // ⛔ 必须排在 `itemsSortFocused` **之前**：动作行在屏幕上就在排序胶囊上面，
        //    两层不会同时为真，但顺序写反的话（万一标志位漏清）↑↓ 会互相打架。
        // ⛔ 只在 `Level.ITEMS` 下有意义：作品墙那一层这一行是 GONE。
        if (actionsFocused) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> if (down) moveActions(-1)
                KeyEvent.KEYCODE_DPAD_RIGHT -> if (down) moveActions(1)
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> if (down) applyAction()
                KeyEvent.KEYCODE_DPAD_DOWN -> if (down) focusItemsSort()
                // ⛔ 动作行是最上面那一层，再往上没有东西了 ⇒ 与返回键同义（回作品墙）。
                //    返回键本身由 [handleBack] 统一处理，走到那儿同样是回作品墙。
                KeyEvent.KEYCODE_DPAD_UP -> if (down) backToWorks()
                KeyEvent.KEYCODE_MENU -> if (down) openMenu()
                // ⛔ 不认识的键放行（音量、电源、HDMI…），别把遥控器全吞了。
                else -> return super.dispatchKeyEvent(event)
            }
            return true
        }

        // ── 剧集列表的排序胶囊拿到光标：←→ 移光标、OK 生效、↓/返回 回列表、↑ 到动作行 ──
        // ⛔ 只在 `Level.ITEMS` 下有意义：作品墙那一层没有这个胶囊。放在「海报墙 /
        //    剧集列表」通用分支**之前**，优先吃掉这些键，避免它们泄漏到底下的列表。
        if (itemsSortFocused) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> if (down) moveItemsSort(-1)
                KeyEvent.KEYCODE_DPAD_RIGHT -> if (down) moveItemsSort(1)
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> if (down) applyItemsSort()
                // ⛔ 返回键同上，由 [handleBack] 统一处理 —— 那里是「回作品墙」，
                //    不是「往下走一层」：排序胶囊上按返回该退出这一页。
                KeyEvent.KEYCODE_DPAD_DOWN -> if (down) focusItemsList()
                // ⛔ 排序胶囊上面**还有动作行**，所以 ↑ 是「再上一层」而不是
                //    「回作品墙」。只有动作行上再按 ↑ 才退出这一页。
                KeyEvent.KEYCODE_DPAD_UP -> if (down) focusDetailActions()
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
                // 剧集列表首行 ↑ 进排序胶囊（胶囊在列表上方，且只在 ITEMS 层存在）。
                if (down && level == Level.ITEMS && itemsList.selectedItemPosition == 0) {
                    focusItemsSort()
                    return true
                }
            }
            KeyEvent.KEYCODE_MENU -> {
                if (down) openMenu()
                return true
            }
            // ⛔ 返回键不在这里 —— 它由上面统一的 [handleBack] 处理。原先这里
            //    只挡 `Level.ITEMS`，作品墙上的返回会掉到 `super` 去 ⇒
            //    系统直接关掉本页（= 退出 App）。
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * 返回键：**逐层往上退**，退到最底下再问一句「要退出云影吗」。
     *
     * ## 层级（从高到低）
     *
     * ```
     *   ① 作品简介页（Level.ITEMS）    → 作品墙，光标**回到进来时那一张卡**
     *   ② 作品墙 + 状态行拿焦点         → 导航栏
     *   ③ 作品墙 + 海报墙拿焦点         → 导航栏，光标对准**当前生效的那一颗**
     *   ④ 导航栏 + 非「全部」           → 切到「全部」，光标停在「全部」上
     *   ⑤ 导航栏 + 已经是「全部」       → 退出确认框 → 退出 App
     * ```
     *
     * 例：焦点在「动漫」下的某张卡 → 返回 → 停在「动漫」胶囊上 → 返回 →
     * 停在「全部」胶囊上 → 返回 → 弹退出确认。
     *
     * ⛔ 扫描中 / 刮削中、筛选面板、菜单**不在这里** —— 它们是长任务或覆盖层，
     *    在 [dispatchKeyEvent] 里各自更靠前就被吃掉了（返回键在那儿的语义是
     *    「停下」/「关掉这一层」）。
     *
     * ⛔ ③ 是「一步跳到导航栏」，**不经过状态行**：状态行是工具条（排序 / 筛选），
     *    不是一层页面。用户要动排序才按 ↑ 上去，而返回键的语义是「离开这个列表」。
     * ⛔ ④ 是**一次退干净**：分类 / 最近播放 / 追剧 / 筛选 / 只看有海报一起退掉。
     *    逐条退会让用户按四五次才回到首页，而每个中间态都是他自己都没印象的列表。
     */
    private fun handleBack() {
        // ⛔ 这一行是**排障的唯一线索**：电视上没有可用的 UI 快照（`uiautomator`
        //    拿不到焦点态），遥控器行为出问题时只能靠它反推「当时在哪一层」。
        Log.i(
            TAG,
            "返回键：level=$level tabs=$tabsFocused bar=$barFocused " +
                "分类=${category ?: "全部"} 最近播放=$playedOnly 追剧=$followedOnly " +
                "只看有海报=$posterOnly 筛选=$selectedFilterCount",
        )
        // ① 作品简介页 → 作品墙（光标还原到进来时那张卡）
        if (level == Level.ITEMS) {
            backToWorks()
            return
        }
        // ② 状态行 → 导航栏
        if (barFocused) {
            backToNav()
            return
        }
        // ③ 海报墙 → 导航栏
        if (!tabsFocused) {
            backToNav()
            return
        }
        // ④ 已经在导航栏上，但还没回到「全部媒体」→ 一次退干净
        if (!isAtHome()) {
            backToAll()
            return
        }
        // ⑤ 已经是首页 —— 问一句再退
        exitDialog.show(title = "要退出云影吗？", confirmLabel = "退出")
    }

    /**
     * 焦点上移到导航栏，光标对准**当前生效的那一颗**。
     *
     * ⛔ `buildNav()` 必须在 `focusTabs()` **之前**调：它只在 `tabsFocused == false`
     *    时才把光标同步到「当前生效项」（见它的文档）。顺序反了的话，`focusTabs()`
     *    里那次 `paintTabs()` → `buildNav()` 会因为 `tabsFocused` 已经是 `true`
     *    而跳过同步，光标停在上一次的位置 —— 现象是「返回之后高亮跳到别的分类上」。
     */
    private fun backToNav() {
        buildNav()
        focusTabs()
    }

    /**
     * 是不是「首页（全部媒体）」—— 没分类、没视图、没筛选。
     *
     * ⛔ **排序不算**：它是用户对「同一个列表怎么排」的偏好，不是「在看哪个列表」。
     *    把排序也算进来的话，用户改一次排序就再也退不到首页了（而首页又正是
     *    唯一能弹退出确认的地方 ⇒ 返回键直接失效）。
     * ⛔ **「只看有海报」算**：它和筛选一样会把列表截短，用户看到的就是另一个列表。
     */
    private fun isAtHome(): Boolean =
        category == null &&
            !playedOnly &&
            !followedOnly &&
            !posterOnly &&
            selectedFilterCount == 0

    /**
     * 退回「全部媒体」：清掉分类 / 视图 / 筛选 / 只看有海报，**光标停在「全部」上**。
     *
     * ⛔ 与「把焦点收回海报墙」**刻意不同**：用户此刻就在导航栏上，返回键要的是
     *    「换一个分类」。焦点一旦被抢到海报墙，用户再按一次返回的落点就不是
     *    他以为的那一层（会先去海报墙、再回导航栏，凭空多两次）。
     */
    private fun backToAll() {
        category = null
        playedOnly = false
        followedOnly = false
        posterOnly = false
        scrapedOnly = false
        years.clear()
        genres.clear()
        // ⛔ 「全部」永远是第一颗胶囊（见 `buildNav` 的添加顺序），光标直接落那儿。
        // ⛔ 必须在 `loadWorks()` **之前**设：`applyWorks` 里会 `paintTabs()`，
        //    而 `buildNav()` 在 `tabsFocused == true` 时**不会**重算光标位置。
        navIndex = 0
        // ⛔ 状态行的控件数会随筛选一起变少（「清空筛选」会消失），光标跟着归零，
        //    否则它会停在一个已经不存在的下标上（那一行会「没有光标」）。
        barIndex = 0
        loadWorks()
    }

    /**
     * OK：作品墙 → **进简介页**；剧集列表 → 播选中的那一集。
     *
     * ⛔ 简介页上的 OK 不走这里 —— 那两行胶囊（动作 / 排序）在
     *    [dispatchKeyEvent] 里就被吃掉了，根本到不了这个分支。
     */
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
     * 卡片：海报 + 片名 + 副标题（类型 · 年份）。
     *
     * ## ⛔ 为什么复用 `convertView` 时要按**下标**取子控件
     *
     * `GridView` 的回收视图就是同一个 `LinearLayout`，子控件顺序在
     * [buildCard] 里定死（`posterBox` 在下标 0，片名在下标 1，副标题在下标 2）。
     * 用 `getChildAt(0..n)` 取比自己找 `tag` 快，
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
            // ⛔ 更新角标是**第 4 个子控件（下标 3）**，见 [buildCard] 的追加顺序。
            //    加它的时候必须加在**末尾**：`getChildAt` 全是按下标取的，插在
            //    中间会让上面那行 `getChildAt(2)` 拿到更新角标，评分就画到它上面
            //    —— 而且不报错（红线 9）。
            val updateBadge = posterBox.getChildAt(3) as TextView
            val titleView = card.getChildAt(1) as TextView
            val metaView = card.getChildAt(2) as TextView

            // 海报高度按卡片宽度的 2:3 算 —— 每张卡片都重新设一次，
            // 因为 `cardW` 可能在旋转/换屏后变过。
            val posterH = cardW * 3 / 2
            posterBox.layoutParams = LinearLayout.LayoutParams(cardW, posterH)

            val file = posters.fileFor(w)
            val bmp = file?.let { posters.cached(it) }
            if (bmp != null) {
                // ⛔ 圆角在 drawable 层做：包裹成 `RoundedPosterDrawable`，缩放也不丢角。
                image.setImageDrawable(RoundedPosterDrawable(bmp, dp(8).toFloat()))
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
                } else {
                    // 本地一个文件都没有 ⇒ 未刮削的作品：去拉网盘自带的缩略图
                    // （见 [fetchCloudCover] 的文档）。下好之后它会自己重画。
                    fetchCloudCover(w)
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

            // 更新角标：只在真有新集时出现。
            //
            // ⛔ 判据是 `newItemCount > 0`，**不是** `followed`：追了但没更新时
            //    海报上不该有任何东西（那只是「我在追」，不是「有东西可看」）。
            //    用户清掉角标（进过简介页）之后它也会自己消失。
            // ⛔ 文案是 `+N` 而不是「更新 N」：一格海报只有百来像素宽，
            //    「更新」两个字会把数字挤没（PC 端横屏宽，那边写全称）。
            if (w.newItemCount > 0) {
                updateBadge.text = "+${w.newItemCount}"
                updateBadge.visibility = View.VISIBLE
            } else {
                updateBadge.visibility = View.GONE
            }

            // ⛔ 不画续播进度条：用户明确说卡片上画进度条不好看，信息要精简
            //    （只留 名称 / 类型 / 年份）。进度只在剧集列表行里表达。

            titleView.text = w.title
            metaView.text = w.cardMeta

            // ── 焦点效果：**只突出选中的那张，绝不在海报上画任何框** ─────
            //
            // ⛔ 之前两版都犯了同一个错：给海报加「边框/光晕/底色」—— 用户明
            //    确反馈过两次「丑」。这一次彻底不动背景：
            //    选中 = 放大 1.1 + 抬升阴影 + 标题/副标题变品牌色；
            //    非选中 = 海报原样（圆角由海报自己的 `clipToOutline` 提供）；
            //    整面墙始终是干净的海报，焦点靠**大小跳变**一眼可辨。
            //
            // ⛔ 海报 alpha 始终满亮度：之前会压暗其余几张做对比度，用户嫌「所
            //    有卡片都变暗」，这次所有卡都是亮的。
            val gridFocused = worksGrid.isFocused
            val selected = gridFocused && worksGrid.selectedItemPosition == position
            image.alpha = 1f
            placeholder.alpha = 1f
            badge.alpha = 1f
            updateBadge.alpha = 1f
            val s = if (selected) 1.1f else 1f
            // ⛔ 卡片整体放大（`scaleX/Y`）；圆角靠 `RoundedPosterDrawable`（drawable
            //    层），不靠 `clipToOutline` —— 后者在缩放态下裁切会失效。
            card.scaleX = s
            card.scaleY = s
            // ⛔ 抬升阴影。`convertView` 复用时旧卡片的 elevation 不会自己回 0，
            //    所以选中=8dp、其它=0 必须**每帧重设**（不能只在选中那次设）。
            card.elevation = if (selected) dp(8).toFloat() else 0f
            titleView.setTextColor(if (selected) BRAND_TINT else Color.WHITE)
            metaView.setTextColor(if (selected) 0xFFB9B2FF.toInt() else MUTED)
            return card
        }
    }

    /**
     * 自带圆角的海报 drawable。
     *
     * ⛔ 圆角在 **drawable 层**做（不是 `View.clipToOutline`）：drawable 自己按
     *    `bounds` 裁成圆角矩形来画 bitmap。ImageView 无论怎么 `scaleX/Y` 缩放，
     *    圆角都跟着 drawable 的 `bounds` 一起缩放 —— 聚焦放大时四角照样是圆的。
     *    这是修「放大后圆角没了」最稳的办法：实测 `clipToOutline` 在缩放态下
     *    裁切会失效，烘焙进 bitmap 的圆角也不稳定（实机像素采样验证过）。
     *
     * ⛔ 用 `BitmapShader` 画而不是 `canvas.drawBitmap`：drawable 的 `bounds`
     *    由 ImageView 的 `CENTER_CROP` 决定，尺寸未必等于 bitmap 像素尺寸，
     *    shader 会把 bitmap 自动映射铺满 `bounds`，不会出现画偏/画不满。
     */
    private class RoundedPosterDrawable(
        private val bitmap: Bitmap,
        private val radiusPx: Float,
    ) : Drawable() {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        private val path = Path()

        override fun onBoundsChange(bounds: Rect) {
            path.reset()
            path.addRoundRect(RectF(bounds), radiusPx, radiusPx, Path.Direction.CW)
        }

        override fun draw(canvas: Canvas) {
            canvas.save()
            canvas.clipPath(path)
            canvas.drawPaint(paint)
            canvas.restore()
        }

        override fun setAlpha(alpha: Int) {
            paint.alpha = alpha
        }

        override fun setColorFilter(colorFilter: ColorFilter?) {
            paint.colorFilter = colorFilter
        }

        @Deprecated("Deprecated in Java")
        override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

        override fun getIntrinsicWidth(): Int = bitmap.width
        override fun getIntrinsicHeight(): Int = bitmap.height
    }

    private fun buildCard(): LinearLayout {
        // ⛔ 圆角在 **drawable 层**做（见 `RoundedPosterDrawable`）：海报 bitmap 被
        //    包成一个自带圆角的 drawable，ImageView 怎么缩放、角落都圆。不靠
        //    `clipToOutline`（缩放态下裁切会失效，表现为「放大后圆角没了」），
        //    也不烘焙进 bitmap（实测烘焙出的圆角不稳定）。
        val radius = dp(8)
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // ⛔ 底部留一点：卡片圆角会把最底下的文字下角切掉。
            setPadding(0, 0, 0, dp(6))
        }

        val posterBox = FrameLayout(this)
        val image = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
        }
        posterBox.addView(image, FrameLayout.LayoutParams(MATCH, MATCH))
        posterBox.addView(
            TextView(this).apply {
                setTextColor(0xFF4B5563.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 34f)
                gravity = Gravity.CENTER
                // ⛔ 占位块也用圆角 drawable（drawable 形状本身是圆的，缩放不丢角）。
                background = GradientDrawable().apply {
                    cornerRadius = radius.toFloat()
                    setColor(0xFF232833.toInt())
                }
            },
            FrameLayout.LayoutParams(MATCH, MATCH),
        )
        // 评分角标。样式**逐项对标 PC 端海报墙**（`library_page.dart` 的
        // `TagChip(label: rating, icon: Icons.star_rounded, color: AppTheme.warn,
        // filled: true)`），五项一一对应：
        //
        // | | PC 端 | 这里 |
        // |---|---|---|
        // | 位置 | `left: 6, bottom: 6` | `BOTTOM or START` + 6dp |
        // | 底 / 字 | `warn` @92% / `bg` | [RATING_BG] / [RATING_FG] |
        // | 圆角 | `5`（卡片宽 172） | `dp(5)` |
        // | 内边距 | `h6 v2.5` | `h7 v3` |
        // | 字重 | `w600` | `BOLD` |
        //
        // ⛔ **落在左下角**，不是右上角。右上角是「未刮削」标签的位置
        //    （PC 端那里放的是 `文件名` 那枚灰标），两枚都挤在右上会互相打架。
        // ⛔ 圆角从 `dp(10)`（药丸）收到 `dp(5)` 是这次「好看」的主要来源：
        //    药丸形状在小尺寸下像**按钮**，会让人以为点得动；小圆角才像标签。
        posterBox.addView(
            TextView(this).apply {
                setTextColor(RATING_FG)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(dp(7), dp(3), dp(7), dp(3))
                background = GradientDrawable().apply {
                    cornerRadius = dp(5).toFloat()
                    setColor(RATING_BG)
                }
            },
            FrameLayout.LayoutParams(WRAP, WRAP).apply {
                gravity = Gravity.BOTTOM or Gravity.START
                bottomMargin = dp(6)
                leftMargin = dp(6)
            },
        )
        // 更新角标（追剧）。**必须加在最后**，见 [WorksAdapter.getView] 的说明 ——
        // 那是红线 9：`posterBox` 的子控件全是按下标取的，插在中间会把评分
        // 角标顶到别的位置上，而且不报错。
        //
        // 四个角的占用：左下 = 评分，**左上 = 更新角标**，右下 = 无，右上 = 无。
        // ⛔ 选左上而不是右上：PC 端右上角是「未刮削」的灰标（这里没画），
        //    而且左上离左下最远，两枚角标不会在同一只眼睛里打架。
        // ⛔ 样式与评分角标**同尺寸不同色**（品牌色实心 / 深色字）：同色的话
        //    两枚小方块在沙发距离下分不出哪个是「★ 8.7」哪个是「+2」。
        posterBox.addView(
            TextView(this).apply {
                setTextColor(0xFF1A1533.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(dp(7), dp(3), dp(7), dp(3))
                background = GradientDrawable().apply {
                    cornerRadius = dp(5).toFloat()
                    setColor(BRAND_TINT)
                }
            },
            FrameLayout.LayoutParams(WRAP, WRAP).apply {
                gravity = Gravity.TOP or Gravity.START
                topMargin = dp(6)
                leftMargin = dp(6)
            },
        )
        card.addView(posterBox)

        // ⛔ 不要播放进度条：用户明确说「卡片上画进度条不好看」，且信息要
        //    精简（只留 名称 / 类型 / 年份）。进度在剧集列表行里仍有表达。
        // ⛔ 片名上留白 8dp → 4dp：每张卡省 8px，一行 8 张就是 8px × 2 行 ——
        //    这 16px 正好是「第二行能不能完整露出来」的胜负手（实测只差几个像素）。
        card.addView(TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(0, dp(4), 0, 0)
        })
        card.addView(TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        return card
    }

    // ⛔ 这里曾经有个 `cardBackground(selected)`：选中 = 紫底 + 2dp 亮紫描边。
    //    已删除 —— 海报卡片的焦点效果改成**纯明度 + 缩放**（见 `WorksAdapter.getView`），
    //    用户明确说过「海报焦点时还是有边框样式，太丑了」。
    //    剧集列表行仍然用 `BRAND_SELECT`（那里是文字行，底色是它唯一的选中线索）。

    // ------------------------------------------------------------------
    // 剧集列表渲染
    // ------------------------------------------------------------------

    /**
     * 剧集行主标题：新集时在**行首**加一个品牌色的「■ NEW」。
     *
     * ## 为什么用 `SpannableString` 而不是再插一个 View
     *
     * 这一行是 `[列(标题/副标题)] [集号] [进度] [时间]` 四段，全是按下标取的
     * （`row.getChildAt(0..3)`）。在中间插一个「NEW」小方块要把后面三段全部
     * 重新编号 —— 而这类改动**不会报错**，只会让进度列画到时间列上。
     * 拼进标题的 `SpannableString` 一行搞定，且 `ellipsize` 照常生效。
     *
     * ⛔ 前缀只染色 + 加粗，**不改整行的字号**：标题 18sp 是「文件名是重点」
     *    这条口径撑起来的（见 [ItemsAdapter] 的表），把整行放大或加底色会
     *    让 12 集里有 2 集看起来像另一种东西。
     * ⛔ 前缀后面**留两个空格**：中文/方块字符与英文/数字之间不留白时，
     *    沙发距离下会连成一片（「■ NEW黑亚当…」）。
     */
    private fun newEpisodeTitle(text: String, isNew: Boolean): CharSequence {
        val prefix = WorkDetailFormat.newEpisodePrefix(isNew)
        if (prefix.isEmpty()) return text
        return SpannableString(prefix + text).apply {
            setSpan(
                ForegroundColorSpan(BRAND_TINT),
                0,
                prefix.length,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
            setSpan(
                StyleSpan(Typeface.BOLD),
                0,
                prefix.length,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
        }
    }

    /**
     * 作品简介页的「文件」列表 —— 一行 = 库里的一条文件。
     *
     * ## 一行五样东西（从左到右）
     *
     * | 位置 | 内容 | 为什么 |
     * |---|---|---|
     * | 主标题 18sp 白 | **文件名**（去扩展名，[EpisodeLabels.fileLabel]），新集时行首带品牌色「■ NEW」 | ⛔ 不能用 `displayTitle`：它优先返回**作品标题**，整列会印成同一句话（「黑亚当」× 12），剧集之间、同一部电影的多个版本之间都分不出来 |
     * | 副标题 13sp 灰 | 分辨率 · 大小 | ⛔ 进度不在这里 —— 它单独占一列 |
     * | 标签 13sp 品牌色 | `S01E03`（集号解析得出时才画） | 一眼扫集号，不用在文件名里找 |
     * | 进度 13sp 固定列 | `62%` / `—`（历史**最大**位置占比） | 竖着扫一眼看出哪几集看过；⛔ 不是续播点（看完被清成 NULL） |
     * | 时间 13sp 右对齐 | **网盘文件的修改时间**（相对时间） | 与 PC 端 `ModifiedTimeColumn` 同口径；⛔ 单位已是毫秒，别再 ×1000 |
     *
     * ⛔ 2026-10-07 用户原话：「文件列表应该重点凸显的是文件名，而不是全部都是
     *    媒体名，否则剧集列表都是媒体名，看起来体验非常不好」—— 当时这一行写的是
     *    `entry.displayTitle`，于是 12 集全叫「黑亚当」。
     */
    private inner class ItemsAdapter : BaseAdapter() {
        override fun getCount() = items.size
        override fun getItem(position: Int) = position.toLong()
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            // ⛔ **懒加子 View**：首屏 convertView 是 null，这一行一个子 View 都
            //    没有，直接 `row.getChildAt(0) as LinearLayout` 必崩（旧写法的坑）。
            //    改成「没有就现建并 addView」，与 `BrowseActivity.EntryAdapter` 同一路。
            val row = (convertView as? LinearLayout) ?: LinearLayout(this@LibraryActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(GRID_PAD_DP), dp(12), dp(GRID_PAD_DP), dp(12))
            }
            val column = row.getChildAt(0) as? LinearLayout ?: LinearLayout(this@LibraryActivity).apply {
                orientation = LinearLayout.VERTICAL
                // ⛔ 占满除「标签 / 时间」之外的剩余宽度：文件名那一列才能随屏伸缩。
                layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f)
                row.addView(this)
            }
            val line1 = column.getChildAt(0) as? TextView ?: TextView(this@LibraryActivity).apply {
                setTextColor(Color.WHITE)
                // ⛔ 17 → 18sp：这一行现在是**文件名**（唯一能把 12 集区分开的信息），
                //    比副标题大 5sp 才撑得起「重点」。再多就挤掉列表行数了。
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                column.addView(this)
            }
            val line2 = column.getChildAt(1) as? TextView ?: TextView(this@LibraryActivity).apply {
                setTextColor(MUTED)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                column.addView(this)
            }
            val tag = row.getChildAt(1) as? TextView ?: TextView(this@LibraryActivity).apply {
                setTextColor(BRAND_TINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                gravity = Gravity.CENTER
                setPadding(dp(10), 0, dp(10), 0)
                layoutParams = LinearLayout.LayoutParams(WRAP, WRAP)
                row.addView(this)
            }
            // 播放进度列：**单独一列**、固定宽度、右对齐，只写百分比（`62%`）。
            // ⛔ 读的是历史最大位置（[EpisodeLabels.progressPercent]），不是续播点 ——
            //    看完的那一集续播点会被清成 NULL，用它的话「看过没有」永远显示不出来。
            // ⛔ 没有进度时写 `—` 而不是藏起来：这一列的价值就在于**竖着扫一眼**
            //    看出哪几集看过，列时有时无的话就没法扫了（与时间列同一规矩）。
            val progress = row.getChildAt(2) as? TextView ?: TextView(this@LibraryActivity).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                gravity = Gravity.END
                maxLines = 1
                layoutParams = LinearLayout.LayoutParams(dp(PROGRESS_COL_DP), WRAP)
                row.addView(this)
            }
            // 修改时间列：与 PC 端 `ModifiedTimeColumn` 同一口径 —— 固定宽度、
            // 右对齐、显示相对时间（`3 天前`），`null`/`0` 显示 `—`。
            val time = row.getChildAt(3) as? TextView ?: TextView(this@LibraryActivity).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                gravity = Gravity.END
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                layoutParams = LinearLayout.LayoutParams(dp(TIME_COL_DP), WRAP)
                row.addView(this)
            }

            // ⛔ 别把这个局部变量叫 `it`：下面 `?.let { … }` 的隐式参数也叫 `it`，
            //    两层同名会让「这行用的是哪个」纯靠规则推断，读代码时极易看错。
            val entry = items[position]
            tag.text = entry.episodeTag ?: ""
            tag.visibility = if (entry.episodeTag == null) View.GONE else View.VISIBLE
            // ⛔ 主标题是**文件名**（去扩展名），不是 `entry.displayTitle` ——
            //    后者优先返回**作品标题**，于是整列印的是同一句话（「黑亚当」× 12），
            //    剧集之间、同一部电影的多个版本之间**完全分不出来**。
            //    口径与播放页 OSD 的「选集」同一支（[EpisodeLabels.fileLabel]），
            //    也是 PC 端详情页 `rowLabel(RowLabelStyle.fileName)` 的口径。
            // ⛔ 但**不**照抄 PC 的「剧名-文件名」前缀：那一行在电视上只有一行、
            //    尾部省略，长剧名会把真正要看的文件名挤出屏幕外。
            //
            // 行首的「■ NEW」是**追剧以来才入库、且从没播过**的那几集
            // （判据 `Work.isNewSinceFollow`，由 [WorkDetailFormat.newEpisodePrefix]
            // 给文案）。
            // ⛔ 「没播过」= `max_position_ms` **与** `last_played_at` **两条都空**，
            //    后者是已读回执。它由 [play] 在**点击那一刻**写入（不再等播放页
            //    退出时补写 —— 那边 `positionMs <= 0` 就提前 return，短看几秒
            //    一集一个字都不写，于是标记赖着不走）。
            // ⛔ 但**写完还得重读**：标签是照着**内存里**这份 `LibraryItem` 现算的，
            //    库里改了它不会自己变 —— 所以从播放页回来时 [onActivityResult]
            //    要走 [reloadCurrentItems]。两件事缺一，标记就还在。
            val isNew = currentWork?.isNewSinceFollow(entry) == true
            line1.text = newEpisodeTitle(EpisodeLabels.fileLabel(entry), isNew)
            // 副标题只报「这一条文件本身是什么」（清晰度 · 体积）。
            // ⛔ 进度**不在这里**：它已经单独占一列了，两处都写就是同一件事印两遍
            //    —— 这一行的宽度还要留给文件名。
            line2.text = buildString {
                entry.resolution?.takeIf { it.isNotEmpty() }?.let { append("$it · ") }
                append(formatSize(entry.sizeBytes ?: 0L))
            }
            val percent = EpisodeLabels.progressPercent(entry)
            progress.text = percent ?: "—"
            // 看过 ⇒ 亮一档，没看过 ⇒ 与时间列的「不知道」同档灰。
            progress.setTextColor(if (percent != null) 0xFFE5E7EB.toInt() else 0xFF4B5563.toInt())
            // ⛔ [LibraryItem.modifiedAt] 已经是**毫秒**了（`LibraryDb.queryItems` 从库里
            //    的秒乘过一次，好与网盘的 `updatedAtMs` 同单位）。这里**再乘一次 1000**
            //    会得到一个公元 5 万多年的时间戳 ⇒ `Fmt.relativeTime` 的 `diffSec < 0`
            //    那一支 ⇒ 每一行都写「刚刚」（2026-10-07 实机：三行全「刚刚」，用户
            //    的原话是「修改时间不是网盘文件的修改时间」）。
            //    0 / null 当「网盘没给」，显示 `—`（而不是 1970 年）。
            val m = entry.modifiedAtMs ?: 0L
            time.text = Fmt.relativeTime(m, System.currentTimeMillis())
            time.setTextColor(if (m > 0) 0xFF9AA3B2.toInt() else 0xFF4B5563.toInt())

            row.background = listRowFocusDrawable(
                itemsList.isFocused && itemsList.selectedItemPosition == position,
            )
            return row
        }
    }

    // ------------------------------------------------------------------

    // ⛔ 这里曾经有个 `private fun clock(ms)`：列表副标题的「看到 12:34」用它格式化
    //    续播点。已删除 —— 那个位置现在走 [EpisodeLabels.progressLabel]（读历史最大
    //    位置、并带上总时长），本页不再需要自己格式化时钟。

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun matchParent() = FrameLayout.LayoutParams(MATCH, MATCH)

    private companion object {
        const val TAG = "CloudCine"

        /**
         * `startActivityForResult` 的请求码。
         *
         * ⛔ 判 `requestCode` 而不是只判 `resultCode`：子页面回 OK 都会走到
         *    [onActivityResult]，只判 `resultCode` 的话任何一个子页面退出
         *    都会触发一次「刷新作品」。
         */
        const val REQ_SCRAPE = 1001

        /**
         * 从播放页回来。
         *
         * ⛔ 与 [REQ_SCRAPE] 分开：这两条回来要干的事不同（一个是重读
         *    `media_works` 一整行，一个是重读这一部的文件列表），而**都不能**
         *    只靠 `resultCode` 判 —— 播放页压根没有 `setResult`。
         */
        const val REQ_PLAYER = 1002

        /**
         * 进媒体库后多久开始静默追更检查（毫秒）。
         *
         * ⛔ 1.5 秒是「首帧已经画完、海报墙那批读库 + 扫海报目录已经跑起来」
         *    的估计值。放在 `post` 里（0 延迟）会与首屏那批抢同一个后台线程池
         *    —— 而用户对这个检查**没有任何预期**，晚 1.5 秒他察觉不到。
         */
        const val FOLLOW_LAUNCH_DELAY_MS = 1500L

        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        const val BG = 0xFF101216.toInt()
        const val MUTED = 0xFF9AA3B2.toInt()

        /**
         * 评分角标的实心底色 —— 与 PC 端 `TagChip(filled: true, color: AppTheme.warn)`
         * 同一支色：`#FFB454` 压到 92% 不透明（`0xEB`）。
         *
         * ⛔ 别改回「半透明黑 + 白字」。那是角标最初的写法，问题不在对比度而在
         *    **语义**：一排海报上飘着好几个一模一样的黑药丸，看的人分不清哪个是
         *    评分、哪个是别的什么；暖橙实底一眼就是「这片子多少分」。
         *    这也是 PC 端海报墙的口径（那里 `warn` 只用在评分上）。
         */
        const val RATING_BG = 0xEBFFB454.toInt()

        /** 评分角标的字色 —— PC 端 `AppTheme.bg`（`#0B0D12`），与实底形成高对比。 */
        const val RATING_FG = 0xFF0B0D12.toInt()

        /** 品牌主色 `#7F77DD` 在深底上的可读版本。 */
        const val BRAND_TINT = 0xFFA9A3F5.toInt()

        /** 选中底色：品牌色的深色调，既要能看出选中、又不能刺眼。 */
        const val BRAND_SELECT = 0xFF332C63.toInt()

        /** 海报墙左右留白。 */
        const val GRID_PAD_DP = 32

        /**
         * 「播放进度」列宽（dp）。
         *
         * ⛔ 宽度要装得下最长的那个值（`100%` / `<1%`）**并且固定** —— 这一列是
         *    给人竖着扫的，宽度随内容变会让整张表左右跳。
         */
        const val PROGRESS_COL_DP = 64

        /**
         * 「修改时间」列宽（dp）。
         *
         * ⛔ 96 是按最长的相对时间（`2026-09-01`）留的 —— 缩到 80 以下时那一档
         *    会被省略号吃掉，而它恰好是**唯一**能被完整读出来的形态。
         */
        const val TIME_COL_DP = 96

        /**
         * 简介页海报的宽度（dp），高度按 2:3 算。
         *
         * ⛔ **不要照抄 PC 端 `work_detail_page.dart` 的 138×207**：那是给
         *    桌面窗口高度用的。电视横屏的逻辑高只有 540dp（1080p / density 2.0），
         *    207dp 的海报加上动作行、排序行、剧集列表、底部两行提示会把这一页
         *    撑爆 —— 列表只剩一行，而「选集」恰恰是这一页的主要用途。
         */
        const val DETAIL_POSTER_DP = 96

        /** 卡片间距。 */
        const val GRID_GAP_DP = 12

        /**
         * 目标卡宽（dp）—— 实际列数由屏幕像素宽度反算，见 `computeGrid`。
         *
         * ⛔ 这个值**同时**决定列数和卡片高度（海报 2:3 ⇒ 高 = 宽 × 1.5），
         *    所以它是「一屏能看几部」的主开关，不只是横向密度。
         *
         * 132 → 100 的来历（1920×1080 / density 2.0，实测）：132dp 反算出 **6 列**，
         * 卡宽 278px、卡高 499px —— 一行就吃掉屏高的 46%，可视区只放得下
         * **1.3 行**（6 张完整 + 6 张残）。100dp 反算出 **8 列**，卡宽 203px、
         * 卡高 378px，配合下面各处压缩的上下固定栏，可视区正好放下**完整 2 行**
         * ⇒ 一屏从 6 部变成 16 部。
         *
         * ⛔ 别为了「更密」把它压到 88 以下：那会跳到 9 列，卡宽只剩 177px，
         *    在沙发距离上海报上的字就看不清了（9 列要配合把卡片文字改到海报上，
         *    那是另一套版式，不在这次范围内）。
         */
        const val TARGET_CARD_DP = 100

        /**
         * 海报缩略图缓存上限。
         *
         * ⛔ 必须封顶：一屏十几张 2:3 的图，RGB_565 下每张约 250 KB，
         *    没有上限的话「从头滚到尾」等于把整个海报墙留在堆里。
         */
        const val POSTER_CACHE_BYTES = 12 * 1024 * 1024

        /**
         * 网盘封面下好之后，攒多久统一重画一次作品墙。
         *
         * ⛔ 不能每张都重画：首次进库时未刮削的作品可能有几百部，逐张
         *    `notifyDataSetChanged()` 等于把海报墙按住不让动。300 ms 足够把
         *    同一屏触发的那一批下载收进来。
         */
        const val CLOUD_REFRESH_MS = 300L

        /**
         * 覆盖层菜单上下留的呼吸位（dp，上下各一半）。
         *
         * ⛔ 不能贴边：电视有 overscan，最外面一圈在部分机器上根本看不到。
         */
        const val OVERLAY_TOP_BOTTOM_DP = 72
    }
}
