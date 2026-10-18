package com.cloudcine.tv.pan.baidu

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * [BaiduQrLogin] 的状态机覆盖（注入假 HTTP，不起真网络）。
 *
 * ## 为什么这组断言值得写
 *
 * 扫码登录的失败模式**几乎全是静默的**：
 *
 * 1. **长轮询超时当成失败** ⇒ 用户每 20 秒看到一次「正在获取二维码」，
 *    而服务端其实只是在等他扫码。这条最容易被「顺手加个 try/catch 转 Error」改坏。
 * 2. **`channel_v` 是二次编码的 JSON** ⇒ 直接 `json["channel_v"]` 当对象用，
 *    永远是 `null`，于是**永远**「等待中」，扫了也没反应。
 * 3. **主线换票没拿到 BDUSS 时不降级** ⇒ 触发风控的账号 100% 登不进去。
 * 4. **`status` 是字符串不是数字** ⇒ `when (channel["status"])` 分支全不命中。
 */
class BaiduQrLoginTest {

    // ------------------------------------------------------------------
    // 假 HTTP
    // ------------------------------------------------------------------

    /**
     * 按「URL 的路径片段」分派的假实现。
     *
     * ⛔ 不按完整 URL 匹配：查询串里带 `tt=<时间戳>`，完整匹配必然对不上。
     */
    private class FakeHttp(
        private val routes: List<Triple<String, (Map<String, String>) -> BaiduResponse, Int>>,
    ) : BaiduHttpLike {
        /** 每次请求都记下来，供「到底打了几次」这类断言用。 */
        val calls = ArrayList<String>()

        override fun get(
            url: String,
            query: Map<String, String>,
            headers: Map<String, String>,
            followRedirects: Boolean,
            timeoutMs: Int,
        ): BaiduResponse {
            calls.add(url)
            for ((path, make, _) in routes) {
                if (url.contains(path)) return make(query)
            }
            return BaiduResponse(status = 404, body = "no route: $url")
        }

        override fun post(
            url: String,
            query: Map<String, String>,
            headers: Map<String, String>,
            followRedirects: Boolean,
            timeoutMs: Int,
        ): BaiduResponse {
            calls.add("POST $url")
            for ((path, make, _) in routes) {
                if (url.contains(path)) return make(query)
            }
            return BaiduResponse(status = 404, body = "no route: $url")
        }

        override fun getBytes(url: String, headers: Map<String, String>, maxBytes: Int, timeoutMs: Int): ByteArray {
            calls.add("BYTES $url")
            return byteArrayOf(1, 2, 3)
        }
    }

    private fun ok(body: String) = BaiduResponse(status = 200, body = body)

    // ------------------------------------------------------------------
    // 第 1 跳：取二维码
    // ------------------------------------------------------------------

    @Test
    fun `取码成功后 imgurl 被补成绝对地址`() {
        val http = FakeHttp(
            listOf(
                Triple(
                    BaiduEndpoints.GET_QRCODE,
                    { _ ->
                        ok(
                            """{"errno":0,"sign":"SIGN123",""" +
                                """"imgurl":"https://passport.baidu.com/v2/api/qrcode?x=1"}""",
                        )
                    },
                    0,
                ),
            ),
        )
        val s = BaiduQrLogin(http).start()
        assertEquals("SIGN123", s.sign)
        assertTrue(s.imgUrl.startsWith("https://"))
    }

    @Test
    fun `取码被限流时抛出可读的错误`() {
        val http = FakeHttp(
            listOf(
                Triple(
                    BaiduEndpoints.GET_QRCODE,
                    { _ -> ok("""{"errno":50000}""") },
                    0,
                ),
            ),
        )
        try {
            BaiduQrLogin(http).start()
            fail("50000 应该抛 LoginException")
        } catch (e: BaiduQrLogin.LoginException) {
            assertTrue("错误文案要能直接上屏：${e.message}", e.message!!.contains("频繁"))
        }
    }

    @Test
    fun `取码响应没有 sign 时抛错而不是返回一个空会话`() {
        val http = FakeHttp(
            listOf(Triple(BaiduEndpoints.GET_QRCODE, { _ -> ok("""{"errno":0}""") }, 0)),
        )
        try {
            BaiduQrLogin(http).start()
            fail("缺 sign 应该抛 LoginException")
        } catch (_: BaiduQrLogin.LoginException) {
        }
    }

    // ------------------------------------------------------------------
    // 第 2 跳：长轮询
    // ------------------------------------------------------------------

    private fun session() = BaiduQrLogin.Session(
        sign = "SIGN",
        imgUrl = "https://x/qr.png",
        gid = "GID",
        createdAtMs = 0L,
    )

