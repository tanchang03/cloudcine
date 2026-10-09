/// 百度网盘**扫码登录**的数据层。
///
/// ## 完整链路（三跳，全部在 `passport.baidu.com`，无鉴权无签名）
///
/// ```
/// 1. GET /v2/api/getqrcode?lp=pc&qrloginfrom=pc&gid={gid}
///      → {errno:0, sign:"…", imgurl:"//passport.baidu.com/v2/api/qrcode?sign=…"}
/// 2. 把 imgurl 的图片画成二维码，用户用百度网盘 App 扫码
///    GET /channel/unicast?channel_id={sign}&gid={gid}&tpl=netdisk&_sdkFrom=1&apiver=v3&tt={ms}
///      → jsonp: cb({errno:1})                        ← 还没扫，继续轮询
///      → jsonp: cb({errno:0, channel_v:"{…}"})        ← channel_v 是**字符串**，要再 parse
///           channel_v.status = "1" → 已扫，等用户在手机上点确认
///           channel_v.status = "0" → 已确认，带 v / u，可以换 BDUSS
///           channel_v.status = "2" → 用户在手机上取消了
/// 3. GET /v3/login/main/qrbdusslogin?v={ms}&bduss={channel_v.v}&u={channel_v.u}
///        &loginVersion=v5&qrcode=1&tpl=netdisk&maskId=&fileId=
///      → {errInfo:{no:0}, data:{…}}  + Set-Cookie: BDUSS=…   ← 凭证在这里
/// 4. 跟 302 落到 `pan.baidu.com`（**换票的 `u` 参数就是落点**），
///    把**网盘域**下发的 Cookie 一并收下                       ← 见 [_settleOnPan]
/// ```
///
/// ## ⛔ 第 4 步不能省（2026-10-09 定位）
///
/// 客户端登录链的第 3 步回的是 **302**，而它的 WebView 会**跟着跳**到
/// `pan.baidu.com` —— 逆向出来的 Cookie 域过滤表是
/// `^\.baidu\.com$|^\.pan\.baidu\.com$|^\.passport\.baidu\.com$|^\.pcs\.baidu\.com$`，
/// 网盘域那一项只可能由**这一跳**产生。
///
/// 本适配器早先为了拿到 3xx 响应里的 `Set-Cookie` 而 `followRedirects: false`，
/// 于是**没有任何人访问落点**：手里只有 passport 域的凭证，网盘侧不认，
/// 紧接着 `/api/account/uinfo` 回 `errno=-6`（「登录状态无效」）——
/// 现象就是「手机显示授权成功、PC 端却提示登录失败」。
///
/// ## 为什么是这条路，而不是官方开放平台的设备码
///
/// 官方那套（`/oauth/2.0/device/code`）**也能扫码**，而且 `refresh_token`
/// 有 10 年 —— 但受 `/apps/{appname}/` 限制，**扫不出用户已有的媒体库**。
/// 本客户端走的是 **Mac 客户端同款**链路（那个客户端自己就是打开
/// `pan.baidu.com/disk/maclogin` 扫的），因此拿到的是**全盘可用**的会话。
///
/// ## ⛔ 三个照抄客户端的细节，改一个就登不上
///
/// 1. **`channel_v` 是字符串不是对象**。它是被服务端二次编码过的 JSON
///    （`"{\"v\":\"…\"}"`）。直接当 Map 用会拿不到任何字段，而现象是
///    「扫码确认了但页面一直转圈」—— 因为 `status` 永远是 `null`。
/// 2. **成功判据是 `errInfo.no == 0`**，不是 `data.errno`。客户端源码里是
///    `0==n.errInfo.no || 0==n.data.errno`，两个都要认。
/// 3. **`tpl=netdisk`**。它是业务线标识，填错服务端会按别的业务线签发凭证
///    （可能拿到一个网盘用不了的 BDUSS）。
///
/// ## ⛔ 长轮询会挂住 ~30 秒，这不是故障
///
/// `/channel/unicast` 没有事件时会**一直不返回**，直到超时或事件到达。
/// 实测（2026-10-08）挂约 30 秒后回 `cb({"errno":1})`。所以：
///   - HTTP 超时必须给到 40 秒以上，否则每次轮询都「超时」；
///   - 客户端源码里的 35 秒 `setTimeout` 是**它自己的**看门狗（超时后
///     展示「二维码加载失败，点击刷新」），不是服务端的 TTL。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/cookie_parser.dart';
import '../../core/utils/redact.dart';
import '../http/http_client.dart';
import '../remote/baidu/baidu_endpoints.dart';

/// 一次扫码登录会话。
class BaiduQrSession {
  const BaiduQrSession({
    required this.sign,
    required this.imgUrl,
    required this.gid,
    required this.createdAt,
  });

  /// 二维码的 `sign`。
  ///
  /// ⚠️ 它同时是长轮询的 `channel_id`，也是这次登录的凭据之一 ——
  /// **不要进日志**。
  final String sign;

  /// 二维码图片地址（**已经补好 `https://` scheme**）。
  ///
  /// 服务端返回的 `imgurl` 缺 scheme，**两种形态都见过**：
  ///   - 协议相对 `//passport.baidu.com/…`
  ///   - 仅 host 相对 `passport.baidu.com/…`（**实测以此为主**）
  /// 不补 scheme 的话 `Uri.parse` 得到的 URI 没有 host，
  /// 之后 `getBytes` 直接发不出请求 —— 页面就会一直显示
  /// 「二维码加载失败，点击重试」。
  final Uri imgUrl;

