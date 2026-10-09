/// 百度网盘**自用接口**的端点与请求常量。
///
/// ## 为什么是自用接口，而不是官方开放平台
///
/// 官方开放平台对本产品**不可用**，这是硬限制而非取舍（证据见
/// `.workbuddy-ai/memory/2026-10-08.md`）：官方文档（2026-08-03 更新）明确
/// **2026-06-03 之后创建的应用**，`download` / `meta` / `move` 等接口
/// **只能访问 `/apps/{appname}/` 目录下的文件**，越界返回 `errno=20011`。
/// 而本产品要扫的是用户**已有的整个媒体库**，不可能要求用户把片子搬进
/// `/我的应用数据/`。个人认证应用还限 10 个用户、1 个应用。
///
/// 所以走 **Web 端自用接口**（`pan.baidu.com/api/*`）—— 靠登录态 Cookie
/// （`BDUSS`）鉴权，与夸克走 `drive-pc.quark.cn` 是同一个思路。
///
/// ## 证据等级（本仓库的规矩：不许凭公开资料下结论）
///
/// 本文件里的每个常量都标了来源。三种标记：
///   - **【实测】** —— 本轮或上一轮真的发过请求、看到过响应；
///   - **【客户端】** —— 从百度网盘 Mac 客户端 V8.8.8 的 JS 里读出来的
///     （`core.asar`），是官方实现自己在用的值；
///   - **【未验证】** —— 来自社区实现或官方文档，**本机没验过**。
///     标注它是因为「知道有这么个东西」和「它现在还能用」是两件事。
library;

class BaiduEndpoints {
  const BaiduEndpoints._();

  // -------------------------------------------------------------------
  // 主机
  // -------------------------------------------------------------------

  /// 网盘 Web API 主机。【实测】全部 `api/*` 端点在此域下。
  static const String panHost = 'https://pan.baidu.com';

  /// 账号认证主机。【客户端】扫码登录四个端点全在这里。
  ///
  /// ⚠️ 与网盘域**不是**一回事：Cookie 在 `passport` 域登录、在 `pan` 域使用。
  static const String passportHost = 'https://passport.baidu.com';

  /// PCS 直链主机。【未验证】历史上直链会落在 `d.pcs.baidu.com`。
  ///
  /// 保留它只用于 [ownsUrl] 的归属判定 —— 直链主机随时可能变，
  /// 而判错归属的后果是「图片请求不带鉴权头」而不是崩溃。
  static const String pcsHost = 'https://d.pcs.baidu.com';

  /// 登录入口（浏览器授权时打开的地址）。
  ///
  /// 【实测】Mac 客户端的登录页就是它，且该页面自己
  /// `localStorage.setItem('passLoginType', 'qrcode')` —— 官方刻意只开扫码。
  static const String loginUrl = 'https://pan.baidu.com/disk/maclogin';

  // -------------------------------------------------------------------
  // 网盘业务端点（相对路径）
  // -------------------------------------------------------------------

  /// 列目录。
  ///
  /// 【实测】带垃圾 Cookie 返回 `{"errno":-6}` ⇒ 端点存活、门在 Cookie。
  ///
  /// ⚠️ **`dir` 收的是路径而不是 ID** —— 这是与夸克最大的结构差异
  /// （夸克 `pdir_fid` 是 ID）。适配器内部用 `fs_id → path` 缓存把
  /// 这个差异吃掉，接口层不必感知，见 `BaiduAdapter.listDirectory`。
  static const String list = '/api/list';

  /// 全盘搜索。
  ///
  /// ⚠️ 【未验证】百度**没有**与夸克 `_sort` 等价的「文件优先」开关，
  /// 搜索命中的目录要靠调用方自行过滤（契约里已经写明这一点）。
  static const String search = '/api/search';

  /// 账号信息（昵称 / uk / 会员档位）。【实测】存活，`-6` 门。
  static const String accountUinfo = '/api/account/uinfo';

