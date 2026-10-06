package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BackupManifest] 与 [IsoTime] 的序列化契约。
 *
 * ## 为什么这组断言值得写
 *
 * 备份清单是 Android 与 PC 端之间**唯一的元信息通道**，而它读错的方式
 * 全是静默的：
 *
 *   * 时间字符串少了 `Z` → Dart 的 `DateTime.tryParse` 当**本地时间**解析，
 *     「谁新」的比较偏掉整整一个时区（在 UTC+8 上就是 8 小时）；
 *   * `schemaVersion` 被写成 `16.0` → Dart 那边 `as int?` 返回 null，
 *     版本号悄悄退化成默认值 1；
 *   * 空库时写了 `"libraryModifiedAt": null` → 行为其实一样，但人工看
 *     这份 JSON 时得推理才知道「这备份是空的」。
 */
class BackupManifestTest {

    private val base = BackupManifest(
        deviceId = "tv-1",
        deviceName = "小米电视",
        createdAt = 1_759_700_123_456L,
        libraryModifiedAt = 1_759_700_000_000L,
        schemaVersion = 16,
        fileNames = listOf(BackupManifest.DB_ENTRY, BackupManifest.POSTERS_ENTRY),
        note = null,
    )

    // ── 同步判据 ────────────────────────────────────────────────────

    @Test
    fun `effectiveModifiedAt 退化成 createdAt 而不是 0`() {
        // ⛔ 这条与直觉相反。退化成 0 看起来「更安全」，实际是让所有老备份
        // （没有 libraryModifiedAt 那个字段时生成的）恒定「比本地旧」⇒
        // 本地永远上传、老备份永远不被采纳。
        val empty = base.copy(libraryModifiedAt = null, createdAt = 1_700_000_000_000L)
        assertEquals(1_700_000_000_000L, empty.effectiveModifiedAt)
    }

    @Test
    fun `有库内容时以 libraryModifiedAt 为准`() {
        val m = base.copy(libraryModifiedAt = 1_000L, createdAt = 9_999_999L)
        assertEquals(1_000L, m.effectiveModifiedAt)
    }

    @Test
    fun `hasLibraryContent 只看 libraryModifiedAt`() {
        assertTrue(base.hasLibraryContent)
        assertFalse(base.copy(libraryModifiedAt = null).hasLibraryContent)
    }

