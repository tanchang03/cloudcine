/// 夸克**扫码登录**（CAS 流程）的数据层。
///
/// ## 完整链路（2026-09-24 真机跑通）
///
/// ```
/// 1. GET /cas/ajax/getTokenForQrcodeLogin?client_id=532
///      → {"status":2000000,"data":{"members":{"token":"sta…"}}}
/// 2. 把 token 装进二维码，用户用夸克 App 扫码并确认
/// 3. GET /cas/ajax/getServiceTicketByQrcodeToken?token=<t>&client_id=532
///      未扫码 → {"status":50004001,"message":"Query result is empty"}
///      已确认 → status=2000000，data.members.service_ticket
/// 4. GET https://pan.quark.cn/account/info?st=<service_ticket>
///      → 该响应的 Set-Cookie 里下发 __pus（通常连 __puus 一起）
/// ```
///
/// 全程无鉴权、无签名，也不接触账号密码。
///
/// ## ⛔ `client_id` 必须配对（9 组矩阵实测，踩过）
///
/// | 取票 | 轮询 | 结果 |
/// |---|---|---|
/// | 不带 | 不带 | `50004001`（正常待扫码） |
/// | 不带 | 带   | `50004002 Token Not Found` ❌ |
/// | 带   | 带任意 | `50004001` |
///
/// 即「取票带了 client_id，轮询就必须带；两边都不带也行；混着用就找不到 token」。
/// 本实现**两端统一用同一个 `_clientId`**，杜绝混用。
///
/// ## ⛔ 第 4 跳不能用 `/cas/ajax/loginWithServiceTicket`
///
/// 那个端点（`pan.quark.cn` / `uop.quark.cn` 两个域都试过）是给**浏览器整页跳转**
/// 用的旧 CAS 端点：AJAX 语义下只回 `ctoken` / `_UP_*`，**不下发账号 Cookie**。
/// 网页版的真实做法在 `pan_idx.js` 的 `doAuth` 里 —— 直接 GET `/account/info?st=`。
library;

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/redact.dart';
import '../http/http_client.dart';
import '../remote/quark/quark_endpoints.dart';

/// 一次扫码登录会话：服务端下发的一次性 token + 二维码里要装的 URL。
class QrLoginSession {
  const QrLoginSession({
    required this.token,
    required this.qrUrl,
    required this.createdAt,
  });

  /// 二维码 token。**不要进日志**（它是这次登录的凭据之一）。
  final String token;

  /// 二维码内容 —— 手机扫了之后打开的「端内登录确认页」。
  final Uri qrUrl;

  final DateTime createdAt;
}

/// 轮询结果。
///
/// 基类必须有 `const` 构造函数，否则子类的 `const` 构造无法调用它
/// （`HttpResult` 那套常量响应在测试里要用 const）。
sealed class QrPollOutcome {
  const QrPollOutcome();
}

/// 还没扫（服务端 `Query result is empty`）。继续轮询。
class QrPollWaiting extends QrPollOutcome {
  const QrPollWaiting();
}

/// 服务端给了非「待扫码」的载荷 —— 扫码流程有进展了。
///
/// 保留完整 `payload` 有两个用途：取出 `data.members.service_ticket` 接着兑换，
/// 以及在服务端改响应形状时能原样看到它到底回了什么。
class QrPollConfirmed extends QrPollOutcome {
  const QrPollConfirmed({required this.status, required this.payload});

  final int status;

  /// 服务端 `data` 字段（可能为 `null`，此时是空 Map）。
  final Map<String, Object?> payload;

  /// 键名列表 —— 排查时看这个就够，不必暴露值。
  List<String> get payloadKeys => payload.keys.toList()..sort();
}

/// token 不存在或已失效（`Token Not Found`）。需要重新取票。
class QrPollExpired extends QrPollOutcome {
  const QrPollExpired({required this.status, required this.message});

  final int status;
  final String message;
}

/// 网络层失败、非 2xx、或返回了没见过的业务码。
class QrPollError extends QrPollOutcome {
  const QrPollError({required this.message, this.status});

  final String message;
  final int? status;
}

