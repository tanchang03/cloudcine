package com.cloudcine.tv

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
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
    ) {
        fun isEnabled(i: Int): Boolean = enabled.getOrElse(i) { true }
    }

    var onActivate: ((row: Int, chip: Int) -> Unit)? = null
    var onClose: (() -> Unit)? = null

    /** 当前是否已把焦点「进入」纵向列表（云影的 `_inList`）。 */
    var inList: Boolean = false
        private set

    private val card: LinearLayout
    private val sidebarBox: LinearLayout
    private val rightHost: FrameLayout
    private val tileViews = ArrayList<TextView>()

    private var rows: List<Row> = emptyList()
    private var selRow = 0
    private var selChip = 0

    private var chipRow: LinearLayout? = null
    private var chipViews = ArrayList<TextView>()
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
        applySidebarSelection()
        rebuildRight()
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
                if (row.vertical) { inList = true; rebuildRight(); return true }
                moveChip(1)
                return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                onActivate?.invoke(selRow, if (row.options.isEmpty()) -1 else selChip)
                return true
            }
            KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_ESCAPE -> { onClose?.invoke(); return true }
            else -> return false
        }
    }

    private fun moveRow(delta: Int) {
        val n = rows.size
        selRow = ((selRow + delta) % n + n) % n
        selChip = currentOptionIndex()
        inList = false
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
                    }
                    chipViews.add(chip)
                    rowBox.addView(chip, LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, dp(CHIP_H).toInt(),
                    ).apply { marginEnd = dp(10f).toInt() })
                }
                strip.addView(rowBox)
                chipRow = rowBox
                root.addView(strip, LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(CHIP_H).toInt(),
                ))
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

    /** 纵向列表的 adapter —— 一行一个 TextView，选中态蓝底（照对标播放器）。 */
    private inner class RowListAdapter(private val row: Row) : BaseAdapter() {
        override fun getCount(): Int = row.options.size
        override fun getItem(position: Int): Any = row.options[position]
        override fun getItemId(position: Int): Long = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val tv = (convertView as? TextView) ?: TextView(context).apply {
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14.5f)
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(14f).toInt(), 0, dp(10f).toInt(), 0)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }
            val selected = position == selChip
            tv.text = row.options[position]
            tv.background = GradientDrawable().apply {
                cornerRadius = dp(8f)
                setColor(if (selected) ACCENT else Color.TRANSPARENT)
            }
            tv.setTextColor(
                if (selected) Color.WHITE
                else if (row.isEnabled(position)) 0xFFD3D1C7.toInt() else DIM
            )
            tv.layoutParams = android.widget.AbsListView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(36f).toInt(),
            )
            return tv
        }
    }

    private companion object {
        const val SAFE_H = 48f
        const val SAFE_V = 27f
        const val SIDEBAR_W = 180f
        const val TILE_H = 40f
        const val SIDEBAR_PAD_V = 14f

        /** 7 × 40 + 28 + 0.8（与云影 `kPlayerTvSheetHeight` 同一个算式）。 */
        const val CARD_H = 7 * TILE_H + 28f + 0.8f
        const val CHIP_H = 34f

        const val CARD_TOP = 0xFA262E42.toInt()
        const val CARD_BOTTOM = 0xF5141824.toInt()
        const val ACCENT = 0xFF7F77DD.toInt()
        const val MUTED = 0xFF9AA3B2.toInt()
        const val DIM = 0xFF5F6875.toInt()
    }
}
