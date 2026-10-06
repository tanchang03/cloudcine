package com.cloudcine.tv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView

/**
 * 原生（Android View）版的 TV 播放器 OSD —— **几何照抄云影的 Flutter 版**
 * （`lib/ui/widgets/player_tv_panel.dart` 的常量），这样两台机器上肉眼看到的是
 * 同一块菜单，性能差异才归因得到渲染方式上，而不是「谁的菜单更小」。
 *
 * 抄过来的常量（dp = 云影的逻辑 px，目标机 devicePixelRatio 正好是 2.0）：
 *   * 过扫描内边距 48 / 27
 *   * 侧边栏宽 180、每行 40、上下内边距 14 → 卡片高 7×40+28+0.8
 *   * chip 高 34
 *
 * ## ⛔ 与 Flutter 版**故意不同**的三处，都是性能变量
 *
 * 1. **没有 `clipBehavior` / 圆角裁剪**。Flutter 版对整张卡片做 `Clip.antiAlias`，
 *    在 Mali 上是真金白银。这里只把**背景**画成圆角，子控件本来就内缩，
 *    视觉几乎无差，但省掉一次全宽裁剪。
 * 2. **没有 blur 阴影**。Flutter 版卡片带 26/34 两个 blur，每颗 chip 还各带两个
 *    12/10 的 blur。原生这里一个都没有 —— 这是要验证的差异之一。
 * 3. **没有隐式动画**。Flutter 版每次按键会起 `AnimatedContainer`（120ms）/
 *    `AnimatedScale`，把出帧需求从 25Hz 拉到 60Hz。这里选中态是**直接换背景**，
 *    一帧到位。
 *
 * 这三处如果去掉之后 OSD 还是慢，那就说明瓶颈不在 OSD 画法上。
 */
class TvOsdView(context: Context) : FrameLayout(context) {

    /**
     * 一行。前六个字段与云影 `PlayerTvRowValue` 一一对应。
     *
     * [id] 与 [active] 是原生版**额外**加的两个字段，都源于同一个原因：
     * 原生只回传**行下标**（[onActivate]），而下标会漂移。
     *
     *   * [id] —— 行数不是固定的：「直接给 URL」的对照路径就没有画质行，
     *     片源没有内嵌字幕时字幕行会退化成一句提示。用下标去 `when`，
     *     迟早把「字幕」接到「倍速」上；用稳定 id 还原语义就不会。
     *   * [active] —— 当前**生效**的选项下标。打开菜单时光标直接停在这上面，
     *     否则光标永远落在第一项、和用户此刻的状态对不上（比如现在放的是
     *     中文硬字幕，光标却停在「关闭」上，一按 OK 就把它关了）。
     */
    class Row(
        val label: String,
        val value: String,
        val options: List<String> = emptyList(),
        val enabled: List<Boolean> = emptyList(),
        /** 纵向列表（云影的「选集」）。true 时右侧是可滚动列表，不是 chips。 */
        val vertical: Boolean = false,
        /** options 为空时显示的那句说明。 */
        val hint: String? = null,
        /** 稳定标识，见类注释。 */
        val id: String = "",
        /** 当前生效项的下标；`-1` 表示「这行没有生效态」（如调试开关）。 */
        val active: Int = -1,
        /**
         * 每一项左边的**网盘封面**地址（`media_items.thumb_url`）。空 = 不画图。
         *
         * ⛔ 与 [options] **等长**（没有封面那几项给空串），不要写成「短的
         *    那个按顺序贴上去」—— `ListView` 会回收 View，靠下标取值的
         *    地方一旦错位，表现是「第 7 集的封面贴在第 3 集上」，
         *    而且只在滚动之后才出现。
         * ⛔ 只有 [vertical] 的行用得上它。chips 是 34dp 高的文字胶囊，
         *    塞不下图，也从来不传。
         */
        val thumbs: List<String> = emptyList(),
        /**
         * 每一项的**历史播放进度**（`0.0~1.0`）；**负数 = 这一条不画进度条**。
         *
         * ⛔ 负数与 `0.0` 必须分开：`0.0` 是「看过、但只看了开头」，负数才是
         *    「没看过 ⇒ 把条子整个藏起来」。混成 0 的话一整列空条看着像
         *    「全都卡在加载中」。
         * ⛔ 与 [options] **等长**（没有进度的那一项给 `-1.0`），理由同 [thumbs]。
         */
        val progress: List<Double> = emptyList(),
    ) {
        fun isEnabled(i: Int): Boolean = enabled.getOrElse(i) { true }

        fun thumbAt(i: Int): String = thumbs.getOrElse(i) { "" }

        /** 这一条的进度；`< 0` = 没进度（不画条）。 */
        fun progressAt(i: Int): Double = progress.getOrElse(i) { -1.0 }
    }

