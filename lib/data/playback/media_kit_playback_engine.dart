import 'dart:async';

import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/utils/mpv_cache_state.dart';
import '../../core/utils/mpv_chapters.dart';
import '../../core/utils/player_buffer_config.dart';
import '../../core/utils/player_subtitle_config.dart';
import '../../core/utils/track_labels.dart';
import '../../domain/services/intro_marker.dart';
import '../../domain/services/playback_engine.dart';
import '../../domain/services/playback_media.dart';
import 'change_gate.dart';

/// media_kit（mpv）引擎。**默认内核**，除杜比视界以外的片源全走这里。
///
/// ## 这一份的职责是「原样包一遍」
///
/// 它**不引入任何新行为**：参数、默认值、裁剪范围、过滤规则全部照抄
/// `PlaybackController` 迁移之前的写法。理由很实际 —— 默认内核承担着
/// 100% 的既有片源，任何「顺手优化」都会变成一次全量回归。
///
/// 唯一真正新增的是 [networkSpeed] 的 1 Hz 轮询：那段逻辑原来长在
/// `player_window_app.dart` 里（`_startNetSpeedPolling`），契约要求它属于
/// 引擎，所以搬过来 —— 解析仍走同一个 [rawInputBytesPerSecond]，
/// 没有第二份实现。
///
/// ## 能力：最全，但 macOS 上渲染不了 DV
///
/// 见 [EngineCapabilities.mediaKit]。mpv 支持音效滤镜（`af` / `audio-channels`）、
/// 实时输入速率、原始日志流 —— 这些在 mdk 上都没有对等物。
///
/// ⚠️ 但 macOS 上 media_kit 走的是 mpv 的 **render API**（`vo=libmpv`），
/// `render_backends[]` 只有 `gpu` / `sw`，`vo=gpu-next` 架构上不可达 ——
/// 所以 DV Profile 5 在这条路上**不可能**渲染正确。这正是按需路由的理由。
///
/// ## 归属：本类**拥有** Player 与 VideoController
///
/// 两者都在构造函数里建出来，[dispose] 负责销毁。这是刻意的 ——
/// 与 [FvpPlaybackEngine] 对称，调用方不必记住「哪个引擎的东西要自己回收」。
///
/// [player] 仍然对外暴露，因为有几个 mpv **专有**能力不走契约：
/// 音效（`PlayerAudioEffect.apply`）与缓冲调优（`PlayerBufferConfig.apply`）。
/// 契约里没有它们是因为 mdk 没有对等物（[EngineCapabilities.audioEffects]
/// / [EngineCapabilities.rawProperty] 都是 false），不是因为它们不该被调用。
class MediaKitPlaybackEngine implements PlaybackEngine {
  /// [tv] 决定缓冲参数与上限。判据由调用方给（`isTvDevice()`）——
  /// 引擎不该自己去猜平台，那是可以注入的、能测的输入。
  ///
  /// [verboseLog] 把 mpv 的日志级别抬到 `warn`。
  ///
  /// ## ⚠️ 只有独立播放窗口需要它，而且是**必要条件**
  ///
  /// 抬高之后 `log` 流才会带上 `http: HTTP error 4xx`（实测是 **warn** 级，
  /// 而 media_kit 默认只请求 `error`）。独立窗口的「直链过期 → 自动重新取链」
  /// 全靠这一条，缺了它用户实际会遇到的那种过期**一次都检测不到**。
  /// 完整实测记录见 `player_protocol.dart` 的 `isHttp4xxLog`。
  ///
  /// 内置播放页**不开**（保持默认 `error`）：它没有那条过期检测，
  /// 而 warn 级会把字幕诊断之外的一堆噪音也放进日志缓冲。
  MediaKitPlaybackEngine({bool tv = false, bool verboseLog = false})
      : _player = mk.Player(
          configuration: mk.PlayerConfiguration(
            logLevel: verboseLog ? mk.MPVLogLevel.warn : mk.MPVLogLevel.error,
            // TV 上换一套更小的缓冲：桌面那套（1 GB + 无限预读）在电视盒子上
            // 会把内存和 eMMC 写满，实测表现就是卡帧 + 音画不同步。
            // 判据与理由都在 `PlayerBufferConfig` 的类文档里。
            bufferSize: PlayerBufferConfig.bufferSizeFor(tv: tv),
            // ⚠️ 必须给：缺了它 media_kit 会把 `sub-visibility` 设成 `no`，
            // **所有**字幕都不显示且不报错。原因见 `PlayerSubtitleConfig`。
            libass: PlayerSubtitleConfig.useLibass,
          ),
        ) {
    // 渲染控制器**必须**绑定到上面那个 player，且必须在任何 `open()` 之前
    // 建出来。
    //
    // 这里曾经写的是 `VideoController(mk.Player())` —— 一个**新建的**实例。
    // 于是「解码」和「出画面」落在两个互不相干的 mpv 实例上：player 照常
    // 解码音频（有声音、进度条正常），但它从来没有视频输出端，画面永远是
    // 空的，而且**不报任何错**。实测症状：mp4 4K 只有声音没画面。
    videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        // 让 mpv 在已知有问题的驱动上自动退回软解，比强制硬解稳。
        enableHardwareAcceleration: true,
      ),
    );
    _bindStreams();
    // 补 media_kit 构造参数管不到的 mpv 缓冲属性（demuxer-readahead-secs）。
    // setProperty 内部等播放器初始化完成再设，不需要在这里同步等待。
    unawaited(PlayerBufferConfig.apply(_player, tv: tv));
  }

  final mk.Player _player;
  bool _disposed = false;

  /// mpv 播放器实例。
  ///
  /// ⚠️ 暴露它是**刻意的例外**：音效与缓冲调优是 mpv 专有能力，
  /// 契约里没有（mdk 无对等物）。别拿它去绕开契约 —— 起播、切轨、字幕
  /// 一律走本类的方法，否则业务规则（清晰度要重取链、外挂字幕要先解码）
  /// 会被绕过。
  mk.Player get player => _player;

  /// 交给 UI 的渲染句柄（`Video(controller: ...)`）。
  ///
  /// ⚠️ 领域层的契约**故意不带这个方法**（领域层不引 Flutter）。
  /// UI 层按引擎的具体类型决定用哪个渲染组件，见
  /// `ui/widgets/playback_surface.dart`。
  late final VideoController videoController;

  @override
  EngineCapabilities get capabilities => EngineCapabilities.mediaKit;

  // -------------------------------------------------------------------
  // 事件
  // -------------------------------------------------------------------

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _bufferEnd = StreamController<Duration>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _rate = StreamController<double>.broadcast();
  final _tracks = StreamController<EngineTracks>.broadcast();
  final _activeAudio = StreamController<int?>.broadcast();
  final _activeSubtitle = StreamController<int?>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _log = StreamController<String>.broadcast();
  final _videoSize = StreamController<EngineVideoSize>.broadcast();
  final _bufferingPercentage = StreamController<double>.broadcast();
  final _networkSpeed = StreamController<double>.broadcast();

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get buffering => _buffering.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;

  /// ⚠️ **直接转发**，不做换算。
  ///
  /// mpv 的 `demuxer-cache-time`（media_kit 的 `player.stream.buffer`）本来
  /// 就是**绝对时间戳**，与契约要求的参照系一致 —— 所以这里**不能**再调
  /// [EngineTimeRange.cacheEndAt]。那个换算点是给 mdk 的「区间列表」用的，
  /// 套到 mpv 的标量上会变成「拿一个数字去找包含它的区间」，语义完全错位。
  @override
  Stream<Duration> get bufferEnd => _bufferEnd.stream;

  @override
  Stream<double> get volume => _volume.stream;
  @override
  Stream<double> get rate => _rate.stream;
  @override
  Stream<EngineTracks> get tracks => _tracks.stream;
  @override
  Stream<int?> get activeAudioTrackId => _activeAudio.stream;
  @override
  Stream<int?> get activeSubtitleTrackId => _activeSubtitle.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get error => _error.stream;
  @override
  Stream<String> get log => _log.stream;
  @override
  Stream<EngineVideoSize> get videoSize => _videoSize.stream;
  @override
  Stream<double> get bufferingPercentage => _bufferingPercentage.stream;
  @override
  Stream<double> get networkSpeed => _networkSpeed.stream;

  // 值没变就不发。规则本体见 [ChangeGate]。
  final _gPlaying = ChangeGate<bool>();
  final _gBuffering = ChangeGate<bool>();
  final _gPosition = ChangeGate<Duration>();
  final _gDuration = ChangeGate<Duration>();
  final _gBufferEnd = ChangeGate<Duration>();
  final _gVolume = ChangeGate<double>();
  final _gRate = ChangeGate<double>();
  final _gTracks = ChangeGate<String>();
  final _gActiveAudio = ChangeGate<int?>();
  final _gActiveSubtitle = ChangeGate<int?>();
  final _gCompleted = ChangeGate<bool>();
  final _gError = ChangeGate<String>();
  final _gVideoSize = ChangeGate<EngineVideoSize>();
  final _gBufferingPercentage = ChangeGate<double>();
  final _gNetworkSpeed = ChangeGate<double>();

  // -------------------------------------------------------------------
  // 命令
  // -------------------------------------------------------------------

  @override
  Future<void> open(EngineMedia media, {bool play = true}) async {
    if (_disposed) return;
    _resetGates();

    // ⚠️ 起播位置走 `Media(start:)` 而**不是**「open 之后再 seek」。
    //
    // media_kit 把 `start` 落成「在 mpv 的 `on_load` 钩子里设 start 属性」，
    // 而 `Player.open()` **不等**文件加载完成（它只发 `loadlist`），紧跟的
    // 一次 `seek` 落在解复用器就绪之前就被丢掉 —— 那正是本项目「续播点了
    // 没用、每次都从头开始」的根因。实测记录（含 HLS）见 [PlaybackMedia]。
    //
    // 同理 `start` 会**残留**：mpv 不会在加载完之后清掉它，所以不续播时也
    // 必须显式写 0（`PlaybackMedia.build` 的 `startAt` 默认值就是
    // `Duration.zero`，不给 null 的唯一原因）。
    await _player.open(
      PlaybackMedia.build(
        media.url,
        headers: media.headers,
        startAt: media.startAt,
      ),
      play: play,
    );
    _startNetSpeedPolling();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> stop() async {
    _stopNetSpeedPolling();
    await _player.stop();
  }

  /// 绝对跳转。**不在这里夹取** —— 裁剪规则（`clampSeekTarget`）属于业务：
  /// 独立播放窗口用的是同一套，留在调用方才能保证只有一份。
  @override
  Future<void> seek(Duration to) => _player.seek(to);

  /// 契约口径是 0..100（与设置里存的一致），mpv 也是 0..100。
  @override
  Future<void> setVolume(double value) =>
      _player.setVolume(value.clamp(0.0, 100.0));

  /// 0.25x ~ 4x 是合理范围；超出会被 mpv 静默夹住，不如我们自己夹，
  /// 这样 UI 上显示的倍速与实际一致。
  @override
  Future<void> setRate(double value) =>
      _player.setRate(value.clamp(0.25, 4.0));

  /// `null` = 交回引擎自己决定 → mpv 的 `auto`（选第一条）。
  ///
  /// ⚠️ 与 [FvpPlaybackEngine] 的同一方法是**不同语义**：mdk 那边
  /// `setActiveTracks(audio, [])` 是「一条都不选」＝静音，所以它把 null
  /// 当空操作。这里能真正表达「让引擎决定」，因为 mpv 有 `auto` 这个轨。
  @override
  Future<void> selectAudioTrack(int? id) => _player.setAudioTrack(
        id == null
            ? mk.AudioTrack.auto()
            : mk.AudioTrack('$id', null, null),
      );

  /// `null` = **关掉字幕**（mpv 的 `no`）。
  @override
  Future<void> selectSubtitleTrack(int? id) => _player.setSubtitleTrack(
        id == null
            ? mk.SubtitleTrack.no()
            : mk.SubtitleTrack('$id', null, null),
      );

  @override
  Future<void> loadExternalSubtitle(String uri) =>
      _player.setSubtitleTrack(mk.SubtitleTrack.uri(uri));

  /// mpv **能直接吃字符串**，所以这条对 media_kit 是零成本的。
  ///
  /// ⚠️ 与 [FvpPlaybackEngine] 的同一方法**实现完全不同**（那边要落临时文件）
  /// —— 这正是它被放进契约、而不是推给调用方的原因，见契约里的类文档。
  @override
  Future<void> loadExternalSubtitleText(
    String text, {
    String? title,
    String? language,
  }) =>
      _player.setSubtitleTrack(
        mk.SubtitleTrack.data(text, title: title, language: language),
      );

  /// 读一次章节清单。
  ///
  /// 解析复用 [MpvChapters.read]（mpv 的 `chapter-list` 属性）。
  /// 读的**时机**由调用方决定：必须等 `position > 0`（容器解析完），
  /// 早读会拿到空列表而与「这个文件没章节」无法区分 —— 理由见
  /// [MpvChapters] 的类文档。
  @override
  Future<List<EngineChapter>> chapters() async {
    final raw = await MpvChapters.read(_player);
    return chaptersFrom(raw, _player.state.duration);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _stopNetSpeedPolling();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    await Future.wait<void>(<Future<void>>[
      _playing.close(),
      _buffering.close(),
      _position.close(),
      _duration.close(),
      _bufferEnd.close(),
      _volume.close(),
      _rate.close(),
      _tracks.close(),
      _activeAudio.close(),
      _activeSubtitle.close(),
      _completed.close(),
      _error.close(),
      _log.close(),
      _videoSize.close(),
      _bufferingPercentage.close(),
      _networkSpeed.close(),
    ]);

    // 本类拥有 Player 与 VideoController（见类文档），由这里销毁。
    await _player.dispose();
  }

  // -------------------------------------------------------------------
  // 纯函数（可单测，不依赖 Player 实例）
  // -------------------------------------------------------------------

  /// mpv 的轨道号 → 契约的整数 id。
  ///
  /// ⚠️ **不是** `int.parse`：media_kit 的 `tracks.*` 前两条是合成轨
  /// （`auto` / `no`），它们的 `id` 是字符串而不是轨道号。解析不了就返回
  /// `null`，那正是「没有选中任何轨」的正确表示。
  static int? parseTrackId(String? id) => id == null ? null : int.tryParse(id);

  /// `mk.Tracks` → 契约的轨道快照。
  ///
  /// 过滤规则委托给 [TrackLabels.realTracks]：合成轨（`auto` / `no`）必须
  /// 剔掉，否则菜单里会多出两条「点了没反应」的选项，而自动选字幕取
  /// 「第一条」时**每次都会选中它们**。规则本体在那边，别在这里另写一份。
  static EngineTracks mapTracks(mk.Tracks tracks) => EngineTracks(
        video: <EngineTrack>[
          for (final t in TrackLabels.realTracks(tracks.video, (t) => t.id))
            _trackOf(
              id: t.id,
              title: t.title,
              language: t.language,
              codec: t.codec,
              isDefault: t.isDefault,
            ),
        ],
        audio: <EngineTrack>[
          for (final t in TrackLabels.realTracks(tracks.audio, (t) => t.id))
            _trackOf(
              id: t.id,
              title: t.title,
              language: t.language,
              codec: t.codec,
              isDefault: t.isDefault,
            ),
        ],
        subtitle: <EngineTrack>[
          for (final t in TrackLabels.realTracks(tracks.subtitle, (t) => t.id))
            _trackOf(
              id: t.id,
              title: t.title,
              language: t.language,
              codec: t.codec,
              isDefault: t.isDefault,
            ),
        ],
      );

  /// mpv 的章节清单 → 契约的章节列表。
  ///
  /// ## 这里有一处**语义补全**，不是照抄
  ///
  /// mpv 的 `chapter-list` **只给起点**（`IntroChapter` 只有 `title` + `start`），
  /// 而契约要求 `[start, end]`。补法是行业惯例：**一章延伸到下一章的起点**，
  /// 最后一章延伸到片尾（[mediaDuration]）。
  ///
  /// ⚠️ 片尾补不上时（`mediaDuration` 还没解出来，或它比起点还小）退化成
  /// 「终点 = 起点」，于是 `duration` 是 0。这是**诚实的**退化 —— 章节清单
  /// 的用途只有「认片头」，而认片头只看 `start`；编一个假终点反而会污染
  /// `EngineChapter.duration`。
  ///
  /// 同时做一次单调保护：mpv 理论上按序给，但真出现乱序时 `end < start`
  /// 会让 `duration` 变负数 —— 那种值流到界面上是「负数时长」，
  /// 比退化到 0 难查得多。
  static List<EngineChapter> chaptersFrom(
    List<IntroChapter> raw,
    Duration mediaDuration,
  ) {
    if (raw.isEmpty) return const <EngineChapter>[];

    return <EngineChapter>[
      for (var i = 0; i < raw.length; i++)
        EngineChapter(
          start: raw[i].start,
          end: _endOf(raw, i, mediaDuration),
          title: raw[i].title,
        ),
    ];
  }

  static Duration _endOf(
    List<IntroChapter> raw,
    int index,
    Duration mediaDuration,
  ) {
    final start = raw[index].start;
    final next = index + 1 < raw.length ? raw[index + 1].start : mediaDuration;
    // 终点不得早于起点（乱序 / 片长未知两种情况下都会撞上）。
    return next > start ? next : start;
  }

  static EngineTrack _trackOf({
    required String id,
    String? title,
    String? language,
    String? codec,
    bool? isDefault,
  }) =>
      EngineTrack(
        // 上游 `realTracks` 已经保证能解析成整数，所以这里用 `parse` 而不是
        // `tryParse`：真解析不了就应当炸出来，而不是静默产出一条没有轨道号的轨。
        id: int.parse(id),
        title: title,
        language: language,
        codec: codec,
        isDefault: isDefault ?? false,
      );

  // -------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------

  final List<StreamSubscription<Object?>> _subs = [];

  void _bindStreams() {
    final s = _player.stream;

    _subs.add(s.playing.listen((v) {
      if (_gPlaying.accept(v)) _playing.add(v);
    }));
    _subs.add(s.buffering.listen((v) {
      if (_gBuffering.accept(v)) _buffering.add(v);
    }));
    _subs.add(s.position.listen((v) {
      if (_gPosition.accept(v)) _position.add(v);
    }));
    _subs.add(s.duration.listen((v) {
      if (_gDuration.accept(v)) _duration.add(v);
    }));

    // 缓冲终点是**绝对时间戳**，直接转发（见 [bufferEnd] 的文档）。
    _subs.add(s.buffer.listen((v) {
      if (_gBufferEnd.accept(v)) _bufferEnd.add(v);
    }));

    // 音量 / 倍速：mpv 的浮点会抖，闸是必须的（容差判断留给闸的 `==`，
    // 因为 mpv 报的是它自己存的值，同一次设置不会给出两个不同的 double）。
    _subs.add(s.volume.listen((v) {
      if (_gVolume.accept(v)) _volume.add(v);
    }));
    _subs.add(s.rate.listen((v) {
      if (_gRate.accept(v)) _rate.add(v);
    }));

    // 内嵌轨清单：mpv 解完文件头之后才可用，所以这是**流**而不是一次性查询。
    _subs.add(s.tracks.listen((t) {
      final mapped = mapTracks(t);
      if (_gTracks.accept(mapped.signature)) _tracks.add(mapped);
    }));

    // 当前选中的轨。**只认 mpv 的回报**，不看我们下发过什么 ——
    // 切轨成功与否只有 mpv 说了算。
    _subs.add(s.track.listen((t) {
      final audio = parseTrackId(t.audio.id);
      final subtitle = parseTrackId(t.subtitle.id);
      if (_gActiveAudio.accept(audio)) _activeAudio.add(audio);
      if (_gActiveSubtitle.accept(subtitle)) _activeSubtitle.add(subtitle);
    }));

    _subs.add(s.completed.listen((v) {
      if (_gCompleted.accept(v)) _completed.add(v);
    }));

    _subs.add(s.error.listen((msg) {
      // 原样转发，不做过滤（见契约里 [PlaybackEngine.error] 的文档）。
      // mpv 很吵，过滤规则在上层。
      if (_gError.accept(msg)) _error.add(msg);
    }));

    // ⚠️ 字幕那条**只能靠日志流**：media_kit 只把特定 prefix 的 error 转发到
    // `stream.error`（`file` / `ffmpeg`（text 必须以 `tcp:` 开头）/ `vd` /
    // `ad` / `cplayer` / `stream`），而报字幕解码失败的是 `sd_lavc` ——
    // 不在白名单里。所以这里**不能**因为「已经监听了 error」就省掉。
    //
    // 不过闸：日志本来就是有则报的流水，重复文本同样是新事件。
    _subs.add(s.log.listen((entry) => _log.add(entry.text)));

    // 「出画面了没有」的判据。`videoParams` 要等 mpv 解出第一帧才能定输出
    // 格式，所以它是**最准**的那个（独立窗口那条路也是这么判的）。
    _subs.add(s.videoParams.listen((p) {
      final size = EngineVideoSize(p.w ?? 0, p.h ?? 0);
      if (_gVideoSize.accept(size)) _videoSize.add(size);
    }));

    _subs.add(s.bufferingPercentage.listen((v) {
      if (_gBufferingPercentage.accept(v)) _bufferingPercentage.add(v);
    }));
  }

  /// 换源时闸要归零：新流的 duration / 轨道 id 与旧流无关，
  /// 不归零的话「新流的值恰好等于旧流」会被判成没变而不上报。
  void _resetGates() {
    _gPlaying.reset();
    _gBuffering.reset();
    _gPosition.reset();
    _gDuration.reset();
    _gBufferEnd.reset();
    _gVolume.reset();
    _gRate.reset();
    _gTracks.reset();
    _gActiveAudio.reset();
    _gActiveSubtitle.reset();
    _gCompleted.reset();
    _gError.reset();
    _gVideoSize.reset();
    _gBufferingPercentage.reset();
    _gNetworkSpeed.reset();
  }

  // -------------------------------------------------------------------
  // 实时输入速率（1 Hz 轮询）
  // -------------------------------------------------------------------

  Timer? _netSpeedTimer;

  /// 开始 1 Hz 轮询 `demuxer-cache-state`。重复调用只会重置计时器。
  ///
  /// 用轮询而不是 `observeProperty`：那个属性是 **node 类型**，mpv 的变更
  /// 通知不保证发；1 Hz 读一个字符串的代价可以忽略。这段逻辑原来长在
  /// `player_window_app.dart` 里，搬进来是为了让契约的 [networkSpeed]
  /// 有唯一来源 —— 两个播放器各轮询一次会得到两份不同的读数。
  void _startNetSpeedPolling() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_readNetSpeed()),
    );
  }

  void _stopNetSpeedPolling() {
    _netSpeedTimer?.cancel();
    _netSpeedTimer = null;
  }

  /// 读一次 mpv 的输入速率。**绝不抛** —— 它跑在播放路径上。
  ///
  /// 任何失败（播放器还没建好、已 dispose、属性读不到）都只是这一拍不发：
  /// 「不知道」不等于「网速是 0」。解析本体在 [rawInputBytesPerSecond]。
  Future<void> _readNetSpeed() async {
    if (_disposed) return;
    final platform = _player.platform;
    // 平台不是 `NativePlayer`（理论上只有 web，本应用不涉及）时读不到。
    if (platform is! mk.NativePlayer) return;
    try {
      final state = await platform.getProperty('demuxer-cache-state');
      if (_disposed) return;
      final bytes = rawInputBytesPerSecond(state);
      if (bytes == null) return;
      if (_gNetworkSpeed.accept(bytes)) _networkSpeed.add(bytes);
    } catch (_) {
      // 静默：速率读数拿不到不该影响播放，也不该刷日志（1 Hz 会刷满）。
    }
  }
}