  /// 容量信息。【实测】存活，`-6` 门。
  static const String quota = '/api/quota';

  /// 取直链 —— **路径版**（`target=[<path>]`）。
  ///
  /// 调用形态：`/api/filemetas?target=[path]&dlink=1&web=5`。【实测】存活。
  ///
  /// ## `origin` 决定的是**通道**，不是签名（2026-10-09 实测）
  ///
  /// 同一个端点、同一份 Cookie，只改 `origin` 取回来的直链落在**两条
  /// 吞吐差 30 倍的通道**上：
  ///
  /// | `origin` | 直链带 `vuk` | 视频 | 音频 | 文档 | 单连接吞吐 |
  /// |---|---|---|---|---|---|
  /// | `dlna` | 是 | 206 ✅ | 206 ✅ | `403 31329 hit illeage dlna` | **1.1~2.9 MB/s** |
  /// | 不带 / `pc` / `web` / `netdisk` / `android` / `ios` / `tv` / `pan` | 否 | 206 | 206 | 206 ✅ | 40~90 KB/s |
  ///
  /// 也就是说：**`origin=dlna` 是唯一快的通道，但它只服务媒体**
  /// （视频 + 音频；见 [dlnaCategories]）；
  /// 其余取值统统走非会员的普通下载通道，被**按账号**限速在 ~80 KB/s。
  ///
  /// 所以适配器**不能**二选一了事（那是 2026-10-09 上午那版的做法，
  /// 代价是媒体播放掉进慢通道）—— 它按响应里的 `info[].category` 分流
  /// （见 [canUseDlna] 与 `BaiduAdapter._resolveOriginalViaPathString`）。
  ///
  /// ⚠️ 它与官方 `/rest/2.0/xpan/multimedia?method=filemetas` 的区别是
  /// **不收 `access_token`、只认 Cookie**，因此不受 `/apps/` 限制。
  /// 适配器把它排在 [xpanFilemetas] 之后作为兜底。
  static const String filemetas = '/api/filemetas';

  /// 取链请求里 `origin` 的**投屏（DLNA）**取值 —— 唯一能拿到快通道的那个。
  ///
  /// ⛔ 它签出的直链**只服务媒体**（视频 / 音频）：拿它去取文档，CDN 回
  /// `403 31329 hit black userlist , hit illeage dlna`（文案里的
  /// 「黑名单」是误导，与账号 / 会员 / Cookie 都无关）。
  static const String dlnaOrigin = 'dlna';

  /// `/api/filemetas` 响应里 `info[].category` 的取值 —— 服务端认定的文件类型。
  ///
  /// 用它（而不是文件扩展名）决定走哪条通道：它是**服务端权威**的，
  /// 能正确处理「扩展名骗人」的情况（例如一个叫 `.mp4` 的 PDF）。
  static const int categoryVideo = 1;
  static const int categoryAudio = 2;
  static const int categoryImage = 3;
  static const int categoryDocument = 4;
  static const int categoryApplication = 5;
  static const int categoryOther = 6;

  /// 能走 [dlnaOrigin] 快通道的类别：**媒体**（视频 + 音频）。
  ///
  /// 【实测 2026-10-09】同一账号、同一份 Cookie，只改 `origin`：
  ///
  /// | `category` | 带 `origin=dlna` | 不带 |
  /// |---|---|---|
  /// | `1` 视频 | **1410 KB/s** ✅ | 83 KB/s |
  /// | `2` 音频 | **1024 KB/s** ✅ | 84 KB/s |
  /// | `4` 文档 | `403 31329 illeage dlna` ❌ | 41 KB/s |
  ///
  /// 图片（`3`）与其余类别**没实测过**，所以不放进这里 —— 它们体积小，
  /// 走慢通道的代价可以接受；放进去却撞 31329 就是**下不了**。
  /// 保守的错法只会慢，激进的错法会坏。
  static const List<int> dlnaCategories = [categoryVideo, categoryAudio];