    /**
     * 纵向列表里那些封面的来源。
     *
     * ⛔ OSD **自己不做网络、也不做磁盘** —— 它只负责「问」。理由与整个
     *    OSD 被改写成原生 View 是同一条：这台电视上按键→上屏的预算只有
     *    几毫秒，任何一次 `File.exists()` 或解码都会变成可见的卡顿。
     *    取图由播放页（`EpisodeThumbs` + `PanApi`）在后台线程做。
     */
    interface ThumbSource {
        /**
         * 内存里已经解码好的就返回它 —— **主线程可调**，必须立即返回。
         * 没命中返回 `null`，列表先画占位块。
         */
        fun cached(url: String): Bitmap?

        /**
         * 已经确认「拿不到」的地址 —— 主线程可调。
         *
         * ⛔ 有这个判据，列表才不会对约三成「服务端没生成过预览图」的条目
         *    反复重试（表现是「滚一格卡一下」）。
         */
        fun isKnownBad(url: String): Boolean

        /**
         * 异步取图，**完成后在主线程回调 [onReady]**。
         *
         * ⛔ [onReady] 的语义是「重新画一遍这个列表」，不是「这一行现在有图了」
         *    —— OSD 只会拿它去 `notifyDataSetChanged()`。回调里再去摸
         *    `ListView` 的具体某一项，会踩到「取回来时用户已经滚走了」。
         */
        fun fetch(url: String, targetPx: Int, onReady: () -> Unit)
    }

    var onActivate: ((row: Int, chip: Int) -> Unit)? = null
    var onClose: (() -> Unit)? = null

    /** 纵向列表里封面的来源。不设 = 列表只画文字（和以前一样）。 */
    var thumbs: ThumbSource? = null

    /** 当前是否已把焦点「进入」纵向列表（云影的 `_inList`）。 */
    var inList: Boolean = false
        private set

    /**
     * 是否处于「纵向列表展开」态 —— 卡片在这个态下会**长高**。
     *
     * ⛔ 见 [CARD_LIST_H]：不长的后果不是「不好看」，是**选不到后面几集**
     *    —— 卡片只有 [CARD_H] 那么高时，右侧列表一屏只放得下 4 行，
     *    一部 24 集的剧要按 6 屏方向键。
     */
    private var listMode = false

    private val card: LinearLayout
    private val sidebarBox: LinearLayout
    private val rightHost: FrameLayout
    private val tileViews = ArrayList<TextView>()

    private var rows: List<Row> = emptyList()
    private var selRow = 0
    private var selChip = 0

    private var chipRow: LinearLayout? = null
    private var chipViews = ArrayList<TextView>()

    /**
     * chips 行外面那层横向滚动容器。
     *
     * ⛔ 留着它是为了**把选中项滚进可视区**。这个 `HorizontalScrollView` 里的
     *    chip 全是普通 `TextView`，没有焦点 —— 框架的「聚焦自动滚动」**不会**
     *    生效。以前选项少（最多 8 条字幕）时看不出问题，加进外挂字幕之后
     *    一屏放不下，用户就会「按了右键，高亮没了，也不知道选中了哪一条」。
     */
    private var chipStrip: HorizontalScrollView? = null
    private var listView: ListView? = null
    private var listAdapter: RowListAdapter? = null
    private var headerLabel: TextView? = null
    private var headerValue: TextView? = null

    init {
        // 整屏透明容器，只让底部那张卡片可点/可见。铺满是为了让
        // 「按键→上屏」的测量把 OSD 自身的位置也算进去。
        setBackgroundColor(Color.TRANSPARENT)

        card = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = cardBackground()
        }

