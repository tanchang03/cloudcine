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
        // ⛔ 忙等超时：扫描（后台写事务）与界面（主线程读）会**同时**碰这个库，
        //    而默认超时是 0ms —— 撞上一次写事务就直接抛 `database is locked`，
        //    症状是「扫描到一半，海报墙突然报读取失败」。
        //    设 5 秒让读等一会儿，而不是立刻失败。用 PRAGMA 而不是
        //    `setBusyTimeout()`：后者在部分 API 级别上是隐藏接口。
        opened.rawQuery("PRAGMA busy_timeout=5000", null).use { it.moveToFirst() }
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
    // 设置（`settings` 表）
    //
    // ⛔ 刮削凭证（TMDB Key / 两个反代地址 / 豆瓣 Cookie）走**这里**，而不是
    //    `AppPrefs`（SharedPreferences）。理由只有一个但很硬：**备份包里装的
    //    是整个 sqlite 文件的原始字节**，`settings` 表随之一路走；而
    //    SharedPreferences 在备份包里根本不存在。放进 `AppPrefs` 的话，
    //    「在电脑上配好、同步到电视」这件事就不成立了。
    // ------------------------------------------------------------------

    /**
     * 读出**整张** `settings` 表。
     *
     * ⛔ 一次读全表而不是按需四次 `getSetting`：刮削要用四个键，而这个方法在
     *    **每次开始刮削**时调一次。表很小（几十行），一次读完更省。
     *
     * ⚠️ 读出来的包括 PC 端同步过来的值 —— 这正是「反代地址跨端可用」的实现方式。
     */
    fun settingsMap(): Map<String, String> {
        val out = HashMap<String, String>(32)
        require().rawQuery("SELECT key, value FROM settings", null).use { c ->
            while (c.moveToNext()) {
                val k = c.getString(0) ?: continue
                out[k] = c.getString(1).orEmpty()
            }
        }
        return out
    }

    /** 读一个设置项。**缺失返回 `null`**（不是空串 —— 两者语义不同）。 */
    fun getSetting(key: String): String? {
        require().rawQuery(
            "SELECT value FROM settings WHERE key = ? LIMIT 1",
            arrayOf(key),
        ).use { c -> if (c.moveToFirst()) return c.getString(0).orEmpty() }
        return null
    }

    /**
     * 写一个设置项（存在即更新，不存在则插入）。
     *
     * ⛔ 不用 `INSERT OR REPLACE`：那是「先删后插」，在只有 `key`/`value` 两列的
     *    表上行为一样，但语义上是「删一行再插一行」—— 将来这张表多一列
     *    （比如 `updated_at`）时会把新列的值抹掉。显式分两支，与
     *    [applyScanItems] 同一条规矩。
     */
    fun setSetting(key: String, value: String) {
        val d = require()
        val n = d.update(
            "settings",
            ContentValues().apply { put("value", value) },
            "key = ?",
            arrayOf(key),
        )
        if (n == 0) {
            d.insert(
                "settings",
                null,
                ContentValues().apply {
                    put("key", key)
                    put("value", value)
                },
            )
        }
    }

    // ------------------------------------------------------------------
    // 刮削写回
    // ------------------------------------------------------------------

    /**
     * 把刮削结果**合并回**作品行并落库，返回更新后的行（找不到该作品时 `null`）。
     *
     * ## 为什么不能复用 [insertMissingWorks]
     *
     * 那个用 `INSERT OR IGNORE`，**绝不更新已存在的行** —— 它的职责是「补建」，
     * 而刮削要的恰恰是更新那一行（且只更新元数据列）。
     *
     * ## 哪些列会被改
     *
     * 标题 / 原名 / 年份 / 简介 / 海报 / 背景图 / 评分 / 类型 / `online_id` /
     * `source` / `scraped_at` / `updated_at`。
     *
     * ⛔ **`item_count` / `total_bytes` / `season_count` / `last_modified_at`
     * 一个字都不碰** —— 它们是**扫描的产物**，与刮削无关。抄一遍或写 0 都会
     * 让卡片上的「24 集」变成一个错的数字。
     *
     * ## 海报换了就必须清 `poster_file` / `poster_face_x`
     *
     * 缓存文件名是按 URL 散列出来的，地址换了就该重新下载；不清的话详情页会
     * 继续显示上一版海报。`poster_face_x` 同理：刮削海报是 2:3 竖版、铺满格子
     * 不裁切，压根不需要人脸锚点，写 NULL 是**结论**而不是缺失。
     *
     * ## 分类
     *
     * [categoryOverride] 非空 = 用户在刮削页**亲手选的结论** → 直接落库并锁
     * （`category_manual = 1`），之后的刮削不再改写它。为空时按
     * [categoryAfterScrape] 的规则判。
     *
     * ## `genres_manual`
     *
     * 用户手敲过的类型标签**不被刮削覆盖** —— 他可能就是为了修「刮削返回的类型
     * 是错的」才动手的，再刮一次又冲掉等于白改。所以先查这一列。
     */
    fun updateWorkScrape(
        workKey: String,
        meta: ScrapedMetadata,
        categoryOverride: String? = null,
        nowSec: Long = nowSec(),
    ): Work? {
        val cur = workByKey(workKey) ?: return null

        val posterUrl = meta.posterUrl?.takeIf { it.isNotBlank() } ?: cur.posterUrl
        val posterChanged = posterUrl != cur.posterUrl

        // 类型标签锁要**单独查**：`Work` 是只读视图模型，刻意没有这一列
        //（它只在写的时候有意义，多读一列就多一处与 PC 端 schema 脱钩的风险）。
        var genresManual = false
        require().rawQuery(
            "SELECT genres_manual FROM media_works WHERE key = ? LIMIT 1",
            arrayOf(workKey),
        ).use { c -> if (c.moveToFirst()) genresManual = c.getInt(0) != 0 }

        val category = categoryAfterScrape(cur, meta, categoryOverride)
        val genres = when {
            genresManual -> cur.genres
            meta.genres.isNotEmpty() -> meta.genres
            else -> cur.genres
        }

        val values = ContentValues().apply {
            put("title", meta.title)
            put("category", category)
            // ⛔ 用户这次**亲手选了**类型 → 锁住它（与 PC 端同一条规则：用户明确
            //    要求的状态变更不该被后续自动流程改写）。没选就保持原值不动。
            if (categoryOverride != null) put("category_manual", 1)

            val ot = meta.originalTitle?.takeIf { it.isNotBlank() } ?: cur.originalTitle
            if (ot != null) put("original_title", ot) else putNull("original_title")

            val year = meta.year ?: cur.year
            if (year != null) put("year", year) else putNull("year")

            val overview = meta.overview?.takeIf { it.isNotBlank() } ?: cur.overview
            if (overview != null) put("overview", overview) else putNull("overview")

            if (posterUrl != null) put("poster_url", posterUrl) else putNull("poster_url")
            if (posterChanged) {
                putNull("poster_file")
                putNull("poster_face_x")
            }

            val rating = meta.rating ?: cur.rating
            if (rating != null) put("rating", rating) else putNull("rating")

            put("genres", jsonArray(genres))
            // `online_id` / `backdrop_url` 只在刮到值时才写：`Work` 没读这两列，
            // 拿不到旧值可回退，写 NULL 会把 PC 端刮来的背景图抹掉。
            meta.onlineId?.takeIf { it.isNotBlank() }?.let { put("online_id", it) }
            meta.backdropUrl?.takeIf { it.isNotBlank() }?.let { put("backdrop_url", it) }

            // ⛔ `source = 'online'` 是「已刮削」的唯一判据（筛选项按它算）。
            put("source", ScrapeSource.online.id)
            put("scraped_at", nowSec)
            put("updated_at", nowSec)
        }
        require().update("media_works", values, "key = ?", arrayOf(workKey))
        Log.i(
            TAG,
            "刮削落库 $workKey → 「${meta.title}」" +
                "${meta.year?.let { "（$it）" } ?: ""} · 分类=$category" +
                "${if (categoryOverride != null) "（手选）" else ""}" +
                " · 类型=${genres.joinToString("/")}" +
                "${if (posterChanged) " · 海报已换（待下载）" else ""}",
        )
        return workByKey(workKey)
    }

    /**
     * 记下某部作品的海报缓存文件名（[PosterFetcher] 下载完成后回写）。
     *
     * ⛔ 回写它**有实际收益**：PC 端 `PosterCache.pathFor` 拿到 `knownFile` 时
     *    直接返回（省一次「按 key + url 现算」），Android 端 [PosterStore.fileFor]
     *    也把它排在第一优先。不回写的话两边都得走现算或扫目录，多一次磁盘判断。
     *
     * ⚠️ 只写文件名、**不写绝对路径** —— 库要能整个搬走（换机器、改缓存目录）
     *    而不用改数据（与 PC 端 `PosterCache.relativeNameOf` 的注释同一条）。
     */
    fun setWorkPosterFile(workKey: String, fileName: String) {
        require().update(
            "media_works",
            ContentValues().apply { put("poster_file", fileName) },
            "key = ?",
            arrayOf(workKey),
        )
    }

    /**
     * 给**海报地址还是空的**作品补上网盘缩略图地址。
     *
     * ## 为什么必须有它（[insertMissingWorks] 是 `CONFLICT_IGNORE`）
     *
     * 作品行只在**新建**时写一次 `poster_url`，之后重扫一个字都不改 —— 那是对
     * 的（已有地址可能是 PC 端刮削时挑好的那张图）。但代价是：某次扫描恰好
     * 没拿到缩略图时（夸克对约 30% 的视频还没生成预览图，见
     * `DriveEntry.previewUrl`），`poster_url` 就落成空值，**之后每次重扫都补
     * 不上** —— 那部作品永远是一块「首字」灰块，而它名下明明有别的集带着图。
     *
     * 所以补这一条**只填空的**回填。
     *
     * ⛔ 判据里必须带空串：库里 `NULL` 与 `''` 两种都出现过（PC 端与 Android 端
     *    写空的方式不同），只判 `IS NULL` 会让一半的空行漏掉。
     * ⛔ 已有地址的行**一个字都不许改**：用户看到的可能是他亲手刮削过的那张海报。
     *
     * @param entries `作品键 → 网盘缩略图地址`。地址为空白的项会被跳过。
     * @return 实际补上的行数。
     */
    fun backfillWorkPosterUrls(entries: Map<String, String>): Int {
        if (entries.isEmpty()) return 0
        val d = require()
        var n = 0
        d.beginTransaction()
        try {
            for ((key, url) in entries) {
                if (url.isBlank()) continue
                n += d.update(
                    "media_works",
                    ContentValues().apply { put("poster_url", url) },
                    "key = ? AND (poster_url IS NULL OR poster_url = '')",
                    arrayOf(key),
                )
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
        return n
    }

    /**
     * 刮削之后这部作品该归到哪一栏。
     *
     * ## 为什么不能直接调 `MediaCategoryGuesser.guess`
     *
     * `guess` 的最后一步是「按 `kind` 落到电影 / 剧集」—— 那是**兜底**，
     * 而这里要的是「刮削**新增**了什么证据」，不是「从头再判一次」。
     *
     * 用 `guess` 会有一个很难查的后果：用户把综艺放在 `/综艺/奔跑吧/`（扫描期
     * 靠目录路径正确地判成「综艺」），而 TMDB 对国产综艺常常给不出「真人秀」
     * 这个类型 —— 于是 `guess` 走到 kind 兜底，把「综艺」**冲成「剧集」**。
     * 用户看到的是「我的综艺栏目空了」。
     *
     * ## 所以规则是：genres 说话才算，不说就闭嘴
     *
     *   1. 用户在刮削页手选的类型 → 结论，直接用；
     *   2. `fromGenres` 有结论（动画 / 纪录片 / 真人秀）→ 用它（TMDB 的真实类型，
     *      比目录名和关键词都准，与 `MediaCategoryGuesser` 把 genres 排第一优先
     *      的口径一致）；
     *   3. `fromGenres` 没结论 → 看**条目结构**（`douban/tv/…` / `tmdb/movie/…`）。
     *      这一条只在**手动通道**用（Android 端只有手动），因为用户在候选列表里
     *      亲手确认过这一条 —— 那是比文件名结构强得多的证据。它能救这一类：
     *      文件名只剩 `2026.2160p.WEB-DL.mkv`，扫描期结构上认不出（落到「其他」），
     *      而用户在候选里亲手确认了这是一部剧；
     *   4. 都没有 → **原样保留扫描期的判定**。
     *
     * ⚠️ 第 3 步的代价（已知并接受）：放在 `/综艺/` 而数据源又没给「真人秀」
     *    类型的片子，会被判成「剧集」—— 此时在刮削页的「媒体类型」里点一下
     *    「综艺」即可（PC 端同一条取舍）。
     */
    private fun categoryAfterScrape(
        current: Work,
        meta: ScrapedMetadata,
        override: String?,
    ): String {
        if (override != null) return override
        MediaCategoryGuesser.fromGenres(meta.genres)?.let { return it }
        when (structureOf(meta.onlineId)) {
            "tv" -> return MediaCategoryNames.SERIES
            "movie" -> return MediaCategoryNames.MOVIE
        }
        return current.category
    }

    // ------------------------------------------------------------------
    // 追剧 / 更新提醒（schema v17）
    // ------------------------------------------------------------------
    //
    // 四列一组：`followed` / `follow_started_at` / `follow_checked_at` /
    // `new_item_count`。完整口径见 `LibrarySchema` 与 `Work` 上的注释，
    // 这里只重复三条最容易写错、且**错了不会报错**的：
    //
    //   1. ⛔ [setFollowed] **要**写 `updated_at`（用户显式动作 = 真实内容
    //      变更，该跨端同步）；[applyFollowCheck] / [clearFollowBadge]
    //      **绝不能**写它 —— 否则每次自动检查都会改同步判据
    //      `libraryModifiedAt`，本机永远「看起来更新」，下一次同步无条件
    //      上传，把另一台设备的播放进度盖掉。
    //   2. ⛔ [applyFollowCheck] 里的计数是**增量累加**，不是重算 ——
    //      重算会把用户刚清掉的角标又算回来。
    //   3. ⛔ [clearFollowBadge] 只清计数，**不动 `follow_started_at`** ——
    //      动了的话剧集列表的 NEW 标签会跟着消失，而用户还没看。

    /**
     * 打开 / 关闭一部作品的追剧。
     *
     * 开启时**同时建立两条水位线**：`follow_started_at = follow_checked_at = now`，
     * 并把 `new_item_count` 清 0。三件事必须一起做：
     *
     *   - `follow_started_at = now` ⇒ 此刻之前入库的集**都不算新增**
     *     （用户刚看完 12 集才开的追剧，不该把 12 集全标成 NEW）；
     *   - `follow_checked_at = now` ⇒ 第一次检查只报「开启之后」的新增，
     *     不会把开启那一刻之前扫到的东西重报一遍；
     *   - `new_item_count = 0` ⇒ 角标从零开始。
     *
     * 关闭时四列一起清回默认。⛔ 清 `follow_started_at` 是**有意**的：
     * 关掉再打开 = 「重新开始追」，之前的 NEW 标签全部作废。
     *
     * @param nowSec 由调用方注入是为了可测：水位线是「秒」级的，测试里
     *   两次调用落在同一秒会让「开启前 / 开启后」的判据失效。
     */
    fun setFollowed(key: String, followed: Boolean, nowSec: Long = nowSec()) {
        val values = ContentValues().apply {
            put("followed", if (followed) 1 else 0)
            if (followed) {
                put("follow_started_at", nowSec)
                put("follow_checked_at", nowSec)
            } else {
                putNull("follow_started_at")
                putNull("follow_checked_at")
            }
            put("new_item_count", 0)
            // ⛔ 这一列**要**写：开关追剧是用户的显式动作 = 真实内容变更，
            //    该跨端同步 —— 否则「电脑上追了这部，电视上打开没有」。
            //    （与 applyFollowCheck / clearFollowBadge 恰好相反。）
            put("updated_at", nowSec)
        }
        require().update("media_works", values, "key = ?", arrayOf(key))
    }

    /**
     * 清掉一部作品的未读更新角标（用户进了简介页 = 「我知道了」）。
     *
     * ⛔ **只清 `new_item_count`**：
     *   * 不动 `follow_started_at` —— 剧集行的 NEW 标签靠它，那是「哪几集
     *     是新的、我还没看」，与角标回答的不是同一个问题；
     *   * 不动 `follow_checked_at` —— 那是水位线，动它会让下一次检查把
     *     同一批新集重数一遍；
     *   * 不动 `updated_at` —— 它参与同步判据 `libraryModifiedAt`，
     *     写它会让本机永远「看起来更新」，下次同步无条件上传、
     *     把另一台设备的播放进度盖掉。
     */
    fun clearFollowBadge(key: String) {
        require().update(
            "media_works",
            ContentValues().apply { put("new_item_count", 0) },
            "key = ?",
            arrayOf(key),
        )
    }

    /**
     * 一次追更检查的写回（**一个事务**）。
     *
     * @param increments 作品 key → 本次新增条数。只放**有新增**的作品，
     *   没新增的不必出现在里面（但仍要在 [checkedKeys] 里推进水位线）。
     * @param checkedKeys 本次**成功检查过**的作品 key —— 水位线
     *   `follow_checked_at` 只对这些作品推进。
     *
     * ⛔ **列目录失败的目录所覆盖的作品必须排除在 [checkedKeys] 之外**：
     *    水位线是「已经看过这里了」的承诺，在没看成功时推进它，等于把这批
     *    新集永久划进「已读」—— 用户再也不会被提醒，而且没有任何报错。
     *    与全盘扫描那条「有目录列失败就不做陈旧清理」是同一条思路。
     *
     * ⛔ 不写 `updated_at`（本节顶部第 1 条）。
     *
     * ## 为什么先 SELECT 再逐条 UPDATE，而不是一条
     * `SET new_item_count = new_item_count + ?`
     *
     * 与 `upsertItems` 里「在 Kotlin 侧合并」同一条理由：这个数只涉及
     * **在追的那几部**（通常个位数到几十），多一次 SELECT 换来的是
     * 「增量语义在代码里看得见」，而不是藏在一条 SQL 表达式里。
     * 读回之后仍在**同一个事务**里写：中途失败时「水位线推进了、计数没加上」
     * 这种半成品状态不会落库。
     */
    fun applyFollowCheck(
        increments: Map<String, Int>,
        checkedKeys: Collection<String>,
        checkedAtSec: Long = nowSec(),
    ) {
        if (checkedKeys.isEmpty()) return
        val d = require()
        val keys = checkedKeys.toList()

        val existing = HashMap<String, Int>(keys.size * 2)
        for (chunk in keys.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "SELECT key, new_item_count FROM media_works WHERE key IN ($marks)",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) existing[c.getString(0)] = c.getInt(1)
            }
        }

        d.beginTransaction()
        try {
            for (key in keys) {
                // 行在两次查询之间被删了（用户在详情页点了「移除整部」）：
                // 跳过，不写一条 UPDATE 去影响 0 行。
                val old = existing[key] ?: continue
                val added = increments[key] ?: 0
                d.execSQL(
                    "UPDATE media_works SET follow_checked_at = ?, new_item_count = ? " +
                        "WHERE key = ?",
                    // ⛔ **增量累加**。重算（`= 本次新增数`）会把用户刚清掉的
                    //    角标又算回来 —— 用户进过一次简介页，角标却在下一次
                    //    检查时复活。
                    arrayOf<Any?>(checkedAtSec, old + added, key),
                )
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
    }

    /** 全部**在追**的作品 key（只含 `merged_into IS NULL` 的行）。 */
    fun followedWorkKeys(): List<String> {
        val out = ArrayList<String>(32)
        require().rawQuery(
            "SELECT key FROM media_works WHERE followed = 1 AND merged_into IS NULL",
            null,
        ).use { c -> while (c.moveToNext()) out.add(c.getString(0)) }
        return out
    }

    /**
     * 这几部作品名下的**网盘目录**（已按 fid 去重），每个目录带上
     * 「它覆盖到了哪些在追的作品」。
     *
     * ## 并集口径
     *
     * 与 [itemsForWork] 一致：跨目录归一时源行的 `group_key` **从不改写**，
     * 所以「这部作品的文件在哪些目录」的正确答案是**并集** —— 只查目标
     * 自己的 `group_key` 会漏掉被折叠进来的那些文件所在的目录，表现是
     * 「合并过的剧永远收不到更新提醒」，而检查日志一切正常。
     *
     * ⛔ 顺带记下「源 → 目标」的反查表：文件行上只有**源**的 `group_key`，
     *    而水位线只写在**目标**行上，所以回写时必须能把它翻译回目标。
     *    少了这张表，被折叠过的剧会「列了目录、但水位线永远不推进」——
     *    每检查一次就把同一批新集重报一次。
     *
     * ⛔ **必须去重**：一部剧的 12 集通常在同一个目录里，不去重就是
     * 12 次列目录请求（而夸克有 QPS 限制）。
     * ⛔ 空 `dir_id` 跳过：那是老库 / 手改过的行的兜底值，拿它去列目录
     * 只会得到一次失败请求。
     */
    fun dirsForWorks(keys: Collection<String>): List<FollowDir> {
        if (keys.isEmpty()) return emptyList()
        val d = require()
        val target = HashSet(keys)

        val sourceToTarget = HashMap<String, String>(keys.size * 2)
        for (chunk in keys.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "SELECT key, merged_into FROM media_works WHERE merged_into IN ($marks)",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) {
                    val src = c.getString(0) ?: continue
                    // 链式合并是不允许的（见 `merged_into` 的注释），所以一层就够。
                    // 目标不在在追集合里 = 折叠到一部**没在追**的作品上，
                    // 它的文件不该算进任何在追作品的覆盖范围。
                    val dst = c.getString(1) ?: continue
                    if (!target.contains(dst)) continue
                    sourceToTarget[src] = dst
                }
            }
        }

        val all = HashSet<String>(keys.size * 2)
        all.addAll(keys)
        all.addAll(sourceToTarget.keys)

        val dirPathById = HashMap<String, String>()
        val workKeysByDir = HashMap<String, MutableSet<String>>()
        for (chunk in all.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "SELECT dir_id, dir_path, group_key FROM media_items WHERE group_key IN ($marks)",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    if (id.isNullOrEmpty()) continue
                    val group = c.getString(2) ?: continue
                    val owner = sourceToTarget[group] ?: group
                    if (!target.contains(owner)) continue
                    workKeysByDir.getOrPut(id) { HashSet() }.add(owner)
                    if (!dirPathById.containsKey(id)) {
                        // ⛔ 走包级的 `normalizeDirPath`（`DirPaths.kt`）：
                        //    `dirPath` 参与 `groupKey` 的计算，少了尾斜杠会让
                        //    同一个文件在追更检查里算出**另一个** groupKey ——
                        //    表现是「检查完多出一部重复的作品」。
                        dirPathById[id] = normalizeDirPath(c.getString(1).orEmpty())
                    }
                }
            }
        }

        return dirPathById.map { (id, path) ->
            FollowDir(id, path, workKeysByDir[id] ?: emptySet())
        }
    }

    /**
     * 这几部作品各自「**上次检查之后**新入库的条数」= `new_item_count` 的增量。
     *
     * 判据：`first_seen_at > COALESCE(follow_checked_at, follow_started_at)`。
     *
     * ## ⛔ 用 `COALESCE(checked, started)` 而不是裸 `checked`
     *
     * 只有 [setFollowed] 会把 `followed` 置 1，而它**同时**写两条水位线 ——
     * 所以「`followed = 1` 但 `follow_checked_at IS NULL`」本该不存在。
     * 但真出现了（手改的库、早期版本写的行）时，裸 `checked` 会让
     * `first_seen_at > NULL` 恒为 NULL、计数恒为 0 —— 这部剧**永远不提醒**，
     * 而且没有任何报错。退回 `follow_started_at` 是它的正确语义。
     *
     * ⛔ 两个都 `NULL` 时**必须**得到 0，不能退到 0（epoch）：那会把整部剧
     *    算成新增（角标直接变成总集数）。SQLite 里 `x > NULL` 天然是 NULL、
     *    COUNT 不计入，所以只要把 `COALESCE` 写进比较式就自动成立。
     *
     * ## ⛔ 按**并集**口径数（与 [itemsForWork] 一致）
     *
     * 被折叠进来的源作品名下的集**不在** `group_key = key` 里。只数存值的话，
     * 合并过的剧角标会永远少报那几集 —— 而 [dirsForWorks] 已经按并集把目录
     * 找齐了，两处口径不一致会让「检查到了新集但不报数」。
     *
     * 没在结果里的 key 视为 0（调用方不必先铺一遍零）。
     */
    fun pendingNewItemCounts(keys: Collection<String>): Map<String, Int> {
        if (keys.isEmpty()) return emptyMap()
        val out = HashMap<String, Int>(keys.size * 2)
        val d = require()
        for (chunk in keys.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "SELECT w.key, ("
                    + "  SELECT COUNT(*) FROM media_items i "
                    + "   WHERE i.group_key IN ("
                    + "           SELECT w2.key FROM media_works w2 "
                    + "            WHERE w2.key = w.key OR w2.merged_into = w.key) "
                    + "     AND i.first_seen_at > "
                    + "         COALESCE(w.follow_checked_at, w.follow_started_at)"
                    + ") FROM media_works w WHERE w.key IN ($marks)",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) out[c.getString(0)] = c.getInt(1)
            }
        }
        return out
    }

    /**
     * 有几部在追的作品带未读更新（分类栏「追剧 N」上的那个数字）。
     *
     * 与 [playedCount] 同类的角标计数：海报墙上不显示，只用于分类栏。
     * ⛔ 数的是 `new_item_count > 0` 而不是 `followed = 1` —— 「追剧 N」
     *    在电视上是一个**提醒**（有 N 部动了），不是「你追了 N 部」的
     *    收藏计数。与 PC 端 `countUpdatedWorks` 逐字同口径。
     */
    fun followedUpdateCount(): Int = require().rawQuery(
        "SELECT COUNT(*) FROM media_works WHERE merged_into IS NULL AND new_item_count > 0",
        null,
    ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    // ------------------------------------------------------------------
    // 读：列表 / 详情
    // ------------------------------------------------------------------

    /** 作品列表排序。 */
    enum class Sort(val label: String) {
        recentModified("最近修改"),
        recentAdded("最近添加"),
        recentPlayed("最近播放"),
        rating("评分"),

        /**
         * 按上映年份倒序。
         *
         * ⛔ 位置**必须**与 PC 端 `WorkSort` 对齐（声明顺序就是菜单顺序）：
         *    两端不一致的话，同一个用户在两个端上看到的排序菜单是两套顺序。
         *    PC 端是 `recentModified / recentAdded / recentPlayed / rating /
         *    year / title` —— 所以这里插在 `rating` 与 `title` 之间。
         */
        year("年份"),
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
     *
     * [followedOnly] 是「追剧」那一栏：只留在追的作品，并把**有未读更新的**
     * 按 `new_item_count` 倒序顶到最前（其余仍按 [sort]）。它是一个与
     * [playedOnly] 同类的**视图开关**，不是一个分类取值。
     */
    fun listWorks(
        sort: Sort = Sort.recentModified,
        playedOnly: Boolean = false,
        followedOnly: Boolean = false,
        category: String? = null,
        years: Set<Int> = emptySet(),
        genres: Set<String> = emptySet(),
        scrapedOnly: Boolean = false,
        keyword: String? = null,
        limit: Int = 500,
        offset: Int = 0,
    ): List<Work> {
        val (where, args) = workWhere(
            category = category,
            playedOnly = playedOnly,
            followedOnly = followedOnly,
            scrapedOnly = scrapedOnly,
            years = years,
            genres = genres,
            keyword = keyword,
        )

        val order = when (sort) {
            Sort.recentModified -> "last_modified_at DESC, year DESC, title ASC"
            Sort.recentAdded -> "first_seen_at DESC, year DESC, title ASC"
            Sort.recentPlayed -> "last_played_at DESC, year DESC, title ASC"
            Sort.rating -> "rating DESC, year DESC, title ASC"
            // ⛔ 按年份排时**没有 `year DESC` 这个 tie-breaker**（自己跟自己比），
            //    照抄 PC 端 `_orderingFor`：年份相同时按标题。
            Sort.year -> "year DESC, title ASC"
            Sort.title -> "title ASC"
        }

        // 追剧栏把「有更新的」顶到最前，其余仍按用户选的那套排序 —— 与 PC 端
        // `listWorks` 里 `followedOnly ? [newItemCount desc, ...] : [...]` 逐字同形。
        // ⛔ 这是**排序**而不是筛选：`followedOnly` 只决定「只看在追的」，
        //    置顶是它附带的表达 —— 用户点进追剧栏，第一眼要看到哪几部动了。
        val effectiveOrder = if (followedOnly) "new_item_count DESC, $order" else order

        val sql = buildString {
            append("SELECT $WORK_COLUMNS FROM media_works")
            append(" WHERE ").append(where)
            append(" ORDER BY ").append(effectiveOrder)
            append(" LIMIT ").append(limit).append(" OFFSET ").append(offset)
        }
        return withUnionStats(queryWorks(sql, args))
    }

    /**
     * 把「真有源作品折进来」的那几部的三个计数换成**并集**值。
     *
     * ## 为什么必须换
     *
     * 库里 `item_count` / `total_bytes` / `season_count` 存的是**自己名下**的
     * 文件。归一之后源行的 `group_key` 从不改写，于是卡片会写「1 集」而点进
     * 详情页有 13 个文件 —— 用户看到的两个数字自相矛盾，且都是「合法」的。
     * 真库上 `01尚硅谷嵌入式技术之c语言` 存值 211 / 并集 1292，差 1081。
     *
     * ## 三条别改错（与 PC 端 `_withUnionStats` 同一条）
     *
     * 1. ⛔ **不写回库**。`mergeWorkForUpsert` 对 `item_count` 是「永远取新值」，
     *    一旦写回，下次重扫就把并集冲成自己名下的数。
     * 2. **只碰「真有源折进来」的行**（SQL 里的 `AND EXISTS(...)`）。老库里
     *    `item_count` 与真实行数本就可能不一致，全表重算会把老数据也一起改掉。
     * 3. ⚠️ **`seasons` 是 `COUNT(DISTINCT season)` 且只数 `> 0`** —— 绝对值，
     *    **不能相加**（两季 + 两季 ≠ 四季）。`items` / `bytes` 才是求和。
     *
     * ⛔ `workByKey` / `allWorks` **仍是存值**（不做列表展示，别顺手也改成并集）
     *    —— 详情页的「N 集」用的是 `itemsForWork(...).size`，不走这两个。
     */
    private fun withUnionStats(works: List<Work>): List<Work> {
        if (works.isEmpty()) return works
        val stats = unionStats(works.map { it.key })
        if (stats.isEmpty()) return works
        return works.map { w ->
            val s = stats[w.key] ?: return@map w
            w.copy(
                itemCount = s.items,
                totalBytes = s.bytes,
                seasonCount = s.seasons,
                // ⛔ 进度也一起换成并集值（`null` 就是 `null`）：只查自己名下的话
                //    「合并过的剧」在卡片上永远画不出进度条，而点进去是有进度的。
                //    并集里一条可续的都没有时必须是 `null`（不画），不能退成 0.0
                //    —— 0.0 会画出一条 0% 的槽，看起来像「点过但没看」。
                resumeFraction = s.resume,
            )
        }
    }

    /** 一部作品并集口径的计数与进度。`resume` 为 `null` = 并集里没有可续的。 */
    private class UnionStats(
        val items: Int,
        val bytes: Long,
        val seasons: Int,
        val resume: Double?,
    )

    /**
     * 这些作品里「有源折进来」的那几部，其**并集**的文件数 / 体积 / 季数。
     *
     * ⛔ SQL 与 PC 端 `DriftMediaRepository._unionStats` **逐字同形**：
     *    `src` 那个 CTE 的两段 `UNION ALL` 保证「自己名下的」与「折进来的」
     *    都数上（只数后一半会让「合并后集数反而变少」）。
     * ⛔ 第一段带 `AND EXISTS(...)`：没有源折进来的作品**不进结果**，
     *    调用方据此保留它原来的存值。
     * ⚠️ 第二段**不按 key 过滤**（与 PC 端一致）：它返回库里全部折叠目标的
     *    统计，调用方按 key 取。多出来的那些行只多几十字节，换来的是两端
     *    SQL 一模一样 —— 别为了「省一点」改成局部，那样两边迟早漂移。
     */
    private fun unionStats(keys: List<String>): Map<String, UnionStats> {
        val out = HashMap<String, UnionStats>(keys.size)
        val d = require()
        for (chunk in keys.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "WITH src AS (" +
                    "  SELECT t.key AS tgt, t.key AS src FROM media_works t " +
                    "   WHERE t.key IN ($marks) " +
                    "     AND EXISTS (SELECT 1 FROM media_works s WHERE s.merged_into = t.key) " +
                    "  UNION ALL " +
                    "  SELECT s.merged_into AS tgt, s.key AS src FROM media_works s " +
                    "   WHERE s.merged_into IS NOT NULL) " +
                    "SELECT s.tgt AS tgt, " +
                    "       COUNT(i.id) AS items, " +
                    "       COALESCE(SUM(i.size_bytes), 0) AS bytes, " +
                    "       COUNT(DISTINCT CASE WHEN i.season > 0 THEN i.season END) AS seasons, " +
                    "       MAX(CASE WHEN i.duration_ms > 0 AND i.resume_position_ms > 0 " +
                    "           THEN CAST(i.resume_position_ms AS REAL) / i.duration_ms END) " +
                    "           AS resume " +
                    "FROM src s JOIN media_items i ON i.group_key = s.src " +
                    "GROUP BY s.tgt",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) {
                    val resume = c.getDouble(4)
                    out[c.getString(0)] = UnionStats(
                        items = c.getInt(1),
                        bytes = c.getLong(2),
                        seasons = c.getInt(3),
                        resume = if (c.isNull(4)) null else resume,
                    )
                }
            }
        }
        return out
    }

    fun workByKey(key: String): Work? =
        queryWorks("SELECT $WORK_COLUMNS FROM media_works WHERE key = ? LIMIT 1", arrayOf(key))
            .firstOrNull()

    /**
     * **简介页**用的作品行：`itemCount` / `seasonCount` / `totalBytes` / `resumeFraction`
     * 都换成**并集**口径。
     *
     * ## 为什么简介页也要并集，而 `workByKey` 保持存值
     *
     * 简介页头部那一行元数据（`2024 · 2 季 · 13 集 · 剧集 · …`）来自
     * [WorkDetailFormat.metaLine]，它读的就是 `w.itemCount` / `w.seasonCount`。
     * 只把**列表**改成并集的话，用户会看到头部写「1 集」、下面列着 13 行
     * —— 同一个数字在同一个页面上自相矛盾（2026-10-07 现场「遮天」：
     * 存值 1 / 并集 13）。
     *
     * PC 端没有这个问题：`_InfoColumn` 的「N 个文件」取自**列表长度**
     * （`visibleCount`），压根不读存值。这里把并集补到行上，是与 PC 对齐。
     *
     * ⛔ 别顺手把 [workByKey] 也改成并集：它被 `syncFollowReadCount` 之类的
     *    **写路径**用（要拿真实存值），改了会牵动别的口径。详情页走这个方法。
     * ⛔ 传进来的可能是**别名 key**（`PlayerActivity` 的选集传的是
     *    `item.group_key`，归一后那是源 key）—— 先向上解析到 owner 再取行。
     */
    fun workForDetail(key: String): Work? {
        val owner = ownerKeyOf(key)
        val row = workByKey(owner) ?: return null
        // `withUnionStats` 只动「真有源折进来」的行，其余原样返回 —— 与作品墙同一条。
        return withUnionStats(listOf(row)).firstOrNull()
    }

    /**
     * 「**还没刮削过**」的作品，按**最近修改倒序**（与作品墙默认排序同一口径）。
     *
     * ## 三条排除规则，每条都对应一种「刮了也是白刮」
     *
     *   * `merged_into IS NULL` —— 被跨目录归一折叠掉的行**不显示在墙上**
     *     （全库的查询都带这一条）。刮它等于白花一个搜索词。
     *   * `source = 'online'` —— 已经刮到了。**扫描后的自动刮削只补没刮过的**，
     *     不重刮：重刮会把用户上次手动挑中的那条结果换成算法自己挑的
     *     （与 PC 端 `ScanService` 那句「刮削在遍历之后单独跑，且只刮还没刮过
     *     的作品」是同一条）。
     *   * `source = 'manual'` —— 用户**亲手**改过片名 / 分类（PC 端
     *     `customizeWork` 写的值）。这一类作品在线刮削**永远不许碰**：
     *     用户清掉刮错的信息、自己敲了正确的片名，下一次扫描又给它刮回来，
     *     那这个功能等于不存在。
     *
     * ⛔ 判据写 `source IS NULL` 一起兜住：老库（PC 端 v3 之前）没有这一列的值。
     *
     * @param limit 一次最多取多少部。批量刮削是串行的，几千部一次跑不完也没意义。
     */
    fun worksNeedingScrape(limit: Int = 500): List<Work> =
        queryWorks(
            "SELECT $WORK_COLUMNS FROM media_works " +
                "WHERE merged_into IS NULL " +
                "AND (source IS NULL OR (source <> 'online' AND source <> 'manual')) " +
                "ORDER BY (last_modified_at IS NULL), last_modified_at DESC, " +
                "year DESC, title ASC LIMIT $limit",
            emptyArray(),
        )

    // ------------------------------------------------------------------
    // 筛选：条件拼装
    // ------------------------------------------------------------------

    /**
     * 把「分类 / 最近播放 / 追剧 / 已刮削 / 年份 / 类型 / 搜索词」拼成 WHERE 与参数。
     *
     * ⛔ **`listWorks` 与两个分面计数共用本函数**。分开写的话必然出现
     *    「列表 11 部、面板角标写 12」这种用户一眼看得见、却极难查的不一致
     *    （PC 端为此专门写了 `_workConditions` 给三处共用，同一条理由）。
     *
     * ⛔ `years` / `genres` 内部是**或**、维度之间是**与**：一部片子只有
     *    一两个类型、一个年份，取交集几乎永远筛不出东西。这与 PC 端
     *    `listWorks` 的接口文档一致。
     *
     * @return `WHERE 子句`（已含 `merged_into IS NULL`）与 `参数数组`。
     */
    private fun workWhere(
        category: String? = null,
        playedOnly: Boolean = false,
        followedOnly: Boolean = false,
        scrapedOnly: Boolean = false,
        years: Set<Int> = emptySet(),
        genres: Set<String> = emptySet(),
        keyword: String? = null,
    ): Pair<String, Array<String>> {
        val where = ArrayList<String>()
        val args = ArrayList<String>()
        where.add("merged_into IS NULL")

        // 「最近播放」的判据是 `last_played_at IS NOT NULL`，**不是**「比某个时间新」：
        // 后者会把「上个月看过」也算成没看过，而这一栏的意思是「我看过的」，
        // 「最近」由排序负责。
        if (playedOnly) where.add("last_played_at IS NOT NULL")

        // 「追剧」的判据就是那一列（`followed = 1`）。与 `playedOnly` 完全同类：
        // 是一个**视图**（不落库、不参与分类判定），所以是一个独立的布尔开关，
        // 而不是 `MediaCategory` 的一个取值 —— 照抄 PC 端
        // `LibraryFilter.followedOnly` 的取舍。
        // ⛔ 用 `= 1` 而不是 `IS TRUE`：SQLite 3.22 支持 `IS TRUE`，但本列是
        //    `INTEGER NOT NULL DEFAULT 0`，`= 1` 走得到索引也更直白。
        if (followedOnly) where.add("followed = 1")

        // 「已刮削」的判据是 `source = 'online'`，**不是**「有海报 / 有简介」——
        // PC 端特意避开了 `MediaWork.isScraped`，因为那一位还含 `manual`，
        // 而「自定义」恰恰会清掉在线信息。
        if (scrapedOnly) where.add("source = 'online'")

        if (!category.isNullOrEmpty()) {
            where.add(categoryCondition(category))
            args.addAll(categoryArgs(category))
        }

        if (years.isNotEmpty()) {
            // ⛔ `year IS NULL` 的行在任何年份条件下都不命中 —— `IN` 对 NULL
            //    求值为 NULL（假）。这与面板角标一致（`yearCounts` 也不数它们）。
            where.add("year IN (" + years.joinToString(",") { "?" } + ")")
            for (y in years) args.add(y.toString())
        }

        if (genres.isNotEmpty()) {
            // ⛔ `genres` 是 JSON 数组文本（`["动画","科幻"]`），所以匹配串
            //    **必须带上引号**：`LIKE '%动画%'` 会把「动画片」也捞进来，
            //    而 `LIKE '%"动画"%'` 只在它确实是数组里一个独立元素时命中。
            val ors = ArrayList<String>(genres.size)
            for (g in genres) {
                ors.add("genres LIKE ?")
                args.add("%\"${g.replace("\"", "\"\"")}\"%")
            }
            where.add("(" + ors.joinToString(" OR ") + ")")
        }

        val kw = keyword?.trim().orEmpty()
        if (kw.isNotEmpty()) {
            where.add("(title LIKE ? OR original_title LIKE ? OR key LIKE ?)")
            val like = "%$kw%"
            args.add(like); args.add(like); args.add(like)
        }

        return where.joinToString(" AND ") to args.toTypedArray()
    }

    /**
     * 单个分类的条件 —— 照抄 PC 端 `_categoryCondition`。
     *
     * ⛔ **`movie` / `series` / `other` 三个桶有空串兜底**，其余三个没有。
     *    原因是老库（PC 端 v3 之前入库的行）的 `category` 是**空串**，
     *    而那时唯一能用来分类的信息是 `kind`。不做兜底的话，这批作品
     *    在「电影 / 剧集 / 其他」三栏里**一部都不出现**，只在「全部」里看得见 ——
     *    用户会以为自己的片子被删了。
     *    动漫 / 综艺 / 纪录片是**语义**分类，`kind` 推不出来（动漫剧集和普通
     *    剧集的 `kind` 都是 `episode`），所以那三栏没有兜底可言。
     *
     * ⚠️ 与 PC 端的一处**有意修正**：PC 写的是 `category = ''`，而 SQL 里
     *    `NULL = ''` 求值为 NULL（假）—— 也就是 `category` 为 **NULL** 的行
     *    在 PC 端既进不了兜底、又不属于任何分类。这里改成
     *    `(category IS NULL OR category = '')`，把 NULL 一并纳入。
     */
    private fun categoryCondition(category: String): String = when (category) {
        MediaCategoryNames.MOVIE ->
            "(category = 'movie' OR ((category IS NULL OR category = '') AND kind = 'movie'))"
        MediaCategoryNames.SERIES ->
            "(category = 'series' OR ((category IS NULL OR category = '') AND kind = 'episode'))"
        MediaCategoryNames.OTHER ->
            "(category = 'other' OR ((category IS NULL OR category = '') AND kind = 'unknown'))"
        // 动漫 / 综艺 / 纪录片（以及将来新增的分类）：只看那一列。
        else -> "category = ?"
    }

    /** [categoryCondition] 只在 `else` 分支用了 `?` 占位，那时才需要参数。 */
    private fun categoryArgs(category: String): List<String> = when (category) {
        MediaCategoryNames.MOVIE,
        MediaCategoryNames.SERIES,
        MediaCategoryNames.OTHER,
        -> emptyList()
        else -> listOf(category)
    }

    /** 「最近播放」栏的角标：播过的作品数（`last_played_at IS NOT NULL`）。 */
    fun playedCount(): Int = require().rawQuery(
        "SELECT COUNT(*) FROM media_works " +
            "WHERE merged_into IS NULL AND last_played_at IS NOT NULL",
        null,
    ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    /**
     * 各年份的作品数（筛选面板「年份」那一组）。
     *
     * ⛔ 统计范围是 `category / playedOnly / scrapedOnly / keyword`，
     *    **不含** `years` / `genres` 自己 —— 否则用户每勾一个类型，
     *    剩下的类型角标就会跟着变，勾到第二个时列表已经空了。
     *    而面板唯一的承诺是「点下去至少有一条结果」。
     */
    fun yearCounts(
        category: String? = null,
        playedOnly: Boolean = false,
        followedOnly: Boolean = false,
        scrapedOnly: Boolean = false,
        keyword: String? = null,
    ): Map<Int, Int> {
        val (where, args) = workWhere(
            category = category,
            playedOnly = playedOnly,
            followedOnly = followedOnly,
            scrapedOnly = scrapedOnly,
            keyword = keyword,
        )
        val out = LinkedHashMap<Int, Int>()
        require().rawQuery(
            "SELECT year, COUNT(*) FROM media_works " +
                "WHERE ($where) AND year IS NOT NULL AND year > 0 " +
                "GROUP BY year ORDER BY year DESC",
            args,
        ).use { c ->
            while (c.moveToNext()) out[c.getInt(0)] = c.getInt(1)
        }
        return out
    }

    /**
     * 各类型的作品数（筛选面板「类型」那一组）。
     *
     * ⛔ `genres` 是 JSON 数组文本，**SQL 数不出来** —— 只能把那一列读出来在
     *    Kotlin 里拆（PC 端 `countWorksByGenre` 走的是同一条路）。仍然只读
     *    **一列**、不碰整行，所以比 `listWorks` 便宜得多。
     * ⛔ 同一个类型在一行里理论上不重复，但数据脏了时角标也不该大于作品数
     *    —— 所以按行去重。
     */
    fun genreCounts(
        category: String? = null,
        playedOnly: Boolean = false,
        followedOnly: Boolean = false,
        scrapedOnly: Boolean = false,
        keyword: String? = null,
    ): Map<String, Int> {
        val (where, args) = workWhere(
            category = category,
            playedOnly = playedOnly,
            followedOnly = followedOnly,
            scrapedOnly = scrapedOnly,
            keyword = keyword,
        )
        val out = HashMap<String, Int>()
        require().rawQuery("SELECT genres FROM media_works WHERE $where", args).use { c ->
            while (c.moveToNext()) {
                for (g in parseJsonArray(c.getString(0)).toSet()) {
                    out[g] = (out[g] ?: 0) + 1
                }
            }
        }
        return out
    }

    /**
     * 每个分类的作品数（分类栏上的角标）。
     *
     * ⛔ **一次查完**，不要「每个标签各查一次」—— 7 个标签就是 7 次全表扫描，
     *    而这一步在**每次切分类/刷新**时都会跑。
     * ⛔ 分桶规则必须与 [categoryCondition] **逐字对齐**（含空串兜底），
     *    否则会出现「角标写 72、点进去 68」这种自相矛盾。这里是同一套规则
     *    写成 SQL：先把 `category` 列归成 6 个桶之一，再 `GROUP BY` 那个桶。
     * @return `分类名 → 数量`。
     */
    fun categoryCounts(): Map<String, Int> {
        val out = HashMap<String, Int>()
        require().rawQuery(
            "SELECT CASE " +
                "WHEN category IN ('movie','series','anime','variety','documentary') " +
                "THEN category " +
                "WHEN category = 'other' THEN 'other' " +
                "WHEN kind = 'movie' THEN 'movie' " +
                "WHEN kind = 'episode' THEN 'series' " +
                "ELSE 'other' END AS bucket, COUNT(*) " +
                "FROM media_works WHERE merged_into IS NULL GROUP BY bucket",
            null,
        ).use { c ->
            while (c.moveToNext()) {
                out[c.getString(0) ?: MediaCategoryNames.OTHER] = c.getInt(1)
            }
        }
        return out
    }

    /**
     * 「看过但没看完」的作品数 —— 给筛选行上的角标用。
     *
     * ⛔ **按并集数**（2026-10-07 修）：归一之后源行的 `group_key` 从不改写，
     *    只 `JOIN … ON i.group_key = w.key` 会把「进度全在被折走的那一半里」
     *    的作品漏掉 —— 角标少一个，而列表里那部作品明明有进度条。
     *    与 [itemsForWork] / [unionStats] 同口径。
     *
     * ⛔ 别写成 `JOIN … ON i.group_key = w.key OR i.group_key IN (SELECT …)`：
     *    那个 `OR` 让 SQLite 用不上自动索引（同一张表上实测 4.9 秒 vs 1 毫秒）。
     *    这里用 `src` 那个 CTE 的两段 `UNION ALL`（每条腿都是等值连接）。
     */
    fun unfinishedCount(): Int = require().rawQuery(
        "WITH src AS (" +
            "  SELECT t.key AS tgt, t.key AS src FROM media_works t " +
            "   WHERE t.merged_into IS NULL " +
            "  UNION ALL " +
            "  SELECT s.merged_into AS tgt, s.key AS src FROM media_works s " +
            "   WHERE s.merged_into IS NOT NULL) " +
            "SELECT COUNT(DISTINCT s.tgt) FROM src s " +
            "JOIN media_items i ON i.group_key = s.src " +
            "WHERE i.resume_position_ms > 0",
        null,
    ).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    /**
     * 一部作品下的所有文件。
     *
     * 排序：**季 → 部 → 集**，都没标号的排最后。这个顺序就是详情页文件列表的
     * 顺序，也是「自动连播下一集」的依据。
     *
     * ## ⛔ 必须按**并集**取，而且别名 key 要先向上解析（2026-10-07 修）
     *
     * 跨目录归一之后**源行的 `group_key` 从不改写**（`mergeWorksInto` 只给源
     * 作品打一个 `merged_into` 标记），所以「这部作品有哪些文件」的正确答案是
     *
     * ```
     * 自己名下的  ∪  所有已折叠进来的源作品名下的
     * ```
     *
     * 只查 `group_key = ?` 的后果（用户现场原话）：
     * > 「恢复相同的媒体库备份，『遮天』这个剧集在 TV 端简介页中文件列表
     * >   只有 1 个文件，但是 PC 端有 2 个季以及好多文件，两边完全不一致」
     *
     * 真库形状（`cloudcine.sqlite` 直查）：
     * ```
     * media_works['shroudingtheheavens']   item_count = 1      ← 它自己那一条
     * media_works['z遮天'].merged_into   = 'shroudingtheheavens'  ← 12 条
     * ```
     * ⇒ 旧 SQL 返回 **1**，新 SQL 返回 **13**。
     *
     * ⚠️ 这个缺口**不只影响这一部**：`01尚硅谷嵌入式技术之c语言` 存值 211、
     *    并集 **1292** —— 它此前在电视上少了 1081 个文件。
     *
     * ## ⛔ 为什么还要「向上解析」
     *
     * 调用方给的 key 可能是**别名**：`PlayerActivity.loadSiblings` 拿到的是
     * 当前条目的 `group_key`，而归一之后那正是**源**的 key（`z遮天`）。
     * 拿它去查并集只会查到源自己那 12 条 —— 选集行里永远少一条。
     * 所以先 `merged_into` 往上走一跳（链式合并不允许，一跳就够）。
     *
     * ⛔ [dirsForWorks] / [pendingNewItemCounts] 早就按并集口径写了，只有这里
     *    漏了 —— 而它们两处的注释还把本方法当成并集口径的基准。
     */
    fun itemsForWork(key: String): List<LibraryItem> {
        val owner = ownerKeyOf(key)
        return queryItems(
            "SELECT $ITEM_COLUMNS FROM media_items WHERE group_key IN (" +
                "SELECT key FROM media_works WHERE key = ? OR merged_into = ?) " +
                "ORDER BY (season IS NULL), season, (part IS NULL), part, " +
                "(episode IS NULL), episode, name",
            arrayOf(owner, owner),
        )
    }

    /**
     * 把可能是**别名**的作品 key 解析成真正的作品 key（`merged_into` 指向的那个）。
     *
     * 不是别名、或那一行不存在时原样返回。只走一跳 —— 折叠不允许成链
     * （`mergeWorksInto` 会拒绝把别名当目标），这一点由写侧保证。
     */
    private fun ownerKeyOf(key: String): String {
        val merged = queryString(
            require(),
            "SELECT merged_into FROM media_works WHERE key = ? LIMIT 1",
            arrayOf(key),
        )
        return merged?.takeIf { it.isNotEmpty() } ?: key
    }

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
    // 写：扫描入库
    // ------------------------------------------------------------------

    /**
     * 已有的媒体项 `id → group_key`。
     *
     * ⛔ 扫描**必须**先查这个再决定怎么分组：库里那些行是 PC 端按它自己的解析器
     *    分好的组，而 Android 侧的解析器是移植版 —— 两边对同一个文件给出**不同**
     *    `group_key` 是完全可能的（PC 端加了一条新规则、或移植时的边角差异）。
     *    不复用的话，一次「重新扫描」会把整库拆成两份：原来那部剧还在，旁边
     *    又多出一部同名的、只含新扫到的那几集。
     *
     * 分批查（`IN` 里最多 400 个占位符）：SQLite 的变量上限是 999，而一次扫描
     * 能扫出几千个文件 —— 一次拼完会直接抛 `too many SQL variables`。
     */
    fun groupKeysOf(ids: Collection<String>): Map<String, String> {
        if (ids.isEmpty()) return emptyMap()
        val out = HashMap<String, String>(ids.size * 2)
        val d = require()
        for (chunk in ids.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "SELECT id, group_key FROM media_items WHERE id IN ($marks)",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) out[c.getString(0)] = c.getString(1)
            }
        }
        return out
    }

    /** 库里已有的全部作品 key（扫描时用来判断「这部是不是新的」）。 */
    fun workKeys(): Set<String> {
        val out = HashSet<String>(512)
        require().rawQuery("SELECT key FROM media_works", null).use { c ->
            while (c.moveToNext()) out.add(c.getString(0))
        }
        return out
    }

    /**
     * 扫描结果入库。
     *
     * ## ⛔ 为什么不用 `INSERT OR REPLACE`
     *
     * `REPLACE` 在冲突时是**先 DELETE 再 INSERT** —— 那会把 `resume_position_ms`、
     * `max_position_ms`、`last_played_at`、`first_seen_at` 一起抹掉。
     * 用户重扫一次库，全部观看进度归零，而这件事**不会报错**。
     *
     * ## ⛔ 为什么也不用 `ON CONFLICT … DO UPDATE`
     *
     * 那是 SQLite **3.24（2018-06）**才有的语法，而本机目标设备的 SQLite 是
     * 随 Android 9 一起发布的 3.22 —— 语法不支持，运行期直接抛。
     *
     * 所以这里**显式分两支**：已存在的行只更新「文件事实」那几列（大小 / 修改时间 /
     * 容器 / 分辨率 / 编码 / 花絮标记），新行才整行插入。分成两支还有一个好处：
     * 「扫描到底改了哪些列」这件事在代码里是看得见的，而不是藏在一条 SQL 里。
     *
     * 返回 `(新增, 更新)`。
     */
    fun applyScanItems(items: List<ScanItem>, nowSec: Long = nowSec()): Pair<Int, Int> {
        if (items.isEmpty()) return 0 to 0
        val d = require()
        val existing = groupKeysOf(items.map { it.id })
        var inserted = 0
        var updated = 0
        d.beginTransaction()
        try {
            for (it in items) {
                if (existing.containsKey(it.id)) {
                    d.update(
                        "media_items",
                        ContentValues().apply {
                            put("name", it.name)
                            put("dir_id", it.dirId)
                            put("dir_path", it.dirPath)
                            it.sizeBytes?.let { v -> put("size_bytes", v) } ?: putNull("size_bytes")
                            it.modifiedAtSec?.let { v -> put("modified_at", v) } ?: putNull("modified_at")
                            // ⛔ 与新增分支同一条规矩：这三个**只在拿到值时才写**。
                            //    服务端这次没告诉我们时长，不等于这个文件没有时长 ——
                            //    写成 NULL 会把上一次的好值抹掉。
                            it.durationMs?.let { v -> put("duration_ms", v) }
                            it.videoWidth?.let { v -> put("video_width", v) }
                            it.videoHeight?.let { v -> put("video_height", v) }
                            put("container", it.container)
                            it.resolution?.let { v -> put("resolution", v) } ?: putNull("resolution")
                            it.source?.let { v -> put("source", v) } ?: putNull("source")
                            it.videoCodec?.let { v -> put("video_codec", v) } ?: putNull("video_codec")
                            it.audioCodec?.let { v -> put("audio_codec", v) } ?: putNull("audio_codec")
                            put("flags", jsonArray(it.flags))
                            it.releaseGroup?.let { v -> put("release_group", v) }
                                ?: putNull("release_group")
                            put("is_sample_or_extra", if (it.isSampleOrExtra) 1 else 0)
                            put("updated_at", nowSec)
                        },
                        "id = ?",
                        arrayOf(it.id),
                    )
                    updated++
                } else {
                    d.insert(
                        "media_items",
                        // `nullColumnHack`：SQLite 的 `INSERT` 在「一个列都没给」时会
                        // 语法错误，这个参数就是那种情况下的兜底列名。我们每行都给了
                        // 一堆 NOT NULL 列，用不上它 —— 但这个参数**不能省**，
                        // 它没有 2 参数的重载。
                        null,
                        ContentValues().apply {
                            put("id", it.id)
                            put("provider", it.provider)
                            put("file_id", it.fileId)
                            put("name", it.name)
                            put("dir_id", it.dirId)
                            put("dir_path", it.dirPath)
                            put("group_key", it.groupKey)
                            put("kind", it.kind)
                            it.title?.let { v -> put("title", v) } ?: putNull("title")
                            it.year?.let { v -> put("year", v) } ?: putNull("year")
                            it.season?.let { v -> put("season", v) } ?: putNull("season")
                            it.episode?.let { v -> put("episode", v) } ?: putNull("episode")
                            it.episodeEnd?.let { v -> put("episode_end", v) }
                                ?: putNull("episode_end")
                            it.part?.let { v -> put("part", v) } ?: putNull("part")
                            it.partLabel?.let { v -> put("part_label", v) }
                                ?: putNull("part_label")
                            put("container", it.container)
                            it.resolution?.let { v -> put("resolution", v) } ?: putNull("resolution")
                            it.sizeBytes?.let { v -> put("size_bytes", v) } ?: putNull("size_bytes")
                            it.modifiedAtSec?.let { v -> put("modified_at", v) } ?: putNull("modified_at")
                            // ⛔ 这三个**只在拿到值时才写**（不像邻居那样写 NULL）。
                            //    它们表达的是「服务端告诉我们多长 / 多大」，
                            //    拿不到 ≠ 文件没有时长。写成 NULL 会把上一次
                            //    扫到的（或 PC 端刮到的）好值抹掉，而「继续观看」
                            //    的进度条正是靠 `duration_ms > 0` 才画得出来。
                            it.durationMs?.let { v -> put("duration_ms", v) }
                            it.videoWidth?.let { v -> put("video_width", v) }
                            it.videoHeight?.let { v -> put("video_height", v) }
                            it.source?.let { v -> put("source", v) } ?: putNull("source")
                            it.videoCodec?.let { v -> put("video_codec", v) } ?: putNull("video_codec")
                            it.audioCodec?.let { v -> put("audio_codec", v) } ?: putNull("audio_codec")
                            put("flags", jsonArray(it.flags))
                            it.releaseGroup?.let { v -> put("release_group", v) }
                                ?: putNull("release_group")
                            put("is_sample_or_extra", if (it.isSampleOrExtra) 1 else 0)
                            it.thumbUrl?.let { v -> put("thumb_url", v) } ?: putNull("thumb_url")
                            it.faceAnchorX?.let { v -> put("face_anchor_x", v) }
                                ?: putNull("face_anchor_x")
                            // ⛔ 新行才写 `first_seen_at`：「入库时间」是「最近添加」
                            //    排序的依据，重扫不该把它刷新成现在。
                            put("first_seen_at", nowSec)
                            put("updated_at", nowSec)
                        },
                    )
                    inserted++
                }
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
        return inserted to updated
    }

    /**
     * 补建**缺失的**作品行。
     *
     * ⛔ 用 `INSERT OR IGNORE`，**绝不更新已存在的行**。已有的作品行上挂着
     *    刮削结果（片名 / 年份 / 简介 / 海报 / 类型 / 评分）和用户手改过的分类
     *    （`category_manual` / `genres_manual`）—— 扫描是「发现文件」，不是
     *    「重算元数据」。覆盖掉的话，用户重扫一次库，海报和简介全没了。
     *
     * 返回新建的作品数。
     */
    fun insertMissingWorks(works: List<ScanWork>, nowSec: Long = nowSec()): Int {
        if (works.isEmpty()) return 0
        val d = require()
        var n = 0
        d.beginTransaction()
        try {
            for (w in works) {
                val row = ContentValues().apply {
                    put("key", w.key)
                    put("provider", w.provider)
                    put("kind", w.kind)
                    put("category", w.category)
                    put("title", w.title)
                    w.year?.let { v -> put("year", v) } ?: putNull("year")
                    // 兜底封面：网盘缩略图。**不覆盖**已有作品行（见本函数的
                    // `CONFLICT_IGNORE`），所以这里只在「新作品」时落一次。
                    w.posterUrl?.let { v -> put("poster_url", v) }
                    put("genres", "[]")
                    // `source = 'local'` —— 「已刮削」的判据是 `source = 'online'`，
                    // 所以本地扫出来的作品**不会**被算成已刮削（这是对的：
                    // 它的片名 / 年份都还没核实过）。
                    put("source", "local")
                    put("item_count", w.itemCount)
                    put("total_bytes", w.totalBytes)
                    put("season_count", w.seasonCount)
                    w.lastModifiedAt?.let { v -> put("last_modified_at", v) }
                        ?: putNull("last_modified_at")
                    put("first_seen_at", nowSec)
                    put("updated_at", nowSec)
                }
                n += d.insertWithOnConflict(
                    "media_works",
                    null,
                    row,
                    android.database.sqlite.SQLiteDatabase.CONFLICT_IGNORE,
                ).let { if (it == -1L) 0 else 1 }
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
        return n
    }

    /**
     * 重算受影响作品的三个冗余列（`item_count` / `total_bytes` / `season_count`）
     * 与 `last_modified_at`。
     *
     * ⛔ 必须重算：卡片上要显示「24 集」而不想每次 `COUNT(*)`，所以那三列是
     *    冗余存储。新扫进来的文件不重算的话，卡片会一直写着旧数字 ——
     *    用户刚扫完看到数字没变，只会以为扫描没生效。
     *
     * ⛔ 口径是**存值**（只看 `group_key` 等于这个 key 的行），不是
     *    `listWorks` 那套并集口径：折叠进来的源作品的文件由 `listWorks` 在读的
     *    时候并进去，这里若再并一次就会被数两遍。
     */
    fun refreshWorkStats(keys: Collection<String>, nowSec: Long = nowSec()) {
        if (keys.isEmpty()) return
        val d = require()

        // ① 一条 `GROUP BY` 把参与统计的行算完。
        //
        // ⛔ 不要写成「每个 key 一条带 4 个相关子查询的 UPDATE」：`media_items.group_key`
        //    上**没有索引**，那种写法是「作品数 × 4 × 全表扫描」——
        //    实测口径下几百部作品就要几十秒，而这段时间里库是被写事务占住的。
        //    `GROUP BY` 只扫一遍表，之后按主键更新是纯值写入（微秒级）。
        val stats = HashMap<String, Stat>(keys.size * 2)
        for (chunk in keys.chunked(400)) {
            val marks = chunk.joinToString(",") { "?" }
            d.rawQuery(
                "SELECT group_key, COUNT(*), COALESCE(SUM(size_bytes), 0), " +
                    "COUNT(DISTINCT CASE WHEN season > 0 THEN season END), " +
                    "MAX(modified_at) " +
                    "FROM media_items WHERE group_key IN ($marks) GROUP BY group_key",
                chunk.toTypedArray(),
            ).use { c ->
                while (c.moveToNext()) {
                    stats[c.getString(0)] = Stat(
                        items = c.getLong(1),
                        bytes = c.getLong(2),
                        seasons = c.getInt(3),
                        lastModifiedAt = if (c.isNull(4)) null else c.getLong(4),
                    )
                }
            }
        }

        // ② 按主键逐条更新。
        //
        // ⛔ 查不到聚合行的 key 要写**零**而不是跳过：那正是「这部作品的文件
        //    全被清掉了」的情况，跳过的话卡片会一直显示旧集数。
        d.beginTransaction()
        try {
            for (key in keys) {
                val s = stats[key]
                d.execSQL(
                    "UPDATE media_works SET item_count = ?, total_bytes = ?, " +
                        "season_count = ?, last_modified_at = ?, updated_at = ? " +
                        "WHERE key = ?",
                    arrayOf<Any?>(
                        s?.items ?: 0L,
                        s?.bytes ?: 0L,
                        s?.seasons ?: 0,
                        s?.lastModifiedAt,
                        nowSec,
                        key,
                    ),
                )
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
    }

    /** [refreshWorkStats] 用的一行聚合结果。 */
    private data class Stat(
        val items: Long,
        val bytes: Long,
        val seasons: Int,
        val lastModifiedAt: Long?,
    )

    /**
     * 清理「网盘侧已经不存在」的陈旧媒体项。
     *
     * 口径与 PC 端 `MediaRepositoryImpl.deleteItemsNotIn` **一致**：
     *   * 只删 `media_items`（**不删 `media_works`** —— 作品行上挂着刮削结果与
     *     用户手改的分类，删了要重刮；计数由 [refreshWorkStats] 重算成 0，
     *     列表里会显示「0 集」而不是凭空消失）；
     *   * 删完顺手清**孤儿**字幕引用与播放偏好（两张表都挂在 `item_id` 上，
     *     而它们与 `media_items` 之间**没有外键** —— 不手动清就永远躺在表里，
     *     在任何界面上都看不到）。
     *
     * ## ⛔ 白名单式删除在「白名单本身不完整」时是有害的
     *
     * 调用方必须保证 [keep] 是**本次完整扫描**扫到的全部 id，并且**中途没有
     * 目录列失败**。少一个目录就会把那个目录下的文件全判成「已删除」，
     * 连带着把它们的播放进度一起删掉。守在哪一侧？—— 守在这里太晚了
     * （函数看不出白名单完不完整），所以守 [LibraryScanner] 那三个前置条件。
     *
     * 分批删（`IN` 里最多 400 个占位符）：一次扫出几千个文件，
     * 拼一条超长 `IN` 会直接抛 `too many SQL variables`（SQLite 上限 999）。
     */
    fun pruneMissingItems(provider: String, keep: Set<String>): Int {
        // 先把「库里在、白名单里没有」的 id 收齐，再按批删。
        // ⛔ 不用 `NOT IN (几千个)`：同样是变量上限问题，而且大 `NOT IN`
        //    在 SQLite 3.22 上走的是全表扫 + 逐个比较，比按主键 `IN` 删慢得多。
        val gone = ArrayList<String>(256)
        require().rawQuery(
            "SELECT id FROM media_items WHERE provider = ?",
            arrayOf(provider),
        ).use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                if (!keep.contains(id)) gone.add(id)
            }
        }
        if (gone.isEmpty()) return 0

        val d = require()
        var n = 0
        d.beginTransaction()
        try {
            for (chunk in gone.chunked(400)) {
                val marks = chunk.joinToString(",") { "?" }
                n += d.delete("media_items", "id IN ($marks)", chunk.toTypedArray())
            }
            if (n > 0) {
                d.execSQL(
                    "DELETE FROM subtitle_refs WHERE item_id NOT IN " +
                        "(SELECT id FROM media_items)",
                )
                d.execSQL(
                    "DELETE FROM playback_prefs WHERE item_id NOT IN " +
                        "(SELECT id FROM media_items)",
                )
            }
            d.setTransactionSuccessful()
        } finally {
            d.endTransaction()
        }
        return n
    }

    private fun jsonArray(items: List<String>): String {
        if (items.isEmpty()) return "[]"
        return items.joinToString(",", "[", "]") { "\"" + it.replace("\"", "\\\"") + "\"" }
    }

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
                        // ⛔ 钳到 [0,1]：position 越过 duration（片尾曲/时长估短）时
                        //    进度条不能溢出格子。0 也归 null —— 「看过 0 秒」不画条。
                        resumeFraction = c.doubleOrNull("resume_fraction")
                            ?.takeIf { it > 0.0 }
                            ?.coerceAtMost(1.0),
                        // 追剧三列（schema v17）。读不到就当「没在追」——
                        // 老库刚升级完那一次正是这个状态，与升级前表现一致。
                        followed = c.boolOrFalse("followed"),
                        followStartedAt = c.longOrNull("follow_started_at"),
                        newItemCount = c.intOrNull("new_item_count") ?: 0,
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
                        // ⛔ **秒** —— 全库时间列都是秒（`LibraryDb` 类注释）。
                        //    这里换算成毫秒，好与网盘那边的 `updatedAtMs` 同单位。
                        //    ⛔ 字段名里的 `Ms` 就是这件事的**唯一**提醒：界面层
                        //    再乘一次 1000 会得到公元 5 万年的时刻，而
                        //    `Fmt.relativeTime` 只会把它显示成「刚刚」——
                        //    2026-10-07 真的这么错过一次（简介页三行全「刚刚」）。
                        modifiedAtMs = c.longOrNull("modified_at")?.let { it * 1000L },
                        thumbUrl = c.strOrNull("thumb_url"),
                        faceAnchorX = c.doubleOrNull("face_anchor_x"),
                        videoWidth = c.intOrNull("video_width"),
                        videoHeight = c.intOrNull("video_height"),
                        isSampleOrExtra = c.boolOrFalse("is_sample_or_extra"),
                        // ⛔ **秒**，与其它时间列同单位（不是 `modifiedAtMs`）。
                        //    剧集行 NEW 标签的基线就是它（`Work.isNewSinceFollow`）。
                        firstSeenAt = c.longOrNull("first_seen_at"),
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

        /**
         * 作品级列清单。
         *
         * ⛔ `resume_fraction` 是**相关子查询**，不是表上的列 —— 它引用外层表名
         *    `media_works`，所以 `SELECT $WORK_COLUMNS` 的外层 FROM **必须**是
         *    `media_works` 本身、**不能起别名**（`FROM media_works w` 会让 SQLite
         *    找不到 `media_works.key` 而直接报错）。
         * ⛔ 用 `MAX(CASE WHEN …)` 而不是 `MAX(resume/duration)`：`duration_ms` 为 0
         *    或 NULL 的项会产生 NULL，SQLite 的 `MAX` **忽略 NULL**，所以两种写法
         *    在正常数据上等价；但显式 CASE 把「除零」写死成不参与比较，语义更硬。
         */
        private const val WORK_COLUMNS =
            "key, kind, category, title, original_title, year, overview, poster_url, " +
                "poster_file, poster_face_x, rating, genres, source, item_count, " +
                "total_bytes, season_count, last_modified_at, first_seen_at, last_played_at, " +
                // 追剧三列（schema v17）。⛔ `follow_checked_at` **刻意不在这里**：
                // 它是检查期的水位线，只出现在 `applyFollowCheck` 的写语句里，
                // 界面从来不看它 —— 与「不要为了完整把 31 列全搬进来」同一条。
                "followed, follow_started_at, new_item_count, " +
                // ⛔ **这里只查自己名下的**，不许把并集塞进来 —— 实测（真库
                //    201 部 / 2866 条）：这个相关子查询写等值时 SQLite 会给
                //    `media_items.group_key` 建**自动索引**，500 行 21ms；一旦
                //    改成 `IN (SELECT …)` 或 `… OR … IN (SELECT …)`，自动索引
                //    就用不上了，同样的查询变成 **7.5 秒 / 4.9 秒**（逐行全表扫）。
                //    并集口径的进度由 [withUnionStats] 那条**页级**查询补
                //    （和三个计数一起算，实测 4ms）。
                "(SELECT MAX(CASE WHEN i.duration_ms > 0 AND i.resume_position_ms > 0 " +
                "THEN CAST(i.resume_position_ms AS REAL) / i.duration_ms END) " +
                "FROM media_items i WHERE i.group_key = media_works.key) AS resume_fraction"

        private const val ITEM_COLUMNS =
            "id, provider, file_id, dir_id, name, dir_path, group_key, kind, title, year, season, " +
                "episode, episode_end, part, part_label, container, resolution, size_bytes, " +
                "duration_ms, resume_position_ms, max_position_ms, last_played_at, " +
                // ⛔ `modified_at` 之前**没有读出来**：它是「哪几个是刚传的」的
                //    唯一依据（文件列表默认就按它倒序），而这一列从扫描那一刻
                //    起就写在库里 —— 只是没人把它读进 `LibraryItem`。
                "modified_at, " +
                // ⛔ `first_seen_at` 同理：schema v1 就有，直到 v17 的追剧
                //    「新集」标签才第一次被界面用到。它**只在行首次插入时写**，
                //    所以是「这一集什么时候第一次出现在库里」的历史事实 ——
                //    不能拿 `modified_at` 代替（换一版更高码率也会变）。
                "first_seen_at, " +
                "thumb_url, face_anchor_x, video_width, video_height, is_sample_or_extra"

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

        /**
         * 布尔列（库里存 0/1）。
         *
         * ⛔ 读不到就当 `false`：`is_sample_or_extra` 的默认值就是 false，
         *    而**认成「是花絮」会让那条文件从「点卡片直接播」的候选里消失** ——
         *    症状是「点海报没反应」，比误播一条花絮难查得多。
         */
        private fun Cursor.boolOrFalse(name: String): Boolean {
            val i = getColumnIndexOrThrow(name)
            return !isNull(i) && getInt(i) != 0
        }
    }
}
