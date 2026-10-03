import 'package:flutter/foundation.dart';

import '../../core/utils/filename_parser.dart';
import '../../domain/services/intro_marker.dart';
import '../../domain/services/missing_media.dart';

/// 一档可选的清晰度。**只有元信息，没有地址。**
///
/// ## 为什么地址不跟着来
///
/// 取链留在主窗口是这套架构的硬边界（见 [PlayRequest] 的类文档）。所以
/// 播放窗口的「画质」弹框不是「换一条 URL」，而是**把档位 id 报回主窗口**，
/// 由主窗口重新取一条链回来 —— 走的就是 [TicketRefreshRequest] 那条路。
///
/// 这也顺带解决了「切档之后画质菜单要跟着变」：主窗口回来的新 [PlayRequest]
/// 里带着新的 [PlayRequest.qualities]，弹框重新渲染即可。
@immutable
class QualityBrief {
  const QualityBrief({required this.id, required this.label, this.detail});

  /// 服务端档位标识（`origin` / `super` / `4k`…）。切档时原样带回。
  final String id;

  /// 展示名（`原画` / `超清 1080P`）。
  final String label;

  /// 补充说明（`1920×1080 · 4.2 Mbps`）。可能为空。
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'detail': detail,
      };

  /// 畸形输入返回 null —— 一档读不懂就丢一档，不该让整个请求解不开。
  static QualityBrief? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final label = raw['label'];
    final detail = raw['detail'];
    return QualityBrief(
      id: id,
      // label 缺失时退回 id：菜单上显示一个 `h265_1080` 也比显示空行强。
      label: label is String && label.isNotEmpty ? label : id,
      detail: detail is String && detail.isNotEmpty ? detail : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualityBrief &&
          other.id == id &&
          other.label == label &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(id, label, detail);

  @override
  String toString() => 'QualityBrief($id, $label)';
}

/// 网盘上的一条字幕文件。**只有引用，不带正文。**
///
/// ## 为什么正文不跟着来
///
/// 与 [QualityBrief]「不带地址」是同一条边界：读网盘文件需要凭证与请求头
/// （夸克直链缺 Cookie 一律 412），而那些东西**只存在于主窗口**。播放窗口
/// 知道「有这条字幕」，真正要用时再让主窗口把正文取回来（
/// `PlayerBridgeMethod.fetchSubtitleText`）。
///
/// 另一个理由是开销：扫描阶段就已经明确「不下载字幕正文」（见
/// `SubtitleIndexer` 的类文档）—— 一个几千部片子的库会因此多出几千次请求，
/// 而其中大部分字幕用户永远不会看。
@immutable
class SubtitleBrief {
  const SubtitleBrief({
    required this.fileId,
    required this.label,
    this.language,
    this.fileName,
  });

  /// 字幕文件的网盘 id。取正文时原样报回主窗口。
  final String fileId;

  /// 展示名（`简体中文` / `英文`）
  final String label;

  /// 语言码（`zh` / `en`）。菜单排序用（中文优先）。
  final String? language;

  /// 原始文件名（`Movie.2023.chs.srt`）。菜单副标题与排错用。
  final String? fileName;

  Map<String, Object?> toJson() => <String, Object?>{
        'fileId': fileId,
        'label': label,
        'language': language,
        'fileName': fileName,
      };

  /// 畸形输入返回 null —— 一条读不懂就丢一条，不该让整个请求解不开。
  static SubtitleBrief? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fileId = raw['fileId'];
    if (fileId is! String || fileId.isEmpty) return null;
    final label = raw['label'];
    final language = raw['language'];
    final fileName = raw['fileName'];
    return SubtitleBrief(
      fileId: fileId,
      // 没有名字时退回文件名，再没有就退回 id —— 菜单上不能出现空行。
      label: label is String && label.isNotEmpty
          ? label
          : (fileName is String && fileName.isNotEmpty ? fileName : fileId),
      language: language is String && language.isNotEmpty ? language : null,
      fileName: fileName is String && fileName.isNotEmpty ? fileName : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtitleBrief &&
          other.fileId == fileId &&
          other.label == label &&
          other.language == language &&
          other.fileName == fileName;

  @override
  int get hashCode => Object.hash(fileId, label, language, fileName);

  @override
  String toString() => 'SubtitleBrief($label)';
}

/// 在线字幕站点上搜到的一条候选。
///
/// 与 [SubtitleBrief] 的区别：那条是**网盘上已经存在的**字幕文件（有 fileId、
/// 走我们自己的取链），这条是**第三方站点上的**（要换一条临时下载地址才拿得到，
/// 而且有每日额度）。两者在菜单里是同一组选项，但**取正文的路径完全不同**。
///
/// 放在协议层而不是直接把 `OnlineSubtitleHit` 传过来：播放窗口不该为了显示
/// 一条字幕而依赖某个字幕站的客户端。
@immutable
class OnlineSubtitleBrief {
  const OnlineSubtitleBrief({
    required this.fileId,
    required this.fileName,
    this.language,
    this.title,
    this.downloadCount = 0,
  });

  /// 在这家站点上的 `file_id`。下载时原样报回主窗口。
  final int fileId;

  final String fileName;
  final String? language;
  final String? title;
  final int downloadCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'fileId': fileId,
        'fileName': fileName,
        'language': language,
        'title': title,
        'downloadCount': downloadCount,
      };

  static OnlineSubtitleBrief? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fileId = raw['fileId'];
    final id = fileId is int ? fileId : int.tryParse('$fileId');
    if (id == null) return null;
    final fileName = raw['fileName'];
    final language = raw['language'];
    final title = raw['title'];
    final count = raw['downloadCount'];
    return OnlineSubtitleBrief(
      fileId: id,
      fileName: fileName is String && fileName.isNotEmpty ? fileName : '字幕 $id',
      language: language is String && language.isNotEmpty ? language : null,
      title: title is String && title.isNotEmpty ? title : null,
      downloadCount: count is int ? count : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnlineSubtitleBrief &&
          other.fileId == fileId &&
          other.fileName == fileName &&
          other.language == language &&
          other.title == title &&
          other.downloadCount == downloadCount;

  @override
  int get hashCode => Object.hash(fileId, fileName, language, title, downloadCount);

  @override
  String toString() => 'OnlineSubtitleBrief($fileName, ${language ?? "-"})';
}

/// 「去字幕站搜这部片」的请求。
///
/// ## 为什么参数是 `itemId` 而不是一句 `query`
///
/// 字幕站要的**不只是一句片名**：同一部剧的不同季/集是不同的字幕，电影还要
/// 年份来排除同名翻拍。这几样东西都躺在主窗口的库里（`MediaItem`），而播放
/// 窗口手里只有一个给人看的标题字符串 —— 让它去拆「指环王：力量之戒 S01E01」
/// 再猜出季集号，就是把一个已经结构化的信息降级成字符串解析。
///
/// 与 [PlayerBridgeMethod.refreshTicket] 是同一个道理：凡是「要查库才知道」的
/// 参数，一律由主窗口按 `itemId` 自己补全，播放窗口只负责说「搜这一条」。
///
/// [fallbackQuery] 服务没有库记录的场景（手输直链、内置自检视频）：那时没有
/// `itemId`，只能拿显示标题凑合搜一次，搜不准是预期的。
@immutable
class SubtitleSearchRequest {
  const SubtitleSearchRequest({this.itemId = '', this.fallbackQuery = ''});

