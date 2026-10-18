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

/**
 * 目录路径 → **百度 API 认的形态**（不带尾斜杠，根仍是 `/`）。
 *
 * ⛔ 百度的 `dir` 参数与 `dlink` 里的 `path` 都是**不带尾斜杠**的
 * （`/电影` 而不是 `/电影/`）。带上去不一定报错，但取链兜底那条路由
 * （`/api/filemetas?target=["/电影/a.mkv"]`）是**逐字匹配**的 ——
 * 多一个斜杠就匹配不到，响应里没有 `dlink`，表现是「原画取不到、
 * 只剩转码档」。所以两处都从这里出。
 *
 * ⛔ 与 [normalizeDirPath] 是**两个方向**，别互相替代：库里存的是带斜杠的
 * （`groupKey` 口径），发请求要的是不带斜杠的（百度口径）。
 */
internal fun dirPathOf(path: String): String {
    val p = normalizeDirPath(path).trimEnd('/')
    return if (p.isEmpty()) ROOT_PATH else p
}

/**
 * `dirPath` + `fileName` → 完整路径（`/电影/第一季/a.mkv`）。
 *
 * ⛔ 入参 `dirPath` 两种形态都吃（带 / 不带尾斜杠），因为调用方一半来自
 * 库（带）、一半来自浏览页的目录栈（不带）。拼接本身只有这一份实现，
 * 免得「多了个双斜杠 `/电影//a.mkv`」这种错落到某一条路径上 —— 它同样
 * 是逐字匹配，取链会静默失败。
 */
internal fun fullPathOf(dirPath: String, fileName: String): String {
    val dir = dirPathOf(dirPath)
    return if (dir == ROOT_PATH) "/$fileName" else "$dir/$fileName"
}
