package com.cloudcine.tv.library

import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * 备份包（`.ccbak`）的字节格式。
 *
 * ## 格式（与 PC 端 `library_backup_service.dart` **逐字节一致**）
 *
 * ```
 * [magic 'CCBK'(4)] [manifestLen(4, BE)] [manifest JSON utf8]
 * [dbLen(4, BE)]    [db 原始字节]        [海报打包字节(可选)]
 * ```
 *
 * ⛔ **不是 ZIP**。PC 端刻意用了这个自描述格式（`dart:io` 没有内置 ZIP、
 * 不想为两个文件引 `archive` 包）。Android 这边**只能跟着走** —— 一旦有人
 * 「顺手换成 zip 更标准」，两端的备份就再也互相读不了，而报错会是
 * 「magic 不匹配」，看不出是格式分歧。
 *
 * ## 海报目录的打包
 *
 * 对每个文件写 `[nameLen(4)][name utf8][dataLen(4)][data]`，末尾写 `[0]` 终止。
 * 没有目录树 —— 海报缓存本来就是**平铺**的（文件名自带作品键）。
 *
 * ## 长度前缀都是**大端** uint32
 *
 * Dart 的 `ByteData.setUint32` 默认就是 big-endian。⛔ 写成小端不会报错，
 * 只会在另一端得到一个天文数字的长度然后「包超出范围」。
 */
object BackupPackage {

    private const val TAG = "CloudCine"

    /** magic bytes：ASCII `CCBK`。 */
    private val MAGIC = byteArrayOf(0x43, 0x43, 0x42, 0x4B)

    private const val HEADER_LEN = 8 // magic(4) + manifestLen(4)

    /** 备份包扩展名。 */
    const val EXTENSION = ".ccbak"

    /** 网盘上放备份的目录名。与 PC 端 `LibraryBackupService.defaultBackupDir` 一致。 */
    const val BACKUP_DIR_NAME = "云影备份"

    /** 解析结果。 */
    class Parsed(
        val manifest: BackupManifest,
        /** 数据库的原始字节（**没有**任何加工，直接写文件即可）。 */
        val dbBytes: ByteArray,
        /** 海报目录的打包字节；备份里没有海报时为 `null`。 */
        val posterBytes: ByteArray?,
    )

    // ------------------------------------------------------------------
    // 组装 / 解析
    // ------------------------------------------------------------------

    /**
     * 组装备份包。
     *
     * ⛔ `manifest.fileNames` 必须与传进来的内容**对得上**：导入端是拿
     * `fileNames.contains("posters/")` 来决定要不要解海报的。这边写 `posters/`
     * 而 [posterBytes] 是 null 的话，导入端会拿 `dbEnd` 之后**空的一段**去解包，
     * 解出 0 个文件 —— 不报错，但海报全丢。
     */
    fun build(manifest: BackupManifest, dbBytes: ByteArray, posterBytes: ByteArray?): ByteArray {
        val manifestBytes = manifest.toBytes()
        val out = ByteArrayOutputStream(
            HEADER_LEN + manifestBytes.size + 4 + dbBytes.size + (posterBytes?.size ?: 0),
        )
        out.write(MAGIC)
        out.write(uint32Be(manifestBytes.size))
        out.write(manifestBytes)
        out.write(uint32Be(dbBytes.size))
        out.write(dbBytes)
        if (posterBytes != null && posterBytes.isNotEmpty()) out.write(posterBytes)
        return out.toByteArray()
    }

    /**
     * 解析备份包。
     *
     * 每一处长度越界都**显式抛 [BackupFormatException]**，不做「尽力而为」——
     * 一个被截断的备份包如果被「尽量解开」，结果就是**半个媒体库**，
     * 而用户会以为恢复成功了。
     */
    fun parse(bytes: ByteArray): Parsed {
        if (bytes.size < HEADER_LEN) {
            throw BackupFormatException("备份包太小（${bytes.size} 字节），连包头都不够")
        }
        for (i in MAGIC.indices) {
            if (bytes[i] != MAGIC[i]) {
                throw BackupFormatException("备份包格式错误：magic 不匹配（不是 .ccbak？）")
            }
        }
        val manifestLen = readUint32Be(bytes, 4)
        val manifestStart = HEADER_LEN.toLong()
        if (manifestStart + manifestLen > bytes.size) {
            throw BackupFormatException(
                "备份包格式错误：清单长度超出包范围（要 $manifestLen，只剩 ${bytes.size - manifestStart}）",
            )
        }
        val manifest = BackupManifest.fromBytes(
            bytes.copyOfRange(manifestStart.toInt(), (manifestStart + manifestLen).toInt()),
        )

        val dataOffset = manifestStart + manifestLen
        if (dataOffset + 4 > bytes.size) {
            throw BackupFormatException("备份包格式错误：缺少数据库长度")
        }
        val dbLen = readUint32Be(bytes, dataOffset.toInt())
        val dbStart = dataOffset + 4
        val dbEnd = dbStart + dbLen
        if (dbEnd > bytes.size) {
            throw BackupFormatException(
                "备份包格式错误：数据库字节超出包范围（需要 $dbEnd，只有 ${bytes.size}）",
            )
        }
        val dbBytes = bytes.copyOfRange(dbStart.toInt(), dbEnd.toInt())

        // ⛔ 两个条件都要：`fileNames` 里声明了海报**且**包尾确实还有字节。
        // 只看包尾长度的话，一个「声明没有海报、但尾部有垃圾」的包会去解垃圾；
        // 只看 `fileNames` 的话，一个被截断的包会解出 0 个文件然后静默丢海报。
        val posterBytes = if (
            manifest.fileNames.contains(BackupManifest.POSTERS_ENTRY) && dbEnd < bytes.size
        ) {
            bytes.copyOfRange(dbEnd.toInt(), bytes.size)
        } else {
            null
        }

        return Parsed(manifest, dbBytes, posterBytes)
    }

