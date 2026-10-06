package com.cloudcine.tv

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.util.Log
import android.util.LruCache
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
import com.cloudcine.tv.library.DeviceIdentity
import com.cloudcine.tv.library.LibraryBackupService
import com.cloudcine.tv.library.LibraryDb
import com.cloudcine.tv.library.LibraryItem
import com.cloudcine.tv.library.LibraryPaths
import com.cloudcine.tv.library.Work
import com.cloudcine.tv.pan.Bg
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.PanApi
import com.cloudcine.tv.pan.formatSize
import java.io.File

/**
 * 媒体库 —— 读**本地索引**（`cloudcine.sqlite`），不是网盘实时目录。
 *
 * ## 与 [BrowseActivity] 的分工
 *
 * | | 数据来源 | 需要联网 |
 * |---|---|---|
 * | 文件列表 | 网盘实时目录 | 要 |
 * | **媒体库** | 同步下来的本地索引 | **不要** |
 *
 * 这个区别是刻意的：库是电脑扫出来、通过备份包同步过来的，所以
 * **断网也能浏览**（只是播不了）。也正因为如此，本页**不检查登录态** ——
 * 检查登录会把「看自己同步下来的库」这件事也一起挡掉。
 *
 * ## 三层结构
 *
 * ```
 * 作品列表  →  OK  →  文件列表（某一部作品下）  →  OK  →  PlayerActivity
 * ```
 *
 * 层级用 [level] 表示，返回键退一层 —— 与 [BrowseActivity] 的目录栈同一个思路：
 * 不自己维护导航栈，少一处「返回键行为诡异」的来源。
 *
 * ## 菜单（MENU 键）
 *
 * 同步 / 上传备份 / 从网盘恢复 / 排序 / 只看未看完 —— 前三个需要登录态，
 * 点的时候才检查。**「从网盘恢复」是破坏性的**，走二次确认。
 */
class LibraryActivity : Activity() {

    // ── 依赖 ────────────────────────────────────────────────────────
    private lateinit var store: CredStore
    private lateinit var api: PanApi
    private lateinit var db: LibraryDb
    private lateinit var service: LibraryBackupService
    private lateinit var posterDir: File

    // ── 视图 ────────────────────────────────────────────────────────
    private lateinit var listView: ListView
    private lateinit var title: TextView
    private lateinit var status: TextView
    private lateinit var root: FrameLayout
    private lateinit var overlay: LinearLayout
    private lateinit var overlayTitle: TextView
    private lateinit var overlayRowsBox: LinearLayout
    private lateinit var overlayScrim: FrameLayout

    // ── 状态 ────────────────────────────────────────────────────────
    private enum class Level { WORKS, ITEMS }

    private var level = Level.WORKS
    private var currentWork: Work? = null
    private var sort = LibraryDb.Sort.recentModified
    private var playedOnly = false
    private var busy = false

    private val works = ArrayList<Work>()
    private val items = ArrayList<LibraryItem>()
    private lateinit var adapter: RowAdapter

    /** 覆盖层（菜单 / 确认框）的状态。可见时按键全部由 [dispatchKeyEvent] 接管。 */
    private var overlayVisible = false
    private var overlayIndex = 0
    private var overlayLabels: List<String> = emptyList()
    private var overlayOnPick: ((Int) -> Unit)? = null

    /** 海报缩略图缓存。电视只有 512 MB Java 堆，必须封顶。 */
    private val posters = object : LruCache<String, Bitmap>(POSTER_CACHE_BYTES) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        store = CredStore(this)
        api = PanApi(store)
        posterDir = LibraryPaths.posterDir(this)
        db = LibraryDb(LibraryPaths.dbFile(this))
        service = LibraryBackupService(
            db = db,
            api = api,
            posterDir = posterDir,
            deviceId = DeviceIdentity.id(this),
            deviceName = DeviceIdentity.name(),
        )

        root = FrameLayout(this).apply { setBackgroundColor(BG) }
        root.addView(buildContent(), matchParent())
        root.addView(buildOverlay(), matchParent())
        setContentView(root)

