package com.cloudcine.kuake

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.media3.common.C
import androidx.media3.common.Player
import java.util.Locale

/**
 * 播放页贴底控制栏：`12:34 / 58:20` + 双层进度条 + 状态/网速。
 *
 * ## 三层进度（这是需求里最关键的一条）
 *
 * | 层 | 含义 | 来源 |
 * |---|---|---|
 * | 底色 | 整条时长（未缓冲） | — |
 * | 浅色 | **已缓冲**区间 | `player.bufferedPosition` |
 * | 亮色 | 已播放 | `player.currentPosition` |
 *
 * 用户要的「拖到已缓冲进度就立刻播、不用重新缓冲」之所以成立，是因为
 * ExoPlayer 的 `seekTo` 落在已缓冲区间内时**不需要任何网络**，直接从
 * `SampleQueue` 里出帧。所以这层浅色不是装饰 —— 它是**可以瞬时跳转的
 * 范围**的可视化。反过来，拖到浅色之外就一定得重新缓冲，界面必须先让
 * 用户看见这件事。
 *
 * ## 为什么自己画进度条，不用 `android.widget.ProgressBar`
 *
 * `ProgressBar` 的 determinate 外观由主题里的 9-patch 决定，颜色只能靠
 * tint 去染，高度也受 drawable 最小尺寸限制；而且它的 `secondaryProgress`
 * 语义是「第二进度」，绘制顺序固定。这里要的是**三色 + 圆角 + 圆形游标 +
 * 可拖拽**，自己画 40 行反而更短、更可控。
 *
 * ⛔ 控制栏**不是焦点节点**（`isFocusable = false`）：遥控器按键统一由
 * `PlayerActivity.dispatchKeyEvent` 收，跟 OSD 一样的道理 —— 一旦让它自己
 * 去抢焦点，就会出现云影踩过的「菜单能弹、方向键按不动」。
 */
class PlayerControlsView(context: Context) : LinearLayout(context) {

    private val timeText: TextView
    private val statusText: TextView
    private val seekBar: SeekBarView

    private var player: Player? = null

    /**
     * 网速来源。由 Activity 挂上 [NetRateMeter.ratePerSec]，
     * 每拍 ticker 取一次（**同一拍里只取一次**，别在别处再取 ——
     * 那会让采样点变密、窗口变短，读数开始抖）。
     */
    var networkRateSupplier: (() -> Long)? = null

    /** 用户拖完进度条后回调（比例 0..1）。 */
    var onSeek: ((Float) -> Unit)? = null

    private val ticker = object : Runnable {
        override fun run() {
            refresh()
            postDelayed(this, TICK_MS)
        }
    }

