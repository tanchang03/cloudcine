import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/error/drive_error.dart';
import '../../core/utils/subtitle_formats.dart';
import '../adapters/cloud_drive_adapter.dart';
import '../entities/media_item.dart';
import '../entities/quality_option.dart';
import '../entities/stream_ticket.dart';
import '../entities/subtitle_track.dart';
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
    _bindPlayerStreams();
  }

  final DriveAdapterRegistry _registry;
  final SubtitleResolver _subtitleResolver;
  final Duration _positionSaveInterval;

  /// mpv 播放器实例。**只在本类内部使用**。
  final mk.Player player = mk.Player();

  /// 渲染控制器，交给 `Video(controller: ...)`。
  final VideoController videoController = VideoController(
    mk.Player(),
    configuration: const VideoControllerConfiguration(
      // `auto-safe`：在已知有问题的驱动上自动退回软解，比强制硬解稳。
      enableHardwareAcceleration: true,
    ),
  );

  // -------------------------------------------------------------------
  // 对外状态
  // -------------------------------------------------------------------

  MediaItem? _item;
  StreamTicket? _ticket;
  String? _activeQualityId;
  bool _loading = false;
  String? _error;

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
  Future<void> _loadIntoPlayer(StreamTicket ticket) async {
    diag.info(
      '播放',
      '交给播放器：${ticket.redactedUrl} '
      '请求头=${ticket.headers.keys.toList()} '
      '档位=${_activeQualityId ?? "-"}',
    );
    await player.open(
      mk.Media(ticket.url.toString(), httpHeaders: ticket.headers),
      play: true,
    );
  }

  /// 决定「当前应该用哪一档」。
  ///
  /// 优先级：设置里的默认档 → 原画 → 第一档。
  /// **原画优先**是刻意的：转码流会丢细节，而本应用的用户把片子放在网盘上
  /// 就是想要原片质量。只有用户显式选了别的档位才用别的。
  String? _pickActiveQualityId(StreamTicket ticket, String? preferred) {
    if (ticket.qualities.isEmpty) return null;

    if (preferred != null && preferred.isNotEmpty) {
      final q = ticket.qualityById(preferred);
      if (q != null && q.isAvailable) return q.id;
    }
    for (final q in ticket.qualities) {
      if (q.isOriginal && q.isAvailable) return q.id;
    }
    for (final q in ticket.qualities) {
      if (q.isAvailable) return q.id;
    }
    return ticket.qualities.first.id;
  }

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
      _error = '「${q.label}」这一档服务端没有提供播放地址';
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
    notifyListeners();

    try {
      final next = ticket.withQuality(q);
      _ticket = next;
      _activeQualityId = q.id;
      await _loadIntoPlayer(next);

      // 恢复位置。mpv 换源后位置归零，不恢复的话用户每切一次清晰度
      // 就得自己拖回去。
      if (resumeAt > Duration.zero) {
        await player.seek(resumeAt);
      }
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
            _error = '内嵌字幕缺少轨道号';
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
      _error = null;
    } catch (e) {
      _error = '加载字幕失败：$e';
      diag.error('字幕', '加载失败（${track.displayLabel}）：$e');
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

  Future<void> playOrPause() => player.playOrPause();

  /// 相对跳转（方向键 / 快捷键用）。
  Future<void> seekRelative(Duration delta) => seek(_position + delta);

  /// 绝对跳转。自动夹在 `[0, duration]` 内 —— 越界的 seek 在 mpv 上
  /// 表现是「跳到一个不存在的位置然后卡住」，比不跳更糟。
  Future<void> seek(Duration target) async {
    var t = target;
    if (t < Duration.zero) t = Duration.zero;
    if (_duration > Duration.zero && t > _duration) t = _duration;
    await player.seek(t);
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
    for (var i = 0; i < tracks.subtitle.length; i++) {
      final t = tracks.subtitle[i];
      embeddedSubs.add(
        SubtitleTrack(
          id: 'embedded#${t.id}',
          origin: SubtitleOrigin.embedded,
          label: _labelForEmbedded(t.title, t.language, '内嵌字幕 ${i + 1}'),
          format: SubtitleFormatDetector.of(t.title ?? ''),
          embeddedTrackId: int.tryParse(t.id),
          language: _languageFromTag(t.language),
          isDefault: t.isDefault ?? false,
        ),
      );
    }

    final changed = embeddedSubs.length != _embeddedSubtitles.length;
    _embeddedSubtitles = embeddedSubs;
    _embeddedAudio = tracks.audio;
    if (!changed) return;

    diag.info(
      '播放',
      '内嵌轨更新：字幕 ${embeddedSubs.length} 条、'
      '音轨 ${tracks.audio.length} 条、视频 ${tracks.video.length} 条',
    );
    notifyListeners();

    // 内嵌字幕往往比外挂字幕晚一步出现，自动选择要再来一次 ——
    // 否则用户看到的初始状态是「没字幕」，得手动去点。
    if (_subtitlesEnabled && _activeSubtitleId == null) {
      unawaited(_autoLoadSubtitle());
    }
  }

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
