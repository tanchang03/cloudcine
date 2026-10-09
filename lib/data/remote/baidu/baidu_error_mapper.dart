import '../../../core/error/drive_error.dart';
import '../../http/http_client.dart';

/// 百度网盘业务错误码。
///
/// ## 证据等级
///
/// 每个常量都标了来源，**不要把「社区都说有」当成「我验过」**：
///   - **【实测】** —— 本机真的拿到过这个码；
///   - **【官方文档】** —— 官方文档明写；
///   - **【未验证】** —— 社区实现 / 官方文档里的间接线索，本机没验过。
///
/// 未验证的那些**仍然要映射**，理由是：映射错一个码的后果只是错误文案
/// 不够精确（落进 `unknown` 兜底也一样是报错），而**漏映射**会让一个
/// 「需要重新登录」被当成「未知错误」反复重试 —— 后者才是真正伤人的。
class BaiduErrorCode {
  const BaiduErrorCode._();

  /// 成功。
  static const int ok = 0;

  /// **未登录 / 会话已过期**。
  ///
  /// 【实测】2026-10-08：无 Cookie 与带垃圾 `BDUSS` 打 `/api/list`、
  /// `/api/batch/streaming`、`/api/account/uinfo` 全部返回
  /// `{"errno":-6,"show_msg":"账户已过期，重新登陆"}`。
  ///
  /// 这是**最常见**的一个码：它同时表示「没带 Cookie」和「Cookie 废了」，
  /// 服务端不区分。两者对上层是同一件事 —— 都要重新授权。
  static const int notLoggedIn = -6;

  /// 文件或目录不存在。【未验证】
  static const int fileNotFound = -7;

  /// 文件已存在。【未验证】
  static const int fileAlreadyExists = -8;

  /// 文件不存在。【未验证】
  static const int fileNotExist = -9;

  /// 目录不存在。【未验证】
  static const int dirNotExist = -10;

  /// 参数错误。【未验证】
  static const int invalidParam = 2;

  /// 需要身份验证（风控拦截）。【未验证】
  static const int needVerify = -62;

  /// 该目录下已有同名文件。【未验证】
  static const int sameNameExists = 111;

  /// 有文件正在传输中。【未验证】
  static const int transferInProgress = 112;

  /// **路径不在允许访问范围内**。
  ///
  /// 【官方文档】2026-08-03 更新的原话：「为进一步保障用户网盘数据安全…
  /// **2026年6月3日后在平台创建的应用**，以下接口**仅支持访问
  /// `/apps/{appname}` 目录下的文件**」。
  ///
  /// ⚠️ 这个码是**官方开放平台**的越界码。本适配器走自用接口、不带
  /// `access_token`，正常不该撞上它。仍然映射，是因为一旦出现它，
  /// 说明「自用接口这条路被收紧了」—— 那是需要用户知道的大事，
  /// 不该被吞进 `unknown`。
  static const int pathNotAllowed = 20011;

  /// 一次操作文件数超限。【未验证】
  static const int tooManyFiles = 31066;

  /// **反盗链**。
  ///
  /// 【实测】2026-10-08：下载旧版客户端 dmg 时直连 CDN 未带
  /// `Referer: https://pan.baidu.com/download`，返回
  /// `{"error_code":31326,"error_msg":"anti hotlinking"}`。
  ///
  /// 取直链时也会撞到它 —— 社区一致结论是 GET `dlink` 必须带
  /// `User-Agent: pan.baidu.com`，否则回这个码。
  static const int antiHotlinking = 31326;

  /// 直链已过期。【未验证】社区实测 `dlink` 有效期约 8 小时。
  static const int dlinkExpired = 31360;

  /// 直链签名错误。【未验证】通常是把 `dlink` 截断或改写过。
  static const int dlinkSignInvalid = 31362;

  /// 扫码登录被风控拦截。
  ///
  /// 【客户端】`loginv5` 源码里的 `400023` 分支：走
  /// `/v3/login/main/qrbdusslogin`，但参数换成 `authsid` + `bdusssign`
  /// 而不是 `bduss`，且文案是「为了你的账号安全…」。
  ///
  /// ⇒ 撞上它**不是**「登录失败」，而是「需要走另一条参数形态」。
  /// 适配器目前把它如实报给用户（让用户去 App 里确认），不做自动降级 ——
  /// 那条分支的参数（`authsid`）来自服务端上一个响应，本机没验证过，
  /// 贸然实现只会掩盖真实错误。
  static const int qrRiskControl = 400023;

  /// 取二维码次数超限。【客户端】登录页里有 `5e4 === +t.errno` 的特判
  /// （`50000`），命中时展示「刷新失败」。
  static const int qrFetchLimit = 50000;
}

