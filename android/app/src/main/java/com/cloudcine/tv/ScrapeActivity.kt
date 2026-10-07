package com.cloudcine.tv

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.BaseAdapter
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import com.cloudcine.tv.library.DoubanScraper
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.ProgressStore
import com.cloudcine.tv.library.MediaCategoryNames
import com.cloudcine.tv.library.PosterFetcher
import com.cloudcine.tv.library.ScrapeCandidate
import com.cloudcine.tv.library.ScrapeQuery
import com.cloudcine.tv.library.ScrapeQueryBuilder
import com.cloudcine.tv.library.ScraperPipeline
import com.cloudcine.tv.library.TmdbScraper
import com.cloudcine.tv.pan.Bg

/**
 * **手动刮削页** —— 详情页菜单里那个「手动刮削」进来的地方。
 *
 * ## 它解决什么问题
 *
 * 自动刮削失败的大多是**片名解析不准**：文件名里插了 `z`（`超z级z马z力z欧z…`）、
 * 只剩分辨率信息、或者数据源里根本没收录。这时唯一的出路是**用户自己敲一个词**
 * 再搜，然后从候选里挑一条 —— 用户做过判断之后，任何匹配闸门都该让路。
 *
 * ## 与 PC 端 `ManualScrapeDialog` 的对应关系
 *
 * 同一套流程（预填 → 搜候选 → 选中 → 落库），但**交互按电视重做**：
 *
 * | PC 端 | 这里 |
 * |---|---|
 * | 输入框 + 年份框 + 搜索按钮 | 输入框（软键盘）+ 胶囊行（搜索 / 源 / 类型） |
 * | 候选列表可滚动、可点击 | 候选列表 + 自管 OK（电视上 `OnItemClickListener` 不可靠） |
 * | 媒体类型下拉 | 菜单里选（默认「自动」） |
 *
 * ## 预填的是**文件名解析出来的词**，不是库里已存的标题
 *
 * 这一点照抄 PC 端：库里那个标题很可能是**上一次刮错的结果**，用户得先意识到
 * 「框里是错的」才会去改。预填原始词（`超z级z马z力z欧z银z河z大z电影aa`）反而
 * 更有用 —— 它诚实地展示了「自动刮削拿着这么个词去搜」，用户一眼就知道该删什么。
 *
 * ## 按键（全部在 [dispatchKeyEvent] 里自管）
 *
 * | 键 | 位置 | 行为 |
 * |---|---|---|
 * | OK | 搜索框 | 弹软键盘编辑（系统默认） |
 * | OK | 胶囊行 | 搜索 / 弹子菜单 |
 * | OK | 候选列表 | **用这一条更新**（⛔ DOWN 与 UP 都要吞） |
 * | ↓ | 搜索框 / 胶囊行 | 往下一层 |
 * | ↑ | 列表首行 / 胶囊行 | 往上一层 |
 * | 菜单 | 任意 | 换搜索源 / 媒体类型 / 重新搜索 |
 * | 返回 | 任意 | 取消，回详情页 |
 *
 * ⛔ **OK 的 DOWN 与 UP 都必须吞掉**：只吞 DOWN 会让一次按键触发两次
 *    （`dispatchKeyEvent` 收 DOWN，焦点系统又用 UP 触发一次点击）——
 *    表现是「按一下刮两遍」。
 */
class ScrapeActivity : Activity() {

    private lateinit var db: LibraryDb
    private lateinit var workKey: String
    private lateinit var workTitle: String

    private lateinit var searchBox: EditText
    private lateinit var status: TextView
    private lateinit var listView: ListView
    private lateinit var chipBox: LinearLayout
    private lateinit var chipScroll: HorizontalScrollView

    // ── 覆盖层（选搜索源 / 选媒体类型）──
    private lateinit var overlayScrim: FrameLayout
    private lateinit var overlayTitle: TextView
    private lateinit var overlayRowsBox: LinearLayout
    private lateinit var overlayScroll: ScrollView
    private var overlayVisible = false
    private var overlayIndex = 0
    private var overlayLabels: List<String> = emptyList()
    private var overlayOnPick: ((Int) -> Unit)? = null

