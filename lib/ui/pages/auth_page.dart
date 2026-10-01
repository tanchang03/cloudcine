import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/drive_provider.dart';
import '../providers/auth_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';

/// 登录入口页。
///
/// 只提供**扫码**一条链路，因为它是唯一一条不需要用户交出密码的链路：
/// 二维码由 `uop.quark.cn` 签发，用户在夸克 App 里确认，我们只拿到
/// 一张 `service_ticket` 去换账号 Cookie。
class AuthPage extends ConsumerWidget {
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const AppLogo(size: 52),
                const SizedBox(height: 18),
                const Text(
                  AppLogo.appName,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '把夸克网盘变成你的私人影院',
                  style: TextStyle(fontSize: 12.5, color: AppTheme.muted),
                ),
                const SizedBox(height: 34),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.panel,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.line, width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Bullet(
                        icon: Icons.qr_code_2_rounded,
                        title: '扫码登录',
                        body: '用夸克 App 扫一下即可。全程不接触你的账号密码，'
                            '凭证只存在本机的安全存储里，不会上传。',
                      ),
                      const SizedBox(height: 14),
                      _Bullet(
                        icon: Icons.travel_explore_rounded,
                        title: '全盘扫描 + 刮削',
                        body: '扫出网盘里的全部视频，按片名/年份/季集自动归组，'
                            '并识别分辨率、编码、字幕。',
                      ),
                      const SizedBox(height: 14),
                      _Bullet(
                        icon: Icons.play_circle_outline_rounded,
                        title: '原画播放',
                        body: 'MKV / AVI / TS / RMVB 都能播；支持清晰度切换、'
                            '内嵌与外挂字幕（含 GBK 中文乱码修正）。',
                      ),
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: auth?.busy ?? false
                            ? null
                            : () => context.push('/auth/qr'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                        label: const Text(
                          '用夸克 App 扫码登录',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                if (auth?.error != null)
                  Text(
                    auth!.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      color: AppTheme.danger,
                    ),
                  ),
                const SizedBox(height: 10),
                Text(
                  '当前对接：${DriveProvider.quark.displayName}'
                  '（走 PC 端自用接口）',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: AppTheme.dim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: AppTheme.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.7,
                  color: AppTheme.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
