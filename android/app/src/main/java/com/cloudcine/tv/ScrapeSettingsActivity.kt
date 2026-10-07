package com.cloudcine.tv

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.cloudcine.tv.library.DoubanScraper
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.LibrarySettings
import com.cloudcine.tv.library.ScrapeProbe
import com.cloudcine.tv.library.TmdbScraper
import com.cloudcine.tv.pan.Bg

/**
 * **刮削设置** —— TMDB Key / 两个反代地址 / 豆瓣 Cookie。
 *
 * ## 这些值存在哪、为什么
 *
 * 存在**媒体库的 `settings` 表**里（不是 `AppPrefs` / SharedPreferences）。
 * 这不是随手选的：备份包（`.ccbak`）里装的是**整个 `cloudcine.sqlite` 文件的
 * 原始字节**，`settings` 表随之一起走。所以：
 *
 *   * 在电脑上填好的 TMDB 反代地址，**同步到电视上直接可用**；
 *   * 反过来，在电视上贴的豆瓣 Cookie，**同步回电脑也不用再贴一遍**。
 *
 * ⛔ 放进 `AppPrefs` 的话这件事就不成立 —— SharedPreferences 在备份包里根本
 *    不存在。键名（[LibrarySettings]）也必须与 PC 端 `SettingKeys` 逐字一致，
 *    差一个字母就是「同步过来了但两边都读不到」，且**不报任何错**。
 *
 * ## 为什么要分开配「API 地址」与「图片地址」
 *
 * 它们是**两个域名**（`api.themoviedb.org` / `image.tmdb.org`），而反代经常
 * 只覆盖其中一个。合成一个的话，「API 通了但图片下不来」（海报全是灰块）
 * 就没法修。
 *
 * ## 按键
 *
 * ↑↓ 在 [navOrder] 那条链上移动 —— 四个输入框 + 两个「测试」按钮 + 「保存」
 * （⛔ 单行 EditText 会自己吃掉 ↑↓，所以这里显式在 [dispatchKeyEvent] 里接管）；
 * OK 在输入框上弹软键盘、在按钮上执行（见 [actionFor]）。
 *
 * ## 为什么有「测试」按钮
 *
 * 凭证填错了，原本唯一的验证方式是「去刮一部看看」—— 而那要等 TMDB 先超时
 * 十来秒，最后只给一句「未命中」。「地址不通 / 凭证被拒 / 被限流」三种完全
 * 不同的原因在结果上长得一模一样，用户只能反复重贴同一个串。
 * 两个按钮把结论直接摆出来，见 [probeTmdb] / [probeDouban]。
 */
class ScrapeSettingsActivity : Activity() {

    private lateinit var db: LibraryDb

    private lateinit var keyBox: EditText
    private lateinit var apiBox: EditText
    private lateinit var imageBox: EditText
    private lateinit var cookieBox: EditText

    private lateinit var tmdbTestButton: TextView
    private lateinit var doubanTestButton: TextView
    private lateinit var tmdbProbeLine: TextView
    private lateinit var doubanProbeLine: TextView

    private lateinit var saveButton: TextView
    private lateinit var status: TextView

    /**
     * ↑↓ 的焦点顺序。
     *
     * ⛔ **不是「四个输入框」而是一份显式清单**：两个「测试」按钮要各自紧跟
     *    在自己测的那组字段后面（测 TMDB 的按钮贴在 TMDB 三个框之后，测豆瓣的
     *    贴在 Cookie 框之后），这个顺序从字段类型推不出来。
     */
    private var navOrder: List<View> = emptyList()

    private var saving = false

    /** 有测试正在跑。⛔ 防连点：两次探测会并发、白白多烧一份豆瓣额度。 */
    private var probing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        db = LibraryDb(LibraryPaths.dbFile(this))

        val scroll = ScrollView(this).apply {
            setBackgroundColor(BG)
            isVerticalScrollBarEnabled = false
        }
        scroll.addView(buildContent(), FrameLayout.LayoutParams(MATCH, WRAP))
        setContentView(scroll)

