package com.cloudcine.tv.library

/**
 * 媒体库索引库的 **schema 契约**。
 *
 * ⛔ 这个文件里的每一个表名、列名、类型、默认值，都是**照着 PC 端（Flutter）
 * 的 drift 生成结果逐字抄的**，不是「按语义重新设计」的。理由是跨端同步：
 *
 *   * 备份包（`.ccbak`）里装的是 **SQLite 文件的原始字节**；
 *   * PC 端 restore 之后直接 `user_version` 一看，等于 16 就**不再跑迁移**，
 *     直接拿它当自己的库用；
 *   * 所以 Android 导出的库，列名差一个字母，PC 端那边就是
 *     `no such column: xxx` —— 而且**不会**有迁移来兜底。
 *
 * 生成 DDL 的规则也与 drift 一致（`"name" TYPE [NOT NULL] [DEFAULT x] [CHECK …]`，
 * 主键统一写在末尾的 `PRIMARY KEY (…)`），这样 `LibrarySchemaTest` 可以拿
 * PC 端 dump 出来的原文做**逐字比对**，而不是靠人眼看。
 *
 * ⚠️ 单位约定（与 drift 一致）：
 *   * 时间列一律存 **Unix 秒**（不是毫秒）—— drift 的 `DateTimeColumn` 默认口径；
 *   * 布尔列存 **0/1 整数**，并带 `CHECK (… IN (0, 1))`；
 *   * `flags` / `genres` / `pending_dirs` / `prefs` 存 **JSON 字符串**。
 */
object LibrarySchema {

    /** 库文件名。与 PC 端 `openAppDatabase()` 里那个名字**必须一致**。 */
    const val FILE_NAME = "cloudcine.sqlite"

    /**
     * 当前 schema 版本，写进 SQLite 的 `user_version`。
     *
     * ⛔ 与 PC 端 `AppDatabase.schemaVersion` 必须相等。写小了 → PC 端 restore
     * 后会跑一遍迁移（多数是 `ADD COLUMN`，会直接报 duplicate column）；
     * 写大了 → PC 端直接判定「来自更高版本的数据库」并只打一条 warn。
     */
    const val VERSION = 17

    /** 一列的定义。 */
    data class Column(
        val name: String,
        val type: String,
        val notNull: Boolean,
        /** `DEFAULT` 后面的原文，`null` = 没有默认值。 */
        val default: String? = null,
        /** `CHECK` 括号里的条件原文，`null` = 没有约束。 */
        val check: String? = null,
    )

    /** 一张表的定义。 */
    data class Table(
        val name: String,
        val columns: List<Column>,
        val primaryKey: List<String>,
    )

    // ------------------------------------------------------------------
    // 工具：把上面的结构拼成与 drift 逐字一致的 DDL
    // ------------------------------------------------------------------

    /** 生成 `CREATE TABLE`。`ifNotExists` 给「补齐缺失的表」那条路用。 */
    fun createSql(table: Table, ifNotExists: Boolean = false): String {
        val head = if (ifNotExists) "CREATE TABLE IF NOT EXISTS" else "CREATE TABLE"
        val cols = table.columns.joinToString(", ") { columnSql(it) }
        val pk = table.primaryKey.joinToString(", ") { q(it) }
        return "$head ${q(table.name)} ($cols, PRIMARY KEY ($pk))"
    }

    /** 生成 `ALTER TABLE … ADD COLUMN`（补齐缺失的列）。 */
    fun addColumnSql(table: Table, column: Column): String =
        "ALTER TABLE ${q(table.name)} ADD COLUMN ${columnSql(column)}"

    private fun columnSql(c: Column): String {
        val sb = StringBuilder("${q(c.name)} ${c.type}")
        // ⛔ drift **显式写出可空性**（可空列也带 ` NULL`），不是省略。
        //    省略在 SQLite 里语义相同，但会让这里的逐字比对永远差几个字符，
        //    而「比对失败」正是这个文件唯一的验收方式 —— 所以照抄。
        sb.append(if (c.notNull) " NOT NULL" else " NULL")
        c.default?.let { sb.append(" DEFAULT $it") }
        c.check?.let { sb.append(" CHECK ($it)") }
        return sb.toString()
    }

    private fun q(ident: String) = "\"$ident\""

