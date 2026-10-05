import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';

/// 启动页。
///
/// 存在的唯一理由是**等授权状态解析完**。授权恢复要读安全存储 + 打一次
/// `account/info` 校验，是个真实的网络往返；这段时间里必须有个东西占位，
/// 否则会先闪一下授权页再跳走。
class SplashPage extends ConsumerWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      // ⚠️ 必须用 `AppTheme.bg` 而不是 `Colors.transparent`：透明底色在
      // Android TV 上会导致首帧渲染为白色（系统给透明 Surface 的默认清屏色
      // 是白色），用户看到的是 2-4 秒白屏再切到深色 Splash。用深色底立刻
      // 覆盖，视觉上等同于「无白屏」。
      backgroundColor: AppTheme.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLogo(size: 56),
            const SizedBox(height: 18),
            const Text(
              AppLogo.appName,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '网盘媒体库播放器',
              style: TextStyle(fontSize: 12, color: AppTheme.dim),
            ),
            const SizedBox(height: 32),
            if (auth.hasError) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  '${auth.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.7,
                    color: AppTheme.danger,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: () => ref.invalidate(authControllerProvider),
                child: const Text('重试'),
              ),
            ] else
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}