  /// 本次会话的 `gid`（32 位十六进制随机串）。
  ///
  /// ⚠️ **三跳必须用同一个 `gid`**：它在第 1 跳生成、第 2 跳回传、
  /// 第 3 跳作为 `u` 的兜底来源。三跳各生成一个会让服务端认不出
  /// 这是同一次登录。
  final String gid;

  final DateTime createdAt;
}

/// 轮询结果。
sealed class BaiduQrPollOutcome {
  const BaiduQrPollOutcome();
}

/// 还没扫（长轮询超时返回，或 `errno != 0` 且没有 `channel_v`）。继续轮询。
class BaiduQrWaiting extends BaiduQrPollOutcome {
  const BaiduQrWaiting();
}

/// 已扫码，**等用户在手机上点「确认登录」**。
///
/// 单独一个状态而不是并进 [BaiduQrWaiting]：界面上这两句话完全不同
/// （「请用 App 扫码」vs「已在手机上确认」），合并会让用户以为没扫上。
class BaiduQrScanned extends BaiduQrPollOutcome {
  const BaiduQrScanned();
}

/// 用户已在手机上确认 —— 拿到了换 BDUSS 所需的两个值。
class BaiduQrConfirmed extends BaiduQrPollOutcome {
  const BaiduQrConfirmed({required this.v, required this.u});

  /// `channel_v.v`，作为第 3 跳的 `bduss` 参数。**是凭据，别进日志**。
  final String v;

  /// `channel_v.u`（**已 `decodeURIComponent`**）。
  final String u;
}

/// 用户在手机上点了取消。
class BaiduQrCancelled extends BaiduQrPollOutcome {
  const BaiduQrCancelled();
}

/// `sign` 失效（二维码过期）。需要重新取码。
class BaiduQrExpired extends BaiduQrPollOutcome {
  const BaiduQrExpired({required this.message});

  final String message;
}

/// 网络层失败 / 非 2xx / 没见过的业务码。
class BaiduQrError extends BaiduQrPollOutcome {
  const BaiduQrError({required this.message, this.errno});

  final String message;
  final int? errno;
}

/// 扫码登录客户端。
///
/// 依赖 [HttpClientLike] 而非 `dio`，因此单元测试可以注入假客户端，
/// **完全不发网络请求**就能覆盖三跳的全部状态分支。
class BaiduQrLoginClient {
  BaiduQrLoginClient({
    required HttpClientLike http,
    Duration? timeout,
    Duration? pollTimeout,
    String Function()? gidFactory,
    DateTime Function()? clock,
  })  : _http = http,
        _timeout = timeout ?? const Duration(seconds: 15),
        // 长轮询单独一个超时：普通请求 15 秒够了，而 unicast 会挂 30 秒。
        _pollTimeout = pollTimeout ?? const Duration(seconds: 45),
        _newGid = gidFactory ?? newBaiduGid,
        _clock = clock ?? DateTime.now;

  /// 客户端源码里的看门狗时长（35 秒）。这里只是**照抄**，用于文档与测试。
  static const Duration clientWatchdog = Duration(seconds: 35);

  /// 「落地网盘域」（[_settleOnPan]）最多跟几跳重定向。
  ///
  /// 5 是**防环**上限而不是协议要求：正常链路只有
  /// `bdusslogin(302) → pan.baidu.com/` 一跳，偶尔多一跳 `/disk/main`。
  /// 超过它说明落点是个环（服务端异常，或有人构造了 `Location`），
  /// 继续跟只会白烧时间。
  static const int _maxSettleHops = 5;

  /// 二维码有效期。客户端没有明说，服务端 `expires_in` 也没给。
  ///
  /// 取 5 分钟与夸克那一页保持一致 —— 它是**兜底**，真正判失效的是
  /// 轮询返回的 [BaiduQrExpired]。
  static const Duration sessionTtl = Duration(minutes: 5);

  final HttpClientLike _http;
  final Duration _timeout;
  final Duration _pollTimeout;
  final String Function() _newGid;
  final DateTime Function() _clock;

  /// 三跳之间要保持的 Cookie 罐。
  ///
  /// ## 为什么必须跨跳携带
  ///
  /// 百度扫码登录的三跳是**同一次会话**：第 1 跳 `getqrcode` 会下发
  /// `BAIDUID`，第 2、3 跳**必须把它带回去** —— 服务端靠它认出「这还是
  /// 同一个浏览器在扫码」。参考实现（社区 Node 脚本与 Cloudflare Worker
  /// 版）都显式做了这件事，并且明确写了一句：
  /// 「第 3 步不带回 Cookie 就拿不到正式 BDUSS」。
  ///
  /// ⚠️ 本适配器早期**三跳都不带 Cookie**（每一跳都是干净请求），等于把
  /// 一次登录拆成三次互不相干的会话。那可能让服务端签发的凭证与网盘侧
  /// 对不上 —— 现象正是「扫码成功，但紧接着调用网盘接口回 `errno=-6`」
  /// （2026-10-08 实测）。
  final Map<String, String> _jar = {};

  Map<String, String> get _headers => const {
        'Accept': '*/*',
        'User-Agent': BaiduEndpoints.passportUserAgent,
        'Referer': BaiduEndpoints.passportReferer,
      };

  /// 当前应带的 `Cookie:` 头（罐为空时不带，保持与旧行为一致）。
  Map<String, String> get _cookieHeaders =>
      _jar.isEmpty ? const {} : {'Cookie': buildCookieHeader(_jar)};