    /** 布尔列在 drift 里就是 `INTEGER NOT NULL DEFAULT 0 CHECK (… IN (0, 1))`。 */
    private fun bool(name: String, default: Int = 0) = Column(
        name = name,
        type = "INTEGER",
        notNull = true,
        default = "$default",
        check = "\"$name\" IN (0, 1)",
    )

    private fun text(name: String, notNull: Boolean = false, default: String? = null) =
        Column(name, "TEXT", notNull, default)

    private fun int(name: String, notNull: Boolean = false, default: Int? = null) =
        Column(name, "INTEGER", notNull, default?.toString())

    private fun real(name: String) = Column(name, "REAL", notNull = false)

    // ------------------------------------------------------------------
    // 7 张表
    // ------------------------------------------------------------------

    val mediaItems = Table(
        name = "media_items",
        columns = listOf(
            text("id", notNull = true),
            text("provider", notNull = true),
            text("file_id", notNull = true),
            text("name", notNull = true),
            text("dir_id", notNull = true, default = "''"),
            text("dir_path", notNull = true, default = "'/'"),
            text("group_key", notNull = true),
            text("kind", notNull = true),
            text("title"),
            int("year"),
            int("season"),
            int("episode"),
            int("episode_end"),
            int("part"),
            text("part_label"),
            text("container", notNull = true, default = "'other'"),
            text("resolution"),
            int("size_bytes"),
            int("modified_at"),
            int("duration_ms"),
            text("source"),
            text("video_codec"),
            text("audio_codec"),
            text("flags", notNull = true, default = "'[]'"),
            text("release_group"),
            bool("is_sample_or_extra"),
            int("first_seen_at", notNull = true),
            int("updated_at", notNull = true),
            int("last_played_at"),
            int("resume_position_ms"),
            int("max_position_ms"),
            text("thumb_url"),
            real("face_anchor_x"),
            int("video_width"),
            int("video_height"),
        ),
        primaryKey = listOf("id"),
    )

    val mediaWorks = Table(
        name = "media_works",
        columns = listOf(
            text("key", notNull = true),
            text("provider", notNull = true),
            text("kind", notNull = true),
            // ⛔ 默认是**空串**（= 还没判定过），不是 'other'（= 判过了，认不出来）。
            text("category", notNull = true, default = "''"),
            bool("category_manual"),
            text("title", notNull = true),
            text("original_title"),
            int("year"),
            text("overview"),
            text("poster_url"),
            text("poster_file"),
            real("poster_face_x"),
            text("backdrop_url"),
            text("backdrop_file"),
            real("rating"),
            text("genres", notNull = true, default = "'[]'"),
            bool("genres_manual"),
            text("online_id"),
            text("source", notNull = true),
            int("scraped_at"),
            int("item_count", notNull = true, default = 0),
            int("total_bytes", notNull = true, default = 0),
            int("season_count", notNull = true, default = 0),
            int("last_modified_at"),
            int("first_seen_at"),
            int("last_played_at"),
            int("updated_at", notNull = true),
            text("merged_into"),
            int("intro_start_ms"),
            int("intro_end_ms"),
            // v17：追剧 / 更新提醒。四列一组，缺一列这个功能就不成立。
            // ⛔ 默认值 `0` / `NULL` / `NULL` / `0` 恰好表达「这部作品没在追剧」，
            //    所以升级不需要回填，行为与升级前完全一致。
            bool("followed"),
            int("follow_started_at"),
            int("follow_checked_at"),
            int("new_item_count", notNull = true, default = 0),
        ),
        primaryKey = listOf("key"),
    )

    val subtitleRefs = Table(
        name = "subtitle_refs",
        columns = listOf(
            text("id", notNull = true),
            text("item_id", notNull = true),
            text("origin", notNull = true),
            text("label", notNull = true),
            text("format", notNull = true),
            text("language_code"),
            text("language_label"),
            text("file_id"),
            text("file_name"),
            text("local_path"),
            int("embedded_track_id"),
            bool("is_forced"),
            bool("is_sdh"),
            bool("is_default"),
        ),
        primaryKey = listOf("id"),
    )

