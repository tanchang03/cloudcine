package com.cloudcine.tv.library

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * [BackupPackage] 的字节格式。
 *
 * ## 为什么这组断言值得写
 *
 * `.ccbak` 是自描述的**二进制**格式（不是 ZIP），两端的读取端都没有
 * 「格式不认识的字段就跳过」这种宽容度 —— 长度前缀写成小端、或者少写一个
 * `[0]` 终止标记，症状都是**另一端读出天文数字然后报「包超出范围」**，
 * 看不出是字节序分歧。
 *
 * 另外 [BackupPackage.unpackDirectory] 会往磁盘写文件，而它读的是
 * **从网盘下载下来的、可能被人手工改过的**字节 —— 名字里的 `../` 必须挡住。
 */
class BackupPackageTest {

    private val manifest = BackupManifest(
        deviceId = "tv-1",
        deviceName = "小米电视",
        createdAt = 1_759_700_123_456L,
        libraryModifiedAt = 1_759_700_000_000L,
        schemaVersion = 16,
        fileNames = listOf(BackupManifest.DB_ENTRY, BackupManifest.POSTERS_ENTRY),
    )

    private val dbBytes = "SQLite format 3\u0000假装是数据库".toByteArray(Charsets.UTF_8)

    private fun tempDir(): File = Files.createTempDirectory("cloudcine-test").toFile()

    private fun u32(v: Int) = byteArrayOf(
        ((v ushr 24) and 0xFF).toByte(),
        ((v ushr 16) and 0xFF).toByte(),
        ((v ushr 8) and 0xFF).toByte(),
        (v and 0xFF).toByte(),
    )

    // ── 组装 / 解析 ──────────────────────────────────────────────────

    @Test
    fun `magic 是 ASCII CCBK 且长度前缀是大端`() {
        val pkg = BackupPackage.build(manifest.copy(fileNames = listOf(BackupManifest.DB_ENTRY)), dbBytes, null)
        assertEquals('C'.code.toByte(), pkg[0])
        assertEquals('C'.code.toByte(), pkg[1])
        assertEquals('B'.code.toByte(), pkg[2])
        assertEquals('K'.code.toByte(), pkg[3])

        // 第 5 个字节（下标 4）是清单长度的最高位。清单 JSON 一百多字节，
        // 大端下这一字节必然是 0；写成小端就会是个非零值。
        assertEquals("长度前缀必须是大端", 0, pkg[4].toInt())
    }

    @Test
    fun `往返不丢清单与数据库字节`() {
        val pkg = BackupPackage.build(manifest, dbBytes, null)
        val parsed = BackupPackage.parse(pkg)
        assertEquals(manifest, parsed.manifest)
        assertArrayEquals(dbBytes, parsed.dbBytes)
        assertNull(parsed.posterBytes)
    }

    @Test
    fun `往返带上海报段`() {
        val posters = u32(3) + "a.jpg".toByteArray() + u32(2) + byteArrayOf(1, 2) + u32(0)
        val pkg = BackupPackage.build(manifest, dbBytes, posters)
        val parsed = BackupPackage.parse(pkg)
        assertArrayEquals(posters, parsed.posterBytes)
        assertArrayEquals(dbBytes, parsed.dbBytes)
    }

    @Test
    fun `extractManifest 只取清单`() {
        val pkg = BackupPackage.build(manifest, dbBytes, null)
        assertEquals(manifest, BackupPackage.extractManifest(pkg))
    }

    @Test
    fun `fileNames 声明了海报但包尾没有字节时 posterBytes 为 null`() {
        // 只看 fileNames 的实现会拿一段空字节去解包 —— 解出 0 个文件、
        // 不报错，海报全丢。
        val pkg = BackupPackage.build(manifest, dbBytes, null)
        assertNull(BackupPackage.parse(pkg).posterBytes)
    }

    @Test
    fun `fileNames 没声明海报时忽略包尾垃圾`() {
        val noPosters = manifest.copy(fileNames = listOf(BackupManifest.DB_ENTRY))
        val pkg = BackupPackage.build(noPosters, dbBytes, null) + byteArrayOf(9, 9, 9)
        val parsed = BackupPackage.parse(pkg)
        assertNull(parsed.posterBytes)
        assertArrayEquals(dbBytes, parsed.dbBytes)
    }

    // ── 坏包 ────────────────────────────────────────────────────────

    @Test
    fun `太短或 magic 不对一律抛 BackupFormatException`() {
        for (bad in listOf(ByteArray(0), ByteArray(3), byteArrayOf(0x50, 0x4B, 3, 4, 0, 0, 0, 0))) {
            try {
                BackupPackage.parse(bad)
                fail("应当抛 BackupFormatException")
            } catch (e: BackupFormatException) {
                assertTrue(e.message!!.isNotEmpty())
            }
        }
    }

