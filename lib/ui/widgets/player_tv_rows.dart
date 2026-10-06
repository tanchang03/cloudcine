import 'dart:async';

import 'package:media_kit/media_kit.dart' as mk;

import '../../core/utils/file_names.dart';
import '../../core/utils/player_audio_effect.dart';
import '../../core/utils/track_labels.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/quality_option.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/playback_controller.dart';
import 'player_tv_panel.dart';

/// 倍速档位。
///
/// ⚠️ 桌面控制栏的 `_RateMenu` **必须**用这一份：两张表各写一份的话，
/// 「电视上能选 2.0x、桌面上只有 1.5x」这种偏差没有任何人会发现 ——
/// 没人会开着两个平台对着数档位。
const List<double> kPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

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

/// `1:02:03` / `02:03`。只给「片头」那一行用。
String tvClockLabel(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 构建 TV 播放菜单的 7 行模型。
///
/// ## ⛔ 这是**唯一**一份，不要再写第二份
///
/// 电视上这块菜单现在有两个渲染器：
///   * Flutter 版 —— `player_tv_overlay.dart` 的 [PlayerTvOverlay]（回退路径）；
///   * 原生版 —— `android/.../TvOsdView.kt`，由 [encodeTvOsdPayload] 喂数据。
///
/// 两边的**几何与按键语义**是照抄的（原型 `KuakeOsdView` 的注释里记着这件事），
/// 数据则必须来自这里。各写一份的话，「原生菜单里画质有 4 档、Flutter 菜单里
/// 有 5 档」这种偏差没有任何一台设备会同时显示出来 —— 也就永远不会被发现。
///
/// 行的顺序**就是** [PlayerTvRow] 的声明顺序，原生那边按下标回调，
/// 播放页用 `PlayerTvRow.values[index]` 还原，两边都依赖这个约定。
List<PlayerTvRowValue> buildPlayerTvRows({
  required PlaybackController controller,
  required List<MediaItem> siblings,
  required MediaItem? item,
  required String? activeAudioId,
}) {
  final epIndex =
      item == null ? -1 : siblings.indexWhere((i) => i.id == item.id);

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
    _qualityRow(controller),
    _subtitleRow(controller),
    _audioRow(controller, activeAudioId),
    _effectRow(controller),
    _rateRow(controller),
    _introRow(controller),
  ];
}

