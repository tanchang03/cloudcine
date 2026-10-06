package com.cloudcine.kuake

import android.content.Context
import android.util.AttributeSet
import android.widget.FrameLayout

/**
 * 按**片源宽高比**给子 View 定界的容器（letterbox / pillarbox）。
 *
 * ## 为什么必须有它
 *
 * `ExoPlayer.setVideoSurfaceView()` 之后，解码器直接把画面写进 Surface 的
 * buffer，而 Surface 的 buffer 尺寸**就是片源尺寸**（实测 1440×612）。
 * 但 `SurfaceView` 这个 **View** 会把 buffer 拉伸铺满自己的 bounds ——
 * 如果 bounds 是 `MATCH_PARENT`（1920×1080），画面就被**非等比拉伸**：
 * 2.35:1 的宽银幕电影在 16:9 屏上被横向拉长，人脸变扁。
 *
 * 所以这里做两件事：
 *   1. `onMeasure` —— 子 View 按 `aspectRatio` 缩放到父容器内**最大可能的等比矩形**；
 *   2. `onLayout` —— 把子 View **居中**，剩下的区域留给父容器的黑底当信箱边。
 *
 * ## ⛔ 它只包 SurfaceView，不包 OSD
 *
 * OSD 与统计浮层必须是外层 `FrameLayout` 的兄弟节点、铺满整屏 ——
 * 否则菜单会被一起压进画面矩形里，在信箱边上留下一圈永远点不到的死区。
 *
 * ## 为什么不用 `media3-ui` 的 `AspectRatioFrameLayout`
 *
 * 本工程刻意不引 `media3-ui`（Gradle 缓存里没有，且它会带进 `PlayerView` 的
 * 控制栏，把「原生 OSD 到底贵不贵」这个变量搅浑）。这个类只有几十行。
 */
class AspectRatioFrameLayout @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {

    /** 宽 / 高。**`0` 表示「还不知道片源尺寸」→ 退回铺满**。 */
    private var aspectRatio = 0f

    /**
     * @param ratio 宽高比（宽 ÷ 高）。传 `0` 或负数表示「还不知道」，
     *   此时按铺满处理 —— 起播前那一小段黑屏比留一圈莫名其妙的黑边好。
     */
    fun setAspectRatio(ratio: Float) {
        if (ratio <= 0f || ratio.isNaN() || ratio.isInfinite()) {
            if (aspectRatio == 0f) return
            aspectRatio = 0f
        } else {
            if (kotlin.math.abs(aspectRatio - ratio) < 0.0001f) return
            aspectRatio = ratio
        }
        requestLayout()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val parentW = MeasureSpec.getSize(widthMeasureSpec)
        val parentH = MeasureSpec.getSize(heightMeasureSpec)

        // 自己永远铺满父容器（黑底由 setBackgroundColor 提供）。
        setMeasuredDimension(parentW, parentH)

        var childW = parentW
        var childH = parentH
        if (aspectRatio > 0f && parentW > 0 && parentH > 0) {
            // 先按满宽算高；若超出父高，就改成按满高算宽。
            childH = (parentW / aspectRatio + 0.5f).toInt()
            if (childH > parentH) {
                childH = parentH
                childW = (parentH * aspectRatio + 0.5f).toInt()
            }
            childW = childW.coerceAtLeast(1)
            childH = childH.coerceAtLeast(1)
        }

        for (i in 0 until childCount) {
            getChildAt(i).measure(
                MeasureSpec.makeMeasureSpec(childW, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(childH, MeasureSpec.EXACTLY),
            )
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val w = right - left
        val h = bottom - top
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            val cw = child.measuredWidth
            val ch = child.measuredHeight
            val cl = (w - cw) / 2
            val ct = (h - ch) / 2
            child.layout(cl, ct, cl + cw, ct + ch)
        }
    }
}
