import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

/// 「这台设备是电视」的判据。
///
/// ## 为什么要有**不带 context** 的这一份
///
/// `AppTheme.isTvLayout(context)` 要读 `MediaQuery`，而播放器的缓冲参数是在
/// `PlaybackController` 构造时定的 —— 那一刻**还没有任何 widget**，拿不到
/// context。于是要么把判定推迟到第一帧（参数就晚了一拍，而 mpv 的 stream 层
/// 缓存**只在打开片源那一刻生效**，晚一拍等于没设），要么在这里给一份。
///
/// ## 为什么判据是「屏幕宽度」而不是系统标志
///
/// Flutter 没有暴露 Android 的 leanback 标志（要读 `UiModeManager` 得走
/// method channel 写原生代码）。而**逻辑宽度 ≥ 960** 这个判据实测够用：
/// 官方 TV 设计稿就是 960×540，手机普遍只有 360–430，中间的平板即使被误判，
/// 拿到的也只是「更适合远看」的那套参数，不会坏。
///
/// ⚠️ [tvMinLogicalWidth] 是**唯一**的阈值：带 context 那份（[AppTheme]）
/// 必须引用同一个常量。两处各写一个数字的话，「桌面端某个页面上的 TV 分支」
/// 与「播放器里的 TV 参数」会在某个宽度上分道扬镳，而那种 bug 只在特定
/// 分辨率的盒子上出现 —— 最难查的那一类。
const double tvMinLogicalWidth = 960;

/// 「是电视吗」的**判据本体**：平台 + 逻辑宽度。
///
/// 拆出来是因为 [isTvDevice] 要从 `PlatformDispatcher` 里读屏幕尺寸，而那个
/// 值在 `flutter test` 里**改不动**（实测：`tester.view.physicalSize` 设过之后
/// `PlatformDispatcher.instance.views.first` 仍是 2400×1800@3.0，逻辑宽恒为
/// 800）。也就是说只测 [isTvDevice] 的话，TV 分支在测试里**永远走不到** ——
/// 一条永远为假的断言比没有断言更糟，它会让人以为验过了。
///
/// 判据本体是纯函数，三条分支都能测；[isTvDevice] 只负责把值取来喂给它。
bool isTvSize({
  required TargetPlatform platform,
  required double logicalWidth,
}) =>
    platform == TargetPlatform.android && logicalWidth >= tvMinLogicalWidth;

/// Android TV（或电视盒子）上返回 `true`。
///
/// ⚠️ 已知盲区：报出**逻辑宽 < 960** 的电视盒子会漏判（例如少数把 1080p 屏
/// 报成 800 逻辑宽的旧盒子）。真机上若发现「明明是电视却没走 TV 参数」，
/// 第一件事是去诊断页看那行「策略=桌面/TV」—— 那行就是为这类设备写的。
bool isTvDevice() {
  final views = PlatformDispatcher.instance.views;
  if (views.isEmpty) return false;

  final view = views.first;
  final ratio = view.devicePixelRatio;
  if (ratio <= 0) return false;

  return isTvSize(
    platform: defaultTargetPlatform,
    logicalWidth: view.physicalSize.width / ratio,
  );
}
