import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// TV 上用来替代 Material [Slider] 的「可调滑块」。
///
/// **为什么不能直接用 [Slider]**：它的快捷键表把**四个方向键全绑了**
/// （`arrowLeft/Right/Up/Down` → 调整值）。于是在电视上焦点一落到滑块上，
/// 按 ↑/↓ 就被滑块吃掉去改值，**焦点再也走不掉** —— 用户报的第 4 条就是这个。
///
/// **为什么不能在 [Slider] 外面套一层 `Focus.onKeyEvent` 拦 ↑↓**：
/// 按键从**主焦点节点往祖先链**冒泡，而 [Slider] 自己的 `Shortcuts` 就在它的
/// 焦点节点**旁边/上面**，比外层那层 `Focus` **更早**拿到事件 —— 外层永远轮不到。
/// 所以唯一的解法是**别让 [Slider] 拿到焦点**。
///
/// 做法：把 [Slider] 的 `focusNode` 设成一个**不可聚焦**的惰性节点（它只用来
/// 保留 Slider 的原生外观），焦点停在**外层这个 [Focus]** 上。由外层处理
/// ←/→ 调值，↑/↓ 一律 `ignored` —— 交给 Flutter 默认的「方向键 = 方向焦点
/// 遍历」那条快捷方式，焦点自然就走出去了。
///
/// 桌面不走这条路（[Slider] 的鼠标拖拽更自然），只在 TV 分支用。
class TvAdjustSlider extends StatefulWidget {
  const TvAdjustSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;

  /// 步数。`<= 0` 时退化成「全程分 20 步」。
  final int divisions;

  final ValueChanged<double> onChanged;

  @override
  State<TvAdjustSlider> createState() => _TvAdjustSliderState();
}

class _TvAdjustSliderState extends State<TvAdjustSlider> {
  /// ⛔ 必须 `canRequestFocus: false`。它一旦能聚焦，就会把 ↑↓ 吃回去，
  /// 本控件存在的理由（让焦点走得掉）当场失效。
  final FocusNode _inertNode = FocusNode(
    debugLabel: 'tv-slider-inert',
    canRequestFocus: false,
    skipTraversal: true,
  );

  bool _focused = false;

  @override
  void dispose() {
    _inertNode.dispose();
    super.dispose();
  }

  /// 一次 ←/→ 的步长。用 `divisions` 推出来，和 Material Slider 的分档一致。
  double get _step {
    final span = widget.max - widget.min;
    final d = widget.divisions;
    return d <= 0 ? span / 20 : span / d;
  }

  void _nudge(int dir) {
    final next = (widget.value + dir * _step).clamp(widget.min, widget.max);
    if (next != widget.value) widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // ⛔ 子树里的一切都**不能**成为焦点。这是本控件成立的关键，而且**不能**
      // 用「给节点设 `canRequestFocus: false`」代替 —— 实测（见
      // `tv_adjust_slider_test.dart`）：`Slider` 内部的 `FocusableActionDetector`
      // 会用 `Focus` 把节点上的 `canRequestFocus` **覆盖回 true**，设了等于没设。
      // 只有从**结构上**封死，内部的 `Shortcuts` 才永远拿不到按键。
      descendantsAreFocusable: false,
      onFocusChange: (v) {
        if (v != _focused) setState(() => _focused = v);
      },
      onKeyEvent: (node, event) {
        // 只认「按下」与「长按重复」；抬起忽略，否则一次按键会被当成两下。
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _nudge(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _nudge(1);
          return KeyEventResult.handled;
        }
        // ⛔ ↑/↓ **必须** 返回 `ignored` —— 这就是本控件的全部意义。
        // 返回 `handled` 会让焦点重新被困在这里。
        return KeyEventResult.ignored;
      },
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          // 焦点信号只能靠**轨道与滑钮本身的颜色**：第 2 条需求已经明确
          // 不要背景蒙版，所以这里不画任何底衬。
          activeTrackColor:
              _focused ? AppTheme.accent : AppTheme.accent.withValues(alpha: 0.55),
          thumbColor:
              _focused ? AppTheme.accent : AppTheme.accent.withValues(alpha: 0.75),
          overlayShape: SliderComponentShape.noOverlay,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: _focused ? 8.5 : 6.5,
          ),
        ),
        child: Slider(
          focusNode: _inertNode,
          value: widget.value.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}
