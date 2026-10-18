package com.cloudcine.tv.pan.baidu

import android.util.Log
import com.cloudcine.tv.pan.CredStore
import com.cloudcine.tv.pan.DriveClient
import com.cloudcine.tv.pan.DriveEntry
import com.cloudcine.tv.pan.DriveException
import com.cloudcine.tv.pan.DriveProviders
import com.cloudcine.tv.pan.PlayInfo
import com.cloudcine.tv.pan.Quality
import java.util.Collections

/**
 * 百度网盘**自用接口**客户端（TV 端）。
 *
 * 逐条对齐 PC 端 `lib/data/remote/baidu/baidu_adapter.dart` 的能力面：
 * 列目录、取链（三条路由降级 + 按 category 分流快/慢通道）、读小文件、
 * 取缩略图、探活。**备份 / 上传那套没有移植**（电视端不写网盘，见
 * `LibraryBackupService` 的类文档）。
 *
 * ## 取链路由阶梯（与 PC 逐条同源）
 *
 * | # | 路由 | 收什么 | 说明 |
 * |---|---|---|---|
 * | ① | `/rest/2.0/xpan/multimedia?method=filemetas&dlink=1` | `fsids` | 只收手里就有的 `fs_id` |
 * | ② | `/api/filemetas?target=[path]&dlink=1&web=5` | 路径 | **按 `category` 分流** `origin=dlna` |
 * | ③ | `/api/batch/streaming?check_blue=1&type=<档位>` | 路径 | 清晰度梯度的唯一来源 |
 *
 * ①② 取**原画**，③ 取**转码档**；三者「同时需要」而非依次备选。
 * 短路规则：授权失效（`needsReauth`）与文件不存在（`notFound`）**立即上抛** ——
 * 换接口结果一样，再打只是白费一次取链配额。
 *
 * ## ⛔ 通道分流（PC 端三轮实测，别重新试）
 *
 * | 取链时 `origin` | 直链带 `vuk` | 视频 | 音频 | 文档 | 单连接吞吐 |
 * |---|---|---|---|---|---|
 * | `dlna` | 是 | 206 | 206 | `403 31329` | **1.0~2.9 MB/s** |
 * | 不带 | 否 | 206 | 206 | 206 | ~80 KB/s（账号级限速） |
 *
 * 所以：媒体（`category` 1/2）走 dlna 快通道，其余走普通通道，普通通道
 * **必须单连接**（加连接不加吞吐）。TV 端把这条钉在 [Quality.maxConnections]。
 *
 * ## 路径缓存
 *
 * 百度的列目录 / 取链都收**路径**，而库里只有 `fs_id`。每次列目录都白捡
 * 一批 `fs_id → path`；播放页还会用 `dirPath + name` 预热（[primePath]），
 * 所以「重启后从最近播放直点开」不需要额外请求，也绕开了 xpan 的账号风控。
 */
