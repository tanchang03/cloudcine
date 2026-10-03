import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/player_audio_effect.dart';
import '../../domain/entities/playback_preference.dart';
import 'player_protocol.dart';
import 'window_launch.dart';

/// 主窗口 ↔ 播放窗口的跨引擎通道。
///
/// 用 [ChannelMode.bidirectional] 是刻意的：插件允许**最多两个**引擎注册同一个
/// 通道名，且只有这两个能互相调用 —— 正好是「主窗口 + 一个播放窗口」的形状。
/// 换成 `unidirectional` 会让任何第三个窗口都能打进来，没有必要。
///
/// ⚠️ 代价：如果关掉的播放窗口其引擎没有真正销毁（见 `player_window_app.dart`
/// 里 `dispose()` 的探针注释），它的通道注册就不会注销，**再开一个播放窗口会
/// 撞 `CHANNEL_LIMIT_REACHED`**。那条报错出现即等于证明「引擎没销毁」。
const WindowMethodChannel playerWindowChannel = WindowMethodChannel(
  'cloudcine/player',
  mode: ChannelMode.bidirectional,
);

/// 协议方法名。集中在这里，免得主窗口和播放窗口各写一份字符串。
abstract final class PlayerBridgeMethod {
  /// 播放窗口 → 主窗口：「你在吗」。
  ///
  /// 它同时是**通道连通性**的判据：通道不通时 `invokeMethod` 会抛
  /// [WindowChannelException]，而那是唯一能证明两个引擎确实连上的证据 ——
  /// 引擎起得来、插件注册得上，都不代表通道通。
  static const String ping = 'ping';

  /// 主窗口 → 播放窗口：「播这个」。参数是 [PlayRequest.toJson]。
  static const String play = 'play';

  /// 播放窗口 → 主窗口：「开窗时那个请求给我」。
  ///
  /// 新窗口必须走这条路，不能由主窗口直接推 —— 原因见 [_pendingPlayRequest]。
  static const String fetchPendingPlay = 'fetchPendingPlay';

  /// 播放窗口 → 主窗口：「我看到这里了」。参数是
  /// [PlaybackProgressReport.toJson]。
  static const String reportProgress = 'reportProgress';

  /// 播放窗口 → 主窗口：「这条直链失效了，再给我一条」。参数是
  /// [TicketRefreshRequest.toJson]，返回 [PlayRequest.toJson] 或 null。
  ///
  /// 方向是**播放窗口发起**而不是主窗口定时推：直链过期只在下一次真正发起
  /// 请求时才暴露（最典型的是拖进度条触发 Range 请求），提前推一条新链既没有
  /// 触发时机，也会打断正在播的流。所以让它坏在哪、修在哪。
  static const String refreshTicket = 'refreshTicket';

  /// 播放窗口 → 主窗口：「把这条网盘字幕的正文给我」。
  ///
  /// 参数是 `{'fileId': …}`，返回**已解码的 UTF-8 文本**，取不到时返回 null。
  ///
  /// ## 为什么必须过主窗口
  ///
  /// 两个硬约束，任何一个不解决都表现为「外挂字幕用不了」：
  ///
  ///   1. **请求头**。夸克直链缺 Cookie 一律 412，而 `media_kit` 的
  ///      `SubtitleTrack.uri` / `.data` **都没有请求头参数**（视频可以用
  ///      `Media(uri, httpHeaders:)`，字幕不行）。所以字节只能我们自己取。
  ///   2. **编码**。中文外挂字幕大量是 GBK，mpv 的自动探测经常失败 —— 满屏乱码。
  ///      正文在主窗口用 `decodeTextBytes`（先严格 UTF-8、失败再 GBK）解码成
  ///      UTF-8 文本再过来，这一类问题才根治。
  ///
  /// 传**文本**而不是字节：跨引擎通道传的是 `Uint8List` 也能做到，但解码要在
  /// 有 `fast_gbk` 的那一侧做，而播放窗口刻意不背这些依赖。
  static const String fetchSubtitleText = 'fetchSubtitleText';

