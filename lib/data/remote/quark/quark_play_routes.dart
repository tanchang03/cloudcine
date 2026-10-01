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
/// ## 2026-10-01 实测：`play/info` 里**没有原画**
///
/// 之前这条路由的响应形状没有落盘证据，所以解析器做成「形状无关」——
/// 递归遍历、把像播放地址的字段都收出来。这个设计本身没问题，
/// 但它把**音轨**也收了进来，于是踩了一个很贵的坑：
///
/// ```
/// data.<fid>.video_list = [ {resolution: super, video_info:{url, 1440x600}},
///                           {resolution: high,  video_info:{url,  960x400}},
///                           {resolution: low,   video_info:{url,  480x200}} ]
/// data.<fid>.audio_list = [ {type: dolby_eac3, audio_info:{url}} ]   ← 纯音频流
/// data.<fid>.meta       = {format: "matroska,webm", 1920x800, h264, bitrate 7758}
/// ```
///
/// `audio_info.url` 没有分辨率字段、URL 里也没有 `1080p` 这类线索，
/// 于是被 `isOriginal = (declared == null && fromUrl == null)` 判定成**「原画」**，
/// 又因为原画永远排最前，它成了默认要播的那一条。
///
/// **症状：原画「没有画面」** —— 那条流里根本没有视频轨，mpv 照常推进时间轴、
/// 有声音、进度条在走，就是不出画，而且**不报任何错**。
///
/// 所以现在 `parseQualities` **跳过 `audio_list` / `audio_info` 子树**：
/// 视频档位只可能来自 `video_list`。真正的原文件由 `/file/audioplay`
/// 单独取（见 `QuarkAdapter.resolveStream`）。
///
/// ## 解析部分刻意做成纯函数
///
/// 解析器**不按固定字段名读**，而是递归遍历响应体，把「像播放地址的字段」都
/// 收集起来，再用同一层的分辨率字段命名。这样服务端换字段名时仍有较大概率
/// 继续可用，且可以用合成载荷做单测覆盖各种形状。
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

  /// `POST /1/clouddrive/file/v2/play` —— 视频播放（单文件形态）。
  ///
  /// ⚠️ **必须 POST + `{"fid": …}`**。2026-10-01 实测三种形态：
  ///
  /// | 请求 | 结果 |
  /// |---|---|
  /// | `GET ?fid=` | `405 Request method 'GET' not supported` |
  /// | `POST {"fids":[fid]}` | `400 code=14001 Bad Parameter: [fid is empty!]` |
  /// | `POST {"fid":fid}` | `200 code=0`，结构与 `play/info` 完全一致 |
  ///
  /// 也就是说这条路以前**从来没通过**（写的是 GET），而它排在降级链第 2 位
  /// —— 第 1 条一旦出问题，它接不住，直接掉到第 3 条。
  v2Play(
    id: 'v2_play',
    label: '视频播放',
    path: '/1/clouddrive/file/v2/play',
    method: 'POST',
    bodyStyle: QuarkPlayBodyStyle.fid,
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

  /// `{fid: id}` 放在 body 里（单文件接口，如 `v2/play`）
  fid,

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

  /// 只可能装**音轨**的键名（小写）。遍历时整棵子树跳过。
  ///
  /// ⚠️ 这个名单是「原画播出来没画面」那个事故的直接解药，别删也别放宽。
  /// 机理见本文件的 library 文档：`audio_list[].audio_info.url` 是一条
  /// **纯音频流**，它没有分辨率字段，于是会被当成「原画」——
  /// 而原画永远排最前，就成了默认要播的那一条。
  ///
  /// 用「按子树跳过」而不是「按字段名过滤 url」：音频条目里的地址字段名
  /// 与视频完全一样（都叫 `url`），只按字段名过滤分不出来。
  static const Set<String> audioOnlyKeys = {
    'audio_list',
    'audio_info',
    'audio_stream_list',
  };

  /// 从响应体里收集全部清晰度档位。
  ///
  /// 返回的列表**已去重、已排序**（原画最前，其余按清晰度降序），
  /// 并且**只保留有地址的档位** —— 服务端列了档位却没给地址时，
  /// 显示一个选了没反应的选项比不显示更糟。
  ///
  /// 返回的档位**只来自视频轨**（见 [audioOnlyKeys]）。真正的原文件不在
  /// 这里 —— `play/info` 的 `video_list` 只有转码梯度，原画要另走
  /// `/file/audioplay`。
  static List<QualityOption> parseQualities(Object? data) {
    final byId = <String, QualityOption>{};

    _walk(data, (map, inherited) {
      final url = _firstUrl(map);
      if (url == null) return;

      // 档位标识：本层显式字段优先，其次祖先带下来的，最后才看 URL 里的线索。
      // [inherited] 已经是「本层或祖先」的合并结果（见 _walkNode）。
      final declared = inherited.resolution;
      final fromUrl = _resolutionFromUrl(url);
      final bool declaredOriginal = inherited.original;

      // ⚠️ **既没有标识、URL 里也没有线索，且没被显式标为原画 → 不是一档清晰度。**
      //
      // 这里以前写的是「都没有就当原画」，而那个兜底正是「原画没有画面」事故的
      // 成因：`audio_list[].audio_info.url` 没有任何分辨率信息，于是被提升成
      // 「原画」——而原画永远排最前，于是默认播的就是那条**纯音频流**：
      // 有声音、进度条在走、没有画面，**不报任何错**。
      //
      // 即使有了 audioOnlyKeys 那层过滤，这条规则也必须留着：任何**没有
      // 分辨率信息**的地址都不该被提升成「原画」。原画现在只有一个来源 ——
      // `/file/audioplay` 取回的原文件（见 `QuarkAdapter.resolveStream`）。
      //
      // 服务端真给原画档时它会带标识（`origin` / `source` / `is_original`），
      // 那两种情况分别由 `QualityLabels.isOriginal` 与 `declaredOriginal` 接住。
      if (declared == null && fromUrl == null && !declaredOriginal) return;

      final id = declared ?? fromUrl ?? kOriginalQualityId;
      final isOriginal = declaredOriginal || QualityLabels.isOriginal(id);

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
        bitrate: _bitrateBps(_firstInt(map, bitrateKeys)),
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

  /// 从响应体里找「默认播放地址」。
  ///
  /// 优先取被标为原画的档位；没有标记时取 [parseQualities] 的第一条。
  /// 都拿不到返回 `null`（调用方应换下一条路由）。
  ///
  /// ⚠️ 在真实的 `play/info` 响应上它**几乎总是返回最高那一档转码流**，
  /// 不是原画 —— 因为 `video_list` 里根本没有原画（见 library 文档）。
  /// 要原文件请用 `/file/audioplay`，别用这个。
  static Uri? parseOriginalUrl(Object? data) {
    final qualities = parseQualities(data);
    for (final q in qualities) {
      if (q.isOriginal && q.url != null) return q.url;
    }
    if (qualities.isNotEmpty) return qualities.first.url;
    return null;
  }

  /// 源文件（原画）的元信息，用来给「原画」那一档写副标题。
  ///
  /// ## 为什么单独读 `meta` 而不是复用 [parseQualities]
  ///
  /// `meta` 描述的是**原始文件**（`format: "matroska,webm"`、真实宽高、
  /// 总码率），而 `video_list[*].video_info` 描述的是**转码产物**。
  /// 两者的字段名高度重合（都有 `width` / `height` / `bitrate` / `codec`），
  /// 所以不能靠「找第一个有宽高的对象」区分 —— 只能按键名 `meta` 取。
  ///
  /// 实测样本（指环王 S01E01，3.8 GB）：
  /// `{"duration":3947,"size":3828008839,"format":"matroska,webm",
  ///   "width":1920,"height":800,"bitrate":7758.0,"codec":"h264","fps":24.0,
  ///   "pix_fmt":"yuv420p"}`
  ///
  /// 取不到就返回 `null` —— 原画那一档只是少一行副标题，不影响播放。
  static SourceMeta? parseSourceMeta(Object? data) {
    Map<String, Object?>? meta;
    _walk(data, (map, _) {
      if (meta != null) return;
      for (final entry in map.entries) {
        if (entry.key.toLowerCase() != 'meta') continue;
        final v = entry.value;
        if (v is! Map) continue;
        final m = <String, Object?>{};
        v.forEach((k, val) => m['$k'] = val);
        meta = m;
        return;
      }
    });

    final m = meta;
    if (m == null) return null;

    final width = _firstInt(m, widthKeys);
    final height = _firstInt(m, heightKeys);
    final bitrate = _bitrateBps(_firstInt(m, bitrateKeys));
    final size = _firstInt(m, sizeKeys);
    final format = _firstString(m, const ['format', 'format_name']);
    final codec = _firstString(m, const ['codec', 'video_codec']);

    if (width == null &&
        height == null &&
        bitrate == null &&
        size == null &&
        format == null &&
        codec == null) {
      return null;
    }

    return SourceMeta(
      width: width,
      height: height,
      bitrate: bitrate,
      sizeBytes: size,
      format: format,
      codec: codec,
    );
  }

  /// 把源文件元信息拼成一行副标题（`1920×800 · 7.6 Mbps · MKV`）。
  ///
  /// 与 [QualityOption.displayDetail] 的口径保持一致（宽×高 · 码率），
  /// 只多一个容器后缀 —— 「原画」那一档最值得告诉用户的就是「这是什么容器、
  /// 有多大」，因为它就是原文件本身。
  static String describeSourceMeta(SourceMeta meta) {
    final parts = <String>[];
    if (meta.width != null && meta.height != null) {
      parts.add('${meta.width}×${meta.height}');
    }
    if (meta.bitrate != null && meta.bitrate! > 0) {
      parts.add('${(meta.bitrate! / 1000000).toStringAsFixed(1)} Mbps');
    }
    final container = _containerLabel(meta.format);
    if (container != null) parts.add(container);
    return parts.join(' · ');
  }

  /// `matroska,webm` → `MKV`。认不出来返回 `null`（不猜）。
  static String? _containerLabel(String? format) {
    if (format == null) return null;
    final f = format.toLowerCase();
    if (f.contains('matroska') || f.contains('webm')) return 'MKV';
    if (f.contains('mp4') || f.contains('mov')) return 'MP4';
    if (f.contains('mpegts') || f.contains('mpeg-ts')) return 'TS';
    if (f.contains('avi')) return 'AVI';
    if (f.contains('flv')) return 'FLV';
    if (f.contains('asf')) return 'WMV';
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

  /// 把服务端的码率字段归一成 **bps**。
  ///
  /// ## 为什么需要归一
  ///
  /// 2026-10-01 实测：夸克 `play/info` 的 `bitrate` 是 **kbps**，不是 bps。
  /// 两个独立样本互相印证：
  ///
  /// | 样本 | 响应里的 bitrate | 用「体积 ÷ 时长」算出来 |
  /// |---|---|---|
  /// | super 转码档（749 MB / 3947 s） | `1518.0` | 1 518 000 bps = **1518 kbps** |
  /// | 源文件 meta（3.83 GB / 3947 s） | `7758.0` | 7 758 000 bps = **7758 kbps** |
  ///
  /// 不归一的话，`QualityOption.displayDetail` 那个 `/ 1000000` 会把
  /// 1518 算成 **`0.0 Mbps`** —— 画质菜单里每一档的副标题都是「0.0 Mbps」，
  /// 而且**不报任何错**，看着像服务端没给码率。
  ///
  /// ## 判据为什么是 100000
  ///
  /// 「kbps 还是 bps」只能靠数量级区分，而两档之间隔得很开：
  /// 视频码率最小也有几百 kbps，即 bps 表示下至少 100000；
  /// 而 100 Mbps 的视频在 kbps 表示下才 100000。
  /// 所以 `100000` 是一条两边都不会误伤的分界线 ——
  /// 它同时容纳「100 Mbps 的 kbps 值」与「100 kbps 的 bps 值」这两个极端。
  static int? _bitrateBps(int? raw) {
    if (raw == null || raw <= 0) return raw;
    return raw < 100000 ? raw * 1000 : raw;
  }

  static String? _buildDetail(Map<String, Object?> map) {
    final parts = <String>[];
    final w = _firstInt(map, widthKeys);
    final h = _firstInt(map, heightKeys);
    if (w != null && h != null) parts.add('$w×$h');
    final br = _bitrateBps(_firstInt(map, bitrateKeys));
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
  ///
  /// **键名进入判定**：走到 [audioOnlyKeys] 里的键时整棵子树跳过。
  /// 这是「音轨被当成原画」那个事故的解药 —— 详见本文件的 library 文档。
  /// 只按字段名过滤是分不出来的，因为音频条目里的地址字段也叫 `url`。
  ///
  /// **祖先的标识会传下去**（见 [_Inherited]）：真实响应里 `resolution`
  /// 同时出现在条目本身和它的 `video_info` 里，但那是「恰好如此」不是契约。
  static void _walk(
    Object? node,
    void Function(Map<String, Object?> map, _Inherited inherited) visit,
  ) {
    _walkNode(node, visit, const _Inherited());
  }

  static void _walkNode(
    Object? node,
    void Function(Map<String, Object?> map, _Inherited inherited) visit,
    _Inherited inherited,
  ) {
    if (node is Map) {
      final map = <String, Object?>{};
      node.forEach((k, v) => map['$k'] = v);

      // 本层自己声明的标识优先，否则沿用祖先的。
      final ownResolution = _firstString(map, resolutionKeys);
      final ownOriginal = _firstBool(map, originalKeys) ?? false;
      final effective = _Inherited(
        resolution: ownResolution ?? inherited.resolution,
        original: ownOriginal || inherited.original,
      );

      visit(map, effective);

      for (final entry in map.entries) {
        if (audioOnlyKeys.contains(entry.key.toLowerCase())) continue;
        _walkNode(entry.value, visit, effective);
      }
    } else if (node is List) {
      // 列表的每一项拿到的都是**父层**的上下文 —— 不能把前一项的标识
      // 传染给后一项（同一层里各档位本来就是并列的）。
      for (final v in node) {
        _walkNode(v, visit, inherited);
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

/// 遍历响应体时从**祖先**带下来的上下文。
///
/// ## 为什么需要它
///
/// 真实响应里 `resolution` 同时出现在条目本身与它的 `video_info` 里：
///
/// ```json
/// { "resolution": "super",
///   "video_info": { "url": "…", "resolution": "super" } }
/// ```
///
/// 但「两处都有」是**恰好如此，不是契约**。只要服务端哪天把外层那份省掉
/// （或者把地址挪到更深一层），只认「地址所在那一层有没有标识」的解析器就会
/// 认不出这一档 —— 而认不出的后果是**静默丢档**：画质菜单里少一项，
/// 不报错、日志干净。
///
/// 所以把祖先的标识一路带下去，两种布局都成立。
/// 反过来（列表里前一项的标识传染给后一项）是错的，见 [_walkNode] 里
/// 对 `List` 的处理。
class _Inherited {
  const _Inherited({this.resolution, this.original = false});

  /// 本层或任一祖先声明的档位标识
  final String? resolution;

  /// 本层或任一祖先声明过「这是原画」
  final bool original;
}

/// 源文件（原画）的元信息。
///
/// 全部字段都可空 —— 它只用来给「原画」那一档写一行副标题，
/// 缺哪个就少写哪一段，**不影响播放**（原画的地址来自 `/file/audioplay`，
/// 与这里能不能解析出元信息无关）。
class SourceMeta {
  const SourceMeta({
    this.width,
    this.height,
    this.bitrate,
    this.sizeBytes,
    this.format,
    this.codec,
  });

  final int? width;
  final int? height;

  /// 总码率（bps）
  final int? bitrate;

  /// 文件字节数。它同时是**比索引库里那条记录更权威的体积** ——
  /// 索引库的值来自扫描时的目录列表，而这里是服务端读文件头得到的。
  final int? sizeBytes;

  /// 容器名（`matroska,webm` / `mov,mp4,m4a,3gp,3g2,mj2`）
  final String? format;

  final String? codec;

  @override
  String toString() => 'SourceMeta(${width}x$height, $codec, $format, '
      'bitrate=$bitrate, size=$sizeBytes)';
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
