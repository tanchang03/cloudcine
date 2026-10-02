import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/tv_affordance.dart';

/// 一级导航的侧栏外壳。
///
/// 用 `StatefulShellRoute` 而不是普通 `ShellRoute`：三个一级入口
/// （媒体库 / 扫描 / 设置）各自要**保住自己的状态** —— 切到设置再切回
/// 媒体库时，海报墙的滚动位置与搜索词不该被重置。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // TV 上先把过扫描区域让出来，否则真机会把最外圈的内容切掉
      // （侧栏最左边那列字首当其冲）。
      // 非 TV 上 `safeAreaInsets` 返回 `EdgeInsets.zero`，桌面与手机完全不受影响。
      body: Padding(
        padding: AppTheme.safeAreaInsets(context),
        child: Row(
          children: [
            _Sidebar(shell: shell),
            const VerticalDivider(
              width: 0.5,
              thickness: 0.5,
              color: AppTheme.line,
            ),
            Expanded(child: shell),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.shell});

  final StatefulNavigationShell shell;

  static const List<({IconData icon, String label, String path})> _items = [
    (icon: Icons.grid_view_rounded, label: '媒体库', path: '/library'),
    (icon: Icons.radar_rounded, label: '扫描', path: '/scan'),
    (icon: Icons.settings_rounded, label: '设置', path: '/settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;

    return SizedBox(
      width: AppTheme.sidebarWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: AppLogo(showWordmark: true),
          ),
          const Divider(height: 0.5, color: AppTheme.line),
          const SizedBox(height: 8),
          for (var i = 0; i < _items.length; i++)
            _NavTile(
              icon: _items[i].icon,
              label: _items[i].label,
              selected: shell.currentIndex == i,
              onTap: () => shell.goBranch(
                i,
                // 点已选中的项 = 「回到这个入口的根」，与大多数桌面应用一致。
                initialLocation: i == shell.currentIndex,
              ),
            ),
          const Spacer(),
          const Divider(height: 0.5, color: AppTheme.line),
          _AccountBlock(
            name: auth?.account?.label ?? '未登录',
            detail: auth?.account?.memberLabel,
            degraded: auth != null && !auth.canPersist,
            busy: auth?.busy ?? false,
            onSignOut: () =>
                ref.read(authControllerProvider.notifier).signOut(),
          ),
          _NavTile(
            icon: Icons.receipt_long_rounded,
            label: '诊断日志',
            selected: false,
            onTap: () => context.push('/diagnostics'),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.text : AppTheme.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? AppTheme.panel2 : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppTheme.panel2.withValues(alpha: 0.6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(icon, size: 17, color: color),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountBlock extends StatelessWidget {
  const _AccountBlock({
    required this.name,
    required this.detail,
    required this.degraded,
    required this.busy,
    required this.onSignOut,
  });

  final String name;
  final String? detail;
  final bool degraded;
  final bool busy;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  degraded ? '凭证仅本次有效' : (detail ?? '夸克网盘'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: degraded ? AppTheme.warn : AppTheme.dim,
                  ),
                ),
              ],
            ),
          ),
          // 侧栏底部那个 ⤴ 是纯图标 —— TV 上补「退出登录」，
          // 否则它看起来和「关掉窗口」没什么区别。
          TvIconLabel(
            label: '退出登录',
            enabled: !busy,
            child: IconButton(
              onPressed: busy ? null : onSignOut,
              iconSize: 15,
              tooltip: '退出登录',
              icon: const Icon(Icons.logout_rounded),
            ),
          ),
        ],
      ),
    );
  }
}
