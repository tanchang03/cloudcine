package com.cloudcine.tv.pan.baidu

/**
 * 百度网盘**自用接口**的端点与请求常量（TV 端移植版）。
 *
 * 逐条照抄 PC 端 `lib/data/remote/baidu/baidu_endpoints.dart`（那里有完整的
 * 【实测】/【客户端】/【未验证】证据等级标注）。**只搬结论，不重新论证** ——
 * 两端口径必须一致，否则会出现「PC 上能播、电视上不能播」且两边日志
 * 都对不上的局面。改这里之前先去改 PC 那份。
 *
 * ## 为什么是自用接口，而不是官方开放平台
 *
 * 官方开放平台对本产品**不可用**：2026-06-03 之后创建的应用，`download` /
 * `meta` / `move` 等接口只能访问 `/apps/{appname}/` 目录，越界 `errno=20011`。
 * 而本产品要扫的是用户**已有的整个媒体库**。所以走 Web 端自用接口
 * （`pan.baidu.com/api/…`），靠登录态 Cookie（`BDUSS`）鉴权 —— 与夸克走
 * `drive-pc.quark.cn` 同一个思路。
 */
object BaiduEndpoints {

    // -------------------------------------------------------------------
    // 主机
    // -------------------------------------------------------------------

    /** 网盘 Web API 主机。全部 `api/…` 端点在此域下。 */
    const val PAN_HOST = "https://pan.baidu.com"

    /** 账号认证主机。扫码登录四个端点全在这里。⚠️ 与网盘域不是一回事。 */
    const val PASSPORT_HOST = "https://passport.baidu.com"

    /** PCS 直链主机。只用于 [ownsUrl] 的归属判定。 */
    const val PCS_HOST = "https://d.pcs.baidu.com"

    /** 登录入口（浏览器授权时打开的地址）。 */
    const val LOGIN_URL = "https://pan.baidu.com/disk/maclogin"

    // -------------------------------------------------------------------
    // 网盘业务端点（相对路径）
    // -------------------------------------------------------------------

    /** 列目录。⚠️ **`dir` 收的是路径而不是 ID**（与夸克最大的结构差异）。 */
    const val LIST = "/api/list"

    /** 全盘搜索（递归）。 */
    const val SEARCH = "/api/search"

    /** 账号信息（昵称 / uk / 会员档位）。 */
    const val ACCOUNT_UINFO = "/api/account/uinfo"

    /** 容量信息。 */
    const val QUOTA = "/api/quota"

    /** 取直链 —— **路径版**（`target=[<path>]`）。 */
    const val FILEMETAS = "/api/filemetas"

    /** 取直链 —— **fsid 版**（官方 xpan 路径，但用 Cookie 鉴权）。 */
    const val XPAN_MULTIMEDIA = "/rest/2.0/xpan/multimedia"

    /** 转码档取流（清晰度梯度的唯一来源）。 */
    const val BATCH_STREAMING = "/api/batch/streaming"

    /** 模板变量（内含 `bdstoken`）。 */
    const val GET_TEMPLATE_VARIABLE = "/api/gettemplatevariable"

    /** `bdstoken` 的另一条来源。 */
    const val GET_TEMPLATE = "/api/get/template"

    /** `gettemplatevariable` 的 `fields` 参数（客户端同款）。 */
    const val TEMPLATE_FIELDS = "[\"bdstoken\",\"uk\",\"isdocuser\",\"servertime\"]"

    // -------------------------------------------------------------------
    // 扫码登录端点（全部在 passport 域）
    // -------------------------------------------------------------------

    /** 取二维码。响应 `{errno:0, sign, imgurl}`，`imgurl` 是协议相对地址。 */
    const val GET_QRCODE = "/v2/api/getqrcode"

    /** 长轮询（jsonp）。无事件时会挂约 30 秒再回 `cb({"errno":1})`。 */
    const val UNICAST = "/channel/unicast"

    /** 扫码确认换 BDUSS —— **主线**（GET，不带 loginVersion）。 */
    const val BDUSS_LOGIN_MAINLINE = "/v2/api/bdusslogin"

    /** 扫码确认换 BDUSS —— **风控分支**（POST，`loginVersion=v4`）。 */
    const val QR_BDUSS_LOGIN = "/v3/login/main/qrbdusslogin"

    /** 换 **netdisk 专用 `STOKEN`**（客户端登录链第 5 步）。 */
    const val STOKEN_AUTH = "/v3/login/api/auth"

    // -------------------------------------------------------------------
    // 请求常量
    // -------------------------------------------------------------------

    /** 根目录标识。⚠️ **与夸克的 `'0'` 不同，百度用路径 `'/'`**。 */
    const val ROOT_ID = "/"

