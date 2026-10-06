package com.cloudcine.tv

import android.util.Log
import java.io.IOException
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLongArray
import java.util.concurrent.locks.ReentrantLock

/**
 * **多连接并行分块**地把一条 HTTP 资源读成「顺序字节流」。
 *
 * ## 它解决什么
 *
 * 夸克对**单条连接**限速约 1 MiB/s（2026-10-06 实测：单连接稳态 1016~1022 KB/s、
 * 波动 <0.3%；8 连接 120s 稳态 8.03 MiB/s，`8.03/8 = 1.004 MiB/s` 每连接逐位吻合）。
 * 而 4K 原画要 3.67 MiB/s ⇒ 单连接只有 27.8%，必然「播一会卡一会」。
 *
 * 所以这里把一条连接变成 [connections] 条并发 Range 连接，**读出来仍是严格顺序的
 * 字节流** —— 上层的 Media3 完全不知道底下是几条连接。
 *
 * ## 关键设计（四条，都是踩过坑的）
 *
 * ### 1. 「块号 mod N」固定分派 ⇒ worker i 永远只用槽位 i
 *
 * 第 `k` 块固定由 worker `k % N` 取、固定写进槽位 `k % N`。于是：
 *   - 「顺序消费」只需要 N 个缓冲槽，总内存 = `N × chunkBytes`（有界）；
 *   - **背压是免费的**：worker 想取第 `k + N` 块时，槽位 `k % N` 还被第 `k` 块
 *     占着，而槽位只有在「消费者读干净」之后才释放 ⇒ 生产者天然不会跑到
 *     消费者前面超过一个窗口。
 *
 * ⛔ 不要改成「谁有空谁抢下一块」：块到槽的映射会漂移，消费者无法知道
 *    「我现在要的这一块在哪个槽」，只能全槽轮询 —— 复杂度换不到任何吞吐。
 *
 * ### 2. 边收边发（**不能等整块下完再给上层**）
 *
 * 槽位一有字节就允许 `read()` 取走。2026-10-05 的血案就是「整块下完才
 * `cache.put` + 结算」：`chunkSize` 从 2 MiB 调到 8 MiB 后首块要 15~45 秒，
 * 播放器 `readTimeout` 直接炸 `Source error`。
 * ⇒ 首字节延迟只取决于**一条连接**的首包，与 [chunkBytes] 无关。
 *
 * ### 3. 连接**复用**（keep-alive）
 *
 * 每个 worker 反复要块，但成功路径**不主动 `disconnect()`**、且每次都把响应体
 * 读干净 —— 这样 `HttpURLConnection` 会把连接还给连接池，下一块复用同一条。
 * 主工程踩过「每取一块就新建 + 立刻 close」的坑：17 GiB 的片子等于上万次
 * TCP+TLS 握手，聚合吞吐被切成锯齿。
 *
 * ### 4. 重试是**断点续传**，起点是「已写进槽的字节数」
 *
 * ⛔ 不是 `chunk.start`：重试期间消费者可能已经把前面那截读走了，从
 *    `chunk.start` 重下会把已经交付的数据又写回去，读出来的流会错位。
 *
 * ## 并发模型
 *
 * 一把锁 + 一个 condition，粒度粗但只有 N+1 个线程、竞争极低。
 * 所有等待都带超时（[WAIT_SLICE_MS]），所以 `close()`、上游失败、线程中断
 * 都能在半个周期内被发现，不会永久挂住。
 *
 * @param base        起点（含）
 * @param limit       终点（含）；`< 0` 表示长度未知
 * @param connections 并发连接数（>= 1）
 * @param chunkBytes  每块字节数（> 0）
 */
