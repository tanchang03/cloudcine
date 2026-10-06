package com.cloudcine.tv.pan

import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * 夸克上传里**纯计算**的那部分：签名串、`CompleteMultipartUpload` XML、
 * 哈希与 Base64。
 *
 * ## 为什么单独抽出来
 *
 * 这几样东西错了**全部不报错**，只是让 OSS 回 `403 SignatureDoesNotMatch`
 * 或让分片合并失败：
 *
 *   * 签名串（`auth_meta`）里的换行、字段顺序、`Content-Type` 那几行，
 *     必须与**真正发出去的请求头**逐字一致 —— 差一个 `\n` 就是 403；
 *   * `CompleteMultipartUpload` 的 XML 里 `ETag` 必须用**双引号**包起来、
 *     分片必须**按 part_number 升序**，否则「分片不匹配」；
 *   * `Content-MD5` 是 XML 字节的 MD5 再 Base64（**不是** hex），
 *     写错了 OSS 直接拒绝。
 *
 * 这些东西在真机上排查一次要十分钟（还只能看到一句 403），而在单测里
 * 逐字比对只要一毫秒。所以它们必须是纯函数、不碰网络、不碰 Android API。
 *
 * ⛔ **不用 `android.util.Base64`**：JVM 单测里它是空壳（返回 null），
 *    用它写的签名串在单测里根本跑不起来。自己写二十行反而可测、可控
 *    （而且必须保证**不换行** —— OSS 的签名对换行敏感）。
 *
 * ⛔ 也不引 `okhttp` / `commons-codec`：本工程要能离线构建。
 */
object OssAuth {

    /**
     * OSS 请求里带的 `x-oss-user-agent`。
     *
     * ⛔ 这个值**参与签名计算**（它出现在 `auth_meta` 的
     * `x-oss-user-agent:` 那一行），所以它必须与实际请求头**逐字相同**。
     * 夸克服务端按这个串验签，改成 `cloudcine/1.0` 会直接 403。
     */
    const val OSS_USER_AGENT = "aliyun-sdk-js/6.6.1"

    /** 分片上传的一个分片：序号 + OSS 回的 ETag（**已去掉引号**）。 */
    data class Part(val partNumber: Int, val etag: String)

    // ------------------------------------------------------------------
    // 编码 / 哈希
    // ------------------------------------------------------------------

    private const val ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    /**
     * 标准 Base64，**带 `=` 补齐、不换行**。
     *
     * ⛔ 不换行这一点是硬要求：`x-oss-callback` 的值会进签名串，而签名串
     *    是逐字符拼出来的 —— 中间插了 `\r\n` 就再也对不上。
     *    （`android.util.Base64.DEFAULT` 会换行，所以那个默认值本来也不能用。）
     */
    fun base64(bytes: ByteArray): String {
        val sb = StringBuilder((bytes.size + 2) / 3 * 4)
        var i = 0
        while (i < bytes.size) {
            val b0 = bytes[i].toInt() and 0xFF
            val b1 = if (i + 1 < bytes.size) bytes[i + 1].toInt() and 0xFF else -1
            val b2 = if (i + 2 < bytes.size) bytes[i + 2].toInt() and 0xFF else -1

            sb.append(ALPHABET[b0 shr 2])
            sb.append(ALPHABET[((b0 and 0x03) shl 4) or (if (b1 >= 0) b1 shr 4 else 0)])
            sb.append(
                if (b1 >= 0) {
                    ALPHABET[((b1 and 0x0F) shl 2) or (if (b2 >= 0) b2 shr 6 else 0)]
                } else {
                    '='
                },
            )
            sb.append(if (b2 >= 0) ALPHABET[b2 and 0x3F] else '=')
            i += 3
        }
        return sb.toString()
    }

    /** MD5 的 **hex 小写**（`file/update/hash` 的 `md5` 字段要这个形式）。 */
    fun md5Hex(bytes: ByteArray): String = hex(MessageDigest.getInstance("MD5").digest(bytes))

