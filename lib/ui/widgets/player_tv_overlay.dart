import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../core/utils/player_audio_effect.dart';
import '../../core/utils/track_labels.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/playback_controller.dart';
import 'player_tv_panel.dart';

/// 倍速档位。
///
/// ⚠️ 桌面控制栏的 `_RateMenu` **必须**用这一份：两张表各写一份的话，
/// 「电视上能选 2.0x、桌面上只有 1.5x」这种偏差没有任何人会发现 ——
/// 没人会开着两个平台对着数档位。
const List<double> kPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// `1:02:03` / `02:03`。
///
/// 只给「片头那一行」用，写在这里而不是复用播放页的 `_fmtClock`：那个是
/// 私有的，而为一行文字去改一个 2000 行文件的可见性不值得 —— 代价是这里
/// 多一份实现，收益是两个文件不再互相牵扯。
String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 集数网格里一格的文字。
///
/// 优先用**解析出来的集号**（`episode`），没有才退回「第 N 格」。
/// 直接用下标的问题在于：网盘目录里经常混着花絮 / 预告（它们也在
/// `itemsForWork` 的返回值里），下标会把用户带去一个不是正片的格子。
@visibleForTesting
String episodeCellLabel(MediaItem item, int index) {
  final e = item.episode;
  if (e != null) return '$e';
  final part = item.partLabel;
  if (part != null && part.isNotEmpty) return part;
  return '${index + 1}';
}

/// 「选集」那一行显示的当前值。
String episodeRowLabel(MediaItem item, int index) {
  final e = item.episode;
  if (e != null) return '第 $e 集';
  final part = item.partLabel;
  if (part != null && part.isNotEmpty) return part;
  return '第 ${index + 1} 集';
}

/// TV 播放页右侧那块设置面板的**全部状态与切换逻辑**。
///
/// ## 为什么单独一个组件，而不是塞进播放页
///
/// 播放页已经 2000 行，再塞进「面板开在第几页、选中第几行、每一档怎么循环」
/// 会让它彻底没法读。而这块逻辑与播放页的耦合面其实很窄：只是
/// **读控制器状态** + **回调出「用户选了什么」**，两侧都不碰数据库。
/// 收进来之后，播放页只剩「什么时候打开 / 关闭它」这一个决定。
///
/// ## 「改值」为什么不直接调控制器
///
/// 画质与字幕**切完了还要落库**（而且只在真的切成功之后才落，见
/// `_changeQuality` / `_changeSubtitle` 的注释）。那段逻辑在播放页手里，
/// 这里重做一遍就是两份「只在成功时记」的规则 —— 一定会漂。
class PlayerTvOverlay extends StatefulWidget {
  const PlayerTvOverlay({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.item,
    required this.siblings,
    required this.activeAudioId,
    required this.onPickQuality,
    required this.onPickSubtitle,
    required this.onPickAudioTrack,
    required this.onPickAudioEffect,
    required this.onPickRate,
    required this.onPickEpisode,
    required this.onJumpIntro,
    required this.onClose,
    required this.onActivity,
  });

  final PlaybackController controller;

  /// 面板的焦点节点，**由播放页持有**。
  ///
  /// ⛔ 不能让面板自己建一个 + `autofocus`：画面节点早就占着焦点了，
  /// `autofocus` 是空操作，面板会收不到任何按键（用户报的「上下键按不动」
  /// 就是这个）。播放页在打开面板后显式 `requestFocus` 到这个节点上。
  final FocusNode focusNode;

  /// 当前这一集。**可能为 null**（还没加载出来）—— 那时「选集」行显示「—」。
  final MediaItem? item;

  /// 同一部作品下的全部条目（含花絮）。空列表表示这部片子不在库里
  /// （例如从「文件夹」直接播了一个没入库的文件）→ 「选集」行不可调。
  final List<MediaItem> siblings;

  /// 当前音轨 id。控制器只给列表不给「选中了哪条」，由播放页记账后传进来。
  final String? activeAudioId;

  final Future<void> Function(String qualityId) onPickQuality;
  final Future<void> Function(SubtitleTrack? track) onPickSubtitle;
  final void Function(mk.AudioTrack track, int index) onPickAudioTrack;
  final Future<void> Function(AudioEffectPreset preset) onPickAudioEffect;
  final Future<void> Function(double rate) onPickRate;
  final Future<void> Function(MediaItem item) onPickEpisode;

  /// 跳到片头起点。
  ///
  /// TV 上**只跳不标**：手标片头要把播放头定位到某一秒（长按方向键最快也要
  /// 几十秒），遥控器实质上做不到。标记那一路留在桌面控制栏的片头菜单里。
  final Future<void> Function() onJumpIntro;

  final VoidCallback onClose;
  final VoidCallback onActivity;

  @override
  State<PlayerTvOverlay> createState() => _PlayerTvOverlayState();
}

