import '../../core/utils/subtitle_formats.dart';

/// 字幕的来源。
///
/// 这三条来源在播放器里的**加载方式完全不同**，所以必须区分：
///   - [cloudFile]：网盘上的字幕文件 → 先取直链，再交给 mpv 当外挂字幕加载
///   - [embedded]：视频文件内嵌的字幕轨 → mpv 直接 `sid=N` 切轨
///   - [localFile]：用户从本机选的字幕 → mpv 直接读本地路径
enum SubtitleOrigin {
  cloudFile('网盘字幕'),
  embedded('内嵌字幕'),
  localFile('本地字幕');

  const SubtitleOrigin(this.label);

  final String label;
}

/// 一条可加载的字幕。
///
/// 同一个视频往往同时有「内嵌中文轨」「同目录 `xxx.chs.ass`」「同目录
/// `xxx.eng.srt`」，它们在 UI 上是**同一个下拉列表**里的三个选项 ——
/// 用户不关心它从哪来，只关心能不能选中文字幕。所以本类型把三种来源
/// 归一成一条记录。
class SubtitleTrack {
  const SubtitleTrack({
    required this.id,
    required this.origin,
    required this.label,
    required this.format,
    this.language,
    this.fileId,
    this.fileName,
    this.localPath,
    this.embeddedTrackId,
    this.isForced = false,
    this.isSdh = false,
    this.isDefault = false,
    this.isExternal = false,
  });

  /// 稳定 ID。同一视频内的字幕按「来源 + 标识」去重时用它。
  final String id;

  final SubtitleOrigin origin;

  /// 展示名：`简体中文` / `英文 (SRT)` / `内嵌轨 #3`
  final String label;

  final SubtitleFormat format;

  final SubtitleLanguage? language;

  /// 网盘字幕文件 ID（[SubtitleOrigin.cloudFile] 时非空）
  final String? fileId;

  /// 字幕文件名（含扩展名）
  final String? fileName;

  /// 本地字幕绝对路径（[SubtitleOrigin.localFile] 时非空）
  final String? localPath;

  /// mpv 轨道号（[SubtitleOrigin.embedded] 时非空）
  final int? embeddedTrackId;

  final bool isForced;
  final bool isSdh;
  final bool isDefault;

  /// 是否是「视频文件之外」的字幕（网盘/本地文件）。
  ///
  /// mpv 的 `--sub-files` 只对外挂字幕有效；内嵌轨要靠切轨。
  final bool isExternal;

  /// 展示名后缀：`简体中文 (ASS)`
  String get displayLabel {
    final f = format.label;
    if (label.contains(f)) return label;
    return '$label ($f)';
  }

  /// 语言码（用于「默认选中文」这类偏好）
  String get languageCode => language?.code ?? '';

  /// 排序权重：**中文优先、非强制优先、文本字幕优先**。
  ///
  /// 排序而不是过滤：用户可能就是想看英文原版，把别的藏起来是越权。
  int get preferenceScore {
    var score = 0;
    final code = languageCode;
    if (code.startsWith('zh')) score -= 100;
    if (isForced) score += 50;
    if (isSdh) score += 20;
    if (!format.isText) score += 10;
    if (isDefault) score -= 5;
    return score;
  }

  SubtitleTrack copyWith({
    String? label,
    bool? isDefault,
    int? embeddedTrackId,
  }) =>
      SubtitleTrack(
        id: id,
        origin: origin,
        label: label ?? this.label,
        format: format,
        language: language,
        fileId: fileId,
        fileName: fileName,
        localPath: localPath,
        embeddedTrackId: embeddedTrackId ?? this.embeddedTrackId,
        isForced: isForced,
        isSdh: isSdh,
        isDefault: isDefault ?? this.isDefault,
        isExternal: isExternal,
      );

  @override
  String toString() => 'SubtitleTrack(${origin.name}, $displayLabel'
      '${isForced ? ", forced" : ""})';
}

/// 「某个媒体项有一条这样的字幕」。
///
/// 单独一个类型而不是给 [SubtitleTrack] 加个 `itemId` 字段：字幕本身
/// 是**视频的属性**，不应该自带「我属于谁」——那会让同一个字幕对象
/// 在复用（比如同一条内嵌轨信息）时携带过期的归属。
class SubtitleRef {
  const SubtitleRef({required this.itemId, required this.track});

  /// `MediaItem.id`
  final String itemId;

  final SubtitleTrack track;

  @override
  String toString() => 'SubtitleRef($itemId → ${track.displayLabel})';
}
