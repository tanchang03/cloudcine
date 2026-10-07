package com.cloudcine.tv.pan

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * 网盘 PC 自用接口（`drive-pc.quark.cn`，靠网页登录态 Cookie 鉴权）。
 *
 * ⛔ **不是**官方开放平台 `open-api-drive.quark.cn` —— 那套要 OAuth
 * `access_token`，两者不可混用。
 *
 * ## 所有请求都必须带 `pr=ucpro&fr=pc`
 *
 * 实测：漏掉公共参数时 `batch/file/play/info` 直接回
 * `HTTP 401 code=31001 require login [guest]` —— 看起来像「没登录」，
 * 实际是「请求缺参数，服务端把你当游客」。这条在 Mac 侧探针上踩过一次。
 *
 * ## `__puus` 是直链的硬门槛（实测）
 *
 * 同一条已签名的 CDN 直链，四种 Cookie 组合的结果：
 *
 * | 请求带的 Cookie | 结果 |
 * |---|---|
 * | 最新 `__puus` | **206** |
 * | 陈旧 `__puus` | **206**（陈旧也行） |
 * | 有 `__pus` 等会话 Cookie，**缺** `__puus` | **412** |
 * | 完全不带 Cookie | **206** |
 *
 * 即「要么不带 Cookie，要么必须带 `__puus`」。**带一半是最坏的**：
 * 服务端认得你是登录用户，却过不了防重放校验，于是 412 ——
 * 表现是「列表能刷、一播就转圈」。所以本类在每个响应后都回填
 * `Set-Cookie` 里的 `__puus`（[absorbCookies]）。
 */
class PanApi(private val store: CredStore) {

    /** 网盘业务错误。`needsReauth` 时上层应回登录页。 */
    class ApiException(
        val code: Int,
        override val message: String,
        val needsReauth: Boolean = false,
    ) : Exception(message)

    // ------------------------------------------------------------------
    // 列目录
    // ------------------------------------------------------------------

