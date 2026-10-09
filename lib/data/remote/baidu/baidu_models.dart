import '../../../domain/entities/cloud_account.dart';
import '../../../domain/entities/drive_entry.dart';
import '../../../domain/entities/drive_provider.dart';
import '../../../domain/entities/quality_option.dart';
import '../../../domain/entities/stream_ticket.dart';
import '../../http/http_client.dart';
import 'baidu_endpoints.dart';

/// 百度响应字段 → 领域模型的映射。
///
/// 全部是纯函数，字段名按逆向 Mac 客户端 + 上一轮探针实测校准。
///
/// ## ⛔ 第一个坑：列表不在 `data.list` 里
///
/// 夸克的列表在 `data.list`，所以共用的 [HttpResult.dataListItems] 直接能用。
/// **百度不是** —— `/api/list` 与 `/api/search` 把数组放在**顶层**：
///
/// ```json
/// { "errno": 0, "list": [ {...}, {...} ], "request_id": 123 }
/// ```
///
/// 所以本文件一律走 [listItemsOf]，它同时认 `list`、`info`、`data.list`、
/// `data.info` 四种位置。只认一种的后果是**列表永远是空的，而且不报错** ——
/// 扫描器会认为「这个网盘一个文件都没有」。
///
/// ## 字段对照表
///
/// | 百度字段 | 含义 | 易错点 |
/// |---|---|---|
/// | `fs_id` | 文件/目录 ID（**数字**） | 必须转成字符串，主键是文本 |
/// | `server_filename` | 名称 | 不是 `name` |
/// | `isdir` | `1`=目录 `0`=文件 | **与夸克 `file_type` 的 0/1 语义相反** |
/// | `path` | 完整路径 | 取直链与列目录都要它 |
/// | `size` | 体积 | 目录为 0 |
/// | `server_mtime` | 修改时间 | unix **秒** |
/// | `duration` | 时长（秒） | 单位是秒，与夸克一致 |
/// | `thumbs` | 缩略图字典 | `url1/url2/url3` 三档 |
class BaiduMapper {
  const BaiduMapper._();

  // ------------------------------------------------------------------
  // 列表项
  // ------------------------------------------------------------------

  /// 从响应里捞出列表项，**四种位置都认**。
  ///
  /// 见类文档的「第一个坑」。顺序是「顶层优先」：百度的实际形状是顶层，
  /// 顶层没有才去 `data` 里找（防御未来改版）。
  static List<Map<String, Object?>> listItemsOf(HttpResult result) {
    final json = result.json;
    if (json == null) return const [];

    for (final key in const ['list', 'info']) {
      final v = json[key];
      if (v is List) {
        final items = v.whereType<Map<String, Object?>>().toList();
        if (items.isNotEmpty) return items;
      }
    }

    // 退到共用取法（`data.list` / `data` 为数组）
    return result.dataListItems;
  }

