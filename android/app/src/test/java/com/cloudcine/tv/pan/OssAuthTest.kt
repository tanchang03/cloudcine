package com.cloudcine.tv.pan

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * [OssAuth] 的签名串 / XML / 编码。
 *
 * ## 为什么这组断言值得写
 *
 * 上传链路里这几样东西**错了全都不报错**，只让 OSS 回一句 403 或让合并
 * 失败 —— 在电视上排查一次要十分钟，而且看不到「哪一行不对」。它们又
 * 恰好全是纯计算，所以拿确定值钉死是最便宜的保险。
 *
 * 断言里的「期望值」是按阿里云 OSS 的签名规范（`Authorization` 的
 * `auth_meta` 格式）与 PC 端 `QuarkAdapter` 的拼法逐字写出来的。
 */
class OssAuthTest {

    private val ts = "Tue, 06 Oct 2026 11:16:13 GMT"
    private val bucket = "bucket1"
    private val objKey = "obj/key"
    private val uploadId = "UID-123"

    // ── Base64 ─────────────────────────────────────────────────────

    @Test
    fun `Base64 与标准实现一致`() {
        // 经典向量（RFC 4648 §10）。
        assertEquals("", OssAuth.base64(ByteArray(0)))
        assertEquals("Zg==", OssAuth.base64("f".toByteArray()))
        assertEquals("Zm8=", OssAuth.base64("fo".toByteArray()))
        assertEquals("Zm9v", OssAuth.base64("foo".toByteArray()))
        assertEquals("Zm9vYg==", OssAuth.base64("foob".toByteArray()))
        assertEquals("Zm9vYmE=", OssAuth.base64("fooba".toByteArray()))
        assertEquals("Zm9vYmFy", OssAuth.base64("foobar".toByteArray()))
    }

    @Test
    fun `Base64 不换行 且长度总是 4 的倍数`() {
        // ⛔ 这一条是硬要求：`x-oss-callback` 的 Base64 会进签名串，
        //    中间插了 \r\n 就再也对不上（android.util.Base64.DEFAULT 会换行）。
        val bytes = ByteArray(256) { it.toByte() }
        val s = OssAuth.base64(bytes)
        assertFalse("不能含换行", s.contains('\n') || s.contains('\r'))
        assertEquals(0, s.length % 4)
        assertEquals((bytes.size + 2) / 3 * 4, s.length)
    }

    @Test
    fun `Base64 覆盖所有字节值且可被标准解码器还原`() {
        val bytes = ByteArray(256) { (it xor 0x5A).toByte() }
        assertEquals(
            java.util.Base64.getEncoder().encodeToString(bytes),
            OssAuth.base64(bytes),
        )
    }

    @Test
    fun `中文按 UTF-8 字节编码`() {
        val s = "云影备份"
        assertEquals(
            java.util.Base64.getEncoder().encodeToString(s.toByteArray(Charsets.UTF_8)),
            OssAuth.base64(s.toByteArray(Charsets.UTF_8)),
        )
    }

    // ── 哈希 ───────────────────────────────────────────────────────

    @Test
    fun `md5 与 sha1 的 hex 都是小写`() {
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", OssAuth.md5Hex(ByteArray(0)))
        assertEquals("da39a3ee5e6b4b0d3255bfef95601890afd80709", OssAuth.sha1Hex(ByteArray(0)))
        assertEquals("900150983cd24fb0d6963f7d28e17f72", OssAuth.md5Hex("abc".toByteArray()))
    }

    @Test
    fun `Content-MD5 用的是 Base64 不是 hex`() {
        // ⛔ 混用不会报「参数错误」，只会得到一个 403 / InvalidDigest。
        assertEquals("1B2M2Y8AsgTpgAmY7PhCfg==", OssAuth.md5Base64(ByteArray(0)))
        assertEquals("kAFQmDzST7DWlj99KOF/cg==", OssAuth.md5Base64("abc".toByteArray()))
        assertFalse(OssAuth.md5Base64("abc".toByteArray()).contains("900150983cd24fb0"))
    }

    // ── 时间 ───────────────────────────────────────────────────────

    @Test
    fun `x-oss-date 是英文缩写加 GMT`() {
        assertEquals("Thu, 01 Jan 1970 00:00:00 GMT", OssAuth.ossTimestamp(0L))
        // 2026-10-06 11:16:13 UTC
        assertEquals(ts, OssAuth.ossTimestamp(1_791_285_373_000L))
    }

    // ── 签名串 ─────────────────────────────────────────────────────

    @Test
    fun `分片签名串逐字对齐 OSS 规范`() {
        // ⛔ 第 2 行是**空行**（PUT 不带 Content-MD5），第 5、6 行是
        //    自定义头（按字典序），最后一行是 `/<bucket>/<key>?<query>`。
        assertEquals(
            "PUT\n" +
                "\n" +
                "application/octet-stream\n" +
                "$ts\n" +
                "x-oss-date:$ts\n" +
                "x-oss-user-agent:aliyun-sdk-js/6.6.1\n" +
                "/bucket1/obj/key?partNumber=2&uploadId=UID-123",
            OssAuth.partAuthMeta(bucket, objKey, partNumber = 2, uploadId = uploadId, ossDate = ts),
        )
    }

