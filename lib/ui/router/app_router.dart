import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/media_item.dart';
import '../pages/auth_page.dart';
import '../pages/auth_qr_login_page.dart';
import '../pages/diagnostics_page.dart';
import '../pages/downloads_page.dart';
import '../pages/folder_page.dart';
import '../pages/library_page.dart';
import '../pages/player_page.dart';
import '../pages/scan_page.dart';
import '../pages/settings_page.dart';
import '../pages/splash_page.dart';
import '../pages/work_detail_page.dart';
import '../providers/auth_providers.dart';
import '../shell/app_shell.dart';

/// 把 Riverpod 的状态变化桥接给 go_router 的 `refreshListenable`。
///
/// go_router 的 `redirect` 只在「路由变化」或「refreshListenable 触发」时求值。
/// 授权状态是**异步**解析出来的，不主动通知它重算的话，登录成功后页面
/// 不会跳走 —— 用户会盯着一个已经成功的二维码页发呆。
class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen(authControllerProvider, (_, __) => refresh.ping());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authControllerProvider);
      final location = state.matchedLocation;

      // 授权状态还没解析出来时停在启动页，否则会「先闪一下授权页、
      // 再跳回媒体库」—— 那一下闪烁会让用户以为登录态丢了。
      if (auth.isLoading) return location == '/splash' ? null : '/splash';

      final authorized = auth.valueOrNull?.isAuthorized ?? false;
      if (location == '/splash') return authorized ? '/library' : '/auth';

      // 多家并存模型：授权页是「添加 / 重登一家网盘」的入口，**即使已经**
      // **登录了别的网盘也必须可达**——否则已连夸克的用户永远点不进百度
      // 的扫码页（表现就是「点了没反应 / 页面不切换」）。所以已授权时**不再**
      // 把 `/auth*` 踢回 `/library`；登录成功后的跳转交给 [AuthQrLoginPage]
      // 自己 `context.go('/library')` 完成。
      final atAuth = location.startsWith('/auth');
      if (!authorized && !atAuth) return '/auth';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashPage()),
      GoRoute(
        path: '/auth',
        builder: (_, __) => const AuthPage(),
        routes: [
          GoRoute(
            path: 'qr',
            builder: (_, state) => AuthQrLoginPage(
              // 走 query 而不是 path 段：`/auth/qr/quark` 与 `/auth/qr` 是
              // 两条不同的路由，多一层就多一个「返回时落到哪」的问题。
              //
              // ⚠️ 解析不出来时退回夸克 —— 历史默认值（这个键出现之前
              //    唯一的选择就是夸克）。
              provider: DriveProvider.fromId(
                    state.uri.queryParameters['drive'] ?? '',
                  ) ??
                  DriveProvider.quark,
            ),
          ),
        ],
      ),

      // 作品详情与播放页都是**全屏 push 页**：它们是从列表点进去的一层，
      // 返回键回到原来的列表。不进侧栏分支 —— 侧栏那三项是一级入口，
      // 「某部片子」不是。
      //
      // 参数走 query 而不是 path 段：作品键是**归组键**，本身可能带
      // `/` 或 `|`，塞进路径段要么被当成层级、要么得整段转义。
      GoRoute(
        path: '/work',
        builder: (_, state) =>
            WorkDetailPage(workKey: state.uri.queryParameters['key'] ?? ''),
      ),
      GoRoute(
        path: '/play',
        builder: (_, state) => PlayerPage(
          itemId: state.uri.queryParameters['item'] ?? '',
          qualityId: state.uri.queryParameters['quality'],
          // 直接播（未入库）时条目对象随导航带过来。安全 cast：`extra` 是
          // 个 `Object?`，别的调用方塞进别的东西时**退回按 id 查库**，
          // 而不是在这里抛一个类型错误。
          item: state.extra is MediaItem ? state.extra as MediaItem : null,
        ),
      ),

      // 诊断日志同样是全屏页：它是排查工具，不是产品功能的一级入口。
      GoRoute(path: '/diagnostics', builder: (_, __) => const DiagnosticsPage()),

      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(shell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/library', builder: (_, __) => const LibraryPage()),
            ],
          ),
          // 「文件夹」与「媒体库」是**并列**的一级入口，不是一个页面里的两个
          // 视图：前者读网盘实时目录、按位置组织，后者读本地索引、按作品
          // 组织。合成一页时媒体库页头得为它挂上一堆用不着的分支，而用户在
          // 「媒体库」这个名字下面也不会想到网盘目录在那里。
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/folders', builder: (_, __) => const FolderPage()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/scan', builder: (_, __) => const ScanPage()),
            ],
          ),
          // ⚠️ 分支顺序**必须**与 `app_shell.dart` 里 `_items` 的顺序一致：
          // 侧栏那个 `shell.currentIndex == i` 的判据是按**下标**对的，
          // 两处顺序不一致的表现是「点『下载』高亮的是『设置』」——
          // 而页面确实切过去了，所以看起来像高亮坏了。
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/downloads',
                builder: (_, __) => const DownloadsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/settings', builder: (_, __) => const SettingsPage()),
            ],
          ),
        ],
      ),
    ],
  );
});
