import '../../core/utils/filename_parser.dart';
import '../../core/utils/video_formats.dart';
import 'drive_entry.dart';
import 'drive_provider.dart';

/// 媒体库里的一条**文件级**记录（一个可播放的视频文件）。
///
/// 与 [MediaWork] 的分工：
///   - `MediaItem` = 「网盘上的这个文件」（有 fid、有体积、有路径）
///   - `MediaWork` = 「这是一部什么作品」（有海报、有简介、有一堆集）
///
/// 一部剧 = 一个 work + N 个 item。电影通常是 1:1，但同一个电影可能有
/// 多个版本（1080p / 2160p），那也是 1 个 work + N 个 item。
class MediaItem {
  const MediaItem({
    required this.provider,
    required this.fileId,
    required this.name,
    required this.dirId,
    required this.dirPath,
    required this.groupKey,
    required this.kind,
    this.title,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
    this.part,
    this.partLabel,
    this.container = VideoContainer.other,
    this.resolution,
    this.videoWidth,
    this.videoHeight,
    this.sizeBytes,
    this.modifiedAt,
    this.durationMs,
    this.source,
    this.videoCodec,
    this.audioCodec,
    this.flags = const {},
    this.releaseGroup,
    this.isSampleOrExtra = false,
    this.thumbUrl,
    this.faceAnchorX,
    this.lastPlayedAt,
    required this.firstSeenAt,
    required this.updatedAt,
  });

  final DriveProvider provider;

  /// 网盘侧文件 ID（夸克是 `fid`）
  final String fileId;

  /// 文件名（含扩展名）
  final String name;

  /// 父目录 ID
  final String dirId;

  /// 展示用目录路径，形如 `/电影/流浪地球2 (2023)/`
  final String dirPath;

  /// 归组键（见 `ParsedMediaName.groupKey`）
  final String groupKey;

  final MediaKind kind;

  /// 本地解析出的片名（刮削成功前就是展示名）
  final String? title;
  final int? year;
  final int? season;
  final int? episode;
  final int? episodeEnd;

  /// 部号（`第X部` / `上部`·`下部` / `Part.2` / `CD1`）。
  ///
  /// ## 与 [season] 是两个维度
  ///
  /// 季是**外层**（《进击的巨人》第三季），部是**内层**（Part.1 / Part.2）；
  /// 而电影没有季，只有部（《流浪地球》上下部）。两者不能合并成一个字段 ——
  /// 混在一起会让 `S03 Part.2` 排成「第三季的第 2 集」那种错位。
  final int? part;

  /// 部的展示名（`特别篇` / `上部` / `下部`）。
  ///
  /// 非空时展示**优先用它**：用户认的是「特别篇」这三个字，不是「第 9999 部」。
  final String? partLabel;

  final VideoContainer container;

  /// 该条目**已知最好**的分辨率档位。
  ///
  /// 来源有两级，**实测优先**：
  ///   1. 网盘给的 [videoWidth] / [videoHeight]（走
  ///      `VideoFormats.resolutionFromDimensions`，按长边归挡）；
  ///   2. 退化到从文件名推断（`VideoFormats.resolutionFromName`）。
  ///
  /// ## 为什么不拆成「实测档位」和「文件名档位」两个字段
  ///
  /// UI 上只该显示一个「这片子多清晰」。实测存在时，文件名那点信息没有
  /// 额外价值（它只会更不可靠）；而需要判断「这个值是不是实测的」时，
  /// 看 [videoWidth] / [videoHeight] 是否为 `null` 就够了。
  final VideoResolution? resolution;

  /// 网盘给出的**实测**视频宽度（像素）。夸克：`video_width`。
  ///
  /// 2026-10-01 实测：递归遍历 44 个目录、427 个视频，覆盖率 **100%**。
  /// 比文件名里的 `2160p` 可靠 —— 那是发布组自己标的。
  final int? videoWidth;

