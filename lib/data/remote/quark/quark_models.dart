import '../../../core/utils/face_anchor.dart';
import '../../../domain/entities/cloud_account.dart';
import '../../../domain/entities/drive_entry.dart';
import '../../../domain/entities/drive_provider.dart';
import '../../../domain/entities/stream_ticket.dart';
import 'quark_endpoints.dart';

/// 夸克响应字段 → 领域模型的映射。
///
/// 全部是纯函数，字段名严格按 PoC 实测校准：
///
/// | 夸克字段 | 含义 | 易错点 |
/// |---|---|---|
/// | `fid` | 文件/目录 ID | 不是 `id` |
/// | `pdir_fid` | 父目录 ID | 不是 `parent_id` |
/// | `file_name` | 名称（含扩展名） | 不是 `name` |
/// | `dir` | **目录布尔位** | 必须以此为准 |
/// | `file_type` | `0`=目录 `1`=文件 | 早期误把 `1` 当目录，导致 BFS 队列爆炸 |
/// | `format_type` | MIME | 可作音频识别的辅助信号 |
/// | `updated_at` | 时间戳 | 秒 / 毫秒两种都可能 |
/// | `duration` | 音频时长 | **单位是秒**，且 `0` 表示「没刮削到」而非「空文件」 |
class QuarkMapper {
  const QuarkMapper._();

