package com.cloudcine.tv.library

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * [MiniJson] 的读写行为。
 *
 * ## 为什么这组断言值得写
 *
 * 它不是通用 JSON 库，**只服务备份清单**。而清单里有两个字段的表示形式
 * 直接决定同步方向：
 *
 *   * `schemaVersion` 必须是整数（写成 `16.0` 时 Dart 的 `as int?` 给 null，
 *     版本号悄悄退化成 1）；
 *   * 时间字符串里的 `Z` 必须原样保留（少了它 Dart 按本地时间解析）。
 *
 * 所以「数字怎么输出」「字符串怎么转义」这两件事必须被钉住。
 */
class MiniJsonTest {

    // ── 写 ──────────────────────────────────────────────────────────

    @Test
    fun `整数不写成小数`() {
        assertEquals("16", MiniJson.write(16))
        assertEquals("0", MiniJson.write(0))
        assertEquals("-3", MiniJson.write(-3))
        assertEquals("16", MiniJson.write(16L))
        // Double 的整数值也压成整数 —— 这是 trimDouble 存在的理由。
        assertEquals("16", MiniJson.write(16.0))
        assertEquals("1.5", MiniJson.write(1.5))
    }

    @Test
    fun `非有限浮点写成 null`() {
        // JSON 没有 NaN / Infinity，写出来就是非法 JSON。
        assertEquals("null", MiniJson.write(Double.NaN))
        assertEquals("null", MiniJson.write(Double.POSITIVE_INFINITY))
    }

    @Test
    fun `中文不转义`() {
        // 与 Dart 的 jsonEncode 一致：输出 UTF-8 原文，不写 \uXXXX。
        // 这直接决定了「小米电视」这个设备名在备份包里长什么样。
        assertEquals("\"小米电视 📺\"", MiniJson.write("小米电视 📺"))
    }

    @Test
    fun `控制字符与引号反斜杠转义`() {
        assertEquals("\"a\\\"b\"", MiniJson.write("a\"b"))
        assertEquals("\"a\\\\b\"", MiniJson.write("a\\b"))
        assertEquals("\"a\\nb\"", MiniJson.write("a\nb"))
        assertEquals("\"a\\rb\"", MiniJson.write("a\rb"))
        assertEquals("\"a\\tb\"", MiniJson.write("a\tb"))
        assertEquals("\"\\u0001\"", MiniJson.write("\u0001"))
    }

    @Test
    fun `对象保持插入顺序`() {
        val m = LinkedHashMap<String, Any?>()
        m["b"] = 1
        m["a"] = 2
        assertEquals("{\"b\":1,\"a\":2}", MiniJson.write(m))
    }

    @Test
    fun `嵌套数组与 null`() {
        assertEquals("[\"a\",1,null,true]", MiniJson.write(listOf("a", 1, null, true)))
        assertEquals("{}", MiniJson.write(emptyMap<String, Any?>()))
        assertEquals("[]", MiniJson.write(emptyList<Any>()))
    }

    // ── 读 ──────────────────────────────────────────────────────────

    @Test
    fun `读回对象 整数是 Long 小数是 Double`() {
        val v = MiniJson.parseObject("{\"a\":16,\"b\":1.5,\"c\":\"x\",\"d\":true,\"e\":null}")
        assertEquals(16L, v["a"])
        assertEquals(1.5, v["b"])
        assertEquals("x", v["c"])
        assertEquals(true, v["d"])
        assertNull(v["e"])
    }

    @Test
    fun `读回转义字符`() {
        val v = MiniJson.parseObject("{\"s\":\"a\\\"b\\\\c\\nd\\u4e2d\"}")
        assertEquals("a\"b\\c\nd中", v["s"])
    }

    @Test
    fun `读回嵌套数组`() {
        val v = MiniJson.parseObject("{\"fileNames\":[\"cloudcine.sqlite\",\"posters/\"]}")
        @Suppress("UNCHECKED_CAST")
        val names = v["fileNames"] as List<Any?>
        assertEquals(listOf("cloudcine.sqlite", "posters/"), names)
    }

    @Test
    fun `容忍空白`() {
        val v = MiniJson.parseObject("  {\n  \"a\" : 1 ,\n  \"b\" : [ 1 , 2 ]\n}  ")
        assertEquals(1L, v["a"])
        assertEquals(listOf<Any?>(1L, 2L), v["b"])
    }

    @Test
    fun `读不懂就抛 不做容错`() {
        // 容错会把「包坏了」和「包是老版本、少一个字段」混在一起，
        // 而这两件事的处理完全相反。
        val bad = listOf(
            "",
            "{",
            "{\"a\"}",
            "{\"a\":}",
            "{\"a\":1,}",
            "[1,2",
            "\"未闭合",
            "tru",
            "{\"a\":1} 尾巴",
            "{\"a\":\"\\q\"}",
            "{\"a\":\"\\u12\"}",
        )
        for (s in bad) {
            try {
                MiniJson.parse(s)
                fail("应当抛 IllegalArgumentException：$s")
            } catch (e: IllegalArgumentException) {
                assertTrue(e.message!!.isNotEmpty())
            }
        }
    }

    @Test
    fun `parseObject 对非对象输入抛异常`() {
        for (s in listOf("[1]", "\"x\"", "1", "null")) {
            try {
                MiniJson.parseObject(s)
                fail("应当抛 IllegalArgumentException：$s")
            } catch (_: IllegalArgumentException) {
                // 期望
            }
        }
    }

    @Test
    fun `写读往返`() {
        val original = linkedMapOf<String, Any?>(
            "deviceId" to "tv-1",
            "deviceName" to "小米电视",
            "schemaVersion" to 16,
            "fileNames" to listOf("cloudcine.sqlite", "posters/"),
            "note" to null,
        )
        val back = MiniJson.parseObject(MiniJson.write(original))
        assertEquals("tv-1", back["deviceId"])
        assertEquals("小米电视", back["deviceName"])
        assertEquals(16L, back["schemaVersion"])
        assertEquals(listOf("cloudcine.sqlite", "posters/"), back["fileNames"])
        assertNull(back["note"])
    }
}
