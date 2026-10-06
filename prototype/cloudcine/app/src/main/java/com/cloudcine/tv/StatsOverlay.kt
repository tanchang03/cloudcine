package com.cloudcine.tv

import android.app.ActivityManager
import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.View
import android.widget.TextView
import androidx.media3.common.Format
import androidx.media3.exoplayer.ExoPlayer
import java.io.File
import java.util.Locale

/**
 * 左上角的实测浮层。**这个原型的全部意义就是它**：没有数字，
 * 「原生是不是更跟手」就只是一句感觉。
 *
 * ## 两个指标是关键，其余是上下文
 *
 * 1. **按键→下一帧 (ms)**：`dispatchKeyEvent` 里记时刻，下一个
 *    `Choreographer` 回调里算差值。这就是用户说的「跟手」——
 *    从按下到画面开始更新。云影那边这条没法直接测（按键要穿过 Flutter 的
 *    平台通道 + Dart 事件循环），只能靠帧耗时间接推；这里能直接读。
 * 2. **UI 帧间隔 最大 (ms)**：>16.7 说明掉帧，>50 说明肉眼可见的卡。
 *
 * 其余几项用于与云影的 `[资源]` 日志**逐行对齐**（同一个口径）：
 * 进程 CPU 用**单核口径**并写明折合 N 核（4 核盒子要 400% 才叫满载），
 * 内存读 `VmRSS`，系统可用内存走 `ActivityManager`。
 *
 * ## ⚠️ 一个诚实的取舍
 *
 * 帧回调是**自续**的（每帧重新 post），所以它会持续请求 vsync。这在
 * 播放视频时几乎无额外代价（显示管线本来就在按刷新率出帧），但**待机时**
 * 会让它多烧一点电 —— 原型阶段接受，换成正式实现时应当只在需要时开。
 */
class StatsOverlay(context: Context) : TextView(context) {

    private val choreographer = Choreographer.getInstance()
    private val handler = Handler(Looper.getMainLooper())

    private var running = false
    private var player: ExoPlayer? = null

    /** 解码器名由 `AnalyticsListener.onVideoDecoderInitialized` 喂进来。 */
    private var decoderName: String? = null
    private var videoFormat: Format? = null

    // ── 帧与按键 ──────────────────────────────────────────────
    private var lastFrameNs = 0L
    private var framesThisWindow = 0
    private var maxFrameGapMs = 0.0
    private var uiFps = 0.0
    private var pendingKeyNs = 0L
    private var lastKeyMs = 0.0
    private var maxKeyMs = 0.0
    private var keySamples = 0

    // ── CPU / 内存 ────────────────────────────────────────────
    private var prevTicks: Long? = null
    private var prevAtMs = 0L
    private var cpuSingleCorePct = 0.0
    private var rssMb = 0.0
    private var sysAvailMb = 0.0

    // ── 渲染 ─────────────────────────────────────────────────
    // ⛔ Media3 1.5.1 的 `DecoderCounters` 里这些计数器全是 **`int`**（不是 `long`）：
    //    实测 `javap androidx.media3.exoplayer.DecoderCounters` 得到
    //    `renderedOutputBufferCount` / `droppedBufferCount` / `queuedInputBufferCount`
    //    都是 `public int`。写成 `Long` 会编译不过；而且**没有 `inputBufferCount`
    //    这个字段**（那是 ExoPlayer 2.x 的名字）。
    private var prevRendered = 0
    private var renderedFps = 0.0
    private var dropped = 0
    private var decoded = 0

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            val now = System.nanoTime()
            if (lastFrameNs != 0L) {
                val gapMs = (now - lastFrameNs) / 1_000_000.0
                framesThisWindow++
                if (gapMs > maxFrameGapMs) maxFrameGapMs = gapMs
            }
            lastFrameNs = now

