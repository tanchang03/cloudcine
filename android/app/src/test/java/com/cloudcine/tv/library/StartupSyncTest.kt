package com.cloudcine.tv.library

import com.cloudcine.tv.library.SyncDecision.Action
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 启动时「要不要弹那个同步提示」的判据。
 *
 * ## 为什么这组断言值得写
 *
 * 这个功能做错的方式**不是报错**，而是「每次都弹」或者「永远不弹」：
 *
 *   * 判据放宽到「本地更新也弹」→ 用户每次开电视都被问一次「要不要上传」，
 *     几天之后他对所有弹窗一律按取消 —— 包括真正该看的那一次；
 *   * 判据写反 / 写成 `action.uploads` → 网盘上有更新的备份时**不弹**，
 *     用户永远不知道电脑上刚扫的库已经传上去了，只能自己去菜单里翻。
 *
 * 两种错法都不会有任何日志或崩溃，只会让人觉得「这个功能没用」。
 */
class StartupSyncTest {

    @Test
    fun `远程更新或本地空库要问用户`() {
        // 这两条是用户要的：网盘上有更新的备份（或本机根本没有库）。
        assertTrue(StartupSync.shouldPrompt(Action.restoreRemoteNewer))
        assertTrue(StartupSync.shouldPrompt(Action.restoreLocalEmpty))
    }

    @Test
    fun `本地更新时不问 —— 否则每次启动都问一次要不要上传`() {
        // ⛔ 本地更新是**常态**：看一集、标个进度都会让本地时间戳变新。
        assertFalse(StartupSync.shouldPrompt(Action.uploadLocalNewer))
        assertFalse(StartupSync.shouldPrompt(Action.uploadFirst))
        assertFalse(StartupSync.shouldPrompt(Action.uploadRemoteEmpty))
    }

    @Test
    fun `冲突与无变化都不在启动时问`() {
        // 冲突要看得见两边的库才选得出来，两行弹窗承担不了；
        // 无变化则是没事发生。
        assertFalse(StartupSync.shouldPrompt(Action.conflict))
        assertFalse(StartupSync.shouldPrompt(Action.unchanged))
    }

    @Test
    fun `弹的条件恰好等于会改本地库的那两个动作`() {
        // 与 `Action.restores` 对齐。两处口径分开写（那边是「同步会做什么」，
        // 这边是「启动时问不问」），但今天必须是同一个集合 ——
        // 万一哪天有人给 `restores` 加了第三个动作，这条会红。
        for (a in Action.entries) {
            assertTrue(
                "「${a.name}」的启动提示口径与 restores 不一致",
                StartupSync.shouldPrompt(a) == a.restores,
            )
        }
    }
}
