import 'drive_provider.dart';

/// 网盘能力声明。
///
/// 适配器**必须如实声明**自己的能力，上层据此决定：
///   - 是否展示「搜索」入口；
///   - 播放时是否要带自定义请求头；
///   - 哪些曲目要打上「超限不可播」标记；
///   - 扫描 / 取链的节流参数。
///
/// 这是「新增网盘零改动」的关键：差异全部收敛到这份声明里。
class Capabilities {
  const Capabilities({
    required this.provider,
    this.canListDirectory = true,
    this.canSearch = true,
    this.canResolveDirectLink = true,
    this.directLinkNeedsHeaders = false,
    this.supportsRangeRequests = true,
    this.maxSingleFileBytes,
    this.listQps = 3.0,
    this.linkQps = 1.0,
    this.defaultPageSize = 50,
    this.authModes = const {},
  });

  final DriveProvider provider;

  /// 能否列目录（决定能否做全盘遍历扫描）
  final bool canListDirectory;

  /// 能否按关键词搜索
  final bool canSearch;

  /// 能否取到可播放的直链
  final bool canResolveDirectLink;

  /// 取直链播放时是否必须携带自定义请求头。
  ///
  /// 夸克实测结论：**必须带 Cookie**。裸链 / 仅带 Referer / 仅带 UA 全部返回
  /// `412 Precondition Failed`，只要带上 Cookie 就变 `206 Partial Content`。
  final bool directLinkNeedsHeaders;

  /// 直链是否支持 HTTP Range（决定能否拖动进度条 / seek）
  final bool supportsRangeRequests;

  /// **在线播放取链**的单文件体积上限（字节）。`null` 表示无此限制。
  ///
  /// ⚠️ 语义边界（2026-09-24 修正，务必看清）：
  /// 这里声明的是**播放取链**的上限，**不是**网盘「下载」接口的上限。
  /// 两者经常不是一回事 —— 夸克就是典型反例：
  ///   - `/1/clouddrive/file/download`（PC 网页版取下载直链）单文件约 50MiB
  ///     就返回 `code=23018`（见 [fiftyMiB]）；
  ///   - `/1/clouddrive/file/audioplay`（音频播放接口）**没有这条限制**，
  ///     774.1MB 的整轨 WAV 也照常返回原文件直链。
  ///
  /// 所以**不要把 download 的上限填到这里**：它会让上层把大批其实能播的曲目
  /// 误判成「超限不可播」（夸克库内就有 43.9%）。真正取不到链时，
  /// 由 `PlaybackController` 在运行时标记 —— 那才是准确的信息。
  final int? maxSingleFileBytes;

  /// 列目录接口的节流上限（次/秒）
  final double listQps;

  /// 取直链接口的节流上限（次/秒）
  final double linkQps;

  /// 默认分页大小
  final int defaultPageSize;

  /// 该网盘支持的授权方式集合
  final Set<AuthMode> authModes;

  /// 是否声明了**播放取链**的体积上限
  bool get hasFileSizeLimit => maxSingleFileBytes != null;

  /// 夸克 `/1/clouddrive/file/download`（**下载**路由）的实测边界：50MiB。
  ///
  /// ⚠️ 这是**下载**接口的边界，不是播放能力。夸克播放走
  /// `/1/clouddrive/file/audioplay`，不受此限 —— 所以
  /// `QuarkAdapter.quarkCapabilities` **不**声明 [maxSingleFileBytes]。
  ///
  /// 常量保留是因为它仍然有用：判断「同一个文件走哪条路由能拿到链」，
  /// 例如 `tool/quark_live_smoke.dart` 用它挑下载路由的探测样本。
  static const int fiftyMiB = 50 * 1024 * 1024;

  Capabilities copyWith({
    bool? canListDirectory,
    bool? canSearch,
    bool? canResolveDirectLink,
    bool? directLinkNeedsHeaders,
    bool? supportsRangeRequests,
    int? maxSingleFileBytes,
    bool clearMaxSingleFileBytes = false,
    double? listQps,
    double? linkQps,
    int? defaultPageSize,
    Set<AuthMode>? authModes,
  }) {
    return Capabilities(
      provider: provider,
      canListDirectory: canListDirectory ?? this.canListDirectory,
      canSearch: canSearch ?? this.canSearch,
      canResolveDirectLink: canResolveDirectLink ?? this.canResolveDirectLink,
      directLinkNeedsHeaders: directLinkNeedsHeaders ?? this.directLinkNeedsHeaders,
      supportsRangeRequests: supportsRangeRequests ?? this.supportsRangeRequests,
      maxSingleFileBytes: clearMaxSingleFileBytes
          ? null
          : (maxSingleFileBytes ?? this.maxSingleFileBytes),
      listQps: listQps ?? this.listQps,
      linkQps: linkQps ?? this.linkQps,
      defaultPageSize: defaultPageSize ?? this.defaultPageSize,
      authModes: authModes ?? this.authModes,
    );
  }

  @override
  String toString() => 'Capabilities(${provider.id}, '
      'list=$canListDirectory, search=$canSearch, stream=$canResolveDirectLink, '
      'maxFile=${maxSingleFileBytes ?? "∞"}, listQps=$listQps, linkQps=$linkQps)';
}

/// 授权方式。
///
/// 夸克没有开放平台 `client_id`，因此主链路是「夸克 App 扫码 → 用 `service_ticket`
/// 兑换账号 Cookie」（[qrCode]），不接触账号密码；其余方式作为备选与兜底。
enum AuthMode {
  browserCookie(
    id: 'browser_cookie',
    displayName: '浏览器登录授权',
    description: '打开内置浏览器登录网盘，登录成功后自动抓取会话凭证',
  ),
  manualCookie(
    id: 'manual_cookie',
    displayName: '手动粘贴凭证',
    description: '从已登录的浏览器开发者工具复制 Cookie 粘贴进来',
  ),
  qrCode(
    id: 'qr_code',
    displayName: '扫码登录',
    description: '扫描二维码完成授权',
  ),
  oauth(
    id: 'oauth',
    displayName: '官方授权登录',
    description: '跳转网盘官方开放平台完成 OAuth 授权',
  ),
  localClient(
    id: 'local_client',
    displayName: '读取本机客户端会话',
    description: '复用本机已登录网盘客户端的会话（仅桌面端可用）',
  );

  const AuthMode({
    required this.id,
    required this.displayName,
    required this.description,
  });

  final String id;
  final String displayName;
  final String description;

  static AuthMode? fromId(String id) {
    for (final m in values) {
      if (m.id == id) return m;
    }
    return null;
  }
}
