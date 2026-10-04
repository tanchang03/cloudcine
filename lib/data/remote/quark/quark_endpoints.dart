/// 夸克 PC 自用接口的端点与请求常量。
///
/// **重要区分**（PoC 结论）：
///   - 官方开放平台：`open-api-drive.quark.cn`，需 OAuth `access_token`；
///   - 本文件用的是**PC 客户端自用接口**：`drive-pc.quark.cn`，
///     靠网页登录态 Cookie（`__pus` / `__puus`）鉴权。
///
/// 两者不可混用：本机 Cookie 换不到开放平台的 token，反之亦然。
library;

class QuarkEndpoints {
  const QuarkEndpoints._();

  /// PC 网关。PoC 实测全部端点在此域名下可用。
  static const String pcGateway = 'https://drive-pc.quark.cn';

  /// 备用网关。列目录/取直链实测同样可用，作为降级备选。
  static const String altGateway = 'https://drive.quark.cn';

  /// 网页版来源，用于构造 `Referer` / `Origin`。
  static const String webOrigin = 'https://pan.quark.cn';

  /// 授权登录入口（浏览器授权时打开的地址）
  static const String loginUrl = 'https://pan.quark.cn/';

  // -------------------------------------------------------------------
  // 端点（相对路径）
  // -------------------------------------------------------------------

  /// 配置 / 会话校验。最轻量的连通性探测。
  static const String config = '/1/clouddrive/config';

  /// 用户信息：昵称、容量、会员档位
  static const String member = '/1/clouddrive/member';

  /// 列目录
  static const String fileSort = '/1/clouddrive/file/sort';

  /// 搜索（全盘，不限目录）
  static const String fileSearch = '/1/clouddrive/file/search';

  /// 创建文件/文件夹。
  ///
  /// 请求体：`{dir_init_lock, dir_path, file_name, pdir_fid}`。
  /// `pdir_fid="0"` 为根目录；`file_name` 是文件夹名。
  /// 同名重复创建幂等，返回已有目录 fid。
  static const String fileCreate = '/1/clouddrive/file';

  /// 删除文件/文件夹。
  ///
  /// 请求体：`{action_type, filelist, exclude_fids}`。
  /// `action_type=2` 为永久删除；`filelist` 是 fid 列表。
  static const String fileDelete = '/1/clouddrive/file/delete';

  /// 移动文件/文件夹（批量）。
  ///
  /// 请求体：`{action_type, to_pdir_fid, filelist, exclude_fids}`。
  /// `action_type=1` 为移动；`to_pdir_fid` 是目标目录 fid。
  ///
  /// ⚠️ 与 [fileDelete] **同族**（同一个 `action_type` + `filelist` 组合），
  /// 所以字段名可以从 delete 那条直接推。但**别照抄官方开放平台文档**：
  /// `open-api-drive.quark.cn` 的 `/open/v1/file/move` 用的是
  /// `fid_list` + `fid_list≤100`，字段名与本网关**不一样**，两套网关
  /// 不能混（鉴权也不同，见 `QuarkEndpoints.pcGateway` 的注释）。
  ///
  /// ⚠️ 一次最多带 100 个 fid（来源是官方 `file/move` 的 `fid_list` 上限，
  /// 社区实现与本网关同族接口都按这个数）。见
  /// `driveMaxFidsPerRequest`。
  static const String fileMove = '/1/clouddrive/file/move';

  /// 上传预请求（秒传判定 + 分片地址分配）。
  ///
  /// 请求体含 `file_name`、`size`、`pdir_fid`、`format_type`、
  /// `l_created_at` / `l_updated_at`（毫秒时间戳）。
  /// 响应 `data.finish=1` 时秒传命中，直接返回 `fid`。
  static const String uploadPre = '/1/clouddrive/file/upload/pre';

  /// 上传完成的**第二步**：通知夸克把已合并的对象登记成文件。
  ///
  /// 请求体：`{task_id, obj_key}`。
  ///
  /// ⚠️ **不是** `{task_id, part_info_list}`。分片的真正合并由 OSS 的
  /// `CompleteMultipartUpload` 完成（见 `QuarkAdapter._completeMultipartUpload`）。
  /// 只调本端点、或把 body 写成 `part_info_list`，都会得到
  /// `code=43001 request cpp error[complete file failed!]` —— 服务端找不到
  /// 可合并的对象。这两步缺一不可，且顺序不能反。
  static const String uploadFinish = '/1/clouddrive/file/upload/finish';