  /// 从 `gettemplatevariable` / `get/template` 的响应里捞 `bdstoken`。
  ///
  /// ## 为什么单独写一个
  ///
  /// `bdstoken` 是网盘 `/api/*` 的**会话令牌**：缺了它服务端回
  /// `errno=-6`「登录状态无效」，与「凭证废了」**同一个码**。
  /// 客户端登录链的第 7 步专门取它，本适配器早期整条链路都没带。
  ///
  /// ## 形状
  ///
  /// 两条来源的层级不同，所以**两层都找**：
  ///   - `{"errno":0,"result":{"bdstoken":"…"}}`（`gettemplatevariable`）；
  ///   - `{"errno":0,"bdstoken":"…"}`（防御 `get/template` 的扁平形状）。
  ///
  /// 找不到返回 `null` —— 调用方据此决定「不带令牌继续」，不抛错。
  static String? bdstokenOf(HttpResult result) {
    final json = result.json;
    if (json == null) return null;

    final direct = json['bdstoken'];
    if (direct is String && direct.isNotEmpty) return direct;

    final nested = json['result'];
    if (nested is Map) {
      final v = nested['bdstoken'];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// 解析 `isdir` 判定是否为目录。
  ///
  /// ⚠️ **`isdir` 的语义与夸克的 `file_type` 相反**：
  ///   - 百度 `isdir`: `1` = 目录，`0` = 文件；
  ///   - 夸克 `file_type`: `0` = 目录，`1` = 文件。
  ///
  /// 照着夸克那份抄会**把整个目录树反过来** —— 文件被当成目录去递归，
  /// 目录被当成文件入库。现象是「扫描了几万个『文件』，全是目录名」。
  static bool parseIsDirectory(Map<String, Object?> json) {
    final v = json['isdir'];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
      final n = int.tryParse(lower);
      if (n != null) return n != 0;
    }
    // 兜底：没有 isdir 时，有 `size` 且无 `path` 结尾斜杠的按文件算。
    // 保守判为文件 —— 判成目录会让 BFS 队列爆炸，判成文件最多漏扫一层。
    return false;
  }

  /// 单个列表项 → [DriveEntry]。缺关键字段时返回 `null`（跳过脏数据）。
  static DriveEntry? toEntry(Map<String, Object?> json) {
    // fs_id 是**数字**，而契约要求 `id` 是字符串。`_asString` 会走
    // `toString()`，但 1234567890 与 1234567890.0 会得到不同字符串 ——
    // 所以数字分支单独处理，避免 `1.23456789e9` 这种科学计数法形态。
    final id = _fsIdOf(json);
    if (id == null || id.isEmpty) return null;

    final name = _asString(json['server_filename']) ??
        _asString(json['filename']) ??
        _asString(json['name']);
    if (name == null || name.isEmpty) return null;

    final isDir = parseIsDirectory(json);
    final thumbs = json['thumbs'];

    return DriveEntry(
      id: id,
      name: name,
      isDirectory: isDir,
      sizeBytes: isDir ? 0 : _asInt(json['size']),
      mimeType: isDir ? null : _mimeFromEntry(json),
      modifiedAt: parseTimestamp(json['server_mtime'] ?? json['local_mtime']),
      parentId: null, // 百度列表项不带父 ID，只有完整 path
      // 百度**直接给完整路径**（`/电影/xxx.mkv`），扫描器不必自己拼。
      // 但契约里 `path` 是「展示用路径（由扫描器按遍历栈拼出）」，
      // 两者含义一致，所以这里照填 —— 有真值就用真值。
      path: _asString(json['path']),
      durationMs: isDir ? null : parseDurationMs(json['duration']),
      // 【未验证】缩略图三档：url1 最小、url3 最大。
      // 与夸克一样，**必须带 Cookie 才能取到**（走 `imageHeaders()`）。
      thumbnailUrl: isDir ? null : _thumb(thumbs, const ['url1', 'url2']),
      previewImageUrl: isDir ? null : _thumb(thumbs, const ['url3', 'url2']),
      videoWidth: isDir ? null : _positive(json['width']),
      videoHeight: isDir ? null : _positive(json['height']),
      // 百度列表项**不给人脸框**（夸克的 `cover_face_boundary` 没有对应物）。
      // 留 `null`，渲染时退回画面正中 —— 这是诚实的降级，不是缺陷。
      faceAnchorX: null,
    );
  }

  /// 批量映射，自动跳过脏数据。
  static List<DriveEntry> toEntries(Iterable<Map<String, Object?>> items) =>
      items.map(toEntry).whereType<DriveEntry>().toList();

  /// 从 [DriveEntry] 列表里抽出 `fs_id → path` 映射。
  ///
  /// 适配器用它维护路径缓存：百度的列目录 / 取直链都要**路径**，
  /// 而调用方手里只有 `fs_id`（契约里的 `dirId` / `fileId`）。
  /// 列表项自带 `path`，所以每列一次目录就白捡一批映射。
  static Map<String, String> pathIndex(Iterable<DriveEntry> entries) {
    final out = <String, String>{};
    for (final e in entries) {
      final p = e.path;
      if (p != null && p.isNotEmpty) out[e.id] = p;
    }
    return out;
  }

  /// 取 `fs_id` 并转成稳定的字符串。
  static String? _fsIdOf(Map<String, Object?> json) {
    for (final key in const ['fs_id', 'fsid', 'id']) {
      final v = json[key];
      if (v == null) continue;
      if (v is int) return v.toString();
      if (v is num) {
        // 整数型的 double（JSON 解析器偶尔会给）要走 toInt，
        // 否则会得到 `1234567890.0` 这种带小数点的 id。
        final d = v.toDouble();
        return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
      }
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// `thumbs` 是一个字典（或数组），按优先级取第一个非空地址。
  static String? _thumb(Object? thumbs, List<String> keys) {
    if (thumbs is Map) {
      for (final k in keys) {
        final v = thumbs[k];
        if (v is String && v.isNotEmpty) return v;
      }
      // 字典里任何非空的都行（字段名可能变）
      for (final v in thumbs.values) {
        if (v is String && v.isNotEmpty) return v;
      }
      return null;
    }
    if (thumbs is List) {
      for (final v in thumbs) {
        if (v is String && v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// 从列表项猜 MIME。
  ///
  /// 百度不给 MIME 字符串，只给 `category`（1=视频 2=音频 3=图片 …）与
  /// `media_type`。这里**优先按扩展名**，因为分类字段的取值没实测过，
  /// 猜错会把 `.mkv` 标成音频。
  static String? _mimeFromEntry(Map<String, Object?> json) {
    final name = _asString(json['server_filename']) ??
        _asString(json['filename']) ??
        '';
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mkv':
        return 'video/x-matroska';
      case 'avi':
        return 'video/x-msvideo';
      case 'ts':
      case 'm2ts':
        return 'video/mp2t';
      case 'mov':
        return 'video/quicktime';
      case 'wmv':
        return 'video/x-ms-wmv';
      case 'flv':
        return 'video/x-flv';
      case 'rmvb':
        return 'application/vnd.rn-realmedia-vbr';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'flac':
        return 'audio/flac';
      case 'aac':
        return 'audio/aac';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'ape':
        return 'audio/x-ape';
      case 'cue':
        return 'text/plain';
      default:
        return null;
    }
  }

  // ------------------------------------------------------------------
  // 账号信息
  // ------------------------------------------------------------------

  /// 会员档位解析。
  ///
  /// 百度在不同接口里给不同的字段：`vip_type`（数字）、
  /// `member_type`、`product_name`。数字口径与客户端一致
  /// （`{normal:0, vip:1, svip:2}`，见 [BaiduVipType]）。
  ///
  /// ## 为什么自己拆 `data` 层
  ///
  /// `/api/account/uinfo` 把字段包在 `data` 里，而 `/api/quota` 放在顶层
  /// （与列表同一个坑）。让**调用方**去判断包在哪一层，等于把这个知识
  /// 复制到每个调用点 —— 早晚会有一处漏判，然后「会员等级永远是普通用户」，
  /// 表现是清晰度菜单少几档，且不报任何错。所以在这里一次拆干净。
  ///
  /// ⚠️ **认不出来时返回 [BaiduVipType.normal]**（而不是抛错）：
  /// 会员等级只影响「要不要去请求转码档」，认错的后果是画质菜单少几档，
  /// 而抛错会让整个账号信息加载失败、连容量条都不显示。
  static int parseVipType(Map<String, Object?> json) {
    final data = _nested(json, 'data') ?? json;
    return _parseVipTypeFlat(data);
  }

  static int _parseVipTypeFlat(Map<String, Object?> data) {
    for (final key in const ['vip_type', 'vipType', 'member_type']) {
      final n = _asInt(data[key]);
      if (n != null) {
        if (n >= BaiduVipType.svip) return BaiduVipType.svip;
        if (n == BaiduVipType.vip) return BaiduVipType.vip;
        return BaiduVipType.normal;
      }
    }
    // 字符串形态：`svip` / `vip2` / `vip` 之类
    for (final key in const ['product_name', 'detail_cluster', 'cluster']) {
      final s = _asString(data[key])?.toLowerCase();
      if (s == null || s.isEmpty) continue;
      if (s.contains('svip') || s.contains('super')) return BaiduVipType.svip;
      if (s.contains('vip')) return BaiduVipType.vip;
    }
    return BaiduVipType.normal;
  }

  /// 账号信息 → [CloudAccount] 的可选字段。
  ///
  /// ## 为什么容量要多认几种形状
  ///
  /// `/api/quota` 的响应把 `total` / `used` 放在**顶层**（与列表同一个坑），
  /// 而 `/api/account/uinfo` 可能把容量包在 `data` 里。两个接口都可能被
  /// 单独调用（容量刷新只需要 quota），所以这里对「在哪一层」不做假设。
  ///
  /// 认错字段的后果**不是报错**，而是界面上静静地少一条容量条 ——
  /// 所以宁可多认几个名字。
  static CloudAccount mergeAccountInfo(
    CloudAccount base,
    Map<String, Object?> uinfo,
  ) {
    final data = _nested(uinfo, 'data') ?? uinfo;

    return base.copyWith(
      displayName: _asString(data['netdisk_name']) ??
          _asString(data['baidu_name']) ??
          _asString(data['username']) ??
          _asString(data['nickname']),
      userId: _ukOf(data) ?? base.userId,
      avatarUrl: _asString(data['avatar_url']) ?? base.avatarUrl,
      memberLabel: BaiduVipType.labelFor(parseVipType(data)),
    );
  }

  /// 把容量信息并进账号。
  ///
  /// ⚠️ 单独一个方法而不是并进 [mergeAccountInfo]：容量走
  /// `/api/quota`、账号走 `/api/account/uinfo`，**两个接口可能一个成功
  /// 一个失败**。合在一起会让「拿不到容量」连带把昵称也丢掉。
  static CloudAccount mergeQuota(
    CloudAccount base,
    Map<String, Object?> quota,
  ) {
    final data = _nested(quota, 'data') ?? quota;

    int? pick(List<String> keys) {
      for (final k in keys) {
        final n = _asInt(data[k]);
        if (n != null && n > 0) return n;
      }
      return null;
    }

    return base.copyWith(
      storageTotalBytes: pick(const ['total', 'quota', 'total_capacity']),
      storageUsedBytes: pick(const ['used', 'use_capacity', 'used_capacity']),
    );
  }

  /// 取用户 ID（百度叫 `uk`）。
  static String? _ukOf(Map<String, Object?> data) {
    for (final key in const ['uk', 'user_id', 'uid']) {
      final v = data[key];
      if (v is int) return v.toString();
      if (v is num) return v.toInt().toString();
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 取直链
  // ------------------------------------------------------------------

  /// 从取链响应里解析出 `dlink`。
  ///
  /// ## 三条路由的响应形状都不一样
  ///
  /// | 路由 | 数组字段 | 地址字段 |
  /// |---|---|---|
  /// | `/api/filemetas?target=[path]&dlink=1` | `info` | `dlink` |
  /// | `/rest/2.0/xpan/multimedia?method=filemetas` | `list` | `dlink` |
  /// | `/api/mediainfo?type=VideoURL` | `info` / `data` | `dlink` / `url` |
  ///
  /// 一律走 [listItemsOf] 取数组，再逐个候选字段找地址。
  /// 返回 `null` 表示响应里没有可用直链（调用方据此换下一条路由）。
  static Uri? parseDlink(HttpResult result) {
    for (final item in listItemsOf(result)) {
      final url = dlinkOf(item);
      if (url != null) return url;
    }
    // 有些路由把地址直接放顶层
    final top = result.json;
    if (top != null) {
      final url = dlinkOf(top);
      if (url != null) return url;
    }
    return null;
  }

  /// 从单个对象里取 `dlink`（也认 `url` / `download_url`）。
  static Uri? dlinkOf(Map<String, Object?> item) {
    for (final key in const [
      'dlink',
      'download_url',
      'downloadUrl',
      'url',
      'link',
    ]) {
      final v = item[key];
      if (v is String && v.isNotEmpty) {
        final uri = Uri.tryParse(v);
        // `hasScheme` 是必须的：百度偶尔给协议相对地址（`//d.pcs.…`），
        // 直接当绝对地址用会让播放器拿到一个没有 scheme 的 URI。
        if (uri != null && uri.hasScheme) return uri;
        if (v.startsWith('//')) {
          final fixed = Uri.tryParse('https:$v');
          if (fixed != null) return fixed;
        }
      }
    }
    return null;
  }

  /// 从取链响应里解析出 `fs_id → path`。
  ///
  /// 用于适配器的路径缓存回填：`filemetas` 的响应里带 `path`，
  /// 所以「只有 fs_id 不知道路径」这种情况可以靠它补上。
  static Map<String, String> parsePathIndex(HttpResult result) {
    final out = <String, String>{};
    for (final item in listItemsOf(result)) {
      final id = _fsIdOf(item);
      final path = _asString(item['path']);
      if (id != null && id.isNotEmpty && path != null && path.isNotEmpty) {
        out[id] = path;
      }
    }
    return out;
  }

  /// 直链请求头的**默认形状**。
  ///
  /// ⚠️ 这只是「没探测出更好的形状时」的兜底。**它已经被实测证伪过两次**
  /// （2026-10-09：UA 用 `pan.baidu.com` 403，改成 `netdisk` 仍 403），
  /// 所以 crack 路由的真实形状由 `BaiduAdapter` 用探针实测决定，
  /// 不靠这里猜。本方法保留给官方路由（有官方文档背书）与探针全败时的兜底。
  ///
  /// [includeCookie] / [includeReferer] 可关：探针要能试出
  /// 「不要 Cookie / 不要 Referer」的形状 —— 社区实现 AList 的 crack 路由
  /// **两个都不带**，所以它们都可能是 403 的真因。
  static Map<String, String> dlinkHeaders({
    required String userAgent,
    required String cookieHeader,
    bool includeCookie = true,
    bool includeReferer = true,
  }) {
    return <String, String>{
      'User-Agent': userAgent,
      'Accept': '*/*',
      if (includeReferer) 'Referer': '${BaiduEndpoints.panHost}/',
      if (includeCookie && cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
  }

  /// 从取链响应里解析出**服务端认定的文件类型**。
  ///
  /// `/api/filemetas` 的 `info[]` 里带 `category`（1 视频 / 2 音频 /
  /// 3 图片 / 4 文档 / 5 应用 / 6 其他，常量见 [BaiduEndpoints]）。
  /// 【实测】同一份响应里，`.mp4` 是 `1`、`.pdf` 是 `4`。
  ///
  /// ## 为什么值得单独一个方法
  ///
  /// 它决定**走哪条直链通道**：只有视频能走 `origin=dlna` 的快通道
  /// （1~3 MB/s），其余一律走被限速到 ~80 KB/s 的普通通道，而且
  /// 后者还必须单连接（见 [StreamTicket.maxConnections]）。
  ///
  /// 用服务端的 `category` 而不是文件扩展名：它是权威的，
  /// 能正确处理「扩展名骗人」（一个叫 `.mp4` 的 PDF）。
  ///
  /// 解析不到返回 `null` —— 调用方据此走**保守**的那条（慢通道）。
  static int? categoryOf(HttpResult result) {
    for (final item in listItemsOf(result)) {
      final n = _asInt(item['category']);
      if (n != null) return n;
    }
    return null;
  }

  /// 组装 [StreamTicket]。
  ///
  /// ## ⛔ 请求头必须由调用方显式给，这里**不替它猜**
  ///
  /// 百度的直链请求形状是**按路由分的方言**，而且 crack 那条路
  /// **没有任何官方文档**（官方文档只写 Open Platform 那条，要
  /// `access_token`，我们走不了）。所以形状一旦猜错，现象是
  /// **CDN 硬 403**——它发生在业务层之前（业务错都是 HTTP 200 + JSON），
  /// 日志上看起来像「直链过期」，极难反查。
  ///
  /// [headers] 因此是 required：形状的**决策权在调用方**（见
  /// `BaiduAdapter._dlinkHeaders` 的实测表），这里只负责组装。
  ///
  /// ## 为什么 `expiresAt` 用 `dlinkTtl` 而不是解析 URL
  ///
  /// 夸克直链的 `auth_key` 第 1 段就是真实过期时刻，所以那边能精确解析。
  /// **百度的 `dlink` 不带过期时间戳**（只有 `time=` 签发时刻），
  /// 所以只能按服务端声明的 8 小时倒推。这是诚实的近似：
  /// 宁可提前判过期（30 分钟后重新取链），也不要中途断流。
  ///
  /// ## [maxConnections] 是**通道**的属性
  ///
  /// 由调用方按取链时用的 `origin` 决定，见 [StreamTicket.maxConnections]
  /// 的实测表。这里只是透传，不做判断。
  static StreamTicket toStreamTicket({
    required Uri url,
    required Map<String, String> headers,
    int? contentLength,
    String? contentType,
    DateTime? now,
    int? maxConnections,
  }) {
    final fetchedAt = now ?? DateTime.now();
    return StreamTicket(
      url: url,
      headers: headers,
      expiresAt: fetchedAt.add(BaiduEndpoints.dlinkTtl),
      contentLength: contentLength,
      contentType: contentType,
      supportsRange: true,
      maxConnections: maxConnections,
    );
  }

  // ------------------------------------------------------------------
  // 清晰度档位
  // ------------------------------------------------------------------

  /// 由档位枚举造一个 [QualityOption]。
  ///
  /// [url] 为 `null` 时表示「服务端有这个档位但我们没拿到地址」——
  /// `QualityOption.isAvailable` 会返回 `false`，UI 据此置灰而不是隐藏。
  static QualityOption toQualityOption({
    required int type,
    Uri? url,
    int? estimatedBytes,
  }) {
    return QualityOption(
      id: BaiduResolution.idFor(type),
      label: BaiduResolution.labelFor(type),
      detail: _qualityDetail(type),
      url: url,
      // 转码档**都不是原画**：百度把 `2K原画 / 4K原画` 也起了「原画」的名，
      // 但它们是转码流（客户端菜单里 `desc` 写的是「原画」指画质定位，
      // 不是「未经转码」）。真正的原画由 `/api/filemetas?dlink=1` 取回，
      // 那一档由适配器自己造（见 `BaiduAdapter.resolveStream`）。
      isOriginal: false,
      height: BaiduResolution.heightFor(type),
      estimatedBytes: estimatedBytes,
    );
  }

  static String? _qualityDetail(int type) {
    if (type == BaiduResolution.intelligentHd) {
      // 帧彩映画是 AI 增强而非固定分辨率，没有宽高可报。
      return '智能高清增强';
    }
    if (type > BaiduResolution.p480) return '超级会员专享';
    return null;
  }

  // ------------------------------------------------------------------
  // 时间与基础类型
  // ------------------------------------------------------------------

  /// 时长解析：百度的 `duration` **单位是秒**（与夸克一致），转毫秒。
  ///
  /// `0` 归一成 `null`：百度对没刮削出元数据的文件给 `0`，
  /// 显示 `00:00` 会让人以为文件是空的，`--:--` 才是诚实的「不知道」。
  static int? parseDurationMs(Object? value) {
    final seconds = _asInt(value);
    if (seconds == null || seconds <= 0) return null;
    return seconds * 1000;
  }

  /// 时间戳解析。百度的 `server_mtime` 是 **unix 秒**。
  ///
  /// 兼容秒 / 毫秒 / 字符串 / ISO8601 —— 与夸克那份同一个理由：
  /// 服务端返回类型不稳定，而判错单位的后果是「所有文件都是 1970 年」。
  static DateTime? parseTimestamp(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;

    if (value is num) {
      final n = value.toInt();
      if (n <= 0) return null;
      return _sane(DateTime.fromMillisecondsSinceEpoch(_toMs(n)));
    }

    if (value is String) {
      final n = int.tryParse(value);
      if (n != null) return parseTimestamp(n);
      return _sane(DateTime.tryParse(value));
    }
    return null;
  }

  /// 秒 / 毫秒自适应：13 位及以上按毫秒处理。
  static int _toMs(int n) => n > 99999999999 ? n : n * 1000;

  /// 正整数归一：`null` / `0` / 负数一律当「不知道」。
  static int? _positive(Object? v) {
    final n = _asInt(v);
    return (n == null || n <= 0) ? null : n;
  }

  /// 取嵌套对象（`data` 层）。
  static Map<String, Object?>? _nested(Map<String, Object?> json, String key) {
    final v = json[key];
    return v is Map<String, Object?> ? v : null;
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _asString(Object? v) {
    if (v is String) return v.isEmpty ? null : v;
    if (v == null) return null;
    return v.toString();
  }

  /// 时间合理性过滤：超出 2000–2100 视为脏数据。
  static DateTime? _sane(DateTime? dt) {
    if (dt == null) return null;
    if (dt.year < 2000 || dt.year > 2100) return null;
    return dt;
  }
}

/// 让映射器可以直接用在适配器里，避免重复 `DriveProvider.baidu`。
const DriveProvider baiduProvider = DriveProvider.baidu;

/// 原画档位的 id（与夸克共用同一个哨兵）。
///
/// 复用 `kOriginalQualityId` 而不是自造一个：`QualityLabels.isOriginal`
/// 与 `sortWeight` 都按它判定，自造会让原画排到转码档后面，
/// 默认播的就成了转码流 —— 表现是「默认画质变差了」，且不报任何错。
const String baiduOriginalQualityId = kOriginalQualityId;
