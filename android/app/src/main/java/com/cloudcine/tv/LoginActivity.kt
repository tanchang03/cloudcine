package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.QrLogin
import com.cloudcine.tv.pan.CredStore

/**
 * 扫码登录页 —— 「授权」这一块的唯一实现。
 *
 * 电视上没有键盘，扫码是**唯一现实**的登录方式：二维码画在电视上，
 * 手机 App 扫一下确认即可。全程不接触账号密码。
 *
 * 轮询节奏 2 秒一次，与云影一致。⛔ 轮询**不刷日志**：
 * `50004001`（还没扫）是正常态，每 2 秒打一行会把 logcat 淹掉。
 */
class LoginActivity : Activity() {

    private lateinit var store: CredStore
    private lateinit var login: QrLogin
    private lateinit var qrImage: ImageView
    private lateinit var status: TextView

    private var session: QrLogin.Session? = null
    private var stopped = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = CredStore(this)
        login = QrLogin(store)

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
        }
        root.addView(
            qrImage,
            LinearLayout.LayoutParams(dp(360), dp(360)),
        )

        // 右：品牌 + 说明与状态
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
        col.addView(text("用手机扫描左侧二维码，并在手机上点确认。", 15f, 0xFF9AA3B2.toInt()))
        col.addView(text("全程不接触账号密码，凭证只存在本机。", 13f, 0xFF6B7280.toInt()))
        status = text("正在获取二维码…", 16f, BRAND_TINT).apply {
            setPadding(0, dp(24), 0, 0)
        }
        col.addView(status)
        root.addView(col)

        setContentView(root)

        // 已登录就直接进**媒体库**（首页，省一次扫码）
        if (store.loggedIn) {
            Log.i(TAG, "已有凭证，跳过登录")
            gotoLibrary()
            return
        }
        startLogin()
    }

    private fun startLogin() {
        Bg.run({ login.start() }) { s, err ->
            if (stopped) return@run
            if (err != null || s == null) {
                status.text = "获取二维码失败：${err?.message ?: "未知错误"}\n（按返回键重试）"
                Log.e(TAG, "取二维码失败", err)
                return@run
            }
            session = s
            qrImage.setImageBitmap(QrCode.bitmap(s.qrUrl, dp(360) - dp(24)))
            status.text = "等待扫码…"
            pollLoop()
        }
    }

    /**
     * 轮询循环。
     *
     * ⛔ 用 `postDelayed` 串行重排，**不要 `while(true) { poll(); sleep() }`** ——
     * 后者要占一条后台线程直到登录完成（或超时），而这个页面可能被按返回键
     * 留在后台很久，线程就一直挂着。串行重排天然随页面一起停。
     */
    private fun pollLoop() {
        val s = session ?: return
        Bg.run({ login.poll(s) }) { outcome, err ->
            if (stopped) return@run
            when {
                err != null -> {
                    status.text = "轮询出错：${err.message}"
                    retryLater()
                }
                outcome is QrLogin.Poll.Confirmed -> {
                    status.text = "已确认，正在换取凭证…"
                    exchange(outcome.ticket)
                }
                outcome is QrLogin.Poll.Expired -> {
                    // token 过期（超过有效期或 client_id 不匹配）→ 重新取一张
                    status.text = "二维码已过期，正在刷新…"
                    startLogin()
                }
                outcome is QrLogin.Poll.Error -> {
                    status.text = "等待中（${outcome.message}）"
                    retryLater()
                }
                else -> retryLater()
            }
        }
    }

    private fun retryLater() {
        status.postDelayed({ if (!stopped) pollLoop() }, POLL_INTERVAL_MS)
    }

    private fun exchange(ticket: String) {
        Bg.run({
            login.exchange(ticket)
            // 换完立刻打一发 API：一是验证凭证真的可用，二是让服务端把
            // `__puus` 下发下来（`/account/info` 不给它）。
            PanApi(store).fetchNickname()
        }) { nick, err ->
            if (stopped) return@run
            if (err != null) {
                status.text = "登录失败：${err.message}"
                status.postDelayed({ if (!stopped) startLogin() }, 2500)
                return@run
            }
            nick?.let { store.nickname = it }
            Log.i(TAG, "登录成功，昵称=${nick ?: "（未取到）"}")
            status.text = "登录成功${if (nick.isNullOrEmpty()) "" else "，$nick"}，正在进入媒体库…"
            status.postDelayed({ if (!stopped) gotoLibrary() }, 600)
        }
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

    private companion object {
        const val TAG = "CloudCine"
        const val POLL_INTERVAL_MS = 2000L

        /** 品牌主色的浅色调（OSD 里那个 `#7F77DD` 直接用在深底上偏暗）。 */
        const val BRAND_TINT = 0xFF9F98F5.toInt()
    }
}
