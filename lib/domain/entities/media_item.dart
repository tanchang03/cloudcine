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
    this.container = VideoContainer.other,
    this.resolution,
    this.sizeBytes,
    this.modifiedAt,
    this.durationMs,
    this.source,
    this.videoCodec,
    this.audioCodec,
    this.flags = const {},
    this.releaseGroup,
    this.isSampleOrExtra = false,
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

  final VideoContainer container;

  /// 从文件名推断的分辨率。**不是实测值** —— 真实分辨率要等播放器解出来。
  final VideoResolution? resolution;

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

  final DateTime firstSeenAt;
  final DateTime updatedAt;

  /// 稳定主键。`provider` 前缀是必须的：接第二家网盘后，不同网盘的
  /// `fid` 完全可能撞车。
  String get id => '${provider.id}:$fileId';

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

  MediaItem copyWith({
    String? dirPath,
    String? title,
    int? year,
    int? season,
    int? episode,
    int? episodeEnd,
    VideoResolution? resolution,
    int? durationMs,
    bool? isSampleOrExtra,
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
        container: container,
        resolution: resolution ?? this.resolution,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        durationMs: durationMs ?? this.durationMs,
        source: source,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        flags: flags,
        releaseGroup: releaseGroup,
        isSampleOrExtra: isSampleOrExtra ?? this.isSampleOrExtra,
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
      container: VideoFormats.containerOf(entry.name, mimeType: entry.mimeType),
      // 文件名里的分辨率优先，网盘元数据里没有更好的来源
      resolution: parsed.resolution ??
          VideoFormats.resolutionFromName(entry.name),
      sizeBytes: entry.sizeBytes,
      modifiedAt: entry.modifiedAt,
      durationMs: entry.durationMs,
      source: parsed.source,
      videoCodec: parsed.videoCodec,
      audioCodec: parsed.audioCodec,
      flags: parsed.flags,
      releaseGroup: parsed.releaseGroup,
      isSampleOrExtra: parsed.isSampleOrExtra,
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
