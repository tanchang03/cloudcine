package com.cloudcine.tv.library

import com.cloudcine.tv.pan.DriveException
import java.io.IOException

/**
 * 按批删除网盘文件的循环 —— 从 `LibraryActivity.removeWorks` 里抽出来的。
 *
 * ## 为什么值得单独一个类
 *
 * 它是这条链路上**唯一**能在 JVM 单测里跑起来的一段：`LibraryDb` 要真
 * SQLite、`PanApi` 要真凭证与真网盘，而这里只依赖「给我一批 fid、告诉我
 * 删了几个」。抽出来之后，「250 个文件分 3 批」「某一批失败还要不要继续」
 * 「进度会不会走满」都能用假网盘跑 —— 不必真的删片子。
 *
 * ## 语义（改之前先看这里）
 *
 * * **普通失败不中止**（限流、单个文件被拒）：只有那一批算失败，后面继续发。
 * * **凭证失效 / 断网中止**（[abortOn]）：后面每一批都会以同样的方式失败，
 *   继续打只会把限流线顶穿，用户还得等几十次超时。没发出去的那几批
 *   **照样计入 failed** —— 它们确实没删掉，报成成功是撒谎。
 * * **失败的那一批也算「走完」**：进度照样往前推。卡在失败批次上不动，
 *   屏幕上看起来就是死机。中止时直接把进度推到满格。
 * * **`error` 只记第一条**：后面每一批大概率是同一条原因，堆一串只会让
 *   提示框长到看不完。
 *
 * ⚠️ 这套判据与 PC 的 `LibraryRemovalController._deleteFromDrive` 同口径
 *    （那边叫 `needsReauth || type == network`）。改一侧记得改另一侧。
 */
object BatchFileDeleter {

    /**
     * 每批带多少个 fid。
     *
     * ⛔ 必须与 PC 的 `driveMaxFidsPerRequest` **同数**（100）：一次带三千个
     *    fid 超时的话，用户什么信息都拿不到，也说不清「动了多少、失败多少」。
     */
    const val FIDS_PER_BATCH = 100

    /** 一次批量删除的账。三个数缺一不可，理由同 `DriveRemovalSummary`。 */
    data class Result(
        val deleted: Int,
        val failed: Int,
        val error: String?,
    )

    /**
     * 这个异常值不值得再试下一批。
     *
     * 凭证失效（`needsReauth`）与网络层异常（`IOException`）**不是按批次的**：
     * 换一批 fid 还是同样的结果。
     */
    fun abortOn(e: Exception): Boolean =
        (e is DriveException && e.needsReauth) || e is IOException

    /**
     * 删掉 [fids] 里的全部文件。
     *
     * @param onProgress `(已完成, 总数)`。**第一件事就是报 `(0, total)`** ——
     *   分母必须早于第一批请求，否则屏幕上的数字会先跳一下，看着像数错了。
     * @param abortOn 这一批的异常是否意味着「后面的也不用试了」。默认见
     *   [abortOn]（凭证失效 / 断网）。
     * @param onBatch 每一批**成功之后**的回调：`(这一批的 fid, 确认删掉的个数)`。
     *   多选删除靠它把「哪几个真的没了」记下来，再去清对应的媒体库索引 ——
     *   ⛔ 只清**确认删掉**的那些：清早了会得到「文件还在网盘上、库里却没了」，
     *   而那要重新扫一遍才能回来（见 `BrowseActivity.doBatchDelete`）。
     * @param deleteBatch 真正发请求的那一步，返回**确认删掉**的个数。
     *   抛异常 = 这一批失败（个数按这一批的 size 计入 failed）。
     */
    fun delete(
        fids: Collection<String>,
        onProgress: (done: Int, total: Int) -> Unit = { _, _ -> },
        abortOn: (Exception) -> Boolean = ::abortOn,
        onBatch: (chunk: List<String>, deletedInBatch: Int) -> Unit = { _, _ -> },
        deleteBatch: (List<String>) -> Int,
    ): Result {
        if (fids.isEmpty()) return Result(deleted = 0, failed = 0, error = null)

        val total = fids.size
        onProgress(0, total)

        var deleted = 0
        var failed = 0
        var error: String? = null
        var done = 0
        val chunks = fids.chunked(FIDS_PER_BATCH)

        for ((i, chunk) in chunks.withIndex()) {
            try {
                val n = deleteBatch(chunk)
                deleted += n
                // ⛔ 只在**这一批真的走完**时回调：部分成功时我们并不知道是哪几个
                //    成功了（网盘只回个数），此时宁可让索引留着 —— 留着是自愈的
                //    （下次扫描会再报一次「文件不在」），清错是不可逆的。
                onBatch(chunk, n)
            } catch (e: Exception) {
                failed += chunk.size
                if (error == null) error = e.message ?: e.javaClass.simpleName
                if (abortOn(e)) {
                    // 没发出去的那几批也算失败：它们确实没删掉。
                    for (j in i + 1 until chunks.size) failed += chunks[j].size
                    // 进度推到满格：停在 100/250 上关窗，看起来像被掐断了。
                    onProgress(total, total)
                    return Result(deleted = deleted, failed = failed, error = error)
                }
            }
            done += chunk.size
            onProgress(done, total)
        }
        return Result(deleted = deleted, failed = failed, error = error)
    }
}