  /// 这个类别能不能走快通道。解析不到类别（`null`）时**走慢通道**。
  static bool canUseDlna(int? category) =>
      category != null && dlnaCategories.contains(category);


  /// 取直链 —— **fsid 版**（官方 xpan 路径，但用 Cookie 鉴权）。
  ///
  /// 【未验证】`/rest/2.0/xpan/multimedia?method=filemetas&dlink=1&fsids=[id]`。
  ///
  /// 排在路径版**之前**的原因：它收的是 `fs_id`，而适配器手里正好只有
  /// `fileId`（= `fs_id`）。路径版需要先解析出路径，多一次查询。
  static const String xpanMultimedia = '/rest/2.0/xpan/multimedia';

  /// 转码档取流（**清晰度梯度的唯一来源**）。
  ///
  /// 【客户端】从 Mac 客户端 V8.8.8 逆向得到，且【实测】端点存活
  /// （带垃圾 Cookie 返回 `{"errno":-6,"show_msg":"账户已过期，重新登陆"}`）。
  ///
  /// 客户端里的常量名是 `video_preload`，经 `getUrlbyKey` 查内置表得到
  /// `https://${host_pan}/api/batch/streaming`。调用形态：
  ///
  /// ```
  /// GET /api/batch/streaming?check_blue=1&type=<档位>&path=<encodeURIComponent(JSON数组)>
  /// ```
  ///
  /// - `check_blue=1`：路径合规检查开关（客户端自己也带）；
  /// - `type`：**清晰度档位**，取值见 [BaiduResolution]；
  /// - `path`：**路径数组**的 JSON 字符串，形如 `["\/a.mp4","\/b.mp4"]`。
  ///
  /// ⚠️ 客户端调它是**预加载**（`ipcRenderer.send('setPreloadInfoDirect')`），
  /// 响应形状本机没拿到过 —— 适配器按「尽力解析出 URL、解析不到就
  /// 如实返回空档位列表」处理，不猜。
  static const String batchStreaming = '/api/batch/streaming';

  /// 视频直链（另一条路由）。
  ///
  /// 【未验证】来自 AList 已废弃的 `linkCrackVideo`：
  /// `/api/mediainfo?type=VideoURL&...&nom3u8=1`。
  static const String mediaInfo = '/api/mediainfo';

  /// 模板变量（内含 `bdstoken`）。【实测】存活，`-6` 门。
  static const String gettemplatevariable = '/api/gettemplatevariable';

  /// `gettemplatevariable` 的 `fields` 参数（**客户端同款**）。
  ///
  /// 客户端登录链的第 7 步就是拿它换 `bdstoken`；`bdstoken` 是网盘
  /// `/api/*` 的**会话令牌**，缺了它服务端会回 `errno=-6`
  /// （「登录状态无效」）—— 与「凭证真的废了」**同一个码**。
  static const String templateFields =
      '["bdstoken","uk","isdocuser","servertime"]';

  /// `bdstoken` 的另一条来源。
  ///
  /// 【客户端】Mac 客户端的 URL 表里 `getbdstoken` 指向
  /// `https://pan.baidu.com/api/get/template`（不是 `gettemplatevariable`）。
  /// 两条都留着：拿不到 `bdstoken` 时轮换着试，比只认一条稳。
  static const String getTemplate = '/api/get/template';

  // -------------------------------------------------------------------
  // 扫码登录端点（全部在 passport 域，**无鉴权无签名**）
  // -------------------------------------------------------------------

  /// 取二维码。
  ///
  /// 【客户端】登录页源码里的拼法：
  /// `/v2/api/getqrcode?lp=pc&qrloginfrom={qrloginfrom}&gid={gid}`
  ///
  /// 响应：`{errno:0, sign, imgurl}`，其中 `imgurl` 是**协议相对地址**
  /// （`//passport.baidu.com/v2/api/qrcode?sign=…`），必须自己补 `https:`。
  /// 【实测】补上后取回的是真 PNG。
  static const String getQrcode = '/v2/api/getqrcode';

