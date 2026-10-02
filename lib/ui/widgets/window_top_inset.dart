import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 窗口顶部的**留白区**，高度等于系统标题栏（32pt）。
///
/// ⚠️ **只有 macOS 用它**。系统标题栏已经被 `MainFlutterWindow.swift` 的
/// `applyVirtualTitleBar()` 抹成透明（`fullSizeContentView` + `titlebarAppearsTransparent`
/// + `titleVisibility = .hidden`），窗口内容一路铺到最顶端。但红黄绿三个
/// **原生按钮还在那里** —— 它们的位置由 AppKit 决定（x 约 9..69、圆心距顶
/// 16），所以顶部必须留出一条空白，否则页面内容会被三个按钮压住。
///
/// **它是刻意完全不可见的**：没有底色、没有下边框、不画任何文字。
///
/// 理由：只要画了其中任何一样，顶部就会变成「一条横条」，看起来
/// 跟系统标题栏没去掉一样 —— 而用户要的正是「没有标题栏」。
/// 应用名由侧栏的 Logo 承担，不需要在顶部再重复一遍。
///
/// 高度取 [AppTheme.titleBarHeight]，**等于系统标题栏那一档（32pt）**，
/// 这样原生按钮的圆心正好落在留白区中线上。
///
/// 拖动窗口、双击缩放、全屏仍然由原生标题栏那 32pt 承担
/// （那一段在内容视图之上，命中测试到不了 Flutter），所以这里不需要
/// 任何手势代码。
class WindowTopInset extends StatelessWidget {
  const WindowTopInset({super.key});

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: AppTheme.titleBarHeight);
}