  /// 本地索引库里这一项的 id。空串 = 没有库记录。
  final String itemId;

  /// 没有 [itemId] 时用的兜底片名。
  final String fallbackQuery;

  /// 两样都没有就没得搜。主窗口据此**不发请求**（发出去只会白烧一次额度）。
  bool get isEmpty => itemId.isEmpty && fallbackQuery.trim().isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'fallbackQuery': fallbackQuery,
      };

  /// 解不开时返回**空请求**而不是 null —— 调用方只需要判 [isEmpty]，
  /// 多一个 null 分支就多一处可能漏判的地方。
  static SubtitleSearchRequest fromJson(Object? raw) {
    if (raw is! Map) return const SubtitleSearchRequest();
    final itemId = raw['itemId'];
    final fallback = raw['fallbackQuery'];
    return SubtitleSearchRequest(
      itemId: itemId is String ? itemId : '',
      fallbackQuery: fallback is String ? fallback : '',
    );
  }

  @override
  String toString() =>
      'SubtitleSearchRequest(itemId=${itemId.isEmpty ? "-" : itemId}, '
      'fallback="${fallbackQuery.trim()}")';
}

/// 剧集列表里的一项。
///
/// ## 为什么列表数据要跟着请求一起来
///
/// 播放窗口跑在**另一个引擎**里，碰不到主窗口的仓储（见 `PlayerWindowApp`
/// 的类文档）。所以「这部剧还有哪几集」只能由主窗口在投递请求时一并给出。
///
/// ## 为什么续播点在这里是**原始值**
///
/// [resumePosition] 是库里存的原始位置，面板上用它画进度条（「这一集看到
/// 一半」）。而真正切过去时的起点要过一遍「快看完了就从头」的取舍 ——
/// 那一步由 `PlaybackResume.startFrom` 做，**由播放窗口在切集时算**：
/// 它手里有 [resumePosition] 与 [duration]，算完把结果当位置报回主窗口。
///
/// 之所以不在主窗口算好塞进来：同一个字段要同时服务「显示」和「起播」两个
/// 用途，而两者的口径不同 —— 混在一起会让进度条显示成 0（看着像没看过）。
@immutable
class PlaylistEntry {
  const PlaylistEntry({
    required this.itemId,
    required this.title,
    this.subtitle = '',
    this.thumbnailUrl,
    this.resumePosition = Duration.zero,
    this.duration = Duration.zero,
    this.isExtra = false,
  });

  /// 这一集的媒体项 id（`provider:fileId`）。切集时原样报回主窗口。
  final String itemId;

  /// 主标题。有集号时是 `第 3 集`（多集连播是 `第 3-4 集`）；**提不出集号时
  /// 是 `剧名-文件名`** —— 那一支不能用片名，否则「目录名作为系列名」的
  /// 目录（整目录归一部剧、季集号被刻意清掉）下列表里每一行都是同一个剧名，
  /// 完全分不出是哪一集。组装规则见 `desktop_play.dart` 的 `_episodeLabel`。
  final String title;

  /// 副标题（`2160P · MKV · H.265 · 12.3 GB`）。可能为空。
  final String subtitle;

  /// 缩略图地址。**是作品海报，不是这一集的截图** —— 网盘不给逐集预览图，
  /// 我们也没有解码首帧的能力（那要在播放窗口里跑一次 seek，代价太大）。
  /// `null` 时 UI 用集号占位。
  final String? thumbnailUrl;

  /// 库里存的续播点（原始值，见类文档）。
  final Duration resumePosition;

  /// 这一集的时长。未知时是 [Duration.zero]。
  final Duration duration;

  /// 这一条是不是**花絮 / 预告 / 样片**。
  ///
  /// 自动连播必须跳过它们，而不是撞上就停（见 `EpisodeQueue.nextAfter`
  /// 第 2 条）：网盘上的剧集目录里经常混着 `S01E01.预告.mp4` / `Sample.mkv`，
  /// 而且顺序不固定 —— 不跳的话，第 2 集播完会开始播一个 30 秒的预告片，
  /// 而用户刚把遥控器放下。
  ///
  /// 判据来自扫描期的 `MediaItem.isSampleOrExtra`（唯一实现在
  /// `media_entry_classifier.dart`），**不在播放窗口里重算** —— 它拿不到
  /// 文件名以外的信息，重算必然与库里的口径漂移。
  final bool isExtra;

  /// 有没有看过一点。面板据此决定要不要画那条细进度条。
  bool get hasProgress => resumePosition > Duration.zero;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'title': title,
        'subtitle': subtitle,
        'thumbnailUrl': thumbnailUrl,
        'resumePositionMs': resumePosition.inMilliseconds,
        'durationMs': duration.inMilliseconds,
        'isExtra': isExtra,
      };

  /// 畸形输入返回 null。**没有 itemId 的项没有意义** —— 点它也不知道该播什么。
  static PlaylistEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;

    final title = raw['title'];
    final subtitle = raw['subtitle'];
    final thumbnail = raw['thumbnailUrl'];
    final resume = raw['resumePositionMs'];
    final duration = raw['durationMs'];
    // 缺这一项时按「不是花絮」处理：老版本主窗口投过来的请求里没有它，
    // 而把每一集都当成花絮的后果是**自动连播整个失效**（一直往后扫到结尾），
    // 比偶尔播一个预告片严重得多。
    final isExtra = raw['isExtra'];

    return PlaylistEntry(
      itemId: itemId,
      title: title is String && title.isNotEmpty ? title : itemId,
      subtitle: subtitle is String ? subtitle : '',
      thumbnailUrl: thumbnail is String && thumbnail.isNotEmpty
          ? thumbnail
          : null,
      resumePosition: Duration(
        milliseconds: resume is int && resume > 0 ? resume : 0,
      ),
      duration: Duration(
        milliseconds: duration is int && duration > 0 ? duration : 0,
      ),
      isExtra: isExtra is bool && isExtra,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistEntry &&
          other.itemId == itemId &&
          other.title == title &&
          other.subtitle == subtitle &&
          other.thumbnailUrl == thumbnailUrl &&
          other.resumePosition == resumePosition &&
          other.duration == duration &&
          other.isExtra == isExtra;

  @override
  int get hashCode => Object.hash(
        itemId,
        title,
        subtitle,
        thumbnailUrl,
        resumePosition,
        duration,
        isExtra,
      );

  @override
  String toString() =>
      'PlaylistEntry($title, ${resumePosition.inSeconds}s/${duration.inSeconds}s'
      '${isExtra ? ", 花絮" : ""})';
}

