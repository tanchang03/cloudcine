package com.cloudcine.tv.pan.baidu

import com.cloudcine.tv.library.MiniJson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BaiduMapper] 的判据覆盖。
 *
 * ## 为什么这组断言值得写
 *
 * 百度的响应形状与夸克**处处不同**，而每一处不同抄错都**不会报错**：
 *
 * | 判据 | 抄错的后果 |
 * |---|---|
 * | `isdir` 语义（`1` = 目录） | 整个目录树反过来 —— BFS 队列爆炸，或者一个目录都不进 |
 * | `dlink` 可能是协议相对地址（`//d.pcs…`） | 播放器拿到一个没有 scheme 的 URI，起播即失败 |
 * | `duration` 单位是秒 | `requiredMbPerSec` 算成 1000 倍，自动选档永远挑最省的那档 |
 * | `category` 决定走快通道还是慢通道 | 走错通道：要么 403 31329，要么 80 KB/s |
 *
 * 所以这里每条都钉住**一个具体的错误后果**，而不是「字段解析对不对」。
 */
class BaiduMapperTest {

    // ------------------------------------------------------------------
    // isdir
    // ------------------------------------------------------------------

    @Test
    fun `isdir 是 1 时才是目录`() {
        // ⛔ 与夸克 `file_type` 相反：夸克 0=目录、1=文件，百度 1=目录。
        assertTrue(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":1}""")))
        assertFalse(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":0}""")))
    }

    @Test
    fun `isdir 的字符串与布尔形态都认`() {
        assertTrue(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":"1"}""")))
        assertFalse(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":"0"}""")))
        assertTrue(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":true}""")))
        assertFalse(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":false}""")))
    }

    @Test
    fun `isdir 缺失时判成文件`() {
        // 保守兜底：漏扫一个目录只是少一层，误判成目录会让 BFS 队列爆炸。
        assertFalse(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"name":"a.mkv"}""")))
        // 认不出来的字符串同理。
        assertFalse(BaiduMapper.parseIsDirectory(MiniJson.parseObject("""{"isdir":"?"}""")))
    }

    // ------------------------------------------------------------------
    // fs_id
    // ------------------------------------------------------------------

    @Test
    fun `fs_id 是数字时按整数输出而不是科学计数法`() {
        // ⛔ 百度的 `fs_id` 是 15~19 位整数，走 `Double.toString()` 会变成
        //    `1.23456789012345E14` —— 主键里带上它，同一条文件每次算出的 id
        //    都不同（`Double` 尾数精度也会丢位），表现为「每次扫描都新增一批」。
        assertEquals(
            "123456789012345",
            BaiduMapper.fsIdOf(MiniJson.parseObject("""{"fs_id":123456789012345}""")),
        )
    }

    @Test
    fun `fs_id 是字符串时原样保留`() {
        assertEquals(
            "987654321",
            BaiduMapper.fsIdOf(MiniJson.parseObject("""{"fs_id":"987654321"}""")),
        )
    }

    @Test
    fun `fs_id 三个字段名都认`() {
        assertEquals("1", BaiduMapper.fsIdOf(MiniJson.parseObject("""{"fsid":"1"}""")))
        assertEquals("2", BaiduMapper.fsIdOf(MiniJson.parseObject("""{"id":"2"}""")))
    }

    // ------------------------------------------------------------------
    // dlink
    // ------------------------------------------------------------------

    @Test
    fun `协议相对直链会补上 https`() {
        // ⛔ 百度有时下发 `//d.pcs.baidu.com/file/...`。不补 scheme，
        //    `Uri.parse` 之后 `getScheme()` 是 null，media3 起播直接失败。
        assertEquals(
            "https://d.pcs.baidu.com/file/abc",
            BaiduMapper.dlinkOf(
                MiniJson.parseObject("""{"dlink":"//d.pcs.baidu.com/file/abc"}"""),
            ),
        )
    }

    @Test
    fun `绝对直链原样返回`() {
        assertEquals(
            "http://d.pcs.baidu.com/file/x",
            BaiduMapper.dlinkOf(
                MiniJson.parseObject("""{"dlink":"http://d.pcs.baidu.com/file/x"}"""),
            ),
        )
    }

    @Test
    fun `dlink 五个候选字段都认`() {
        for (key in listOf("dlink", "download_url", "downloadUrl", "url", "link")) {
            assertEquals(
                "$key 应被识别",
                "https://x/y",
                BaiduMapper.dlinkOf(MiniJson.parseObject("""{"$key":"https://x/y"}""")),
            )
        }
    }

    @Test
    fun `取链响应里 dlink 在 list 第一项也能捞到`() {
        val json = MiniJson.parseObject(
            """{"errno":0,"list":[{"fs_id":1,"dlink":"https://d.pcs/1"}]}""",
        )
        assertEquals("https://d.pcs/1", BaiduMapper.parseDlink(json))
    }

    @Test
    fun `没有可用直链时返回 null`() {
        assertNull(BaiduMapper.parseDlink(MiniJson.parseObject("""{"errno":0,"list":[]}""")))
        assertNull(BaiduMapper.parseDlink(MiniJson.parseObject("""{"dlink":""}""")))
        assertNull(BaiduMapper.parseDlink(null))
    }

    // ------------------------------------------------------------------
    // 直链请求头
    // ------------------------------------------------------------------

    @Test
    fun `直链请求头必须用 netdisk 这个 UA`() {
        // ⛔ CDN 第二跳（`*.baidupcs.com`）的 `sign` 是**按 User-Agent 签的**。
        //    换成浏览器 UA 立刻 `403 31362 sign error` —— 而列表、取链全都正常，
        //    只有播放失败，看起来像「片源坏了」。
        val h = BaiduMapper.dlinkHeaders("BDUSS=abc")
        assertEquals("netdisk", h["User-Agent"])
        assertEquals("BDUSS=abc", h["Cookie"])
    }

    @Test
    fun `没有 Cookie 时不写 Cookie 头`() {
        assertNull(BaiduMapper.dlinkHeaders("")["Cookie"])
    }

    // ------------------------------------------------------------------
    // category / 时长 / 体积
    // ------------------------------------------------------------------

    @Test
    fun `category 从 list 里取`() {
        assertEquals(
            1,
            BaiduMapper.categoryOf(MiniJson.parseObject("""{"list":[{"category":1}]}""")),
        )
        assertNull(BaiduMapper.categoryOf(MiniJson.parseObject("""{"list":[{}]}""")))
    }

    @Test
    fun `duration 是秒时乘 1000`() {
        // ⛔ 秒当成毫秒用，`requiredMbPerSec` 会小 1000 倍 —— 4K 原画被算成
        //    「0.003 MB/s」，自动选档永远挑原画，然后卡死。
        assertEquals(7490_000L, BaiduMapper.durationMsOf(MiniJson.parseObject("""{"list":[{"duration":7490}]}""")))
        // 已经是毫秒的（> 999999）原样。
        assertEquals(
            7_490_000L,
            BaiduMapper.durationMsOf(MiniJson.parseObject("""{"list":[{"duration":7490000}]}""")),
        )
        assertNull(BaiduMapper.durationMsOf(MiniJson.parseObject("""{"list":[{"duration":0}]}""")))
    }

    @Test
    fun `体积只认正数`() {
        assertEquals(
            1234L,
            BaiduMapper.contentLengthOf(MiniJson.parseObject("""{"list":[{"size":1234}]}""")),
        )
        assertNull(BaiduMapper.contentLengthOf(MiniJson.parseObject("""{"list":[{"size":0}]}""")))
    }

    // ------------------------------------------------------------------
    // 列表项 → DriveEntry
    // ------------------------------------------------------------------

    @Test
    fun `列表项映射出 fid 名字与目录位`() {
        val json = MiniJson.parseObject(
            """
            {"fs_id":42,"server_filename":"阿凡达.mkv","isdir":0,"size":900,
             "server_mtime":1700000000,"category":1,
             "thumbs":{"url1":"https://t/1","url3":"https://t/3"},
             "width":3840,"height":1606,"duration":7200,"path":"/电影/阿凡达.mkv"}
            """.trimIndent(),
        )
        val e = BaiduMapper.toEntry(json)
        assertNotNull(e)
        assertEquals("42", e!!.fid)
        assertEquals("阿凡达.mkv", e.name)
        assertFalse(e.isDir)
        assertEquals(900L, e.sizeBytes)
        // ⛔ `server_mtime` 是**秒**，`DriveEntry.updatedAtMs` 要毫秒。
        assertEquals(1_700_000_000_000L, e.updatedAtMs)
        // 缩略图取最大那档（url3）。
        assertEquals("https://t/3", e.previewUrl)
        assertEquals(3840, e.videoWidth)
        assertEquals(7_200_000L, e.durationMs)
    }

    @Test
    fun `目录项不带缩略图与时长`() {
        val json = MiniJson.parseObject(
            """{"fs_id":7,"server_filename":"电影","isdir":1,"thumbs":{"url1":"https://t/1"}}""",
        )
        val e = BaiduMapper.toEntry(json)!!
        assertTrue(e.isDir)
        assertEquals(0L, e.sizeBytes)
        assertNull(e.previewUrl)
        assertNull(e.durationMs)
    }

    @Test
    fun `没有 fs_id 或文件名的脏数据直接跳过`() {
        assertNull(BaiduMapper.toEntry(MiniJson.parseObject("""{"server_filename":"a.mkv"}""")))
        assertNull(BaiduMapper.toEntry(MiniJson.parseObject("""{"fs_id":1}""")))
    }

    @Test
    fun `列表项四种位置都认`() {
        val top = """{"list":[{"fs_id":1,"server_filename":"a"}]}"""
        val info = """{"info":[{"fs_id":1,"server_filename":"a"}]}"""
        val dataList = """{"data":{"list":[{"fs_id":1,"server_filename":"a"}]}}"""
        val dataArr = """{"data":[{"fs_id":1,"server_filename":"a"}]}"""
        for (body in listOf(top, info, dataList, dataArr)) {
            assertEquals(body, 1, BaiduMapper.listItemsOf(MiniJson.parseObject(body)).size)
        }
    }

    // ------------------------------------------------------------------
    // 会员档位
    // ------------------------------------------------------------------

    @Test
    fun `会员档位认数字与字符串`() {
        assertEquals(
            BaiduVipType.SVIP,
            BaiduMapper.parseVipType(MiniJson.parseObject("""{"data":{"vip_type":2}}""")),
        )
        assertEquals(
            BaiduVipType.VIP,
            BaiduMapper.parseVipType(MiniJson.parseObject("""{"data":{"vip_type":1}}""")),
        )
        // 认不出来时按普通用户（保守：只请求 480P，不会去要一个拿不到的档）。
        assertEquals(
            BaiduVipType.NORMAL,
            BaiduMapper.parseVipType(MiniJson.parseObject("""{"data":{}}""")),
        )
        assertEquals(
            BaiduVipType.SVIP,
            BaiduMapper.parseVipType(MiniJson.parseObject("""{"data":{"product_name":"svip"}}""")),
        )
    }
}