    /** SHA1 的 **hex 小写**（同上，`sha1` 字段）。 */
    fun sha1Hex(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-1").digest(bytes))

    /**
     * MD5 的 **Base64**（`Content-MD5` 请求头要这个形式）。
     *
     * ⛔ 与 [md5Hex] **不是**一回事：`file/update/hash` 的 `md5` 字段要 hex，
     *    而 `Content-MD5` 头要 Base64。两者混用不会报「参数错误」，
     *    只会得到一个 403 或 `InvalidDigest`。
     */
    fun md5Base64(bytes: ByteArray): String =
        base64(MessageDigest.getInstance("MD5").digest(bytes))

    private fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4])
            sb.append(HEX[v and 0x0F])
        }
        return sb.toString()
    }

    private const val HEX = "0123456789abcdef"

    // ------------------------------------------------------------------
    // 时间
    // ------------------------------------------------------------------

    /**
     * OSS 要的 `x-oss-date`：`Tue, 06 Oct 2026 11:16:13 GMT`。
     *
     * ⛔ 必须**带 `GMT` 字样**（不是 `+0000`）、且是**英文星期/月份缩写** ——
     *    它是签名串里的一行，格式不对 OSS 直接判 `RequestTimeTooSkewed`。
     *    `Locale.US` 不能省：某些 ROM 的默认 locale 会输出中文月份。
     *
     * @param epochMillis 传入而不是内部取 `System.currentTimeMillis()`，
     *   这样单测能钉住一个确定的值。
     */
    fun ossTimestamp(epochMillis: Long): String {
        val fmt = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date(epochMillis))
    }

    // ------------------------------------------------------------------
    // 签名串（auth_meta）
    // ------------------------------------------------------------------

    /**
     * 分片 PUT 的签名串。
     *
     * 逐行对应真实请求：
     * ```
     * PUT
     *                      ← Content-MD5 为空
     * application/octet-stream
     * <x-oss-date>
     * x-oss-date:<x-oss-date>
     * x-oss-user-agent:<OSS_USER_AGENT>
     * /<bucket>/<objKey>?partNumber=<n>&uploadId=<id>
     * ```
     *
     * ⛔ 第 2 行是**空行**（PUT 没带 `Content-MD5`）—— 顺手删掉它
     *    会让后面所有行整体上移，签名全错。
     * ⛔ 查询串里 `partNumber` 在 `uploadId` **之前**，顺序不能换。
     */
    fun partAuthMeta(
        bucket: String,
        objKey: String,
        partNumber: Int,
        uploadId: String,
        ossDate: String,
    ): String = buildString {
        append("PUT\n")
        append("\n")
        append("application/octet-stream\n")
        append(ossDate).append('\n')
        append("x-oss-date:").append(ossDate).append('\n')
        append("x-oss-user-agent:").append(OSS_USER_AGENT).append('\n')
        append('/').append(bucket).append('/').append(objKey)
        append("?partNumber=").append(partNumber).append("&uploadId=").append(uploadId)
    }

    /**
     * `CompleteMultipartUpload` 的签名串。
     *
     * ⛔ 与分片那条的差异全在细节上，逐条对上：
     *   * 方法是 `POST`；
     *   * 第 2 行是 **`Content-MD5` 的 Base64**（[md5Base64]，不是 hex）；
     *   * 第 3 行是 `application/xml`（不是 `application/octet-stream`）；
     *   * `x-oss-callback` **排在 `x-oss-date` 前面**（字典序）；
     *   * 查询串里**只有 `uploadId`**，没有 `partNumber`。
     */
    fun completeAuthMeta(
        bucket: String,
        objKey: String,
        uploadId: String,
        ossDate: String,
        contentMd5Base64: String,
        callbackBase64: String,
    ): String = buildString {
        append("POST\n")
        append(contentMd5Base64).append('\n')
        append("application/xml\n")
        append(ossDate).append('\n')
        append("x-oss-callback:").append(callbackBase64).append('\n')
        append("x-oss-date:").append(ossDate).append('\n')
        append("x-oss-user-agent:").append(OSS_USER_AGENT).append('\n')
        append('/').append(bucket).append('/').append(objKey)
        append("?uploadId=").append(uploadId)
    }

    // ------------------------------------------------------------------
    // CompleteMultipartUpload XML
    // ------------------------------------------------------------------

    /**
     * 构造 OSS 的 `CompleteMultipartUpload` 请求体。
     *
     * ⛔ 两条规则错了都**不报错**，只表现为「合并上传失败」：
     *   * 分片必须**按 part_number 升序**（这里显式排序，不信任调用方）；
     *   * `ETag` 必须用**双引号**包起来 —— 原样回填分片 PUT 响应里的值。
     *     OSS 返回的 `ETag` 自带引号（`"abc"`），[Part.etag] 里存的是
     *     **去掉引号**之后的裸值，这里再补上。存的时候就带引号、
     *     这里再加一层的话会变成 `""abc""`。
     *
     * ⛔ 换行用 `\n`（不是 `\r\n`）—— 与 PC 端
     *    `QuarkAdapter.buildCompleteMultipartXml` 逐字节一致，也因为
     *    这个 XML 的 MD5 会进签名串。
     */
    fun completeMultipartXml(parts: List<Part>): String {
        val ordered = parts.sortedBy { it.partNumber }
        val sb = StringBuilder(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<CompleteMultipartUpload>\n",
        )
        for (p in ordered) {
            sb.append("<Part>\n")
            sb.append("<PartNumber>").append(p.partNumber).append("</PartNumber>\n")
            sb.append("<ETag>\"").append(p.etag).append("\"</ETag>\n")
            sb.append("</Part>\n")
        }
        sb.append("</CompleteMultipartUpload>")
        return sb.toString()
    }

    /**
     * 去掉 ETag 两侧的引号。
     *
     * ⛔ 别用 `trim('"')`：那会把 `W/"abc"` 这种弱校验前缀也一起吃掉。
     *    只剥**最外层**成对的引号。
     */
    fun stripEtagQuotes(raw: String): String {
        var s = raw.trim()
        if (s.length >= 2 && s.first() == '"' && s.last() == '"') s = s.substring(1, s.length - 1)
        return s
    }

    /**
     * 由预上传响应拼出 OSS 的基地址。
     *
     * 夸克给的 `upload_url` 形如 `http://upload.quark.cn`（有的环境带路径），
     * 最终地址是 `https://<bucket>.<host>/<obj_key>`。
     *
     * ⛔ `upload_url` 为空时**必须报错**，不能「凑一个」—— 拼出来的
     *    `https://<bucket>./<key>` 会连到一个不存在的域名，表现为
     *    连接超时，而日志里看不出是这里的问题。
     */
    fun ossBase(uploadUrl: String, bucket: String, objKey: String): String {
        val host = uploadUrl
            .replace("http://", "")
            .replace("https://", "")
            .substringBefore('/')
            .trim()
        require(host.isNotEmpty()) { "预上传响应没有给出 upload_url，无法定位 OSS" }
        require(bucket.isNotEmpty()) { "预上传响应没有给出 bucket" }
        require(objKey.isNotEmpty()) { "预上传响应没有给出 obj_key" }
        return "https://$bucket.$host/$objKey"
    }
}
