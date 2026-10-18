package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.DriveProviders
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.QrLogin
import com.cloudcine.tv.pan.baidu.BaiduEndpoints
import com.cloudcine.tv.pan.baidu.BaiduQrLogin
import com.cloudcine.tv.pan.baidu.filterBaiduCookiesForCredential

/**
 * 扫码登录页 —— 「授权」这一块的唯一实现（**两家网盘共用**）。
 *
 * 电视上没有键盘，扫码是**唯一现实**的登录方式：二维码画在电视上，
 * 手机 App 扫一下确认即可。全程不接触账号密码。
 *
 * ## ⛔ 两家的二维码**不是同一种东西**
 *
 * | | 夸克 | 百度 |
 * |---|---|---|
 * | 服务端给什么 | 一个 **token 字符串** | 一张**已经画好的 PNG 地址**（`imgurl`） |
 * | 电视这边怎么画 | 自己编码成二维码（[QrCode.bitmap]） | 下载下来直接显示（[BitmapFactory]） |
 * | 有没有「已扫码」态 | 没有 | **有**（`status=1`，要提示用户去手机点确认） |
 *
 * 照着夸克那套去 `QrCode.bitmap(imgurl)` 编码百度的二维码，得到的是一张
 * 「把网址当内容」的二维码 —— 扫出来是一串 URL，永远不会登录成功。
 *
 * ## ⛔ 切网盘必须作废旧回调
 *
 * 轮询是异步的，用户可能在轮询途中切到另一家。旧那条链的 `Confirmed` 回来时
 * 若照常写库，就会把**上一家**的凭证写进**这一家**的槽位（两家 Cookie 结构
 * 完全不同，症状是「登录成功但列表一直空」）。所以每次切换都把 [generation]
 * 加一，回调先比对这个号，不一致就整个丢掉。
 */
class LoginActivity : Activity() {

    private lateinit var store: CredStore
    private lateinit var quark: QrLogin
    private lateinit var baidu: BaiduQrLogin

    private lateinit var qrImage: ImageView
    private lateinit var status: TextView
    private lateinit var hint: TextView
    private lateinit var tabs: LinearLayout
    private val tabViews = LinkedHashMap<String, TextView>()

    /** 当前要登录哪一家。 */
    private var provider: String = DriveProviders.QUARK

    private var quarkSession: QrLogin.Session? = null
    private var baiduSession: BaiduQrLogin.Session? = null

    private var stopped = false

