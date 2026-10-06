package com.cloudcine.tv

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.Timeout
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * [ParallelRangeReader] 的行为单测。
 *
 * ## 为什么必须真起一个 HTTP 服务
 *
 * 这个类要验证的四件事**全都只在真实 socket 上才成立**：
 *   * **顺序**：N 条连接各下各的块，拼出来的流必须与源逐字节相同；
 *   * **背压**：并发在途请求数**不得超过连接数**（内存有界 = `N × chunkBytes`）；
 *   * **EOF**：读完之后必须返回 `-1`，而且**再读一次仍要返回 `-1`**
 *     （不粘住的话第二次会去等一个永远不会被填的槽 ⇒ 播放器永久卡死）；
 *   * **重试续传**：上游短读后必须从**已写进槽的字节数**续，而不是从块首重下。
 *
 * ## ⛔ 为什么不用 `com.sun.net.httpserver`
 *
 * Android 的单测虽然跑在 JVM 上，但**编译期用的是 `android.jar` 那套 bootclasspath**，
 * `com.sun.net.httpserver` 属于 JDK 的 `jdk.httpserver` 模块、**不在其中** ——
 * 直接 `import` 会 `Unresolved reference 'sun'`（实测）。
 * 所以这里用最原始的 [ServerSocket] 自己写 60 行 HTTP/1.1：
 * **零测试依赖**，而且「短读」「416」「无视 Range」「不响应」这几种边界响应
 * 只有自己写才控制得精确。
 */
class ParallelRangeReaderTest {

    /**
     * ⛔ **死锁兜底**：这个类测的正是并发，一旦有活锁/死锁，没有这道闸
     *    Gradle 会**一直挂着**（实测挂过 5 分钟以上，只能 `jstack` + `pkill` 收场）。
     *    30 秒足够任何一条用例跑完（最长的那条约 1 秒）。
     */
    @get:Rule
    val timeout: Timeout = Timeout.seconds(30)

    /** 确定性的假文件：第 `i` 个字节 = `(i * 31 + 7) and 0xFF`。 */
    private fun fakeFile(size: Int): ByteArray =
        ByteArray(size) { ((it * 31 + 7) and 0xFF).toByte() }

