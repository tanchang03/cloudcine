package com.cloudcine.tv

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 确认框 —— 原生自绘，画法照 [TvOsdView]（同一套配色与圆角，
 * 不做裁剪/阴影/动画）。
 *
 * 两处用它：播放页问「要退出播放吗？」（[PlayerActivity]），媒体库首页问
 * 「要退出云影吗？」（[LibraryActivity]，返回键退到最底那一层时弹）。
 * 文案由 [show] 的两个参数决定，组件本身不认识任何一个业务。
 *
 * ## 交互约定
 *
 *   * `←→` 在「取消 / 退出」之间挪光标，**不循环**（与 OSD 的 chips 同一套语义）；
 *   * `OK` 执行选中的那个；
 *   * `返回` / `MENU` = **取消**（返回键永远是「退一步」，不会因为手滑退出播放）；
 *   * 默认停在**「取消」**上：退出是不可逆动作，默认项不能是危险的那个。
 *
 * ⛔ 按键**不走 View 的焦点系统**，由 `PlayerActivity.dispatchKeyEvent` 转进来
 *    （见 [onKey]）。理由与 OSD 相同：自绘控件里没有可遍历的焦点节点，
 *    交给焦点系统就会出现云影踩过的「能弹出来、方向键按不动」。
 */
class ConfirmDialogView(context: Context) : FrameLayout(context) {

    var onConfirm: (() -> Unit)? = null
    var onCancel: (() -> Unit)? = null

    private lateinit var titleView: TextView
    private val buttons = ArrayList<TextView>()

    private var selected = 0

    init {
        // 半透明黑幕，铺满整屏：既挡住画面让焦点落在框上，也让触摸不会穿到
        // 下面的进度条去。
        setBackgroundColor(0xB3000000.toInt())
        isClickable = true
        visibility = View.GONE

        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = cardBackground()
            setPadding(dp(40f).toInt(), dp(30f).toInt(), dp(40f).toInt(), dp(26f).toInt())
        }

        titleView = TextView(context).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
            gravity = Gravity.CENTER
        }
        card.addView(
            titleView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        row.addView(makeButton(0, "取消", cancel = true))
        row.addView(makeButton(1, "退出播放", cancel = false))
        card.addView(
            row,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(24f).toInt() },
        )

        addView(
            card,
            LayoutParams(
                dp(CARD_W).toInt(),
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
    }

    // ------------------------------------------------------------------

    /**
     * 弹框。
     *
     * ⛔ `confirmLabel` 默认「退出播放」（播放页），**媒体库要传「退出」** ——
     *    同一个组件在两处问的不是同一件事：那边退的是播放页，这边退的是整个 App。
     *    写死「退出播放」的话，媒体库上会问出一句读不通的话。
     */
    fun show(title: String = "要退出播放吗？", confirmLabel: String = "退出播放") {
        titleView.text = title
        buttons.getOrNull(1)?.text = confirmLabel
        // ⛔ 每次打开都回到「取消」。上一次选了「退出」再按返回取消掉，下次打开
        //    如果还停在「退出」上，一次误触就真的退出了。
        selected = 0
        applySelection()
        visibility = View.VISIBLE
    }

    fun dismiss() {
        visibility = View.GONE
    }

    val isShowing: Boolean get() = visibility == View.VISIBLE

    /**
     * 返回 true 表示这个键被框吃掉了。
     *
     * ⛔ 除返回/MENU 之外的键**一律吞掉**：弹框开着的时候，方向键绝不能漏到
     *    播放器上去触发快进/暂停。
     */
    fun onKey(keyCode: Int): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_DPAD_LEFT -> { move(-1); return true }
            KeyEvent.KEYCODE_DPAD_RIGHT -> { move(1); return true }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                activate(); return true
            }
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_ESCAPE -> {
                onCancel?.invoke(); return true
            }
            else -> return true
        }
    }

    private fun move(delta: Int) {
        val next = (selected + delta).coerceIn(0, buttons.size - 1)
        if (next == selected) return
        selected = next
        applySelection()
    }

    private fun activate() {
        if (selected == 0) onCancel?.invoke() else onConfirm?.invoke()
    }

    private fun applySelection() {
        for ((i, tv) in buttons.withIndex()) {
            tv.background = chipBackground(i == selected, cancel = i == 0)
            tv.setTextColor(if (i == selected) Color.WHITE else MUTED)
        }
    }

    private fun makeButton(index: Int, label: String, cancel: Boolean): TextView {
        val tv = TextView(context).apply {
            text = label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15.5f)
            gravity = Gravity.CENTER
            setPadding(dp(30f).toInt(), 0, dp(30f).toInt(), 0)
            background = chipBackground(index == selected, cancel)
            setTextColor(if (index == selected) Color.WHITE else MUTED)
            isClickable = true
            setOnClickListener {
                selected = index
                applySelection()
                activate()
            }
        }
        tv.layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            dp(BTN_H).toInt(),
        ).apply { if (index > 0) marginStart = dp(16f).toInt() }
        buttons.add(tv)
        return tv
    }

    private fun cardBackground() = GradientDrawable().apply {
        orientation = GradientDrawable.Orientation.TOP_BOTTOM
        colors = intArrayOf(CARD_TOP, CARD_BOTTOM)
        cornerRadius = dp(22f)
        setStroke(dp(0.8f).toInt().coerceAtLeast(1), 0x24FFFFFF)
    }

    /**
     * 「退出播放」用红底提示危险性；「取消」沿用 OSD 的强调色。
     * 未选中一律是极淡的白底，跟 OSD 的 chip 完全一致。
     */
    private fun chipBackground(selected: Boolean, cancel: Boolean) = GradientDrawable().apply {
        cornerRadius = dp(8f)
        setColor(
            when {
                selected && cancel -> ACCENT
                selected -> DANGER
                else -> 0x14FFFFFF
            }
        )
    }

    private fun dp(v: Float): Float = v * resources.displayMetrics.density

    private companion object {
        const val CARD_W = 560f
        const val BTN_H = 40f

        const val CARD_TOP = 0xFA262E42.toInt()
        const val CARD_BOTTOM = 0xF5141824.toInt()
        const val ACCENT = 0xFF7F77DD.toInt()
        const val DANGER = 0xFFD9534F.toInt()
        const val MUTED = 0xFFD3D1C7.toInt()
    }
}