/// 把 7 行模型编成原生 OSD 直接吃的 JSON。
///
/// 形状与 `TvOsdView.Row` 一一对应：
/// `label / value / options[] / enabled[] / vertical / selected / hint`。
/// `enabled` 与 `options` **等长**（原生那边 `enabled.getOrElse(i) { true }`
/// 只是兜底，不是常态）。
Map<String, Object?> encodeTvOsdPayload(
  List<PlayerTvRowValue> rows, {
  int selectedRow = 0,
}) {
  return <String, Object?>{
    'selectedRow': selectedRow,
    'rows': <Map<String, Object?>>[
      for (final r in rows)
        <String, Object?>{
          'label': r.row.label,
          'value': r.value,
          'options': <String>[for (final o in r.options) o.label],
          'enabled': <bool>[for (final o in r.options) o.enabled],
          'vertical': r.vertical,
          'selected': r.selectedOption,
          'hint': r.hint,
        },
    ],
  };
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
PlayerTvRowValue _audioRow(PlaybackController c, String? activeAudioId) {
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
  var selected = 0;
  for (var i = 0; i < tracks.length; i++) {
    if (tracks[i].id == activeAudioId) selected = i;
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
    value: marker == null ? '未标记' : '跳到 ${tvClockLabel(marker.start)}',
    adjustable: false,
    hint: marker == null
        ? '这部片没有片头标记（标记入口在桌面控制栏）'
        : '按 OK 跳到 ${tvClockLabel(marker.start)}',
  );
}

// -------------------------------------------------------------------
// 「按了 OK」→ 播放页的动作
// -------------------------------------------------------------------

/// 播放页交给 TV 菜单的 7 个动作回调。
///
/// 收成一个对象是为了让 [applyPlayerTvRowAction] 只依赖一个参数 ——
/// 7 个回调散着传，两个调用点（Flutter 版菜单 / 原生版菜单）很容易
/// 漏掉一个，而漏掉的那个正好是低频的那一行（例如「音效」）。
class TvOsdActionTarget {
  const TvOsdActionTarget({
    required this.onPickQuality,
    required this.onPickSubtitle,
    required this.onPickAudioTrack,
    required this.onPickAudioEffect,
    required this.onPickRate,
    required this.onPickEpisode,
    required this.onJumpIntro,
    required this.onClose,
  });

  final Future<void> Function(String qualityId) onPickQuality;
  final Future<void> Function(SubtitleTrack? track) onPickSubtitle;
  final void Function(mk.AudioTrack track, int index) onPickAudioTrack;
  final Future<void> Function(AudioEffectPreset preset) onPickAudioEffect;
  final Future<void> Function(double rate) onPickRate;
  final Future<void> Function(MediaItem item) onPickEpisode;
  final Future<void> Function() onJumpIntro;
  final void Function() onClose;
}

/// 把「用户在 TV 菜单上按了 OK」翻译成播放页的动作。
///
/// ## ⛔ 两个渲染器共用这一份
///
/// Flutter 版菜单（`PlayerTvOverlay._activate`）与原生版菜单
/// （`player_page.dart` 的 `_onTvOsdActivate`）都调这里。各写一遍的话，
/// 「原生菜单切字幕会落库、Flutter 菜单切字幕不落库」这种偏差只会在
/// 换回 Flutter 菜单那天才暴露 —— 而那天可能永远不会到来。
///
/// ## 为什么收「选项列表」而不是整个控制器
///
/// 控制器是个 1600 行的重对象，为了跑一条「第 2 颗 chip 该落到哪条音轨」
/// 的断言去造它不划算。这里只收真正用到的三张表 —— 于是这条映射规则
/// 可以被单测钉住（`test/ui/widgets/player_tv_rows_test.dart`）。
///
/// ## 为什么每一条都 `onClose`
///
/// 云影的菜单是「选完就收起」：用户按 OK 之后要看的是切换的过渡效果，
/// 留着菜单只会挡住画面。**唯一**不收起的是「选集」越界那一档（
/// `optionIndex` 为负，说明这一条根本不在剧集列表里）。
void applyPlayerTvRowAction({
  required PlayerTvRow row,
  required int optionIndex,
  required List<MediaItem> siblings,
  required List<QualityOption> qualities,
  required List<SubtitleTrack> subtitles,
  required List<mk.AudioTrack> audioTracks,
  required TvOsdActionTarget target,
}) {
  switch (row) {
    case PlayerTvRow.episode:
      if (optionIndex < 0 || optionIndex >= siblings.length) return;
      unawaited(target.onPickEpisode(siblings[optionIndex]));
    case PlayerTvRow.intro:
      unawaited(target.onJumpIntro());
    case PlayerTvRow.quality:
      if (optionIndex >= 0 && optionIndex < qualities.length) {
        // 不可选的档位在菜单里已经灰掉、← / → 也会跳过它，这里再挡一次是
        // 为了鼠标：鼠标点得到灰掉的那一颗。
        if (qualities[optionIndex].isAvailable) {
          unawaited(target.onPickQuality(qualities[optionIndex].id));
        }
      }
    case PlayerTvRow.subtitle:
      if (optionIndex <= 0) {
        // 第 0 颗是「关闭」。`null` 在播放页那边就是「关掉字幕」。
        unawaited(target.onPickSubtitle(null));
      } else if (optionIndex - 1 < subtitles.length) {
        unawaited(target.onPickSubtitle(subtitles[optionIndex - 1]));
      }
    case PlayerTvRow.audioTrack:
      if (optionIndex >= 0 && optionIndex < audioTracks.length) {
        target.onPickAudioTrack(audioTracks[optionIndex], optionIndex);
      }
    case PlayerTvRow.audioEffect:
      final all = PlayerAudioEffect.selectable;
      if (optionIndex >= 0 && optionIndex < all.length) {
        unawaited(target.onPickAudioEffect(all[optionIndex]));
      }
    case PlayerTvRow.rate:
      if (optionIndex >= 0 && optionIndex < kPlaybackRates.length) {
        unawaited(target.onPickRate(kPlaybackRates[optionIndex]));
      }
  }
  target.onClose();
}
