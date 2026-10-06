package com.cloudcine.cloudcine

import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 云影的主 Activity。
 *
 * ## 为什么这里要管一个 OSD
 *
 * 云影的 TV 播放菜单原本是 Flutter widget（`PlayerTvOverlay`）。真机实测
 * 出一个结构性差距：那个菜单在 `ListenableBuilder(listenable: controller)`
 * 里，播放进度每 tick 都重建整棵页面树，而 Dart 主 isolate 同时还在跑本地
 * 中继（TLS 握手 / 解密 / 分块拷贝全在那条线程上）。结果按一次菜单键要
 * **524 ms** 才上屏（原型是 0.3~8.3 ms）。
 *
 * 所以这里照夸克原型（`prototype/kuake`）的做法，把菜单换成**原生 View**
 * （[TvOsdView]）：它作为独立图层挂在 FlutterView 之上，按键与重绘完全
 * 不经过 Dart —— 中继再忙也不影响它。
 *
 * ## 职责边界
 *
 * ⛔ 这个类**不做播放决策**。它只负责：
 *   1. 把 Dart 递过来的行数据（`show` 的 `payload`）转成 [TvOsdView.Row]；
 *   2. 显示 / 隐藏那块 View；
 *   3. OSD 可见时把按键喂给它，不可见时**原样交回 Flutter**；
 *   4. 把「用户按了 OK」和「用户要求关闭」回传 Dart。
 *
 * 行数据由 `lib/ui/widgets/player_tv_rows.dart` 的 `buildPlayerTvRows`
 * 生成 —— 与 Flutter 版菜单是**同一份**。
 */
class MainActivity : FlutterActivity() {

    private var osd: TvOsdView? = null
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { ch ->
                ch.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "show" -> {
                            val payload = call.argument<Map<String, Any?>>("payload")
                            // 返回「原生侧有没有接住」：Dart 那边据此决定是
                            // 退回 Flutter 版菜单，还是什么都不做。
                            result.success(showOsd(payload))
                        }
                        "hide" -> {
                            // ⛔ 不回调 onClose：这是 Dart 自己的决定，
                            //    回传会让播放页把「已经关掉」再处理一遍。
                            hideOsd(notify = false)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }
    }

    // ------------------------------------------------------------------
    // OSD
    // ------------------------------------------------------------------

    /** @return 原生侧有没有接住（false = 拿不到内容视图，Dart 要退回 Flutter 版菜单）。 */
    private fun showOsd(payload: Map<String, Any?>?): Boolean {
        val view = ensureOsd() ?: return false

        val rawRows = payload?.get("rows") as? List<*>
        val startRow = (payload?.get("selectedRow") as? Number)?.toInt() ?: 0
        val rows = rawRows.orEmpty().mapNotNull { it.toOsdRow() }

        view.bind(rows, startRow)
        view.visibility = View.VISIBLE
        Log.i(TAG, "OSD 显示：${rows.size} 行，起始行 $startRow")
        return true
    }

    private fun hideOsd(notify: Boolean) {
        val view = osd ?: return
        if (view.visibility != View.VISIBLE) return
        view.visibility = View.GONE
        Log.i(TAG, "OSD 隐藏（notify=$notify）")
        if (notify) channel?.invokeMethod("onClose", null)
    }

    /**
     * 懒建 + 挂到内容视图之上。
     *
     * ⛔ 必须挂 `android.R.id.content`（FlutterView 的父容器）而不是别的：
     * `setContentView` 把 FlutterView 塞进那个 FrameLayout，后加的兄弟
     * 自然盖在它上面。挂到 FlutterView **里面**是不行的 —— 那等于又变成
     * 一个 Flutter 平台视图，白折腾。
     */
    private fun ensureOsd(): TvOsdView? {
        osd?.let { return it }
        val root = findViewById<ViewGroup>(android.R.id.content)
        if (root == null) {
            // 走到这里 Dart 那边会退回 Flutter 版菜单 —— 但那是「降级」，
            // 必须留痕，否则「电视上菜单变成 Flutter 版了」没人查得到原因。
            Log.w(TAG, "找不到 android.R.id.content，原生 OSD 无法挂载")
            return null
        }
        val view = TvOsdView(this).apply {
            visibility = View.GONE
            onActivate = { row, chip ->
                Log.i(TAG, "OSD 激活：行 $row 第 $chip 颗")
                // 云影的菜单是「选完就收起」（见 `PlayerTvOverlay._activate`），
                // 所以这里立刻藏起来，不等 Dart 处理完 —— 否则中继一忙，
                // 用户按了 OK 之后菜单会僵在原地。
                hideOsd(notify = false)
                channel?.invokeMethod(
                    "onActivate",
                    mapOf("row" to row, "chip" to chip),
                )
            }
            onClose = { hideOsd(notify = true) }
        }
        root.addView(
            view,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        osd = view
        return view
    }

    // ------------------------------------------------------------------
    // 按键
    // ------------------------------------------------------------------

    /**
     * ⛔ 用 `dispatchKeyEvent` 而不是给 View 挂 `OnKeyListener`：遥控器的按键
     * 必须**先**在 Activity 这一层被看到。OSD 是自绘的、里面没有可遍历的
     * 焦点节点 —— 交给焦点系统就会变成云影踩过的那个坑「菜单能弹出来，
     * 但上下键按不动」。
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val view = osd
        if (view == null || view.visibility != View.VISIBLE) {
            return super.dispatchKeyEvent(event)
        }

        // ⛔ 只认 `ACTION_DOWN`。遥控器**长按连发**在 Android TV 上本来就是
        //    一串独立的 `ACTION_DOWN`，收 `ACTION_MULTIPLE`（已 deprecated）
        //    只会多出一条没用的分支。up 也要吞掉 —— 不能让 Flutter 收到一个
        //    没有对应 down 的 up。
        if (event.action != KeyEvent.ACTION_DOWN) return true

        if (view.onKey(event.keyCode)) return true
        when (event.keyCode) {
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_MENU -> {
                hideOsd(notify = true)
                return true
            }
        }
        // OSD 开着时，别的键也吞掉，避免误触播放控制。
        return true
    }

    // ------------------------------------------------------------------

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        osd = null
        super.onDestroy()
    }

    private fun Any?.toOsdRow(): TvOsdView.Row? {
        val m = this as? Map<*, *> ?: return null
        return TvOsdView.Row(
            label = m["label"] as? String ?: "",
            value = m["value"] as? String ?: "",
            options = (m["options"] as? List<*>)?.map { it as? String ?: "" }.orEmpty(),
            enabled = (m["enabled"] as? List<*>)?.map { it as? Boolean ?: true }.orEmpty(),
            vertical = m["vertical"] as? Boolean ?: false,
            hint = m["hint"] as? String,
            selected = (m["selected"] as? Number)?.toInt() ?: 0,
        )
    }

    private companion object {
        const val CHANNEL = "cloudcine/tv_osd"

        /// ⛔ 不是调试残留：小米电视上**有硬件视频层时 `screencap` 抓回来是全黑**，
        /// 原生 OSD 的显示 / 隐藏 / 激活只能靠 logcat 验证。
        const val TAG = "CloudCineOsd"
    }
}
