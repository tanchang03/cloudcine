package com.cloudcine.tv

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

/**
 * 播放页贴底控制栏：`12:34 / 58:20` + 多层进度条 + 状态/网速。
 *
 * ## 进度条的四层（这是需求里最关键的一条）
 *
 * | 层 | 含义 | 来源 |
 * |---|---|---|
 * | 底色 | 整条时长（未缓冲） | — |
 * | 淡蓝 | **磁盘缓存**已覆盖的区间（可多段） | `SimpleCache.getCachedSpans` |
 * | 浅色 | **内存缓冲**区间（前向 + 后缓冲） | `player.bufferedPosition` ± 后缓冲 |
 * | 亮蓝 | 已播放 | `player.currentPosition` |
 *
 * 用户要的「拖到已缓冲进度就立刻播、不用重新缓冲」之所以成立，是因为
 * ExoPlayer 的 `seekTo` 落在已缓冲区间内时**不需要任何网络**，直接从
 * `SampleQueue` 里出帧。所以这层浅色不是装饰 —— 它是**可以瞬时跳转的
 * 范围**的可视化。反过来，拖到浅色之外就一定得重新缓冲，界面必须先让
 * 用户看见这件事。
 *
 * ## 为什么磁盘缓存是**多段**的
 *
 * ⛔ 用户把进度条拖到预取前沿之外时，预取器会跟到新位置（见
 * `DiskPrefetcher.reanchor`），于是盘上就是
 * `[片头, 旧前沿] ∪ [新锚点, 新前沿]` —— 中间那个空洞是**真的没有数据**。
 * 画成「从片头连到新前沿」等于骗用户：他会以为回拖那一段不用重新缓冲。
 *
 * ## 为什么自己画进度条，不用 `android.widget.ProgressBar`
 *
 * `ProgressBar` 的 determinate 外观由主题里的 9-patch 决定，颜色只能靠
 * tint 去染，高度也受 drawable 最小尺寸限制；而且它的 `secondaryProgress`
 * 语义是「第二进度」，绘制顺序固定。这里要的是**多色 + 多段 + 圆角 +
 * 圆形游标 + 可拖拽**，自己画几十行反而更短、更可控。
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

    /**
     * 后缓冲保留时长（毫秒）。由 Activity 挂上 [BufferPlan] 算出的那个值。
     *
     * 进度条用它把内存缓冲区间向**左**延伸到播放头后面那段 ——
     * 见 [SeekBarView.bufferStartRatio] 里「为什么不能只画到 0」。
     */
    var backBufferMsSupplier: (() -> Long)? = null

    /**
     * 磁盘缓存快照（进度条那层淡蓝 + 右侧「磁盘 512 MiB」**同源**）。
     *
     * ⛔ 是**取值器**而不是当时的数值：换档、跳转、淘汰都会让它变。
     * ⛔ 里面读的是 `SimpleCache`（要拿锁、遍历 span）与 `player.duration`，
     *    **必须**在主线程调 —— 它就是从 `refresh()` 里调的。
     */
    var diskCacheSupplier: (() -> DiskCacheSnapshot)? = null

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
        timeText.text = "${Fmt.time((dur * ratio).toLong())} / ${Fmt.time(dur)}"
    }

    /**
     * 遥控器快进/快退时的「跟手」显示：把进度条与时间文字直接挪到 [targetMs]。
     *
     * ⛔ **只动显示，不动播放器** —— 真正的 `seekTo` 由 Activity 防抖后发一次。
     *    与 [onScrubbed] 是一对：一个来自触摸、一个来自按键，对用户是同一件事。
     *
     * ⛔ 顺带 `beginExternalScrub()`：让 ticker 在这期间别把进度条刷回真实
     *    播放位置（那会让「按一下挪一格」变成「按一下闪回去」）。
     */
    fun showPendingSeek(targetMs: Long) {
        val p = player ?: return
        val dur = durationOf(p) ?: return
        if (dur <= 0L) return
        seekBar.beginExternalScrub()
        seekBar.progressRatio = (targetMs.toFloat() / dur).coerceIn(0f, 1f)
        timeText.text = "${Fmt.time(targetMs)} / ${Fmt.time(dur)}"
    }

    /** 外部接管结束（跳转已提交）。 */
    fun endExternalScrub() = seekBar.endExternalScrub()

    private fun refresh() {
        val p = player ?: return
        val pos = p.currentPosition.coerceAtLeast(0L)
        val dur = durationOf(p)
        val buf = p.bufferedPosition.coerceAtLeast(pos)

        // ⛔ 磁盘缓存快照**一拍只取一次**：算它要拿 `SimpleCache` 的锁并遍历
        //    全部 span（可达几十个），进度条与右侧文字各取一遍就是白翻一倍，
        //    而且是每 500ms 一次。
        val disk = diskCacheSupplier?.invoke() ?: DiskCacheSnapshot.EMPTY

        // 拖拽中不要被 ticker 抢回去 —— 否则手指还按着、时间文字自己跳。
        if (!seekBar.scrubbing) {
            timeText.text = if (dur == null) {
                "${Fmt.time(pos)} / --:--"
            } else {
                "${Fmt.time(pos)} / ${Fmt.time(dur)}"
            }
            if (dur != null && dur > 0) {
                val d = dur.toFloat()
                seekBar.progressRatio = pos.toFloat() / d
                seekBar.bufferedRatio = buf.toFloat() / d
                // 后缓冲：把内存缓冲区间**向左延伸**到播放头后面那段。
                // ⛔ 不能只画到 0 —— 那会让「已播过但还在缓冲里」看起来像
                //    「已经播过、要重下」，回拖时用户会被骗。
                val backMs = backBufferMsSupplier?.invoke() ?: 0L
                seekBar.bufferStartRatio = (pos - backMs).coerceAtLeast(0L).toFloat() / d
                // 磁盘缓存：**多段**。跳转留下的空洞必须留着 —— 见类注释。
                seekBar.diskRanges = disk.ranges
            } else {
                seekBar.progressRatio = 0f
                seekBar.bufferedRatio = 0f
                seekBar.bufferStartRatio = 0f
                seekBar.diskRanges = FloatArray(0)
            }
        }

        // ⛔ 速率每拍**只拉一次**。拉两次 = 同一拍塞两个采样点，窗口被压短、
        //    读数开始抖，而且「窗口内无新字节就衰减到 0」这条判据也会失真。
        val rate = networkRateSupplier?.invoke() ?: 0L
        val diskText = diskText(disk)

        statusText.text = statusLine(p, buf - pos, rate, diskText)
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
                "[控制栏] ${Fmt.time(pos)} / ${if (dur == null) "--:--" else Fmt.time(dur)}" +
                    " · 已缓冲+${(buf - pos) / 1000}s" +
                    " · 速率 ${Fmt.speed(rate)}" +
                    (if (diskText != null) " · $diskText" else "") +
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
     *
     * @param disk 磁盘缓存那一小段（[diskCacheText]）；没启用时是 null
     */
    private fun statusLine(p: Player, aheadMs: Long, rate: Long, disk: String?): String {
        val speed = Fmt.speed(rate)
        val buffering = p.playbackState == Player.STATE_BUFFERING
        val paused = !p.playWhenReady
        val ahead = (aheadMs / 1000).coerceAtLeast(0)
        return when {
            buffering && rate > 0 -> "缓冲中 · $speed"
            buffering -> "缓冲中…"
            // ⛔ 暂停时**必须**把磁盘缓存亮出来。用户暂停就是想看「还在不在下」，
            //    而「已缓冲 Ns」读的是 ExoPlayer 的 `SampleQueue`（48 MiB 上限），
            //    预取器写进磁盘的数据根本进不了它 —— 数字会一直不动，
            //    用户就会以为「暂停后不缓冲了」。实测就是这么误判的：
            //    磁盘里已经写了 512 MiB，屏幕上还写着「已暂停 · 已缓冲 9s」。
            paused && disk != null -> "已暂停 · 内存 ${ahead}s · $disk"
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

    /**
     * 磁盘缓存那一小段文字，例如 `磁盘 512 MiB`；**没下到东西时返回 null**。
     *
     * ⛔ 用**本片**已提交的字节数（[DiskCacheSnapshot.usedBytes]），它和进度条
     *    画出来的淡蓝层是**同一份数据**算出来的，所以结构上不可能自相矛盾。
     *    曾经用的是 `PrefetchCache.usedBytes()` —— 那是整个缓存目录的占用，
     *    含别的片源的残留，于是出现「控制栏写着 2.2 GiB、进度条却画 0」
     *    （实测就是这么撞出来的），用户完全没法判断缓存到底生效没有。
     *
     * ⛔ 也不再用「已下到的时间」：跳转会在磁盘上留下空洞，而一个时间点
     *    表达不了「两段」。**位置由进度条说，规模由这行字说**，各司其职。
     */
    private fun diskText(snap: DiskCacheSnapshot): String? {
        if (snap.usedBytes <= 0L) return null
        return "磁盘 ${Fmt.bytes(snap.usedBytes)}"
    }

    /** `C.TIME_UNSET` 与负数都要当成「还不知道时长」。 */
    private fun durationOf(p: Player): Long? {
        val d = p.duration
        return if (d == C.TIME_UNSET || d <= 0) null else d
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        /** 与全工程同一个 tag，`adb logcat -s CloudCine` 一条命令全看得到。 */
        private const val TAG = "CloudCine"

        /** 500ms。再快没有意义（人眼读不出），再慢时间文字会一跳一跳。 */
        private const val TICK_MS = 500L
        private const val SEEK_TOUCH_DP = 34
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

    /**
     * 内存缓冲区间的**起点**比例（0..1）。
     *
     * ⛔ 存在的理由是**后缓冲**：`bufferedPosition` 只给前向的终点，
     *    而 ExoPlayer 其实还保留着播放头**后面**一段（可回拖、不必重下）。
     *    只画 `[0, bufferedRatio]` 等于把后缓冲画成了「已经播过」，
     *    用户回拖时看到浅色区间却还要重新缓冲 —— 那是云影踩过的坑。
     */
    var bufferStartRatio = 0f
        set(v) {
            field = v.coerceIn(0f, 1f)
            invalidate()
        }

    /**
     * **磁盘缓存**已覆盖的区间，扁平比例数组 `[起0, 止0, 起1, 止1, …]`（0..1）。
     *
     * 这一层与内存缓冲是两回事：内存缓冲受 `SampleQueue` 的 48 MiB 约束
     * （原画只够 9 秒），而磁盘缓存由 [DiskPrefetcher] 绕开播放器预算
     * 顺序灌入，能到 GB 级。**两者必须画成不同颜色**，否则用户没法判断
     * 「暂停时到底有没有在继续下」—— 那正是这个需求要解决的困惑。
     *
     * ⛔ 为什么是**数组**而不是一个「画到哪」的比例：跳转后预取器跟到新位置
     *    （见 [DiskPrefetcher.reanchor]），盘上就变成两段、中间是真空洞。
     *    画成「从片头连到新前沿」等于告诉用户回拖那一段不用重新缓冲 —— 骗人。
     */
    var diskRanges: FloatArray = FloatArray(0)
        set(v) {
            field = v
            invalidate()
        }

    /**
     * 「进度条正被人攥着」—— 手指按住（触摸拖拽）**或**遥控器连续快进中。
     *
     * ⛔ 控制栏的 ticker 每 500ms 会把 [progressRatio] 刷成播放器的真实位置，
     *    必须靠这个标志屏蔽掉，否则会出现「手还按着、进度条自己跳回去」。
     */
    var scrubbing = false
        private set

    /**
     * 由**外部**接管进度条（遥控器连续快进/快退）。
     *
     * ⛔ 存在的理由是「跟手」：遥控器方向键是**自动重复**的（按住时约
     *    20 次/秒）。若每次按键都真发一次 `seekTo`，播放器会反复拆掉当前
     *    load、重开数据源、重建解码管线 —— 表现就是「拖起来很卡、不跟手」，
     *    而且每次重开数据源都会新建一个 16 MiB 的并行读取器，直接撑爆堆
     *    （2026-10-06 真机 OOM）。
     *
     * 改成：按键只挪**待提交目标**（本方法负责把进度条与时间文字挪过去），
     * 真正的 `seekTo` 由 `PlayerActivity` 防抖后**只发一次**。
     */
    fun beginExternalScrub() {
        scrubbing = true
    }

    /** 外部接管结束（跳转已提交）。下一拍 ticker 恢复正常回写。 */
    fun endExternalScrub() {
        scrubbing = false
        invalidate()
    }

    var onScrub: ((Float) -> Unit)? = null
    var onCommit: ((Float) -> Unit)? = null

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x33FFFFFF
    }

    /**
     * 磁盘缓存层：**淡蓝**。
     *
     * ⛔ 用色调（蓝）而不是亮度来区分内存缓冲：两者都是浅色的话，
     *    在电视这种对比度差的面板上根本分不出来。蓝色 = 「已经在盘上」，
     *    白色 = 「在内存里」，纯蓝 = 「已播过」。
     */
    private val diskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x593D7EFF
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

        // 从下往上四层，顺序不能反：
        //   轨道 → 磁盘缓存（可多段）→ 内存缓冲（前向+后向）→ 已播放
        rect.set(left, cy - half, right, cy + half)
        canvas.drawRoundRect(rect, half, half, trackPaint)

        // 磁盘缓存：逐段画。相邻两段（`SimpleCache` 没合并的连续 span）
        // 画出来是同一个矩形，视觉上无差别，不必先去合并。
        var i = 0
        while (i + 1 < diskRanges.size) {
            val a = diskRanges[i]
            val b = diskRanges[i + 1]
            if (b > a) {
                rect.set(left + w * a, cy - half, left + w * b, cy + half)
                canvas.drawRoundRect(rect, half, half, diskPaint)
            }
            i += 2
        }
        // ⛔ 宽度判据是 `> bufferStartRatio`（不是 `> 0`）：后缓冲让起点右移，
        //    若还按 0 判，会画出一个「左端点到 bufferedRatio」的假区间。
        if (bufferedRatio > bufferStartRatio) {
            rect.set(
                left + w * bufferStartRatio,
                cy - half,
                left + w * bufferedRatio,
                cy + half,
            )
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
