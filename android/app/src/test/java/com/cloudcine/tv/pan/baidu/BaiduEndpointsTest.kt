package com.cloudcine.tv.pan.baidu

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BaiduEndpoints] 的常量与判据覆盖。
 *
 * 这些值**全部是从 PC 端三轮实测里抄下来的**（见 `baidu_endpoints.dart` 的
 * 证据等级标注）。抄错的代价不是「报错」，而是「换一条通道」：
 *
 * - `origin` 填错 ⇒ 拿不到 `vuk` 签名的直链，从 1~2.9 MB/s 掉到 80 KB/s；
 * - 快通道用在非媒体上 ⇒ `403 31329`；
 * - 档位 id 改一个字 ⇒ 已存进库的 `quality_id` 全部失效（换档后回到默认）。
 */
class BaiduEndpointsTest {

    @Test
    fun `只有媒体类别能走 dlna 快通道`() {
        // category 1=视频、2=音频；3=文档、4=应用…一律 403 31329。
        assertTrue(BaiduEndpoints.canUseDlna(BaiduEndpoints.CATEGORY_VIDEO))
        assertTrue(BaiduEndpoints.canUseDlna(BaiduEndpoints.CATEGORY_AUDIO))
        assertFalse(BaiduEndpoints.canUseDlna(3))
        assertFalse(BaiduEndpoints.canUseDlna(4))
        // 解析不到类别时走**慢通道**（保守：慢总比 403 好）。
        assertFalse(BaiduEndpoints.canUseDlna(null))
    }

    @Test
    fun `根标识是斜杠而不是零`() {
        // ⛔ 夸克是 "0"。抄过来会让百度第一次列目录落在一个不存在的目录上，
        //    表现是「登录成功、文件列表一直空」。
        assertEquals("/", BaiduEndpoints.ROOT_ID)
    }

    @Test
    fun `档位 id 可往返`() {
        for (t in BaiduResolution.ALL) {
            assertEquals(t, BaiduResolution.typeFromId(BaiduResolution.idFor(t)))
        }
        assertNull(BaiduResolution.typeFromId("origin"))
        assertNull(BaiduResolution.typeFromId("baidu_"))
        assertNull(BaiduResolution.typeFromId("quark_4"))
    }

    @Test
    fun `档位 id 的字面量不要改`() {
        // 它会被写进 `settings` / 播放偏好，改一个字等于让所有存量偏好失效。
        assertEquals("baidu_0", BaiduResolution.idFor(BaiduResolution.P360))
        assertEquals("baidu_3", BaiduResolution.idFor(BaiduResolution.P1080))
        assertEquals("baidu_6", BaiduResolution.idFor(BaiduResolution.INTELLIGENT_HD))
    }

    @Test
    fun `默认档按会员等级分`() {
        // 非会员只有 480P 能取到；直接要 1080P 会拿到一个空响应。
        assertEquals(BaiduResolution.P480, BaiduResolution.defaultFor(BaiduVipType.NORMAL))
        assertEquals(BaiduResolution.P1080, BaiduResolution.defaultFor(BaiduVipType.SVIP))
    }

    @Test
    fun `帧彩映画没有标称高度`() {
        // 它是 AI 增强而非固定分辨率，报一个假高度会让自动选档把它排到最高。
        assertNull(BaiduResolution.heightFor(BaiduResolution.INTELLIGENT_HD))
        assertEquals(2160, BaiduResolution.heightFor(BaiduResolution.K4))
    }

    @Test
    fun `Cookie 头把关键键排在前面`() {
        val header = BaiduEndpoints.cookieHeader(
            linkedMapOf(
                "BAIDUID" to "b",
                "STOKEN" to "s",
                "BDUSS" to "d",
            ),
        )
        // ⛔ 顺序不是装饰：`BDUSS` 必须在最前（服务端按第一个命中的会话键认人）。
        assertEquals("BDUSS=d; STOKEN=s; BAIDUID=b", header)
    }

    @Test
    fun `空值不进 Cookie 头`() {
        assertEquals("BDUSS=d", BaiduEndpoints.cookieHeader(mapOf("BDUSS" to "d", "STOKEN" to "")))
        assertEquals("", BaiduEndpoints.cookieHeader(emptyMap()))
    }

    @Test
    fun `域名归属按 baidu_com 判`() {
        assertTrue(BaiduEndpoints.ownsUrl("https://d.pcs.baidu.com/file/x"))
        assertTrue(BaiduEndpoints.ownsUrl("https://pan.baidu.com/rest/2.0"))
        assertFalse(BaiduEndpoints.ownsUrl("https://cdn.quark.cn/x"))
    }

    @Test
    fun `直链的 UA 是 netdisk`() {
        // 与 `BaiduMapper.dlinkHeaders` 同源，两处任一处改了都会 403 31362。
        assertEquals("netdisk", BaiduEndpoints.NETDISK_DLINK_UA)
    }
}
