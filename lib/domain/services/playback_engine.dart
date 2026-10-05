/// 播放引擎契约 —— 把「用哪个内核」这件事从业务里隔离出来。
///
/// ## 为什么需要这一层
///
/// 杜比视界 Profile 5 的像素在 Dolby 私有的 IPT-PQ-C2 空间里，还原成 RGB
/// 必须把 RPU 元数据应用在**渲染阶段**。而 macOS 上 media_kit 走的是 mpv 的
/// **render API**（`vo=libmpv`），它的 `render_backends[]` 只有 `gpu` / `sw`
/// 两个，`vo=gpu-next` **架构上不可达** —— 也就是说 libmpv 这条路在 macOS 上
/// **不可能**渲染 DV，调任何参数都没用。
///
/// 结论是必须换内核（libmdk / fvp，已 PoC 验证能正确渲染 P5）。
///
/// ## 但换内核 ≠ 全量替换
///
/// 按需路由：**只有 DV 片走新内核**，其余片源仍走 media_kit。
/// 好处是暴露面小 —— 只有少数片源承担新路径的回归风险；
/// Android / TV 完全不动（那边是**真 window vo**，本来就不受 render API 限制）。
///
/// ⚠️ 按需路由**没有**减少实现量：DV 片同样要切音轨、挂字幕、跳章节、看缓冲，
/// 所以业务层必须对两个内核一视同仁 —— 这正是本文件存在的理由。
///
/// ## 契约里最危险的一条：缓冲终点
///
/// [PlaybackEngine.bufferEnd] 的语义是 **「已缓存区间的结束位置」**，
/// 参照系与播放头相同（等价于 mpv 的 `demuxer-cache-time` / `ts_end`），
/// **不是**「播放头前面还有多少秒」。
///
/// 这条曾经被写错过一次：把绝对值又加了一遍播放头，于是每跳一次进度条
/// 缓冲层就凭空多出一整个播放头那么长（详见 `PlayerBufferProgress` 的类文档）。
/// 两个内核对这个量的**原始表示并不一样** —— mpv 直接给绝对时间戳，
/// 而 mdk 给的是**区间列表**。转换规则见 [EngineTimeRange.cacheEndAt]，
/// 那是这条契约在两个内核之间唯一允许的换算点。
library;

/// 一段已缓存的**闭区间**（两端都含），单位与参照系同播放头。
///
/// 存在的唯一理由是 [cacheEndAt]：它把 mdk 的「区间列表」折算成 mpv 那种
/// 「一个绝对时间戳」，让上层不必知道自己跑在哪个内核上。
class EngineTimeRange {
  const EngineTimeRange({required this.start, required this.end});

  final Duration start;
  final Duration end;

  /// 播放头所在那一段缓存的**结束位置**。等价于 mpv 的 `ts_end`。
  ///
  /// ## 为什么优先取「包含播放头的那一段」
  ///
  /// mdk 会把**所有**缓存区间都给出来，其中包括 seek 之后残留在别处的段。
  /// 取全局最大值会把一段**与播放头不相邻**的远端缓存算进来，进度条于是
  /// 画出一段其实读不到的「已缓存」—— 用户看到缓冲层很满、画面照样卡。
  /// mpv 的 `ts_end` 指的是**正在读的那一段**的终点，与「包含播放头」同义。
  ///
  /// ## 播放头不在任何区间里时返回 0，而不是最大值
  ///
  /// 代价是不对称的：
  /// - **少报**（返回 0）：`PlayerBufferProgress.positionOf` 会退回播放头，
  ///   界面只是暂时不画缓冲层，下一拍就回来了；
  /// - **多报**：进度条凭空宣称缓存到了很远的地方，而这是**假的**。
  ///
  /// 所以宁可返回 0。调用方**不要**在这里补任何「猜一个」的逻辑。
  static Duration cacheEndAt(
    List<EngineTimeRange> ranges,
    Duration position,
  ) {
    for (final r in ranges) {
      if (position >= r.start && position <= r.end) return r.end;
    }
    return Duration.zero;
  }
}