  /// 把响应的 `Set-Cookie` 并进罐里。
  void _absorbCookies(List<String> setCookieLines) {
    if (setCookieLines.isEmpty) return;
    _jar.addAll(parseSetCookieLines(setCookieLines));
  }

  /// 第 1 跳：取一个二维码。
  Future<BaiduQrSession> start() async {
    // 新一次登录 = 新罐。不清的话上一轮遗留的 `BAIDUID` 会被带回服务端，
    // 而那是**另一次**会话的标识。
    _jar.clear();

    final gid = _newGid();
    final res = await _http.get(
      '${BaiduEndpoints.passportHost}${BaiduEndpoints.getQrcode}',
      query: <String, Object?>{
        'lp': 'pc',
        'qrloginfrom': BaiduEndpoints.qrloginFrom,
        'gid': gid,
      },
      headers: _headers,
      timeout: _timeout,
    );

    // `getqrcode` 会下发 `BAIDUID`（实测），后续两跳要带回去。见 [_jar]。
    _absorbCookies(res.setCookieLines);

    if (res.isNetworkFailure) {
      diag.error('qrlogin', '百度取二维码失败：网络层 ${res.rawBody}');
      throw const BaiduQrLoginException('连不上百度认证服务，请检查网络');
    }
    if (!res.isSuccessStatus) {
      diag.error('qrlogin', '百度取二维码失败：HTTP ${res.statusCode}');
      throw BaiduQrLoginException('认证服务返回 HTTP ${res.statusCode}');
    }

    final json = parseJsonpObject(res.rawBody);
    if (json == null) {
      diag.error('qrlogin', '百度取二维码失败：响应不是 JSON');
      throw const BaiduQrLoginException('认证服务返回了无法解析的内容');
    }

    final errno = _asInt(json['errno']);

    // 客户端源码里的特判：`5e4 === +t.errno` 时展示「刷新失败」。
    if (errno == BaiduErrorCodeQr.fetchLimit) {
      diag.warn('qrlogin', '百度取二维码被限流（errno=50000）');
      throw const BaiduQrLoginException('获取二维码过于频繁，请稍后再试');
    }
    if (errno != 0) {
      diag.warn('qrlogin', '百度取二维码返回 errno=$errno');
      throw BaiduQrLoginException('获取二维码失败（errno=$errno）');
    }

    final sign = _asString(json['sign']);
    final imgRaw = _asString(json['imgurl']);
    if (sign == null || sign.isEmpty || imgRaw == null || imgRaw.isEmpty) {
      // ⚠️ 不把响应体打进日志（可能含凭据），只记键名。
      diag.error(
        'qrlogin',
        '百度取二维码响应缺字段（keys=${json.keys.toList()}）',
      );
      throw const BaiduQrLoginException('认证服务没有返回二维码');
    }

    diag.info(
      'qrlogin',
      '百度已取到二维码 sign=${maskSecret(sign)}，gid=$gid，'
          '会话Cookie键=${_jar.keys.toList()}',
    );

    return BaiduQrSession(
      sign: sign,
      // 服务端 `imgurl` 缺 scheme，两种形态都见过（详见
      // [BaiduQrSession.imgUrl]）。统一兜底成 `https://` 绝对 URL —
      // 这个地址只可能来自 `passport.baidu.com`，走 http 没意义。
      imgUrl: _normalizeImgUrl(imgRaw),
      gid: gid,
      createdAt: _clock(),
    );
  }

  /// 把服务端的 `imgurl` 兜底成带 `https://` scheme 的绝对 URL。
  ///
  /// 接受三种形态：
  ///   - `https://host/...` / `http://host/...` → 原样；
  ///   - `//host/...`（协议相对）→ 补 `https:`；
  ///   - `host/...`（**实测以此为主**，没前导 `//` 也没 scheme）→ 补成
  ///     `https://`。
  ///
  /// 旧版只判 `startsWith('//')`，实测 `imgurl` 不带前导 `//` 时会漏掉，
  /// 之后 `Uri.parse` 得到一个没 scheme 的 URI，`getBytes` 直接失败。
  /// 用 `Uri.tryParse` 先看一眼：有 scheme 就不动；没 scheme 统一补。
  static Uri _normalizeImgUrl(String raw) {
    final parsed = Uri.tryParse(raw);
    if (parsed != null && parsed.hasScheme) return parsed;
    if (raw.startsWith('//')) return Uri.parse('https:$raw');
    return Uri.parse('https://$raw');
  }

  /// 取二维码图片的原始字节（交给页面去渲染）。
  ///
  /// 返回 `null` 表示取不到 —— 页面据此展示「二维码加载失败，点击重试」，
  /// **不要**因此中断整个登录流程：图片可能只是被 CDN 抖了一下，
  /// 重新取一次往往就好。
  Future<Uint8List?> fetchQrImage(BaiduQrSession session) async {
    try {
      return await _http.getBytes(
        session.imgUrl.toString(),
        headers: _headers,
        timeout: _timeout,
      );
    } catch (e) {
      diag.warn('qrlogin', '百度二维码图片下载失败：$e');
      return null;
    }
  }

