/// 归一化错误类型。
///
/// 三家网盘的错误码体系完全不同（夸克 errno、阿里 code、百度 errno），
/// 上层业务只处理这里定义的 [DriveErrorType]，不感知具体平台。
library;

enum DriveErrorType {
  /// 未授权或凭证失效，需要重新登录
  unauthorized,

  /// 触发限流，应退避重试
  rateLimited,

  /// 文件或目录不存在
  notFound,

  /// 直链已过期，需重新获取
  urlExpired,

  /// 权限不足
  permissionDenied,

  /// 单文件超出网盘**取链**接口允许的体积
  ///
  /// 注意是「取链接口」而不是「文件」：同一个文件可能只是这条取链路由
  /// 不给，换条路由就能播。夸克就是这种情况（下载路由 50MiB /
  /// 播放路由无限制），详见 `QuarkEndpoints.fileAudioplay` 的注释。
  fileTooLarge,

  /// 网络层错误（超时、DNS、连接失败）
  network,

  /// 响应无法解析
  malformedResponse,

  /// 该网盘不支持此能力（如夸克不支持列目录）
  unsupported,

  /// 其他未归类错误
  unknown,
}

class DriveException implements Exception {
  const DriveException({
    required this.type,
    required this.message,
    this.providerCode,
    this.httpStatus,
    this.rawMessage,
  });

  final DriveErrorType type;
  final String message;

  /// 网盘原始业务码，便于排查
  final int? providerCode;
  final int? httpStatus;
  final String? rawMessage;

  /// 是否值得重试
  bool get isRetryable =>
      type == DriveErrorType.rateLimited ||
      type == DriveErrorType.network ||
      type == DriveErrorType.urlExpired;

  /// 是否需要用户重新授权
  bool get needsReauth => type == DriveErrorType.unauthorized;

  @override
  String toString() => 'DriveException(${type.name}, '
      'code=$providerCode, http=$httpStatus, $message)';
}