    @Test
    fun `轮询超时按等待处理而不是失败`() {
        // ⛔ 长轮询会挂 ~30 秒。抛异常 = 超时 = 正常态。
        val http = object : BaiduHttpLike {
            override fun get(
                url: String,
                query: Map<String, String>,
                headers: Map<String, String>,
                followRedirects: Boolean,
                timeoutMs: Int,
            ): BaiduResponse = throw java.net.SocketTimeoutException("Read timed out")

            override fun post(
                url: String,
                query: Map<String, String>,
                headers: Map<String, String>,
                followRedirects: Boolean,
                timeoutMs: Int,
            ): BaiduResponse = throw java.net.SocketTimeoutException()

            override fun getBytes(url: String, headers: Map<String, String>, maxBytes: Int, timeoutMs: Int) =
                ByteArray(0)
        }
        assertTrue(BaiduQrLogin(http).poll(session()) is BaiduQrLogin.Poll.Waiting)
    }

    @Test
    fun `没有事件载荷时是等待`() {
        val http = FakeHttp(
            listOf(Triple(BaiduEndpoints.UNICAST, { _ -> ok("cb({\"errno\":1})") }, 0)),
        )
        assertTrue(BaiduQrLogin(http).poll(session()) is BaiduQrLogin.Poll.Waiting)
    }

    @Test
    fun `channel_v 是二次编码的字符串时也能解出已扫码`() {
        // ⛔ 服务端把 `channel_v` 又编码成一个 **JSON 字符串**。
        //    直接当对象用永远是 null ⇒ 永远「等待中」，扫了也没反应。
        val inner = """{\"status\":1}"""
        val body = """cb({"errno":0,"channel_v":"$inner"})"""
        val http = FakeHttp(listOf(Triple(BaiduEndpoints.UNICAST, { _ -> ok(body) }, 0)))
        assertTrue(BaiduQrLogin(http).poll(session()) is BaiduQrLogin.Poll.Scanned)
    }

    @Test
    fun `status 为 0 且带 v 时是已确认`() {
        val inner = """{\"status\":0,\"v\":\"VVV\",\"u\":\"https%3A%2F%2Fpan.baidu.com%2F\"}"""
        val body = """cb({"errno":0,"channel_v":"$inner"})"""
        val http = FakeHttp(listOf(Triple(BaiduEndpoints.UNICAST, { _ -> ok(body) }, 0)))
        val p = BaiduQrLogin(http).poll(session())
        assertTrue("应已确认，实际 $p", p is BaiduQrLogin.Poll.Confirmed)
        p as BaiduQrLogin.Poll.Confirmed
        assertEquals("VVV", p.v)
        // `u` 要 URL 解码一次，否则落点会变成一个带 %3A%2F%2F 的非法地址。
        assertEquals("https://pan.baidu.com/", p.u)
    }

    @Test
    fun `status 为 0 但缺 v 时报错而不是确认`() {
        val inner = """{\"status\":0}"""
        val body = """cb({"errno":0,"channel_v":"$inner"})"""
        val http = FakeHttp(listOf(Triple(BaiduEndpoints.UNICAST, { _ -> ok(body) }, 0)))
        assertTrue(BaiduQrLogin(http).poll(session()) is BaiduQrLogin.Poll.Error)
    }

    @Test
    fun `status 为 2 时是用户取消`() {
        val inner = """{\"status\":2}"""
        val body = """cb({"errno":0,"channel_v":"$inner"})"""
        val http = FakeHttp(listOf(Triple(BaiduEndpoints.UNICAST, { _ -> ok(body) }, 0)))
        assertTrue(BaiduQrLogin(http).poll(session()) is BaiduQrLogin.Poll.Cancelled)
    }

    @Test
    fun `轮询 HTTP 非 2xx 才算错误`() {
        val http = FakeHttp(
            listOf(Triple(BaiduEndpoints.UNICAST, { _ -> BaiduResponse(status = 500) }, 0)),
        )
        assertTrue(BaiduQrLogin(http).poll(session()) is BaiduQrLogin.Poll.Error)
    }

    // ------------------------------------------------------------------
    // 第 3~5 跳：换票
    // ------------------------------------------------------------------

    @Test
    fun `主线拿到 BDUSS 时不再打风控分支`() {
        val http = FakeHttp(
            listOf(
                Triple(
                    BaiduEndpoints.BDUSS_LOGIN_MAINLINE,
                    { _ ->
                        BaiduResponse(
                            status = 302,
                            setCookies = listOf("BDUSS=BDUSS_OK; Path=/; Domain=baidu.com"),
                            location = "https://pan.baidu.com/",
                        )
                    },
                    0,
                ),
                // 落地那一跳：给一个网盘域的 Cookie，然后 200 结束。
                Triple(
                    "pan.baidu.com/",
                    { _ ->
                        BaiduResponse(
                            status = 200,
                            setCookies = listOf("PANWEB=1; Path=/; Domain=baidu.com"),
                        )
                    },
                    0,
                ),
                Triple(
                    BaiduEndpoints.STOKEN_AUTH,
                    { _ -> ok("""{"errno":0,"data":{"stoken_list":{"netdisk":"STOKEN_ND"}}}""") },
                    0,
                ),
            ),
        )
        val r = BaiduQrLogin(http).exchange(BaiduQrLogin.Poll.Confirmed("V", "https://pan.baidu.com/"))
        assertEquals("BDUSS_OK", r.cookies["BDUSS"])
        // netdisk 专用 STOKEN 覆盖换票下发的那个 —— 少了它网盘侧不认会话。
        assertEquals("STOKEN_ND", r.cookies["STOKEN"])
        assertTrue(r.panCookieNames.contains("PANWEB"))
        // 风控分支一次都不该被打。
        assertTrue(http.calls.none { it.contains(BaiduEndpoints.QR_BDUSS_LOGIN) })
    }

