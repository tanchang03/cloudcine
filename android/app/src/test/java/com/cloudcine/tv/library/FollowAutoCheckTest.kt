package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [FollowAutoCheck] 的取值口径。
 *
 * ## 为什么这几条值得写
 *
 * 这个枚举的 id 字符串要**跨端走**（存在 `settings.follow_auto_check`，
 * 随 `.ccbak` 备份包从电脑搬到电视）。所以两类错法都是静默的：
 *
 *   * 某个取值改名（`on_launch` → `onLaunch`）→ 电视上读到一个不认识的
 *     值，`parse` 落到默认分支 → 用户明确选了「关闭」，电视却开始自动检查；
 *   * `parse` 的默认分支被写成 `OFF` 而不是 `ON_LAUNCH` → 老库（根本没有
 *     这个键）静默地永不检查，用户以为「这功能就是坏的」。
 *
 * 都不会抛异常，所以判据必须在单测里钉住。
 */
class FollowAutoCheckTest {

    @Test
    fun `id 字符串与 PC 端逐字一致`() {
        // 这三个字面量是跨端契约的一部分 —— 改了它们就等于改了备份格式。
        assertEquals("off", FollowAutoCheck.OFF.id)
        assertEquals("on_launch", FollowAutoCheck.ON_LAUNCH.id)
        assertEquals("every_6h", FollowAutoCheck.EVERY_6H.id)
    }

    @Test
    fun `parse 认得出每一个取值`() {
        assertEquals(FollowAutoCheck.OFF, FollowAutoCheck.parse("off"))
        assertEquals(FollowAutoCheck.ON_LAUNCH, FollowAutoCheck.parse("on_launch"))
        assertEquals(FollowAutoCheck.EVERY_6H, FollowAutoCheck.parse("every_6h"))
    }

    @Test
    fun `parse 对 null 与写坏的值退回 ON_LAUNCH`() {
        // ⛔ 默认必须是 ON_LAUNCH 而不是 OFF：老库没有这个键，
        //    退回 OFF 会让「追剧」这个功能在新装机器上静默失效。
        assertEquals(FollowAutoCheck.ON_LAUNCH, FollowAutoCheck.parse(null))
        assertEquals(FollowAutoCheck.ON_LAUNCH, FollowAutoCheck.parse(""))
        assertEquals(FollowAutoCheck.ON_LAUNCH, FollowAutoCheck.parse("onLaunch"))
        assertEquals(FollowAutoCheck.ON_LAUNCH, FollowAutoCheck.parse("   "))
        assertEquals(FollowAutoCheck.ON_LAUNCH, FollowAutoCheck.parse("OFF"))
    }

    @Test
    fun `OFF 没有窗口，另两个都是 6 小时`() {
        assertNull("关闭必须表达成「不自动检查」，而不是某个很大的窗口", FollowAutoCheck.OFF.windowSec)
        assertEquals(6 * 3600L, FollowAutoCheck.ON_LAUNCH.windowSec)
        assertEquals(6 * 3600L, FollowAutoCheck.EVERY_6H.windowSec)
    }

    @Test
    fun `只有 EVERY_6H 挂周期定时器`() {
        assertFalse(FollowAutoCheck.OFF.runsOnTimer)
        assertFalse("启动检查不该变成周期检查", FollowAutoCheck.ON_LAUNCH.runsOnTimer)
        assertTrue(FollowAutoCheck.EVERY_6H.runsOnTimer)
    }

    @Test
    fun `启动窗口与自动窗口是两个数`() {
        // 电视常被反复唤醒（待机 → 进媒体库），6 小时的窗口会让绝大多数
        // 唤醒都什么都不做，用户会觉得「这功能根本没在跑」。所以启动检查
        // 用更短的 30 分钟 —— 这不是笔误，是刻意的偏离。
        assertEquals(30 * 60L, FollowAutoCheck.LAUNCH_WINDOW_SEC)
        assertTrue(FollowAutoCheck.LAUNCH_WINDOW_SEC < FollowAutoCheck.ON_LAUNCH.windowSec!!)
    }
}
