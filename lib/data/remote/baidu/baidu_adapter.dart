import 'dart:convert';
import 'dart:typed_data';

import '../../../core/diagnostics/diag_log.dart';
import '../../../core/error/drive_error.dart';
import '../../../core/utils/redact.dart';
import '../../../domain/adapters/cloud_drive_adapter.dart';
import '../../../domain/adapters/credential_store.dart';
import '../../../domain/entities/auth_credential.dart';
import '../../../domain/entities/capabilities.dart';
import '../../../domain/entities/cloud_account.dart';
import '../../../domain/entities/drive_entry.dart';
import '../../../domain/entities/drive_provider.dart';
import '../../../domain/entities/quality_option.dart';
import '../../../domain/entities/stream_ticket.dart';
import '../../http/http_client.dart';
import '../../http/token_bucket.dart';
import 'baidu_endpoints.dart';
import 'baidu_error_mapper.dart';
import 'baidu_models.dart';

/// 百度网盘适配器（**只读**：授权 / 遍历 / 取流）。
///
/// 走 **Web 自用接口**（`pan.baidu.com/api/*`），靠登录态 Cookie（`BDUSS`）
/// 鉴权。理由与端点证据等级见 [BaiduEndpoints] 的类文档。
///
/// 该类**只依赖 [HttpClientLike]**，不依赖 `dio`，因此可以在单元测试里
/// 用假客户端把分页、错误映射、限流、**取流路由降级**、直链组装全部覆盖到，
/// 不发一次网络请求。
///
/// ## 本轮范围：只读
///
/// 实现了 `restoreSession` / `authorize` / `signOut` / `refreshAccount` /
/// `ping` / `listDirectory` / `search` / `resolveStream` / `readFileBytes`。
///
/// `createFolder` / `deleteFiles` / `moveFiles` / `uploadFile` **不实现** ——
/// 它们在基类里默认抛 `unsupported`，上层据此隐藏入口。
/// 写入链路要等「真实账号验证过取链与遍历」之后再单独做：
/// 一旦写错就是**用户数据损失**，不该和读链路一起上线。
///
/// ## ⛔ 与夸克最大的三个结构差异（抄代码时会踩）
///
/// | 维度 | 夸克 | 百度 |
/// |---|---|---|
/// | 目录标识 | `fid`（ID） | **路径**（`dir=/电影`） |
/// | 列表位置 | `data.list` | **顶层 `list`** |
/// | 目录布尔位 | `file_type`：`0`=目录 | `isdir`：**`1`**=目录 |
///
/// 前两条各自会让「一个文件都扫不到」且**不报错**，第三条会把目录树
/// **整个反过来**。适配器内部用路径缓存把第一条吃掉，后两条在
/// [BaiduMapper] 里处理。
///
/// ## ⛔ 必须 `extends` 而不是 `implements`
///
/// 基类的类文档专门写了这一条：`implements` 只继承接口、**不继承实现**，
/// 于是基类里那些「表达『这个能力可以不支持』的默认实现」
/// （`createFolder` / `deleteFiles` / `moveFiles` / `uploadFile`，
/// 默认一律抛 `unsupported`）会全部失效 —— 子类被迫写四个抛异常的空壳。
/// 那是噪音，不是表达。本轮只读，正是靠这四条默认实现来声明「不写」。
class BaiduAdapter extends CloudDriveAdapter {
  BaiduAdapter({
    required HttpClientLike http,
    required CredentialStore credentialStore,
    Capabilities? capabilities,
    TokenBucket? listBucket,
    TokenBucket? linkBucket,
    String gateway = BaiduEndpoints.panHost,
    DateTime Function()? clock,
  })  : _http = http,
        _store = credentialStore,
        _gateway = gateway,
        _clock = clock ?? DateTime.now,
        _capabilities = capabilities ?? baiduCapabilities,
        _listBucket = listBucket ??
            TokenBucket(ratePerSecond: (capabilities ?? baiduCapabilities).listQps),
        _linkBucket = linkBucket ??
            TokenBucket(
              ratePerSecond: (capabilities ?? baiduCapabilities).linkQps,
              burst: linkBucketBurst,
            );

  /// 取链桶的突发容量。
  ///
  /// 与夸克同一条理由：一次播放可能连打两个请求（原画 + 转码档），
  /// 它们是一对「计划中的请求」，不是重试风暴。桶容量 1 会让第二个
  /// 必然等满 1 秒，而这一秒换来的是**零**保护价值。
  ///
  /// 公开是为了让单测钉住它。
  static const int linkBucketBurst = 2;

  /// 百度的默认能力声明。
  ///
  /// ## `listQps = 2.0` 是**保守猜测**，不是实测
  ///
  /// 夸克的 3.0 QPS 是参考项目实测出来的（未触发风控）。百度**没有**
  /// 对应的实测数据，而百度的风控比夸克严（公开可见的共识是「扫全盘容易
  /// 触发限流」）。所以取 2.0 —— 宁可慢一点，也不要让用户的全盘扫描
  /// 在中途被风控掐断（那会留下一个半截的索引库，比慢更难查）。
  ///
  /// ⚠️ 这里**不声明 [Capabilities.maxSingleFileBytes]**：百度的 `dlink`
  /// 路由没有已知的单文件上限（与夸克不同，夸克是「下载路由 50MiB」）。
  /// 声明一个猜的上限会让**大批其实能播的文件被误判为不可播**，
  /// 比不声明糟得多。真正取不到链时由播放控制器在运行时标记。
  static const Capabilities baiduCapabilities = Capabilities(
    provider: DriveProvider.baidu,
    canListDirectory: true,
    canSearch: true,
    canResolveDirectLink: true,
    // ⛔ **只读**。本次对接的范围就是「能扫能播」，四个写方法（建目录 /
    //    删 / 移 / 上传）一律走基类的 `unsupported` 默认实现。
    //
    //    显式声明而不是只靠抛异常：备份上传要**先**挑一家能写的网盘
    //    （见 `Capabilities.canWrite`），靠异常表达的话只能挑完再失败。
    canWrite: false,
    // 直链必须带 `User-Agent: pan.baidu.com`，否则 `31326 anti hotlinking`。
    directLinkNeedsHeaders: true,
    supportsRangeRequests: true,
    listQps: 2.0,
    linkQps: 1.0,
    // 百度单页上限通常是 1000，取 100 是折中：够快，又不会让一次响应
    // 大到解析卡顿（扫描器自己还有 pageSize 策略）。
    defaultPageSize: 100,
    authModes: {
      // 主链路：百度网盘 App 扫码（Mac 客户端同款），全盘可用。
      AuthMode.qrCode,
      // 兜底：手动粘贴 BDUSS（官方开放平台的设备码扫码**不可用**，
      // 受 `/apps/{appname}/` 限制，见 `BaiduEndpoints` 的类文档）。
      AuthMode.manualCookie,
    },
  );