class _PlayerTvOverlayState extends State<PlayerTvOverlay> {
  int _rowIndex = 0;

  /// 停在集数网格那一页。
  bool _episodes = false;

  @override
  Widget build(BuildContext context) {
    if (_episodes) {
      final siblings = widget.siblings;
      return PlayerTvEpisodeGrid(
        focusNode: widget.focusNode,
        count: siblings.length,
        currentIndex: siblings.indexWhere((i) => i.id == widget.item?.id),
        labelOf: (i) => episodeCellLabel(siblings[i], i),
        onPick: (i) {
          // 选完就跳，跳完**收起整个面板**：用户想看的是片子，不是面板。
          unawaited(widget.onPickEpisode(siblings[i]));
          widget.onClose();
        },
        onClose: () => setState(() => _episodes = false),
        onActivity: widget.onActivity,
      );
    }

    return PlayerTvPanel(
      focusNode: widget.focusNode,
      rows: _rows(),
      selectedIndex: _rowIndex,
      onSelectedChanged: (i) => setState(() => _rowIndex = i),
      onAdjust: _adjust,
      onActivate: _activate,
      onClose: widget.onClose,
      onActivity: widget.onActivity,
    );
  }

  List<PlayerTvRowValue> _rows() {
    final c = widget.controller;
    final siblings = widget.siblings;
    final item = widget.item;
    final epIndex = item == null ? -1 : siblings.indexWhere((i) => i.id == item.id);

    return [
      PlayerTvRowValue(
        row: PlayerTvRow.episode,
        value: epIndex < 0 ? '' : episodeRowLabel(siblings[epIndex], epIndex),
        adjustable: siblings.length > 1,
      ),
      _qualityRow(c),
      _subtitleRow(c),
      _audioRow(c),
      PlayerTvRowValue(
        row: PlayerTvRow.audioEffect,
        value: PlayerAudioEffect.label(c.audioEffect),
        adjustable: PlayerAudioEffect.selectable.length > 1,
      ),
      PlayerTvRowValue(
        row: PlayerTvRow.rate,
        value: c.rate == 1.0 ? '正常速度' : '${c.rate}x',
      ),
      _introRow(c),
    ];
  }

  PlayerTvRowValue _introRow(PlaybackController c) {
    final marker = c.introMarker;
    return PlayerTvRowValue(
      row: PlayerTvRow.intro,
      // 没有片头标识时写「未标记」而不是空串：空串会被渲染成「—」，
      // 用户读不出那是「还没标」还是「这部片没有片头」。
      value: marker == null ? '未标记' : '跳到 ${_clock(marker.start)}',
      adjustable: false,
    );
  }

  PlayerTvRowValue _qualityRow(PlaybackController c) {
    final all = c.qualities;
    // 服务端没给转码梯度时只有原画一档 —— 写「原画」而不是空串：
    // 用户要确认的是「我现在看的是不是最好的那档」，这本身是有效信息。
    if (all.isEmpty) {
      return const PlayerTvRowValue(
        row: PlayerTvRow.quality,
        value: '原画',
        adjustable: false,
      );
    }
    final active = c.activeQualityId;
    var label = '原画';
    for (final q in all) {
      if (q.id == active) {
        label = q.label;
        break;
      }
    }
    return PlayerTvRowValue(
      row: PlayerTvRow.quality,
      value: label,
      adjustable: all.length > 1,
    );
  }

  PlayerTvRowValue _subtitleRow(PlaybackController c) {
    final tracks = c.allSubtitles;
    final active = c.activeSubtitleId;
    if (active == null) {
      return PlayerTvRowValue(
        row: PlayerTvRow.subtitle,
        value: '关闭',
        adjustable: tracks.isNotEmpty,
      );
    }
    var label = '字幕';
    for (final t in tracks) {
      if (t.id == active) {
        label = t.displayLabel;
        break;
      }
    }
    return PlayerTvRowValue(row: PlayerTvRow.subtitle, value: label);
  }

  /// 音轨名走 `TrackLabels.audioTitle`，**本文件不再自己维护一张语言表**。
  ///
  /// 这里一开始抄了一份「`chi` → 中文」的映射（当时的理由是「只为一行文字去
  /// 动 `TrackLabels` 不值得」）。那是错的：桌面内置播放页的音轨菜单、独立
  /// 播放窗口、以及这块面板一共三处要显示同一个名字，各抄一份的结果是
  /// 「`chi` 在一处显示中文、另一处显示简体中文、第三处原样显示 chi」——
  /// 而这三处**没有任何一处在真机上会同时出现**，所以没人会发现。
  /// `TrackLabels` 的类文档正好写着这件事，别再拆成两份。
  PlayerTvRowValue _audioRow(PlaybackController c) {
    final tracks = c.embeddedAudioTracks;
    if (tracks.length <= 1) {
      return PlayerTvRowValue(
        row: PlayerTvRow.audioTrack,
        // 只有一条音轨时也要把它的名字显示出来：用户要确认的是
        // 「这部片子有没有国语」，而不是「这里有个菜单」。
        value: tracks.isEmpty ? '' : TrackLabels.audioTitle(tracks.first),
        adjustable: false,
      );
    }
    final active = widget.activeAudioId;
    var label = TrackLabels.audioTitle(tracks.first);
    for (final t in tracks) {
      if (t.id == active) {
        label = TrackLabels.audioTitle(t);
        break;
      }
    }
    return PlayerTvRowValue(row: PlayerTvRow.audioTrack, value: label);
  }