/// 视频输出尺寸。**纯 Dart**，因为领域层不引 Flutter（不能直接用 `Size`）。
///
/// 用途只有一个：判断「出画面了没有」。mpv 那边对应 `stream.videoParams`
/// 的 `w > 0`，mdk 那边对应 `VideoPlayerValue.size`。加载指示器等它 ——
/// 它比 `duration` / `position` 更准（那两者纯音频流也会给）。
class EngineVideoSize {
  const EngineVideoSize(this.width, this.height);

  static const unknown = EngineVideoSize(0, 0);

  final int width;
  final int height;

  bool get hasVideo => width > 0 && height > 0;

  /// 值相等。**必须有** —— 这个对象是「值没变就不发」的闸所比较的对象，
  /// 而闸用的是 `==`。不实现的话每次都是引用不等，于是每一拍都往上报一次
  /// 「尺寸变了」，订阅方（加载指示器）跟着每拍重建。
  ///
  /// 这类「值是新的、内容一样」的误报在 Dart 里只有 `==` 能挡住，
  /// 别指望闸去深比较 —— 那会把每个类型都特殊对待一遍。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EngineVideoSize &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'EngineVideoSize($width x $height)';
}

/// 交给引擎去播的一条流。
class EngineMedia {
  const EngineMedia({
    required this.url,
    this.headers = const {},
    this.startAt = Duration.zero,
  });

  final String url;

  /// 必须随请求一起发的头。
  ///
  /// ⚠️ **夸克直链缺 `Cookie` 一律返回 412**，表现是「能扫描、一播就报错」，
  /// 而错误信息里看不出是缺头。两个内核都必须把这份头原样带上
  /// （media_kit 走 `Media(httpHeaders:)`，fvp 走 `avio.headers`）。
  final Map<String, String> headers;

  /// 起播位置。
  ///
  /// ⚠️ 两个内核的**下达方式不同**，且都不能用「open 之后再 seek」替代：
  /// - media_kit：`Media(start:)`；
  /// - fvp：`initialize()` 之后、`play()` 之前 `seekTo()` ——
  ///   mdk 在 Prepared 状态下 seek 是有效的（不像 mpv 的 `loadfile` 竞态）。
  ///
  /// 这条**必须在真机上验**：续播是本应用的主路径。
  final Duration startAt;
}

/// 一个章节。**只用来跳片头**（见 `IntroSession`），不做章节菜单。
///
/// 两个内核的**取法完全不同**，且都是「一次性查询」而不是流：
/// - media_kit：`NativePlayer.getProperty('chapter-list')`（mpv 属性，返回字符串）；
/// - fvp：`MediaInfo.chapters`。
///
/// 所以契约做成 [PlaybackEngine.chapters] 这个方法，由实现各自解析。
class EngineChapter {
  const EngineChapter({
    required this.start,
    required this.end,
    this.title,
  });

  final Duration start;
  final Duration end;
  final String? title;

  Duration get duration => end - start;

  @override
  String toString() => 'EngineChapter($start ~ $end, $title)';
}

/// 一条轨道（音轨 / 字幕轨 / 视频轨）。
///
/// 字段刻意与媒体库里的 [SubtitleTrack] 保持可映射，但**不带业务语义**
/// （没有「外挂 / 内嵌」之分、没有偏好打分）—— 那些是上层的规则。
class EngineTrack {
  const EngineTrack({
    required this.id,
    this.title,
    this.language,
    this.codec,
    this.isDefault = false,
  });

  /// 引擎内部的轨道号。上层用它来回切轨。
  final int id;

  final String? title;
  final String? language;