  /// 播放窗口 → 主窗口：「把这张网盘缩略图给我」，回**本地文件路径**。
  ///
  /// 参数是 `{'itemId': <String>, 'url': <String>}`，返回本地绝对路径；
  /// 取不到时返回 `null`（播放窗口据此退回占位图）。
  ///
  /// ## 为什么缩略图也要过主窗口
  ///
  /// 与 [fetchSubtitleText] 同一条理由：夸克缩略图**缺 Cookie 一律 401**，
  /// 而且它每个响应轮换 `__puus`，陈旧 Cookie 是 `401 auth expired`。播放
  /// 窗口拿不到凭证，也没有主窗口那套 HTTP 配置（代理、超时、限流）。
  ///
  /// ⚠️ 顺带一个不那么明显的好处：主窗口那边有 `PosterCache`，**媒体库里
  /// 已经显示过的缩略图早就落盘了**。于是「打开剧集面板」这一步对大部分
  /// 条目是零网络 —— 这是把图交给主窗口取、而不是把请求头塞进 `PlayRequest`
  /// 让播放窗口自己下的关键差别。
  ///
  /// ## 为什么回**路径**而不是字节
  ///
  /// `PosterCache` 按 URL 落盘、并且把并发请求合成一次。回路径等于让剧集
  /// 面板白捡两层缓存（磁盘 + 播放窗口自己的 `Image` 缓存）；回字节的话
  /// 每次开窗都得重下，而一部剧几十集就是几十次带 Cookie 的往返。
  ///
  /// [itemId]（`quark:<fid>`）只是缓存文件名的键（见
  /// `PosterCache.fileNameFor`）：用 fid 而不是整条 URL 当键，缓存文件才
  /// 可读、也才在换了图片地址时仍然指得准同一集。
  static const String fetchThumbnail = 'fetchThumbnail';

  /// 播放窗口 → 主窗口：「去字幕站上搜一下」。
  ///
  /// 参数是 [SubtitleSearchRequest.toJson]，返回 [OnlineSubtitleBrief] 的
  /// `toJson` 列表（没搜到时是**空列表**，不是 null —— 与「请求失败」区分开）。
  ///
  /// 走主窗口的理由与 [fetchSubtitleText] 一样：Api-Key 在设置里、HTTP 客户端
  /// 在主窗口，而播放窗口不该为了一条字幕去背一个字幕站客户端。
  ///
  /// ⚠️ **搜索失败是抛异常，不是返回空列表**。这条区别是刻意的：返回空列表
  /// 会被用户读成「这部片没有字幕」，而实际可能是 Api-Key 没配对 —— 两个
  /// 完全不同的排查方向。异常里的 `code` 是失败种类（`opensubtitles/badApiKey`
  /// 这种，给日志看），`message` 是一句能直接显示给用户的中文。
  static const String searchOnlineSubtitles = 'searchOnlineSubtitles';

  /// 播放窗口 → 主窗口：「把这条在线字幕的正文给我」。
  ///
  /// 参数是 `{'fileId': <int>}`，返回已解码的文本，失败返回 null。
  static const String fetchOnlineSubtitle = 'fetchOnlineSubtitle';

  /// 播放窗口 → 主窗口：「把这部作品的片头区间存下来」。
  ///
  /// 参数是 [IntroRangeSaveRequest.toJson]，返回 [IntroRangeSnapshot.toJson]
  /// （**落库之后的真实值**，不是一个 bool —— 理由见那个类的文档）。
  ///
  /// ## 为什么标记必须回主窗口写
  ///
  /// 片头区间落在 `MediaWork.introStartMs` 上，而库与仓储都装在主窗口。
  /// 播放窗口刻意不碰数据库（它跑在另一个引擎里，连 `groupKey` 都不知道）。
  /// 所以「标记片头」这个动作在那边只是**把值报回来**。
  static const String saveIntroRange = 'saveIntroRange';

  /// 播放窗口 → 主窗口：「这一条是不是已经没了？能删到哪一层？」
  ///
  /// 参数是 `{'itemId': …}`，返回 [MissingMediaBrief.toJson]，或 `null`
  /// （主窗口查不到这一条 —— 那时播放窗口应当如实提示，不要弹对话框）。
  ///
  /// ## 为什么要有这一条，而不是让播放窗口自己查
  ///
  /// 走的是 [refreshTicket] 失败之后的第二步：那一步只能告诉播放窗口
  /// 「取链失败了」，而「失败是不是因为文件没了、以及能删到哪一层」要读库
  /// 才知道。库在主窗口，播放窗口连 `groupKey` 都没有。
  static const String queryMissingMedia = 'queryMissingMedia';

  /// 播放窗口 → 主窗口：「按这个范围把它删掉」。
  ///
  /// 参数是 [MissingMediaRemoval.toJson]，返回 `bool`（是否真的动了库）。
  ///
  /// 删除**必须由主窗口执行**：它要删的是 `media_items` 与 `media_works`
  /// 两行，而播放窗口刻意不碰数据库 —— 与 [saveIntroRange] 同一条边界。
  static const String removeMissingMedia = 'removeMissingMedia';

  /// 播放窗口 → 主窗口：「用户把音效换成了这一档，存下来」。
  ///
  /// 参数是 `{'value': 'auto' | 'upmix' | 'stereo' | 'passthrough'}`，返回
  /// `null`（**不返回值**：这是一条单向通知，播放窗口那边音效早已生效，
  /// 不需要等落库结果）。
  ///
  /// ## 为什么这一条也必须回主窗口写
  ///
  /// 与 [saveIntroRange] 同一条边界：设置库装在主窗口，播放窗口跑在另一个
  /// 引擎里读不到它。不回传的话，用户在播放窗口里选的音效只在**这一次**有效
  /// —— 下次开窗口又变回设置里那一档，而用户完全不知道为什么。
  static const String saveAudioEffect = 'saveAudioEffect';