/// 主窗口 → 播放窗口的「播这个」请求。
///
/// ## 为什么边界画在这里
///
/// 它**只带出画需要的东西**：直链、请求头、标题、起播位置，外加一个本地
/// 记录 id（只为回报进度用）。不带清晰度梯度、不带任何网盘凭证。
///
/// 这是刻意的，也是夸克网盘的做法：取链、鉴权、重试全部留在主窗口 ——
/// 那套逻辑的正确性只在主窗口验过（`QuarkAdapter` + 会话轮换 + 路由降级），
/// 播放窗口一旦也要自己取链，就得把这一整套复制一份，然后维护两个真相。
///
/// 反过来，播放窗口只做一件事：拿到一个能播的 URL 和它需要的请求头，出画。
/// 它甚至不知道「夸克」这个词。
///
/// ## 为什么请求头必须显式传
///
/// 夸克直链**缺 Cookie 一律 412**（见 `StreamTicket.headers` 的文档）。
/// 少了这一项的表现是「能取到链、一播就报错」，而错误信息里看不出是缺头。
@immutable
class PlayRequest {
  const PlayRequest({
    required this.url,
    required this.title,
    this.itemId = '',
    this.headers = const <String, String>{},
    this.qualityId,
    this.qualityLabel,
    this.startPosition = Duration.zero,
    this.sizeBytes,
    this.qualities = const <QualityBrief>[],
    this.playlist = const <PlaylistEntry>[],
    this.subtitles = const <SubtitleBrief>[],
    this.autoPlayNext = true,
    this.skipIntro = true,
    this.introStartMs,
    this.introEndMs,
    this.streamRelay = true,
    this.relayConnections = 8,
  });

  /// 直链地址（含签名查询串）
  final String url;

  /// 播放窗口标题栏/页头显示的片名
  final String title;

  /// 本地索引库里这一项的 id。
  ///
  /// **只为回报进度用**：播放窗口每 10 秒把位置报回主窗口，主窗口据此
  /// `markPlayed`。它不是凭证，只是我们自己的一个行号。
  ///
  /// 之所以进度要回主窗口落库而不是播放窗口自己写：数据库与仓储都装在主窗口，
  /// 播放窗口刻意不碰它们（见 `PlayerWindowApp` 的类文档）。
  ///
  /// 它同时是**能不能刷新直链的开关**：没有 id（自检视频、手输直链）就没法
  /// 让主窗口重新取链。
  final String itemId;

  /// 播放器必须携带的请求头
  final Map<String, String> headers;

  /// 当前档位的**机器可读标识**（`4k` / `super` 这类）。
  ///
  /// 与 [qualityLabel] 的区别：label 是给人看的（`4k(2160p)`），id 是给
  /// 服务端和自己看的。刷新直链时必须把 id 原样带回去 —— 只带 label 的话
  /// 主窗口只能退回「设置里的默认档位」，用户手选的档位会在一次刷新后
  /// **静默跳回默认**。
  final String? qualityId;

  /// 当前档位的人话标签（`4k(2160p)` 这类），仅用于显示
  final String? qualityLabel;

  /// 整片文件的字节数。**可以为空**（自建条目、手输直链都没有它）。
  ///
  /// 存在的唯一用途是把「缓存速度」换算成人看得懂的单位：mpv 只会告诉我们
  /// 「已经缓存到播放头前面多少**秒**」（`demuxer-cache-time`），
  /// 想知道多少 KB/s 就得知道这一秒对应多少字节 —— 而
  /// `字节 ÷ 时长 = 平均码率`，两者都在这里了。
  ///
  /// 换了清晰度之后它**不再准确**（不同档位码率不同），但缓冲指示要的只是
  /// 一个数量级，够用。
  final int? sizeBytes;

  /// 起播位置。切换清晰度后重建请求时用它续上，避免每次都从头开始。
  ///
  /// 刷新过期直链时也走这里：播放窗口把当前位置报上来，主窗口取到新链后
  /// 原样填回，于是刷新对用户表现为「卡一下接着播」而不是「从头开始」。
  final Duration startPosition;

  /// 服务端给出的可选清晰度档位。**空列表是有意义的状态** ——
  /// 表示这一条流没有转码梯度，画质入口应当置灰而不是弹一个只有一项的菜单。
  ///
  /// 列表里的 id 与 [qualityId] 同源：菜单上打勾的那一项就是 [qualityId]。
  final List<QualityBrief> qualities;

  /// 同一部作品下的其它可播条目。**空列表 = 没有列表可看**
  /// （电影、自检视频、手输直链）。
  ///
  /// 由主窗口在投递时一并给出，理由见 [PlaylistEntry] 的类文档。
  final List<PlaylistEntry> playlist;

  /// 网盘上**同目录**的字幕文件。空列表 = 这部片子没扫到外挂字幕
  /// （很常见：发布组没给、或者扫描时没开字幕索引）。
  ///
  /// 与 [qualities] 一样，空列表是**有意义的状态**而不是「还没加载」：
  /// 是否显示「网盘字幕」那一组，就看它。
  ///
  /// 注意它与「内嵌字幕轨」是两回事：内嵌轨在播放窗口本地从 mpv 的
  /// `stream.tracks` 读，这里的则是**视频文件之外**的独立文件。
  final List<SubtitleBrief> subtitles;

  /// 一集播完是否自动播下一集。来自设置 `SettingKeys.autoPlayNext`。
  ///
  /// ## 为什么这个开关必须**跟着请求过来**
  ///
  /// 播放窗口跑在另一个引擎里，**读不到设置库**（设置存在主窗口的 SQLite 里，
  /// 见 `SettingsStore` 的类文档）。它自己也没有「设置」这个概念 ——
  /// 想让它知道这一项，只有两条路：每次判断时回主窗口问一次（为一个布尔值
  /// 多一次跨引擎往返，而且要在播完那一刻同步拿到），或者随请求一起带过来。
  /// 后者显然更省，代价只是「播到一半去改设置不生效」—— 那本来也该下次生效。
  ///
  /// ⚠️ 缺省值是 **true**：与 `AppSettings.fromValues` 的判据
  /// （`!= 'false'`）一致。缺省 false 的话，主窗口某次忘了带这个字段就会
  /// 表现成「自动连播整个失效」，而没有任何报错。
  final bool autoPlayNext;

  /// 有片头标识时是否自动跳过片头。来自设置 `SettingKeys.skipIntro`。
  ///
  /// 与 [autoPlayNext] 同样必须随请求过来，缺省值同样是 **true**。
  final bool skipIntro;

