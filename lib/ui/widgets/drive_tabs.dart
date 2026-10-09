import 'package:flutter/material.dart';

import '../../domain/entities/drive_provider.dart';
import '../theme/app_theme.dart';

/// 一排「在看哪家网盘」的标签。
///
/// ## 为什么必须**看得见**
///
/// 多家网盘**同时在线**是常态，而「目录树」和「扫描」一次只能服务一家。
/// 没有这个控件的话，用户连着两家却只看到其中一棵树，而且无从知道另一棵
/// 在哪 —— 那正是「没看到百度入口」的观感。
///
/// ⛔ 它是**视图选择**，不是账号切换：点它不会让任何一家掉线，两边的会话
///    都还在（对比侧栏的账号行，那边才是连 / 断）。
///
/// ## 只有一家时不显示
///
/// 一家的时候它就是一行没用的装饰 —— 而且会让人以为「好像还有别的网盘没
/// 连上」。所以 [drives] 少于 2 个时返回空盒子（`SizedBox.shrink()`），
/// **不是**隐藏成 0 高度的占位。
class DriveTabs extends StatelessWidget {
  const DriveTabs({
    super.key,
    required this.drives,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
    this.label = '网盘',
  });

  /// 候选（**已连接**的那几家，未登录的不该出现在这里）。
  final List<DriveProvider> drives;

  final DriveProvider selected;

  final ValueChanged<DriveProvider> onChanged;

  /// 忙的时候（正在扫描）锁住：扫到一半换网盘会让进度条指代不清。
  final bool enabled;

  /// 前缀文案。`扫描` / `浏览` 各用各的，避免用户以为这一排是全局的。
  final String label;

  @override
  Widget build(BuildContext context) {
    if (drives.length < 2) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
        ),
        const SizedBox(width: 10),
        for (var i = 0; i < drives.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          _Tab(
            provider: drives[i],
            selected: drives[i] == selected,
            enabled: enabled,
            onTap: () => onChanged(drives[i]),
          ),
        ],
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.provider,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final DriveProvider provider;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? AppTheme.accent : AppTheme.panel2;
    final fg = selected ? Colors.white : AppTheme.muted;

    return Material(
      color: bg.withValues(alpha: enabled ? 1 : 0.45),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Text(
            provider.displayName,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: fg.withValues(alpha: enabled ? 1 : 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
