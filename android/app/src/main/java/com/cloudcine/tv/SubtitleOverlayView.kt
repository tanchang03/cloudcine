package com.cloudcine.tv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Log
import android.view.View
import androidx.media3.common.text.Cue

/**
 * 内嵌字幕的**绘制出口**。
 *
 * ## 为什么必须有这个类（2026-10-06 定案）
 *
 * `androidx.media3.exoplayer.text.TextRenderer` 的构造签名是
 * `TextRenderer(TextOutput output, Looper looper, …)` —— 它**要一个出口**。
 * 而本工程刻意不引 `media3-ui`（见 `AspectRatioFrameLayout` 的注释），也就
 * 没有 `PlayerView` / `SubtitleView` 这两个现成的 `TextOutput`，画面又是裸
 * `SurfaceView`（`setVideoSurfaceView`）。于是：
 *
 *   * 轨道**选得上**（`setOverrideForType` 生效，`onTracksChanged` 里
 *     `#0 西班牙语 … ← 选中`、菜单高亮正确）；
 *   * cue 也被 `CueDecoder` **解出来了**（`TextRenderer` 自带该字段，
 *     `application/x-media3-cues` 就是它认的格式）；
 *   * 但**没有任何 `TextOutput` 注册在 ExoPlayer 上** ⇒ 解出来的 cue
 *     被**直接丢掉**，屏幕上什么都没有，且**一条错都不报**。
 *
 * 这正是「选内嵌字幕成功、但字幕不上屏」的真因。本类补上那个出口：
 * `PlayerActivity` 在已有的 `Player.Listener` 里接 `onCues(CueGroup)`，
 * 把 `cueGroup.cues` 交过来画。
 *
 * ## 为什么不用 `media3-ui` 的 `SubtitleView`
 *
 * 两条路都能通。引 `media3-ui` 只需 `SubtitleView` 一个类（它本身就是
 * `TextOutput`），排版/位图/PGS 都是现成的；但 `media3-ui` **不在 Gradle
 * 缓存里**，会破坏「离线可构建」。本类只覆盖本片源实际会用到的两种情况 ——
 * **文字**（`Cue.text`，本片 7 条内嵌字幕全是这种）与**位图**（`Cue.bitmap`，
 * PGS/VobSub）—— 用不到一百行，换来零新依赖。
 *
 * ## 与 OSD / 控制栏的关系
 *
 * 字幕是**外层 `FrameLayout` 的兄弟节点**（与统计浮层同理），不放进
 * `AspectRatioFrameLayout`：它要能盖到信箱边上，而且要在 OSD 打开时**抬到
 * 菜单上方**。抬高由 [bottomInsetPx] 控制，值由 `PlayerActivity` 按
 * 控制栏 / OSD 的可见状态算（见那边的 `updateSubtitleInset`）。
 *
 * ## 性能
 *
 * `onCues` 是**按字幕事件**回调的（不是每帧），但为稳妥起见这里仍按内容做了
 * 去重（[signature]）——同一批 cue 重复送达时直接 return，不重排
 * `StaticLayout`。这台电视只有 4 核，字幕不该跟解码抢 CPU。
 */
class SubtitleOverlayView(context: Context) : View(context) {

    private var cues: List<Cue> = emptyList()

    /** 上次画的内容指纹，用来吃掉重复的 `onCues`。 */
    private var signature: String? = null

    private var loggedFirstCue = false

    /** 容器给的原始对齐只记一次，用来确认「右对齐」这个判断。 */
    private var loggedAlignment = false

