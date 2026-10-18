package com.cloudcine.tv.pan

/**
 * 网盘服务商标识（与 PC 端 `DriveProvider.id`、`media_items.provider` 逐字一致）。
 *
 * ⛔ 这两个字符串是**跨端契约**：`media_items.id = "provider:fileId"`，
 * 改一个字就会让 PC 与电视把同一批文件当成两份（表现为「同步之后媒体库翻倍」）。
 */
object DriveProviders {
    const val QUARK = "quark"
    const val BAIDU = "baidu"

    fun displayName(provider: String): String = when (provider) {
        BAIDU -> "百度网盘"
        else -> "夸克网盘"
    }

    fun shortName(provider: String): String = when (provider) {
        BAIDU -> "百度"
        else -> "夸克"
    }

    /** 该 URL 是否属于百度域（缩略图 / 直链的归属判定）。 */
    fun isBaiduUrl(url: String): Boolean = url.contains("baidu.com")

    /** 解析 `provider:fileId` 里的 provider 段。 */
    fun ofItemId(itemId: String): String =
        itemId.substringBefore(':', QUARK).ifEmpty { QUARK }
}

/**
 * 一个网盘账号的**最小能力面**：列目录、取链、读小文件、取图、探活。
 *
 * ## 为什么抽这一层
 *
 * 扫描器、播放页、文件列表、封面兜底原本都直接吃 `PanApi`（夸克）。接第二家
 * 网盘时，如果各自 `if (provider == "baidu")` 分支，判据会散落在五六个文件里，
 * 而漏掉一处的表现是**静默的**（例如「百度条目能列出来、一点播就报错」）。
 * 所以统一收成这一个接口：**调用方只认能力，不认厂家**。
 *
 * ## 各方法的口径
 *
 * - [listDirectory]：`idOrPath` 是「目录标识」。夸克是 `fid`，百度是**路径**
 *   （也接受 `fs_id`，内部翻译）。分页由调用方驱动（每页 [size] 条）。
 * - [resolve]：取一次起播需要的全部档位。**每次现取**（直链带签名）。
 *   [pathHint] 只在百度上有用（省一次路径翻译；夸克忽略）。
 * - [readFileBytes]：读小文件原始字节（外挂字幕）。返回**字节**不是字符串。
 * - [thumbBytes]：取网盘缩略图（**必须带网盘凭证**，裸链会 401/403）。
 * - [ping]：最轻量的连通性探测，用来判断「凭证还在不在」。
 */
interface DriveClient {
    /** [DriveProviders] 里的稳定标识。 */
    val providerId: String

    /** 根目录标识（夸克 `"0"`，百度 `"/"`）。 */
    val rootId: String

    fun listDirectory(idOrPath: String, page: Int = 1, size: Int = 100): List<DriveEntry>

    fun resolve(fileId: String, pathHint: String? = null): PlayInfo

    fun fileBytesUrl(fileId: String): String

    fun readFileBytes(fileId: String, maxBytes: Int = 512 * 1024): ByteArray

    fun thumbBytes(url: String, maxBytes: Int = 3 * 1024 * 1024): ByteArray

    fun ping(): Boolean
}

/** 按 provider 造一个客户端。 */
object DriveClients {
    fun create(provider: String, store: CredStore): DriveClient =
        if (provider == DriveProviders.BAIDU) {
            com.cloudcine.tv.pan.baidu.BaiduApi(store)
        } else {
            PanApi(store)
        }
}
