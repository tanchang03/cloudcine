import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/app_providers.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'widgets/app_logo.dart';
import 'widgets/window_top_inset.dart';
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

    // 把设置里的中继开关推给中继实例。与上面同一个理由：副作用 Provider
    // 必须有人 watch 才会执行。而且这里**必须**是 watch 而不是 read ——
    // read 只跑一次，用户之后在设置页改开关就不会生效。
    ref.watch(relayConfigSyncProvider);

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
      //
      // `WindowChrome` 在背景光晕**之上**、Navigator 之下加一条顶部留白
      // （macOS），给红黄绿三个原生按钮让位 —— 系统标题栏已被
      // `MainFlutterWindow.swift` 的 `applyVirtualTitleBar()` 抹成透明。
      builder: (context, child) => DesignBackground(
        child: WindowChrome(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}

/// 窗口外壳：顶部留白 + 路由内容。
///
/// 挂在 `MaterialApp.builder` 上，也就是 **Navigator 之上** ——
/// 这样顶部留白不跟着路由转场一起滑动/缩放。
///
/// 这里只有一条 [WindowTopInset]，不再有标题栏：系统标题栏已抹掉，
/// 而自绘一条横条只会让人以为「标题栏没去掉」。应用名由侧栏的
/// Logo 承担，所以也不需要监听路由变化。
///
/// ⚠️ **这条只在 macOS 上出现**：macOS 侧把系统标题栏抹成了透明
/// （`macos/Runner/MainFlutterWindow.swift`），窗口内容铺到最顶端、
/// 红黄绿三个原生按钮浮在内容之上，所以要让出一条给它们 ——
/// 那一条**什么都不画**（`WindowTopInset`）。
///
/// Windows / Linux 还留着系统原生标题栏，内容本来就顶在它之下，
/// 再插一条 32pt 只会多出一截死白。
class WindowChrome extends StatelessWidget {
  const WindowChrome({super.key, required this.child});

  final Widget child;

  /// 这个平台需不需要顶部那条 [AppTheme.titleBarHeight]。
  ///
  /// 刻意收成一个**纯函数**（平台当参数传进来），而不是直接在 build 里读
  /// `Platform.isMacOS`：那样只能测出「跑测试的这台机器」的结果 ——
  /// 在 macOS 上跑，其它平台那条分支永远测不到。
  ///
  /// 也不读 `dart:io` 的 `Platform`，而是读 [defaultTargetPlatform]：
  /// 后者能被 `debugDefaultTargetPlatformOverride` 拨动，widget 测试里
  /// 可以把整个外壳按别的平台渲染一遍。
  static bool needsTopInset(TargetPlatform platform) =>
      platform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    if (!needsTopInset(defaultTargetPlatform)) {
      return child;
    }
    return Column(
      children: [
        const WindowTopInset(),
        Expanded(child: child),
      ],
    );
  }
}
