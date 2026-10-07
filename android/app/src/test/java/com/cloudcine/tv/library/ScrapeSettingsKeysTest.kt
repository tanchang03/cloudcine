package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 刮削凭证的**键名契约** —— 与 PC 端 `lib/data/db/settings_store.dart` 的
 * `SettingKeys` 逐字一致。
 *
 * ## 为什么这一组必须单测（它是「凭证随备份恢复」的成败所在）
 *
 * 备份包（`.ccbak`）里装的是**整个 `cloudcine.sqlite` 文件的原始字节**，
 * `settings` 表随之一起走。所以「token / cookie 随备份恢复」这件事**不需要
 * 任何新的备份代码** —— 只要把值写进 `settings` 表，它就自动跨端走。
 *
 * 于是唯一的失败模式是：**键名不一致**。
 *
 *   * 电脑写 `tmdb_api_key`，电视读 `tmdb_api_key `（多一个空格）⇒ 电视上
 *     就是「没配」，走匿名额度；
 *   * 电脑写 `douban_cookie`，电视写 `doubanCookie` ⇒ 同上。
 *
 * 而这两边**都不会报错**：读不到设置一律退回默认值，默认值就是「没配」。
 * 用户看到的现象是「明明电脑上能刮，电视上刮不到」—— 没有任何日志能指到
 * 这里。所以这几个字面量必须被钉在测试里：**改名字就会红**，改的人被迫去
 * 想「PC 端那边同步改了吗」。
 *
 * ⛔ 表结构本身（`settings` 的 DDL）由 `LibrarySchemaTest` 守着，这里只钉键名。
 */
class ScrapeSettingsKeysTest {

    /**
     * 四个键的**字面量**。
     *
     * ⛔ 这些字符串是从 PC 端 `SettingKeys` 逐字抄过来的，**不是**可以随手
     *    重构的常量名。把 `tmdb_api_key` 改成 `tmdb.key` 会让两台机器上的库
     *    互相读不到对方的凭证，且完全静默。
     */
    @Test
    fun `四个凭证键与 PC 端逐字一致`() {
        assertEquals("tmdb_api_key", LibrarySettings.TMDB_API_KEY)
        assertEquals("tmdb_api_base", LibrarySettings.TMDB_API_BASE)
        assertEquals("tmdb_image_base", LibrarySettings.TMDB_IMAGE_BASE)
        assertEquals("douban_cookie", LibrarySettings.DOUBAN_COOKIE)
    }

    /**
     * 键名是**蛇形小写、无空格**。
     *
     * 单独立一条是因为「多一个尾随空格」这类错误在肉眼 diff 里几乎看不见，
     * 而它与「改了个名字」的后果完全一样。
     */
    @Test
    fun `键名是蛇形小写且没有空白`() {
        for (k in LibrarySettings.SCRAPE_KEYS) {
            assertEquals("键名不该有前后空白：[$k]", k, k.trim())
            assertFalse("键名不该含空格：[$k]", k.contains(' '))
            assertEquals("键名必须全是小写：[$k]", k, k.lowercase())
            assertTrue("键名应形如 a_b：[$k]", Regex("^[a-z][a-z0-9_]*$").matches(k))
        }
    }

    /** 「刮削设置」那一屏上能填的就是这四个 —— 不多不少。 */
    @Test
    fun `SCRAPE_KEYS 恰好是这四个且不重复`() {
        assertEquals(4, LibrarySettings.SCRAPE_KEYS.size)
        assertEquals(LibrarySettings.SCRAPE_KEYS.size, LibrarySettings.SCRAPE_KEYS.toSet().size)
        assertEquals(
            setOf(
                LibrarySettings.TMDB_API_KEY,
                LibrarySettings.TMDB_API_BASE,
                LibrarySettings.TMDB_IMAGE_BASE,
                LibrarySettings.DOUBAN_COOKIE,
            ),
            LibrarySettings.SCRAPE_KEYS.toSet(),
        )
    }

    /**
     * ⛔ `tmdb_api_base` 与 `tmdb_image_base` **必须是两个不同的键**。
     *
     * 它们是两个域名（`api.themoviedb.org` / `image.tmdb.org`），而反代经常
     * 只覆盖其中一个。合成一个的话，「API 通了但海报全是灰块」就没法修 ——
     * 而用户只会觉得「刮削坏了」。
     */
    @Test
    fun `TMDB 的 API 地址与图片地址是两个键`() {
        assertFalse(LibrarySettings.TMDB_API_BASE == LibrarySettings.TMDB_IMAGE_BASE)
    }

    /**
     * ⛔ 「记住播放进度」这一条也照抄 PC 端 —— 它同样随备份走。
     *
     * 键名不一致的后果：用户在电视上关掉「记住进度」，回电脑上还是从中间开始播。
     */
    @Test
    fun `记住进度的键与 PC 端一致`() {
        assertEquals("remember_position", LibrarySchema.KEY_REMEMBER_PROGRESS)
    }
}
