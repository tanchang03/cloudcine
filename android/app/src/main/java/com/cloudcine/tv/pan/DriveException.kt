package com.cloudcine.tv.pan

/**
 * 网盘侧的失败。两家（夸克 / 百度）的具体异常都继承它。
 *
 * ## 为什么要有这个基类
 *
 * 「凭证废了」这件事必须能被**与厂家无关**的代码认出来 —— 最要紧的是
 * [com.cloudcine.tv.library.LibraryScanner]：它现在只会在 `catch (e: Throwable)`
 * 里 `failedDirs++` 然后接着列下一个目录。凭证失效时这意味着：
 *
 * - 根目录第一次列就失败，队列空了 ⇒ 扫描「正常完成」；
 * - 状态行给出「扫描完成：媒体 0 · 跳过 1 个目录」；
 * - 用户看到一面空墙，**以为网盘上真的没有片子**，而不是「该重新登录了」。
 *
 * 2026-10-17 在模拟器上用一份失效的 `BDUSS` 实测到的正是这个现象：日志里
 * 明明有 `errno=-6 登录状态无效`，界面上却只有一个「跳过 1 个目录」。
 *
 * ⛔ 所以扫描 / 发现碰到 `needsReauth` 时必须**中止**并把它报上去，不能当成
 * 「这个目录跳过」——两者的后果完全不同：后者会让用户以为库是空的。
 */
open class DriveException(
    /** ⛔ 非空：调用方大量用 `e.message` 拼状态行，可空会把判空散到每一处。 */
    override val message: String,
    /** 凭证已失效（或压根没登录）⇒ 上层应回登录页，且**不要**继续扫描。 */
    val needsReauth: Boolean = false,
    /** 文件/目录不存在。这是**正常**结果（网盘上被删了），不该当成故障。 */
    val notFound: Boolean = false,
) : Exception(message)