    val scanCursors = Table(
        name = "scan_cursors",
        columns = listOf(
            text("provider", notNull = true),
            text("root_id", notNull = true),
            text("root_path", notNull = true, default = "'/'"),
            text("pending_dirs", notNull = true, default = "'[]'"),
            text("current_dir"),
            text("current_page_token"),
            text("stage", notNull = true),
            int("scanned_dirs", notNull = true, default = 0),
            int("scanned_files", notNull = true, default = 0),
            int("found_tracks", notNull = true, default = 0),
            int("total_bytes", notNull = true, default = 0),
            int("failed_dirs", notNull = true, default = 0),
            text("last_error"),
            int("updated_at", notNull = true),
        ),
        primaryKey = listOf("provider"),
    )

    val settings = Table(
        name = "settings",
        columns = listOf(
            text("key", notNull = true),
            text("value", notNull = true),
        ),
        primaryKey = listOf("key"),
    )

    val playbackPrefs = Table(
        name = "playback_prefs",
        columns = listOf(
            text("item_id", notNull = true),
            text("group_key", notNull = true),
            text("prefs", notNull = true, default = "'{}'"),
            int("updated_at", notNull = true),
        ),
        primaryKey = listOf("item_id"),
    )

    val downloadTasks = Table(
        name = "download_tasks",
        columns = listOf(
            text("id", notNull = true),
            text("provider", notNull = true),
            text("file_id", notNull = true),
            text("name", notNull = true),
            text("dir_path", notNull = true, default = "'/'"),
            text("save_path", notNull = true),
            int("size_bytes"),
            int("received_bytes", notNull = true, default = 0),
            text("status", notNull = true),
            text("error"),
            int("created_at", notNull = true),
            int("updated_at", notNull = true),
        ),
        primaryKey = listOf("id"),
    )

    /** 全部表，**顺序与 PC 端 `@DriftDatabase(tables: […])` 一致**（便于人工比对）。 */
    val TABLES: List<Table> = listOf(
        mediaItems,
        mediaWorks,
        subtitleRefs,
        scanCursors,
        settings,
        playbackPrefs,
        downloadTasks,
    )

    // ------------------------------------------------------------------
    // 设置键（`settings` 表里的 key）—— 只列我们真的要读写的
    // -------------------------------------------------------------------

    /**
     * 「记住播放进度」的开关。
     *
     * ⚠️ 键名照抄 PC 端 `SettingKeys.rememberPosition`（值是 `remember_position`，
     * 不是包了命名空间的那种写法）。它关掉时**不该写** `resume_position_ms`，
     * 否则用户关了开关、回电脑上还是从中间开始播。
     *
     * ⚠️ 判据是 `!= 'false'`（缺失即开），与 PC 端
     * `desktop_play.dart` / `player_bridge_host.dart` 两处一致 ——
     * 写成 `== 'true'` 会让新装用户永远不记进度。
     */
    const val KEY_REMEMBER_PROGRESS = "remember_position"
}

/**
 * 刮削凭证的键名 —— **与 PC 端 `lib/data/db/settings_store.dart` 的 `SettingKeys`
 * 逐字一致**。
 *
 * ## 为什么键名是跨端契约的一部分
 *
 * 备份包（`.ccbak`）里装的是**整个 `cloudcine.sqlite` 文件的原始字节**，
 * `settings` 表随之一起走。所以：
 *
 *   * 在电脑上填好的 TMDB 反代地址，同步到电视上**直接可用**；
 *   * 键名差一个字母，电视上就是「没配」—— 而**两边都不会报错**，
 *     用户看到的现象是「明明电脑上能刮，电视上刮不到」。
 *
 * 这就是为什么这几个常量集中在这里，而不是散在设置页与刮削器里各写一份字面量。
 */
object LibrarySettings {
    /** TMDB API Key。空串 = 不启用 TMDB 源。 */
    const val TMDB_API_KEY = "tmdb_api_key"

    /** TMDB API 的 Base URL（境内需自建反代）。空 = 用官方地址。 */
    const val TMDB_API_BASE = "tmdb_api_base"

    /**
     * TMDB 图片 CDN 的 Base URL。**与 [TMDB_API_BASE] 是两个域名**，必须分开配
     * —— 反代经常只覆盖其中一个，合成一个的话「API 通了但图片下不来」没法修。
     */
    const val TMDB_IMAGE_BASE = "tmdb_image_base"

    /** 豆瓣登录后的 Cookie。空 = 走匿名额度（实测约 10 个搜索词）。 */
    const val DOUBAN_COOKIE = "douban_cookie"

