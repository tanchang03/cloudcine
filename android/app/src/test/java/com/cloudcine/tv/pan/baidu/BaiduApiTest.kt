package com.cloudcine.tv.pan.baidu

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * [BaiduApi] 取链路由与错误映射（注入假 HTTP，不起真网络）。
 *
 * ## 为什么这组断言值得写
 *
 * 取链是「能看到列表、点开播不了」的唯一来源，而它的失败**全是静默降级**：
 *
 * 1. **`-6` 一码多义**（没 Cookie / Cookie 废了 / 缺 `bdstoken` / 风控）。
 *    不区分就自愈的话，缺令牌这种「重打一次就好」的情形会被报成
 *    「登录失效」，用户被踢回登录页 —— 而他明明刚扫过码。
 * 2. **dlna 快通道只服务媒体**。非媒体（字幕、文档）拿 dlna 直链会
 *    `403 31329`；不按 `category` 分流就会「字幕永远加载不出来」。
 * 3. **路由是「同时需要」而不是「依次备选」**：①失败不代表②也会失败，
 *    而②失败不代表拿不到转码档。
 */
class BaiduApiTest {

    private class FakeHttp(
        private val handler: (url: String, query: Map<String, String>, isPost: Boolean) -> BaiduResponse,
    ) : BaiduHttpLike {
        val calls = ArrayList<String>()

        override fun get(
            url: String,
            query: Map<String, String>,
            headers: Map<String, String>,
            followRedirects: Boolean,
            timeoutMs: Int,
        ): BaiduResponse {
            calls.add(url)
            return handler(url, query, false)
        }

        override fun post(
            url: String,
            query: Map<String, String>,
            headers: Map<String, String>,
            followRedirects: Boolean,
            timeoutMs: Int,
        ): BaiduResponse {
            calls.add("POST $url")
            return handler(url, query, true)
        }

        override fun getBytes(url: String, headers: Map<String, String>, maxBytes: Int, timeoutMs: Int) =
            byteArrayOf(9)

        fun count(path: String) = calls.count { it.contains(path) }
    }

    private fun api(http: BaiduHttpLike, cookie: String = "BDUSS=ok") =
        BaiduApi(cookieSource = { cookie }, http = http)

    // ------------------------------------------------------------------
    // 列目录
    // ------------------------------------------------------------------

    @Test
    fun `列目录用路径而不是 id`() {
        // ⛔ 百度最大的结构差异：`dir` 收的是**路径**。
        val http = FakeHttp { url, query, _ ->
            if (url.contains(BaiduEndpoints.LIST)) {
                assertEquals("/电影", query["dir"])
                BaiduResponse(
                    status = 200,
                    body = """{"errno":0,"list":[{"fs_id":1,"server_filename":"a.mkv","isdir":0,"path":"/电影/a.mkv"}]}""",
                )
            } else {
                BaiduResponse(status = 404)
            }
        }
        val list = api(http).listDirectory("/电影")
        assertEquals(1, list.size)
        assertEquals("1", list[0].fid)
    }

    @Test
    fun `没有会话时直接报需要重新登录`() {
        // ⛔ 不带 Cookie 打过去百度回 `-6`，与「Cookie 废了」同码。
        //    本地先判能省一次往返，也让上层能立刻回登录页。
        val http = FakeHttp { _, _, _ -> BaiduResponse(status = 200, body = """{"errno":0}""") }
        try {
            api(http, cookie = "").listDirectory("/")
            fail("没有 Cookie 应该抛 needsReauth")
        } catch (e: BaiduApi.BaiduException) {
            assertTrue(e.needsReauth)
            assertTrue("一次请求都不该发", http.calls.isEmpty())
        }
    }

    // ------------------------------------------------------------------
    // 取链：路由降级
    // ------------------------------------------------------------------

    @Test
    fun `fsid 路由成功时原画排第一且带上直链方言头`() {
        val http = FakeHttp { url, _, _ ->
            when {
                url.contains(BaiduEndpoints.XPAN_MULTIMEDIA) ->
                    BaiduResponse(
                        status = 200,
                        body = """{"errno":0,"list":[{"fs_id":42,"dlink":"https://d.pcs/1",
                                  "size":1000,"duration":100,"path":"/电影/a.mkv"}]}""",
                    )
                // 转码档：这一条不给地址，验证「拿不到不算失败」。
                url.contains(BaiduEndpoints.BATCH_STREAMING) ->
                    BaiduResponse(status = 200, body = """{"errno":0,"list":[]}""")
                else -> BaiduResponse(status = 404)
            }
        }
        val pi = api(http).resolve("42", "/电影/a.mkv")
        assertEquals("origin", pi.qualities.first().id)
        assertTrue(pi.qualities.first().isOriginal)
        // 直链必须带 `User-Agent: netdisk`（CDN 的 sign 按 UA 签）。
        assertEquals("netdisk", pi.qualities.first().headers["User-Agent"])
        // 百度慢通道/快通道都是单连接。
        assertEquals(1, pi.qualities.first().maxConnections)
        // 时长要落到 PlayInfo 上（自动选档靠它算「需多少 MB/s」）。
        assertEquals(100_000L, pi.durationMs)
    }