    @Test
    fun `合并签名串逐字对齐 OSS 规范`() {
        // ⛔ 与分片那条的差异全在细节：POST / Content-MD5 的 Base64 /
        //    application-xml / x-oss-callback 排在 x-oss-date 之前 /
        //    查询串只有 uploadId。
        assertEquals(
            "POST\n" +
                "1B2M2Y8AsgTpgAmY7PhCfg==\n" +
                "application/xml\n" +
                "$ts\n" +
                "x-oss-callback:CALLBACK_B64\n" +
                "x-oss-date:$ts\n" +
                "x-oss-user-agent:aliyun-sdk-js/6.6.1\n" +
                "/bucket1/obj/key?uploadId=UID-123",
            OssAuth.completeAuthMeta(
                bucket = bucket,
                objKey = objKey,
                uploadId = uploadId,
                ossDate = ts,
                contentMd5Base64 = "1B2M2Y8AsgTpgAmY7PhCfg==",
                callbackBase64 = "CALLBACK_B64",
            ),
        )
    }

    @Test
    fun `签名串里不能出现多余空白`() {
        val meta = OssAuth.partAuthMeta(bucket, objKey, 1, uploadId, ts)
        assertEquals("行数固定为 7", 7, meta.split('\n').size)
        for (line in meta.split('\n')) {
            assertEquals("每行不能有首尾空格：[$line]", line.trim(), line)
        }
    }

    // ── CompleteMultipartUpload XML ─────────────────────────────────

    @Test
    fun `XML 逐字对齐 且 ETag 带双引号`() {
        assertEquals(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                "<CompleteMultipartUpload>\n" +
                "<Part>\n<PartNumber>1</PartNumber>\n<ETag>\"aa\"</ETag>\n</Part>\n" +
                "<Part>\n<PartNumber>2</PartNumber>\n<ETag>\"bb\"</ETag>\n</Part>\n" +
                "</CompleteMultipartUpload>",
            OssAuth.completeMultipartXml(listOf(OssAuth.Part(1, "aa"), OssAuth.Part(2, "bb"))),
        )
    }

    @Test
    fun `XML 里的分片按序号升序 不信任调用方顺序`() {
        // 乱序会让 OSS 判「分片不匹配」。
        val xml = OssAuth.completeMultipartXml(
            listOf(OssAuth.Part(3, "c"), OssAuth.Part(1, "a"), OssAuth.Part(2, "b")),
        )
        val i1 = xml.indexOf("<PartNumber>1<")
        val i2 = xml.indexOf("<PartNumber>2<")
        val i3 = xml.indexOf("<PartNumber>3<")
        assertTrue("三个分片都要出现（i1=$i1 i2=$i2 i3=$i3）", i1 >= 0 && i2 >= 0 && i3 >= 0)
        assertTrue("1 必须排在 2 前面（i1=$i1 i2=$i2）", i1 < i2)
        assertTrue("2 必须排在 3 前面（i2=$i2 i3=$i3）", i2 < i3)
    }

    @Test
    fun `XML 用 LF 不用 CRLF`() {
        // ⛔ 这个 XML 的 MD5 会进签名串，换行形式必须与 PC 端一致。
        val xml = OssAuth.completeMultipartXml(listOf(OssAuth.Part(1, "a")))
        assertFalse(xml.contains("\r"))
    }

    @Test
    fun `空分片列表也能生成合法 XML`() {
        // 正常路径不会走到（`totalParts` 至少为 1），但生成器本身不该炸。
        assertEquals(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                "<CompleteMultipartUpload>\n" +
                "</CompleteMultipartUpload>",
            OssAuth.completeMultipartXml(emptyList()),
        )
    }

    // ── ETag / OSS 基地址 ──────────────────────────────────────────

    @Test
    fun `剥 ETag 引号只剥最外层成对的那一对`() {
        assertEquals("abc", OssAuth.stripEtagQuotes("\"abc\""))
        assertEquals("abc", OssAuth.stripEtagQuotes("  \"abc\"  "))
        assertEquals("abc", OssAuth.stripEtagQuotes("abc"))
        assertEquals("", OssAuth.stripEtagQuotes(""))
        // 单边引号不是成对的，保持原样（真实 ETag 不会长这样）。
        assertEquals("\"abc", OssAuth.stripEtagQuotes("\"abc"))
    }

    @Test
    fun `OSS 基地址按 bucket 加前缀`() {
        assertEquals(
            "https://bucket1.upload.quark.cn/obj/key",
            OssAuth.ossBase("http://upload.quark.cn", "bucket1", "obj/key"),
        )
        assertEquals(
            "https://bucket1.upload.quark.cn/obj/key",
            OssAuth.ossBase("https://upload.quark.cn/", "bucket1", "obj/key"),
        )
        // 带路径的 upload_url：只取主机名。
        assertEquals(
            "https://bucket1.upload.quark.cn/obj/key",
            OssAuth.ossBase("https://upload.quark.cn/some/path", "bucket1", "obj/key"),
        )
    }

    @Test
    fun `缺 upload_url 或 bucket 时必须报错`() {
        // ⛔ 不能「凑一个」：拼出来的域名连不上，表现是连接超时，
        //    日志里看不出是这里的问题。
        for (args in listOf(
            Triple("", "bucket1", "k"),
            Triple("http://upload.quark.cn", "", "k"),
            Triple("http://upload.quark.cn", "bucket1", ""),
        )) {
            try {
                OssAuth.ossBase(args.first, args.second, args.third)
                fail("应当抛 IllegalArgumentException")
            } catch (_: IllegalArgumentException) {
                // 期望
            }
        }
    }

    @Test
    fun `user-agent 常量参与签名 不能改`() {
        assertTrue(OssAuth.partAuthMeta(bucket, objKey, 1, uploadId, ts).contains(OssAuth.OSS_USER_AGENT))
        assertEquals("aliyun-sdk-js/6.6.1", OssAuth.OSS_USER_AGENT)
    }
}