    /**
     * 一个支持 `Range` 的极简 HTTP/1.1 服务（每条连接一个线程，响应后即关）。
     *
     * @param honorRange `false` = 无视 `Range` 一律回 **200 整文件**
     *                   （测「跳过前缀」那条路径）。
     * @param truncateAt `>= 0` 时：**第一次**收到「起点正好等于它」的请求时，
     *                   只回 [truncateBytes] 字节（模拟服务端提前断流）。
     * @param responseDelayMs 每个响应故意慢这么多毫秒（让并发真的重叠，
     *                        否则背压断言会因「服务端太快」退化成串行）。
     * @param stall `true` = 收到请求后一直不写响应（测 `close()` 能否唤醒
     *              阻塞在 socket 读上的消费者）。
     */
    private class MiniHttpServer(
        private val body: ByteArray,
        private val honorRange: Boolean = true,
        private val truncateAt: Long = -1,
        private val truncateBytes: Int = 0,
        private val responseDelayMs: Long = 0,
        private val stall: Boolean = false,
    ) {
        val requests = AtomicInteger()

        /** 同时在处理的请求数的峰值 —— 背压断言的依据。 */
        val maxConcurrent = AtomicInteger()

        private val live = AtomicInteger()
        private val truncated = AtomicInteger()
        private val stallLatch = CountDownLatch(1)

        @Volatile
        private var running = true
        private lateinit var listener: ServerSocket
        private var acceptor: Thread? = null

        fun start(): Int {
            listener = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
            acceptor = Thread({ acceptLoop() }, "test-http-accept").apply {
                isDaemon = true
                start()
            }
            return listener.localPort
        }

        fun stop() {
            running = false
            stallLatch.countDown()
            runCatching { listener.close() }
            runCatching { acceptor?.join(1_000) }
        }

        private fun acceptLoop() {
            while (running) {
                val s = try {
                    listener.accept()
                } catch (_: IOException) {
                    return
                }
                Thread({ serve(s) }, "test-http-conn").apply { isDaemon = true }.start()
            }
        }

        private fun serve(s: Socket) {
            try {
                val input = BufferedInputStream(s.getInputStream())
                if (readLine(input) == null) return // 连接开了就断（disconnect）—— 不算一次请求
                requests.incrementAndGet()
                var rangeHeader: String? = null
                while (true) {
                    val line = readLine(input) ?: break
                    if (line.isEmpty()) break
                    val c = line.indexOf(':')
                    if (c > 0 && line.substring(0, c).trim().equals("Range", ignoreCase = true)) {
                        rangeHeader = line.substring(c + 1).trim()
                    }
                }
                val now = live.incrementAndGet()
                maxConcurrent.updateAndGet { maxOf(it, now) }
                try {
                    respond(s, rangeHeader)
                } finally {
                    live.decrementAndGet()
                }
            } catch (_: Exception) {
                // 客户端主动断开（`close()` 里的 disconnect）是**正常路径**，不是失败。
            } finally {
                runCatching { s.close() }
            }
        }

        private fun respond(s: Socket, rangeHeader: String?) {
            if (stall) {
                stallLatch.await(20, TimeUnit.SECONDS)
                return
            }
            if (responseDelayMs > 0) Thread.sleep(responseDelayMs)

            var from = 0L
            var to = body.size - 1L
            val ranged = honorRange && rangeHeader != null
            if (ranged) {
                val m = RANGE_RE.find(rangeHeader!!)
                if (m != null) {
                    from = m.groupValues[1].toLong()
                    val endStr = m.groupValues[2]
                    to = if (endStr.isEmpty()) body.size - 1L else minOf(endStr.toLong(), body.size - 1L)
                }
            }

            val out = BufferedOutputStream(s.getOutputStream())
            if (from > body.size - 1) {
                writeHead(out, 416, 0, "bytes */${body.size}")
                out.flush()
                return
            }

            var count = (to - from + 1).toInt()
            if (truncateAt >= 0 && from == truncateAt && truncated.compareAndSet(0, 1)) {
                // ⛔ 回一个**自洽但比请求的块短**的 206：`Content-Length` 与
                //    `Content-Range` 都说只有这么多。于是读出来的流是「合法但短」的
                //    —— 这正是最难查的那种上游行为（不是断连、不是报错）。
                count = minOf(count, truncateBytes)
            }

            val status = if (ranged) 206 else 200
            writeHead(
                out,
                status,
                count,
                if (status == 206) "bytes $from-${from + count - 1}/${body.size}" else null,
            )
            out.write(body, from.toInt(), count)
            out.flush()
        }

        private fun writeHead(out: OutputStream, status: Int, length: Int, contentRange: String?) {
            val sb = StringBuilder()
            sb.append("HTTP/1.1 ").append(status).append(' ').append(statusText(status)).append("\r\n")
            sb.append("Content-Type: application/octet-stream\r\n")
            sb.append("Content-Length: ").append(length).append("\r\n")
            // 每条请求一个连接，响应后关 —— 单测里不需要 keep-alive。
            sb.append("Connection: close\r\n")
            if (contentRange != null) sb.append("Content-Range: ").append(contentRange).append("\r\n")
            sb.append("\r\n")
            out.write(sb.toString().toByteArray(Charsets.ISO_8859_1))
        }

        private fun statusText(status: Int): String = when (status) {
            200 -> "OK"
            206 -> "Partial Content"
            416 -> "Range Not Satisfiable"
            else -> "Unknown"
        }

        /** 读到 `\n` 为止；流已结束且一个字节都没读到时返回 `null`。 */
        private fun readLine(input: InputStream): String? {
            val sb = StringBuilder()
            while (true) {
                val b = input.read()
                if (b < 0) return if (sb.isEmpty()) null else sb.toString()
                if (b == '\n'.code) return sb.toString().trimEnd('\r')
                sb.append(b.toChar())
            }
        }
    }

    private var server: MiniHttpServer? = null

    @After
    fun tearDown() {
        server?.stop()
        server = null
    }

    private fun startServer(
        body: ByteArray,
        honorRange: Boolean = true,
        truncateAt: Long = -1,
        truncateBytes: Int = 0,
        responseDelayMs: Long = 0,
        stall: Boolean = false,
    ): Pair<MiniHttpServer, String> {
        val s = MiniHttpServer(body, honorRange, truncateAt, truncateBytes, responseDelayMs, stall)
        val port = s.start()
        server = s
        return s to "http://127.0.0.1:$port/f"
    }

