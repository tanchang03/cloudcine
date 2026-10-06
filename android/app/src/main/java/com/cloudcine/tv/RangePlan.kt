package com.cloudcine.tv

/**
 * 多连接分块下载的**纯规划逻辑**。
 *
 * ## 为什么单独拆出来
 *
 * 「第 idx 块是哪几个字节」这件事的边界条件比看上去多，而且**错了不会崩、
 * 只会静默地少下或多下几个字节** —— 表现成「播到某处花屏/跳一下」，在电视上
 * 排查一次要十分钟。所以它必须是无 IO、无 Android 依赖的纯函数，能被单测直接
 * 按边界值打。真正的网络与并发在 [ParallelRangeReader] 里。
 *
 * ## 坐标口径（⛔ 全文只用这一套）
 *
 * 所有偏移都是**绝对文件偏移**，闭区间：
 *   - [Chunk.start] / [Chunk.endInclusive] 都是「文件里的第几个字节」，
 *     两端**都算在内**（和 HTTP `Range: bytes=a-b` 的语义一致，b 是含的）。
 *   - `base` 是本次要读的起点，`limit` 是本次要读的**终点（含）**。
 *   - `limit < 0` = **长度未知**（Media3 的 `C.LENGTH_UNSET`）。
 *
 * ⛔ 别把「含/不含」在两处用不同约定：`endInclusive` 一旦被当成开区间，
 *    每次都会少下 1 个字节，而末块的那 1 个字节正好是文件结尾 —— 表现为
 *    「播到最后几秒卡住」。
 */
object RangePlan {

    /** 一块要取的字节区间，闭区间 `[start, endInclusive]`。 */
    data class Chunk(val index: Int, val start: Long, val endInclusive: Long) {
        /** 这一块要下的字节数。 */
        val length: Long get() = endInclusive - start + 1
    }

    /**
     * 第 [index] 块。
     *
     * @param base       起点（含）
     * @param limit      终点（含）；`< 0` 表示长度未知
     * @param chunkBytes 块大小（> 0）
     * @return 越界返回 `null`（**这是「到文件末尾了」的唯一表达**，
     *         不要用「长度 0 的块」代替 —— 那会让调用方以为还要再下点什么）
     */
    fun chunk(index: Int, base: Long, limit: Long, chunkBytes: Int): Chunk? {
        require(index >= 0) { "块号不能为负：$index" }
        require(chunkBytes > 0) { "块大小必须为正：$chunkBytes" }
        val start = base + index.toLong() * chunkBytes
        if (limit >= 0) {
            // ⛔ 判据是 `start > limit`（不是 `>=`）：`start == limit` 时
            //    还剩**最后 1 个字节**要下，漏掉它文件就短 1 字节。
            if (start > limit) return null
            return Chunk(index, start, minOf(start + chunkBytes - 1, limit))
        }
        // 长度未知：先按整块要，短读由调用方当 EOF 处理。
        return Chunk(index, start, start + chunkBytes - 1)
    }

    /**
     * 已知长度时一共几块（向上取整）；长度未知返回 `-1`。
     *
     * `base > limit`（空区间）返回 `0`。
     */
    fun chunkCount(base: Long, limit: Long, chunkBytes: Int): Long {
        require(chunkBytes > 0) { "块大小必须为正：$chunkBytes" }
        if (limit < 0) return -1
        val remaining = limit - base + 1
        if (remaining <= 0) return 0
        return (remaining + chunkBytes - 1) / chunkBytes
    }

    /**
     * 实际该开几条连接。
     *
     * ⛔ 别无条件给满 [max]：Media3 开流时会先读一小段头（常常只有几百 KiB），
     *    为它开 8 条连接是纯浪费 —— 7 条立刻收到 416 或短读、白建 7 次连接。
     *    所以**已知长度就按块数收敛**。
     *
     * ⛔ 长度未知时给满 [max]：那多半就是主播放段，它才是要加速的对象。
     *    （代价是「先读头」那一次也会开满，这是可接受的：那一段很短，
     *    浪费的是连接数不是带宽。）
     */
    fun connections(base: Long, limit: Long, chunkBytes: Int, max: Int): Int {
        require(max >= 1) { "连接数至少 1" }
        require(chunkBytes > 0) { "块大小必须为正：$chunkBytes" }
        if (limit < 0) return max
        val chunks = chunkCount(base, limit, chunkBytes)
        if (chunks <= 0) return 1
        return if (chunks < max) chunks.toInt() else max
    }

    /**
     * 从 `Content-Range: bytes 0-1023/1048576` 里取**总长**。
     *
     * 返回 `-1` 表示拿不到（`*`、缺 `/`、格式不对）。
     * ⛔ 拿不到时**必须留 -1**，不能退化成 0 —— 0 会被下游当成「空文件」。
     */
    fun totalFromContentRange(header: String?): Long {
        val slash = header?.lastIndexOf('/') ?: return -1
        if (slash < 0) return -1
        val tail = header.substring(slash + 1).trim()
        if (tail.isEmpty() || tail == "*") return -1
        return tail.toLongOrNull()?.takeIf { it > 0 } ?: -1
    }

    /**
     * 从 `Content-Range: bytes 0-1023/1048576` 里取**本段起点**。
     *
     * 用来核对「服务端真的按我们要的偏移给了」—— 有些 CDN 会忽略 `Range`
     * 直接回 200 整文件。返回 `-1` 表示拿不到。
     */
    fun startFromContentRange(header: String?): Long {
        val h = header?.trim() ?: return -1
        val sp = h.indexOf(' ')
        if (sp < 0) return -1
        val range = h.substring(sp + 1)
        val dash = range.indexOf('-')
        if (dash <= 0) return -1
        return range.substring(0, dash).trim().toLongOrNull() ?: -1
    }
}