    @Test
    fun `fsid 路由失败时降级到路径路由`() {
        val http = FakeHttp { url, query, _ ->
            when {
                // xpan 被风控挡住。
                url.contains(BaiduEndpoints.XPAN_MULTIMEDIA) ->
                    BaiduResponse(status = 200, body = """{"errno":9019}""")
                // 路径路由：先按 dlna 取（媒体 ⇒ 快通道）。
                url.contains(BaiduEndpoints.FILEMETAS) && query["origin"] == BaiduEndpoints.DLNA_ORIGIN ->
                    BaiduResponse(
                        status = 200,
                        body = """{"errno":0,"info":[{"category":1,"dlink":"https://d.pcs/fast","size":10}]}""",
                    )
                url.contains(BaiduEndpoints.BATCH_STREAMING) ->
                    BaiduResponse(status = 200, body = """{"errno":0,"list":[]}""")
                else -> BaiduResponse(status = 404)
            }
        }
        val pi = api(http).resolve("42", "/电影/a.mkv")
        assertEquals("https://d.pcs/fast", pi.qualities.first().url)
        assertEquals(1, http.count(BaiduEndpoints.FILEMETAS))
    }

    @Test
    fun `非媒体去掉 origin 重取（dlna 会回 403 31329）`() {
        val http = FakeHttp { url, query, _ ->
            when {
                // xpan 端点被风控挡住（`/api/` 路由不受影响 —— 这正是 9019 的语义）。
                url.contains(BaiduEndpoints.XPAN_MULTIMEDIA) ->
                    BaiduResponse(status = 200, body = """{"errno":9019}""")
                url.contains(BaiduEndpoints.FILEMETAS) && query["origin"] == BaiduEndpoints.DLNA_ORIGIN ->
                    // 文档：dlna 直链被 CDN 拒。
                    BaiduResponse(status = 200, body = """{"errno":0,"info":[{"category":4,"dlink":"https://d.pcs/bad"}]}""")
                url.contains(BaiduEndpoints.FILEMETAS) ->
                    BaiduResponse(
                        status = 200,
                        body = """{"errno":0,"info":[{"category":4,"dlink":"https://d.pcs/plain"}]}""",
                    )
                // ⛔ 转码档回 404 是**正常情形**（这个账号/这个文件没有转码流），
                //    绝不能因此让整次取链失败 —— 见 `resolve` 里那段注释。
                url.contains(BaiduEndpoints.BATCH_STREAMING) ->
                    BaiduResponse(status = 404)
                else -> BaiduResponse(status = 404)
            }
        }
        val pi = api(http).resolve("42", "/电影/a.srt")
        assertEquals("https://d.pcs/plain", pi.qualities.first().url)
        assertEquals(2, http.count(BaiduEndpoints.FILEMETAS))
    }

    @Test
    fun `转码档在响应里没地址时不影响原画可播`() {
        val http = FakeHttp { url, _, _ ->
            when {
                url.contains(BaiduEndpoints.XPAN_MULTIMEDIA) ->
                    BaiduResponse(status = 200, body = """{"errno":0,"list":[{"dlink":"https://d.pcs/o","path":"/a.mkv"}]}""")
                url.contains(BaiduEndpoints.BATCH_STREAMING) ->
                    BaiduResponse(status = 200, body = """{"errno":0,"list":[{"fs_id":1}]}""")
                else -> BaiduResponse(status = 404)
            }
        }
        val pi = api(http).resolve("1", "/a.mkv")
        assertEquals(1, pi.qualities.size)
        assertEquals("origin", pi.qualities.first().id)
    }

    @Test
    fun `全部路由失败时抛出带最后一条错误的异常`() {
        val http = FakeHttp { _, _, _ -> BaiduResponse(status = 200, body = """{"errno":-7}""") }
        try {
            api(http).resolve("1", "/a.mkv")
            fail("应该抛 BaiduException")
        } catch (e: BaiduApi.BaiduException) {
            // `-7` 是「文件不存在」⇒ 不可降级，直接上抛（换接口结果一样）。
            assertTrue(e.notFound)
        }
    }

    // ------------------------------------------------------------------
    // -6 自愈
    // ------------------------------------------------------------------