  /// 播放窗口 → 主窗口：「用户给这部片换了音轨 / 字幕 / 字幕开关，存下来」。
  ///
  /// 参数是 `{'itemId': <String>, 'preference': <PlaybackPreference.toJson>}`，
  /// 返回 `null`（与 [saveAudioEffect] 一样是**单向通知**：播放窗口那边早已
  /// 生效，落库只决定「下次还记不记得」）。
  ///
  /// ## 为什么传的是**整份**偏好而不是「改了哪一项」
  ///
  /// 播放窗口手里本来就有一份完整的偏好（打开时从请求里拿的），用户每改一项
  /// 就地更新。传整份的代价是几十字节，换来的是**主窗口不需要实现合并语义** ——
  /// 而「哪些字段该保留」这件事一旦有两处实现（两边各一套 patch 规则），
  /// 必然漂移成「主窗口保存时把某几项抹掉了」这种查不出来的 bug。
  ///
  /// ⚠️ 播放窗口**只播种、不改写**：它拿到请求时把这份偏好原样存下来（见
  /// `player_window_app.dart` 的 `_adoptRequest`），之后用户改哪一项才更新
  /// 哪一项。而请求里那份**本来就是主窗口从库里读出来的**，所以主窗口收到就
  /// **直接整份覆盖写**也不会丢掉用户没动过的项 —— 不必再读一遍库做合并，
  /// 也就不会出现「一次字幕切换把用户选的画质抹成 NULL」这种事。
  ///
  /// ⛔ 反过来，**别让播放窗口把画质 / 音效「对齐到本次实际在用的值」再报
  /// 回来**：本次实际在用的大多数时候只是**全局默认**（用户从没为这部片选
  /// 过），写进库就等于把它钉死成这部片的覆盖值 —— 之后用户改全局默认，这部
  /// 片再也不跟着变，而他完全不知道为什么。
  ///
  /// 音效另有一条 [saveAudioEffect]：那条写的是**全局默认**（这台设备怎么接
  /// 音箱），这条写的是**这部片的覆盖**。两个都要写，理由见
  /// `PlaybackPreference.audioEffect` 的文档。
  static const String savePlaybackPreference = 'savePlaybackPreference';
}

/// 跨引擎通道上的**错误码**。
///
/// 通道只认 `PlatformException` 的 `code` / `message` 三段，所以「失败的种类」
/// 只能靠 `code` 传。集中在同一个地方是必须的：主窗口抛、播放窗口判，
/// 两边各写一个字符串字面量的话，改一处就会**静默**失去那个分支 ——
/// 表现为「文件没了，但没人问我要不要删」，而没有任何报错。
abstract final class PlayerBridgeError {
  /// 网盘上已经没有这个文件了（见 `player_bridge_host.dart` 里
  /// `_asMissingFileError`）。
  ///
  /// 收到它意味着「这条索引已经失效」，播放窗口应当给用户一个
  /// 「从媒体库移除」的出口；其它错误码都只是「这次没取到」。
  static const String missingFile = 'drive/notFound';
}

/// 当前平台是否支持多窗口。
///
/// `desktop_multi_window` 只实现了 macOS / Windows / Linux；在 Android 上碰它的
/// 任何 API 都会抛 `MissingPluginException`。所有入口都要先过这道闸。
///
/// 用 [defaultTargetPlatform] 而不是 `dart:io` 的 `Platform`：前者是项目里
/// 既有的平台判定口径（见 `playback_exit_policy.dart`），且单测可以用
/// `debugDefaultTargetPlatformOverride` 覆盖。
bool get supportsMultiWindow =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

/// 播放窗口回报进度时，主窗口该做什么。
///
/// **必须由 UI 层装上**（见 `playerBridgeHostProvider`）：这个文件在
/// `main()` 里就被调用，那时还没有 Riverpod 容器，拿不到仓储。
/// 没装上时进度回报会被安静丢弃，只在日志里留一条 debug。
///
/// 返回类型是 `Future` 而不是 `void`：调用方会 **await** 它（见
/// [handlePlayerWindowCall]）。切集那一步要「先把当前位置写库，再读库算新一集的
/// 续播点」，只靠「发完了消息」是排不出这个顺序的。
Future<void> Function(PlaybackProgressReport report)? onPlaybackProgress;

/// 播放窗口要求刷新直链时，主窗口该做什么。
///
/// 与 [onPlaybackProgress] 同样的理由必须由 UI 层装上（需要仓储与适配器）。
///
/// 返回 `null` 表示刷不出来（条目已不在库里、取链失败、平台不支持），
/// 播放窗口拿到 null 就应当**停在原地并如实告诉用户**，而不是反复重试 ——
/// 重试由它自己的 `TicketRefreshGuard` 管，这里只负责一次成败。
Future<PlayRequest?> Function(TicketRefreshRequest request)? onTicketRefresh;