    /**
     * 列一层目录。`fid` 为 `"0"` 表示根。
     *
     * ⛔ `_size` 别开太大：服务端对每页条数有上限，超了不报错、只是返回条数变少，
     * 表现为「有些文件看不到」。100 是实测稳的值。
     */
    fun listDirectory(fid: String, page: Int = 1, size: Int = 100): List<DriveEntry> {
        val res = PanHttp.get(
            url = "$PC$PATH_FILE_SORT",
            query = commonQuery() + mapOf(
                "pdir_fid" to if (fid.isEmpty()) ROOT else fid,
                "_page" to "$page",
                "_size" to "$size",
                "_fetch_total" to "1",
                // 目录优先、更新时间倒序。服务端用 `file_type:asc` 表示目录在前。
                "_sort" to "file_type:asc,updated_at:desc",
                "_is_hl" to "1",
            ),
            cookie = store.requestCookie(),
        )
        absorbCookies(res)
        ensureOk(res, "列目录")

        val list = res.dataList ?: return emptyList()
        val out = ArrayList<DriveEntry>(list.length())
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            val name = o.optString("file_name").ifEmpty { o.optString("file_name_display") }
            if (name.isEmpty()) continue
            // ⛔ 先判目录再取文件字段：目录上这些字段要么缺失、要么是垃圾值
            //    （`video_width=0`），照抄下去会让分辨率归挡算出一个荒唐的档位。
            val dir = isDir(o)
            out.add(
                DriveEntry(
                    fid = o.optString("fid").ifEmpty { o.optString("id") },
                    name = name,
                    isDir = dir,
                    sizeBytes = o.optLong("size", 0L),
                    updatedAtMs = normalizeTimestamp(o.optLong("updated_at", 0L)),
                    parentId = o.optString("pdir_fid").ifEmpty { null },
                    previewUrl = if (dir) null else o.optString("preview_url").ifEmpty { null },
                    videoWidth = if (dir) null else positive(o.optInt("video_width", 0)),
                    videoHeight = if (dir) null else positive(o.optInt("video_height", 0)),
                    // 夸克 `duration` 下发的是**秒**（PC 端 `parseDurationMs` 同口径）。
                    durationMs = if (dir) null else secondsToMs(o.optLong("duration", 0L)),
                ),
            )
        }
        return out
    }

    /**
     * 取**任意文件**的原始字节地址 —— 外挂字幕走这条。
     *
     * ⛔ 用 `file/audioplay` 而**不是** `file/download`。两者都返回原文件本身，
     *    但 `file/download` 单文件超过约 50 MiB 直接回 `code=23018`
     *    （见 `lib/domain/services/drive_download.dart` 的实测记录），
     *    而 `audioplay` 实测**对任意 fid 都返回原文件本身**且不限体积 ——
     *    连被服务端判成 `text/plain` 的文件也照原样给字节。
     *    字幕虽然小，但「用哪条路由」这件事只该有一个答案。
     *
     * ⛔ 返回的是**带签名的临时地址**，别缓存、别复用；每次要用现取。
     */
    fun fileBytesUrl(fid: String): String {
        val res = PanHttp.get(
            url = "$PC$PATH_AUDIOPLAY",
            query = commonQuery() + mapOf("fid" to fid),
            cookie = store.requestCookie(),
        )
        absorbCookies(res)
        ensureOk(res, "取文件地址")
        val url = res.data?.optString("audio_url").orEmpty()
        if (url.isEmpty()) throw ApiException(-1, "服务端没给出文件地址（fid=$fid）")
        return url
    }

    /** 用户信息，只在标题栏显示昵称。失败不抛 —— 它纯装饰。 */
    fun fetchNickname(): String? = runCatching {
        val res = PanHttp.get("$PC$PATH_MEMBER", commonQuery(), store.requestCookie())
        absorbCookies(res)
        res.data?.optString("nickname")?.takeIf { it.isNotEmpty() }
    }.getOrNull()

    /** 最轻量的连通性探测。用来判断「凭证还在不在」。 */
    fun ping(): Boolean = runCatching {
        val res = PanHttp.get("$PC$PATH_CONFIG", commonQuery(), store.requestCookie())
        absorbCookies(res)
        res.isOk
    }.getOrDefault(false)

    // ------------------------------------------------------------------
    // 取链
    // ------------------------------------------------------------------

    /**
     * 取一次起播需要的全部流：**转码阶梯 + 原画**。
     *
     * 两条来源是**并列**的、不是备选：
     *   - `batch/file/play/info` → `video_list[]`，转码阶梯，**唯一能拿到档位列表的路由**；
     *   - `file/audioplay` → 原文件本身，**不受 50 MiB 限制**（`file/download` 会 23018）。
     *
     * ⛔ 解析 `video_list` 时**必须跳过 `audio_list`**：那条是纯音频流
     * （`dolby_eac3`），没有分辨率字段，很容易被当成「原画」——
     * 而原画永远排最前，于是默认播了一条**没有视频轨**的流：
     * 有声音、进度条在走、**没有画面、不报任何错**。云影踩过这个坑。
     */
    fun resolve(fid: String): PlayInfo {
        val info = fetchPlayInfo(fid)
        val original = fetchOriginal(fid)

        val qualities = ArrayList<Quality>()
        original?.let { qualities.add(it) }
        qualities.addAll(info.second)
        if (qualities.isEmpty()) {
            throw ApiException(-1, "服务端没给出任何可用地址（转码档与原画都是空的）")
        }

        // 原画在最前；其余按分辨率降序（高的在前）。
        val sorted = qualities.sortedWith(
            compareByDescending<Quality> { it.isOriginal }
                .thenByDescending { it.height }
                .thenByDescending { it.bitrateKbps },
        )
        return PlayInfo(
            fileName = info.first,
            durationMs = info.third,
            defaultQualityId = original?.let { if (info.second.isEmpty()) ORIGIN else info.fourth }
                ?: info.fourth,
            qualities = sorted,
        )
    }

    /**
     * @return `(文件名, 转码档列表, 时长ms, 服务端默认档位)`
     */
    private fun fetchPlayInfo(fid: String): Quad<String, List<Quality>, Long, String> {
        val body = JSONObject().apply {
            // 照抄客户端：`resolutions` 声明梯度，顺序从低到高。
            // 少了 `fetch_play_video_resolution_setting` 等开关，响应会变瘦、
            // 档位列表就是空的。
            put("resolutions", RESOLUTION_TIERS)
            put("fetch_credits_setting", 1)
            put("fetch_play_video_resolution_setting", 1)
            put("fetch_play_audio_type_setting", 1)
            put("support_resolution_free_limit_ab", 1)
            put("fetch_pdir", 1)
            put("support_right", "trial_1080P_zhizhen_pc")
            put("supports", "")
            put("fids", JSONArray().put(fid))
        }
        val res = PanHttp.postJson(
            url = "$PC$PATH_PLAY_INFO",
            query = commonQuery() + mapOf("uc_param_str" to "utfrpr"),
            body = body,
            cookie = store.requestCookie(),
        )
        absorbCookies(res)
        ensureOk(res, "取播放信息")

        val node = pickNode(res.data, fid) ?: return Quad("", emptyList(), 0L, "")
        val fileName = node.optString("file_name")
        val durationMs = node.optJSONObject("meta")?.optLong("duration", 0L)
            ?.times(1000L) ?: 0L

        val out = ArrayList<Quality>()
        val list = node.optJSONArray("video_list")
        if (list != null) {
            for (i in 0 until list.length()) {
                val item = list.optJSONObject(i) ?: continue
                val info = item.optJSONObject("video_info") ?: continue
                val url = info.optString("url")
                if (url.isEmpty()) continue
                // ⛔ 只认 `video_list`；`audio_list` 已在 pickNode 之外被排除。
                val id = item.optString("resolution").ifEmpty { info.optString("resolution") }
                if (id.isEmpty()) continue
                out.add(
                    Quality(
                        id = id,
                        label = tierLabel(id),
                        width = info.optInt("width"),
                        height = info.optInt("height"),
                        bitrateKbps = info.optInt("bitrate"),
                        sizeBytes = info.optLong("size", 0L),
                        url = url,
                        isOriginal = false,
                        durationMs = info.optLong("duration", 0L) * 1000L,
                    ),
                )
            }
        }
        Log.i(TAG, "play/info 档位=${out.joinToString { "${it.id}(${it.width}x${it.height},${it.bitrateKbps}kbps,${it.requiredMbPerSec}MB/s)" }}")
        return Quad(fileName, out, durationMs, node.optString("default_resolution"))
    }

    /** 原画：`file/audioplay` 返回的是**原文件本身**（名字叫 audio，视频照样给）。 */
    private fun fetchOriginal(fid: String): Quality? {
        val res = runCatching {
            PanHttp.get(
                url = "$PC$PATH_AUDIOPLAY",
                query = commonQuery() + mapOf("fid" to fid),
                cookie = store.requestCookie(),
            )
        }.getOrNull() ?: return null
        absorbCookies(res)
        if (!res.isOk) {
            Log.w(TAG, "audioplay 失败 code=${res.code} ${res.message}（原画这一档不可用，不影响转码档）")
            return null
        }
        val d = res.data ?: return null
        val url = d.optString("audio_url")
        if (url.isEmpty()) return null
        val size = d.optLong("size", 0L)
        val durationMs = d.optLong("duration", 0L) * 1000L
        return Quality(
            id = ORIGIN,
            label = "原画",
            width = d.optInt("video_width"),
            height = d.optInt("video_height"),
            bitrateKbps = if (durationMs > 0) (size * 8 / durationMs).toInt() else 0,
            sizeBytes = size,
            url = url,
            isOriginal = true,
            durationMs = durationMs,
        )
    }

    // ------------------------------------------------------------------
    // 文件管理：建目录 / 删除 / 上传 / 下载
    //
    // 这一组是**媒体库备份互操作**的全部依赖：备份包要能被放进网盘的
    // 「云影备份」目录、被列出来、被下载回来。播放链路一条都不用它们。
    // ------------------------------------------------------------------

    /**
     * 在 `parentId` 下创建目录，返回它的 fid。
     *
     * 同名重复创建是**幂等**的（服务端返回已存在的那个 fid），所以调用方
     * 不必先查重 —— [ensureFolder] 之所以还是先列一次，是为了省掉一次写操作。
     */
    fun createFolder(parentId: String, name: String): String {
        val res = post(
            PATH_FILE_CREATE,
            JSONObject().apply {
                put("dir_init_lock", false)
                put("dir_path", "")
                put("file_name", name)
                put("pdir_fid", parentId.ifEmpty { ROOT })
            },
            "创建目录",
        )
        val fid = parseFid(res.data)
        if (fid.isEmpty()) throw ApiException(-1, "创建目录失败：响应中没有返回目录 ID")
        return fid
    }

    /**
     * 找一个**已存在**的子目录；不存在返回 `null`，**绝不创建**。
     *
     * ⛔ [ensureFolder] 会创建 —— 那个副作用对「上传 / 恢复」是对的，但
     *    **启动时的探测不能有**：用户还没备份过的时候，每开一次电视就往他
     *    网盘根目录里塞一个空的「云影备份」。探测是只读动作，只读就该无副作用。
     */
    fun findFolder(parentId: String, name: String): String? =
        listDirectory(parentId.ifEmpty { ROOT }, page = 1, size = 200)
            .firstOrNull { it.isDir && it.name == name }
            ?.fid

    /**
     * 确保 `parentId` 下存在名为 `name` 的目录，返回它的 fid。
     *
     * ⛔ 先列目录再建，而不是直接建：直接建也能work（幂等），但会在每次
     *    同步时都往网盘写一次 —— 而「只读的同步」不该有副作用。
     */
    fun ensureFolder(parentId: String, name: String): String =
        findFolder(parentId, name) ?: createFolder(parentId, name)

    /**
     * **永久**删除一批文件/目录（`action_type=2`）。
     *
     * ⚠️ 不可逆。调用方必须做 UI 二次确认。
     *
     * ## 返回值是**入参回显**，不是逐条核实的结果
     *
     * 夸克的删除响应只有信封（`code` / `message`），没有可读的逐条结果。
     * 所以这个列表的含义是「请求成功了几条」，**不是**「网盘上真的少了几条」。
     * 服务端在同一批里跳过某几个（无权限、已在回收站、fid 已失效）时，
     * 我们照旧报成功 —— 这个偏差**看不见**。
     *
     * ⛔ 别改成「删完立刻重列目录来核对」：删除在服务端未必立刻可见，
     *    刚删完就重列很可能仍然看得到，那会把成功报成失败 —— 比少报更糟。
     */
    fun deleteFiles(fileIds: List<String>): List<String> {
        if (fileIds.isEmpty()) return emptyList()
        post(
            PATH_FILE_DELETE,
            JSONObject().apply {
                put("action_type", 2) // 2 = 永久删除
                put("filelist", JSONArray(fileIds))
                put("exclude_fids", JSONArray())
            },
            "删除文件",
        )
        return fileIds
    }

    /**
     * 把一个文件**全部**读回来（下载备份包走这条）。
     *
     * ⛔ 走 `file/audioplay` 取的地址，**不是** `file/download` ——
     *    后者单文件超过约 50 MiB 直接回 `code=23018`，而备份包很容易超。
     *    理由与 [fileBytesUrl] 一字不差，只是那边是给字幕用的。
     *
     * ⛔ [maxBytes] 是**防呆**不是限制。这台电视只有 512 MB Java 堆，
     *    而这条路会把整个文件读进内存 —— 上限没兜住的话，
     *    表现不是「报错」而是 `OutOfMemoryError` 把进程带走。
     */
    fun fileBytes(fid: String, maxBytes: Int = MAX_DOWNLOAD_BYTES): ByteArray =
        PanHttp.getBytes(
            url = fileBytesUrl(fid),
            cookie = store.requestCookie(),
            maxBytes = maxBytes,
            timeoutMs = 60_000,
        )

    /**
     * 只取一个文件**开头**的若干字节。
     *
     * 备份包把清单放在最前面（`[magic][清单长度][清单][库][海报]`），
     * 所以「这份备份比本机新还是旧」这个问题，几十 KB 就能回答 ——
     * 不必把后面的海报段整个拉下来。见 [PanHttp.getBytesHead]。
     *
     * ⛔ 与 [fileBytes] 一样走 `file/audioplay` 现签的地址，并且**同样要把
     *    `Set-Cookie` 收回去**：夸克在每个响应里轮换 `__puus`，丢掉它下一次
     *    取链就可能 412（理由见 [absorbSetCookies]）。
     */
    fun fileHeadBytes(fid: String, maxBytes: Int = 64 * 1024): ByteArray {
        val res = PanHttp.getBytesHead(
            url = fileBytesUrl(fid),
            cookie = store.requestCookie(),
            maxBytes = maxBytes,
        )
        absorbSetCookies(res.setCookies)
        return res.bytes
    }

    /**
     * 上传一个文件到 `parentId`，返回新文件的 fid。
     *
     * ## 流程（与 PC 端 `QuarkAdapter.uploadFile` 逐步对齐）
     *
     * 1. `file/upload/pre` 预上传 —— 拿到 `task_id`、OSS 的
     *    `bucket` / `obj_key` / `upload_id` / `auth_info` / `callback`；
     * 2. `file/update/hash` 秒传判定 —— `data.finish == true` 就**直接结束**，
     *    一个字节都不用传（备份包在两端之间来回传时命中率很高）；
     * 3. 逐片取 `auth_key`（`file/upload/auth`）→ `PUT` 到 OSS → 收 ETag；
     * 4. **两步**收尾：OSS `CompleteMultipartUpload`（带 `x-oss-callback`）
     *    → `file/upload/finish`（body 只有 `task_id` + `obj_key`）。
     *
     * ⛔ 第 4 步的**两步缺一不可，顺序也不能反**。只调
     *    `file/upload/finish` 会得到
     *    `code=43001 request cpp error[complete file failed!]` ——
     *    服务端找不到可合并的对象。这一条在 PC 端是踩过的坑，
     *    `QuarkEndpoints.uploadFinish` 的注释里留着原话。
     *
     * ⛔ [onProgress] 在**调用线程**上回调（本类所有方法都是阻塞的，
     *    调用方负责放到 [Bg] 里）。别在回调里碰 View。
     */
    fun uploadFile(
        parentId: String,
        fileName: String,
        bytes: ByteArray,
        onProgress: ((sent: Int, total: Int) -> Unit)? = null,
    ): String {
        val size = bytes.size
        val nowMs = System.currentTimeMillis()
        val pdir = parentId.ifEmpty { ROOT }

        // ① 预上传
        val preData = post(
            PATH_UPLOAD_PRE,
            JSONObject().apply {
                put("ccp_hash_update", true)
                put("dir_name", "")
                put("file_name", fileName)
                put("format_type", "application/octet-stream")
                put("l_created_at", nowMs)
                put("l_updated_at", nowMs)
                put("pdir_fid", pdir)
                put("size", size)
            },
            "上传预请求",
        ).data ?: throw ApiException(-1, "上传预请求失败：响应中没有 data")

        val taskId = preData.optString("task_id")
        if (taskId.isEmpty()) throw ApiException(-1, "上传预请求失败：没有返回 task_id")

        // ② 秒传判定
        val hashData = post(
            PATH_UPLOAD_HASH,
            JSONObject().apply {
                put("md5", OssAuth.md5Hex(bytes))
                put("sha1", OssAuth.sha1Hex(bytes))
                put("task_id", taskId)
            },
            "秒传判定",
        ).data
        if (hashData != null && hashData.optBoolean("finish", false)) {
            val fid = parseFid(hashData)
            if (fid.isNotEmpty()) {
                Log.i(TAG, "上传：秒传命中「$fileName」→ fid=$fid")
                onProgress?.invoke(size, size)
                return fid
            }
        }

        // ③ 分片上传到 OSS
        val bucket = preData.optString("bucket")
        val objKey = preData.optString("obj_key")
        val uploadId = preData.optString("upload_id")
        val ossBase = OssAuth.ossBase(preData.optString("upload_url"), bucket, objKey)
        val authInfo = if (preData.has("auth_info")) preData.get("auth_info") else null

        val partSize = preData.optInt("part_size").takeIf { it > 0 }
            ?: preData.optJSONObject("metadata")?.optInt("part_size")?.takeIf { it > 0 }
            ?: DEFAULT_PART_SIZE

        // ⛔ 空文件也要传一片（`totalParts` 至少为 1），否则 OSS 那边
        //    一个分片都没有、合并必然失败。
        val totalParts = if (size == 0) 1 else (size + partSize - 1) / partSize
        Log.i(TAG, "上传：分片 $totalParts 片 × $partSize 字节（OSS: $bucket/$objKey）")

        val parts = ArrayList<OssAuth.Part>(totalParts)
        for (pn in 1..totalParts) {
            val from = (pn - 1) * partSize
            val to = minOf(from + partSize, size)
            val chunk = bytes.copyOfRange(from, to)

            val ts = OssAuth.ossTimestamp(System.currentTimeMillis())
            val authKey = post(
                PATH_UPLOAD_AUTH,
                JSONObject().apply {
                    put("auth_info", authInfo)
                    put("auth_meta", OssAuth.partAuthMeta(bucket, objKey, pn, uploadId, ts))
                    put("task_id", taskId)
                },
                "分片授权($pn/$totalParts)",
            ).data?.optString("auth_key").orEmpty()

            val res = PanHttp.putBytes(
                url = "$ossBase?partNumber=$pn&uploadId=$uploadId",
                body = chunk,
                headers = mapOf(
                    "Authorization" to authKey,
                    "Content-Type" to "application/octet-stream",
                    "x-oss-date" to ts,
                    "x-oss-user-agent" to OssAuth.OSS_USER_AGENT,
                ),
            )
            if (!res.isOk) {
                throw ApiException(-1, "分片 $pn/$totalParts 上传失败：HTTP ${res.status} ${res.brief()}")
            }
            val etag = OssAuth.stripEtagQuotes(res.header("ETag").orEmpty())
            if (etag.isEmpty()) {
                throw ApiException(-1, "分片 $pn/$totalParts 没有返回 ETag（缺了它无法合并）")
            }
            parts.add(OssAuth.Part(pn, etag))
            onProgress?.invoke(to, size)
        }

        // ④ 收尾（两步，缺一不可）
        return finishUpload(taskId, ossBase, bucket, objKey, uploadId, authInfo, preData, parts)
    }

    /**
     * 上传收尾。
     *
     * 拆出来只是为了让 [uploadFile] 的主干能一眼看完 —— 它**不是**可选步骤。
     */
    private fun finishUpload(
        taskId: String,
        ossBase: String,
        bucket: String,
        objKey: String,
        uploadId: String,
        authInfo: Any?,
        preData: JSONObject,
        parts: List<OssAuth.Part>,
    ): String {
        // ⛔ callback 是预上传响应里给的配置对象。**必须原样回填给 OSS** ——
        //    它决定 OSS 合并完成后回调夸克哪个地址去登记文件。缺了它
        //    `x-oss-callback` 头就没法构造，签名串也少一行。
        if (!preData.has("callback")) {
            throw ApiException(-1, "上传预请求没有返回 callback，无法完成 OSS 合并上传")
        }
        val callbackJson = preData.get("callback").toString()

        val xml = OssAuth.completeMultipartXml(parts)
        val xmlBytes = xml.toByteArray(Charsets.UTF_8)
        val contentMd5 = OssAuth.md5Base64(xmlBytes)
        val callbackBase64 = OssAuth.base64(callbackJson.toByteArray(Charsets.UTF_8))

        val ts = OssAuth.ossTimestamp(System.currentTimeMillis())
        val authKey = post(
            PATH_UPLOAD_AUTH,
            JSONObject().apply {
                put("auth_info", authInfo)
                put(
                    "auth_meta",
                    OssAuth.completeAuthMeta(bucket, objKey, uploadId, ts, contentMd5, callbackBase64),
                )
                put("task_id", taskId)
            },
            "完成上传授权",
        ).data?.optString("auth_key").orEmpty()

        // 5. POST XML 到 OSS —— 合并分片，并由 OSS 触发 callback
        val res = PanHttp.postBytes(
            url = "$ossBase?uploadId=$uploadId",
            body = xmlBytes,
            headers = mapOf(
                "Authorization" to authKey,
                "Content-MD5" to contentMd5,
                "Content-Type" to "application/xml",
                "x-oss-callback" to callbackBase64,
                "x-oss-date" to ts,
                "x-oss-user-agent" to OssAuth.OSS_USER_AGENT,
            ),
        )
        if (!res.isOk) {
            throw ApiException(-1, "OSS 合并分片失败：HTTP ${res.status} ${res.brief()}")
        }

        // 6. 通知夸克：把合并后的对象登记成文件
        val fid = parseFid(
            post(
                PATH_UPLOAD_FINISH,
                JSONObject().apply {
                    put("task_id", taskId)
                    put("obj_key", objKey)
                },
                "完成上传",
            ).data,
        )
        if (fid.isEmpty()) throw ApiException(-1, "完成上传响应中没有返回文件 ID")
        return fid
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    /**
     * 把响应里轮换的 `__puus` 回填进 [CredStore]。
     *
     * ⛔ 不能省。服务端在每个 API 响应的 `Set-Cookie` 里轮换下发 `__puus`，
     * 而直链要求「要么不带 Cookie，要么带 `__puus`」。少了它，列表能刷、
     * 一直播就 412。
     */
    private fun absorbCookies(res: PanResponse) = absorbSetCookies(res.setCookies)

    /**
     * 把响应里轮换下发的 `__puus` / `Video-Auth` 收回凭证库。
     *
     * ⛔ 与 [absorbCookies] 是同一件事，分成两层是因为**二进制响应**
     *    （网盘缩略图，见 [thumbBytes]）拿不到 `PanResponse`，只有原始
     *    `Set-Cookie` 行。两处各写一份的话，缩略图那条路会漏掉 `__puus`，
     *    而漏掉的后果不是「图片糊了」—— 是**下一次取链 412**，
     *    完全看不出和翻选集有什么关系。
     */
    private fun absorbSetCookies(setCookies: List<String>) {
        if (setCookies.isEmpty()) return
        val puus = cookieValueOf(setCookies, "__puus")
        if (!puus.isNullOrEmpty()) {
            val cur = store.cookie
            store.cookie = if (cur.contains("__puus=")) {
                cur.replace(Regex("__puus=[^;]*"), "__puus=$puus")
            } else {
                "$cur; __puus=$puus"
            }
        }
        cookieValueOf(setCookies, "Video-Auth")?.takeIf { it.isNotEmpty() }?.let { store.videoAuth = it }
    }

    /** 从 `Set-Cookie` 行里取某个键的值 —— 与 `PanResponse.cookieValue` 同口径。 */
    private fun cookieValueOf(setCookies: List<String>, name: String): String? {
        for (line in setCookies) {
            val semi = line.indexOf(';')
            val pair = if (semi < 0) line else line.substring(0, semi)
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            if (pair.substring(0, eq).trim() == name) return pair.substring(eq + 1).trim()
        }
        return null
    }

    /**
     * 取一张**网盘缩略图**（`media_items.thumb_url` → 夸克 `preview_url`）。
     *
     * ⛔ 必须带 Cookie：裸链回 `401 code=31001 require login`（实测，
     *    见 `docs/媒体库体验优化-逆向评估.md §2.2`）。
     * ⛔ 取完**必须**把响应里的 `Set-Cookie` 收回去 —— 见 [absorbSetCookies]。
     * ⛔ 走 `preview_url`（640×360，约 12 KiB）而不是 `thumbnail`（178×100）：
     *    库里只存了前者，而且列表行里的封面在 2× 屏上要 ~192px 宽，
     *    178 那一档明显发糊。
     *
     * 这个方法**只在后台线程调**（要发网络请求）。
     */
    fun thumbBytes(url: String, maxBytes: Int = 3 * 1024 * 1024): ByteArray {
        val res = PanHttp.getBytesWithCookies(
            url = url,
            cookie = store.requestCookie(),
            maxBytes = maxBytes,
            // 缩略图是「看得见就行」的东西，不值得让它占着连接 20 秒。
            timeoutMs = 12_000,
        )
        absorbSetCookies(res.setCookies)
        return res.bytes
    }

    private fun ensureOk(res: PanResponse, what: String) {
        if (res.isOk) return
        // 31001 = require login [guest]：缺公共参数或凭证失效。
        val reauth = res.code == 31001 || res.status == 401
        throw ApiException(
            res.code,
            "$what 失败：HTTP ${res.status} code=${res.code} ${res.message}".trim(),
            needsReauth = reauth,
        )
    }

    /** POST 一个 JSON body 到网盘端点，回填 Cookie 并校验业务码。 */
    private fun post(path: String, body: JSONObject, what: String): PanResponse {
        val res = PanHttp.postJson("$PC$path", commonQuery(), body, store.requestCookie())
        absorbCookies(res)
        ensureOk(res, what)
        return res
    }

    /**
     * 从响应 `data` 里挖出文件 fid。
     *
     * 口径照抄 PC 端 `QuarkMapper.parseFid`：`fid` → `file_id` → `id`，
     * 值可能是字符串也可能是数字（服务端两种都给过）。
     */
    private fun parseFid(data: JSONObject?): String {
        if (data == null) return ""
        for (key in FID_KEYS) {
            if (!data.has(key)) continue
            when (val v = data.opt(key)) {
                is String -> if (v.isNotEmpty()) return v
                is Number -> return v.toString()
                else -> Unit
            }
        }
        return ""
    }

    /**
     * `data` 可能是 `{fid: {...}}` 也可能是 `[{...}]`，两种都认。
     *
     * 按 fid 取键优先，取不到就退化成「第一个对象」—— 服务端改形状时
     * 至少还能播，而不是整个菜单空掉。
     */
    private fun pickNode(data: JSONObject?, fid: String): JSONObject? {
        if (data == null) return null
        data.optJSONObject(fid)?.let { return it }
        val keys = data.keys()
        while (keys.hasNext()) {
            val o = data.optJSONObject(keys.next())
            if (o != null) return o
        }
        return null
    }

    /** 目录判定：**以 `dir` 为准**，`file_type` 只作兜底。 */
    private fun isDir(o: JSONObject): Boolean {
        if (o.has("dir")) {
            val d = o.opt("dir")
            if (d is Boolean) return d
            if (d is Number) return d.toInt() != 0
            if (d is String) return d == "true" || d == "1"
        }
        if (o.has("file_type")) return o.optInt("file_type") == 0
        return false
    }

    /** `updated_at` 秒/毫秒两种都可能，统一成毫秒。 */
    private fun normalizeTimestamp(v: Long): Long = if (v in 1..9_999_999_999L) v * 1000L else v

    /**
     * 正整数归一：`null` / `0` / 负数一律当「不知道」。
     *
     * 「0 = 网盘还没刮削到」是这家的惯用约定（`duration` 同样如此），
     * 所以宽高也按同一口径处理 —— 把 `0` 传下去会让分辨率归挡算出荒唐的档位。
     */
    private fun positive(v: Int): Int? = if (v > 0) v else null

    /** 夸克的 `duration` 是**秒**，库里统一存毫秒。`<= 0` 当不知道。 */
    private fun secondsToMs(v: Long): Long? = if (v > 0) v * 1000L else null

    private fun tierLabel(id: String): String = when (id.lowercase()) {
        "4k" -> "4K"
        "2k" -> "2K"
        "super" -> "超清"
        "high" -> "高清"
        "normal" -> "标清"
        "low" -> "流畅"
        else -> id
    }

    /** 四元组（Kotlin 的 `Triple` 装不下四个）。 */
    private data class Quad<A, B, C, D>(val first: A, val second: B, val third: C, val fourth: D)

    companion object {
        private const val TAG = "CloudCine"

        const val PC = "https://drive-pc.quark.cn"

        const val PATH_CONFIG = "/1/clouddrive/config"
        const val PATH_MEMBER = "/1/clouddrive/member"
        const val PATH_FILE_SORT = "/1/clouddrive/file/sort"
        const val PATH_PLAY_INFO = "/1/clouddrive/batch/file/play/info"
        const val PATH_AUDIOPLAY = "/1/clouddrive/file/audioplay"

        // ── 文件管理（媒体库备份互操作）─────────────────────────────
        const val PATH_FILE_CREATE = "/1/clouddrive/file"
        const val PATH_FILE_DELETE = "/1/clouddrive/file/delete"
        const val PATH_UPLOAD_PRE = "/1/clouddrive/file/upload/pre"
        const val PATH_UPLOAD_HASH = "/1/clouddrive/file/update/hash"
        const val PATH_UPLOAD_AUTH = "/1/clouddrive/file/upload/auth"
        const val PATH_UPLOAD_FINISH = "/1/clouddrive/file/upload/finish"

        /** 一次上传的分片大小。夸克预上传响应里的 `part_size` 一般是 4 MiB。 */
        const val DEFAULT_PART_SIZE = 4 * 1024 * 1024

        /**
         * 单次下载的字节上限。
         *
         * 备份包通常是几 MB（库 + 海报），但用户勾了「含海报」之后可能到
         * 几十 MB。**不能设成「不限」** —— 这台电视只有 512 MB Java 堆，
         * 越界的表现是 `OutOfMemoryError` 直接把进程带走，不是一条错误日志。
         */
        const val MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024

        /** `parseFid` 的候选键，顺序即优先级。 */
        val FID_KEYS = listOf("fid", "file_id", "id")

        const val ROOT = "0"

        /** 原画档的 id（转码档用的是 `4k`/`super` 这些）。 */
        const val ORIGIN = "origin"

        /** 照抄客户端的梯度声明，顺序从低到高。 */
        const val RESOLUTION_TIERS = "normal,low,high,super,2k,4k"

        /**
         * ⛔ `fr` 必须与账号类型匹配：写 `mac` 会得到
         * `code=31001 require login [guest]`（实测）。
         */
        fun commonQuery(): Map<String, String> = mapOf("pr" to "ucpro", "fr" to "pc")
    }
}
