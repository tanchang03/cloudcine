package com.cloudcine.tv.library

import android.content.Context
import java.io.File

/**
 * 媒体库相关文件的落盘位置 —— **全工程唯一一处**，别在别处再拼一遍路径。
 *
 * ⛔ 放 `filesDir`（应用私有目录）而**不是** `getExternalFilesDir`：
 *   * 备份包要从这里把库文件原样读出来上传，外部存储可能被用户/其他应用动过；
 *   * 电视上外部存储经常是「可弹出」的，库文件不该跟着 U 盘走。
 *
 * ⚠️ 这两个名字（`cloudcine.sqlite` / `posters`）必须与 PC 端的
 *   `getApplicationSupportDirectory()` 下的同名文件**一一对应** ——
 *   备份包里的 `fileNames` 认的就是它们。
 */
object LibraryPaths {

    /** 库文件名。与 PC 端 `openAppDatabase()` 里那个名字一致。 */
    const val DB_NAME = LibrarySchema.FILE_NAME

    /** 海报缓存目录名。与 PC 端 `main.dart` 里的 `support.path/posters` 一致。 */
    const val POSTER_DIR_NAME = "posters"

    /**
     * 「选集」列表里那张网盘封面的缓存目录名。
     *
     * ⛔ **Android 独有，不进备份包**（PC 端没有这个概念 —— 它那边的选集列表
     *    只有文字）。所以这个名字**不**需要与 PC 端对齐；备份只打包
     *    `dbFile` 与 `posterDir` 两样（见 `LibraryBackupService.exportBackup`），
     *    多出来的目录不会被打进去，也不会被恢复流程碰到。
     */
    const val THUMB_DIR_NAME = "thumbs"

    fun dbFile(context: Context): File = File(context.filesDir, DB_NAME)

    fun posterDir(context: Context): File = File(context.filesDir, POSTER_DIR_NAME)

    fun thumbDir(context: Context): File = File(context.filesDir, THUMB_DIR_NAME)
}
