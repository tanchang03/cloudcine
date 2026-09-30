import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../data/db/settings_store.dart';
import '../../domain/entities/media_item.dart';
import '../providers/app_providers.dart';
import 'player_protocol.dart';
import 'player_window_bridge.dart';

/// 取链只需要「读 provider」这一件事。
///
/// `WidgetRef`（widget 层）与 `Ref`（provider 层）都有这个方法，但 Riverpod
/// 没有暴露它们的公共父类型。抽成函数类型是为了让**选档规则只有一份** ——
/// 否则「点播放时取链」和「播放中刷新直链」会各写一套，同一部片在两种情形下
/// 会播出不同清晰度（而且这种错很难被注意到）。
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// 桌面端：把「播这部片」交给独立播放窗口。
///
/// 返回 `true` 表示已经交给窗口（调用方不要再跳内置播放页）；
/// 返回 `false` 表示应当**退回同进程的播放页** —— 平台不支持、取链失败、
/// 窗口起不来，都走这条。
///
/// 为什么留退路而不是直接抛：独立窗口是 PC 端的增强能力，它坏掉不该让
/// 「看片」这件事整个不可用。夸克网盘也是这么做的 ——
/// `isApolloPlayerEnable()` 为假时降级到 H5 `<video>`。
///
/// 取链的耗时是**几百毫秒**（实测 `play/info` 约 360ms），所以这里不需要
/// 转圈提示：窗口会紧接着弹出来，中间的空档短到不值得插一个 loading。
Future<bool> openInPlayerWindow(
  WidgetRef ref,
  MediaItem item, {
  String? qualityId,
}) async {
  if (!supportsMultiWindow) return false;

  try {
    final request = await buildPlayRequest(ref.read, item, qualityId: qualityId);
    final controller = await const PlayerWindowLauncher().open(request);
    return controller != null;
  } catch (e, st) {
    diag.error('窗口', '开独立播放窗口失败，退回内置播放页', error: e, stackTrace: st);
    return false;
  }
}

/// 在主窗口把票据解析成一条可以直接投给播放窗口的请求。
///
/// 这里做的是 `PlaybackController.open` 的**前半段**（取链 + 选档），
/// 但不碰 mpv —— 播放动作发生在另一个引擎里。
///
/// 选档规则走 `StreamTicket.pickActiveQualityId`，与内置播放页共用同一处
/// 实现：两处各写一份的话，同一部片在两种播法下会播出不同清晰度。
///
/// [startPosition] 在**刷新过期直链**时使用：播放窗口把当前位置报上来，
/// 这里原样填进请求，于是刷新对用户表现为「卡一下接着播」而不是「从头开始」。
Future<PlayRequest> buildPlayRequest(
  ProviderReader read,
  MediaItem item, {
  String? qualityId,
  Duration startPosition = Duration.zero,
}) async {
  // 依赖**同步**取完再进 await：这中间 widget 可能被回收，
  // 之后再碰 `ref` 就会抛。
  final adapter = read(adapterRegistryProvider).requireAdapter(item.provider);
  final settings = read(settingsStoreProvider);

  final values = await settings.readAll(const [SettingKeys.defaultQuality]);
  final preferred = qualityId ?? _nonEmpty(values[SettingKeys.defaultQuality]);

  diag.info(
    '窗口',
    '为独立窗口取链：fid=${item.fileId} 首选档位=${preferred ?? "-"}',
  );
  final ticket = await adapter.resolveStream(item.fileId, qualityId: preferred);

  final activeId = ticket.pickActiveQualityId(preferred);
  final quality = activeId == null ? null : ticket.qualityById(activeId);
  final picked = quality == null ? ticket : ticket.withQuality(quality);

  diag.info(
    '窗口',
    '投给独立窗口：${picked.redactedUrl} '
    '请求头=${picked.headers.keys.toList()} 档位=${quality?.label ?? "-"}',
  );

  return PlayRequest(
    url: picked.url.toString(),
    title: item.displayTitle,
    // 只为进度回报用：播放窗口每 10 秒把位置报回来，主窗口据此落库。
    // 不带它的话「独立窗口播完，续播位置不记」。
    //
    // 它同时是「这条请求能不能被刷新」的开关 —— 见
    // `PlayerBridgeMethod.refreshTicket`。
    itemId: item.id,
    headers: picked.headers,
    // id 与 label 都要带：id 是刷新时原样带回的（保证还是这一档），
    // label 只用于显示。只带 label 的话，用户手选的档位会在一次刷新后
    // 静默跳回设置里的默认档。
    qualityId: activeId,
    qualityLabel: quality?.label,
    startPosition: startPosition,
  );
}

String? _nonEmpty(String? v) =>
    (v == null || v.trim().isEmpty) ? null : v.trim();
