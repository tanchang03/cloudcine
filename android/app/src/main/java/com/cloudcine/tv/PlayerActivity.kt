package com.cloudcine.tv

import android.app.Activity
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheKeyFactory
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultAllocator
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.PlayInfo
import com.cloudcine.tv.pan.Quality
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.PanHttp
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.formatSize
import java.util.Locale

/**
 * 播放页 —— **1:1 复刻对标播放器的三件事**。
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
 * ## 第 4 件：**带宽不够时降档，而不是硬扛原画**
 *
 * 同一部 `黑亚当 2160p`（时长 7490s），服务端给的档位（实测）：
 *
 * | 档位 | 分辨率 | 体积 | 需要带宽 |
 * |---|---|---|---|
 * | 原画 | 3840×1606 | 21.9 GiB | **3.00 MB/s** |
 * | 4k | 3840×1606 | 4.6 GiB | **0.63 MB/s** |
 * | super | 1440×602 | 1.03 GiB | 0.14 MB/s |
 *
 * 服务端自己的 `default_resolution` 是 `super`（肉眼就能看出糊），照抄它等于
 * 替用户做了降画质的决定；一律上最高档又会在带宽不够时退化成「加载-播放-加载」。
 * 所以起播前**先量一次并行带宽**，再挑「扛得住的最清晰那一档」并留 30% 余量
 * —— 见 [probeThenPlay]。
 *
 * ⛔ PC 端（Flutter）默认播原画，要 3 MB/s，只能靠 8 连接中继去凑，而那个中继
 *    跑在 **Dart 主 isolate**（= Android 主线程）上。本工程把中继换成了
 *    **原生 8 连接并行取流 + 磁盘旁路预取** —— 这才是「同一片源换个播放器就
 *    流畅」的主因，也是 Android 端必须原生的理由。
 */
class PlayerActivity : Activity() {

    private lateinit var videoBox: AspectRatioFrameLayout
    private lateinit var surfaceView: SurfaceView
    private lateinit var osd: TvOsdView
    private lateinit var stats: StatsOverlay
    private lateinit var notice: TextView
    private lateinit var controls: PlayerControlsView
    private lateinit var confirmExit: ConfirmDialogView

    /** 整页根容器。字幕抬高时要读它的高度（见 [updateSubtitleInset]）。 */
    private lateinit var root: FrameLayout

    /**
     * 内嵌字幕的**绘制出口**。
     *
     * ⛔ 少了它（或少了 [Player.Listener.onCues] 那一句），字幕就是
     *    「选得上、不上屏、零报错」—— `TextRenderer` 解出来的 cue 没有
     *    任何 `TextOutput` 接，被直接丢掉。机理见 [SubtitleOverlayView]。
     */
    private lateinit var subtitles: SubtitleOverlayView

    private val ui = Handler(Looper.getMainLooper())

    /**
     * 「没人按键就把控制栏收起来」的那一拍。
     *
     * ⛔ 到点也不能无脑收 —— 先问 [keepControlsVisible]。见那边的注释。
     */
    private val hideControls = Runnable {
        if (!keepControlsVisible()) setControlsShown(false)
    }

    private var isBuffering = false

    /**
     * 控制栏该不该**一直**留在屏幕上（即：不许自动收起）。
     *
     * ⛔ 判据不是「用户有没有按键」，而是**他是不是正在读控制栏上的数字**：
     *
     *   * **缓冲中** —— 他在看「缓冲中 · 3.2 MB/s」；
     *   * **已暂停** —— 他在看「已暂停 · 已缓冲 +118s」还会不会继续长。
     *
     * 这两种情况下把控制栏收掉，等于把他正盯着看的读数抢走。暂停态尤其明显：
     * 用户按暂停十有八九**就是为了**确认「暂停后还在不在继续缓冲」，
     * 4 秒后自己消失正好把答案盖住。
     *
     * ⚠️ `isPlaying == false` 在**缓冲中**同样成立（playWhenReady 还是 true，
     * 但状态是 BUFFERING）。这里不需要特意排除：两者都是「要留着」。
     * 播完（`STATE_ENDED`）也是 false ⇒ 控制栏留在屏幕上，这也合理 ——
     * 用户要看播到哪了。
     */
    private fun keepControlsVisible(): Boolean = isBuffering || player?.isPlaying == false

    /**
     * 下载速率：`ByteCounter` 在**数据源那一层**数字节，[NetRateMeter] 做差分。
     * 由 [PlayerControlsView] 每拍拉一次（⛔ **只在这一处拉** —— 多拉一次采样点
     * 就变密、窗口变短，读数会开始抖）。
     */
    private val netBytes = ByteCounter()
    private val netMeter = NetRateMeter()

    /**
     * 最近一次算出的网速（字节/秒）。给**第二个**消费者（调试浮层）读。
     *
     * ⛔ 只在主线程读写（两个消费者都是 View 的 ticker），所以不用 volatile。
     */
    private var lastRatePerSec = 0L

    /**
     * 网速取值器（字节/秒）。**控制栏与调试浮层共用这一个。**
     *
     * ⛔ 不能让两边各建一个表：[NetRateMeter.onCumulativeBytes] 是**采样**
     *    （往窗口里塞点），两边各采一份 = 采样率翻倍、窗口边界各走各的 ⇒
     *    同一时刻两个地方显示两个数，用户会来问哪个是真的。
     *    所以只留一个入口，并把结果缓存给第二个消费者。
     *    控制栏 500ms 一拍是较快的那一个，由它负责采样。
     */
    private val rateSupplier: () -> Long = {
        netMeter.onCumulativeBytes(netBytes.bytes)
        val r = netMeter.ratePerSec()
        lastRatePerSec = r
        r
    }

    private var player: ExoPlayer? = null
    private lateinit var store: CredStore

    /**
     * 磁盘缓存的**旁路预取器**。它不经过 ExoPlayer 的 `SampleQueue`，
     * 所以暂停时照样往前下 —— 见 [DiskPrefetcher] 的类注释。
     *
     * 生命周期：起播时新建、[onDestroy] 取消。**不能跨播放页复用** ——
     * 换片就换 url，缓存键也换了。
     */
    private var prefetcher: DiskPrefetcher? = null

    /**
     * 当前片的磁盘缓存句柄（`null` = 没启用 / 空间不够）。
     *
     * ⛔ 留着它是为了让控制栏能按 [DiskPrefetcher.cacheKey] 去
     * `Cache.getCachedSpans()` 查「本片在盘上覆盖了哪些区间」——
     * 进度条那层淡蓝要的正是这个。**不能**改用 `PrefetchCache.usedBytes()`：
     * 那是整个缓存目录的占用，含别的片源的残留（踩过，见 `diskText`）。
     */
    private var cacheRef: Cache? = null

    /** 当前片的夸克 `fid`（来自 `EXTRA_FID`）；空 = 走「直接给 URL」的对照路径。 */
    private var currentFid = ""

    /** 当前档位的 id（`Quality.id`，如 `super` / `4k` / `ORIGIN`）。 */
    private var currentQualityId = ""

    /**
     * **稳定缓存键** —— 磁盘缓存能不能跨会话复用的**唯一**决定因素。
     *
     * ## 为什么不能用 URL 当键（2026-10-06 实测）
     *
     * media3 的 [CacheKeyFactory.DEFAULT] 就是**拿 URL 字符串当键**。而夸克直链
     * 是**每次起播现取、带签名的临时地址**（`api.resolve(fid)`）⇒ 换一次会话
     * URL 就变 ⇒ 键变 ⇒ 上次下的数据**一个字节都命中不了**。
     *
     * 实测：盘上 4.9 GB / 61 个 span 文件，强杀重开播同一部片，
     * 面板 `磁盘 本片` 从 `972 MiB · 8 段` 直接掉到 **`0 B`**；
     * 缓存目录里还多出两个**全新的键前缀**（`13`/`14`）。用户看到的现象就是
     * 「同一部片下次打开还要重新缓冲」。
     *
     * ## 键的构成
     *
     * `quark:<fid>:<画质档 id>`
     *
     * ⛔ **画质档 id 不能省**：原画与各转码档是**完全不同的字节流**。只按 `fid`
     *    做键的话，先看原画、再切到 `super` 档，会把原画的字节喂给转码档的
     *    解析器 —— 直接解码出乱码/花屏，而且**不报错**。
     *
     * ⛔ 空（对照路径，没有 fid）时返回空串，调用方要**退回默认键** ——
     *    见 [cacheKeyFor]。
     */
    private val stableCacheKey: String
        get() = if (currentFid.isEmpty()) "" else "quark:$currentFid:$currentQualityId"

    /**
     * 给数据源用的键工厂。
     *
     * ⛔ **必须优先认 `dataSpec.key`**：预取器的 `CacheWriter` 会显式带 key
     *    （`DataSpec(uri, from, length, cacheKey)`），而它带的就是 [stableCacheKey]。
     *    如果这里无脑返回 [stableCacheKey]、把 `dataSpec.key` 丢掉，两者就分家了。
     */
    private val cacheKeyFactory = CacheKeyFactory { dataSpec ->
        dataSpec.key ?: cacheKeyFor(dataSpec.uri)
    }

    /** 没有稳定键（对照路径）时退回 media3 默认的「按 URL」行为。 */
    private fun cacheKeyFor(uri: Uri): String {
        val k = stableCacheKey
        return if (k.isNotEmpty()) k else CacheKeyFactory.DEFAULT.buildCacheKey(DataSpec(uri))
    }

    /**
     * 播放头在文件里的**字节位置**，由主线程每秒刷新的快照。
     *
     * ⛔ 它存在的唯一理由：`ExoPlayer.currentPosition` **只能在主线程读**。
     *    在别的线程读会抛 `IllegalStateException: Player is accessed on the
     *    wrong thread`，而预取线程的未捕获异常**会带走整个进程** ——
     *    用户看到的就是「无法打开影片，闪退」（2026-10-06 实测）。
     *    所以预取线程只许读这个快照，绝不碰 `player`。
     */
    @Volatile
    private var playheadBytesCache = 0L

    /** 当前档位的码率（字节/秒），把 [playheadBytesCache] 换算出来用。主线程写。 */
    @Volatile
    private var bytesPerSecCache = 0.0

    /**
     * 后缓冲保留时长（毫秒），[BufferPlan] 算出来的那个值。
     *
     * 进度条用它把内存缓冲区间向左延伸（见 `SeekBarView.bufferStartRatio`）。
     * ⛔ 存下来是因为**它和字节预算是联动算的**，进度条那边不能自己再猜一遍。
     */
    @Volatile
    private var backBufferMsCache = 0L