  /// 第 2 跳：轮询一次。
  ///
  /// ⚠️ **单飞由调用方保证**（页面里那个 `_polling` 标志）。本方法自己
  /// 不做并发保护 —— 它只是一次网络调用，而「同一时刻只允许一次」是
  /// 调度问题，放在页面里比藏在客户端里更容易看清。
  Future<BaiduQrPollOutcome> poll(BaiduQrSession session) async {
    final res = await _http.get(
      '${BaiduEndpoints.passportHost}${BaiduEndpoints.unicast}',
      query: <String, Object?>{
        'channel_id': session.sign,
        'gid': session.gid,
        'tpl': BaiduEndpoints.product,
        '_sdkFrom': '1',
        'apiver': 'v3',
        'tt': _clock().millisecondsSinceEpoch.toString(),
        'callback': 'cb',
      },
      headers: {..._headers, ..._cookieHeaders},
      // 长轮询专用超时（45s > 客户端看门狗 35s）。
      timeout: _pollTimeout,
    );

    // 长轮询也可能顺带回 `Set-Cookie`（会话续期），一并收下。
    _absorbCookies(res.setCookieLines);

    // ⚠️ 超时**不是错误**：长轮询本来就会挂住。dio 超时会走 networkFailure，
    // 所以这里把它当成「暂时没有事件」，而不是失败 —— 否则页面的
    // 「连续失败 3 次就报错」会在用户还没来得及扫码时就触发。
    if (res.isNetworkFailure) {
      return const BaiduQrWaiting();
    }
    if (!res.isSuccessStatus) {
      return BaiduQrError(
        message: '认证服务返回 HTTP ${res.statusCode}',
        errno: res.statusCode,
      );
    }

    final json = parseJsonpObject(res.rawBody);
    if (json == null) {
      return const BaiduQrError(message: '认证服务返回了无法解析的内容');
    }

    final errno = _asInt(json['errno']) ?? 0;

    // `channel_v` 是**被二次编码的 JSON 字符串**，见类文档第 1 条。
    final channel = _parseChannelV(json['channel_v']);

    if (channel == null) {
      // 没有事件载荷。`errno != 0` 也走这里 —— 实测 `errno:1` 就是
      // 「还没有事件」，不是错误。不打日志，否则每轮刷一行会淹掉日志。
      return const BaiduQrWaiting();
    }

    final status = _asString(channel['status']);

    switch (status) {
      case '1':
        diag.info('qrlogin', '百度扫码：已扫，等待手机确认');
        return const BaiduQrScanned();

      case '0':
        final v = _asString(channel['v']);
        final u = _asString(channel['u']);
        if (v == null || v.isEmpty) {
          // 确认了却没给 v：服务端改形状了。如实报错，别硬着头皮往下走。
          diag.warn('qrlogin', '百度扫码已确认但缺 channel_v.v');
          return const BaiduQrError(message: '扫码回执不完整，请重新扫码');
        }
        diag.info('qrlogin', '百度扫码已确认，v=${maskSecret(v)}');
        return BaiduQrConfirmed(v: v, u: u ?? '');

      case '2':
        diag.info('qrlogin', '百度扫码：用户在手机上取消了');
        return const BaiduQrCancelled();

      default:
        // `status` 为 null 或没见过的值。当作「还没事件」继续等，
        // 而不是报错 —— 报错会让一次偶发的形状变化直接废掉整次登录。
        if (errno != 0) {
          diag.debug('qrlogin', '百度扫码轮询：errno=$errno，继续等待');
        }
        return const BaiduQrWaiting();
    }
  }

  /// 第 3 跳：用确认回执换 BDUSS。
  ///
  /// ## ⛔ 顺序不能反（2026-10-09 修）
  ///
  /// 客户端**真正在用的是主线** `GET /v2/api/bdusslogin`；
  /// `/v3/login/main/qrbdusslogin` 只是**风控分支**（`errno 400023` 才走，
  /// 且要带上一条响应里的 `authsid`）。
  ///
  /// 本适配器早期把两者**弄反了**：把风控分支当主线，还给它送
  /// `loginVersion=v5` —— 而 `v5` 属于微信小程序分支 `/v3/api/mini/qrlogin`。
  /// 那个组合服务端照样回 `200` 并下发一整套 `Set-Cookie`
  /// （`BDUSS`/`STOKEN`/`PTOKEN`/`BAIDUID`…），**看起来完全成功**，
  /// 但签发的会话网盘侧不认 —— 下一步 `/api/account/uinfo` 回 `errno=-6`，
  /// 现象就是「扫码成功、手机也确认了，PC 端却提示登录状态无效」。
  ///
  /// ## 为什么保留风控分支
  ///
  /// 它是真实存在的一条路（客户端源码里没删，只是条件触发）。主线若
  /// 因版本差异拿不到凭证，多打一次请求换一次机会，代价可以接受。
  /// 但**风控本身不做降级**：`400023` 是「去 App 确认」，不是「换条路由
  /// 就好」，降级只会把真实原因盖掉。
  Future<BaiduQrLoginCookies> exchange(BaiduQrConfirmed confirmed) async {
    final mainline = await _exchangeVia(
      path: BaiduEndpoints.bdussLoginMainline,
      isPost: false,
      loginVersion: null,
      confirmed: confirmed,
    );
    if (mainline != null) {
      final panCookieNames = await _settleOnPan(mainline.location);
      await _absorbNetdiskStoken();
      return BaiduQrLoginCookies(
        cookies: {..._jar},
        rawSetCookie: mainline.setCookie,
        panCookieNames: panCookieNames,
      );
    }

    diag.warn('qrlogin', '百度主线换票未拿到 BDUSS，降级试风控分支（v4）');
    final risk = await _exchangeVia(
      path: BaiduEndpoints.qrBdussLogin,
      isPost: true,
      loginVersion: 'v4',
      confirmed: confirmed,
    );
    if (risk != null) {
      final panCookieNames = await _settleOnPan(risk.location);
      await _absorbNetdiskStoken();
      return BaiduQrLoginCookies(
        cookies: {..._jar},
        rawSetCookie: risk.setCookie,
        panCookieNames: panCookieNames,
      );
    }

    throw const BaiduQrLoginException(
      '扫码已确认，但换取登录凭证失败（服务端没有下发 BDUSS）',
    );
  }