  final HttpClientLike _http;
  final CredentialStore _store;
  final String _gateway;
  final DateTime Function() _clock;
  final Capabilities _capabilities;
  final TokenBucket _listBucket;
  final TokenBucket _linkBucket;

  AuthCredential? _credential;
  CloudAccount? _account;

  /// 会员档位（[BaiduVipType]）。默认按普通用户算。
  ///
  /// 拿不到账号信息时保持 [BaiduVipType.normal]：这是**保守**的默认 ——
  /// 按普通用户算最多是「不去请求高档转码流」，而按 SVIP 算会去请求
  /// 服务端本来就不给的档位，白费配额还多一次失败日志。
  int _vipType = BaiduVipType.normal;

  /// `fs_id → 完整路径` 缓存。
  ///
  /// ## 为什么必须有它（这是百度适配器最核心的一处设计）
  ///
  /// 契约里 `listDirectory(dirId:)` 与 `resolveStream(fileId)` 收的都是
  /// **不透明 ID**，而百度的 `dir` 参数收的是**路径**。调用方手里只有
  /// `fs_id`（扫描器按 `entry.id` 入队），所以适配器必须自己完成
  /// 「ID → 路径」的翻译。
  ///
  /// 三种做法里选了缓存：
  ///   1. 改契约加一个可选 `dirPath` 参数 —— 要改 8 个测试替身，
  ///      而那是**接口污染**：只有百度一家需要它；
  ///   2. 每次列目录都先查一次 `filemetas` 拿路径 —— 全盘扫描是几百个
  ///      目录，等于**请求数翻倍**，在 2 QPS 限流下直接翻倍扫描时间；
  ///   3. **本方案**：列表项自带 `path`，所以每列一次父目录就白捡一批
  ///      子项的路径映射。BFS 天然「先列父、后列子」，命中率接近 100%。
  ///
  /// 缓存未命中时（首次进入某个已知 ID、或用户从外部跳进来）才回退到
  /// 方案 2，只多一次请求。
  final Map<String, String> _pathByFsId = {};

  @override
  DriveProvider get provider => DriveProvider.baidu;

  @override
  Capabilities get capabilities => _capabilities;

  @override
  String get rootId => BaiduEndpoints.rootId;

  /// 当前会话的 `Cookie:` 头。未授权时为空串。
  String get _cookieHeader => _credential?.cookieHeader ?? '';

  /// 网盘 `/api/*` 的**会话令牌**（客户端登录链第 7 步取到的 `bdstoken`）。
  ///
  /// ## 为什么必须带
  ///
  /// 客户端**每一条**网盘请求都带 `bdstoken`；缺了它服务端回
  /// `errno=-6`「登录状态无效」—— 与「凭证真的废了」**同一个码**，
  /// 所以光看错误码分不出是哪种（见 `BaiduErrorCode.notLoggedIn`）。
  /// 本适配器早期整条链路都没有它，于是「扫码成功」之后所有 `/api/*`
  /// 一律 -6（2026-10-08 / 10-09 两次实测）。
  ///
  /// ## 生命周期
  ///
  /// 惰性取、按会话缓存；拿到 `-6` 时置空以便下次重取（令牌会过期）；
  /// 换账号 / 登出时清空。
  String? _bdstoken;

  /// 是否持有会话（不代表仍然有效）。
  bool get hasSession => _cookieHeader.isNotEmpty;

  /// 当前账号（若已恢复/授权）。
  CloudAccount? get currentAccount => _account;

  /// 当前会员档位（[BaiduVipType]）。
  int get vipType => _vipType;

  // -------------------------------------------------------------------
  // 授权
  // -------------------------------------------------------------------

  @override
  Future<CloudAccount?> restoreSession() async {
    final stored = await _store.load(DriveProvider.baidu);
    if (stored == null || stored.isEmpty) {
      diag.warn('会话', '百度恢复失败：凭证存储里没有可用凭证');
      return null;
    }

    _credential = stored;
    _bdstoken = null;
    diag.info(
      '会话',
      '百度拿到凭证：模式=${stored.mode.name}，'
      'Cookie ${maskCookieHeader(stored.cookieHeader)}，'
      '捕获于 ${stored.capturedAt}',
    );

    final account = await _fetchAccount();
    _account = account;
    diag.info('会话', '百度校验通过：${account.label}（${_vipLabel()}）');
    return account;
  }

  /// 重新拉一次账号信息，**不动凭证存储**。
  ///
  /// ## 为什么覆盖默认实现（理由与夸克**不同**）
  ///
  /// 夸克覆盖它是因为「重读存储会把轮换过的 Cookie 换回旧的」。
  /// 百度**没有 Cookie 轮换**（实测打 `/api/list` 的响应里没有
  /// `Set-Cookie`），所以覆盖的收益只剩「少读一次安全存储」。
  ///
  /// 保留覆盖是因为语义更准：这个方法叫「刷新账号信息」，而
  /// [restoreSession] 叫「恢复会话」—— 后者还会在存储为空时返回 `null`，
  /// 而调用方（容量条刷新）要的是「问一次服务端」，不是「重新登录一遍」。
  @override
  Future<CloudAccount?> refreshAccount() async {
    final account = await _fetchAccount();
    _account = account;
    return account;
  }

  @override
  Future<CloudAccount> authorize(AuthCredential credential) async {
    if (credential.isEmpty) {
      throw const DriveException(
        type: DriveErrorType.unauthorized,
        message: '授权凭证为空，请重新登录百度网盘',
      );
    }

    _credential = credential;
    _bdstoken = null;
    diag.info(
      '会话',
      '百度提交凭证校验：模式=${credential.mode.name}，'
      'Cookie ${maskCookieHeader(credential.cookieHeader)}',
    );

    CloudAccount account;
    try {
      // 先校验再落库：避免把废凭证写进安全存储。
      account = await _fetchAccount();
    } catch (_) {
      _credential = null;
      _account = null;
      diag.error('会话', '百度凭证校验失败，已丢弃');
      rethrow;
    }

    _account = account;
    await _store.save(credential);
    diag.info('会话', '百度授权完成：${account.label}（${_vipLabel()}）');
    return account;
  }

  @override
  Future<void> signOut() async {
    _credential = null;
    _account = null;
    _vipType = BaiduVipType.normal;
    // `bdstoken` 是**按会话**签发的，换账号后旧值必然失效。
    _bdstoken = null;
    _pathByFsId.clear();
    await _store.clear(DriveProvider.baidu);
    diag.info('会话', '百度已退出登录');
  }

  @override
  Future<bool> ping() async {
    if (!hasSession) return false;
    try {
      // 用 `/api/quota` 而不是 `/api/list`：前者更轻（不遍历目录），
      // 而「连接诊断」只需要知道「凭证还认不认」。
      await _request(
        () => _get(BaiduEndpoints.quota),
        context: '连接诊断',
      );
      return true;
    } on DriveException catch (e) {
      if (e.needsReauth) return false;
      rethrow;
    }
  }

