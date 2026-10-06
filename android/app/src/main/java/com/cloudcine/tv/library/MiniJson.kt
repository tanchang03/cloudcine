package com.cloudcine.tv.library

/**
 * 极小的 JSON 读写器，**只给备份清单（manifest）用**。
 *
 * ## 为什么不直接用 `org.json`
 *
 * 备份清单是跨端契约里最要紧的一块（`libraryModifiedAt` 直接决定同步方向），
 * 而它必须能被**纯 JVM 单测**覆盖。问题是本工程的 JVM 单测跑在
 * `android.jar` 的**空壳实现**上（`testOptions.unitTests.isReturnDefaultValues`），
 * 那里面 `org.json.JSONObject` 的方法体全被抹掉、返回 null —— 用它写的
 * 序列化/反序列化在单测里根本跑不起来，只能靠真机验。
 *
 * 与其为了测一个 7 字段的对象去引 `org.json:json` 或 Robolectric，
 * 不如自己写这一百来行：**零依赖、可单测、行为完全可控**。
 *
 * ⛔ 不要拿它当通用 JSON 库用。工程里其它地方照旧用 `org.json`。
 *
 * ## 与 Dart `jsonEncode` 的差异（都是刻意的）
 *
 *   * 非 ASCII 字符**不转义**（与 Dart 一致，输出 UTF-8 原文）；
 *   * 数字：整数写成整数（`16` 而不是 `16.0`）—— Dart 那边 `schemaVersion`
 *     是 `int`，`jsonDecode` 出来若变成 double，`as int?` 会返回 null，
 *     版本号就悄悄退化成默认值 1。
 */
object MiniJson {

    // ------------------------------------------------------------------
    // 写
    // ------------------------------------------------------------------

    /** 序列化。支持 `Map` / `List` / `String` / `Number` / `Boolean` / `null`。 */
    fun write(value: Any?): String {
        val sb = StringBuilder()
        writeTo(sb, value)
        return sb.toString()
    }

    private fun writeTo(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is String -> writeString(sb, value)
            is Boolean -> sb.append(if (value) "true" else "false")
            is Int, is Long, is Short, is Byte -> sb.append(value.toString())
            is Double -> sb.append(if (value.isFinite()) trimDouble(value) else "null")
            is Float -> sb.append(if (value.isFinite()) trimDouble(value.toDouble()) else "null")
            is Number -> sb.append(value.toString())
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, v) in value) {
                    if (!first) sb.append(',')
                    first = false
                    writeString(sb, k.toString())
                    sb.append(':')
                    writeTo(sb, v)
                }
                sb.append('}')
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (v in value) {
                    if (!first) sb.append(',')
                    first = false
                    writeTo(sb, v)
                }
                sb.append(']')
            }
            else -> writeString(sb, value.toString())
        }
    }

    /** `1.0` → `1`，`1.5` → `1.5`。避免把整数值写成 `16.0`。 */
    private fun trimDouble(d: Double): String =
        if (d == Math.floor(d) && !d.isInfinite() && Math.abs(d) < 1e15) {
            d.toLong().toString()
        } else {
            d.toString()
        }

    private fun writeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (ch in s) {
            when (ch) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (ch < ' ') sb.append("\\u%04x".format(ch.code)) else sb.append(ch)
            }
        }
        sb.append('"')
    }

    // ------------------------------------------------------------------
    // 读
    // ------------------------------------------------------------------

    /**
     * 解析。**读不懂就抛 [IllegalArgumentException]**。
     *
     * ⛔ 这里故意**不**做「容错解析」：调用方（[BackupManifest.fromJson]）才是
     * 决定「某个字段缺了怎么办」的地方 —— 混在一起会让「包坏了」和「包是
     * 老版本、少一个字段」分不清，而这两件事的处理完全相反（前者该报错，
     * 后者该退默认值）。
     */
    fun parse(text: String): Any? {
        val p = Parser(text)
        p.skipWs()
        val v = p.value()
        p.skipWs()
        if (!p.eof()) throw IllegalArgumentException("JSON 尾部有多余内容（位置 ${p.pos}）")
        return v
    }

    /** 解析成对象；不是对象就抛。 */
    fun parseObject(text: String): Map<String, Any?> {
        val v = parse(text)
        @Suppress("UNCHECKED_CAST")
        return v as? Map<String, Any?>
            ?: throw IllegalArgumentException("期望 JSON 对象，实际是 ${v?.javaClass?.simpleName}")
    }

    private class Parser(private val s: String) {
        var pos = 0

        fun eof() = pos >= s.length

        fun skipWs() {
            while (pos < s.length && s[pos].let { it == ' ' || it == '\t' || it == '\n' || it == '\r' }) pos++
        }

        fun value(): Any? {
            if (eof()) throw err("内容意外结束")
            return when (s[pos]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> num()
            }
        }

        private fun obj(): Map<String, Any?> {
            expect('{')
            val out = LinkedHashMap<String, Any?>()
            skipWs()
            if (peek() == '}') { pos++; return out }
            while (true) {
                skipWs()
                val k = str()
                skipWs()
                expect(':')
                skipWs()
                out[k] = value()
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    '}' -> { pos++; return out }
                    else -> throw err("对象里期望 , 或 }")
                }
            }
        }

        private fun arr(): List<Any?> {
            expect('[')
            val out = ArrayList<Any?>()
            skipWs()
            if (peek() == ']') { pos++; return out }
            while (true) {
                skipWs()
                out.add(value())
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    ']' -> { pos++; return out }
                    else -> throw err("数组里期望 , 或 ]")
                }
            }
        }

        private fun str(): String {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                if (eof()) throw err("字符串未闭合")
                val c = s[pos++]
                when {
                    c == '"' -> return sb.toString()
                    c != '\\' -> sb.append(c)
                    else -> {
                        if (eof()) throw err("转义符后内容意外结束")
                        when (val e = s[pos++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (pos + 4 > s.length) throw err("\\u 后面不足 4 位")
                                val hex = s.substring(pos, pos + 4)
                                pos += 4
                                sb.append(hex.toInt(16).toChar())
                            }
                            else -> throw err("不认识的转义 \\$e")
                        }
                    }
                }
            }
        }

        private fun num(): Any {
            val start = pos
            if (peek() == '-' || peek() == '+') pos++
            var isDouble = false
            while (!eof()) {
                val c = s[pos]
                if (c in '0'..'9') { pos++; continue }
                if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { isDouble = true; pos++; continue }
                break
            }
            val raw = s.substring(start, pos)
            if (raw.isEmpty()) throw err("期望一个值")
            return if (isDouble) {
                raw.toDoubleOrNull() ?: throw err("不是合法数字：$raw")
            } else {
                raw.toLongOrNull() ?: raw.toDoubleOrNull() ?: throw err("不是合法数字：$raw")
            }
        }

        private fun <T> literal(word: String, value: T): T {
            if (!s.startsWith(word, pos)) throw err("期望 $word")
            pos += word.length
            return value
        }

        private fun peek(): Char = if (eof()) '\u0000' else s[pos]

        private fun expect(c: Char) {
            if (eof() || s[pos] != c) throw err("期望 $c")
            pos++
        }

        private fun err(msg: String) = IllegalArgumentException("JSON 解析失败：$msg（位置 $pos）")
    }
}
