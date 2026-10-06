package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LibrarySchema] 的 DDL 与 PC 端（drift）**逐字比对**。
 *
 * ## 为什么这组断言值得写
 *
 * 下面那些 `EXPECTED_*` 常量是从 PC 端 dump 出来的**原文**
 * （`SELECT sql FROM sqlite_master`，见仓库 `HOWTO.md` §媒体库数据结构）。
 * 它们不是「另一个手写的期望值」—— 是 PC 端真的会建出来的那张表。
 *
 * 备份包装的是 **SQLite 文件的原始字节**，PC 端 restore 之后看
 * `user_version == 16` 就**不再跑迁移**，直接拿它当自己的库用。所以：
 *
 *   * 列名少一个 / 多一个 → PC 端 `no such column`，**没有迁移兜底**；
 *   * `DEFAULT` 值不同 → 新插入的行在两端语义不同（最典型的是
 *     `media_works.category`：空串 = 还没判定过，`'other'` = 判过了认不出来）；
 *   * `user_version` 写错 → 写小了 PC 端跑一遍迁移（`ADD COLUMN` 撞
 *     duplicate column），写大了它只打一条 warn 然后照用。
 *
 * 这三种都**不会**在 Android 这边报任何错。
 */
class LibrarySchemaTest {

    @Test
    fun `user_version 必须是 16`() {
        // 与 PC 端 AppDatabase.schemaVersion 相等。
        assertEquals(16, LibrarySchema.VERSION)
    }

    @Test
    fun `库文件名与 PC 端一致`() {
        assertEquals("cloudcine.sqlite", LibrarySchema.FILE_NAME)
    }

    @Test
    fun `七张表齐全且顺序与 PC 端 DriftDatabase 声明一致`() {
        assertEquals(
            listOf(
                "media_items",
                "media_works",
                "subtitle_refs",
                "scan_cursors",
                "settings",
                "playback_prefs",
                "download_tasks",
            ),
            LibrarySchema.TABLES.map { it.name },
        )
    }

    // ── 逐字比对 ─────────────────────────────────────────────────────

