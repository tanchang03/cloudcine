import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// TV 焦点指示器 —— 套在「遥控器能选中」的东西外面。
///
/// ## 为什么不能只靠主题里的 `focusColor`
///
/// `InkWell` 的焦点高亮属于 **ink 特性**，由最近的 `Material` 的
/// `_RenderInkFeatures` 绘制，而它的 `paint` 是**先画 ink、再 `super.paint`
/// 画子节点**。海报卡片的内容就是一整张图 —— 于是高亮被图整个盖住，
/// 把 `focusColor` 调多亮都看不见。
/// 实测依据：`_WorkCard` 是全项目唯一一个没给自己包 `Material` 的卡片点击区，
/// 它的 ink 落到 `Scaffold` 那一层，高亮只可能从卡片下半部透明底的文字区露出来。
///
/// 这里改成在**子节点之上**再叠一圈描边（外加轻微放大）：
/// 无论卡片里放的是海报、视频帧还是一段文字，焦点环一定在最上面。
///
/// ## 为什么用 `Focus(canRequestFocus: false)` 自己判，而不是
/// `FocusableActionDetector.onShowFocusHighlight`
///
/// `FocusableActionDetector` 在 `enabled: false` 时把「要不要显示高亮」
/// 交给 `MediaQuery.navigationMode` 决定（`actions.dart` 里
/// `canRequestFocus(target) => traditional || null => target.enabled`）。
/// 而 Android TV 上 `navigationMode` 到底报 `traditional` 还是 `directional`，
/// **只能真机验**。把焦点可见性押在一个没验证过的平台取值上，代价太大。
///
/// 换成只看 `FocusManager.instance.highlightMode`，它是确定的：
///   * Android 默认是 `touch`；**收到第一个按键事件就翻成 `traditional`**；
///   * 桌面默认就是 `traditional`；点过屏幕后翻成 `touch`。
/// 所以 TV 上「一按遥控器就出现焦点环、点一下屏幕就消失」是必然的，
/// 桌面上也不会在鼠标点过的卡片上留一圈环。
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.borderRadius,
    this.focusScale = 1.0,
    this.color,
    this.width = 2,
    this.glow = true,
  });

  final Widget child;

  /// 焦点环的圆角，应与子节点自己的圆角一致（对不上会看出来是两圈）。
  final BorderRadius? borderRadius;

  /// 获得焦点时放大的倍数。**1.0 = 不放大**（默认）。
  ///
  /// 放大是官方 TV 规范里的焦点指示之一，但它会向外溢出格子。
  /// 溢出量 = 该方向尺寸 × (scale - 1) / 2，用之前先确认父级间距够大。
  /// 海报墙实测：卡片约 133×199、间距 14/18，1.05 时每边只溢出 3.3 / 5 px，安全。
  final double focusScale;

  /// 焦点环颜色。默认用强调色。
  final Color? color;

  /// 焦点环线宽。2 是「3 米外还看得见」的下限。
  final double width;

  /// 是否加一圈辉光。海报墙画面杂乱，辉光能让焦点更快被找到。
  final bool glow;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    super.dispose();
  }

  void _onHighlightModeChanged(FocusHighlightMode mode) {
    if (mounted) setState(() {});
  }

  /// 焦点环只在「键盘 / 遥控器在操作」时才画。
  bool get _showRing =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppTheme.accent;
    final radius = widget.borderRadius ?? BorderRadius.circular(10);

    return Focus(
      // 只**观察**焦点，不参与竞争：`canRequestFocus: false` 让这一层
      // 不会变成焦点遍历里多出来的一站（否则每张卡片都要多按一次方向键），
      // 而 `onFocusChange` 在该节点**或任意后代**拿到焦点时照样会触发。
      canRequestFocus: false,
      onFocusChange: (value) {
        if (value != _focused) setState(() => _focused = value);
      },
      child: AnimatedScale(
        scale: _showRing ? widget.focusScale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Stack(
          children: [
            widget.child,
            // 描边画在**子节点之后** —— 这一行就是整个组件存在的理由。
            // `IgnorePointer` 保证它不吃掉点击。
            if (_showRing)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(color: color, width: widget.width),
                      boxShadow: widget.glow
                          ? [
                              BoxShadow(
                                color: color.withValues(alpha: 0.45),
                                blurRadius: 12,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
