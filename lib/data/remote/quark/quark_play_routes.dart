/// 夸克**播放路由**与转码梯度的解析。
///
/// ## 背景：为什么需要多条路由
///
/// 参考项目（CloudTune）实测出的结论，直接决定本文件的设计：
///
/// | 路由 | 端点 | 体积限制 | 给的是什么 | 验证状态 |
/// |---|---|---|---|---|
/// | 下载 | `POST /file/download` | **~50 MiB**（`code=23018`） | 原文件 | 参考项目实测 |
/// | 音频播放 | `GET /file/audioplay?fid=` | **无** | 原文件 | 参考项目实测 |
/// | 视频播放 | `GET /file/v2/play?fid=` | 未知 | 未知 | **未验证** |
/// | 播放信息 | `POST /batch/file/play/info` | 未知 | 转码梯度 + 原画 | **未验证** |
///
/// 后两条是**从夸克 macOS 客户端逆向得到的端点**（`quark_video_paly`
/// 包内），参考项目的 PoC 脚本 `_diag_playroute.py` 打过它们，但结论没有
/// 落盘 —— 所以本应用**不能假设它们可用**。
///
/// ## 因此的策略
///
/// 取流走「**逐条降级**」，顺序按「信息量从多到少」排：
///   1. `play/info` —— 唯一能拿到**转码梯度**（清晰度切换）的路由；
///   2. `v2/play` —— 客户端播视频用的路由；
///   3. `audioplay` —— **已实测可用**，且不限体积，作为主力兜底；
///   4. `download` —— 已实测可用但有 50 MiB 限制，最后兜底。
///
/// 任何一条成功就停。全部失败才报错。这样「未验证的路由今天不通」只会
/// 让用户失去清晰度切换，**不会让视频播不了**。
///
/// ## 解析部分刻意做成纯函数
///
/// `play/info` 的真实响应形状没有落盘证据，所以解析器**不按固定字段名读**，
/// 而是递归遍历响应体，把「像播放地址的字段」都收集起来，再用同一层的
/// 分辨率字段命名。这样服务端换字段名时仍有较大概率继续可用，
/// 且可以用合成载荷做单测覆盖各种形状。
library;

import '../../../core/utils/redact.dart';
import '../../../domain/entities/quality_option.dart';

/// 夸克播放路由。
enum QuarkPlayRoute {
  /// `POST /1/clouddrive/batch/file/play/info` —— 播放信息预取。
  ///
  /// 客户端逆向出来的请求体带 `resolutions` 梯度声明，响应里应当包含
  /// 各档转码流的地址。**这是清晰度切换的唯一来源。**
  playInfo(
    id: 'play_info',
    label: '播放信息预取',
    path: '/1/clouddrive/batch/file/play/info',
    method: 'POST',
    bodyStyle: QuarkPlayBodyStyle.fids,
  ),

  /// `GET /1/clouddrive/file/v2/play?fid=` —— 视频播放。
  v2Play(
    id: 'v2_play',
    label: '视频播放',
    path: '/1/clouddrive/file/v2/play',
    method: 'GET',
    bodyStyle: QuarkPlayBodyStyle.query,
  ),

  /// `GET /1/clouddrive/file/audioplay?fid=` —— 音频播放。
  ///
  /// ⚠️ 名字叫 audio，但参考项目实测它**对任意 fid 都返回原文件直链**
  /// （连被服务端判成 `text/plain` 的 DSF 也照样返回原字节），
  /// 且不受 50 MiB 限制。所以它在本应用里是**主力兜底路由**。
  audioPlay(
    id: 'audio_play',
    label: '音频播放接口',
    path: '/1/clouddrive/file/audioplay',
    method: 'GET',
    bodyStyle: QuarkPlayBodyStyle.query,
  ),

  /// `POST /1/clouddrive/file/download` —— 下载直链（**有 50 MiB 限制**）。
  download(
    id: 'download',
    label: '下载直链',
    path: '/1/clouddrive/file/download',
    method: 'POST',
    bodyStyle: QuarkPlayBodyStyle.fids,
  );

  const QuarkPlayRoute({
    required this.id,
    required this.label,
    required this.path,
    required this.method,
    required this.bodyStyle,
  });

  final String id;
  final String label;
  final String path;

  /// `GET` 或 `POST`
  final String method;

  final QuarkPlayBodyStyle bodyStyle;

  bool get isPost => method == 'POST';
}

/// 请求参数形态。
///
/// 公开是因为它是 [QuarkPlayRoute] 的构造参数 —— 但**它只服务于适配器内部
/// 的路由分发**，上层业务代码不应该看它。真正的请求组装在
/// `QuarkAdapter._resolveVia*` 里。
enum QuarkPlayBodyStyle {
  /// `{fids: [id]}` 放在 body 里
  fids,

