import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart' as vp;

import '../../data/playback/fvp_playback_engine.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../../data/playback/video_player_exo_playback_engine.dart';
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
/// 这里手工拼出 `BoxFit.contain` 的效果 —— 这正是两个调用点用的那一个
/// （窗口显式传、播放页取默认）。
/// **别的 `fit` 值在 fvp 上不生效**，写在这里以免将来有人以为它是通用的。
///
/// ⚠️ 2026-10-05 platformView 线（Android TV）起：**不能再套 `AspectRatio`**——
/// platform view 的尺寸由原生 `setFixedSize` + Flutter 给的 rect 两边协商，
/// 外面再套一层会让 hybrid composition 算错。letterbox 由内部自己算
/// （`LayoutBuilder` + 手工定宽高）。macOS 的 textureView 同样走这套，
/// 视觉语义一致。
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
      return _FvpPlaybackSurface(
        key: ValueKey(e),
        engine: e,
        fill: fill,
      );
    }
    if (e is VideoPlayerExoPlaybackEngine) {
      return _FvpPlaybackSurface(
        key: ValueKey(e),
        engine: e,
        fill: fill,
      );
    }

    // 未知实现：不猜。画一块底色比抛异常好 —— 这层在播放页的 Stack 里，
    // 抛出去会把整个播放页带崩。
    return ColoredBox(color: fill);
  }
}

/// fvp 引擎的出画面层。**与高频重建隔离**。
///
/// 播放页会按 position tick 高频重建整棵子树（`player_page.dart`），而
/// platform view 是 hybrid composition —— 每次重建都有一次额外合成风险。
/// 所以这个 StatefulWidget 只在「引擎实例 / controller / 已初始化状态 /
/// 宽高比」真的变了才重新组合出子树，其余重建直接返回缓存的 widget 实例
/// （相同实例短路子孙的重建）。
class _FvpPlaybackSurface extends StatefulWidget {
  const _FvpPlaybackSurface({
    super.key,
    required this.engine,
    required this.fill,
  });

  final Object engine;
  final Color fill;

  @override
  State<_FvpPlaybackSurface> createState() => _FvpPlaybackSurfaceState();
}

class _FvpPlaybackSurfaceState extends State<_FvpPlaybackSurface> {
  vp.VideoPlayerController? _bound;
  Widget? _cached;
  bool _inited = false;
  double _ratio = 0;

  @override
  void didUpdateWidget(covariant _FvpPlaybackSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.engine, oldWidget.engine)) {
      _unbind();
      _cached = null;
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  void _unbind() {
    _bound?.removeListener(_onController);
    _bound = null;
  }

  /// 只关心「初始化 / 宽高比」两个会改变布局的值；进度每拍都报事件，
  /// 不能每次都 setState，否则这条隔离就白做了。
  void _onController() {
    final v = _bound?.value;
    if (v == null || !mounted) return;
    if (v.isInitialized == _inited && v.aspectRatio == _ratio) return;
    _inited = v.isInitialized;
    _ratio = v.aspectRatio;
    setState(() => _cached = null);
  }

  @override
  Widget build(BuildContext context) {
    final controller = switch (widget.engine) {
      FvpPlaybackEngine e => e.videoController,
      VideoPlayerExoPlaybackEngine e => e.videoController,
      _ => null,
    };
    // controller 可能因为「引擎重开」而换实例。
    if (!identical(controller, _bound)) {
      _unbind();
      _bound = controller;
      _bound?.addListener(_onController);
      _cached = null;
      _inited = controller?.value.isInitialized ?? false;
      _ratio = controller?.value.aspectRatio ?? 0;
    }

    if (controller == null) return ColoredBox(color: widget.fill);

    final v = controller.value;
    // 只在 isInitialized / aspectRatio 真变化时 setState（进度 tick 不算）——
    // 由 _onController 统一做，这里不用区分原因。
    return _cached ??= ColoredBox(
      color: widget.fill,
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ratio = v.isInitialized && v.aspectRatio > 0
                ? v.aspectRatio
                : 16 / 9;
            var w = constraints.maxWidth;
            var h = w / ratio;
            if (h > constraints.maxHeight) {
              h = constraints.maxHeight;
              w = h * ratio;
            }
            return SizedBox(
              width: w,
              height: h,
              child: vp.VideoPlayer(controller),
            );
          },
        ),
      ),
    );
  }
}
