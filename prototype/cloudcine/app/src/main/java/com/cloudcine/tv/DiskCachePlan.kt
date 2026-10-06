package com.cloudcine.tv

/**
 * 进度条上「磁盘缓存」那一层的一次快照。
 *
 * ⛔ **一拍只算一次**：算它要拿 `SimpleCache` 的锁并遍历全部 span（可达几十个），
 * 进度条与右侧文字各算一遍就是白翻一倍，而且是每 500ms 一次。
 */
class DiskCacheSnapshot(
    /**
     * 已覆盖区间，**比例 0..1，扁平**：`[起0, 止0, 起1, 止1, …]`。
     *
     * ⛔ 是**区间列表**而不是单个「画到哪」：用户拖到预取前沿之外后，
     * 磁盘上就是 `[片头, 旧前沿] ∪ [新锚点, 新前沿]` 两段，中间那个空洞
     * 是**真的没有数据**。画成「从片头连到新前沿」等于骗用户 ——
     * 他会以为回拖那一段不用重新缓冲。
     */
    val ranges: FloatArray,
    /** 本片在盘上已提交的**总字节数**（不是缓存目录的总占用，那是别的片源的账）。 */
    val usedBytes: Long,
    /**
     * 原始**字节**区间（扁平 `[起, 止, …]`，止为开区间）。
     *
     * 留着它是为了回答「某个字节位置在盘上到底有没有」：进度条要的是**比例**，
     * 而跳转时判断「这一跳要不要重新缓冲」要的是**字节** —— 播放器给的位置
     * 是精确的字节偏移，比例则是估算的。`covers` 就是干这个的。
     */
    val byteRanges: LongArray,
    /**
     * 已覆盖到的最远**媒体时间**（毫秒）；`0` = 没有数据、或拿不到码率算不出来。
     *
     * ⛔ 是「最远」而不是「播放头前方」：跳转留下两段时，它指的是**更靠后
     *    那一段**的末尾。调试面板写「到 58:47」说的就是这个。
     */
    val endMs: Long,
) {
    /** 已覆盖的段数。跳转一次就会多一段（中间是真空洞）。 */
    val segments: Int get() = byteRanges.size / 2

    /**
     * `positionBytes` 是否落在某个已提交的区间里。
     *
     * 对零长度/倒序的垃圾区间天然免疫（`pos < 止` 永远不成立），
     * 所以调用方不必先清洗。
     */
    fun covers(positionBytes: Long): Boolean {
        var i = 0
        while (i + 1 < byteRanges.size) {
            if (positionBytes >= byteRanges[i] && positionBytes < byteRanges[i + 1]) return true
            i += 2
        }
        return false
    }

    companion object {
        val EMPTY = DiskCacheSnapshot(FloatArray(0), 0L, LongArray(0), 0L)
    }
}

/**
 * 把「磁盘上覆盖了哪些字节」换算成进度条能画的比例。**纯函数，不碰 Android。**
 *
 * ## 为什么要单独一层
 *
 * `SimpleCache` 给的是**字节区间**（`CacheSpan.position / length`），而进度条
 * 画的是**时间比例**。两者之间只有码率这一个桥梁，而码率是**估算**的
 * （`Quality.requiredMbPerSec`，VBR 片源必然有偏差）—— 所以换算结果只能
 * 当作「大概画在这儿」，不能当作精确读数。把它抽成纯函数是为了能对
 * 「空洞」「超出总长」「拿不到码率」这些边界写单测，而不是在 `onDraw` 里试。
 */
object DiskCachePlan {

    /**
     * 整片字节数的估算值；**拿不到码率或时长时返回 0**（表示「算不了」，
     * 调用方应当**什么都不画**，而不是画到 0 位置）。
     *
     * @param bytesPerSec 当前档位的码率（字节/秒）。`<= 0` / NaN / Inf 都算拿不到。
     * @param durationMs 播放器给的时长（毫秒）。`C.TIME_UNSET`（-9223372036854775807）
     *   与 `<= 0` 都算拿不到。
     */
    fun totalBytes(bytesPerSec: Double, durationMs: Long): Double {
        if (!bytesPerSec.isFinite() || bytesPerSec <= 0.0) return 0.0
        if (durationMs <= 0L) return 0.0
        val total = bytesPerSec * durationMs / 1000.0
        return if (total.isFinite() && total > 0.0) total else 0.0
    }