  /// 换票的具体一跳。成功返回本跳的 `Set-Cookie` 与 302 落点，失败返回 `null`
  /// （由 [exchange] 决定降级）。
  ///
  /// [isPost] / [loginVersion] 是**两条分支的真实形状差异**，不是风格问题：
  /// 主线是 `GET` 且**不带** `loginVersion`，风控分支是 `POST` 且带 `v4`。
  Future<_ExchangeOutcome?> _exchangeVia({
    required String path,
    required bool isPost,
    required String? loginVersion,
    required BaiduQrConfirmed confirmed,
  }) async {
    final now = _clock().millisecondsSinceEpoch;

    // 记下换票**前**罐里有哪些键 —— 换票响应会往罐里加东西，之后再读就
    // 分不清「我们带过去了什么」和「服务端刚下发什么」了。
    final sentCookieKeys = _jar.keys.toList();

    // `u` 是「登录成功后跳转的落点」。服务端在 `channel_v.u` 里给（实测），
    // 但**它可能为空** —— 空串会让服务端按「无落点」签发，可能拿到一个
    // 网盘侧用不了的凭证。此时退回 Mac 客户端写死的 `https://pan.baidu.com/`
    // （[BaiduEndpoints.postLoginUrl]，客户端源码里的 `u: "https://pan.baidu.com/"`）。
    final u = confirmed.u.isNotEmpty ? confirmed.u : BaiduEndpoints.postLoginUrl;

    // 两条分支的参数形状**不同**，不能共用一份：
    //   · 主线（GET）：客户端只送 `tt / bduss / u / qrcode / tpl`；
    //   · 风控分支（POST）：多送 `v`、`loginVersion=v4`、`maskId`、`fileId`。
    // 早先把 `v` + `loginVersion=v5` 送给了 qrbdusslogin —— 那是小程序分支的
    // 组合，服务端照发 Cookie，但会话网盘侧不认（见 [exchange] 的文档）。
    final query = <String, Object?>{
      'tt': now.toString(),
      'bduss': confirmed.v,
      // ⚠️ 传**已解码**的值，由 HTTP 层编码一次。
      // 客户端是「先 decodeURIComponent、再 encodeURIComponent」，
      // 净效果就是原样 —— 我们再编一次就变成双重编码了。
      'u': u,
      'qrcode': '1',
      'tpl': BaiduEndpoints.product,
      if (isPost) ...{
        'v': now.toString(),
        if (loginVersion != null) 'loginVersion': loginVersion,
        'maskId': '',
        'fileId': '',
      },
    };

    final url = '${BaiduEndpoints.passportHost}$path';
    // ⚠️ 带上前面两跳攒下的 `BAIDUID` —— 服务端靠它认出「这是同一次登录」。
    final headers = {..._headers, ..._cookieHeaders};

    // ⛔ 不跟重定向：凭证在 `Set-Cookie` 里，而 3xx 的 Set-Cookie
    // 跟丢就没了（夸克那边踩过同一个坑，见 `HttpClientLike.get` 的文档）。
    final res = isPost
        ? await _http.post(
            url,
            query: query,
            headers: headers,
            timeout: _timeout,
          )
        : await _http.get(
            url,
            query: query,
            headers: headers,
            followRedirects: false,
          );

    // 2xx 与 3xx 都接受：服务端可能用 302 下发 Cookie。
    final acceptable = res.statusCode >= 200 && res.statusCode < 400;

    // 换票这一跳是凭证的主要来源，收下它的 `Set-Cookie`。
    _absorbCookies(res.setCookieLines);
    final cookies = parseSetCookieLines(res.setCookieLines);

    diag.info(
      'qrlogin',
      '百度换票（$path，${isPost ? "POST" : "GET"}）→ HTTP ${res.statusCode}，'
          '请求带Cookie键=$sentCookieKeys，'
          '响应SetCookie键=${cookies.keys.toList()}',
    );

    if (!acceptable) {
      diag.warn('qrlogin', '百度换票（$path）HTTP ${res.statusCode}');
      return null;
    }

    // 业务判据（客户端源码）：`errInfo.no == 0 || data.errno == 0`，
    // **外加顶层 `errno == 0`** —— 主线 `/v2/api/bdusslogin` 用的是顶层
    // `errno`（实测无效 bduss 回 `errno:1`），只认前两个会把它误判成失败。
    final json = parseJsonpObject(res.rawBody);
    if (json != null) {
      final errInfo = json['errInfo'];
      final no = errInfo is Map ? _asInt(errInfo['no']) : null;
      final data = json['data'];
      final dataErrno = data is Map ? _asInt(data['errno']) : null;
      final topErrno = _asInt(json['errno']);
      final ok = no == 0 || dataErrno == 0 || topErrno == 0;
      if (!ok) {
        diag.warn(
          'qrlogin',
          '百度换票（$path）业务失败：errInfo.no=$no, '
              'data.errno=$dataErrno, errno=$topErrno',
        );
        // 风控单独提一句：它不是「失败」，而是「要去 App 里确认」。
        if (no == BaiduErrorCodeQr.riskControl ||
            dataErrno == BaiduErrorCodeQr.riskControl ||
            topErrno == BaiduErrorCodeQr.riskControl) {
          throw const BaiduQrLoginException(
            '百度账号触发了安全验证，请先在手机百度网盘 App 内确认后重试',
          );
        }
        return null;
      }
    }

    final bduss = cookies['BDUSS'];
    if (bduss == null || bduss.isEmpty) {
      diag.warn(
        'qrlogin',
        '百度换票（$path）未下发 BDUSS，拿到键=${cookies.keys.toList()}',
      );
      return null;
    }

    // 返回本跳的 `Set-Cookie` 原文（[BaiduQrLoginCookies.rawSetCookie] 用）
    // 与 302 落点 —— 后者是 [exchange] 里 [settleOnPan] 那一跳的起点。
    // ⚠️ 凭证本身不在这里组装：落点那一跳还会往罐里加网盘域的 Cookie，
    //    提前组装会漏掉它们（见 [_settleOnPan]）。
    return (
      setCookie: res.setCookieLines,
      location: res.header('location'),
    );
  }

