import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_item.dart';
import '../windows/desktop_play.dart';

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
Future<void> playItem(
  BuildContext context,
  WidgetRef ref,
  MediaItem item, {
  String? qualityId,
}) async {
  if (await openInPlayerWindow(ref, item, qualityId: qualityId)) return;
  if (!context.mounted) return;
  await context.push('/play?item=${Uri.encodeComponent(item.id)}');
}
