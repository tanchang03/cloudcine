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
import androidx.media3.exoplayer.upstream.DefaultAllocator
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
 * ## 缓冲那三行（2026-10-06 加）
 *
 * | 行 | 回答什么 | 关键读法 |
 * |---|---|---|
 * | `缓冲 内存` | 播放头前方还有多少、后缓冲留了多少、**占用多少字节** | 占用贴着预算 = 已下满 |
 * | `磁盘 本片` | 这片在盘上覆盖了多少、**几段**、最远到哪 | 段数 > 1 = 跳转留了空洞 |
 * | `预取` | 预取器进度 + **实时网速** | 领先贴着上限 = 在等播放头 |
 *
 * ⛔ 三行里的数**全部来自注入的取值器**（见下面那些 `*Supplier`），浮层自己
 *    只负责排版。理由和 `PlayerControlsView` 一样：控制栏与浮层会**同屏**
 *    出现，两边各算一遍必然漂移，而漂移的读数会被当成 bug 追。
 * ⛔ 唯独 `player` 是直接读的 —— 它本来就在这个类里，而且本方法就在主线程。
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

    /**
     * 内存缓冲的**分配器**与它的**字节上限**（`setTargetBufferBytes` 那个值）。
     *
     * ⛔ 两个必须**同源**一起给：`getTotalBytesAllocated()` 是分子、
     *    预算是分母。换了播放器却只换一个，会显示「43/48」这种看着合理、
     *    其实不是一对的读数 —— 那比不显示更坏。
     * 由 [bindBufferBudget] 一起设。
     */
    private var allocator: DefaultAllocator? = null
    private var bufferBudgetBytes = 0

    /**
     * 网速（字节/秒）。**必须与控制栏用同一个 `NetRateMeter` 采样点** ——
     * 两处各建一个表，同一时刻会显示两个数，用户会来问哪个是真的。
     */
    var networkRateSupplier: (() -> Long)? = null

    /** 后缓冲保留时长（毫秒），[BufferPlan] 算出来的那个值。 */
    var backBufferMsSupplier: (() -> Long)? = null

    /** 本片在磁盘上覆盖了哪些区间（段数 / 字节数 / 最远时间）。 */
    var diskCacheSupplier: (() -> DiskCacheSnapshot)? = null

    /** 缓存目录概况（占用 / 上限 / 磁盘剩余）—— 一行字，由 `PrefetchCache` 给。 */
    var diskStatSupplier: (() -> String)? = null

    /** 旁路预取器；未启用（空间不够 / 未起播）时返回 null。 */
    var prefetcherSupplier: (() -> DiskPrefetcher?)? = null

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

    /**
     * 把「内存缓冲预算」与它的分配器一起交给浮层 —— 见 [allocator] 的注释。
     *
     * ⛔ 传 null 表示这一项不显示（比如没走 `startPlayer` 的对照路径），
     *    **不要**退回成 0：那会写成「占用 0/0 MiB」，看起来像缓冲被关掉了。
     */
    fun bindBufferBudget(allocator: DefaultAllocator?, budgetBytes: Int) {
        this.allocator = allocator
        this.bufferBudgetBytes = if (allocator == null) 0 else budgetBytes
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

        // ── 缓冲读数：内存 / 磁盘 / 网络（2026-10-06 加）────────────
        // 这三样是当前阶段最该看的：内存缓冲受 `setTargetBufferBytes`（本机
        // 48 MiB）封顶、磁盘缓存是「暂停也在下」的**唯一**证据、网速是判断
        // 「到底卡在哪」的入口。
        //
        // ⛔ 全部在**主线程**取（本方法就是主线程 tick）：`bufferedPosition` /
        //    `currentPosition` 都只能在主线程读 —— 预取线程读它闪退过一次。
        val aheadMs = if (p != null) {
            (p.bufferedPosition - p.currentPosition).coerceAtLeast(0L)
        } else {
            0L
        }
        val backMs = backBufferMsSupplier?.invoke() ?: 0L
        // ⛔ -1 = 没接分配器（对照路径），与「占用 0 字节」是两回事，
        //    见 bindBufferBudget 的注释。
        val memUsed = allocator?.totalBytesAllocated?.toLong() ?: -1L
        val disk = diskCacheSupplier?.invoke() ?: DiskCacheSnapshot.EMPTY
        val pf = prefetcherSupplier?.invoke()
        val rate = networkRateSupplier?.invoke() ?: 0L
        val cacheLine = diskStatSupplier?.invoke()

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

            // ── 缓冲：内存 ─────────────────────────────────────────
            // 「后缓冲」是 `BufferPlan` 按字节预算反算出来的秒数 —— 它和
            // 「占用 x/y MiB」是同一个预算的两面：后缓冲拿多了，前向就饿死。
            append("缓冲 内存 +").append(aheadMs / 1000).append("s（后缓冲 ")
                .append(String.format(Locale.US, "%.1fs", backMs / 1000.0))
                .append("）· 占用 ")
            if (memUsed >= 0) {
                append(Fmt.mib(memUsed)).append('/')
                    .append(Fmt.mib(bufferBudgetBytes.toLong())).append(" MiB")
            } else {
                append("--")
            }
            append('\n')

            // ── 缓冲：磁盘 ─────────────────────────────────────────
            // ⛔ 「本片」与「目录」必须分开写：目录占用含别的片源的残留，
            //    只报目录就会出现「写着 3.4 GiB、进度条却一片空白」的
            //    自相矛盾画面（实测撞过）。
            append("磁盘 本片 ").append(Fmt.bytes(disk.usedBytes))
            if (disk.segments > 0) {
                append(" · ").append(disk.segments).append(" 段")
                if (disk.endMs > 0) append(" · 到 ").append(Fmt.time(disk.endMs))
            }
            append(" · ").append(cacheLine ?: "未启用").append('\n')

            // ── 缓冲：网络 ─────────────────────────────────────────
            // 「领先」贴着上限 = 已经下满、在等播放头；远小于上限 = 还在追；
            // **负数** = 播放头跑到预取前沿前面去了（跳转之后会看到，随后爬回）。
            append("预取 ")
            if (pf == null) {
                append("未启用")
            } else {
                append("第 ").append(pf.chunks).append(" 块 · 领先 ")
                    .append(Fmt.bytes(pf.leadBytes))
                    .append("（上限 ").append(Fmt.bytes(pf.maxLeadBytes)).append("）")
            }
            append(" · 网络 ").append(Fmt.speed(rate)).append('\n')

            append(
                String.format(
                    Locale.US, "进程CPU %.1f%%（折合 %d 核 %.1f%%） · 内存 %.0f MB\n",
                    cpuSingleCorePct,
                    Runtime.getRuntime().availableProcessors(),
                    cpuSingleCorePct / Runtime.getRuntime().availableProcessors(),
                    rssMb,
                )
            )
            // ⛔ Java 堆必须单独看：ExoPlayer 的缓冲字节数组吃的是它，
            //    而本机 `heapgrowthlimit=192m` —— 堆贴近上限就是崩溃前兆。
            append(
                String.format(
                    Locale.US, "Java 堆 %.0f/%.0f MB · 系统可用内存 %.0f MB\n",
                    heapUsedMb(), heapMaxMb(), sysAvailMb,
                )
            )
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
     *
     * ⛔ 用 `readLine()` 只读第一行，**不要 `readText()`**：`/proc/self/stat` 确实
     * 只有一行，但 `readText()` 会先按 16KB 起分配缓冲。堆被占满时，就是这一下
     * 把主线程打死的（实测崩溃栈顶正是这里要的 16400 字节）。
     * 读什么都会死是事实，但**别让自己成为压死骆驼的那根稻草**。
     */
    private fun readSelfTicks(): Long? = try {
        val s = File("/proc/self/stat").bufferedReader().use { it.readLine() } ?: return null
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

    /** 同理：逐行读到 `VmRSS:` 就停，别把整份 `/proc/self/status` 读成一个 List。 */
    private fun readVmRssKb(): Double = try {
        val line = File("/proc/self/status").bufferedReader().use { r ->
            var found: String? = null
            while (found == null) {
                val l = r.readLine() ?: break
                if (l.startsWith("VmRSS:")) found = l
            }
            found
        }
        line?.filter { it.isDigit() }?.toDoubleOrNull() ?: 0.0
    } catch (_: Exception) {
        0.0
    }

    /**
     * Java 堆用量 / 上限（MB）。
     *
     * ⛔ **这一项是必须的**：`setTargetBufferBytes` 吃的是 Java 堆，而本机
     * `heapgrowthlimit=192m`。之前把缓冲上限写死成 192MiB 时，堆被 ExoPlayer
     * 的字节数组占满，表现为「播 4K 一分钟后崩」。有这一行，下次一眼就能看出
     * 是「缓冲把堆吃了」还是「别处漏了」。
     */
    private fun heapUsedMb(): Double {
        val rt = Runtime.getRuntime()
        return (rt.totalMemory() - rt.freeMemory()) / 1048576.0
    }

    private fun heapMaxMb(): Double = Runtime.getRuntime().maxMemory() / 1048576.0

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