  /// 更新文件哈希（秒传判定）。
  ///
  /// 请求体：`{md5, sha1, task_id}`。
  /// 响应 `data.finish=true` 且返回 `fid` → 秒传成功。
  static const String uploadHash = '/1/clouddrive/file/update/hash';

  /// 获取分片上传授权。
  ///
  /// 请求体：`{auth_info, auth_meta, task_id}`。
  /// 响应 `data.auth_key` 为 OSS PUT 请求的 `Authorization` 头值。
  static const String uploadAuth = '/1/clouddrive/file/upload/auth';

  /// 取下载直链。
  ///
  /// ⚠️ **单文件约 50MiB 硬上限**（超限返回 `code=23018`）。这是 PC 网页版
  /// 「下载」这条产品路径的限制，**不是**文件能不能播的限制。
  /// 播放走 [fileAudioplay]。
  static const String fileDownload = '/1/clouddrive/file/download';

  /// 取音频播放直链（**播放主路径**）。
  ///
  /// 2026-09-24 实测结论（三个独立探针交叉验证）：
  ///   - **不受 50MiB 限制**：774.1MB 的整轨 WAV 照样返回 `code=0` + `audio_url`；
  ///   - 给的是**原文件**，不是转码流：`Content-Range` 总长逐字节等于原体积
  ///     （比值 1.0000），首字节 magic 与原格式一致；
  ///   - 支持 Range（`206` + `Accept-Ranges: bytes`），可拖动进度；
  ///   - **必须带 Cookie**，裸链返回 `412 Precondition Failed`；
  ///   - **不需要额外签名**，沿用 `pr=ucpro&fr=pc` + Cookie 即可。
  ///
  /// 这是夸克客户端自己用的接口（逆向 `/Applications/Quark.app` 得到），
  /// 因此属于**未公开路由**，存在被改动的风险 —— 所以调用方要保留
  /// [fileDownload] 作为兜底。
  static const String fileAudioplay = '/1/clouddrive/file/audioplay';

  // -------------------------------------------------------------------
  // 视频播放路由（逆向客户端得到，**未经实测验证**）
  // -------------------------------------------------------------------

  /// 视频播放接口。
  ///
  /// 来源：逆向 `/Applications/Quark.app` 7.2.0.992 的
  /// `Resources/assets/flutter/App.framework`（包名 `quark_video_paly`），
  /// 端点族见 `poc/_diag_playroute.py`。
  ///
  /// ⚠️ **未实测**：PoC 脚本打过它但没有把结论落盘。因此
  /// `QuarkAdapter` 只把它当作「比 audioplay 多拿一点信息」的候选，
  /// 失败就降级 —— 不依赖它必须可用。
  static const String fileV2Play = '/1/clouddrive/file/v2/play';

  /// 播放信息预取（**清晰度梯度的唯一来源**）。
  ///
  /// 客户端的请求体带 `resolutions: "normal,low,high,super,2k,4k"`，
  /// 响应里应当带各档转码流的地址。同样**未实测**。
  static const String playInfo = '/1/clouddrive/batch/file/play/info';

  /// 转码预览状态机（`doing/fail/type_fail/size_fail`）。
  ///
  /// 客户端里有这个端点，其中 `size_fail` 的文案是「文件体积较大，
  /// 暂不支持在线预览」—— 说明服务端**确实存在转码预览**这条路径。
  /// 本应用暂不调用它，留作后续「预览图/缩略图」功能的入口。
  static const String filePreview = '/1/clouddrive/file/preview';

  // -------------------------------------------------------------------
  // 扫码登录（CAS）
  // -------------------------------------------------------------------

