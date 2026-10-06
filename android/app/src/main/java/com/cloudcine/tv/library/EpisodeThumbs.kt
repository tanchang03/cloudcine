package com.cloudcine.tv.library

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.util.LruCache
import com.cloudcine.tv.pan.PanApi
import java.io.File
import java.util.Collections

/**
 * 「选集」列表里每一条左边那张**网盘封面**的取用。
 *
 * ## 数据从哪来
 *
 * `media_items.thumb_url` → 夸克列目录时下发的 `preview_url`
 * （实测 640×360 WebP，约 12 KiB）。**必须带 Cookie**：裸链回
 * `401 code=31001 require login`（见 `docs/媒体库体验优化-逆向评估.md §2.2`），
 * 所以下载统一走 [PanApi.thumbBytes]（它现取最新 Cookie，并把响应里轮换的
 * `__puus` 收回去）。
 *
 * ## ⛔ 为什么扫描期不下、非要等到这里才下
 *
 * 一个库上千条，全下就是上千次请求 —— 而用户可能一次都不翻到那些片子。
 * 扫描期只记 URL（`ScanItem.thumbUrl`），**首次真的要显示时才下**。
 * 这一点与 PC 端的 `PosterCache` 是同一条结论。
 *
 * ## 三级缓存
 *
 * 1. **内存**（[cache]，按字节计价）—— 上下翻列表时不再碰磁盘；
 * 2. **磁盘**（`filesDir/thumbs/t-<url 散列>.img`）—— 关掉播放页再回来、
 *    甚至重启应用都还在。文件名用 [PosterNaming.hash8]，与海报缓存同一套
 *    散列（⛔ 不用 `String.hashCode()`，它跨运行时不稳定）；
 * 3. 都没有才发网络请求。
 *
 * ⛔ **失败要记下来**（[failed]）：服务端只对约七成视频生成过预览图，
 *    剩下三成每次拉都会 404/401。不记的话，列表每滚一格就重试一次，
 *    在那台电视上就是「滚一下卡一下」。标记只在内存里 —— 重启后允许重试，
 *    因为失败也可能是临时的网络问题。
 *
 * ## 线程模型
 *
 * [cached] 可以在主线程调（纯内存查表）；[load] **必须**在后台线程调
 * （要读盘 / 发请求 / 解码）。
 */
class EpisodeThumbs(
    private val dir: File,
    cacheBytes: Int,
) {

    private val cache = object : LruCache<String, Bitmap>(cacheBytes) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    private val failed: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /**
     * 正在下的地址。
     *
     * ⛔ 去重不能省：`ListView` 每次 `getView` 都会问一次「有没有图」，
     *    而用户在列表里上下滚两下，同一个地址就会被问好几次 ——
     *    不去重就是同一张 12 KiB 的图**并发下三遍**（还各占一条连接，
     *    在这台电视的 WiFi 上是实打实的带宽浪费）。
     */
    private val inFlight: MutableSet<String> = Collections.synchronizedSet(HashSet())

    /** 内存里有没有已经解码好的。**主线程可调**。 */
    fun cached(url: String): Bitmap? = cache.get(url)

    /** 这个地址是不是已经确认过「拿不到」。主线程可调。 */
    fun isKnownBad(url: String): Boolean = failed.contains(url)

    /**
     * 取一张缩略图。**必须在后台线程调**。
     *
     * @return 拿不到时返回 `null`（并把它记进 [failed]，除非是磁盘/解码出了岔子）。
     */
    fun load(url: String, api: PanApi, targetPx: Int): Bitmap? {
        cache.get(url)?.let { return it }
        if (failed.contains(url)) return null
        // 已经有人在下了 —— 直接回 null，让它下完那一趟去通知界面重画。
        if (!inFlight.add(url)) return null
        try {
            return loadLocked(url, api, targetPx)
        } finally {
            inFlight.remove(url)
        }
    }

    private fun loadLocked(url: String, api: PanApi, targetPx: Int): Bitmap? {
        // ① 磁盘
        val file = fileFor(url)
        if (file.isFile && file.length() > 0) {
            decodeFile(file, targetPx)?.let {
                cache.put(url, it)
                return it
            }
            // 落盘的是半截 / 坏文件 —— 删掉重下，否则这一条永远显示不出来。
            runCatching { file.delete() }
        }

        // ② 网络
        val bytes = try {
            api.thumbBytes(url)
        } catch (t: Throwable) {
            Log.i(TAG, "缩略图取不到（记下不再重试）：${t.message} · ${file.name}")
            failed.add(url)
            return null
        }
        if (bytes.isEmpty()) {
            failed.add(url)
            return null
        }
        // 先落盘再解码：解码失败也不该让这次下载白费（下次还能从盘上试）。
        writeAtomically(file, bytes)
        val bmp = decodeBytes(bytes, targetPx)
        if (bmp == null) {
            Log.w(TAG, "缩略图解码失败（${bytes.size} 字节）：${file.name}")
            runCatching { file.delete() }
            return null
        }
        cache.put(url, bmp)
        return bmp
    }

    private fun fileFor(url: String): File = File(dir, "t-${PosterNaming.hash8(url)}.img")

    /**
     * 先写临时文件再改名。
     *
     * ⛔ 不能直接往目标文件写：写到一半进程被杀（电视上很常见 —— 这台机器
     *    只有 2.5 GB 内存，LMK 随时会动手），留下的是**半张图**，而它会被
     *    当成「已缓存」永远命中，表现为「这一集封面永远花屏」。
     */
    private fun writeAtomically(file: File, bytes: ByteArray) {
        runCatching {
            dir.mkdirs()
            val tmp = File(dir, "${file.name}.part")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(file)) {
                tmp.copyTo(file, overwrite = true)
                tmp.delete()
            }
        }.onFailure { Log.w(TAG, "缩略图落盘失败：${file.name}", it) }
    }

    private fun decodeFile(file: File, targetPx: Int): Bitmap? = runCatching {
        BitmapFactory.decodeFile(file.absolutePath, sampleOptions(file.absolutePath, targetPx))
    }.getOrNull()

    private fun decodeBytes(bytes: ByteArray, targetPx: Int): Bitmap? = runCatching {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size,
            options(bounds.outWidth, bounds.outHeight, targetPx),
        )
    }.getOrNull()

    private fun sampleOptions(path: String, targetPx: Int): BitmapFactory.Options {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        return options(bounds.outWidth, bounds.outHeight, targetPx)
    }

    /**
     * 按 2 的幂降采样到「不小于 [targetPx]」。
     *
     * ⛔ 缩略图是 **16:9 的横图**（640×360），所以只需要看**宽**。
     *    照海报那边（2:3 竖图，宽高都要够）的写法会少采一档、白白多占
     *    一倍内存 —— 列表里同时可见 5~6 张，差别很实在。
     * ⛔ `inPreferredConfig = RGB_565`：缩略图不需要透明通道，省一半堆。
     *    这台电视只有 512 MB Java 堆。
     */
    private fun options(width: Int, height: Int, targetPx: Int): BitmapFactory.Options {
        val opts = BitmapFactory.Options()
        opts.inPreferredConfig = Bitmap.Config.RGB_565
        if (width <= 0 || height <= 0 || targetPx <= 0) return opts
        var sample = 1
        while (width / (sample * 2) >= targetPx) sample *= 2
        opts.inSampleSize = sample
        return opts
    }

    private companion object {
        const val TAG = "CloudCine"
    }
}