/// 扫码登录客户端。
///
/// 依赖 [HttpClientLike] 而非 `dio`，因此单元测试可以注入假客户端，
/// **完全不发网络请求**就能覆盖全部状态分支。
class QuarkQrLoginClient {
  QuarkQrLoginClient({
    required HttpClientLike http,
    String? clientId,
    String? platform,
    Duration? timeout,
  })  : _http = http,
        _clientId = clientId ?? QuarkEndpoints.webClientId,
        _platform = platform ?? 'mac',
        _timeout = timeout ?? const Duration(seconds: 15);

  /// 业务码：成功。
  static const int statusOk = 2000000;

  /// 业务码：还没人扫（`Query result is empty`）。**这是待扫码的正常态**，
  /// 不是错误 —— 别把它当失败处理，否则会一直重取票。
  static const int statusNotScanned = 50004001;

  /// 业务码：token 找不到。通常是 `client_id` 没收对，或 token 过期。
  static const int statusTokenNotFound = 50004002;

  final HttpClientLike _http;
  final String _clientId;
  final String _platform;
  final Duration _timeout;

  Uri get _tokenUrl =>
      Uri.parse(QuarkEndpoints.casGateway + QuarkEndpoints.casQrToken);

  Uri get _ticketUrl =>
      Uri.parse(QuarkEndpoints.casGateway + QuarkEndpoints.casQrServiceTicket);

  Map<String, String> get _headers => const {
        'Accept': 'application/json, text/plain, */*',
        'User-Agent': QuarkEndpoints.userAgent,
        'Referer': QuarkEndpoints.referer,
      };

  /// 组装二维码内容。
  ///
  /// 模板照抄桌面客户端（`LoginConfig.quarkScan.scanUrl` + 那串 `uc_biz_str`），
  /// 只把短链换成**网页端**的 `4_eMHBJ`、`client_id` 换成 `532`。
  Uri buildQrUrl(String token) => Uri.parse(
        '${QuarkEndpoints.webScanLoginPage}'
        '?uc_param_str='
        '&token=${Uri.encodeComponent(token)}'
        '&client_id=$_clientId'
        '&uc_biz_str=${QuarkEndpoints.qrBizStr}'
        '&platform=$_platform',
      );

  /// 取一个二维码 token。
  Future<QrLoginSession> start() async {
    final res = await _http.get(
      _tokenUrl.toString(),
      query: <String, Object?>{'client_id': _clientId},
      headers: _headers,
      timeout: _timeout,
    );

    if (res.isNetworkFailure) {
      diag.error('qrlogin', '取二维码 token 失败：网络层 ${res.rawBody}');
      throw const QrLoginException('连不上夸克认证服务，请检查网络');
    }
    if (!res.isSuccessStatus) {
      diag.error('qrlogin', '取二维码 token 失败：HTTP ${res.statusCode}');
      throw QrLoginException('认证服务返回 HTTP ${res.statusCode}');
    }

    final token = _extractToken(res.dataMap);
    if (token == null || token.isEmpty) {
      // ⚠️ 不能把响应体打进日志：里面可能有凭据。只记键名。
      diag.error(
        'qrlogin',
        '取二维码 token 失败：响应里没有 data.members.token'
            '（dataKeys=${res.dataMap?.keys.toList()}）',
      );
      throw QrLoginException(
        '认证服务没有返回二维码 token（status=${res.businessCode ?? '-'}）',
      );
    }

    diag.info(
      'qrlogin',
      '已取到二维码 token ${maskSecret(token)}，client_id=$_clientId',
    );

    return QrLoginSession(
      token: token,
      qrUrl: buildQrUrl(token),
      createdAt: DateTime.now(),
    );
  }

  /// 拿 `data.members.token`。
  ///
  /// `HttpResult.dataMap` 的嵌套值类型是 `Object?`，必须逐层判断，
  /// 直接 `as String` 会在服务端改形状时抛类型转换异常。
  static String? _extractToken(Map<String, Object?>? data) {
    if (data == null) return null;
    final members = data['members'];
    if (members is! Map) return null;
    final token = members['token'];
    return token is String ? token : token?.toString();
  }

