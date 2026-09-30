import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../data/db/settings_store.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/quality_option.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/playback_controller.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// 播放页。
///
/// ## 为什么播放页要自己把数据装一遍
///
/// 它接收的是 **itemId 而不是 `MediaItem` 对象**。看起来多绕一步，换来两件事：
///   1. 深链接 / 热重载后页面能自己恢复（对象传参会丢）；
///   2. 「播放」这件事的**全部前置条件**（字幕引用、默认清晰度、音量倍速、
///      是否自动加载字幕）都从库里现读，不会因为调用方忘了传某个参数
///      而静默用默认值。
///
/// ## 控制栏为什么是自绘的
///
/// `media_kit_video` 自带一套 `AdaptiveVideoControls`，但它**不认识清晰度** ——
/// 网盘的清晰度是服务端转码梯度，mpv 侧只是换了一条 URL，对播放器来说
/// 就是「同一个文件」。清晰度菜单、字幕来源标注（网盘/内嵌）、
/// 音轨语言名这些都必须我们自己画。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, required this.itemId, this.qualityId});

  final String itemId;

  /// 指定要播的清晰度档位（从详情页点某一档进来时用）。`null` = 用设置里的默认。
  final String? qualityId;

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  MediaItem? _item;
  String? _loadError;
  bool _ready = false;

  /// 沉浸模式：隐藏顶栏与控制栏，只剩画面。
  bool _immersive = false;

  /// 拖动进度条时的临时值。拖动过程中不能让 `position` 流把滑块拽回去。
  double? _dragFraction;

  /// 当前音轨 id。页面自己记：mpv 的 `tracks` 流只给列表，不给「当前选中」。
  String? _audioId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    final repo = ref.read(mediaRepositoryProvider);

    final item = await repo.itemById(widget.itemId);
    if (!mounted) return;
    if (item == null) {
      setState(() => _loadError = '找不到这个媒体项。可能它已被重新扫描移除，'
          '或链接是从旧版本的应用里带过来的。');
      return;
    }

    // 字幕引用（扫描期建的，不含正文）与设置一起读。
    final subtitles = await repo.subtitlesForItem(item.id);
    final settings = ref.read(settingsStoreProvider);
    final values = await settings.readAll(const [
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
      SettingKeys.playerVolume,
      SettingKeys.playerRate,
    ]);
    if (!mounted) return;

    final preferred =
        widget.qualityId ?? _nonEmpty(values[SettingKeys.defaultQuality]);
    // 默认 **true**：绝大多数片子都有中文字幕，默认加载省一次点击；
    // 没有字幕时 `_autoLoadSubtitle` 会安静地什么都不做。
    final autoSub = values[SettingKeys.autoLoadSubtitles] != 'false';
    final volume = double.tryParse(values[SettingKeys.playerVolume] ?? '') ?? 100;
    final rate = double.tryParse(values[SettingKeys.playerRate] ?? '') ?? 1.0;

    final controller = ref.read(playbackControllerProvider);
    await controller.setVolume(volume);
    await controller.setRate(rate);

    setState(() {
      _item = item;
      _ready = true;
    });

    await controller.open(
      item,
      subtitles: subtitles,
      preferredQualityId: preferred,
      autoLoadSubtitles: autoSub,
    );
  }

  static String? _nonEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(playbackControllerProvider);

    return Scaffold(
      backgroundColor: AppTheme.cinema,
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space):
                controller.playOrPause,
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                controller.seekRelative(const Duration(seconds: -10)),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                controller.seekRelative(const Duration(seconds: 10)),
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_immersive) {
                setState(() => _immersive = false);
              } else {
                context.pop();
              }
            },
          },
          child: Focus(
            autofocus: true,
            child: Column(
              children: [
                if (!_immersive) _buildTopBar(controller),
                Expanded(child: _buildStage(controller)),
                if (!_immersive) _buildControlBar(controller),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // 顶栏
  // -------------------------------------------------------------------

  Widget _buildTopBar(PlaybackController controller) {
    final item = _item;
    return Container(
      height: 48,
      color: AppTheme.cinema,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => context.pop(),
            iconSize: 18,
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back_rounded, color: AppTheme.text),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item?.displayTitle ?? '加载中…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.text,
                  ),
                ),
                if (item != null)
                  Text(
                    item.technicalSummary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _immersive = true),
            iconSize: 17,
            tooltip: '沉浸模式（Esc 退出）',
            icon: const Icon(Icons.fullscreen_rounded, color: AppTheme.muted),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 画面
  // -------------------------------------------------------------------

  Widget _buildStage(PlaybackController controller) {
    final loadError = _loadError;
    if (loadError != null) {
      return EmptyState(
        icon: Icons.link_off_rounded,
        danger: true,
        title: '打不开这个视频',
        body: loadError,
        actionLabel: '返回',
        onAction: () => context.pop(),
      );
    }

    final error = controller.error;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (_ready)
          Video(
            controller: controller.videoController,
            // 自绘控制栏（见类文档）。
            controls: (_) => const SizedBox.shrink(),
            fill: AppTheme.cinema,
            subtitleViewConfiguration: const SubtitleViewConfiguration(
              style: TextStyle(
                fontSize: 30,
                height: 1.35,
                color: Colors.white,
                fontWeight: FontWeight.w500,
                backgroundColor: Color(0x99000000),
              ),
              padding: EdgeInsets.fromLTRB(24, 0, 24, 44),
            ),
          )
        else
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),

        if (controller.isBuffering && error == null)
          const Center(
            child: SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),

        if (error != null)
          _ErrorOverlay(
            message: error,
            onRetry: controller.retry,
            onBack: () => context.pop(),
          ),

        // 沉浸模式下点画面任意处切回普通模式 —— 否则用户会「进去出不来」。
        if (_immersive)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _immersive = false),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------
  // 控制栏
  // -------------------------------------------------------------------

  Widget _buildControlBar(PlaybackController controller) {
    final duration = controller.duration;
    final position = controller.position;
    final fraction = _dragFraction ??
        (duration.inMilliseconds <= 0
            ? 0.0
            : (position.inMilliseconds / duration.inMilliseconds)
                .clamp(0.0, 1.0));

    return Container(
      height: AppTheme.playerBarHeight,
      color: AppTheme.cinema,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Text(
                _fmt(position),
                style: AppTheme.mono.copyWith(color: AppTheme.muted),
              ),
              Expanded(
                child: Slider(
                  value: fraction,
                  onChangeStart: (v) => setState(() => _dragFraction = v),
                  onChanged: (v) => setState(() => _dragFraction = v),
                  onChangeEnd: (v) {
                    setState(() => _dragFraction = null);
                    unawaited(controller.seekToFraction(v));
                  },
                ),
              ),
              Text(
                _fmt(duration),
                style: AppTheme.mono.copyWith(color: AppTheme.dim),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: controller.playOrPause,
                iconSize: 22,
                tooltip: controller.isPlaying ? '暂停（空格）' : '播放（空格）',
                icon: Icon(
                  controller.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: AppTheme.text,
                ),
              ),
              IconButton(
                onPressed: () =>
                    controller.seekRelative(const Duration(seconds: -10)),
                iconSize: 17,
                tooltip: '后退 10 秒（←）',
                icon: const Icon(Icons.replay_10_rounded, color: AppTheme.muted),
              ),
              IconButton(
                onPressed: () =>
                    controller.seekRelative(const Duration(seconds: 10)),
                iconSize: 17,
                tooltip: '前进 10 秒（→）',
                icon: const Icon(
                  Icons.forward_10_rounded,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(width: 6),

              // 音量
              IconButton(
                onPressed: () => unawaited(
                  controller.setVolume(controller.volume > 0 ? 0 : 100),
                ),
                iconSize: 16,
                tooltip: controller.volume > 0 ? '静音' : '取消静音',
                icon: Icon(
                  controller.volume <= 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  color: AppTheme.muted,
                ),
              ),
              SizedBox(
                width: 84,
                child: Slider(
                  value: controller.volume.clamp(0, 100),
                  max: 100,
                  onChanged: (v) => unawaited(controller.setVolume(v)),
                ),
              ),

              const Spacer(),

              _QualityMenu(controller: controller),
              _SubtitleMenu(controller: controller),
              _AudioMenu(
                controller: controller,
                activeId: _audioId,
                onSelected: (id) => setState(() => _audioId = id),
              ),
              _RateMenu(controller: controller),
            ],
          ),
        ],
      ),
    );
  }

  /// `1:02:03` / `02:03`
  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------

