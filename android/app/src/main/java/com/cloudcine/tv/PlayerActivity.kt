package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
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
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultAllocator
import com.cloudcine.tv.library.DeviceIdentity
import com.cloudcine.tv.library.EpisodeLabels
import com.cloudcine.tv.library.EpisodeThumbs
import com.cloudcine.tv.library.IntroMarker
import com.cloudcine.tv.library.IntroSession
import com.cloudcine.tv.library.dirPathOf
import com.cloudcine.tv.library.fullPathOf
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryItem
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.LibrarySchema
import com.cloudcine.tv.library.MissingReceipt
import com.cloudcine.tv.library.MissingReceipts
import com.cloudcine.tv.library.OutroSkip
import com.cloudcine.tv.library.PlaybackResume
import com.cloudcine.tv.library.ProgressStore
import com.cloudcine.tv.library.ScanItem
import com.cloudcine.tv.library.SeekObservation
import com.cloudcine.tv.library.SkipAnchor
import com.cloudcine.tv.library.SkipAnchorCollector
import com.cloudcine.tv.library.SkipLearning
import com.cloudcine.tv.library.SkipSample
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.PlayInfo
import com.cloudcine.tv.pan.Quality
import com.cloudcine.tv.pan.DriveClient
import com.cloudcine.tv.pan.DriveClients
import com.cloudcine.tv.pan.DriveException
import com.cloudcine.tv.pan.DriveProviders
import com.cloudcine.tv.pan.PanHttp
import com.cloudcine.tv.pan.SubtitleFile
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.baidu.BaiduEndpoints
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

    /**
     * 当前片的**网盘文件 id**（来自 `EXTRA_FID`；夸克是 `fid`、百度是 `fs_id`）。
     * 空 = 走「直接给 URL」的对照路径。
     */
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
        get() = if (currentFid.isEmpty()) "" else "$provider:$currentFid:$currentQualityId"

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

    /**
     * 没有稳定键（对照路径）时退回 media3 默认的「按 URL」行为。
     *
     * ⛔ **HLS/DASH 必须按 URL 分键**，不能共用 `quark:<fid>:<档位>`：
     *    那种媒体**不是一个文件**，而是「一个播放列表 + N 个分片」，
     *    每个 URL 都是一条独立的字节流。共用一个键的后果是
     *    **分片请求命中播放列表的字节**，解封装器报
     *    `Cannot find sync byte. Most likely not a Transport Stream` ——
     *    看起来像片源坏了，其实是两条流被串成了一条
     *    （2026-10-06 真机实测：`179.mkv` 的 4K 档）。
     *
     * ⛔⛔ 判据必须用 [currentIsPlaylist]（**档位级**），**不能**只看当前
     *    URL 的后缀：HLS 的**分片**地址通常不带 `.m3u8`（如 `…/media_0.ts`），
     *    只按 URL 判就会漏掉分片 —— 实测第一次修就是这样，
     *    播放列表走了新键（网络实读 0.12 MiB），分片却落回旧键、
     *    **从缓存里读到播放列表文本**，网络一次都没开就报同一个错。
     *
     * ⛔ 这里**故意**用完整 URL（含签名）当后半段，而不是只用路径：
     *    路径不保证唯一（分片可能同路径、只差 query），而键撞了就是**静默**
     *    播错数据。HLS 的分片本来就只读一次，跨会话复用毫无价值 ——
     *    用「零碰撞」换掉那点收益是划算的。
     */
    private fun cacheKeyFor(uri: Uri): String {
        val k = stableCacheKey
        if (k.isEmpty()) return CacheKeyFactory.DEFAULT.buildCacheKey(DataSpec(uri))
        val url = uri.toString()
        // 只打**第一条分片**：它的末段长什么样，正是「分片不带 `.m3u8`」
        // 这个判据的直接证据。每片都打会刷屏。
        if (currentIsPlaylist && !loggedSegmentUrl && !PlaylistUrl.isPlaylist(url)) {
            loggedSegmentUrl = true
            Log.i(TAG, "HLS 分片地址末段=${uri.lastPathSegment}（不带 .m3u8 ⇒ 只能靠档位级标记分键）")
        }
        return if (currentIsPlaylist || PlaylistUrl.isPlaylist(url)) "$k#$url" else k
    }

    /** 见 [cacheKeyFor]：日志去重用，只关心第一次。 */
    @Volatile
    private var loggedSegmentUrl = false

    /**
     * **当前档位**是不是 HLS/DASH 播放列表。
     *
     * ⛔ 见 [cacheKeyFor]：必须是**档位级**状态，逐 URL 判断会漏掉分片。
     *    由 [playQuality] 在换档时写入，早于任何一次 `open()`。
     */
    @Volatile
    private var currentIsPlaylist = false

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
                // 片头跳过 / 片尾提示 / 落点采集都挂在**这一条 1 秒的心跳**上，
                // 而不是 10 秒的 `progressTick`：跳过片头要「刚进区间就跳」，
                // 而 10 秒的粒度会让用户先看十秒片头再被跳走 —— 那还不如不跳。
                tickSkipLearning(p)
            }
            ui.postDelayed(this, PLAYHEAD_TICK_MS)
        }
    }

    /** 全局参数（调试浮层开关等），与登录态分开存。 */
    private lateinit var prefs: AppPrefs
    private var api: DriveClient? = null

    /**
     * 当前条目属于哪家网盘（`quark` / `baidu`）。
     *
     * ⛔ 它决定三件事：取链走哪个客户端、CDN 请求头用哪套方言、并行连接数
     * 上不上限。缺省夸克 —— 老路径（直接给 URL / 文件列表）的意图里没有它。
     */
    private var provider: String = DriveProviders.QUARK

    /**
     * 按厂家缓存的客户端（选集封面要按**地址归属**选，见 `ThumbSource.fetch`）。
     *
     * ⛔ 同步包装：封面下载在后台线程池里并发跑，普通 `HashMap` 并发写会丢条目。
     */
    private val clients: MutableMap<String, DriveClient> =
        java.util.Collections.synchronizedMap(HashMap())

    /** 取（并按需创建）某个网盘的客户端。 */
    private fun clientOf(p: String): DriveClient =
        clients[p] ?: DriveClients.create(p, store).also { clients[p] = it }

    /**
     * 一条图片地址属于哪家网盘 —— **按域名**判，不按当前片。
     *
     * ⛔ 与 `LibraryActivity.providerOfUrl` 同一口径：封面地址是扫描时存下来的，
     *    按域名判永远对得上。
     */
    private fun clientFor(url: String): DriveClient =
        clientOf(if (BaiduEndpoints.ownsUrl(url)) DriveProviders.BAIDU else DriveProviders.QUARK)
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
     * 重建播放器后要还原的轨道选择（按**标签**匹配，不按下标）。
     *
     * 目前唯一的写入方是 [applyAudioEffect]：改音效必须重建播放器，而
     * `TrackSelectionOverride` 是**指向具体 `TrackGroup` 的对象**，跨播放器
     * 带不过去（见 [tracks] 的注释）。所以只能记住「用户选的是哪一条」的
     * **标签**，等新播放器报出轨道表后按标签重新选中。
     *
     * ⛔ `null` 表示没有待还原的东西 —— 每次还原**消费一次就清空**，
     *    否则用户之后手动切的轨会被反复拽回去（`onTracksChanged` 会多次回调）。
     */
    private var pendingTracks: PendingTracks? = null

    /** [pendingTracks] 的内容：音轨与字幕各一个「标签」，`null` = 没选过。 */
    private class PendingTracks(val audio: String?, val subtitle: String?)

    /**
     * 当前绑给 OSD 的行。
     *
     * ⛔ 按键回调只回传**行下标**，靠 [TvOsdView.Row.id] 还原语义 ——
     *    所以这张表必须与 `osd.bind()` 的那张是同一份，别各建各的。
     */
    private var osdRows: List<TvOsdView.Row> = emptyList()

    // ── 选集（同一部作品下的其它文件）──────────────────────────────
    //
    // 需求：「剧集播放中应该支持选择文件列表（哪一集）」。实现是**照 PC 端**
    // 那一行 —— OSD 第一行「选集」→ 按 →（或 OK）进右侧纵向列表 → 上下选 →
    // OK 换集。区别只在**列表行里多了网盘封面**（用户明确要求）。
    //
    // ⛔ 播放页原来**完全不碰媒体库**：它只拿到一个 `fid` 就去取链。所以
    //    「同一部作品还有哪些文件」这个信息必须由**列表页**带进来
    //    （`EXTRA_GROUP_KEY`），再用 [libDb] 查一次。网盘没有「查兄弟文件」
    //    的接口，靠文件名去猜同作品更是必错。

    /**
     * 媒体库句柄。**惰性打开**：只有从媒体库进来的（有 `EXTRA_GROUP_KEY`）
     * 才需要它，「直接给 URL」的对照路径连库文件都不碰。
     */
    private var libDb: LibraryDb? = null

    /** 同一部作品下的全部条目（已按「季 → 部 → 集 → 名称」排序）。 */
    private var siblings: List<LibraryItem> = emptyList()

    /** 当前正在播的那一条在 [siblings] 里的下标；`-1` = 不在里面。 */
    private var episodeIndex = -1

    /**
     * 最近一次请求选集时用的 `group_key` / `fid`（空 = 这部片没有作品归属）。
     *
     * ⛔ 留着它们是为了**重试**：读库失败（`database is locked`）是瞬时的，
     *    而一次失败会让「选集」整行在本会话里永久消失 —— 打开菜单时正是
     *    再试一次的最好时机（见 [showOsd]）。
     */
    private var siblingsGroupKey = ""
    private var siblingsFid = ""

    /** 选集那次读库**成功过**没有。`false` + 有 groupKey ⇒ 值得重试。 */
    private var siblingsLoaded = false

    /** 读库请求序号：只有最新一次的回调才认，防止旧结果盖掉新的。 */
    private var siblingsSeq = 0

    /** 选集列表里那些网盘封面的取用（内存 + 落盘 + 失败标记）。 */
    private var episodeThumbs: EpisodeThumbs? = null

    // ── 片头 / 片尾的自动学习（schema v18）────────────────────────────
    //
    // 需求原文：「每次都要点进度条跳过片头、到片尾时手动跳到下一集，但没有
    // 所有剧集的片头片尾时间点」。
    //
    // 规则本体全在 `SkipLearning` / `IntroSession`（纯函数 + 状态机，有单测），
    // 这一页只做三件事：**喂位置**、**按回答去 seek**、**把样本报回库**。
    //
    // ⛔ 采集在**这里**、聚合在 `LibraryDb` 那一侧：判断「拖过去之后有没有
    //    停下来看」必须贴着播放头，而聚合要读这部作品的**全部**样本。

    /**
     * 当前作品的 key（`media_works.key`）。空 = 没有库记录
     * （「直接给 URL」的对照路径），那时**一律不学习** —— 样本挂不到任何
     * 一行上，攒了也永远不会被聚合。
     */
    private var workKey = ""

    /** 片头跳过状态机。一个实例对应**一条流**（换集要 reset）。 */
    private val introSession = IntroSession()

    /** 有效落点采集器。与 [introSession] 同一生命周期。 */
    private val anchorCollector = SkipAnchorCollector()

    /** 学习出来的**片尾起点距末尾的偏移**（毫秒）。`null` = 没学过。 */
    private var learnedOutroOffsetMs: Long? = null

    /**
     * **手标**的片尾起点距末尾的偏移（毫秒，`media_works.outro_offset_ms`，
     * schema v19）。`null` = 没标过。
     *
     * ⛔ 电视上**没有界面可写**（用户在电脑上标，随进度文件 / 备份包同步过来），
     *    但播放器**必须读** —— 不读就是「电脑上标了片尾，电视上不跳」，而两端
     *    都不报错。取值链 **手标 > 学习**，判据只有一份实现（`OutroSkip`）。
     */
    private var manualOutroOffsetMs: Long? = null

    /** 这一条流里片尾已经处理过了（上升沿用 —— 提示 / 跳转都不幂等）。 */
    private var outroHandled = false

    /**
     * 「自动连播」开关（`auto_play_next`，与 PC 端同一个键）。
     *
     * ⛔ 缺省**开**，判据是 `!= "false"` —— 与 PC 端
     *    `player_page.dart` 的 `values[SettingKeys.autoPlayNext] != 'false'`
     *    逐字同口径。写成 `== "true"` 的话，新装用户（这一列在库里根本不存在）
     *    永远读成「关」，而 PC 上它是开着的。
     *
     * 它决定「学到片尾之后是自动跳下一集，还是只提示」。
     */
    private var autoPlayNext = true

    /**
     * 这次换集是**我们按学习结论跳的**，不是用户点的。
     *
     * ⛔ 换集要跨 Activity 重建（见 [switchEpisode]），所以这个标记只能挂在
     *    实例上、由 [onNewIntent] 消费。少了它的后果是**自我实现**：采样点
     *    就是我们跳过去的那个位置，它会变成一条「用户在这儿不想看了」的正
     *    样本，把结论越喂越靠前 —— 而它看起来完全像「越学越准」。
     */
    private var switchFromOutro = false

    // ── 播放进度（续播点）──────────────────────────────────────────
    //
    // 需求：「每次打开剧集都从最近播放的那一集的最后播放记录继续播放」。
    //
    // 要成立需要**两头都通**：
    //   * 进来 —— [resumeAtMs]（列表页随起播意图带来）在起播时跳过去；
    //   * 出去 —— [reportProgress] 把看到哪儿了写回 `media_items`。
    // ⛔ 2026-10-06 之前**两头都断着**：播放页从不写进度、也从不读进度，
    //    于是续播点永远是「从 PC 端同步过来的那个值」—— 电视上看的进度
    //    一条都不会留下来。

    /** 起播要跳到的位置（毫秒）；`<= 0` = 从头播。 */
    private var resumeAtMs = 0L

    /** 上一次上报的位置（毫秒）。用来跳过「位置没变」的空写。 */
    private var lastReportedMs = -1L

    /**
     * 进度上报心跳。
     *
     * ⛔ 10 秒而不是每秒：写库是磁盘 I/O，而这部机器上的磁盘正被预取器
     *    以几 MiB/s 的强度在写。每秒一次等于给已经在抖的缓冲又加一份抖动。
     *    10 秒与 PC 端同口径，且「退出时补写」能把误差压到 0。
     */
    private val progressTick = object : Runnable {
        override fun run() {
            reportProgress(flushAtExit = false)
            ui.postDelayed(this, PROGRESS_TICK_MS)
        }
    }

    // ── 外挂字幕（网盘同目录）──────────────────────────────────────
    //
    // 需求：「1. 自动识别网盘当前目录中的字幕文件 2. 选择字幕文件」。
    // 实现方式见 [ExternalSubtitle] 的类注释 —— 关键是**不重建 media source**，
    // 所以换字幕不会让画面卡一下。

    /**
     * 同目录扫到的字幕文件（已把「像本片字幕」的排前面）。
     *
     * 空 = 没扫到，或压根没扫（「直接给 URL」的对照路径没有父目录）。
     */
    private var subtitleFiles: List<SubtitleFile> = emptyList()

    /** 已经加载生效的外挂字幕。`null` = 走内嵌 / 关闭那条路。 */
    private var externalSub: ExternalSubtitle? = null

    /** 正在下载解析的那一条的文件名（菜单里显示「加载中…」）。 */
    private var externalPending: String? = null

    /** 已经生效的那一条的文件名。 */
    private var externalActive: String? = null

    /**
     * 外挂字幕的**上屏心跳**。
     *
     * ⛔ 用 100ms 轮询，而不是「算出下一条 cue 的边界再排一次定时器」：
     *    后者更省 CPU，但只要有一处边界算漏（最典型的是 seek 之后没重排），
     *    字幕就会**永久卡在某一句上** —— 而这个成本是每秒 10 次主线程唤醒
     *    加一次二分查找，相对 4K 解码可以忽略。可靠性优先。
     * ⛔ [SubtitleOverlayView.setCues] 内部按内容指纹去重，所以字幕间隙里的
     *    空转 tick 不会引起任何重绘。
     */
    private val subtitleTick = object : Runnable {
        override fun run() {
            val sub = externalSub ?: return
            // 播放器还没建好（外挂字幕先一步加载完）时也要继续排 —— 建好之后
            // 这一拍自然就接上了。
            player?.let { subtitles.setCues(sub.cuesAt(it.currentPosition)) }
            ui.postDelayed(this, SUBTITLE_TICK_MS)
        }
    }

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

        episodeThumbs = EpisodeThumbs(
            dir = LibraryPaths.thumbDir(this),
            cacheBytes = THUMB_CACHE_BYTES,
        )
        osd = TvOsdView(this).apply {
            visibility = View.GONE
            onActivate = { row, chip -> onOsdActivate(row, chip) }
            onClose = { hideOsd() }
            // ⛔ 封面由播放页在**后台线程**取，OSD 只负责问。OSD 自己一旦
            //    碰网络或磁盘，「按键→上屏」那几毫秒的预算立刻就没了。
            thumbs = object : TvOsdView.ThumbSource {
                override fun cached(url: String) = episodeThumbs?.cached(url)

                override fun isKnownBad(url: String) = episodeThumbs?.isKnownBad(url) ?: true

                override fun fetch(url: String, targetPx: Int, onReady: () -> Unit) {
                    val store = episodeThumbs ?: return
                    // ⛔ 按**地址归属**选厂家，不是按当前片：选集列表里可能混着
                    //    另一家的文件（同一个作品被两家各扫到一次），拿这一家的
                    //    Cookie 去下那一家的缩略图，裸链一律 401 ⇒ 那块永远是灰的。
                    val client = clientFor(url)
                    Bg.run({ store.load(url, client, targetPx) }) { _, _ ->
                        // 失败也回调：`load` 已经把地址记进「拿不到」，
                        // 重画一次列表它就不会再问了（否则每次 getView 都重试）。
                        onReady()
                    }
                }
            }
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
        // ⛔ 与换集（[onNewIntent]）**同一条路**，别在这里另写一份。
        startFromIntent(intent)
    }

    // ------------------------------------------------------------------
    // 取链
    // ------------------------------------------------------------------

    private fun resolveAndPlay(fid: String) {
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty()
        showNotice("正在取链…\n$name")
        // ⛔ 厂家由**意图**带进来（列表页知道它是从哪家扫出来的）。缺省夸克：
        //    老路径（文件列表）没有这个 extra。
        provider = intent.getStringExtra(EXTRA_PROVIDER)
            ?.takeIf { it.isNotEmpty() }
            ?: DriveProviders.QUARK
        api = DriveClients.create(provider, store)
        // ⛔ 记下来源 fid —— 它是**稳定缓存键**的前半段（见 [stableCacheKey]）。
        //    不记的话就只能退回按 URL 做键，磁盘缓存永远跨不了会话。
        currentFid = fid
        // 百度需要**路径**才能走 `/api/filemetas` / 转码档；列表页已经把
        // 「dirPath + name」拼好带过来了（省一次 fs_id → path 翻译，也绕开
        // xpan 的账号风控）。夸克忽略这个参数。
        val pathHint = intent.getStringExtra(EXTRA_PATH)?.takeIf { it.isNotEmpty() }
        Bg.run({ api!!.resolve(fid, pathHint) }) { pi, err ->
            if (err != null) {
                Log.e(TAG, "取链失败", err)
                if (isMissingFile(err)) {
                    // 文件**已经不在网盘上** ⇒ 留一张回执，媒体库页回来时问用户。
                    //
                    // ⛔ 只留「哪个 fid 没了」，**不问话**：电视上的问话必须发生在
                    //    用户回到媒体库、眼前就是这部剧的文件列表的时候 —— 在播放页
                    //    弹一个「要不要移除」，用户根本看不见「还剩几集」，只能盲选。
                    //    PC 端那个弹窗之所以在播放页上，是因为它还有独立的播放窗口；
                    //    电视端退回列表就是全部上下文（见 `MissingMediaPlan` 类文档）。
                    //
                    // ⛔ 走进程内的槽位（`MissingReceipts`）而**不是** `setResult`：
                    //    这一页是 `singleTask`，结果协议不保证把 intent 带回来 ——
                    //    见 `MissingReceipt` 的类文档。
                    MissingReceipts.put(
                        MissingReceipt(
                            fid = fid,
                            provider = provider,
                            name = intent.getStringExtra(EXTRA_NAME).orEmpty(),
                            groupKey = intent.getStringExtra(EXTRA_GROUP_KEY)?.trim().orEmpty(),
                        ),
                    )
                    showNotice("这个文件已经不在网盘上了\n${err.message}\n按返回键，媒体库会问你要不要移除它")
                } else {
                    showNotice("取链失败\n${err.message}")
                }
                return@run
            }
            // 取到了 ⇒ 撤掉上一次失败留下的回执：换集时前一集可能已经报过
            // 「文件没了」，不撤的话用户会回到媒体库、被问一个**已经能播的**
            // 文件要不要移除。
            MissingReceipts.clear()
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

            // 同目录字幕的**自动识别**。放在这里（取链成功之后）而不是
            // `onCreate` 里，是为了不与 `resolve` 抢同一份 Cookie ——
            // `PanApi.absorbCookies` 是「读改写」，两条并发请求会丢一次
            // `__puus` 轮换。这里与下面的测速并行，不占起播的关键路径。
            subtitleDirRef()?.let { discoverSubtitles(it) }
        }
    }

    /**
     * 这次取链失败是不是「文件已经不在网盘上」。
     *
     * ## ⛔ 只认 [DriveException.notFound]
     *
     * 取链失败有很多种，而它们的后果完全不同：
     *
     *   * `needsReauth` / 网络 / 限流 → 文件**还在**，只是这次没取到。
     *     拿这种失败去问用户「要不要移除这一条」，他一点确认，一条好好的
     *     索引就没了，而原因只是刚才断了一下网；
     *   * 直链 4xx（签名过期 / 换 IP）→ 说明的是**这条 URL** 失效，
     *     重新取一次链就好，与文件在不在是两回事。
     *
     * 所以判据与 PC 端 `missing_media.dart` 的 `isMissingFileError` 逐字一致：
     * 服务端**明确说没有这个 fid**，才允许把「它可能已经被删了」这个推断
     * 摆到用户面前。
     */
    private fun isMissingFile(err: Throwable): Boolean =
        err is DriveException && err.notFound

    // ------------------------------------------------------------------
    // 选集
    // ------------------------------------------------------------------

    /**
     * 把同一部作品下的全部条目读进来（为了「选集」那一行）。
     * ⛔ **必须在后台线程查**：一部剧能有两百多条，主线程查库就是一次可见的卡顿
     *    —— 而且它发生在 `onCreate`，卡的是「起播前那段黑屏」。
     * ⛔ 读不到库（没同步过 / 文件坏了）时**静默降级**：选集行不出现，
     *    播放本身完全不受影响。这条路径不该因为「库没了」而播不了片。
     *
     * ## ⛔⛔ 为什么必须**重试**
     *
     * 真机现场（2026-10-24，MiTV-MFTP0）：点进播放的那一刻，媒体库页正在写
     * `last_played_at`（`LibraryActivity.play()` 里的 `markPlayed`），两个句柄
     * 撞在同一个 `journal_mode=DELETE` 的库上，播放页这边 `LibraryDb.open()`
     * 当场抛 `SQLITE_BUSY`（`database is locked`）。
     *
     * 那时的老代码**一次失败就永久放弃** —— 于是「选集」整行在这个会话里再也
     * 不出现，用户看到的是「同一个剧集，有时有选集、有时没有；重启后第一次
     * 总是好的」。锁是**瞬时**的（另一边的写事务毫秒级结束），所以：
     *
     *   1. 这里退避重试几次（[SIBLINGS_RETRIES]）；
     *   2. 仍然失败的话，[showOsd] 打开菜单时还会再试 —— 那是用户的真实动作，
     *      比任何定时器都靠谱。
     */
    private fun loadSiblings(groupKey: String, fid: String) {
        siblingsGroupKey = groupKey
        siblingsFid = fid
        if (groupKey.isEmpty()) {
            // ⛔ 这条**要留日志**：以前是静默 return，真机上根本分不清
            //    「没有 group_key」和「查到了 0 条」。
            Log.i(TAG, "选集：这条没有 group_key（不是从媒体库进来的？），选集行不可用")
            return
        }
        val seq = ++siblingsSeq
        loadSiblingsAttempt(groupKey, fid, seq, attempt = 0)
    }

    /** [loadSiblings] 的一次尝试；失败按 [SIBLINGS_RETRY_DELAY_MS] 线性退避重试。 */
    private fun loadSiblingsAttempt(groupKey: String, fid: String, seq: Int, attempt: Int) {
        Bg.run({ ensureLib().itemsForWork(groupKey) }) { list, err ->
            // 期间又发起过一次读库（换集 / 重试）⇒ 这次的结果已经过期。
            if (seq != siblingsSeq) return@run
            if (err != null) {
                if (attempt < SIBLINGS_RETRIES) {
                    Log.w(
                        TAG,
                        "读选集失败（groupKey=$groupKey，第 ${attempt + 1} 次），" +
                            "${SIBLINGS_RETRY_DELAY_MS * (attempt + 1)}ms 后重试",
                        err,
                    )
                    ui.postDelayed(
                        {
                            if (seq == siblingsSeq) {
                                loadSiblingsAttempt(groupKey, fid, seq, attempt + 1)
                            }
                        },
                        SIBLINGS_RETRY_DELAY_MS * (attempt + 1),
                    )
                    return@run
                }
                Log.w(
                    TAG,
                    "读选集失败（groupKey=$groupKey，已重试 $SIBLINGS_RETRIES 次），" +
                        "选集行暂不可用（打开菜单会再试一次）",
                    err,
                )
                return@run
            }
            siblingsLoaded = true
            val items = list.orEmpty()
            siblings = items
            episodeIndex = items.indexOfFirst { it.fileId == fid }
            Log.i(
                TAG,
                "选集：$groupKey 共 ${items.size} 条，当前下标 $episodeIndex" +
                    if (episodeIndex < 0) "（当前文件不在这个作品里）" else "",
            )
            // ⛔ 只有**真的能选**（两条以上）才重绑：一条时选集行不会出现，
            //    重绑只会白白把用户的菜单光标重置回第一行。
            if (items.size > 1) rebindOsd()
        }
    }

    /**
     * 换到同一作品下的另一条。
     *
     * ## ⛔ 为什么**不能** `startActivity` 之后 `finish()`
     *
     * `AndroidManifest.xml` 里这一页是 `android:launchMode="singleTask"` ——
     * 全工程**只允许存在一个播放页**（这是有意的：两个播放器会抢同一把
     * 磁盘缓存锁）。而 singleTask 下再 `startActivity(PlayerActivity)`，
     * 系统**不会**新建实例，只把 Intent 送回当前这个实例的 [onNewIntent]。
     * 于是「起新页 + finish 旧页」会变成「什么都没做 + 把自己关掉」
     * —— 真机表现正是用户报的那句：**换集之后播放器直接退出**。
     *
     * 所以这里只 `startActivity`，由 [onNewIntent] 接住并把旧的那条流整个换掉。
     *
     * ## 为什么复用同一个实例、而不是就地换 media source
     *
     * 就地换（像 [playQuality] 那样 `setMediaItem`）看着更省事，但**换集和换档
     * 不是一回事**：换档是同一份字节的不同码率，而换集是**另一个文件** ——
     * 外挂字幕要重新扫目录、轨道选择要整套丢掉、续播点要换成新那一集的、
     * 连缓存键的 fid 都变了。这些事 [startFromIntent] 那条路径**已经全都做对了**，
     * 就地换等于把它们再抄一遍，抄漏一条就是「换集后字幕还是上一集的」。
     *
     * 附带的好处：没有 Activity 切换，也就没有那 0.3~0.8 秒的黑场。
     * 而**测速**那 3 秒不能忍 —— 同一条 WiFi、同一个 CDN，刚量过的带宽没必要
     * 每集重量一遍，所以把上一次的实测值随 intent 带过去
     * （见 [EXTRA_REUSE_BANDWIDTH] 与 [probeThenPlay]）。
     *
     * @param fromOutro `true` = 这次换集是**我们按学习结论跳的**，不是用户点的。
     *   ⛔ 它只影响一件事：`onNewIntent` 里那次「片尾信号」要不要发（见
     *   [switchFromOutro]）。漏了它的后果是**自我实现** —— 采样点就是我们
     *   跳过去的那个位置，它会被记成「用户在这儿不想看了」，把结论越喂越靠前，
     *   而整个过程看起来完全像「越学越准」。
     */
    private fun switchEpisode(index: Int, fromOutro: Boolean = false) {
        val item = siblings.getOrNull(index) ?: return
        if (item.fileId == currentFid) {
            Log.i(TAG, "选集：选中的就是正在播的那一条（${item.name}），不重开")
            hideOsd()
            return
        }
        Log.i(
            TAG,
            "选集 → 第 ${index + 1}/${siblings.size} 条：${item.name}" +
                (EpisodeLabels.progressLabel(item)?.let { "（历史进度 $it）" } ?: ""),
        )
        // ⛔ 标记必须在 `startActivity` **之前**挂上：singleTask 下它是**同步**
        //    走到 [onNewIntent] 的（见下面的注释），之后再设已经晚了。
        if (fromOutro) switchFromOutro = true
        // 先收菜单：singleTask 下 `startActivity` 会**同步**走到 [onNewIntent]，
        //    那边接手之后这一页的 OSD 数据就已经是上一个文件的了。
        hideOsd()
        startActivity(
            Intent(this, PlayerActivity::class.java)
                .putExtra(EXTRA_FID, item.fileId)
                .putExtra(EXTRA_NAME, item.name)
                .putExtra(EXTRA_HEADERS, intent.getStringExtra(EXTRA_HEADERS))
                .putExtra(EXTRA_PDIR, item.dirId)
                // ⛔ 厂家与路径**逐条跟着库里的那一行走**，不沿用当前这集的：
                //    同一个作品下完全可能混着两家的文件（跨端同步 / 用户自己
                //    分开放），沿用旧值就会拿夸克的 Cookie 去开百度的文件。
                .putExtra(EXTRA_PROVIDER, item.provider)
                .putExtra(EXTRA_PATH, fullPathOf(item.dirPath, item.name))
                .putExtra(EXTRA_PDIR_PATH, dirPathOf(item.dirPath))
                .putExtra(EXTRA_GROUP_KEY, item.groupKey)
                // ⛔ 换过去那一集**自己的**续播点：列表里可能好几集都看过，
                //    切到第 5 集就该从第 5 集上次停的地方开始，不是 0，
                //    更不是上一集留下的位置。
                .putExtra(EXTRA_RESUME_MS, item.resumePositionMs ?: 0L)
                // 已经量过的带宽 —— 别让用户每换一集等 3 秒测速。
                .putExtra(EXTRA_REUSE_BANDWIDTH, measuredMbPerSec),
        )
        // ⛔ **不要 `finish()`**：这一页是 singleTask，`finish()` 会把整个
        //    播放页关掉（新 Intent 只会回到自己身上）—— 见上面的类注释。
    }

    /**
     * singleTask 下**换集**（以及 adb 再次 `am start`）会走到这里，而不是
     * [onCreate] —— 见 [switchEpisode] 的类注释。
     *
     * ⛔ 必须先 `setIntent(intent)`：`resolveAndPlay` 读的是 Activity 的
     *    `intent` 字段（`EXTRA_NAME` / `EXTRA_PDIR`），不换掉的话它拿到的
     *    还是**上一集**的名字与父目录 —— 表现为「换集成功，但字幕扫的是
     *    上一集那个目录」。
     *
     * ⛔ 换之前必须把**上一个文件的全部残留**清干净：轨道 override、外挂
     *    字幕、已扫到的字幕文件、缓存键… 漏掉一条就是「换集后字幕/音轨
     *    还是上一集的」。
     *
     * ⛔ 这里也是**片尾信号**的唯一入口之一（另一个是 [onDestroy]）：换集
     *    ＝「这一集不看了」的终态，比任何 seek 都清楚。顺序必须是
     *    「先补写进度 → 再发片尾信号 → 最后清状态」，因为两者都要读
     *    `player.currentPosition`，而再往下走就要 `release()` 了。
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        val previous = currentFid
        Log.i(TAG, "换集：复用当前播放页（旧 fid=$previous）")

        // ⛔ 上一集的位置**必须先存下来**：换集到这里时，`player` 还活着，
        //    再往下走就要 release 了 —— 之后 `currentPosition` 就没了。
        reportProgress(flushAtExit = true)
        lastReportedMs = -1L

        // ── 片尾信号（必须还在 `player` 活着、且状态没清的时候发）─────
        // ⛔ 自动跳片尾引起的换集**绝不记样本** —— 否则采样点就是我们自己
        //    跳过去的那个位置（见 [switchFromOutro] 的文档）。
        //    这个标记用完即复位，不能跨到下一次换集。
        if (switchFromOutro) {
            switchFromOutro = false
            Log.i(TAG, "这次换集是跳过片尾引起的，不记片尾样本")
        } else {
            reportEpisodeSwitchAnchor()
        }

        // ── 清掉上一集的一切 ──────────────────────────────────────
        ui.removeCallbacks(progressTick)
        prefetcher?.cancel()
        prefetcher = null
        stopExternalSubtitle()
        externalSub = null
        externalActive = null
        externalPending = null
        subtitleFiles = emptyList()
        tracks = null
        pendingTracks = null
        info = null
        current = null
        currentFid = ""
        currentQualityId = ""
        currentIsPlaylist = false
        siblings = emptyList()
        episodeIndex = -1
        // ⛔ 换了集 = 选集这份数据作废；不置回 false 的话，下一次读库失败后
        //    [showOsd] 就不会再补试（它会以为上一份是好的）。
        siblingsLoaded = false
        firstFrameRendered = false
        player?.release()
        player = null
        // 倍速**故意保留**：那是观看习惯，不是「上一个文件的属性」。
        // 控制栏留在屏幕上，新一集起播时 `showControls()` 会自己更新。
        hideOsd()

        startFromIntent(intent)
    }

    /**
     * 按当前 `intent` 起播 —— [onCreate] 与 [onNewIntent] **共用这一条路**。
     *
     * ⛔ 不能两边各写一份 `when { fid -> … spec -> … }`：换集走过的那条分支
     *    会比首次启动少做一两件事（历史上正是这么漏掉外挂字幕的），而这种
     *    「首次正常、换集后不对」的 bug 极难复现 —— 用户只会觉得它时好时坏。
     */
    private fun startFromIntent(intent: Intent) {
        val fid = intent.getStringExtra(EXTRA_FID)?.trim().orEmpty()
        spec = StreamSpec.fromIntent(intent)
        resumeAtMs = intent.getLongExtra(EXTRA_RESUME_MS, 0L)
        val groupKey = intent.getStringExtra(EXTRA_GROUP_KEY)?.trim().orEmpty()
        loadSiblings(groupKey, fid)
        // 片头 / 片尾的配置与学习结论（异步读库，见 [loadSkipConfig]）。
        loadSkipConfig(groupKey)
        // 落点采集器归零，并把**起播位置**记下来。⛔ 用 `resumeAtMs` 而不是
        // 位置流第一个值：续播（从上次位置继续）时「0 → 落点」这个区间根本
        // 不成立 —— 用户没看过那段，也就谈不上「跳过片头」。
        anchorCollector.reset()
        anchorCollector.notePlayStart(resumeAtMs)
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
    // 播放进度（写回媒体库）
    // ------------------------------------------------------------------

    /**
     * 把「看到哪儿了」写回媒体库。
     *
     * ## 写三样东西，三样各有各的用处
     *
     * | 列 | 用处 | 判据 |
     * |---|---|---|
     * | `last_played_at`（item + work） | 「最近播放」的排序依据 | 每次播过就写 |
     * | `max_position_ms` | 列表里那条细进度条（`看过没有 / 看到哪儿了`） | **只增不减**、永不清除 |
     * | `resume_position_ms` | 「下次从哪儿接着播」 | 会变、也会被**清掉** |
     *
     * ⛔ `max` 与 `resume` **必须分开**：看完的一集 `resume` 要清成 NULL、
     *    而 `max` 必须保留 —— 用续播点画进度条的话，看完的一集会显示成 0%。
     *
     * ## ⛔ 为什么看完要**清掉**续播点
     *
     * 留着的话，下次打开会从「还差一分钟」开始，看两秒就出字幕 —— 用户只会
     * 以为这一集坏了。判据见 [PlaybackResume.isFinished]。
     *
     * ## ⛔ 为什么落库失败不能打断播放
     *
     * 落库失败只记日志。它是「下次能不能续」的问题，不是「现在能不能看」的问题，
     * 弹个 toast 把正在看的画面打断是最坏的取舍。但不能**静默** —— 否则
     * 「续播位置丢了」会变成一个无从查起的问题。
     *
     * @param flushAtExit true = 退出前的最后一次（跳过「位置没变」的优化）。
     */
    private fun reportProgress(flushAtExit: Boolean) {
        val p = player ?: return
        val fid = currentFid
        // 「直接给 URL」的对照路径没有 fid，也就没有库里的那一行 —— 写不进去。
        if (fid.isEmpty()) return
        val positionMs = p.currentPosition
        if (positionMs <= 0L) return
        if (!flushAtExit && positionMs == lastReportedMs) return
        lastReportedMs = positionMs

        val totalMs = p.duration.takeIf { it > 0 } ?: 0L
        val itemId = ScanItem.idOf("quark", fid)
        val keep = PlaybackResume.worthKeeping(positionMs, totalMs)
        Bg.run({
            val db = ensureLib()
            db.markPlayed(itemId)
            if (totalMs > 0L) db.saveMaxPosition(itemId, positionMs)
            // ⛔ 看完 / 不足 5 秒 ⇒ 传 `null`，由 `saveResumePosition` 写成 NULL。
            db.saveResumePosition(itemId, if (keep) positionMs else null)
            Triple(itemId, positionMs, keep)
        }) { r, err ->
            if (err != null) {
                Log.w(TAG, "进度落库失败（不影响播放）：${err.message}")
                return@run
            }
            if (r == null) return@run
            Log.i(
                TAG,
                "进度：${r.first} @ ${r.second / 1000}s / ${totalMs / 1000}s" +
                    if (r.third) "" else "（已看完或太短 ⇒ 清掉续播点）",
            )
        }
    }

    // ------------------------------------------------------------------
    // 片头 / 片尾的自动学习（schema v18）
    // ------------------------------------------------------------------
    //
    // 规则本体在 `SkipLearning` / `IntroSession` / `SkipAnchorCollector`
    // （全是纯函数 + 一个状态机，有单测）。这一页只做三件事：
    //
    //   1. [tickSkipLearning] —— 每秒把播放头喂给状态机与采集器；
    //   2. 按状态机的回答去 seek（**不算用户 seek**）；
    //   3. [reportSkipAnchor] —— 把确认出的样本交给 `LibraryDb` 聚合。

    /**
     * 每秒一次：片头跳过 + 片尾提示 + 落点采集。
     *
     * ## ⛔ 为什么挂在 1 秒的 [playheadTick] 而不是 10 秒的 [progressTick]
     *
     * 跳过片头要「刚进区间就跳」。10 秒的粒度意味着用户先看十秒片头再被跳走
     * —— 那还不如不跳。而落点采集的「停留 15 秒」判据也需要秒级的位置采样。
     *
     * ## ⛔ 为什么这里没有 `try/catch`
     *
     * 全是纯计算 + 一次 `seekTo`，没有 IO。真正会失败的那部分（写库）在
     * [reportSkipAnchor] 的后台任务里，那条路自己 catch。
     */
    private fun tickSkipLearning(p: Player) {
        val positionMs = p.currentPosition
        if (positionMs <= 0L) return

        // 片长未知时位置不可信（还在解容器），此刻算出来的偏移没有意义。
        val d = p.duration
        val totalMs = if (d == C.TIME_UNSET || d <= 0L) 0L else d

        // ① 片头：进了区间就跳。
        // ⛔ `user = false` —— 这一跳是**我们自己**发起的。记成用户 seek 的话，
        //    「跳过片头」会变成一条片头样本，而它恰恰是学习结论自己造出来的，
        //    会把结论越喂越靠后。
        introSession.takeSkipTarget(positionMs)?.let { target ->
            Log.i(TAG, "跳过片头：${positionMs / 1000}s → ${target / 1000}s")
            showNotice("已跳过片头")
            seekToPosition(target, "跳片头", user = false)
        }

        // ② 片头锚点：只有「拖过去之后停下来看了」才确认。
        if (totalMs > 0L) {
            anchorCollector.notePosition(positionMs)?.let { reportSkipAnchor(it) }
        }

        // ③ 片尾：提示 / 自动跳下一集。
        maybeHandleOutro(positionMs, totalMs)
    }

    /**
     * 播放头进入**片尾区间**（取值链 手标 > 学习）。
     *
     * ## ⛔ 默认只提示，开着「自动连播」才真的跳
     *
     * 片尾的信号天生比片头弱：片头有「起点 = 0」这个强锚，片尾没有 ——
     * 「跳过片尾」与「快进去看结局」在信号上长得一模一样。误跳的代价是用户
     * **直接丢掉结局**，不可逆。
     *
     * 而开着自动连播说明用户已经明确要过「这一集看完就接下一集」—— 片尾只是
     * 把这件事提前到他不想看的地方。判据与 PC 端 `player_page.dart` 的
     * `_onOutroReached` 逐字同形。
     */
    private fun maybeHandleOutro(positionMs: Long, totalMs: Long) {
        if (outroHandled) return
        // 取值链 **手标 > 学习**（判据只有一份实现：`OutroSkip`，与片头那条链
        // 同形）。⛔ 手标那一列唯一的来源是 PC 端 —— 不读就是「电脑上标了片尾，
        // 电视上不跳」，而两端都不报错。
        val offset = OutroSkip.effectiveOffsetMs(manualOutroOffsetMs, learnedOutroOffsetMs)
            ?: return
        val start = OutroSkip.startMs(totalMs, offset) ?: return
        if (positionMs < start) return

        outroHandled = true
        Log.i(TAG, "到达片尾：${positionMs / 1000}s（片尾从 ${start / 1000}s 起）")

        if (!autoPlayNext) {
            showNotice("已到片尾")
            return
        }
        val next = nextEpisodeIndex()
        if (next < 0) {
            // 不是错误：最后一集播到片尾就该停（循环重播会让睡着的用户被整夜播放）。
            showNotice("已到片尾（已是最后一集）")
            return
        }
        showNotice("已跳过片尾 · 播放下一集")
        // ⛔ `fromOutro = true`：这次换集是**我们自己**跳的，不能记成样本
        //    （见 [switchFromOutro] 的文档）。
        switchEpisode(next, fromOutro = true)
    }

    /**
     * 下一集的下标；没有下一集时 `-1`。
     *
     * 规则与 PC 端 `EpisodeQueue.nextAfter` 的三条一致：**当前项不在列表里
     * 不从头开始**（`episodeIndex < 0` 直接返回 -1）、**跳过花絮**、
     * **到尾不循环**。
     */
    private fun nextEpisodeIndex(): Int {
        if (episodeIndex < 0) return -1
        var i = episodeIndex + 1
        while (i < siblings.size && siblings[i].isSampleOrExtra) i++
        return if (i < siblings.size) i else -1
    }

    /**
     * 发一次**片尾信号**：用户切到了下一集，或直接退出了播放。
     *
     * ## 为什么片尾只有这一个信号
     *
     * 判据的完整推导在 [SkipAnchorCollector.noteEpisodeSwitch] 上，这里只强调
     * 一点：它传的是**切集那一刻**的播放头位置，不是「用户之前拖到哪儿」。
     * 用户看剧情看到第 43 分钟、按下一集，那 43:00 才是「不想看的那一段」的
     * 起点；传拖拽落点会把中间看过的内容也算进片尾。
     *
     * ## ⛔ 调用时机
     *
     * 必须在 `player.release()` **之前**（之后 `currentPosition` 就没了），
     * 且必须在 `workKey` / `currentFid` 被清空**之前** —— 否则样本挂不到
     * 任何一行上（[reportSkipAnchor] 拿不到 `workKey` 会直接返回）。
     * 两处调用点（[onNewIntent] / [onDestroy]）都满足这两条。
     *
     * ## 为什么失败要静默
     *
     * 它是**纯计算**（采集器 + 分类），没有 IO；真正的写库在
     * [reportSkipAnchor] 的后台任务里，那条路自己 catch。这里不弹任何东西 ——
     * 用户正在换集/退出，弹个 toast 只会打断。
     */
    private fun reportEpisodeSwitchAnchor() {
        val p = player ?: return
        if (workKey.isEmpty()) return
        val d = p.duration
        val totalMs = if (d == C.TIME_UNSET || d <= 0L) 0L else d
        if (totalMs <= 0L) return
        val positionMs = p.currentPosition
        if (positionMs <= 0L) return

        anchorCollector.noteEpisodeSwitch(positionMs, totalMs)?.let { reportSkipAnchor(it) }
    }

    /**
     * 读这一部作品的「跳过片头 / 片尾」开关、**手标**与**学习结论**。
     *
     * ⛔ 必须在后台线程查（要开库）。查完之前 `introSession` 是空的 ——
     *    也就是「不跳」。这个先后顺序是**安全**的：宁可前几秒不跳，
     *    也不要拿上一部作品的区间去跳。
     */
    private fun loadSkipConfig(groupKey: String) {
        if (groupKey.isEmpty()) {
            // 「直接给 URL」的对照路径：没有库记录，不学习也不跳。
            workKey = ""
            introSession.reset(enabled = false)
            manualOutroOffsetMs = null
            learnedOutroOffsetMs = null
            outroHandled = false
            return
        }
        workKey = groupKey
        Bg.run({
            val db = ensureLib()
            val work = db.workByKey(groupKey)
            val skipIntro = db.getSetting(LibrarySchema.KEY_SKIP_INTRO) != "false"
            val autoNext = db.getSetting(LibrarySchema.KEY_AUTO_PLAY_NEXT) != "false"
            Triple(work, skipIntro, autoNext)
        }) { r, err ->
            if (err != null) {
                Log.w(TAG, "读跳过配置失败（groupKey=$groupKey），不跳片头片尾", err)
                return@run
            }
            if (r == null) return@run
            val (work, skipIntro, autoNext) = r
            // ⛔ 期间可能已经换集（`workKey` 被下一次 [loadSkipConfig] 改掉了）。
            //    晚到的结果打到新一集上，表现是「刚切过去画面自己跳一下」。
            if (workKey != groupKey) return@run

            autoPlayNext = autoNext
            // 片尾两组列分别读，取值链（手标 > 学习）在 `maybeHandleOutro` 里走
            // `OutroSkip` —— 与片头那条链同形，不在这里合成。
            manualOutroOffsetMs = work?.outroOffsetMs
            learnedOutroOffsetMs = work?.learnedOutroOffsetMs
            outroHandled = false
            // 手标优先于学习（取值链在 `IntroSession.marker` 里，只有一份实现）。
            // ⛔ 手标那一列 Android 端**没有界面可写**，但 PC 端标的会随备份过来，
            //    所以这里必须读 —— 不读的话「电脑上标好的片头，电视上不跳」。
            introSession.reset(
                manual = work?.let { IntroMarker.fromMilliseconds(it.introStartMs, it.introEndMs) },
                learned = work?.learnedIntroRange,
                enabled = skipIntro,
            )
            Log.i(
                TAG,
                "跳过配置：手标=${introSession.manualMarker} 学习=${introSession.learnedMarker} " +
                    "片尾偏移=${OutroSkip.effectiveOffsetMs(manualOutroOffsetMs, learnedOutroOffsetMs)?.let { "${it / 1000}s" } ?: "-"} " +
                    "(手标=${manualOutroOffsetMs ?: "-"} 学习=${learnedOutroOffsetMs ?: "-"}) " +
                    "跳片头=$skipIntro 自动连播=$autoNext",
            )
        }
    }

    /**
     * 把一条**有效落点**样本交给库，并在攒够之后重聚合一次。
     *
     * ## 为什么每次都**重聚合全部样本**
     *
     * 判据是中位数 + MAD：加一条样本既可能让原本不够的样本数跨过门槛，也可能
     * 让**已有结论失效**（散布被撑爆）。增量公式算不出这两件事，而样本是
     * 「每集最多两条」的极小数据量，全量重算的代价可以忽略。
     */
    private fun reportSkipAnchor(anchor: SkipAnchor) {
        val fid = currentFid
        val key = workKey
        if (fid.isEmpty() || key.isEmpty()) return

        // 采集器已经按窗口过滤过一遍，这里再判一次是为了拿到 `kind` ——
        // 判据只有一份实现（`SkipLearning.classify`）。
        val kind = SkipLearning.classify(anchor) ?: return
        val itemId = ScanItem.idOf("quark", fid)
        val nowMs = System.currentTimeMillis()
        val device = DeviceIdentity.id(this)

        Bg.run({
            val db = ensureLib()
            db.addSkipSample(
                SkipSample(
                    id = SkipSample.idFor(itemId, kind, nowMs),
                    itemId = itemId,
                    workKey = key,
                    kind = kind,
                    anchorMs = anchor.anchorMs,
                    durationMs = anchor.durationMs,
                    device = device,
                    createdAtMs = nowMs,
                ),
            )
            val samples = db.skipSamplesForWork(key)
            val outcome = SkipLearning.learn(samples)
            if (outcome.isEmpty) return@run null
            db.saveLearnedSkip(key, outcome)
            db.pruneSkipSamples(key)
            outcome
        }) { outcome, err ->
            if (err != null) {
                // 学习失败**不影响播放**，但必须留痕 —— 否则「怎么学不出来」
                // 会变成一个无从查起的问题。
                Log.w(TAG, "落点样本处理失败（不影响播放）：${err.message}")
                return@run
            }
            if (outcome == null) {
                Log.i(TAG, "落点已记录，但还没攒够可用的学习结论")
                return@run
            }
            Log.i(TAG, "学习结论已更新：$key → intro=${outcome.intro} outro=${outcome.outro}")
            // ⛔ 期间可能已经换集：晚到的结论打到新一集上，表现是「刚切过去
            //    画面自己跳一下」。与 [loadSkipConfig] 同一条竞态守卫。
            if (workKey != key) return@run
            // 「当场学会」：用户第一次拖到片尾切集，样本就够了，结论立刻写回。
            // 不同步进来的话这一集就再也不会提示 —— 用户会觉得「刚学会的东西
            // 没生效」，而那正是他第一次手动操作的那一集。
            introSession.setLearned(
                outcome.intro?.let { IntroMarker(0L, it.endMs) },
            )
            if (outcome.outro != null) {
                learnedOutroOffsetMs = outcome.outro.offsetMs
                outroHandled = false
            }
        }
    }

    /**
     * 惰性打开媒体库。**只能在后台线程调**（要开文件、可能建表）。
     *
     * ⛔ 与 [libDb] 的关系：这里是唯一的赋值处，而 [loadSiblings] 也走这里 ——
     *    两处各 new 一个 `LibraryDb` 的话，同一个文件会有两个句柄，
     *    在 `journal_mode=DELETE`（不用 WAL，见 `LibraryDb` 类注释）下更容易
     *    撞上 `database is locked`。
     */
    private fun ensureLib(): LibraryDb {
        libDb?.let { return it }
        // ⛔ 必须走 `LibraryDb.shared`（进程内唯一）：媒体库页此刻正持着同一个
        //    库在写 `last_played_at`，这里再 new 一个句柄就是**第二个连接**，
        //    在 `journal_mode=DELETE` 下会当场抛 `database is locked`，
        //    表现为「选集」整行消失（见 `LibraryDb.shared` 的类注释）。
        val db = LibraryDb.shared(
            LibraryPaths.dbFile(this),
            progress = ProgressStore.shared(LibraryPaths.progressFile(this)),
        )
        libDb = db
        return db
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
        // 换集时复用上一次的实测带宽 —— 同一条 WiFi、同一个 CDN，刚量过的数
        // 没必要每集重量一遍（那是每换一集白等 3 秒）。
        // ⛔ 只走**换集**这条路（[switchEpisode] 才会带这个 extra）。正常起播
        //    一律实测：换片、换网络之后旧值就不作数了，而「量一下再挑档」
        //    正是本工程不卡顿的全部理由，不能为了省 3 秒把它常态化掉。
        val reused = intent.getDoubleExtra(EXTRA_REUSE_BANDWIDTH, 0.0)
        if (reused > 0.0) {
            measuredMbPerSec = reused
            val pick = chooseQuality(pi)
            Log.i(
                TAG,
                "换集：复用上次实测 %.2f MB/s（跳过测速），选档 ${pick.id}" +
                    "（${pick.label}，需 %.2f MB/s）".format(reused, pick.requiredMbPerSec),
            )
            playQuality(pick)
            return
        }

        // ⛔ 探**原画**，不是「最高那档」。夸克那边两者恰好是同一条（原画分辨率
        //    最高、且排在最前），但百度的原画是 `/api/filemetas` 直链、**没有**
        //    `height`（0），而转码档带 `height=480` —— 按高度挑就会去探一条
        //    完全不同 CDN 的转码流，测出来的带宽与真正要播的那条无关。
        val probeTarget = pi.qualities.firstOrNull { it.isOriginal }
            ?: pi.qualities.maxByOrNull { it.height }
            ?: pi.qualities.first()
        // ⛔ 探的是**最高档**，所以头与连接数也必须取**最高档**那一份：
        //    百度的 `origin=dlna` 快通道与慢通道是两套签名/两套限速，
        //    拿慢通道的头去探快通道的链会得到 403，读数直接是 0。
        val conns = effectiveConnections(probeTarget)
        showNotice("正在测速…\n（按最高档 ${probeTarget.label}、$conns 条连接探 3 秒）")
        Bg.run({
            ParallelProbe.measure(
                url = probeTarget.url,
                // ⛔ 用 [headersForCdn] 而不是裸 cookie：它与播放**同一套判据**
                //    （缺 `__puus` 就不带 Cookie）。两处各写一份的话，
                //    很容易只改了一处，于是「播放正常、测速 412」或反过来。
                headers = headersForCdn(probeTarget),
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
     * 一组都扛不住就降一级。全都扛不住时取服务端默认档。
     *
     * ⛔ **成本未知 ≠ 免费**：`requiredMbPerSec == 0` 只表示「体积或时长缺一个」，
     *    不是「这一档不花带宽」。参与比较时会把它剔掉；一条能算的都没有时
     *    退回默认档。百度的转码档最容易缺体积，不这么写就会「总是挑 480P」。
     */
    private fun chooseQuality(pi: PlayInfo): Quality {
        if (measuredMbPerSec <= 0.0) return pi.defaultQuality ?: pi.qualities.first()
        val budget = measuredMbPerSec * 0.7
        val groups = pi.qualities.groupBy { it.height }.toSortedMap(compareByDescending { it })
        for (group in groups.values) {
            val best = group
                .filter { it.requiredMbPerSec > 0.0 }
                .minByOrNull { it.requiredMbPerSec } ?: continue
            if (best.requiredMbPerSec <= budget) return best
        }
        return pi.defaultQuality
            ?: pi.qualities.firstOrNull { it.isOriginal }
            ?: pi.qualities.first()
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

        // ⛔ **URL 的后缀决定 Media3 走哪条解封装路径**，而 `MediaItem.fromUri`
        //    只给 URI、不给 MIME ⇒ `DefaultMediaSourceFactory` 会按
        //    `Uri.getLastPathSegment()` 的后缀自己猜：
        //      `.m3u8` ⇒ HLS（按 TS/fMP4 分片解）· 其它 ⇒ Progressive（整文件解）。
        //    猜错的后果是**解封装器报「不是 TS」**，看起来像片源坏了，
        //    其实是「拿整文件当 HLS 分片」——所以这一行必须能看见。
        //
        // ⛔ 同时要把结果**记成档位级状态**：分片地址不带 `.m3u8`，
        //    缓存键必须靠这个标记才能和播放列表分开 —— 见 [cacheKeyFor]。
        val parsed = runCatching { Uri.parse(q.url) }.getOrNull()
        currentIsPlaylist = PlaylistUrl.isPlaylist(q.url)
        loggedSegmentUrl = false
        Log.i(
            TAG,
            "档位 URL：host=${parsed?.host} path 末段=${parsed?.lastPathSegment}" +
                if (currentIsPlaylist) " ⇒ HLS/DASH（磁盘缓存按**每个 URL**分键）" else "",
        )

        if (player == null) {
            startPlayer(q.url, headersForCdn(q))
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
     * 切换「音效」。
     *
     * ## ⛔ 为什么必须**重建播放器**，而不能像换档那样只 `setMediaItem`
     *
     * 音效是靠给 `AudioSink` 装一个 `ChannelMixingAudioProcessor` 实现的，而它的
     * **输出声道数在 `onConfigure()` 里就定死了**（`queueInput()` 虽然每块都重读
     * 矩阵，但输出缓冲区是按当时那个声道数分配的）。所以「透传 ↔ 下混」这种
     * **改声道数**的切换，光改矩阵不重建 sink 只会把 6 声道的字节写进 2 声道的
     * 缓冲区 —— 而 `AudioSink` 是 `DefaultRenderersFactory.buildAudioSink()` 在
     * **建播放器时**造出来的，media3 1.5.1 没有运行期换它的接口。
     *
     * 代价与「换档」同级：画面黑一下、从当前位置重新缓冲。位置、播放态、倍速，
     * 以及**用户选过的音轨与字幕**（按标签，见 [restorePendingTracks]）都会带过去。
     */
    private fun applyAudioEffect(effect: AudioEffect) {
        if (prefs.audioEffect == effect) {
            Log.i(TAG, "音效未变（${effect.label}），不重建播放器")
            return
        }
        // ⛔ **先落库再重建**：重建要一秒多，中途若进程被杀，至少不会出现
        //    「点了没生效、下次进来还是旧的」。
        prefs.audioEffect = effect

        val q = current
        val p = player
        if (q == null || p == null) {
            // 「直接给 URL」的对照路径（`-e url`）没有档位，重建不了 ——
            // 记下来，下次起播自然生效。⛔ 必须**明说**，别让用户以为切了没反应。
            Log.i(TAG, "音效 → ${effect.label}（当前没有档位，下次起播生效）")
            showNoticeBriefly("音效 → ${effect.label}\n下次起播生效")
            return
        }

        val resumeMs = p.currentPosition.coerceAtLeast(0L)
        val wasPlaying = p.playWhenReady
        // ⛔ 记住用户选过的音轨 / 字幕（按**标签**）。不记的话，切一次音效
        //    字幕就没了 —— 而用户根本不会把这两件事联系起来。
        val audioLabel = trackChoices(C.TRACK_TYPE_AUDIO, withOff = false)
            .firstOrNull { it.selected }?.label
        val textLabel = trackChoices(C.TRACK_TYPE_TEXT, withOff = true)
            .firstOrNull { it.selected }?.label
        pendingTracks = if (audioLabel != null || textLabel != null) {
            PendingTracks(audioLabel, textLabel)
        } else {
            null
        }

        Log.i(
            TAG,
            "音效 → ${effect.label}（${effect.detail}）：重建播放器" +
                "（AudioSink 只能在建播放器时换）· 进度 ${resumeMs / 1000}s 保留",
        )
        // ⛔ 先停预取器：它拿着 SimpleCache 在写盘，而 [startPlayer] 会重建它。
        //    `startDiskPrefetch` 里本来也会 cancel 旧的，这里显式先停是为了
        //    在「释放旧播放器」与「起新播放器」之间不留一个还在跑的写者。
        prefetcher?.cancel()
        prefetcher = null
        tracks = null
        p.release()
        player = null

        startPlayer(q.url, headersForCdn(q))
        if (resumeMs > 0) player?.seekTo(resumeMs)
        player?.setPlaybackSpeed(currentSpeed.toFloat())
        player?.playWhenReady = wasPlaying
        showNotice("正在切换音效：${effect.label}…")
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
     * ## ① 网盘适配器给了逐档方言 ⇒ 直接用
     *
     * 百度的直链与夸克**不是一套规矩**（见 `BaiduMapper.dlinkHeaders`）：
     *
     * - 第二跳是 `*.baidupcs.com`，它的 `sign` 是**按 User-Agent 签的** ⇒ 必须
     *   用 `User-Agent: netdisk`，换成浏览器 UA 立刻 `403 31362 sign error`；
     * - Cookie 必须带 `BDUSS`（不带也能下，但走的是**未登录限速**）。
     *
     * 这些差异由 `BaiduApi.resolve` 随 `Quality.headers` 一起带过来 ——
     * 播放页**不需要知道**哪家网盘有哪些规矩，也就不会出现「加了百度分支、
     * 忘了改测速那条路」这种半修。
     *
     * ## ② 夸克（以及 `-e url` 的对照路径）：实测规则
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
    private fun headersForCdn(q: Quality? = current): Map<String, String> {
        // ⛔ 逐档方言优先。空 map 才落到夸克那套 —— `PanApi` 从不填 `headers`。
        if (q != null && q.headers.isNotEmpty()) return q.headers
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
     * 实际可用的并行连接数。
     *
     * ⛔ 网盘适配器若给了**上限**（`Quality.maxConnections > 0`）就必须服从：
     *    百度**非 dlna** 直链是按账号限速的（实测 ~80 KB/s），多开连接不会变快，
     *    只会更容易触发风控；`dlna` 快通道也是单连接最稳。
     *    用户把 OSD 里的「连接数」调到 8 也不该突破它 —— 那条设置描述的是
     *    「夸克那种按连接限速的网盘」，不是「无视网盘规矩」。
     */
    private fun effectiveConnections(q: Quality? = current): Int {
        val pref = prefs.parallelConnections
        val cap = q?.maxConnections ?: 0
        return if (cap > 0) minOf(pref, cap) else pref
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
        // ⛔ 这条分支只服务**夸克**（百度的头由 `Quality.headers` 带过来，不会走到这里）。
        //    显式指名 quark 而不是用默认值：多网盘之后 `requestCookie()` 的默认值
        //    是「当前激活网盘」，用它就会在百度激活时把百度 Cookie 发给夸克 CDN。
        val cookie = store.requestCookie(DriveProviders.QUARK)
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
     * ⛔⛔ **但「起点 0」不能变成「从 0 一直往前爬」**（2026-10-11 评估发现）：
     *    [DiskPrefetcher] 只会**往前**挪锚点，而挪锚点（`reanchor`）**只在
     *    用户跳转**时被调。于是**续播**时 —— 本工程绝大多数起播都是续播 ——
     *    播放头在 31:20、预取器却在从字节 0 往下灌，要把用户**已经看过**的
     *    前 31 分钟全下完，才轮到播放头前方。
     *
     *    实测（模拟器，`01.mp4` 续播到 1880s）：
     *    ```
     *    17:45:05.327  续播：起播跳到 1880s（库里记的续播点）
     *    17:45:05.331  磁盘预取：已启动（键 quark:e631…:origin · 码率 0.24 MiB/s）
     *    17:45:06.328  … 磁盘 本片 0 B … 预取 第 0 块 · 领先 0 B
     *    ```
     *    `预取 第 0 块` = 还在下文件头那一块。根因是**顺序**：
     *    [startPlayer] 里 `exo.seekTo(startMs)`（续播点）发生在
     *    `startDiskPrefetch(...)` **之前**，那次 `onPositionDiscontinuity(SEEK)`
     *    打过来时 `prefetcher` 还是 null ⇒ `reanchor` 成了空操作。
     *
     * ★ **修法（2026-10-11 已落地）**：把「起点」和「首块」拆开 ——
     *    起点仍是 0，但**首块只下 [PrefetchPlan.HEAD_BYTES]**（够把
     *    `moov` / 索引落盘），首块一提交就跳到续播点。判据分别在
     *    [PrefetchPlan.chunkSpan] 与 [PrefetchPlan.jumpAfterHead]。
     *    ⇒ 这里要把续播点换算成字节传下去（[PrefetchPlan.resumeAnchorBytes]），
     *    而不是再补一次 `reanchor` —— 后者会在「首块下完之前」就跳，
     *    文件头反而永远落不了盘。
     *
     * ## 领先量为什么是「缓存上限的 70%」
     *
     * ⛔ 不能设成无上限：那会一口气把缓存灌满，而用户可能看 5 分钟就退出 ——
     * 白下、白写盘。70% 留出余量给 **LRU 的腾挪空间**。
     * ⛔ 别再写「留给播放器自己写的那部分（已播段）」（2026-10-11 更正）：
     *    **播放器根本不写缓存**（`setCacheWriteDataSinkFactory(null)`），
     *    唯一的写者就是这个预取器。
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

        // ⛔ **播放列表（HLS）不起预取器**：预取器的模型是「一条字节流，
        //    按播放头往前领跑」，而 HLS 是「一个播放列表 + N 个分片」——
        //    它只会把那个 100 多 KiB 的播放列表当正片下下来（实测写进缓存
        //    125 KiB），既没有意义，又**污染了缓存键**（见 [cacheKeyFor]）。
        //    HLS 的深缓冲交给播放器自己的内存缓冲（`maxBufferMs = 120s`）。
        if (PlaylistUrl.isPlaylist(url)) {
            Log.i(TAG, "磁盘预取：跳过（这是 HLS/DASH 播放列表，一个媒体对应多个 URL，按流预取不成立）")
            return
        }

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
        // ⛔ 续播点 → 字节位置：**必须用上面那个 `bytesPerSec`**（= 码率 ×
        //    1048576，字节/秒）。单位搞混会让锚点差 100 万倍，而现象只是
        //    「预取器跑到文件外面去了」，不报任何错。判据见
        //    [PrefetchPlan.resumeAnchorBytes]（`<= 0` / 码率未知 ⇒ 不跳）。
        val resumeAnchor = PrefetchPlan.resumeAnchorBytes(resumeAtMs, bytesPerSec)
        val p = DiskPrefetcher(
            cache = cache,
            dataSourceFactory = upstream,
            uri = uri,
            cacheKey = key,
            startPositionBytes = 0L,
            // ⛔ 首块（文件头）下完就跳到这里，别再灌用户已经看过的那一段 ——
            //    见 KDoc「为什么起点是 0」那一节。
            jumpAfterHeadBytes = resumeAnchor,
            totalBytes = -1L,
            maxLeadBytes = lead,
            // ⛔ 只读主线程写好的**快照**，绝不在这里碰 `player` ——
            //    见 [playheadBytesCache] 的注释（踩过一次，直接闪退）。
            playheadBytes = { playheadBytesCache },
        )
        prefetcher = p
        p.start()
        // ⛔ 先把文案**拼完整**再 `format`：早先写成 `Log.i(...)` 后面吊一个
        //    `.format(rate)`，那玩意儿贴在 `)` 上 ⇒ 语法错。判据：这里只出现
        //    一个 `Log.i(` 与一个配对的 `)`，`.format(rate)` 作用在**字符串**上。
        val jumpNote = if (resumeAnchor > 0L) {
            "跳到续播点 ${resumeAnchor / 1048576} MiB）"
        } else {
            "继续往前（无续播点））"
        }
        Log.i(
            TAG,
            (
                "磁盘预取：已启动（键 $key · 码率 %.2f MiB/s ⇒ 领先上限 ${lead / 1048576} MiB · " +
                    "首块 ${PrefetchPlan.HEAD_BYTES / 1048576} MiB 后$jumpNote"
                ).format(rate),
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
            // ⛔ 走 [effectiveConnections] 而不是直接读偏好：网盘给了上限就得服从
            //    （百度慢通道多连接 = 更快触发风控，且**总带宽不会变**）。
            connections = { effectiveConnections() },
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
            "数据源：多连接并行（${effectiveConnections()} 条 × " +
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

        // ⛔ 音效必须在**建播放器时**就交给 AudioSink（见 [AudioEffectRenderersFactory]）。
        //    media3 没有「运行期换 AudioSink / 换处理器链」的接口，所以
        //    [applyAudioEffect] 走的是**重建播放器**这条路，而不是改一个属性。
        val renderers = AudioEffectRenderersFactory(this, prefs.audioEffect)
        Log.i(TAG, "音效：${prefs.audioEffect.label}（${prefs.audioEffect.detail}）")
        val exo = ExoPlayer.Builder(this, renderers, mediaSourceFactory)
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
                // ⛔ 紧跟着日志、且在 `rebindOsd()` 之前：重建播放器后要把用户
                //    原来选的音轨 / 字幕按**标签**选回来，菜单才显示得对。
                restorePendingTracks()
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
                // ⛔ 外挂字幕生效时**让路**：那条路由 [subtitleTick] 驱动，
                //    两个来源一起写 `subtitles` 会互相覆盖，表现为字幕一闪一闪。
                if (externalSub != null) return
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
        // 外挂字幕可能**先一步**加载完（同目录扫得快，而取链+测速要几秒）——
        // 那时 `disableEmbeddedText()` 因为 `player == null` 空转了一次。
        // 这里补一刀：播放器一建好就把内嵌文字轨关掉。
        if (externalSub != null) disableEmbeddedText()
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
        // 续播点 ——「每次打开剧集都从最近播放的那一集的最后播放记录继续播放」。
        //
        // ⛔ 必须在 `prepare()` **之后**再 `seekTo`：之前这一列只存在于库里、
        //    从来没被用过，于是「同一个文件换了播放器就从头开始」。
        // ⛔ `resumeAtMs` 由**列表页**随意图带来（`PlayTarget.resolve` 已经挑好了
        //    该播哪一集），不是这里去猜 —— 播哪一集与从哪儿续，判据必须同一处。
        val startMs = resumeAtMs
        if (startMs > 0L) {
            exo.seekTo(startMs)
            // ⛔ 不要在这里 `showNotice`：下面紧接着就是「正在打开…」，
            //    两行相隔几毫秒，用户只看得见后面那句（还会以为跳续失败了）。
            //    续播这件事由**控制栏上跳动的进度条**自己说话 —— 它本来就
            //    会亮出来（见下面 `showControls()`）。
            Log.i(TAG, "续播：起播跳到 ${startMs / 1000}s（库里记的续播点）")
        }
        // ⛔ 进度心跳在建好播放器之后才起：之前没有 `currentPosition` 可报。
        // ⛔ 先 `removeCallbacks`：`startPlayer` 会被**重建播放器**那条路再调一次
        //    （换音效），不取消就会有两个心跳同时在跑 —— 写库频率翻倍，
        //    而且这种重复只有在「切过一次音效之后」才出现。
        ui.removeCallbacks(progressTick)
        ui.postDelayed(progressTick, PROGRESS_TICK_MS)
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
        // ⛔ 退出前**必须补写一次进度**，而且必须在 `player.release()` **之前**
        //    —— 释放之后 `currentPosition` 就没有了。
        //    没有这一笔的话：用户在第 12 分钟退出，而下一次定时上报（10 秒一次）
        //    最多是 10 秒前写的 ⇒ 每次退出都丢最多 10 秒。真正致命的是
        //    「看了两分钟就退出」这种情形：一次都没上报过，进度全丢。
        reportProgress(flushAtExit = true)
        // ── 片尾信号（退出播放 = 「这一集不看了」的另一个终态）────────
        // ⛔ 必须在 `player.release()` 之前：释放之后 `currentPosition` 就没了。
        // ⛔ 与 [onNewIntent] 同一条路（[reportEpisodeSwitchAnchor]），别在这里
        //    另写一份 —— 两份判据漂移的表现是「切集学得出来、退出学不出来」。
        // ⛔ `switchFromOutro` 在这里几乎总是 `false`：跳片尾引起的换集走的是
        //    [onNewIntent]（singleTask 复用实例，不 `finish()`），标记在那时
        //    就被消费掉了。留着这个判断是**防御**：万一哪天真加了 `finish()`，
        //    少了它就会把自动跳转的位置记成用户样本。
        if (switchFromOutro) {
            switchFromOutro = false
        } else {
            reportEpisodeSwitchAnchor()
        }
        ui.removeCallbacks(hideControls)
        ui.removeCallbacks(progressTick)
        // ⛔ 防抖里的跳转也要取消：player 释放后再跑会崩，而且此时跳转
        //    已经没有意义（用户都离开播放页了）。
        ui.removeCallbacks(seekCommit)
        pendingSeekMs = -1L
        // ⛔ 快照定时器也要停：它读 `player.currentPosition`，
        //    player 释放后再跑会崩。
        ui.removeCallbacks(playheadTick)
        // ⛔ 外挂字幕的心跳也要停：它读 `player.currentPosition`，
        //    player 释放后再跑会崩（与 playheadTick 同一个原因）。
        ui.removeCallbacks(subtitleTick)
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
        // ⛔ **故意不关** `libDb`：上面那次退出补写是**异步**的（Bg 线程），
        //    在这里 `close()` 会与它撞上 —— 表现为偶发的 `IllegalStateException:
        //    attempt to re-open an already-closed object`，而且只在「退出时正好
        //    赶上写库」这个窗口里出现。一个 SQLite 句柄比一次崩溃便宜得多，
        //    进程结束会自然回收。
        super.onDestroy()
    }

    // ------------------------------------------------------------------
    // 外挂字幕（网盘同目录）
    // ------------------------------------------------------------------

    /**
     * 「同目录」的标识：夸克用 `fid`，百度用**目录路径**。
     *
     * ⛔ 不能只给 `fid`：百度没有「fid → 父目录」的现成接口，播放页手里
     *    只有一个文件 `fs_id`，冷启动时路径缓存是空的，去翻译会撞 xpan
     *    的账号风控。所以列表页把**路径**一起带过来（`EXTRA_PDIR_PATH`）。
     */
    private fun subtitleDirRef(): String? {
        val dirPath = intent.getStringExtra(EXTRA_PDIR_PATH)?.trim().orEmpty()
        if (provider == DriveProviders.BAIDU) {
            return dirPath.takeIf { it.isNotEmpty() }
        }
        return intent.getStringExtra(EXTRA_PDIR)?.trim()?.takeIf { it.isNotEmpty() }
    }

    /**
     * 扫一遍本片所在的网盘目录，挑出能当字幕的文件。
     *
     * ⛔ 在**后台线程**做（[Bg]），主线程只收结果 —— 列目录是一次网络往返，
     *    放在主线程只会让起播那几秒更卡。
     * ⛔ 父目录标识 **只能由列表页带过来**：单个 `fid` 推不出它的父目录，
     *    而网盘没有「查父目录」的接口（见 `BrowseActivity` 的目录栈）。
     *    没有它就不扫，功能静默降级 —— 播放本身不受影响。
     */
    private fun discoverSubtitles(pdir: String) {
        val a = api ?: return
        Bg.run({ a.listDirectory(pdir) }) { list, err ->
            if (err != null) {
                Log.w(TAG, "扫同目录字幕失败（不影响播放）：${err.message}")
                return@run
            }
            // ⛔ 用 [ExternalSubtitle.isSupported] 而不是只看 `isSubtitle`：
            //    `.sub` / `.idx` / `.sup` 都是图形字幕，media3 没有解析器，
            //    摆进菜单只会得到「选了没反应」。
            val found = (list ?: emptyList())
                .filter { it.isSubtitle && ExternalSubtitle.isSupported(it.name) }
                .map { SubtitleFile(it.fid, it.name, it.sizeBytes) }
            if (found.isEmpty()) {
                Log.i(TAG, "同目录没有可用字幕文件")
                return@run
            }

            val videoStem = ExternalSubtitle.normalize(
                intent.getStringExtra(EXTRA_NAME).orEmpty(),
            )
            val matchable = ExternalSubtitle.isMatchable(videoStem)
            // 「自动识别」的排序依据就这一条：归一化主干相等的排最前。
            val sorted = found.sortedByDescending { f ->
                val s = ExternalSubtitle.normalize(f.name)
                if (matchable && ExternalSubtitle.isMatchable(s) && s == videoStem) 1 else 0
            }
            subtitleFiles = sorted
            Log.i(
                TAG,
                "同目录字幕 ${sorted.size} 个（视频主干=${videoStem.ifEmpty { "—" }}）：" +
                    sorted.joinToString("、") { it.name },
            )

            // 与片名主干完全相等 ⇒ 认定为「本片的字幕」，自动加载。
            // 这是所有播放器（Kodi / VLC / PotPlayer）的通行约定，也是需求里
            // 「自动识别」最有用的一半。⛔ 只认**相等**，不做模糊 ——
            // 配错字幕比不配更烦人（用户会以为字幕坏了）。
            val auto = if (matchable) {
                sorted.firstOrNull {
                    val s = ExternalSubtitle.normalize(it.name)
                    ExternalSubtitle.isMatchable(s) && s == videoStem
                }
            } else {
                null
            }
            if (auto != null) {
                Log.i(TAG, "自动匹配到外挂字幕：${auto.name}")
                startExternalSubtitle(auto)
            }
            if (osd.visibility == View.VISIBLE) rebindOsd()
        }
    }

    /**
     * 下载并解析一条外挂字幕，成功后接管上屏。
     *
     * ⛔ 两步都在后台：`readFileBytes` 内含一次网盘 API 往返 + 一次 CDN 下载。
     *    字幕虽然只有几十 KiB，但在电视的 WiFi 上仍可能几百毫秒 ——
     *    放在主线程就是一次可见的掉帧。
     * ⛔ 请求头**跟着厂家走**：百度的直链必须带 `User-Agent: netdisk` +
     *    百度 Cookie（见 `BaiduMapper.dlinkHeaders`），所以这里不能自己拼
     *    `PanHttp.getBytes`，统一交给客户端。
     */
    private fun startExternalSubtitle(file: SubtitleFile) {
        val a = api ?: return
        externalPending = file.name
        if (osd.visibility == View.VISIBLE) rebindOsd()
        showNoticeBriefly("正在加载字幕…\n${file.name}", 1_200L)

        Bg.run({
            val bytes = a.readFileBytes(file.fid, SUBTITLE_MAX_BYTES)
            ExternalSubtitle.parse(file.name, bytes)
        }) { sub, err ->
            // ⛔ 结果可能**已经过期**：用户在这几百毫秒里又换了别的字幕
            //    （或者选了「关闭」）。不校验的话，先点的那条晚到的结果会把
            //    后点的覆盖掉 —— 表现为「选了半天，最后生效的是第一次点的那个」。
            if (externalPending != file.name) {
                Log.i(TAG, "丢弃过期的字幕加载结果：${file.name}")
                return@run
            }
            externalPending = null
            if (err != null || sub == null) {
                Log.e(TAG, "字幕加载失败：${file.name}", err)
                showNoticeBriefly("字幕加载失败\n${err?.message ?: "未知原因"}", 3_500L)
                if (osd.visibility == View.VISIBLE) rebindOsd()
                return@run
            }

            externalSub = sub
            externalActive = file.name
            // 内嵌文字轨必须让路：两条都往 `subtitles` 里写会互相覆盖，
            // 表现为「字幕一闪一闪」。
            disableEmbeddedText()
            Log.i(
                TAG,
                "外挂字幕已加载：${file.name} · ${sub.cueCount} 条 · 覆盖到 ${sub.spanMs / 1000}s",
            )
            // 立刻喂一次，别等下一个 tick —— 否则最多有 100ms 的空窗。
            player?.let { subtitles.setCues(sub.cuesAt(it.currentPosition)) }
            ui.removeCallbacks(subtitleTick)
            ui.post(subtitleTick)
            showNoticeBriefly("字幕：${file.name}", 1_800L)
            if (osd.visibility == View.VISIBLE) rebindOsd()
        }
    }

    /**
     * 停掉外挂字幕，把上屏权交还内嵌 / 关闭。
     *
     * ⛔ `externalPending` 也要清：清掉之后，还在路上的那次加载回来时
     *    `externalPending != file.name` 成立，结果会被自然丢弃。
     */
    private fun stopExternalSubtitle() {
        ui.removeCallbacks(subtitleTick)
        externalSub = null
        externalActive = null
        externalPending = null
        if (::subtitles.isInitialized) subtitles.setCues(emptyList())
    }

    /**
     * 关掉内嵌文字轨。
     *
     * ⛔ 光清 override **不够** —— 没有 override 时 ExoPlayer 会按
     *    `preferredTextLanguages` 自己再挑一条，内嵌字幕照样出来、与外挂
     *    叠在一起。（同 [applyTrackChoice] 里「关闭」那条路的注释。）
     */
    private fun disableEmbeddedText() {
        val p = player ?: return
        val b = p.trackSelectionParameters.buildUpon()
        b.clearOverridesOfType(C.TRACK_TYPE_TEXT)
        b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        p.trackSelectionParameters = b.build()
    }

    /**
     * 外挂字幕在菜单里显示的名字。
     *
     * 去掉扩展名：一屏 chips 里 `.srt` / `.ass` 是纯噪音，格式在日志里看得到。
     */
    private fun externalLabel(f: SubtitleFile): String {
        val base = f.name.substringBeforeLast('.', f.name)
        return if (f.name == externalPending) "$base（加载中…）" else base
    }

    // ------------------------------------------------------------------
    // OSD —— 画质 / 连接数 / 音轨 / 音效 / 字幕 / 倍速 / 调试
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
        // 画质档位的分辨率 / 码率 / 需带宽不进菜单（太长，见 `buildRows`），
        // 但必须留在日志里：「4K 卡顿」排查的第一步就是对照这几档的需带宽
        // （原画 3.00 MB/s vs 4k 0.63 MB/s，差 5 倍 —— 见 `PanModels.Quality`）。
        info?.let { pi ->
            Log.i(
                TAG,
                "画质档位：" + pi.qualities.joinToString(" | ") { "${it.label}(${it.id}) ${it.detail}" },
            )
        }
    }

    private fun buildRows(): List<TvOsdView.Row> {
        val out = ArrayList<TvOsdView.Row>(8)
        // 「选集」在第一行 —— **照 PC 端**（`buildPlayerTvRows` 里它就是第一项）。
        // 顺序在这里是有意义的：打开菜单时光标停在第一行，而「换一集」是
        // 剧集播放中最常做的事，排第一等于「按一下 OK 就到」。
        episodeRow()?.let { out += it }
        // 「画质」只在有 PlayInfo（正常取链路径）时才有。直接给 URL 的对照路径
        // 没有档位概念 ⇒ 少一行 —— 这正是回调要按 id 而不是按下标分派的原因。
        info?.let { pi ->
            out += TvOsdView.Row(
                id = ROW_QUALITY,
                label = "画质",
                value = current?.label ?: "—",
                // ⛔ 选项**只放短名**（`原画` / `4K` / `超清` / `高清` / `标清` / `流畅`）。
                //    曾经拼过 `${label}  ${detail}`（`4K  3840×1606 · 5.2 Mbps · 需
                //    0.63 MB/s`），一个 chip 就吃掉大半行，后面几档全被挤出面板 ——
                //    用户的原话是「选项过于冗长，超出设置面板」。
                //    分辨率 / 码率 / 需带宽 挪进日志（见 `rebindOsd`）：选档时真正
                //    要判断的是「哪一档能流畅播」，那件事已由 `chooseQuality` 按实测
                //    带宽自动做掉，不该让用户对着数字心算。
                options = pi.qualities.map { it.label },
                active = pi.qualities.indexOfFirst { it.id == current?.id },
            )
        }
        out += parallelRow()
        // ⛔ 这一行的标签是**「音轨」**，不是「音效」。
        //    它列的是**片源里封着的流**（语言 / 声道 / 环绕编码），chip 文案形如
        //    「韩语 · 立体声 · 杜比+」。2026-10-06 之前这里写的是「音效」，
        //    用户看到菜单里一列语言，反馈就是「音效感觉像是音轨，找不到音轨在哪」。
        //    PC 端的 `player_audio_effect.dart` 里早就写着这条后果，两边是同一个坑。
        out += trackRow(ROW_AUDIO, "音轨", C.TRACK_TYPE_AUDIO, withOff = false)
        // ⛔「音效」紧跟「音轨」：两者解决的是同一个听感问题的两半，摆一起最好找。
        out += audioEffectRow()
        out += trackRow(ROW_SUBTITLE, "字幕", C.TRACK_TYPE_TEXT, withOff = true)
        out += rateRow(currentSpeed)
        out += debugRow()
        return out
    }

    /**
     * 「选集」那一行 —— 照 PC 端，但列表里多一张**网盘封面**。
     *
     * ## 形态
     *
     * `vertical = true`：焦点在这一行按 **→**（或 OK）进右侧纵向列表，
     * 上下选、OK 换集、← / 返回退回侧栏 —— 按键语义与云影/夸克一致，
     * 由 [TvOsdView] 负责。
     *
     * ## ⛔ 什么时候**不**给这一行
     *
     * `siblings.size <= 1` 时返回 `null`：一部电影、或者一部只有一条文件的
     * 剧，没有「集」可选，多一行只是让菜单变长。
     * ⛔ 也正因如此**行数不是固定的** —— 回调一律按 [TvOsdView.Row.id] 分派
     *    （见 [onOsdActivate]），绝不能按下标 `when`。
     *
     * ## 列表三样东西怎么来的
     *
     * | 位置 | 内容 | 为什么 |
     * |---|---|---|
     * | 封面 | `media_items.thumb_url`（夸克 640×360 预览图） | 用户明确要求「网盘封面」 |
     * | 主标题 | [EpisodeLabels.fileLabel]（文件名去扩展名） | ⛔ **不写「第 N 集」** —— 见 `EpisodeLabels` 的类注释 |
     * | 进度条 | [EpisodeLabels.progressFraction]（读 **历史最大位置**） | 一眼看出「这一集看过没有 / 看到哪儿了」 |
     */
    private fun episodeRow(): TvOsdView.Row? {
        if (siblings.size <= 1) return null
        val options = ArrayList<String>(siblings.size)
        val progress = ArrayList<Double>(siblings.size)
        val thumbs = ArrayList<String>(siblings.size)
        for (item in siblings) {
            options.add(EpisodeLabels.fileLabel(item))
            // `-1.0` = 这一条没进度 ⇒ 条子整个藏起来（不是画一条空槽）。
            progress.add(EpisodeLabels.progressFraction(item) ?: -1.0)
            // ⛔ 与 options **等长**：没有预览图的那一条也要占一个空位，
            //    不能「跳过去」。`ListView` 按下标取值，错位了就是
            //    「第 7 集的封面贴在第 3 集上」，而且只在滚动之后才出现。
            thumbs.add(item.thumbUrl.orEmpty())
        }
        val idx = episodeIndex
        return TvOsdView.Row(
            id = ROW_EPISODE,
            label = "选集",
            value = if (idx in siblings.indices) options[idx] else "—",
            options = options,
            progress = progress,
            thumbs = thumbs,
            vertical = true,
            active = idx,
        )
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
                hint = when {
                    // ⛔ 这句要区分「片源没有内嵌字幕」和「同目录也没有外挂字幕」——
                    //    只说前者的话，用户看到「没有内嵌字幕」会以为没救了，
                    //    而实际上他可能只是没把 .srt 放到同一个目录里。
                    type != C.TRACK_TYPE_TEXT -> "该片源没有音轨"
                    subtitleFiles.isEmpty() -> "没有内嵌字幕，同目录也没有字幕文件"
                    else -> "该片源没有内嵌字幕"
                },
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
        val pref = prefs.parallelConnections
        // ⛔ 显示**实际生效**的条数，不是偏好值：百度慢通道被适配器压到 1 条，
        //    这时还显示「8 条」就是在骗人 —— 用户会以为调了没生效，反复去调。
        val n = effectiveConnections()
        val capped = n != pref
        val choices = AppPrefs.PARALLEL_CHOICES
        val label = { v: Int -> if (v <= 1) "1 条（关）" else "$v 条" }
        return TvOsdView.Row(
            id = ROW_PARALLEL,
            label = "连接数",
            value = label(n) + if (capped) "（网盘限制）" else "",
            options = choices.map(label),
            // ⛔ `active` 可能为 -1（存量偏好里存了个不在候选里的数）——
            //    OSD 对 -1 的语义就是「这行没有生效态」，不会崩，也不会误高亮。
            active = choices.indexOfFirst { it == n },
        )
    }

    /**
     * 「音效」那一行 —— 播放端对输出的处理方式（跟随片源 / 强制立体声）。
     *
     * ⛔ 与上一行「音轨」是**两件完全不同的事**，别合并（理由见 [AudioEffect]）：
     *    音轨是片源里封着的流（语言），音效是这台设备怎么处理输出。
     *
     * ⛔ 这是**全局参数**（存 `AppPrefs`）：它描述的是「这台电视怎么接音箱」，
     *    与正在放哪部片无关 —— 换片、换集都不该把它重置掉。
     *
     * ⚠️ 切换**要重建播放器**（见 [applyAudioEffect]），所以不像倍速那样
     *    「点了立刻听到区别」：画面会黑一下、从当前位置重新缓冲。这是 media3
     *    没给「运行期换 AudioSink」的接口导致的，不是没做。
     */
    private fun audioEffectRow(): TvOsdView.Row {
        val cur = prefs.audioEffect
        val all = AudioEffect.ALL
        return TvOsdView.Row(
            id = ROW_AUDIO_EFFECT,
            label = "音效",
            value = cur.label,
            options = all.map { it.label },
            active = all.indexOf(cur),
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
     *   * **画质 / 音效** —— 两者都要重建播放链路（画质换 media source、
     *     音效换 AudioSink），画面会黑一下，菜单收掉；
     *   * **音轨 / 字幕 / 倍速 / 调试** —— 留在菜单里。挑字幕往往要连试几条，
     *     每点一下就关菜单等于逼用户重开五遍。
     */
    private fun onOsdActivate(row: Int, chip: Int) {
        when (osdRows.getOrNull(row)?.id) {
            ROW_EPISODE -> {
                // ⛔ 换集**收菜单**：新一集起播后旧的那份行数据（音轨 / 字幕 /
                //    画质档位）全都是上一个文件的，留着就是错的。
                //    而且换集本身会重开播放页，菜单在那边是关着的。
                switchEpisode(chip)
            }
            ROW_QUALITY -> {
                info?.qualities?.getOrNull(chip)?.let { playQuality(it) }
                hideOsd()
            }
            ROW_AUDIO -> {
                applyTrackChoice(C.TRACK_TYPE_AUDIO, withOff = false, chip = chip)
                rebindOsd()
            }
            ROW_AUDIO_EFFECT -> {
                AudioEffect.ALL.getOrNull(chip)?.let { applyAudioEffect(it) }
                hideOsd()
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

    /**
     * 一条可选轨道。
     *
     * `group == null` 表示**不是片源里的轨道** —— 只有字幕会用到，两种情况：
     *   * [external] 为 `null` —— 「关闭」；
     *   * [external] 非空 —— 网盘同目录的**外挂字幕**。
     *
     * ⛔ 外挂字幕不能靠 `index` 表达（它根本不在 `Tracks` 里），所以必须
     *    单独一个字段。用「index = -1 就是关闭」那种约定会在加上外挂之后
     *    立刻分不清「关」和「外挂第 0 条」。
     */
    private class TrackChoice(
        val label: String,
        val group: TrackGroup?,
        val index: Int,
        val selected: Boolean,
        val external: SubtitleFile? = null,
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
        val out = ArrayList<TrackChoice>()
        if (withOff) out.add(TrackChoice(OFF_LABEL, null, -1, selected = false))
        var ordinal = 0
        var anySelected = false
        val t = tracks
        if (t != null) {
            for (g in t.groups) {
                if (g.type != type) continue
                for (i in 0 until g.length) {
                    ordinal++
                    val sel = g.isTrackSelected(i)
                    if (sel) anySelected = true
                    out.add(TrackChoice(trackLabel(g, i, ordinal), g.mediaTrackGroup, i, sel))
                }
            }
        }
        // 外挂字幕**并进同一行** —— 「选字幕」在用户眼里就是一件事，
        // 拆成两行之后「现在到底用的是哪条」反而说不清，而且两条行会互相打架
        // （选了内嵌却忘了关外挂，字幕就叠在一起）。
        if (type == C.TRACK_TYPE_TEXT) {
            for (f in subtitleFiles) {
                out.add(
                    TrackChoice(
                        label = externalLabel(f),
                        group = null,
                        index = -1,
                        selected = f.name == externalActive,
                        external = f,
                    ),
                )
            }
        }
        // 内嵌一条都没选中、外挂也没有在生效 ⇒ 现在就是「关闭」状态。
        // ⛔ `externalActive == null` 这个条件不能漏：外挂生效时内嵌必然是
        //    一条都没选中的（我们主动把它关了），少了它光标会停在「关闭」上，
        //    而实际正在放的是外挂字幕。
        if (withOff && !anySelected && externalActive == null && out.size > 1) {
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
        val choice = trackChoices(type, withOff).getOrNull(chip)
        if (choice == null) {
            Log.w(TAG, "轨道下标越界：type=$type chip=$chip")
            return
        }

        // 外挂字幕：**不走** ExoPlayer 的轨道机制 —— 自己下载解析后接管上屏
        // （见 [ExternalSubtitle] 的类注释：挂到 media source 上要重建播放器）。
        if (type == C.TRACK_TYPE_TEXT && choice.external != null) {
            Log.i(TAG, "切字幕 → 外挂 ${choice.external.name}")
            startExternalSubtitle(choice.external)
            return
        }

        val p = player ?: return
        // 内嵌 / 关闭都要先把外挂摘掉：两条会同时往 `subtitles` 里写。
        if (type == C.TRACK_TYPE_TEXT && (externalSub != null || externalPending != null)) {
            stopExternalSubtitle()
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

    /**
     * 把重建播放器前记住的轨道选择按**标签**重新选上。见 [pendingTracks]。
     *
     * ⛔ 轨道表为空就**先不消费** `pendingTracks`：`prepare()` 之后
     *    `onTracksChanged` 常常回调两三次，头一两次可能是空的。这时候消费掉
     *    就等于「还原失败」，用户看到的是「切了个音效，字幕没了」。
     * ⛔ 匹配不上一律**放弃**（不动任何东西）：片源里那条轨可能压根不在，
     *    硬按旧下标去选会选错一条 —— 症状是「切了个音效，语言变了」。
     */
    private fun restorePendingTracks() {
        val want = pendingTracks ?: return
        val groups = tracks?.groups ?: return
        if (groups.isEmpty()) return
        pendingTracks = null
        want.audio?.let { restoreTrack(C.TRACK_TYPE_AUDIO, withOff = false, label = it) }
        want.subtitle?.let { restoreTrack(C.TRACK_TYPE_TEXT, withOff = true, label = it) }
    }

    private fun restoreTrack(type: Int, withOff: Boolean, label: String) {
        val choices = trackChoices(type, withOff)
        val idx = choices.indexOfFirst { it.label == label }
        if (idx < 0) {
            Log.i(TAG, "还原${trackTypeName(type)}「$label」：新片源里没有这一条，保持默认")
            return
        }
        applyTrackChoice(type, withOff, idx)
        Log.i(TAG, "还原${trackTypeName(type)} → $label")
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
        // ⛔⛔ 上一次读库没成功（撞上另一个句柄的写事务，见 [loadSiblings]）时，
        //    「选集」行此刻是**缺**的。打开菜单是用户的真实动作，也是最后一次
        //    自然的补救机会 —— 重试成功后 [rebindOsd] 会把这一行补上。
        //    不这么做的话，一次瞬时失败 = 整个会话都没有选集。
        if (!siblingsLoaded && siblingsGroupKey.isNotEmpty()) {
            Log.i(TAG, "OSD 打开时补一次选集读库（上次没成功）")
            loadSiblings(siblingsGroupKey, siblingsFid)
        }
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
     * @param user `true` = 用户发起的（触摸拖拽 / 快进 / 数字键），
     *   `false` = **我们自己**发起的（跳片头）。⛔ 这个区别只影响一件事：
     *   用户 seek 会被记成学习样本，自动跳**绝不会** —— 否则学习结论会
     *   自己喂自己，片头越学越靠后，而它看起来完全像「越学越准」。
     */
    private fun seekToPosition(targetMs: Long, source: String, user: Boolean = true) {
        val p = player ?: return
        val d = p.duration
        val max = if (d == C.TIME_UNSET || d <= 0L) Long.MAX_VALUE else d
        val target = targetMs.coerceIn(0L, max)
        // 学习样本：**必须在 `seekTo` 之前**读 `currentPosition` ——
        // `seekTo` 之后它立刻就是新位置了，`from` 会等于 `to`，
        // 于是「前进」这条判据恒为假，一条样本都攒不到。
        if (user) {
            anchorCollector.noteSeek(
                SeekObservation(
                    fromMs = p.currentPosition,
                    toMs = target,
                    durationMs = if (d == C.TIME_UNSET || d <= 0L) 0L else d,
                    // 倍速下「位置」的语义变了（用户在扫剧），锚点与其他集不可比。
                    // 判据在 `SkipAnchorCollector.noteSeek` 里，这里如实报。
                    rate = p.playbackParameters.speed.toDouble(),
                ),
            )
        }
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

        /**
         * 本条属于哪家网盘（`quark` / `baidu`）。
         *
         * ⛔ 缺省按 `quark` 处理 —— 老的起播路径（`BrowseActivity` / `LibraryActivity`
         *    在本次改造前发出的 intent）都没有这个 extra，不能因此崩掉。
         * ⛔ 它决定 `DriveClients.create(provider, store)` 用哪家的 `DriveClient`，
         *    以及 CDN 请求头走哪套方言（见 `headersForCdn`）。
         */
        const val EXTRA_PROVIDER = "provider"

        /**
         * 百度用的**完整网盘路径**（`父目录路径 + "/" + 文件名`）。
         *
         * ⛔ 百度**没有** fid → path 的反查接口，而取链的兜底路由（`/api/filemetas`、
         *    `/api/batch/streaming`）都要路径。由列表页顺手带过来能省一次翻译，
         *    更重要的是**避开冷启动时 xpan 接口的风控**（`-6` 的常见来源）。
         * 夸克忽略这个 extra（它只认 `pdir_fid`）。
         */
        const val EXTRA_PATH = "path"

        /**
         * 本片**所在目录**的 fid —— 「自动识别同目录字幕」的唯一依据。
         *
         * ⛔ 单个 `fid` 推不出父目录，网盘也没有「查父目录」的接口，
         *    所以它必须由列表页随起播意图一起带过来（见 `BrowseActivity.onEntry`）。
         *    没有它时外挂字幕功能静默降级，播放不受影响。
         */
        const val EXTRA_PDIR = "pdir"

        /**
         * 百度用的**父目录路径**（`/剧集/第一季`）—— 与 [EXTRA_PDIR] 同义，只是百度那边
         * 目录的标识是**路径**而不是 id（`dir` 字段）。
         *
         * ⛔ 两者都要传、不能合并：夸克查同目录字幕要 `pdir_fid`，百度要 `dir` 路径。
         *    传哪个由 [EXTRA_PROVIDER] 决定（见 `subtitleDirRef`）。
         */
        const val EXTRA_PDIR_PATH = "pdirPath"

        /**
         * 本片**所属作品**的 `group_key` —— 「选集」的唯一入口。
         *
         * ⛔ 播放页原来完全不碰媒体库，只拿一个 `fid` 就去取链，于是「同一部
         *    作品还有哪些文件」这件事**无从得知**（网盘没有「查兄弟文件」的
         *    接口；按文件名去猜同作品更是必错）。只能由**列表页**随起播意图
         *    带过来，播放页再拿它去查一次库（见 `loadSiblings`）。
         *
         * 没有它时选集行不出现，播放本身完全不受影响 —— 从「文件浏览」页
         *    直接点一个文件进来就是这种情形。
         */
        const val EXTRA_GROUP_KEY = "groupKey"

        /**
         * 「选集」读库失败的重试次数与退避基数（毫秒）。
         *
         * ⛔ 撞的是 `SQLITE_BUSY`（另一个句柄正在写 `last_played_at`），而写事务
         *    是毫秒级的 —— 三次、最多等 150+300+450ms 足够，再多只会让
         *    「起播后菜单晚一拍才长选集行」变得可感知。
         */
        private const val SIBLINGS_RETRIES = 3
        private const val SIBLINGS_RETRY_DELAY_MS = 150L

        /**
         * 起播要跳到的位置（毫秒）；`<= 0` = 从头播。
         *
         * ⛔ 由**列表页**带过来（`PlayTarget.resolve` 挑好那一集之后顺手取的
         *    `resume_position_ms`）。播放页不自己查库 —— 见 `onCreate` 那处注释。
         */
        const val EXTRA_RESUME_MS = "resumeMs"

        /**
         * 上一次实测的并行带宽（MiB/s）—— 只有**换集**才带。
         *
         * ⛔ 换集会重开播放页，而量一次带宽要 3 秒；同一条 WiFi、同一个 CDN，
         *    刚量过的数没必要每集重量一遍。见 `probeThenPlay`。
         * ⛔ `0.0` = 没有（正常起播），此时一律实测。
         */
        const val EXTRA_REUSE_BANDWIDTH = "reuseBandwidth"

        /**
         * 外挂字幕文件的大小上限。
         *
         * ⛔ 字幕是几十 KiB 的纯文本，8 MiB 只是防呆（防止把误标成 `.srt` 的
         *    视频整个读进内存）。读超上限直接当「读不到」处理，播放不受影响。
         */
        private const val SUBTITLE_MAX_BYTES = 8 * 1024 * 1024

        private const val BrowserUa =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

        private val SPEEDS = listOf(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)

        // ── OSD 行的稳定标识 ────────────────────────────────────────
        // ⛔ 原生 OSD 只回传**行下标**，而「画质」行在对照路径上不存在、
        //    「字幕/音效」行在片源没有对应轨道时会退化成一句提示 —— 行数
        //    不是固定的。所以分派一律走这些 id，不要 `when (row) { 0 -> ... }`。
        private const val ROW_EPISODE = "episode"
        private const val ROW_QUALITY = "quality"
        private const val ROW_PARALLEL = "parallel"
        private const val ROW_AUDIO = "audio"
        private const val ROW_AUDIO_EFFECT = "audioEffect"
        private const val ROW_SUBTITLE = "subtitle"
        private const val ROW_SPEED = "speed"
        private const val ROW_DEBUG = "debug"

        /** 字幕那一行最前面的「关闭」项。 */
        private const val OFF_LABEL = "关闭"

        /**
         * 进度写库的心跳（毫秒）—— 与 PC 端同口径（10 秒）。
         *
         * ⛔ 别调快：写库是磁盘 I/O，而预取器正在以几 MiB/s 往同一块盘写。
         *    每秒一次等于给已经在抖的缓冲再加一份抖动。误差由「退出时补写」
         *    兜住，所以慢一点没有任何代价。
         */
        private const val PROGRESS_TICK_MS = 10_000L

        /**
         * 选集封面在内存里的缓存上限（字节）。
         *
         * 一张封面解码后是 `320×180 RGB_565` ≈ 115 KiB；8 MiB ≈ 70 张。
         * 一屏只看得见 6 行，70 张足够上下翻好几屏不至于重新解码，
         * 又不会把「从头翻到尾」的整部剧留在堆里（这台电视只有 512 MB）。
         */
        private const val THUMB_CACHE_BYTES = 8 * 1024 * 1024

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
         * 外挂字幕的上屏周期（毫秒）。
         *
         * ⛔ 见 [subtitleTick] 的注释：这里**故意**用轮询而不是「按 cue 边界排
         *    定时器」。100ms 是「人眼察觉不到的延迟」与「几乎不耗 CPU」的交点 ——
         *    每次只做一次二分 + 一次内容指纹比对，字幕间隙里几乎零成本。
         */
        private const val SUBTITLE_TICK_MS = 100L

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
