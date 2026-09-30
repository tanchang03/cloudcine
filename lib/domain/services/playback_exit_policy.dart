import 'package:flutter/foundation.dart';

/// 从播放页「返回」时，播放器该怎么办。
///
/// 这不是实现细节，是**平台约定**，所以单独成文件、单独可测。
///
///   - **桌面**（macOS / Windows / Linux）：返回列表通常意味着「一边浏览
///     一边继续听」。桌面窗口本来就能并存多个内容，停掉播放是打断用户，
///     而且任务栏 / 程序坞里随时找得回来。
///   - **移动端 / Android TV**：返回意味着「我看完了」。继续在后台出声
///     既没有可见的控件可以停它，也不符合系统对后台音频的预期 ——
///     Android 上要长期后台播放得配前台服务与常驻通知，那是另一件事。
///     更实际的问题是：一个已经离开的页面还占着 4K 解码器和网络连接。
///
/// 判断依据用 [TargetPlatform] 而不是 `dart:io` 的 `Platform.isXxx`：
/// 前者可以在单元测试里用 `debugDefaultTargetPlatformOverride` 覆盖，
/// 后者不行 —— 而平台分支恰恰是最需要测的那类代码。
///
/// 注：Android TV 走的就是 [TargetPlatform.android]，所以「TV 返回即停止」
/// 不需要额外的 TV 探测；手机与 TV 在这件事上的期望是一致的。
enum PlaybackExitBehavior {
  /// 保持播放，只把控制权交回列表。
  keepPlaying,

  /// 停止播放并释放解码资源。
  stopAndRelease;

  /// 这个平台上「返回」应当走哪条路。
  ///
  /// 用穷尽 `switch` 而不是 `default`：将来 Flutter 新增平台时这里会
  /// **编译不过**，逼人明确表态，而不是悄悄归到某一类里。
  static PlaybackExitBehavior forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux =>
          PlaybackExitBehavior.keepPlaying,
        TargetPlatform.android ||
        TargetPlatform.iOS ||
        TargetPlatform.fuchsia =>
          PlaybackExitBehavior.stopAndRelease,
      };
}
