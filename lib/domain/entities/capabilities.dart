import 'drive_provider.dart';

/// 网盘能力声明。
///
/// 适配器**必须如实声明**自己的能力，上层据此决定：
///   - 是否展示「搜索」入口；
///   - 播放时是否要带自定义请求头；
///   - 哪些曲目要打上「超限不可播」标记；
///   - 扫描 / 取链的节流参数；
///   - 备份包能不能落到这家（[canWrite]）、批量删除时哪些文件删得掉、
///     哪些只能从媒体库移除（[canDelete]）、多选工具条上「移动」该不该
///     置灰（[canMove]）。
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
    this.canWrite = true,
    this.canDelete = true,
    this.canMove = true,
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

  /// 这家网盘**能不能写**（上传 / 建目录）。
  ///
  /// ## 为什么需要一个显式的能力位，而不是只靠「基类默认抛 unsupported」
  ///
  /// 「抛异常」表达的是**运行时**的「这次不行」；而有一类需求必须在
  /// **调用之前**就知道能不能写：
  ///
  ///   * **备份上传选哪家**。备份包只能落在**一家**网盘上（见
  ///     `libraryBackupServiceProvider`）。接了百度之后，如果挑中它，
  ///     用户点「备份」只会拿到一句 `unsupported` —— 而他明明已经登录了
  ///     夸克，只是不知道要选。选之前能判，就能直接挑一个能写的。
  ///   * UI 上「加入媒体库 / 上传」这类入口该不该**置灰**，而不是点了才报错。
  ///
  /// ⚠️ 它说的是「这家网盘整体上支不支持写」，不是「这个账号有没有权限」
  ///    （会员等级、目录只读这类差异仍然靠运行时异常表达）。
  ///
  /// ⛔ **不含删除、不含移动**。那两件事各有一个位（[canDelete] /
  /// [canMove]），因为一家的能力可以是「能删、不能传」：百度现在就是
  /// （见 `BaiduAdapter` 的类文档）。合成一个位只有两种错法，而且都很难查：
  ///   - 按 [canWrite] 判删除 ⇒ 百度明明能删，媒体库批量删除却把它的文件
  ///     算成「删不了」，用户勾了「一并删网盘」之后看到文件原样留在盘上；
  ///   - 按 [canWrite] 判上传 ⇒ 百度明明不能传，备份却挑中它然后失败。
  final bool canWrite;

  /// 这家网盘**能不能删文件**（网盘侧删除，对用户是**不可逆**的）。
  ///
  /// 用途只有一处判定，但错一次就很伤人：媒体库批量删除里「这几个文件
  /// 删得掉 / 那几个所在网盘删不了」的分账（见 `LibraryBatchDeletePlan`
  /// 的 `undeletableFileCount`）。判错的后果是把「删不掉」说成「已删」，
  /// 而用户此刻正盯着容量条等它掉数字。
  ///
  /// ⚠️ 与 [canWrite] 一样，它说的是**网盘整体**支不支持，不保证**这一次**
  ///    一定成功（目录只读、单文件被锁定、限流都会失败）—— 那些靠运行时
  ///    异常如实上报。
  final bool canDelete;

  /// 这家网盘**能不能移动 / 重命名**（把条目挪到另一个目录）。
  ///
  /// 判据用在文件夹页那条多选工具条上：不支持时「移动」按钮**置灰**，
  /// 而不是让用户点完再读一句 `unsupported`。后者是这个页面反复踩过的
  /// 形状 —— 用户分不清「功能坏了」和「这家网盘不支持」。
  ///
  /// ⚠️ 移动**不改 fid**（见基类 `moveFiles` 的文档），所以它与 [canDelete]
  ///    的风险等级不同：删错了要用户自己去回收站捞，移动错了再移回去就行。
  ///    两个位分开，正是为了让「能删不能移」或反过来这类组合表达得出来。
  final bool canMove;

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
    bool? canWrite,
    bool? canDelete,
    bool? canMove,
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
      canWrite: canWrite ?? this.canWrite,
      canDelete: canDelete ?? this.canDelete,
      canMove: canMove ?? this.canMove,
    );
  }

  @override
  String toString() => 'Capabilities(${provider.id}, '
      'list=$canListDirectory, search=$canSearch, stream=$canResolveDirectLink, '
      'write=$canWrite, delete=$canDelete, move=$canMove, '
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
