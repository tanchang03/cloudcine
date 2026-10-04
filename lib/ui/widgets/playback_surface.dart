import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;

import '../../data/playback/fvp_playback_engine.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../../domain/services/playback_engine.dart';

/// 出画面的那一层。**按当前引擎挑渲染组件**。
///
/// ## 为什么必须是独立组件，而不是给两个内核各写一个 widget
///
/// 两个内核的渲染句柄类型**不同且互不兼容**：
///   - media_kit → `VideoController`（配 `media_kit_video` 的 `Video`）；
///   - fvp       → `VideoPlayerController`（配 `video_player` 的 `VideoPlayer`）。
///
/// 而两个播放器（内置页 `player_page.dart`、独立窗口 `player_window_app.dart`）
/// 都只持有一个 [PlaybackEngine]，不该知道现在跑的是哪一个 —— 否则「DV 片要
/// 换渲染组件」这件事会散进两个页面，改一处必漏另一处。
///
/// 所以分派只发生在这里一处：调用方永远写 `PlaybackSurface(engine: ...)`。
///
/// ## 领域层为什么不知道这个组件
///
/// [PlaybackEngine] 的契约里**故意没有**「给我一个渲染句柄」这个方法 ——
/// 领域层不引 Flutter，拿不到 widget。两个实现各自把句柄做成
/// **具体类型上的 getter**（`MediaKitPlaybackEngine.videoController` /
/// `FvpPlaybackEngine.videoController`），由本文件按具体类型取。
///
/// ## fvp 那条路的 `fit` 只实现了 `contain`
///
/// `media_kit_video` 的 `Video` 自带 `fit` / `fill` / `alignment` 一整套；
/// `video_player` 的 `VideoPlayer` 只有「把纹理铺满给它的盒子」。
/// 这里用 [AspectRatio] + [Center] 手工拼出 `BoxFit.contain` 的效果 ——
/// 这正是两个调用点用的那一个（窗口显式传、播放页取默认）。
/// **别的 `fit` 值在 fvp 上不生效**，写在这里以免将来有人以为它是通用的。
class PlaybackSurface extends StatelessWidget {
  const PlaybackSurface({
    super.key,
    required this.engine,
    this.controls,
    this.fit = BoxFit.contain,
    this.fill = const Color(0xFF000000),
    this.subtitleViewConfiguration = const SubtitleViewConfiguration(),
  });

  final PlaybackEngine engine;

  /// 自绘控制栏的钩子。两个调用点都传「什么都不画」（它们有自己的控制栏）。
  ///
  /// fvp 那条路**没有对等物**：`video_player` 不带控制栏，所以这个参数
  /// 在那里被忽略 —— 不是漏了，是本来就没有。
  final VideoControlsBuilder? controls;

  /// 只在 media_kit 那条路上生效（见类文档）。
  final BoxFit fit;

  /// 黑边底色。两个内核都支持。
  final Color fill;

  /// 字幕样式。只有 media_kit 那条路支持（它用 Flutter 层渲染字幕）；
  /// fvp 的字幕由 mdk 自己（libass）烧进画面，样式不从这里走。
  final SubtitleViewConfiguration subtitleViewConfiguration;

  @override
  Widget build(BuildContext context) {
    final e = engine;

    if (e is MediaKitPlaybackEngine) {
      return Video(
        controller: e.videoController,
        controls: controls,
        fit: fit,
        fill: fill,
        subtitleViewConfiguration: subtitleViewConfiguration,
      );
    }

    if (e is FvpPlaybackEngine) {
      final controller = e.videoController;
      // 引擎建出来了但还没 `open()`：`video_player` 那时还没有 playerId。
      // 只画底色，不要塞一个未初始化的 `VideoPlayer` —— 它内部会渲染一个空
      // `Container`，尺寸是 0，于是 `AspectRatio` 拿到 0 宽高会在下一帧
      // 触发一次无意义的布局异常。
      if (controller == null) return ColoredBox(color: fill);

      final value = controller.value;
      final ratio = value.isInitialized && value.aspectRatio > 0
          ? value.aspectRatio
          : 16 / 9;
      return ColoredBox(
        color: fill,
        child: Center(
          child: AspectRatio(
            aspectRatio: ratio,
            child: vp.VideoPlayer(controller),
          ),
        ),
      );
    }

    // 未知实现：不猜。画一块底色比抛异常好 —— 这层在播放页的 Stack 里，
    // 抛出去会把整个播放页带崩。
    return ColoredBox(color: fill);
  }
}
