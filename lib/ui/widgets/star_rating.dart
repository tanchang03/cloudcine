import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 半星评分条。
///
/// ## 值域
///
/// 评分在「存储层」是 `1..10` 的整数（= 0.5~5 星 × 2，见 [DiaryEntry.rating]）；
/// 这里对外也是这个整数，**`null` 表示未评分**。
///
/// ## 三端交互（设计文档 §8.4）
///
/// - 鼠标 / 触控：星条分 10 段（每段 0.5 分），悬停实时预览、点击落值；
///   点**当前分值**可清除（回到未评分）。
/// - 键盘：←/→ 每次 ±0.5，数字键 1–9 直接给分（×2 得存储值），Enter 提交。
/// - 遥控器：焦点进入星条后用 ←/→ 调星（系统键重复即可长按加速），
///   Enter 提交。不要求用户连按 9 次。
///
/// ## 保存策略
///
/// **改动即存** —— 每次 [onChanged] 都立即回调，由上层（[diaryNotifierProvider]）
/// 落盘 + 防抖同步。**不内置「保存」按钮**：评分是低风险操作，一个显式按钮
/// 只会让人担心「我改的存上了吗」。
class StarRating extends StatefulWidget {
  const StarRating({
    super.key,
    required this.rating,
    required this.onChanged,
    this.size = 28,
    this.showLabel = true,
  });

  /// 当前评分（1..10），`null` = 未评分。
  final int? rating;

  /// 评分为 `null` 表示「清除评分」。
  final ValueChanged<int?> onChanged;

  /// 单颗星的边长。
  final double size;

  /// 右侧显示「9.0 / 待评分」文字。
  final bool showLabel;

  @override
  State<StarRating> createState() => _StarRatingState();
}

class _StarRatingState extends State<StarRating> {
  /// 悬停/拖拽时的预览值（星，0..5），`null` 表示不预览。
  double? _hoverStars;

  double get _currentStars =>
      _hoverStars ?? (widget.rating == null ? 0 : widget.rating! / 2);

  /// 把星条内的水平位置（0..1）映射成 0.5 步进的评分值（1..10）。
  int? _valueFromFraction(double fraction) {
    final stars = (fraction.clamp(0, 1) * 5).clamp(0, 5);
    final half = (stars * 2).round() / 2; // 0..5，步进 0.5
    if (half <= 0) return null; // 点了最左 → 未评分
    return (half * 2).round(); // 1..10
  }

  void _commit(int? value) {
    // 点当前分值 → 清除。
    if (value != null && value == widget.rating) value = null;
    if (value == widget.rating) return;
    widget.onChanged(value);
  }

  void _bump(double delta) {
    final base = widget.rating == null ? 0 : widget.rating! / 2;
    final next = (base + delta).clamp(0.5, 5.0);
    final v = (next * 2).round();
    _commit(v);
  }

  @override
  Widget build(BuildContext context) {
    final stars = _currentStars;
    final label = widget.rating == null
        ? '待评分'
        : (widget.rating! / 2).toStringAsFixed(1);

    final starRow = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          children: [
            // 背景：空星
            _starRow(stars: 0, color: const Color(0xFF3A4256)),
            // 前景：金星，按当前值宽度裁切
            ClipRect(
              clipper: _WidthClipper(width * (stars / 5)),
              child: _starRow(stars: 5, color: const Color(0xFFFFB454)),
            ),
            // 命中层：10 段，悬停/点击/拖拽
            Positioned.fill(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (e) {
                  final f = e.localPosition.dx / math.max(1, width);
                  setState(() => _hoverStars = f * 5);
                },
                onExit: (_) => setState(() => _hoverStars = null),
                child: GestureDetector(
                  onTapDown: (e) {
                    final f = e.localPosition.dx / math.max(1, width);
                    _commit(_valueFromFraction(f));
                  },
                  onHorizontalDragUpdate: (e) {
                    final f = e.localPosition.dx / math.max(1, width);
                    setState(() => _hoverStars = f * 5);
                  },
                  onHorizontalDragEnd: (_) {
                    final v = _valueFromFraction(_currentStars / 5);
                    _commit(v);
                    setState(() => _hoverStars = null);
                  },
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ],
        );
      },
    );

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Focus(
          // 键盘 / 遥控器：←/→ 调星，数字键直接给分，Enter 提交（即存）。
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.arrowLeft) {
                _bump(-0.5);
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowRight) {
                _bump(0.5);
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.select) {
                _commit(widget.rating);
                return KeyEventResult.handled;
              }
              final n = _digitFromKey(key);
              if (n != null && n >= 1 && n <= 9) {
                _commit(n * 2);
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: SizedBox(
            width: widget.size * 5,
            height: widget.size,
            child: starRow,
          ),
        ),
        if (widget.showLabel) ...[
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: widget.rating == null
                  ? const Color(0xFF8B95AC)
                  : const Color(0xFFE9EDF6),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );

    return row;
  }

  Widget _starRow({required double stars, required Color color}) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: List.generate(5, (i) {
        final filled = i < stars.floor();
        final half = !filled && (i == stars.floor()) && (stars - i) >= 0.5;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Icon(
            filled
                ? Icons.star_rounded
                : (half ? Icons.star_half_rounded : Icons.star_outline_rounded),
            size: widget.size,
            color: color,
          ),
        );
      }),
    );
  }
}

class _WidthClipper extends CustomClipper<Rect> {
  const _WidthClipper(this.width);
  final double width;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, width, size.height);
  @override
  bool shouldReclip(_WidthClipper old) => old.width != width;
}

int? _digitFromKey(LogicalKeyboardKey key) {
  final s = key.keyLabel;
  if (s.length == 1 && s.codeUnitAt(0) >= 0x31 && s.codeUnitAt(0) <= 0x39) {
    return s.codeUnitAt(0) - 0x30;
  }
  return null;
}