  /// CAS 认证服务 —— **扫码登录真正的服务端**。
  ///
  /// ⚠️ 2026-09-24 踩过的坑：别去找 `user-auth-server.quark.cn` 或
  /// `utoken2.uc.cn`，那两个域的 `/cas/ajax/*` 全是 404。它们出现在
  /// 客户端原生二进制里，但**不是**网页侧扫码登录用的服务端。
  /// 真正可用的配置写死在网盘前端 bundle 里：
  /// `scanLoginPage` / `mobileLoginPage` / `passwordLoginPage` 全部指向
  /// `uop.quark.cn`。实测两个接口均**无鉴权、无签名**。
  static const String casGateway = 'https://uop.quark.cn';

  /// 取二维码 token。响应 `data.members.token`。
  static const String casQrToken = '/cas/ajax/getTokenForQrcodeLogin';

  /// 用 token 轮询换 service ticket。
  static const String casQrServiceTicket =
      '/cas/ajax/getServiceTicketByQrcodeToken';

  /// 票据 → 账号 Cookie 的兑换端点（**网页端扫码登录的最后一跳**）。
  ///
  /// 从 pan.quark.cn 主 bundle 逆向得到（`doAuth` 函数，生产配置
  /// `bizHost: "https://pan.quark.cn"`）：
  ///
  /// ```
  /// GET /account/info?st=<service_ticket>
  /// → 200 + {"success":true,"data":{...}}
  ///   + Set-Cookie: __pus=…; __puus=…   ← 账号 Cookie 在这里
  /// ```
  ///
  /// ⚠️ 踩坑记录：`/cas/ajax/loginWithServiceTicket`（pan/uop 两个域）是给
  /// 浏览器整页跳转用的旧 CAS 端点，AJAX 语义下**不会**下发账号 Cookie，
  /// 真机实测两轮全部失败后换成这个端点。
  static const String accountInfo = 'https://pan.quark.cn/account/info';

  /// 登录成功后网页版跳转的候选首页（`onLoginSuccess` → `window.location`）。
  ///
  /// 兑换拿到 `__pus` 后**补一跳**到这里：`__puus` 不在 `/account/info` 的
  /// 响应里（前端 bundle 里 `__puus` 出现 0 次，是服务端动态下发），
  /// 而是在登录后的第一个页面请求的 Set-Cookie 里下发。真机实测 2026-09-24：
  /// `/account/info` 只给了 `__pus`/`__kp`/`__kps`/`__ktd`/`__uid`，缺 `__puus`；
  /// JSON 语义补跳也拿不到 —— 必须页面导航语义（`Accept: text/html`）。
  static const List<String> postLoginHomeUrls = [
    'https://pan.quark.cn/list/all',
    'https://pan.quark.cn/',
  ];

  /// 网页侧 `client_id`。
  ///
  /// ⚠️ 与桌面客户端的 `533` 是**两个不同的端**：
  /// 桌面端 `LoginConfig.quarkScan.clientId = "533"`，网页端写死 `532`。
  static const String webClientId = '532';

  /// 网页版扫码登录页（二维码里装的**确认页**地址，不是登录页）。
  ///
  /// 实测 `https://su.quark.cn/4_eMHBJ` → 302 → `b.quark.cn/apps/…`，
  /// 标题「端内登录确认页」。手机扫码后打开的正是它。
  /// 桌面端对应的是 `https://su.quark.cn/8_iWD15`。
  static const String webScanLoginPage = 'https://su.quark.cn/4_eMHBJ';

  /// 二维码里那串业务参数（照抄桌面客户端的 `uc_biz_str`）。
  ///
  /// 含义：`S:custom`（自定义皮肤）+ `OPT:SAREA@0`（非安全区）+
  /// `OPT:IMMERSIVE@1`（沉浸式）+ `OPT:BACK_BTN_STYLE@0`。
  /// 只影响确认页的显示长相，与取票/轮询无关；网页端实测带着它扫码确认正常，
  /// 但没逐项对照过去掉会怎样，所以先原样保留。
  static const String qrBizStr =
      'S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401'
      '%7COPT%3ABACK_BTN_STYLE%400';

  // -------------------------------------------------------------------
  // 请求常量
  // -------------------------------------------------------------------

  /// 根目录 ID。夸克用 `'0'` 表示根。
  static const String rootId = '0';

