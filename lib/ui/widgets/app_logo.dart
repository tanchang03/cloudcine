import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 应用标识：渐变方块 + 播放三角。
///
/// 纯绘制，不带图片资源 —— 这样在 splash / 侧栏 / 关于页三处复用同一份
/// 视觉，且不受打包资源配置影响。
class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.size = 28,
    this.showWordmark = false,
  });

  final double size;

  /// 是否在右侧显示应用名。
  final bool showWordmark;

  static const String appName = '云影';

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        Icons.play_arrow_rounded,
        size: size * 0.62,
        color: Colors.white,
      ),
    );

    if (!showWordmark) return mark;

    return Row(
      children: [
        mark,
        const SizedBox(width: 10),
        const Text(
          appName,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: AppTheme.text,
          ),
        ),
      ],
    );
  }
}