        loadWorks()
    }

    override fun onDestroy() {
        super.onDestroy()
        // ⛔ 必须关：留着连接的话，下次 `rawBytes()` 会读到一份「少最后几次写入」
        //    的库（理由见 `LibraryDb.rawBytes` 的文档）。
        runCatching { db.close() }
    }

    private fun buildContent(): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

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
        head.addView(title, LinearLayout.LayoutParams(0, WRAP, 1f))
        column.addView(head)

        status = TextView(this).apply {
            setTextColor(MUTED)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(dp(48), 0, dp(48), dp(8))
        }
        column.addView(status)

        adapter = RowAdapter()
        listView = ListView(this).apply {
            adapter = this@LibraryActivity.adapter
            divider = null
            dividerHeight = 0
            setBackgroundColor(BG)
            setOnItemClickListener { _, _, position, _ -> onRow(position) }
            isFocusable = true
            isFocusableInTouchMode = true
        }
        column.addView(listView, LinearLayout.LayoutParams(MATCH, 0, 1f))

        column.addView(TextView(this).apply {
            text = "↑↓ 选择 · OK 播放 · 返回 上一层 · 菜单 备份/同步"
            setTextColor(0xFF6B7280.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(48), dp(6), dp(48), dp(20))
        })
        return column
    }

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
            FrameLayout.LayoutParams(dp(520), WRAP).apply { gravity = Gravity.CENTER },
        )
        return scrim.also { this.overlayScrim = it }
    }

    // ------------------------------------------------------------------
    // 读库
    // ------------------------------------------------------------------

    private fun loadWorks(keepStatus: String? = null) {
        if (keepStatus == null) status.text = "读取媒体库…"
        // ⛔ 两个查询都放在**同一个后台任务**里。`hasContent()` 也是查库，
        //    挪到下面的回调里（那个回调在主线程）会在主线程上读 SQLite。
        Bg.run({
            db.listWorks(sort = sort, playedOnly = playedOnly) to db.hasContent()
        }) { result, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                Log.e(TAG, "读媒体库失败", err)
                return@run
            }
            val list = result?.first ?: emptyList()
            val hasContent = result?.second ?: false
            works.clear()
            works.addAll(list)
            level = Level.WORKS
            currentWork = null
            adapter.notifyDataSetChanged()
            title.text = "媒体库"
            status.text = keepStatus ?: when {
                works.isEmpty() && hasContent ->
                    "没有符合条件的作品（「只看未看完」开着？）"
                works.isEmpty() ->
                    "媒体库是空的 —— 用「菜单 → 从网盘恢复」把电脑上的库同步下来"
                else -> "共 ${works.size} 部作品 · 排序：${sort.label}" +
                    if (playedOnly) " · 只看未看完" else ""
            }
            listView.setSelection(0)
            listView.requestFocus()
        }
    }

    private fun openWork(w: Work) {
        status.text = "读取「${w.title}」…"
        Bg.run({ db.itemsForWork(w.key) }) { list, err ->
            if (err != null) {
                status.text = "读取失败：${err.message}"
                return@run
            }
            items.clear()
            items.addAll(list ?: emptyList())
            level = Level.ITEMS
            currentWork = w
            adapter.notifyDataSetChanged()
            title.text = "媒体库 / ${w.title}"
            status.text = "${w.title} · ${items.size} 个文件" +
                (w.subtitle.takeIf { it.isNotEmpty() }?.let { " · $it" } ?: "")
            listView.setSelection(0)
            listView.requestFocus()
        }
    }

    /** 回到作品列表。返回键在 [Level.ITEMS] 上会调它。 */
    private fun backToWorks() {
        level = Level.WORKS
        currentWork = null
        items.clear()
        loadWorks()
    }

    // ------------------------------------------------------------------
    // 点播
    // ------------------------------------------------------------------

    private fun onRow(position: Int) {
        when (level) {
            Level.WORKS -> works.getOrNull(position)?.let { openWork(it) }
            Level.ITEMS -> items.getOrNull(position)?.let { play(it) }
        }
    }

    /**
     * 交给 [PlayerActivity] 起播。
     *
     * ⛔ `EXTRA_PDIR` 必须给：播放页靠它扫**同目录**的外挂字幕。库里的
     *    `dir_id` 就是电脑扫描时记下的父目录 fid —— 单个文件的 fid
     *    **推不出**父目录，网盘也没有「查父目录」的接口。
     */
    private fun play(item: LibraryItem) {
        startActivity(
            Intent(this, PlayerActivity::class.java)
                .putExtra(PlayerActivity.EXTRA_FID, item.fileId)
                .putExtra(PlayerActivity.EXTRA_NAME, item.name)
                .putExtra(PlayerActivity.EXTRA_HEADERS, store.requestCookie())
                .putExtra(PlayerActivity.EXTRA_PDIR, item.dirId),
        )
    }

    // ------------------------------------------------------------------
    // 覆盖层
    // ------------------------------------------------------------------

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
            titleText = "媒体库",
            labels = listOf(
                "同步（本地 ↔ 网盘）",
                "上传备份到网盘",
                "从网盘恢复（覆盖本地）",
                "排序：${sort.label}",
                if (playedOnly) "只看未看完：开" else "只看未看完：关",
                "返回文件列表",
            ),
        ) { index ->
            when (index) {
                0 -> { hideOverlay(); doSync() }
                1 -> { hideOverlay(); doUpload() }
                2 -> { hideOverlay(); confirmRestore() }
                3 -> {
                    sort = LibraryDb.Sort.entries[(sort.ordinal + 1) % LibraryDb.Sort.entries.size]
                    hideOverlay()
                    loadWorks()
                }
                4 -> {
                    playedOnly = !playedOnly
                    hideOverlay()
                    loadWorks()
                }
                else -> {
                    hideOverlay()
                    startActivity(Intent(this, BrowseActivity::class.java))
                    finish()
                }
            }
        }
    }

    private fun confirmRestore() {
        showOverlay(
            titleText = "用网盘上的最新备份覆盖本地媒体库？\n（本机没上传过的改动会丢失）",
            labels = listOf("取消", "确认恢复"),
        ) { index ->
            hideOverlay()
            if (index == 1) doRestore()
        }
    }

    // ------------------------------------------------------------------
    // 备份 / 同步
    // ------------------------------------------------------------------

    /** 三个备份动作共用的前置检查：**只有它们**需要登录态。 */
    private fun requireLogin(): Boolean {
        if (store.loggedIn) return true
        status.text = "需要先登录网盘（返回 → 菜单 → 重新登录）"
        return false
    }

    private fun guard(what: String): Boolean {
        if (busy) {
            status.text = "正在${busyWhat}，请稍候…"
            return false
        }
        if (!requireLogin()) return false
        busy = true
        busyWhat = what
        status.text = "$what…"
        return true
    }

    private var busyWhat = ""

    private fun finishJob(message: String) {
        busy = false
        busyWhat = ""
        status.text = message
    }

    private fun doSync() {
        if (!guard("同步")) return
        Bg.run({
            service.sync(onProgress = { sent, total ->
                runOnUiThread { status.text = "同步：上传 $sent/$total" }
            })
        }) { out, err ->
            if (err != null) {
                Log.e(TAG, "同步失败", err)
                finishJob("同步失败：${err.message}")
                return@run
            }
            // ⛔ 无论上传还是恢复，都要重读列表：恢复会换掉整个库，
            //    上传虽然不动本地，但「最近修改」的时间戳变了、排序会变。
            finishJob(out?.message ?: "同步完成")
            loadWorks()
        }
    }

    private fun doUpload() {
        if (!guard("打包并上传")) return
        Bg.run({
            val bytes = service.exportBackup(includePosters = true, includeSettings = true)
            service.uploadBackup(bytes, onProgress = { sent, total ->
                runOnUiThread { status.text = "上传 $sent/$total 字节" }
            })
        }) { fid, err ->
            if (err != null) {
                Log.e(TAG, "上传备份失败", err)
                finishJob("上传失败：${err.message}")
                return@run
            }
            finishJob("已上传到网盘备份目录（fid=$fid）")
        }
    }

    private fun doRestore() {
        if (!guard("从网盘恢复")) return
        Bg.run({ service.restoreLatest() }) { latest, err ->
            if (err != null) {
                Log.e(TAG, "从网盘恢复失败", err)
                finishJob("恢复失败：${err.message}")
                return@run
            }
            if (latest == null) {
                finishJob("网盘备份目录里还没有任何备份")
                return@run
            }
            finishJob("已恢复「${latest.name}」（${formatSize(latest.sizeBytes)}）")
            loadWorks()
        }
    }

    // ------------------------------------------------------------------
    // 按键
    // ------------------------------------------------------------------

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)

        if (overlayVisible) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    overlayIndex = (overlayIndex + 1) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_UP -> {
                    overlayIndex = (overlayIndex + overlayLabels.size - 1) % overlayLabels.size
                    paintOverlaySelection()
                    return true
                }
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                -> {
                    overlayOnPick?.invoke(overlayIndex)
                    return true
                }
                // ⛔ 返回 / MENU 都是「关掉菜单」，不是「执行当前项」。
                //    菜单里有一项是不可逆的（从网盘恢复），手滑代价太大。
                KeyEvent.KEYCODE_BACK,
                KeyEvent.KEYCODE_MENU,
                -> {
                    hideOverlay()
                    return true
                }
            }
            return true // 菜单开着时吞掉其它按键，别让底下的列表跟着动
        }

        when (event.keyCode) {
            KeyEvent.KEYCODE_MENU -> {
                openMenu()
                return true
            }
            KeyEvent.KEYCODE_BACK -> if (level == Level.ITEMS) {
                backToWorks()
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    // ------------------------------------------------------------------
    // 列表渲染
    // ------------------------------------------------------------------

    private inner class RowAdapter : BaseAdapter() {
        override fun getCount() = if (level == Level.WORKS) works.size else items.size
        override fun getItem(position: Int) = position.toLong()
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val row = (convertView as? LinearLayout) ?: LinearLayout(this@LibraryActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(48), dp(10), dp(48), dp(10))
            }
            val thumb = row.getChildAt(0) as? ImageView
                ?: ImageView(this@LibraryActivity).apply {
                    scaleType = ImageView.ScaleType.CENTER_CROP
                    setBackgroundColor(0xFF232833.toInt())
                    row.addView(this, LinearLayout.LayoutParams(dp(46), dp(68)))
                }
            val column = row.getChildAt(1) as? LinearLayout
                ?: LinearLayout(this@LibraryActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(14), 0, 0, 0)
                    row.addView(this, LinearLayout.LayoutParams(0, WRAP, 1f))
                }
            val line1 = column.getChildAt(0) as? TextView
                ?: TextView(this@LibraryActivity).apply {
                    setTextColor(Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                    column.addView(this)
                }
            val line2 = column.getChildAt(1) as? TextView
                ?: TextView(this@LibraryActivity).apply {
                    setTextColor(MUTED)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    maxLines = 1
                    column.addView(this)
                }

            if (level == Level.WORKS) {
                val w = works[position]
                line1.text = w.title
                line2.text = w.subtitle.ifEmpty { formatSize(w.totalBytes) }
                bindPoster(thumb, w)
            } else {
                // ⛔ 别把这个局部变量叫 `it`：下面 `?.let { … }` 的隐式参数
                //    也叫 `it`，两层同名会让「这行用的是哪个」纯靠规则推断，
                //    读代码时极易看错。
                val entry = items[position]
                thumb.setImageDrawable(null)
                thumb.visibility = View.GONE
                line1.text = entry.episodeTag?.let { tag -> "$tag  ${entry.displayTitle}" }
                    ?: entry.displayTitle
                line2.text = buildString {
                    entry.resolution?.takeIf { r -> r.isNotEmpty() }?.let { append("$it ") }
                    append(formatSize(entry.sizeBytes ?: 0L))
                    val resume = entry.resumePositionMs
                    if (resume != null && resume > 0) {
                        append(" · 看到 ${clock(resume)}")
                    }
                }
            }

            // ⛔ 选中态必须自己画：`divider = null` 时 ListView 不改行背景，
            //    遥控器上就是「按了没反应」。
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

    /**
     * 海报缩略图。
     *
     * `media_works.poster_file` 存的是**缓存目录里的文件名**（电脑刮削时写的），
     * 直接开 `posterDir/<poster_file>` 就行 —— 不需要重算 PC 端那套
     * `作品键_散列.jpg` 的命名规则。
     *
     * ⛔ 解码**绝不能在主线程做**（`getView` 就在主线程上）。命中缓存才画，
     *    没命中就后台解码、好了再刷一行。
     */
    private fun bindPoster(view: ImageView, w: Work) {
        val name = w.posterFile?.takeIf { it.isNotBlank() } ?: run {
            view.setImageDrawable(null)
            return
        }
        posters.get(name)?.let {
            view.setImageBitmap(it)
            return
        }
        view.setImageDrawable(null)
        if (!posterDir.isDirectory) return
        val file = File(posterDir, name)
        if (!file.isFile) return
        Bg.run({ decodePoster(file) }) { bitmap, err ->
            if (bitmap == null || err != null) return@run
            posters.put(name, bitmap)
            // 只刷新可见行；这里不做「定位到哪一行」，因为列表可能已经换了内容。
            listView.invalidateViews()
        }
    }

    private fun decodePoster(file: File): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= THUMB_TARGET_PX) sample *= 2
        return runCatching {
            BitmapFactory.decodeFile(
                file.absolutePath,
                BitmapFactory.Options().apply { inSampleSize = sample },
            )
        }.getOrNull()
    }

    /** `1:23:45` / `12:34` —— 续播位置用，比「1234567 毫秒」有用。 */
    private fun clock(ms: Long): String {
        val total = ms / 1000
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

    private fun matchParent() = FrameLayout.LayoutParams(MATCH, MATCH)

    private companion object {
        const val TAG = "CloudCine"

        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        const val BG = 0xFF101216.toInt()
        const val MUTED = 0xFF9AA3B2.toInt()
        const val BRAND_TINT = 0xFFA9A3F5.toInt()
        const val BRAND_SELECT = 0xFF332C63.toInt()

        /** 缩略图目标宽度（px）：46dp 在 1.5x 密度下约 69px，留到 96 足够清晰。 */
        const val THUMB_TARGET_PX = 96

        /** 海报缓存上限。电视只有 512 MB Java 堆，且 46×68dp 的缩略图本身很小。 */
        const val POSTER_CACHE_BYTES = 6 * 1024 * 1024
    }
}