  /// 编解码器短名（`aac` / `subrip` / `hdmv_pgs_subtitle`）。
  ///
  /// ## 为什么它必须在契约里
  ///
  /// 唯一用途是**内嵌字幕清单的诊断日志** —— 那是「字幕出不来」的第一分诊点：
  /// 有轨道但画面没字，就得看是哪一种字幕（`hdmv_pgs_subtitle` 是位图，
  /// 本机解不开与 `subrip` 解不开是两回事）。丢了这一位，两种故障在日志里
  /// 长得一模一样。音轨 / 字幕菜单的副标题（`TrackLabels.*Detail`）也读它。
  ///
  /// 两个内核给的都是 **FFmpeg 的短名**（media_kit 转发 mpv 的 `codec`，
  /// mdk 直接给 FFmpeg 的 codec 名），口径天然一致，不需要归一化。
  final String? codec;

  final bool isDefault;

  @override
  String toString() =>
      'EngineTrack($id, $title, $language, codec=$codec, default=$isDefault)';
}

/// 当前媒体解出来的轨道清单。
///
/// 这是一个**快照**而不是流：mpv 会把轨道变化做成流（`stream.tracks`），
/// 而 mdk 只在 `MediaInfo` 里给一次性查询。契约统一成「流」，
/// 由实现负责在合适的时机重新发一份（见各实现里的重发策略）。
class EngineTracks {
  const EngineTracks({
    this.audio = const [],
    this.subtitle = const [],
    this.video = const [],
  });

  static const empty = EngineTracks();

  final List<EngineTrack> audio;
  final List<EngineTrack> subtitle;
  final List<EngineTrack> video;

  bool get isEmpty => audio.isEmpty && subtitle.isEmpty && video.isEmpty;

  /// 内容指纹。**给实现用来判「这次回报和上次一样吗」**。
  ///
  /// 为什么不直接实现 `==`：这三个是 `List`，默认的引用相等会让每次回报都
  /// 被当成「变了」，于是每一拍都往上抛一遍 —— 而订阅方（播放页）收到就会
  /// 重建、重跑「自动选字幕」「还原音轨」那两条逻辑。
  ///
  /// 指纹里**必须带 id 而不只是条数**：换集时条数常常一样，只有 id 变了。
  /// 只比条数的话，「换了新一集但音轨清单条数相同」会被判成没变，
  /// 于是偏好还原与自动选字幕都不会重跑。
  String get signature => '${_sig(video)}#${_sig(audio)}#${_sig(subtitle)}';

  static String _sig(List<EngineTrack> ts) =>
      ts.map((t) => t.id).join(',');

  @override
  String toString() =>
      'EngineTracks(音 ${audio.length} / 字 ${subtitle.length} / 视 ${video.length})';
}

/// 内核能力声明。
///
/// ## 为什么要有它，而不是「不支持就静默无效」
///
/// 两个内核的能力**不是超集关系**：mdk 没有音效滤镜（mpv 的 `af`）、
/// 没有实时输入速率读数、没有 mpv 那种日志流。
/// 这些功能在界面上**有入口**，静默失效的表现是「用户点了没反应」——
/// 那是最难查的一类问题，而且用户会以为自己没设置对。
///
/// 所以能力必须是**可查询的**，由 UI 决定置灰并给出说明。
/// 出画面方式。
///
/// 同一个内核（fvp）在不同平台可以走不同的输出路：Android TV 用
/// platformView（SurfaceView），macOS 用 textureView。把差异做成可查询的
/// 能力位，UI 就能按它解释各自的取舍（§5 的表）。
enum SurfaceOutput {
  /// 纹理路（media_kit / mdk 的 textureView）。
  texture,

  /// 原生 SurfaceView hybrid composition。
  platformView,
}

class EngineCapabilities {
  const EngineCapabilities({
    required this.audioEffects,
    required this.networkSpeed,
    required this.rawLog,
    required this.chapters,
    required this.rawProperty,
    required this.surfaceOutput,
  });

  /// 音效预设（声道布局 / 直通）。
  final bool audioEffects;

