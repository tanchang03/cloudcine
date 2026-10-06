package com.cloudcine.tv

import android.content.Context
import android.os.StatFs
import android.util.Log
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * 进程内**唯一**的磁盘缓存实例，外加磁盘空间查询。
 *
 * ## 为什么必须是单例
 *
 * `SimpleCache` 会在缓存目录里放一把文件锁（`.lock`）。同一个目录
 * 建第二个实例会直接抛 `CacheException: Another SimpleCache instance
 * uses this folder`。而 `Cache` 是「一个目录一个实例」的语义，
 * 生命周期应当跟**进程**走，不是跟 Activity 走 ——
 * 放进 `PlayerActivity` 的话，退出再进播放页就会撞锁。
 *
 * 所以这里用 `object` + `applicationContext`，**不改 AndroidManifest**
 * （不动 `application` 标签就少一个崩溃源）。
 *
 * ## 目录选择：`cacheDir` 而不是 `filesDir`
 *
 * `cacheDir` 是**系统可以在低存储时主动回收**的那一类 —— 对我们正合适，
 * 因为缓存丢了只是重下。`filesDir` 只有「清除数据/卸载」才释放，
 * 一个几百 MB~几 GB 的媒体缓存放那里，用户清不掉也看不见。
 *
 * ⚠️ 代价：系统真回收时会连同 `SimpleCache` 的索引一起删。
 * 这不会崩 —— `SimpleCache` 下次构造会重新扫描目录、重建索引，
 * 只是「已缓存」变成「没缓存」。**这正是我们要的让路行为。**
 */
object PrefetchCache {

    private const val TAG = "CloudCine"

    /** 缓存目录名。改它等于放弃旧缓存，所以不要随便改。 */
    private const val DIR_NAME = "media_cache"

    @Volatile
    private var cache: SimpleCache? = null

    /** 构造失败（目录被锁 / 空间不够）后不再重试，免得每次进播放页都撞一次。 */
    @Volatile
    private var unavailable = false

    @Volatile
    private var evictor: DiskCacheEvictor? = null

    /**
     * 初始化时算出的上限。
     *
     * [DiskCacheEvictor.lastLimitBytes] 要等**第一次淘汰**才有值，
     * 而预取器一起来就要用它算「允许领先多少」，所以单独记一份初值。
     */
    @Volatile
    private var initialLimitBytes: Long = 0L

    /**
     * 拿缓存实例；**空间不够或初始化失败时返回 null**（调用方走纯网络路径）。
     *
     * 返回 null 不是错误 —— 这是「这台机器不该开缓存」的正常结果。
     */
    fun get(context: Context): SimpleCache? {
        cache?.let { return it }
        if (unavailable) return null
        synchronized(this) {
            cache?.let { return it }
            if (unavailable) return null
            val app = context.applicationContext
            val dir = File(app.cacheDir, DIR_NAME)
            val available = availableBytes(dir)
            val limit = DiskSpace.cacheLimitBytes(available)
            if (limit <= 0L) {
                Log.i(
                    TAG,
                    "磁盘缓存：不开（可用 ${mib(available)} MiB，" +
                        "按规则算出的上限 ${mib(limit)} MiB 不够用）",
                )
                unavailable = true
                return null
            }
            return try {
                dir.mkdirs()
                // ⛔ 上限用**取值器**传进去：每次淘汰现读 StatFs，
                //    这样播放期间系统空间被别的 App 吃掉时能自动收缩。
                val ev = DiskCacheEvictor { DiskSpace.cacheLimitBytes(availableBytes(dir)) }
                val created = SimpleCache(dir, ev)
                evictor = ev
                initialLimitBytes = limit
                cache = created
                Log.i(
                    TAG,
                    "磁盘缓存：已启用 · 目录 ${dir.absolutePath} · " +
                        "上限 ${mib(limit)} MiB（可用 ${mib(available)} MiB，" +
                        "给系统留 ${mib(DiskSpace.MIN_FREE_BYTES)} MiB 后取一半）",
                )
                created
            } catch (e: Exception) {
                Log.w(TAG, "磁盘缓存：初始化失败，退回纯网络（${e.message}）", e)
                unavailable = true
                null
            }
        }
    }

    /** 当前缓存占用（字节）；没启用时是 0。 */
    fun usedBytes(): Long = evictor?.usedBytes ?: 0L

    /**
     * 当前生效的上限（字节）；没启用时是 0。
     *
     * 优先取淘汰器**最近一次现算**的值（空间变化后更准），
     * 还没淘汰过就退回初始化时算的那个。
     */
    fun limitBytes(): Long =
        evictor?.lastLimitBytes?.takeIf { it > 0L } ?: initialLimitBytes

    /**
     * 目录所在分区的可用字节；**读不到返回 -1**。
     *
     * ⛔ **必须把自己已经占掉的缓存加回去。**
     *    `StatFs.availableBytes` 会把本 App 缓存目录里的文件算成「已用」，
     *    于是「可用空间」随缓存增长而缩小 ⇒ 算出的上限越来越小 ⇒
     *    **自我压缩**。实测：同一台电视，缓存为空时算出 5081 MiB；
     *    等缓存占了 2.2 GiB，同一套公式只算出 3981 MiB，
     *    解方程收敛到 3387 MiB —— 缓存越用越少，完全是反的。
     *    加回 [usedBytes] 之后，算的才是「这块盘总共能给我多少」。
     *
     * ⛔ 返回 -1 而不是 0：调用方 [DiskSpace.cacheLimitBytes] 对
     *    「非正数」一律判为「不开缓存」，但日志里要能区分
     *    「空间真的不够」与「读不出来」。
     */
    fun availableBytes(dir: File): Long = try {
        val target = if (dir.exists()) dir else dir.parentFile ?: dir
        StatFs(target.absolutePath).availableBytes + usedBytes()
    } catch (e: Exception) {
        Log.w(TAG, "磁盘缓存：读可用空间失败（${e.message}）")
        -1L
    }

    /** 一行摘要，给播放页日志用。 */
    fun describe(context: Context): String {
        val c = get(context)
        val available = availableBytes(File(context.applicationContext.cacheDir, DIR_NAME))
        return if (c == null) {
            "磁盘缓存 关（可用 ${mib(available)} MiB）"
        } else {
            "磁盘缓存 ${mib(usedBytes())} / ${mib(limitBytes())} MiB（磁盘可用 ${mib(available)} MiB）"
        }
    }

    private fun mib(bytes: Long): Long = if (bytes < 0) -1 else bytes / 1048576
}
