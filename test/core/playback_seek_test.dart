import 'package:cloudcine/core/utils/playback_seek.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跳转位置的夹取。
///
/// ## 为什么这条规则值得单独钉住
///
/// 它守的是「按方向键」这个最常用的操作。夹错了**不会抛任何异常**，
/// 只会让播放器跳到一个不存在的位置然后卡住 —— 看起来像播放器挂了。
/// 而两条边界各自对应一个真实场景（片头连按左键、片尾连按右键），
/// 不是假想的输入。
void main() {
  group('clampSeekTarget', () {
    test('范围内的目标原样返回', () {
      expect(
        clampSeekTarget(
          const Duration(seconds: 90),
          const Duration(minutes: 2),
        ),
        const Duration(seconds: 90),
      );
    });

    test('退到片头之前 → 夹到 0，而不是负数', () {
      // 场景：刚开播 5 秒，按一下「后退 10 秒」。
      // 不夹的话 mpv 会收到一个负位置并卡住，而不是「停在片头」。
      expect(
        clampSeekTarget(
          const Duration(seconds: -5),
          const Duration(minutes: 2),
        ),
        Duration.zero,
      );
    });

    test('越过片尾 → 夹到总时长，而不是跳到文件外面', () {
      // 场景：还剩 3 秒，按一下「前进 10 秒」。
      expect(
        clampSeekTarget(
          const Duration(minutes: 2, seconds: 7),
          const Duration(minutes: 2),
        ),
        const Duration(minutes: 2),
      );
    });

    test('总时长未知时**不夹上界** —— 否则刚开播一按右键进度就归零', () {
      // 文件头还没解出来时 `duration` 是 0，那一刻没有上界可夹。
      // 硬夹会把位置压回 0，用户看到的是「进度条归零」。
      expect(
        clampSeekTarget(
          const Duration(seconds: 10),
          Duration.zero,
        ),
        const Duration(seconds: 10),
      );
    });

    test('总时长未知时下界照样夹', () {
      // 上界不知道，不代表下界也可以放任。
      expect(
        clampSeekTarget(
          const Duration(seconds: -10),
          Duration.zero,
        ),
        Duration.zero,
      );
    });

    test('恰好落在两端时不改动', () {
      expect(
        clampSeekTarget(Duration.zero, const Duration(minutes: 2)),
        Duration.zero,
      );
      expect(
        clampSeekTarget(
          const Duration(minutes: 2),
          const Duration(minutes: 2),
        ),
        const Duration(minutes: 2),
      );
    });
  });
}
