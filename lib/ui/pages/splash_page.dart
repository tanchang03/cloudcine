import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';

/// 启动页。
///
/// 存在的唯一理由是**等授权状态解析完**。授权恢复要读钥匙串 + 打一次
/// `account/info` 校验，是个真实的网络往返；这段时间里必须有个东西占位，
/// 否则会先闪一下授权页再跳走。
class SplashPage extends ConsumerWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
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