    private fun reader(
        url: String,
        base: Long,
        limit: Long,
        connections: Int,
        chunkBytes: Int,
    ) = ParallelRangeReader(
        url = url,
        headers = emptyMap(),
        base = base,
        limit = limit,
        connections = connections,
        chunkBytes = chunkBytes,
        connectTimeoutMs = 3_000,
        readTimeoutMs = 3_000,
    )

    private fun readAll(r: ParallelRangeReader, bufSize: Int = 8192): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(bufSize)
        while (true) {
            val n = r.read(buf, 0, buf.size)
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    // ── 1. 顺序：多连接拼出来的流必须与源逐字节相同 ────────────────

    @Test
    fun `4 条连接读完整流 与源逐字节相同 末块不满也正确`() {
        // ⛔ 故意让文件大小**不是** chunkBytes 的整数倍（5 块 + 123 字节）：
        //    末块不满是最容易算错的地方，而它正好是文件结尾。
        val size = 5 * 65536 + 123
        val body = fakeFile(size)
        val (_, url) = startServer(body)

        val r = reader(url, base = 0, limit = -1, connections = 4, chunkBytes = 65536)
        r.start()
        try {
            val got = readAll(r)
            assertEquals(size, got.size)
            assertArrayEquals(body, got)
        } finally {
            r.close()
        }
    }

    // ── 2. EOF 必须粘住（否则第二次 read 永久挂住）────────────────

    @Test
    fun `长度已知时 读完返回 -1 且可重复读`() {
        val size = 3 * 8192
        val body = fakeFile(size)
        val (_, url) = startServer(body)

        val r = reader(url, base = 0, limit = size - 1L, connections = 4, chunkBytes = 8192)
        r.start()
        try {
            assertArrayEquals(body, readAll(r))
            // ⛔ 关键断言：`DataReader` 契约要求「到头之后继续读仍返回 -1」。
            //    不粘住的话这里会**永久阻塞**（等一个不会再被填的槽位）——
            //    表现成播放器读完整段后卡死、CPU 却是 0，最难查。
            val buf = ByteArray(16)
            assertEquals(-1, r.read(buf, 0, buf.size))
            assertEquals(-1, r.read(buf, 0, buf.size))
        } finally {
            r.close()
        }
    }

    @Test
    fun `起点已在文件末尾之外时立即返回 -1`() {
        val body = fakeFile(1024)
        val (_, url) = startServer(body)

        // base 正好等于文件长度 ⇒ 第 0 块就落在文件外 ⇒ 上游 416。
        val r = reader(url, base = 1024, limit = -1, connections = 1, chunkBytes = 512)
        r.start()
        try {
            val buf = ByteArray(16)
            assertEquals(-1, r.read(buf, 0, buf.size))
        } finally {
            r.close()
        }
    }

    // ── 3. 小块读跨块拼接 ─────────────────────────────────────────

    @Test
    fun `每次只读 1000 字节时跨块拼接仍然正确`() {
        val size = 64 * 4096 + 77
        val body = fakeFile(size)
        val (_, url) = startServer(body)

        val r = reader(url, base = 0, limit = -1, connections = 8, chunkBytes = 4096)
        r.start()
        try {
            assertArrayEquals(body, readAll(r, bufSize = 1000))
        } finally {
            r.close()
        }
    }

    // ── 4. seek：只读中间一段 ─────────────────────────────────────

    @Test
    fun `从中间起读一段 内容与源对应区间一致`() {
        val size = 200_000
        val body = fakeFile(size)
        val (_, url) = startServer(body)

        val base = 100_000L
        val limit = 149_999L
        val r = reader(url, base = base, limit = limit, connections = 4, chunkBytes = 8192)
        r.start()
        try {
            val got = readAll(r)
            assertEquals(50_000, got.size)
            assertArrayEquals(body.copyOfRange(base.toInt(), limit.toInt() + 1), got)
        } finally {
            r.close()
        }
    }

    // ── 5. 背压：并发在途请求数 ≤ 连接数 ──────────────────────────

    @Test
    fun `并发在途请求数不超过连接数`() {
        val size = 16 * 65536
        val body = fakeFile(size)
        // 每个响应慢 40ms，让 4 条连接真的重叠 —— 否则服务端太快、请求退化成串行，
        // 这条断言就变成「什么都没验证」。
        val (s, url) = startServer(body, responseDelayMs = 40)

        val r = reader(url, base = 0, limit = -1, connections = 4, chunkBytes = 65536)
        r.start()
        try {
            assertArrayEquals(body, readAll(r))
            assertTrue(
                "在途峰值 ${s.maxConcurrent.get()} 超过了连接数 4 —— 说明有 worker 越过了自己的槽位",
                s.maxConcurrent.get() <= 4,
            )
            assertTrue(
                "在途峰值只有 ${s.maxConcurrent.get()} —— 4 条连接没有真的并行起来",
                s.maxConcurrent.get() >= 2,
            )
        } finally {
            r.close()
        }
    }

    // ── 6. 重试续传：上游短读后数据仍然完整 ───────────────────────

    @Test
    fun `上游短读会重试 且最终数据完整`() {
        val size = 4 * 65536
        val body = fakeFile(size)
        // 第 1 块（起点 65536）第一次只回 10000 字节。
        val (s, url) = startServer(body, truncateAt = 65536, truncateBytes = 10_000)

        val r = reader(url, base = 0, limit = -1, connections = 1, chunkBytes = 65536)
        r.start()
        try {
            assertArrayEquals(body, readAll(r))
            // 4 块 + 1 次重试 = 5 次请求。⛔ 少于 5 说明短读被当成了 EOF
            //    —— 那样流会**从断点处截断**，而日志上一切正常。
            assertTrue("请求次数 ${s.requests.get()} < 5，短读可能被误当成 EOF", s.requests.get() >= 5)
        } finally {
            r.close()
        }
    }

    // ── 7. close() 能唤醒阻塞中的 read ────────────────────────────

    @Test
    fun `close 能把阻塞在 read 上的消费者唤醒`() {
        val body = fakeFile(65536)
        val (_, url) = startServer(body, stall = true)

        val r = reader(url, base = 0, limit = -1, connections = 2, chunkBytes = 8192)
        r.start()

        val done = CountDownLatch(1)
        val caught = AtomicReference<Throwable?>()
        Thread {
            try {
                r.read(ByteArray(16), 0, 16)
            } catch (e: Throwable) {
                caught.set(e)
            } finally {
                done.countDown()
            }
        }.apply { isDaemon = true }.start()

        Thread.sleep(300)
        r.close()

        assertTrue("close() 之后 3 秒内 read 仍未返回", done.await(3, TimeUnit.SECONDS))
        // ⛔ 必须是**中断异常**而不是 `-1`：`-1` 会被上层当成「正常读到文件末尾」，
        //    于是一段根本没下完的流被当成完整的 —— 静默的错误。
        assertTrue(
            "期望 InterruptedIOException，实际是 ${caught.get()}",
            caught.get() is InterruptedIOException,
        )
    }

    // ── 8. 上游无视 Range（回 200）时跳过前缀 ─────────────────────

    @Test
    fun `上游回 200 整文件时 跳过前缀后内容仍然正确`() {
        val size = 100_000
        val body = fakeFile(size)
        val (_, url) = startServer(body, honorRange = false)

        val base = 1000L
        val limit = 1999L
        val r = reader(url, base = base, limit = limit, connections = 4, chunkBytes = 1024)
        r.start()
        try {
            val got = readAll(r)
            assertEquals(1000, got.size)
            assertArrayEquals(body.copyOfRange(base.toInt(), limit.toInt() + 1), got)
        } finally {
            r.close()
        }
    }

    // ── 9. 已知长度按块数收敛连接数 ───────────────────────────────

    @Test
    fun `已知长度时实际连接数按块数收敛`() {
        val body = fakeFile(4096)
        val (_, url) = startServer(body)

        // 4096 字节 / 1024 一块 = 4 块 ⇒ 即使给 8，也只该开 4 条。
        val r = reader(url, base = 0, limit = 4095, connections = 8, chunkBytes = 1024)
        assertEquals(4, r.connectionsUsed)
        r.start()
        try {
            assertArrayEquals(body, readAll(r))
        } finally {
            r.close()
        }
    }

    companion object {
        private val RANGE_RE = Regex("bytes=(\\d+)-(\\d*)")
    }
}