  /// 长轮询（jsonp）。
  ///
  /// 【客户端】`/channel/unicast?channel_id={sign}&gid={gid}&tpl={product}&_sdkFrom=1`
  /// 另带 `apiver=v3` 与 `tt={ms}` 两个查询参数（在 `data` 里）。
  ///
  /// 【实测】端点会**挂住约 30 秒**再回 `cb({"errno":1})` —— 这是长轮询的
  /// 正常行为（没有事件就一直等），不是端点坏了。所以超时必须给足，
  /// 否则每次轮询都会「超时」，用户永远等不到扫码结果。
  static const String unicast = '/channel/unicast';

  /// 扫码确认换 BDUSS —— **主线**（客户端真正在用的那一条）。
  ///
  /// 【客户端】`GET /v2/api/bdusslogin?tt={ms}` + `{bduss, u, qrcode:1, tpl}`。
  ///
  /// ⚠️ **不带 `loginVersion`** —— 那条参数只出现在另外两条分支上
  /// （见 [qrBdussLogin] 与小程序分支 `/v3/api/mini/qrlogin`）。
  ///
  /// 成功判据是**顶层** `errno == 0`（无效 bduss 回 `errno:1`，实测）。
  /// 响应里的 `Set-Cookie` 才是 `BDUSS` 的真正来源。
  static const String bdussLoginMainline = '/v2/api/bdusslogin';

  /// 扫码确认换 BDUSS —— **风控分支**（客户端只在 `errno 400023` 时才走）。
  ///
  /// 【客户端】`POST /v3/login/main/qrbdusslogin`，载荷
  /// `{authsid, bduss, u, loginVersion:'v4', tpl}` —— `authsid` 来自
  /// 上一条响应里的风控字段，没有它这个端点回 `310005`。
  ///
  /// ⛔⛔ **`loginVersion:'v5'` 不属于这个端点**，它属于微信小程序分支
  /// `/v3/api/mini/qrlogin`。2026-10-09 之前本适配器把这条当**主线**、
  /// 还送 `loginVersion=v5` —— 一个服务端从没见过的参数组合。
  /// 它照样回 `200` 并下发 `Set-Cookie`，但签发的会话网盘侧不认，
  /// 现象正是「扫码成功，紧接着 `/api/account/uinfo` 回 `errno=-6`」
  /// （2026-10-08 / 10-09 两次实测）。
  ///
  /// 因此现在它**只做兜底**，且按客户端原样用 `POST` + `loginVersion=v4`。
  static const String qrBdussLogin = '/v3/login/main/qrbdusslogin';

  /// 换 **netdisk 专用 `STOKEN`**（客户端登录链的第 5 步）。
  ///
  /// 【客户端】`GET {passport}/v3/login/api/auth?bduss=&ptoken=`
  /// → `data.stoken_list.netdisk`（实测端点 LIVE）。
  ///
  /// ⚠️ 换票响应的 `Set-Cookie` 里**已经**有 `STOKEN`，所以这一步是
  /// **补强**而不是前提：能换到 netdisk 专用值就覆盖，换不到就沿用。
  static const String stokenAuth = '/v3/login/api/auth';

  // -------------------------------------------------------------------
  // 请求常量
  // -------------------------------------------------------------------

  /// 根目录标识。
  ///
  /// ⚠️ **与夸克的 `'0'` 不同，百度用路径 `'/'`**。
  ///
  /// 这不是随便定的：百度的 `dir` 参数本身就是路径，没有「根 fs_id」这个概念
  /// （`/api/list?dir=/` 才是列根目录）。契约允许各网盘自定根 ID
  /// （`CloudDriveAdapter.rootId` 的文档就是这么写的），所以这里用 `'/'`。
  static const String rootId = '/';