  /// 客户端登录链的**第 4 步**：把会话「落地」到网盘域。
  ///
  /// ## 为什么非做不可（2026-10-09 定位）
  ///
  /// 逆向客户端在这一步是 **WebView 跟着 302 跳到 `pan.baidu.com`**
  /// （`bdusslogin` 的 `u` 参数就是那个落点），然后**从 WebView 的 Cookie
  /// 罐里**取凭证 —— 它的域过滤表明确列了
  /// `^\.baidu\.com$|^\.pan\.baidu\.com$|^\.passport\.baidu\.com$|^\.pcs\.baidu\.com$`，
  /// 而**网盘域那一项只可能由这一跳下发**。
  ///
  /// 我们早先为了拿到 3xx 响应里的 `Set-Cookie` 而 `followRedirects: false`，
  /// 结果**没有任何人访问落点**：手里只有 passport 域的凭证，网盘侧不认，
  /// 于是 `/api/account/uinfo` 回 `errno=-6`（「登录状态无效」）——
  /// 现象正是「手机显示授权成功、PC 端却登录失败」。
  ///
  /// ## 为什么自己走重定向链，而不是 `followRedirects: true`
  ///
  /// dio 的 `Response.headers` 只有**最后一跳**的头。自动跟随会把中途每一跳
  /// 的 `Set-Cookie` 全丢掉 —— 而我们要的恰恰是它们。所以手动逐跳走，
  /// 每跳都吸收一次（这也正是浏览器的行为）。
  ///
  /// ## 边界
  ///
  /// - 只在 `baidu.com` 域内跟随：凭据不能被一个伪造的 `Location` 带去外站。
  /// - 失败（网络、404、超出跳数、成环）**只记日志**，绝不让整次登录失败 ——
  ///   它是加分项，不是前提。
  ///
  /// 返回**这一跳收到的 Cookie 名**（去重排序）。调用方要把它们交给
  /// [filterBaiduCookiesForCredential] 放行 —— 那些名字不在固定名单里
  /// （`PANWEB` / `PANPSC` …），只按固定名单过滤会把它们一起丢掉，
  /// 等于把这一跳白做了。
  Future<List<String>> _settleOnPan(String? location) async {
    var url = _settleTarget(location);
    final visited = <String>{};
    final collected = <String>{};

    for (var hop = 0; hop < _maxSettleHops; hop++) {
      if (!visited.add(url)) {
        diag.debug('qrlogin', '百度落地网盘域出现环（$url），停止');
        break;
      }

      HttpResult res;
      try {
        res = await _http.get(
          url,
          // ⛔ 自己走重定向：`followRedirects: true` 只留最后一跳的头，
          //    会把中途的 `Set-Cookie` 全丢掉（见方法文档）。
          followRedirects: false,
          headers: {
            ..._headers,
            // 这一步是**页面导航**而不是 XHR（客户端是 WebView 跳转）。
            'Accept': BaiduEndpoints.pageAccept,
            // 浏览器的 Referer 就是「上一页」，逐跳更新。
            'Referer': url,
            ..._cookieHeaders,
          },
          timeout: _timeout,
        );
      } catch (e) {
        diag.warn('qrlogin', '百度落地网盘域异常（不影响登录）：$e');
        break;
      }

      final added = parseSetCookieLines(res.setCookieLines);
      _absorbCookies(res.setCookieLines);
      collected.addAll(added.keys);

      if (added.isEmpty) {
        diag.debug(
          'qrlogin',
          '百度落地网盘域：$url → HTTP ${res.statusCode}（无新 Cookie）',
        );
      } else {
        diag.info(
          'qrlogin',
          '百度落地网盘域：$url → HTTP ${res.statusCode}，'
              '收到Cookie键=${added.keys.toList()}',
        );
      }

      final next = _redirectTarget(res, url);
      if (next == null) break;
      url = next;
    }

    return collected.toList()..sort();
  }

  /// 落地起点：优先 302 的 `Location`，没有就用客户端写死的落点
  /// （[BaiduEndpoints.postLoginUrl]）。
  ///
  /// ⚠️ 相对 `Location`（`/v2/api/…`）按 **passport 域**补全 —— 服务端
  /// 确实可能这么回，而 `Uri.resolve` 需要一个基准。
  static String _settleTarget(String? location) {
    final raw = location?.trim();
    if (raw == null || raw.isEmpty) return BaiduEndpoints.postLoginUrl;

    final resolved = Uri.tryParse(BaiduEndpoints.passportHost)?.resolve(raw);
    if (resolved == null || !_isBaiduHost(resolved.host)) {
      // ⛔ 外站落点不跟：凭证不能被带去别的地方。退回客户端写死的落点。
      diag.warn(
        'qrlogin',
        '百度换票落点不在百度域（host=${resolved?.host ?? "?"}），改用默认落点',
      );
      return BaiduEndpoints.postLoginUrl;
    }
    return resolved.toString();
  }

