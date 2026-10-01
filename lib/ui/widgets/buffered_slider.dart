import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 缓冲层的默认颜色：比「已播」暗、比「未缓冲的底」亮。
///
/// 三层必须**亮度递増**：未缓冲（白 24%）→ 已缓冲（白 40%）→ 已播（强调色）。
/// 反过来或拉不开差距的话，用户没法一眼看出「能拖到哪儿不至于卡」。
const Color kBufferedTrackColor = Color(0x66FFFFFF);

/// 带**缓冲层**的进度条。
///
/// 两层（已播 / 底）是 Flutter 的 `Slider` 本来就有的，多画出来的是中间那层
/// 「已经缓存到这儿了，拖过去不会卡」。网盘播放器必须给它：流是 HTTP 逐段
/// 取的，用户的真实问题不是「播到哪了」而是「我能拖到哪」。
///
/// 两个播放器（内置播放页 + 独立播放窗口）**都用这一个** —— 独立窗口跑在
/// 另一个 Flutter 引擎里，两处各写一遍必然漂移（这个项目已经为「两个播放器
/// 各一份」付出过代价）。
///
/// ## 用法
///
/// [value] 与 [buffered] 都是 **0..1 的比例**，不是毫秒 —— 独立窗口原来按
/// 毫秒传、内置播放页按比例传，统一成比例后两边不可能再算错一次。
/// [buffered] 传 `null` 表示「没有缓冲信息」，此时不画这一层。
///
/// 计算结果见 [PlayerBufferProgress]：**不要**把「已缓存秒数」直接当比例。
class BufferedSlider extends StatelessWidget {
  const BufferedSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.buffered,
    this.onChangeStart,
    this.onChangeEnd,
    this.enabled = true,
    this.trackHeight = 3,
    this.thumbRadius = 6,
    this.overlayRadius = 12,
    this.activeColor,
    this.bufferedColor,
    this.inactiveColor,
    this.thumbColor,
  });

  /// 已播进度（0..1）。
  final double value;

  /// 缓冲进度（0..1）。`null` = 不画缓冲层（时长未知、或还没拿到缓存量）。
  final double? buffered;

  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// 为 false 时滑块不可拖（时长还没解出来的那一段）。
  final bool enabled;

  final double trackHeight;
  final double thumbRadius;
  final double overlayRadius;

  final Color? activeColor;
  final Color? bufferedColor;
  final Color? inactiveColor;
  final Color? thumbColor;

  @override
  Widget build(BuildContext context) {
    final accent = activeColor ?? AppTheme.accent;
    // 用 copyWith 而不是直接 new 一份 SliderThemeData：后者会把主题里那些
    // 没被我们指定的字段（disabled 态的颜色等）留成 null，轨道绘制里对它们
    // 有 assert，一进 disabled 就崩。
    final theme = SliderTheme.of(context).copyWith(
      trackHeight: trackHeight,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
      overlayShape: RoundSliderOverlayShape(overlayRadius: overlayRadius),
      activeTrackColor: accent,
      inactiveTrackColor: inactiveColor ?? const Color(0x3DFFFFFF),
      thumbColor: thumbColor ?? accent,
      trackShape: BufferedTrackShape(
        buffered: buffered,
        color: bufferedColor ?? kBufferedTrackColor,
        radius: trackHeight / 2,
      ),
    );

    return SliderTheme(
      data: theme,
      child: Slider(
        value: value.clamp(0.0, 1.0),
        onChanged: enabled ? onChanged : null,
        onChangeStart: enabled ? onChangeStart : null,
        onChangeEnd: enabled ? onChangeEnd : null,
      ),
    );
  }
}

/// 三层轨道：未缓冲的底 → 已缓冲 → 已播。
///
/// 照着 `RectangularSliderTrackShape` 写的（同样的 `getPreferredRect`、
/// 同样的颜色 tween），只多画一层。圆角是必要的：轨道只有 3 像素高，
/// 方角在缩略状态下看着像一道裂纹。
/// 公开而不是私有的：测试要能断言「缓冲比例真的进了绘制层」。
///
/// 只有这一层才会真的画出缓冲，参数传丢了的话组件照样能建起来、也不报错 ——
/// 表现就是缓冲层悄悄没了，跟「本来就没有」一模一样。
class BufferedTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const BufferedTrackShape({
    required this.buffered,
    required this.color,
    required this.radius,
  });

  /// 缓冲进度（0..1）。`null` = 不画这一层。
  final double? buffered;
  final Color color;
  final double radius;

  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    required TextDirection textDirection,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }

    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final r = Radius.circular(radius);

    final activePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledActiveTrackColor,
        end: sliderTheme.activeTrackColor,
      ).evaluate(enableAnimation)!;
    final inactivePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledInactiveTrackColor,
        end: sliderTheme.inactiveTrackColor,
      ).evaluate(enableAnimation)!;
    final bufferedPaint = Paint()
      // 不可拖时整条轨道都该压暗，缓冲层不能还是亮的 —— 否则「还没准备好」
      // 会显示成「已经缓存好了」。
      ..color = ColorTween(
        begin: color.withValues(alpha: 0.25),
        end: color,
      ).evaluate(enableAnimation)!;

    final ltr = textDirection == TextDirection.ltr;

    // 1) 底：整条。
    context.canvas.drawRRect(
      RRect.fromLTRBR(
        trackRect.left,
        trackRect.top,
        trackRect.right,
        trackRect.bottom,
        r,
      ),
      inactivePaint,
    );

    // 2) 缓冲：从起点到「缓存到的位置」。
    final fraction = buffered;
    if (fraction != null && fraction > 0) {
      final f = fraction.clamp(0.0, 1.0);
      final edge = ltr
          ? trackRect.left + trackRect.width * f
          : trackRect.right - trackRect.width * f;
      context.canvas.drawRRect(
        RRect.fromLTRBR(
          ltr ? trackRect.left : edge,
          trackRect.top,
          ltr ? edge : trackRect.right,
          trackRect.bottom,
          r,
        ),
        bufferedPaint,
      );
    }

    // 3) 已播：从起点到滑块。
    final played = Rect.fromLTRB(
      ltr ? trackRect.left : thumbCenter.dx,
      trackRect.top,
      ltr ? thumbCenter.dx : trackRect.right,
      trackRect.bottom,
    );
    if (!played.isEmpty) {
      context.canvas.drawRRect(
        RRect.fromLTRBR(played.left, played.top, played.right, played.bottom, r),
        activePaint,
      );
    }
  }
}
