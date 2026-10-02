import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../data/db/settings_store.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/missing_media.dart';
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
  } on DriveException catch (e, st) {
    diag.error('窗口', '开独立播放窗口失败，退回内置播放页', error: e, stackTrace: st);
    // 「文件已经不在网盘上」**不退回内置页**。
    //
    // 内置页会拿同一个 fid 再取一次链，必然以同样的方式失败：白烧一次
    // 请求，还把用户晾在一个注定打不开的播放页上，而那里能给的只有一句
    // 「文件不存在」。真正该问的是「这条索引还有没有用」—— 那是调用方
    // （`playItem`）的活，所以抛给它。
    //
    // 其它失败种类（登录失效、限流、网络）照旧退回：那些情况下文件还在，
    // 内置页的重试按钮是有意义的。
    if (isMissingFileError(e)) rethrow;
    return false;
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
    SettingKeys.autoPlayNext,
    SettingKeys.skipIntro,
  ]);
  final preferred = qualityId ?? _nonEmpty(values[SettingKeys.defaultQuality]);
  // 设置里缺这一项时按「记住」处理：与 `AppSettings.rememberPosition` 的
  // 缺省值保持一致，两处不一致会出现「设置页显示开、实际没记住」。
  final remember = values[SettingKeys.rememberPosition] != 'false';
  // 连播与跳片头必须**随请求投过去**：播放窗口在另一个引擎里，读不到设置库
  // （见 `PlayRequest.autoPlayNext` 的类文档）。判据与 `AppSettings.fromValues`
  // 一致（缺失即开）—— 写成 `== 'true'` 会让「主窗口某次漏带」表现成
  // 「这两项在设置页开着却完全不生效」。
  final autoPlayNext = values[SettingKeys.autoPlayNext] != 'false';
  final skipIntro = values[SettingKeys.skipIntro] != 'false';

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

  // 作品行读一次，供三处用：剧集列表的缩略图、手标的片头区间。
  // 分两次读会多一次往返，而且两处拿到的可能是不同版本的行。
  final work = await repository.workByKey(item.groupKey);

  // 海报只查一次：剧集列表里每一集的缩略图都是**同一张作品海报**
  // （网盘不给逐集预览图，理由见 `PlaylistEntry.thumbnailUrl`）。
  final posterUrl =
      siblings.length < 2 ? null : _nonEmpty(work?.posterUrl);

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
      // 刮削后的剧名（没刮过就是本地解析出的片名）。**必须用作品行上的
      // 那个**，不是条目自己的 `title`：列表里一行一行扫的时候用户认的是
      // 「这部剧叫什么」，而条目上的 title 只是单个文件解析出来的东西。
      // 作品行缺失时 `listLabel` 会自己退回条目的 `title`。
      workTitle: work?.title,
    ),
    subtitles: await _buildSubtitles(repository, item.id),
    autoPlayNext: autoPlayNext,
    skipIntro: skipIntro,
    // 手标的片头区间。文件章节那一份由播放窗口自己从 mpv 读（它手里就有），
    // 这一对只能随请求过去 —— 库在主窗口。
    introStartMs: work?.introStartMs,
    introEndMs: work?.introEndMs,
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
  String? workTitle,
}) {
  if (siblings.length < 2) return const <PlaylistEntry>[];
  final labels = _playlistLabels(siblings, workTitle: workTitle);
  return <PlaylistEntry>[
    for (var i = 0; i < siblings.length; i++)
      PlaylistEntry(
        itemId: siblings[i].id,
        title: labels[i],
        subtitle: siblings[i].technicalSummary,
        thumbnailUrl: thumbnailUrl,
        // 原始值（不套「看完就从片头」）—— 面板上要用它画进度条。
        // 真正切过去时的起点由播放窗口算，见 `PlaylistEntry` 的类文档。
        resumePosition: resume[siblings[i].id] ?? Duration.zero,
        duration: _durationOf(siblings[i]),
        // 花絮 / 预告 / 样片。自动连播要跳过它们而不是撞上就停 ——
        // 判据取自扫描期的结果，不在这里重算（见 `PlaylistEntry.isExtra`）。
        isExtra: siblings[i].isSampleOrExtra,
      ),
  ];
}

/// 列表里每一行的标题 —— **先短，撞名才补信息**。
///
/// ## 为什么要这一步（不能直接用 `compact`）
///
/// 同一部剧的同一集常常有多个版本（翡翠台 / MyTVSuper、国语 / 粤语），它们的
/// `season`/`episode` 一模一样，`compact` 口径下**全写成 `第 1 集`** ——
/// 面板里就会出现两行一模一样的字。窄面板放不下版本名，但「撞名」是可以
/// 检测出来的：只给撞了的那几条加信息，其余保持短标题，不白白浪费本来就
/// 只有 320px 的宽度。
///
/// ## 逐级退让（每一级都只在**还撞着**的时候才用）
///
///   1. `第 3 集` —— 常态，最省空间；
///   2. `剧名 S01E03` —— 补片名，两个版本之间只有它不同；
///   3. `剧名-文件名` —— 连片名也分不开的两条（同一集的两个压制/码率），
///      只有文件名保证互不相同。
///
/// ⚠️ 递进去的是**作品行**的标题（刮削后的剧名）：用户认的是「这部剧叫什么」，
/// 而条目自己的 `title` 只是单个文件解析出来的东西
/// （`/来自：分享/F飞CC日  志2/01.国语.mp4` 解析出的是 `F飞CC日 志2`）。
List<String> _playlistLabels(List<MediaItem> items, {String? workTitle}) {
  var labels = <String>[
    for (final it in items)
      it.rowLabel(RowLabelStyle.compact, workTitle: workTitle),
  ];

  // 两级退让，最多各跑一次：先 `withTitle`，还撞就 `fileName`。
  for (final style in const [RowLabelStyle.withTitle, RowLabelStyle.fileName]) {
    final clashing = _clashingLabels(labels);
    if (clashing.isEmpty) break;
    labels = <String>[
      for (var i = 0; i < items.length; i++)
        clashing.contains(labels[i])
            ? items[i].rowLabel(style, workTitle: workTitle)
            : labels[i],
    ];
  }
  return labels;
}

/// 出现次数大于 1 的那些标题。**必须按「值」统计** —— 这正是要检测的东西。
Set<String> _clashingLabels(List<String> labels) {
  final seen = <String>{};
  final clashing = <String>{};
  for (final l in labels) {
    if (!seen.add(l)) clashing.add(l);
  }
  return clashing;
}

Duration _durationOf(MediaItem item) {
  final ms = item.durationMs;
  if (ms == null || ms <= 0) return Duration.zero;
  return Duration(milliseconds: ms);
}

String? _nonEmpty(String? v) =>
    (v == null || v.trim().isEmpty) ? null : v.trim();
