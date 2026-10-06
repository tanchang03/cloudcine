package com.cloudcine.kuake

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.cloudcine.kuake.quark.Bg
import com.cloudcine.kuake.quark.PlayInfo
import com.cloudcine.kuake.quark.Quality
import com.cloudcine.kuake.quark.QuarkApi
import com.cloudcine.kuake.quark.QuarkHttp
import com.cloudcine.kuake.quark.QuarkStore
import com.cloudcine.kuake.quark.formatSize
import java.util.Locale

/**
 * 播放页 —— **1:1 复刻夸克播放器的三件事**。
 *
 * 1. **MediaCodec 直出 SurfaceView**（`setVideoSurfaceView`）：解码器直接往
 *    Surface 的 buffer 里写，视频像素**完全不进应用的渲染管线** ——
 *    没有「拷回 CPU 内存」、没有「上传成纹理」。云影走 mpv 时只能出 Flutter
 *    纹理（`media_kit_video` 在 Android 上写死 `createSurfaceProducer()`），
 *    这一层是结构性的差距。
 * 2. **OSD 是原生 View**，不是 Flutter widget：没有 Dart 侧每秒 10 次整页
 *    rebuild，按键到画面只经过一次 `invalidate()`。
 * 3. **视频与 OSD 是两个系统图层**：OSD 变化只让 HWUI 重绘受损区域，
 *    视频那一层是独立 buffer，由硬件合成器去合。
 *
 * ## 第 4 件（也是这次最关键的）：**播转码档，不播原画**
 *
 * 同一部 `黑亚当 2160p`（时长 7490s），夸克给的档位（实测）：
 *
 * | 档位 | 分辨率 | 体积 | 需要带宽 |
 * |---|---|---|---|
 * | 原画 | 3840×1606 | 21.9 GiB | **3.00 MB/s** |
 * | 4k | 3840×1606 | 4.6 GiB | **0.63 MB/s** |
 * | super | 1440×602 | 1.03 GiB | 0.14 MB/s |
 *
 * 而夸克自己的 `default_resolution` 就是 `super`。云影默认播原画，
 * 要 3 MB/s，只能靠 8 连接中继去凑 —— 那个中继跑在 Dart 主 isolate 上。
 * **本原型不需要中继，因为它不需要那 5 倍带宽。**
 */
class PlayerActivity : Activity() {

    private lateinit var videoBox: AspectRatioFrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var osd: KuakeOsdView
    private lateinit var stats: StatsOverlay
    private lateinit var notice: TextView

    private var player: ExoPlayer? = null
    private lateinit var store: QuarkStore
    private var api: QuarkApi? = null
    private var info: PlayInfo? = null
    private var current: Quality? = null

    /**
     * 起播前那次单连接测速的结果（MiB/s）。`<= 0` 表示没测到
     * （超时/被拒/失败），此时 [chooseQuality] 退回夸克的默认档。
     *
     * ⛔ 单位是 **MiB/s**（`1048576` 进制），而档位的 `requiredMbPerSec`
     * 用的是 **MB/s**（`1048576` 也是二进制但名字写成 MB）。两者都是
     * 「字节 ÷ 1048576 ÷ 秒」，所以可以直接比 —— 但别把 MiB 和 MB
     * 理解成 1000 进制，那会白送 4.8% 的余量假象。
     */
    private var measuredMbPerSec = 0.0

    /** 直接给 URL 的旧路径（对照云影中继用），见 [StreamSpec]。 */
    private var spec: StreamSpec? = null

    private var firstFrameRendered = false
    private var openedAtMs = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        store = QuarkStore(this)

        // ── 布局：SurfaceView 打底，OSD 与浮层盖在上面 ──────────────
        //
        // ⛔ SurfaceView **必须**装在 AspectRatioFrameLayout 里，不能直接
        //    MATCH_PARENT —— 否则片源（如 1440×612，2.35:1）会被拉伸铺满
        //    1920×1080 的屏，画面横向拉长。OSD 与浮层则要留在外层铺满整屏，
        //    否则菜单会被一起压进画面矩形、在信箱边上留一圈点不到的死区。
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