  // -------------------------------------------------------------------
  // 遍历与搜索
  // -------------------------------------------------------------------

  /// 列目录。
  ///
  /// [dirId] 是 `fs_id`（或根目录的 [rootId]），内部翻译成路径 ——
  /// 见 [_pathByFsId] 的类文档。
  @override
  Future<DrivePage> listDirectory({
    required String dirId,
    String? pageToken,
    int? pageSize,
  }) async {
    final size = pageSize ?? _capabilities.defaultPageSize;
    final page = _parsePageToken(pageToken);
    final dirPath = await _resolvePath(dirId);

    final result = await _listBucket.run(
      () => _request(
        () => _get(BaiduEndpoints.list, {
          'dir': dirPath,
          'order': 'name',
          'desc': '0',
          'page': page,
          'num': size,
          // 不显示空目录：媒体库扫描不需要它们，少传一点数据。
          'showempty': 0,
          // 让服务端顺带带上缩略图字段（`thumbs`）。
          'web': 1,
        }),
        context: '列目录',
      ),
    );

    final entries = BaiduMapper.toEntries(BaiduMapper.listItemsOf(result));

    // ⭐ 白捡路径映射：列表项自带 `path`，这一批子项下次被列时就能直接命中。
    _pathByFsId.addAll(BaiduMapper.pathIndex(entries));
    // 目录自己的路径也记一下（根目录除外，它恒为 `/`）。
    if (dirPath != BaiduEndpoints.rootId && dirId.isNotEmpty) {
      _pathByFsId[dirId] = dirPath;
    }

    // 下一页判定。
    //
    // 优先用服务端的 `has_more`（百度部分响应会带）；没有就退回
    // 「满页启发式」—— 与夸克同一套：返回条数 == 请求条数即认为还有下一页。
    final hasMore = _asBool(result.json?['has_more']);
    String? nextToken;
    if (hasMore == true) {
      nextToken = '${page + 1}';
    } else if (hasMore == null && entries.length >= size) {
      nextToken = '${page + 1}';
    }

    return DrivePage(
      entries: entries,
      nextPageToken: nextToken,
      total: _asInt(result.json?['total']),
    );
  }