  /// OK 落在某一行上。
  ///
  /// ⚠️ 「片头」跳完**收起面板**：跳过去之后用户要看的是片子，留着面板
  /// 只会挡住三分之一画面。
  void _activate(PlayerTvRow row) {
    switch (row) {
      case PlayerTvRow.episode:
        if (widget.siblings.length > 1) setState(() => _episodes = true);
      case PlayerTvRow.intro:
        unawaited(widget.onJumpIntro());
        widget.onClose();
      case PlayerTvRow.quality:
      case PlayerTvRow.subtitle:
      case PlayerTvRow.audioTrack:
      case PlayerTvRow.audioEffect:
      case PlayerTvRow.rate:
        _adjust(row, 1);
    }
  }

  void _adjust(PlayerTvRow row, int delta) {
    switch (row) {
      case PlayerTvRow.intro:
        // 左右键对片头没有意义 —— 它是一次跳转，走 OK。
        break;
      case PlayerTvRow.episode:
        _stepEpisode(delta);
      case PlayerTvRow.quality:
        _stepQuality(delta);
      case PlayerTvRow.subtitle:
        _stepSubtitle(delta);
      case PlayerTvRow.audioTrack:
        _stepAudio(delta);
      case PlayerTvRow.audioEffect:
        _stepEffect(delta);
      case PlayerTvRow.rate:
        _stepRate(delta);
    }
  }

  void _stepEpisode(int delta) {
    final siblings = widget.siblings;
    final item = widget.item;
    if (item == null || siblings.length <= 1) return;
    final i = siblings.indexWhere((e) => e.id == item.id);
    if (i < 0) return;
    final target = i + delta;
    // **不循环**：第一集的「上一集」不存在，绕到最后一集是纯困惑。
    if (target < 0 || target >= siblings.length) return;
    unawaited(widget.onPickEpisode(siblings[target]));
  }

  void _stepQuality(int delta) {
    final all = widget.controller.qualities;
    if (all.length <= 1) return;
    var i = all.indexWhere((q) => q.id == widget.controller.activeQualityId);
    if (i < 0) i = 0;
    // 跳过「服务端没给地址」的档位：按下去只会弹一条提示，而用户要按第二次
    // 才知道自己刚才那下没生效。最多绕一圈，全是不可用时什么都不做。
    for (var n = 0; n < all.length; n++) {
      i = nextTvRowIndex(current: i, delta: delta, total: all.length);
      if (all[i].isAvailable) {
        unawaited(widget.onPickQuality(all[i].id));
        return;
      }
    }
  }

  void _stepSubtitle(int delta) {
    final tracks = widget.controller.allSubtitles;
    if (tracks.isEmpty) return;
    final active = widget.controller.activeSubtitleId;
    var cur = 0; // 0 = 关闭字幕
    if (active != null) {
      final idx = tracks.indexWhere((t) => t.id == active);
      if (idx >= 0) cur = idx + 1;
    }
    final next = nextTvRowIndex(
      current: cur,
      delta: delta,
      total: tracks.length + 1,
    );
    unawaited(widget.onPickSubtitle(next == 0 ? null : tracks[next - 1]));
  }

  void _stepAudio(int delta) {
    final tracks = widget.controller.embeddedAudioTracks;
    if (tracks.length <= 1) return;
    var i = tracks.indexWhere((t) => t.id == widget.activeAudioId);
    if (i < 0) i = 0;
    final next = nextTvRowIndex(current: i, delta: delta, total: tracks.length);
    widget.onPickAudioTrack(tracks[next], next);
  }

  void _stepEffect(int delta) {
    final all = PlayerAudioEffect.selectable;
    if (all.length <= 1) return;
    var i = all.indexOf(widget.controller.audioEffect);
    if (i < 0) i = 0;
    unawaited(widget.onPickAudioEffect(all[nextTvRowIndex(
      current: i,
      delta: delta,
      total: all.length,
    )]));
  }

  void _stepRate(int delta) {
    var i = kPlaybackRates.indexOf(widget.controller.rate);
    if (i < 0) i = kPlaybackRates.indexOf(1.0);
    unawaited(widget.onPickRate(kPlaybackRates[nextTvRowIndex(
      current: i,
      delta: delta,
      total: kPlaybackRates.length,
    )]));
  }
}