class _QualityMenu extends StatelessWidget {
  const _QualityMenu({required this.controller});

  final PlaybackController controller;

  @override
  Widget build(BuildContext context) {
    final qualities = controller.qualities;

    // 服务端没给转码梯度时不显示入口 —— 一个只有一项的下拉框
    // 只会让用户以为「清晰度切换坏了」。
    if (qualities.length <= 1) return const SizedBox.shrink();

    final active = controller.activeQualityId;

    return PopupMenuButton<String>(
      tooltip: '清晰度',
      initialValue: active,
      onSelected: (id) => unawaited(controller.switchQuality(id)),
      itemBuilder: (context) => [
        for (final q in qualities)
          PopupMenuItem<String>(
            value: q.id,
            enabled: q.isAvailable,
            child: _MenuRow(
              label: q.label,
              detail: q.displayDetail,
              selected: q.id == active,
              dim: !q.isAvailable,
            ),
          ),
      ],
      child: _BarButton(
        icon: Icons.high_quality_rounded,
        label: _activeLabel(qualities, active),
        active: true,
      ),
    );
  }

  static String _activeLabel(List<QualityOption> all, String? active) {
    for (final q in all) {
      if (q.id == active) return q.label;
    }
    return '清晰度';
  }
}

class _SubtitleMenu extends StatelessWidget {
  const _SubtitleMenu({required this.controller});

  final PlaybackController controller;

  static const String _offValue = '__off__';

