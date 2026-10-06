package com.cloudcine.kuake

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
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
import androidx.media3.exoplayer.DefaultLoadControl
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
    private lateinit var controls: PlayerControlsView
    private lateinit var confirmExit: ConfirmDialogView

    private val ui = Handler(Looper.getMainLooper())

    /** 「没人按键就把控制栏收起来」的那一拍。 */
    private val hideControls = Runnable { if (!isBuffering) controls.visibility = View.GONE }

    private var isBuffering = false

    /**
     * 下载速率：`ByteCounter` 在**数据源那一层**数字节，[NetRateMeter] 做差分。
     * 由 [PlayerControlsView] 每拍拉一次（⛔ **只在这一处拉** —— 多拉一次采样点
     * 就变密、窗口变短，读数会开始抖）。
     */
    private val netBytes = ByteCounter()
    private val netMeter = NetRateMeter()

    private var player: ExoPlayer? = null
    private lateinit var store: QuarkStore

    /** 全局参数（调试浮层开关等），与登录态分开存。 */
    private lateinit var prefs: ProtoPrefs
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
        prefs = ProtoPrefs(this)

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
        // 默认关（全局参数）。要看的时候 MENU → 调试 → 开启。
        applyDebugOverlay()

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

        // ── 贴底控制栏（进度条 / 缓冲进度 / 网速）──────────────────
        //
        // ⛔ 它**不进 AspectRatioFrameLayout**：那条黑边（信箱）也属于「屏幕」，
        //    控制栏要贴屏幕底，不是贴画面底 —— 否则宽银幕片源下控制栏会
        //    浮到画面下方正中，看着像飘在半空。
        // ⛔ 初始 GONE：起播前由居中的 notice 负责说话（取链/测速/打开），
        //    播放器建好后才由 [showControls] 亮出来。
        controls = PlayerControlsView(this).apply {
            visibility = View.GONE
            networkRateSupplier = {
                netMeter.onCumulativeBytes(netBytes.bytes)
                netMeter.ratePerSec()
            }
            onSeek = { ratio -> seekToRatio(ratio) }
        }
        root.addView(
            controls,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.BOTTOM },
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

        // 退出确认框 —— **最后加进 root**，保证它压在控制栏与 OSD 之上。
        confirmExit = ConfirmDialogView(this).apply {
            onConfirm = { finish() }
            onCancel = { hideExitConfirm() }
        }
        root.addView(
            confirmExit,
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
                // ⛔ 别缩回 4 MiB：那个量在 0.7s 就读满，量到的是**突发**速率，
                //    不是可持续速率。实测电视上突发 5.49 MiB/s、可持续只有
                //    ~1 MB/s —— 用突发值去选档，必然选到 4K 原画然后一直卡。
                //    12 MiB 能把窗口拉到 ~2s，是个折中（再长用户等不起）。
                maxBytes = 12L * 1024 * 1024,
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
            // ⛔ 换档**必须把进度带过去**。`setMediaItem` 会把播放位置重置成 0，
            //    而换档是用户「看画质不合适」时最常做的动作 —— 从第 40 分钟
            //    换个档就跳回片头，比卡顿更让人恼火。
            val resumeMs = player?.currentPosition?.coerceAtLeast(0L) ?: 0L
            val wasPlaying = player?.playWhenReady ?: true
            netBytes.reset()
            netMeter.reset()
            player?.setMediaItem(MediaItem.fromUri(q.url))
            openedAtMs = System.currentTimeMillis()
            firstFrameRendered = false
            player?.prepare()
            if (resumeMs > 0) player?.seekTo(resumeMs)
            player?.playWhenReady = wasPlaying
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

        // ⛔ 速率**不走** `AnalyticsListener.onBandwidthEstimate`：那个回调
        //    一次传输结束才发一次（`DefaultBandwidthMeter` 在 `onTransferEnd`
        //    里通知），缓冲中好几秒才有一个样本 ⇒ 窗口里没有新字节 ⇒ 界面
        //    上只剩「缓冲中」、看不到速率（实测就是这个现象）。
        //    改成在数据源上数 `read()` 的返回值：字节是连续进来的。
        val mediaSourceFactory =
            DefaultMediaSourceFactory(CountingDataSourceFactory(http, netBytes))

        // ── 缓冲策略（三条需求都落在这里）──────────────────────────
        //
        // ⛔ `maxBufferMs` 必须**调大**（默认 50s）：需求里的「暂停时也持续
        //    缓冲」就是它。ExoPlayer 暂停后不会停下载，而是一直填到
        //    `maxBufferMs`；默认 50s 一到就停，用户看到进度条浅色不再长，
        //    以为暂停就不缓冲了。给到 120s。
        // ⛔ `bufferForPlaybackMs` 从默认 2500 降到 1500：首帧更快（实测
        //    原画首帧 2.4s，其中约 1s 是在等这条阈值）。
        // ⛔ `setTargetBufferBytes(192MiB)` 是**内存护栏**：4K 原画 2.75MB/s
        //    × 120s = 330MB，这台电视总共才 2.5GB 内存，不封顶会被 LMK 杀。
        //    192MiB 在 4K 下约等于 70s，在超清档下约等于 6 分钟。
        // ⛔ `setBackBuffer(60s, true)` 让**回拖**也在缓冲里：默认后缓冲很短，
        //    往左拖 10s 看着在浅色区间内、其实数据已经丢了，照样重新缓冲。
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                30_000,   // minBufferMs：低于它一定继续下载
                120_000,  // maxBufferMs：暂停时能一直缓冲到这里
                1_500,    // bufferForPlaybackMs：起播阈值
                5_000,    // bufferForPlaybackAfterRebufferMs：卡完恢复的阈值
            )
            .setBackBuffer(60_000, true)
            .setTargetBufferBytes(192 * 1024 * 1024)
            .build()

        val exo = ExoPlayer.Builder(this, DefaultRenderersFactory(this), mediaSourceFactory)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setLoadControl(loadControl)
            .build()

        exo.setVideoSurfaceView(surfaceView)
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                Log.i(TAG, "状态 $state")
                // ⛔ 缓冲状态**不再走居中的 notice**：那一行字没地方放网速。
                //    改由控制栏右侧承担（「缓冲中 · 3.2 MB/s」），并且缓冲期间
                //    控制栏**不自动隐藏** —— 用户正盯着它看网速，收起来很讨厌。
                isBuffering = state == Player.STATE_BUFFERING
                if (isBuffering) {
                    hideNotice()
                    showControls(autoHide = false)
                } else if (state == Player.STATE_READY) {
                    hideNotice()
                    scheduleHideControls()
                }
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
        controls.bind(exo)

        exo.setMediaItem(MediaItem.fromUri(url))
        openedAtMs = System.currentTimeMillis()
        exo.prepare()
        exo.playWhenReady = true

        showNotice("正在打开…")
        // 播放器一建好就把控制栏亮出来（4 秒后自动收），让用户立刻看到
        // 进度条与缓冲进度在长 —— 这是本原型要验证的东西。
        showControls()
    }

    override fun onDestroy() {
        ui.removeCallbacks(hideControls)
        controls.unbind()
        stats.stop()
        player?.release()
        player = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // OSD —— 只有「画质」和「倍速」两行，其余功能原型不做
    // ------------------------------------------------------------------

    private fun buildRows(): List<KuakeOsdView.Row> {
        val pi = info ?: return listOf(rateRow(currentSpeed), debugRow())
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
            debugRow(),
        )
    }

    /**
     * 「调试」那一行 —— 开关左上角那块浮层。
     *
     * ⛔ 这是**全局参数**（存 `ProtoPrefs`，跨影片跨重启都记得），不是逐影片的
     *    播放偏好。⛔ 顺序不能随便动：原生 OSD 只回传**行下标**
     *    （见 [onOsdActivate]），加行/换行必须同时改这里与那边的 `when`。
     */
    private fun debugRow() = KuakeOsdView.Row(
        label = "调试",
        value = if (prefs.debugOverlay) "开启" else "关闭",
        options = listOf("关闭", "开启"),
    )

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
            2 -> setDebugOverlay(chip == 1)
        }
        hideOsd()
    }

    /**
     * 开关调试浮层。
     *
     * ⛔ **只切 `visibility`，不 `stop()`**：`[统计]` 那条 logcat 是硬件视频层下
     *    唯一能读到帧率/CPU/内存的通道（`screencap` 抓不到画面、播放中
     *    `uiautomator dump` 也拿不到），关掉浮层就把它一起掐了，反而更不好查。
     */
    private fun setDebugOverlay(on: Boolean) {
        prefs.debugOverlay = on
        applyDebugOverlay()
        osd.bind(buildRows())
    }

    private fun applyDebugOverlay() {
        val on = prefs.debugOverlay
        stats.visibility = if (on) View.VISIBLE else View.GONE
        Log.i(TAG, "调试浮层（全局参数）= ${if (on) "开启" else "关闭"}")
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

        // ── 第 0 层：退出确认框 ────────────────────────────────────
        // 它在最上面，开着的时候**所有**按键都归它，一个都不能漏到播放器上
        // （否则方向键会在弹框后面偷偷快进）。
        if (confirmExit.isShowing) {
            stats.markKey()
            return confirmExit.onKey(code)
        }

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

        // ── 返回键：两级，必须在 `showControls()` **之前**判 ──────────
        // ① 还有覆盖层（控制栏）→ 先收掉，回到「全屏播放状态」；
        // ② 已经是全屏播放 → 弹「要退出播放吗？」，确认后才 `finish()`。
        //
        // ⛔ 顺序不能反：`showControls()` 会把控制栏置成 VISIBLE，之后再问
        //    「控制栏是不是开着」就**恒为真**，返回键永远只会收控制栏、
        //    永远弹不出退出确认。
        if (code == KeyEvent.KEYCODE_BACK) {
            if (controls.visibility == View.VISIBLE) {
                hideControlsNow(); return true
            }
            showExitConfirm(); return true
        }

        // 其余按键都先把控制栏亮出来 —— 用户按方向键/暂停键，就是要看进度条。
        // ⛔ 这里**不能 return true**，后面还要按具体键分派。
        showControls()

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
                seekBy(-SEEK_STEP_MS); return true
            }
            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                seekBy(SEEK_STEP_MS); return true
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
     * 弹退出确认。
     *
     * ⛔ **顺带暂停**：弹框盖在正在播的画面上、声音还在响，是个很怪的组合
     *    （夸克也是暂停的）。取消时**按原样恢复** —— 本来就是暂停的，取消后
     *    不能自己播起来。
     */
    private fun showExitConfirm() {
        val p = player
        resumeAfterExitConfirm = p?.playWhenReady == true
        p?.pause()
        hideControlsNow()
        confirmExit.show()
        stats.markKey()
        Log.i(TAG, "弹出退出确认（原播放态=${if (resumeAfterExitConfirm) "播放中" else "已暂停"}）")
    }

    private fun hideExitConfirm() {
        confirmExit.dismiss()
        if (resumeAfterExitConfirm) player?.play()
        resumeAfterExitConfirm = false
        Log.i(TAG, "取消退出，继续播放")
    }

    /** 弹退出确认前的播放态，取消时按原样恢复。 */
    private var resumeAfterExitConfirm = false

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
    // 贴底控制栏
    // ------------------------------------------------------------------

    /**
     * 亮出控制栏。
     *
     * @param autoHide 是否 4 秒后自动收起。**缓冲中必须传 false** ——
     *   用户正盯着「缓冲中 · 3.2 MB/s」判断是不是网络问题，收起来很讨厌。
     *   缓冲状态本身由 [hideControls] 里那道 `isBuffering` 兜底，
     *   所以就算排了收起，缓冲开始时也会被拦下。
     */
    private fun showControls(autoHide: Boolean = true) {
        if (!::controls.isInitialized) return
        controls.visibility = View.VISIBLE
        ui.removeCallbacks(hideControls)
        if (autoHide) ui.postDelayed(hideControls, CONTROLS_HIDE_MS)
    }

    private fun scheduleHideControls() {
        ui.removeCallbacks(hideControls)
        ui.postDelayed(hideControls, CONTROLS_HIDE_MS)
    }

    /** 用户主动收（返回键），**不受缓冲状态阻挡**。 */
    private fun hideControlsNow() {
        ui.removeCallbacks(hideControls)
        controls.visibility = View.GONE
    }

    /**
     * 拖到某个比例。
     *
     * 落在**已缓冲区间**内时 ExoPlayer 直接从 `SampleQueue` 出帧，不碰网络 ——
     * 这就是需求里「拖到已缓冲进度就直接播、不用重新缓冲」的实现方式：
     * 不需要任何特殊处理，只要不误调 `prepare()`、并让用户能看见缓冲区间
     * （进度条那层浅色）就够了。
     */
    private fun seekToRatio(ratio: Float) {
        val p = player ?: return
        val d = p.duration
        if (d == C.TIME_UNSET || d <= 0) return
        val target = (d * ratio.toDouble()).toLong().coerceIn(0L, d)
        p.seekTo(target)
        val inBuffer = target <= p.bufferedPosition
        Log.i(
            TAG,
            "拖拽跳转 → ${target / 1000}s（已缓冲到 ${p.bufferedPosition / 1000}s，" +
                if (inBuffer) "区间内，不需重新缓冲）" else "区间外，需缓冲）",
        )
        showControls()
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

        /** 没人按键就把控制栏收起来。4 秒够看清缓冲进度在长，又不挡画面。 */
        private const val CONTROLS_HIDE_MS = 4_000L

        /**
         * 方向键步进。10 秒是电视端的通行值：够快（一部长片按 50 下到底），
         * 又不会一按就跳过头。遥控器长按连发是一串独立 ACTION_DOWN，
         * 所以「按住左/右」天然就是连续拖拽。
         */
        private const val SEEK_STEP_MS = 10_000L
    }
}