  /// 网盘给出的**实测**视频高度（像素）。夸克：`video_height`。
  ///
  /// ⚠️ 别拿它单独归挡分辨率：实测样本里宽银幕裁切占 40%
  /// （`3840x1632`、`1920x804`…），只看高度会整体低估一档。
  final int? videoHeight;

  final int? sizeBytes;
  final DateTime? modifiedAt;

  /// 网盘声明的时长（毫秒）。夸克对视频会给 `duration`，单位秒。
  final int? durationMs;

  final String? source;
  final String? videoCodec;
  final String? audioCodec;
  final Set<String> flags;
  final String? releaseGroup;

  /// 花絮/样片。**仍然入库**，只是默认从「正片」列表里过滤掉 ——
  /// 直接丢弃会让用户找不到它们，而它们确实在网盘上。
  final bool isSampleOrExtra;

  /// 网盘**服务端生成**的视频缩略图地址。
  ///
  /// 夸克实测（2026-09-30）：列目录返回的每个视频项自带
  /// `thumbnail` / `big_thumbnail` / `preview_url` 三个字段，
  /// 形如 `https://drive-pc.quark.cn/1/clouddrive/file/video/thumbnail?fid=<fid>`，
  /// 返回 WebP（178×100 / 533×300 / 640×360）。
  ///
  /// ## 为什么这条字段很关键
  ///
  /// 没有它，未刮削的媒体库就是一墙「片名首字」的灰块。有了它，
  /// **即使一个刮削器都没配**（断网、没 TMDB Key），媒体库也有真实画面。
  /// 这与「本地解析永远可用，在线刮削是增强」是同一条设计原则。
  ///
  /// ⚠️ 取这个地址**必须带 Cookie**，而且必须是**最新的** `__puus` ——
  /// 与播放直链同一条规则（实测：旧 `__puus` 返回 `401 auth expired`）。
  /// 所以这里只存地址，下载交给 `PosterCache` + 适配器提供的请求头。
  final String? thumbUrl;

  /// 这张缩略图里**人物所在的水平位置**（归一化 0~1），来自夸克的人脸框。
  ///
  /// 2026-10-01 探针实测覆盖率 **56/60（93%）**。
  ///
  /// 它和 [thumbUrl] 是**一对**：只有把 16:9 的帧裁成竖版封面时才有意义，
  /// 所以「谁提供缩略图，就由谁提供锚点」。换封面来源（比如刮到了 TMDB
  /// 的 2:3 海报）时必须一起换掉 —— 拿视频帧的锚点去裁海报是错的。
  ///
  /// 没有可用人脸框时为 `null`，渲染时退回画面正中。
  final double? faceAnchorX;

  /// 最近播放时刻。`null` 表示没播过。
  ///
  /// 它决定「点开一部剧该播哪一集」（见 `PlayTarget`）。与
  /// [resumePositionMs] 的分工：这一列是「什么时候看的」，
  /// 那一列是「看到哪儿了」—— 看完的一集前者还在、后者被清掉。
  final DateTime? lastPlayedAt;

  final DateTime firstSeenAt;
  final DateTime updatedAt;

