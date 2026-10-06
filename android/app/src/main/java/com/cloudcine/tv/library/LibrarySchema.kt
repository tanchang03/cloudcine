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
    const val VERSION = 16

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
        if (c.notNull) sb.append(" NOT NULL")
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
