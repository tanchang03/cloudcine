import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../core/utils/player_audio_effect.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/playback_controller.dart';
import 'player_tv_panel.dart';
import 'player_tv_rows.dart';

// `kPlaybackRates` / `rateLabel` / `episodeCellLabel` / `episodeRowLabel`
// 现在住在 `player_tv_rows.dart` —— 那是 Flutter 版与**原生 OSD**
// （`android/.../TvOsdView.kt`，走 `core/platform/tv_osd_channel.dart`）
// 共用的唯一一份行模型。
//
// 这里 re-export，是为了不动 `player_page.dart` 里 `kPlaybackRates` 的用法：
// 那张表仍然是「桌面 `_RateMenu` 与 TV 菜单同一张」的那一张。
export 'player_tv_rows.dart';

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
///
/// ## 与原生版的关系
///
/// Android TV 上这块菜单已经换成**原生 View**（`TvOsdView.kt`）：按键到上屏
/// 不再经过 Dart，中继再忙也不影响它出帧。这个 Flutter 版保留为
/// **通道不可用时的回退路径**（`TvOsdChannel.supported == false`），
/// 两边的行数据都来自 [buildPlayerTvRows]。
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

  /// ⛔ 行数据只从 [buildPlayerTvRows] 来 —— 原生 OSD 用的是同一份。
  List<PlayerTvRowValue> _rows() => buildPlayerTvRows(
        controller: widget.controller,
        siblings: widget.siblings,
        item: widget.item,
        activeAudioId: widget.activeAudioId,
      );

  // -------------------------------------------------------------------
  // 按键 → 动作
  // -------------------------------------------------------------------

  /// OK 落在某一行上。
  ///
  /// `optionIndex` 是选项条里被选中的那颗；这一行没有选项条时为 -1。
  ///
  /// ⛔ 规则本体在 [applyPlayerTvRowAction] —— Android TV 上的**原生版菜单
  /// 走的是同一份**（`player_page.dart` 的 `_onTvOsdActivate`）。这里只是
  /// 把本组件的回调打包过去。
  void _activate(PlayerTvRow row, int optionIndex) {
    applyPlayerTvRowAction(
      row: row,
      optionIndex: optionIndex,
      siblings: widget.siblings,
      qualities: widget.controller.qualities,
      subtitles: widget.controller.allSubtitles,
      audioTracks: widget.controller.embeddedAudioTracks,
      target: TvOsdActionTarget(
        onPickQuality: widget.onPickQuality,
        onPickSubtitle: widget.onPickSubtitle,
        onPickAudioTrack: widget.onPickAudioTrack,
        onPickAudioEffect: widget.onPickAudioEffect,
        onPickRate: widget.onPickRate,
        onPickEpisode: widget.onPickEpisode,
        onJumpIntro: widget.onJumpIntro,
        onClose: widget.onClose,
      ),
    );
  }

  /// ← / → 落在**没有选项条**的行上。
  ///
  /// 目前只有「选集」会走到这里 —— 它的选项多到铺不下一条，改成「直接换集」
  /// 反而更顺手（看剧时「下一集」是最高频的动作）。
  void _adjust(PlayerTvRow row, int delta) {
    if (row == PlayerTvRow.episode) _stepEpisode(delta);
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