    @Test
    fun `缺 bdstoken 的 -6 会补令牌后重打一次`() {
        var tokenFetched = false
        val http = FakeHttp { url, query, _ ->
            when {
                url.contains(BaiduEndpoints.GET_TEMPLATE_VARIABLE) -> {
                    tokenFetched = true
                    BaiduResponse(status = 200, body = """{"errno":0,"bdstoken":"TOKEN"}""")
                }
                // 第一次（没带令牌）回 -6；带上令牌之后成功。
                url.contains(BaiduEndpoints.LIST) ->
                    if (query["bdstoken"] == "TOKEN") {
                        BaiduResponse(status = 200, body = """{"errno":0,"list":[]}""")
                    } else {
                        BaiduResponse(status = 200, body = """{"errno":-6}""")
                    }
                else -> BaiduResponse(status = 404)
            }
        }
        val list = api(http).listDirectory("/")
        assertTrue("应该去取过 bdstoken", tokenFetched)
        assertTrue(list.isEmpty())
        // 列目录一共打了两次（第一次 -6、补令牌后重打）。
        assertEquals(2, http.count(BaiduEndpoints.LIST))
    }

    @Test
    fun `已经有令牌时不再无限重试`() {
        val http = FakeHttp { url, query, _ ->
            when {
                url.contains(BaiduEndpoints.GET_TEMPLATE_VARIABLE) ->
                    BaiduResponse(status = 200, body = """{"errno":0,"bdstoken":"T"}""")
                url.contains(BaiduEndpoints.LIST) ->
                    BaiduResponse(status = 200, body = """{"errno":-6}""")
                else -> BaiduResponse(status = 404)
            }
        }
        try {
            api(http).listDirectory("/")
            fail("应该抛 -6")
        } catch (e: BaiduApi.BaiduException) {
            assertTrue(e.needsReauth)
        }
        // ⛔ 只重试一次：`-6` 循环重试会把限流撞成封号。
        assertTrue("列目录最多打两次，实际 ${http.count(BaiduEndpoints.LIST)}",
            http.count(BaiduEndpoints.LIST) <= 2)
    }

    @Test
    fun `凭证失效时取令牌本身不会无限递归`() {
        // ⛔ 2026-10-17 模拟器实测的缺陷：`ensureBdstoken()` 里那次 `apiGet`
        //    只传了 `withBdstoken = false`、**没传** `allowBdstokenRetry =
        //    false` ⇒ 取令牌的请求自己也回 `-6`，于是又进 `ensureBdstoken()`。
        //    现象是一次扫描打出 **251 条**「取 bdstoken 失败」（每条两次
        //    HTTP），电视上表现为「扫描卡住、转圈、零报错」。
        val http = FakeHttp { _, _, _ -> BaiduResponse(status = 200, body = """{"errno":-6}""") }
        try {
            api(http).listDirectory("/")
            fail("凭证失效应该抛 needsReauth")
        } catch (e: BaiduApi.BaiduException) {
            assertTrue(e.needsReauth)
        }
        // 上限 = 1 次列目录 + 2 次取令牌（两条来源各一次）。
        assertEquals("HTTP 次数必须封顶，实际 ${http.calls}", 3, http.calls.size)
    }

    // ------------------------------------------------------------------
    // 小文件
    // ------------------------------------------------------------------

    @Test
    fun `读小文件不带 origin`() {
        // ⛔ 字幕不是媒体：带 `origin=dlna` 取链会拿到一个只服务媒体的直链，
        //    下载时 403 31329 —— 表现为「字幕永远加载不出来」。
        val http = FakeHttp { url, query, _ ->
            when {
                // ⛔ 路径翻译那一步的响应**必须带 `fs_id`**：`pathOf` 是按
                //    `fs_id → path` 建索引的，只给 `path` 会索引出空表。
                url.contains(BaiduEndpoints.XPAN_MULTIMEDIA) ->
                    BaiduResponse(
                        status = 200,
                        body = """{"errno":0,"list":[{"fs_id":42,"path":"/电影/a.srt"}]}""",
                    )
                url.contains(BaiduEndpoints.FILEMETAS) -> {
                    assertEquals(null, query["origin"])
                    BaiduResponse(status = 200, body = """{"errno":0,"info":[{"dlink":"https://d.pcs/srt"}]}""")
                }
                else -> BaiduResponse(status = 404)
            }
        }
        val bytes = api(http).readFileBytes("42", 1024)
        assertNotNull(bytes)
        assertEquals(1, bytes.size)
    }

    @Test
    fun `取文件地址时路径未知会报不存在而不是空地址`() {
        val http = FakeHttp { _, _, _ -> BaiduResponse(status = 200, body = """{"errno":-9}""") }
        try {
            api(http).fileBytesUrl("42")
            fail("应该抛 notFound")
        } catch (e: BaiduApi.BaiduException) {
            assertTrue(e.notFound || e.message.contains("路径"))
        }
    }
}