    /** 网盘 Web API 的公共参数（网页版固定带）。 */
    val COMMON_PARAMS: Map<String, String> = linkedMapOf(
        "channel" to "chunlei",
        "web" to "1",
        "app_id" to "250528",
        "clienttype" to "0",
    )

    /** 请求网盘 API 时用的 UA（实测浏览器 UA 打 `/api/list` 正常返回 `-6` 门）。 */
    const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /** 扫码链路（passport 域）用的 UA。与 [USER_AGENT] 同值即可。 */
    const val PASSPORT_USER_AGENT = USER_AGENT

    const val REFERER = "https://pan.baidu.com/disk/home"

    /** 请求网盘 API 时带的 `Origin`。⛔ 不能省 —— 百度 WAF 可能把没有它的
     *  `/api/…` 请求当成非网页来源，拒绝在业务层看起来就是 `errno=-6`。 */
    const val ORIGIN = "https://pan.baidu.com"

    /** 扫码链路的 `Referer`。 */
    const val PASSPORT_REFERER = LOGIN_URL

    const val ACCEPT = "application/json, text/plain, */*"
    const val ACCEPT_LANGUAGE = "zh-CN,zh;q=0.9"

    /** **页面导航**（不是 XHR）用的 `Accept`（落地网盘域那一跳用）。 */
    const val PAGE_ACCEPT =
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    /** 扫码登录的业务参数（客户端照抄：`tpl` 填错会按别的业务线签发凭证）。 */
    const val PRODUCT = "netdisk"
    const val SUB_PRODUCT = "netdisk_web"
    const val QRLOGIN_FROM = "pc"

    /** 登录成功后网页版跳转的落点。 */
    const val POST_LOGIN_URL = "https://pan.baidu.com/"

    // -------------------------------------------------------------------
    // 直链通道
    // -------------------------------------------------------------------

    /** 取链请求里 `origin` 的**投屏（DLNA）**取值 —— 唯一能拿到快通道的那个。 */
    const val DLNA_ORIGIN = "dlna"

    /** `/api/filemetas` 响应里 `info[].category` 的取值（服务端权威文件类型）。 */
    const val CATEGORY_VIDEO = 1
    const val CATEGORY_AUDIO = 2
    const val CATEGORY_IMAGE = 3
    const val CATEGORY_DOCUMENT = 4
    const val CATEGORY_APPLICATION = 5
    const val CATEGORY_OTHER = 6

    /** 能走 [DLNA_ORIGIN] 快通道的类别：**媒体**（视频 + 音频）。 */
    val DLNA_CATEGORIES = listOf(CATEGORY_VIDEO, CATEGORY_AUDIO)

    /** 这个类别能不能走快通道。解析不到类别（`null`）时走**慢通道**（保守）。 */
    fun canUseDlna(category: Int?): Boolean =
        category != null && DLNA_CATEGORIES.contains(category)

    /**
     * 直链的第二跳 UA。
     *
     * ★ 实测：CDN（`*.baidupcs.com`）的 `sign` 是按 UA 签的 —— 同一个 URL，
     * `netdisk` 回 206，浏览器 UA / `Dart/` UA 一律 403 31362 sign error。
     * ⚠️ Java 的 `HttpURLConnection` 与 media3 的 `DefaultHttpDataSource`
     * **都会在重定向上保留 UA**，所以它能熬过 302。
     */
    const val NETDISK_DLINK_UA = "netdisk"

    /** 官方 Open Platform 路由的 UA（本项目不走那条，仅文档对照）。 */
    const val OFFICIAL_DLINK_UA = "pan.baidu.com"

    /** `dlink` 的实际有效期（URL 里不带过期时间戳，只能按服务端声明倒推）。 */
    const val DLINK_TTL_MS = 8L * 60 * 60 * 1000

    // -------------------------------------------------------------------
    // Cookie
    // -------------------------------------------------------------------

    /** 会话必需 Cookie —— 缺它即视为未登录。 */
    val ESSENTIAL_COOKIE_NAMES = listOf("BDUSS")

    /** 会一并落库的已知 Cookie。 */
    val KNOWN_COOKIE_NAMES = listOf(
        "BDUSS", "BDUSS_BFESS", "STOKEN", "PASS_STOKEN",
        "PTOKEN", "PTOKEN_BFESS", "BAIDUID", "BAIDUID_BFESS",
    )

    /** 组装 `Cookie:` 头时的优先顺序（关键键在前）。 */
    val COOKIE_HEADER_ORDER = listOf(
        "BDUSS", "BDUSS_BFESS", "STOKEN", "PASS_STOKEN", "PTOKEN",
    )

    /** 域名归属判定：直链 / 缩略图主机多变，按 `baidu.com` 后缀判。 */
    fun ownsUrl(url: String): Boolean = url.contains("baidu.com")