    /**
     * 软键盘**可能**正显示。
     *
     * ⛔ 只在我们自己显隐键盘的地方维护 —— 不去问系统「键盘现在可见吗」：
     *    没有可靠的 API（`InputMethodManager.isAcceptingText` 说的是「有输入
     *    连接」而不是「键盘可见」）。唯一用途是返回键：键盘在 → 先收键盘；
     *    键盘已经收了 → 放行给系统，真的返回上一页。
     */
    private var keyboardUp = false

    // ── 胶囊行（搜索 / 源 / 类型）──
    private inner class Chip(val label: String, val onTap: () -> Unit)

    private var chips: List<Chip> = emptyList()
    private var chipCursor = 0
    private var chipFocused = false

    // ── 状态 ──
    private val candidates = ArrayList<ScrapeCandidate>()
    private lateinit var adapter: CandidateAdapter

    /** 是否有网络动作在跑（搜索 / 应用）。跑的时候禁止并发。 */
    private var busy = false

    /** 只在某个源里搜；`null` = 全部启用的源。 */
    private var sourceFilter: String? = null

    /** 用户手选的媒体类型；`null` = 自动（按刮削结果判）。 */
    private var categoryOverride: String? = null

    /** 文件名解析出来的年份 / 结构，搜索时带上（用户看不见，但影响命中率）。 */
    private var parsedYear: Int? = null
    private var parsedKind: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        workKey = intent.getStringExtra(EXTRA_WORK_KEY).orEmpty()
        workTitle = intent.getStringExtra(EXTRA_WORK_TITLE).orEmpty()
        if (workKey.isEmpty()) {
            Log.w(TAG, "刮削页缺少 workKey，直接退出")
            finish()
            return
        }
        db = LibraryDb(
            LibraryPaths.dbFile(this),
            progress = ProgressStore.shared(LibraryPaths.progressFile(this)),
        )

        val frame = FrameLayout(this).apply { setBackgroundColor(BG) }
        frame.addView(buildContent(), matchParent())
        frame.addView(buildOverlay(), matchParent())
        setContentView(frame)