            // 按键→下一帧：这是「跟手」的直接读数。
            if (pendingKeyNs != 0L) {
                val ms = (now - pendingKeyNs) / 1_000_000.0
                lastKeyMs = ms
                keySamples++
                if (ms > maxKeyMs) maxKeyMs = ms
                pendingKeyNs = 0L
                // 逐次落 logcat：最大/末次那两个值会被后面的按键冲掉，
                // 要看清「分布」必须每条都留。
                Log.i(TAG, String.format(Locale.US, "[按键] → 下一帧 %.1f ms", ms))
            }
            choreographer.postFrameCallback(this)
        }
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            refresh()
            handler.postDelayed(this, 1000L)
        }
    }

    init {
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
        typeface = android.graphics.Typeface.MONOSPACE
        gravity = Gravity.START
        val h = (12 * resources.displayMetrics.density).toInt()
        setPadding(h * 2, h, h * 2, h)
        background = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = h.toFloat()
            setColor(0xB2000000.toInt())
        }
    }

    fun bind(player: ExoPlayer?) {
        this.player = player
        prevRendered = 0
        prevTicks = null
    }

    fun setDecoder(name: String?) {
        decoderName = name
    }

    fun setVideoFormat(format: Format?) {
        videoFormat = format
    }

    /** 每次「被 OSD 吃掉的按键」都要调一次，用来量按键→下一帧。 */
    fun markKey() {
        pendingKeyNs = System.nanoTime()
    }

    fun resetKeyStats() {
        lastKeyMs = 0.0
        maxKeyMs = 0.0
        keySamples = 0
    }

    fun start() {
        if (running) return
        running = true
        lastFrameNs = 0L
        prevAtMs = SystemClock.elapsedRealtime()
        choreographer.postFrameCallback(frameCallback)
        handler.postDelayed(tick, 1000L)
    }

    fun stop() {
        running = false
        choreographer.removeFrameCallback(frameCallback)
        handler.removeCallbacks(tick)
    }

    // ------------------------------------------------------------------

    private fun refresh() {
        val nowMs = SystemClock.elapsedRealtime()

        // ── CPU：单核口径。折合 N 核写出来，否则 42% 会被误读成「很闲」。──
        val ticks = readSelfTicks()
        if (ticks != null) {
            val prev = prevTicks
            if (prev != null) {
                val dtMs = (nowMs - prevAtMs).coerceAtLeast(1L)
                // USER_HZ 在 Android 上恒为 100（与云影 ResourceProbe 同口径）。
                cpuSingleCorePct = (ticks - prev) * 1000.0 / dtMs / 100.0 * 100.0
            }
            prevTicks = ticks
        }
        prevAtMs = nowMs

        rssMb = readVmRssKb() / 1024.0
        sysAvailMb = readSysAvailMb()

        val p = player
        if (p != null) {
            val c = p.videoDecoderCounters
            if (c != null) {
                val rendered = c.renderedOutputBufferCount
                renderedFps = (rendered - prevRendered).toDouble()
                prevRendered = rendered
                dropped = c.droppedBufferCount
                // 「已解码」取 `queuedInputBufferCount`：Media3 里没有 `inputBufferCount`，
                // 这个是「已排入解码器的输入缓冲数」，与云影 [资源] 那一行的口径最接近。
                decoded = c.queuedInputBufferCount
            }
        }

        uiFps = framesThisWindow.toDouble()
        framesThisWindow = 0

        text = buildString {
            append("Media3 ExoPlayer · SurfaceView（零拷贝）\n")
            val f = videoFormat
            if (f != null) {
                append("片源 ").append(f.width).append('x').append(f.height)
                if (f.frameRate > 0) {
                    append(String.format(Locale.US, " · %.2ffps", f.frameRate))
                }
                append(" · ").append(f.codecs ?: "?").append('\n')
            }
            append("解码器 ").append(decoderName ?: "未起").append('\n')
            append(String.format(Locale.US, "渲染 %.1f fps · 丢帧 %d · 已解码 %d\n", renderedFps, dropped, decoded))
            append(
                String.format(
                    Locale.US, "进程CPU %.1f%%（折合 %d 核 %.1f%%） · 内存 %.0f MB\n",
                    cpuSingleCorePct,
                    Runtime.getRuntime().availableProcessors(),
                    cpuSingleCorePct / Runtime.getRuntime().availableProcessors(),
                    rssMb,
                )
            )
            append(String.format(Locale.US, "系统可用内存 %.0f MB\n", sysAvailMb))
            append(
                String.format(
                    Locale.US, "UI %.1f fps · 最大帧间隔 %.1f ms\n",
                    uiFps, maxFrameGapMs,
                )
            )
            append(
                String.format(
                    Locale.US, "按键→下一帧 %.1f ms（最大 %.1f，n=%d）",
                    lastKeyMs, maxKeyMs, keySamples,
                )
            )
        }
        maxFrameGapMs = 0.0

        // ── 落 logcat ────────────────────────────────────────────────
        // ⛔ 这条通道是**必需**的，不是调试残留：小米电视上有硬件视频层时
        //    `screencap` 抓回来是**纯白**（硬合成层不进 framebuffer 快照），
        //    浮层上画的字**读不到**。视频还在跑的时候，logcat 是唯一能把
        //    「UI fps / 最大帧间隔 / 进程 CPU / 解码器」带出来的路。
        //    一行一条，用 `adb logcat -s CloudCine | grep 统计` 取。
        Log.i(TAG, "[统计] " + text.toString().replace('\n', '｜'))
    }

    /**
     * 进程累计 CPU 节拍（utime + stime）。
     *
     * ⛔ **必须按最后一个 `)` 切**：`comm`（进程名）允许含空格与括号，
     * 按空白 split 会让后面所有字段整体错位 —— 而且**不报错**，只是 CPU 变成垃圾值。
     */
    private fun readSelfTicks(): Long? = try {
        val s = File("/proc/self/stat").readText()
        val i = s.lastIndexOf(')')
        if (i < 0) null else {
            val parts = s.substring(i + 2).split(' ')
            val ut = parts.getOrNull(11)?.toLongOrNull()
            val st = parts.getOrNull(12)?.toLongOrNull()
            if (ut == null || st == null) null else ut + st
        }
    } catch (_: Exception) {
        null
    }

    private fun readVmRssKb(): Double = try {
        File("/proc/self/status").readLines()
            .firstOrNull { it.startsWith("VmRSS:") }
            ?.filter { it.isDigit() }
            ?.toDoubleOrNull() ?: 0.0
    } catch (_: Exception) {
        0.0
    }

    private fun readSysAvailMb(): Double = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        info.availMem / 1024.0 / 1024.0
    } catch (_: Exception) {
        0.0
    }

    /** 浮层自己也要能被「按住」—— 避免它挡住按键。 */
    override fun onTouchEvent(event: android.view.MotionEvent): Boolean = false

    fun hideSelf() {
        visibility = View.GONE
    }

    private companion object {
        /** 与 `PlayerActivity` 同一个 tag —— 一次 `logcat -s CloudCine` 全看到。 */
        const val TAG = "CloudCine"
    }
}
