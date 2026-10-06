package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LibraryBackupService] 里**不碰数据库、不碰网络**的那部分。
 *
 * 导出 / 导入 / 同步本身都要真的 SQLite 与网盘，JVM 单测跑不了
 * （`android.database.sqlite` 在单测里是空壳）。真正容易被写错、又
 * 必须逐字对齐 PC 端的，是**备份文件名**这一条 —— 它决定了两端在同一个
 * 网盘目录里看到的文件是否长得一样。
 */
class LibraryBackupServiceTest {

    @Test
    fun `备份文件名与 PC 端同格式`() {
        // PC 端：`cloudcine_backup_${toIso8601String().replaceAll(':','-').split('.').first}.ccbak`
        // → `cloudcine_backup_2026-10-06T11-16-13.ccbak`（UTC、秒级、无毫秒）。
        // 2026-10-06T11:16:13Z
        assertEquals(
            "cloudcine_backup_2026-10-06T11-16-13.ccbak",
            LibraryBackupService.defaultFileName(1_791_285_373_000L),
        )
    }

    @Test
    fun `文件名里必须带时间戳`() {
        // ⛔ 上传是「先删后传」，固定名会在一次失败的上传里把上一份好备份
        //    一起带走，而中间那段空窗期网盘上什么都没有。
        val a = LibraryBackupService.defaultFileName(1_791_285_373_000L)
        val b = LibraryBackupService.defaultFileName(1_791_285_374_000L)
        assertNotEquals(a, b)
    }

    @Test
    fun `文件名不含冒号且以 ccbak 结尾`() {
        // ⛔ 冒号在网盘 / Windows 上都是非法字符。PC 端刻意把它们换成 `-`。
        val name = LibraryBackupService.defaultFileName(1_791_285_373_000L)
        assertTrue("不能含冒号：$name", !name.contains(':'))
        assertTrue(name.endsWith(BackupPackage.EXTENSION))
        assertTrue(name.startsWith("cloudcine_backup_"))
    }
}