  /// 轮询一次。
  Future<QrPollOutcome> poll(QrLoginSession session) async {
    final res = await _http.get(
      _ticketUrl.toString(),
      query: <String, Object?>{'token': session.token, 'client_id': _clientId},
      headers: _headers,
      timeout: _timeout,
    );

    if (res.isNetworkFailure) {
      return QrPollError(message: '网络不可用：${res.rawBody}');
    }
    if (!res.isSuccessStatus) {
      return QrPollError(
        message: '认证服务返回 HTTP ${res.statusCode}',
        status: res.statusCode,
      );
    }

    final code = res.businessCode;
    final message = res.businessMessage ?? '';

    switch (code) {
      case statusNotScanned:
        // 正常态，不打日志 —— 否则每 2 秒刷一行，日志会被淹掉。
        return const QrPollWaiting();

      case statusTokenNotFound:
        diag.warn(
          'qrlogin',
          'token 已失效（$statusTokenNotFound $message）。'
              '检查 client_id 是否与取票时一致',
        );
        return QrPollExpired(status: statusTokenNotFound, message: message);

      case statusOk:
        final payload = res.dataMap ?? const <String, Object?>{};
        diag.info(
          'qrlogin',
          '扫码已确认：status=$statusOk，payload 键=${payload.keys.toList()}',
        );
        return QrPollConfirmed(status: statusOk, payload: payload);

      default:
        diag.warn('qrlogin', '未预期的业务码：status=$code $message');
        return QrPollError(
          message: message.isEmpty ? '未知响应' : message,
          status: code,
        );
    }
  }

  /// 票据 → 账号 Cookie 的最后一跳。
  ///
  /// 网页版前端的真实做法（从 pan.quark.cn 主 bundle 逆向，`doAuth` 函数）：
  ///
  /// ```
  /// GET https://pan.quark.cn/account/info?st=<service_ticket>
  /// ```
  ///
  /// 服务端验证 `st` 后，在**这个请求的 Set-Cookie** 里下发网盘账号
  /// Cookie（`__pus` / `__puus`），响应体是 JSON：`{success: true, data: {...}}`。
  ///
  /// 之前试过的 `/cas/ajax/loginWithServiceTicket`（pan/uop 两个域）都是
  /// 给浏览器整页跳转用的旧 CAS 端点，AJAX 语义下不会下发账号 Cookie ——
  /// 这是 2026-09-24 晚真机两轮实测踩出来的坑。
  Future<QrLoginCookies> exchangeServiceTicket(String serviceTicket) async {
    // JSON 语义的 AJAX 请求（与网页版 `Px({url: ...account/info, params:{st}})` 一致）。
    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': QuarkEndpoints.userAgent,
      'Referer': 'https://pan.quark.cn/',
    };

    final res = await _http.get(
      QuarkEndpoints.accountInfo,
      query: <String, Object?>{'st': serviceTicket},
      headers: headers,
      timeout: _timeout,
    );

    diag.info(
      'qrlogin',
      '兑换 /account/info → status=${res.statusCode}, '
      'success=${res.json?['success']}, '
      'cookieKeys=${parseSetCookieLines(res.setCookieLines).keys.toList()}',
    );

    if (res.isNetworkFailure) {
      diag.error('qrlogin', '兑换票据网络层失败：${res.rawBody}');
      throw const QrLoginException('兑换票据时网络不可用，请检查网络');
    }
    if (!res.isSuccessStatus) {
      diag.error('qrlogin', '兑换票据返回 HTTP ${res.statusCode}，body=${redactUrl(res.rawBody)}');
      throw QrLoginException('兑换票据返回 HTTP ${res.statusCode}');
    }

    // 服务端校验失败时返回 success=false（票据无效/过期）。
    if (res.json != null && res.json!['success'] != true) {
      final msg = res.businessMessage ?? '票据校验未通过';
      diag.warn('qrlogin', '/account/info 返回 success=false：$msg');
      throw QrLoginException('票据兑换被拒绝：$msg');
    }

    final cookies = parseSetCookieLines(res.setCookieLines);

    // `__pus` 是硬必需：没有它等于没登录。
    if ((cookies['__pus'] ?? '').isEmpty) {
      diag.warn(
        'qrlogin',
        '/account/info 校验通过但未下发 __pus。拿到键=${cookies.keys.toList()}',
      );
      throw const QrLoginException('票据兑换未返回会话凭证（__pus）');
    }