  /// 实时输入速率读数（底部浮层那个「速率」）。
  final bool networkSpeed;

  /// 引擎原始日志流。目前只有一处用途：**字幕解码失败的诊断**。
  final bool rawLog;

  /// 章节列表（跳片头用）。
  final bool chapters;

  /// 能否直接下发引擎原生属性（缓冲调优那一组）。
  final bool rawProperty;

  /// 出画面走哪条路（纹理 / 原生 SurfaceView）。
  final SurfaceOutput surfaceOutput;

  /// media_kit（mpv）：能力最全，但 macOS 上渲染不了 DV。
  static const mediaKit = EngineCapabilities(
    audioEffects: true,
    networkSpeed: true,
    rawLog: true,
    chapters: true,
    rawProperty: true,
    surfaceOutput: SurfaceOutput.texture,
  );

  /// fvp（libmdk）：能渲染 DV，但上面三项没有对等物。
  static const mdk = EngineCapabilities(
    audioEffects: false,
    networkSpeed: false,
    rawLog: false,
    chapters: true,
    rawProperty: false,
    surfaceOutput: SurfaceOutput.texture,
  );

  /// fvp 在 Android TV 上的 platformView 输出。
  static const mdkTv = EngineCapabilities(
    audioEffects: false,
    networkSpeed: false,
    rawLog: false,
    chapters: true,
    rawProperty: false,
    surfaceOutput: SurfaceOutput.platformView,
  );
}

/// 一个播放引擎。
///
/// ## 事件流的约定
///
/// - 全部是**广播流**，且**不重放**：订阅者必须在 `open()` 之前订好。
///   两个内核的原生 API 都是这个脾气（mpv 的属性通知、mdk 的状态回调），
///   实现里不要为了「方便」加 `BehaviorSubject` 之类的重放 —— 那会让
///   同一条事件在不同订阅者那里时序不一致。
/// - 值没变时**不发**。上层靠这个省重建（比如 `volume` 的浮点抖动）。
/// - 流上**不抛异常**：失败走 [error]，否则一次播放错误会把整个流的订阅链
///   打断，表现是「出错之后就再也收不到任何事件」。
abstract class PlaybackEngine {
  EngineCapabilities get capabilities;

  // -------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------

  Stream<bool> get playing;
  Stream<bool> get buffering;

  /// 播放头位置。高频（约 10 Hz），上层负责节流后再落库。
  Stream<Duration> get position;
  Stream<Duration> get duration;

  /// 缓冲终点。⚠️ **绝对时间戳**，不是「前面还有多少秒」。
  /// 语义与唯一的换算点见 [EngineTimeRange.cacheEndAt] 与 [PlaybackEngine] 的类文档。
  Stream<Duration> get bufferEnd;

  Stream<double> get volume;
  Stream<double> get rate;

  /// 轨道清单。内嵌轨是**流式出现**的（文件头解完才有），
  /// 所以实现必须在内嵌轨变化时重新发一份，不能只发一次。
  Stream<EngineTracks> get tracks;

  /// 当前生效的音轨号。`null` = 引擎还没定。
  Stream<int?> get activeAudioTrackId;

  /// 当前生效的字幕轨号。`null` = 没有字幕在显示。
  Stream<int?> get activeSubtitleTrackId;

  /// 播到结尾（**上升沿**语义由上层处理，这里发状态）。
  Stream<bool> get completed;

  /// 播放失败。一句话，给人读。
  ///
  /// ⚠️ 实现**原样转发**内核的报错，不做过滤。过滤是上层的事 ——
  /// mpv 的报错很吵（关键词不匹配的一律丢、字幕解码失败要分流到 [log]），
  /// 而那套规则是业务判断，不该散进每个实现里各写一遍。
  Stream<String> get error;