/// 播放窗口要一条网盘字幕的正文时，主窗口该做什么。
///
/// 与 [onPlaybackProgress] 同样的理由必须由 UI 层装上（需要适配器与凭证）。
///
/// 返回**已解码的 UTF-8 文本**；`null` 表示取不到（文件已删、取链失败、
/// 平台不支持）。播放窗口拿到 null 应当**如实告诉用户**，不要静默什么都不做 ——
/// 那会被读成「点了没反应」。
Future<String?> Function(String fileId)? onFetchSubtitleText;

/// 播放窗口要一张网盘缩略图时，主窗口该做什么。
///
/// 与 [onFetchSubtitleText] 同样的理由必须由 UI 层装上（需要海报缓存、
/// HTTP 客户端与凭证）。
///
/// 返回**本地绝对路径**；`null` 表示取不到（断网、Cookie 失效、地址已过期）——
/// 播放窗口拿到 `null` 应当**安静退回占位图**，不要重试：面板一展开就是
/// 七八行同时要图，逐行重试只会把夸克的 QPS 额度烧在一件用户根本不会
/// 注意到的事情上（占位图本来就是这个列表的既有形态）。
///
/// ⚠️ [itemId] 可能是**空串**（请求来自老版本主窗口、或那一集没有库记录）：
/// 那时缓存键退化成 URL 本身，图照样取得回来，只是文件名不好看。
Future<String?> Function(String itemId, String url)? onFetchThumbnail;

/// 播放窗口要在字幕站上搜字幕时，主窗口该做什么。
///
/// 返回**空列表**表示「确实搜不到」；抛异常表示「这次请求没成」。
/// 这两者绝不能混 —— 混了以后用户看到「搜不到」会以为这部片没有字幕，
/// 而实际可能是 Api-Key 没配对。
///
/// 抛出的异常**必须是 [PlatformException]**：跨引擎通道只认识这一种错误
/// 形状（框架按 `code`/`message`/`details` 三段编码），别的异常到了对面会
/// 退化成一个 `code='error'`、`message=<整段 toString>` 的兜底错误 ——
/// 那正是「用户看到一坨 OpenSubtitlesException(notConfigured, …)」的来源。
Future<List<OnlineSubtitleBrief>> Function(SubtitleSearchRequest request)?
    onSearchOnlineSubtitles;

/// 播放窗口要一条在线字幕的正文时，主窗口该做什么。
Future<String?> Function(int fileId)? onFetchOnlineSubtitle;

/// 播放窗口要保存片头区间时，主窗口该做什么。
///
/// 与 [onPlaybackProgress] 同样的理由必须由 UI 层装上（需要仓储）。
///
/// 返回**落库之后的真实值**；`null` 表示写不了（条目不在库里、平台不支持）——
/// 播放窗口拿到 null 应当如实告诉用户「标记没保存」，不要静默什么都不做，
/// 那会被读成「点了没反应」。
Future<IntroRangeSnapshot?> Function(IntroRangeSaveRequest request)?
    onSaveIntroRange;

/// 播放窗口把用户选的「音效」预设报回来时，主窗口该做什么。
///
/// 与 [onSaveIntroRange] 同样的理由必须由 UI 层装上（要拿设置库）。
///
/// **没有返回值**：这是一条单向通知。播放窗口那边音效早已生效（它自己就能设
/// mpv 属性），落库只是「下次还记得」—— 拿不到结果也不该拦住用户。
/// 所以回调失败只记日志，不回传错误。
Future<void> Function(AudioEffectPreset preset)? onSaveAudioEffect;

/// 播放窗口把「这部片的音轨 / 字幕 / 字幕开关」报回来时，主窗口该做什么。
///
/// 与 [onSaveAudioEffect] 同样的理由必须由 UI 层装上（要拿仓储）。
///
/// **没有返回值**：与 [onSaveAudioEffect] 同一条边界 —— 播放窗口那边已经
/// 生效了，落库只决定「下次还记不记得」。为一次写库失败给用户弹一个错误，
/// 与他的操作（换条字幕）毫无关系。
///
/// ⚠️ [itemId] 可能是空串（手输直链、内置自检视频这些没有库记录的播放）。
/// 那种情况下**不要写库**：没有 itemId 就没有行可以挂，硬造一条只会留下一堆
/// 永远对不上任何文件的孤儿偏好。
Future<void> Function(String itemId, PlaybackPreference preference)?
    onSavePlaybackPreference;

/// 播放窗口问「这一条是不是已经没了」时，主窗口该做什么。
///
/// 返回 `null` 表示库里查不到这一条（它已经被删了、或 id 变了）—— 播放窗口
/// 拿到 null 应当**如实提示**而不是弹一个字段全空的对话框。
Future<MissingMediaBrief?> Function(String itemId)? onQueryMissingMedia;