    /**
     * 「扫描后自动刮削」开关。
     *
     * ⛔ 键名与 PC 端 `SettingKeys.autoScrapeOnScan` **逐字一致**
     *    （`auto_scrape_on_scan`）—— 它在 `settings` 表里、随备份包跨端走。
     *
     * ⚠️ **两端的默认值刻意不同，连判据的方向都相反**：
     *
     * | | 判据 | 缺失时 |
     * |---|---|---|
     * | PC | `== "true"` | 关 |
     * | Android | `!= "false"` | **开** |
     *
     * PC 端默认**关**：那边是整盘扫描几千个文件，豆瓣匿名额度约 10 个搜索词，
     * 走一遍必然中途耗尽。Android 端默认**开** —— 电视上用户看不到进度细节，
     * 「扫完还得手动去点每一部」的体验比配额更糟，而且 [AutoScraper] 有源级预算
     * 会自己收工。
     *
     * ⛔ Android 侧的判据**刻意是「不等于 `"false"`」**：这一列在 PC 的旧库里
     *    根本不存在（那边默认关），而缺失在电视上应当读成「开」。写成
     *    `== "true"` 的话，从电脑同步过来的库会在电视上默认关掉 ——
     *    用户根本不知道有这么个功能。判据写在 `LibraryActivity.autoScrapeEnabled()`
     *    里，**不在**这里：这里只放键名。
     */
    const val AUTO_SCRAPE_ON_SCAN = "auto_scrape_on_scan"

    /**
     * **追更检查的全局节流零点**（Unix **秒**的十进制字符串）。
     *
     * ⛔ 键名与 PC 端 `SettingKeys.followLastCheckAt` **逐字一致**
     *    （`follow_last_check_at`）—— 它在 `settings` 表里、随备份包跨端走。
     *
     * ⛔ 值是 **Unix 秒**，不是 ISO8601。两端各用各的解析器时（Dart
     *    `toIso8601String` 是本地时间、不带时区后缀、微秒位数还随值变化），
     *    只要有一边按 UTC 解析就会差出整整一个时区，而**两边都不报错**，
     *    表现是「节流窗口时灵时不灵」。Unix 秒没有任何解释空间。
     *    PC 端读它是 `readInt`，这边是 `String.toLongOrNull()`。
     *
     * ## 为什么需要它，而不是只看作品级的 `follow_checked_at`
     *
     * `media_works.follow_checked_at` 是**逐部作品**的（每部剧各自的水位线），
     * 而「要不要现在就发起一次检查」是个**全局**问题 —— 没有这一列的话，
     * 每次进媒体库都要把每一部在追的剧重新查一遍。
     *
     * ## ⛔ 为什么放在 `settings` 表，而不是 `media_works`
     *
     * 同步判据 `libraryModifiedAt()` = `MAX(media_works.updated_at)` ∪
     * `MAX(media_items.first_seen_at)` ∪ `MAX(media_items.last_played_at)`。
     * **`settings` 表不在其中** —— 所以写这个键**不会**让本机「看起来更新」，
     * 也就不会在下一次同步时无条件上传、把另一台设备的进度盖掉。
     *
     * 反过来，如果把它塞进 `media_works`，那么**每次自动检查都会改同步判据**
     * —— 一台常开机的设备会永远赢下 LWW 比较，另一台设备看的进度就永远
     * 同步不上去。这是这个功能里最隐蔽的一条红线。
     */
    const val FOLLOW_LAST_CHECK_AT = "follow_last_check_at"

    /**
     * 自动追更检查的策略。取值见 `FollowAutoCheck`：
     * `off` / `on_launch`（默认）/ `every_6h`。
     *
     * ⛔ 键名与 PC 端 `SettingKeys.followAutoCheck` 逐字一致。
     * ⚠️ 默认值写在 `FollowAutoCheck.parse` 里（只认三个枚举名，其余一律
     *    退回默认），**不在**这里 —— 这里只放键名。
     */
    const val FOLLOW_AUTO_CHECK = "follow_auto_check"

    /**
     * 「刮削设置」那一屏里能填的全部**凭证**键。
     *
     * ⛔ [AUTO_SCRAPE_ON_SCAN] **不在**这个表里：它是个开关、不是凭证，
     *    放进来会让设置页的「当前已填 N 项」把开关也算成一项。
     */
    val SCRAPE_KEYS = listOf(TMDB_API_KEY, TMDB_API_BASE, TMDB_IMAGE_BASE, DOUBAN_COOKIE)
}