class BaiduApi(
    /**
     * 取百度会话 Cookie 的**函数**。
     *
     * ⛔ 收函数而不是 `CredStore`：`CredStore` 依赖 `android.content.Context`，
     *    而 JVM 单测跑的是 `android.jar` 的空壳（`getSharedPreferences` 返回
     *    `null`）⇒ 拿不到一个能用的实例，整个类就没法测。本类对凭证的全部
     *    诉求只有「给我一串 Cookie」这一句，收成函数既够用又可测。
     */
    private val cookieSource: () -> String,
    private val http: BaiduHttpLike = BaiduHttpClient,
) : DriveClient {

    /** 生产用：从 [CredStore] 里读百度那一份。 */
    constructor(store: CredStore, http: BaiduHttpLike = BaiduHttpClient) :
        this({ store.cookie(DriveProviders.BAIDU) }, http)

    /** 百度业务错误。`needsReauth` 时上层应回登录页。 */
    class BaiduException(
        val errno: Int,
        message: String,
        needsReauth: Boolean = false,
        notFound: Boolean = false,
    ) : DriveException(message, needsReauth = needsReauth, notFound = notFound)

    override val providerId: String = DriveProviders.BAIDU
    override val rootId: String = BaiduEndpoints.ROOT_ID

    /**
     * `fs_id → path`。
     *
     * ⛔ 有上限：一次全盘扫描能列到几万个条目，无界缓存会吃掉几十 MB 堆
     * （这台电视只有 512 MB）。超限时**整批清掉**而不是 LRU —— 清掉之后
     * 还能靠 `dirPath + name` 预热 / xpan 翻译补回来，而 LRU 的记账成本
     * 比它省下的那点命中率更贵。
     */
    private val pathByFsId: MutableMap<String, String> =
        Collections.synchronizedMap(LinkedHashMap<String, String>())

    private var bdstoken: String? = null
    private var vipType: Int = BaiduVipType.NORMAL

    /** 撞过 9019 之后闩住 ①（风控是账号维度的，重复打不会放行）。 */
    private var xpanRiskControlled = false

    private fun cookieHeader(): String = cookieSource()

    val hasSession: Boolean get() = cookieHeader().isNotEmpty()

    /** 会员档位（决定要不要请求转码档；非 SVIP 只有 480P）。 */
    val currentVipType: Int get() = vipType

    // ------------------------------------------------------------------
    // 列目录
    // ------------------------------------------------------------------

    /**
     * 列一层目录。
     *
     * [idOrPath] 三种形态都认：`"/"`（根）、以 `/` 开头的**路径**、
     * 以及 `fs_id`（走路径缓存 / xpan 翻译）。返回顺序由服务端给
     * （`order=name`），排序由 UI 侧自己再做一次。
     */
    override fun listDirectory(idOrPath: String, page: Int, size: Int): List<DriveEntry> {
        val dirPath = resolvePath(idOrPath)
        val json = apiGet(
            BaiduEndpoints.LIST,
            linkedMapOf(
                "dir" to dirPath,
                "order" to "name",
                "desc" to "0",
                "page" to page.toString(),
                "num" to size.toString(),
                // 不显示空目录：媒体库扫描不需要它们。
                "showempty" to "0",
                // 让服务端顺带带上缩略图字段（`thumbs`）。
                "web" to "1",
            ),
            context = "列目录",
        )

        val items = BaiduMapper.listItemsOf(json)
        // ⭐ 白捡路径映射：列表项自带 `path`，这批子项下次被列时就能直接命中。
        rememberPaths(BaiduMapper.pathIndexOfJson(items))
        if (dirPath != BaiduEndpoints.ROOT_ID && idOrPath != BaiduEndpoints.ROOT_ID) {
            rememberPath(idOrPath, dirPath)
        }
        return BaiduMapper.toEntries(items)
    }

    /** 全盘搜索（递归）。⚠️ 百度没有「文件优先」开关，结果里混着目录。 */
    fun search(keyword: String, page: Int = 1, size: Int = 100): List<DriveEntry> {
        val trimmed = keyword.trim()
        if (trimmed.isEmpty()) return emptyList()
        val json = apiGet(
            BaiduEndpoints.SEARCH,
            linkedMapOf(
                "wd" to trimmed,
                "page" to page.toString(),
                "num" to size.toString(),
                "recursion" to "1",
                "web" to "1",
            ),
            context = "搜索",
        )
        val items = BaiduMapper.listItemsOf(json)
        rememberPaths(BaiduMapper.pathIndexOfJson(items))
        return BaiduMapper.toEntries(items)
    }

    // ------------------------------------------------------------------
    // 取链
    // ------------------------------------------------------------------

    override fun resolve(fileId: String, pathHint: String?): PlayInfo {
        if (!hasSession) {
            throw BaiduException(
                BaiduErrorCode.NOT_LOGGED_IN,
                "尚未授权百度网盘账号",
                needsReauth = true,
            )
        }
        if (!pathHint.isNullOrEmpty()) primePath(fileId, pathHint)

        val failures = ArrayList<String>(3)

        // ── ① 原画：fsid 路由（首选，只收手里就有的东西）──────────────
        var original: Ticket? = null
        if (xpanRiskControlled) {
            Log.i(TAG, "百度 xpan 处于账号风控中（9019），跳过 fsid 路由，直接走 /api/ 路由")
        } else {
            original = attempt("xpan_filemetas", failures) { resolveOriginalViaFsid(fileId) }
        }

        // ── ② 原画兜底：路径路由（按 category 分流快/慢通道）──────────
        if (original == null) {
            original = attempt("web_filemetas", failures) { resolveOriginalViaPath(fileId) }
        }

        // ── ③ 转码档：清晰度菜单的唯一来源（拿不到不算失败）────────────
        // ⛔ 把**原画那边量到的时长**带下去：转码流与原文件时长相同，而
        //    `batch/streaming` 的响应里常常没有 `duration`。缺了它，转码档
        //    的 `requiredMbPerSec` 就是 0（=「不需要带宽」），自动选档会无脑
        //    挑它 —— 看起来像「画质总是被降到 480P」。
        //
        // ⛔⛔ 这一档**任何**失败都不能拖垮整次取链（`needsReauth` 除外）：
        //    `attempt` 对 `notFound` 是「立即上抛」的 —— 那条规则是给
        //    「文件本身」的两条路由定的，而 `/api/batch/streaming` 回 404 只
        //    意味着「这个账号/这个文件没有转码档」。照抄会让「原画明明已经
        //    取到了」的片子直接报「文件不存在」。
        val fileDurationMs = original?.durationMs ?: 0L
        val ladder = try {
            attempt("batch_streaming", failures) { resolveLadder(fileId, fileDurationMs) }
        } catch (e: BaiduException) {
            if (e.needsReauth) throw e
            Log.w(TAG, "百度转码档不可用（原画仍可播）：${e.message}")
            failures.add("batch_streaming: ${e.message}")
            null
        }

        if (original == null && ladder == null) {
            Log.e(TAG, "百度全部取链路由失败：${failures.joinToString(" | ")}")
            if (xpanRiskControlled) {
                throw BaiduException(
                    BaiduErrorCode.RISK_CONTROL,
                    "取链失败：百度账号触发安全验证（风控），请先到 pan.baidu.com 网页版完成验证后再试",
                )
            }
            throw BaiduException(
                -1,
                "取链失败，无法播放该文件。最后一条错误：${failures.lastOrNull() ?: "无"}",
            )
        }

        // 原画永远排最前（调用方没指定档位时自然选中它）。
        val qualities = ArrayList<Quality>(2)
        original?.let {
            qualities.add(
                Quality(
                    id = ORIGINAL_QUALITY_ID,
                    label = "原画",
                    width = 0,
                    height = 0,
                    bitrateKbps = 0,
                    sizeBytes = it.contentLength ?: 0L,
                    url = it.url,
                    isOriginal = true,
                    durationMs = it.durationMs,
                    headers = it.headers,
                    maxConnections = it.maxConnections,
                ),
            )
        }
        ladder?.let { qualities.add(it) }

        val name = pathByFsId[fileId]?.substringAfterLast('/').orEmpty()
        Log.i(
            TAG,
            "百度取链成功：${qualities.size} 档（原画=${original != null}，" +
                "转码档=${if (ladder == null) "无" else ladder.label}），" +
                "时长=${fileDurationMs / 1000}s，失败路由=${failures.size}",
        )
        return PlayInfo(
            fileName = name,
            durationMs = fileDurationMs,
            defaultQualityId = qualities.first().id,
            qualities = qualities,
        )
    }

    /** 一次取链的结果（原画 / 转码档共用）。 */
    private class Ticket(
        val url: String,
        val headers: Map<String, String>,
        val contentLength: Long? = null,
        val maxConnections: Int = 1,
        /** 文件时长（毫秒）；`0` = 服务端没给。见 [BaiduMapper.durationMsOf]。 */
        val durationMs: Long = 0L,
    )

    /** ① 原画（fsid 路由）。 */
    private fun resolveOriginalViaFsid(fileId: String): Ticket? {
        val json = apiGet(
            BaiduEndpoints.XPAN_MULTIMEDIA,
            linkedMapOf(
                "method" to "filemetas",
                "fsids" to "[$fileId]",
                "dlink" to "1",
                "thumb" to "0",
            ),
            context = "取原画直链",
        )
        // 顺手回填路径缓存 —— filemetas 的响应里带 `path`。
        rememberPaths(BaiduMapper.parsePathIndex(json))
        val url = BaiduMapper.parseDlink(json) ?: return null
        return Ticket(
            url = url,
            headers = BaiduMapper.dlinkHeaders(cookieHeader()),
            contentLength = BaiduMapper.contentLengthOf(json),
            maxConnections = FAST_CHANNEL_CONNECTIONS,
            durationMs = BaiduMapper.durationMsOf(json) ?: 0L,
        )
    }

    /** ② 原画兜底（路径路由）。 */
    private fun resolveOriginalViaPath(fileId: String): Ticket? {
        val path = pathOf(fileId) ?: return null
        // ── 第一取：按**快通道**取（媒体一次往返就拿到）──────────────
        val fast = filemetasOf(path, BaiduEndpoints.DLNA_ORIGIN)
        val category = fast?.let { BaiduMapper.categoryOf(it) }
        if (fast != null && BaiduEndpoints.canUseDlna(category)) {
            Log.d(TAG, "百度走 dlna 快通道（category=$category）")
            return ticketFrom(fast, maxConnections = FAST_CHANNEL_CONNECTIONS)
        }

        // ── 非媒体：dlna 直链会被 CDN 拒（403 31329），去掉 origin 重取 ──
        try {
            val plain = filemetasOf(path, null)
            if (plain != null) {
                Log.d(TAG, "百度走普通通道（category=${BaiduMapper.categoryOf(plain)}，单连接）")
                return ticketFrom(plain, maxConnections = SLOW_CHANNEL_CONNECTIONS)
            }
        } catch (e: BaiduException) {
            if (e.needsReauth || e.notFound) throw e
            Log.w(TAG, "百度去掉 origin 重取失败，退回 dlna 直链：${e.message}")
        }

        // 重取失败：退回第一取的地址（媒体被误判成非媒体时唯一还能试一把的机会）。
        if (fast == null) return null
        Log.w(TAG, "百度普通通道不可用，退回 dlna 直链（可能只服务媒体）")
        return ticketFrom(fast, maxConnections = FAST_CHANNEL_CONNECTIONS)
    }

    /** 打一次 `/api/filemetas`；响应里没有可用直链时返回 `null`。 */
    private fun filemetasOf(path: String, origin: String?): Map<String, Any?>? {
        val params = linkedMapOf(
            // ⛔ 必须是 **JSON 数组字符串**（`["\/电影\/a.mkv"]`），不是裸路径。
            "target" to jsonArrayOf(path),
            "dlink" to "1",
            "web" to "5",
        )
        if (!origin.isNullOrEmpty()) params["origin"] = origin
        val json = apiGet(BaiduEndpoints.FILEMETAS, params, context = "取原画直链（路径路由）")
        if (BaiduMapper.parseDlink(json) == null) return null
        return json
    }

    private fun ticketFrom(json: Map<String, Any?>, maxConnections: Int): Ticket? {
        val url = BaiduMapper.parseDlink(json) ?: return null
        return Ticket(
            url = url,
            headers = BaiduMapper.dlinkHeaders(cookieHeader()),
            contentLength = BaiduMapper.contentLengthOf(json),
            maxConnections = maxConnections,
            durationMs = BaiduMapper.durationMsOf(json) ?: 0L,
        )
    }

    /**
     * ③ 转码档。
     *
     * ⛔ 只探**一档**（账号默认档）：客户端是逐档调的，枚举 7 档要打 7 次
     * 请求，而取链限流是 1 QPS ⇒ 起播前先等 7 秒。
     *
     * @param fileDurationMs 原画那边量到的时长（转码流与它相同）。`0` = 不知道。
     */
    private fun resolveLadder(fileId: String, fileDurationMs: Long): Quality? {
        val path = pathOf(fileId) ?: run {
            Log.d(TAG, "百度转码档跳过：路径未知（fs_id=$fileId）")
            return null
        }
        val type = BaiduResolution.defaultFor(vipType)
        val json = apiGet(
            BaiduEndpoints.BATCH_STREAMING,
            linkedMapOf(
                "check_blue" to "1",
                "type" to type.toString(),
                "path" to jsonArrayOf(path),
            ),
            context = "取转码档直链",
        )
        val url = BaiduMapper.parseDlink(json) ?: run {
            // 端点通了但响应里没有地址：只是「这一档拿不到」，原画仍可播。
            Log.d(TAG, "百度转码档响应里没有可用地址（type=$type）")
            return null
        }
        return Quality(
            id = BaiduResolution.idFor(type),
            label = BaiduResolution.labelFor(type),
            width = 0,
            height = BaiduResolution.heightFor(type) ?: 0,
            bitrateKbps = 0,
            // 转码档的体积响应里有时给、有时不给。给了才有「需 x MB/s」可算。
            sizeBytes = BaiduMapper.contentLengthOf(json) ?: 0L,
            url = url,
            isOriginal = false,
            durationMs = fileDurationMs,
            headers = BaiduMapper.dlinkHeaders(cookieHeader()),
            // 转码档走客户端 CDN：单连接保守起步（多连接对百度没有实测收益）。
            maxConnections = SLOW_CHANNEL_CONNECTIONS,
        )
    }

    // ------------------------------------------------------------------
    // 小文件 / 图片 / 账号
    // ------------------------------------------------------------------

    override fun fileBytesUrl(fileId: String): String {
        val path = pathOf(fileId)
            ?: throw BaiduException(-1, "找不到文件的路径（fs_id=$fileId）", notFound = true)
        // 字幕不是媒体 ⇒ 不带 origin（dlna 通道对它回 403 31329）。
        val json = apiGet(
            BaiduEndpoints.FILEMETAS,
            linkedMapOf(
                "target" to jsonArrayOf(path),
                "dlink" to "1",
                "web" to "5",
            ),
            context = "取文件地址",
        )
        return BaiduMapper.parseDlink(json)
            ?: throw BaiduException(-1, "服务端没给出文件地址（fs_id=$fileId）")
    }

    override fun readFileBytes(fileId: String, maxBytes: Int): ByteArray {
        val url = fileBytesUrl(fileId)
        val bytes = http.getBytes(
            url = url,
            headers = BaiduMapper.dlinkHeaders(cookieHeader()),
            maxBytes = maxBytes,
        )
        if (bytes.size > maxBytes) {
            throw BaiduException(-1, "文件实际大小 ${bytes.size} 超过读取上限 $maxBytes")
        }
        return bytes
    }

    override fun thumbBytes(url: String, maxBytes: Int): ByteArray =
        http.getBytes(url = url, headers = panHeaders(), maxBytes = maxBytes)

    override fun ping(): Boolean = runCatching {
        val json = apiGet(BaiduEndpoints.ACCOUNT_UINFO, null, context = "探活")
        json != null
    }.getOrDefault(false)

    /** 账号昵称（纯装饰，失败不抛）。顺带把 `vipType` 读进来。 */
    fun fetchNickname(): String? = runCatching {
        val json = apiGet(BaiduEndpoints.ACCOUNT_UINFO, null, context = "获取账号信息") ?: return null
        vipType = BaiduMapper.parseVipType(json)
        BaiduMapper.nicknameOf(json)
    }.getOrNull()

    /** 预热 `fs_id → path`（播放页从 `dirPath + name` 拼出来，省一次翻译请求）。 */
    fun primePath(fileId: String, path: String) {
        if (fileId.isEmpty() || !path.startsWith("/")) return
        rememberPath(fileId, path)
        Log.d(TAG, "百度路径缓存预热：fs_id=$fileId → $path")
    }

    // ------------------------------------------------------------------
    // 路径
    // ------------------------------------------------------------------

    /** 把 `fs_id` / 路径 / 根标识统一成**路径**。 */
    private fun resolvePath(idOrPath: String): String {
        if (idOrPath.isEmpty() || idOrPath == BaiduEndpoints.ROOT_ID) return BaiduEndpoints.ROOT_ID
        if (idOrPath.startsWith("/")) return idOrPath
        return pathOf(idOrPath) ?: throw BaiduException(
            BaiduErrorCode.FILE_NOT_EXIST,
            "找不到目录的路径（fs_id=$idOrPath）",
            notFound = true,
        )
    }

    /** 取路径：缓存优先，未命中才打一次 `filemetas`（`dlink=0`）。 */
    private fun pathOf(fsId: String): String? {
        if (fsId.isEmpty() || fsId == BaiduEndpoints.ROOT_ID) return BaiduEndpoints.ROOT_ID
        if (fsId.startsWith("/")) return fsId
        pathByFsId[fsId]?.takeIf { it.isNotEmpty() }?.let { return it }

        Log.d(TAG, "百度路径缓存未命中，查询 fs_id=$fsId")
        val json = try {
            apiGet(
                BaiduEndpoints.XPAN_MULTIMEDIA,
                linkedMapOf(
                    "method" to "filemetas",
                    "fsids" to "[$fsId]",
                    "dlink" to "0",
                    "thumb" to "0",
                ),
                context = "解析路径",
            )
        } catch (e: BaiduException) {
            if (e.needsReauth || e.notFound) throw e
            Log.w(TAG, "百度路径翻译失败（fs_id=$fsId）：${e.message}")
            return null
        }
        val index = BaiduMapper.parsePathIndex(json)
        rememberPaths(index)
        return index[fsId]?.takeIf { it.isNotEmpty() }
    }

    private fun rememberPath(fsId: String, path: String) {
        if (fsId.isEmpty() || path.isEmpty()) return
        if (pathByFsId.size >= MAX_PATH_CACHE) {
            // 整批清掉而不是 LRU：见 `pathByFsId` 的文档。
            pathByFsId.clear()
        }
        pathByFsId[fsId] = path
    }

    private fun rememberPaths(index: Map<String, String>) {
        for ((k, v) in index) rememberPath(k, v)
    }

    // ------------------------------------------------------------------
    // 请求管线
    // ------------------------------------------------------------------

    /**
     * 打一条 `/api/…`。
     *
     * `-6` 会**自愈一次**：百度把「缺 `bdstoken`」和「凭证真的废了」都报成
     * `-6`，前者补一次令牌再打就好。⛔ 只重试一次（防递归）。
     */
    private fun apiGet(
        path: String,
        params: Map<String, String>?,
        context: String,
        allowBdstokenRetry: Boolean = true,
        withBdstoken: Boolean = true,
    ): Map<String, Any?>? {
        if (!hasSession) {
            throw BaiduException(
                BaiduErrorCode.NOT_LOGGED_IN,
                "$context：尚未授权百度网盘账号",
                needsReauth = true,
            )
        }
        val query = LinkedHashMap<String, String>()
        query.putAll(BaiduEndpoints.COMMON_PARAMS)
        val token = bdstoken
        if (withBdstoken && !token.isNullOrEmpty()) query["bdstoken"] = token
        params?.let { query.putAll(it) }

        val res = http.get(
            url = BaiduEndpoints.PAN_HOST + path,
            query = query,
            headers = panHeaders(),
        )
        val errno = res.errno
        if (res.status in 200..299 && errno == BaiduErrorCode.OK) return res.json

        val e = exceptionFrom(res, context)
        Log.e(
            TAG,
            "百度$context 失败：errno=$errno http=${res.status} " +
                "show_msg=${res.showMsg.ifEmpty { "—" }} body=${res.body.take(200)}",
        )
        if (allowBdstokenRetry && e.needsReauth && bdstoken.isNullOrEmpty()) {
            val fresh = ensureBdstoken()
            if (!fresh.isNullOrEmpty()) {
                Log.i(TAG, "百度补上 bdstoken 后重试$context")
                return apiGet(path, params, context, allowBdstokenRetry = false, withBdstoken = withBdstoken)
            }
        }
        throw e
    }

    /**
     * 取（并缓存）`bdstoken`。两条来源都试；都失败返回 `null`（不带令牌继续）。
     *
     * ## ⛔ 两个参数缺一不可
     *
     * - `withBdstoken = false`：正在取它，带上必然是空的。
     * - `allowBdstokenRetry = false`：**取令牌本身不能再触发取令牌**。只传前
     *   一个的话，凭证真的废了时 `/api/gettemplatevariable` 也回 `-6`，
     *   于是 `apiGet` 又进 `ensureBdstoken()` —— 无限递归。2026-10-17 在
     *   模拟器上实测到过：一次扫描打出 **251 条**「取 bdstoken 失败」，
     *   每条都要走完两次 HTTP，等于拿电视的 CPU 打空转（PC 端没有这个坑，
     *   因为它的 `_get` 直接绕过重试管线）。
     */
    private fun ensureBdstoken(): String? {
        bdstoken?.takeIf { it.isNotEmpty() }?.let { return it }
        for (path in listOf(BaiduEndpoints.GET_TEMPLATE_VARIABLE, BaiduEndpoints.GET_TEMPLATE)) {
            val token = try {
                val json = apiGet(
                    path,
                    linkedMapOf("fields" to BaiduEndpoints.TEMPLATE_FIELDS),
                    context = "取 bdstoken",
                    allowBdstokenRetry = false,
                    withBdstoken = false,
                )
                BaiduMapper.bdstokenOf(json)
            } catch (e: BaiduException) {
                Log.w(TAG, "百度 $path 取 bdstoken 失败：${e.message}")
                null
            }
            if (!token.isNullOrEmpty()) {
                bdstoken = token
                Log.i(TAG, "百度已取到 bdstoken（来源 $path）")
                return token
            }
        }
        return null
    }

    /**
     * 网盘 API 的公共请求头。
     *
     * ⚠️ `Origin` 不能省：百度 WAF 可能把没有它的 `/api/…` 请求当成非网页
     * 来源，拒绝在业务层看起来就是 `errno=-6`（与「凭证废了」同码）。
     */
    private fun panHeaders(): Map<String, String> {
        val out = linkedMapOf(
            "User-Agent" to BaiduEndpoints.USER_AGENT,
            "Accept" to BaiduEndpoints.ACCEPT,
            "Accept-Language" to BaiduEndpoints.ACCEPT_LANGUAGE,
            "Referer" to BaiduEndpoints.REFERER,
            "Origin" to BaiduEndpoints.ORIGIN,
        )
        val cookie = cookieHeader()
        if (cookie.isNotEmpty()) out["Cookie"] = cookie
        return out
    }

    /** 试一条取链路径。失败记进 [failures] 并返回 `null`。 */
    private fun <T> attempt(id: String, failures: MutableList<String>, run: () -> T?): T? = try {
        run() ?: run {
            failures.add("$id: 响应里没有可用地址")
            null
        }
    } catch (e: BaiduException) {
        if (e.needsReauth || e.notFound) {
            Log.e(TAG, "百度 $id 失败且不可降级，直接放弃：${e.message}")
            throw e
        }
        if (e.errno == BaiduErrorCode.RISK_CONTROL) xpanRiskControlled = true
        failures.add("$id: ${e.message}")
        Log.w(TAG, "百度 $id 失败，其他路由仍可独立工作：${e.message}")
        null
    }

    private fun exceptionFrom(res: BaiduResponse, context: String): BaiduException {
        if (res.status == 401 || res.status == 403) {
            return BaiduException(-1, "$context：凭证无效或没有权限（HTTP ${res.status}）", needsReauth = true)
        }
        if (res.status == 404) {
            return BaiduException(-1, "$context：文件不存在（HTTP 404）", notFound = true)
        }
        val errno = res.errno
        val raw = res.showMsg.ifEmpty { "errno=$errno" }
        return when (errno) {
            BaiduErrorCode.NOT_LOGGED_IN -> BaiduException(
                errno, "$context：登录状态无效（$raw）", needsReauth = true,
            )
            BaiduErrorCode.FILE_NOT_FOUND,
            BaiduErrorCode.FILE_NOT_EXIST,
            BaiduErrorCode.DIR_NOT_EXIST,
            -> BaiduException(errno, "$context：文件或目录不存在（$raw）", notFound = true)
            BaiduErrorCode.RISK_CONTROL -> BaiduException(errno, "$context：账号触发风控（$raw）")
            BaiduErrorCode.NEED_VERIFY -> BaiduException(errno, "$context：需要安全验证（$raw）")
            else -> BaiduException(errno, "$context：$raw")
        }
    }

    /** 把一条路径编码成百度要求的 **JSON 数组字符串**（`["\/a.mkv"]`）。 */
    private fun jsonArrayOf(path: String): String {
        val escaped = path.replace("\\", "\\\\").replace("\"", "\\\"")
        return "[\"$escaped\"]"
    }

    companion object {
        private const val TAG = "CloudCine"

        /** 原画档的稳定 id —— 与 PC 端 `kOriginalQualityId` 逐字一致。 */
        const val ORIGINAL_QUALITY_ID = "origin"

        /** dlna 快通道的连接数（单连接就能跑满，多开没有实测收益）。 */
        const val FAST_CHANNEL_CONNECTIONS = 1

        /** 普通通道**必须**单连接：限速是账号级的，加连接不加吞吐。 */
        const val SLOW_CHANNEL_CONNECTIONS = 1

        /** 路径缓存上限（条目数）。超限整批清掉，见 `pathByFsId`。 */
        private const val MAX_PATH_CACHE = 20_000
    }
}