    init {
        orientation = VERTICAL
        setBackgroundColor(0xE6101216.toInt())
        setPadding(dp(48), dp(16), dp(48), dp(18))
        isFocusable = false
        isFocusableInTouchMode = false
        clipToPadding = false

        // ── 第一行：左时间、右状态 ──────────────────────────────
        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        timeText = TextView(context).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            typeface = android.graphics.Typeface.MONOSPACE
            text = "00:00 / --:--"
        }
        statusText = TextView(context).apply {
            setTextColor(0xFF8FB6FF.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.END
            text = ""
        }
        row.addView(
            timeText,
            LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f),
        )
        row.addView(
            statusText,
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT),
        )
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))

        // ── 第二行：进度条 ──────────────────────────────────────
        seekBar = SeekBarView(context).apply {
            onScrub = { ratio -> onScrubbed(ratio) }
            onCommit = { ratio -> onSeek?.invoke(ratio) }
        }
        addView(
            seekBar,
            LayoutParams(LayoutParams.MATCH_PARENT, dp(SEEK_TOUCH_DP)).apply {
                topMargin = dp(10)
            },
        )
    }

    // ------------------------------------------------------------------

    fun bind(player: Player?) {
        this.player = player
        removeCallbacks(ticker)
        refresh()
        postDelayed(ticker, TICK_MS)
    }

    fun unbind() {
        removeCallbacks(ticker)
        player = null
    }

    /** 拖拽中：只更新时间文字，不动播放器。 */
    private fun onScrubbed(ratio: Float) {
        val p = player ?: return
        val dur = durationOf(p) ?: return
        timeText.text = "${fmtTime((dur * ratio).toLong())} / ${fmtTime(dur)}"
    }

    private fun refresh() {
        val p = player ?: return
        val pos = p.currentPosition.coerceAtLeast(0L)
        val dur = durationOf(p)
        val buf = p.bufferedPosition.coerceAtLeast(pos)

        // 拖拽中不要被 ticker 抢回去 —— 否则手指还按着、时间文字自己跳。
        if (!seekBar.scrubbing) {
            timeText.text = if (dur == null) {
                "${fmtTime(pos)} / --:--"
            } else {
                "${fmtTime(pos)} / ${fmtTime(dur)}"
            }
            seekBar.progressRatio = if (dur == null || dur <= 0) 0f else (pos.toFloat() / dur)
            seekBar.bufferedRatio = if (dur == null || dur <= 0) 0f else (buf.toFloat() / dur)
        }

        // ⛔ 速率每拍**只拉一次**。拉两次 = 同一拍塞两个采样点，窗口被压短、
        //    读数开始抖，而且「窗口内无新字节就衰减到 0」这条判据也会失真。
        val rate = networkRateSupplier?.invoke() ?: 0L

        statusText.text = statusLine(p, buf - pos, rate)
        statusText.setTextColor(
            if (p.playbackState == Player.STATE_BUFFERING) {
                0xFF8FB6FF.toInt()
            } else {
                0xFFD8DEE9.toInt()
            },
        )

        // 每秒把控制栏的读数打一行。**这是必需的验证通道**：有硬件视频层时
        // `screencap` 取不到画面，而播放中 UI 永不 idle、`uiautomator dump`
        // 也拿不到 —— 不看日志就没法确认速率到底有没有在动。
        val now = SystemClock.elapsedRealtime()
        if (now - lastLogAt >= 1_000L) {
            lastLogAt = now
            Log.i(
                TAG,
                "[控制栏] ${fmtTime(pos)} / ${if (dur == null) "--:--" else fmtTime(dur)}" +
                    " · 已缓冲+${(buf - pos) / 1000}s" +
                    " · 速率 ${fmtSpeed(rate)}" +
                    " · ${statusText.text}",
            )
        }
    }

    private var lastLogAt = 0L

    /**
     * 右侧那行字。三种态：
     *   - **缓冲中** → 必须带上实时网速（用户明确要的）
     *   - **暂停** → 说清「还在持续缓冲」，否则用户会以为暂停就不下载了
     *   - **播放中** → 速率 + 缓冲余量
     */
    private fun statusLine(p: Player, aheadMs: Long, rate: Long): String {
        val speed = fmtSpeed(rate)
        val buffering = p.playbackState == Player.STATE_BUFFERING
        val paused = !p.playWhenReady
        val ahead = (aheadMs / 1000).coerceAtLeast(0)
        return when {
            buffering && rate > 0 -> "缓冲中 · $speed"
            buffering -> "缓冲中…"
            paused && rate > 0 -> "已暂停 · 持续缓冲 · $speed"
            paused && ahead > 0 -> "已暂停 · 已缓冲 ${ahead}s"
            paused -> "已暂停"
            // ⛔ 播放中也要把速率带上：用户要判断「现在到底在下多少」，
            //    只在缓冲时显示等于大部分时间都看不到。
            rate > 0 && ahead > 0 -> "$speed · 已缓冲 ${ahead}s"
            rate > 0 -> speed
            ahead > 0 -> "已缓冲 ${ahead}s"
            else -> ""
        }
    }

    /** `C.TIME_UNSET` 与负数都要当成「还不知道时长」。 */
    private fun durationOf(p: Player): Long? {
        val d = p.duration
        return if (d == C.TIME_UNSET || d <= 0) null else d
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        /** 与全工程同一个 tag，`adb logcat -s KuakeProto` 一条命令全看得到。 */
        private const val TAG = "KuakeProto"

        /** 500ms。再快没有意义（人眼读不出），再慢时间文字会一跳一跳。 */
        private const val TICK_MS = 500L
        private const val SEEK_TOUCH_DP = 34

        fun fmtTime(ms: Long): String {
            if (ms < 0) return "--:--"
            val t = ms / 1000
            val h = t / 3600
            val m = (t % 3600) / 60
            val s = t % 60
            return if (h > 0) {
                String.format(Locale.US, "%d:%02d:%02d", h, m, s)
            } else {
                String.format(Locale.US, "%02d:%02d", m, s)
            }
        }

        fun fmtSpeed(bytesPerSec: Long): String = when {
            bytesPerSec <= 0 -> "0 KB/s"
            bytesPerSec >= 1L shl 20 -> "%.2f MB/s".format(bytesPerSec / 1048576.0)
            else -> "%.0f KB/s".format(bytesPerSec / 1024.0)
        }
    }
}

