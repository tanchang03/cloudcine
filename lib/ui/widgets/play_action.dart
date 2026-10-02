import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error/drive_error.dart';
import '../../domain/entities/media_item.dart';
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
  await context.push('/play?item=${Uri.encodeComponent(item.id)}');
}