  /// 网盘上的**完整路径**：`/电影/流浪地球2 (2023)/流浪地球2.2023.2160p.mkv`
  ///
  /// 展示路径在扫描时保证以 `/` 结尾（见 `ScanService._joinPath`），但这是
  /// 扫描器的实现细节，不该让每个调用方都去假设它 —— 少了这个拼接，
  /// 详情页上「复制网盘路径」会得到 `/目录/文件名` 少一个斜杠的畸形结果，
  /// 粘进夸克搜索框里搜不到。
  String get netdiskPath {
    final dir = dirPath.isEmpty ? '/' : dirPath;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  /// 稳定主键。`provider` 前缀是必须的：接第二家网盘后，不同网盘的
  /// `fid` 完全可能撞车。
  String get id => idFor(provider, fileId);

  /// 主键的构造规则。**单独暴露出来**是给「还没入库的网盘条目」用的：
  /// 目录视图要判断「网盘上的这个文件是不是已经在库里了」，而它手上只有
  /// 一个 `DriveEntry`，没有 `MediaItem`。让调用方自己拼
  /// `'${provider.id}:${entry.id}'` 就等于把主键格式抄了第二份 ——
  /// 哪天格式变了，那处比对会**静默地**永远不命中（表现为「已入库」标记
  /// 全部消失，而扫描、播放都正常）。
  static String idFor(DriveProvider provider, String fileId) =>
      '${provider.id}:$fileId';

  /// 展示名：片名 + 集号/年份，没有片名时退回文件名。
  String get displayTitle {
    final t = title;
    if (t == null || t.isEmpty) {
      final dot = name.lastIndexOf('.');
      return dot > 0 ? name.substring(0, dot) : name;
    }
    final e = episode;
    if (e != null) {
      final s = season;
      final prefix = s == null ? '' : 'S${s.toString().padLeft(2, '0')}';
      final end = episodeEnd;
      final range = (end != null && end != e)
          ? 'E${e.toString().padLeft(2, '0')}-E${end.toString().padLeft(2, '0')}'
          : 'E${e.toString().padLeft(2, '0')}';
      return '$t $prefix$range';
    }
    final y = year;
    return y == null ? t : '$t ($y)';
  }

  /// 列表副标题：`2160P · MKV · H.265 · HDR · 12.3 GB`
  String get technicalSummary {
    final parts = <String>[
      if (resolution != null) resolution!.marketingLabel,
      if (container != VideoContainer.other) container.label,
      if (videoCodec != null) videoCodec!,
      if (audioCodec != null) audioCodec!,
      ...flags.take(2),
      if (sizeBytes != null && sizeBytes! > 0) formatBytes(sizeBytes!),
    ];
    return parts.join(' · ');
  }

  /// 没有编号的部（`特别篇` / `剧场版`）的排序号 —— 排在所有编号部之后。
  ///
  /// 取一个大到不可能被真实部号撞上的值：真实部号是「第几部」，两位数都罕见。
  static const int specialPartOrder = 9999;

  /// 部的**排序号**。
  ///
  ///   - 有编号的部（`第2部` / `Part.2`）→ 用编号；
  ///   - `特别篇` 这类没有编号的 → [specialPartOrder]，排在所有编号部**之后**；
  ///   - 没标部的 → 0，排在最前（与 [season] 用 `?? 0` 的口径一致）。
  ///
  /// 抽成 getter 是为了让「特别篇排最后」这条规则**只有一份实现** ——
  /// 列表排序、层级选择器、`PlayTarget` 三处都读它。散成三份的话，
  /// 三处对「特别篇算第几部」的理解迟早分叉。
  int get partOrder {
    if (part != null) return part!;
    if (partLabel != null && partLabel!.isNotEmpty) return specialPartOrder;
    return 0;
  }

  /// 部的展示文本；没标部时返回 `null`（调用方据此不画这一层）。
  String? get partText {
    final l = partLabel;
    if (l != null && l.isNotEmpty) return l;
    if (part != null) return '第 $part 部';
    return null;
  }

  MediaItem copyWith({
    String? dirPath,
    String? title,
    int? year,
    int? season,
    int? episode,
    int? episodeEnd,
    int? part,
    String? partLabel,
    VideoResolution? resolution,
    int? videoWidth,
    int? videoHeight,
    int? durationMs,
    bool? isSampleOrExtra,
    String? thumbUrl,
    double? faceAnchorX,
    DateTime? lastPlayedAt,
    DateTime? updatedAt,
  }) =>
      MediaItem(
        provider: provider,
        fileId: fileId,
        name: name,
        dirId: dirId,
        dirPath: dirPath ?? this.dirPath,
        groupKey: groupKey,
        kind: kind,
        title: title ?? this.title,
        year: year ?? this.year,
        season: season ?? this.season,
        episode: episode ?? this.episode,
        episodeEnd: episodeEnd ?? this.episodeEnd,
        part: part ?? this.part,
        partLabel: partLabel ?? this.partLabel,
        container: container,
        resolution: resolution ?? this.resolution,
        videoWidth: videoWidth ?? this.videoWidth,
        videoHeight: videoHeight ?? this.videoHeight,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        durationMs: durationMs ?? this.durationMs,
        source: source,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        flags: flags,
        releaseGroup: releaseGroup,
        isSampleOrExtra: isSampleOrExtra ?? this.isSampleOrExtra,
        thumbUrl: thumbUrl ?? this.thumbUrl,
        faceAnchorX: faceAnchorX ?? this.faceAnchorX,
        lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
        firstSeenAt: firstSeenAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 从「网盘条目 + 文件名解析结果」构造。
  factory MediaItem.fromEntry({
    required DriveEntry entry,
    required DriveProvider provider,
    required String dirPath,
    required ParsedMediaName parsed,
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();
    return MediaItem(
      provider: provider,
      fileId: entry.id,
      name: entry.name,
      dirId: entry.parentId ?? '',
      dirPath: dirPath,
      groupKey: parsed.groupKey,
      kind: parsed.kind,
      title: parsed.title,
      year: parsed.year,
      season: parsed.season,
      episode: parsed.episode,
      episodeEnd: parsed.episodeEnd,
      part: parsed.part,
      partLabel: parsed.partLabel,
      container: VideoFormats.containerOf(entry.name, mimeType: entry.mimeType),
      // **实测优先**：网盘给的像素尺寸比文件名可靠 —— 文件名是发布组自己
      // 标的，会标错也会缺；尺寸是服务端读文件头得到的（实测覆盖率 100%）。
      // 拿不到实测值时才退回文件名解析。
      //
      // ⚠️ 必须用 `resolutionFromDimensions`（按**长边**归挡），不能用
      // `_byHeight`（按高度）。实测样本里宽银幕裁切占 40%，按高度会把
      // `3840x1632` 的 4K 片标成 1440P，进而让多版本排序把 4K 版排到后面。
      resolution: VideoFormats.resolutionFromDimensions(
            entry.videoWidth,
            entry.videoHeight,
          ) ??
          parsed.resolution ??
          VideoFormats.resolutionFromName(entry.name),
      videoWidth: entry.videoWidth,
      videoHeight: entry.videoHeight,
      sizeBytes: entry.sizeBytes,
      modifiedAt: entry.modifiedAt,
      durationMs: entry.durationMs,
      source: parsed.source,
      videoCodec: parsed.videoCodec,
      audioCodec: parsed.audioCodec,
      flags: parsed.flags,
      releaseGroup: parsed.releaseGroup,
      isSampleOrExtra: parsed.isSampleOrExtra,
      // 网盘给的缩略图优先用 `preview_url`（实测 640×360，三档里最大）——
      // 海报墙上一个格子约 172 逻辑像素宽，2x 屏要 344px，
      // 178×100 那一档明显糊。反正都是按需下载 + 落盘缓存，一次几 KB。
      thumbUrl: entry.previewImageUrl ?? entry.thumbnailUrl,
      // 锚点与缩略图**同源**：三档缩略图都是同一个 fid 的同一帧（只是尺寸
      // 不同），所以人脸位置通用，不需要按档位分别取。
      faceAnchorX: entry.faceAnchorX,
      firstSeenAt: ts,
      updatedAt: ts,
    );
  }

  @override
  String toString() =>
      'MediaItem(${kind.name}, $fileId, "$displayTitle", ${sizeBytes ?? "-"}B)';
}

/// 人类可读体积。
///
/// 放在这里而不是 `core/utils/format.dart`：那个文件的 `formatBytes` 是
/// 音频项目留下的**二进制单位**（1024 进制），视频库的体积动辄几十 GB，
/// 展示口径要一致，所以在这里单独定一份并显式声明进制。
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : (value >= 10 ? 1 : 2);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