        sidebarBox = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val p = dp(SIDEBAR_PAD_V).toInt()
            setPadding(0, p, 0, p)
        }

        rightHost = FrameLayout(context)

        card.addView(
            sidebarBox,
            LinearLayout.LayoutParams(dp(SIDEBAR_W).toInt(), ViewGroup.LayoutParams.MATCH_PARENT),
        )
        card.addView(
            rightHost,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                marginStart = dp(6f).toInt()
                marginEnd = dp(18f).toInt()
                topMargin = dp(30f).toInt()
                bottomMargin = dp(42f).toInt()
            },
        )

        // 卡片贴底，左右各留过扫描带；底部留 safe.bottom。
        val lp = LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(CARD_H).toInt(),
            Gravity.BOTTOM,
        )
        lp.leftMargin = dp(SAFE_H).toInt()
        lp.rightMargin = dp(SAFE_H).toInt()
        lp.bottomMargin = dp(SAFE_V).toInt()
        addView(card, lp)
    }

    // ------------------------------------------------------------------
    // 数据
    // ------------------------------------------------------------------

    fun bind(rows: List<Row>) {
        this.rows = rows
        if (rows.isEmpty()) return
        selRow = selRow.coerceIn(0, rows.size - 1)
        selChip = currentOptionIndex()
        inList = false
        listMode = false
        // ⛔ 行数是**可变**的（没有画质行 / 没有选集行都会少几行），所以卡片
        //    高度每次重绑都按行数重算 —— 写死一个 CARD_H 的话，少一行的情形
        //    会在卡片底部留一条空带，多一行的情形会把最后一行挤出可视区。
        applyCardHeight()
        rebuildSidebar()
        rebuildRight()
    }

    /**
     * 回到「刚打开菜单」的初始态：选中第一行（选集）、光标停在当前生效项。
     *
     * ⛔ 每次打开都必须调：测量要可重复 —— 上一次停在「片头」那一行时，
     * 下一次打开的第一下按键测到的是另一条路径（右侧要不要重建都不一样）。
     */
    fun resetSelectionForTest() {
        selRow = 0
        selChip = currentOptionIndex()
        inList = false
        listMode = false
        applyCardHeight()
        applySidebarSelection()
        rebuildRight()
    }

    /**
     * 卡片当前应该多高（dp）。
     *
     * ⛔ 默认态 = **行数 × 每行高 + 上下内边距**，不是那个写死的 `CARD_H`
     *    （它只是「7 行时」的取值，见常量注释）。行数会变，高度就得跟着变。
     * ⛔ 展开态 = [CARD_LIST_H]（见那里的理由）。
     */
    private fun targetCardHeightDp(): Float = if (listMode) {
        CARD_LIST_H
    } else {
        rows.size.coerceAtLeast(1) * TILE_H + SIDEBAR_PAD_V * 2 + 0.8f
    }

    private fun applyCardHeight() {
        val lp = card.layoutParams as? LayoutParams ?: return
        val want = dp(targetCardHeightDp()).toInt()
        if (lp.height == want) return
        lp.height = want
        card.layoutParams = lp
    }

    /** 进出纵向列表时切卡片高度 —— 见 [CARD_LIST_H]。 */
    private fun setListMode(on: Boolean) {
        if (listMode == on) return
        listMode = on
        applyCardHeight()
    }

    /**
     * 光标该停在哪一项。
     *
     * ⛔ 优先停在**当前生效**的那一项（`Row.active`）—— 这样打开菜单、或用
     *    ↑↓ 换到某一行时，光标就在用户此刻用的那个档位/字幕/倍速上，按 OK
     *    不会莫名其妙改掉一个他没想动的设置。
     *    只有行没给 `active`（`-1`）时才退化成「夹住上一次的光标位置」。
     */
    private fun currentOptionIndex(): Int {
        val row = rows.getOrNull(selRow) ?: return 0
        if (row.options.isEmpty()) return 0
        if (row.active in row.options.indices) return row.active
        return selChip.coerceIn(0, row.options.size - 1)
    }

    // ------------------------------------------------------------------
    // 按键 —— 与云影 `_PlayerTvSheetState._onKey` 同一套语义
    // ------------------------------------------------------------------

    /**
     * 返回 true 表示这个键被 OSD 吃掉了。
     *
     * ⛔ 语义必须与 Flutter 版一致，否则测出来的不是「画法差异」：
     *   * 纵向列表里 ↑/↓ 是**在列表里选**，不再是切分类；← / 返回键退回侧栏；
     *   * 侧栏里 ↑/↓ **循环**（最后一行再往下回到第一行）；
     *   * ←/→ 在 chips 里**不循环**，撞到两端就停，并且**跳过灰掉的**；
     *   * 没有 chips 的行，←/→ 交给外部（云影那边是「选集直接换集」）。
     */
    fun onKey(keyCode: Int): Boolean {
        if (rows.isEmpty()) return false
        val row = rows[selRow]

        if (inList) {
            when (keyCode) {
                KeyEvent.KEYCODE_DPAD_UP -> { moveChip(-1); return true }
                KeyEvent.KEYCODE_DPAD_DOWN -> { moveChip(1); return true }
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_ESCAPE -> {
                    inList = false
                    setListMode(false)
                    rebuildRight()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                    onActivate?.invoke(selRow, selChip)
                    return true
                }
                else -> return false
            }
        }

        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> { moveRow(-1); return true }
            KeyEvent.KEYCODE_DPAD_DOWN -> { moveRow(1); return true }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                if (row.options.isEmpty()) return false
                if (row.vertical) return true // 列表外没有可挪的，什么都不做
                moveChip(-1)
                return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                if (row.options.isEmpty()) return false
                if (row.vertical) { enterList(); return true }
                moveChip(1)
                return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                // ⛔ 纵向列表这一行，**OK 也是「进入列表」**，不是「直接生效」。
                //    照云影/夸克的原设计这里只有 → 能进列表，但遥控器上
                //    「按 OK 没反应」是最容易被当成 bug 的表现 —— 用户不会
                //    想到要去按方向键。两种按法都进列表，换集统一发生在列表里，
                //    这样也顺手避免了「在菜单上误按 OK 直接跳集」。
                if (row.vertical && row.options.size > 1) { enterList(); return true }
                onActivate?.invoke(selRow, if (row.options.isEmpty()) -1 else selChip)
                return true
            }
            KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_ESCAPE -> { onClose?.invoke(); return true }
            else -> return false
        }
    }

    /** 焦点进右侧纵向列表（云影的 `_inList = true`）。 */
    private fun enterList() {
        inList = true
        setListMode(true)
        rebuildRight()
    }

    private fun moveRow(delta: Int) {
        val n = rows.size
        selRow = ((selRow + delta) % n + n) % n
        selChip = currentOptionIndex()
        inList = false
        // 换行必然离开列表态：另一行要么是 chips，要么没有选项。
        setListMode(false)
        applySidebarSelection()
        rebuildRight()
    }

    private fun moveChip(delta: Int) {
        val opts = rows[selRow].options
        var i = selChip
        while (true) {
            i += delta
            if (i < 0 || i >= opts.size) return
            if (rows[selRow].isEnabled(i)) break
        }
        if (i == selChip) return
        selChip = i
        if (inList) {
            listAdapter?.notifyDataSetChanged()
            listView?.setSelection(selChip)
        } else {
            applyChipSelection()
        }
    }

    // ------------------------------------------------------------------
    // 视图
    // ------------------------------------------------------------------

    private fun rebuildSidebar() {
        sidebarBox.removeAllViews()
        tileViews.clear()
        for ((i, r) in rows.withIndex()) {
            val tv = TextView(context).apply {
                text = r.label
                setTextColor(if (i == selRow) Color.WHITE else MUTED)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(18f).toInt(), 0, dp(8f).toInt(), 0)
                background = tileBackground(i == selRow)
            }
            sidebarBox.addView(tv, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(TILE_H).toInt(),
            ))
            tileViews.add(tv)
        }
    }

    private fun applySidebarSelection() {
        for ((i, tv) in tileViews.withIndex()) {
            tv.setTextColor(if (i == selRow) Color.WHITE else MUTED)
            tv.background = tileBackground(i == selRow)
        }
    }

    private fun rebuildRight() {
        rightHost.removeAllViews()
        chipRow = null
        chipStrip = null
        chipViews = ArrayList()
        listView = null
        listAdapter = null
        headerLabel = null
        headerValue = null

        val row = rows[selRow]
        val root = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }

        // 标题行（图标位置留白，原生这里不引图标字体）
        val head = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        headerLabel = TextView(context).apply {
            text = row.label
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        }
        headerValue = TextView(context).apply {
            text = if (row.value.isEmpty()) "—" else row.value
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        head.addView(headerLabel, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { marginEnd = dp(12f).toInt() })
        head.addView(headerValue, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f,
        ))
        root.addView(head, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dp(12f).toInt() })

        when {
            row.options.isEmpty() -> {
                val tv = TextView(context).apply {
                    text = row.hint.orEmpty()
                    setTextColor(MUTED)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                }
                root.addView(tv, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ))
            }

            row.vertical -> {
                // 云影那边是 `ListView.builder`（懒构建）。这里用框架 `ListView`
                // + 自定义 adapter 对齐同一条路：**不预建 N 个 View**。
                val lv = ListView(context).apply {
                    divider = null
                    dividerHeight = 0
                    setPadding(0, 0, dp(4f).toInt(), 0)
                    clipToPadding = false
                    isVerticalScrollBarEnabled = false
                }
                val adapter = RowListAdapter(row)
                lv.adapter = adapter
                lv.setSelection(selChip)
                listView = lv
                listAdapter = adapter
                root.addView(lv, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
                ))
            }

            else -> {
                val strip = HorizontalScrollView(context).apply {
                    isHorizontalScrollBarEnabled = false
                    clipToPadding = false
                }
                val rowBox = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
                chipViews = ArrayList()
                for ((i, label) in row.options.withIndex()) {
                    val chip = TextView(context).apply {
                        text = label
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                        gravity = Gravity.CENTER
                        setPadding(dp(14f).toInt(), 0, dp(14f).toInt(), 0)
                        background = chipBackground(row, i)
                        setTextColor(chipTextColor(row, i))
                        // ⛔ 单个 chip 的宽度上限：调用方给短名（`4K` / `超清`），但
                        //    服务端偶尔会给出映射表里没有的档位 id（`tierLabel` 会
                        //    原样回退），那种串能一个 chip 撑满整行、把后面的档全顶
                        //    出面板。截断比撑破好 —— 完整档位名在 `CloudCine` 日志里。
                        maxLines = 1
                        ellipsize = android.text.TextUtils.TruncateAt.END
                        maxWidth = dp(MAX_CHIP_W).toInt()
                    }
                    chipViews.add(chip)
                    rowBox.addView(chip, LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, dp(CHIP_H).toInt(),
                    ).apply { marginEnd = dp(10f).toInt() })
                }
                strip.addView(rowBox)
                chipRow = rowBox
                chipStrip = strip
                root.addView(strip, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(CHIP_H).toInt(),
                ))
                // 重建之后 chips 还没测量，`scrollChipIntoView` 读到的宽度是 0。
                // 排到下一拍，让「打开菜单时光标停在当前生效项」也能立刻被滚到
                // 可见区里 —— 否则菜单一开，用户看到的是一个空白的 chip 行。
                strip.post { scrollChipIntoView() }
            }
        }

        rightHost.addView(root, LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
        ))
    }

    private fun applyChipSelection() {
        val row = rows.getOrNull(selRow) ?: return
        for ((i, tv) in chipViews.withIndex()) {
            tv.background = chipBackground(row, i)
            tv.setTextColor(chipTextColor(row, i))
        }
        scrollChipIntoView()
    }

    /**
     * 把当前选中的 chip 滚进可视区。
     *
     * ⛔ 用 `scrollTo`（**瞬间**）而不是 `smoothScrollTo`：这台电视上 OSD 的
     *    整个设计取舍就是「一帧到位、不做动画」（见类注释），这里跟着动画
     *    会让「按键→上屏」的测量多出一段无谓的时间。
     * ⛔ 只在**真的越界**时才滚，否则每次按键都 `scrollTo` 会把用户手动滚过
     *    的位置弹回去。
     */
    private fun scrollChipIntoView() {
        val strip = chipStrip ?: return
        val chip = chipViews.getOrNull(selChip) ?: return
        val viewW = strip.width
        if (viewW <= 0) return
        // chip 的父节点就是 strip 的内容根，所以 `chip.left/right` 就是内容坐标。
        val pad = dp(24f).toInt()
        val cur = strip.scrollX
        val target = when {
            chip.left - pad < cur -> chip.left - pad
            chip.right + pad > cur + viewW -> chip.right + pad - viewW
            else -> return
        }
        strip.scrollTo(target.coerceAtLeast(0), 0)
    }

    // ------------------------------------------------------------------
    // 画法：圆角只画在背景上，不做裁剪、不加阴影、不做动画
    // ------------------------------------------------------------------

    private fun cardBackground() = GradientDrawable().apply {
        orientation = GradientDrawable.Orientation.TOP_BOTTOM
        colors = intArrayOf(CARD_TOP, CARD_BOTTOM)
        val r = dp(22f)
        // 只有上面两个角是圆的：它贴着屏幕下缘，下面两个角本来就看不见。
        cornerRadii = floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
        setStroke(dp(0.8f).toInt().coerceAtLeast(1), 0x24FFFFFF)
    }

    private fun tileBackground(selected: Boolean) = GradientDrawable().apply {
        cornerRadius = dp(8f)
        setColor(if (selected) 0x1AFFFFFF else Color.TRANSPARENT)
    }

    private fun chipBackground(row: Row, i: Int) = GradientDrawable().apply {
        cornerRadius = dp(8f)
        setColor(
            when {
                i == selChip && row.isEnabled(i) -> ACCENT
                row.isEnabled(i) -> 0x14FFFFFF
                else -> 0x0AFFFFFF
            }
        )
    }

    private fun chipTextColor(row: Row, i: Int): Int = when {
        i == selChip && row.isEnabled(i) -> Color.WHITE
        row.isEnabled(i) -> 0xFFD3D1C7.toInt()
        else -> DIM
    }

    private fun dp(v: Float): Float = v * resources.displayMetrics.density

    /**
     * 菜单卡片贴底占用的**总高度**（px，含底边距）。
     *
     * 给字幕用：菜单打开时字幕必须抬到卡片上沿（见 `PlayerActivity.updateSubtitleInset`），
     * 而卡片几何（`SAFE_V` / `CARD_H`）只在本类里。
     *
     * ⛔ 别让调用方另抄一份 `27 + 7×40 + 28` 的算式 —— 几何一改两边就不一致，
     *    表现是「菜单一开字幕正好被压在菜单上」，而且只在某些行数下才露馅。
     */
    fun sheetHeightPx(): Int = dp(SAFE_V).toInt() + cardHeightPx()

    /**
     * 卡片**当前实际**高度（px）。
     *
     * ⛔ 必须读实测值，不能拿 `CARD_H` 算：行数会变（有没有选集行）、
     *    展开纵向列表时还会长高。拿常量算的表现是「菜单一开字幕正好压在
     *    菜单上」，而且**只在某些行数下才露馅** —— 极难复现。
     */
    fun cardHeightPx(): Int =
        card.layoutParams?.height?.takeIf { it > 0 } ?: dp(CARD_H).toInt()

    /**
     * 纵向列表的 adapter —— 一行 = **封面 + 集号 + 文件名**。
     *
     * ## 三个状态必须能同时分辨
     *
     * | 状态 | 画法 |
     * |---|---|
     * | **光标**（用户此刻停在这） | 实心 ACCENT 圆角块 + 左侧 4dp **白**条 + 白字 |
     * | **正在播**（现在放的就是它） | 左侧 4dp **ACCENT** 条 + 标题前缀 `▶` + 标题亮白 |
     * | 其它 | 无条，标题常规色、副标题压暗 |
     *
     * ⛔ 「光标」与「正在播」**是两件事**，必须分开画：打开菜单时光标落在
     *    正在播的那一集上（`Row.active`），用户按一下 ↓ 之后两者就分家了。
     *    只画一个的话，用户会以为自己刚才把正在播的那集切掉了 ——
     *    而实际上什么都没发生。
     * ⛔ 一律**不画边框**（用户就这条提过三次）：对比全部来自实心面的明度。
     */
    private inner class RowListAdapter(private val row: Row) : BaseAdapter() {
        override fun getCount(): Int = row.options.size
        override fun getItem(position: Int): Any = row.options[position]
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val cell = (convertView as? LinearLayout) ?: buildListRow()
            val bar = cell.getChildAt(0) as View
            val thumbBox = cell.getChildAt(1) as FrameLayout
            val image = thumbBox.getChildAt(0) as ImageView
            val placeholder = thumbBox.getChildAt(1) as TextView
            val textBox = cell.getChildAt(2) as LinearLayout
            val title = textBox.getChildAt(0) as TextView
            val strip = textBox.getChildAt(1) as LinearLayout

            val selected = position == selChip
            val playing = position == row.active
            val enabled = row.isEnabled(position)

            // ── 封面 ──────────────────────────────────────────────
            val url = row.thumbAt(position)
            val bmp = if (url.isEmpty()) null else thumbs?.cached(url)
            if (bmp != null) {
                image.setImageBitmap(bmp)
                image.visibility = View.VISIBLE
                placeholder.visibility = View.GONE
            } else {
                image.setImageDrawable(null)
                image.visibility = View.INVISIBLE
                // ⛔ 占位块上写**集号**而不是「无封面」：集号本来就要靠
                //    标题那一行读，缩略图位空着不如让它承担同样的信息 ——
                //    而且服务端对约三成视频根本没生成过预览图，那个位置
                //    长期是空的，写「无封面」等于三成条目挂着一句废话。
                placeholder.text = row.options[position].take(6)
                placeholder.visibility = View.VISIBLE
                // 没下过、也没确认拿不到 → 排一次后台下载。
                if (url.isNotEmpty() && thumbs?.isKnownBad(url) != true) {
                    val self = this
                    thumbs?.fetch(url, dp(LIST_THUMB_W).toInt()) {
                        // ⛔ `post` 不能省：`getView` 有可能就在这一拍里被调用，
                        //    而**在布局过程中 `notifyDataSetChanged` 会抛
                        //    「The content of the adapter has changed but
                        //    ListView did not receive a notification」**。
                        // ⛔ 还要确认这期间菜单没被重建成别的 adapter。
                        listView?.post { if (listAdapter === self) self.notifyDataSetChanged() }
                    }
                }
            }
            // 选中行整块是 ACCENT 实心，图片也压暗一点，免得亮图盖过白字。
            image.alpha = if (selected) 0.75f else 1f
            placeholder.alpha = image.alpha

            // ── 左侧竖条 ──────────────────────────────────────────
            bar.setBackgroundColor(
                when {
                    selected -> Color.WHITE
                    playing -> ACCENT
                    else -> Color.TRANSPARENT
                }
            )

            // ── 文字 ──────────────────────────────────────────────
            title.text = if (playing) "▶ ${row.options[position]}" else row.options[position]
            title.setTextColor(
                when {
                    selected -> Color.WHITE
                    !enabled -> DIM
                    playing -> Color.WHITE
                    else -> 0xFFD3D1C7.toInt()
                }
            )

            // ── 历史进度条 ────────────────────────────────────────
            val fraction = row.progressAt(position)
            if (fraction < 0.0) {
                strip.visibility = View.GONE
            } else {
                strip.visibility = View.VISIBLE
                val f = fraction.coerceIn(0.0, 1.0)
                (strip.getChildAt(0).layoutParams as LinearLayout.LayoutParams).weight = f.toFloat()
                (strip.getChildAt(1).layoutParams as LinearLayout.LayoutParams).weight =
                    (1.0 - f).toFloat()
                // 选中行整块已经是 ACCENT 实心，再用品牌紫画进度条就糊成一片
                // ⇒ 选中时改画**白色**，靠明度差把「看过多少」说清楚。
                strip.getChildAt(0).setBackgroundColor(if (selected) Color.WHITE else ACCENT)
                strip.requestLayout()
            }

            cell.background = GradientDrawable().apply {
                cornerRadius = dp(8f)
                setColor(if (selected) ACCENT else Color.TRANSPARENT)
            }
            cell.layoutParams = AbsListView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(LIST_ROW_H).toInt(),
            )
            return cell
        }

        /**
         * 造一行的骨架。子节点**顺序即契约**（`getView` 按下标取）：
         * `[0] 竖条 · [1] 封面框{图, 占位字} · [2] 文字列{文件名, 进度条{看过, 没看}}`。
         */
        private fun buildListRow(): LinearLayout {
            val cell = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8f).toInt(), 0, dp(12f).toInt(), 0)
            }

            cell.addView(
                View(context),
                LinearLayout.LayoutParams(dp(4f).toInt(), ViewGroup.LayoutParams.MATCH_PARENT)
                    .apply { marginEnd = dp(10f).toInt() },
            )

            val thumbBox = FrameLayout(context)
            thumbBox.addView(
                ImageView(context).apply {
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    setBackgroundColor(0xFF232833.toInt())
                },
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            thumbBox.addView(
                TextView(context).apply {
                    setTextColor(0xFF6B7686.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    gravity = Gravity.CENTER
                    setBackgroundColor(0xFF232833.toInt())
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                },
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
                ),
            )
            cell.addView(
                thumbBox,
                LinearLayout.LayoutParams(
                    dp(LIST_THUMB_W).toInt(), dp(LIST_THUMB_H).toInt(),
                ),
            )

            val textBox = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
            textBox.addView(
                TextView(context).apply {
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
            // 历史进度条 —— 与海报墙那条（`LibraryActivity.paintProgress`）
            // **同一套画法**：一条细槽，按比例分成「看过 / 没看」两段。
            // ⛔ 用权重分段而不是「设固定宽度」：行宽会随卡片宽度变，
            //    固定宽度在窄屏上会溢出、在宽屏上只剩下半截。
            val strip = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                setBackgroundColor(0x33FFFFFF)
            }
            strip.addView(View(context), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0f))
            strip.addView(View(context), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            textBox.addView(
                strip,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(PROGRESS_H).toInt(),
                ).apply { topMargin = dp(6f).toInt() },
            )
            cell.addView(
                textBox,
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                    .apply { marginStart = dp(12f).toInt() },
            )
            return cell
        }
    }

    private companion object {
        const val SAFE_H = 48f
        const val SAFE_V = 27f
        const val SIDEBAR_W = 180f
        const val TILE_H = 40f
        const val SIDEBAR_PAD_V = 14f

        /**
         * 卡片高度：`行数 × 40 + 上下内边距 28 + 0.8`（与云影
         * `kPlayerTvSheetHeight` 同一个算式）。
         *
         * ⛔ 这是**「7 行时」的取值**，不是恒定值 —— 真实高度由
         *    [targetCardHeightDp] 按当前行数算（Android 侧多了「选集」行，
         *    也多了展开态）。这个常量留下来只做「还没绑过数据」时的兜底，
         *    以及给单测一个对照值。
         */
        const val CARD_H = 7 * TILE_H + 28f + 0.8f
        const val CHIP_H = 34f

        /**
         * 展开纵向列表（选集）时的卡片高度（dp）。
         *
         * ## 为什么必须长高
         *
         * 1080p 电视在 dp 口径下只有 **540dp 高**，卡片默认高度
         * （8 行 = 348.8dp）里能分给右侧列表的只有约 240dp。一行「封面 +
         * 集号 + 文件名」最少要 60dp ⇒ **一屏只看得见 4 集**。一部 24 集的
         * 剧要按 6 屏方向键才能到底 —— 那已经不是「不好用」，是「没法用」。
         *
         * 460dp 时右侧列表能放 **6 行**，且卡片顶沿仍在屏幕上方 50dp 处
         * （`SAFE_V` 27 + 460 = 487 < 540），不会顶到状态栏 / 安全区。
         * ⛔ 再高就会盖住左上角的调试浮层（`StatsOverlay`，贴 `topMargin 27dp`）。
         */
        const val CARD_LIST_H = 460f

        /** 纵向列表一行的高度（dp）：封面 54 + 上下各 3 的呼吸位。 */
        const val LIST_ROW_H = 60f

        /** 列表行里封面的尺寸（dp）。16:9，与夸克 `preview_url` 同比例。 */
        const val LIST_THUMB_W = 96f
        const val LIST_THUMB_H = 54f

        /**
         * 列表行里那条历史进度条的高度（dp）。
         *
         * 3dp 是「沙发距离下看得见比例、又不至于抢了文件名」的值 ——
         * 与海报墙上那条同厚。
         */
        const val PROGRESS_H = 3f

        /**
         * 单个 chip 的宽度上限（dp）。
         *
         * 面板右侧可用宽度 ≈ 屏幕宽 − `SAFE_H` − `SIDEBAR_W`，在 1080p 上约 560dp；
         * 取 160dp 是「放得下 5~6 个汉字，但绝不至于一个 chip 占掉半行」。
         */
        const val MAX_CHIP_W = 160f

        const val CARD_TOP = 0xFA262E42.toInt()
        const val CARD_BOTTOM = 0xF5141824.toInt()
        const val ACCENT = 0xFF7F77DD.toInt()
        const val MUTED = 0xFF9AA3B2.toInt()
        const val DIM = 0xFF5F6875.toInt()
    }
}
