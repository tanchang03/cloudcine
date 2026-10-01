import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../core/utils/playback_seek.dart';
import '../../core/utils/player_buffer_config.dart';
import '../../core/utils/subtitle_formats.dart';
import '../../core/utils/track_labels.dart';
import '../adapters/cloud_drive_adapter.dart';
import '../entities/media_item.dart';
import '../entities/quality_option.dart';
import '../entities/stream_ticket.dart';
import '../entities/subtitle_track.dart';
import 'playback_media.dart';
import 'subtitle_service.dart';

/// 播放控制器 —— 本应用「能不能看」这件事的唯一裁决者。
///
/// ## 为什么用 media_kit（mpv）而不是 `video_player`
///
/// | 能力 | mpv | `video_player` |
/// |---|---|---|
/// | 容器 | MKV / AVI / TS / RMVB / FLV 全能 | 平台支持什么就是什么 |
/// | 内嵌字幕 | ASS/SSA 完整特效渲染 | 基本没有 |
/// | 外挂字幕 | 直接加载，编码可控 | 不支持 |
/// | 自定义请求头 | 支持 | 支持但有限 |
///
/// 本应用的核心场景是「播用户网盘里已有的片子」：容器五花八门，
/// 而且**必须带 Cookie 才能取到流**（夸克直链缺 Cookie 一律 412）。
/// mpv 是唯一一个两边都能满足的后端。
///
/// ## 状态设计
///
/// 所有可变状态都在这个对象上，UI 通过 `ChangeNotifier` 重建。
/// **不把 `Player` 暴露给 UI**：那样 UI 就会开始直接调 mpv，
/// 「清晰度切换要重取链」「外挂字幕要先解码」这类业务规则会被绕过。
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required DriveAdapterRegistry registry,
    required SubtitleResolver subtitleResolver,
    Duration positionSaveInterval = const Duration(seconds: 10),
  })  : _registry = registry,
        _subtitleResolver = subtitleResolver,
        _positionSaveInterval = positionSaveInterval {
    // 渲染控制器**必须**绑定到上面那个 [player]，并且必须在任何 `open()`
    // 之前就建出来。
    //
    // 这里曾经写的是 `VideoController(mk.Player())` —— 一个**新建的**实例。
    // 于是「解码」和「出画面」落在两个互不相干的 mpv 实例上：`player` 照常
    // 解码音频（**有声音、进度条正常**），但它从来没有视频输出端，
    // 画面永远是空的，而且**不报任何错**。
    // 实测症状：mp4 4K 只有声音没画面。
    //
    // 「在 `open()` 之前」同样是硬要求：mpv 要拿到视频输出端之后才会把画面
    // 送过去，晚一步这一次播放就全程没画面。放在构造函数里是唯一不依赖
    // 调用顺序的写法 —— 播放页是在 post-frame 回调里才 `open()` 的，
    // 如果这里改成 `late` 惰性初始化，正确性就押在「UI 恰好先 build 过一次」
    // 这种时序巧合上了。
    videoController = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        // 让 mpv 在已知有问题的驱动上自动退回软解，比强制硬解稳。
        enableHardwareAcceleration: true,
      ),
    );
    _bindPlayerStreams();
    // 补 media_kit 构造参数管不到的 mpv 缓冲属性（demuxer-readahead-secs）。
    // setProperty 内部等播放器初始化完成再设，不需要在 open() 之前同步等待。
    unawaited(PlayerBufferConfig.apply(player));
  }

  final DriveAdapterRegistry _registry;
  final SubtitleResolver _subtitleResolver;
  final Duration _positionSaveInterval;

  /// mpv 播放器实例。**只在本类内部使用**。
  ///
  /// 缓冲上限 256 MB（media_kit 默认 32 MB 对高码率原画远远不够），
  /// 预读目标在 [PlayerBufferConfig.apply] 里设。两个播放器（本类 +
  /// 独立窗口 `player_window_app.dart`）共用同一份配置。
  final mk.Player player = mk.Player(
    configuration: const mk.PlayerConfiguration(
      bufferSize: PlayerBufferConfig.bufferSize,
    ),
  );

  /// 渲染控制器，交给 `Video(controller: ...)`。
  ///
  /// 在构造函数体里赋值（见下），**不能**写成字段初始化器：Dart 的实例字段
  /// 初始化器不允许访问 `this`，而它必须绑定到上面那个 [player]。
  late final VideoController videoController;

  // -------------------------------------------------------------------
  // 对外状态
  // -------------------------------------------------------------------

  MediaItem? _item;
  StreamTicket? _ticket;
  String? _activeQualityId;
  bool _loading = false;
  String? _error;

  /// 非致命提示（字幕加载失败、选的档位服务端没给地址…）。
  ///
  /// **绝不能塞进 [_error]**：`error` 在播放页是一层 **88% 不透明的全屏遮罩**，
  /// 会把画面整个盖住。「这条字幕没加载上」不该让用户看不到视频 ——
  /// 实测踩过：自动选字幕失败 → 画面被「播放失败」遮住，声音却还在放，
  /// 用户以为播放器坏了。
  String? _notice;

  List<SubtitleTrack> _externalSubtitles = const [];
  List<SubtitleTrack> _embeddedSubtitles = const [];
  List<mk.AudioTrack> _embeddedAudio = const [];
  String? _activeSubtitleId;
  bool _subtitlesEnabled = true;

  bool _buffering = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 100;
  double _rate = 1.0;

  /// 当前正在播放的媒体项
  MediaItem? get item => _item;

  /// 当前票据（含全部清晰度档位）
  StreamTicket? get ticket => _ticket;

  /// 可选清晰度。**空列表是正常状态**：服务端没给转码梯度时只有原画。
  List<QualityOption> get qualities => _ticket?.qualities ?? const [];

  String? get activeQualityId => _activeQualityId;

  bool get isLoading => _loading;
  String? get error => _error;
  bool get hasError => _error != null;

  /// 非致命提示，UI 应当**不遮挡画面**地展示它（见 [_notice]）。
  String? get notice => _notice;

  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// 网盘外挂字幕（扫描期建立的引用）
  List<SubtitleTrack> get externalSubtitles => _externalSubtitles;

  /// 视频内嵌字幕轨（mpv 解出来的）
  List<SubtitleTrack> get embeddedSubtitles => _embeddedSubtitles;

  /// 全部可选字幕（外挂 + 内嵌），**按偏好排序**（中文优先）
  List<SubtitleTrack> get allSubtitles {
    final all = [...externalSubtitles, ...embeddedSubtitles];
    all.sort((a, b) => a.preferenceScore.compareTo(b.preferenceScore));
    return all;
  }

  List<mk.AudioTrack> get embeddedAudioTracks => _embeddedAudio;

  String? get activeSubtitleId => _activeSubtitleId;
  bool get subtitlesEnabled => _subtitlesEnabled;

  bool get isBuffering => _buffering;
  bool get isPlaying => _playing;
  Duration get position => _position;
  Duration get duration => _duration;

  /// 音量（0..100，与 mpv 口径一致）
  double get volume => _volume;

  double get rate => _rate;

  bool get hasMedia => _item != null;

  /// 进度（0..1）。时长未知时返回 0。
  double get progress {
    final total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// 是否可以切清晰度（UI 据此决定显不显示那个按钮）。
  bool get canSwitchQuality => qualities.length > 1;

  /// 进度回调（每 [positionSaveInterval] 触发一次）。
  ///
  /// 控制器本身**不依赖仓储**：落库由 UI 层接这个回调完成。
  /// 这样播放控制器可以在单元测试里独立构造。
  void Function(Duration position)? onPositionTick;

  // -------------------------------------------------------------------
  // 打开与取链
  // -------------------------------------------------------------------

  /// 打开一个媒体项。
  ///
  /// [subtitles] 是扫描期建立的字幕引用（可为空）。
  /// [preferredQualityId] 是设置里的默认档位（可为空 = 原画优先）。
  Future<void> open(
    MediaItem item, {
    List<SubtitleTrack> subtitles = const [],
    String? preferredQualityId,
    bool autoLoadSubtitles = true,
  }) async {
    _item = item;
    _error = null;
    _notice = null;
    _loading = true;
    _position = Duration.zero;
    _duration = Duration.zero;
    _externalSubtitles = subtitles;
    _embeddedSubtitles = const [];
    _embeddedAudio = const [];
    _activeSubtitleId = null;
    _subtitlesEnabled = autoLoadSubtitles;
    _subtitleResolver.clear();
    notifyListeners();

    diag.section('播放 ${item.displayTitle}');
    diag.info(
      '播放',
      'fid=${item.fileId} 容器=${item.container.label} '
      '分辨率=${item.resolution?.label ?? "-"} 体积=${item.sizeBytes ?? "-"}B '
      '外挂字幕=${subtitles.length} 条',
    );

    try {
      final adapter = _registry.requireAdapter(item.provider);
      final ticket = await adapter.resolveStream(
        item.fileId,
        qualityId: preferredQualityId,
      );

      _ticket = ticket;
      _activeQualityId = _pickActiveQualityId(ticket, preferredQualityId);

      await _loadIntoPlayer(ticket);
      _loading = false;
      notifyListeners();

      if (_subtitlesEnabled) {
        unawaited(_autoLoadSubtitle());
      }
    } on DriveException catch (e) {
      _loading = false;
      _error = _explain(e);
      diag.error('播放', '取链失败：$e');
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = '播放失败：$e';
      diag.error('播放', '意外错误：$e');
      notifyListeners();
    }
  }

  /// 把票据交给 mpv。
  ///
  /// ⚠️ **请求头是必须的**。夸克直链缺 Cookie 一律返回 412，
  /// 表现是「能扫描、一播就报错」，而错误信息里看不出是缺头。
  ///
  /// [startAt] 是起播位置，走 [PlaybackMedia]（也就是 `Media(start:)`）而不是
  /// 「open 之后再 seek」—— 后者**无效**：`Player.open()` 不等文件加载完成，
  /// 紧跟的那次 seek 会被丢掉。实测记录见 [PlaybackMedia] 的类文档。
  Future<void> _loadIntoPlayer(
    StreamTicket ticket, {
    Duration startAt = Duration.zero,
  }) async {
    diag.info(
      '播放',
      '交给播放器：${ticket.redactedUrl} '
      '请求头=${ticket.headers.keys.toList()} '
      '档位=${_activeQualityId ?? "-"} '
      '起播=${startAt.inSeconds}s',
    );
    await player.open(
      PlaybackMedia.build(
        ticket.url.toString(),
        headers: ticket.headers,
        startAt: startAt,
      ),
      play: true,
    );
  }

  /// 决定「当前应该用哪一档」。
  ///
  /// 规则本体在 [StreamTicket.pickActiveQualityId] —— **独立播放窗口那条路
  /// 也要用同一套**（主窗口取到票据后据此决定把哪一档的地址发出去），
  /// 所以判定不能留在这一层。这里只保留一个同名薄委托，让调用点不必改。
  String? _pickActiveQualityId(StreamTicket ticket, String? preferred) =>
      ticket.pickActiveQualityId(preferred);

  /// 切换清晰度。
  ///
  /// 夸克各档位流是**同一个 fid 的不同转码产物**，地址在第一次取链时就
  /// 一起拿到了（见 `QuarkPlayInfoParser`），所以这里**不需要重新取链** ——
  /// 直接换 URL 重开即可。位置与播放状态由本方法自己恢复。
  Future<void> switchQuality(String qualityId) async {
    final ticket = _ticket;
    if (ticket == null) return;

    final q = ticket.qualityById(qualityId);
    if (q == null) {
      diag.warn('播放', '档位 $qualityId 不存在，忽略');
      return;
    }
    if (!q.isAvailable) {
      // 非致命：当前这一档还在正常播，切不过去只是没切。
      _notice = '「${q.label}」这一档服务端没有提供播放地址';
      notifyListeners();
      return;
    }

    final resumeAt = _position;
    final wasPlaying = _playing;

    diag.info(
      '播放',
      '切换清晰度 → ${q.label}（${q.id}），恢复到 ${resumeAt.inSeconds}s',
    );

    _loading = true;
    _error = null;
    _notice = null;
    notifyListeners();

    try {
      final next = ticket.withQuality(q);
      _ticket = next;
      _activeQualityId = q.id;
      // 位置**必须**交给 `Media(start:)`：mpv 换源后位置归零，不恢复的话用户
      // 每切一次清晰度就得自己拖回去。
      //
      // ⚠️ 这里原来写的是「open 之后 `player.seek(resumeAt)`」—— 那次 seek 会
      // 被丢掉（`Player.open()` 不等文件加载完成），所以「切清晰度回片头」
      // 是个已经存在的行为，只是没人把它和续播失败联系起来。实测见
      // [PlaybackMedia] 的类文档。
      await _loadIntoPlayer(next, startAt: resumeAt);

      if (!wasPlaying) await player.pause();

      _loading = false;
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = '切换清晰度失败：$e';
      diag.error('播放', '切换清晰度失败：$e');
      notifyListeners();
    }
  }

  /// 重新取链（票据过期 / 播放中断时用）。
  Future<void> retry() async {
    final item = _item;
    if (item == null) return;
    await open(
      item,
      subtitles: _externalSubtitles,
      preferredQualityId: _activeQualityId,
      autoLoadSubtitles: _subtitlesEnabled,
    );
  }

  // -------------------------------------------------------------------
  // 字幕
  // -------------------------------------------------------------------

  /// 自动挑一条字幕加载。
  ///
  /// 排序已由 [SubtitleTrack.preferenceScore] 定好（中文优先、非强制优先、
  /// 文本字幕优先），所以「第一条」就是最合适的那条。
  Future<void> _autoLoadSubtitle() async {
    final all = allSubtitles;
    if (all.isEmpty) return;
    await selectSubtitle(all.first);
  }

  /// 选中一条字幕。传 `null` 表示关闭字幕。
  Future<void> selectSubtitle(SubtitleTrack? track) async {
    if (track == null) {
      _activeSubtitleId = null;
      _subtitlesEnabled = false;
      await player.setSubtitleTrack(mk.SubtitleTrack.no());
      notifyListeners();
      return;
    }

    try {
      switch (track.origin) {
        case SubtitleOrigin.embedded:
          // 内嵌轨：mpv 自己切轨。`id` 就是 mpv 的 `sid`。
          final id = track.embeddedTrackId;
          if (id == null) {
            // 兜底分支。正常情况下 `_onTracksChanged` 已经把「没有轨道号」
            // 的合成轨（media_kit 的 `auto` / `no`）过滤掉了，走不到这里。
            _notice = '这条内嵌字幕没有轨道号，无法切换';
            notifyListeners();
            return;
          }
          await player.setSubtitleTrack(mk.SubtitleTrack('$id', null, null));

        case SubtitleOrigin.cloudFile:
          // 网盘字幕：我们自己取字节 + 解码成 UTF-8 文本，再交给播放器。
          // 这一步同时解决了「请求头」和「GBK 编码」两个问题。
          final resolved = await _subtitleResolver.load(track);
          if (!resolved.isText) {
            throw StateError('网盘字幕应当解出文本');
          }
          await player.setSubtitleTrack(
            mk.SubtitleTrack.data(
              resolved.text!,
              title: track.displayLabel,
              language:
                  track.languageCode.isEmpty ? null : track.languageCode,
            ),
          );

        case SubtitleOrigin.localFile:
          final resolved = await _subtitleResolver.load(track);
          final path = resolved.path;
          if (path == null) throw StateError('本地字幕缺少路径');
          await player.setSubtitleTrack(
            mk.SubtitleTrack.uri(
              path,
              title: track.displayLabel,
              language:
                  track.languageCode.isEmpty ? null : track.languageCode,
            ),
          );
      }
      _activeSubtitleId = track.id;
      _subtitlesEnabled = true;
      _notice = null;
    } catch (e) {
      // 字幕失败**不是播放失败**：视频照常放，只是这条字幕没挂上。
      // 所以走 `_notice` 而不是 `_error` —— 后者会拉起全屏遮罩盖住画面。
      _notice = '加载字幕失败：$e';
      diag.warn('字幕', '加载失败（${track.displayLabel}）：$e');
    }
    notifyListeners();
  }

  /// 开/关字幕。
  Future<void> setSubtitlesEnabled(bool enabled) async {
    if (!enabled) {
      await selectSubtitle(null);
      return;
    }
    final all = allSubtitles;
    if (all.isEmpty) {
      _subtitlesEnabled = true;
      notifyListeners();
      return;
    }
    await selectSubtitle(all.first);
  }

  /// 追加一条本地字幕（用户从磁盘选的）。
  ///
  /// 这是**不落库**的：用户临时选的字幕只对本次播放有效。
  /// 想让它长期生效要放到网盘上（那才是本应用的索引来源）。
  Future<void> addLocalSubtitle(String path, {String? label}) async {
    final track = SubtitleTrack(
      id: 'local#${DateTime.now().microsecondsSinceEpoch}',
      origin: SubtitleOrigin.localFile,
      label: label ?? path.split(RegExp(r'[/\\]')).last,
      format: SubtitleFormatDetector.of(path),
      localPath: path,
      isExternal: true,
    );
    _externalSubtitles = [..._externalSubtitles, track];
    await selectSubtitle(track);
  }

  // -------------------------------------------------------------------
  // 播放控制
  // -------------------------------------------------------------------

  /// 切换音轨。
  ///
  /// 放在控制器上而不是让页面直接 `player.setAudioTrack(...)`：
  /// `Player` 一旦漏给 UI，UI 就会开始绕开「清晰度要重取链」
  /// 「外挂字幕要先解码」这类业务规则，而它们恰恰是这个类存在的理由。
  ///
  /// 不需要额外记账「当前是哪条」—— mpv 自己会通过 `tracks` 流回报，
  /// 页面据此高亮即可。
  Future<void> selectAudioTrack(mk.AudioTrack track) async {
    await player.setAudioTrack(track);
    diag.info('播放', '切换音轨：${track.id} ${track.title ?? ""}');
    notifyListeners();
  }

  Future<void> play() => player.play();

  Future<void> pause() => player.pause();

  /// 停止播放并**释放解码资源**。
  ///
  /// 与 [pause] 的区别是「页面已经离开」：
  ///   - `pause` 假定用户还会回来，所以保留已打开的文件、解码器和缓冲；
  ///   - `stop` 把它们全部交还给 mpv，并清掉票据与轨道状态。
  ///
  /// 移动端 / Android TV 上按返回必须走这条（见 `PlaybackExitBehavior`）——
  /// 否则一个已经离开的页面还占着 4K 解码器和网络连接。
  ///
  /// **不清 `_item`**：播放页在退场动画期间还要显示标题，而 `open()`
  /// 本来就会重置全部状态。
  Future<void> stop() async {
    try {
      await player.stop();
    } catch (e) {
      // 停止失败不该把返回流程卡住 —— 用户已经要走了。
      diag.warn('播放', '停止播放失败：$e');
    }
    _playing = false;
    _buffering = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _ticket = null;
    _activeQualityId = null;
    _activeSubtitleId = null;
    _embeddedSubtitles = const [];
    _embeddedAudio = const [];
    _error = null;
    _notice = null;
    _subtitleResolver.clear();
    notifyListeners();
  }

  Future<void> playOrPause() => player.playOrPause();

  /// 相对跳转（方向键 / 快捷键用）。
  Future<void> seekRelative(Duration delta) => seek(_position + delta);

  /// 绝对跳转。自动夹在 `[0, duration]` 内 —— 越界的 seek 在 mpv 上
  /// 表现是「跳到一个不存在的位置然后卡住」，比不跳更糟。
  ///
  /// 夹取规则本体在 [clampSeekTarget]：**独立播放窗口也要用同一套**
  /// （它跑在另一个 Flutter 引擎里，够不到本类），两处各写一遍会漂移。
  Future<void> seek(Duration target) async {
    await player.seek(clampSeekTarget(target, _duration));
  }

  /// 按比例跳转（进度条点击用）。
  Future<void> seekToFraction(double fraction) {
    if (_duration <= Duration.zero) return Future.value();
    final f = fraction.clamp(0.0, 1.0);
    return seek(Duration(milliseconds: (_duration.inMilliseconds * f).round()));
  }

  Future<void> setVolume(double value) async {
    await player.setVolume(value.clamp(0.0, 100.0));
  }

  Future<void> setRate(double value) async {
    // 0.25x ~ 4x 是合理范围；超出会被 mpv 静默夹住，
    // 不如我们自己夹，这样 UI 上显示的倍速与实际一致。
    await player.setRate(value.clamp(0.25, 4.0));
  }

  // -------------------------------------------------------------------
  // mpv 事件绑定
  // -------------------------------------------------------------------

  final List<StreamSubscription<Object?>> _subs = [];

  void _bindPlayerStreams() {
    _subs.add(player.stream.playing.listen((v) {
      if (v == _playing) return;
      _playing = v;
      notifyListeners();
    }));

    _subs.add(player.stream.buffering.listen((v) {
      if (v == _buffering) return;
      _buffering = v;
      notifyListeners();
    }));

    _subs.add(player.stream.position.listen((v) {
      _position = v;
      notifyListeners();
      _maybeTickPosition(v);
    }));

    _subs.add(player.stream.duration.listen((v) {
      if (v == _duration) return;
      _duration = v;
      notifyListeners();
    }));

    _subs.add(player.stream.volume.listen((v) {
      if ((v - _volume).abs() < 0.01) return;
      _volume = v;
      notifyListeners();
    }));

    _subs.add(player.stream.rate.listen((v) {
      if ((v - _rate).abs() < 0.001) return;
      _rate = v;
      notifyListeners();
    }));

    // 内嵌轨列表：mpv 解完文件头之后才可用，因此这是**流**而不是一次性查询。
    _subs.add(player.stream.tracks.listen(_onTracksChanged));

    // 播放错误。mpv 的报错很笼统（`Failed to open ...`），
    // 但对用户来说「播不了」这个结论是准确的 —— 具体原因看诊断日志。
    _subs.add(player.stream.error.listen((msg) {
      final lower = msg.toLowerCase();
      if (!lower.contains('failed') && !lower.contains('error')) return;
      diag.warn('播放', 'mpv 报错：$msg');
      _error ??= '播放器报错：$msg';
      notifyListeners();
    }));
  }

  /// 进度存档节流。
  ///
  /// `position` 是每 ~100ms 一条的高频流，不能每条都写库。
  /// 用「整十秒边界」当触发条件：天然节流，且不需要额外的计时器。
  int _lastTickSecond = -1;

  void _maybeTickPosition(Duration v) {
    final interval = _positionSaveInterval.inSeconds;
    if (interval <= 0) return;
    final second = v.inSeconds;
    if (second <= 0) return;
    if (second % interval != 0) return;
    if (second == _lastTickSecond) return;
    _lastTickSecond = second;
    onPositionTick?.call(v);
  }

  void _onTracksChanged(mk.Tracks tracks) {
    final embeddedSubs = <SubtitleTrack>[];
    for (final t in realTracksOf(tracks.subtitle, (t) => t.id)) {
      // 上面的过滤器已经保证 id 能解析成整数，这里用 `parse` 而不是 `tryParse`
      // 是刻意的：真解析不了就应当炸出来，而不是静默产出一条没有轨道号的字幕。
      final trackId = int.parse(t.id);
      embeddedSubs.add(
        SubtitleTrack(
          id: 'embedded#$trackId',
          origin: SubtitleOrigin.embedded,
          label: _labelForEmbedded(
            t.title,
            t.language,
            '内嵌字幕 ${embeddedSubs.length + 1}',
          ),
          format: SubtitleFormatDetector.of(t.title ?? ''),
          embeddedTrackId: trackId,
          language: _languageFromTag(t.language),
          isDefault: t.isDefault ?? false,
        ),
      );
    }

    final embeddedAudio = realTracksOf(tracks.audio, (t) => t.id);
    final videoCount = realTracksOf(tracks.video, (t) => t.id).length;

    final changed = embeddedSubs.length != _embeddedSubtitles.length ||
        embeddedAudio.length != _embeddedAudio.length;
    _embeddedSubtitles = embeddedSubs;
    _embeddedAudio = embeddedAudio;
    if (!changed) return;

    diag.info(
      '播放',
      '内嵌轨更新：字幕 ${embeddedSubs.length} 条、'
      '音轨 ${embeddedAudio.length} 条、视频 $videoCount 条',
    );
    notifyListeners();

    // 内嵌字幕往往比外挂字幕晚一步出现，自动选择要再来一次 ——
    // 否则用户看到的初始状态是「没字幕」，得手动去点。
    if (_subtitlesEnabled && _activeSubtitleId == null) {
      unawaited(_autoLoadSubtitle());
    }
  }

  /// 只保留**真实存在的轨道**，剔除 media_kit 硬塞进来的合成轨。
  ///
  /// ⚠️ `tracks.video` / `tracks.audio` / `tracks.subtitle` 的**前两条是合成轨**：
  /// media_kit 的 `real.dart` 里写死了 `[XxxTrack.auto(), XxxTrack.no()]`，
  /// 它们的 `id` 是字符串 `'auto'` / `'no'`，**不是 mpv 的轨道号**。
  ///
  /// 把它们当真实轨道会踩两个坑：
  ///   1. `int.tryParse('auto')` → `null` → 报「内嵌字幕缺少轨道号」；
  ///   2. 它们永远排在最前面，而自动选字幕取的是「第一条」——
  ///      于是**每次播放都会去选那条合成轨**，必错。
  ///
  /// 实测症状：一个根本没有内嵌字幕的 mp4，`tracks.subtitle.length` 也是 2，
  /// 正好就是这两条合成轨（音轨、视频轨同样各 2 条）。
  ///
  /// 用泛型 + [idOf] 而不是 `T extends _Track`：media_kit 的轨道基类 `_Track`
  /// 是**私有**的，外部没法拿它当类型约束，只能把「怎么取 id」传进来。
  ///
  /// 实现委托给 `TrackLabels.realTracks` —— 独立播放窗口要用同一条规则
  /// （它拿不到这个控制器），拆成两份必然走样。
  @visibleForTesting
  static List<T> realTracksOf<T>(Iterable<T> tracks, String Function(T) idOf) =>
      TrackLabels.realTracks(tracks, idOf);

  static String _labelForEmbedded(
    String? title,
    String? language,
    String fallback,
  ) {
    final t = (title ?? '').trim();
    if (t.isNotEmpty) return t;
    return _languageFromTag(language)?.label ?? fallback;
  }

  /// 把 mpv 给的语言标记（`chi` / `zho` / `zh` / `eng`）映射成我们的语言对象。
  static SubtitleLanguage? _languageFromTag(String? tag) {
    if (tag == null || tag.trim().isEmpty) return null;
    final t = tag.trim().toLowerCase();
    const table = {
      'chi': SubtitleLanguage(code: 'zh', label: '中文'),
      'zho': SubtitleLanguage(code: 'zh', label: '中文'),
      'zh': SubtitleLanguage(code: 'zh', label: '中文'),
      'chs': SubtitleLanguage(code: 'zh-Hans', label: '简体中文'),
      'cht': SubtitleLanguage(code: 'zh-Hant', label: '繁体中文'),
      'eng': SubtitleLanguage(code: 'en', label: '英文'),
      'en': SubtitleLanguage(code: 'en', label: '英文'),
      'jpn': SubtitleLanguage(code: 'ja', label: '日文'),
      'ja': SubtitleLanguage(code: 'ja', label: '日文'),
      'kor': SubtitleLanguage(code: 'ko', label: '韩文'),
      'ko': SubtitleLanguage(code: 'ko', label: '韩文'),
    };
    return table[t] ?? SubtitleLanguage(code: t, label: t);
  }

  /// 把 [DriveException] 翻成用户能看懂、且**能据此行动**的话。
  static String _explain(DriveException e) => switch (e.type) {
        DriveErrorType.unauthorized => '登录已失效，请重新扫码登录夸克账号',
        DriveErrorType.notFound => '文件不存在或已被删除（可能网盘侧删掉了）',
        DriveErrorType.fileTooLarge =>
          '夸克拒绝了取链：该文件超出了所有取链路由的体积限制',
        DriveErrorType.rateLimited => '请求过于频繁，请稍后重试',
        DriveErrorType.network => '网络不可用，请检查网络连接',
        _ => e.message,
      };

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    unawaited(player.dispose());
    super.dispose();
  }
}

/// 从文件名猜字幕格式（用于本地字幕与内嵌轨标签）。
///
/// 单独一个小类而不是直接调 `SubtitleFormats.formatOf`：那个方法吃的是
/// **文件名**，而内嵌轨的 `title` 经常是 `Chinese` / `简体` 这类没有扩展名
/// 的字符串，需要在这里退化成「按内容标记猜」。
class SubtitleFormatDetector {
  const SubtitleFormatDetector._();

  static SubtitleFormat of(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('ass')) return SubtitleFormat.ass;
    if (lower.contains('ssa')) return SubtitleFormat.ssa;
    if (lower.contains('vtt')) return SubtitleFormat.vtt;
    if (lower.contains('pgs') || lower.contains('sup')) {
      return SubtitleFormat.pgs;
    }
    return SubtitleFormat.srt;
  }
}