  /// 用户**手标**的片头区间（毫秒）。`null` = 没标过。
  ///
  /// ## 为什么手标区间要传过来，而文件章节不用
  ///
  /// 文件章节是播放窗口**自己从 mpv 读**的（`chapter-list`，见
  /// `Mp4Chapters` 那套工具），它手里就有，不必传。
  ///
  /// 手标的那一份存在库里（`MediaWork.introStartMs`），而库在主窗口 ——
  /// 播放窗口拿不到。所以只能随请求过来。
  ///
  /// 优先级：**文件章节优先**（那是发布者给的、与这一集严格对应），
  /// 这一对是兜底（网盘上的剧集绝大多数没有章节）。
  final int? introStartMs;
  final int? introEndMs;

  /// 播原画时是否走本地多路中继（并发预取）。**默认开**。
  ///
  /// ## 为什么必须随请求投过来
  ///
  /// 播放窗口跑在**另一个 Flutter 引擎**里，读不到设置库（与
  /// [autoPlayNext] / [skipIntro] 同一个理由）。不带这一项的话，用户在设置页
  /// 关掉中继只对内置播放页生效，而独立窗口照旧开着 —— 用户不可能知道
  /// 这两条路是分开的，只会觉得开关时灵时不灵。
  final bool streamRelay;

  /// 中继的并发连接数。同样随请求投过来。
  final int relayConnections;

  /// 手标区间；半条标记（只标了起点或终点）当没有。
  ///
  /// 用 `IntroMarker.fromMilliseconds` 而不是在这里各判一次：那个函数还要
  /// 挡住「终点早于起点」这类脏数据，规则只能有一份。
  IntroMarker? get introRange =>
      IntroMarker.fromMilliseconds(introStartMs, introEndMs);

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'title': title,
        'itemId': itemId,
        'headers': headers,
        'qualityId': qualityId,
        'qualityLabel': qualityLabel,
        'startPositionMs': startPosition.inMilliseconds,
        'sizeBytes': sizeBytes,
        'qualities': qualities.map((q) => q.toJson()).toList(),
        'playlist': playlist.map((e) => e.toJson()).toList(),
        'subtitles': subtitles.map((s) => s.toJson()).toList(),
        'autoPlayNext': autoPlayNext,
        'skipIntro': skipIntro,
        'introStartMs': introStartMs,
        'introEndMs': introEndMs,
        'streamRelay': streamRelay,
        'relayConnections': relayConnections,
      };

  /// 从通道参数还原。**任何畸形输入都返回 null，不抛异常** ——
  /// 播放窗口拿到一个解不开的请求时，正确行为是安静地停在空舞台，
  /// 而不是崩掉一个刚起来的窗口。
  static PlayRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;

    final headers = <String, String>{};
    final rawHeaders = raw['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is String && v is String) headers[k] = v;
      }
    }

    // ⚠️ 列表里**逐项**容错：一项读不懂就丢一项，不能让整条请求解不开 ——
    // 那会让「有一个畸形档位」变成「整部片都播不了」。
    final qualities = <QualityBrief>[];
    final rawQualities = raw['qualities'];
    if (rawQualities is List) {
      for (final item in rawQualities) {
        final brief = QualityBrief.fromJson(item);
        if (brief != null) qualities.add(brief);
      }
    }

    final playlist = <PlaylistEntry>[];
    final rawPlaylist = raw['playlist'];
    if (rawPlaylist is List) {
      for (final item in rawPlaylist) {
        final entry = PlaylistEntry.fromJson(item);
        if (entry != null) playlist.add(entry);
      }
    }

    final subtitles = <SubtitleBrief>[];
    final rawSubtitles = raw['subtitles'];
    if (rawSubtitles is List) {
      for (final item in rawSubtitles) {
        final brief = SubtitleBrief.fromJson(item);
        if (brief != null) subtitles.add(brief);
      }
    }

    final rawTitle = raw['title'];
    final rawItemId = raw['itemId'];
    final rawQualityId = raw['qualityId'];
    final rawLabel = raw['qualityLabel'];
    final ms = raw['startPositionMs'];
    final rawAutoNext = raw['autoPlayNext'];
    final rawSkipIntro = raw['skipIntro'];
    final rawIntroStart = raw['introStartMs'];
    final rawIntroEnd = raw['introEndMs'];
    final rawStreamRelay = raw['streamRelay'];
    final rawRelayConnections = raw['relayConnections'];

    return PlayRequest(
      url: url,
      title: rawTitle is String ? rawTitle : '',
      itemId: rawItemId is String ? rawItemId : '',
      headers: headers,
      qualityId: rawQualityId is String && rawQualityId.isNotEmpty
          ? rawQualityId
          : null,
      qualityLabel: rawLabel is String ? rawLabel : null,
      startPosition: Duration(milliseconds: ms is int && ms > 0 ? ms : 0),
      sizeBytes: raw['sizeBytes'] is int ? raw['sizeBytes'] as int : null,
      qualities: qualities,
      playlist: playlist,
      subtitles: subtitles,
      // 只有**显式 false** 才关掉（判据与 `AppSettings.fromValues` 一致）。
      // 写成 `rawAutoNext is bool && rawAutoNext` 的话，主窗口某次漏带这个
      // 字段就会静默关掉连播与跳片头 —— 而这两项在设置页上是**开着**的。
      autoPlayNext: rawAutoNext != false,
      skipIntro: rawSkipIntro != false,
      // 非正数当没有：0 秒的片头没有意义，而写进去会让 `IntroMarker`
      // 的 `isValid` 之外多一条隐式规则。
      introStartMs: rawIntroStart is int && rawIntroStart > 0
          ? rawIntroStart
          : null,
      introEndMs:
          rawIntroEnd is int && rawIntroEnd > 0 ? rawIntroEnd : null,
      // 与 autoPlayNext / skipIntro 同一套判据：只有**显式 false** 才关。
      // 写成 `rawStreamRelay == true` 的话，主窗口某次漏带这个字段就会静默
      // 关掉中继 —— 而设置页上它是开着的。
      streamRelay: rawStreamRelay != false,
      // 越界值夹回来而不是原样信：通道那头给个 0 会让中继直接不下数据
      // （`_take` 永远挑不出块），表现是「播不了」而不是「慢」。
      relayConnections: rawRelayConnections is int
          ? rawRelayConnections.clamp(1, 16).toInt()
          : 8,
    );
  }

  /// 供日志使用的**脱敏**摘要。
  ///
  /// ⚠️ 绝不能把 [url] 或 [headers] 直接打进日志：直链带签名查询串，
  /// headers 里有 Cookie。诊断日志是给用户复制粘贴用的，不能成为泄露渠道。
  String describe() {
    final q = qualityLabel;
    return q == null ? title : '$title（$q）';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlayRequest &&
          other.url == url &&
          other.title == title &&
          other.itemId == itemId &&
          other.qualityId == qualityId &&
          other.qualityLabel == qualityLabel &&
          other.startPosition == startPosition &&
          other.sizeBytes == sizeBytes &&
          other.autoPlayNext == autoPlayNext &&
          other.skipIntro == skipIntro &&
          other.introStartMs == introStartMs &&
          other.introEndMs == introEndMs &&
          other.streamRelay == streamRelay &&
          other.relayConnections == relayConnections &&
          mapEquals(other.headers, headers) &&
          listEquals(other.qualities, qualities) &&
          listEquals(other.playlist, playlist) &&
          listEquals(other.subtitles, subtitles);

  @override
  int get hashCode => Object.hash(
        url,
        title,
        itemId,
        qualityId,
        qualityLabel,
        startPosition,
        sizeBytes,
        autoPlayNext,
        skipIntro,
        introStartMs,
        introEndMs,
        streamRelay,
        relayConnections,
        Object.hashAllUnordered(
          headers.entries.map((e) => Object.hash(e.key, e.value)),
        ),
        Object.hashAll(qualities),
        Object.hashAll(playlist),
        Object.hashAll(subtitles),
      );

  @override
  String toString() => 'PlayRequest(${describe()})';
}