    /** 每秒把播放位置换算成字节，写进 [playheadBytesCache]。 */
    private val playheadTick = object : Runnable {
        override fun run() {
            val p = player
            if (p != null) {
                // 换算不了（拿不到码率）就**保留上一次的值**，不要写 0 ——
                // 写 0 会让预取器以为播放头回到了片头，从而丢掉「领先太多就等」
                // 这道刹车，一口气把缓存灌满。
                val b = estimatedBytes(p.currentPosition)
                if (b >= 0L) playheadBytesCache = b
            }
            ui.postDelayed(this, PLAYHEAD_TICK_MS)
        }
    }

    /** 全局参数（调试浮层开关等），与登录态分开存。 */
    private lateinit var prefs: AppPrefs
    private var api: PanApi? = null
    private var info: PlayInfo? = null
    private var current: Quality? = null

    /**
     * 起播前那次单连接测速的结果（MiB/s）。`<= 0` 表示没测到
     * （超时/被拒/失败），此时 [chooseQuality] 退回服务端的默认档。
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

    /**
     * 最近一次 `onTracksChanged` 拿到的轨道表。
     *
     * ⛔ **必须每帧现读、不能把 `TrackGroup` 存下来复用**：换档（[playQuality]）
     *    会换掉整个 `MediaItem`，`Tracks` 随之重建 —— 旧 `TrackGroup` 拿去
     *    `setOverrideForType` 不报错，但永远选不中（组对不上）。
     *    所以这里只留「最新那份」，选项列表每次由 [trackChoices] 现枚举。
     */
    private var tracks: Tracks? = null

    /**
     * 当前绑给 OSD 的行。
     *
     * ⛔ 按键回调只回传**行下标**，靠 [TvOsdView.Row.id] 还原语义 ——
     *    所以这张表必须与 `osd.bind()` 的那张是同一份，别各建各的。
     */
    private var osdRows: List<TvOsdView.Row> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        store = CredStore(this)
        prefs = AppPrefs(this)