    // ---------- 补一跳：`__puus` 在登录后的第一个页面请求里下发 ----------
    //
    // 网页版 doAuth 成功后立刻 `window.location` 跳首页；`__puus` 就在那次
    // 响应的 Set-Cookie 里（bundle 里 `__puus` 出现 0 次，纯服务端行为）。
    //
    // ⚠️ 必须**页面导航语义**（`Accept: text/html`）—— 与 CAS 端点同款坑：
    // AJAX 语义（`Accept: application/json`）下服务端不下发 `__puus`
    //（2026-09-24 第四轮真机实测：JSON 语义补跳拿不到）。
    if ((cookies['__puus'] ?? '').isEmpty) {
      final navHeaders = <String, String>{
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'User-Agent': QuarkEndpoints.userAgent,
        'Referer': 'https://pan.quark.cn/',
        'Cookie': _cookieHeader(cookies),
      };

      for (final homeUrl in QuarkEndpoints.postLoginHomeUrls) {
        final homeRes = await _http.get(
          homeUrl,
          headers: navHeaders,
          timeout: _timeout,
        );
        final homeCookies = parseSetCookieLines(homeRes.setCookieLines);
        diag.info(
          'qrlogin',
          '补跳 $homeUrl → status=${homeRes.statusCode}, '
          '新增 cookieKeys=${homeCookies.keys.toList()}',
        );
        if (homeCookies.isNotEmpty) {
          cookies.addAll(homeCookies);
          navHeaders['Cookie'] = _cookieHeader(cookies);
        }
        if ((cookies['__puus'] ?? '').isNotEmpty) break;
      }
    }

    // `__puus` 尽力获取：拿不到不在此处硬失败 —— 交给 `authorize` 的
    // `_fetchMember` 用真实网盘接口校验做最终裁决（若凭证不足会返回
    // 明确的服务端错误）。
    if ((cookies['__puus'] ?? '').isEmpty) {
      diag.warn(
        'qrlogin',
        '补跳后仍未拿到 __puus，继续用现有 Cookie 尝试登录校验。'
        '拿到键=${cookies.keys.toList()}',
      );
    }

    diag.info('qrlogin', '票据兑换成功，账号 Cookie 键=${cookies.keys.toList()}');
    return QrLoginCookies(cookies: cookies, rawSetCookie: res.setCookieLines);
  }

  /// 把 cookie map 编成 `Cookie:` 请求头值。
  static String _cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 兑换拿到的账号 Cookie。
class QrLoginCookies {
  const QrLoginCookies({
    required this.cookies,
    required this.rawSetCookie,
  });

  /// 解析后的 `name → value`（已去掉 path/domain/expires 等属性）。
  final Map<String, String> cookies;

  /// 原始 `Set-Cookie` 行（排查用，不含值以外敏感信息）。
  final List<String> rawSetCookie;

  List<String> get keys => cookies.keys.toList()..sort();

  bool get hasEssential => QuarkEndpoints.essentialCookieNames
      .every((name) => (cookies[name] ?? '').isNotEmpty);
}

/// 把 `Set-Cookie` 原始行解析成 `name=value`。
///
/// 每条形如 `name=value; Path=/; Domain=.quark.cn; HttpOnly`，
/// 只取第一个 `;` 之前那段（属性对落库/发请求没用）。
Map<String, String> parseSetCookieLines(List<String> lines) {
  final out = <String, String>{};
  for (final line in lines) {
    final semi = line.indexOf(';');
    final pair = semi < 0 ? line : line.substring(0, semi);
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (name.isNotEmpty) out[name] = value;
  }
  return out;
}

/// 过滤出可落库的 Cookie（与浏览器授权器一致的 known/essential 名单）。
///
/// 兑换会顺带带回 `_UP_*` / `ctoken` 等无关 Cookie，落库只留已知 + 必需项，
/// 避免把无关凭据带进钥匙串。
Map<String, String> filterQrCookiesForCredential(Map<String, String> cookies) {
  final out = <String, String>{};
  for (final name in QuarkEndpoints.knownCookieNames) {
    final v = cookies[name];
    if (v != null && v.isNotEmpty) out[name] = v;
  }
  for (final name in QuarkEndpoints.essentialCookieNames) {
    final v = cookies[name];
    if (v != null && v.isNotEmpty) out[name] = v;
  }
  return out;
}

/// 扫码登录过程中的可预期错误（网络失败、响应缺字段）。
///
/// 与 `DriveException` 分开：后者描述网盘业务接口错误，
/// 而这是**登录流程**自己的失败。
class QrLoginException implements Exception {
  const QrLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}
