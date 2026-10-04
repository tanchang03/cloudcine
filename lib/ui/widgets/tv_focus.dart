import 'package:flutter/material.dart';

/// TV 焦点指示器 —— 套在「遥控器能选中」的东西外面。
///
/// ## 它做什么
///
/// 拿到焦点时：**轻微放大**（[focusScale]），外加一层**中性提亮**（[brighten]，
/// 可选）。就这些 —— 不画边框、不加辉光、**也不用带颜色的蒙版**。
///
/// ## 为什么连「强调色蒙版」也不要了（这一版改掉的东西）
///
/// 上一版把 2px 描边换成了「一层强调色罩」（`accent @ 0.18`）。真机反馈是
/// **「不需要背景蒙版色凸显，看起来有点多余，也不太美观」**。
/// 问题出在**颜色**：一层蓝紫罩子把内容染了色，看着像「选中」而不是「焦点」；
/// 一屏几十张卡片各染一层，整体观感发脏。
///
/// 现在只用 TV 官方规范里那两条**中性**信号：
///   * **放大** —— 不动任何颜色，靠几何位移指示焦点；
///   * **提亮** —— 中性白，只抬亮度、不染色。
///
/// ## 为什么大多数地方连提亮都不需要
///
/// 侧栏项 / chip / 排序按钮 / 列表行 / 选集格子**自己有 `Material`**，
/// `InkWell` 的焦点高亮（主题的 `focusColor`，现在也是中性白）本来就画得出来。
/// 真正需要这层兜底的只有**海报卡片**：它的 ink 落到 `Scaffold` 那一层，
/// 被整张海报盖住（理由见下面那段）。
///
/// ⚠️ 兜底那层必须画在子节点**之后**。这一行是整个组件存在的理由。
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
/// 所以 TV 上「一按遥控器就出现焦点提示、点一下屏幕就消失」是必然的，
/// 桌面上也不会在鼠标点过的卡片上留一层亮罩。
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.borderRadius,
    this.focusScale = 1.0,
    this.brighten = 0.0,
  });

  final Widget child;

  /// 焦点提示的圆角，应与子节点自己的圆角一致（对不上会看出来是两层）。
  final BorderRadius? borderRadius;

  /// 获得焦点时放大的倍数。**1.0 = 不放大**（默认）。
  ///
  /// 放大是官方 TV 规范里的焦点指示之一，也是这一版**主力**信号（不染色）。
  /// 它会向外溢出格子，溢出量 = 该方向尺寸 × (scale - 1) / 2，
  /// 用之前先确认父级间距够大。
  /// 海报墙实测：卡片约 133×199、间距 14/18，1.05 时每边只溢出 3.3 / 5 px，安全。
  final double focusScale;

  /// 焦点时叠一层**中性白**提亮的强度（0 = 不叠）。
  ///
  /// ⚠️ 只有「ink 高亮被内容盖住」的地方才需要它（目前是海报卡片）。
  /// 别为了「更明显」到处加 —— 它叠在 ink 高亮之上，两者会相加；
  /// 0.10 左右已经是「看得见但不刺眼」的量。
  final double brighten;

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

  /// 焦点罩只在「键盘 / 遥控器在操作」时才画。
  bool get _showHighlight =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  Widget build(BuildContext context) {
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
        scale: _showHighlight ? widget.focusScale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Stack(
          children: [
            widget.child,
            // 提亮层画在**子节点之后** —— 这一行就是整个组件存在的理由。
            // `IgnorePointer` 保证它不吃掉点击。
            //
            // ⚠️ 只有 [brighten] > 0 才叠。绝大多数调用点（侧栏项 / chip /
            // 排序按钮 / 列表行 / 选集格子）自己有 ink 高亮，不需要这层；
            // 海报卡片那类 ink 被内容盖住的才靠它兜底。
            if (_showHighlight && widget.brighten > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      // 中性白 —— **不带强调色**。带颜色的罩子会把内容整体染色，
                      // 正是用户说的「背景蒙版色凸显…有点多余，也不太美观」。
                      color: Colors.white.withValues(alpha: widget.brighten),
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