  /// 所有请求都必须带的公共参数。
  ///
  /// 注意：`fr` 必须与账号类型匹配。实测用 `fr=mac` 会返回
  /// `code=31001 require login [guest]`，因此固定为 `pc`。
  static const Map<String, String> commonParams = {
    'pr': 'ucpro',
    'fr': 'pc',
  };

  /// PoC 实测可用的 UA（Chrome on macOS）
  static const String userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static const String referer = 'https://pan.quark.cn/';
  static const String origin = 'https://pan.quark.cn';
  static const String accept = 'application/json, text/plain, */*';
  static const String acceptLanguage = 'zh-CN,zh;q=0.9';

  /// 列目录默认排序：目录优先、更新时间倒序
  static const String defaultSort = 'file_type:asc,updated_at:desc';

  /// 搜索排序：**文件优先**。
  ///
  /// 实测（2026-09-23）：
  ///   - `file_type:asc`（默认）→ 返回的前 20 条**全是目录**；
  ///   - `file_type:desc` → 前 20 条**全是文件**。
  /// 音乐检索只关心文件，所以搜索用后者，避免用户翻半天全是目录。
  static const String searchSort = 'file_type:desc,updated_at:desc';

  /// 网页登录态 Cookie 的域名集合。
  ///
  /// 浏览器授权时需要从这两个域取 Cookie：登录动作发生在 `pan.quark.cn`，
  /// 而接口调用走 `drive-pc.quark.cn`。
  static const List<String> cookieDomains = [
    'https://pan.quark.cn',
    'https://drive-pc.quark.cn',
  ];

  /// 会话必需 Cookie —— 缺任一即视为未登录。
  static const List<String> essentialCookieNames = ['__pus', '__puus'];

  /// 会一并抓取的已知 Cookie（便于服务端识别设备/账号）。
  ///
  /// ⚠️ `Video-Auth` **不能少**（2026-10-04 实测）：它由签发**转码档**的
  /// `/file/play/info` 下发，而转码档的地址是 `media.m3u8` —— 那个 URL
  /// **不带签名**（同一个文件隔几小时取回来一模一样），鉴权全靠这个 cookie。
  /// 少了它，mpv 去取 m3u8 / 分片会拿到 **404**，表现是「只有声音没画面、
  /// 播两秒就 EOF」。
  ///
  /// 原画走的是 `/file/audioplay`，地址自带 `auth_key` 签名、且那个接口
  /// 不下发 `Video-Auth` —— 这正是「原画正常、转码档全挂」的分界线。
  static const List<String> knownCookieNames = [
    '__pus',
    '__puus',
    '__kuus',
    '__uid',
    '__kp',
    '__kps',
    '__ktd',
    '__kui',
    'Video-Auth',
  ];

  /// 组装 `Cookie:` 头时的优先顺序（关键键在前，便于日志排查）
  static const List<String> cookieHeaderOrder = [
    '__pus',
    '__puus',
    '__kuus',
    '__uid',
    '__kp',
  ];

  /// 直链过期时间的兜底 TTL。
  ///
  /// 正常情况下用不到：夸克直链的 `auth_key` 参数第 1 段就是真实过期时刻
  /// （unix 秒），由 `QuarkMapper.parseUrlExpiry` 解析。
  ///
  /// ⚠️ **只有第 1 段可信**。2026-09-24 实测 `auth_key` 形如
  /// `<过期unix秒>-<第二段>-<TTL秒>-<签名>`，其中 TTL 段**随路由与文件变化**：
  ///
  /// | 路由 | 文件 | 第1段−now | 第3段 TTL |
  /// |---|---|---|---|
  /// | download | 15.1MB | 21601s | 21600（6h） |
  /// | audioplay | 15.1MB | 10801s | 10800（3h） |
  /// | audioplay | 774.1MB | 18405s | 18404（5.11h） |
  ///
  /// 即**播放路由的地址过期更快且不固定**，所以更不该长期缓存票据。
  ///
  /// 这里只在**解析不出来**时兜底。取 30 分钟是折中：远小于实测最短的 3 小时
  /// （不会导致播放中途断流），又不必每次起播都重新取链。
  static const Duration ticketFallbackTtl = Duration(minutes: 30);
}