        // ── 布局：SurfaceView 打底，OSD 与浮层盖在上面 ──────────────
        //
        // ⛔ SurfaceView **必须**装在 AspectRatioFrameLayout 里，不能直接
        //    MATCH_PARENT —— 否则片源（如 1440×612，2.35:1）会被拉伸铺满
        //    1920×1080 的屏，画面横向拉长。OSD 与浮层则要留在外层铺满整屏，
        //    否则菜单会被一起压进画面矩形、在信箱边上留一圈点不到的死区。
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }

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

        // ── 字幕（内嵌字幕的上屏出口）──────────────────────────────
        //
        // ⛔ 与统计浮层同理，它**不进 AspectRatioFrameLayout**：要能盖到信箱
        //    边上，也要能在 OSD 打开时抬到菜单上方（[updateSubtitleInset]）。
        // ⛔ 顺序有讲究 —— 它在 videoBox **之后**、stats/controls/osd **之前**：
        //    字幕该被控制栏和菜单压住，而不是反过来。
        subtitles = SubtitleOverlayView(this)
        root.addView(
            subtitles,
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
            // ⛔ 取值器**共用一个**（见 [rateSupplier]）：控制栏负责采样，
            //    调试浮层读缓存值，两处显示的永远是同一个数。
            networkRateSupplier = rateSupplier
            onSeek = { ratio -> seekToRatio(ratio) }
        }
        root.addView(
            controls,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.BOTTOM },
        )

        osd = TvOsdView(this).apply {
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
        // 起播前先把字幕底距摆好：`bottomInsetPx` 默认 0 = 贴屏幕最底，
        // 那位置在电视上常被过扫描吃掉。见 [updateSubtitleInset]。
        updateSubtitleInset()

        // 两条入口：按 fid 自己取链（正常路径），或直接给 URL（对照用）。
        spec = StreamSpec.fromIntent(intent)
        val fid = intent.getStringExtra(EXTRA_FID)?.trim().orEmpty()
        when {
            fid.isNotEmpty() -> resolveAndPlay(fid)
            spec != null -> {
                Log.i(TAG, "直接用给定 URL 播放（对照路径）：${spec!!.url}")
                startPlayer(spec!!.url, spec!!.headers)
                // 这条路径没有 PlayInfo ⇒ 没有「画质」行，行下标与常规路径不同。
                // 正因如此回调才按 id 分派（见 [onOsdActivate]）。
                rebindOsd()
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
        api = PanApi(store)
        // ⛔ 记下来源 fid —— 它是**稳定缓存键**的前半段（见 [stableCacheKey]）。
        //    不记的话就只能退回按 URL 做键，磁盘缓存永远跨不了会话。
        currentFid = fid
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
     * ## 为什么不能直接照抄服务端的 `default_resolution`
     *
     * 服务端给的是 **`super`**（1440×810 那种），在 4K 片源上**肉眼就能看出糊**。
     * 照抄它等于「用服务端的保守默认，替用户做了降画质的决定」。
     * 但反过来一律上最高档也不行 —— 4K 原画要 3.67 MiB/s，这台电视的 WiFi
     * 未必给得起，硬上就退化成云影那种「加载-播放-加载」。
     *
     * 所以：**量一下，再选「带宽扛得住的最清晰那一档」**，并留 30% 余量
     * （短窗口测速仍偏乐观，且播放本身还有抖动）。
     *
     * ## ⛔ 探测必须**与播放同构**（2026-10-06 改）
     *
     * 原来走 [PanHttp.probeThroughput]：**单连接**、12 MiB / 2 秒。电视上实测
     * 它量到 `12.00 MiB / 1.97s = 6.08 MiB/s`，于是判「原画余量 40%」→ 选原画
     * → 播 1 分钟后掉到 **1021 KB/s** → 一直卡。
     *
     * 错在两点：**连接数不对**（夸克按连接限速 1 MiB/s，1 条连接量到的数与
     * 播放实际用几条无关）+ **窗口落在突发段里**（新连接前 ~10 秒能跑 2.3~2.9 MiB/s）。
     * 换成 [ParallelProbe]（复用 [ParallelRangeReader]，连接数与播放同一个取值器）
     * 之后，量到的数就是播放能拿到的数。
     *
     * 探测成本：最多 3 秒 / 12 MiB。用最高档的地址探（同域名同 CDN，速率可比）。
     */
    private fun probeThenPlay(pi: PlayInfo) {
        val probeTarget = pi.qualities.maxByOrNull { it.height } ?: pi.qualities.first()
        val conns = prefs.parallelConnections
        showNotice("正在测速…\n（按最高档 ${probeTarget.label}、$conns 条连接探 3 秒）")
        Bg.run({
            ParallelProbe.measure(
                url = probeTarget.url,
                // ⛔ 用 [headersForCdn] 而不是裸 cookie：它与播放**同一套判据**
                //    （缺 `__puus` 就不带 Cookie）。两处各写一份的话，
                //    很容易只改了一处，于是「播放正常、测速 412」或反过来。
                headers = headersForCdn(),
                connections = conns,
                // ⛔ 别把窗口缩到 2 秒以内：那样连「每条连接是否都吃上活」都看不出来
                //    （8 条连接要一点时间才铺开）。3 秒是「能看出连接铺开」与
                //    「用户等得起」的折中。
                maxBytes = 12L * 1024 * 1024,
                maxMillis = 3_000,
            )
        }) { r, err ->
            measuredMbPerSec = r?.mibPerSec ?: 0.0
            if (err != null || r == null) {
                Log.w(TAG, "并行测速失败，退回服务端的默认档", err)
                measuredMbPerSec = 0.0
            } else {
                Log.i(TAG, "★ 实测并行带宽：$r")
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
            Log.i(TAG, "档位未变（${q.id}），不重建播放器")
            return
        }
        Log.i(
            TAG,
            "起播档位 ${q.id}（${q.label}）${q.width}x${q.height} " +
                "${formatSize(q.sizeBytes)} 需 %.2f MB/s".format(q.requiredMbPerSec),
        )
        current = q
        // ⛔ 换档**必须**更新缓存键的这半段：原画与转码档是不同的字节流，
        //    键里不带档位就会互相串数据（解码出乱码、且不报错）。
        //    见 [stableCacheKey]。
        currentQualityId = q.id

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
            // ⛔ 换档 = 换 media source ⇒ 字幕/音轨全都换了一套。旧的
            //    `tracks` 与用户选过的 override 都不能带过去：新 source 上
            //    没有那对 TrackGroup，override 会变成一条**指向不存在组的
            //    死规则**，之后字幕再也选不上。清掉重来。
            resetTrackOverrides()
            player?.setMediaItem(MediaItem.fromUri(q.url))
            openedAtMs = System.currentTimeMillis()
            firstFrameRendered = false
            player?.prepare()
            if (resumeMs > 0) player?.seekTo(resumeMs)
            player?.playWhenReady = wasPlaying
            showNotice("正在切换：${q.label}…")
        }
        rebindOsd()
    }

    /**
     * 丢掉上一套 media source 的轨道选择。
     *
     * ⛔ 只清 override，**不动用户选的字幕语言偏好**（`preferredTextLanguages`）——
     *    那是跨片的观看习惯，换个档就重置掉很讨厌。这里要清的只是「这个文件里
     *    选的是第几条」这种**逐文件**的东西。
     */
    private fun resetTrackOverrides() {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
            .build()
        tracks = null
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
        out["User-Agent"] = BrowserUa
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

    /**
     * 当前档位的码率（MiB/s），交给 [BufferPlan] 反算后缓冲时长。
     *
     * ⛔ `-e url` 那条**对照路径**（[onCreate] 里直接起播）没有档位信息，
     *    返回 0 ⇒ [BufferPlan] 用它的保守兜底。宁可后缓冲偏小 —— 偏小的代价是
     *    「回拖几秒要重下」，偏大的代价是「前向饿死、暂停后一个字节都不读」。
     */
    private fun assumedBitrateMibps(): Double =
        current?.requiredMbPerSec?.takeIf { it > 0.0 } ?: 0.0

    /**
     * 起一条**旁路预取**：绕开 ExoPlayer 的缓冲预算，直接往磁盘缓存灌数据。
     *
     * 这是「暂停时也能一直缓冲」的**唯一实现方式**。播放器自己的 loader
     * 受 `SampleQueue`（48 MiB）约束，暂停时一个字节都不读；
     * 而这条线程不经过 loader，因此暂停时照样往前下 —— 见 [DiskPrefetcher]。
     *
     * ## 为什么起点是 0 而不是播放位置
     *
     * 文件头（`moov` / 索引）每次起播都要读一遍。从 0 开始下，
     * 第二次打开同一个文件时那段就能命中缓存，省掉一次
     * `pos=0` 的嗅探往返（实测 250~500ms）。
     *
     * ## 领先量为什么是「缓存上限的 70%」
     *
     * ⛔ 不能设成无上限：那会一口气把缓存灌满，而用户可能看 5 分钟就退出 ——
     * 白下、白写盘。70% 留出余量给播放器自己写的那部分（已播段），
     * 让 LRU 有腾挪空间。
     *
     * @param cache 为 null（空间不够 / 初始化失败）时**直接不预取**，
     *   播放走纯网络 —— 这是正常路径，不是错误。
     * @param upstream 上游数据源。**应当传「带计数的那一层」**
     *   （[CountingDataSourceFactory] 包过的并行源），否则界面上的速率
     *   只数播放器自己的流量、恒为 0 —— 见调用点的注释。
     */
    private fun startDiskPrefetch(
        url: String,
        cache: Cache?,
        upstream: DataSource.Factory,
        bitrateMibps: Double,
    ) {
        prefetcher?.cancel()
        prefetcher = null

        val rate = if (bitrateMibps > 0.0) bitrateMibps else BufferPlan.ASSUMED_BITRATE_MIBPS
        val bytesPerSec = rate * 1048576.0

        // ── 控制栏 / 进度条的数据源（**与有没有磁盘缓存无关**，先挂上）──
        // ⛔ 一律传**取值器**而不是当时的数值：换档、跳转、LRU 淘汰都会让它变。
        //    这里的 `bytesPerSecCache` 是「字节 ↔ 时间」的唯一换算桥梁，
        //    换档后它必须跟着变，否则进度条那层淡蓝会一路按旧码率画。
        bytesPerSecCache = bytesPerSec
        playheadBytesCache = 0L
        cacheRef = cache
        controls.backBufferMsSupplier = { backBufferMsCache }
        controls.diskCacheSupplier = { diskCacheSnapshot() }
        // 先开「播放头快照」的定时器，再起预取：否则预取第一轮读到的是 0，
        // 会误判成「播放头在片头」，领先量算错。
        ui.removeCallbacks(playheadTick)
        ui.post(playheadTick)

        if (cache == null) {
            Log.i(TAG, "磁盘预取：未启用（缓存不可用），播放走纯网络")
            return
        }

        val lead = (PrefetchCache.limitBytes() * 7 / 10).coerceAtLeast(64L * 1024 * 1024)
        val uri = Uri.parse(url)
        // ⛔ 预取器与播放器的缓存键**必须是同一个** —— 见 [cacheKeyFor]。
        //    两边各算各的（哪怕公式一样）迟早会分家：只要有一处改了规则，
        //    预取下的东西播放器就一个字节都命中不了，而现象只是「缓冲白下了」，
        //    不报任何错。所以这里**复用同一个函数**，不复制公式。
        val key = cacheKeyFor(uri)
        val p = DiskPrefetcher(
            cache = cache,
            dataSourceFactory = upstream,
            uri = uri,
            cacheKey = key,
            startPositionBytes = 0L,
            totalBytes = -1L,
            maxLeadBytes = lead,
            // ⛔ 只读主线程写好的**快照**，绝不在这里碰 `player` ——
            //    见 [playheadBytesCache] 的注释（踩过一次，直接闪退）。
            playheadBytes = { playheadBytesCache },
        )
        prefetcher = p
        p.start()
        Log.i(
            TAG,
            "磁盘预取：已启动（键 $key · 码率 %.2f MiB/s ⇒ 领先上限 ${lead / 1048576} MiB）"
                .format(rate),
        )
    }

    /**
     * 取一次「**本片**在磁盘上覆盖了哪些区间」的快照，给进度条那层淡蓝用。
     *
     * ⛔ **必须由主线程调**（控制栏的 ticker 就在主线程）：里面要读
     *    `player.duration`，而 `ExoPlayer` 只在主线程可读 —— 踩过，
     *    见 [playheadBytesCache] 的注释（那次直接闪退）。
     *
     * ⛔ 用 `getCachedSpans` 而**不是** `prefetcher.nextPositionBytes`：
     *    跳转后预取器会跟到新位置（[DiskPrefetcher.reanchor]），盘上就成了
     *    两段、中间是真空洞。只报一个「下到哪」会把空洞画成有数据。
     *
     * ⚠️ 换算桥梁是**估算**的码率（`Quality.requiredMbPerSec`），所以画出来的
     *    位置只是「大概」—— VBR 片源必然有偏差。这一点消不掉：`SimpleCache`
     *    只知道字节，进度条只知道时间。
     *
     * ⚠️ 代价：`getCachedSpans` 拿的是 `SimpleCache` 的**对象锁**，与写者提交
     *    文件时是同一把。控制栏 500ms 一拍、span 是几十个量级，可以忽略；
     *    但**分块若改小**（比如 128 MiB → 8 MiB），span 会涨到几百上千个，
     *    那时就得改成后台线程取、或者降频。
     */
    private fun diskCacheSnapshot(): DiskCacheSnapshot {
        val c = cacheRef ?: return DiskCacheSnapshot.EMPTY
        val key = prefetcher?.cacheKey ?: return DiskCacheSnapshot.EMPTY
        val ranges = runCatching {
            val spans = c.getCachedSpans(key)
            val out = LongArray(spans.size * 2)
            var i = 0
            for (s in spans) {
                // ⛔ 只算**已提交**的 span。正在写的那一段 `isCached = false`，
                //    且 `length` 是 `C.LENGTH_UNSET`（-1）—— 收进来会画出一个
                //    起点在终点右边的「负宽度」矩形。
                if (!s.isCached || s.length <= 0L) continue
                out[i++] = s.position
                out[i++] = s.position + s.length
            }
            out.copyOf(i)
        }.getOrElse {
            // 读缓存元数据失败不该影响播放：这一拍不画淡蓝而已。
            Log.w(TAG, "读磁盘缓存区间失败（不影响播放）：${it.message}")
            return DiskCacheSnapshot.EMPTY
        }
        val dur = player?.duration ?: return DiskCacheSnapshot.EMPTY
        return DiskCachePlan.snapshot(ranges, bytesPerSecCache, dur)
    }

    private fun startPlayer(url: String, headers: Map<String, String>) {
        // ── 数据源：**多连接并行**（Android 端性能的核心）────────────
        //
        // ⛔ 不再是 `DefaultHttpDataSource`。理由（全部是 2026-10-06 实测）：
        //    夸克对**单条连接**限速约 1 MiB/s（单连接稳态 1016~1022 KB/s、
        //    波动 <0.3%；8 连接 120s 稳态 8.03 MiB/s，`8.03/8 = 1.004` 逐位吻合）。
        //    而 4K 原画要 **3.67 MiB/s** ⇒ 单连接只有 27.8%，
        //    必然「播 1 分钟就掉到 1 MB/s、然后一直卡」。
        //
        // ⛔ 包装顺序**并行源在内、计数在外**：计数层只转发 `read()` 的返回值，
        //    放在外面 ⇒ `NetRateMeter` 读到的仍是真实网络速率，
        //    与单连接时的口径完全一致，1 ↔ 8 的 A/B 才可比。
        //    （放反了会把「每条连接各自 1 MiB/s」数成 8 倍，读数虚高。）
        //
        // ⛔ 连接数用 `() -> Int` **取值器**而不是当场取一个 Int：播放器建一次
        //    长期复用（换档走 `setMediaItem`），而 Factory 是建播放器时就交出去的。
        //    传取值器 ⇒ 菜单里改完，**下一次 `open()` 立刻生效**，不必重建播放器。
        val parallel = ParallelRangeDataSourceFactory(
            headers = headers,
            connections = { prefs.parallelConnections },
            chunkBytes = ParallelRangeDataSourceFactory.DEFAULT_CHUNK_BYTES,
            connectTimeoutMs = StreamSpec.DEFAULT_TIMEOUT_MS,
            readTimeoutMs = StreamSpec.DEFAULT_TIMEOUT_MS,
        )

        // ── 磁盘缓存：**只读不写**，写入方只留预取器一个 ──────────────
        //
        // ⛔ 包装顺序：`CacheDataSource(upstream = 计数(并行))`。
        //    把计数放在缓存**外面**的话，`NetRateMeter` 会把「缓存命中的读」
        //    也算成网络流量 —— 速率虚高，而且「缓存到底有没有生效」没法判断。
        //
        // ⛔ **播放器不许写缓存**（`setCacheWriteDataSinkFactory(null)`）：
        //    两个写者撞上同一个 span 时，`SimpleCache.startFile` 抛的是
        //    `IllegalStateException`，而 `CacheDataSource` 只吞 `IOException`
        //    ⇒ 会直接崩。让 [DiskPrefetcher] 当唯一写者，换来零崩溃风险；
        //    代价只是「起播头十几秒那一段会被重复下载」（原画约 40 MiB）。
        val cache = PrefetchCache.get(this)
        val countingParallel = CountingDataSourceFactory(parallel, netBytes)
        val upstream: DataSource.Factory = if (cache != null) {
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(countingParallel)
                .setCacheWriteDataSinkFactory(null)
                // ⛔ **必须**换掉默认的键工厂。默认那个拿 URL 当键，而夸克直链
                //    每次起播都换（带签名），于是磁盘缓存**永远跨不了会话** ——
                //    实测重开后同一部片 `磁盘 本片` 从 972 MiB 掉到 0 B。
                //    详见 [stableCacheKey]。
                .setCacheKeyFactory(cacheKeyFactory)
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        } else {
            countingParallel
        }
        val mediaSourceFactory = DefaultMediaSourceFactory(upstream)

        Log.i(
            TAG,
            "数据源：多连接并行（${prefs.parallelConnections} 条 × " +
                "${ParallelRangeDataSourceFactory.DEFAULT_CHUNK_BYTES / 1024} KiB/块）· " +
                "缓存键 ${stableCacheKey.ifEmpty { "（按 URL，对照路径）" }} · " +
                PrefetchCache.describe(this),
        )

        // ── 缓冲策略（三条需求都落在这里）──────────────────────────
        //
        // ⛔ `maxBufferMs` 必须**调大**（默认 50s）：需求里的「暂停时也持续
        //    缓冲」就是它。ExoPlayer 暂停后不会停下载，而是一直填到
        //    `maxBufferMs`；默认 50s 一到就停，用户看到进度条浅色不再长，
        //    以为暂停就不缓冲了。给到 120s。
        // ⛔ `bufferForPlaybackMs` 从默认 2500 降到 1500：首帧更快（实测
        //    原画首帧 2.4s，其中约 1s 是在等这条阈值）。
        //
        // ── 缓冲字节上限：**必须按堆算，不能写死** ─────────────────
        //
        // ⛔⛔ 这里踩过一个把 App 直接打死的坑。原来写死 `192 * 1024 * 1024`，
        //    当时的想法是「192MiB 是个安全的内存护栏」。**它是整块 Java 堆。**
        //
        //    这台电视 `ro.config.low_ram=true`、`dalvik.vm.heapgrowthlimit=192m`
        //    （`getprop` 实测），manifest 又没开 `largeHeap` ⇒ App 能用的
        //    Java 堆就是 **192MiB**。
        //
        //    而 `setTargetBufferBytes` 是给 ExoPlayer 的 allocator 用的
        //    **Java 字节数组**总额（`DefaultAllocator` 里就是 `new byte[]`），
        //    **不是原生内存、也不走 SurfaceView**。所以「上限 = 堆」等于
        //    「允许它把堆占满」⇒ 播高码率片源时 loader 一路分配，堆满之后
        //    任何一次小分配都会 `OutOfMemoryError` 崩主线程。
        //
        //    实测崩溃（`logcat -b crash`）：
        //      OutOfMemoryError: Failed to allocate a 16400 byte allocation
        //      with 13416 free bytes … max allowed footprint 201326592,
        //      growth limit 201326592
        //      at StatsOverlay.readSelfTicks(StatsOverlay.kt:260)   ← 只是受害者
        //    受害者是「每秒读一次 /proc/self/stat」要的 16KB —— 堆已经满了，
        //    读什么都会死。**现象是「播 4K 约 1 分钟后必崩」**
        //    （192MiB ÷ 2.75MB/s ≈ 70s）。
        //
        //    改成堆的 **1/4**，并封顶 64MiB：
        //      * 这台电视：192MiB ÷ 4 = **48MiB** ⇒ 4K 原画约 17s 前向缓冲；
        //        超清档（0.14MB/s）下 48MiB ≈ 6 分钟，所以 `maxBufferMs=120s`
        //        在低码率档下仍然是先撞到的那个，需求不受影响。
        //      * 大堆机型（512MiB）：min(128MiB, 64MiB) = 64MiB，与
        //        ExoPlayer 自己的默认值同量级。
        val heapMax = Runtime.getRuntime().maxMemory()
        val bufferBytes = minOf(heapMax / 4, 64L * 1024 * 1024)
        Log.i(
            TAG,
            "Java 堆上限 ${heapMax / 1048576} MiB ⇒ 缓冲字节上限 " +
                "${bufferBytes / 1048576} MiB（不许再写死）",
        )

        // ── 后缓冲：**按字节预算反算，不许写死秒数**（2026-10-06 实测修正）──
        //
        // ⛔⛔ 原来写 `setBackBuffer(30_000, true)` = 「保留 30 秒」。当时的
        //    算账是「30s 在超清档下才 4MB，放得下」—— 低码率档确实放得下，
        //    但**原画档 30s = 3.67 × 30 = 110 MiB**，是 48 MiB 总预算的 2.3 倍。
        //
        //    而 `setTargetBufferBytes` 的额度是**前向 + 后向共用**的
        //    （`DefaultAllocator.getTotalBytesAllocated()` 两边都算进去），
        //    ⇒ 后缓冲把额度吃光，前向只剩 2~7s（实测）。
        //      * 播放中：锯齿 —— `15.35 → 0.98 → 3.00 → 12.79 → 0 MB/s`；
        //      * **暂停时更糟**：播放头不动 ⇒ 后缓冲样本永不回收 ⇒ 分配器恒满
        //        ⇒ `shouldContinueLoading` 因 `targetBufferSizeReached` 恒 false
        //        ⇒ **一个字节都不读**（实测「已暂停 · 已缓冲+2s · 速率 0 KB/s」
        //        卡了整整 30 秒，用户看到的就是「暂停后不缓冲了」）。
        //
        // ⇒ 改成：后缓冲**最多占字节预算的 1/4**，时长按**当前档位码率**反算，
        //    并钳在 [2s, 30s]。低码率档仍然拿得到 30s
        //    （48MiB ÷ 4 ÷ 0.31 ≈ 39s → 钳 30s），原画档只留 3.3s（12 MiB），
        //    把剩下的 36 MiB 让给前向 ≈ 9.8s。
        //
        // ⛔ 别想着打开 `setPrioritizeTimeOverSizeThresholds(true)` 来「按秒保住」
        //    后缓冲：那个开关的意思是**允许突破字节上限**，正是 10-04 那次
        //    `OutOfMemoryError` 崩溃的成因。字节上限是不许动的红线。
        val bitrateMibps = assumedBitrateMibps()
        val backBufferMs = BufferPlan.backBufferMs(bufferBytes, bitrateMibps)
        // 进度条要用它把内存缓冲区间向左延伸（后缓冲那段）。
        backBufferMsCache = backBufferMs.toLong()
        Log.i(
            TAG,
            "后缓冲 ${backBufferMs}ms（码率 %.2f MiB/s，后缓冲只占预算的 %d MiB）".format(
                if (bitrateMibps > 0.0) bitrateMibps else BufferPlan.ASSUMED_BITRATE_MIBPS,
                bufferBytes / 1048576 / 4,
            ),
        )
        // ── 分配器：自己建一个，只为了**能读数** ────────────────────
        //
        // ⛔ 这是 `DefaultLoadControl` 默认就在用的那一个，参数逐字相同
        //    （`trimOnReset = true`、分段 = `C.DEFAULT_BUFFER_SEGMENT_SIZE`），
        //    所以**行为零变化** —— 唯一的区别是我们拿到了引用，于是可以读
        //    `getTotalBytesAllocated()`：它正是 `setTargetBufferBytes` 管的那个数
        //    （「当前真正在用多少字节」），调试浮层那行「占用 43/48 MiB」就是它。
        //
        // ⛔ 不自己建的话就只能拿「已缓冲秒数 × 估算码率」去反推，而码率是估的、
        //    后缓冲还占着同一份额度 —— 算出来的数会跟预算对不上账，
        //    那比不显示更坏（这个项目已经被「两套账本」坑过一次）。
        val allocator = DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE)
        val loadControl = DefaultLoadControl.Builder()
            .setAllocator(allocator)
            .setBufferDurationsMs(
                30_000,   // minBufferMs：低于它一定继续下载
                120_000,  // maxBufferMs：暂停时能一直缓冲到这里（低码率档可达）
                1_500,    // bufferForPlaybackMs：起播阈值
                5_000,    // bufferForPlaybackAfterRebufferMs：卡完恢复的阈值
            )
            .setBackBuffer(backBufferMs, true)
            .setTargetBufferBytes(bufferBytes.toInt())
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

            /**
             * 播放/暂停**切换的那一刻**。
             *
             * ⛔ 暂停时要把控制栏叫回来、并且**不许它自动收起**：用户按暂停
             *    十有八九就是为了看「已暂停 · 已缓冲 +118s」还会不会继续长。
             *    只靠 [hideControls] 里那道兜底也能拦住「已排的收起」，但那时
             *    控制栏可能已经因为别的原因不可见，这里显式叫一次最稳。
             */
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (isPlaying) return
                // ⛔ 缓冲中 `isPlaying` 也是 false（`playWhenReady` 还是 true），
                //    那不是「用户暂停」—— 缓冲期由 `onPlaybackStateChanged` 管，
                //    别在这儿重复触发（否则每次缓冲都会多一条「已暂停」日志）。
                if (exo.playWhenReady) return
                Log.i(TAG, "已暂停 ⇒ 控制栏常驻（看缓冲进度）")
                showControls(autoHide = false)
            }

            /**
             * 位置**不连续**的那一刻 —— 跳转（拖进度条、方向键 ±10s）都走到这里。
             *
             * ⛔ 这是**唯一**通知预取器「播放头跳了」的地方。不通知的话，
             *    它会继续下用户刚刚跳过的那一段（现在落在播放头**后面**），
             *    而播放头前方一个字节都不下 —— 这就是
             *    「拖了进度条以后磁盘缓存会不会从当前位置重来」的答案：
             *    **原来不会，现在会**（见 [DiskPrefetcher.reanchor]）。
             *
             * ⛔ 只认 `DISCONTINUITY_REASON_SEEK`：
             *    `SEEK_ADJUSTMENT` 是 ExoPlayer 自己在就近同步帧上做的微调
             *    （几百毫秒量级）、`AUTO_TRANSITION` 是自动切下一个 mediaItem ——
             *    那些都不该让预取器丢下已经下好的数据。
             */
            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                if (reason != Player.DISCONTINUITY_REASON_SEEK) return
                if (bytesPerSecCache <= 0.0) return
                // ⛔ 必须**立刻**刷新快照。定时器是每秒一次，跳转后它会拿
                //    **旧位置**算领先量，预取器就以为「播放头还在老地方」
                //    而多下一整块（最多 12 秒）。
                val bytes = estimatedBytes(newPosition.positionMs).coerceAtLeast(0L)
                playheadBytesCache = bytes
                prefetcher?.reanchor(bytes)
                Log.i(
                    TAG,
                    "跳转 → ${newPosition.positionMs / 1000}s（约 ${bytes / 1048576} MiB）" +
                        " ⇒ 已通知预取器重新锚定",
                )
            }

            override fun onPlayerError(error: PlaybackException) {
                val msg = "${error.errorCodeName}: ${error.message}"
                Log.e(TAG, "播放失败 $msg", error)
                showNotice("播放失败\n$msg")
            }

            /**
             * 轨道表变了 —— **这是字幕/音轨菜单的唯一数据来源**。
             *
             * ⛔ 不要自己去 `player.currentTracks` 轮询，也不要缓存：换档、切
             *    字幕、甚至自适应码率换 rendition 都会走到这里。切换生效后
             *    **一定会**再回调一次（选中态跟着变），所以「点了没反应」这种
             *    事在这里能一眼看出来 —— 日志里没有新的 `轨道变化`，就是没生效。
             */
            override fun onTracksChanged(tracks: Tracks) {
                this@PlayerActivity.tracks = tracks
                Log.i(TAG, describeTracks(tracks))
                // 菜单开着就立刻刷新：用户按完 OK 要马上看到光标跳到新选项上。
                // （菜单没开时不用重建 View —— 那纯属白干活，`showOsd` 会补上。）
                if (osd.visibility == View.VISIBLE) rebindOsd()
            }

            /**
             * 字幕 cue 到货 —— **内嵌字幕唯一的上屏通道**。
             *
             * ⛔ 这一句就是「内嵌字幕选得上、不上屏」的修复本体。
             *    `TextRenderer` 把 cue 交给注册过的 `TextOutput`；本工程刻意不引
             *    `media3-ui`，没有 `PlayerView`/`SubtitleView` 那种现成出口，
             *    而 `Player.Listener` 的 `onCues` 是 media3 给的**等价入口**，
             *    不需要额外依赖。
             * ⛔ 别改成只接已废弃的 `onCues(List<Cue>)`：1.5.1 里
             *    `CueGroup` 版本才是主路径，`CueGroup` 还带 `presentationTimeUs`。
             * ⚠️ 字幕间隙 ExoPlayer 会回传**空** cue 组，[SubtitleOverlayView]
             *    按内容去重，空组同样是一次有效的「清屏」。
             */
            override fun onCues(cueGroup: CueGroup) {
                subtitles.setCues(cueGroup.cues)
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
        // ── 调试浮层要的三样（2026-10-06 加）─────────────────────────
        // ⛔ 分配器与预算**必须一起给**：分子分母同源，否则会显示
        //    「43/48」这种看着合理、其实不是一对的读数 —— 见 StatsOverlay.allocator。
        stats.bindBufferBudget(allocator, bufferBytes.toInt())
        // ⛔ 网速读**缓存值**，不再自己采一次样 —— 见 [rateSupplier]。
        stats.networkRateSupplier = { lastRatePerSec }
        stats.backBufferMsSupplier = { backBufferMsCache }
        stats.diskCacheSupplier = { diskCacheSnapshot() }
        stats.diskStatSupplier = { PrefetchCache.shortStat(this) }
        stats.prefetcherSupplier = { prefetcher }
        stats.start()
        controls.bind(exo)

        exo.setMediaItem(MediaItem.fromUri(url))
        openedAtMs = System.currentTimeMillis()
        exo.prepare()
        exo.playWhenReady = true

        // ⛔ 传给预取器的是 `countingParallel`（**同一把计数器**），不是 `parallel`：
        //    播放器现在几乎总是从磁盘缓存命中、不碰网络，速率会恒为 0 ——
        //    而真正在下的正是预取器。分开计数就会出现
        //    「速率 0 KB/s · 磁盘 3.3 GiB」这种自相矛盾的读数（2026-10-06 实测），
        //    用户看到 0 就以为「不缓冲了」，而这正是本需求要消灭的误判。
        //    [ByteCounter] 内部是 `AtomicLong`，两条线程同时加不会丢字节。
        startDiskPrefetch(url, cache, countingParallel, bitrateMibps)

        showNotice("正在打开…")
        // 播放器一建好就把控制栏亮出来（4 秒后自动收），让用户立刻看到
        // 进度条与缓冲进度在长 —— 这是「暂停时也在缓冲」的直接体现。
        showControls()
    }

    override fun onDestroy() {
        ui.removeCallbacks(hideControls)
        // ⛔ 防抖里的跳转也要取消：player 释放后再跑会崩，而且此时跳转
        //    已经没有意义（用户都离开播放页了）。
        ui.removeCallbacks(seekCommit)
        pendingSeekMs = -1L
        // ⛔ 快照定时器也要停：它读 `player.currentPosition`，
        //    player 释放后再跑会崩。
        ui.removeCallbacks(playheadTick)
        controls.unbind()
        prefetcher?.cancel()
        prefetcher = null
        cacheRef = null
        Log.i(TAG, "退出播放页 · ${PrefetchCache.describe(this)}")
        stats.stop()
        // ⛔ 分配器跟着播放器一起释放，浮层别再拿着它读 —— 虽然 `stats.stop()`
        //    之后不会再 tick，但把引用留着是纯粹的隐患。
        stats.bindBufferBudget(null, 0)
        player?.release()
        player = null
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // OSD —— 画质 / 音效（音轨）/ 字幕 / 倍速 / 调试
    // ------------------------------------------------------------------

    /**
     * 重绑 OSD 行。
     *
     * ⛔ **所有 `osd.bind()` 都必须走这里**：按键回调只回传行下标，靠 [osdRows]
     *    还原语义 —— 那张表必须与真正绑上去的是同一份，各建各的就会分派到别的功能。
     */
    private fun rebindOsd() {
        val rows = buildRows()
        osdRows = rows
        osd.bind(rows)
        // ⛔ 每次重绑都记一行「菜单此刻长什么样」。硬件视频层下截不到图、播放中
        //    也 dump 不到 UI，这是**唯一**能确认「用户看到的是不是我以为的那份」
        //    的通道。判据：选项里有没有「（1）（2）」这种重名序号、光标该停哪。
        Log.i(
            TAG,
            "菜单内容：" + rows.joinToString(" | ") { r ->
                val opts = if (r.options.isEmpty()) {
                    "(无选项)"
                } else {
                    r.options.mapIndexed { i, o -> if (i == r.active) "[$o]" else o }
                        .joinToString(",")
                }
                "${r.label}=${r.value} → $opts"
            },
        )
    }

    private fun buildRows(): List<TvOsdView.Row> {
        val out = ArrayList<TvOsdView.Row>(6)
        // 「画质」只在有 PlayInfo（正常取链路径）时才有。直接给 URL 的对照路径
        // 没有档位概念 ⇒ 少一行 —— 这正是回调要按 id 而不是按下标分派的原因。
        info?.let { pi ->
            out += TvOsdView.Row(
                id = ROW_QUALITY,
                label = "画质",
                value = current?.label ?: "—",
                // 选项带真实分辨率与「需要多少带宽」—— 这是选档时最该看的数字，
                // 藏进日志就没人看了。
                options = pi.qualities.map { "${it.label}  ${it.detail}" },
                active = pi.qualities.indexOfFirst { it.id == current?.id },
            )
        }
        out += parallelRow()
        out += trackRow(ROW_AUDIO, "音效", C.TRACK_TYPE_AUDIO, withOff = false)
        out += trackRow(ROW_SUBTITLE, "字幕", C.TRACK_TYPE_TEXT, withOff = true)
        out += rateRow(currentSpeed)
        out += debugRow()
        return out
    }

    /**
     * 造一行轨道选择（音轨 / 字幕）。
     *
     * ⛔ 片源里**没有**这类轨道时返回一行只有 `hint` 的行（`options` 空）。
     *    OSD 对空 options 的行，←/→ 会原样返回 false、落到 Activity 那层被吞掉
     *    —— 正好是「这行没得选」该有的表现，不用另加一套禁用逻辑。
     */
    private fun trackRow(
        id: String,
        label: String,
        type: Int,
        withOff: Boolean,
    ): TvOsdView.Row {
        val choices = trackChoices(type, withOff)
        if (choices.isEmpty()) {
            return TvOsdView.Row(
                id = id,
                label = label,
                value = "—",
                hint = if (type == C.TRACK_TYPE_TEXT) "该片源没有内嵌字幕" else "该片源没有音轨",
            )
        }
        return TvOsdView.Row(
            id = id,
            label = label,
            value = choices.firstOrNull { it.selected }?.label ?: "—",
            options = choices.map { it.label },
            active = choices.indexOfFirst { it.selected },
        )
    }

    /**
     * 「连接数」那一行 —— 多连接并行下载开几条连接。
     *
     * ⛔ 这是**全局参数**（存 `AppPrefs`，跨影片跨重启都记得），不是逐影片的
     *    播放偏好。
     *
     * ⛔ 改完**要重开这条流才生效**：`DataSourceFactory` 里传的是取值器
     *    （见 [startPlayer]），正在跑的那条流不会中途改连接数。
     *    `1 条（关）` 保留下来是为了能**现场做 A/B** —— 1 ↔ 8 一换，
     *    「卡」与「不卡」肉眼可见，比任何日志都有说服力。
     */
    private fun parallelRow(): TvOsdView.Row {
        val n = prefs.parallelConnections
        val choices = AppPrefs.PARALLEL_CHOICES
        return TvOsdView.Row(
            id = ROW_PARALLEL,
            label = "连接数",
            value = if (n <= 1) "1 条（关）" else "$n 条",
            options = choices.map { if (it <= 1) "1 条（关）" else "$it 条" },
            // ⛔ `active` 可能为 -1（存量偏好里存了个不在候选里的数）——
            //    OSD 对 -1 的语义就是「这行没有生效态」，不会崩，也不会误高亮。
            active = choices.indexOfFirst { it == n },
        )
    }

    /**
     * 「调试」那一行 —— 开关左上角那块浮层。
     *
     * ⛔ 这是**全局参数**（存 `AppPrefs`，跨影片跨重启都记得），不是逐影片的
     *    播放偏好。
     */
    private fun debugRow() = TvOsdView.Row(
        id = ROW_DEBUG,
        label = "调试",
        value = if (prefs.debugOverlay) "开启" else "关闭",
        options = listOf("关闭", "开启"),
        active = if (prefs.debugOverlay) 1 else 0,
    )

    private fun rateRow(speed: Double) = TvOsdView.Row(
        id = ROW_SPEED,
        label = "倍速",
        value = rateLabel(speed),
        options = SPEEDS.map { rateLabel(it) },
        active = SPEEDS.indexOfFirst { it == speed },
    )

    /**
     * OSD 激活回调。
     *
     * ⛔ 回调**只带行下标**，所以第一件事是按 [osdRows] 把下标还原成稳定 id
     *    再分派 —— 行数不是固定的（没有画质行、没有字幕行都会少一行），
     *    用下标 `when` 迟早把「字幕」接到「倍速」上。
     *
     * 菜单开合的取舍（照对标播放器）：
     *   * **画质** —— 换档要重建 media source、画面会黑一下，菜单收掉；
     *   * **音效 / 字幕 / 倍速 / 调试** —— 留在菜单里。挑字幕往往要连试几条，
     *     每点一下就关菜单等于逼用户重开五遍。
     */
    private fun onOsdActivate(row: Int, chip: Int) {
        when (osdRows.getOrNull(row)?.id) {
            ROW_QUALITY -> {
                info?.qualities?.getOrNull(chip)?.let { playQuality(it) }
                hideOsd()
            }
            ROW_AUDIO -> {
                applyTrackChoice(C.TRACK_TYPE_AUDIO, withOff = false, chip = chip)
                rebindOsd()
            }
            ROW_SUBTITLE -> {
                applyTrackChoice(C.TRACK_TYPE_TEXT, withOff = true, chip = chip)
                rebindOsd()
            }
            ROW_SPEED -> {
                val rate = SPEEDS.getOrNull(chip) ?: 1.0
                currentSpeed = rate
                player?.setPlaybackSpeed(rate.toFloat())
                Log.i(TAG, "OSD 倍速 → ${rateLabel(rate)}")
                rebindOsd()
            }
            ROW_PARALLEL -> {
                val n = AppPrefs.PARALLEL_CHOICES.getOrNull(chip) ?: AppPrefs.DEFAULT_PARALLEL_CONNECTIONS
                setParallelConnections(n)
                // ⛔ 必须**明确告诉用户要重开**：连接数是在 `open()` 时读的，
                //    正在跑的那条流不会变。不提示的话，用户会以为「切了没反应」，
                //    然后去怀疑是别的地方坏了。
                showNoticeBriefly(
                    if (n <= 1) "连接数 → 1 条（关）\n重开本条流生效" else "连接数 → $n 条\n重开本条流生效",
                )
                rebindOsd()
            }
            ROW_DEBUG -> setDebugOverlay(chip == 1)
            else -> {
                Log.w(TAG, "OSD 回调了未知行下标 $row（osdRows.size=${osdRows.size}）")
                hideOsd()
            }
        }
    }

    // ------------------------------------------------------------------
    // 轨道（字幕 / 音轨）
    // ------------------------------------------------------------------

    /** 一条可选轨道。`group == null` 表示「关闭」—— 只有字幕会用到。 */
    private class TrackChoice(
        val label: String,
        val group: TrackGroup?,
        val index: Int,
        val selected: Boolean,
    )

    /**
     * 枚举某一类轨道。
     *
     * ⛔ **每次现枚举，不缓存**：见 [tracks] 的注释 —— 换档后旧的 `TrackGroup`
     *    就是一张废纸，拿它去 `setOverrideForType` 不报错、但永远选不中。
     *
     * @param withOff 是否在最前面插一项「关闭」。字幕要（关字幕是常规操作）；
     *   音轨**不要** —— 关掉音轨等于把片子变默片，不是个有用的选项。
     */
    private fun trackChoices(type: Int, withOff: Boolean): List<TrackChoice> {
        val t = tracks ?: return emptyList()
        val out = ArrayList<TrackChoice>()
        if (withOff) out.add(TrackChoice(OFF_LABEL, null, -1, selected = false))
        var ordinal = 0
        var anySelected = false
        for (g in t.groups) {
            if (g.type != type) continue
            for (i in 0 until g.length) {
                ordinal++
                val sel = g.isTrackSelected(i)
                if (sel) anySelected = true
                out.add(TrackChoice(trackLabel(g, i, ordinal), g.mediaTrackGroup, i, sel))
            }
        }
        // 有轨道但一条都没选中 ⇒ 现在就是「关闭」状态，把光标指到那一项
        if (withOff && !anySelected && out.size > 1) {
            out[0] = TrackChoice(OFF_LABEL, null, -1, selected = true)
        }
        disambiguate(out)
        return out
    }

    /**
     * 给重名的轨道加序号。
     *
     * ⛔ 实测这个片源的转码档有 **2 条「韩语 · 立体声」和 2 条「中文（简体）」**
     *    （容器里就是多条独立轨道）。菜单里并排摆两个一模一样的 chip，用户
     *    根本不知道自己在切哪一条 —— 日志里也只能靠「第几组」去数。
     * ⛔ 只给**同名**的加（`（1）`/`（2）`），不无差别编号：片源只有一条音轨时
     *    显示「韩语 · 立体声（1）」是纯噪音。
     */
    private fun disambiguate(choices: MutableList<TrackChoice>) {
        val dup = choices.groupBy { it.label }.filterValues { it.size > 1 }.keys
        if (dup.isEmpty()) return
        val seen = HashMap<String, Int>()
        for (i in choices.indices) {
            val c = choices[i]
            if (c.label !in dup) continue
            val n = (seen[c.label] ?: 0) + 1
            seen[c.label] = n
            choices[i] = TrackChoice("${c.label}（$n）", c.group, c.index, c.selected)
        }
    }

    /**
     * 应用一条轨道选择。
     *
     * `setOverrideForType` 是**替换式**的：它把该 type 的 override 换成本次这条、
     * 不会叠加，所以不必先 `clearOverridesOfType` —— 那反而多出一次「无 override」
     * 的中间态，字幕会闪一下。
     *
     * 关字幕走的是另一条路：`clearOverridesOfType` + `setTrackTypeDisabled(true)`。
     * ⛔ 光清 override 不够 —— 没有 override 时 ExoPlayer 会按
     *    `preferredTextLanguages` 自己再挑一条，字幕照样出来。
     */
    private fun applyTrackChoice(type: Int, withOff: Boolean, chip: Int) {
        val p = player ?: return
        val choice = trackChoices(type, withOff).getOrNull(chip)
        if (choice == null) {
            Log.w(TAG, "轨道下标越界：type=$type chip=$chip")
            return
        }
        val b = p.trackSelectionParameters.buildUpon()
        if (choice.group == null) {
            b.clearOverridesOfType(type)
            b.setTrackTypeDisabled(type, true)
            Log.i(TAG, "切${trackTypeName(type)} → 关闭")
        } else {
            b.setTrackTypeDisabled(type, false)
            b.setOverrideForType(TrackSelectionOverride(choice.group, choice.index))
            Log.i(
                TAG,
                "切${trackTypeName(type)} → ${choice.label}" +
                    "（组内第 ${choice.index} 条，共 ${choice.group.length} 条）",
            )
        }
        p.trackSelectionParameters = b.build()
    }

    private fun trackLabel(g: Tracks.Group, i: Int, ordinal: Int): String {
        val f = g.getTrackFormat(i)
        val type = g.type
        val name = f.label?.trim()?.takeIf { it.isNotEmpty() }
        val fallback = when (type) {
            C.TRACK_TYPE_TEXT -> "字幕 $ordinal"
            C.TRACK_TYPE_AUDIO -> "音轨 $ordinal"
            C.TRACK_TYPE_VIDEO -> "视频 $ordinal"
            else -> "轨道 $ordinal"
        }
        val sb = StringBuilder(name ?: languageName(f.language) ?: fallback)
        when (type) {
            C.TRACK_TYPE_TEXT -> {
                if ((f.selectionFlags and C.SELECTION_FLAG_FORCED) != 0) sb.append("（强制）")
            }
            C.TRACK_TYPE_AUDIO -> {
                channelLabel(f.channelCount)?.let { sb.append(" · ").append(it) }
                surroundCodec(f.sampleMimeType)?.let { sb.append(" · ").append(it) }
            }
            // 视频轨只进日志（菜单里没有「视频轨」这一行，画面档位由「画质」管），
            // 所以这里带上分辨率，方便对着 `片源 1440x810` 那条日志核对。
            C.TRACK_TYPE_VIDEO -> {
                if (f.width > 0 && f.height > 0) sb.append(" · ${f.width}x${f.height}")
            }
        }
        return sb.toString()
    }

    /**
     * ISO 639 语言码 → 中文名。
     *
     * ⛔ 不用 `Locale.forLanguageTag(...).displayLanguage`：那个跟着**系统语言**
     *    走，电视设成英文时菜单会变成 "Chinese"，而这块菜单是照对标播放器做的中文界面。
     */
    private fun languageName(lang: String?): String? {
        val l = lang?.trim()?.lowercase()
        if (l.isNullOrEmpty() || l == "und" || l == "unknown") return null
        return when {
            l.contains("yue") -> "粤语"
            l.startsWith("zh") -> if (
                l.contains("hant") || l.contains("tw") || l.contains("hk") || l.contains("mo")
            ) {
                "中文（繁体）"
            } else {
                "中文（简体）"
            }
            l.startsWith("en") -> "英语"
            l.startsWith("ja") -> "日语"
            l.startsWith("ko") -> "韩语"
            l.startsWith("fr") -> "法语"
            l.startsWith("de") -> "德语"
            l.startsWith("es") -> "西班牙语"
            l.startsWith("pt") -> "葡萄牙语"
            l.startsWith("ru") -> "俄语"
            l.startsWith("it") -> "意大利语"
            l.startsWith("th") -> "泰语"
            l.startsWith("vi") -> "越南语"
            else -> l
        }
    }

    private fun channelLabel(n: Int): String? = when (n) {
        1 -> "单声道"
        2 -> "立体声"
        6 -> "5.1"
        8 -> "7.1"
        else -> if (n > 0) "${n} 声道" else null
    }

    /**
     * 只标出电视用户真正在意的两种：杜比 / DTS。其余不标，省得菜单太长。
     * ⛔ `eac3` 必须先判 —— 它字符串里含 `ac3`，顺序反了会把杜比+标成杜比。
     */
    private fun surroundCodec(mime: String?): String? = when {
        mime == null -> null
        mime.contains("eac3") -> "杜比+"
        mime.contains("ac3") -> "杜比"
        mime.contains("ac4") -> "杜比 AC-4"
        mime.contains("dts") -> "DTS"
        else -> null
    }

    private fun trackTypeName(type: Int): String = when (type) {
        C.TRACK_TYPE_AUDIO -> "音轨"
        C.TRACK_TYPE_TEXT -> "字幕"
        C.TRACK_TYPE_VIDEO -> "视频"
        else -> "轨道($type)"
    }

    /**
     * 把轨道表打成人能读的日志。
     *
     * ⛔ 硬件视频层下 `screencap` 全黑、播放中 `uiautomator dump` 拿不到 UI，
     *    所以**字幕/音轨到底有没有切成功，只能靠这条日志判**。判据：
     *    切换后应立刻出现一条新的「轨道变化」，且对应条目带 `← 选中`。
     *
     * ⚠️ 这里的标签是**原始**标签（不带重名序号），而菜单里重名的会显示成
     *    `中文（简体）（1）`。两边对照请看紧随其后的「菜单内容」那条。
     */
    private fun describeTracks(t: Tracks): String {
        val sb = StringBuilder("轨道变化：")
        if (t.groups.isEmpty()) return sb.append("（无）").toString()
        for (g in t.groups) {
            sb.append("\n  ").append(trackTypeName(g.type))
                .append(" ×").append(g.length)
            for (i in 0 until g.length) {
                val f = g.getTrackFormat(i)
                sb.append("\n    #").append(i).append(' ')
                    .append(trackLabel(g, i, i + 1))
                    .append("  ").append(f.sampleMimeType ?: f.containerMimeType ?: "")
                    .append(if (g.isTrackSelected(i)) "  ← 选中" else "")
            }
        }
        return sb.toString()
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
        rebindOsd()
    }

    /**
     * 改多连接并行的连接数。
     *
     * ⛔ **不重建播放器**：连接数是 `DataSourceFactory` 里的取值器，下一次
     *    `open()`（换档 / 重开这条流 / seek 到未缓冲区）就会用新值。
     *    正在跑的那条流不受影响 —— 这一点必须提示用户（见 [onOsdActivate]）。
     */
    private fun setParallelConnections(n: Int) {
        prefs.parallelConnections = n
        Log.i(TAG, "连接数（全局参数）= $n 条（重开本条流生效）")
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
        val code = event.keyCode

        // ── 快进/快退键的**松手** ──────────────────────────────────
        // ⛔ 这一段必须放在「只认 ACTION_DOWN」那道门**之前**：用户按住方向键
        //    时系统只送一串 ACTION_DOWN，松手才送 ACTION_UP —— 那是「拖动结束」
        //    的**精确**信号。靠它提交，就不可能出现「还没松手，进度已经被调了」。
        // ⛔ 但覆盖层（退出确认 / OSD）开着时方向键归它们，不能当快进 ——
        //    所以这里要和下面那两道判断用同一套条件。
        if (event.action == KeyEvent.ACTION_UP &&
            !confirmExit.isShowing &&
            osd.visibility != View.VISIBLE &&
            onSeekKeyUp(code)
        ) {
            stats.markKey()
            return true
        }

        // ⛔ 其余只认 `ACTION_DOWN`。遥控器长按连发在 Android TV 上本来就是
        //    一串独立的 ACTION_DOWN，收 ACTION_MULTIPLE 只会多一条没用的分支。
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)

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
     *    （对标播放器也是暂停的）。取消时**按原样恢复** —— 本来就是暂停的，取消后
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
     * 待提交的跳转目标（毫秒）；**`< 0` = 没有**。
     *
     * ⛔ 存在的理由是遥控器方向键的**自动重复**：按住 `→` 时系统约 20 次/秒
     *    地送 `KEYCODE_DPAD_RIGHT`。若每次按键都真发一次 `seekTo`，有两个后果，
     *    都是 2026-10-06 真机实测到的：
     *
     *    1. **卡顿、不跟手** —— 每次 `seekTo` 都要让 ExoPlayer 拆掉当前 load、
     *       重开数据源、重建解码管线。20 次/秒地拆建，画面根本来不及出，
     *       用户看到的就是「拖起来非常卡」。
     *    2. **OOM 崩溃** —— 每次重开数据源都会新建一个 `ParallelRangeReader`，
     *       它**一次性**分配 `8 × 2 MiB = 16 MiB` 的槽位数组。实测一次拖拽
     *       2 秒内发起 28 次 seek，堆被打到 `192MB/192MB`，且 GC
     *       `freed 0(0B)`（那些数组全部强可达），进程被杀：
     *       `FATAL EXCEPTION: cc-range-1 / java.lang.OutOfMemoryError`。
     *
     * 所以：按键只累加这个目标（UI 立刻跟手），真跳转由 [seekCommit]
     * **防抖后只发一次**。实测口径：同一次拖拽从 28 次 `seekTo` 降到 1 次。
     */
    private var pendingSeekMs = -1L

    /**
     * 本轮「连续快进」的起始时刻（`elapsedRealtime`）；**`< 0` = 没有在进行中**。
     *
     * 用它算「按住多久了」，交给 [SeekPlan.multiplier] 决定加速倍率。
     * ⛔ 必须在**提交时清零**：否则下一轮拖动会接着上一轮的时长继续加速，
     *    变成「按一下就飞到底」。
     */
    private var seekSessionStartMs = -1L

    /**
     * 兜底提交的定时器。
     *
     * ⛔ **主路径不是它，而是按键的 `ACTION_UP`**（见 [onSeekKeyUp]）。
     *    遥控器松手会送来一个 `ACTION_UP` —— 那是「拖动结束」的**精确**信号，
     *    比任何时间窗口都准。
     *
     * ⛔ 之所以还要这个兜底：个别遥控器/机顶盒**不发 `ACTION_UP`**。
     *    没有兜底就会「按完永远不跳」—— 那比跳早了更糟。
     *
     * ⛔ 窗口必须**大于遥控器的自动重复间隔**。实测过：原来的 400ms 小于
     *    某些遥控器的重复间隔（约 500ms），于是按住时每按一下就提交一次 ——
     *    用户的原话是「拖动过程中会触发影片进度调整，实际上并没有释放
     *    拖动按钮」。800ms 留出余量，同时又不会让「按一下」等太久。
     */
    private val seekCommit = Runnable { commitPendingSeek() }

    /**
     * 相对跳转（遥控器 `←→` ±10s / 快进快退键 ±30s）。
     *
     * ⛔ **不再直接 `seekTo`** —— 只挪待提交目标，见 [pendingSeekMs]。
     *    用 `seekTo(currentPosition ± delta)` 而不是 `Player.seekBy()`：后者在
     *    media3 1.3 才加进来，这里刻意钉在 1.5.1。负数要夹到 0 ——
     *    `seekTo(-10000)` 会被 ExoPlayer 当成「seek 到末尾」，是个不报错的坑。
     *
     * ⛔ 基准必须是**待提交目标**而不是 `currentPosition`：连续按右键时
     *    `currentPosition` 还停在老位置（上一次的 seek 还没提交），拿它累加
     *    会让「按 10 次右键只走 10 秒」。
     */
    private fun seekBy(deltaMs: Long) {
        val p = player ?: return
        val now = SystemClock.elapsedRealtime()
        if (seekSessionStartMs < 0L) seekSessionStartMs = now
        // 按住越久步子越大 —— 否则 2 小时的片子要按住 36 秒才到底。
        // 倍率表与「前 2 秒必须 ×1」的约定都在 [SeekPlan.multiplier] 里。
        val step = SeekPlan.acceleratedDelta(deltaMs, now - seekSessionStartMs)
        // 累加与夹取的算术在 [SeekPlan.step] 里，**有单测**（含溢出与
        // 「时长未知时不许拿 -1 去夹」两个坑）。
        val target = SeekPlan.step(pendingSeekMs, p.currentPosition, step, p.duration)
        pendingSeekMs = target
        // 立刻把进度条与时间文字挪过去 —— 「跟手」就来自这一步。
        controls.showPendingSeek(target)
        ui.removeCallbacks(seekCommit)
        ui.postDelayed(seekCommit, SEEK_FALLBACK_MS)
    }

    /**
     * 快进/快退键**松手**。
     *
     * ⛔ **不能在这里直接 `seekTo`** —— 松手只是「可以提交了」的信号，不是
     *    「马上提交」。直接提交的话，**快速连点**（`DOWN/UP` 成对、间隔
     *    几十毫秒）会变成一串 seek，而实测 28 次 seek 就能把堆打满
     *    （`FATAL EXCEPTION: cc-range-1 / OutOfMemoryError`）。
     *
     * 所以这里的动作是：把兜底窗口从 [SEEK_FALLBACK_MS] **缩短**成
     * [SEEK_RELEASE_MS]。于是：
     *   * **长按**：一串 `ACTION_DOWN` 不断把窗口重置成 800ms，最后那个
     *     `ACTION_UP` 把它缩到 150ms ⇒ 松手后 150ms 提交**一次**；
     *   * **连点**：每个 `UP` 都把窗口缩到 150ms，而下一对按键 67ms 后又
     *     把它重置 ⇒ 最后一次之后 150ms 才提交，同样只有**一次**；
     *   * **单击**：150ms 后生效 —— 快到用户感觉不到。
     *
     * @return 是否消费掉了这个事件
     */
    private fun onSeekKeyUp(code: Int): Boolean {
        if (!isSeekKey(code)) return false
        // ⛔ 兜底定时器已经提交过（`pendingSeekMs < 0`）就什么都不做，
        //    但**事件仍要吞掉** —— 否则它漏给 `super` 会被系统当成一次
        //    「按键未处理」去做别的默认动作。
        if (pendingSeekMs >= 0L) {
            ui.removeCallbacks(seekCommit)
            ui.postDelayed(seekCommit, SEEK_RELEASE_MS)
        }
        return true
    }

    /** 这几个键才走「累加 + 防抖」那条路（见 [seekBy]）。 */
    private fun isSeekKey(code: Int): Boolean =
        code == KeyEvent.KEYCODE_DPAD_LEFT ||
            code == KeyEvent.KEYCODE_DPAD_RIGHT ||
            code == KeyEvent.KEYCODE_MEDIA_FAST_FORWARD ||
            code == KeyEvent.KEYCODE_MEDIA_REWIND

    /**
     * 把攒下的目标落成**一次**跳转。
     *
     * 走的是与触摸拖拽**同一条** [seekToPosition]：同一份日志、同一份
     * 「内存/磁盘是否命中」判断。两处各写一套必然漂移，而漂移的读数会被
     * 当成 bug 追（这条在磁盘缓存层已经吃过一次亏）。
     */
    private fun commitPendingSeek() {
        val target = pendingSeekMs
        pendingSeekMs = -1L
        // ⛔ 加速档位跟着本轮结束一起清零，否则下一轮会「按一下就飞到底」。
        seekSessionStartMs = -1L
        if (target < 0L) return
        seekToPosition(target, "快进")
    }

    private fun showOsd() {
        // ⛔ 先重绑再定位光标：行是现造的（字幕/音轨的行数随片源变），
        //    `resetSelectionForTest()` 里的 `currentOptionIndex()` 读的是
        //    **已经绑上去的那份 rows**，顺序反了光标就会落在上一份表上。
        rebindOsd()
        osd.resetSelectionForTest()
        osd.visibility = View.VISIBLE
        // ⛔ 必须紧跟着抬字幕：菜单卡片占了屏幕下半截，不抬的话字幕正好被压住。
        updateSubtitleInset()
        stats.markKey()
        Log.i(TAG, "OSD 打开（${osdRows.size} 行：${osdRows.joinToString("/") { it.id }}）")
    }

    private fun hideOsd() {
        osd.visibility = View.GONE
        updateSubtitleInset()
        Log.i(TAG, "OSD 关闭")
    }

    // ------------------------------------------------------------------
    // 贴底控制栏
    // ------------------------------------------------------------------

    /**
     * 亮出控制栏。
     *
     * @param autoHide 是否 4 秒后自动收起。**缓冲中与暂停时必须传 false** ——
     *   用户正盯着「缓冲中 · 3.2 MB/s」判断是不是网络问题、盯着
     *   「已暂停 · 已缓冲 +118s」看它还会不会长，收起来等于把读数抢走。
     *   ⛔ 就算传了 true 也不怕：[keepControlsVisible] 会兜底，
     *      排了收起也不会真的收。
     */
    private fun showControls(autoHide: Boolean = true) {
        if (!::controls.isInitialized) return
        setControlsShown(true)
        ui.removeCallbacks(hideControls)
        // ⛔ 正在「被读」时就别排这一拍：省一次无谓的唤醒，也让意图在代码里看得见。
        if (autoHide && !keepControlsVisible()) ui.postDelayed(hideControls, CONTROLS_HIDE_MS)
    }

    private fun scheduleHideControls() {
        ui.removeCallbacks(hideControls)
        if (!keepControlsVisible()) ui.postDelayed(hideControls, CONTROLS_HIDE_MS)
    }

    /** 用户主动收（返回键），**不受缓冲状态阻挡**。 */
    private fun hideControlsNow() {
        ui.removeCallbacks(hideControls)
        setControlsShown(false)
    }

    /**
     * 控制栏显隐的**唯一**入口。
     *
     * ⛔ 别退回直接写 `controls.visibility`：字幕的底距要跟着控制栏走
     *    （见 [updateSubtitleInset]），漏掉一处就会出现「控制栏弹出来把字幕
     *    压在底下」—— 而这台电视上字幕看不见，用户第一反应是「字幕又没了」。
     */
    private fun setControlsShown(shown: Boolean) {
        if (!::controls.isInitialized) return
        controls.visibility = if (shown) View.VISIBLE else View.GONE
        updateSubtitleInset()
    }

    /**
     * 重算字幕底距：**贴画面下缘，被控制栏 / OSD 挡住时抬到它们上面**。
     *
     * 三档取值（单位 px，本机 density=320 ⇒ 1 dp = 2 px）：
     *   * 什么都没有 —— [SUBTITLE_BASE_INSET_DP]，正好落在宽银幕片源的下信箱边里；
     *   * 控制栏亮着 —— 抬到控制栏上沿再留一口气；
     *   * OSD 开着 —— 抬到菜单卡片上沿（卡片是 7×40dp + 28dp，见 `TvOsdView`）。
     *
     * ⛔ 用 `maxOf` 而不是相加：控制栏与菜单在布局上**互斥**（菜单开着时不画
     *    控制栏），相加只会把字幕顶到屏幕中间去。
     */
    private fun updateSubtitleInset() {
        if (!::subtitles.isInitialized) return
        var inset = dp(SUBTITLE_BASE_INSET_DP)
        if (::controls.isInitialized && controls.visibility == View.VISIBLE) {
            // 布局前 `controls.height` 还是 0，用估算值兜底。
            val h = if (controls.height > 0) controls.height else dp(CONTROLS_FALLBACK_DP)
            inset = maxOf(inset, h + dp(SUBTITLE_GAP_DP))
        }
        if (::osd.isInitialized && osd.visibility == View.VISIBLE) {
            inset = maxOf(inset, osd.sheetHeightPx() + dp(SUBTITLE_GAP_DP))
        }
        subtitles.bottomInsetPx = inset
    }

    /**
     * 拖到某个比例。
     *
     * 落在**已缓冲区间**内时 ExoPlayer 直接从 `SampleQueue` 出帧，不碰网络 ——
     * 这就是需求里「拖到已缓冲进度就直接播、不用重新缓冲」的实现方式：
     * 不需要任何特殊处理，只要不误调 `prepare()`、并让用户能看见缓冲区间
     * （进度条那层浅色）就够了。
     *
     * ⛔ 日志里必须把「内存缓冲」与「磁盘缓存」分开说：命中磁盘缓存同样
     *    **不用重新缓冲**（`CacheDataSource` 直接从盘上读）。只写「区间外，
     *    需缓冲」会在用户拖进磁盘缓存时给出相反的结论，验证时会被带偏。
     */
    private fun seekToRatio(ratio: Float) {
        val p = player ?: return
        val d = p.duration
        if (d == C.TIME_UNSET || d <= 0) return
        val target = (d * ratio.toDouble()).toLong().coerceIn(0L, d)
        // 触摸拖拽本来就是「松手才提交」（见 `SeekBarView.onTouchEvent`），
        // 理论上不会与防抖定时器并存；这里清一下纯属保险 —— 万一上一轮
        // 遥控器快进的提交还没落地，用户又去拖了进度条，两个跳转会打架。
        ui.removeCallbacks(seekCommit)
        pendingSeekMs = -1L
        seekSessionStartMs = -1L
        seekToPosition(target, "触摸")
    }

    /**
     * **唯一**真正的跳转落点 —— 触摸拖拽与遥控器快进都必须走这里。
     *
     * ⛔ 两处各写一遍 `seekTo` 会让日志口径与「内存/磁盘是否命中」的判断
     *    漂移，而漂移的读数会被当成 bug 追。
     *
     * @param source 只进日志：`触摸` / `快进`。排查「谁在拖」时这一栏是
     *               分水岭 —— 曾经因为看不出是触摸还是按键，把一个
     *               「松手前就提交」的问题误判成了别的原因。
     */
    private fun seekToPosition(targetMs: Long, source: String) {
        val p = player ?: return
        val d = p.duration
        val max = if (d == C.TIME_UNSET || d <= 0L) Long.MAX_VALUE else d
        val target = targetMs.coerceIn(0L, max)
        // ⛔ `bufferedPosition` 必须在 `seekTo` **之前**读。
        //    拖到未缓冲处时 ExoPlayer 会把 `bufferedPosition` 夹到新位置
        //    （≥ target），于是 `target <= bufferedPosition` **恒为真** ——
        //    日志会永远说「内存区间内，不需重新缓冲」，而下面「磁盘缓存命中」
        //    那一路变成**死代码**。（2026-10-06 真机拖拽实测抓出来的：
        //    拖到 88:56、内存缓冲明明只有 +58s，却报了「内存区间内」。）
        val bufferedBefore = p.bufferedPosition
        p.seekTo(target)
        val inBuffer = target <= bufferedBefore
        // 估算位置是否落在磁盘已提交的区间里 —— 见 [DiskCacheSnapshot.covers]。
        val inDisk = !inBuffer && diskCacheSnapshot().covers(estimatedBytes(target))
        Log.i(
            TAG,
            "跳转提交[$source] → ${target / 1000}s（跳前内存缓冲到 ${bufferedBefore / 1000}s，" +
                when {
                    inBuffer -> "内存区间内，不需重新缓冲）"
                    inDisk -> "内存区间外、磁盘缓存命中，不需重新缓冲）"
                    else -> "两处都没命中，需缓冲）"
                },
        )
        // 跳转已落地 ⇒ 松开进度条，让 ticker 恢复正常回写。
        controls.endExternalScrub()
        showControls()
    }

    /**
     * 把媒体时间换算成文件里的**字节**位置。
     *
     * ⛔ 用的是**平均码率**（`Quality.requiredMbPerSec`），VBR 片源必然有偏差 ——
     *    只用于「大概在不在缓存区间里」这类判断，不能当精确偏移使。
     *    返回 -1 表示换算不了（拿不到码率）。
     */
    private fun estimatedBytes(positionMs: Long): Long {
        val r = bytesPerSecCache
        if (r <= 0.0 || positionMs <= 0L) return -1L
        return (positionMs / 1000.0 * r).toLong()
    }

    // ------------------------------------------------------------------

    private fun showNotice(text: String) {
        notice.text = text
        notice.visibility = View.VISIBLE
    }

    /**
     * 临时提示：`ms` 后自动收掉。
     *
     * ⛔ 不能直接用 [showNotice]：它只在**播放状态变化**时才被 [hideNotice] 收掉，
     *    而「改连接数」不改变播放状态（尤其暂停时）—— 提示会一直挂在画面正中，
     *    比不提示还烦。
     * ⛔ 用**文本比对**而不是无脑 `postDelayed(::hideNotice)`：连点两次时，
     *    第一次排的那一拍会在第二次的提示还显示着的时候把它收掉，
     *    看起来就像「第二次没生效」。
     */
    private fun showNoticeBriefly(text: String, ms: Long = 2_500L) {
        showNotice(text)
        ui.postDelayed({
            if (notice.text.toString() == text) hideNotice()
        }, ms)
    }

    private fun hideNotice() {
        notice.visibility = View.GONE
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        const val TAG = "CloudCine"
        const val EXTRA_FID = "fid"
        const val EXTRA_NAME = "name"
        const val EXTRA_HEADERS = "headers"

        private const val BrowserUa =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

        private val SPEEDS = listOf(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)

        // ── OSD 行的稳定标识 ────────────────────────────────────────
        // ⛔ 原生 OSD 只回传**行下标**，而「画质」行在对照路径上不存在、
        //    「字幕/音效」行在片源没有对应轨道时会退化成一句提示 —— 行数
        //    不是固定的。所以分派一律走这些 id，不要 `when (row) { 0 -> ... }`。
        private const val ROW_QUALITY = "quality"
        private const val ROW_PARALLEL = "parallel"
        private const val ROW_AUDIO = "audio"
        private const val ROW_SUBTITLE = "subtitle"
        private const val ROW_SPEED = "speed"
        private const val ROW_DEBUG = "debug"

        /** 字幕那一行最前面的「关闭」项。 */
        private const val OFF_LABEL = "关闭"

        /** 没人按键就把控制栏收起来。4 秒够看清缓冲进度在长，又不挡画面。 */
        private const val CONTROLS_HIDE_MS = 4_000L

        /**
         * 方向键步进。10 秒是电视端的通行值：够快（一部长片按 50 下到底），
         * 又不会一按就跳过头。
         *
         * ⛔ 遥控器长按连发是**一串独立按键事件**（约 20 次/秒）。这些事件
         *    **不能**每个都真发一次 `seekTo` —— 那会 20 次/秒地拆建解码管线，
         *    既卡顿又爆堆（见 [pendingSeekMs]）。它们只累加待提交目标。
         */
        private const val SEEK_STEP_MS = 10_000L

        /**
         * **兜底**提交窗口（毫秒）：用户还在按键时，用它等「按完」。
         *
         * ⛔ 主路径不是它 —— 是按键的 `ACTION_UP`（见 [onSeekKeyUp]），
         *    它会把窗口缩短成 [SEEK_RELEASE_MS]。这里只为「遥控器不发
         *    `ACTION_UP`」的机型兜底，所以宁可给宽一点。
         *
         * ⛔ **必须大于遥控器的自动重复间隔**。原来是 400ms，而部分遥控器
         *    的重复间隔约 500ms ⇒ 按住时每按一下就提交一次，表现成
         *    「拖动过程中会触发影片进度调整，实际上并没有释放拖动按钮」
         *    （2026-10-06 用户原话）。800ms 留出余量。
         * ⛔ 也别调到 1.5s 以上：真遇到不发 `ACTION_UP` 的机型，用户会觉得
         *    「按完半天不动」。
         */
        private const val SEEK_FALLBACK_MS = 800L

        /**
         * **松手**之后的提交延迟（毫秒）。
         *
         * 用户已经松手，可以尽快生效；但留 150ms 是为了让**连点**也能合并
         * —— 见 [onSeekKeyUp] 的三种情形。低于 100ms 就接近「每次按键都提交」
         * 了，连点会退化成 seek 风暴。
         */
        private const val SEEK_RELEASE_MS = 150L

        /**
         * 「播放头字节位置」快照的刷新周期。
         *
         * 1 秒足够：它只用来决定预取器「能领先播放头多少」，
         * 而领先量是几百 MiB 的量级，误差几百毫秒无所谓。
         * ⛔ 别调快：这个回调跑在主线程上，而主线程已经背着
         * 「每 tick 重建整页」的负担（见 PlayerControlsView 的注释）。
         */
        private const val PLAYHEAD_TICK_MS = 1_000L

        /**
         * 字幕**底距**（dp）。
         *
         * 1080p / density=320 下是 144 px。挑这个值是为了让宽银幕片源（如
         * 2.39:1）的字幕正好落在下信箱边里 —— 信箱边实测约 138 px 高。
         * ⛔ 别按「贴着屏幕底」来设：屏幕最底下那几十像素在电视上常被
         *    机壳/过扫描吃掉，贴底的字幕会被切掉下半截。
         */
        private const val SUBTITLE_BASE_INSET_DP = 72

        /** 字幕与控制栏 / 菜单之间的呼吸位（dp）。 */
        private const val SUBTITLE_GAP_DP = 16

        /**
         * 控制栏高度的**估算值**（dp），只在布局完成前兜底用。
         *
         * 布局后一律以 `controls.height` 实测为准；估算值存在的意义是
         * 「控制栏刚 VISIBLE、还没量过」的那一拍别把字幕压在它底下。
         */
        private const val CONTROLS_FALLBACK_DP = 96
    }
}