/// 播放窗口要求移除一条已经失效的索引时，主窗口该做什么。
///
/// 返回是否真的动了库。删完之后媒体库的所有列表都要重取 —— 那是主窗口自己的
/// 事（`MissingMediaController`），播放窗口不需要知道。
Future<bool> Function(MissingMediaRemoval request)? onRemoveMissingMedia;

/// 主窗口侧：还没被播放窗口取走的播放请求。
///
/// **为什么要有这个「待取」盒子，而不是创建窗口后直接把请求推过去** ——
/// 因为有时序竞争：`WindowController.create` 返回时，子窗口才刚开始起引擎，
/// 它注册跨引擎通道要等到第一帧之后。此刻推过去必然拿 `CHANNEL_UNREGISTERED`。
///
/// 所以投递分两条路：
///   - **新窗口 → 拉**：请求放进盒子，子窗口启动完成后自己来取（[PlayerBridgeMethod.fetchPendingPlay]）。
///   - **已有窗口 → 推**：那个引擎早就就绪，直接 `play`；推失败就留在盒子里，
///     等下次开窗被拉走。**不做重试循环** —— 那只会把一个已经失败的操作拖长。
///
/// 主窗口只有一个引擎，所以用进程内全局变量即可，不需要跨引擎存储。
PlayRequest? _pendingPlayRequest;

/// 仅测试用：读出/清空待取请求。
@visibleForTesting
PlayRequest? get debugPendingPlayRequest => _pendingPlayRequest;

@visibleForTesting
void debugSetPendingPlayRequest(PlayRequest? request) =>
    _pendingPlayRequest = request;

/// 主窗口侧：注册跨引擎通道的处理器。
///
/// **必须早于任何播放窗口的 ping**，否则播放窗口会拿到 `CHANNEL_UNREGISTERED`。
/// 调用点放在 `main()` 里、`runApp` 之前。
///
/// 失败不抛异常：多窗口只是 PC 端的增强能力，通道没注册上不该挡住应用启动。
Future<void> registerPlayerWindowBridge() async {
  if (!supportsMultiWindow) return;
  try {
    await playerWindowChannel.setMethodCallHandler(handlePlayerWindowCall);
    diag.info('窗口', '已注册播放器跨窗口通道');
  } catch (e) {
    diag.warn('窗口', '注册播放器跨窗口通道失败：$e');
  }
}

