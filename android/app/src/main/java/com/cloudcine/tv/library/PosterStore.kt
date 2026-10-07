package com.cloudcine.tv.library

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import java.io.File

/**
 * 海报的**查找 + 解码**。
 *
 * ⛔ **不做下载**：海报是随备份包一起搬过来的（实测 325 个文件已经在盘上），
 *    播放端为了看一眼封面去发网络请求是纯浪费 —— 而且夸克有 QPS 限制。
 *
 * ## 为什么要有目录索引，而不是逐张 `File.exists()`
 *
 * PC 端把海报命名成 `{归一化作品键}_{URL散列}.jpg`，而 `media_works.poster_file`
 * 这一列**实测 128 部全是空**（PC 端自己从不回写）。所以「作品 → 文件」这个映射
 * 只能**由文件名反推**（见 [PosterNaming.indexKeyOf]）。
 *
 * 反推有两种做法：
 *   * 每张卡片各扫一遍目录 —— 128 部 × 325 个文件 = **4 万次 stat**，主线程必卡；
 *   * **开机扫一次、建成 `Map`** —— 325 次，之后全是内存查表。
 * 选后者。索引只在 [buildIndex] 里重建（**必须在后台线程**）。
 */
class PosterStore(
    private val dir: File,
    cacheBytes: Int,
) {

    /**
     * 缩略图缓存。
     *
     * ⛔ 必须封顶：一屏十几张 2:3 的图，ARGB_8888 下每张就几百 KB，
     *    没有上限的话「从头滚到尾」等于把整个海报墙留在堆里。
     *    用 `byteCount` 而不是「张数」计价 —— 张数对大小不同的图毫无意义。
     */
    private val cache = object : LruCache<String, Bitmap>(cacheBytes) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    /** `归一化作品键 → 文件`。null = 还没扫过。 */
    @Volatile
    private var index: Map<String, File>? = null

    /** 索引里认出来的海报文件数（诊断 / 状态行用）。 */
    val indexedCount: Int get() = index?.size ?: 0

    /**
     * 重建目录索引。**必须在后台线程调**（要读磁盘）。
     *
     * 重复调用是安全的；旧索引在重建期间继续可用，建成后整体替换。
     */
    fun buildIndex() {
        val map = HashMap<String, File>(512)
        val files = dir.listFiles()
        if (files != null) {
            for (f in files) {
                if (!f.isFile) continue
                val key = PosterNaming.indexKeyOf(f.name) ?: continue
                // 同名（不该发生）只留第一个 —— 留「目录返回顺序里的第一个」
                // 至少是确定的，而覆盖成最后一个会让不同机器结果不一致。
                if (!map.containsKey(key)) map[key] = f
            }
        }
        index = map
    }

    /** 找到某个作品的海报文件；没有则 null。 */
    fun fileFor(work: Work): File? {
        // ① 库里记着的文件名优先 —— 有就直接用，连索引都不用查。
        //    （PC 端以前不写这一列，Android 端刮削下载完会**回写**它。）
        val named = work.posterFile?.takeIf { it.isNotBlank() }
        if (named != null) {
            val f = File(dir, named)
            if (f.isFile) return f
        }
        // ② 用**当前** `posterUrl` 精确算文件名 —— 与 PC 端 `PosterCache.pathFor`
        //    同一口径（它也是拿 `key` + `url` 现算）。
        //
        //    ⛔ 这一步是**刮削换海报之后能立刻看到新图**的关键。文件名的第二段
        //    是 URL 的散列，所以新旧海报是**两个不同的文件**；只靠 ③ 的目录索引
        //    会在两个文件里随便挑一个（索引按「目录返回顺序里的第一个」建），
        //    用户就会看到「刮了但海报没变」。
        val url = work.posterUrl?.takeIf { it.isNotBlank() }
        if (url != null) {
            val f = File(dir, PosterNaming.fileNameFor(work.key, url))
            if (f.isFile) return f
        }
        // ③ 退回索引 —— 兼容「PC 端刮的、随备份搬过来的」那些作品
        //    （它们的 `posterUrl` 可能是空的，只有文件在盘上）。
        return index?.get(PosterNaming.sanitize(work.key))
    }

    fun cached(file: File): Bitmap? = cache.get(file.name)

    fun put(file: File, bitmap: Bitmap) {
        cache.put(file.name, bitmap)
    }

    /**
     * 缩略图解码。**绝不能在主线程调**（`getView` 就在主线程上）。
     *
     * @param targetPx 目标宽度（像素）。按 2 的幂降采样到「不小于它」，
     *   再交给 `ImageView` 缩放 —— 一次采样到位，不做二次缩放。
     */
    fun decode(file: File, targetPx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        // 宽**和**高都要够：海报是 2:3 的竖图，只按宽算会采过头。
        while (bounds.outWidth / (sample * 2) >= targetPx &&
            bounds.outHeight / (sample * 2) >= targetPx
        ) {
            sample *= 2
        }
        return runCatching {
            BitmapFactory.decodeFile(
                file.absolutePath,
                BitmapFactory.Options().apply {
                    inSampleSize = sample
                    // ⛔ 海报不需要透明通道。RGB_565 直接省一半堆 ——
                    //    一屏十几张缩略图，ARGB_8888 会白白吃掉好几 MB。
                    inPreferredConfig = Bitmap.Config.RGB_565
                },
            )
        }.getOrNull()
    }
}