    /**
     * 字幕底距（px）。**0 表示贴 View 底部**。
     *
     * ⛔ 由 `PlayerActivity.updateSubtitleInset()` 改写，别在这里算 ——
     *    它要同时知道控制栏高度与 OSD 卡片高度，那两样只有 Activity 有。
     */
    var bottomInsetPx: Int = 0
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        // ⛔ 必须是 LEFT：换行/对齐由 `StaticLayout` 的 Alignment 负责，
        //    把 textAlign 设成 CENTER 会让 `drawText` 再偏一次，整块文字飞出屏幕。
        textAlign = Paint.Align.LEFT
    }

    private val windowPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)

    private val dst = Rect()
    private val box = RectF()

    init {
        // 纯 `View` 默认就会走 onDraw，这里只是把意图写明（被包进 ViewGroup 后
        // 若有人调 setWillNotDraw(true)，字幕会静默消失）。
        setWillNotDraw(false)
    }

    /**
     * 交给上屏的一批 cue。**空列表 = 清屏**（ExoPlayer 在字幕间隙会回传空）。
     *
     * ⚠️ `CueGroup.cues` 是 `ImmutableList`，可以安全持有到下次回调 ——
     *    但本类不依赖这一点：只在内容变化时替换引用。
     */
    fun setCues(newCues: List<Cue>) {
        val sig = signatureOf(newCues)
        if (sig == signature) return
        signature = sig
        cues = newCues
        if (newCues.isNotEmpty() && !loggedFirstCue) {
            loggedFirstCue = true
            // ⛔ 这条日志是**唯一**能证明「出口通了」的现场证据：硬件视频层下
            //    `screencap` 全黑、播放中 `uiautomator dump` 也拿不到画面。
            Log.i(TAG, "首条字幕上屏：${newCues.size} 条 · ${newCues.firstOrNull()?.text}")
        }
        invalidate()
    }

    /**
     * 内容指纹。
     *
     * ⛔ 别用 `List<Cue>.equals`：`Cue.text` 常是 `SpannableString` 之类**没有
     *    重写 equals** 的 CharSequence，逐次回调都会判「不等」⇒ 每拍重排一次
     *    `StaticLayout`。这里只取**文字本身**与**位图身份**。
     */
    private fun signatureOf(list: List<Cue>): String {
        if (list.isEmpty()) return ""
        val sb = StringBuilder(list.size * 16)
        for (c in list) {
            val bmp = c.bitmap
            if (bmp != null) {
                sb.append('B').append(System.identityHashCode(bmp))
            } else {
                sb.append('T').append(c.text ?: "")
            }
            sb.append('\u0001')
        }
        return sb.toString()
    }

    override fun onDraw(canvas: Canvas) {
        val list = cues
        if (list.isEmpty()) return

        // 从下往上叠：**最后一条贴底**（与播放器一致），前面的往上排。
        var bottom = (height - bottomInsetPx).toFloat()
        for (i in list.indices.reversed()) {
            val cue = list[i]
            val bmp = cue.bitmap
            bottom = if (bmp != null) {
                drawBitmapCue(canvas, bmp, cue, bottom)
            } else {
                drawTextCue(canvas, cue, bottom)
            }
        }
    }

    // ------------------------------------------------------------------
    // 文字字幕
    // ------------------------------------------------------------------

    private fun drawTextCue(canvas: Canvas, cue: Cue, bottom: Float): Float {
        val text = cue.text
        if (text.isNullOrBlank()) return bottom

        val size = textSizePx(cue)
        textPaint.textSize = size
        // 描边随字号缩放 —— 电视上亮画面里没这层黑边，白字会糊掉。
        textPaint.setShadowLayer(size * 0.14f, 0f, size * 0.05f, SHADOW_COLOR)

        val sidePad = width * SIDE_PAD_FRACTION
        val maxWidth = (width - 2 * sidePad).coerceAtLeast(1f).toInt()

        // ⛔⛔ **一律居中，忽略 `cue.textAlignment`**（2026-10-06 修正）。
        //
        // 本片源（`tx3g → application/x-media3-cues`）给每条 cue 带的
        // `textAlignment` 是**右对齐**。照搬进 `StaticLayout` 后，每行会在
        // maxWidth 里靠右排，整块字幕就贴到屏幕右边 —— 就是用户看到的
        // 「字幕右对齐，好奇怪」。
        //
        // 字幕的行业默认就是**居中**；`textAlignment` 只在做竖排/特殊定位
        // 时才值得尊重，而那类 cue 本工程不处理。恒居中永远不会错。
        if (cue.textAlignment != null && !loggedAlignment) {
            loggedAlignment = true
            Log.i(TAG, "容器给的原始对齐 = ${cue.textAlignment}（已忽略，一律居中）")
        }

        @Suppress("DEPRECATION")
        val layout = StaticLayout(
            text, textPaint, maxWidth, Layout.Alignment.ALIGN_CENTER, 1f, 0f, false,
        )

        // 真实文字块宽度：多行取最宽那行。`layout.width` 恒等于 maxWidth
        // （就是传进去的约束），所以不能拿它当文字宽度。
        var textW = 0f
        for (line in 0 until layout.lineCount) {
            textW = maxOf(textW, layout.getLineWidth(line))
        }
        val layoutW = layout.width.toFloat()

        // 摆放：`StaticLayout` 已经把**每一行**在 maxWidth 内居中，所以只要把
        // 整个 layout 盒居中，文字就居中 —— 单行/多行都对。
        val left = (width - layoutW) / 2f
        // 文字实际覆盖的水平范围（用于 `windowColor` 底色）。所有行都以 textW
        // 那条最宽行为准居中，取它的左右边界即可盖住全部行。
        val textLeft = left + (layoutW - textW) / 2f

        val top = cueTop(cue, layout.height.toFloat(), bottom)

        if (cue.windowColorSet) {
            val padH = size * 0.4f
            val padV = size * 0.16f
            windowPaint.color = cue.windowColor
            box.set(
                textLeft - padH,
                top - padV,
                textLeft + textW + padH,
                top + layout.height + padV,
            )
            canvas.drawRoundRect(box, size * 0.12f, size * 0.12f, windowPaint)
        }

        canvas.save()
        canvas.translate(left, top)
        layout.draw(canvas)
        canvas.restore()

        return top - size * LINE_GAP
    }

    /** 字号：优先用 cue 自带的，缺省按屏高定 —— 1080p 下约 52 px。 */
    private fun textSizePx(cue: Cue): Float {
        val ts = cue.textSize
        if (ts == Cue.DIMEN_UNSET || ts <= 0f) return height * DEFAULT_TEXT_FRACTION
        return when (cue.textSizeType) {
            Cue.TEXT_SIZE_TYPE_FRACTIONAL,
            Cue.TEXT_SIZE_TYPE_FRACTIONAL_IGNORE_PADDING,
            -> ts * height

            else -> ts
        }
    }

    /**
     * 这一条的**顶边** y。
     *
     * 默认贴 [bottom]（也就是从下往上叠）。只有 cue 明确给了 `line` 才改 ——
     * 本片源的 `tx3g → application/x-media3-cues` 不带定位，走的都是默认分支。
     */
    private fun cueTop(cue: Cue, h: Float, bottom: Float): Float {
        if (cue.lineType == Cue.TYPE_UNSET || cue.line == Cue.DIMEN_UNSET) return bottom - h
        val lineY = when (cue.lineType) {
            Cue.LINE_TYPE_FRACTION -> cue.line * height
            // 行号：media3 的语义是**从下往上数**（0 = 最下面一行）。
            Cue.LINE_TYPE_NUMBER -> bottom - (cue.line + 1) * h
            else -> return bottom - h
        }
        return when (cue.lineAnchor) {
            Cue.ANCHOR_TYPE_START -> lineY
            Cue.ANCHOR_TYPE_MIDDLE -> lineY - h / 2f
            else -> lineY - h
        }
    }

    // ------------------------------------------------------------------
    // 位图字幕（PGS / VobSub）
    // ------------------------------------------------------------------

    private fun drawBitmapCue(canvas: Canvas, bmp: Bitmap, cue: Cue, bottom: Float): Float {
        if (bmp.width <= 0 || bmp.height <= 0) return bottom

        var h = if (cue.bitmapHeight != Cue.DIMEN_UNSET && cue.bitmapHeight > 0f) {
            cue.bitmapHeight * height
        } else {
            bmp.height.toFloat()
        }
        var w = h * bmp.width / bmp.height
        // 别越出画面（PGS 有时按 4K 出图，屏只有 1080p）。
        val maxW = width * 0.96f
        if (w > maxW) {
            w = maxW
            h = w * bmp.height / bmp.width
        }

        val top = cueTop(cue, h, bottom)
        val cx = horizontalCenter(cue, w)
        dst.set(
            (cx - w / 2f).toInt(),
            top.toInt(),
            (cx + w / 2f).toInt(),
            (top + h).toInt(),
        )
        canvas.drawBitmap(bmp, null, dst, bitmapPaint)
        return top - h * LINE_GAP
    }

    /**
     * 水平中心。缺省屏中心；cue 给了 `position` 才按它算。
     *
     * ⚠️ `positionAnchor` 说的是「`position` 指的是这条的哪条边」，不是
     *    「往哪边对齐」—— 搞反了整条字幕会偏出半屏。
     */
    private fun horizontalCenter(cue: Cue, w: Float): Float {
        if (cue.position == Cue.DIMEN_UNSET) return width / 2f
        val p = cue.position * width
        return when (cue.positionAnchor) {
            // position 指的是这条的**左**边 ⇒ 中心要往右挪半个宽。
            Cue.ANCHOR_TYPE_START -> p + w / 2f
            // 指的是**右**边 ⇒ 往左挪半个宽。
            Cue.ANCHOR_TYPE_END -> p - w / 2f
            // MIDDLE / 未设：position 就是中心。
            else -> p
        }
    }

    private companion object {
        const val TAG = "CloudCine"

        /** 缺省字号占屏高的比例（1080p ≈ 52 px）。 */
        const val DEFAULT_TEXT_FRACTION = 0.048f

        /** 左右安全边距占屏宽的比例。 */
        const val SIDE_PAD_FRACTION = 0.05f

        /** 多条 cue 之间的行距（相对字号）。 */
        const val LINE_GAP = 0.35f

        /** 文字描边。白字 + 黑边，亮画面上也读得清。 */
        const val SHADOW_COLOR = 0xE6000000.toInt()
    }
}
