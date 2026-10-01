import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../data/db/settings_store.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/playback_resume.dart';
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
/// ## [startPosition] 的两种语义，别混
///
///   - **给了值** → 原样使用。这是「刷新过期直链」那条路：位置是**当前正在播
///     的地方**，必须一字不差地续上。
///   - **不给（null）** → 读库里的续播点，并过一遍 [PlaybackResume] 的取舍
///     （太靠前当没看过、接近结尾当看完）。这是「用户点开一集」那条路。
///
/// 之所以不能用同一个口径：刷新时如果也套「接近结尾就从片头」，
/// 用户在最后两分钟里遇到直链过期就会被丢回片头。
Future<PlayRequest> buildPlayRequest(
  ProviderReader read,
  MediaItem item, {
  String? qualityId,
  Duration? startPosition,
}) async {
  // 依赖**同步**取完再进 await：这中间 widget 可能被回收，
  // 之后再碰 `ref` 就会抛。
  final adapter = read(adapterRegistryProvider).requireAdapter(item.provider);
  final settings = read(settingsStoreProvider);
  final repository = read(mediaRepositoryProvider);

  final values = await settings.readAll(const [
    SettingKeys.defaultQuality,
    SettingKeys.rememberPosition,
  ]);
  final preferred = qualityId ?? _nonEmpty(values[SettingKeys.defaultQuality]);
  // 设置里缺这一项时按「记住」处理：与 `AppSettings.rememberPosition` 的
  // 缺省值保持一致，两处不一致会出现「设置页显示开、实际没记住」。
  final remember = values[SettingKeys.rememberPosition] != 'false';

  // 剧集列表与续播位置一起取：它们来自同一批兄弟条目，分两次查会多一次
  // 往返，也容易漏掉「当前这一集」本身（它不是从 `siblings` 里挑出来的，
  // 而是调用方给的那一项）。
  final siblings = await repository.itemsForWork(item.groupKey);
  final ids = <String>{item.id, for (final s in siblings) s.id}.toList();
  final resume = remember
      ? await repository.resumePositions(ids)
      : const <String, Duration>{};

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
    '请求头=${picked.headers.keys.toList()} 档位=${quality?.label ?? "-"} '
    '可选档位=${ticket.qualities.length} 同组条目=${siblings.length}',
  );

  final start = startPosition ??
      PlaybackResume.startFrom(
        stored: resume[item.id] ?? Duration.zero,
        total: _durationOf(item),
      );
  if (start > Duration.zero) {
    diag.info('窗口', '续播：${item.displayTitle} 从 ${start.inSeconds}s 开始');
  }

  // 海报只查一次：剧集列表里每一集的缩略图都是**同一张作品海报**
  // （网盘不给逐集预览图，理由见 `PlaylistEntry.thumbnailUrl`）。
  final posterUrl = siblings.length < 2
      ? null
      : _nonEmpty((await repository.workByKey(item.groupKey))?.posterUrl);

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
    // id 与 label 都要带：id 是刷新/切档时原样带回的（保证还是这一档），
    // label 只用于显示。只带 label 的话，用户手选的档位会在一次刷新后
    // 静默跳回设置里的默认档。
    qualityId: activeId,
    qualityLabel: quality?.label,
    startPosition: start,
    // 缓冲指示要用它把「缓存了多少秒」换算成 KB/s，见字段文档。
    sizeBytes: item.sizeBytes,
    // 画质弹框的数据源。**只有元信息，没有地址** —— 换档要把 id 报回来
    // 重新取链，理由见 `QualityBrief` 的类文档。
    qualities: [
      for (final q in ticket.qualities)
        QualityBrief(
          id: q.id,
          label: q.label,
          detail: _nonEmpty(q.displayDetail),
        ),
    ],
    playlist: _buildPlaylist(
      siblings: siblings,
      resume: resume,
      thumbnailUrl: posterUrl,
    ),
    subtitles: await _buildSubtitles(repository, item.id),
  );
}

/// 把库里存的**网盘**字幕引用转成播放窗口能显示的清单。
///
/// ⚠️ 只要 [SubtitleOrigin.cloudFile]：内嵌轨在播放窗口本地从 mpv 的
/// `stream.tracks` 读（那才是它的真相来源），本地字幕是用户临时选的、
/// 主窗口根本不知道。**只带引用，不带正文** —— 正文等用户真的选中那条时
/// 再走 `PlayerBridgeMethod.fetchSubtitleText` 取，理由见 `SubtitleBrief`。
Future<List<SubtitleBrief>> _buildSubtitles(
  MediaRepository repository,
  String itemId,
) async {
  final tracks = await repository.subtitlesForItem(itemId);
  return <SubtitleBrief>[
    for (final t in tracks)
      if (t.origin == SubtitleOrigin.cloudFile)
        if (t.fileId case final fid? when fid.isNotEmpty)
          SubtitleBrief(
            fileId: fid,
            label: t.displayLabel,
            language: t.languageCode.isEmpty ? null : t.languageCode,
            fileName: t.fileName,
          ),
  ];
}

/// 把同一部作品的其它条目拼成剧集列表。
///
/// **只有一项时返回空列表**：电影、单集花絮的「列表」里只有它自己，
/// 弹出来只会挡住画面。这也是「是电视剧才显示集数列表」的实现口径 ——
/// 判据不是「kind 是不是剧」，而是「同组有没有多个可播条目」，
/// 后者对「一部电影的两个版本」同样成立（那时也确实该能选）。
List<PlaylistEntry> _buildPlaylist({
  required List<MediaItem> siblings,
  required Map<String, Duration> resume,
  required String? thumbnailUrl,
}) {
  if (siblings.length < 2) return const <PlaylistEntry>[];
  return <PlaylistEntry>[
    for (final s in siblings)
      PlaylistEntry(
        itemId: s.id,
        title: _episodeLabel(s),
        subtitle: s.technicalSummary,
        thumbnailUrl: thumbnailUrl,
        // 原始值（不套「看完就从片头」）—— 面板上要用它画进度条。
        // 真正切过去时的起点由播放窗口算，见 `PlaylistEntry` 的类文档。
        resumePosition: resume[s.id] ?? Duration.zero,
        duration: _durationOf(s),
      ),
  ];
}

/// 剧集列表上的主标题。
///
/// 不用 `displayTitle`：它带着片名（`剧名 S01E03`），而列表里每一行都是
/// 同一部剧，片名是纯噪音 —— 用户扫的是集号。多季时补一个季前缀，
/// 否则第二季的「第 3 集」会跟第一季的撞在一起分不清。
String _episodeLabel(MediaItem item) {
  final e = item.episode;
  if (e == null) return item.displayTitle;

  final season = item.season;
  final end = item.episodeEnd;
  final range = (end != null && end != e) ? '$e-$end' : '$e';
  final prefix = (season == null || season <= 1) ? '' : 'S$season · ';
  return '$prefix第 $range 集';
}

Duration _durationOf(MediaItem item) {
  final ms = item.durationMs;
  if (ms == null || ms <= 0) return Duration.zero;
  return Duration(milliseconds: ms);
}

String? _nonEmpty(String? v) =>
    (v == null || v.trim().isEmpty) ? null : v.trim();
