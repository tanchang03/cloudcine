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
/// 二维码由网盘自己签发，用户在手机 App 里确认，我们只拿到一张
/// 一次性回执去换账号 Cookie。
///
/// ## 为什么这里要列网盘
///
/// 应用是**多家并存**模型：每家网盘各有一份会话，媒体库把两家的条目混在
/// 一个库里（主键 `provider:fileId`）。所以这一页的语义是**「添加一家网盘」**，
/// 不是「选一家替换掉原来的」。
///
/// ⛔ 已经连上的那家**照样要显示**，只是按钮变成「已连接 · 重新登录」——
///    隐藏它会让人以为「连不上」，而真实原因可能只是百度会话过期需要重扫。
///
/// 名单来自 [selectableDrivesProvider] —— 判据是「该适配器声明了支持扫码」，
/// 不在这里写枚举名，新增一家网盘不必改这个文件。
class AuthPage extends ConsumerWidget {
  const AuthPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final drives = ref.watch(selectableDrivesProvider);

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
                  '把网盘变成你的私人影院',
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
                      const _Bullet(
                        icon: Icons.qr_code_2_rounded,
                        title: '扫码登录',
                        body: '用手机 App 扫一下即可。全程不接触你的账号密码，'
                            '凭证只存在本机的安全存储里，不会上传。',
                      ),
                      const SizedBox(height: 14),
                      const _Bullet(
                        icon: Icons.travel_explore_rounded,
                        title: '全盘扫描 + 刮削',
                        body: '扫出网盘里的全部视频，按片名/年份/季集自动归组，'
                            '并识别分辨率、编码、字幕。',
                      ),
                      const SizedBox(height: 14),
                      const _Bullet(
                        icon: Icons.play_circle_outline_rounded,
                        title: '原画播放',
                        body: 'MKV / AVI / TS / RMVB 都能播；支持清晰度切换、'
                            '内嵌与外挂字幕（含 GBK 中文乱码修正）。',
                      ),
                      const SizedBox(height: 22),
                      for (final provider in drives) ...[
                        _DriveButton(
                          provider: provider,
                          connected: auth?.accounts.containsKey(provider) ??
                              false,
                          accountLabel: auth?.accountFor(provider)?.label,
                          busy: auth?.busy ?? false,
                          onPressed: () =>
                              context.push('/auth/qr?drive=${provider.id}'),
                        ),
                        // ⛔ 错误**按网盘**显示：百度扫码失败不该让夸克的
                        //    卡片也挂一条「授权失败」。
                        if (auth?.errorFor(provider) case final e?) ...[
                          const SizedBox(height: 6),
                          Text(
                            e,
                            style: const TextStyle(
                              fontSize: 11.5,
                              height: 1.7,
                              color: AppTheme.danger,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                      ],
                      if (drives.isEmpty)
                        const Text(
                          '没有可用的网盘适配器 —— 这通常意味着组合根'
                          '（app_providers.dart）漏注册了。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.7,
                            color: AppTheme.danger,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '夸克走 PC 端自用接口，百度走 Web 自用接口（当前只读：'
                  '能扫能播，暂不支持上传/移动/删除）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: AppTheme.dim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一家网盘的登录按钮。
///
/// 已连接时按钮**不消失**，而是变成「已连接 · 重新登录」——
/// 登录是**追加**语义（不会顶掉其它网盘），所以重新扫一次是安全的。
class _DriveButton extends StatelessWidget {
  const _DriveButton({
    required this.provider,
    required this.connected,
    required this.busy,
    required this.onPressed,
    this.accountLabel,
  });

  final DriveProvider provider;
  final bool connected;
  final bool busy;
  final VoidCallback onPressed;
  final String? accountLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : onPressed,
          style: FilledButton.styleFrom(
            // 已连接时用次要配色：主色留给「还没连的那家」，
            // 让「接下来该点哪个」一眼可辨。
            backgroundColor:
                connected ? AppTheme.panel2 : AppTheme.accent,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: connected
                  ? const BorderSide(color: AppTheme.line)
                  : BorderSide.none,
            ),
          ),
          icon: Icon(
            connected
                ? Icons.check_circle_outline_rounded
                : Icons.qr_code_scanner_rounded,
            size: 18,
          ),
          label: Text(
            connected
                ? '${provider.shortName}已连接 · 重新登录'
                : '用${provider.shortName} App 扫码登录',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (connected && accountLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              accountLabel!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.muted),
            ),
          ),
      ],
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