  /// 3xx 的下一跳。非重定向 / 没有 `Location` / 跳出百度域 ⇒ `null`（停止）。
  static String? _redirectTarget(HttpResult res, String currentUrl) {
    if (res.statusCode < 300 || res.statusCode >= 400) return null;

    final raw = res.header('location')?.trim();
    if (raw == null || raw.isEmpty) return null;

    final resolved = Uri.tryParse(currentUrl)?.resolve(raw);
    if (resolved == null) return null;

    if (!_isBaiduHost(resolved.host)) {
      diag.warn(
        'qrlogin',
        '百度落地重定向跳出百度域（host=${resolved.host}），停止跟随',
      );
      return null;
    }
    return resolved.toString();
  }

  /// 是否百度域（含子域）。落地链只在这里面走。
  static bool _isBaiduHost(String host) =>
      host == 'baidu.com' || host.endsWith('.baidu.com');

  /// 客户端登录链的**第 5 步**：把 `BDUSS` + `PTOKEN` 换成 netdisk 专用 `STOKEN`。
  ///
  /// ## 为什么要有这一步
  ///
  /// 换票响应的 `Set-Cookie` 里**已经**有 `STOKEN`，所以这不是前提而是
  /// **补强** —— 客户端仍然专门再换一次，说明它认的是
  /// `stoken_list.netdisk` 那个**按业务线区分**的值。
  ///
  /// ## 边界
  ///
  /// - 只接受**明确写着 `netdisk` 的条目**：拿不到就沿用罐里已有的 `STOKEN`，
  ///   绝不因为「解析出个别的什么」把能用的值覆盖掉。
  /// - 任何失败（网络、形状变化、`errno != 0`）都**只记日志**，
  ///   绝不让整次登录失败 —— 它是加分项，不是前提。
  Future<void> _absorbNetdiskStoken() async {
    final bduss = _jar['BDUSS'] ?? _jar['BDUSS_BFESS'];
    if (bduss == null || bduss.isEmpty) return;
    final ptoken = _jar['PTOKEN'] ?? _jar['PTOKEN_BFESS'];

    try {
      final res = await _http.get(
        '${BaiduEndpoints.passportHost}${BaiduEndpoints.stokenAuth}',
        query: <String, Object?>{
          'bduss': bduss,
          if (ptoken != null && ptoken.isNotEmpty) 'ptoken': ptoken,
        },
        headers: {..._headers, ..._cookieHeaders},
        timeout: _timeout,
      );
      if (!res.isSuccessStatus) {
        diag.warn('qrlogin', '百度 netdisk STOKEN 换取 HTTP ${res.statusCode}，沿用现有值');
        return;
      }

      final token = _netdiskStokenFrom(parseJsonpObject(res.rawBody));
      if (token == null || token.isEmpty) {
        diag.warn('qrlogin', '百度 netdisk STOKEN 未返回 netdisk 条目，沿用换票下发值');
        return;
      }

      _jar['STOKEN'] = token;
      diag.info('qrlogin', '百度已换到 netdisk 专用 STOKEN（覆盖换票下发值）');
    } catch (e) {
      diag.warn('qrlogin', '百度 netdisk STOKEN 换取异常（不影响登录）：$e');
    }
  }

  /// 从 `stoken_list` 里取 **netdisk** 那一条。
  ///
  /// 三种形状都认（客户端各版本不同）：`{netdisk: "…"}`、
  /// `[{netdisk: "…"}]`、以及直接给字符串（无业务线区分）。
  /// ⚠️ 绝不把「别的业务线的 stoken」当成 netdisk 的 —— 那会把一个
  /// 能用的值换成不能用的。
  static String? _netdiskStokenFrom(Map<String, Object?>? json) {
    if (json == null) return null;

    final data = json['data'];
    final candidates = <Object?>[
      if (data is Map) data['stoken_list'],
      json['stoken_list'],
    ];

    for (final candidate in candidates) {
      if (candidate is Map) {
        final v = candidate['netdisk'];
        if (v is String && v.isNotEmpty) return v;
      } else if (candidate is List) {
        for (final item in candidate) {
          if (item is Map) {
            final v = item['netdisk'];
            if (v is String && v.isNotEmpty) return v;
          }
        }
      }
    }
    return null;
  }