    @Test
    fun `同一台设备永远不算冲突`() {
        val a = base.copy(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        val b = base.copy(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        assertFalse(a.conflictsWith(b))
    }

    @Test
    fun `不同设备 60 秒内算冲突 正好 60 秒不算`() {
        val a = base.copy(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        assertTrue(a.conflictsWith(base.copy(deviceId = "pc-1", libraryModifiedAt = 1_059_999L)))
        assertFalse(a.conflictsWith(base.copy(deviceId = "pc-1", libraryModifiedAt = 1_060_000L)))
    }

    // ── JSON ────────────────────────────────────────────────────────

    @Test
    fun `toJson 输出与 Dart 端逐字对齐`() {
        // 这一串是契约本身：键名、顺序（LinkedHashMap 保持插入序）、
        // 时间格式、以及**不写 note**（它是 null）。
        assertEquals(
            "{\"deviceId\":\"tv-1\",\"deviceName\":\"小米电视\"," +
                "\"createdAt\":\"2025-10-05T21:35:23.456Z\"," +
                "\"libraryModifiedAt\":\"2025-10-05T21:33:20.000Z\"," +
                "\"schemaVersion\":16," +
                "\"fileNames\":[\"cloudcine.sqlite\",\"posters/\"]}",
            MiniJson.write(base.toJson()),
        )
    }

    @Test
    fun `空库时不写 libraryModifiedAt 键`() {
        val json = MiniJson.write(base.copy(libraryModifiedAt = null).toJson())
        assertFalse("空库不该出现这个键", json.contains("libraryModifiedAt"))
    }

    @Test
    fun `时间字符串必须带 Z`() {
        // 少了它 Dart 会按本地时间解析 —— 比较偏掉一个时区。
        val json = MiniJson.write(base.toJson())
        assertTrue(json.contains("2025-10-05T21:33:20.000Z"))
    }

    @Test
    fun `schemaVersion 必须写成整数`() {
        // 写成 16.0 的话 Dart 的 `as int?` 给 null，版本号退化成 1。
        assertTrue(MiniJson.write(base.toJson()).contains("\"schemaVersion\":16"))
    }

    @Test
    fun `字节往返不丢字段`() {
        assertEquals(base, BackupManifest.fromBytes(base.toBytes()))
    }

    @Test
    fun `中文设备名与备注走 UTF-8 原文`() {
        val m = base.copy(deviceName = "客厅电视 📺", note = "手动备份")
        val back = BackupManifest.fromBytes(m.toBytes())
        assertEquals("客厅电视 📺", back.deviceName)
        assertEquals("手动备份", back.note)
    }

    @Test
    fun `能读懂 PC 端生成的清单`() {
        // 模拟一份 Dart `jsonEncode` 出来的原文（字段顺序、格式都照抄）。
        val raw = "{\"deviceId\":\"pc-1\",\"deviceName\":\"MacBook\"," +
            "\"createdAt\":\"2026-10-06T11:16:13.123Z\"," +
            "\"libraryModifiedAt\":\"2026-10-06T11:16:13.123Z\"," +
            "\"schemaVersion\":16," +
            "\"fileNames\":[\"cloudcine.sqlite\",\"posters/\"]}"
        val m = BackupManifest.fromBytes(raw.toByteArray(Charsets.UTF_8))
        assertEquals("pc-1", m.deviceId)
        assertEquals(16, m.schemaVersion)
        assertEquals(1_791_285_373_123L, m.libraryModifiedAt)
        assertEquals(2, m.fileNames.size)
        assertTrue(m.hasLibraryContent)
    }

    @Test
    fun `缺字段一律退默认值 不抛`() {
        // 这是用户可能手工改过、也可能是旧版本生成的文件。
        val m = BackupManifest.fromJson(emptyMap())
        assertEquals("unknown", m.deviceId)
        assertEquals("未知设备", m.deviceName)
        assertEquals(0L, m.createdAt)
        assertNull(m.libraryModifiedAt)
        assertEquals(1, m.schemaVersion)
        assertTrue(m.fileNames.isEmpty())
        assertFalse(m.hasLibraryContent)
    }

    @Test
    fun `schemaVersion 是数字字符串时也能读`() {
        val m = BackupManifest.fromJson(mapOf("schemaVersion" to "16"))
        assertEquals(16, m.schemaVersion)
    }

    @Test
    fun `空字符串的 deviceId 退默认值`() {
        // Dart 那边是 `?? 'unknown'`，但一个空串设备名同样没法用。
        assertEquals("unknown", BackupManifest.fromJson(mapOf("deviceId" to "")).deviceId)
    }

    // ── IsoTime ────────────────────────────────────────────────────

    @Test
    fun `format 输出固定三位小数与 Z`() {
        assertEquals("1970-01-01T00:00:00.000Z", IsoTime.format(0L))
        assertEquals("2025-10-05T21:33:20.000Z", IsoTime.format(1_759_700_000_000L))
        assertEquals("2025-10-05T21:35:23.456Z", IsoTime.format(1_759_700_123_456L))
    }

    @Test
    fun `format 与 parse 互逆`() {
        for (ms in listOf(0L, 1_000L, 1_759_700_000_000L, 1_791_285_373_123L)) {
            assertEquals(ms, IsoTime.parse(IsoTime.format(ms)))
        }
    }

    @Test
    fun `parse 容忍 1 到 9 位小数秒`() {
        // Dart 的 toIso8601String() 在微秒非零时输出 **6 位**小数 ——
        // 用 SimpleDateFormat 配一个 pattern 吃不下来，所以才手写解析。
        assertEquals(1_759_700_000_000L, IsoTime.parse("2025-10-05T21:33:20Z"))
        assertEquals(1_759_700_000_100L, IsoTime.parse("2025-10-05T21:33:20.1Z"))
        assertEquals(1_759_700_000_123L, IsoTime.parse("2025-10-05T21:33:20.123Z"))
        assertEquals(1_759_700_000_123L, IsoTime.parse("2025-10-05T21:33:20.123456Z"))
        assertEquals(1_759_700_000_123L, IsoTime.parse("2025-10-05T21:33:20.123456789Z"))
    }

    @Test
    fun `parse 认时区后缀`() {
        // 同一个瞬间的两种写法。
        assertEquals(1_791_285_373_123L, IsoTime.parse("2026-10-06T11:16:13.123Z"))
        assertEquals(1_791_285_373_123L, IsoTime.parse("2026-10-06T19:16:13.123+08:00"))
        assertEquals(1_791_285_373_123L, IsoTime.parse("2026-10-06T19:16:13.123+0800"))
        assertEquals(1_791_285_373_123L, IsoTime.parse("2026-10-06T03:16:13.123-08:00"))
    }

    @Test
    fun `parse 无后缀时按 UTC`() {
        // ⚠️ 与 Dart 不同（Dart 按本地时间）。我们的 manifest 永远带 Z，
        // 无后缀只会出现在手工编辑过的文件里，「当 UTC」比「当电视所在时区」
        // 更可预测。
        assertEquals(IsoTime.parse("2026-10-06T11:16:13.123Z"), IsoTime.parse("2026-10-06T11:16:13.123"))
    }

    @Test
    fun `parse 读不懂一律返回 null 不抛`() {
        assertNull(IsoTime.parse(null))
        assertNull(IsoTime.parse(""))
        assertNull(IsoTime.parse("   "))
        assertNull(IsoTime.parse("不是时间"))
        assertNull(IsoTime.parse("2026-10-06"))
        assertNull(IsoTime.parse("2026-13-06T11:16:13Z")) // 月份越界
        assertNull(IsoTime.parse("2026-10-06T25:16:13Z")) // 小时越界
        assertNull(IsoTime.parse("2026-10-06T11:16:13.12xZ"))
    }

    @Test
    fun `parse 对日期里的短横线不误判成时区`() {
        // 曾经的写法用 `indexOfLast { … }` + `body.indexOf(it)` 找时区后缀，
        // 而 lambda 拿不到下标 ⇒ 命中日期里的第一个 `-`，后缀永远找不到。
        assertEquals(1_759_700_000_000L, IsoTime.parse("2025-10-05T21:33:20Z"))
    }
}
