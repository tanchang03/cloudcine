package com.cloudcine.tv.library

import android.content.ContentValues
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import java.io.File

/**
 * 媒体库索引库（`cloudcine.sqlite`）的 Android 侧读写入口。
 *
 * ## 它存在的意义只有一条：**与 PC 端共用同一个文件**
 *
 * 不是「一个类似的库」，是**同一个 schema、同一个文件**。PC 端扫描出来的
 * 索引、刮削出来的海报与简介、你标好的片头区间，都会随备份包过来；Android
 * 这边改的播放进度、画质选择，也会随备份包回去。所以：
 *
 *   * ⛔ **不写任何迁移**。Android 不实现 v1→v16 那 15 步 —— 那不是它的活。
 *     打开时只做一件事：把缺失的表 / 列**补上**（见 [ensureSchema]），
 *     然后把 `user_version` 对齐到 16。补列只加名字与类型，不加 `NOT NULL`
 *     （SQLite 不允许给已有表加 `NOT NULL` 且无默认值的列）。
 *   * ⛔ **不用 WAL**。备份包装的是**单个文件的原始字节**，而 WAL 下最新
 *     的数据可能还在 `-wal` 里 —— 那样导出去的库是**旧的**，而且不会有
 *     任何报错。所以显式 `PRAGMA journal_mode=DELETE`。
 *   * ⛔ 时间列一律 **Unix 秒**，与 drift 的 `DateTimeColumn` 口径一致。
 *     写毫秒的话，PC 端会把 1970 年附近的日期当成「最近播放」，排序全乱。
 *
 * ## 线程模型
 *
 * 所有方法都是阻塞的，**调用方负责放到后台线程**（本工程统一用 `Bg`）。
 * `SQLiteDatabase` 自身对多线程是安全的（内部串行化），但 [close] 与
 * 正在跑的查询之间没有保护 —— 只有「恢复备份」那一处会 close，
 * 而它本来就该在没有任何读的时候做（见 `LibraryBackupService.importBackup`）。
 */
class LibraryDb(val file: File) {

    private var db: SQLiteDatabase? = null

    /** 库文件是否已经在磁盘上（= 这台电视同步过 / 扫过库）。 */
    fun exists(): Boolean = file.exists() && file.length() > 0

    /** 打开（必要时建库）。重复调用是幂等的。 */
    @Synchronized
    fun open(): SQLiteDatabase {
        db?.let { if (it.isOpen) return it }
        file.parentFile?.mkdirs()
        val fresh = !exists()
        val opened = SQLiteDatabase.openOrCreateDatabase(file, null)
        // ⛔ 必须在任何写入之前设；见类文档「不用 WAL」。
        opened.rawQuery("PRAGMA journal_mode=DELETE", null).use { it.moveToFirst() }
        opened.rawQuery("PRAGMA foreign_keys=ON", null).use { it.moveToFirst() }
        if (fresh) Log.i(TAG, "索引库不存在，新建：${file.absolutePath}")
        ensureSchema(opened)
        db = opened
        return opened
    }

    @Synchronized
    fun close() {
        db?.let { runCatching { it.close() } }
        db = null
    }

    private fun require(): SQLiteDatabase = db?.takeIf { it.isOpen } ?: open()

    // ------------------------------------------------------------------
    // schema 对齐
    // ------------------------------------------------------------------

