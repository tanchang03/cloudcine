package com.cloudcine.tv.library

/**
 * 网盘目录路径的**归一化口径** —— 全包只有这一份实现。
 *
 * ## 为什么必须只有一份
 *
 * `dirPath` 是 `groupKey`（归组键）的组成部分：同一个文件传进不同的 `dirPath`
 * 形态（`/电影` vs `/电影/`），会算出**两个不同的 groupKey**，于是同一部片子
 * 在海报墙上出现两格、或者追更检查报出来的「新集」挂到了一个不存在的作品上。
 *
 * 而这是**静默的**：没有任何断言、没有异常，只有用户某天发现「怎么多了一格」。
 * 所以扫描器（`LibraryScanner`）、追更检查（`LibraryDb.dirsForWorks`）与
 * 将来任何拿 `dirPath` 造 `ScanItem` 的地方，都必须调这一个函数。
 *
 * ⛔ 与 PC 端 `drivePathWithTrailingSlash` 同口径：**一律带尾斜杠**，
 *    根目录是 `/`（不是空串）。
 */
internal const val ROOT_PATH = "/"

/**
 * 把目录路径归一成**带尾斜杠**的形态。
 *
 * 空串与 `/` 都归一成 [ROOT_PATH]。空串拼出来的 `groupKey` 与 `/` 拼出来的
 * 不同，那会让根目录下的片子在海报墙上多出一格。
 */
internal fun normalizeDirPath(path: String): String {
    val p = path.trim()
    if (p.isEmpty() || p == ROOT_PATH) return ROOT_PATH
    return if (p.endsWith("/")) p else "$p/"
}