/// 播放窗口 → 主窗口的进度回报。
///
/// 它存在的唯一理由：**「最近播放」不能因为换了播放方式就失效**。
///
/// 内置播放页那条路，进度落库是主窗口的 `PlaybackController.onPositionTick`
/// 在调 `markPlayed`；而独立窗口这条路播放发生在另一个引擎里，主窗口的控制器
/// 根本没被 `open()` 过，那个回调永远不会触发 —— 于是 `lastPlayedAt` 不更新，
/// 「最近播放」排序与已看标记都停在上一次用内置播放页的时候。
///
/// ⚠️ `markPlayed` 落的是**时间戳**，不是播放位置（见
/// `MediaRepository.markPlayed`：它只写 `lastPlayedAt`，库里目前没有存续播
/// 位置的字段）。所以 [position] / [duration] 现在是**随报告一起带上但还没被
/// 消费**的：`position` 用来驱动节流（见 [ProgressThrottle]），两个字段一起
/// 留着是为了将来真要存续播位置时不必再改一次协议。
@immutable
class PlaybackProgressReport {
  const PlaybackProgressReport({
    required this.itemId,
    required this.position,
    this.duration = Duration.zero,
  });

  final String itemId;
  final Duration position;
  final Duration duration;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'positionMs': position.inMilliseconds,
        'durationMs': duration.inMilliseconds,
      };

  /// 畸形输入返回 null，不抛异常。**没有 itemId 就没有意义** ——
  /// 主窗口拿到它也不知道该更新哪一行。
  static PlaybackProgressReport? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;

    final positionMs = raw['positionMs'];
    final durationMs = raw['durationMs'];

    return PlaybackProgressReport(
      itemId: itemId,
      position: Duration(
        milliseconds: positionMs is int && positionMs > 0 ? positionMs : 0,
      ),
      duration: Duration(
        milliseconds: durationMs is int && durationMs > 0 ? durationMs : 0,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackProgressReport &&
          other.itemId == itemId &&
          other.position == position &&
          other.duration == duration;

  @override
  int get hashCode => Object.hash(itemId, position, duration);

  @override
  String toString() =>
      'PlaybackProgressReport($itemId, ${position.inSeconds}s/${duration.inSeconds}s)';
}

/// 播放窗口 → 主窗口的「这条链失效了，再给我一条」请求。
///
/// 网盘的直链都是**带签名的临时 URL**，几十分钟就过期。过期后 mpv 在**下一次
/// 发起请求时**才会失败（seek 会重新发 Range 请求，所以最常见的表现是
/// 「播到一半拖进度条就报错」），而此时播放窗口手里只有一条死链 ——
/// 它自己没有重新取链的能力（没有凭证、也不该有）。
///
/// 所以这条回路的形状是：播放窗口报「我是谁、什么档位、播到哪了」，
/// 主窗口拿新链回来。
///
/// ⚠️ 刻意**不带 URL**：主窗口只需要知道「哪一项」，自己去重新取链。
/// 把旧链带回去只会让人忍不住去「复用」它。
@immutable
class TicketRefreshRequest {
  const TicketRefreshRequest({
    required this.itemId,
    this.qualityId,
    this.position = Duration.zero,
  });

  final String itemId;

  /// 当前档位标识，原样带回，保证刷新后还是同一档。
  final String? qualityId;

  /// 刷新发生时的播放位置。主窗口取到新链后把它填进
  /// [PlayRequest.startPosition]，刷新才不会把用户丢回片头。
  final Duration position;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'qualityId': qualityId,
        'positionMs': position.inMilliseconds,
      };

  /// 畸形输入返回 null。**没有 itemId 就刷不了**。
  static TicketRefreshRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;

    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;

    final qualityId = raw['qualityId'];
    final ms = raw['positionMs'];

    return TicketRefreshRequest(
      itemId: itemId,
      qualityId: qualityId is String && qualityId.isNotEmpty ? qualityId : null,
      position: Duration(milliseconds: ms is int && ms > 0 ? ms : 0),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TicketRefreshRequest &&
          other.itemId == itemId &&
          other.qualityId == qualityId &&
          other.position == position;

  @override
  int get hashCode => Object.hash(itemId, qualityId, position);

  @override
  String toString() =>
      'TicketRefreshRequest($itemId, ${qualityId ?? "-"}, ${position.inSeconds}s)';
}

/// 播放窗口 → 主窗口的「把这部作品的片头区间存下来」请求。
///
/// ## 为什么标记要回主窗口写
///
/// 片头区间存在 `MediaWork.introStartMs` —— 库在主窗口。播放窗口刻意不碰
/// 数据库（见 `PlayerWindowApp` 的类文档），所以它只能把「标了什么」报回来。
///
/// ## 为什么用 `itemId` 而不是 `groupKey`
///
/// 与 [TicketRefreshRequest] 同一条：播放窗口手里只有 [PlaylistEntry.itemId]
/// （它连 `groupKey` 这个概念都没有）。**由主窗口按 itemId 查库补全** ——
/// 让播放窗口去拼一个它不认识的键，就是把一个已经结构化的信息降级成字符串。
///
/// ## 三个动作，与仓储的三个方法一一对应
///
///   - [clear] 为 true → 清掉整个手标区间（**优先于**另两个字段）；
///   - [startMs] / [endMs] 非空 → 各写各的。允许只写一半 —— 用户是先标起点、
///     播一段、再标终点的，中间那段时间库里存着「半条标记」是正常状态
///     （`IntroMarker.fromMilliseconds` 会把半条当没有，所以不会误跳）。
@immutable
class IntroRangeSaveRequest {
  const IntroRangeSaveRequest({
    required this.itemId,
    this.startMs,
    this.endMs,
    this.clear = false,
  });

  /// 本地索引库里这一项的 id（`provider:fileId`）。
  final String itemId;

  /// 新的片头起点（毫秒）。`null` = 不改这一半。
  final int? startMs;

  /// 新的片头终点（毫秒）。`null` = 不改这一半。
  final int? endMs;

  /// 清掉整个手标区间（文件里的章节不受影响）。
  final bool clear;

  /// 三个字段全空 = 什么都不用做。主窗口据此**直接返回**，不白跑一次写库。
  bool get isEmpty => !clear && startMs == null && endMs == null;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'startMs': startMs,
        'endMs': endMs,
        'clear': clear,
      };

  /// 畸形输入返回 null。**没有 itemId 就不知道往哪一行写**。
  static IntroRangeSaveRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;

    final start = raw['startMs'];
    final end = raw['endMs'];
    return IntroRangeSaveRequest(
      itemId: itemId,
      // 非正数当没给：0 秒的片头没有意义（与 `PlayRequest.fromJson` 同口径）。
      startMs: start is int && start > 0 ? start : null,
      endMs: end is int && end > 0 ? end : null,
      clear: raw['clear'] == true,
    );
  }

  @override
  String toString() =>
      'IntroRangeSaveRequest($itemId, ${clear ? "清除" : "$startMs~$endMs"})';
}

