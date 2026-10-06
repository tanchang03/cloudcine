package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SyncDecision] 的分支覆盖。
 *
 * ## 为什么这组断言值得写
 *
 * 同步方向错了**不会报错**：两边都显示「同步成功」，只是其中一边的媒体库
 * 变成了另一边的内容。最贵的一种错法是「新机器第一次同步把网盘上的好备份
 * 冲成空库」—— 那台机器上什么都没了，而且网盘上的备份也已经被覆盖。
 *
 * 下面每条断言对应的都是「PC 端 `LibraryBackupService.sync()` 里的那一行」，
 * 包括**分支顺序**。顺序比条件本身更容易错：`conflictsWith` 与「本地是空库」
 * 两条只要对调，新机器第一次同步就会看到「冲突，请手动选择」。
 */
class SyncDecisionTest {

    private fun manifest(
        deviceId: String = "tv-1",
        libraryModifiedAt: Long? = 1_000_000L,
        createdAt: Long = 2_000_000L,
    ) = BackupManifest(
        deviceId = deviceId,
        deviceName = "设备 $deviceId",
        createdAt = createdAt,
        libraryModifiedAt = libraryModifiedAt,
        schemaVersion = 16,
        fileNames = listOf(BackupManifest.DB_ENTRY),
    )

    @Test
    fun `网盘上还没有备份时首次上传`() {
        assertEquals(
            SyncDecision.Action.uploadFirst,
            SyncDecision.decide(manifest(), remote = null),
        )
    }

    @Test
    fun `本地是空库时无条件让远程赢`() {
        // ★ 整个同步逻辑里最要紧的一格。
        //
        // 空库没有 libraryModifiedAt，于是 effectiveModifiedAt 退化成 createdAt，
        // 也就是「刚刚」—— 比网盘上任何一份备份都新。所以「先比时间」的实现
        // 会让新机器把网盘上的好备份覆盖成空库。
        val local = manifest(libraryModifiedAt = null, createdAt = 9_999_999L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = 1_000L)
        assertTrue(
            "前提：本地按时间比确实「更新」",
            local.effectiveModifiedAt > remote.effectiveModifiedAt,
        )

        assertEquals(
            SyncDecision.Action.restoreLocalEmpty,
            SyncDecision.decide(local, remote),
        )
    }

    @Test
    fun `远程是空备份时绝不覆盖本地`() {
        // 镜像情形：别人从一台新机器推过一次。拿它覆盖本地 = 用一个空库
        // 把本地攒好的媒体库清掉。
        val local = manifest(libraryModifiedAt = 1_000L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = null, createdAt = 9_999_999L)
        assertEquals(
            SyncDecision.Action.uploadRemoteEmpty,
            SyncDecision.decide(local, remote),
        )
    }

    @Test
    fun `不同设备且时间差小于 60 秒算冲突`() {
        val local = manifest(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = 1_059_000L)
        assertEquals(SyncDecision.Action.conflict, SyncDecision.decide(local, remote))
    }

    @Test
    fun `时间差正好 60 秒不再算冲突`() {
        // 判据是 `< 60_000`，边界落在「不比时间」那一侧。
        val local = manifest(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = 1_060_000L)
        assertEquals(
            SyncDecision.Action.restoreRemoteNewer,
            SyncDecision.decide(local, remote),
        )
    }

    @Test
    fun `同一台设备时间再近也不算冲突`() {
        // 自己刚备份完又点「同步」是常态。漏了 sameDevice 这一句，
        // 用户每次都会看到一个没有意义的冲突提示。
        val local = manifest(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        val remote = manifest(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        assertEquals(SyncDecision.Action.unchanged, SyncDecision.decide(local, remote))
    }

    @Test
    fun `本地比远程新时上传覆盖`() {
        val local = manifest(deviceId = "tv-1", libraryModifiedAt = 5_000_000L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = 1_000_000L)
        assertEquals(
            SyncDecision.Action.uploadLocalNewer,
            SyncDecision.decide(local, remote),
        )
    }

    @Test
    fun `远程比本地新时下载恢复`() {
        val local = manifest(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = 5_000_000L)
        assertEquals(
            SyncDecision.Action.restoreRemoteNewer,
            SyncDecision.decide(local, remote),
        )
    }

    @Test
    fun `unchanged 只可能出现在同一台设备上`() {
        // 不同设备时间戳相同 ⇒ 时间差 0 ⇒ 必然落进「冲突」。
        // 这条断言把那个隐含推论钉住：如果哪天有人把 conflictsWith 的
        // 时间窗改成 `<= 0` 之外的写法，这里会红。
        val local = manifest(deviceId = "tv-1", libraryModifiedAt = 1_000_000L)
        val remote = manifest(deviceId = "pc-1", libraryModifiedAt = 1_000_000L)
        assertEquals(SyncDecision.Action.conflict, SyncDecision.decide(local, remote))
    }

    @Test
    fun `restores 与 uploads 互斥且覆盖全部分支`() {
        for (a in SyncDecision.Action.values()) {
            assertFalse("${a.name} 不能同时既恢复又上传", a.restores && a.uploads)
        }
        // 决策函数只会返回这 7 个里的某一个，其中「不做事」的只有 conflict
        // 与 unchanged —— 它们两个都不该动数据。
        assertFalse(SyncDecision.Action.conflict.restores)
        assertFalse(SyncDecision.Action.conflict.uploads)
        assertFalse(SyncDecision.Action.unchanged.restores)
        assertFalse(SyncDecision.Action.unchanged.uploads)

        assertTrue(SyncDecision.Action.uploadFirst.uploads)
        assertTrue(SyncDecision.Action.uploadRemoteEmpty.uploads)
        assertTrue(SyncDecision.Action.uploadLocalNewer.uploads)
        assertTrue(SyncDecision.Action.restoreLocalEmpty.restores)
        assertTrue(SyncDecision.Action.restoreRemoteNewer.restores)
    }
}
