import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error/drive_error.dart';
import '../../domain/entities/drive_entry.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/services/media_discovery.dart';
import '../../domain/services/media_entry_classifier.dart';
import '../../domain/services/missing_media.dart';
import '../windows/desktop_play.dart';
import 'missing_media_dialog.dart';

/// 「播这一条」—— 全应用**唯一**的起播入口。
///
/// ## 为什么必须只有一份
///
/// 起播有两条路：桌面端的独立播放窗口，以及其它平台（或窗口起不来时）的
/// 内置播放页。两处页面各写一份的话，迟早会出现「从海报墙点进去走窗口、
/// 从详情页点进去走内置页」这种分裂 —— 而用户只会觉得「有时候是窗口、
/// 有时候不是，说不清什么时候」。
///
/// ## 降级是**静默**的
///
/// 用户点播放的意图是看片，不是体验多窗口。所以「窗口开不出来」不该变成
/// 一个错误弹窗 —— 直接退回内置播放页，原因进诊断日志
/// （见 `openInPlayerWindow`）。
///
/// ## 唯一一个例外：文件已经不在网盘上了
///
/// 那时**不**退回内置播放页。内置页会拿同一个 fid 再取一次链，必然以同样的
/// 方式失败：白烧一次请求，还把用户晾在一个注定打不开的页面上。取链这一步
/// 在 `buildPlayRequest` 里已经做过了（就在开窗口之前），所以文件没了这件
/// 事在**主窗口**就知道 —— 直接在这里问「要不要从媒体库里移除」。
Future<void> playItem(
  BuildContext context,
  WidgetRef ref,
  MediaItem item, {
  String? qualityId,
}) async {
  try {
    if (await openInPlayerWindow(ref, item, qualityId: qualityId)) return;
  } on DriveException catch (e) {
    // `openInPlayerWindow` 只把「文件没了」这一类抛出来，其余一律吞掉并
    // 退回内置页。这里的判据是**再确认一次**而不是信任调用约定 —— 万一
    // 哪天那边放宽了口径，这里也不会拿「登录失效」去问用户要不要删片。
    if (isMissingFileError(e)) {
      if (!context.mounted) return;
      await removeMissingMedia(context, ref, item);
      return;
    }
  }
  if (!context.mounted) return;
  // `extra` 带的是**对象本身**，不是 id：未入库的条目（目录视图直接点播）
  // 库里没有这一行，内置播放页拿 id 去查会查不到（见 `PlayerPage` 的
  // `item` 字段）。已经入库的条目带上它也无害 —— 同一个对象，省一次点查。
  await context.push(
    '/play?item=${Uri.encodeComponent(item.id)}',
    extra: item,
  );
}

/// 「播网盘上的这一个文件」—— **不需要它已经在媒体库里**。
///
/// ## 为什么要有这条入口
///
/// 目录视图列的是**网盘上的东西**，而媒体库只装「扫过 / 发现过的东西」。
/// 两者之间那段差额（新上传的、上次扫漏的、别人分享过来还没入库的）原先
/// 只能「先点『加入媒体库』、再点播放」。而用户点播放的意图是**看片**，
/// 不是整理媒体库；那个中间步骤还会真的改库（多一条记录、多一部作品），
/// 而他可能只是想先看一眼画质对不对。
///
/// ## 它**不写库**
///
/// 这里造的 `MediaItem` 只活在内存里（[parseTransientMedia]），一行都不落。
/// 起播链本来就不依赖本地库：`PlaybackController.open` 只收一个 `MediaItem`，
/// 直链由 `adapter.resolveStream(fid)` 现取。
///
/// 代价是**六项能力静默降级**（库里没有这一行）：续播点、剧集连播、同目录
/// 字幕、逐片播放偏好、片头标记、直链过期自动续播。最后一项由
/// [rememberTransientItem] 补上（见那张表的文档）；其余五项本来就要求
/// 「库里认得这一条」，用户没入库就不该指望它们。
///
/// ## 为什么非视频一律拒绝
///
/// UI 只对视频行给入口，这里是**防御**：别让一个 `cover.jpg` 或一个 `.srt`
/// 变成一次注定失败的取链（会拿一个图片 fid 去打 `play/info`）。判据与
/// 扫描 / 发现共用 [classifyEntry]。
Future<void> playDriveEntry(
  BuildContext context,
  WidgetRef ref, {
  required DriveProvider provider,
  required DriveEntry entry,
  required String dirPath,
}) async {
  if (classifyEntry(entry) != EntryRole.video) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('这不是可播放的视频文件'),
      ),
    );
    return;
  }

  final item = parseTransientMedia(
    entry: entry,
    provider: provider,
    dirPath: dirPath,
  ).item;

  // 记一份给「直链过期自动续播」用：那条路发生在**另一个引擎**里，只能回
  // 主窗口问，而主窗口查库查不到这一条（它没入库）。见 `desktop_play.dart`
  // 里 `_transientItems` 的文档。
  rememberTransientItem(item);

  await playItem(context, ref, item);
}
