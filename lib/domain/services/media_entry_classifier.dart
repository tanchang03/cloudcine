import '../../core/utils/image_formats.dart';
import '../../core/utils/subtitle_formats.dart';
import '../../core/utils/video_formats.dart';
import '../entities/drive_entry.dart';

/// 一个网盘条目在「媒体索引」里的角色。
///
/// ## 为什么要有这个枚举
///
/// 「哪些文件该进媒体库」这条判据原先只存在于 `ScanService` 的遍历循环里。
/// 现在有**两条**入口会往媒体库里写东西 —— 全盘扫描与局部发现（文件夹里
/// 点「发现」）—— 两处各写一遍判据，迟早会漂移，而漂移是**静默**的：
/// 同一个文件走全盘扫描会入库、走文件夹发现不会（或反过来），用户只会
/// 觉得「这个功能时好时坏」。
///
/// 所以判据只有一份实现，两条路径都调它。
enum EntryRole {
  /// 目录。不是媒体，但扫描/发现要决定是否进进去。
  directory,

  /// 可播放视频 —— **唯一**会被索引进媒体库的东西。
  video,

  /// 字幕文件。不建媒体项，只用来和同目录的视频配对（见 `SubtitleIndexer`）。
  subtitle,

  /// 图片。完全不索引 —— 一张 `cover.jpg` 变成「一个视频」会让媒体库
  /// 出现一堆点开就报错的条目。
  image,

  /// 蓝光镜像（`.iso` / `.img`）。mpv 播不了 BD 导航结构，
  /// 索引了只会得到一堆点了播不了的行。
  discImage,

  /// 其余（文档、压缩包、音频…）。不索引。
  other;

  bool get isIndexable => this == EntryRole.video;
}

/// 判定一个网盘条目的角色。
///
/// **判定顺序不能随手改**：一个名字同时像两类的情况是存在的，顺序决定了它
/// 落到哪一类。当前顺序：字幕 → 图片 → 镜像 → 视频。
///
/// ⚠️ 其中「镜像在视频**之前**」是有意为之，不是笔误。`.iso` / `.img`
/// 本来就不在视频扩展名表里，把镜像判定放在视频判定之后的话这一支永远走
/// 不到（原 `ScanService` 里那句 `isDiscImage` 正是这样变成死代码的）。
/// 两种顺序下**索引结果完全一样**（都不会入库），差别只在日志：放前面才看得
/// 出「这个文件是作为镜像被跳过的」。
EntryRole classifyEntry(DriveEntry entry) {
  if (entry.isDirectory) return EntryRole.directory;

  final name = entry.name;
  if (SubtitleFormats.isSubtitleFile(name)) return EntryRole.subtitle;
  if (isImageFile(name, mimeType: entry.mimeType)) return EntryRole.image;
  if (VideoFormats.isDiscImage(name)) return EntryRole.discImage;
  if (!VideoFormats.isVideoFile(name, mimeType: entry.mimeType)) {
    return EntryRole.other;
  }
  return EntryRole.video;
}