  /// 网盘 Web API 的公共参数。
  ///
  /// 【客户端】`channel` / `web` / `app_id` 三个是网页版固定带的；
  /// `app_id=250528` 是百度网盘网页版的公开应用号（不是密钥，不敏感）。
  static const Map<String, String> commonParams = {
    'channel': 'chunlei',
    'web': '1',
    'app_id': '250528',
    'clienttype': '0',
  };

  /// 请求网盘 API 时用的 UA。【实测】用浏览器 UA 打 `/api/list` 正常返回
  /// `-6`（说明请求本身被接受了，只是没登录）。
  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 扫码链路（passport 域）用的 UA。
  ///
  /// 【实测】取二维码与长轮询都用它。⚠️ 与 [userAgent] 用同一个值即可 ——
  /// 上一轮探针实测证明 passport 端点不挑 UA，但**必须有一个**。
  static const String passportUserAgent = userAgent;

  static const String referer = 'https://pan.baidu.com/disk/home';

  /// 请求网盘 API 时带的 `Origin`。
  ///
  /// 【参考】百度网盘网页版的 XHR 一律带 `Origin: https://pan.baidu.com`。
  /// 两个独立来源都把 `Origin` 列成**必带 header**（本机读到的社区实现
  /// `baidu_pcs.py` 的 session 默认头、以及一份端点速查表）。
  ///
  /// ⚠️ 本适配器**早期漏了它**（2026-10-08 的实测日志里，发往
  /// `/api/account/uinfo` 的请求头是 `[User-Agent, Accept, Accept-Language,
  /// Referer, Cookie]`，唯独没有 `Origin`）。它是我们与一个**已知能跑通**
  /// 的实现之间唯一的结构性差异，因此补上。
  ///
  /// 它不参与业务参数，但百度的 WAF 可能把「没有 `Origin` 的 `/api/*` 请求」
  /// 当成非网页来源。这类拒绝在业务层看起来就是 `errno=-6`（登录状态无效），
  /// 与「凭证真的废了」**同一个码** —— 所以必须先从请求形状上排除掉，
  /// 否则会把一个「头没带全」误判成「账号失效」。
  static const String origin = 'https://pan.baidu.com';

  /// 扫码链路的 `Referer`。
  ///
  /// 【实测】探针脚本用 `https://pan.baidu.com/disk/maclogin` 打
  /// `getqrcode` / `unicast` 全部正常。⚠️ 曾经怀疑它会影响长轮询，
  /// 实测对照组（换成 `passport.baidu.com/`）行为一致 ⇒ 它不关键，
  /// 但保持一致更安全。
  static const String passportReferer = loginUrl;

  static const String accept = 'application/json, text/plain, */*';
  static const String acceptLanguage = 'zh-CN,zh;q=0.9';

  /// **页面导航**（不是 XHR）用的 `Accept`。
  ///
  /// 【客户端】登录链第 4 步是 WebView 跟着 302 跳到 `pan.baidu.com`，
  /// 那是一次**页面请求**而不是接口调用。服务端可能按「页面 / 接口」
  /// 分派不同的会话建立逻辑（网页版的 XHR 才有 `Origin`，页面导航没有），
  /// 所以落地那一跳刻意用页面头而不是 [accept]。
  static const String pageAccept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

  /// 扫码登录的业务参数。
  ///
  /// 【客户端】登录页配置里 `product: "netdisk"`、`subpro: "netdisk_web"`、
  /// `qrloginfrom: 'pc'`。三个都照抄 —— `tpl` 是**业务线标识**，
  /// 填错会让服务端按别的业务线签发凭证。
  static const String product = 'netdisk';
  static const String subProduct = 'netdisk_web';
  static const String qrloginFrom = 'pc';

  /// 登录成功后网页版跳转的落点。【客户端】`u: "https://pan.baidu.com/"`。
  static const String postLoginUrl = 'https://pan.baidu.com/';

  // -------------------------------------------------------------------
  // Cookie
  // -------------------------------------------------------------------