    /** 每次切换/重取二维码都 +1；异步回调靠它判「我还是不是当前这一轮」。 */
    private var generation = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = CredStore(this)
        quark = QrLogin(store)
        baidu = BaiduQrLogin()
        provider = intent.getStringExtra(EXTRA_PROVIDER)
            ?.takeIf { it.isNotEmpty() }
            ?: store.activeProvider

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(64), dp(40), dp(64), dp(40))
            setBackgroundColor(Color.parseColor("#101216"))
            gravity = Gravity.CENTER_VERTICAL
        }

        // 左：二维码（白底，电视上对比度要够）
        qrImage = ImageView(this).apply {
            setBackgroundColor(Color.WHITE)
            setPadding(dp(12), dp(12), dp(12), dp(12))
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        root.addView(
            qrImage,
            LinearLayout.LayoutParams(dp(360), dp(360)),
        )

        // 右：品牌 + 网盘选择 + 说明与状态
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(40), 0, 0, 0)
        }

        // 品牌行：图标 + 字标。登录页是用户见到的第一屏，品牌要在这儿出现，
        // 否则整屏只有一个白框二维码，看不出这是哪个 App。
        val brand = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(22))
        }
        brand.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(52), dp(52)),
        )
        brand.addView(
            text(getString(R.string.app_name), 24f, Color.WHITE).apply {
                setPadding(dp(14), 0, 0, 0)
            },
        )
        col.addView(brand)

        col.addView(text("扫码登录", 26f, Color.WHITE))

        // ── 网盘选择：两个胶囊，OK 切换 ──────────────────────────────
        // ⛔ 用**自管 OK** 的两行按钮而不是 `Button`：电视上 `Button` 拿焦点后
        //    遥控器的 OK 会走 `performClick`，而本工程其它页面全是自管
        //    `dispatchKeyEvent`（见 `LibraryActivity`），混用两套按键模型最容易
        //    出现「这一页返回键不响应」。
        tabs = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(12), 0, dp(4))
        }
        for (p in listOf(DriveProviders.QUARK, DriveProviders.BAIDU)) {
            val tab = text(DriveProviders.displayName(p), 16f, Color.WHITE).apply {
                gravity = Gravity.CENTER
                setPadding(dp(22), dp(10), dp(22), dp(10))
                isFocusable = true
                setOnClickListener { switchProvider(p) }
            }
            tabViews[p] = tab
            tabs.addView(
                tab,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { rightMargin = dp(12) },
            )
        }
        col.addView(tabs)

        hint = text("", 15f, 0xFF9AA3B2.toInt())
        col.addView(hint)
        col.addView(text("全程不接触账号密码，凭证只存在本机。", 13f, 0xFF6B7280.toInt()))
        status = text("正在获取二维码…", 16f, BRAND_TINT).apply {
            setPadding(0, dp(24), 0, 0)
        }
        col.addView(status)
        root.addView(col)

        // ⛔ `renderTabs()` **必须**放在 `hint` / `status` 赋值之后：它要写
        //    `hint.text`。放在建 tabs 的那一段里（挨着 `col.addView(tabs)`）
        //    会在真机上直接崩 —— `lateinit property hint has not been
        //    initialized`，而这句异常发生在 `onCreate` 里，表现是
        //    **点图标闪一下就回桌面**（2026-10-18 模拟器实测）。
        //    这是本工程的既有红线（见 MEMORY：`lateinit` 视图先赋值再调用）。
        renderTabs()

        setContentView(root)
        // ⛔ 光标落在**当前网盘**那个胶囊上，遥控器一进来就能按 OK 重取二维码。
        tabViews[provider]?.requestFocus()

        // 已经登录了这一家 ⇒ 直接进媒体库（省一次扫码）
        if (store.loggedIn(provider)) {
            Log.i(TAG, "$provider 已有凭证，跳过登录")
            gotoLibrary()
            return
        }
        startLogin()
    }

    // ------------------------------------------------------------------
    // 网盘切换
    // ------------------------------------------------------------------

    private fun switchProvider(next: String) {
        if (next == provider) {
            // 已经在这一家：按 OK 的语义是「重取一张二维码」（过期了想手动刷）。
            restart()
            return
        }
        // ⛔ 目标那家「已登录」也**照常出二维码**，不要直接跳回媒体库。
        //    理由：`store.loggedIn` 只说明**本地有凭证**，不说明凭证还有效 ——
        //    而用户被送到登录页，往往正是因为那份凭证已经废了（列目录回 `-6`）。
        //    跳回去只是让他再看一遍空墙。扫码 = 用新凭证覆盖旧的，对「换账号」
        //    和「凭证过期」两种情形都是对的动作。
        //    想「只切换不换账号」的走媒体库菜单里那条「当前网盘：X（切换到Y）」。
        if (store.loggedIn(next)) {
            Log.i(TAG, "$next 已有凭证，仍出二维码（可换账号 / 刷新失效凭证）")
        } else {
            Log.i(TAG, "登录页切换网盘：$provider → $next")
        }
        provider = next
        quarkSession = null
        baiduSession = null
        renderTabs()
        restart()
    }

    private fun renderTabs() {
        for ((p, v) in tabViews) {
            val on = p == provider
            v.setTextColor(if (on) Color.WHITE else 0xFF9AA3B2.toInt())
            v.background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                setColor(if (on) BRAND else 0xFF1B1F27.toInt())
                setStroke(dp(1), if (on) BRAND else 0xFF2C313B.toInt())
            }
        }
        val base = if (provider == DriveProviders.BAIDU) {
            "用手机百度 App 扫码，确认后等这一页自动进入媒体库。"
        } else {
            "用手机夸克 App 扫码，并在手机上点确认。"
        }
        // ⛔ 「已登录」要写出来：否则用户看到二维码会以为自己的登录被清掉了。
        hint.text = if (store.loggedIn(provider)) "$base（已登录，扫码可换账号）" else base
    }

    // ------------------------------------------------------------------
    // 取码
    // ------------------------------------------------------------------

    /** 作废当前这一轮，重新取一张码。 */
    private fun restart() {
        generation++
        quarkSession = null
        baiduSession = null
        qrImage.setImageDrawable(null)
        status.text = "正在获取二维码…"
        startLogin()
    }

    private fun startLogin() {
        val gen = generation
        when (provider) {
            DriveProviders.BAIDU -> startBaidu(gen)
            else -> startQuark(gen)
        }
    }

    private fun startQuark(gen: Int) {
        Bg.run({ quark.start() }) { s, err ->
            if (stopped || gen != generation) return@run
            if (err != null || s == null) {
                status.text = "获取二维码失败：${err?.message ?: "未知错误"}\n（按 OK 重试）"
                Log.e(TAG, "夸克取二维码失败", err)
                return@run
            }
            quarkSession = s
            qrImage.setImageBitmap(QrCode.bitmap(s.qrUrl, dp(360) - dp(24)))
            status.text = "等待扫码…"
            pollLoop(gen)
        }
    }

    private fun startBaidu(gen: Int) {
        Bg.run({
            val s = baidu.start()
            // ⛔ 二维码是**服务端画好的 PNG**，必须在后台下载 —— 主线程发网络
            //    请求会直接 `NetworkOnMainThreadException`。
            val png = baidu.fetchQrImage(s)
            s to png
        }) { pair, err ->
            if (stopped || gen != generation) return@run
            if (err != null || pair == null) {
                status.text = "获取二维码失败：${err?.message ?: "未知错误"}\n（按 OK 重试）"
                Log.e(TAG, "百度取二维码失败", err)
                return@run
            }
            val (s, png) = pair
            baiduSession = s
            val bmp = png?.let {
                runCatching { BitmapFactory.decodeByteArray(it, 0, it.size) }.getOrNull()
            }
            if (bmp != null) {
                qrImage.setImageBitmap(bmp)
                status.text = "等待扫码…"
            } else {
                // 图没下到不代表登录不能做：手机上照样能扫，只是电视上看不见。
                // ⛔ 必须**明说**，否则用户会盯着一个白框等。
                status.text = "二维码图片下载失败\n（可重试；或直接到手机百度 App 的「扫一扫」）"
            }
            pollLoop(gen)
        }
    }

    // ------------------------------------------------------------------
    // 轮询
    // ------------------------------------------------------------------

    /**
     * 轮询循环。
     *
     * ⛔ 用 `postDelayed` 串行重排，**不要 `while(true) { poll(); sleep() }`** ——
     * 后者要占一条后台线程直到登录完成（或超时），而这个页面可能被按返回键
     * 留在后台很久，线程就一直挂着。串行重排天然随页面一起停。
     */
    private fun pollLoop(gen: Int) {
        if (stopped || gen != generation) return
        when (provider) {
            DriveProviders.BAIDU -> pollBaidu(gen)
            else -> pollQuark(gen)
        }
    }

    private fun pollQuark(gen: Int) {
        val s = quarkSession ?: return
        Bg.run({ quark.poll(s) }) { outcome, err ->
            if (stopped || gen != generation) return@run
            when {
                err != null -> {
                    status.text = "轮询出错：${err.message}"
                    retryLater(gen)
                }
                outcome is QrLogin.Poll.Confirmed -> {
                    status.text = "已确认，正在换取凭证…"
                    exchangeQuark(gen, outcome.ticket)
                }
                outcome is QrLogin.Poll.Expired -> {
                    // token 过期（超过有效期或 client_id 不匹配）→ 重新取一张
                    status.text = "二维码已过期，正在刷新…"
                    restart()
                }
                outcome is QrLogin.Poll.Error -> {
                    status.text = "等待中（${outcome.message}）"
                    retryLater(gen)
                }
                else -> retryLater(gen)
            }
        }
    }

    /**
     * 百度轮询。
     *
     * ⛔ `Waiting` 是**正常态**（长轮询挂满 30 秒、或服务端回 `errno:1`），
     *    绝不能当失败重取二维码 —— 那会让用户每半分钟看到一次「正在获取
     *    二维码」，而他其实什么都没做错。
     */
    private fun pollBaidu(gen: Int) {
        val s = baiduSession ?: return
        Bg.run({ baidu.poll(s) }) { outcome, err ->
            if (stopped || gen != generation) return@run
            when {
                err != null -> {
                    status.text = "轮询出错：${err.message}"
                    retryLater(gen)
                }
                outcome is BaiduQrLogin.Poll.Confirmed -> {
                    status.text = "已确认，正在换取凭证…"
                    exchangeBaidu(gen, outcome)
                }
                outcome is BaiduQrLogin.Poll.Scanned -> {
                    // 夸克没有这一态。百度要求**手机上再点一次确认**，
                    // 不提示的话用户会以为「扫完就完事了」然后一直等。
                    status.text = "已扫码，请在手机上点「确认登录」"
                    retryLater(gen)
                }
                outcome is BaiduQrLogin.Poll.Cancelled -> {
                    status.text = "已取消，正在刷新二维码…"
                    restart()
                }
                outcome is BaiduQrLogin.Poll.Expired -> {
                    status.text = "二维码已过期，正在刷新…"
                    restart()
                }
                outcome is BaiduQrLogin.Poll.Error -> {
                    status.text = "等待中（${outcome.message}）"
                    retryLater(gen)
                }
                else -> retryLater(gen)
            }
        }
    }

    private fun retryLater(gen: Int) {
        status.postDelayed({ if (!stopped && gen == generation) pollLoop(gen) }, POLL_INTERVAL_MS)
    }

    // ------------------------------------------------------------------
    // 换票
    // ------------------------------------------------------------------

    private fun exchangeQuark(gen: Int, ticket: String) {
        Bg.run({
            quark.exchange(ticket)
            // 换完立刻打一发 API：一是验证凭证真的可用，二是让服务端把
            // `__puus` 下发下来（`/account/info` 不给它）。
            PanApi(store).fetchNickname()
        }) { nick, err ->
            if (stopped || gen != generation) return@run
            if (err != null) {
                status.text = "登录失败：${err.message}"
                status.postDelayed({ if (!stopped && gen == generation) restart() }, 2500)
                return@run
            }
            nick?.let { store.setNickname(DriveProviders.QUARK, it) }
            onLoggedIn(DriveProviders.QUARK, nick)
        }
    }

    /**
     * 百度换票。
     *
     * ⛔ 写库这一步**在这里**做（夸克那边是 `QrLogin.exchange` 自己写）：
     *    `BaiduQrLogin` 刻意不持有 `CredStore`（它是纯网络状态机，要能被
     *    单测注入假 HTTP），所以「把结果落成一份 Cookie」是页面的事。
     * ⛔ 必须过 [filterBaiduCookiesForCredential]：落点那一跳收到的
     *    `PANWEB` / `PANPSC` 不在固定名单里，丢掉它们网盘侧不认会话。
     */
    private fun exchangeBaidu(gen: Int, confirmed: BaiduQrLogin.Poll.Confirmed) {
        Bg.run({
            val r = baidu.exchange(confirmed)
            val cookies = filterBaiduCookiesForCredential(r.cookies, r.panCookieNames)
            val header = BaiduEndpoints.cookieHeader(cookies)
            if (header.isEmpty()) error("换票成功但没有任何可用 Cookie")
            store.setCookie(DriveProviders.BAIDU, header)
            // 验证 + 顺手取昵称 / 会员档位（非 SVIP 只有 480P 转码档）。
            com.cloudcine.tv.pan.baidu.BaiduApi(store).fetchNickname()
        }) { nick, err ->
            if (stopped || gen != generation) return@run
            if (err != null) {
                status.text = "登录失败：${err.message}"
                // 换票失败要把半成品凭证清掉，否则下次进来会被判「已登录」。
                store.clearProvider(DriveProviders.BAIDU)
                status.postDelayed({ if (!stopped && gen == generation) restart() }, 2500)
                return@run
            }
            nick?.let { store.setNickname(DriveProviders.BAIDU, it) }
            onLoggedIn(DriveProviders.BAIDU, nick)
        }
    }

    private fun onLoggedIn(p: String, nick: String?) {
        // ⛔ 成功之后把这一家设为**当前网盘**：用户刚登的就是他想看的那个库。
        store.activeProvider = p
        Log.i(TAG, "$p 登录成功，昵称=${nick ?: "（未取到）"}")
        status.text = "登录成功${if (nick.isNullOrEmpty()) "" else "，$nick"}，正在进入媒体库…"
        status.postDelayed({ if (!stopped) gotoLibrary() }, 600)
    }

    /**
     * 登录成功后进**媒体库**（不是网盘文件列表）。
     *
     * ⛔ 与 `MainActivity` 的口径必须一致：那一边按登录态直达媒体库，这一边登录完
     *    却送去文件列表的话，用户会觉得「登录之后又跳到了另一个地方」。
     *    网盘目录仍然是媒体库里的一个入口。
     */
    private fun gotoLibrary() {
        startActivity(Intent(this, LibraryActivity::class.java))
        finish()
    }

    // ------------------------------------------------------------------
    // 按键
    // ------------------------------------------------------------------

    /**
     * 返回键：在后台（已登录但停在这一页）时照常退出；
     * 左右键在两颗胶囊之间移动焦点（`LinearLayout` 默认就能做到，
     * 这里只是把「没焦点时」兜住 —— 遥控器刚唤醒时焦点可能落在二维码上）。
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                    if (currentFocus !is TextView) {
                        tabViews[provider]?.requestFocus()
                        return true
                    }
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        stopped = true
        super.onDestroy()
    }

    private fun text(s: String, sp: Float, color: Int) = TextView(this).apply {
        text = s
        setTextColor(color)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setPadding(0, dp(6), 0, dp(6))
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        /** 指定要登录哪一家（缺省按 `store.activeProvider`）。 */
        const val EXTRA_PROVIDER = "provider"

        private const val TAG = "CloudCine"
        private const val POLL_INTERVAL_MS = 2000L

        /** 品牌主色。 */
        private const val BRAND = 0xFF7F77DD.toInt()

        /** 品牌主色的浅色调（深底上直接用主色偏暗）。 */
        private const val BRAND_TINT = 0xFF9F98F5.toInt()
    }
}