    /**
     * 把库补齐到 [LibrarySchema.VERSION]。
     *
     * 两条路：
     *   1. **缺表** → 按 v16 的 DDL 建（`IF NOT EXISTS`，幂等）；
     *   2. **缺列** → `ALTER TABLE ADD COLUMN`。
     *
     * ⛔ 补列时**故意不带 `NOT NULL`**：SQLite 的 `ALTER TABLE ADD COLUMN` 拒绝
     * 「`NOT NULL` 且没有默认值」的列（报 `Cannot add a NOT NULL column with
     * default value NULL`），而 v16 里 `first_seen_at` / `updated_at` 正是这种。
     * 跨端互操作只认**列名与类型**，`NOT NULL` 只是写入期的自我约束 ——
     * 为了这一条把「老库打不开」变成「库打不开」，不划算。
     */
    private fun ensureSchema(d: SQLiteDatabase) {
        val existing = HashSet<String>()
        d.rawQuery("SELECT name FROM sqlite_master WHERE type='table'", null).use { c ->
            while (c.moveToNext()) existing.add(c.getString(0))
        }

        var created = 0
        var added = 0
        for (table in LibrarySchema.TABLES) {
            if (table.name !in existing) {
                d.execSQL(LibrarySchema.createSql(table, ifNotExists = true))
                created++
                continue
            }
            val have = HashSet<String>()
            d.rawQuery("PRAGMA table_info(\"${table.name}\")", null).use { c ->
                while (c.moveToNext()) have.add(c.getString(c.getColumnIndexOrThrow("name")))
            }
            for (col in table.columns) {
                if (col.name in have) continue
                // 去掉 NOT NULL，理由见方法文档。
                val sql = LibrarySchema.addColumnSql(table, col.copy(notNull = false))
                runCatching { d.execSQL(sql) }
                    .onSuccess { added++ }
                    .onFailure { Log.w(TAG, "补列失败：$sql → ${it.message}") }
            }
        }

        val version = userVersion(d)
        if (version != LibrarySchema.VERSION) {
            d.execSQL("PRAGMA user_version=${LibrarySchema.VERSION}")
            Log.i(
                TAG,
                "索引库版本 $version → ${LibrarySchema.VERSION}" +
                    "（补建 $created 张表、$added 列）",
            )
        } else if (created > 0 || added > 0) {
            Log.i(TAG, "索引库已对齐 v${LibrarySchema.VERSION}（补建 $created 表、$added 列）")
        }
    }

