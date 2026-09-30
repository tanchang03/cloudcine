import 'package:cloudcine/domain/services/playback_exit_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「返回时要不要停播」是**平台约定**，不是随手写的 if。
///
/// 真机背景：macOS 上从播放页返回媒体库，播放仍在继续。桌面这其实是
/// **想要**的行为（可以一边浏览一边听），但当时没有任何控件能停它、
/// 也回不去播放页，于是看起来像 bug。而在 Android / Android TV 上继续
/// 后台出声是明确的错误行为：既没有通知栏控件能停它，也白占着一个
/// 4K 解码器和网络连接。
void main() {
  group('PlaybackExitBehavior.forPlatform', () {
    test('桌面三平台：返回后保持播放', () {
      for (final p in const [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          PlaybackExitBehavior.forPlatform(p),
          PlaybackExitBehavior.keepPlaying,
          reason: '$p 上返回不该打断播放',
        );
      }
    });

    test('Android（含 Android TV）：返回即停止并释放解码器', () {
      expect(
        PlaybackExitBehavior.forPlatform(TargetPlatform.android),
        PlaybackExitBehavior.stopAndRelease,
      );
    });

    test('iOS 与 fuchsia 按移动端处理', () {
      expect(
        PlaybackExitBehavior.forPlatform(TargetPlatform.iOS),
        PlaybackExitBehavior.stopAndRelease,
      );
      expect(
        PlaybackExitBehavior.forPlatform(TargetPlatform.fuchsia),
        PlaybackExitBehavior.stopAndRelease,
      );
    });

    test('映射表覆盖全部平台，一个不漏', () {
      const expected = <TargetPlatform, PlaybackExitBehavior>{
        TargetPlatform.macOS: PlaybackExitBehavior.keepPlaying,
        TargetPlatform.windows: PlaybackExitBehavior.keepPlaying,
        TargetPlatform.linux: PlaybackExitBehavior.keepPlaying,
        TargetPlatform.android: PlaybackExitBehavior.stopAndRelease,
        TargetPlatform.iOS: PlaybackExitBehavior.stopAndRelease,
        TargetPlatform.fuchsia: PlaybackExitBehavior.stopAndRelease,
      };

      // 少一个就说明 Flutter 新增了平台而这里没表态。
      expect(expected.keys.toSet(), TargetPlatform.values.toSet());

      expected.forEach((platform, behavior) {
        expect(
          PlaybackExitBehavior.forPlatform(platform),
          behavior,
          reason: '$platform 的分类被改动了',
        );
      });
    });
  });
}