  /// `?fid=xxx` 放在 query 里
  query,
}

/// 夸克在请求体里声明的转码梯度。
///
/// 照抄客户端：`"normal,low,high,super,2k,4k"`。
/// **顺序有意义**（从低到高），但服务端返回什么、返回几档完全由它决定 ——
/// 本应用不假设任何一档一定存在。
const String kQuarkResolutionTiers = 'normal,low,high,super,2k,4k';

/// 转码梯度的**请求参数**（照抄客户端逆向结果）。
///
/// 全部带上是有意的：`fetch_play_video_resolution_setting` 与
/// `fetch_play_audio_type_setting` 决定响应里带不带分辨率/音轨设置，
/// 少了它们响应会变瘦，清晰度列表就是空的。
const Map<String, Object?> kQuarkPlayInfoBody = {
  'resolutions': kQuarkResolutionTiers,
  'fetch_credits_setting': 1,
  'fetch_play_video_resolution_setting': 1,
  'fetch_play_audio_type_setting': 1,
  'support_resolution_free_limit_ab': 1,
  'fetch_pdir': 1,
  'support_right': 'trial_1080P_zhizhen_pc',
  'supports': '',
};

/// `play/info` 响应的解析器。**全部是纯函数**，可用合成载荷单测。
class QuarkPlayInfoParser {
  const QuarkPlayInfoParser._();

  /// 可能是播放地址的字段名（大小写不敏感）。
  static const List<String> urlKeys = [
    'url',
    'play_url',
    'playurl',
    'video_url',
    'videourl',
    'audio_url',
    'audiourl',
    'download_url',
    'downloadurl',
    'file_url',
    'fileurl',
    'backup_url',
    'backupurl',
    'dl_url',
    'main_url',
  ];

  /// 可能是清晰度标识的字段名。
  static const List<String> resolutionKeys = [
    'resolution',
    'resolution_name',
    'resolution_label',
    'resolutionname',
    'quality',
    'definition',
    'res',
    'grade',
    'level',
  ];

  /// 可能是「是不是原画」的布尔字段名。
  static const List<String> originalKeys = [
    'is_original',
    'isoriginal',
    'original',
    'is_source',
    'issource',
    'is_raw',
  ];

  /// 可能是宽高的字段名。
  static const List<String> heightKeys = ['height', 'video_height', 'h'];
  static const List<String> widthKeys = ['width', 'video_width', 'w'];
  static const List<String> bitrateKeys = [
    'bitrate', 'video_bitrate', 'biterate', 'avg_bitrate', 'bit_rate',
  ];
  static const List<String> sizeKeys = ['size', 'file_size', 'filesize', 'bytes'];

  /// 从响应体里收集全部清晰度档位。
  ///
  /// 返回的列表**已去重、已排序**（原画最前，其余按清晰度降序），
  /// 并且**只保留有地址的档位** —— 服务端列了档位却没给地址时，
  /// 显示一个选了没反应的选项比不显示更糟。
  static List<QualityOption> parseQualities(Object? data) {
    final byId = <String, QualityOption>{};

    _walk(data, (map) {
      final url = _firstUrl(map);
      if (url == null) return;

      // 档位标识：先看显式字段，再看 URL 本身有没有分辨率线索，
      // 最后才是「原画」—— 因为原画档常常就是没有标识的那一个。
      final declared = _firstString(map, resolutionKeys);
      final fromUrl = _resolutionFromUrl(url);
      final bool declaredOriginal = _firstBool(map, originalKeys) ?? false;

      final id = declared ??
          fromUrl ??
          (declaredOriginal ? 'origin' : 'origin');

      final isOriginal = declaredOriginal ||
          QualityLabels.isOriginal(id) ||
          (declared == null && fromUrl == null);

      // 同一档位出现多次时保留第一个（服务端常给主地址 + 备份地址）
      if (byId.containsKey(id)) return;

      byId[id] = QualityOption(
        id: id,
        label: isOriginal ? '原画' : QualityLabels.labelFor(id),
        detail: _buildDetail(map),
        url: url,
        isOriginal: isOriginal,
        height: _firstInt(map, heightKeys) ?? _heightFromId(id),
        width: _firstInt(map, widthKeys),
        bitrate: _firstInt(map, bitrateKeys),
        estimatedBytes: _firstInt(map, sizeKeys),
      );
    });

    final list = byId.values.toList()
      ..sort((a, b) {
        final w = QualityLabels.sortWeight(a) - QualityLabels.sortWeight(b);
        if (w != 0) return w;
        return a.id.compareTo(b.id);
      });
    return list;
  }