/// 主窗口侧：处理播放窗口发过来的请求。
@visibleForTesting
Future<Object?> handlePlayerWindowCall(MethodCall call) async {
  switch (call.method) {
    case PlayerBridgeMethod.ping:
      return 'pong';

    case PlayerBridgeMethod.fetchPendingPlay:
      final pending = _pendingPlayRequest;
      // 只交付一次。留着它会让「重新自检」反复把同一部片重新播一遍。
      _pendingPlayRequest = null;
      if (pending != null) {
        diag.info('窗口', '播放请求已被播放窗口取走：${pending.describe()}');
      }
      return pending?.toJson();

    case PlayerBridgeMethod.reportProgress:
      final report = PlaybackProgressReport.fromJson(call.arguments);
      if (report == null) {
        diag.warn('窗口', '收到解不开的进度回报，忽略');
        return null;
      }
      final handler = onPlaybackProgress;
      if (handler == null) {
        // 只在 debug 级别记：这条会每 10 秒来一次，用 warn 会刷屏。
        diag.debug('窗口', '收到进度回报但没有落库回调（UI 层还没装上）');
        return null;
      }
      // ⚠️ **必须 await，不能 fire-and-forget。**
      //
      // 切集的顺序是：播放窗口先报「当前这一集看到哪了」，紧接着请求下一集的
      // 新链；主窗口拿到请求后要**读库**算续播点。若这里不等写入完成，读到
      // 的就是旧值 —— 症状是「切走再切回来，又从头开始」。
      //
      // 平时的 10 秒一次回报也走这条路，但它们对顺序没有要求，等一下（一次
      // 本地 SQLite 写入）没有任何代价。
      await handler(report);
      return null;

    case PlayerBridgeMethod.refreshTicket:
      final refresh = TicketRefreshRequest.fromJson(call.arguments);
      if (refresh == null) {
        diag.warn('窗口', '收到解不开的刷新请求，忽略');
        return null;
      }
      final refreshHandler = onTicketRefresh;
      if (refreshHandler == null) {
        // 用 warn 而不是 debug：正常运行时这条**不该出现**（UI 层一定会装上），
        // 出现即说明启动路径被改坏了。
        diag.warn('窗口', '播放窗口要求刷新直链，但没有装上取链回调');
        return null;
      }
      diag.info('窗口', '播放窗口要求刷新直链：$refresh');
      // 不 catch：「文件已经不在网盘上」是以 [PlatformException] 的形式抛
      // 过来的（见 `player_bridge_host.dart`），播放窗口要靠它的 `code`
      // 决定接下来是「刷新重试」还是「问用户要不要删掉这条索引」。
      // 在这里吞掉会让那一步退化成静默失败 —— 而静默失败在自动连播时表现
      // 为「播完一集就没动静了」，最难查的那一类。
      final fresh = await refreshHandler(refresh);
      if (fresh == null) {
        diag.warn('窗口', '刷新直链失败：$refresh');
        return null;
      }
      // 只打片名/档位/位置，不打新链 —— 直链带签名查询串。
      diag.info(
        '窗口',
        '已刷新直链 → ${fresh.describe()} @ ${fresh.startPosition.inSeconds}s',
      );
      return fresh.toJson();

    case PlayerBridgeMethod.fetchSubtitleText:
      final fileId = call.arguments is Map
          ? (call.arguments as Map)['fileId']
          : null;
      if (fileId is! String || fileId.isEmpty) {
        diag.warn('窗口', '收到没有 fileId 的取字幕请求，忽略');
        return null;
      }
      final fetch = onFetchSubtitleText;
      if (fetch == null) {
        diag.warn('窗口', '播放窗口要字幕正文，但没有装上取字幕回调');
        return null;
      }
      // 不打 fileId 之外的东西：字幕文件名可能含片子信息，但那不是秘密；
      // 反过来**不要**打返回内容 —— 那是整份字幕正文。
      diag.info('窗口', '播放窗口要字幕正文 fid=$fileId');
      final text = await fetch(fileId);
      if (text == null) {
        diag.warn('窗口', '取字幕正文失败 fid=$fileId');
        return null;
      }
      return text;

    case PlayerBridgeMethod.fetchThumbnail:
      final thumbArgs = call.arguments;
      if (thumbArgs is! Map) {
        diag.warn('窗口', '收到畸形的缩略图请求，忽略：$thumbArgs');
        return null;
      }
      final thumbUrl = thumbArgs['url'];
      if (thumbUrl is! String || thumbUrl.isEmpty) {
        diag.warn('窗口', '收到没有地址的缩略图请求，忽略');
        return null;
      }
      final fetchThumb = onFetchThumbnail;
      if (fetchThumb == null) {
        diag.warn('窗口', '播放窗口要缩略图，但没有装上取图回调');
        return null;
      }
      // 用 debug 而不是 info：面板一展开就是好几行同时来，info 会刷屏，
      // 而这条日志的排查价值远不如「取字幕」那条（那是一条用户主动的动作）。
      final thumbItemId = thumbArgs['itemId'];
      diag.debug(
        '窗口',
        '播放窗口要缩略图 itemId=${thumbItemId is String ? thumbItemId : "-"}',
      );
      final thumbPath = await fetchThumb(
        thumbItemId is String ? thumbItemId : '',
        thumbUrl,
      );
      if (thumbPath == null) {
        // 不当作错误：约 30% 的视频夸克还没生成预览图，断网时更是整屏如此。
        diag.debug('窗口', '缩略图没取到，面板那一行退回占位图');
        return null;
      }
      return thumbPath;

    case PlayerBridgeMethod.searchOnlineSubtitles:
      final request = SubtitleSearchRequest.fromJson(call.arguments);
      if (request.isEmpty) {
        diag.warn('窗口', '收到没有片名也没有条目的在线字幕搜索请求，忽略');
        return const <Object?>[];
      }
      final search = onSearchOnlineSubtitles;
      if (search == null) {
        diag.warn('窗口', '播放窗口要搜在线字幕，但没有装上搜索回调');
        return const <Object?>[];
      }
      diag.info('窗口', '播放窗口要搜在线字幕：$request');
      // 不 catch：这里的异常要原样穿到播放窗口去（见回调的文档）。
      final hits = await search(request);
      diag.info('窗口', '在线字幕搜索返回 ${hits.length} 条');
      return hits.map((h) => h.toJson()).toList();

    case PlayerBridgeMethod.fetchOnlineSubtitle:
      final fileId = call.arguments is Map
          ? (call.arguments as Map)['fileId']
          : null;
      final id = fileId is int ? fileId : int.tryParse('$fileId');
      if (id == null) {
        diag.warn('窗口', '收到没有 fileId 的取在线字幕请求，忽略');
        return null;
      }
      final fetchOnline = onFetchOnlineSubtitle;
      if (fetchOnline == null) {
        diag.warn('窗口', '播放窗口要在线字幕正文，但没有装上取字幕回调');
        return null;
      }
      diag.info('窗口', '播放窗口要在线字幕正文 fileId=$id');
      final text = await fetchOnline(id);
      if (text == null) {
        diag.warn('窗口', '取在线字幕正文失败 fileId=$id');
        return null;
      }
      return text;

    case PlayerBridgeMethod.saveIntroRange:
      final save = IntroRangeSaveRequest.fromJson(call.arguments);
      if (save == null) {
        diag.warn('窗口', '收到解不开的片头保存请求，忽略');
        return null;
      }
      if (save.isEmpty) {
        // 三个字段全空 = 用户点了菜单但什么都没选。不当作错误，
        // 只是不白跑一次写库。
        diag.debug('窗口', '片头保存请求没有内容，忽略');
        return const IntroRangeSnapshot().toJson();
      }
      final saveHandler = onSaveIntroRange;
      if (saveHandler == null) {
        diag.warn('窗口', '播放窗口要保存片头区间，但没有装上保存回调');
        return null;
      }
      diag.info('窗口', '播放窗口要保存片头区间：$save');
      final snapshot = await saveHandler(save);
      if (snapshot == null) {
        diag.warn('窗口', '保存片头区间失败：$save');
        return null;
      }
      return snapshot.toJson();

    case PlayerBridgeMethod.queryMissingMedia:
      final itemId = call.arguments is Map
          ? (call.arguments as Map)['itemId']
          : null;
      if (itemId is! String || itemId.isEmpty) {
        diag.warn('窗口', '收到没有 itemId 的失效查询，忽略');
        return null;
      }
      final query = onQueryMissingMedia;
      if (query == null) {
        diag.warn('窗口', '播放窗口查询失效媒体，但没有装上查询回调');
        return null;
      }
      final brief = await query(itemId);
      if (brief == null) {
        diag.warn('窗口', '库里查不到 $itemId，无法给出移除选项');
        return null;
      }
      return brief.toJson();

    case PlayerBridgeMethod.removeMissingMedia:
      final removal = MissingMediaRemoval.fromJson(call.arguments);
      if (removal == null) {
        diag.warn('窗口', '收到解不开的移除请求，忽略');
        return false;
      }
      final remove = onRemoveMissingMedia;
      if (remove == null) {
        diag.warn('窗口', '播放窗口要移除失效媒体，但没有装上移除回调');
        return false;
      }
      diag.info('窗口', '播放窗口要求移除失效媒体：$removal');
      final removed = await remove(removal);
      diag.info('窗口', '移除结果：$removed');
      return removed;

    case PlayerBridgeMethod.saveAudioEffect:
      // 解不开的值**不报错**，只忽略：这是一条单向通知，播放窗口那边不等
      // 结果。为一条存不下来的设置把异常抛回去，只会让用户看到一个与
      // 他的操作毫无关系的错误弹窗。
      final preset = _audioEffectFromArguments(call.arguments);
      if (preset == null) {
        diag.warn('窗口', '收到解不开的音效值，忽略：${call.arguments}');
        return null;
      }
      final saveEffect = onSaveAudioEffect;
      if (saveEffect == null) {
        diag.warn('窗口', '播放窗口要保存音效，但没有装上保存回调');
        return null;
      }
      diag.info('窗口', '播放窗口把音效改成了「${PlayerAudioEffect.label(preset)}」');
      await saveEffect(preset);
      return null;

    case PlayerBridgeMethod.savePlaybackPreference:
      // 与音效同一条边界：单向通知，畸形输入**忽略而不抛**。
      final args = call.arguments;
      if (args is! Map) {
        diag.warn('窗口', '收到畸形的播放偏好参数，忽略：$args');
        return null;
      }
      final itemId = args['itemId'];
      if (itemId is! String || itemId.isEmpty) {
        // 手输直链 / 内置自检视频这类**没有库记录**的播放。不写库：
        // 没有 itemId 就没有行可以挂，硬造一条只会留下永远对不上任何
        // 文件的孤儿偏好。这是正常情况，用 debug 级别记一下即可。
        diag.debug('窗口', '播放偏好没有 itemId（无库记录的播放），不保存');
        return null;
      }
      final preference = PlaybackPreference.fromJson(args['preference']);
      if (preference == null) {
        diag.warn('窗口', '收到解不开的播放偏好，忽略：${args['preference']}');
        return null;
      }
      final savePref = onSavePlaybackPreference;
      if (savePref == null) {
        diag.warn('窗口', '播放窗口要保存播放偏好，但没有装上保存回调');
        return null;
      }
      diag.info('窗口', '播放窗口报回播放偏好：$itemId → $preference');
      await savePref(itemId, preference);
      return null;

    default:
      throw MissingPluginException('主窗口未实现的通道方法：${call.method}');
  }
}