    @Test
    fun `主线没给 BDUSS 时降级走风控分支`() {
        val http = FakeHttp(
            listOf(
                Triple(
                    BaiduEndpoints.BDUSS_LOGIN_MAINLINE,
                    { _ -> BaiduResponse(status = 302, setCookies = emptyList()) },
                    0,
                ),
                Triple(
                    BaiduEndpoints.QR_BDUSS_LOGIN,
                    { _ ->
                        BaiduResponse(
                            status = 200,
                            setCookies = listOf("BDUSS=BDUSS_V4; Path=/; Domain=baidu.com"),
                            location = "https://pan.baidu.com/",
                        )
                    },
                    0,
                ),
                Triple(
                    "pan.baidu.com/",
                    { _ -> BaiduResponse(status = 200, setCookies = emptyList()) },
                    0,
                ),
                Triple(
                    BaiduEndpoints.STOKEN_AUTH,
                    { _ -> BaiduResponse(status = 500) },
                    0,
                ),
            ),
        )
        val r = BaiduQrLogin(http).exchange(BaiduQrLogin.Poll.Confirmed("V", ""))
        assertEquals("BDUSS_V4", r.cookies["BDUSS"])
        assertTrue(http.calls.any { it.contains(BaiduEndpoints.QR_BDUSS_LOGIN) })
    }

    @Test
    fun `两条换票都拿不到 BDUSS 时抛错`() {
        val http = FakeHttp(
            listOf(
                Triple(
                    BaiduEndpoints.BDUSS_LOGIN_MAINLINE,
                    { _ -> BaiduResponse(status = 302, setCookies = emptyList()) },
                    0,
                ),
                Triple(
                    BaiduEndpoints.QR_BDUSS_LOGIN,
                    { _ -> BaiduResponse(status = 200, setCookies = emptyList()) },
                    0,
                ),
            ),
        )
        try {
            BaiduQrLogin(http).exchange(BaiduQrLogin.Poll.Confirmed("V", ""))
            fail("没有 BDUSS 应该抛 LoginException")
        } catch (e: BaiduQrLogin.LoginException) {
            assertTrue(e.message!!.contains("BDUSS"))
        }
    }

    @Test
    fun `风控业务码直接抛出可读错误`() {
        val http = FakeHttp(
            listOf(
                Triple(
                    BaiduEndpoints.BDUSS_LOGIN_MAINLINE,
                    { _ ->
                        BaiduResponse(
                            status = 200,
                            body = """{"errno":400023}""",
                            setCookies = emptyList(),
                        )
                    },
                    0,
                ),
            ),
        )
        try {
            BaiduQrLogin(http).exchange(BaiduQrLogin.Poll.Confirmed("V", ""))
            fail("400023 应该抛 LoginException")
        } catch (e: BaiduQrLogin.LoginException) {
            assertTrue(e.message!!.contains("安全验证"))
        }
    }

    // ------------------------------------------------------------------
    // 凭证过滤
    // ------------------------------------------------------------------

    @Test
    fun `落点收到的不在固定名单里的 Cookie 也要保留`() {
        // ⛔ 丢掉 `PANWEB` / `PANPSC` 与「没做落地」等价：网盘侧不认会话
        //    （`/api/account/uinfo` 回 `-6`），而登录页会显示「登录成功」。
        val kept = filterBaiduCookiesForCredential(
            cookies = mapOf(
                "BDUSS" to "d",
                "BAIDUID" to "b",
                "PANWEB" to "1",
                "PANPSC" to "2",
                "H_PS_UID" to "u",
            ),
            extraNames = listOf("PANWEB", "PANPSC"),
        )
        assertEquals("d", kept["BDUSS"])
        assertEquals("1", kept["PANWEB"])
        assertEquals("2", kept["PANPSC"])
        // 不在名单里的噪音不进凭证。
        assertNull(kept["H_PS_UID"])
    }

    @Test
    fun `空值不进凭证`() {
        val kept = filterBaiduCookiesForCredential(mapOf("BDUSS" to "", "STOKEN" to "s"))
        assertNull(kept["BDUSS"])
        assertEquals("s", kept["STOKEN"])
    }

    @Test
    fun `会话有效期是 5 分钟`() {
        val s = BaiduQrLogin.Session("s", "u", "g", createdAtMs = 0L)
        assertEquals(false, s.isExpired(4 * 60_000L))
        assertEquals(true, s.isExpired(6 * 60_000L))
        assertNotNull(s)
    }
}