    /** 把一组 Cookie 组装成 `Cookie:` 头值（按 [COOKIE_HEADER_ORDER] 排）。 */
    fun cookieHeader(cookies: Map<String, String>): String {
        val names = LinkedHashSet<String>()
        names.addAll(COOKIE_HEADER_ORDER.filter { cookies.containsKey(it) })
        names.addAll(cookies.keys)
        return names.filter { cookies[it]?.isNotEmpty() == true }
            .joinToString("; ") { "$it=${cookies[it]}" }
    }
}

/**
 * 百度转码档位枚举（从 Mac 客户端 V8.8.8 的 JS 里逐字读出）。
 *
 * ⛔ 切档是**超级会员特权**：非 SVIP 只能待在默认低档（480P）。
 * 所以 [BaiduApi.resolve] 只探账号默认档（[defaultFor]），不无脑请求最高档。
 */
object BaiduResolution {
    const val NONE = -1
    const val P360 = 0
    const val P480 = 1
    const val P720 = 2
    const val P1080 = 3
    const val K2 = 4
    const val K4 = 5

    /** 帧彩映画（客户端枚举名 `RESOLUTION_INTELLIGENT_HD`）。 */
    const val INTELLIGENT_HD = 6

    /** 全部有效档位，**由低到高**。 */
    val ALL = listOf(P360, P480, P720, P1080, K2, K4, INTELLIGENT_HD)

    /** 档位 → 展示名（客户端菜单文案逐字照抄）。 */
    fun labelFor(type: Int): String = when (type) {
        P360 -> "360P 省流"
        P480 -> "480P 流畅"
        P720 -> "720P 高清"
        P1080 -> "1080P 超清"
        K2 -> "2K 原画"
        K4 -> "4K 原画"
        INTELLIGENT_HD -> "帧彩映画"
        else -> "未知档位"
    }

    /** 档位 → 短名（电视上的画质 chip 只放短名）。 */
    fun shortLabelFor(type: Int): String = when (type) {
        P360 -> "360P"
        P480 -> "480P"
        P720 -> "720P"
        P1080 -> "1080P"
        K2 -> "2K"
        K4 -> "4K"
        INTELLIGENT_HD -> "帧彩"
        else -> "?"
    }

    /** 档位 → 稳定 id（会被持久化，**不要改**；与 PC 端逐字一致）。 */
    fun idFor(type: Int): String = "baidu_$type"

    /** 稳定 id → 档位。解析不出来返回 `null`。 */
    fun typeFromId(id: String): Int? {
        if (!id.startsWith("baidu_")) return null
        return id.substring("baidu_".length).toIntOrNull()
    }

    /** 档位 → 近似高度（标称值，用于排序与归挡）。 */
    fun heightFor(type: Int): Int? = when (type) {
        P360 -> 360
        P480 -> 480
        P720 -> 720
        P1080 -> 1080
        K2 -> 1440
        K4 -> 2160
        else -> null
    }

    /** 指定会员等级下的默认档位：非 SVIP → 480P，SVIP → 1080P。 */
    fun defaultFor(vipType: Int): Int = if (vipType == BaiduVipType.SVIP) P1080 else P480
}

/** 百度会员档位（客户端 `{normal:0, vip:1, svip:2}`）。 */
object BaiduVipType {
    const val NORMAL = 0
    const val VIP = 1
    const val SVIP = 2

    fun labelFor(type: Int): String = when (type) {
        SVIP -> "超级会员"
        VIP -> "会员"
        else -> "普通用户"
    }
}

/**
 * 百度业务错误码。
 *
 * ⚠️ `-6` 是**一码多义**：没带 Cookie / Cookie 废了 / 缺 `bdstoken` /
 * 账号级临时风控，全都回它。区分它们的唯一可靠线索是服务端原话
 * `show_msg`（而它常常不出现）—— 所以日志里必须留原始响应体。
 */
object BaiduErrorCode {
    const val OK = 0

    /** 未登录 / 会话无效（一码多义，见类文档）。 */
    const val NOT_LOGGED_IN = -6
    const val FILE_NOT_FOUND = -7
    const val FILE_ALREADY_EXISTS = -8
    const val FILE_NOT_EXIST = -9
    const val DIR_NOT_EXIST = -10
    const val INVALID_PARAM = 2
    const val NEED_VERIFY = -62

    /** 账号级风控（xpan 端点被挡，不影响 `/api/…` 路由）。 */
    const val RISK_CONTROL = 9019
    const val PATH_NOT_ALLOWED = 20011

    /** 直链过期 / 签名错（CDN 层）。 */
    const val DLINK_EXPIRED = 31360
    const val DLINK_SIGN_INVALID = 31362

    /** 扫码：风控（要去 App 确认）/ 取码过于频繁。 */
    const val QR_RISK_CONTROL = 400023
    const val QR_FETCH_LIMIT = 50000
}