  /// 解析 `channel_v`。
  ///
  /// 它可能是三种形态，**三种都要认**：
  ///   - 被二次编码的 JSON **字符串**（实测就是这个，客户端用
  ///     `eval("(" + d.channel_v + ")"` 或 `JSON.parse` 解它）；
  ///   - 已经是对象（未来改版）；
  ///   - `null`（没有事件）。
  static Map<String, Object?>? _parseChannelV(Object? raw) {
    if (raw == null) return null;

    if (raw is Map<String, Object?>) {
      return raw.isEmpty ? null : raw;
    }

    if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty) return null;
      final parsed = parseJsonpObject(s) ?? _tryJsonObject(s);
      if (parsed == null || parsed.isEmpty) return null;
      // `channel_v.u` 是 URL 编码的，客户端在这里 decode。
      final u = parsed['u'];
      if (u is String && u.isNotEmpty) {
        parsed['u'] = Uri.decodeComponent(u);
      }
      return parsed;
    }
    return null;
  }

  static Map<String, Object?>? _tryJsonObject(String s) {
    try {
      final decoded = jsonDecode(s);
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static String? _asString(Object? v) {
    if (v is String) return v;
    if (v == null) return null;
    return v.toString();
  }
}

/// 一次成功换票的结果。
///
/// 单独一个记录类型而不是直接返回 [BaiduQrLoginCookies]：换票之后还有
/// **「落地网盘域」**（[_settleOnPan]，客户端登录链第 4 步）与
/// **「换 netdisk STOKEN」**（第 5 步）两跳会继续往 Cookie 罐里加东西，
/// 提前组装凭证就会漏掉它们 —— 而漏掉网盘域那一批正是 `-6` 的成因。
typedef _ExchangeOutcome = ({List<String> setCookie, String? location});

/// 换票拿到的账号 Cookie。
class BaiduQrLoginCookies {
  const BaiduQrLoginCookies({
    required this.cookies,
    required this.rawSetCookie,
    this.panCookieNames = const [],
  });

  /// 解析后的 `name → value`（已去掉 path/domain/expires 等属性）。
  final Map<String, String> cookies;

  /// 原始 `Set-Cookie` 行（排查用）。
  final List<String> rawSetCookie;

  /// 「落地网盘域」那一跳（[_settleOnPan]）收到的 Cookie 名。
  ///
  /// ⚠️ 它们**不在** [BaiduEndpoints.knownCookieNames] 里（`PANWEB` /
  /// `PANPSC` …），所以落库时必须显式放行 —— 见
  /// [filterBaiduCookiesForCredential] 的 `extraNames`。
  final List<String> panCookieNames;

  List<String> get keys => cookies.keys.toList()..sort();

  bool get hasEssential => BaiduEndpoints.essentialCookieNames
      .every((name) => (cookies[name] ?? '').isNotEmpty);
}

/// 过滤出可落库的 Cookie。
///
/// [extraNames] 是**固定名单之外**要一并放行的 Cookie 名 —— 由「落地网盘域」
/// 那一跳（[_settleOnPan]）收集而来（见 [BaiduQrLoginCookies.panCookieNames]）。
///
/// ## 为什么要放行它们
///
/// 固定名单的本意是「别把换票顺带带回的无关 Cookie 长期留在本机安全存储」。
/// 但落地那一跳不一样：它只访问 `pan.baidu.com`，收到的每一项**都是网盘域
/// 自己下发的会话 Cookie** —— 正是网盘侧认会话所需的那些。按固定名单过滤
/// 会把它们一起丢掉，落地那一跳就白做了（而现象与没做时**一模一样**：
/// 依旧是 `/api/account/uinfo` 回 `-6`，很难查）。
Map<String, String> filterBaiduCookiesForCredential(
  Map<String, String> cookies, {
  Iterable<String> extraNames = const [],
}) {
  final out = <String, String>{};
  for (final name in [...BaiduEndpoints.knownCookieNames, ...extraNames]) {
    final v = cookies[name];
    if (v != null && v.isNotEmpty) out[name] = v;
  }
  // 必需项一定要在（knownCookieNames 里已含 BDUSS，这里只是防御
  // 未来有人把 BDUSS 从 known 列表里挪走）。
  for (final name in BaiduEndpoints.essentialCookieNames) {
    final v = cookies[name];
    if (v != null && v.isNotEmpty) out[name] = v;
  }
  return out;
}

/// 生成一个 `gid`：32 位十六进制随机串。
///
/// 客户端是 `crypto.randomBytes(16).toString('hex')`。
/// 用 [Random.secure] 而不是普通 `Random()`：后者是**可预测**的
/// 伪随机，而 `gid` 参与登录链路，可预测会削弱「每次会话不同」的意义。
String newBaiduGid() {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// 从可能带 jsonp 外壳的响应体里取出 JSON 对象。
///
/// 服务端会回 `cb({...})`（因为我们传了 `callback=cb`），也可能直接回
/// `{...}`（`getqrcode` 实测两种都能拿到）。所以这里**两种都吃**。
///
/// 返回 `null` 表示取不出对象 —— 调用方要把它当成「解析失败」而不是
/// 「空结果」，两者的处理完全不同。
Map<String, Object?>? parseJsonpObject(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  // 1) 直接就是 JSON
  final direct = BaiduQrLoginClient._tryJsonObject(trimmed);
  if (direct != null) return direct;

  // 2) jsonp 外壳：取**第一个 `(`** 与**最后一个 `)`** 之间的内容。
  //
  // 用「最后一个 `)`」而不是「第一个」：JSON 里嵌套的对象/数组也会带
  // 括号，取第一个会在第一个内层 `)` 处截断，得到一个半截 JSON。
  final open = trimmed.indexOf('(');
  final close = trimmed.lastIndexOf(')');
  if (open < 0 || close <= open) return null;

  final inner = trimmed.substring(open + 1, close).trim();
  if (inner.isEmpty) return null;
  return BaiduQrLoginClient._tryJsonObject(inner);
}

/// 扫码登录过程中的可预期错误。
///
/// 与 `DriveException` 分开：后者描述网盘**业务接口**错误，
/// 而这是**登录流程**自己的失败。
class BaiduQrLoginException implements Exception {
  const BaiduQrLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 扫码链路的业务码（只放这个文件用得到的）。
///
/// 网盘业务码在 `baidu_error_mapper.dart` 里，两者是**不同的域**：
/// 一个在 passport、一个在 pan，码值互不相关。
class BaiduErrorCodeQr {
  const BaiduErrorCodeQr._();

  /// 取二维码次数超限（客户端登录页里的 `5e4` 特判）。
  static const int fetchLimit = 50000;

  /// 风控拦截（要用户去 App 里确认）。
  static const int riskControl = 400023;
}
