package com.cloudcine.kuake

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
import com.cloudcine.kuake.quark.Bg
import com.cloudcine.kuake.quark.QuarkApi
import com.cloudcine.kuake.quark.QuarkQrLogin
import com.cloudcine.kuake.quark.QuarkStore

/**
 * 扫码登录页 —— 「授权」这一块的唯一实现。
 *
 * 电视上没有键盘，扫码是**唯一现实**的登录方式：二维码画在电视上，
 * 手机夸克 App 扫一下确认即可。全程不接触账号密码。
 *
 * 轮询节奏 2 秒一次，与云影一致。⛔ 轮询**不刷日志**：
 * `50004001`（还没扫）是正常态，每 2 秒打一行会把 logcat 淹掉。
 */
class LoginActivity : Activity() {

    private lateinit var store: QuarkStore
    private lateinit var login: QuarkQrLogin
    private lateinit var qrImage: ImageView
    private lateinit var status: TextView

    private var session: QuarkQrLogin.Session? = null
    private var stopped = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = QuarkStore(this)
        login = QuarkQrLogin(store)

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

        // 右：说明与状态
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(40), 0, 0, 0)
        }
        col.addView(text("扫码登录夸克网盘", 26f, Color.WHITE))
        col.addView(text("用手机夸克 App 扫描左侧二维码，并在手机上点确认。", 15f, 0xFF9AA3B2.toInt()))
        col.addView(text("全程不接触账号密码，凭证只存在本机。", 13f, 0xFF6B7280.toInt()))
        status = text("正在获取二维码…", 16f, 0xFF7DD3FC.toInt()).apply {
            setPadding(0, dp(24), 0, 0)
        }
        col.addView(status)
        root.addView(col)

        setContentView(root)

        // 已登录就直接进列表（省一次扫码）
        if (store.loggedIn) {
            Log.i(TAG, "已有凭证，跳过登录")
            gotoBrowse()
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
                outcome is QuarkQrLogin.Poll.Confirmed -> {
                    status.text = "已确认，正在换取凭证…"
                    exchange(outcome.ticket)
                }
                outcome is QuarkQrLogin.Poll.Expired -> {
                    // token 过期（超过有效期或 client_id 不匹配）→ 重新取一张
                    status.text = "二维码已过期，正在刷新…"
                    startLogin()
                }
                outcome is QuarkQrLogin.Poll.Error -> {
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
            QuarkApi(store).fetchNickname()
        }) { nick, err ->
            if (stopped) return@run
            if (err != null) {
                status.text = "登录失败：${err.message}"
                status.postDelayed({ if (!stopped) startLogin() }, 2500)
                return@run
            }
            nick?.let { store.nickname = it }
            Log.i(TAG, "登录成功，昵称=${nick ?: "（未取到）"}")
            status.text = "登录成功${if (nick.isNullOrEmpty()) "" else "，$nick"}，正在进入文件列表…"
            status.postDelayed({ if (!stopped) gotoBrowse() }, 600)
        }
    }

    private fun gotoBrowse() {
        startActivity(Intent(this, BrowseActivity::class.java))
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
        const val TAG = "KuakeProto"
        const val POLL_INTERVAL_MS = 2000L
    }
}
