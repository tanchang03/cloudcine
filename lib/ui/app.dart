import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'widgets/app_logo.dart';
import 'windows/player_bridge_host.dart';

/// 应用根组件。
class CloudCineApp extends ConsumerWidget {
  const CloudCineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 装上「播放窗口 → 主窗口」的两个回调：进度落库 + 刷新过期直链。
    //
    // 只能装在这里：独立播放窗口的回报是打到**跨引擎通道**上的，
    // 而通道的处理器在 `main()` 里就注册好了（那时还没有 Riverpod 容器），
    // 拿不到仓储与适配器。`watch` 这个 Provider 就是「容器起来后把回调补上」
    // 这一步。
    //
    // 它不产出值，watch 的目的只是建立生命周期绑定 —— 容器销毁时 Provider
    // 会 `onDispose` 把回调摘掉，免得闭包留着一个失效的 `ref`。
    ref.watch(playerBridgeHostProvider);

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
