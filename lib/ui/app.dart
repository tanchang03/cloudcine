import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'widgets/app_logo.dart';

/// 应用根组件。
class CloudCineApp extends ConsumerWidget {
  const CloudCineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: AppLogo.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      // 本应用**锁定深色**：媒体库的主体是海报墙与视频画面，
      // 浅色底会把画面衬得发灰，也会吃掉海报的暗部细节。
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(routerProvider),
      // 背景光晕挂在 builder 上（即 **Navigator 之上**），才能真正铺在
      // 所有路由之下 —— 挂在某个页面里就只在那一个页面生效，
      // 页面切换时背景会「跳」一下。
      builder: (context, child) => DesignBackground(
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}