  @override
  Future<List<DriveEntry>> search({
    required String keyword,
    int limit = 100,
    int offset = 0,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return const [];

    final page = offset <= 0 ? 1 : (offset ~/ limit) + 1;

    final result = await _listBucket.run(
      () => _request(
        () => _get(BaiduEndpoints.search, {
          'wd': trimmed,
          'page': page,
          'num': limit,
          // 递归全盘搜索。不带它只会搜当前目录（而搜索接口没有「当前目录」
          // 的概念，结果会是一个奇怪的子集）。
          'recursion': 1,
          'web': 1,
        }),
        context: '搜索',
      ),
    );

    final entries = BaiduMapper.toEntries(BaiduMapper.listItemsOf(result));
    _pathByFsId.addAll(BaiduMapper.pathIndex(entries));

    // ⚠️ 百度**没有**夸克那种「文件优先」的排序开关，所以结果里混着目录。
    // 契约要求调用方自行过滤 `entry.isFile` —— 这里**不做过滤**，
    // 因为「搜索」这个能力本身对上层是「按关键词找节点」，过滤是调用方的事。
    return entries;
  }

  // -------------------------------------------------------------------
  // 取流：多路由降级
  // -------------------------------------------------------------------

  /// 取播放直链（含清晰度档位）。
  ///
  /// ## 路由阶梯
  ///
  /// | # | 路由 | 收什么 | 证据 |
  /// |---|---|---|---|
  /// | ① | `/rest/2.0/xpan/multimedia?method=filemetas&dlink=1` | `fsids` | 【未验证】 |
  /// | ② | `/api/filemetas?target=[path]&dlink=1&web=5` | 路径 | 【实测】存活 |
  /// | ③ | `/api/batch/streaming?check_blue=1&type=<档位>` | 路径 | 【客户端】+端点【实测】存活 |
  ///
  /// ⚠️ ② 的 `origin` **按响应里的 `category` 决定**，不是固定值：
  /// 媒体（视频 / 音频）带 `origin=dlna` 走快通道（1~3 MB/s），其余不带
  /// （~80 KB/s，必须单连接）。一次取链因此可能发 **1 次或 2 次**请求 ——
  /// 见 [_resolveOriginalViaPathString]。
  ///
  /// ⛔ 早先「一律不带 `origin`」的做法已废：它消掉了文档的 `31329`，
  /// 却把视频也推进慢通道，播放只有 ~80 KB/s。
  ///
  /// ①② 取**原画**（原文件本身），③ 取**转码档**。三者是
  /// 「同时需要」而非「依次备选」：
  ///   - 原画决定「点开就是原片质量」；
  ///   - 转码档决定画质菜单里有没有东西可选。
  ///
  /// 任一条失败都不影响另一条 —— 拿不到转码档只是菜单里没有它，
  /// 拿不到原画还能退回转码档。
  ///
  /// ## ⛔ 本轮 ①②③ 都**没有真实账号验证过**
  ///
  /// 这一点必须说清楚：端点存活（返回 `-6` 而非 404）是实测的，
  /// 但**响应形状**没验过。所以本方法对每条路由都做「解析不出来就
  /// 换下一条」的处理，而不是「按预期形状硬取」。
  /// 全部失败时如实抛错，不返回一个假票据。
  ///
  /// 短路规则：授权失效（`needsReauth`）与文件不存在（`notFound`）
  /// **立即上抛** —— 换接口结果一样，再打只是白费一次取链配额。
  @override
  Future<StreamTicket> resolveStream(String fileId, {String? qualityId}) async {
    diag.info(
      '取链',
      '百度开始取直链 fs_id=$fileId，'
      '会话=${hasSession ? "有" : "无（会直接抛未授权）"}'
      '${qualityId == null ? "" : "，指定档位=$qualityId"}',
    );

    final failures = <String>[];

    // ── ① 原画：fsid 路由（首选，因为它只收我们手里就有的东西）──────────
    var original = await _attempt(
      'xpan_filemetas',
      failures,
      () => _resolveOriginalViaFsid(fileId),
    );

    // ── ② 原画兜底：路径路由 ─────────────────────────────────────────
    //
    // 只在 ① 失败时才走 —— 它需要路径，而路径可能不在缓存里
    // （那时 _resolvePath 会多打一次请求）。
    original ??= await _attempt(
      'web_filemetas',
      failures,
      () => _resolveOriginalViaPath(fileId),
    );

    // ── ③ 转码档：清晰度菜单的唯一来源 ────────────────────────────────
    final ladder = await _attempt(
      'batch_streaming',
      failures,
      () => _resolveLadder(fileId),
    );

    final merged = _mergeOriginalAndLadder(original: original, ladder: ladder);
    if (merged != null) {
      final switched = _applyQuality(merged, qualityId);
      diag.info(
        '取链',
        '百度取链成功：${switched.redactedUrl}，'
        // ⚠️ 这两项是**现场取证**用的：`redactedUrl` 会丢掉 query，
        // 而「dlink 到底有没有签名」与「用了哪种 UA 方言」正是
        // 2026-10-09 那次「取链成功却 403」最需要看、日志里却没有的东西。
        '查询键=[${_dlinkQueryKeys(switched.url)}]，'
        'UA=${switched.headers['User-Agent']}，'
        '档位=[${_describeQualities(switched.qualities)}]'
        '（原画=${original == null ? "无" : "有"}，'
        '转码档=${ladder?.qualities.length ?? 0} 档）',
      );
      return switched;
    }

    diag.error('取链', '百度全部取链路由失败：${failures.join(" | ")}');
    throw DriveException(
      type: DriveErrorType.unknown,
      message: '取链失败，无法播放该文件。'
          '最后一条错误：${failures.isEmpty ? "无" : failures.last}',
    );
  }

  /// ① 原画（fsid 路由）。
  Future<StreamTicket?> _resolveOriginalViaFsid(String fileId) async {
    final result = await _linkBucket.run(
      () => _request(
        () => _get(BaiduEndpoints.xpanMultimedia, {
          'method': 'filemetas',
          'fsids': '[$fileId]',
          'dlink': 1,
          // 不要缩略图：取链这条路上它没用，只会让响应变大。
          'thumb': 0,
        }),
        context: '取原画直链',
      ),
    );

    // 顺手回填路径缓存 —— filemetas 的响应里带 `path`。
    _pathByFsId.addAll(BaiduMapper.parsePathIndex(result));

    final url = BaiduMapper.parseDlink(result);
    if (url == null) return null;

    return BaiduMapper.toStreamTicket(
      url: url,
      // ① 是**官方**路由（Open Platform 形状），有官方文档背书：
      // UA 固定 `pan.baidu.com`。**不探针** —— 探针是给没文档的 crack 路用的。
      headers: BaiduMapper.dlinkHeaders(
        userAgent: BaiduEndpoints.officialDlinkUserAgent,
        cookieHeader: _cookieHeader,
      ),
      contentLength: _contentLengthOf(result),
    );
  }

  /// ② 原画兜底（路径路由）。
  ///
  /// 路径不在缓存里时先解析一次（解析失败会抛 `notFound`，
  /// 由 [_attempt] 判定是否可降级）。
  Future<StreamTicket?> _resolveOriginalViaPath(String fileId) async {
    final path = _pathByFsId[fileId];
    if (path == null || path.isEmpty) {
      final resolved = await _resolvePath(fileId);
      return _resolveOriginalViaPathString(resolved);
    }
    return _resolveOriginalViaPathString(path);
  }

  /// 取一条直链 —— **先快通道、再按类型分流**。
  ///
  /// ## 一次取链发几次请求，取决于**服务端认定的文件类型**
  ///
  /// 快通道（`origin=dlna`）只服务**媒体**（视频 / 音频），而「这文件是不是
  /// 媒体」这件事只有服务端知道 —— 答案就在取链响应自己的 `info[].category`
  /// 里。所以形状是「**先按快通道取，再看答案**」：
  ///
  /// | `category` | 请求数 | 用哪条直链 |
  /// |---|---|---|
  /// | `1` 视频 / `2` 音频 | **1** | 带 `origin=dlna` 那条（1~3 MB/s） |
  /// | 其他 / 解析不到 | **2** | 重取一次、去掉 `origin`（~80 KB/s，**必须单连接**） |
  ///
  /// 为什么快通道放第一跳而不是反过来：**播放走的就是这条路**，而起播对
  /// 延迟敏感 —— 媒体必须一次往返就拿到地址。文档多一次往返可以忽略
  /// （下载本来就要几十秒）。
  ///
  /// ⚠️ 这条分流是 2026-10-09 下午补的。上午那版「一律不带 `origin`」
  /// 消掉了文档的 `31329`，但把**视频也一起推进了慢通道** —— 现象是
  /// 「能播，但只有 ~80 KB/s」，比原来更糟。
  ///
  /// ⚠️ 音频（`2`）是**当晚补测**的：`category=2` 带 `origin=dlna` 拿到
  /// `vuk` 直链，实测 **1024 KB/s**（不带 origin 只有 84 KB/s）。
  /// 图片与其余类别仍走慢通道 —— 见 [BaiduEndpoints.dlnaCategories]。
  Future<StreamTicket?> _resolveOriginalViaPathString(String path) async {
    // ── 第一取：按**快通道**取 ──────────────────────────────────────
    final fast = await _filemetasOf(path, origin: BaiduEndpoints.dlnaOrigin);
    final fastCategory = fast == null ? null : BaiduMapper.categoryOf(fast);
    if (fast != null && BaiduEndpoints.canUseDlna(fastCategory)) {
      diag.debug('取链', '百度走 dlna 快通道（category=$fastCategory）');
      return _ticketFrom(fast);
    }

    // ── 非视频：dlna 直链会被 CDN 拒（`403 31329 hit illeage dlna`）──
    //    重取一次、去掉 `origin`。那条覆盖面全，但被**按账号**限速到
    //    ~80 KB/s，而且多开连接只会让每条都读超时 ⇒ 票据上钉死单连接。
    try {
      final plain = await _filemetasOf(path, origin: null);
      if (plain != null) {
        diag.debug(
          '取链',
          '百度走普通通道（category=${BaiduMapper.categoryOf(plain)}，单连接）',
        );
        return _ticketFrom(plain, maxConnections: _slowChannelConnections);
      }
    } on DriveException catch (e) {
      // 授权失效 / 文件不存在换条通道也一样，直接上抛。
      if (e.needsReauth || e.type == DriveErrorType.notFound) rethrow;
      diag.warn('取链', '百度去掉 origin 重取失败，退回 dlna 直链：${e.message}');
    }

    // 重取失败：退回第一取的地址。**媒体被误判成非媒体**时这是唯一还能
    // 试一把的机会；真的是非媒体则会在消费时被 CDN 403，由上层如实报错。
    if (fast == null) return null;
    diag.warn('取链', '百度普通通道不可用，退回 dlna 直链（可能只服务媒体）');
    return _ticketFrom(fast);
  }

  /// 普通（无 `origin`）通道的连接数上限。
  ///
  /// 该通道的限速是**按账号**的：2026-10-09 实测 1 条 82 KB/s、
  /// 2 条 76 KB/s、4 条 73 KB/s、8 条 68 KB/s 且**全被服务端掐断**。
  /// 加连接完全不加吞吐，只把每条连接都拖进读超时 —— 必须钉死 1。
  static const int _slowChannelConnections = 1;

  /// 打一次 `/api/filemetas`，返回原始结果；响应里没有可用直链时返回 `null`。
  ///
  /// [origin] 为空表示不带 —— 那会拿到**普通通道**（覆盖面全、慢）；
  /// 给 [BaiduEndpoints.dlnaOrigin] 则拿到**快通道**（只服务媒体：视频 + 音频）。
  Future<HttpResult?> _filemetasOf(String path, {required String? origin}) async {
    final result = await _linkBucket.run(
      () => _request(
        () => _get(BaiduEndpoints.filemetas, {
          // ⛔ 必须是 **JSON 数组字符串**（`["\/电影\/a.mkv"]`），
          // 不是裸路径。服务端按 JSON 解析这个参数。
          'target': jsonEncode([path]),
          'dlink': 1,
          'web': 5,
          if (origin != null && origin.isNotEmpty) 'origin': origin,
        }),
        context: '取原画直链（路径路由）',
      ),
    );
    if (BaiduMapper.parseDlink(result) == null) return null;
    return result;
  }

  /// 把一次 `/api/filemetas` 的结果组装成票据。
  ///
  /// [maxConnections] 只在**普通通道**上传 —— 见
  /// [StreamTicket.maxConnections] 的实测表。
  StreamTicket? _ticketFrom(HttpResult result, {int? maxConnections}) {
    final url = BaiduMapper.parseDlink(result);
    if (url == null) return null;
    return BaiduMapper.toStreamTicket(
      url: url,
      // ⛔ ② 是**网页 crack** 路由：**没有官方文档**，形状只能实测。
      headers: _dlinkHeaders(),
      contentLength: _contentLengthOf(result),
      maxConnections: maxConnections,
    );
  }


  /// ③ 转码档。
  ///
  /// ## 为什么只探**一档**（而不是把 7 档都探一遍）
  ///
  /// 客户端是**逐档**调这个端点的（`getResolution()` 只返回当前选中的
  /// 那一个 `resolution`），不是一次拿全梯度。要枚举全部档位就得打 7 次
  /// 请求，而取链限流是 1 QPS ⇒ **起播前先等 7 秒**。那个代价换不来
  /// 成比例的价值。
  ///
  /// 所以只探**账号默认档**（[BaiduResolution.defaultFor]）：
  ///   - 它是服务端**保证会给**的那一档（客户端自己就用它当默认）；
  ///   - 它正好是「4K 卡顿时切过去」想要的那个较轻的档位；
  ///   - 探不到时 `qualities` 为空 —— 契约里这是一个**有意义的状态**
  ///     （「服务端没有提供转码梯度」），UI 据此隐藏清晰度菜单，
  ///     而不是显示一个只有一项的下拉框。
  ///
  /// ⚠️ 需要路径：`path` 参数收的是 JSON 数组。路径不在缓存里时返回 `null`
  /// （转码档是**附加能力**，不值得为它多打一次路径解析请求）。
  Future<StreamTicket?> _resolveLadder(String fileId) async {
    final path = _pathByFsId[fileId];
    if (path == null || path.isEmpty) {
      diag.debug('取链', '百度转码档跳过：路径未知（fs_id=$fileId）');
      return null;
    }

    final type = BaiduResolution.defaultFor(_vipType);

    final result = await _linkBucket.run(
      () => _request(
        () => _get(BaiduEndpoints.batchStreaming, {
          'check_blue': 1,
          'type': type,
          'path': jsonEncode([path]),
        }),
        context: '取转码档直链',
      ),
    );

    final url = BaiduMapper.parseDlink(result);
    if (url == null) {
      // 端点通了但响应里没有地址。**不抛错** —— 这只是「这一档拿不到」，
      // 原画仍然可播。记一条日志就够，别把它升级成失败。
      diag.debug('取链', '百度转码档响应里没有可用地址（type=$type）');
      return null;
    }

    final option = BaiduMapper.toQualityOption(type: type, url: url);

    return StreamTicket(
      url: url,
      // ③ 是**客户端**端点，同样没有官方文档 ⇒ 与 ② 共用同一个实测形状。
      headers: _dlinkHeaders(),
      expiresAt: _clock().add(BaiduEndpoints.dlinkTtl),
      supportsRange: true,
      qualities: [option],
    );
  }

  // -------------------------------------------------------------------
  // crack 直链的请求头
  // -------------------------------------------------------------------

  /// crack 直链（② 网页取链 / ③ 转码档）的请求头。
  ///
  /// ## 形状是怎么定下来的（两轮实测，第二轮推翻了第一轮的结论）
  ///
  /// 这条路由**没有官方文档**（官方那篇只写 Open Platform 那条，要
  /// `access_token`，扫码会话走不了）。所以形状只能实测。
  ///
  /// ### 第一轮（2026-10-09 上午）：把 `31362` 消掉
  ///
  /// 当时的直链是带 `origin=dlna` 取的，实测：
  ///
  /// | 请求 | 结果 |
  /// |---|---|
  /// | 第一跳 `d.pcs.baidu.com/file/<fid>?…`，UA `netdisk` | **302** → CDN |
  /// | 第二跳 `*.baidupcs.com/…`，UA `netdisk` | **206** |
  /// | 第二跳，UA `Dart/…` / `pan.baidu.com` / `Mozilla/5.0` | `403 31362 sign error` |
  ///
  /// ⇒ 结论「只带 `User-Agent: netdisk`，不带 Cookie / Referer」，且 UA
  /// 必须熬过那条 302（Dart 自动跟随重定向会把它换成 `Dart/x.y (dart:io)`）
  /// ⇒ 消费票据的地方一律走 `applyTicketHeaders`。
  ///
  /// ⚠️ 当时还记了一条「带 `Cookie` + `Referer` → `403 31329`」，并把它
  /// 归因给 Cookie。**那条归因是错的** —— 见下。
  ///
  /// ### 第二轮（2026-10-09 下午：换非会员账号后复现 `31329`）
  ///
  /// 同一账号、同一份 Cookie，**只改文件类型**做对照：
  ///
  /// | 文件 | `category` | 带 `origin=dlna` 的直链 |
  /// |---|---|---|
  /// | `1【摩擦力】…mp4` | 1 视频 | **302 → 206**（5331934 B） |
  /// | `24秋升级版大培优…pdf` | 4 文档 | `403 31329 hit illeage dlna` |
  ///
  /// ⇒ **`31329` 与账号 / 会员 / Cookie 都无关，是「用 dlna（投屏＝视频）
  /// 通道去取非视频文件」**。文案里的 `hit black userlist` 是误导。
  ///
  /// 把 `origin` 去掉之后直链**不带 `vuk`**，此时：
  ///
  /// | 请求 | 结果 |
  /// |---|---|
  /// | 第一跳，**只**带 UA `netdisk` | `403 31045 user not exists` |
  /// | 第一跳，**带 `Cookie`** | **302** → CDN |
  /// | 第二跳，只带 UA `netdisk`（无 Cookie） | **206** |
  /// | 第二跳，UA `Dart/3.7 (dart:io)` + Cookie | **206** |
  ///
  /// ⇒ 无 `origin` 的直链**靠 `Cookie` 认领用户，而且只在第一跳需要**；
  /// 第二跳既不挑 UA 也不看 Cookie。第一跳是我们自己发的（不是重定向），
  /// 所以 **Dart 重定向丢 Cookie 在这里完全无害**。
  ///
  /// ### 第三轮（2026-10-09 傍晚：把「快」找回来）
  ///
  /// 第二轮把 `origin` 一律去掉，覆盖面是对了，但**吞吐塌了**：
  /// 同一账号、同一份 Cookie、同一个视频，只改 `origin` 量吞吐：
  ///
  /// | 取链时带的 `origin` | 直链带 `vuk` | 视频 | 音频 | 文档 | 单连接 |
  /// |---|---|---|---|---|---|
  /// | `dlna` | 是 | 206 ✅ | 206 ✅ | `403 31329` | **1410 / 1024 KB/s** |
  /// | 不带 | 否 | 206 ✅ | 206 ✅ | 206 ✅ | **83 / 84 KB/s** |
  /// | `pc` / `ios` | 否 | 206 ✅ | — | 206 ✅ | 82 / 83 KB/s |
  /// | `web` / `netdisk` / `android` / `tv` / `pan` | 否 | 206 ✅ | — | 206 ✅ | 36~40 KB/s |
  ///
  /// ⇒ **`origin=dlna` 是唯一快的通道，其余统统是「非会员普通下载通道」**，
  /// 被**按账号**限速在 ~80 KB/s（加连接数不加吞吐，只会被掐断）。
  ///
  /// ⇒ 于是不能二选一，只能**按类型分流**：媒体（视频 / 音频）走 dlna、
  /// 其余走普通通道，见 [_resolveOriginalViaPathString]。类型取自响应里的
  /// `category`（服务端权威），不猜扩展名。
  ///
  /// ⛔ 三个关键点：
  ///
  ///   1. **媒体取链带 `origin=dlna`**，非媒体**不带**；
  ///   2. **普通通道的直链必须带 `Cookie`** —— 它是无 `vuk` 直链的
  ///      唯一身份来源（dlna 直链自带 `vuk`，带不带都行）；
  ///   3. **普通通道必须单连接** —— 见 [StreamTicket.maxConnections]。
  ///
  /// `applyTicketHeaders` 是**必须**的：dlna 直链第二跳的 `sign`
  /// 是按 UA 签的，UA 熬不过 302 就变成 `31362 sign error`。
  ///
  /// ⚠️ 这里原先挂着一个「逐条试 5 种形状」的运行时探针，**已删除**：
  /// 它自己就是「UA 熬不过重定向」的受害者（探针走的 HTTP 层同样会丢 UA），
  /// 于是 5 条全报 403，把「形状不对」这个**错误结论**写进了日志。
  Map<String, String> _dlinkHeaders() => BaiduMapper.dlinkHeaders(
        userAgent: BaiduEndpoints.netdiskDlinkUserAgent,
        cookieHeader: _cookieHeader,
        includeCookie: true,
        includeReferer: false,
      );

  /// 试一条取链路径。失败记进 [failures] 并返回 `null`。
  ///
  /// 授权失效 / 文件不存在**直接上抛**（见 [resolveStream] 的短路规则）。
  Future<T?> _attempt<T>(
    String id,
    List<String> failures,
    Future<T?> Function() run,
  ) async {
    try {
      final value = await run();
      if (value == null) {
        diag.warn('取链', '百度 $id：接口通了但响应里没有可用地址');
        failures.add('$id: 响应里没有可用地址');
      }
      return value;
    } on DriveException catch (e) {
      if (e.needsReauth || e.type == DriveErrorType.notFound) {
        diag.error('取链', '百度 $id 失败且不可降级，直接放弃', error: _describe(e));
        rethrow;
      }
      failures.add('$id: ${e.type.name} ${e.message}');
      diag.warn('取链', '百度 $id 失败，其他路由仍可独立工作', error: _describe(e));
      return null;
    }
  }

  /// 把「原画」与「转码档」合成一张票据。两条都缺时返回 `null`。
  ///
  /// 原画**永远排最前**，于是 `StreamTicket.pickActiveQualityId` 在调用方
  /// 没指定档位时自然选中它。
  ///
  /// ⚠️ 与夸克那份有一处**关键差异**：百度各档位流的请求头**不一样**
  /// （原画走 `d.pcs.baidu.com` 要 `pan.baidu.com` UA，转码档可能走别的
  /// CDN）。所以票据的请求头取**原画那一份**，转码档在
  /// [StreamTicket.withQuality] 换档时沿用同一套头 —— 这是当前的近似，
  /// 真实账号验证后如果发现转码档需要不同的头，要改成「每档自带请求头」。
  StreamTicket? _mergeOriginalAndLadder({
    required StreamTicket? original,
    required StreamTicket? ladder,
  }) {
    final base = original ?? ladder;
    if (base == null) return null;

    final qualities = <QualityOption>[
      if (original != null)
        QualityOption(
          id: baiduOriginalQualityId,
          label: '原画',
          url: original.url,
          isOriginal: true,
          estimatedBytes: original.contentLength,
        ),
      ...?ladder?.qualities,
    ];

    return StreamTicket(
      url: base.url,
      headers: base.headers,
      expiresAt: base.expiresAt,
      contentLength: base.contentLength,
      supportsRange: base.supportsRange,
      contentType: base.contentType,
      qualities: qualities,
      // ⛔ 必须跟着走：并发上限是**通道**的属性，漏掉它会让文档下载
      //    退回「8 条连接打一条 80 KB/s 的通道」——那正是要修的 bug。
      maxConnections: base.maxConnections,
    );
  }

  /// 按 [qualityId] 换档。找不到 / 没地址时**保留原画**（不抛错）。
  ///
  /// 与夸克那份逐字同构，理由见 `CloudDriveAdapter.resolveStream` 的文档：
  /// 「传了但服务端这次没给这一档 → 降级到可用档位并如实返回，绝不抛错」。
  StreamTicket _applyQuality(StreamTicket ticket, String? qualityId) {
    if (qualityId == null || qualityId.isEmpty) return ticket;
    final q = ticket.qualityById(qualityId);
    if (q == null) {
      diag.warn(
        '取链',
        '百度指定档位 $qualityId 不在本次结果里'
            '（可用=[${_describeQualities(ticket.qualities)}]），保留原画',
      );
      return ticket;
    }
    if (!q.isAvailable) {
      diag.warn('取链', '百度档位 $qualityId 没有地址，保留原画');
      return ticket;
    }
    return ticket.withQuality(q);
  }

  /// 读取小文件的原始字节（CUE 分轨表、字幕）。
  ///
  /// 走原画直链 + `getBytes`。**返回原始字节而不是 `String`** 是必须的：
  /// 中文抓轨的 CUE 大量是 GBK，谁先把它解成字符串，非法字节就已经变成
  /// `�`，编码判定再也做不了（见基类 [readFileBytes] 的文档）。
  @override
  Future<Uint8List> readFileBytes(
    String fileId, {
    int maxBytes = 512 * 1024,
  }) async {
    final ticket = await resolveStream(fileId);
    if (ticket.contentLength != null && ticket.contentLength! > maxBytes) {
      throw DriveException(
        type: DriveErrorType.fileTooLarge,
        message: '文件 ${_formatBytes(ticket.contentLength!)} '
            '超过读取上限 ${_formatBytes(maxBytes)}',
      );
    }

    final bytes = await _http.getBytes(
      ticket.url.toString(),
      headers: ticket.headers,
    );
    if (bytes == null) {
      throw const DriveException(
        type: DriveErrorType.network,
        message: '读取文件内容失败（网络层）',
      );
    }
    if (bytes.length > maxBytes) {
      throw DriveException(
        type: DriveErrorType.fileTooLarge,
        message: '文件实际大小 ${_formatBytes(bytes.length)} '
            '超过读取上限 ${_formatBytes(maxBytes)}',
      );
    }
    return bytes;
  }

  @override
  Future<void> dispose() async {
    _credential = null;
    _account = null;
    _pathByFsId.clear();
  }

  // -------------------------------------------------------------------
  // 图片取用
  // -------------------------------------------------------------------

  /// 缩略图 / 预览图地址的归属判定。
  ///
  /// 百度给的缩略图地址来自 `thumbs` 字段，主机可能是 `pan.baidu.com`、
  /// `d.pcs.baidu.com`、`thumbnail.baidu.com` 等多个域，所以按
  /// **`baidu.com` 后缀**判而不是枚举主机 —— 枚举漏一个的后果是
  /// 海报请求不带 Cookie 而拿到 403，表现是海报墙上整片灰块。
  @override
  bool ownsUrl(String url) => url.contains('baidu.com');

  /// 取缩略图时带的请求头。
  ///
  /// 与夸克不同，百度**不需要**「每次现取以防轮换」—— 它不轮换 Cookie。
  /// 但仍然每次现取：`_cookieHeader` 读的是内存里当前那份，而这在
  /// 重新授权后会变。缓存一份旧 Cookie 的后果与夸克一样（403 / 灰块）。
  @override
  Map<String, String> imageHeaders() => _headers();

  // -------------------------------------------------------------------
  // 路径解析
  // -------------------------------------------------------------------

  /// 把 `fs_id` 翻译成路径。
  ///
  /// 命中缓存就返回；未命中才打一次 `filemetas`。见 [_pathByFsId] 的文档。
  Future<String> _resolvePath(String dirId) async {
    if (dirId.isEmpty || dirId == rootId) return BaiduEndpoints.rootId;

    final cached = _pathByFsId[dirId];
    if (cached != null && cached.isNotEmpty) return cached;

    diag.debug('列目录', '百度路径缓存未命中，查询 fs_id=$dirId');

    final result = await _listBucket.run(
      () => _request(
        () => _get(BaiduEndpoints.xpanMultimedia, {
          'method': 'filemetas',
          'fsids': '[$dirId]',
          'dlink': 0,
          'thumb': 0,
        }),
        context: '解析目录路径',
      ),
    );

    final index = BaiduMapper.parsePathIndex(result);
    _pathByFsId.addAll(index);

    final path = index[dirId];
    if (path == null || path.isEmpty) {
      throw DriveException(
        type: DriveErrorType.notFound,
        message: '找不到目录的路径（fs_id=$dirId）',
      );
    }
    return path;
  }

  // -------------------------------------------------------------------
  // 账号信息
  // -------------------------------------------------------------------

  /// 拉一次账号信息（`uinfo` + `quota`）。
  ///
  /// ## 两个接口分开容错
  ///
  /// `uinfo` 失败 ⇒ 上抛（它同时是**凭证有效性**的判据，授权流程依赖它）。
  /// `quota` 失败 ⇒ 只记日志（容量是附属信息，拿不到最多是不显示容量条，
  /// 不该让整个登录失败）。
  Future<CloudAccount> _fetchAccount() async {
    final uinfoRes = await _request(
      () => _get(BaiduEndpoints.accountUinfo),
      context: '获取账号信息',
    );

    final uinfo = uinfoRes.json ?? const <String, Object?>{};
    _vipType = BaiduMapper.parseVipType(uinfo);

    var account = CloudAccount(
      provider: DriveProvider.baidu,
      authMode: _credential?.mode ?? AuthMode.qrCode,
      authorizedAt: _credential?.capturedAt ?? _clock(),
    );
    account = BaiduMapper.mergeAccountInfo(account, uinfo);

    try {
      final quotaRes = await _request(
        () => _get(BaiduEndpoints.quota),
        context: '获取容量',
      );
      account = BaiduMapper.mergeQuota(
        account,
        quotaRes.json ?? const <String, Object?>{},
      );
    } on DriveException catch (e) {
      diag.warn('会话', '百度容量信息获取失败（不影响登录）：${e.message}');
    }

    return account;
  }

  // -------------------------------------------------------------------
  // 请求管线
  // -------------------------------------------------------------------

  /// 统一请求包装：注入公共参数与请求头，校验业务码，归一化异常。
  ///
  /// ## `-6` 会**自愈一次**
  ///
  /// 百度把「缺 `bdstoken`」和「凭证真的废了」都报成 `errno=-6`。前者
  /// 是可以自愈的：补一次 `bdstoken` 再打一遍就好。所以这里在
  /// `unauthorized` 且**本次还没取过 `bdstoken`** 时，先补令牌、再重试
  /// **一次**（[allowBdstokenRetry] 防止递归）。
  ///
  /// 为什么不「登录时就先把 `bdstoken` 取好」：客户端自己也是**先**调
  /// `/api/account/uinfo`（那时还没有 `bdstoken`）、**再**去取它。
  /// 把顺序倒过来会在「取令牌本身失败」时把登录也一起拖垮。
  Future<HttpResult> _request(
    Future<HttpResult> Function() call, {
    String? context,
    bool allowBdstokenRetry = true,
  }) async {
    if (!hasSession) {
      diag.error('接口', '百度${context ?? "请求"}：尚未授权（没有 Cookie）');
      throw DriveException(
        type: DriveErrorType.unauthorized,
        message: '${context ?? "请求"}：尚未授权百度网盘账号',
      );
    }

    final result = await call();
    if (isBaiduSuccess(result)) {
      // ⚠️ 这里**没有** Cookie 轮换回填 —— 与夸克的关键差异。
      // 百度不轮换（实测 `/api/list` 响应无 `Set-Cookie`），所以不需要
      // 那套 `_absorbRotatedCookies`。哪天真观察到轮换了再加。
      return result;
    }

    final e = baiduExceptionFrom(result, context: context);
    _logBody(context, result);
    diag.error('接口', '百度${context ?? "请求"}业务失败', error: _describe(e));

    if (allowBdstokenRetry &&
        e.type == DriveErrorType.unauthorized &&
        (_bdstoken == null || _bdstoken!.isEmpty)) {
      final token = await _ensureBdstoken();
      if (token != null && token.isNotEmpty) {
        diag.info('接口', '百度补上 bdstoken 后重试${context ?? "请求"}');
        return _request(call, context: context, allowBdstokenRetry: false);
      }
    }

    throw e;
  }

  /// 业务失败时把**原始响应体**（截断）打进日志。
  ///
  /// ## 为什么非留不可
  ///
  /// 百度的 `-6` 是**一码多义**（没带 Cookie / Cookie 废 / 缺 `bdstoken` /
  /// 账号级风控），而区分它们唯一可靠的线索是服务端原话 `show_msg` ——
  /// 可它**常常根本不出现**：2026-10-09 实测 `/api/account/uinfo` 的失败
  /// 响应只有裸 `{"errno":-6}`，连 `show_msg` 都没有。那时只记归一化文案
  /// 就等于把唯一的线索丢了。
  ///
  /// ⚠️ 只打**错误**响应体（不含凭据），且截断到 300 字符。
  static void _logBody(String? context, HttpResult result) {
    final body = result.rawBody.trim();
    if (body.isEmpty) return;
    final shown = body.length > 300 ? '${body.substring(0, 300)}…' : body;
    diag.debug('接口', '百度${context ?? "请求"}响应体：$shown');
  }

  /// 取（并缓存）`bdstoken`。
  ///
  /// 两条来源按客户端 URL 表都试一遍：`gettemplatevariable`（先）与
  /// `get/template`（后）。两条都失败返回 `null` —— 调用方据此决定
  /// 「不带令牌继续」而不是「直接失败」。
  Future<String?> _ensureBdstoken() async {
    final cached = _bdstoken;
    if (cached != null && cached.isNotEmpty) return cached;

    for (final path in const [
      BaiduEndpoints.gettemplatevariable,
      BaiduEndpoints.getTemplate,
    ]) {
      try {
        // ⛔ `withBdstoken: false` —— 正在取它，带上必然是空的。
        final res = await _get(
          path,
          const {'fields': BaiduEndpoints.templateFields},
          false,
        );
        final token = BaiduMapper.bdstokenOf(res);
        if (token != null && token.isNotEmpty) {
          _bdstoken = token;
          diag.info('接口', '百度已取到 bdstoken（来源 $path）');
          return token;
        }
        diag.warn(
          '接口',
          '百度 $path 未返回 bdstoken（errno=${res.businessCode}）',
        );
      } on DriveException catch (e) {
        diag.warn('接口', '百度 $path 取 bdstoken 失败：${_describe(e)}');
      }
    }
    return null;
  }

  /// 网盘 API 的公共请求头。
  ///
  /// ⚠️ `Origin` 不能省。它是本适配器与一个**已知能跑通**的社区实现
  /// （`baidu_pcs.py`）之间唯一的结构性差异 —— 2026-10-08 的实测日志里
  /// 发往 `/api/account/uinfo` 的请求缺了它，而那次拿到了 `errno=-6`。
  /// 见 [BaiduEndpoints.origin]。
  Map<String, String> _headers() => {
        'User-Agent': BaiduEndpoints.userAgent,
        'Accept': BaiduEndpoints.accept,
        'Accept-Language': BaiduEndpoints.acceptLanguage,
        'Referer': BaiduEndpoints.referer,
        'Origin': BaiduEndpoints.origin,
        'Cookie': _cookieHeader,
      };

  /// 打一条网盘 API。
  ///
  /// [withBdstoken] 为 `false` 时不带令牌（只有「取令牌本身」需要）。
  Future<HttpResult> _get(
    String path, [
    Map<String, Object?>? params,
    bool withBdstoken = true,
  ]) {
    final token = _bdstoken;
    return _http.get(
      '$_gateway$path',
      query: {
        ...BaiduEndpoints.commonParams,
        if (withBdstoken && token != null && token.isNotEmpty)
          'bdstoken': token,
        ...?params,
      },
      headers: _headers(),
    );
  }

  // -------------------------------------------------------------------
  // 小工具
  // -------------------------------------------------------------------

  /// 从取链响应里捞体积。
  static int? _contentLengthOf(HttpResult result) {
    for (final item in BaiduMapper.listItemsOf(result)) {
      final n = _asInt(item['size']);
      if (n != null && n > 0) return n;
    }
    return null;
  }

  /// 分页游标解析。非法值回落到第 1 页。
  static int _parsePageToken(String? token) {
    if (token == null || token.isEmpty) return 1;
    final n = int.tryParse(token);
    if (n == null || n < 1) return 1;
    return n;
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// 宽容布尔解析（服务端可能给 `true` / `1` / `"1"`）。
  static bool? _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.toLowerCase().trim();
      if (s == 'true' || s == '1') return true;
      if (s == 'false' || s == '0') return false;
    }
    return null;
  }

