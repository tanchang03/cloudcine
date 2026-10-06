package com.cloudcine.tv

import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheEvictor
import androidx.media3.datasource.cache.CacheSpan
import java.util.ArrayDeque

/**
 * LRU 淘汰器：**上限每次淘汰时现算**，而不是构造时定死。
 *
 * ## 为什么要「现算」
 *
 * Media3 自带的 [androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor]
 * 把 `maxBytes` 在构造时锁死。可磁盘可用空间**是会变的**：
 * - 用户中途装了别的 App、系统下了 OTA、别的应用写了日志；
 * - 反过来，用户清了一遍垃圾，空间又回来了。
 *
 * 缓存是**最该让路**的那一份数据 —— 它随时可以重下。所以上限用
 * `() -> Long` 取值器，每次淘汰都重新读一遍 `StatFs`
 * （见 [PrefetchCache.availableBytes]）。
 *
 * ## LRU 的语义
 *
 * 淘汰「最久没被访问」的 span。播放头**前面**的刚被写过、
 * 播放头**后面**（已播过）的刚被读过，两边都算「新」；
 * 真正被淘汰的是「很久以前看过、现在不看」的那些 —— 正是想要的。
 *
 * ⛔ 这里的 `cache.removeSpan()` 会**同步回调** [onSpanRemoved]，
 * 所以必须先 `lru.removeLast()` 再 `removeSpan`，否则长度会被扣两次
 * （Media3 自己的实现就是这个顺序）。
 */
class DiskCacheEvictor(
    private val limitBytes: () -> Long,
) : CacheEvictor {

    /** 队首 = 最近用过，队尾 = 最该淘汰。 */
    private val lru = ArrayDeque<CacheSpan>()

    /** 已缓存 span 的总字节数（只算 `isCached` 的）。 */
    private var currentSize = 0L

    /** 最近一次生效的上限，供日志读取。 */
    @Volatile
    var lastLimitBytes: Long = 0L
        private set

    override fun requiresCacheSpanTouches(): Boolean = false

    override fun onCacheInitialized() {
        // ⛔ 初始化时**不预扫**：SimpleCache 会把已有 span 逐个回调 onSpanAdded，
        //    这里什么都不用做，交给那些回调去建 LRU 与计数。
    }

    override fun onStartFile(cache: Cache, key: String, position: Long, length: Long) {
        // ⛔ 开写之前先按当前空间腾地方：否则「磁盘已经满了才开始写」的那一轮
        //    会先写失败再淘汰，白白浪费一次 IO。
        synchronized(this) { evict(cache) }
    }

    override fun onSpanAdded(cache: Cache, span: CacheSpan) {
        synchronized(this) {
            if (span.isCached) {
                lru.addFirst(span)
                currentSize += span.length
            }
            evict(cache)
        }
    }

    override fun onSpanRemoved(cache: Cache, span: CacheSpan) {
        synchronized(this) {
            if (lru.remove(span)) {
                currentSize -= span.length
            }
        }
    }

    override fun onSpanTouched(cache: Cache, oldSpan: CacheSpan, newSpan: CacheSpan) {
        synchronized(this) {
            if (oldSpan === newSpan) return
            if (lru.remove(oldSpan)) {
                lru.addFirst(newSpan)
                currentSize += newSpan.length - oldSpan.length
            }
            evict(cache)
        }
    }

    /** 当前占用（字节），供日志读取。 */
    val usedBytes: Long get() = synchronized(this) { currentSize }

    /**
     * 淘汰到「不超过当前上限」为止。调用方须持锁。
     *
     * ⛔ 上限可能是 0（空间紧张 / 算不出来）—— 那时会把缓存**全部清空**，
     * 这是刻意的：宁可丢缓存，也不让系统进低存储。
     */
    private fun evict(cache: Cache) {
        val limit = limitBytes().coerceAtLeast(0L)
        lastLimitBytes = limit
        while (currentSize > limit && lru.isNotEmpty()) {
            val span = lru.removeLast()
            currentSize -= span.length
            cache.removeSpan(span)
        }
    }
}