        videoBox = AspectRatioFrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        surfaceView = SurfaceView(this)
        videoBox.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        root.addView(
            videoBox,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        stats = StatsOverlay(this)
        root.addView(
            stats,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                leftMargin = dp(48)
                topMargin = dp(27)
            },
        )

        notice = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setBackgroundColor(0xCC000000.toInt())
            setPadding(dp(16), dp(10), dp(16), dp(10))
            visibility = View.GONE
        }
        root.addView(
            notice,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.CENTER },
        )

        osd = KuakeOsdView(this).apply {
            visibility = View.GONE
            onActivate = { row, chip -> onOsdActivate(row, chip) }
            onClose = { hideOsd() }
        }
        root.addView(
            osd,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )

        setContentView(root)

        // 两条入口：按 fid 自己取链（正常路径），或直接给 URL（对照用）。
        spec = StreamSpec.fromIntent(intent)
        val fid = intent.getStringExtra(EXTRA_FID)?.trim().orEmpty()
        when {
            fid.isNotEmpty() -> resolveAndPlay(fid)
            spec != null -> {
                Log.i(TAG, "直接用给定 URL 播放（对照路径）：${spec!!.url}")
                startPlayer(spec!!.url, spec!!.headers)
                osd.bind(listOf(rateRow(1.0)))
            }
            else -> {
                Log.w(TAG, "既没有 fid 也没有 url，回列表页")
                finish()
            }
        }
    }

    // ------------------------------------------------------------------
    // 取链
    // ------------------------------------------------------------------

    private fun resolveAndPlay(fid: String) {
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty()
        showNotice("正在取链…\n$name")
        api = QuarkApi(store)
        Bg.run({ api!!.resolve(fid) }) { pi, err ->
            if (err != null) {
                Log.e(TAG, "取链失败", err)
                showNotice("取链失败\n${err.message}")
                return@run
            }
            if (pi == null || pi.qualities.isEmpty()) {
                showNotice("服务端没给出任何可用地址")
                return@run
            }
            info = pi
            Log.i(
                TAG,
                "取链成功：${pi.fileName} 时长=${pi.durationMs / 1000}s " +
                    "服务端默认档=${pi.defaultQualityId}",
            )
            for (q in pi.qualities) {
                Log.i(
                    TAG,
                    "  档位 ${q.id}：${q.label} ${q.width}x${q.height} " +
                        "${formatSize(q.sizeBytes)} 需 %.2f MB/s".format(q.requiredMbPerSec),
                )
            }
            probeThenPlay(pi)
        }
    }

    /**
     * 先量一次真实带宽，再据此挑档。
     *
     * ## 为什么不能直接照抄夸克的 `default_resolution`
     *
     * 夸克给的是 **`super`**（1440×810 那种），在 4K 片源上**肉眼就能看出糊**。
     * 照抄它等于「用夸克的保守默认，替用户做了降画质的决定」。
     * 但反过来一律上最高档也不行 —— 4K 原画要 2.75~3 MB/s，这台电视的 WiFi
     * 未必给得起，硬上就退化成云影那种「加载-播放-加载」。
     *
     * 所以：**量一下，再选「带宽扛得住的最清晰那一档」**，并留 30% 余量
     * （单连接测速只能反映那一个 CDN 节点，且播放本身还有抖动）。
     *
     * 探测成本：最多 2 秒 / 4 MiB。用最高档的地址探（同域名同 CDN，速率可比）。
     */
    private fun probeThenPlay(pi: PlayInfo) {
        val probeTarget = pi.qualities.maxByOrNull { it.height } ?: pi.qualities.first()
        showNotice("正在测速…\n（按最高档 ${probeTarget.label} 探 2 秒）")
        Bg.run({
            QuarkHttp.probeThroughput(
                url = probeTarget.url,
                cookie = cdnCookie(),
                maxBytes = 4L * 1024 * 1024,
                maxMillis = 2_000,
            )
        }) { tp, err ->
            measuredMbPerSec = tp?.mibPerSec ?: 0.0
            if (err != null || tp == null) {
                Log.w(TAG, "测速失败，退回夸克的默认档", err)
                measuredMbPerSec = 0.0
            } else {
                Log.i(TAG, "★ 实测单连接带宽：$tp（HTTP ${tp.status}）")
            }
            val pick = chooseQuality(pi)
            Log.i(
                TAG,
                "自动选档：${pick.id}（${pick.label} ${pick.width}x${pick.height}，" +
                    "需 %.2f MB/s，实测 %.2f MB/s，余量 %.0f%%）".format(
                        pick.requiredMbPerSec,
                        measuredMbPerSec,
                        if (measuredMbPerSec > 0) {
                            (1 - pick.requiredMbPerSec / measuredMbPerSec) * 100
                        } else {
                            0.0
                        },
                    ),
            )
            playQuality(pick)
        }
    }

    /**
     * 挑「带宽扛得住的最清晰那一档」。
     *
     * 先按高度从高到低分组；同一分辨率下**取需要带宽最小的那条**
     * （原画与 `4k` 常常同分辨率，但 `4k` 转码档体积小得多 ——
     * 画面都是 4K，能省 5 倍带宽就没必要走原画）。
     * 一组都扛不住就降一级。全都扛不住时取最省的那条。
     */
    private fun chooseQuality(pi: PlayInfo): Quality {
        if (measuredMbPerSec <= 0.0) return pi.defaultQuality ?: pi.qualities.first()
        val budget = measuredMbPerSec * 0.7
        val groups = pi.qualities.groupBy { it.height }.toSortedMap(compareByDescending { it })
        for (group in groups.values) {
            val best = group.minByOrNull { it.requiredMbPerSec } ?: continue
            if (best.requiredMbPerSec <= budget) return best
        }
        return pi.qualities.minByOrNull { it.requiredMbPerSec } ?: pi.qualities.first()
    }

    /** 切到某一档。同一档重复点不重建播放器。 */
    private fun playQuality(q: Quality) {
        if (current?.id == q.id && player != null) {
            hideOsd()
            return
        }
        Log.i(
            TAG,
            "起播档位 ${q.id}（${q.label}）${q.width}x${q.height} " +
                "${formatSize(q.sizeBytes)} 需 %.2f MB/s".format(q.requiredMbPerSec),
        )
        current = q

        if (player == null) {
            startPlayer(q.url, headersForCdn())
        } else {
            player?.setMediaItem(MediaItem.fromUri(q.url))
            openedAtMs = System.currentTimeMillis()
            firstFrameRendered = false
            player?.prepare()
            player?.playWhenReady = true
            showNotice("正在切换：${q.label}…")
        }
        osd.bind(buildRows())
    }

    /**
     * 发往 CDN 的请求头。
     *
     * ⛔ **要么不带 Cookie，要么必须带 `__puus`**（Mac 侧实测四种组合）：
     *
     * | 带的 Cookie | 结果 |
     * |---|---|
     * | 带 `__puus`（新旧都行） | 206 |
     * | 有 `__pus` 但缺 `__puus` | **412** |
     * | 完全不带 | 206 |
     *
     * 「带一半」是最坏的：服务端认得你是登录用户，却过不了防重放校验。
     * 云影那边的表现正是「列表能刷、一播就转圈」。
     */
    private fun headersForCdn(): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        out["User-Agent"] = QuarkHttpUa
        out["Referer"] = "https://pan.quark.cn/"
        val cookie = cdnCookie()
        if (cookie.isNotEmpty()) {
            out["Cookie"] = cookie
        }
        return out
    }

    /**
     * 发往 CDN 的 Cookie，**与 [headersForCdn] 同一套判据**。
     *
     * 单独抽出来是因为测速（[probeThenPlay]）走的是裸 `HttpURLConnection`，
     * 不走 ExoPlayer 的 header map —— 两处若各写一份，很容易只改了一处，
     * 于是「播放正常、测速 412」或反过来，读数全是错的。
     *
     * @return 可直接塞进 `Cookie` 头的字符串；**空串表示「故意不带 Cookie」**。
     */
    private fun cdnCookie(): String {
        val cookie = store.requestCookie()
        if (cookie.contains("__puus=")) return cookie
        Log.w(TAG, "凭证里没有 __puus —— 按实测规则改为不带 Cookie（带一半必 412）")
        return ""
    }

    // ------------------------------------------------------------------
    // 播放器
    // ------------------------------------------------------------------

    private fun startPlayer(url: String, headers: Map<String, String>) {
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(headers["User-Agent"] ?: QuarkHttpUa)
            .setConnectTimeoutMs(StreamSpec.DEFAULT_TIMEOUT_MS)
            .setReadTimeoutMs(StreamSpec.DEFAULT_TIMEOUT_MS)
            .setDefaultRequestProperties(headers)
            .setAllowCrossProtocolRedirects(true)

        val mediaSourceFactory = DefaultMediaSourceFactory(http)

        val exo = ExoPlayer.Builder(this, DefaultRenderersFactory(this), mediaSourceFactory)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()

        exo.setVideoSurfaceView(surfaceView)
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                Log.i(TAG, "状态 $state")
                if (state == Player.STATE_BUFFERING) showNotice("缓冲中…")
                if (state == Player.STATE_READY) hideNotice()
            }

            override fun onPlayerError(error: PlaybackException) {
                val msg = "${error.errorCodeName}: ${error.message}"
                Log.e(TAG, "播放失败 $msg", error)
                showNotice("播放失败\n$msg")
            }

            /**
             * 片源尺寸一变就重算显示矩形。
             *
             * ⛔ **必须用 `onVideoSizeChanged`，不能用 `onVideoInputFormatChanged`**：
             * 后者给的是**容器/编码**层的宽高，而这里要的是**实际显示**宽高 ——
             * 它多带一个 `pixelWidthHeightRatio`（非方形像素的片源，如部分
             * 标清素材，PAR 不是 1；漏掉它画面会窄一点点，肉眼像「没对齐」）。
             * 还有 `unappliedRotationDegrees`：90/270 时宽高要对调。
             */
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width <= 0 || videoSize.height <= 0) return
                val par = if (videoSize.pixelWidthHeightRatio > 0f) {
                    videoSize.pixelWidthHeightRatio
                } else {
                    1f
                }
                val rotated = videoSize.unappliedRotationDegrees == 90 ||
                    videoSize.unappliedRotationDegrees == 270
                val ratio = if (rotated) {
                    videoSize.height / (videoSize.width * par)
                } else {
                    videoSize.width * par / videoSize.height
                }
                Log.i(
                    TAG,
                    "片源显示尺寸 ${videoSize.width}x${videoSize.height} " +
                        "PAR=$par 旋转=${videoSize.unappliedRotationDegrees}° " +
                        "⇒ 宽高比 %.4f".format(ratio),
                )
                videoBox.setAspectRatio(ratio)
            }
        })

        exo.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) {
                Log.i(TAG, "解码器 $decoderName（初始化 ${initializationDurationMs}ms）")
                stats.setDecoder(decoderName)
            }

            override fun onVideoInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: Format,
                decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?,
            ) {
                stats.setVideoFormat(format)
                Log.i(
                    TAG,
                    String.format(
                        Locale.US, "片源 %dx%d %.2ffps %s",
                        format.width, format.height, format.frameRate, format.codecs,
                    ),
                )
            }

            override fun onRenderedFirstFrame(
                eventTime: AnalyticsListener.EventTime,
                output: Any,
                renderTimeMs: Long,
            ) {
                firstFrameRendered = true
                hideNotice()
                Log.i(TAG, "首帧已出：从打开算 ${System.currentTimeMillis() - openedAtMs}ms")
            }
        })

        player = exo
        stats.bind(exo)
        stats.start()

        exo.setMediaItem(MediaItem.fromUri(url))
        openedAtMs = System.currentTimeMillis()
        exo.prepare()
        exo.playWhenReady = true

        showNotice("正在打开…")
    }

    override fun onDestroy() {
        stats.stop()
        player?.release()
        player = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // OSD —— 只有「画质」和「倍速」两行，其余功能原型不做
    // ------------------------------------------------------------------

    private fun buildRows(): List<KuakeOsdView.Row> {
        val pi = info ?: return listOf(rateRow(currentSpeed))
        val cur = current
        return listOf(
            KuakeOsdView.Row(
                label = "画质",
                value = cur?.label ?: "—",
                // 选项带真实分辨率与「需要多少带宽」—— 这是本原型要看的核心数字，
                // 藏进日志就没人看了。
                options = pi.qualities.map { "${it.label}  ${it.detail}" },
                enabled = pi.qualities.map { true },
            ),
            rateRow(currentSpeed),
        )
    }

    private fun rateRow(speed: Double) = KuakeOsdView.Row(
        label = "倍速",
        value = rateLabel(speed),
        options = SPEEDS.map { rateLabel(it) },
    )

    private fun onOsdActivate(row: Int, chip: Int) {
        when (row) {
            0 -> info?.qualities?.getOrNull(chip)?.let { playQuality(it) }
            1 -> {
                val rate = SPEEDS.getOrNull(chip) ?: 1.0
                currentSpeed = rate
                player?.setPlaybackSpeed(rate.toFloat())
                Log.i(TAG, "OSD 倍速 → ${rateLabel(rate)}")
                osd.bind(buildRows())
            }
        }
        hideOsd()
    }

    private var currentSpeed = 1.0

    private fun rateLabel(v: Double): String = when (v) {
        1.0 -> "正常速度"
        0.5 -> "0.5x"
        0.75 -> "0.75x"
        1.25 -> "1.25x"
        1.5 -> "1.5x"
        2.0 -> "2.0x"
        else -> "${v}x"
    }

    // ------------------------------------------------------------------
    // 按键
    // ------------------------------------------------------------------

    /**
     * ⛔ 用 `dispatchKeyEvent` 而不是给每个 View 挂 `OnKeyListener`：
     * 遥控器按键必须**先**在 Activity 这一层被看到（OSD 是自绘的、里面没有
     * 可遍历的焦点节点），否则会出现云影踩过的坑 ——
     * 「菜单能弹出来，但上下键按不动」。
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // ⛔ 只认 `ACTION_DOWN`。遥控器长按连发在 Android TV 上本来就是
        //    一串独立的 ACTION_DOWN，收 ACTION_MULTIPLE 只会多一条没用的分支。
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)
        val code = event.keyCode

        if (osd.visibility == View.VISIBLE) {
            if (osd.onKey(code)) {
                stats.markKey()
                return true
            }
            when (code) {
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_MENU -> {
                    hideOsd(); return true
                }
            }
            return true // OSD 开着时别的键也吞掉，避免误触播放控制
        }

        when (code) {
            KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_DPAD_UP -> {
                showOsd(); return true
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                val p = player ?: return true
                if (p.isPlaying) p.pause() else p.play()
                return true
            }
            KeyEvent.KEYCODE_DPAD_LEFT -> {
                seekBy(-10_000L); return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                seekBy(10_000L); return true
            }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                seekBy(30_000L); return true
            }
            KeyEvent.KEYCODE_MEDIA_REWIND -> {
                seekBy(-30_000L); return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * 相对跳转。
     *
     * 用 `seekTo(currentPosition ± delta)` 而不是 `Player.seekBy()`：后者在
     * media3 1.3 才加进来，这里刻意钉在 1.5.1。负数要夹到 0 ——
     * `seekTo(-10000)` 会被 ExoPlayer 当成「seek 到末尾」，是个不报错的坑。
     */
    private fun seekBy(deltaMs: Long) {
        val p = player ?: return
        p.seekTo((p.currentPosition + deltaMs).coerceAtLeast(0L))
    }

    private fun showOsd() {
        osd.resetSelectionForTest()
        osd.visibility = View.VISIBLE
        stats.markKey()
        Log.i(TAG, "OSD 打开")
    }

    private fun hideOsd() {
        osd.visibility = View.GONE
        Log.i(TAG, "OSD 关闭")
    }

    // ------------------------------------------------------------------

    private fun showNotice(text: String) {
        notice.text = text
        notice.visibility = View.VISIBLE
    }

    private fun hideNotice() {
        notice.visibility = View.GONE
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        const val TAG = "KuakeProto"
        const val EXTRA_FID = "fid"
        const val EXTRA_NAME = "name"
        const val EXTRA_HEADERS = "headers"

        private const val QuarkHttpUa =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

        private val SPEEDS = listOf(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)
    }
}
