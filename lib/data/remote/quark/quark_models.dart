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
    );
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
  /// 夸克 `/member` 返回的非敏感字段（PoC 已确认）：
  /// `member_type`、`use_capacity`、`total_capacity`、`nickname`。
  static CloudAccount mergeAccountInfo(
    CloudAccount base,
    Map<String, Object?> memberData,
  ) {
    final nickname = _asString(memberData['nickname']) ??
        _asString(memberData['nick_name']) ??
        _asString(memberData['user_name']);

    final memberInfo = memberData['member_info'];
    var memberType = _asString(memberData['member_type']);
    if (memberType == null && memberInfo is Map) {
      memberType = _asString(memberInfo['member_type']);
    }

    return base.copyWith(
      displayName: nickname,
      userId: _asString(memberData['user_id']) ??
          _asString(memberData['uid']) ??
          base.userId,
      storageUsedBytes: _asInt(memberData['use_capacity']),
      storageTotalBytes: _asInt(memberData['total_capacity']),
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
  // 基础类型转换（网盘返回值类型不稳定，一律宽容处理）
  // ------------------------------------------------------------------

  static int? _asInt(Object? v) {
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