class ParallelRangeReader(
    private val url: String,
    private val headers: Map<String, String>,
    private val base: Long,
    private val limit: Long,
    private val connections: Int,
    private val chunkBytes: Int,
    private val connectTimeoutMs: Int,
    private val readTimeoutMs: Int,
    private val maxRetries: Int = DEFAULT_MAX_RETRIES,
) {

    init {
        require(connections >= 1) { "连接数至少 1" }
        require(chunkBytes > 0) { "块大小必须为正：$chunkBytes" }
    }

    // ------------------------------------------------------------------
    // 槽位
    // ------------------------------------------------------------------

    /**
     * 一个缓冲槽。worker `i` 专用（第 `k` 块，`k % N == i`）。
     *
     * 状态机：`FREE`（没人占）→ `FILLING`（生产者正在写）→ `SEALED`（生产者写完）
     * → 消费者读干净后**回到 `FREE`**（给下一轮的 `k + N` 块用）。
     */
    private class Slot(val bytes: ByteArray) {
        var state = FREE
        var chunk: RangePlan.Chunk? = null

        /** 生产者已写入的字节数。 */
        var produced = 0

        /** 消费者已取走的字节数。 */
        var consumed = 0

        companion object {
            const val FREE = 0
            const val FILLING = 1
            const val SEALED = 2
        }
    }

    private val lock = ReentrantLock()
    private val cond = lock.newCondition()
    private val slots = Array(connections) { Slot(ByteArray(chunkBytes)) }

    /** 从 `Content-Range` 回填的真实**总长**；`-1` = 还不知道。 */
    @Volatile
    private var discoveredTotal = -1L

    @Volatile
    private var closed = false

    /**
     * 已经交付过 EOF 了。
     *
     * ⛔ 必须**粘住**：`DataReader` 的契约是「到头之后继续调 `read()` 仍返回
     *    `RESULT_END_OF_INPUT`」。不粘住的话，第二次 `read()` 会去等一个
     *    **永远不会再被填的槽位** —— 表现成播放器在读完整段后**永久卡死**，
     *    而且 CPU 是 0（在 `awaitNanos` 上睡着），看起来像「解码器挂了」。
     */
    private var eofReached = false

    /** 读到哪个绝对偏移了（= 已交付给上层的字节数 + [base]）。 */
    private var readPos = base

    @Volatile
    private var failure: IOException? = null

    /** 每个 worker 当前挂着的连接 —— `close()` 靠它把阻塞的 socket 读打断。 */
    private val liveConn = arrayOfNulls<HttpURLConnection>(connections)

    private val workers = arrayOfNulls<Thread>(connections)

    /**
     * 第 `i` 条 worker 是否已经退休。
     *
     * ⛔ **EOF 判据的第二道保险**，不能省：槽位 `idx % N` 归 worker `idx % N` 专用，
     *    一旦那条 worker 退休，这个槽位**再也不会被填**。消费者若只看槽位，
     *    就会永远等下去。
     *
     *    实测撞到过（`每次只读 1000 字节` + 8 连接）：消费者把最后一块读干净后
     *    `readPos` 正好停在文件末尾，此时它算出的块号仍是一个**已被交还**的槽位，
     *    而 8 条 worker 全部已退休 ⇒ 线程栈里一个 `cc-range-` 都没有，
     *    消费者孤零零挂在 `awaitNanos` 上，CPU 0%。
     */
    private val workerDone = Array(connections) { false }

    // ---- 统计（只读日志用） ----
    private val bytesPerConn = AtomicLongArray(connections)
    private val requests = AtomicInteger()
    private val retries = AtomicInteger()
    private val startedNs = System.nanoTime()

    @Volatile
    private var firstByteMs = -1L

    private val effectiveConnections = RangePlan.connections(base, limit, chunkBytes, connections)

    /**
     * 实际开了几条连接。
     *
     * ⛔ 与构造参数 [connections] **不是一回事**：已知长度时会被 [RangePlan.connections]
     *    按块数收敛（读一小段头只值 1 条）。日志与探测都要用这个值，
     *    否则会出现「日志说 8 条、实际只有 1 条在跑」这种对不上的读数。
     */
    val connectionsUsed: Int get() = effectiveConnections

    // ------------------------------------------------------------------
    // 生命周期
    // ------------------------------------------------------------------

    fun start() {
        for (i in 0 until effectiveConnections) {
            val t = Thread({ runWorker(i) }, "cc-range-$i")
            t.isDaemon = true
            workers[i] = t
            t.start()
        }
        Log.i(
            TAG,
            "并行读取器启动：$effectiveConnections 条连接 · 每块 ${chunkBytes / 1024} KiB" +
                " · 窗口 ${effectiveConnections.toLong() * chunkBytes / 1048576} MiB" +
                " · 起点 $base · 终点 ${if (limit < 0) "未知" else limit.toString()}",
        )
    }

    fun close() {
        lock.lock()
        try {
            if (closed) return
            closed = true
            cond.signalAll()
        } finally {
            lock.unlock()
        }
        // 打断正在阻塞的 socket 读 —— 否则 worker 要等到下一次读超时才退出。
        for (i in 0 until connections) {
            runCatching { liveConn[i]?.disconnect() }
            liveConn[i] = null
        }
        for (i in 0 until connections) {
            val t = workers[i] ?: continue
            runCatching { t.join(JOIN_TIMEOUT_MS) }
        }
        Log.i(TAG, "并行读取器关闭：${statsLine()}")
    }

    /** 一行统计，供日志核对「连接真的都吃上活了」。 */
    fun statsLine(): String {
        val per = (0 until effectiveConnections).joinToString(",") {
            "%.2f".format(bytesPerConn.get(it) / 1048576.0)
        }
        val ms = (System.nanoTime() - startedNs) / 1_000_000
        return "$effectiveConnections 连接 · 各 [$per] MiB · 请求 ${requests.get()} 次" +
            " · 重试 ${retries.get()} · 耗时 ${ms / 1000}.${(ms % 1000) / 100}s"
    }

    /** 已交付给上层的绝对偏移（含），只读日志用。 */
    fun position(): Long = readPos

    // ------------------------------------------------------------------
    // 消费者：严格顺序
    // ------------------------------------------------------------------

    /**
     * 顺序读。
     *
     * ⛔ 这里是**阻塞**语义（和 `DefaultHttpDataSource` 一样），不返回 0：
     *    Media3 的 loader 拿到 0 会立刻再调一次，变成忙等。
     */
    fun read(dst: ByteArray, off: Int, len: Int): Int {
        require(len >= 0 && off >= 0 && off + len <= dst.size) { "越界的 read" }
        if (len == 0) return 0

        lock.lock()
        try {
            while (true) {
                failure?.let { throw it }
                if (closed) throw InterruptedIOException("读取器已关闭")
                if (eofReached) return -1

                val idx = ((readPos - base) / chunkBytes).toInt()
                val slot = slots[idx % effectiveConnections]
                val inChunk = ((readPos - base) % chunkBytes).toInt()

                // ⛔ 末尾判据用**绝对偏移**（`readPos` = 下一个要交付的字节），
                //    不要用「块号是否越界」：读完整块后 `readPos` 恰好落在文件末尾，
                //    此时算出的块号仍是**合法的最后一块**，而那一块早已被读干净、
                //    槽位也交还了 ⇒ 按块号判会漏掉 EOF，然后永久挂住（实测）。
                if (pastEnd()) {
                    eofReached = true
                    return -1
                }

                if (slot.chunk?.index != idx) {
                    // ⛔ 负责这一块的 worker 已经退休 ⇒ 再也不会有字节来了 ⇒ 到头了。
                    //    必须在这里判掉，否则就是**永久等待**（见 [workerDone]）。
                    if (workerDone[idx % effectiveConnections]) {
                        eofReached = true
                        return -1
                    }
                    // 生产者还没轮到我这一块（窗口还没推进到这里）—— 等。
                    cond.awaitNanos(WAIT_SLICE_MS)
                    continue
                }

                val available = slot.produced - inChunk
                if (available > 0) {
                    val n = minOf(len, available)
                    System.arraycopy(slot.bytes, inChunk, dst, off, n)
                    slot.consumed = inChunk + n
                    readPos += n
                    if (firstByteMs < 0) {
                        firstByteMs = (System.nanoTime() - startedNs) / 1_000_000
                        Log.i(TAG, "并行读取器首字节：${firstByteMs}ms（$effectiveConnections 条连接并行中）")
                    }
                    releaseIfDrained(slot, idx)
                    return n
                }

                // available == 0：要么还没收到字节，要么已经到头了。
                if (slot.state == Slot.SEALED) {
                    // 这一块就这么多 —— 到文件末尾了。
                    eofReached = true
                    return -1
                }
                cond.awaitNanos(WAIT_SLICE_MS)
            }
        } finally {
            lock.unlock()
        }
    }

    /**
     * 消费者把这一块读干净了就交还槽位，让 worker 去取 `idx + N` 块。
     *
     * ⛔ 只有 `SEALED` 才谈得上「读干净」：生产者还在写的时候，
     *    `produced` 只是**当前**写到的位置，不是这一块的终点。
     */
    private fun releaseIfDrained(slot: Slot, idx: Int) {
        if (slot.state != Slot.SEALED) return
        releaseLocked(slot, idx)
    }

    /**
     * 生产者写完一块：置 `SEALED`，并在**消费者已经读干净**时立刻交还槽位。
     *
     * ⛔⛔ 这一步**不能只放在消费者的读路径上**（[releaseIfDrained]）。消费者完全可能
     *    在生产者还在 `FILLING` 时就把这一块读干净了 —— 那时 [releaseIfDrained]
     *    因「还没 SEALED」而跳过，而消费者**再也不会回头看这个槽位**（它已经
     *    前进到下一块、那对应的是**另一个**槽位）。于是这个槽位永远停在 `SEALED`，
     *    对应的 worker 永远等不到 `FREE` ⇒ **死锁**。
     *
     *    实测复现：`每次只读 1000 字节` + 8 条连接（消费者比网络快），
     *    8 条 worker 全停在 `while (slot.state != FREE)`，消费者停在
     *    `cond.awaitNanos` —— 两边都在等对方，CPU 0%，直到超时。
     *
     * ⛔ `produced == 0`（上游 416 / 立刻 EOF）时**故意不交还**：消费者要靠
     *    「槽位 SEALED 且 0 字节」判断**流到头了**；提前交还（`chunk = null`）
     *    会让它转去等一个再也不会被填的槽 ⇒ 又是死锁。
     *    这种槽位对应的 worker 已经退休（416 ⇒ `reachedEof`），没人会等它。
     */
    private fun sealSlot(slot: Slot, idx: Int) {
        slot.state = Slot.SEALED
        if (slot.produced > 0) releaseLocked(slot, idx)
        cond.signalAll()
    }

    /**
     * 真正交还槽位。调用方**必须已持有锁**。
     *
     * ⛔ 必须**同时**满足「生产者已 SEALED」（由调用方保证）与
     *    「`consumed` 追平 `produced`」：只判 consumed 会在生产者还在写时误释放，
     *    下一个块直接覆盖掉消费者还没读的部分 —— 表现成偶发花屏，极难复现。
     */
    private fun releaseLocked(slot: Slot, idx: Int) {
        if (slot.consumed < slot.produced) return
        if (slot.chunk?.index != idx) return
        slot.state = Slot.FREE
        slot.chunk = null
        slot.produced = 0
        slot.consumed = 0
        cond.signalAll()
    }

    // ------------------------------------------------------------------
    // 生产者
    // ------------------------------------------------------------------

    /** 已知长度用 [limit]，未知长度靠 `Content-Range` 回填的总长换算成「终点（含）」。 */
    private fun effectiveLimit(): Long {
        if (limit >= 0) return limit
        val total = discoveredTotal
        return if (total > 0) total - 1 else -1
    }

    /**
     * 下一个要交付的字节是否已经**越过**末尾。
     *
     * 判据是 `readPos`（绝对偏移）而不是「块号是否越界」：
     *   * 终点已知（`limit >= 0`，Media3 给了长度）⇒ `readPos > limit`；
     *   * 终点从 `Content-Range` 学到 ⇒ `readPos >= 总长`；
     *   * 两者都不知道 ⇒ 一律 `false`，末尾交给「416 ⇒ 槽位 SEALED 且 0 字节」
     *     或 [workerDone] 那两条判据。
     *
     * ⛔ 别退回「块号越界」的写法：读完整块后 `readPos` **恰好**落在文件末尾，
     *    算出的块号是合法的最后一块 —— 那一块已经被读干净并交还槽位，
     *    于是判据为假、消费者继续等一个不会再被填的槽 ⇒ 永久挂住（实测撞到）。
     */
    private fun pastEnd(): Boolean {
        if (limit >= 0) return readPos > limit
        val total = discoveredTotal
        return total > 0 && readPos >= total
    }

    /**
     * worker 线程体。**外面包一层**只为记录「这条 worker 退休了」
     * —— 内部有好几处 `return`，逐个去写 `workerDone` 一定会漏掉一处。
     */
    private fun runWorker(worker: Int) {
        try {
            runWorkerLoop(worker)
        } finally {
            lock.lock()
            try {
                workerDone[worker] = true
                cond.signalAll()
            } finally {
                lock.unlock()
            }
        }
    }

    private fun runWorkerLoop(worker: Int) {
        var idx = worker
        while (true) {
            val slot = slots[idx % effectiveConnections]
            val chunk: RangePlan.Chunk
            lock.lock()
            try {
                while (slot.state != Slot.FREE) {
                    if (closed) return
                    cond.awaitNanos(WAIT_SLICE_MS)
                }
                if (closed) return
                chunk = RangePlan.chunk(idx, base, effectiveLimit(), chunkBytes) ?: return
                slot.state = Slot.FILLING
                slot.chunk = chunk
                slot.produced = 0
                slot.consumed = 0
                cond.signalAll()
            } finally {
                lock.unlock()
            }

            var reachedEof = false
            try {
                reachedEof = fetch(worker, slot, chunk)
            } catch (e: Exception) {
                val io = if (e is IOException) e else IOException("连接 $worker 异常：$e", e)
                lock.lock()
                try {
                    failure = failure ?: io
                    slot.state = Slot.SEALED
                    cond.signalAll()
                } finally {
                    lock.unlock()
                }
                return
            }

            lock.lock()
            try {
                // ⛔ 必须走 [sealSlot] 而不是直接置 SEALED：消费者可能已经
                //    在 FILLING 期间就把这一块读干净了（见 [sealSlot] 的注释）。
                sealSlot(slot, chunk.index)
            } finally {
                lock.unlock()
            }

            if (reachedEof) return
            idx += effectiveConnections
        }
    }

    /**
     * 把 [chunk] 下进 [slot]。
     *
     * @return `true` = 这一块**没下满**（短读 / 416）⇒ 已到文件末尾，worker 可以退休
     */
    private fun fetch(worker: Int, slot: Slot, chunk: RangePlan.Chunk): Boolean {
        var attempt = 0
        while (true) {
            if (closed) return false
            val from = chunk.start + slot.produced
            if (from > chunk.endInclusive) return false // 其实已经下满了

            val conn = openFollowingRedirects(from, chunk.endInclusive)
            liveConn[worker] = conn
            requests.incrementAndGet()
            try {
                val code = conn.responseCode
                val contentRange = conn.getHeaderField("Content-Range")

                if (code == HTTP_RANGE_NOT_SATISFIABLE) {
                    // 要过了文件末尾 —— 这一块就是空的。
                    RangePlan.totalFromContentRange(contentRange)
                        .takeIf { it > 0 }?.let { discoveredTotal = it }
                    return true
                }
                if (code != HTTP_PARTIAL_CONTENT && code != HTTP_OK) {
                    throw IOException("上游 HTTP $code（要 $from-${chunk.endInclusive}）")
                }

                var needSkip = 0L
                if (code == HTTP_PARTIAL_CONTENT) {
                    RangePlan.totalFromContentRange(contentRange)
                        .takeIf { it > 0 }?.let { discoveredTotal = it }
                    val actualStart = RangePlan.startFromContentRange(contentRange)
                    if (actualStart >= 0 && actualStart != from) {
                        // 服务端给的不是我们要的段 —— 宁可报错也别把错位的数据交给解码器。
                        throw IOException("上游起点 $actualStart != 请求的 $from")
                    }
                } else {
                    // 服务端忽略了 Range，回了整个文件：只能把前面跳掉。慢，但不致命。
                    needSkip = from
                    Log.w(TAG, "上游忽略 Range（HTTP 200）⇒ 跳过前 $from 字节")
                }

                var skipped = 0L
                val buf = ByteArray(READ_BUFFER)
                conn.inputStream.use { input ->
                    while (true) {
                        if (closed) return false
                        val n = input.read(buf)
                        if (n < 0) break
                        var srcOff = 0
                        var cnt = n
                        if (skipped < needSkip) {
                            val s = minOf(needSkip - skipped, cnt.toLong()).toInt()
                            skipped += s
                            srcOff += s
                            cnt -= s
                            if (cnt <= 0) continue
                        }
                        writeInto(slot, chunk, buf, srcOff, cnt)
                    }
                }
                // ⛔ 成功路径**不** disconnect()：留给连接池复用（见类注释第 3 条）。
                if (slot.produced >= chunk.length.toInt()) return false // 下满了，去取下一块

                // 短读。**两种可能必须分清**：
                //   * 真到文件末尾了 —— 已知总长时「已下到的绝对偏移 ≥ 总长」，
                //     或总长压根不知道；
                //   * 服务端**提前关流**了（不是 EOF）—— 此时若当 EOF 处理，
                //     读出来的流会**从这里截断**，表现成「播到某处突然结束」，
                //     而日志上一切正常，最难查。宁可抛出去走重试（断点续传）。
                val reachedEnd = discoveredTotal <= 0 ||
                    chunk.start + slot.produced >= discoveredTotal
                if (reachedEnd) return true
                throw IOException(
                    "上游短读：要 ${chunk.length} 字节只给了 ${slot.produced}" +
                        "（已下到 ${chunk.start + slot.produced}，总长 $discoveredTotal）",
                )
            } catch (e: IOException) {
                runCatching { conn.disconnect() }
                if (closed) return false
                attempt++
                if (attempt > maxRetries) throw e
                retries.incrementAndGet()
                Log.w(
                    TAG,
                    "连接 $worker 取 $from-${chunk.endInclusive} 失败（第 $attempt 次），" +
                        "从 ${chunk.start + slot.produced} 续传：${e.message}",
                )
                runCatching { Thread.sleep((200L * attempt).coerceAtMost(1_500L)) }
            } finally {
                liveConn[worker] = null
            }
        }
    }

    /**
     * 写进槽位。
     *
     * ⛔ **不需要在这里做背压**：块长是固定的（最多 [chunkBytes]），槽位正好这么大，
     *    生产者写完这一块就去等「下一个槽位空闲」，背压由 [runWorker] 里那道
     *    `while (slot.state != FREE)` 承担。在这里再加一层等待只会绕。
     */
    private fun writeInto(slot: Slot, chunk: RangePlan.Chunk, src: ByteArray, srcOff: Int, cnt: Int) {
        lock.lock()
        try {
            val room = chunk.length.toInt() - slot.produced
            if (room <= 0) return
            val n = minOf(room, cnt)
            System.arraycopy(src, srcOff, slot.bytes, slot.produced, n)
            slot.produced += n
            bytesPerConn.addAndGet(chunk.index % effectiveConnections, n.toLong())
            cond.signalAll()
        } finally {
            lock.unlock()
        }
    }

    private fun openRange(target: String, from: Long, to: Long): HttpURLConnection =
        (URL(target).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
            useCaches = false
            // ⛔ 重定向**自己跟**（见 [openFollowingRedirects]）：交给
            //    `HttpURLConnection` 只能跟同协议的跳转，`http→https` 的 302
            //    会原样返回，且跨协议时它不会重放 `Range` 头。`DefaultHttpDataSource`
            //    的 `setAllowCrossProtocolRedirects(true)` 干的就是这件事 ——
            //    换成自己的 DataSource 就得自己补上，否则「某些片源一播就 302
            //    报错」而另一些完全正常。
            instanceFollowRedirects = false
            setRequestProperty("Range", "bytes=$from-$to")
            for ((k, v) in headers) if (v.isNotEmpty()) setRequestProperty(k, v)
        }

    /**
     * 建连接并跟完重定向，返回**最终**那条（可以读 body 的）。
     *
     * ⛔ 每一跳都**重新带上 `Range` 与请求头**：夸克直链的签名在 query 里，
     *    重定向后路径变了，漏掉 `Range` 会退化成「回整个文件」，
     *    症状是「一开播就狂下二十分钟、首帧迟迟不来」。
     */
    private fun openFollowingRedirects(from: Long, to: Long): HttpURLConnection {
        var target = url
        var hops = 0
        while (true) {
            val conn = openRange(target, from, to)
            if (hops >= MAX_REDIRECTS) return conn
            val code = runCatching { conn.responseCode }.getOrElse { return conn }
            if (code !in 300..399) return conn
            val loc = conn.getHeaderField("Location")
            val next = if (loc.isNullOrBlank()) {
                null
            } else {
                // 相对 Location（`/path?x`）也要能解析 ⇒ 以当前 URL 为基准。
                runCatching { URL(URL(target), loc).toString() }.getOrNull()
            }
            if (next == null || next == target) return conn
            runCatching { conn.disconnect() }
            Log.i(TAG, "跟随重定向（$code）：$target → $next")
            target = next
            hops++
        }
    }

    companion object {
        private const val TAG = "CloudCine"

        /** 等待切片。够小，所以 `close()` / 失败最多半个周期就被发现。 */
        private const val WAIT_SLICE_MS = 200L * 1_000_000

        /** 关闭时等 worker 收摊的上限。 */
        private const val JOIN_TIMEOUT_MS = 2_000L

        /** 单次 socket 读的缓冲。 */
        private const val READ_BUFFER = 128 * 1024

        /** 最多跟几跳重定向。5 是浏览器与 `DefaultHttpDataSource` 的通行走法。 */
        private const val MAX_REDIRECTS = 5

        const val DEFAULT_MAX_RETRIES = 3

        private const val HTTP_OK = 200
        private const val HTTP_PARTIAL_CONTENT = 206
        private const val HTTP_RANGE_NOT_SATISFIABLE = 416
    }
}