/// 主窗口回答 [IntroRangeSaveRequest] 时给出的**落库之后的真实值**。
///
/// 为什么不回一个 bool：播放窗口拿到 `true` 之后仍然不知道「现在到底存的是
/// 什么」，只能自己照着请求猜 —— 而它猜不出「只标了起点」这种半条状态在库里
/// 是被接受还是被拒。把值回给它，界面就能显示真相。
@immutable
class IntroRangeSnapshot {
  const IntroRangeSnapshot({this.startMs, this.endMs});

  final int? startMs;
  final int? endMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'introStartMs': startMs,
        'introEndMs': endMs,
      };

  static IntroRangeSnapshot fromJson(Object? raw) {
    if (raw is! Map) return const IntroRangeSnapshot();
    final start = raw['introStartMs'];
    final end = raw['introEndMs'];
    return IntroRangeSnapshot(
      startMs: start is int && start > 0 ? start : null,
      endMs: end is int && end > 0 ? end : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IntroRangeSnapshot &&
          other.startMs == startMs &&
          other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'IntroRangeSnapshot(${startMs ?? "-"}~${endMs ?? "-"})';
}

/// 进度回报的节流器。
///
/// mpv 的 `position` 是每 ~100ms 一条的高频流，不能每条都跨引擎发一次 ——
/// 那会把方法通道变成每秒 10 次的噪音源，而续播位置只需要精确到秒。
///
/// 用「**整十秒边界**」当触发条件：天然节流，且不需要额外的计时器。
/// 与 `PlaybackController._maybeTickPosition` 是同一套办法 —— 两边各自
/// 独立实现是有意的：它们跨越了引擎边界，将来一边改节流粒度不该牵连另一边。
class ProgressThrottle {
  ProgressThrottle({this.intervalSeconds = 10});

  final int intervalSeconds;

  int _lastReportedSecond = -1;

  /// 喂一个位置；返回**需要上报**的位置，不需要上报时返回 null。
  Duration? accept(Duration position) {
    if (intervalSeconds <= 0) return null;
    final second = position.inSeconds;
    // 0 秒是「刚打开」，报上去只会把上次的进度覆盖成 0。
    if (second <= 0) return null;
    if (second % intervalSeconds != 0) return null;
    if (second == _lastReportedSecond) return null;
    _lastReportedSecond = second;
    return position;
  }

  /// 换片时重置。
  ///
  /// 不重置的话有个很难查的症状：新片恰好停在与上一部片**同一个**整十秒上时，
  /// 那一次回报会被当成重复而吞掉。
  void reset() => _lastReportedSecond = -1;
}

/// 「刷新直链」的重试闸。
///
/// 它防的是一个很容易写出来的死循环：
///
/// ```
/// mpv 报错 → 刷新直链 → 重开 → 还是报错 → 再刷新 → …
/// ```
///
/// 而**非时效性**的失败（文件损坏、编码不支持、网盘侧删了）刷新多少次都不会
/// 好 —— 那只会变成每几秒一次的取链请求 + 窗口反复重开。所以自动刷新必须
/// 有上限。
///
/// 光有上限还不够：一部长片里撞上两三次过期是正常的，用满之后整场都不能再
/// 刷新就太脆。所以要能**判定这次刷新是有效的**并清零。
///
/// 判定口径不能是「open 没抛异常」—— 失效的直链照样会被 mpv 接受，
/// 然后在解复用阶段才报错，那时 `open` 早就返回了。所以用两个条件同时成立：
///
///   1. 从刷新那一刻起，**时间**过去了至少 [healthyWindow]（期间没再报错）；
///   2. 位置**确实往前走了**至少 [healthyWindow]（不是停在原地反复重连）。
///
/// 条件 2 单看会有个假阳性：用户往后拖进度条会让位置一次性跳很远。
/// 条件 1 把这种跳变排除掉 —— 真出问题的话，mpv 在几秒内就会再报错。
class TicketRefreshGuard {
  TicketRefreshGuard({
    this.maxAttempts = 3,
    this.healthyWindow = const Duration(seconds: 30),
    this.minInterval = const Duration(seconds: 10),
  });

  /// 连续自动刷新的上限
  final int maxAttempts;

  /// 「这次刷新有效」所需的观察窗口
  final Duration healthyWindow;

  /// 两次**自动**刷新之间的最小间隔（去抖窗口）。
  ///
  /// ## 为什么必须有
  ///
  /// 一次 seek 失败不会只报一条 HTTP 403。ffmpeg 的 http 层带 reconnect
  /// 重试，mpv 又可能在 demux / cplayer 两层各报一次 —— 这些是**同一次故障
  /// 的回声**，间隔常在毫秒级。没有去抖的话，3 次自动刷新额度会被同一批错误
  /// 在几百毫秒内烧完，用户后面再遇到真的过期就一次额度都不剩了。
  ///
  /// ## 10 秒是怎么定的
  ///
  /// 刷新本身的往返是百毫秒级；ffmpeg 的 reconnect 退避在秒级。10 秒足够把
  /// 一次故障的全部回声收干净。而「刚刷完又立刻过期」基本不可能 ——
  /// 新链是刚签出来的，所以这个窗口不会挡住真正的第二次过期。
  final Duration minInterval;

  int _attempts = 0;
  Duration? _resumeAt;
  DateTime? _refreshedAt;

  /// 上一次**自动**刷新被批准的时刻。手动刷新走 [reset]，不记在这里。
  DateTime? _lastAutoAt;

  int get attempts => _attempts;

  bool get exhausted => _attempts >= maxAttempts;

  /// 申请一次自动刷新。
  ///
  /// 返回 true = 批准（已计数）；false = 拒绝，且**拒绝不消耗次数**。
  ///
  /// ⚠️ 返回 false 有**两种**原因，调用方必须分开对待：
  ///   - [exhausted] 为 true → 额度用满。该告诉用户「自动重试停了，可以手动」。
  ///   - [exhausted] 为 false → 只是还在 [minInterval] 冷却里。那是一次去抖，
  ///     **不该弹提示打扰用户** —— 一次故障的回声会连着弹好几条。
  ///
  /// [atPosition] 是刷新发生时的位置，[now] 是刷新时刻 —— 两者都用来在后面
  /// 判定这次刷新有没有用。**时钟由调用方注入**，否则这个判定只能靠 `sleep` 测。
  bool begin(Duration atPosition, {required DateTime now}) {
    if (exhausted) return false;
    final last = _lastAutoAt;
    if (last != null && now.difference(last) < minInterval) return false;
    _attempts++;
    _lastAutoAt = now;
    _resumeAt = atPosition;
    _refreshedAt = now;
    return true;
  }

  /// 喂当前播放位置与时刻。若这次刷新已被证明有效，清零并返回 true。
  ///
  /// 返回「是否刚刚清零」而不是新的计数，是为了让调用方只在真正恢复的那一次
  /// 打一行日志 —— 否则会跟着 position 流刷屏。
  bool observe(Duration position, {required DateTime now}) {
    final mark = _resumeAt;
    final at = _refreshedAt;
    if (mark == null || at == null) return false;
    if (now.difference(at) < healthyWindow) return false;
    if (position <= mark + healthyWindow) return false;

    _resumeAt = null;
    _refreshedAt = null;
    _lastAutoAt = null;
    _attempts = 0;
    return true;
  }

  /// 重置闸门。
  ///
  /// [now] 传了就把冷却窗口也一并重新起算；不传则**清掉**冷却。
  ///
  /// 两种调用场景要的东西正好相反，所以必须区分：
  ///   - **换片**（`_playRequest` / `_playRaw`）：`reset()`。新片是全新的流，
  ///     跟上一部片的冷却没有关系，清掉。
  ///   - **用户手动重新取链**：`reset(now: ...)`。手动刷新**照样会招来旧流
  ///     那批 403 回声**，不重新起冷却的话它们立刻就会把刚清空的额度烧掉。
  void reset({DateTime? now}) {
    _attempts = 0;
    _resumeAt = null;
    _refreshedAt = null;
    _lastAutoAt = now;
  }
}

// ---------------------------------------------------------------------------
// 从 mpv 日志里认出「直链过期」
// ---------------------------------------------------------------------------

/// ffmpeg 报 HTTP 状态码的格式串，形如 `HTTP error 403 Forbidden`。
///
/// **只认 4xx，不认 5xx**：4xx 是「这个请求不被接受」—— 签名过期（401/403）、
/// 缺 Cookie（夸克直链缺头会回 412）、资源被拒（404/410），这些「重新取一条链」
/// 都有救；5xx 是服务端自己出问题，重新取链解决不了，交给 mpv 自己的 reconnect
/// 更合适，硬刷只会白烧重试额度。
///
/// 这条格式串是从**产物里查出来的**（`Avformat.framework` 内有
/// `HTTP error %d %s`），不是猜的；同一个库里没有别的带状态码的报错措辞。
final RegExp _http4xxPattern = RegExp(r'http error 4\d\d', caseSensitive: false);

/// 判定一条 mpv 日志是不是「HTTP 4xx」。
///
/// ## 实测记录 —— 不要凭读源码的推断改这里
///
/// 下面这段是**跑出来的**。方法：用 Python ctypes 把产物里的 `Mpv.framework`
/// 拉起来（`DYLD_FRAMEWORK_PATH` 指向 app 的 Frameworks 目录），起一个「任何
/// 请求都回 403」的本地服务，让**真的** libmpv 去拉，打印它吐出的每一条日志。
///
/// ```
/// level='v'     prefix='ffmpeg'  text='Opening http://…'
/// level='warn'  prefix='ffmpeg'  text='http: HTTP error 403 Forbidden'
/// level='error' prefix='stream'  text='Failed to open http://… .'
/// level='v'     prefix='cplayer' text='Opening failed or was aborted: http://…'
/// ```
///
/// 三条结论，**每条都跟我最初读源码时的判断不一样**：
///
/// 1. **`HTTP error 403` 是 `warn` 级，不是 `error` 级。** 而
///    `mpv_request_log_messages` 的语义是「该级别**及以上严重**的消息才发」。
///    media_kit 默认请求 `error`，所以这条消息**根本不会被发到 Dart** ——
///    连它自己的前缀过滤都轮不到。这就是为什么 `PlayerWindowApp._ensurePlayer`
///    必须把 `PlayerConfiguration.logLevel` 抬到 `MPVLogLevel.warn`。
/// 2. 真正到达 `stream.error` 的是 `prefix='stream'` 的 `Failed to open <url>.`
///    —— prefix 是 `stream` 而**不是** `cplayer`（`cplayer` 那条是 `v` 级，
///    同样收不到）。而且它只在**打开阶段**失败时出现。
/// 3. 正文里带 `http: ` 前缀 —— mpv 把 av_log 的 context 名拼进了 text。
///
/// ### 场景二：流已建立、播放途中才 403（也就是最常见的那种）
///
/// 同一套方法，但第一个响应「声明完整长度、只给 64KB 就断线」，再 seek 到远处：
///
/// ```
/// level='warn'  prefix='ffmpeg'         text='http: HTTP error 403 Forbidden'
/// level='warn'  prefix='ffmpeg'         text='http: Will reconnect at 65536 in 0 second(s), error=Input/output error.'
/// level='error' prefix='ffmpeg'         text='http: Stream ends prematurely at 65536, should be 9799538'
/// level='error' prefix='ffmpeg'         text='Seek failed (to 8162141, size -78)'
/// level='error' prefix='ffmpeg/demuxer' text='mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset …: partial file'
/// ```
///
/// **这个场景下 `stream.error` 一条都收不到。** 逐条对着 media_kit 的规则看：
/// `ffmpeg` 前缀要求 text 以 `tcp:` 开头，而它们要么以 `http:` 开头、要么以
/// `Seek` 开头；`ffmpeg/demuxer` 这个前缀根本不在白名单里。所以**唯一通路就是
/// 本函数 + 抬到 warn 的 `stream.log`** —— 这正是 `_ensurePlayer` 那行配置
/// 不能省的原因：少了它，用户实际会遇到的那种过期**一次都检测不到**。
///
/// 还有一条：一次 403 会**连出十几条**（ffmpeg 的 reconnect 退避是
/// 0s / 1s / 3s / 7s…，实测一次故障刷出 16 个请求）。这就是
/// [TicketRefreshGuard] 必须有冷却窗口的直接原因 —— 没有它，3 次自动刷新额度
/// 会在几秒内被同一批回声烧完。
///
/// ## 分工
///
/// 两条流各管一段，**刻意不重叠**：
///   - `stream.error` → `_onPlayerError`：管 `stream` 前缀的 `Failed to open`；
///   - `stream.log` → 本函数：管 `stream.error` **看不到**的 HTTP 4xx。
///
/// ## 为什么按内容匹配而不是按 prefix
///
/// 实测见到的 prefix 是 `ffmpeg`，但 mpv 给 ffmpeg 日志挂什么 prefix 取决于
/// av_log 的 context 名（也可能是 `http`）。状态码本身一定在正文里 ——
/// 按正文判，两种布局都命中。
bool isHttp4xxLog(String text) => _http4xxPattern.hasMatch(text);

// 字幕那条判定（`isSubtitleDiagnosticLog`）**不在这里**，在
// `core/utils/mpv_subtitle_log.dart`：内置播放页走 `PlaybackController`
// （`domain/` 层），那一层不能 import 这个文件。两边用的是同一份实现，
// 别再复制一份到这里。

/// URL 匹配：`http://` 或 `https://` 起，一直吃到空白字符。
///
/// 播放窗口问「这一条是不是已经没了」，主窗口的答复。
///
/// ## 为什么它得把**文案要用的字段**都带过来
///
/// 播放窗口跑在另一个引擎里，没有 `MediaItem`、也没有 `MediaWork`（库与仓储
/// 都装在主窗口）。而「只移除这一集 / 移除整部剧《X》（24 个文件）」这几个
/// 按钮的措辞由这两个实体算出来 —— 让播放窗口自己拼一份，两个入口的措辞
/// 迟早分叉，用户会觉得这个移除功能时灵时不灵。
///
/// 所以主窗口把算好的**字段**送过来，播放窗口拿它们组装同一个
/// [MissingMediaPlan]，渲染同一个对话框。规则仍然只有一份。
@immutable
class MissingMediaBrief {
  const MissingMediaBrief({
    required this.itemId,
    required this.itemTitle,
    required this.itemPath,
    required this.workTitle,
    required this.kind,
    required this.fileCount,
  });

  /// 本地索引库里这一项的 id。移除时原样报回主窗口。
  final String itemId;

  final String itemTitle;
  final String itemPath;
  final String workTitle;

  /// `MediaKind.name`。认不出来时退回 `unknown` —— 那只会让按钮写
  /// 「这部作品」，比解不开整条消息强。
  final String kind;

  final int fileCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'itemTitle': itemTitle,
        'itemPath': itemPath,
        'workTitle': workTitle,
        'kind': kind,
        'fileCount': fileCount,
      };

  /// 畸形输入返回 null —— 播放窗口拿到 null 就当成「主窗口也不知道」，
  /// 如实提示而不是弹一个字段全空的对话框。
  static MissingMediaBrief? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;
    final itemTitle = raw['itemTitle'];
    final workTitle = raw['workTitle'];
    if (itemTitle is! String || workTitle is! String) return null;
    final count = raw['fileCount'];
    final kindName = raw['kind'];
    return MissingMediaBrief(
      itemId: itemId,
      itemTitle: itemTitle,
      itemPath: raw['itemPath'] is String ? raw['itemPath'] as String : '',
      workTitle: workTitle,
      kind: kindName is String ? kindName : MediaKind.unknown.name,
      fileCount: count is int ? count : 1,
    );
  }

  MissingMediaPlan toPlan() => MissingMediaPlan(
        itemTitle: itemTitle,
        itemPath: itemPath,
        workTitle: workTitle,
        kind: MediaKind.values.firstWhere(
          (k) => k.name == kind,
          orElse: () => MediaKind.unknown,
        ),
        fileCount: fileCount,
      );

  @override
  String toString() =>
      'MissingMediaBrief($itemId, $itemTitle, $fileCount 个文件)';
}

