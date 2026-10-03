import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 「正在播放」动效：三根上下跳动的竖条（等化器图标）。
///
/// ## 为什么是这个形状，而不是一个喇叭 / 一个圆点
///
/// 剧集面板里「哪一集在播」已经有三个静态标记了 —— 左侧那条竖线、背景色、
/// 加粗的标题。再加第四个静态标记只是噪音。**动**才是那个缺掉的信号：
/// 用户扫一眼就知道「这一集正在放」，不用去读任何字。
///
/// ## ⚠️ 它只在面板展开时存在
///
/// 调用点在 `player_window_app.dart` 的 `_buildEpisodeTile`，而那个 tile 只在
/// 剧集面板挂着的时候才被 build。面板收起后 `_playlistMounted` 转 false、
/// 整棵树被摘掉，[AnimationController] 随之 dispose —— 不会在放 4K 的时候
/// 留一个 60fps 的动画一直在后台烧 GPU。
///
/// 改这个组件时**别把它挪到常驻的树上**（比如控制栏），那会变成
/// 「一开播就一直在重绘」。
class NowPlayingBars extends StatefulWidget {
  const NowPlayingBars({
    super.key,
    this.size = 14,
    this.color,
    this.animate = true,
  });

  /// 正方形边长。竖条宽度、间距、最大高度都按它等比算。
  final double size;

  /// 竖条颜色。默认用主题强调色。
  final Color? color;

  /// 关掉动画（测试 / 需要静止的场景）。仍然画三根条，只是不动。
  final bool animate;

  @override
  State<NowPlayingBars> createState() => _NowPlayingBarsState();
}

class _NowPlayingBarsState extends State<NowPlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统「减弱动态效果」开着时不动。这既是无障碍要求，也是测试里
    // **唯一**能让这个动画停下来的口子 —— 它一停，`pumpAndSettle` 就不会
    // 卡在超时上（对照组：窗口里的缓冲指示 `CircularProgressIndicator` 是
    // 个永不停止的动画，那里的用例只能改用显式 `pump`）。
    final still = !widget.animate || MediaQuery.disableAnimationsOf(context);
    if (still) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(NowPlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) didChangeDependencies();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppTheme.accent;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          // 停住时给一个中间相位，而不是全平：静止的三根等高细线看起来像
          // 「三条分隔线」，读不出「这是播放指示」。
          final t = _controller.isAnimating ? _controller.value : 0.30;
          final scales = nowPlayingBarScales(t);
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              for (final s in scales)
                Container(
                  width: math.max(1.5, widget.size * 0.17),
                  height: widget.size * s,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 三根竖条在相位 [t]（0..1）时的高度**占 [NowPlayingBars.size] 的比例**。
///
/// 抽成顶层纯函数是为了能直接单测：这个动画唯一会错的方式是「三根条同相位」
/// —— 那样它看起来只是整体一起呼吸，不像等化器，而截图和肉眼都很难发现
/// （「一直是这样的吧」）。相位差写死在 [barPhaseStep] 里，测试钉住它。
///
/// 返回值恒在 `[minScale, 1.0]` 内：出现 0 或负数会让 `Container` 的高度
/// 变成负值 → 渲染期抛异常。
List<double> nowPlayingBarScales(double t) {
  const barCount = 3;
  final phase = t * 2 * math.pi;
  return <double>[
    for (var i = 0; i < barCount; i++)
      minScale + (1 - minScale) * (0.5 + 0.5 * math.sin(phase + i * barPhaseStep)),
  ];
}

/// 相邻两根竖条的相位差（弧度）。取一个**非整数倍 π** 的值，让三根条的
/// 波峰错开 —— 取 π 的话第 1 根与第 3 根会完全同步（`2π` 的整数倍关系），
/// 看起来就像两根条。
const double barPhaseStep = 2.1;

/// 竖条最矮时的高度比例。**不能是 0**：见 [nowPlayingBarScales]。
const double minScale = 0.30;
