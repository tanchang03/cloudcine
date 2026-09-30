import '../../../core/error/drive_error.dart';
import '../../http/http_client.dart';

/// 夸克业务错误码（PoC 实测）。
class QuarkErrorCode {
  const QuarkErrorCode._();

  static const int ok = 0;

  /// 需要登录：Cookie 无效或缺失；`fr` 与账号类型不匹配时也会出现
  static const int requireLogin = 31001;

  /// 令牌过期
  static const int tokenInvalid = 31004;

  /// **单文件超出 `/file/download` 的体积上限**（实测约 50MB）。
  ///
  /// ⚠️ 这是**下载路由**的限制，不是「文件不能播」。夸克的音频播放走
  /// `/file/audioplay`，该路由没有这条限制（774.1MB 实测可播）。
  /// 所以拿到这个码时，`QuarkAdapter.resolveStream` 已经切过播放路由了 ——
  /// 走到这里意味着两条路由都失败。
  static const int fileSizeLimit = 23018;

  /// 签名验证失败（开放平台接口专用）
  static const int signInvalid = 10001;
}

/// 把夸克的响应归一化成 [DriveException]。
///
/// 上层只认 [DriveErrorType]，不认 `31001` / `23018` 这类数字。
///
/// 判定顺序（不能调换）：网络层失败 → HTTP 状态码 → 业务码。
/// 因为 HTTP 200 也可能带业务错误（夸克的常态），
/// 而 412 这类状态码本身就是关键信号（直链缺 Cookie）。
DriveException quarkExceptionFrom(
  HttpResult result, {
  String? context,
}) {
  // 统一前缀：有 context 时消息形如「取播放直链：文件超出体积上限」
  String msg(String text) =>
      (context == null || context.isEmpty) ? text : '$context：$text';

  final providerCode = result.businessCode;
  final message = result.businessMessage;

  // 1. 网络层失败
  if (result.isNetworkFailure) {
    return DriveException(
      type: DriveErrorType.network,
      message: msg('网络请求失败，请检查网络连接'),
      httpStatus: null,
      rawMessage: result.rawBody,
    );
  }

  // 2. 限流（优先于业务码：429 时体里可能是任意内容）
  if (result.statusCode == 429) {
    return DriveException(
      type: DriveErrorType.rateLimited,
      message: msg('请求过于频繁，请稍后重试'),
      providerCode: providerCode,
      httpStatus: 429,
      rawMessage: message,
    );
  }

  // 3. 业务码映射（夸克绝大多数错误走这里，HTTP 仍是 200）
  switch (providerCode) {
    case QuarkErrorCode.requireLogin:
      return DriveException(
        type: DriveErrorType.unauthorized,
        message: msg('登录状态无效，请重新授权夸克账号'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );
    case QuarkErrorCode.tokenInvalid:
      return DriveException(
        type: DriveErrorType.unauthorized,
        message: msg('登录已过期，请重新授权夸克账号'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );
    case QuarkErrorCode.fileSizeLimit:
      return DriveException(
        type: DriveErrorType.fileTooLarge,
        message: msg('夸克拒绝了取链：下载接口对单文件有体积上限，'
            '音频播放接口也没能返回地址'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );
    case QuarkErrorCode.signInvalid:
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('接口签名校验失败'),
        providerCode: providerCode,
        httpStatus: result.statusCode,
        rawMessage: message,
      );
  }

  // 4. HTTP 状态码
  switch (result.statusCode) {
    case 401:
      return DriveException(
        type: DriveErrorType.unauthorized,
        message: msg('未授权，请重新登录'),
        providerCode: providerCode,
        httpStatus: 401,
        rawMessage: message,
      );
    case 403:
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('无访问权限'),
        providerCode: providerCode,
        httpStatus: 403,
        rawMessage: message,
      );
    case 412:
      // 直链实测：缺少 Cookie 时返回 412 而非 403。
      // 这是「前置条件不满足」，不是权限问题。
      return DriveException(
        type: DriveErrorType.permissionDenied,
        message: msg('请求缺少必要的凭证（直链需要携带 Cookie）'),
        providerCode: providerCode,
        httpStatus: 412,
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
      message: msg('夸克服务暂时不可用（HTTP ${result.statusCode}）'),
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
    message: msg(message ?? '夸克接口返回未知错误'),
    providerCode: providerCode,
    httpStatus: result.statusCode,
    rawMessage: message,
  );
}

/// 判断一次响应是否代表业务成功（`code == 0` 且 HTTP 2xx）。
bool isQuarkSuccess(HttpResult result) =>
    result.isSuccessStatus && result.businessCode == QuarkErrorCode.ok;