/// 从通道参数里取出音效预设。畸形输入返回 `null`。
///
/// 走 `PlayerAudioEffect.parse` 而不是在这里比字符串：那个函数同时承担
/// 「读不懂时退回默认」这条规则，这里再判一次就会多出第二份口径。
/// 但它**把未知值悄悄变成 `auto`**，所以这里要先确认那个字符串确实是已知档位
/// —— 否则「播放窗口报了个未来版本的档位」会被记成「用户选了跟随片源」，
/// 写进库就把用户原来的设置抹掉了。
AudioEffectPreset? _audioEffectFromArguments(Object? raw) {
  if (raw is! Map) return null;
  final value = raw['value'];
  if (value is! String) return null;
  for (final p in PlayerAudioEffect.all) {
    if (p.value == value) return p;
  }
  return null;
}

/// 播放窗口侧：处理主窗口发过来的请求。
///
/// ⚠️ **这个函数必须被 `setMethodCallHandler` 注册上**，否则播放窗口连一句
/// `ping` 都发不出去。原因在原生 `ChannelRegistry.getTarget(for:from:)`：
/// bidirectional 通道的第一步是
///
/// ```swift
/// guard candidates.contains(where: { $0 === window }) else { return nil }
/// ```
///
/// 也就是**调用方自己也必须在配对里**。子窗口没注册过这个通道时，
/// `invokeMethod` 一律拿 `CHANNEL_UNREGISTERED` —— 那看起来像「插件不支持
/// 跨引擎通道」，实际上只是调用方没入场。这个坑踩过一次：自检页会把
/// 「我测试写错了」显示成「通道不通」，白跑一轮实测。
///
/// 这里只处理**协议层面**的方法（心跳）。[PlayerBridgeMethod.play] 要真的去
/// 操作播放器，所以由 `PlayerWindowApp` 包一层再挂上去，不放进这个纯函数。
Future<Object?> handleMainWindowCall(MethodCall call) async {
  switch (call.method) {
    case PlayerBridgeMethod.ping:
      return 'pong';
    default:
      throw MissingPluginException('播放窗口未实现的通道方法：${call.method}');
  }
}

