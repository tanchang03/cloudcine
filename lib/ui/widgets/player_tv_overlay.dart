import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../core/utils/file_names.dart';
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

/// 倍速档位在选项条上怎么写。
///
/// 1.0 写「正常速度」而不是「1.0x」：用户要找的是「怎么恢复原速」，
/// 而「1.0x」需要他在心里先换算一次。
String rateLabel(double rate) => rate == 1.0 ? '正常速度' : '${rate}x';

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

/// TV 播放页底部菜单的**全部状态与切换逻辑**。
///
/// ## 为什么单独一个组件，而不是塞进播放页
///
/// 播放页已经 2000 行，再塞进「菜单开在第几页、选中第几行、每一档怎么循环」
/// 会让它彻底没法读。而这块逻辑与播放页的耦合面其实很窄：只是
/// **读控制器状态** + **回调出「用户选了什么」**，两侧都不碰数据库。
/// 收进来之后，播放页只剩「什么时候打开 / 关闭它」这一个决定。
///
/// ## 「改值」为什么不直接调控制器
///
/// 画质与字幕**切完了还要落库**（而且只在真的切成功之后才落，见
/// `_changeQuality` / `_changeSubtitle` 的注释）。那段逻辑在播放页手里，
/// 这里重做一遍就是两份「只在成功时记」的规则 —— 一定会漂。
///
/// ## 选项从哪来
///
/// 每一行都把**全部可选项**交给 [PlayerTvSheet] 画成一条 chip（照夸克
/// 播放器）。这样用户在按 OK 之前就看得到「有哪些档、现在是哪一档」——
/// 原来那一版只给一个当前值字符串，改值靠 ← / → 逐档盲循环。
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

  /// 菜单的焦点节点，**由播放页持有**。
  ///
  /// ⛔ 不能让菜单自己建一个 + `autofocus`：画面节点早就占着焦点了，
  /// `autofocus` 是空操作，菜单会收不到任何按键（用户报的「上下键按不动」
  /// 就是这个）。播放页在打开菜单后显式 `requestFocus` 到这个节点上。
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
          // 选完就跳，跳完**收起整个菜单**：用户想看的是片子，不是菜单。
          unawaited(widget.onPickEpisode(siblings[i]));
          widget.onClose();
        },
        onClose: () => setState(() => _episodes = false),
        onActivity: widget.onActivity,
      );
    }

    return PlayerTvSheet(
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
        // 「选集」用**纵向列表**呈现（`vertical: true`）：文件名可能很长
        // （含版本 / 分辨率），横着铺不下。交互照夸克：Y 轴选中选集 → 按 →
        // 进入右侧列表 → ↑/↓ 选择 → ← / 返回键退回 Y 轴。
        options: [
          for (var i = 0; i < siblings.length; i++)
            PlayerTvOption(baseNameOf(siblings[i].name)),
        ],
        vertical: true,
        selectedOption: epIndex < 0 ? 0 : epIndex,
        hint: siblings.length > 1
            ? null
            : '这一条不在剧集列表里（不是从库里进来的）',
      ),
      _qualityRow(c),
      _subtitleRow(c),
      _audioRow(c),
      _effectRow(c),
      _rateRow(c),
      _introRow(c),
    ];
  }

  // -------------------------------------------------------------------
  // 每一行的「可选项 + 当前是哪一项」
  //
  // ⚠️ `selectedOption` 必须真的指向 [PlayerTvRowValue.options] 里那一项：
  // 菜单打开时把它当光标起点，越界会让 `options[_chip]` 抛 RangeError。
  // 所以每一处都留了「找不到就退回 0」的兜底。
  // -------------------------------------------------------------------

  PlayerTvRowValue _qualityRow(PlaybackController c) {
    final all = c.qualities;
    // 服务端没给转码梯度时只有原画一档 —— 写「原画」而不是空串：
    // 用户要确认的是「我现在看的是不是最好的那档」，这本身是有效信息。
    if (all.isEmpty) {
      return const PlayerTvRowValue(
        row: PlayerTvRow.quality,
        value: '原画',
        adjustable: false,
        hint: '服务端没有给转码档位，这一条只能放原画',
      );
    }
    final active = c.activeQualityId;
    var selected = 0;
    final options = <PlayerTvOption>[];
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == active) selected = i;
      // 服务端没给地址的档位照画（灰掉），只是 ← / → 会跳过它 ——
      // 直接不画的话，用户会以为这个应用不支持 4K。
      options.add(PlayerTvOption(all[i].label, enabled: all[i].isAvailable));
    }
    return PlayerTvRowValue(
      row: PlayerTvRow.quality,
      value: options[selected].label,
      adjustable: all.length > 1,
      options: options,
      selectedOption: selected,
    );
  }

  PlayerTvRowValue _subtitleRow(PlaybackController c) {
    final tracks = c.allSubtitles;
    if (tracks.isEmpty) {
      return const PlayerTvRowValue(
        row: PlayerTvRow.subtitle,
        value: '关闭',
        adjustable: false,
        hint: '这一条没有任何字幕轨',
      );
    }
    final active = c.activeSubtitleId;
    // 第 0 颗永远是「关闭」—— 把「不要字幕」也做成一档，用户才不用去猜
    // 「怎么关掉」。它占着第 0 位还有个好处：`selectedOption` 永远有值。
    var selected = 0;
    var label = '关闭';
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].id == active) {
        selected = i + 1;
        label = tracks[i].displayLabel;
      }
    }
    // 生效中但不在列表里（例如外挂字幕还没解析完）：说「字幕」比说「关闭」诚实。
    if (active != null && selected == 0) label = '字幕';
    return PlayerTvRowValue(
      row: PlayerTvRow.subtitle,
      value: label,
      options: [
        const PlayerTvOption('关闭'),
        for (final t in tracks) PlayerTvOption(t.displayLabel),
      ],
      selectedOption: selected,
    );
  }

  /// 音轨名走 `TrackLabels.audioTitle`，**本文件不再自己维护一张语言表**。
  ///
  /// 这里一开始抄了一份「`chi` → 中文」的映射（当时的理由是「只为一行文字去
  /// 动 `TrackLabels` 不值得」）。那是错的：桌面内置播放页的音轨菜单、独立
  /// 播放窗口、以及这块菜单一共三处要显示同一个名字，各抄一份的结果是
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
        hint: '这一条只有一条音轨',
      );
    }
    final active = widget.activeAudioId;
    var selected = 0;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].id == active) selected = i;
    }
    return PlayerTvRowValue(
      row: PlayerTvRow.audioTrack,
      value: TrackLabels.audioTitle(tracks[selected]),
      options: [
        for (final t in tracks) PlayerTvOption(TrackLabels.audioTitle(t)),
      ],
      selectedOption: selected,
    );
  }

  PlayerTvRowValue _effectRow(PlaybackController c) {
    final all = PlayerAudioEffect.selectable;
    final active = c.audioEffect;
    if (all.length <= 1) {
      return PlayerTvRowValue(
        row: PlayerTvRow.audioEffect,
        value: PlayerAudioEffect.label(active),
        adjustable: false,
        hint: '这一条没有可切换的音效',
      );
    }
    var selected = all.indexOf(active);
    if (selected < 0) selected = 0;
    return PlayerTvRowValue(
      row: PlayerTvRow.audioEffect,
      value: PlayerAudioEffect.label(active),
      options: [for (final p in all) PlayerTvOption(PlayerAudioEffect.label(p))],
      selectedOption: selected,
    );
  }

  PlayerTvRowValue _rateRow(PlaybackController c) {
    var selected = kPlaybackRates.indexOf(c.rate);
    if (selected < 0) selected = kPlaybackRates.indexOf(1.0);
    return PlayerTvRowValue(
      row: PlayerTvRow.rate,
      value: rateLabel(c.rate),
      options: [for (final r in kPlaybackRates) PlayerTvOption(rateLabel(r))],
      selectedOption: selected,
    );
  }

  PlayerTvRowValue _introRow(PlaybackController c) {
    final marker = c.introMarker;
    return PlayerTvRowValue(
      row: PlayerTvRow.intro,
      // 没有片头标识时写「未标记」而不是空串：空串会被渲染成「—」，
      // 用户读不出那是「还没标」还是「这部片没有片头」。
      value: marker == null ? '未标记' : '跳到 ${_clock(marker.start)}',
      adjustable: false,
      hint: marker == null
          ? '这部片没有片头标记（标记入口在桌面控制栏）'
          : '按 OK 跳到 ${_clock(marker.start)}',
    );
  }

  // -------------------------------------------------------------------
  // 按键 → 动作
  // -------------------------------------------------------------------

  /// OK 落在某一行上。
  ///
  /// `optionIndex` 是选项条里被选中的那颗；这一行没有选项条时为 -1。
  ///
  /// ⚠️ 「片头」跳完**收起菜单**；「选集 / 画质 / 字幕」选完**也收起菜单**：
  /// 选完用户要看的是切换的过渡效果（`_SwitchVeil` + 加载速率），留着菜单
  /// 只会挡住画面。
  void _activate(PlayerTvRow row, int optionIndex) {
    switch (row) {
      case PlayerTvRow.episode:
        // 选集在右侧选项条直接选，不再进二级网格页（见 `_rows` 的注释）。
        if (optionIndex < 0) break;
        final siblings = widget.siblings;
        if (optionIndex >= siblings.length) break;
        unawaited(widget.onPickEpisode(siblings[optionIndex]));
        widget.onClose();
      case PlayerTvRow.intro:
        unawaited(widget.onJumpIntro());
        widget.onClose();
      case PlayerTvRow.quality:
        _pickQuality(optionIndex);
        widget.onClose();
      case PlayerTvRow.subtitle:
        _pickSubtitle(optionIndex);
        widget.onClose();
      case PlayerTvRow.audioTrack:
        _pickAudio(optionIndex);
        widget.onClose();
      case PlayerTvRow.audioEffect:
        _pickEffect(optionIndex);
        widget.onClose();
      case PlayerTvRow.rate:
        _pickRate(optionIndex);
        widget.onClose();
    }
  }

  /// ← / → 落在**没有选项条**的行上。
  ///
  /// 目前只有「选集」会走到这里 —— 它的选项多到铺不下一条，改成「直接换集」
  /// 反而更顺手（看剧时「下一集」是最高频的动作）。
  void _adjust(PlayerTvRow row, int delta) {
    if (row == PlayerTvRow.episode) _stepEpisode(delta);
  }

  void _pickQuality(int i) {
    final all = widget.controller.qualities;
    if (i < 0 || i >= all.length) return;
    // 不可选的档位在菜单里已经灰掉、← / → 也会跳过它，这里再挡一次是为了
    // 鼠标：鼠标点得到灰掉的那一颗。
    if (!all[i].isAvailable) return;
    unawaited(widget.onPickQuality(all[i].id));
  }

  void _pickSubtitle(int i) {
    final tracks = widget.controller.allSubtitles;
    if (i <= 0) {
      // 第 0 颗是「关闭」。`null` 在播放页那边就是「关掉字幕」。
      unawaited(widget.onPickSubtitle(null));
      return;
    }
    final index = i - 1;
    if (index >= tracks.length) return;
    unawaited(widget.onPickSubtitle(tracks[index]));
  }

  void _pickAudio(int i) {
    final tracks = widget.controller.embeddedAudioTracks;
    if (i < 0 || i >= tracks.length) return;
    widget.onPickAudioTrack(tracks[i], i);
  }

  void _pickEffect(int i) {
    final all = PlayerAudioEffect.selectable;
    if (i < 0 || i >= all.length) return;
    unawaited(widget.onPickAudioEffect(all[i]));
  }

  void _pickRate(int i) {
    if (i < 0 || i >= kPlaybackRates.length) return;
    unawaited(widget.onPickRate(kPlaybackRates[i]));
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
}