/**
 * 三层进度条，可触摸拖拽。
 *
 * ⛔ **`scrubbing` 必须对外可见**：控制栏的 ticker 每 500ms 会把
 * `progressRatio` 刷成播放器的真实位置，如果拖拽期间不把它屏蔽掉，就会
 * 出现「手指还按着、进度条自己跳回去」的诡异手感。
 */
class SeekBarView(context: Context) : View(context) {

    var progressRatio = 0f
        set(v) {
            field = v.coerceIn(0f, 1f)
            invalidate()
        }

    var bufferedRatio = 0f
        set(v) {
            field = v.coerceIn(0f, 1f)
            invalidate()
        }

    var scrubbing = false
        private set

    var onScrub: ((Float) -> Unit)? = null
    var onCommit: ((Float) -> Unit)? = null

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x33FFFFFF
    }
    private val bufferPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x8CFFFFFF.toInt()
    }
    private val playedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF3D7EFF.toInt()
    }
    private val thumbPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
    }

    private val rect = RectF()
    private val trackH = dp(5f)
    private val thumbR = dp(8f)

    private fun dp(v: Float): Float = v * resources.displayMetrics.density

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cy = height / 2f
        val left = thumbR
        val right = width - thumbR
        val w = right - left
        if (w <= 0) return
        val half = trackH / 2f

        rect.set(left, cy - half, right, cy + half)
        canvas.drawRoundRect(rect, half, half, trackPaint)

        if (bufferedRatio > 0f) {
            rect.set(left, cy - half, left + w * bufferedRatio, cy + half)
            canvas.drawRoundRect(rect, half, half, bufferPaint)
        }
        if (progressRatio > 0f) {
            rect.set(left, cy - half, left + w * progressRatio, cy + half)
            canvas.drawRoundRect(rect, half, half, playedPaint)
        }
        canvas.drawCircle(left + w * progressRatio, cy, thumbR, thumbPaint)
    }

    /**
     * 触摸拖拽。电视上只有「空鼠/鼠标」才走这条路，遥控器走
     * `PlayerActivity` 的方向键（±10s 步进）。两条路都要有 ——
     * 需求里的「拖拽」指的是这条。
     */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        val span = (width - 2 * thumbR).toFloat()
        if (span <= 0f) return false
        val ratio = ((event.x - thumbR) / span).coerceIn(0f, 1f)
        when (event.action) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                scrubbing = true
                progressRatio = ratio
                onScrub?.invoke(ratio)
                return true
            }
            MotionEvent.ACTION_UP -> {
                scrubbing = false
                progressRatio = ratio
                onCommit?.invoke(ratio)
                performClick()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                scrubbing = false
                invalidate()
                return true
            }
        }
        return false
    }

    override fun performClick(): Boolean = super.performClick()
}