  /// 引擎原始日志。**能力缺失时永不发**（见 [EngineCapabilities.rawLog]）。
  ///
  /// 目前只有一处用途：**字幕解码失败的诊断**。mpv 把它发给 `sd_lavc`，
  /// 而 media_kit 只把特定 prefix 的 error 转发到 `stream.error` ——
  /// `sd_lavc` 不在白名单里，所以这条信息**只能**从日志流拿到
  /// （见 `isSubtitleDiagnosticLog`）。丢了它，本机 libmpv 解不开某种字幕
  /// 这件事就彻底不可见了。
  Stream<String> get log;

  /// 视频输出尺寸。**「出画面了没有」的唯一可靠判据**。
  Stream<EngineVideoSize> get videoSize;

  /// 缓冲百分比（0..1），引擎自己的口径，仅用于显示。
  Stream<double> get bufferingPercentage;

  /// 实时输入速率，**字节/秒**。能力缺失时永不发（见 [EngineCapabilities.networkSpeed]）。
  ///
  /// ⚠️ 单位是字节/秒，不是「秒」。它描述的是**从网络读进来多少数据**，
  /// 与 [bufferEnd]（缓存到哪个时间戳）是两个完全不同的量 —— 前者是带宽，
  /// 后者是位置。想显示成 KB/s 由 UI 换算。
  ///
  /// 拿不到读数时**不发**，而不是发 0：0 会被显示成「网速是 0」，
  /// 而真相是「不知道」（口径与 `rawInputBytesPerSecond` 一致）。
  Stream<double> get networkSpeed;

  /// 章节列表。**能力缺失或还没解出来时返回空列表**。
  ///
  /// 做成「拉」而不是「推」：调用方（跳片头）本来就是「播到某个位置时问一次」，
  /// 做成流的话每一拍都要维护一份状态，而章节在一次播放里根本不会变。
  Future<List<EngineChapter>> chapters();

  // -------------------------------------------------------------------
  // 命令
  // -------------------------------------------------------------------

  Future<void> open(EngineMedia media, {bool play = true});

  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> stop();

  Future<void> seek(Duration to);

  /// 音量，0..100（与现有设置里的口径一致）。
  Future<void> setVolume(double value);

  /// 倍速，1.0 = 原速。
  Future<void> setRate(double value);

  /// 切音轨。`null` = 交回引擎自己决定。
  Future<void> selectAudioTrack(int? id);

  /// 切字幕轨。`null` = **关掉字幕**。
  Future<void> selectSubtitleTrack(int? id);

  /// 挂一条**外部**字幕（按 URI）。
  ///
  /// ⚠️ 只接受 URI。两个内核**都**支持这一条，所以本地字幕（有路径）走它。
  Future<void> loadExternalSubtitle(String uri);

  /// 挂一条**外部**字幕，正文直接给（不走 URI）。
  ///
  /// ## 为什么它必须在契约里，而不是「调用方自己落成临时文件」
  ///
  /// 两个内核收字节的方式**不一样**：
  ///   - media_kit：`SubtitleTrack.data(text)` —— mpv 直接吃字符串，零成本；
  ///   - fvp：mdk 的 `setExternalSubtitle` **只吃 URI**，实现必须把正文落成
  ///     一个临时文件再下发。
  ///
  /// 网盘字幕（`SubtitleOrigin.cloudFile`）的正文是我们自己解码出来的
  /// **字符串**，没有地址。如果把「落临时文件」推给调用方，那件事就会落在
  /// `PlaybackController`（领域层）身上 —— 而它得因此引入 `dart:io` 与
  /// `path_provider`，为了一个纯粹的**内核差异**。所以兜底放在实现里：
  /// 调用方只管交出文本。
  ///
  /// ## 临时文件的回收
  ///
  /// 由**实现**负责：换源（[open]）与 [dispose] 时删掉上一份。
  /// 调用方不必知道它存在。
  Future<void> loadExternalSubtitleText(
    String text, {
    String? title,
    String? language,
  });

  Future<void> dispose();
}