    /**
     * 字节区间 → 比例区间。
     *
     * @param ranges 扁平 `[起, 止, 起, 止, …]`，**止为开区间**（`止 = 起 + 长度`）。
     *   顺序无所谓（内部按起点排序）；长度 `<= 0` 的会被丢掉。
     * @return 扁平比例数组；`totalBytes <= 0` 或没有任何有效区间时返回**空数组**。
     *
     * ⛔ 比例要**夹到 [0,1]**：`totalBytes` 是估算的，末段的止点完全可能
     *    超过它（VBR 片源尾巴码率高，或码率估低了）—— 不夹就会画出界。
     *
     * ⛔ 判 `totalBytes` 时**必须先 `isFinite()`**：`NaN <= 0.0` 是 `false`，
     *    光写 `<= 0` 会让 NaN 一路穿过去，最后 `coerceIn` 也拦不住它
     *    （NaN 与任何数比较都是 false），画出一个 NaN 矩形。
     *    这一条是单测逼出来的（`DiskCachePlanTest` 里那个 NaN 用例）。
     */
    fun rangesToRatios(ranges: LongArray, totalBytes: Double): FloatArray {
        if (!totalBytes.isFinite() || totalBytes <= 0.0) return FloatArray(0)
        if (ranges.size < 2) return FloatArray(0)
        val starts = ArrayList<Long>(ranges.size / 2)
        val ends = ArrayList<Long>(ranges.size / 2)
        var i = 0
        while (i + 1 < ranges.size) {
            val a = ranges[i]
            val b = ranges[i + 1]
            if (b > a) {
                starts.add(a)
                ends.add(b)
            }
            i += 2
        }
        if (starts.isEmpty()) return FloatArray(0)
        val order = starts.indices.sortedBy { starts[it] }
        val out = FloatArray(order.size * 2)
        var j = 0
        for (k in order) {
            out[j++] = (starts[k] / totalBytes).toFloat().coerceIn(0f, 1f)
            out[j++] = (ends[k] / totalBytes).toFloat().coerceIn(0f, 1f)
        }
        return out
    }

    /**
     * 一步到位：字节区间 → [DiskCacheSnapshot]。
     *
     * `usedBytes` 用**有效区间**（长度 > 0）求和，与进度条画出来的东西
     * **同源** —— 这样「文字说 512 MiB、进度条却画 0」这种自相矛盾的画面
     * 结构上不可能再出现（2026-10-06 实测撞过一次：文字读的是缓存目录的
     * 总占用，含别的片源的残留）。
     */
    fun snapshot(ranges: LongArray, bytesPerSec: Double, durationMs: Long): DiskCacheSnapshot {
        var used = 0L
        var endBytes = 0L
        var i = 0
        while (i + 1 < ranges.size) {
            val a = ranges[i]
            val b = ranges[i + 1]
            if (b > a) {
                used += b - a
                if (b > endBytes) endBytes = b
            }
            i += 2
        }
        if (used <= 0L) return DiskCacheSnapshot.EMPTY
        // 最远覆盖到的**媒体时间**：字节 ÷ 码率。⛔ 码率拿不到就留 0，
        //   不要瞎给一个数 —— 「到 58:47」这种读数错一次就没人信了。
        val endMs = if (bytesPerSec.isFinite() && bytesPerSec > 0.0) {
            (endBytes / bytesPerSec * 1000.0).toLong()
        } else {
            0L
        }
        val total = totalBytes(bytesPerSec, durationMs)
        // 比例画不出来（拿不到码率/时长）时仍然把**字节区间**带上：
        // 「某个位置在不在盘上」用不着码率，跳转日志要靠它。
        if (total <= 0.0) return DiskCacheSnapshot(FloatArray(0), used, ranges, endMs)
        return DiskCacheSnapshot(rangesToRatios(ranges, total), used, ranges, endMs)
    }
}