    @Test
    fun `media_items 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.mediaItems,
        EXPECTED_MEDIA_ITEMS,
    )

    @Test
    fun `media_works 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.mediaWorks,
        EXPECTED_MEDIA_WORKS,
    )

    @Test
    fun `subtitle_refs 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.subtitleRefs,
        EXPECTED_SUBTITLE_REFS,
    )

    @Test
    fun `scan_cursors 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.scanCursors,
        EXPECTED_SCAN_CURSORS,
    )

    @Test
    fun `settings 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.settings,
        EXPECTED_SETTINGS,
    )

    @Test
    fun `playback_prefs 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.playbackPrefs,
        EXPECTED_PLAYBACK_PREFS,
    )

    @Test
    fun `download_tasks 建表语句与 drift 输出逐字一致`() = assertDdl(
        LibrarySchema.downloadTasks,
        EXPECTED_DOWNLOAD_TASKS,
    )

    // ── 补表 / 补列 ──────────────────────────────────────────────────

    @Test
    fun `补表用的 DDL 只多 IF NOT EXISTS`() {
        val plain = LibrarySchema.createSql(LibrarySchema.settings)
        val idem = LibrarySchema.createSql(LibrarySchema.settings, ifNotExists = true)
        assertEquals(plain.replace("CREATE TABLE", "CREATE TABLE IF NOT EXISTS"), idem)
    }

    @Test
    fun `补列必须去掉 NOT NULL`() {
        // ⛔ SQLite 的 ALTER TABLE ADD COLUMN 拒绝「NOT NULL 且没有默认值」的列，
        // 而 v16 里 first_seen_at / updated_at 正是这种。跨端互操作只认列名与
        // 类型，NOT NULL 只是写入期的自我约束 —— 为了它把「老库打不开」变成
        // 「库打不开」不划算。
        val col = LibrarySchema.mediaItems.columns.first { it.name == "first_seen_at" }
        assertTrue("前提：这一列在 v16 里是 NOT NULL", col.notNull)

        val sql = LibrarySchema.addColumnSql(LibrarySchema.mediaItems, col.copy(notNull = false))
        // 可空性**照旧显式写出**（`NULL`），与建表语句的写法保持同一套规则 ——
        // 少写一个词在 SQLite 里等价，但会让「补出来的列」与「建出来的列」
        // 在 `PRAGMA table_info` 之外长得不一样，日后比对时多一处噪音。
        assertEquals(
            "ALTER TABLE \"media_items\" ADD COLUMN \"first_seen_at\" INTEGER NULL",
            sql,
        )
    }

    @Test
    fun `补列保留默认值`() {
        val col = LibrarySchema.mediaWorks.columns.first { it.name == "category" }
        assertEquals(
            "ALTER TABLE \"media_works\" ADD COLUMN \"category\" TEXT NULL DEFAULT ''",
            LibrarySchema.addColumnSql(LibrarySchema.mediaWorks, col.copy(notNull = false)),
        )
    }

    // ── 工具 ────────────────────────────────────────────────────────

    private fun assertDdl(table: LibrarySchema.Table, expected: String) {
        val actual = LibrarySchema.createSql(table)
        if (actual != expected) {
            // 直接把第一处差异指出来：整串 assertEquals 的失败信息在
            // 这种几百字符的单行里基本没法读。
            val at = actual.zip(expected).indexOfFirst { (a, b) -> a != b }
                .let { if (it < 0) minOf(actual.length, expected.length) else it }
            val from = maxOf(0, at - 40)
            throw AssertionError(
                "表 ${table.name} 的 DDL 与 PC 端不一致（第 $at 个字符起）：\n" +
                    "  实际：…${actual.substring(from, minOf(actual.length, at + 40))}…\n" +
                    "  期望：…${expected.substring(from, minOf(expected.length, at + 40))}…",
            )
        }
    }

    private companion object {
        // ⛔ 以下均为 PC 端 sqlite_master 的原文，不要「顺手整理格式」。

        const val EXPECTED_MEDIA_ITEMS =
            "CREATE TABLE \"media_items\" (\"id\" TEXT NOT NULL, \"provider\" TEXT NOT NULL, " +
                "\"file_id\" TEXT NOT NULL, \"name\" TEXT NOT NULL, \"dir_id\" TEXT NOT NULL " +
                "DEFAULT '', \"dir_path\" TEXT NOT NULL DEFAULT '/', \"group_key\" TEXT NOT NULL, " +
                "\"kind\" TEXT NOT NULL, \"title\" TEXT NULL, \"year\" INTEGER NULL, \"season\" " +
                "INTEGER NULL, \"episode\" INTEGER NULL, \"episode_end\" INTEGER NULL, \"part\" " +
                "INTEGER NULL, \"part_label\" TEXT NULL, \"container\" TEXT NOT NULL DEFAULT " +
                "'other', \"resolution\" TEXT NULL, \"size_bytes\" INTEGER NULL, \"modified_at\" " +
                "INTEGER NULL, \"duration_ms\" INTEGER NULL, \"source\" TEXT NULL, \"video_codec\" " +
                "TEXT NULL, \"audio_codec\" TEXT NULL, \"flags\" TEXT NOT NULL DEFAULT '[]', " +
                "\"release_group\" TEXT NULL, \"is_sample_or_extra\" INTEGER NOT NULL DEFAULT 0 " +
                "CHECK (\"is_sample_or_extra\" IN (0, 1)), \"first_seen_at\" INTEGER NOT NULL, " +
                "\"updated_at\" INTEGER NOT NULL, \"last_played_at\" INTEGER NULL, " +
                "\"resume_position_ms\" INTEGER NULL, \"max_position_ms\" INTEGER NULL, " +
                "\"thumb_url\" TEXT NULL, \"face_anchor_x\" REAL NULL, \"video_width\" INTEGER " +
                "NULL, \"video_height\" INTEGER NULL, PRIMARY KEY (\"id\"))"

        const val EXPECTED_MEDIA_WORKS =
            "CREATE TABLE \"media_works\" (\"key\" TEXT NOT NULL, \"provider\" TEXT NOT NULL, " +
                "\"kind\" TEXT NOT NULL, \"category\" TEXT NOT NULL DEFAULT '', " +
                "\"category_manual\" INTEGER NOT NULL DEFAULT 0 CHECK (\"category_manual\" IN " +
                "(0, 1)), \"title\" TEXT NOT NULL, \"original_title\" TEXT NULL, \"year\" INTEGER " +
                "NULL, \"overview\" TEXT NULL, \"poster_url\" TEXT NULL, \"poster_file\" TEXT " +
                "NULL, \"poster_face_x\" REAL NULL, \"backdrop_url\" TEXT NULL, \"backdrop_file\" " +
                "TEXT NULL, \"rating\" REAL NULL, \"genres\" TEXT NOT NULL DEFAULT '[]', " +
                "\"genres_manual\" INTEGER NOT NULL DEFAULT 0 CHECK (\"genres_manual\" IN (0, 1)), " +
                "\"online_id\" TEXT NULL, \"source\" TEXT NOT NULL, \"scraped_at\" INTEGER NULL, " +
                "\"item_count\" INTEGER NOT NULL DEFAULT 0, \"total_bytes\" INTEGER NOT NULL " +
                "DEFAULT 0, \"season_count\" INTEGER NOT NULL DEFAULT 0, \"last_modified_at\" " +
                "INTEGER NULL, \"first_seen_at\" INTEGER NULL, \"last_played_at\" INTEGER NULL, " +
                "\"updated_at\" INTEGER NOT NULL, \"merged_into\" TEXT NULL, \"intro_start_ms\" " +
                "INTEGER NULL, \"intro_end_ms\" INTEGER NULL, PRIMARY KEY (\"key\"))"

        const val EXPECTED_SUBTITLE_REFS =
            "CREATE TABLE \"subtitle_refs\" (\"id\" TEXT NOT NULL, \"item_id\" TEXT NOT NULL, " +
                "\"origin\" TEXT NOT NULL, \"label\" TEXT NOT NULL, \"format\" TEXT NOT NULL, " +
                "\"language_code\" TEXT NULL, \"language_label\" TEXT NULL, \"file_id\" TEXT " +
                "NULL, \"file_name\" TEXT NULL, \"local_path\" TEXT NULL, " +
                "\"embedded_track_id\" INTEGER NULL, \"is_forced\" INTEGER NOT NULL DEFAULT 0 " +
                "CHECK (\"is_forced\" IN (0, 1)), \"is_sdh\" INTEGER NOT NULL DEFAULT 0 CHECK " +
                "(\"is_sdh\" IN (0, 1)), \"is_default\" INTEGER NOT NULL DEFAULT 0 CHECK " +
                "(\"is_default\" IN (0, 1)), PRIMARY KEY (\"id\"))"

        const val EXPECTED_SCAN_CURSORS =
            "CREATE TABLE \"scan_cursors\" (\"provider\" TEXT NOT NULL, \"root_id\" TEXT NOT " +
                "NULL, \"root_path\" TEXT NOT NULL DEFAULT '/', \"pending_dirs\" TEXT NOT NULL " +
                "DEFAULT '[]', \"current_dir\" TEXT NULL, \"current_page_token\" TEXT NULL, " +
                "\"stage\" TEXT NOT NULL, \"scanned_dirs\" INTEGER NOT NULL DEFAULT 0, " +
                "\"scanned_files\" INTEGER NOT NULL DEFAULT 0, \"found_tracks\" INTEGER NOT NULL " +
                "DEFAULT 0, \"total_bytes\" INTEGER NOT NULL DEFAULT 0, \"failed_dirs\" INTEGER " +
                "NOT NULL DEFAULT 0, \"last_error\" TEXT NULL, \"updated_at\" INTEGER NOT NULL, " +
                "PRIMARY KEY (\"provider\"))"

        const val EXPECTED_SETTINGS =
            "CREATE TABLE \"settings\" (\"key\" TEXT NOT NULL, \"value\" TEXT NOT NULL, " +
                "PRIMARY KEY (\"key\"))"

        const val EXPECTED_PLAYBACK_PREFS =
            "CREATE TABLE \"playback_prefs\" (\"item_id\" TEXT NOT NULL, \"group_key\" TEXT NOT " +
                "NULL, \"prefs\" TEXT NOT NULL DEFAULT '{}', \"updated_at\" INTEGER NOT NULL, " +
                "PRIMARY KEY (\"item_id\"))"

        const val EXPECTED_DOWNLOAD_TASKS =
            "CREATE TABLE \"download_tasks\" (\"id\" TEXT NOT NULL, \"provider\" TEXT NOT NULL, " +
                "\"file_id\" TEXT NOT NULL, \"name\" TEXT NOT NULL, \"dir_path\" TEXT NOT NULL " +
                "DEFAULT '/', \"save_path\" TEXT NOT NULL, \"size_bytes\" INTEGER NULL, " +
                "\"received_bytes\" INTEGER NOT NULL DEFAULT 0, \"status\" TEXT NOT NULL, " +
                "\"error\" TEXT NULL, \"created_at\" INTEGER NOT NULL, \"updated_at\" INTEGER NOT " +
                "NULL, PRIMARY KEY (\"id\"))"
    }
}