/// 主窗口侧：打开（或复用）播放器窗口。
///
/// **复用优先** —— 对应夸克网盘的 `GetOrCreatePlayerWindow`。反复点播放却每次
/// 都新开一个窗口，用户很快就会攒下一堆播放器窗口，而且每个窗口都占着一个
/// 引擎和一份 mpv 解码资源。
class PlayerWindowLauncher {
  const PlayerWindowLauncher();

  /// 打开窗口并投递 [request]（可为 null = 只开一个空播放窗口）。
  ///
  /// 返回被打开/复用的窗口控制器；平台不支持时为 null。
  /// **不抛异常**：开不了窗口是调用方要处理的正常结果，不是异常路径。
  Future<WindowController?> open([PlayRequest? request]) async {
    if (!supportsMultiWindow) {
      // 明确记一行：否则「点了播放什么都没发生」在日志里完全无迹可寻。
      diag.info('窗口', '当前平台不支持独立播放窗口，应走内置播放页');
      return null;
    }

    _pendingPlayRequest = request;

    final existing = await findExisting();
    if (existing != null) {
      await existing.show();
      diag.info('窗口', '复用已有播放窗口 ${existing.windowId}');
      if (request != null && await _push(existing, request)) {
        _pendingPlayRequest = null;
      }
      return existing;
    }

    final controller = await WindowController.create(
      WindowConfiguration(
        // 入口参数里也带一份请求：它是**兜底**。正常情况下播放窗口会通过
        // `fetchPendingPlay` 来取（那条路没有时序竞争），但万一拉取失败，
        // 窗口至少还能从自己的启动参数里把片子播出来。
        arguments: encodeWindowLaunch(
          WindowKind.player,
          request?.toJson() ?? const <String, Object?>{},
        ),
        hiddenAtLaunch: false,
      ),
    );
    diag.info('窗口', '新建播放窗口 ${controller.windowId}');
    return controller;
  }

  /// 找出已经存在的播放窗口；没有则返回 null。
  Future<WindowController?> findExisting() async {
    if (!supportsMultiWindow) return null;
    for (final controller in await WindowController.getAll()) {
      // 复用 [parseWindowLaunch] 而不是自己判字符串：窗口类型的判定规则只能有
      // 一处，否则将来加了新窗口类型，这里就会漏。
      final launch = parseWindowLaunch(
        <String>[
          kMultiWindowEntryToken,
          controller.windowId,
          controller.arguments,
        ],
      );
      if (launch.isPlayer) return controller;
    }
    return null;
  }

  /// 推一条播放请求给**已经就绪**的播放窗口。成功返回 true。
  ///
  /// 走 [playerWindowChannel]（bidirectional）而不是 `controller.invokeMethod`：
  /// 后者用的是 `mixin.one/window_controller/<id>` 那个**单向**通道，要求子窗口
  /// 先 `setWindowMethodHandler` 才算注册；而 bidirectional 通道两边都已经
  /// 注册过了，直接就能投。
  Future<bool> _push(WindowController controller, PlayRequest request) async {
    try {
      await playerWindowChannel
          .invokeMethod<void>(PlayerBridgeMethod.play, request.toJson());
      diag.info('窗口', '已推送播放请求 → ${request.describe()}');
      return true;
    } on WindowChannelException catch (e) {
      // 多半是子窗口还没注册（引擎仍在起）。留给它自己来取，不重试。
      diag.warn('窗口', '推送播放请求失败（${e.code}），留给播放窗口主动来取');
      return false;
    } catch (e) {
      diag.warn('窗口', '推送播放请求失败：$e');
      return false;
    }
  }
}