/// 把百度的响应归一化成 [DriveException]。
///
/// 上层只认 [DriveErrorType]，不认 `-6` / `20011` 这类数字。
///
/// ## 判定顺序（不能调换）
///
/// 网络层失败 → HTTP 状态码 → 业务码。与夸克那份同理：百度也常在
/// **HTTP 200** 里带业务错误，而 429 / 5xx 这类状态码本身就是关键信号。
DriveException baiduExceptionFrom(
  HttpResult result, {
  String? context,
}) {
  String msg(String text) =>
      (context == null || context.isEmpty) ? text : '$context：$text';

  final providerCode = result.businessCode;
  // 百度的业务消息字段是 `show_msg`（实测），HttpResult.businessMessage
  // 认的是 message/error_info/errmsg/msg —— **认不到 show_msg**。
  // 所以这里额外捞一次，否则错误文案永远是兜底的那句。
  final message = _baiduMessage(result);

  // 1. 网络层失败
  if (result.isNetworkFailure) {
    return DriveException(
      type: DriveErrorType.network,
      message: msg('网络请求失败，请检查网络连接'),
      httpStatus: null,
      rawMessage: result.rawBody,
    );
  }

  // 2. 限流
  if (result.statusCode == 429) {
    return DriveException(
      type: DriveErrorType.rateLimited,
      message: msg('请求过于频繁，请稍后重试'),
      providerCode: providerCode,
      httpStatus: 429,
      rawMessage: message,
    );
  }

  // 3. 业务码（百度绝大多数错误走这里，HTTP 仍是 200）
  switch (providerCode) {
    case BaiduErrorCode.notLoggedIn:
      return DriveException(
        type: DriveErrorType.unauthorized,
        message: msg('百度网盘登录状态无效，请重新授权'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.fileNotFound:
    case BaiduErrorCode.fileNotExist:
    case BaiduErrorCode.dirNotExist:
      return DriveException(
        type: DriveErrorType.notFound,
        message: msg('文件或目录不存在（可能已被删除或移动）'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.dlinkExpired:
    case BaiduErrorCode.dlinkSignInvalid:
      return DriveException(
        type: DriveErrorType.urlExpired,
        message: msg('播放地址已失效，正在重新获取'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.antiHotlinking:
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('直链拒绝了请求（反盗链）：必须带 User-Agent: pan.baidu.com'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.pathNotAllowed:
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('该文件不在应用可访问的目录内'
            '（百度官方开放平台限制：仅 /apps/{appname}/ 可用）'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.needVerify:
    case BaiduErrorCode.qrRiskControl:
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('账号触发了安全验证，请先在百度网盘 App 内确认'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.sameNameExists:
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('目标目录下已有同名文件'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.invalidParam:
      return DriveException(
        type: DriveErrorType.malformedResponse,
        message: msg('接口参数错误'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );

    case BaiduErrorCode.tooManyFiles:
      return DriveException(
        type: DriveErrorType.rateLimited,
        message: msg('一次操作的文件数超过服务端上限'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );
  }

  // 4. HTTP 状态码
  switch (result.statusCode) {
    case 401:
    case 403:
      return DriveException(
        type: DriveErrorType.unauthorized,
        message: msg('未授权，请重新登录'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );
    case 404:
      return DriveException(
        type: DriveErrorType.notFound,
        message: msg('文件不存在或已被删除'),
        providerCode: providerCode,
        httpStatus: 404,
        rawMessage: message,
      );
  }

  if (result.statusCode >= 500) {
    return DriveException(
      type: DriveErrorType.network,
      message: msg('百度网盘服务暂时不可用（HTTP ${result.statusCode}）'),
      providerCode: providerCode,
      httpStatus: result.statusCode,
      rawMessage: message,
    );
  }

  // 5. 非 JSON / 无法解析
  if (!result.hasJson) {
    return DriveException(
      type: DriveErrorType.malformedResponse,
      message: msg('响应无法解析（HTTP ${result.statusCode}）'),
      providerCode: providerCode,
      httpStatus: result.statusCode,
      rawMessage: result.rawBody,
    );
  }

  // 6. 兜底
  return DriveException(
    type: DriveErrorType.unknown,
    message: msg(message ?? '百度网盘接口返回未知错误'),
    providerCode: providerCode,
    httpStatus: result.statusCode,
    rawMessage: message,
  );
}

/// 捞百度的业务消息。
///
/// 百度用的是 `show_msg` / `error_msg`，而 `HttpResult.businessMessage`
/// 只认 `message` / `error_info` / `errmsg` / `msg` —— 两边对不上。
///
/// 不在 `HttpResult` 里加 `show_msg` 的原因：那个类是**所有网盘共用**的，
/// 为了百度一家往它的候选列表里塞字段，等于让另外两家的语义变模糊。
/// 归一化留在各自的适配器里更合适。
String? _baiduMessage(HttpResult result) {
  final direct = result.businessMessage;
  if (direct != null && direct.isNotEmpty) return direct;

  final json = result.json;
  if (json == null) return null;
  for (final key in const ['show_msg', 'error_msg', 'errmsg']) {
    final v = json[key];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

/// 判断一次响应是否代表业务成功（`errno == 0` 且 HTTP 2xx）。
bool isBaiduSuccess(HttpResult result) =>
    result.isSuccessStatus && result.businessCode == BaiduErrorCode.ok;