/// 播放窗口 → 主窗口：「按这个范围把它从媒体库里删掉」。
@immutable
class MissingMediaRemoval {
  const MissingMediaRemoval({
    required this.itemId,
    required this.scope,
  });

  final String itemId;
  final MediaRemovalScope scope;

  Map<String, Object?> toJson() => <String, Object?>{
        'itemId': itemId,
        'scope': scope.name,
      };

  /// 畸形输入返回 null。**没有 itemId 就不知道删哪一行**；`scope` 认不出来
  /// 时退回「只删这一个」—— 那是**代价更小**的那一种，猜错也比整部删掉强。
  static MissingMediaRemoval? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final itemId = raw['itemId'];
    if (itemId is! String || itemId.isEmpty) return null;
    final scopeName = raw['scope'];
    return MissingMediaRemoval(
      itemId: itemId,
      scope: MediaRemovalScope.values.firstWhere(
        (s) => s.name == scopeName,
        orElse: () => MediaRemovalScope.singleItem,
      ),
    );
  }

  @override
  String toString() => 'MissingMediaRemoval($itemId, ${scope.name})';
}

/// `\S+` 会把结尾的句号一起吃掉 —— 换掉就好，见 [redactUrls] 里的补回。
final RegExp _urlPattern = RegExp(r'https?://\S+', caseSensitive: false);