    /**
     * 只取清单（不复制 db 字节）。
     *
     * 同步的「比时间戳」那一步只需要清单 —— 但 PC 端那边是**下载整个包**
     * 再 `_extractManifest`（见 `LibraryBackupService.sync` 的注释：备份包
     * 通常几 MB 到几十 MB，可接受）。Android 这边也照做，因为夸克没有
     * 「只取文件头」的接口，Range 请求能省流量但会多一条容易写错的路径。
     */
    fun extractManifest(bytes: ByteArray): BackupManifest {
        if (bytes.size < HEADER_LEN) throw BackupFormatException("备份包太小（${bytes.size} 字节）")
        for (i in MAGIC.indices) {
            if (bytes[i] != MAGIC[i]) throw BackupFormatException("备份包格式错误：magic 不匹配")
        }
        val manifestLen = readUint32Be(bytes, 4)
        val end = HEADER_LEN + manifestLen
        if (end > bytes.size) throw BackupFormatException("备份包格式错误：清单长度超出包范围")
        return BackupManifest.fromBytes(bytes.copyOfRange(HEADER_LEN, end.toInt()))
    }

    // ------------------------------------------------------------------
    // 海报目录打包 / 解包
    // ------------------------------------------------------------------

    /** 把目录里（**只**第一层）的所有普通文件打包。空目录返回空数组。 */
    fun packDirectory(dir: File): ByteArray {
        val out = ByteArrayOutputStream()
        val files = dir.listFiles()?.filter { it.isFile }?.sortedBy { it.name } ?: emptyList()
        for (f in files) {
            val nameBytes = f.name.toByteArray(Charsets.UTF_8)
            val data = f.readBytes()
            out.write(uint32Be(nameBytes.size))
            out.write(nameBytes)
            out.write(uint32Be(data.size))
            out.write(data)
        }
        out.write(uint32Be(0)) // 终止标记
        return out.toByteArray()
    }

    /**
     * 解包到目录。返回写出的文件数。
     *
     * ⛔ **拒绝带路径分隔符的名字**。PC 端的实现是直接
     * `File('${dir.path}/$name')`，一个 `../../x` 就能写到目录外 ——
     * 那个包可能是从网盘下来的、也可能被人手工改过。多这一层判断不改变
     * 任何合法包的解析结果（合法的海报文件名是 `作品键_8位散列.jpg`，不含分隔符）。
     */
    fun unpackDirectory(bytes: ByteArray, dir: File): Int {
        if (!dir.exists()) dir.mkdirs()
        var offset = 0
        var count = 0
        while (offset < bytes.size) {
            if (offset + 4 > bytes.size) break
            val nameLen = readUint32Be(bytes, offset).toInt()
            offset += 4
            if (nameLen == 0) break // 终止标记

            if (offset + nameLen > bytes.size) {
                Log.w(TAG, "海报解包：文件名字节越界，提前结束（已解 $count 个）")
                break
            }
            val name = String(bytes, offset, nameLen, Charsets.UTF_8)
            offset += nameLen

            if (offset + 4 > bytes.size) {
                Log.w(TAG, "海报解包：缺数据长度，提前结束（已解 $count 个）")
                break
            }
            val dataLen = readUint32Be(bytes, offset).toInt()
            offset += 4

            if (offset + dataLen > bytes.size) {
                Log.w(TAG, "海报解包：数据越界，提前结束（已解 $count 个）")
                break
            }
            if (isUnsafeName(name)) {
                Log.w(TAG, "海报解包：跳过不安全的名字「$name」")
                offset += dataLen
                continue
            }

            runCatching {
                File(dir, name).writeBytes(bytes.copyOfRange(offset, offset + dataLen))
                count++
            }.onFailure { Log.w(TAG, "海报解包：写「$name」失败：${it.message}") }
            offset += dataLen
        }
        return count
    }

    private fun isUnsafeName(name: String): Boolean =
        name.isEmpty() ||
            name == "." ||
            name == ".." ||
            name.contains('/') ||
            name.contains('\\') ||
            name.contains('\u0000')

    // ------------------------------------------------------------------
    // 小端序工具
    // ------------------------------------------------------------------

    /** 大端 uint32 → `Long`（Kotlin 的 `Int` 有符号，装不下 2^31 以上的长度）。 */
    private fun readUint32Be(b: ByteArray, at: Int): Long =
        ((b[at].toLong() and 0xFF) shl 24) or
            ((b[at + 1].toLong() and 0xFF) shl 16) or
            ((b[at + 2].toLong() and 0xFF) shl 8) or
            (b[at + 3].toLong() and 0xFF)

    private fun uint32Be(v: Int): ByteArray = byteArrayOf(
        ((v ushr 24) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(),
        (v and 0xFF).toByte(),
    )
}

/** 备份包读不懂时抛这个（而不是 `IllegalArgumentException`，便于上层分辨）。 */
class BackupFormatException(message: String) : Exception(message)