  /// 会话必需 Cookie —— 缺它即视为未登录。
  ///
  /// 【实测】`BDUSS` 是硬必需：带垃圾 `BDUSS` 打 `/api/list` 与
  /// `/api/batch/streaming` 都返回 `errno=-6`，说明服务端确实在读它。
  static const List<String> essentialCookieNames = ['BDUSS'];

  /// 会一并抓取 / 落库的已知 Cookie。
  ///
  /// 分三组：
  ///   - `BDUSS` / `BDUSS_BFESS`：会话主体（`_BFESS` 是 HttpOnly 变体）；
  ///   - `STOKEN` / `PASS_STOKEN`：换取 `bdstoken` 用（`STOKEN` 是网盘域的，
  ///     `PASS_STOKEN` 是 passport 域的，两者**都要**）；
  ///   - `PTOKEN` / `PTOKEN_BFESS`：passport 侧的票据。
  ///
  /// ⚠️ 百度**没有**夸克那种「每个响应轮换 Cookie」的行为（本机实测：
  /// 打 `/api/list` 的响应里没有 `Set-Cookie`），所以适配器**不需要**
  /// 回填轮换 Cookie。这一点与夸克相反，少了一整类隐蔽故障。
  static const List<String> knownCookieNames = [
    'BDUSS',
    'BDUSS_BFESS',
    'STOKEN',
    'PASS_STOKEN',
    'PTOKEN',
    'PTOKEN_BFESS',
    'BAIDUID',
    'BAIDUID_BFESS',
  ];

  /// 组装 `Cookie:` 头时的优先顺序（关键键在前，便于日志排查）。
  static const List<String> cookieHeaderOrder = [
    'BDUSS',
    'BDUSS_BFESS',
    'STOKEN',
    'PASS_STOKEN',
    'PTOKEN',
  ];

  /// 直链的兜底 TTL。
  ///
  /// 【未验证】社区实测 `dlink` 有效期约 **8 小时**（过期返回 `31360`）。
  /// 这里取 30 分钟是保守折中：远小于 8 小时（不会中途断流），
  /// 又不必每次起播都重新取链。**解析不到真实过期时刻时**才用它。
  static const Duration ticketFallbackTtl = Duration(minutes: 30);

  /// `dlink` 的实际有效期（用于给票据填 `expiresAt`）。
  ///
  /// 【未验证】8 小时。⚠️ 之所以要单独一个常量而不是直接用
  /// [ticketFallbackTtl]：直链的 URL 里**不带**过期时间戳（与夸克的
  /// `auth_key` 不同），只能按服务端声明的有效期倒推。
  static const Duration dlinkTtl = Duration(hours: 8);

  /// ★★ 直链的请求形状**按取链路由分「方言」**。
  ///
  /// | 取链路由 | dlink 字段 | 请求头 |
  /// |---|---|---|
  /// | `/rest/2.0/xpan/multimedia?method=filemetas`（官方 Open Platform，需 `access_token`） | `list[].dlink` | UA [officialDlinkUserAgent] |
  /// | `/api/filemetas?dlink=1&web=5`（网页 crack，**视频**带 [dlnaOrigin]） | `info[].dlink` | UA [netdiskDlinkUserAgent]，dlna 直链**不必带 `Cookie`**（自带 `vuk`） |
  /// | `/api/filemetas?dlink=1&web=5`（网页 crack，**非视频不带** `origin`） | `info[].dlink` | UA [netdiskDlinkUserAgent] + **`Cookie`** |
  /// | `/api/batch/streaming?type=<档位>`（客户端转码档） | `list[].dlink` | UA [netdiskDlinkUserAgent] + **`Cookie`** |
  /// | `/api/mediainfo?type=VideoURL`（客户端 crack） | `info.dlink` | UA [netdiskDlinkUserAgent] + **`Cookie`** |
  ///
  /// ⚠️ 带 `origin` 的两行**不是同一回事**：[dlnaOrigin] 取出来的是
  /// 快通道（1~3 MB/s）但**只服务媒体**（视频 + 音频）；不带 `origin` 的那条
  /// 覆盖面全（视频 + 音频 + 文档）但被限速在 ~80 KB/s。适配器按 `category`
  /// 分流，见 [filemetas] 的实测表。
  ///
  /// ⚠️⚠️ **「换个 UA 就好了」是错的**。2026-10-09 用真实账号 + 真实直链
  /// 逐项对照测出：真正决定成败的是「取链时带没带 `origin`」和
  /// 「直链请求带没带 `Cookie`」。完整因果与实测表见
  /// `BaiduAdapter._dlinkHeaders` 的文档 —— 早先只盯着 UA，白绕了两轮。
  static const String officialDlinkUserAgent = 'pan.baidu.com';

