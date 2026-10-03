import 'package:cloudcine/core/utils/tv_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不带 context 的 TV 判定。
///
/// 为什么值得测：它决定播放器用**哪一套缓冲参数**（1 GB 那套搬到电视上就是
/// 卡帧与音画不同步的来源），而判据自己藏在一个环境相关的包装里 ——
/// [isTvDevice] 从 `PlatformDispatcher` 读屏幕尺寸，那个值在 `flutter test`
/// 里**改不动**（实测逻辑宽恒为 800），所以只测它的话 TV 分支永远走不到。
/// 判据本体 [isTvSize] 才是纯函数，三条分支都得钉住。
void main() {
  group('isTvSize', () {
    test('Android + 960 逻辑宽（官方 TV 设计尺寸）→ 是电视', () {
      expect(
        isTvSize(platform: TargetPlatform.android, logicalWidth: 960),
        isTrue,
      );
    });

    test('Android + 1080p 电视报上来的更宽的值 → 仍是电视', () {
      // 实际盒子报什么都有：960（720p MDPI）、1280、1920（1080p @2x）。
      // 阈值是**下限**，比它宽的都该算电视。
      expect(
        isTvSize(platform: TargetPlatform.android, logicalWidth: 1920),
        isTrue,
      );
    });

    test('Android + 手机宽度 → 不是电视', () {
      expect(
        isTvSize(platform: TargetPlatform.android, logicalWidth: 412),
        isFalse,
      );
    });

    test('macOS 宽屏 → 不是电视（判据必须带平台，不能只看宽度）', () {
      // 这条最关键：只比宽度的话，1920 宽的桌面会拿到「内存只有 1 GB」那套
      // 保守参数，白白牺牲播放体验 —— 而且没人会发现，因为桌面照样能播。
      expect(
        isTvSize(platform: TargetPlatform.macOS, logicalWidth: 1920),
        isFalse,
      );
    });

    test('阈值是 960，且两个判据共用同一个常量', () {
      expect(tvMinLogicalWidth, 960);
      // 差一点点就不算：边界必须明确，否则「959 宽的盒子」的行为靠猜。
      expect(
        isTvSize(platform: TargetPlatform.android, logicalWidth: 959.9),
        isFalse,
      );
    });
  });

  test('isTvDevice 在测试环境（800 逻辑宽）下是 false —— 只作冒烟，不作结论',
      () {
    // ⚠️ 这条**不能**用来验 TV 分支：flutter test 的窗口逻辑宽恒为 800
    // （2400×1800@3x），永远走不到 TV。它存在的唯一理由是钉住「判据里那个
    // 平台检查真的生效了」—— 如果哪天有人把 platform 判断删掉，这条会红。
    expect(isTvDevice(), isFalse);
  });
}