  /// 解析 `dir` 字段判定是否为目录。
  ///
  /// **以 `dir` 为准**，`file_type` 仅作兜底（PoC 血泪教训）。
  static bool parseIsDirectory(Map<String, Object?> json) {
    final d = json['dir'];
    if (d is bool) return d;
    if (d is num) return d != 0;
    if (d is String) {
      final lower = d.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    // 兜底：file_type 0 = 目录，1 = 文件
    final ft = _asInt(json['file_type']);
    if (ft != null) return ft == 0;
    // 最后兜底：有 pdir_fid 且无 size 的常见是目录，但这太脆弱，保守判为文件
    return false;
  }

  /// 单个列表项 → [DriveEntry]。缺关键字段时返回 `null`（跳过脏数据）。
  static DriveEntry? toEntry(Map<String, Object?> json) {
    final id = _asString(json['fid']) ?? _asString(json['id']);
    if (id == null || id.isEmpty) return null;

    final name = _asString(json['file_name']) ??
        _asString(json['name']) ??
        _asString(json['file_name_display']);
    if (name == null || name.isEmpty) return null;

    final isDir = parseIsDirectory(json);

    return DriveEntry(
      id: id,
      name: name,
      isDirectory: isDir,
      sizeBytes: isDir ? 0 : _asInt(json['size']),
      mimeType: _asString(json['format_type']),
      modifiedAt: parseTimestamp(json['updated_at'] ?? json['created_at']),
      parentId: _asString(json['pdir_fid']),
      durationMs: isDir ? null : parseDurationMs(json['duration']),
      // 缩略图：目录没有；文件里也只有**视频**才有。
      //
      // 2026-09-30 实测（真实账号、PC 网关）：列目录返回的视频项带三个地址，
      // 三档尺寸与体积如下 ——
      //
      // | 字段 | 端点 | 实测尺寸 | 实测体积 |
      // |---|---|---|---|
      // | `thumbnail` | `/file/video/thumbnail` | 178×100 | 1.9 KB |
      // | `big_thumbnail` | `/file/video/quick` | 533×300 | 7.9 KB |
      // | `preview_url` | `/file/video/preview` | 640×360 | 12.2 KB |
      //
      // 三档都是 WebP，**都必须带 Cookie**（裸链 `401 auth not found`，
      // 旧 `__puus` 为 `401 auth expired`）。
      //
      // 字段缺失时**不自己拼 URL**：`thumbnail` 只在服务端已经为该文件
      // 生成过预览图时才下发（实测视频搜索结果里 71/100 有），拼出来的
      // 地址对剩下 29% 只会拿到 404/401，白费一次请求还拖慢海报墙。
      thumbnailUrl: isDir ? null : _asString(json['thumbnail']),
      previewImageUrl: isDir ? null : _asString(json['preview_url']),
      // 实测分辨率（2026-10-01）：递归遍历 44 个目录、427 个视频的样本里，
      // `video_width` / `video_height` 覆盖率 **100%**，且没有 0 值。
      //
      // 它比文件名里的 `2160p` 可靠 —— 文件名会撒谎（发布组标错档）、
      // 会缺失（`[组名][片名][01][1080p]` 之外的命名），
      // 而这是服务端读文件头得到的。
      videoWidth: isDir ? null : _positive(json['video_width']),
      videoHeight: isDir ? null : _positive(json['video_height']),
      // 人脸框 → 竖版封面的裁切锚点。
      //
      // 2026-10-01 探针实测：覆盖率 **56/60（93%）**，每条 1~3 张脸。
      // 它是「把 16:9 视频帧裁成竖版」时唯一能锚住人物的依据 ——
      // 按画面正中裁会在双人对谈镜头里裁到两人之间的空隙。
      // 字段格式（`[x1,y1,x2,y2]` 百分比，不是 `[x,y,w,h]`）的判定依据
      // 写在 `FaceAnchor` 的文档注释里，**别改成直接相除百分比**。
      faceAnchorX: isDir ? null : FaceAnchor.parseX(json['cover_face_boundary']),
    );
  }

  /// 正整数归一：`null` / `0` / 负数一律当「不知道」。
  ///
  /// 「0 = 网盘还没刮削到」是这家的惯用约定（`duration` 同样如此），
  /// 所以分辨率也按同一口径处理 —— 把 `0` 传下去会让归挡算出一个
  /// 荒唐的档位。
  static int? _positive(Object? v) {
    final n = _asInt(v);
    return (n == null || n <= 0) ? null : n;
  }

  /// 批量映射，自动跳过脏数据。
  static List<DriveEntry> toEntries(Iterable<Map<String, Object?>> items) =>
      items.map(toEntry).whereType<DriveEntry>().toList();

  /// 时长解析：夸克的 `duration` **单位是秒**，转成毫秒给领域层。
  ///
  /// 实测（2026-09-24）一条 39.3MB 的 flac 返回 `"duration": 186`，
  /// 对应 3 分 06 秒 —— 确认是秒，不是毫秒也不是时长字符串。
  ///
  /// 三种情况都归一成 `null`（表示「不知道」）：
  ///   - 字段缺失（非音频文件本来就没有）；
  ///   - `0` —— 网盘还没刮削出元数据，显示 `00:00` 会让人以为文件是空的；
  ///   - 负数等脏数据。
  ///
  /// 返回 `null` 时列表显示 `--:--`，这是诚实的占位。
  static int? parseDurationMs(Object? value) {
    final seconds = _asInt(value);
    if (seconds == null || seconds <= 0) return null;
    return seconds * 1000;
  }

  /// 时间戳解析。兼容秒 / 毫秒 / 字符串 / ISO8601。
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

  /// 账号信息 → [CloudAccount] 的可选字段。
  ///
  /// 夸克 PC 自用接口 `/member` 返回的非敏感字段（PoC 已确认）：
  /// `member_type`、`use_capacity`、`total_capacity`、`nickname`。
  ///
  /// ## 容量为什么要多认两个名字
  ///
  /// 夸克同一份数据在**两套接口**上名字不同：
  ///
  /// | 接口 | 总容量 | 已用 |
  /// |---|---|---|
  /// | PC 自用 `/1/clouddrive/member`（本项目走的） | `total_capacity` | `use_capacity` |
  /// | 开放平台 `/open/v1/user/get_vip_info` | `capacity` | `used` |
  ///
  /// 两者不可混用（鉴权方式不同），但**字段名互为备选**没有代价：多认一个名字
  /// 只在服务端改口径时救一次场，认错了也只是拿不到值、退回不显示容量条。
  /// 只认一个名字的话，那天界面上会静静地少一行，没有任何报错。
  ///
  /// `member_info` 那层嵌套同理 —— `member_type` 已经出现过包在里面的时候，
  /// 容量跟着一起包进去是完全可能的。
  static CloudAccount mergeAccountInfo(
    CloudAccount base,
    Map<String, Object?> memberData,
  ) {
    final nickname = _asString(memberData['nickname']) ??
        _asString(memberData['nick_name']) ??
        _asString(memberData['user_name']);

    final memberInfo = memberData['member_info'];

    /// 先在顶层找，再在 `member_info` 里找。
    ///
    /// 不做 `cast` 视图 —— 那是个**惰性**转换，真去取一个非 String 键时会抛，
    /// 而这里的字段名全部来自服务端，抛了只能看到一个与容量毫无关系的异常。
    Object? pick(List<String> keys) {
      for (final k in keys) {
        final top = memberData[k];
        if (top != null) return top;
        if (memberInfo is Map) {
          final nested = memberInfo[k];
          if (nested != null) return nested;
        }
      }
      return null;
    }

    final memberType = _asString(pick(const ['member_type']));

    return base.copyWith(
      displayName: nickname,
      userId: _asString(memberData['user_id']) ??
          _asString(memberData['uid']) ??
          base.userId,
      storageUsedBytes: _asInt(pick(const ['use_capacity', 'used'])),
      storageTotalBytes: _asInt(pick(const ['total_capacity', 'capacity'])),
      memberLabel: memberType,
    );
  }

  /// 从取链响应里解析出播放直链。
  ///
  /// 两条路由的字段名不同，这里统一收口：
  ///   - `/1/clouddrive/file/download` → `data[0].download_url`
  ///   - `/1/clouddrive/file/audioplay` → `data.audio_url`
  ///
  /// 返回 `null` 表示响应里没有可用直链（调用方应据此报错）。
  static Uri? parseDirectUrl(Object? dataEntry) {
    if (dataEntry is! Map) return null;
    for (final key in const [
      'download_url',
      'downloadUrl',
      'audio_url',
      'audioUrl',
      'url',
      'dl_url',
    ]) {
      final v = dataEntry[key];
      if (v is String && v.isNotEmpty) {
        final uri = Uri.tryParse(v);
        if (uri != null && uri.hasScheme) return uri;
      }
    }
    return null;
  }

  /// 从直链的查询参数里解析签名过期时间。
  ///
  /// **首选 `auth_key`** —— 这是夸克实际使用的参数，两条路由实测格式一致：
  /// ```
  /// auth_key = <过期unix秒>-<第二段>-<TTL秒>-<签名>
  /// ```
  ///
  /// ⚠️ **只取第 1 段**。第 3 段的 TTL 随路由与文件变化（download 实测 6h；
  /// audioplay 实测 3h 与 5.11h 两种），拿它反推过期时刻会算错。
  /// 第 1 段才是服务端签发的真实过期时刻。
  ///
  /// 其余候选名是防御性兼容：参数命名可能随版本变化，
  /// 而「拿不到过期时间」会导致播放中途断流，代价比多几个候选高。
  /// 解析不出来时返回 `null`，由调用方套用兜底 TTL。
  static DateTime? parseUrlExpiry(Uri url) {
    // 1. 夸克专用：auth_key
    final authKey = url.queryParameters['auth_key'];
    if (authKey != null && authKey.isNotEmpty) {
      final head = authKey.split('-').first;
      final n = int.tryParse(head);
      if (n != null && n > 0) {
        final dt = _sane(DateTime.fromMillisecondsSinceEpoch(_toMs(n)));
        if (dt != null) return dt;
      }
    }

    // 2. 通用候选名
    const candidates = [
      'Expires', 'expires', 'expire', 'exp', 'e', 't', 'time', 'timestamp',
      'deadline', 'valid_until',
    ];
    for (final key in candidates) {
      final raw = url.queryParameters[key];
      if (raw == null || raw.isEmpty) continue;
      final n = int.tryParse(raw);
      if (n == null || n <= 0) continue;
      final dt = _sane(DateTime.fromMillisecondsSinceEpoch(_toMs(n)));
      if (dt != null) return dt;
    }
    return null;
  }

  /// 秒 / 毫秒自适应：13 位及以上按毫秒处理。
  static int _toMs(int n) => n > 99999999999 ? n : n * 1000;

  /// 组装 [StreamTicket]。
  ///
  /// 关键点：**必须带上 Cookie**。PoC 实测裸链返回 `412`，
  /// 带上 Cookie 才返回 `206 Partial Content`。
  static StreamTicket toStreamTicket({
    required Uri url,
    required String cookieHeader,
    int? contentLength,
    String? contentType,
    DateTime? now,
  }) {
    final fetchedAt = now ?? DateTime.now();
    final headers = <String, String>{
      'User-Agent': QuarkEndpoints.userAgent,
      'Accept': '*/*',
      'Referer': QuarkEndpoints.referer,
    };
    if (cookieHeader.isNotEmpty) {
      headers['Cookie'] = cookieHeader;
    }

    return StreamTicket(
      url: url,
      headers: headers,
      // 解析不到就套兜底 TTL，宁可提前刷新也不要中途断流
      expiresAt: parseUrlExpiry(url) ??
          fetchedAt.add(QuarkEndpoints.ticketFallbackTtl),
      contentLength: contentLength,
      contentType: contentType,
      supportsRange: true,
    );
  }

  // ------------------------------------------------------------------
  // 文件管理操作的响应解析
  // ------------------------------------------------------------------

  /// 从创建目录 / 上传完成等响应中提取文件/目录 ID。
  ///
  /// 夸克不同接口返回 fid 的字段名不统一：
  ///   - 创建目录：`data.fid`
  ///   - 上传完成：`data.fid`（秒传命中时也在 `data.fid`）
  ///   - 少数场景返回 `data.file_id`
  ///
  /// 返回 `null` 表示响应中找不到。
  static String? parseFid(Map<String, Object?>? data) {
    if (data == null) return null;
    for (final key in const ['fid', 'file_id', 'id']) {
      final v = data[key];
      if (v is String && v.isNotEmpty) return v;
      if (v is num) return v.toString();
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 基础类型转换（网盘返回值类型不稳定，一律宽容处理）
  // ------------------------------------------------------------------

  static int? _asInt(Object? v) => asInt(v);

  /// 公开的宽容整数转换。
  static int? asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static String? _asString(Object? v) {
    if (v is String) return v;
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

/// 让映射器可以直接用在适配器里，避免重复 `DriveProvider.quark`。
const DriveProvider quarkProvider = DriveProvider.quark;