    private fun userVersion(d: SQLiteDatabase): Int =
        d.rawQuery("PRAGMA user_version", null).use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        }

    // ------------------------------------------------------------------
    // 读：库状态
    // ------------------------------------------------------------------

    /**
     * 「媒体库最后一次内容变更时间」（Unix 秒）。`null` = 空库。
     *
     * ⛔ 这是**同步的判据**，必须与 PC 端 `latestLibraryChangeAt()` 逐项一致：
     * `media_works.updated_at` 的最大值，并上 `media_items.first_seen_at` 与
     * `media_items.last_played_at` 的最大值。少任何一项都会让「刚播过但还没
     * 重新扫描」的机器被判成「没变过」，从而**在同步时把对方的进度盖掉**。
     *
     * ⚠️ 空库返回 `null` 而不是 0：`null` 的语义是「没有内容，让远程赢」，
     * 而 0 会被当成「1970 年改过」—— 那台新机器就会拿空库去覆盖网盘。
     */
    fun libraryModifiedAt(): Long? {
        val d = require()
        var latest: Long? = null
        d.rawQuery("SELECT MAX(updated_at) FROM media_works", null).use { c ->
            if (c.moveToFirst() && !c.isNull(0)) latest = c.getLong(0)
        }
        d.rawQuery(
            "SELECT MAX(first_seen_at), MAX(last_played_at) FROM media_items",
            null,
        ).use { c ->
            if (c.moveToFirst()) {
                for (i in 0 until 2) {
                    if (c.isNull(i)) continue
                    val v = c.getLong(i)
                    if (latest == null || v > latest!!) latest = v
                }
            }
        }
        return latest
    }

    /** 库里有没有内容（= 作品行 + 媒体项行都不为空）。 */
    fun hasContent(): Boolean {
        val d = require()
        d.rawQuery(
            "SELECT (SELECT COUNT(*) FROM media_works) + " +
                "(SELECT COUNT(*) FROM media_items)",
            null,
        ).use { c -> return c.moveToFirst() && c.getLong(0) > 0 }
    }

    /**
     * 「记住播放进度」开关。**缺失即开**（判据 `!= 'false'`）。
     *
     * ⛔ 写成 `== 'true'` 的后果是「新装 / 刚同步下来的库里没有这一行，
     * 于是永远不记进度」，而设置页上开关是开着的。
     */
    fun rememberProgress(): Boolean {
        val d = require()
        d.rawQuery(
            "SELECT value FROM settings WHERE key = ? LIMIT 1",
            arrayOf(LibrarySchema.KEY_REMEMBER_PROGRESS),
        ).use { c ->
            if (c.moveToFirst()) return c.getString(0) != "false"
        }
        return true
    }

    // ------------------------------------------------------------------
    // 读：列表 / 详情
    // ------------------------------------------------------------------

    /** 作品列表排序。 */
    enum class Sort(val label: String) {
        recentModified("最近修改"),
        recentAdded("最近添加"),
        recentPlayed("最近播放"),
        rating("评分"),
        title("标题"),
    }

    /**
     * 取作品列表。
     *
     * ⛔ 必须滤 `merged_into IS NULL`：跨目录归一之后，被折叠的行**不出现**
     * 在列表里（PC 端同一条规则）。漏了这个条件，用户会看到同一部剧的两个格子。
     *
     * 排序的收尾 tie-breaker（`year desc, title asc`）照抄 PC 端
     * `_orderingFor` —— 否则评分相同的一批作品每次刷新都换位置，像列表在乱跳。
     */
    fun listWorks(
        sort: Sort = Sort.recentModified,
        playedOnly: Boolean = false,
        keyword: String? = null,
        limit: Int = 500,
        offset: Int = 0,
    ): List<Work> {
        val where = ArrayList<String>()
        val args = ArrayList<String>()
        where.add("merged_into IS NULL")
        if (playedOnly) where.add("last_played_at IS NOT NULL")
        val kw = keyword?.trim().orEmpty()
        if (kw.isNotEmpty()) {
            where.add("(title LIKE ? OR original_title LIKE ? OR key LIKE ?)")
            val like = "%$kw%"
            args.add(like); args.add(like); args.add(like)
        }

        val order = when (sort) {
            Sort.recentModified -> "last_modified_at DESC, year DESC, title ASC"
            Sort.recentAdded -> "first_seen_at DESC, year DESC, title ASC"
            Sort.recentPlayed -> "last_played_at DESC, year DESC, title ASC"
            Sort.rating -> "rating DESC, year DESC, title ASC"
            Sort.title -> "title ASC"
        }

        val sql = buildString {
            append("SELECT $WORK_COLUMNS FROM media_works")
            append(" WHERE ").append(where.joinToString(" AND "))
            append(" ORDER BY ").append(order)
            append(" LIMIT ").append(limit).append(" OFFSET ").append(offset)
        }
        return queryWorks(sql, args.toTypedArray())
    }

    fun workByKey(key: String): Work? =
        queryWorks("SELECT $WORK_COLUMNS FROM media_works WHERE key = ? LIMIT 1", arrayOf(key))
            .firstOrNull()

    /**
     * 一部作品下的所有文件。
     *
     * 排序：**季 → 部 → 集**，都没标号的排最后。这个顺序就是详情页文件列表的
     * 顺序，也是「自动连播下一集」的依据。
     */
    fun itemsForWork(key: String): List<LibraryItem> =
        queryItems(
            "SELECT $ITEM_COLUMNS FROM media_items WHERE group_key = ? " +
                "ORDER BY (season IS NULL), season, (part IS NULL), part, " +
                "(episode IS NULL), episode, name",
            arrayOf(key),
        )

    fun itemById(id: String): LibraryItem? =
        queryItems("SELECT $ITEM_COLUMNS FROM media_items WHERE id = ? LIMIT 1", arrayOf(id))
            .firstOrNull()

    /**
     * 「继续观看」：最近播过、且**没看完**的那一条。
     *
     * 判据与 PC 端一致：`resume_position_ms IS NOT NULL`（看完的会被清成 NULL）
     * 且 `duration_ms` 已知。`null` = 没有可续的。
     */
    fun lastUnfinished(): Pair<LibraryItem, Work>? {
        val item = queryItems(
            "SELECT $ITEM_COLUMNS FROM media_items " +
                "WHERE resume_position_ms IS NOT NULL AND last_played_at IS NOT NULL " +
                "ORDER BY last_played_at DESC LIMIT 1",
            emptyArray(),
        ).firstOrNull() ?: return null
        val work = workByKey(item.groupKey) ?: return null
        return item to work
    }

    // ------------------------------------------------------------------
    // 写：播放记录
    // ------------------------------------------------------------------

    /**
     * 记一次「播放过」。
     *
     * ⛔ **必须同时写 `media_works.last_played_at`**（PC 端 `markPlayed` 就是
     * 这么做的）。只写媒体项那一列的话，「最近播放」排序里作品级的依据永远是
     * 空的，整部剧会一直垫底。
     */
    fun markPlayed(itemId: String, atSec: Long = nowSec()) {
        val d = require()
        d.update("media_items", ContentValues().apply {
            put("last_played_at", atSec)
        }, "id = ?", arrayOf(itemId))
        val groupKey = queryString(d, "SELECT group_key FROM media_items WHERE id = ?", arrayOf(itemId))
        if (!groupKey.isNullOrEmpty()) {
            d.update("media_works", ContentValues().apply {
                put("last_played_at", atSec)
            }, "key = ?", arrayOf(groupKey))
        }
    }

    /**
     * 写续播位置（毫秒）。`null` / `<= 0` 一律写 `NULL`。
     *
     * ⛔ 不写 0：`NULL` 才是这一列真正的「没有可续的点」。写 0 会让
     * `resumePositions` 里多出一个恒假的值（PC 端 `saveResumePosition` 同口径）。
     */
    fun saveResumePosition(itemId: String, positionMs: Long?) {
        val value: Long? = if (positionMs == null || positionMs <= 0L) null else positionMs
        require().update("media_items", ContentValues().apply {
            if (value == null) putNull("resume_position_ms") else put("resume_position_ms", value)
        }, "id = ?", arrayOf(itemId))
    }

    /**
     * 写「历史最大播放位置」（毫秒，**只增不减**）。
     *
     * ⛔ 只增不减必须由**一条 SQL** 保证。拆成「先读、再比、再写」的话，
     * 两个来源（进度 tick 与退出时补写）并发就会让较小的那个后写，
     * 进度条**往回退** —— 而用户只会看到「看了半天，进度条又回去了」。
     *
     * ⛔ `max(a, b)` 是 SQLite 的多参数标量函数，配合 `COALESCE` 把 NULL 当 0。
     * 老行这一列可能是 NULL（从没播过）。
     */
    fun saveMaxPosition(itemId: String, positionMs: Long) {
        if (positionMs <= 0L) return
        require().execSQL(
            "UPDATE media_items SET max_position_ms = " +
                "max(COALESCE(max_position_ms, 0), ?) WHERE id = ?",
            arrayOf<Any>(positionMs, itemId),
        )
    }

    /** 取续播位置（毫秒）。 */
    fun resumePositionMs(itemId: String): Long? {
        val d = require()
        d.rawQuery(
            "SELECT resume_position_ms FROM media_items WHERE id = ? LIMIT 1",
            arrayOf(itemId),
        ).use { c -> return if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null }
    }

    // ------------------------------------------------------------------
    // 写：播放偏好（逐文件）
    // ------------------------------------------------------------------

    /**
     * 整条覆盖写播放偏好。
     *
     * ⛔ **整条覆盖**，不是合并（PC 端 `playback_prefs` 的约定）：`prefs` 是
     * 一个完整的 JSON 对象，合并要靠调用方先把旧值读出来。做「部分更新」
     * 需要读改写，而读改写在这里只会多一处竞态。
     *
     * [groupKey] 冗余存一份，为的是**同剧继承**：某一集没记过偏好时，
     * 回退到同一部作品里最近改过的那一条。
     */
    fun savePlaybackPreference(itemId: String, groupKey: String, prefsJson: String) {
        require().execSQL(
            "INSERT OR REPLACE INTO playback_prefs (item_id, group_key, prefs, updated_at) " +
                "VALUES (?, ?, ?, ?)",
            arrayOf<Any>(itemId, groupKey, prefsJson, nowSec()),
        )
    }

    /**
     * 读这个文件的播放偏好 JSON。读不到返回 `null`。
     *
     * [fallbackToWork] 为 true 时，本文件没有记录就回退到同作品最近改过的那一条
     * （「用户给第 1 集选了粤语，第 2 集打开也该是粤语」）。
     */
    fun playbackPreferenceJson(
        itemId: String,
        groupKey: String?,
        fallbackToWork: Boolean = true,
    ): String? {
        val d = require()
        d.rawQuery(
            "SELECT prefs FROM playback_prefs WHERE item_id = ? LIMIT 1",
            arrayOf(itemId),
        ).use { c ->
            if (c.moveToFirst()) {
                val v = c.getString(0)
                // 空对象 = 没记过，继续往下找同剧继承。
                if (v != null && v != "{}" && v != "null") return v
            }
        }
        if (!fallbackToWork || groupKey.isNullOrEmpty()) return null
        d.rawQuery(
            "SELECT prefs FROM playback_prefs WHERE group_key = ? " +
                "AND prefs <> '{}' ORDER BY updated_at DESC LIMIT 1",
            arrayOf(groupKey),
        ).use { c ->
            if (c.moveToFirst()) {
                val v = c.getString(0)
                if (v != null && v != "{}" && v != "null") return v
            }
        }
        return null
    }

    // ------------------------------------------------------------------
    // 备份：整个库文件的原始字节
    // ------------------------------------------------------------------

    /**
     * 读出**整个库文件**的原始字节（导出备份用）。
     *
     * ⛔ **必须先 [close]**。连接还开着的时候，SQLite 不保证所有已提交的页
     *    都落在主文件里，而且 `-journal` 可能还在 —— 导出去的会是一份
     *    「看起来完整、其实少最后几次写入」的库，**而且不报任何错**。
     *    这正是本类坚持 `journal_mode=DELETE` 的原因：关掉连接之后，
     *    主文件就是一份自洽的库，不需要再考虑 `-wal`。
     */
    fun rawBytes(): ByteArray {
        close()
        if (!file.exists()) {
            throw IllegalStateException("索引库文件不存在：${file.absolutePath}")
        }
        return file.readBytes()
    }

    /**
     * 用备份里的原始字节**整体替换**本地库，然后重新打开。
     *
     * ⛔ 覆盖之前要把 `-journal` / `-wal` / `-shm` 一起删掉。留着它们的后果是
     *    SQLite 下次打开时**把旧库的回滚日志回放到新库上** —— 得到的是一份
     *    混了两个库的文件，而所有查询都「正常」。
     */
    fun replaceWithRawBytes(bytes: ByteArray) {
        close()
        for (suffix in SIDECAR_SUFFIXES) {
            val side = File(file.absolutePath + suffix)
            if (side.exists()) side.delete()
        }
        file.parentFile?.mkdirs()
        file.writeBytes(bytes)
        open()
    }

    /** 库文件当前占多少字节（`0` = 还没有库）。 */
    fun fileSizeBytes(): Long = if (file.exists()) file.length() else 0L

    // ------------------------------------------------------------------
    // 清空
    // ------------------------------------------------------------------

    /**
     * 清空本地索引（「重建媒体库」）。
     *
     * ⛔ **不动网盘**，也不动 `settings` 与 `playback_prefs` 之外的任何东西 ——
     * 与 PC 端 `wipeIndex()` 清的四张表（字幕引用 / 媒体项 / 作品 / 续扫游标）
     * 保持一致。`settings` 里存着用户的 TMDB key 之类，清掉是另一回事。
     */
    fun wipeIndex() {
        val d = require()
        d.beginTransaction()
        try {
            for (t in listOf("subtitle_refs", "media_items", "media_works", "scan_cursors")) {
                d.delete(t, null, null)
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    private fun queryWorks(sql: String, args: Array<String>): List<Work> {
        val out = ArrayList<Work>()
        require().rawQuery(sql, args).use { c ->
            while (c.moveToNext()) {
                out.add(
                    Work(
                        key = c.str("key"),
                        kind = c.str("kind"),
                        category = c.str("category"),
                        title = c.str("title"),
                        originalTitle = c.strOrNull("original_title"),
                        year = c.intOrNull("year"),
                        overview = c.strOrNull("overview"),
                        posterUrl = c.strOrNull("poster_url"),
                        posterFile = c.strOrNull("poster_file"),
                        posterFaceX = c.doubleOrNull("poster_face_x"),
                        rating = c.doubleOrNull("rating"),
                        genres = parseJsonArray(c.strOrNull("genres")),
                        source = c.str("source"),
                        itemCount = c.intOrNull("item_count") ?: 0,
                        totalBytes = c.longOrNull("total_bytes") ?: 0L,
                        seasonCount = c.intOrNull("season_count") ?: 0,
                        lastModifiedAt = c.longOrNull("last_modified_at"),
                        firstSeenAt = c.longOrNull("first_seen_at"),
                        lastPlayedAt = c.longOrNull("last_played_at"),
                    ),
                )
            }
        }
        return out
    }

    private fun queryItems(sql: String, args: Array<String>): List<LibraryItem> {
        val out = ArrayList<LibraryItem>()
        require().rawQuery(sql, args).use { c ->
            while (c.moveToNext()) {
                out.add(
                    LibraryItem(
                        id = c.str("id"),
                        provider = c.str("provider"),
                        fileId = c.str("file_id"),
                        dirId = c.str("dir_id"),
                        name = c.str("name"),
                        dirPath = c.str("dir_path"),
                        groupKey = c.str("group_key"),
                        kind = c.str("kind"),
                        title = c.strOrNull("title"),
                        year = c.intOrNull("year"),
                        season = c.intOrNull("season"),
                        episode = c.intOrNull("episode"),
                        episodeEnd = c.intOrNull("episode_end"),
                        part = c.intOrNull("part"),
                        partLabel = c.strOrNull("part_label"),
                        container = c.str("container"),
                        resolution = c.strOrNull("resolution"),
                        sizeBytes = c.longOrNull("size_bytes"),
                        durationMs = c.longOrNull("duration_ms"),
                        resumePositionMs = c.longOrNull("resume_position_ms"),
                        maxPositionMs = c.longOrNull("max_position_ms"),
                        lastPlayedAt = c.longOrNull("last_played_at"),
                        thumbUrl = c.strOrNull("thumb_url"),
                        faceAnchorX = c.doubleOrNull("face_anchor_x"),
                        videoWidth = c.intOrNull("video_width"),
                        videoHeight = c.intOrNull("video_height"),
                    ),
                )
            }
        }
        return out
    }

    private fun queryString(d: SQLiteDatabase, sql: String, args: Array<String>): String? =
        d.rawQuery(sql, args).use { c -> if (c.moveToFirst()) c.getString(0) else null }

    /** `genres` 是 JSON 数组字符串；读不懂就当空列表（不抛）。 */
    private fun parseJsonArray(raw: String?): List<String> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            val arr = org.json.JSONArray(raw)
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotEmpty() } }
        }.getOrDefault(emptyList())
    }

    companion object {
        private const val TAG = "CloudCine"

        private const val WORK_COLUMNS =
            "key, kind, category, title, original_title, year, overview, poster_url, " +
                "poster_file, poster_face_x, rating, genres, source, item_count, " +
                "total_bytes, season_count, last_modified_at, first_seen_at, last_played_at"

        private const val ITEM_COLUMNS =
            "id, provider, file_id, dir_id, name, dir_path, group_key, kind, title, year, season, " +
                "episode, episode_end, part, part_label, container, resolution, size_bytes, " +
                "duration_ms, resume_position_ms, max_position_ms, last_played_at, " +
                "thumb_url, face_anchor_x, video_width, video_height"

        /** 当前 Unix 秒。⛔ 全库时间列都是秒，不是毫秒。 */
        fun nowSec(): Long = System.currentTimeMillis() / 1000L

        /**
         * SQLite 在库文件旁边的辅助文件。替换库文件前必须一起删掉 ——
         * 否则下次打开会把**旧库的回滚日志**回放到新库上。
         */
        private val SIDECAR_SUFFIXES = listOf("-journal", "-wal", "-shm")

        private fun Cursor.str(name: String): String = getString(getColumnIndexOrThrow(name)).orEmpty()

        private fun Cursor.strOrNull(name: String): String? {
            val i = getColumnIndexOrThrow(name)
            return if (isNull(i)) null else getString(i)
        }

        private fun Cursor.intOrNull(name: String): Int? {
            val i = getColumnIndexOrThrow(name)
            return if (isNull(i)) null else getInt(i)
        }

        private fun Cursor.longOrNull(name: String): Long? {
            val i = getColumnIndexOrThrow(name)
            return if (isNull(i)) null else getLong(i)
        }

        private fun Cursor.doubleOrNull(name: String): Double? {
            val i = getColumnIndexOrThrow(name)
            return if (isNull(i)) null else getDouble(i)
        }
    }
}