  String _vipLabel() => BaiduVipType.labelFor(_vipType);

  /// 错误摘要（日志用）。
  ///
  /// ⚠️ 必须带上 [DriveException.rawMessage]（百度是 `show_msg`）——
  /// `-6` 这一个码**同时**表示「没带 Cookie」「Cookie 废了」以及
  /// 「账号级临时风控」三种情况，光看 [DriveException.message]（我们自己拼
  /// 的中文）分不出来。服务端原话（`账户已过期，重新登陆` / 风控文案）
  /// 才是区分判据，所以把它一并记进日志。
  static String _describe(DriveException e) {
    final raw = e.rawMessage;
    final tail =
        (raw == null || raw.isEmpty || raw == e.message) ? '' : ' raw=$raw';
    return '${e.type.name} code=${e.providerCode} http=${e.httpStatus} '
        '${e.message}$tail';
  }

  /// 档位列表的可读描述（日志用）。
  ///
  /// ⚠️ 刻意不 import 夸克那份 `describeQualities`：它住在
  /// `quark/quark_play_routes.dart` 里，从百度适配器去 import 夸克的
  /// 播放路由文件是**假的耦合**（两家除了「都有清晰度档位」之外无关）。
  /// 这三行格式化重复一份，比跨家依赖便宜得多。
  static String _describeQualities(List<QualityOption> qualities) {
    if (qualities.isEmpty) return '无档位（只有原画流）';
    return qualities
        .map((q) => '${q.id}${q.height == null ? "" : "(${q.height}p)"}')
        .join(', ');
  }

  /// 直链 query 的**键名**（不取值，避免把 `sign` 写进日志）。
  ///
  /// 用途只有一个：判断这条 dlink 到底**有没有签名**。百度正常签发的
  /// dlink 一定带 `fid`/`time`/`sign` 这一组；只有路径没有 query 说明
  /// 我们解析错了字段（那时下载必然 403/31360，且日志里看不出来）。
  static String _dlinkQueryKeys(Uri url) {
    final keys = url.queryParametersAll.keys.toList()..sort();
    return keys.isEmpty ? '-' : keys.join(',');
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }
}
