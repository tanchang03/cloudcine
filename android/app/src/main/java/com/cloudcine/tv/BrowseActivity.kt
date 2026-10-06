package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.DriveEntry
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.formatSize

/**
 * 文件列表 —— 「文件列表」这一块的唯一实现。
 *
 * 刻意用框架自带的 `ListView`：它**天生支持 D-pad**（上下移动选中项、
 * OK 触发 `onItemClick`），不需要 RecyclerView（那还得引
 * `androidx.recyclerview`，本机 Gradle 缓存里没有）。
 *
 * 目录栈是本地维护的（`fid` + 显示名），返回键弹一层 ——
 * 不调任何「取父目录」的接口，少一次往返也少一个出错点。
 */
class BrowseActivity : Activity() {

    private lateinit var store: CredStore
    private lateinit var api: PanApi
    private lateinit var listView: ListView
    private lateinit var title: TextView
    private lateinit var status: TextView

    private lateinit var overlay: LinearLayout
    private lateinit var overlayTitle: TextView
    private lateinit var overlayRowsBox: LinearLayout
    private lateinit var overlayScrim: FrameLayout

    /**
     * 覆盖层（菜单）的状态。可见时方向键 / OK / 返回**全部**由
     * [dispatchKeyEvent] 接管 —— 不走焦点系统，因为电视遥控器的焦点
     * 遍历在动态加进去的 View 上不可控（`TvOsdView` 同一套做法）。
     */
    private var overlayVisible = false
    private var overlayIndex = 0
    private var overlayLabels: List<String> = emptyList()
    private var overlayOnPick: ((Int) -> Unit)? = null

    private val stack = ArrayList<Pair<String, String>>() // (fid, 显示名)
    private val entries = ArrayList<DriveEntry>()
    private lateinit var adapter: EntryAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = CredStore(this)
        api = PanApi(store)

        if (!store.loggedIn) {
            startActivity(Intent(this, LoginActivity::class.java))
            finish()
            return
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101216"))
        }