  /// 网页 crack / 客户端路由的 UA。
  ///
  /// 【证据】AList 的 `custom_crack_ua` 默认值就是它（`alist-meta.go`），
  /// 且它的 `linkCrack` / `linkCrackVideo` 直接把它塞进直链请求头。
  ///
  /// ★ 2026-10-09 实测（**只对带 `vuk` 的 dlna 直链成立**）：CDN 那一跳
  /// （`*.baidupcs.com`）的 `sign` **是按 `User-Agent` 签的** —— 同一个 URL，
  /// 这个值回 `206`，而 `Dart/3.7 (dart:io)` / `pan.baidu.com` /
  /// `Mozilla/5.0` 一律 `403 {"error_code":31362,"error_msg":"sign error"}`。
  ///
  /// ⚠️ 对**无 `origin`** 的直链，第二跳**不挑 UA**
  /// （`Dart/3.7 (dart:io)` + `Cookie` 也是 `206`）。但本适配器现在
  /// **视频又回到 dlna 直链**了（那是唯一能跑满带宽的通道），
  /// 所以这个值重新变成**必须**的 —— CDN 判**全等**，完整客户端 UA
  /// （`netdisk;1099a;PC;…`）与浏览器 UA 都过不了。
  static const String netdiskDlinkUserAgent = 'netdisk';
}

/// 百度转码档位枚举。
///
/// 【客户端】从 Mac 客户端 V8.8.8 的 JS 里逐字读出来的
/// （`v888js/47.js` 定义 0..5，`main.js` 追加 `6`）：
///
/// ```js
/// e[e.RESOLUTION_NONE=-1]="RESOLUTION_NONE"
/// e[e.RESOLUTION_360P=0]="RESOLUTION_360P"
/// e[e.RESOLUTION_480P=1]="RESOLUTION_480P"
/// e[e.RESOLUTION_720P=2]="RESOLUTION_720P"
/// e[e.RESOLUTION_1080P=3]="RESOLUTION_1080P"
/// e[e.RESOLUTION_2K=4]="RESOLUTION_2K"
/// e[e.RESOLUTION_4K=5]="RESOLUTION_4K"
/// e[e.RESOLUTION_INTELLIGENT_HD=6]="RESOLUTION_INTELLIGENT_HD"
/// ```
///
/// ## ⛔ 切档是**超级会员特权**
///
/// 客户端里的判据是 `if (this.vipType === svip && 1 < e)`，
/// 并弹「超级会员，正在为您切换到会员专享的…画质」。默认档位也分两套：
///
/// | 会员 | 默认值 | 实际档位 |
/// |---|---|---|
/// | 非 SVIP | `{index:1, resolution:1}` | 480P |
/// | SVIP | `{index:3, resolution:3}` | 1080P |
///
/// ⇒ **非会员即使请求高档位，服务端也不会给**。所以本适配器
/// `resolveStream` 会按账号的 `vipType` 决定要不要去请求转码档，
/// 而不是无脑请求最高档再等失败。
class BaiduResolution {
  const BaiduResolution._();

  /// 无档位（客户端用它表示「还没选」）。
  static const int none = -1;

  static const int p360 = 0;
  static const int p480 = 1;
  static const int p720 = 2;
  static const int p1080 = 3;
  static const int k2 = 4;
  static const int k4 = 5;