  /// 从响应体里找「原画 / 默认播放地址」。
  ///
  /// 优先取被标为原画的档位；没有标记时取 [parseQualities] 的第一条。
  /// 都拿不到返回 `null`（调用方应换下一条路由）。
  static Uri? parseOriginalUrl(Object? data) {
    final qualities = parseQualities(data);
    for (final q in qualities) {
      if (q.isOriginal && q.url != null) return q.url;
    }
    if (qualities.isNotEmpty) return qualities.first.url;
    return null;
  }

  /// 从档位标识推高度（`1080p` → 1080）。
  static int? _heightFromId(String id) {
    final m = RegExp(r'(\d{3,4})').firstMatch(id);
    if (m != null) return int.tryParse(m.group(1)!);
    return switch (id.toLowerCase()) {
      '4k' => 2160,
      '2k' => 1440,
      'super' => 1080,
      'fhd' => 1080,
      'high' => 720,
      'hd' => 720,
      'normal' => 480,
      'sd' => 480,
      'low' => 360,
      _ => null,
    };
  }

  /// 从 URL 的路径/查询里嗅探分辨率线索（`.../1080p/...`、`..._720p.mp4`）。
  static String? _resolutionFromUrl(Uri url) {
    final hay = '${url.path}?${url.query}'.toLowerCase();
    final m = RegExp(r'(?<![0-9])(\d{3,4})[pi](?![0-9])').firstMatch(hay);
    if (m != null) return '${m.group(1)}p';
    final k = RegExp(r'(?<![0-9a-z])([248])k(?![0-9a-z])').firstMatch(hay);
    if (k != null) return '${k.group(1)}k';
    return null;
  }

  static String? _buildDetail(Map<String, Object?> map) {
    final parts = <String>[];
    final w = _firstInt(map, widthKeys);
    final h = _firstInt(map, heightKeys);
    if (w != null && h != null) parts.add('$w×$h');
    final br = _firstInt(map, bitrateKeys);
    if (br != null && br > 0) {
      parts.add('${(br / 1000000).toStringAsFixed(1)} Mbps');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 递归遍历 JSON，对每个「对象」调用 [visit]。
  ///
  /// 用 `Object?` 而不是 `Map<String, dynamic>` 是有意的：夸克响应里
  /// 嵌套值类型不稳定（数字可能是字符串、列表可能是对象），
  /// 强类型转换会在服务端改形状时抛异常。
  static void _walk(Object? node, void Function(Map<String, Object?> map) visit) {
    if (node is Map) {
      final map = <String, Object?>{};
      node.forEach((k, v) => map['$k'] = v);
      visit(map);
      for (final v in map.values) {
        _walk(v, visit);
      }
    } else if (node is List) {
      for (final v in node) {
        _walk(v, visit);
      }
    }
  }

  /// 找一个像播放地址的字段。
  static Uri? _firstUrl(Map<String, Object?> map) {
    for (final key in urlKeys) {
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() != key) continue;
        final v = entry.value;
        if (v is! String || v.isEmpty) continue;
        final uri = Uri.tryParse(v);
        if (uri != null && uri.hasScheme && uri.host.isNotEmpty) return uri;
      }
    }
    return null;
  }

  static String? _firstString(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() != key) continue;
        final v = entry.value;
        if (v is String && v.trim().isNotEmpty) return v.trim();
        if (v is num) return '$v';
      }
    }
    return null;
  }

  static int? _firstInt(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() != key) continue;
        final v = entry.value;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) {
          final n = int.tryParse(v);
          if (n != null) return n;
        }
      }
    }
    return null;
  }

  static bool? _firstBool(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() != key) continue;
        final v = entry.value;
        if (v is bool) return v;
        if (v is num) return v != 0;
        if (v is String) {
          final lower = v.toLowerCase();
          if (lower == 'true' || lower == '1') return true;
          if (lower == 'false' || lower == '0') return false;
        }
      }
    }
    return null;
  }
}

/// 把档位列表写进诊断日志（**不含地址**）。
///
/// 地址里有 `auth_key` 签名，绝不能落盘。这里只记「有哪些档位、各多高」，
/// 排查「清晰度列表是空的」时看这一行就够。
String describeQualities(List<QualityOption> qualities) {
  if (qualities.isEmpty) return '无档位（只有原画流）';
  return qualities
      .map((q) => '${q.id}${q.height == null ? "" : "(${q.height}p)"}')
      .join(', ');
}

/// 脱敏的地址描述（复用核心工具，保持与日志口径一致）。
String describeUrl(Uri url) => redactUrl(url.toString());