        // 页头：品牌图标 + 面包屑。图标放在这一行的最左，是列表页唯一的
        // 品牌露出位（页面本身只有文字，不放就完全看不出是哪个 App）。
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(48), dp(24), dp(48), dp(4))
        }
        head.addView(
            ImageView(this).apply { setImageResource(R.mipmap.ic_launcher) },
            LinearLayout.LayoutParams(dp(34), dp(34)),
        )
        title = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            setPadding(dp(12), 0, 0, 0)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.START
        }
        head.addView(
            title,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        column.addView(head)

        status = TextView(this).apply {
            setTextColor(0xFF9AA3B2.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(48), 0, dp(48), dp(8))
        }
        column.addView(status)

        adapter = EntryAdapter()
        listView = ListView(this).apply {
            adapter = this@BrowseActivity.adapter
            divider = null
            dividerHeight = 0
            setBackgroundColor(Color.parseColor("#101216"))
            setOnItemClickListener { _, _, position, _ -> onEntry(entries[position]) }
            isFocusable = true
            isFocusableInTouchMode = true
        }
        column.addView(listView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f,
        ))

        column.addView(TextView(this).apply {
            text = "↑↓ 选择 · OK 进入/播放 · 返回 上一层 · 菜单 更多"
            setTextColor(0xFF6B7280.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(48), dp(6), dp(48), dp(20))
        })

        // 菜单用覆盖层而不是弹 Dialog：Dialog 会另起一个 Window，遥控器焦点
        // 会跑到新 Window 上，返回键也要多按一次；覆盖层留在本 Window 里，
        // 按键全部由 dispatchKeyEvent 直接分派。
        val frame = FrameLayout(this).apply { setBackgroundColor(Color.parseColor("#101216")) }
        frame.addView(
            column,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        frame.addView(
            buildOverlay(),
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ),
        )
        setContentView(frame)

        open(PanApi.ROOT, "云影")
    }

    // ------------------------------------------------------------------
    // 覆盖层菜单
    // ------------------------------------------------------------------

    private fun buildOverlay(): View {
        val scrim = FrameLayout(this).apply {
            setBackgroundColor(0xB3000000.toInt())
            isClickable = true
            visibility = View.GONE
        }
        overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(0xFF1B1F27.toInt())
                setStroke(dp(1), 0xFF3A4150.toInt())
            }
            setPadding(dp(28), dp(22), dp(28), dp(18))
        }
        overlayTitle = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(0, 0, 0, dp(10))
        }
        overlay.addView(overlayTitle)
        overlayRowsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        overlay.addView(overlayRowsBox)

        scrim.addView(
            overlay,
            FrameLayout.LayoutParams(dp(520), ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.CENTER
            },
        )
        overlayScrim = scrim
        return scrim
    }

    private fun showOverlay(titleText: String, labels: List<String>, onPick: (Int) -> Unit) {
        overlayTitle.text = titleText
        overlayLabels = labels
        overlayOnPick = onPick
        overlayIndex = 0
        overlayRowsBox.removeAllViews()
        for (label in labels) {
            overlayRowsBox.addView(TextView(this).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setPadding(dp(14), dp(11), dp(14), dp(11))
                text = label
            })
        }
        paintOverlaySelection()
        overlayScrim.visibility = View.VISIBLE
        overlayVisible = true
    }

    private fun paintOverlaySelection() {
        for (i in 0 until overlayRowsBox.childCount) {
            val v = overlayRowsBox.getChildAt(i) as TextView
            v.setBackgroundColor(if (i == overlayIndex) BRAND_SELECT else Color.TRANSPARENT)
            v.setTextColor(if (i == overlayIndex) BRAND_TINT else Color.WHITE)
        }
    }

    private fun hideOverlay() {
        overlayScrim.visibility = View.GONE
        overlayVisible = false
        overlayOnPick = null
        overlayLabels = emptyList()
        listView.requestFocus()
    }

    private fun openMenu() {
        showOverlay(
            titleText = "云影",
            labels = listOf("媒体库", "重新登录"),
        ) { index ->
            when (index) {
                // 媒体库读的是**同步下来的本地索引**，不需要登录态；
                // 进页面后再按菜单做「同步 / 上传备份 / 从网盘恢复」。
                0 -> {
                    hideOverlay()
                    startActivity(Intent(this, LibraryActivity::class.java))
                }
                else -> {
                    // 重新登录：清凭证回登录页。本 App 上「退出登录」的唯一入口。
                    hideOverlay()
                    store.clear()
                    startActivity(Intent(this, LoginActivity::class.java))
                    finish()
                }
            }
        }
    }

    // ------------------------------------------------------------------

    private fun open(fid: String, name: String) {
        status.text = "加载中…"
        Bg.run({ api.listDirectory(fid) }) { list, err ->
            if (err != null) {
                status.text = "加载失败：${err.message}"
                Log.e(TAG, "列目录失败", err)
                return@run
            }
            val data = list ?: emptyList()
            stack.add(fid to name)
            entries.clear()
            // 目录在前、文件在后；组内保持服务端给的顺序（更新时间倒序）。
            entries.addAll(data.filter { it.isDir })
            entries.addAll(data.filter { !it.isDir })
            adapter.notifyDataSetChanged()
            title.text = stack.joinToString(" / ") { it.second }
            status.text = "共 ${entries.size} 项（目录 ${entries.count { it.isDir }}）"
            listView.setSelection(0)
            listView.requestFocus()
        }
    }

    private fun onEntry(e: DriveEntry) {
        when {
            e.isDir -> open(e.fid, e.name)
            e.isVideo -> startActivity(
                Intent(this, PlayerActivity::class.java)
                    .putExtra(PlayerActivity.EXTRA_FID, e.fid)
                    .putExtra(PlayerActivity.EXTRA_NAME, e.name)
                    .putExtra(PlayerActivity.EXTRA_HEADERS, store.requestCookie())
                    // ⛔ 把**当前目录**的 fid 一起带过去 —— 播放页靠它扫同目录的
                    //    外挂字幕。单个文件的 fid 推不出父目录，网盘也没有
                    //    「查父目录」的接口，所以只能在这里给。
                    //    目录栈的栈顶就是当前列表，`onEntry` 只会在它上面被调用。
                    .putExtra(PlayerActivity.EXTRA_PDIR, stack.lastOrNull()?.first.orEmpty()),
            )
            e.isSubtitle -> status.text = "字幕文件：${e.name}\n（在视频里用「字幕」那一行选）"
            else -> status.text = "不是视频：${e.name}"
        }
    }

    /** 返回键弹一层目录栈；已在根目录则退出。 */
    private fun goUp(): Boolean {
        if (stack.size <= 1) return false
        stack.removeAt(stack.size - 1)
        val (fid, name) = stack.removeAt(stack.size - 1)
        entries.clear()
        adapter.notifyDataSetChanged()
        open(fid, name)
        return true
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)

        // 覆盖层可见时**独占**按键：上下移动、OK 生效、返回/菜单 关闭。
        // ⛔ 不依赖焦点系统：动态加进 ViewGroup 的 TextView 在电视上
        //    不一定拿得到焦点，`requestFocus()` 也常静默失败。
        if (overlayVisible) {
            if (overlayLabels.isEmpty()) {
                hideOverlay()
                return true
            }
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_UP -> {
                    overlayIndex = (overlayIndex - 1 + overlayLabels.size) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    overlayIndex = (overlayIndex + 1) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                    // ⛔ 先取出来再回调：回调里 `hideOverlay()` 会把
                    //    `overlayOnPick` 置空，直接调用会空指针。
                    val pick = overlayOnPick
                    pick?.invoke(overlayIndex)
                    return true
                }
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_MENU -> {
                    hideOverlay()
                    return true
                }
            }
            // 覆盖层开着时吞掉其它键，避免误触到底层列表。
            return true
        }

        when (event.keyCode) {
            KeyEvent.KEYCODE_BACK -> if (goUp()) return true
            KeyEvent.KEYCODE_MENU -> {
                openMenu()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    // ------------------------------------------------------------------

    private inner class EntryAdapter : BaseAdapter() {
        override fun getCount() = entries.size
        override fun getItem(position: Int) = entries[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val row = (convertView as? LinearLayout) ?: LinearLayout(this@BrowseActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(48), dp(12), dp(48), dp(12))
            }
            val e = entries[position]

            val name = row.getChildAt(0) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                row.addView(this)
            }
            val meta = row.getChildAt(1) as? TextView ?: TextView(this@BrowseActivity).apply {
                setTextColor(0xFF9AA3B2.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.END
                row.addView(this)
            }

            name.text = (if (e.isDir) "▸ " else "  ") + e.name
            meta.text = if (e.isDir) "目录" else formatSize(e.sizeBytes)
            // 目录/视频用不同颜色，遥控器上远看也能分清（品牌紫色系）
            name.setTextColor(
                when {
                    e.isDir -> BRAND_TINT
                    e.isVideo -> Color.WHITE
                    else -> 0xFF6B7280.toInt()
                },
            )
            // 选中态：ListView 默认不改行背景（divider=null 时看不出选中），
            // 这里自己给一层高亮，否则遥控器上「按了没反应」。
            row.setBackgroundColor(
                if (listView.isFocused && listView.selectedItemPosition == position) {
                    BRAND_SELECT
                } else {
                    Color.TRANSPARENT
                },
            )
            return row
        }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private companion object {
        const val TAG = "CloudCine"

        /** 品牌主色 `#7F77DD` 在深底上的可读版本。 */
        const val BRAND_TINT = 0xFFA9A3F5.toInt()

        /** 选中行底色：品牌色的深色调，既要能看出选中、又不能刺眼。 */
        const val BRAND_SELECT = 0xFF332C63.toInt()
    }
}