    @Test
    fun `清单长度超出包范围时抛异常`() {
        val pkg = BackupPackage.build(manifest, dbBytes, null)
        // 把 manifestLen 改成一个装不下的值。
        val hacked = pkg.copyOf()
        val big = u32(1_000_000)
        for (i in big.indices) hacked[4 + i] = big[i]
        try {
            BackupPackage.parse(hacked)
            fail("应当抛 BackupFormatException")
        } catch (e: BackupFormatException) {
            assertTrue(e.message!!.contains("清单长度"))
        }
    }

    @Test
    fun `数据库长度超出包范围时抛异常`() {
        val pkg = BackupPackage.build(manifest, dbBytes, null)
        val hacked = pkg.copyOf()
        // dbLen 紧跟在清单后面；直接把它改成比剩余字节大。
        val manifestLen = ((pkg[4].toInt() and 0xFF) shl 24) or
            ((pkg[5].toInt() and 0xFF) shl 16) or
            ((pkg[6].toInt() and 0xFF) shl 8) or
            (pkg[7].toInt() and 0xFF)
        val at = 8 + manifestLen
        val big = u32(999_999_999)
        for (i in big.indices) hacked[at + i] = big[i]
        try {
            BackupPackage.parse(hacked)
            fail("应当抛 BackupFormatException")
        } catch (e: BackupFormatException) {
            assertTrue(e.message!!.contains("数据库字节"))
        }
    }

    @Test
    fun `被截断的包不会被尽力而为地解开`() {
        // 「尽量解开」的结果是半个媒体库，而用户以为恢复成功了。
        val pkg = BackupPackage.build(manifest, dbBytes, null)
        val cut = pkg.copyOfRange(0, pkg.size - 5)
        try {
            BackupPackage.parse(cut)
            fail("应当抛 BackupFormatException")
        } catch (_: BackupFormatException) {
            // 期望
        }
    }

    // ── 海报目录打包 ────────────────────────────────────────────────

    @Test
    fun `空目录打包出 4 个字节的终止标记`() {
        val dir = tempDir()
        try {
            assertArrayEquals(u32(0), BackupPackage.packDirectory(dir))
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `目录打包解包往返 文件名与二进制内容都不变`() {
        val src = tempDir()
        val dst = tempDir()
        try {
            File(src, "作品键_1a2b3c4d.jpg").writeBytes(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3))
            File(src, "另一个.jpg").writeBytes("内容".toByteArray(Charsets.UTF_8))
            File(src, "子目录").mkdirs() // 只打包第一层的普通文件

            val packed = BackupPackage.packDirectory(src)
            val n = BackupPackage.unpackDirectory(packed, dst)

            assertEquals(2, n)
            assertArrayEquals(
                byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3),
                File(dst, "作品键_1a2b3c4d.jpg").readBytes(),
            )
            assertEquals("内容", File(dst, "另一个.jpg").readText(Charsets.UTF_8))
            assertFalse("子目录不该被解出来", File(dst, "子目录").exists())
        } finally {
            src.deleteRecursively()
            dst.deleteRecursively()
        }
    }

    @Test
    fun `解包拒绝带路径分隔符的名字`() {
        // 这个包可能是从网盘下来的、也可能被人手工改过。
        val dst = tempDir()
        val outside = File(dst.parentFile, "evil.txt")
        outside.delete()
        try {
            val name = "../evil.txt".toByteArray(Charsets.UTF_8)
            val payload = u32(name.size) + name + u32(1) + byteArrayOf(7) + u32(0)
            assertEquals(0, BackupPackage.unpackDirectory(payload, dst))
            assertFalse("不该写到目录外", outside.exists())
        } finally {
            dst.deleteRecursively()
            outside.delete()
        }
    }

    @Test
    fun `解包遇到越界长度就停下 不抛`() {
        // 半截的海报段：已经解出来的那些保留，剩下的丢掉。
        val dst = tempDir()
        try {
            val name = "a.jpg".toByteArray(Charsets.UTF_8)
            val payload = u32(name.size) + name + u32(99) + byteArrayOf(1, 2, 3) + u32(0)
            assertEquals(0, BackupPackage.unpackDirectory(payload, dst))
        } finally {
            dst.deleteRecursively()
        }
    }

    @Test
    fun `扩展名与备份目录名与 PC 端一致`() {
        assertEquals(".ccbak", BackupPackage.EXTENSION)
        assertEquals("云影备份", BackupPackage.BACKUP_DIR_NAME)
        assertEquals("cloudcine.sqlite", BackupManifest.DB_ENTRY)
        assertEquals("posters/", BackupManifest.POSTERS_ENTRY)
    }
}