        buildChips()
        prefill()
    }

    override fun onDestroy() {
        super.onDestroy()
        // ⛔ 与其它页面同一条规矩：库连接必须关。留着的话，下一次 `rawBytes()`
        //    （备份导出）会读到一份「少最后几次写入」的库。
        runCatching { db.close() }
    }

    // ------------------------------------------------------------------
    // 视图
    // ------------------------------------------------------------------

    private fun buildContent(): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(48), dp(24), dp(48), dp(16))
        }

        // ── 页头：品牌 + 标题 ──
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        head.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(30), dp(30)),
        )
        head.addView(
            TextView(this).apply {
                text = "手动刮削"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                setPadding(dp(12), 0, 0, 0)
            },
        )
        head.addView(
            TextView(this).apply {
                text = workTitle
                setTextColor(BRAND_TINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                setPadding(dp(12), 0, 0, 0)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.MIDDLE
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        column.addView(head)

        column.addView(
            TextView(this).apply {
                text = "改好搜索词 → 搜索 → 从候选里挑一条。挑中的那一条会覆盖这部作品的" +
                    "标题 / 年份 / 简介 / 海报 / 评分。"
                setTextColor(FAINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setPadding(0, dp(8), 0, dp(12))
            },
        )

        // ── 搜索词输入框 ──
        // ⛔ `isSingleLine` 必须为 true：多行 EditText 会把 ↓ 键自己吃掉用来移光标，
        //    于是「按 ↓ 去候选列表」永远出不去 —— 遥控器上就是「卡在输入框里」。
        searchBox = EditText(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            isSingleLine = true
            maxLines = 1
            setHint("输入片名后按键盘上的「搜索」，或 ↓ 到下面点「搜索」")
            setHintTextColor(FAINT)
            setPadding(dp(16), dp(12), dp(16), dp(12))
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            background = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(0xFF232936.toInt())
            }
            setOnFocusChangeListener { _, hasFocus ->
                background = GradientDrawable().apply {
                    cornerRadius = dp(12).toFloat()
                    setColor(0xFF232936.toInt())
                    if (hasFocus) setStroke(dp(2), BRAND_TINT)
                }
            }
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_SEARCH ||
                    actionId == EditorInfo.IME_ACTION_DONE
                ) {
                    hideKeyboard()
                    doSearch()
                    true
                } else {
                    false
                }
            }
        }
        column.addView(
            searchBox,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        // ── 胶囊行：搜索 / 源 / 类型 ──
        // 与媒体库、文件列表同一套样式语言（实心面明度区分「生效 / 光标 / 常态」，
        // 不描边）；光标态与生效态分离（←→ 只移光标，OK 才生效）。
        chipBox = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isFocusable = false
            isFocusableInTouchMode = false
        }
        chipScroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            clipToPadding = false
            clipChildren = false
            addView(
                chipBox,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        column.addView(
            chipScroll,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(10); bottomMargin = dp(6) },
        )

        status = TextView(this).apply {
            setTextColor(DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(0, dp(4), 0, dp(8))
        }
        column.addView(status)

        // ── 候选列表 ──
        adapter = CandidateAdapter()
        listView = ListView(this).apply {
            adapter = this@ScrapeActivity.adapter
            divider = null
            dividerHeight = 0
            setBackgroundColor(BG)
            isFocusable = true
            isFocusableInTouchMode = true
        }
        column.addView(
            listView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )

        column.addView(
            TextView(this).apply {
                text = "↓ 到候选 · OK 用选中的这一条更新 · 菜单 换源/类型 · 返回 取消"
                setTextColor(FAINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(0, dp(6), 0, 0)
            },
        )
        return column
    }

    private fun buildOverlay(): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0xB3000000.toInt())
            isClickable = true
            visibility = View.GONE
        }
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            // ⛔ 不描边（用户明确说过线框不好看），层次靠比背景亮一档的实心面。
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
        card.addView(overlayTitle)
        overlayRowsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        // ⛔ 菜单必须能滚（与文件列表页同一条理由：1080p 只有 540dp 高，
        //    类型选项有 7 项，溢出时最后几项永远选不到）。
        overlayScroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            isFocusable = false
            isFocusableInTouchMode = false
            addView(overlayRowsBox, ViewGroup.LayoutParams(MATCH, WRAP))
        }
        card.addView(overlayScroll, LinearLayout.LayoutParams(MATCH, WRAP))

        scrim.addView(
            card,
            FrameLayout.LayoutParams(dp(560), WRAP).apply { gravity = Gravity.CENTER },
        )
        overlayScrim = scrim
        return scrim
    }

    // ------------------------------------------------------------------
    // 胶囊行
    // ------------------------------------------------------------------

    private fun buildChips() {
        chips = listOf(
            Chip("搜索") { doSearch() },
            Chip("搜索源：${sourceLabel(sourceFilter)}") { openSourceMenu() },
            Chip("媒体类型：${categoryOverride?.let { MediaCategoryNames.label(it) } ?: "自动"}") {
                openCategoryMenu()
            },
        )
        if (chipCursor >= chips.size) chipCursor = 0
        chipBox.removeAllViews()
        for ((i, c) in chips.withIndex()) {
            chipBox.addView(chipView(c, isCursor = chipFocused && i == chipCursor))
        }
        revealChip(chipCursor)
    }

    private fun chipView(chip: Chip, isCursor: Boolean): TextView = TextView(this).apply {
        text = chip.label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
        setPadding(dp(16), dp(9), dp(16), dp(9))
        maxLines = 1
        isSingleLine = true
        isFocusable = false
        isFocusableInTouchMode = false
        gravity = Gravity.CENTER
        background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setColor(if (isCursor) BRAND_SOLID else 0x14FFFFFF)
        }
        setTextColor(if (isCursor) 0xFF1A1533.toInt() else 0xFFB9C0CC.toInt())
        layoutParams = LinearLayout.LayoutParams(WRAP, WRAP).apply { rightMargin = dp(8) }
    }

    private fun moveChip(delta: Int) {
        if (chips.isEmpty()) return
        chipCursor = (chipCursor + delta + chips.size) % chips.size
        buildChips()
    }

    private fun focusChips() {
        chipFocused = true
        // 焦点离开输入框，IME 会自己收起来。
        keyboardUp = false
        buildChips()
        status.text = "OK 生效 · ↓ 到候选 · ↑ 回搜索框"
    }

    private fun focusSearchBox() {
        chipFocused = false
        buildChips()
        searchBox.requestFocus()
        keyboardUp = true
    }

    private fun focusList() {
        chipFocused = false
        keyboardUp = false
        buildChips()
        listView.requestFocus()
    }

    /** 把光标所在胶囊滚进可视区（胶囊不可聚焦，框架不会自动滚）。 */
    private fun revealChip(index: Int) {
        val chip = chipBox.getChildAt(index) ?: return
        chipScroll.post {
            val pad = dp(24)
            val viewport = chipScroll.width
            if (viewport <= 0) return@post
            val want = when {
                chip.left - pad < chipScroll.scrollX -> chip.left - pad
                chip.right + pad > chipScroll.scrollX + viewport ->
                    chip.right + pad - viewport
                else -> -1
            }
            if (want >= 0) chipScroll.smoothScrollTo(want, 0)
        }
    }

    // ------------------------------------------------------------------
    // 覆盖层（选源 / 选类型）
    // ------------------------------------------------------------------

    private fun showOverlay(titleText: String, labels: List<String>, onPick: (Int) -> Unit) {
        // ⛔ 开覆盖层前**先把软键盘收掉**。搜索框一直拿着焦点时，IME 会抢在
        //    Activity 前面吃掉 ↑↓ / OK（实测 `input keyevent 20` 落在键盘上），
        //    现象是「菜单弹出来了、但光标一动不动、按 OK 也没反应」；而且键盘
        //    会把下半屏盖住，后几项（比如「刮削设置」）根本看不见。
        hideKeyboard()
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
        paintOverlay()
        overlayScrim.visibility = View.VISIBLE
        overlayVisible = true
        overlayScroll.post { overlayScroll.scrollTo(0, 0) }
    }

    private fun paintOverlay() {
        for (i in 0 until overlayRowsBox.childCount) {
            MenuRow.paint(overlayRowsBox.getChildAt(i), i == overlayIndex)
        }
        revealOverlayRow()
    }

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
    }

    private fun openSourceMenu() {
        val opts = ArrayList<Pair<String, String?>>()
        opts.add("全部启用的源" to null)
        for ((id, name) in ScraperPipeline.fromSettings(db).availableSources) {
            opts.add(name to id)
        }
        showOverlay("在哪个源里搜？", opts.map { it.first }) { i ->
            hideOverlay()
            val pick = opts.getOrNull(i) ?: return@showOverlay
            sourceFilter = pick.second
            buildChips()
            status.text = "搜索源：${sourceLabel(sourceFilter)}（下次搜索生效）"
        }
    }

    private fun openCategoryMenu() {
        val opts = ArrayList<Pair<String, String?>>()
        opts.add("自动（按刮削结果判）" to null)
        for (c in MediaCategoryNames.displayOrder) {
            opts.add(MediaCategoryNames.label(c) to c)
        }
        showOverlay("把这部作品归到哪一栏？", opts.map { it.first }) { i ->
            hideOverlay()
            val pick = opts.getOrNull(i) ?: return@showOverlay
            categoryOverride = pick.second
            buildChips()
            status.text = if (categoryOverride == null) {
                "媒体类型：自动"
            } else {
                "媒体类型：${MediaCategoryNames.label(categoryOverride)}（会锁住，之后刮削不再改）"
            }
        }
    }

    // ------------------------------------------------------------------
    // 预填 / 搜索 / 应用
    // ------------------------------------------------------------------

    /**
     * 预填搜索词。
     *
     * ⛔ 挑文件的口径**下沉到了** [ScrapeQueryBuilder.forItems] —— 它同时被
     *    扫描后的自动刮削（`AutoScraper`）使用。两处各写一份的话，同一个作品
     *    会出现「手动刮出来是 A、自动刮出来是 B」，而这是**静默的**。
     *    那段逻辑做三件事：跳过花絮 / 样片、逐条按 `dirPath` 解析、取第一个
     *    可信片名。
     *
     * ⛔ 解析不出可信片名时**退回库里已存的标题**（用户至少有个起点可改），
     *    而不是留一个空框。
     */
    private fun prefill() {
        status.text = "正在准备搜索词…"
        Bg.run({
            ScrapeQueryBuilder.forItems(db.itemsForWork(workKey))
        }) { q, err ->
            if (err != null) Log.w(TAG, "预填搜索词失败", err)
            if (q != null) {
                searchBox.setText(q.title)
                parsedYear = q.year
                parsedKind = q.kind
                status.text = "搜索词来自文件名（年份 ${q.year ?: "无"}）。改好后按 ↓ 点「搜索」"
            } else {
                searchBox.setText(workTitle)
                status.text = "文件名解析不出可信片名，已用库里标题预填。改好后按 ↓ 点「搜索」"
            }
            searchBox.setSelection(searchBox.text.length)
            searchBox.requestFocus()
            keyboardUp = true
        }
    }

    private fun doSearch() {
        if (busy) {
            status.text = "上一个动作还没完成，请稍候…"
            return
        }
        val word = searchBox.text.toString().trim()
        if (word.isEmpty()) {
            status.text = "先填一个搜索词"
            searchBox.requestFocus()
            keyboardUp = true
            return
        }
        hideKeyboard()
        busy = true
        candidates.clear()
        adapter.notifyDataSetChanged()
        status.text = "正在搜「$word」…"
        val q = ScrapeQuery(title = word, year = parsedYear, kind = parsedKind)
        Log.i(TAG, "刮削搜索：「$word」（源=${sourceLabel(sourceFilter)}，年份=$parsedYear）")
        Bg.run({
            // ⛔ 每次都**重新构造**流水线：用户可能刚在设置里填完 Cookie 回来，
            //    缓存实例拿的还是旧值（表现是「填了还是刮不到」）。
            ScraperPipeline.fromSettings(db).search(q, sourceFilter)
        }) { found, err ->
            busy = false
            if (err != null) {
                status.text = "搜索失败：${err.message}"
                Log.w(TAG, "刮削搜索失败", err)
                return@run
            }
            candidates.clear()
            candidates.addAll(found ?: emptyList())
            adapter.notifyDataSetChanged()
            listView.setSelection(0)
            status.text = when {
                candidates.isEmpty() -> {
                    // ⛔ 不能只说「没搜到」：用户会以为片子不在数据源里。
                    //    实际最常见的原因是**词里还有干扰字符**或**源没配好**。
                    "没搜到候选 —— 试试删掉片名里的干扰字符；" +
                        "若 TMDB 一直为空，去「刮削设置」填 API Key / 反代地址"
                }
                else -> "共 ${candidates.size} 条候选 · OK 用选中的这一条更新"
            }
            if (candidates.isNotEmpty()) listView.requestFocus()
        }
    }

    /**
     * 把选中的候选解析成完整元数据、落库、并把海报拉下来。
     *
     * ⛔ 海报下载**放在同一个后台任务里**（而不是另起一个）：它跟着这一次刮削
     *    走，用户看到「已刮削」时海报也应该已经在盘上了。失败**不影响**主流程
     *    （元数据已经落库了），只是墙上那块还是灰的。
     */
    private fun applyCandidate(c: ScrapeCandidate) {
        if (busy) return
        busy = true
        status.text = "正在应用「${c.title}」…"
        Log.i(TAG, "刮削应用：${c.uid}「${c.title}」")
        Bg.run({
            val pipe = ScraperPipeline.fromSettings(db)
            val meta = pipe.resolve(c) ?: return@run null
            val updated = db.updateWorkScrape(workKey, meta, categoryOverride)
                ?: return@run null
            val posterUrl = meta.posterUrl?.takeIf { it.isNotBlank() }
            if (posterUrl != null) {
                val file = PosterFetcher(LibraryPaths.posterDir(this)).fetch(workKey, posterUrl)
                if (file != null) db.setWorkPosterFile(workKey, file)
            }
            Pair(updated, meta)
        }) { result, err ->
            busy = false
            if (err != null || result == null) {
                // ⛔ 与「没搜到」分开说：用户刚**亲手挑了一条**，被告知「没找到」
                //    只会以为界面坏了。真实原因通常是条目被删 / 接口改版。
                status.text = "这一条解析不出完整信息" +
                    "（条目可能已被删除或改版），换一条候选再试"
                Log.w(TAG, "刮削应用失败", err)
                return@run
            }
            val (w, meta) = result
            status.text = buildString {
                append("已刮削：").append(meta.title)
                meta.year?.let { append("（").append(it).append("）") }
                append(" · ").append(sourceLabel(c.source))
                append(" · 类型：").append(MediaCategoryNames.label(w.category))
            }
            Log.i(TAG, "刮削成功：$workKey → ${meta.title}")
            setResult(RESULT_OK)
            // 让用户看清结果再自动返回（刮削是「点一下就走」的动作，
            // 停在这一页等用户按返回反而多一步）。
            status.postDelayed({ if (!isFinishing) finish() }, 900)
        }
    }

    // ------------------------------------------------------------------
    // 按键
    // ------------------------------------------------------------------

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // ── 覆盖层独占按键（与文件列表页同一套）──
        if (overlayVisible) {
            if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)
            if (overlayLabels.isEmpty()) {
                hideOverlay()
                return true
            }
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP -> {
                    overlayIndex = (overlayIndex - 1 + overlayLabels.size) % overlayLabels.size
                    paintOverlay()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    overlayIndex = (overlayIndex + 1) % overlayLabels.size
                    paintOverlay()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                    // ⛔ 先取出来再回调：回调里 `hideOverlay()` 会把 `overlayOnPick`
                    //    置空，直接调用会空指针。
                    val pick = overlayOnPick
                    pick?.invoke(overlayIndex)
                    return true
                }
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_MENU -> {
                    hideOverlay()
                    return true
                }
            }
            return true
        }

        // ── 候选列表上的 OK：**自管**（电视上 `OnItemClickListener` 按 OK 不触发）──
        // ⛔ DOWN 与 UP **都要吞**：只吞 DOWN 会让一次按键触发两次
        //    （dispatch 收 DOWN，焦点系统又用 UP 触发一次点击）= 刮两遍。
        if (listView.hasFocus() && isCenter(event.keyCode)) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> {
                    val c = candidates.getOrNull(listView.selectedItemPosition)
                    if (c != null) applyCandidate(c)
                    return true
                }
                KeyEvent.ACTION_UP -> return true
            }
        }

        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)

        // ── 胶囊行拿到光标 ──
        if (chipFocused) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> { moveChip(-1); return true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { moveChip(1); return true }
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> {
                    chips.getOrNull(chipCursor)?.onTap?.invoke()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    if (candidates.isEmpty()) {
                        status.text = "还没有候选 —— 先点「搜索」"
                    } else {
                        focusList()
                    }
                    return true
                }
                KeyEvent.KEYCODE_DPAD_UP -> { focusSearchBox(); return true }
                KeyEvent.KEYCODE_MENU -> { openMenu(); return true }
            }
            return true
        }

        // ── 搜索框：↓ 去胶囊行 ──
        if (searchBox.hasFocus()) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_DOWN -> { focusChips(); return true }
                KeyEvent.KEYCODE_MENU -> { openMenu(); return true }
                // ⛔ 键盘在 → 先收键盘；键盘**已经收了** → 放行给系统，真的返回
                //    上一页。无条件吞掉的话，用户在这一页按返回永远没反应，
                //    只能按 HOME 逃出去。
                KeyEvent.KEYCODE_BACK -> {
                    if (keyboardUp) {
                        hideKeyboard()
                        return true
                    }
                }
            }
            return super.dispatchKeyEvent(event)
        }

        // ── 候选列表：↑ 首行回上一层 ──
        when (event.keyCode) {
            KeyEvent.KEYCODE_MENU -> {
                openMenu()
                return true
            }
            KeyEvent.KEYCODE_DPAD_UP -> {
                if (listView.selectedItemPosition == 0) {
                    focusChips()
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun isCenter(keyCode: Int): Boolean =
        keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
            keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER

    /**
     * 菜单（菜单键）。
     *
     * ⛔ 用「`标签 to 动作` 的列表」而不是 `labels` + `when(index)`：下标错了
     *    不会编译失败，而这里面有一项是**重新搜索**（会发网络请求）。
     */
    private fun openMenu() {
        val actions = ArrayList<Pair<String, () -> Unit>>()
        actions.add("搜索（用当前搜索词）" to { doSearch() })
        actions.add("搜索源：${sourceLabel(sourceFilter)}" to { openSourceMenu() })
        actions.add(
            "媒体类型：${categoryOverride?.let { MediaCategoryNames.label(it) } ?: "自动"}" to {
                openCategoryMenu()
            },
        )
        actions.add("清空搜索词" to {
            searchBox.setText("")
            searchBox.requestFocus()
            keyboardUp = true
            status.text = "搜索词已清空 —— 敲一个数据源里认得的片名"
        })
        actions.add("刮削设置（TMDB Key / 反代 / 豆瓣 Cookie）" to {
            startActivity(android.content.Intent(this, ScrapeSettingsActivity::class.java))
        })
        showOverlay(titleText = "刮削", labels = actions.map { it.first }) { index ->
            val act = actions.getOrNull(index) ?: return@showOverlay
            hideOverlay()
            act.second()
        }
    }

    // ------------------------------------------------------------------
    // 工具
    // ------------------------------------------------------------------

    private fun sourceLabel(id: String?): String = when (id) {
        null -> "全部"
        DoubanScraper.ID -> "豆瓣"
        TmdbScraper.ID -> "TMDB"
        else -> id
    }

    private fun hideKeyboard() {
        keyboardUp = false
        val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager ?: return
        imm.hideSoftInputFromWindow(searchBox.windowToken, 0)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private inner class CandidateAdapter : BaseAdapter() {
        override fun getCount() = candidates.size
        override fun getItem(position: Int) = candidates[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val row = (convertView as? LinearLayout) ?: LinearLayout(this@ScrapeActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(20), dp(12), dp(20), dp(12))
            }
            val c = candidates[position]

            val title = row.getChildAt(0) as? TextView ?: TextView(this@ScrapeActivity).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.MIDDLE
                layoutParams = LinearLayout.LayoutParams(0, WRAP, 1f)
                row.addView(this)
            }
            val meta = row.getChildAt(1) as? TextView ?: TextView(this@ScrapeActivity).apply {
                setTextColor(DIM)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.END
                row.addView(this)
            }
            val src = row.getChildAt(2) as? TextView ?: TextView(this@ScrapeActivity).apply {
                setTextColor(BRAND_TINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                gravity = Gravity.END
                layoutParams = LinearLayout.LayoutParams(dp(72), WRAP)
                row.addView(this)
            }

            title.text = c.title
            meta.text = c.subtitle
            src.text = sourceLabel(c.source)
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

    companion object {
        /** 从详情页带过来的作品键（`media_works.key`）。 */
        const val EXTRA_WORK_KEY = "scrape_work_key"

        /** 作品标题（只用于页头显示）。 */
        const val EXTRA_WORK_TITLE = "scrape_work_title"

        private const val TAG = "CloudCine"
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        private const val BG = 0xFF101216.toInt()
        private const val DIM = 0xFF9AA3B2.toInt()
        private const val FAINT = 0xFF6B7280.toInt()

        /** 品牌主色 `#7F77DD` 在深底上的可读版本。 */
        private const val BRAND_TINT = 0xFFA9A3F5.toInt()

        /** 品牌主色（胶囊生效态用实心面）。 */
        private const val BRAND_SOLID = 0xFF7F77DD.toInt()

        /** 候选行选中底色（与文件列表 / 媒体库同一档）。 */
        private const val BRAND_SELECT = 0xFF332C63.toInt()
    }

    private fun matchParent() = FrameLayout.LayoutParams(MATCH, MATCH)
}
