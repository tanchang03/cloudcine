import 'package:cloudcine/domain/services/playback_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as mk;

/// media_kit 会把 `auto` / `no` 两条**合成轨**硬塞在 `tracks.*` 的最前面
/// （见 `media_kit/lib/src/player/native/player/real.dart`：
/// `final subtitle = [SubtitleTrack.auto(), SubtitleTrack.no()];`，
/// 它们的 `id` 就是字符串 `'auto'` / `'no'`，不是 mpv 的轨道号）。
///
/// 2026-09-30 真机实测踩到：一个**根本没有内嵌字幕**的 mp4，日志里
/// `内嵌轨更新：字幕 2 条、音轨 2 条、视频 2 条` —— 每一项都正好是那两条
/// 合成轨。老代码把它们当成真实内嵌轨，于是连着三个后果：
///
///   1. `int.tryParse('auto')` → `null` → 报「内嵌字幕缺少轨道号」；
///   2. 自动选字幕取的是「第一条」，而合成轨永远排第一 → **每次播放必错**；
///   3. 那条错误被塞进 `_error`，播放页据此拉起全屏「播放失败」遮罩 →
///      **画面被挡住，声音却还在放**，用户以为播放器坏了。
///
/// 这三条链在真机上全部复现过，所以过滤逻辑必须有回归。
void main() {
  group('PlaybackController.realTracksOf —— 剔除 media_kit 的合成轨', () {
    test('字幕：auto / no 被剔除，真实轨道保留', () {
      final tracks = [
        mk.SubtitleTrack('auto', null, null),
        mk.SubtitleTrack('no', null, null),
        mk.SubtitleTrack('3', 'Chinese', 'chi'),
      ];

      final real = PlaybackController.realTracksOf(tracks, (t) => t.id);

      expect(real.length, 1);
      expect(real.single.id, '3');
    });

    test('字幕：只有合成轨时返回空 —— 实测那个 mp4 就是这种情形', () {
      final tracks = [
        mk.SubtitleTrack('auto', null, null),
        mk.SubtitleTrack('no', null, null),
      ];

      expect(PlaybackController.realTracksOf(tracks, (t) => t.id), isEmpty);
    });

    test('字幕：过滤后相对顺序不变，且每条都有可解析的轨道号', () {
      final tracks = [
        mk.SubtitleTrack('auto', null, null),
        mk.SubtitleTrack('no', null, null),
        mk.SubtitleTrack('7', '简体', 'chi'),
        mk.SubtitleTrack('9', 'English', 'eng'),
        mk.SubtitleTrack('11', '日本語', 'jpn'),
      ];

      final real = PlaybackController.realTracksOf(tracks, (t) => t.id);

      expect(real.map((t) => t.id).toList(), ['7', '9', '11']);
      for (final t in real) {
        expect(int.tryParse(t.id), isNotNull);
      }
    });

    test('音轨：同样过滤 —— 否则单音轨文件也会一直显示出音轨菜单', () {
      final tracks = [
        mk.AudioTrack('auto', null, null),
        mk.AudioTrack('no', null, null),
        mk.AudioTrack('1', '国语', 'chi'),
      ];

      final real = PlaybackController.realTracksOf(tracks, (t) => t.id);

      expect(real.length, 1);
      expect(real.single.id, '1');
    });

    test('视频轨：同样过滤（日志里那句「视频 2 条」就是这两条合成轨）', () {
      final tracks = [
        mk.VideoTrack('auto', null, null),
        mk.VideoTrack('no', null, null),
        mk.VideoTrack('1', null, null),
      ];

      final real = PlaybackController.realTracksOf(tracks, (t) => t.id);

      expect(real.length, 1);
      expect(real.single.id, '1');
    });

    test('非数字 id 一律不算真实轨道', () {
      final tracks = [
        mk.SubtitleTrack('auto', null, null),
        mk.SubtitleTrack('', null, null),
        mk.SubtitleTrack('chi', null, null),
      ];

      expect(PlaybackController.realTracksOf(tracks, (t) => t.id), isEmpty);
    });

    test('空列表不炸', () {
      expect(
        PlaybackController.realTracksOf(<mk.SubtitleTrack>[], (t) => t.id),
        isEmpty,
      );
    });
  });
}