  /// 帧彩映画（客户端枚举名 `RESOLUTION_INTELLIGENT_HD`）。
  static const int intelligentHd = 6;

  /// 全部有效档位，**由低到高**。
  static const List<int> all = [p360, p480, p720, p1080, k2, k4, intelligentHd];

  /// 档位 → 展示名。
  ///
  /// 【客户端】菜单文案逐字照抄（`v888js/48.js`）：
  /// `360P省流 / 480P流畅 / 720P高清 / 1080P超清 / 2K原画 / 4K原画 / 帧彩映画`。
  ///
  /// ⚠️ 展示名与 `QualityOption.id` 分开：`id` 用**稳定的字符串**
  /// （`baidu_720p` 这种），`label` 才用中文。原因是 `id` 会被持久化到
  /// `playback_prefs`，而中文文案随时可能随客户端改版变化。
  static String labelFor(int type) {
    switch (type) {
      case p360:
        return '360P 省流';
      case p480:
        return '480P 流畅';
      case p720:
        return '720P 高清';
      case p1080:
        return '1080P 超清';
      case k2:
        return '2K 原画';
      case k4:
        return '4K 原画';
      case intelligentHd:
        return '帧彩映画';
      default:
        return '未知档位';
    }
  }

  /// 档位 → 短名（给画质 chip 用）。
  ///
  /// ⛔ 电视上的画质 chip **只放短名**（见项目长期约定），
  /// 所以这里单独给一份不含「省流/流畅/超清」这类后缀的短名。
  static String shortLabelFor(int type) {
    switch (type) {
      case p360:
        return '360P';
      case p480:
        return '480P';
      case p720:
        return '720P';
      case p1080:
        return '1080P';
      case k2:
        return '2K';
      case k4:
        return '4K';
      case intelligentHd:
        return '帧彩';
      default:
        return '?';
    }
  }

  /// 档位 → 稳定 id（会被持久化，**不要改**）。
  static String idFor(int type) => 'baidu_$type';

  /// 稳定 id → 档位。解析不出来返回 `null`。
  static int? typeFromId(String id) {
    const prefix = 'baidu_';
    if (!id.startsWith(prefix)) return null;
    return int.tryParse(id.substring(prefix.length));
  }

  /// 档位 → 近似高度（用于 `QualityLabels.sortWeight` 排序与归挡）。
  ///
  /// ⚠️ 这是**标称值**，不是实测分辨率。百度返回的转码流不带宽高元数据，
  /// 所以只能按档位名反推。`帧彩映画` 是 AI 增强而非固定分辨率，
  /// 给 `null` 让排序器按 id 里的数字排（它会落到最后）。
  static int? heightFor(int type) {
    switch (type) {
      case p360:
        return 360;
      case p480:
        return 480;
      case p720:
        return 720;
      case p1080:
        return 1080;
      case k2:
        return 1440;
      case k4:
        return 2160;
      default:
        return null;
    }
  }

  /// 会员档位是否够切到 [type]。
  ///
  /// 判据来自客户端：非 SVIP 只能待在默认的低档。
  /// [vipType] 取值见 [BaiduVipType]。
  static bool requiresSvip(int type) => type > p480;

  /// 指定会员等级下的默认档位。
  ///
  /// 【客户端】非 SVIP → 480P，SVIP → 1080P。见类文档的表格。
  static int defaultFor(int vipType) =>
      vipType == BaiduVipType.svip ? p1080 : p480;
}

/// 百度会员档位。
///
/// 【客户端】`v888js/renderer.js` 里的 `{normal:0, vip:1, svip:2}`，
/// 与 `VipType` 枚举逐字一致。
class BaiduVipType {
  const BaiduVipType._();

  static const int normal = 0;
  static const int vip = 1;
  static const int svip = 2;

  static String labelFor(int type) {
    switch (type) {
      case svip:
        return '超级会员';
      case vip:
        return '会员';
      default:
        return '普通用户';
    }
  }
}
