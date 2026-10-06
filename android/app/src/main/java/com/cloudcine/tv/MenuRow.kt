package com.cloudcine.tv

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 覆盖层菜单的一行 —— **选中态是实心圆角块 + 左侧强调竖条，没有线框**。
 *
 * ## 为什么抽成共用组件
 *
 * 两个页面各有一份菜单（[LibraryActivity] 的媒体库菜单、[BrowseActivity] 的
 * 云影菜单）。各写一份的话，改了一边忘另一边 —— 用户在两个页面会看到
 * 两种不同的高亮样式，而「样式不一致」是最容易被一眼看出来、又最难被
 * 代码审查发现的缺陷。
 *
 * ## ⛔ 为什么不用描边（线框）
 *
 * 之前选中态是一个**直角矩形色块**，光标态是**一圈 2dp 描边**。两者在
 * 电视上都不成立：
 *   * 直角矩形和菜单卡片自己的圆角打架，看着像「没对齐的色块」；
 *   * 描边在深色底 + 沙发距离下**只剩一条 1~2px 的细线**，既看不清也
 *     不高级 —— 而「高级」在深色 UI 里靠的是**实心面的明度层次**，
 *     不是轮廓线。
 * 所以这里全部改成实心：选中 = 品牌色深底 + 白字 + 左侧竖条，
 * 未选中 = 透明底 + 次级文字。两者只差明度，不差轮廓。
 */
object MenuRow {

    private const val ACCENT = 0xFFA9A3F5.toInt()

    /** 选中行的底色。比品牌色暗、比卡片亮 —— 落在两者中间才有层次。 */
    private const val SELECT_FILL = 0xFF3A3268.toInt()

    private const val TEXT = 0xFFC9D0DB.toInt()

    /** 造一行。返回的是 `LinearLayout`（`[0]` 竖条 / `[1]` 文字）。 */
    fun create(ctx: Context, label: String): View {
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(ctx, 8), dp(ctx, 11), dp(ctx, 14), dp(ctx, 11))
        }

        // ⛔ 竖条用**独立 View**，不用 `GradientDrawable.setStroke` ——
        //    描边是四边一圈，做不出「只在左边」。用 `INVISIBLE` 而不是
        //    `GONE` 保留占位，否则选中/未选中的文字会左右跳动。
        row.addView(
            View(ctx).apply { setBackgroundColor(ACCENT) },
            LinearLayout.LayoutParams(dp(ctx, 4), dp(ctx, 20)).apply {
                rightMargin = dp(ctx, 12)
            },
        )
        row.addView(
            TextView(ctx).apply {
                text = label
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        paint(row, false)
        return row
    }

    /** 重画选中态。`row` 必须是 [create] 的返回值。 */
    fun paint(row: View, selected: Boolean) {
        if (row !is LinearLayout || row.childCount < 2) return
        val ctx = row.context
        row.getChildAt(0).visibility = if (selected) View.VISIBLE else View.INVISIBLE
        (row.getChildAt(1) as TextView).setTextColor(if (selected) Color.WHITE else TEXT)
        row.background = GradientDrawable().apply {
            cornerRadius = dp(ctx, 10).toFloat()
            setColor(if (selected) SELECT_FILL else Color.TRANSPARENT)
        }
    }

    private fun dp(ctx: Context, v: Int): Int = (v * ctx.resources.displayMetrics.density).toInt()
}