        loadSettings()
    }

    override fun onDestroy() {
        super.onDestroy()
        runCatching { db.close() }
    }

    // ------------------------------------------------------------------

    private fun buildContent(): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(48), dp(24), dp(48), dp(24))
        }

        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        head.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(30), dp(30)),
        )
        head.addView(
            TextView(this).apply {
                text = "刮削设置"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                setPadding(dp(12), 0, 0, 0)
            },
        )
        column.addView(head)

        column.addView(
            TextView(this).apply {
                text = "这些值存在媒体库里，会随备份包同步到其它设备 —— " +
                    "在电脑上配好的反代地址，同步过来直接可用。"
                setTextColor(FAINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                setPadding(0, dp(8), 0, dp(16))
            },
        )

        keyBox = field(
            column,
            label = "TMDB API Key",
            hint = "留空 = 不启用 TMDB 源",
            note = "在 themoviedb.org 免费申请（v3 或 v4 都接受）。",
        )
        apiBox = field(
            column,
            label = "TMDB API 地址",
            hint = "留空 = ${TmdbScraper.DEFAULT_API_BASE}",
            note = "⚠️ 官方地址在境内不可达（DNS 污染），要用 TMDB 必须填一个" +
                "自建反代的地址。",
        )
        imageBox = field(
            column,
            label = "TMDB 图片地址",
            hint = "留空 = ${TmdbScraper.DEFAULT_IMAGE_BASE}",
            note = "与上面那个是**两个域名**，反代常常只覆盖其中一个 —— " +
                "API 通了但海报全是灰块时，改这里。",
        )
        // 测试按钮紧跟它测的那组字段 —— 结果行也贴着按钮，用户不用来回找。
        tmdbTestButton = probeButton(column, "测试 TMDB 连接") { probeTmdb() }
        tmdbProbeLine = probeLine(column)

        cookieBox = field(
            column,
            label = "豆瓣 Cookie",
            hint = "留空 = 匿名额度（实测约 10 个搜索词）",
            note = "登录 movie.douban.com 后从浏览器复制整条 Cookie。" +
                "留空也能用，只是搜十来次之后会返回 103 need_login（会冷却一段时间）。" +
                "豆瓣接口必带 Referer，这里不用管，代码已经带了。",
        )
        doubanTestButton = probeButton(column, "测试豆瓣 Cookie") { probeDouban() }
        doubanProbeLine = probeLine(column)

        status = TextView(this).apply {
            setTextColor(DIM)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(0, dp(16), 0, dp(10))
            text = "↑↓ 切换 · OK 编辑 / 执行 · 返回 退出"
        }
        column.addView(status)

        val save = TextView(this).apply {
            text = "保存"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setPadding(dp(28), dp(12), dp(28), dp(12))
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { save() }
            setOnFocusChangeListener { _, hasFocus -> paintSaveButton(hasFocus) }
        }
        // ⛔ 赋值与上色**必须分成两步**：`paintSaveButton` 读的就是 `saveButton`
        //    这个 `lateinit` 本身，写在上面那个 `apply` 块里会在**赋值还没发生**
        //    时被调用 ⇒ `UninitializedPropertyAccessException` ⇒ 系统
        //    `Force finishing activity`。用户看到的现象是「点进去立刻弹回上一页、
        //    一句报错都没有」，而不是崩溃弹窗 —— 极难从界面反推。
        saveButton = save
        paintSaveButton(false)
        column.addView(
            saveButton,
            LinearLayout.LayoutParams(dp(160), WRAP).apply { topMargin = dp(18) },
        )

        // ⛔ 这份清单必须在**所有**被它引用的 View 都构造完之后才建。
        //    挪到上面（挨着字段声明写）就会踩同一个 `lateinit` 陷阱：
        //    那时 `saveButton` 还没赋值，`listOf(...)` 里读到它就是
        //    `UninitializedPropertyAccessException`。
        navOrder = listOf(
            keyBox, apiBox, imageBox, tmdbTestButton,
            cookieBox, doubanTestButton,
            saveButton,
        )
        return column
    }

    private fun paintSaveButton(focused: Boolean) {
        saveButton.background = GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(if (focused) BRAND_SOLID else 0x14FFFFFF)
        }
        saveButton.setTextColor(if (focused) 0xFF1A1533.toInt() else 0xFFB9C0CC.toInt())
    }

    // ------------------------------------------------------------------
    // 「测试凭证」
    // ------------------------------------------------------------------

    /**
     * 一个「测试」按钮。
     *
     * ⛔ 与「保存」同一套规矩：`isFocusable` 的普通 View 在电视上靠框架触发
     *    点击**不可靠**，所以 OK 一律在 [dispatchKeyEvent] 里自管（见 [actionFor]）。
     *    这里的 `setOnClickListener` 只服务触摸 / 鼠标。
     */
    private fun probeButton(host: LinearLayout, label: String, run: () -> Unit): TextView {
        val button = TextView(this).apply {
            text = label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            setPadding(dp(22), dp(9), dp(22), dp(9))
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { run() }
            setOnFocusChangeListener { v, hasFocus -> paintProbeButton(v as TextView, hasFocus) }
        }
        paintProbeButton(button, false)
        host.addView(
            button,
            LinearLayout.LayoutParams(dp(220), WRAP).apply { topMargin = dp(10) },
        )
        return button
    }

    private fun paintProbeButton(button: TextView, focused: Boolean) {
        button.background = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setColor(if (focused) BRAND_SOLID else 0x14FFFFFF)
        }
        button.setTextColor(if (focused) 0xFF1A1533.toInt() else 0xFFB9C0CC.toInt())
    }

    /**
     * 一行测试结论。
     *
     * ⛔ 初始就给**空串**而不是 `visibility = GONE`：这一页是纵向 `LinearLayout`，
     *    结论出现 / 消失会让下面的按钮上下跳，遥控器上很别扭。
     */
    private fun probeLine(host: LinearLayout): TextView = TextView(this).apply {
        setTextColor(FAINT)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setPadding(0, dp(8), 0, 0)
        text = ""
        host.addView(this, LinearLayout.LayoutParams(MATCH, WRAP))
    }

    /**
     * 测试 TMDB：**地址通不通** + **Key 对不对**。
     *
     * ⛔ 用输入框里**当前**的值，不是已保存的设置 —— 用户改完还没点「保存」
     *    就想先试试，是最自然的操作顺序。与 PC 端设置页 `_probeTmdb` 同一条。
     */
    private fun probeTmdb() {
        if (probing) return
        probing = true
        hideKeyboard()
        val key = keyBox.text.toString().trim()
        val apiBase = apiBox.text.toString().trim().ifEmpty { TmdbScraper.DEFAULT_API_BASE }
        val imageBase = imageBox.text.toString().trim().ifEmpty { TmdbScraper.DEFAULT_IMAGE_BASE }
        tmdbProbeLine.setTextColor(FAINT)
        tmdbProbeLine.text = "测试中…（最多 10 秒）"
        Bg.run({
            TmdbScraper(apiKey = key, apiBase = apiBase, imageBase = imageBase).probe()
        }) { probe, err ->
            probing = false
            val r = probe ?: ScrapeProbe(false, "测试失败：${err?.message ?: "未知错误"}")
            showProbe(tmdbProbeLine, r)
            Log.i(TAG, "测试 TMDB：${if (r.ok) "通过" else "未通过"} — ${r.message}")
        }
    }

    /**
     * 测试豆瓣 Cookie：**接口通不通** + **是不是登录态** + **有没有被限流**。
     *
     * ⛔ 先拦「把 `Cookie: ` 前缀一起贴进来」这种最常见的错法 —— 它会让服务端
     *    回 103，而 103 看起来像「被限流」，用户会往完全错误的方向查。
     *    与 PC 端 `_probeDouban` 同一条。
     */
    private fun probeDouban() {
        if (probing) return
        val cookie = cookieBox.text.toString().trim()
        if (DoubanScraper.looksLikeRawHeader(cookie)) {
            showProbe(
                doubanProbeLine,
                ScrapeProbe(
                    false,
                    "看起来把 `Cookie: ` 这个前缀也一起贴进来了。" +
                        "只要冒号后面的内容 —— 从 `ll=` 或 `bid=` 开始那一段。",
                ),
            )
            return
        }
        probing = true
        hideKeyboard()
        doubanProbeLine.setTextColor(FAINT)
        doubanProbeLine.text = "测试中…（最多 12 秒）"
        Bg.run({
            DoubanScraper(cookie = cookie).probe()
        }) { probe, err ->
            probing = false
            val r = probe ?: ScrapeProbe(false, "测试失败：${err?.message ?: "未知错误"}")
            showProbe(doubanProbeLine, r)
            Log.i(TAG, "测试豆瓣：${if (r.ok) "通过" else "未通过"} — ${r.message}")
        }
    }

    /**
     * 把结论摆到那一行上。
     *
     * ⛔ 用**文字**（「通过 ·」「未通过 ·」）而不是图标区分成败：`message` 本身
     *    就是给人看的一整句话，加个前缀就能扫到，不必再引一套图标资源。
     */
    private fun showProbe(line: TextView, probe: ScrapeProbe) {
        line.setTextColor(if (probe.ok) OK_GREEN else BAD_RED)
        line.text = (if (probe.ok) "通过 · " else "未通过 · ") + probe.message
    }

    /**
     * 一个带标签 + 说明的输入框，整块挂到 [host] 上，返回里面的 `EditText`。
     *
     * 输入框要交给调用方做 ↑↓ 导航，但「标签/说明」只是排版 —— 所以返回值
     * 是 `EditText` 而不是 `View`。宿主显式传入，不做隐式状态中转。
     */
    private fun field(host: LinearLayout, label: String, hint: String, note: String): EditText {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(10), 0, dp(4))
        }
        col.addView(
            TextView(this).apply {
                text = label
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            },
        )
        val box = EditText(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            isSingleLine = true
            maxLines = 1
            setHint(hint)
            setHintTextColor(FAINT)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(0xFF232936.toInt())
            }
            setOnFocusChangeListener { _, hasFocus ->
                background = GradientDrawable().apply {
                    cornerRadius = dp(10).toFloat()
                    setColor(0xFF232936.toInt())
                    if (hasFocus) setStroke(dp(2), BRAND_TINT)
                }
            }
        }
        col.addView(box, LinearLayout.LayoutParams(MATCH, WRAP))
        col.addView(
            TextView(this).apply {
                text = note
                setTextColor(FAINT)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(0, dp(6), 0, 0)
            },
        )
        // 这一层包装只是为了排版，真正的输入框要交给调用方。
        host.addView(col)
        return box
    }

    // ------------------------------------------------------------------

    private fun loadSettings() {
        status.text = "读取设置…"
        Bg.run({ db.settingsMap() }) { map, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                Log.w(TAG, "读取刮削设置失败", err)
                return@run
            }
            val m = map ?: emptyMap()
            // ⛔ 读出来的可能是**从 PC 端同步过来**的值 —— 这正是本页存在的意义。
            keyBox.setText(m[LibrarySettings.TMDB_API_KEY].orEmpty())
            apiBox.setText(m[LibrarySettings.TMDB_API_BASE].orEmpty())
            imageBox.setText(m[LibrarySettings.TMDB_IMAGE_BASE].orEmpty())
            cookieBox.setText(m[LibrarySettings.DOUBAN_COOKIE].orEmpty())
            val configured = LibrarySettings.SCRAPE_KEYS.count { !m[it].isNullOrBlank() }
            status.text = "当前已填 $configured 项 · ↑↓ 切换输入框 · OK 编辑"
            keyBox.requestFocus()
        }
    }

    private fun save() {
        if (saving) return
        saving = true
        hideKeyboard()
        status.text = "正在保存…"
        // ⛔ 空串也写进去（而不是删行）：空串的语义是「用户明确要求清掉」，
        //    而删行会让「从 PC 端同步过来的旧值」在下次同步时又冒出来。
        val k = keyBox.text.toString().trim()
        val a = apiBox.text.toString().trim()
        val i = imageBox.text.toString().trim()
        val c = cookieBox.text.toString().trim()
        Bg.run({
            db.setSetting(LibrarySettings.TMDB_API_KEY, k)
            db.setSetting(LibrarySettings.TMDB_API_BASE, a)
            db.setSetting(LibrarySettings.TMDB_IMAGE_BASE, i)
            db.setSetting(LibrarySettings.DOUBAN_COOKIE, c)
        }) { _, err ->
            saving = false
            if (err != null) {
                status.text = "保存失败：${err.message}"
                Log.w(TAG, "保存刮削设置失败", err)
                return@run
            }
            val enabled = buildList {
                if (k.isNotEmpty()) add("TMDB")
                if (c.isNotEmpty()) add("豆瓣（登录态额度）")
                if (k.isEmpty() && c.isEmpty()) add("豆瓣（匿名额度）")
            }
            status.text = "已保存：${enabled.joinToString(" + ")} 可用。" +
                "同步一次备份，这些值就会带到其它设备。"
            Log.i(TAG, "刮削设置已保存（TMDB=${k.isNotEmpty()}, 豆瓣=${c.isNotEmpty()}）")
        }
    }

    private fun hideKeyboard() {
        val imm = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager ?: return
        val focused = currentFocus ?: return
        imm.hideSoftInputFromWindow(focused.windowToken, 0)
    }

    // ------------------------------------------------------------------
    // 按键：↑↓ 在输入框之间移动（单行 EditText 会自己吃掉 ↑↓，必须接管）
    // ------------------------------------------------------------------

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val idx = navOrder.indexOfFirst { it.hasFocus() }

        // ── 三个「按 OK 就执行」的按钮（测试 TMDB / 测试豆瓣 / 保存）──
        // ⛔ DOWN 与 UP **都要吞**：只吞 DOWN 的话，焦点系统还会用 UP 再触发一次
        //    点击 ⇒ 测两遍 / 存两次。
        if (idx >= 0 && isCenter(event.keyCode)) {
            val action = actionFor(navOrder[idx])
            if (action != null) {
                if (event.action == KeyEvent.ACTION_DOWN) action.invoke()
                return true
            }
        }

        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)

        if (idx >= 0) {
            when (event.keyCode) {
                // ↓ 走到最后一个就停住。⛔ 不绕回第一个 —— 绕回去会让「到底了」没有手感。
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    if (idx < navOrder.size - 1) navOrder[idx + 1].requestFocus()
                    return true
                }
                // ↑ 走到第一个就吞掉。⛔ 放行的话焦点会跑到页面之外，
                //    用户按 ↑ 看到的是「光标不见了」。
                KeyEvent.KEYCODE_DPAD_UP -> {
                    if (idx > 0) navOrder[idx - 1].requestFocus()
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * 焦点所在的 View 是不是「按 OK 就执行」的按钮；是则返回它的动作。
     *
     * ⛔ 用**显式白名单**，而不是「凡是 TextView 就把 OK 当点击」：输入框也是
     *    View，把 OK 一律当点击会让四个输入框再也弹不出软键盘。
     */
    private fun actionFor(view: View): (() -> Unit)? = when (view) {
        tmdbTestButton -> ({ probeTmdb() })
        doubanTestButton -> ({ probeDouban() })
        saveButton -> ({ save() })
        else -> null
    }

    private fun isCenter(keyCode: Int): Boolean =
        keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
            keyCode == KeyEvent.KEYCODE_ENTER ||
            keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    companion object {
        private const val TAG = "CloudCine"
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        private const val BG = 0xFF101216.toInt()
        private const val DIM = 0xFF9AA3B2.toInt()
        private const val FAINT = 0xFF6B7280.toInt()
        private const val BRAND_TINT = 0xFFA9A3F5.toInt()
        private const val BRAND_SOLID = 0xFF7F77DD.toInt()

        /** 测试结论的颜色。⛔ 只用在结论行上，不参与品牌色。 */
        private const val OK_GREEN = 0xFF5FD08A.toInt()
        private const val BAD_RED = 0xFFFF8A8A.toInt()
    }
}
