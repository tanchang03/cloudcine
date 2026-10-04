import 'package:media_kit/media_kit.dart' as mk;

import '../../domain/services/playback_engine.dart';

/// 引擎契约的轨道对象 → media_kit 的轨道对象。
///
/// ## 为什么需要它
///
/// 换内核之后，轨道清单从引擎契约来（[EngineTrack]），但**两个播放器的
/// 音轨 / 字幕菜单仍然按 media_kit 的类型渲染**：
///
///   - `player_page.dart` 的 `_AudioMenu` 与 `player_tv_overlay.dart` 收的是
///     `List<mk.AudioTrack>`；
///   - `player_window_app.dart` 的 `_audioTracks` / `_embeddedSubtitles` 同理；
///   - 文案全走 `TrackLabels.audioTitle` / `audioDetail` / `subtitleDetail`，
///     而它们吃的是 media_kit 的轨道对象。
///
/// 把这三个菜单改成吃 [EngineTrack] 是**更大**的一次改动（`TrackLabels` 要
/// 整份改写、两处菜单的泛型也要动），而它带来的收益只是「少一个转换函数」。
/// 所以这里选择在**边界上转换一次**：菜单与文案层完全不动，风险最小。
///
/// ## ⚠️ 这是「显示用」的对象，不能拿去下发给引擎
///
/// 合成出来的 `mk.AudioTrack` 只带 id / title / language / codec / isDefault。
/// **别把它喂给 `mk.Player.setAudioTrack`** —— 换内核之后那已经不是播放内核了。
/// 切轨一律走 [PlaybackEngine.selectAudioTrack] / [PlaybackEngine.selectSubtitleTrack]，
/// 传的是整数轨道号（[EngineTrack.id]）。
///
/// ## 为什么 `isDefault` 要给非空
///
/// `mk._Track.isDefault` 是 `bool?`（`null` = 引擎没说）。这里统一填
/// `false`：契约里的 [EngineTrack.isDefault] 本来就是非空布尔，语义是
/// 「引擎有没有把它标成默认」——`false` 正是「没标」。留着 `null` 反而会让
/// `TrackLabels.subtitleDetail` 的 `track.isDefault == true` 之外多出第三种状态。
abstract final class TrackBridge {
  const TrackBridge._();

  /// 音轨。`id` 是引擎内部的轨道号，转成字符串是因为 media_kit 的 id 是字符串。
  static mk.AudioTrack audio(EngineTrack t) => mk.AudioTrack(
        '${t.id}',
        t.title,
        t.language,
        codec: t.codec,
        isDefault: t.isDefault,
      );

  /// 字幕轨。
  static mk.SubtitleTrack subtitle(EngineTrack t) => mk.SubtitleTrack(
        '${t.id}',
        t.title,
        t.language,
        codec: t.codec,
        isDefault: t.isDefault,
      );
}