/// 把文本里的直链抹掉，只留主机名。
///
/// ## 为什么必须有
///
/// mpv 的二级报错是 `Failed to open %s.`，那个 `%s` 是**完整 URL** —— 而夸克
/// 直链的签名就在查询串里。这条消息会一路走到 `diag.warn` 与「重新取链」的
/// 原因字段，也就是**落进诊断日志文件**。而诊断日志是给用户复制粘贴用的
/// （诊断页还专门做了「复制日志路径」按钮），绝不能成为签名泄露渠道。
///
/// 这与 `_openStream` 里「日志不打 url、请求头只打键名」是同一条规矩，
/// 区别只是那条报错**不是我们拼的**，只能事后抹。
///
/// 保留主机名是因为它有诊断价值（能看出是哪个 CDN 节点出的问题）；路径与
/// 查询串对排查没用、对泄露有用，所以一起抹掉。
String redactUrls(String message) {
  return message.replaceAllMapped(_urlPattern, (match) {
    final raw = match[0]!;
    final scheme =
        raw.toLowerCase().startsWith('http://') ? 'http://' : 'https://';
    // `\S+` 连结尾的句号都吃进来了。补回去，免得日志出现
    // 「…已抹去）」这种看起来像被截断的东西。
    final trailing = raw.endsWith('.') ? '.' : '';
    final host = Uri.tryParse(raw)?.host ?? '';
    if (host.isEmpty) return '$scheme（直链已抹去）$trailing';
    return '$scheme$host/…（直链签名已抹去）$trailing';
  });
}