  @override
  Widget build(BuildContext context) {
    final tracks = controller.allSubtitles;
    final active = controller.activeSubtitleId;

    return PopupMenuButton<String>(
      tooltip: '字幕',
      initialValue: active ?? _offValue,
      onSelected: (value) {
        if (value == _offValue) {
          unawaited(controller.selectSubtitle(null));
          return;
        }
        for (final t in tracks) {
          if (t.id == value) {
            unawaited(controller.selectSubtitle(t));
            return;
          }
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: _offValue,
          child: _MenuRow(label: '关闭字幕', detail: ''),
        ),
        if (tracks.isNotEmpty) const PopupMenuDivider(),
        for (final t in tracks)
          PopupMenuItem<String>(
            value: t.id,
            child: _MenuRow(
              label: t.displayLabel,
              detail: _originLabel(t),
              selected: t.id == active,
            ),
          ),
      ],
      child: _BarButton(
        icon: Icons.subtitles_rounded,
        label: active == null ? '字幕' : '字幕 · 开',
        active: active != null,
      ),
    );
  }

  static String _originLabel(SubtitleTrack t) => switch (t.origin) {
        SubtitleOrigin.cloudFile => '网盘字幕',
        SubtitleOrigin.embedded => '内嵌轨',
        SubtitleOrigin.localFile => '本地字幕',
      };
}

class _AudioMenu extends StatelessWidget {
  const _AudioMenu({
    required this.controller,
    required this.activeId,
    required this.onSelected,
  });

  final PlaybackController controller;
  final String? activeId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final tracks = controller.embeddedAudioTracks;
    // 只有一条音轨时菜单没有意义。
    if (tracks.length <= 1) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: '音轨',
      initialValue: activeId,
      onSelected: (id) {
        for (final t in tracks) {
          if (t.id == id) {
            onSelected(id);
            unawaited(controller.selectAudioTrack(t));
            return;
          }
        }
      },
      itemBuilder: (context) => [
        for (var i = 0; i < tracks.length; i++)
          PopupMenuItem<String>(
            value: tracks[i].id,
            child: _MenuRow(
              label: tracks[i].title ??
                  _languageLabel(tracks[i].language) ??
                  '音轨 ${i + 1}',
              detail: _trackDetail(tracks[i]),
              selected: tracks[i].id == activeId,
            ),
          ),
      ],
      child: const _BarButton(icon: Icons.graphic_eq_rounded, label: '音轨'),
    );
  }

  static String _trackDetail(mk.AudioTrack t) => [
        if (t.codec != null) t.codec!,
        if (t.channels != null) t.channels!,
        if (t.bitrate != null) '${(t.bitrate! / 1000).round()} kbps',
      ].join(' · ');

  static String? _languageLabel(String? tag) {
    if (tag == null || tag.isEmpty) return null;
    const table = {
      'chi': '中文',
      'zho': '中文',
      'zh': '中文',
      'eng': '英文',
      'en': '英文',
      'jpn': '日文',
      'ja': '日文',
      'kor': '韩文',
      'ko': '韩文',
    };
    return table[tag.toLowerCase()] ?? tag;
  }
}

class _RateMenu extends StatelessWidget {
  const _RateMenu({required this.controller});

  final PlaybackController controller;

  static const List<double> _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    final rate = controller.rate;

    return PopupMenuButton<double>(
      tooltip: '播放速度',
      initialValue: rate,
      onSelected: (v) => unawaited(controller.setRate(v)),
      itemBuilder: (context) => [
        for (final r in _rates)
          PopupMenuItem<double>(
            value: r,
            child: _MenuRow(
              label: r == 1.0 ? '正常速度' : '${r}x',
              detail: '',
              selected: (r - rate).abs() < 0.001,
            ),
          ),
      ],
      child: _BarButton(
        icon: Icons.speed_rounded,
        label: rate == 1.0 ? '倍速' : '${rate}x',
        active: rate != 1.0,
      ),
    );
  }
}

/// 控制栏上的文字按钮（带图标）。
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppTheme.accent : AppTheme.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 11.5, color: color)),
        ],
      ),
    );
  }
}

/// 菜单里的一行：主标签 + 说明 + 选中勾。
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    required this.detail,
    this.selected = false,
    this.dim = false,
  });

  final String label;
  final String detail;
  final bool selected;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: dim
                        ? AppTheme.dim
                        : (selected ? AppTheme.accent : AppTheme.text),
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
                  ),
              ],
            ),
          ),
          if (selected)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.check_rounded, size: 14, color: AppTheme.accent),
            ),
        ],
      ),
    );
  }
}

/// 取链失败时的遮罩。
///
/// 必须给出**可行动的**说明：夸克取链失败的原因分好几类
/// （登录失效 / 文件被删 / 被所有路由拒绝），笼统写「播放失败」
/// 会让用户以为是播放器的问题而去重装应用。
class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onBack,
  });

  final String message;
  final Future<void> Function() onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.cinema.withValues(alpha: 0.88),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 32,
                color: AppTheme.danger,
              ),
              const SizedBox(height: 14),
              const Text(
                '播放失败',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(onPressed: onBack, child: const Text('返回')),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: () => unawaited(onRetry()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accent,
                    ),
                    child: const Text('重新取链'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
