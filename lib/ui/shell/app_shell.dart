import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_providers.dart';
import '../providers/download_providers.dart';
import '../providers/follow_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import '../widgets/tv_affordance.dart';
import '../widgets/tv_focus.dart';

/// 一级导航的侧栏外壳。
///
/// 用 `StatefulShellRoute` 而不是普通 `ShellRoute`：五个一级入口
/// （媒体库 / 文件夹 / 扫描 / 下载 / 设置）各自要**保住自己的状态** —— 切到
/// 设置再切回媒体库时，海报墙的滚动位置与搜索词不该被重置。
///
/// ⚠️ `_Sidebar._items` 的**顺序就是分支下标**（`shell.currentIndex`）。
/// 增删入口时必须同时改 `app_router.dart` 里 `branches` 的顺序 ——
/// 只改一处的表现是「点一个入口，高亮跳到另一个」，而页面确实切对了。
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// 全局返回键双层确认。TV 上任意页面按返回：
  /// 第一次 → 回到媒体库「全部」页（如果当前不是）；
  /// 第二次 → 退出 App。
  int _backTapCount = 0;
  Timer? _backTapTimer;

  /// 「再按一次返回退出」的提示文案。非空时在屏幕顶部显示居中 toast，
  /// 3 秒后由 [_backTapTimer] 清除 —— 与 SnackBar 不同，这是自绘浮层，
  /// TV 上不会出现浮动态 SnackBar 的溢出异常。
  String? _backHint;

  void _onBackTap() {
    if (_backTapCount == 0) {
      // 第一次：回到媒体库全部页（如果当前不在）。
      final currentIndex = widget.shell.currentIndex;
      if (currentIndex != 0) {
        widget.shell.goBranch(0, initialLocation: true);
      }
      _backTapCount = 1;
      _backTapTimer?.cancel();
      // 提示显示 3 秒后连同计数一起清掉 —— 文案要「过一会自动消失」。
      _backTapTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        setState(() {
          _backTapCount = 0;
          _backHint = null;
        });
      });
      setState(() => _backHint = '再按一次返回退出');
    } else {
      // 第二次：真正退出。
      // ⚠️ 用 `SystemNavigator.pop()` 而不是 `Navigator.pop()`：
      // 后者只会退路由（回到上一个页面），前者会请求 Android 系统
      // 销毁整个 Task，等同于「杀进程」。电视上用户期望的是后者。
      _backTapCount = 0;
      _backTapTimer?.cancel();
      _backTapTimer = null;
      setState(() => _backHint = null);
      SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    _backTapTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tv = AppTheme.isTvLayout(context);
    final shell = widget.shell;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 方向键兜底的中转站：自己**不吃焦点、不参与遍历**，只在默认逻辑走不动时
          // 把焦点送到一级导航。为什么需要它见 [_onShellKey]。
          PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              _onBackTap();
            },
            child: Focus(
              canRequestFocus: false,
              onKeyEvent: _onShellKey,
              // TV 上先把过扫描区域让出来，否则真机会把最外圈的内容切掉。
              // 非 TV 上 `safeAreaInsets` 返回 `EdgeInsets.zero`，桌面与手机完全不受影响。
              child: Padding(
                padding: AppTheme.safeAreaInsets(context),
                // TV 走**顶部一级导航**（参考夸克网盘 TV 版媒体库首页）：
                // 左右分栏在 960 宽下吃掉 240 + 过扫描 96，只剩 624 给内容；
                // 顶部导航只吃纵向 ~60，内容区拿到 864 宽。遥控器左右切导航、
                // 上下在导航与内容之间走，与夸克的「顶栏 Tab + 内容区」一致。
                // 桌面仍走左侧栏（鼠标场景下侧栏信息密度更高）。
                child: tv
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _TopBar(key: _navKey, shell: shell),
                          const Divider(height: 0.5, color: AppTheme.line),
                          Expanded(child: shell),
                        ],
                      )
                    : Row(
                        children: [
                          _Sidebar(key: _navKey, shell: shell),
                          const VerticalDivider(
                            width: 0.5,
                            thickness: 0.5,
                            color: AppTheme.line,
                          ),
                          Expanded(child: shell),
                        ],
                      ),
              ),
            ),
          ),
          // 「再按一次返回退出」提示：自绘居中浮层，3 秒后自动消失。
          // 不用 SnackBar —— TV 上浮动态 SnackBar 会溢出显示异常。
          if (_backHint != null)
            Positioned(
              top: 28,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: _BackHintToast(text: _backHint!),
                ),
              ),
            ),
          // 追更检查的**启动触发器**。没有任何视觉（见 `_FollowLaunchCheck`）——
          // 它只是挂一个延迟定时器，所以放在 `Stack` 最上层也不会挡住任何东西。
          const _FollowLaunchCheck(),
        ],
      ),
    );
  }
}

/// App 启动后的**静默追更检查**。
///
/// ## 为什么挂在壳上，而不是媒体库页
///
/// 「启动后检查一次」的语义是**一次会话一次**（见 `FollowAutoCheck.onLaunch`）。
/// 挂在媒体库页上有两个问题：用户这次是从别的分支进来的（深链、或上次退出
/// 时停在设置页）它压根不会跑；而每次切回媒体库页又会重新挂一次定时器 ——
/// 「启动后 20 秒」变成了「每次进媒体库 20 秒后」。
///
/// 壳是这个进程里**唯一**一个「装好之后不再重建」的 widget，与
/// `_AppShellState` 那套「返回键双层确认」共享同一个生命周期口径。
///
/// ## 为什么延迟 20 秒
///
/// 检查要发网盘请求、要写 SQLite。首帧还没出来就跟启动抢 IO 的话，用户看到
/// 的是「开 App 卡一下」—— 而这个功能的价值是「不用自己想起来去查」，
/// 晚 20 秒完全不影响，它抢掉的启动时间用户却立刻能感觉到。
///
/// ## ⛔ 两个定时器都必须在 `dispose` 里取消
///
/// 漏掉的话 widget 测试会在收尾时炸「A Timer is still pending even after the
/// widget tree was disposed」—— 而它看起来像「加了段跟测试无关的代码，
/// 一堆页面测试全红」，排查方向会完全跑偏。
class _FollowLaunchCheck extends ConsumerStatefulWidget {
  const _FollowLaunchCheck();

  @override
  ConsumerState<_FollowLaunchCheck> createState() => _FollowLaunchCheckState();
}

class _FollowLaunchCheckState extends ConsumerState<_FollowLaunchCheck> {
  /// 启动延迟。见类文档「为什么延迟 20 秒」。
  static const Duration _launchDelay = Duration(seconds: 20);

  /// `every_6h` 那一档的周期。
  ///
  /// ⚠️ 与 `FollowAutoCheck.throttleWindow` 的 6 小时**是同一个数**，但
  /// 刻意**不引用它**：定时器比窗口密的话，多出来的那些次会被节流闸挡掉、
  /// 白转一圈（而且每次都要读一次设置 + 判一次 `off`）；比窗口疏则会漏掉
  /// 窗口边界上的那一次。两个数一起改是必须的 —— 所以这里写死并留这条注释，
  /// 而不是让「周期 = 窗口」变成一个隐式巧合。
  static const Duration _timerPeriod = Duration(hours: 6);

  Timer? _launch;
  Timer? _periodic;

  @override
  void initState() {
    super.initState();
    _launch = Timer(_launchDelay, _checkOnce);
  }

  @override
  void dispose() {
    _launch?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  /// 启动那一次。
  ///
  /// ⛔ **不传 `force`**：走节流窗口、也走 `follow_auto_check = off` 的闸门。
  ///    传 `true` 就变成「每次开 App 都真查一遍」，那是 `off` 想避免的事。
  Future<void> _checkOnce() async {
    if (!mounted) return;
    await ref.read(followControllerProvider.notifier).start();
    if (!mounted) return;
    // 跑完再决定要不要挂周期定时器：这一项是用户可改的，而改设置**不会**
    // 重建壳（设置页是壳里的一个分支），所以没有别的地方能挂上它。
    _syncPeriodic();
  }

  void _syncPeriodic() {
    final policy = ref.read(settingsProvider).valueOrNull?.followAutoCheck;
    final want = policy?.runsOnTimer ?? false;

    if (want && _periodic == null) {
      _periodic = Timer.periodic(_timerPeriod, (_) {
        // ⛔ 周期那几次同样走节流闸（不传 `force`）。用户在别处刚手动查过时，
        //    这一次会被挡掉 —— 这是对的，不是漏跑。
        //
        // 会话中途把设置从「每 6 小时」改成别的档位时，这个定时器会继续存在，
        // 但每一次 `start()` 都会被新的策略挡掉（`off` 直接跳过，
        // `on_launch` 被 6 小时窗口挡住）—— 表现正确，只是白转一圈。
        // 为此去 watch 设置、让整个壳跟着重建是不划算的。
        ref.read(followControllerProvider.notifier).start();
      });
    } else if (!want && _periodic != null) {
      _periodic!.cancel();
      _periodic = null;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 一级导航的根 widget —— 方向键兜底要在**它里面**找目标。
///
/// TV 上它是顶栏，桌面上它是侧栏，共用同一个 key（同一时刻只渲染其一）。
///
/// ⛔ 兜底**只能**在导航子树里找，不能在整个窗口里按几何找。理由见
/// [_nearestNavFocus] 里那段：`IndexedStack` 把另外 4 个分支也留在树里，
/// 它们的坐标和当前页**完全重合**，全窗口搜索会把焦点送到一个**看不见**的
/// 同坐标节点上 —— 用户看到的是「焦点凭空消失了」。
final GlobalKey _navKey = GlobalKey(debugLabel: 'cloudcine-nav');

/// 方向键兜底。
///
/// ## 为什么必须有这一层
///
/// `StatefulShellRoute.indexedStack` **给每个分支一个独立 `Navigator`**，于是
/// 每个分支页有自己的 `FocusScope`。而 `FocusTraversalPolicy.inDirection`
/// （`focus_traversal.dart:1070`）只在 `currentNode.nearestScope.traversalDescendants`
/// 里找候选，**找不到就返回 false，不会向上冒泡到父 scope**。
///
/// 一级导航是分支页的**兄弟**（在外层 scope 里），所以从内容区按方向键
/// 永远走不进去 —— 实测：焦点在内容区时那个候选表**只有 1 个节点**（它自己）。
/// 同一方向键在焦点位于导航时就能走通，因为那时最近 scope 换成了外层那个。
/// 桌面上是从内容区按 ← 进侧栏，TV 上是从内容区按 ↑ 进顶栏，根因同一条。
///
/// 这是 `StatefulShellRoute` 的固有结构，不是接线错误：Tab 能跨（`_moveFocus`
/// 会爬 scope 边界），**但真机遥控器没有 Tab**.
///
/// ## 只在「默认逻辑走不动」时出手
///
/// ① 先跑 `focusInDirection` —— 与框架默认的 `_DirectionalFocusAction`
/// **逐字一致**（含「方向反过来时回到上一个位置」那套 `_popPolicyDataIfNeeded`）。
/// 它返回 true 就说明框架自己找到了，直接放行，**内容区内部的方向键行为一点不变**。
/// ② 只有它返回 false（真的没得走）才轮到兜底，而且**只往一级导航送**。
KeyEventResult _onShellKey(FocusNode node, KeyEvent event) {
  final direction = _arrowDirectionOf(event);
  if (direction == null) return KeyEventResult.ignored;

  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || focus.context == null) return KeyEventResult.ignored;

  // ① 框架自己那套。
  if (focus.focusInDirection(direction)) return KeyEventResult.handled;

  // ② 兜底。
  final next = _nearestNavFocus(focus, direction);
  if (next == null) {
    // 真的没得走 —— 交还给默认处理（例如 Ctrl+方向键的滚动），别把按键吞掉。
    return KeyEventResult.ignored;
  }
  next.requestFocus();
  return KeyEventResult.handled;
}

/// 这个按键是不是「往某个方向走」。
///
/// ⛔ 按住 Ctrl 的方向键在框架里是**滚动**（`ScrollIntent`），不是焦点移动 ——
/// 抢过来会让「Ctrl+↑」在列表里翻不动页。
TraversalDirection? _arrowDirectionOf(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  if (HardwareKeyboard.instance.isControlPressed) return null;
  return switch (event.logicalKey) {
    LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
    LogicalKeyboardKey.arrowRight => TraversalDirection.right,
    LogicalKeyboardKey.arrowUp => TraversalDirection.up,
    LogicalKeyboardKey.arrowDown => TraversalDirection.down,
    _ => null,
  };
}

/// 在**一级导航子树**里找 [direction] 方向上离 [from] 最近的那个可聚焦节点。
///
/// 筛选规则照抄框架的 `_sortAndFilterHorizontally` / `_sortAndFilterVertically`
/// （`focus_traversal.dart:906` / `:932`），这样「什么算在那个方向上」的判据与
/// 框架一致，不会出现「框架说没有、我说有」的错位：
///   * 候选必须**整体**在方向上（左：`center.dx <= from.left`）；
///   * 先挑「与 from 在垂直于方向轴上有重叠」的那批（带内），带内为空才放宽；
///   * 带内按方向轴上的间距取最近，同距时按垂直偏移取最近 —— 后者保证结果稳定，
///     不依赖焦点树的遍历顺序。
FocusNode? _nearestNavFocus(FocusNode from, TraversalDirection direction) {
  final root = _navKey.currentContext;
  if (root == null) return null;

  final fromRect = from.rect;
  if (fromRect.isEmpty) return null;

  final candidates = <FocusNode>[];
  for (final candidate in FocusManager.instance.rootScope.descendants) {
    if (!candidate.canRequestFocus || candidate.skipTraversal) continue;
    final context = candidate.context;
    if (context == null) continue;
    if (!_isInside(context, root)) continue;
    final rect = candidate.rect;
    if (rect.isEmpty) continue;

    final onTheWay = switch (direction) {
      TraversalDirection.left => rect.center.dx <= fromRect.left,
      TraversalDirection.right => rect.center.dx >= fromRect.right,
      TraversalDirection.up => rect.center.dy <= fromRect.top,
      TraversalDirection.down => rect.center.dy >= fromRect.bottom,
    };
    if (onTheWay) candidates.add(candidate);
  }
  if (candidates.isEmpty) return null;

  // 带内优先：从海报墙最左边按 ← 时，「高度上和这一排重叠」的那几项才是用户
  // 心里想的那些，而不是侧栏最顶或最底那一项。
  final band = switch (direction) {
    TraversalDirection.left || TraversalDirection.right => Rect.fromLTRB(
        double.negativeInfinity,
        fromRect.top,
        double.infinity,
        fromRect.bottom,
      ),
    TraversalDirection.up || TraversalDirection.down => Rect.fromLTRB(
        fromRect.left,
        double.negativeInfinity,
        fromRect.right,
        double.infinity,
      ),
  };
  final inBand = candidates
      .where((candidate) => !candidate.rect.intersect(band).isEmpty)
      .toList();
  final pool = inBand.isEmpty ? candidates : inBand;

  double alongAxis(FocusNode n) => switch (direction) {
        TraversalDirection.left => fromRect.left - n.rect.right,
        TraversalDirection.right => n.rect.left - fromRect.right,
        TraversalDirection.up => fromRect.top - n.rect.bottom,
        TraversalDirection.down => n.rect.top - fromRect.bottom,
      };
  double acrossAxis(FocusNode n) => switch (direction) {
        TraversalDirection.left ||
        TraversalDirection.right =>
          (n.rect.center.dy - fromRect.center.dy).abs(),
        TraversalDirection.up ||
        TraversalDirection.down =>
          (n.rect.center.dx - fromRect.center.dx).abs(),
      };

  pool.sort((a, b) {
    final byAxis = alongAxis(a).compareTo(alongAxis(b));
    if (byAxis != 0) return byAxis;
    return acrossAxis(a).compareTo(acrossAxis(b));
  });
  return pool.first;
}

/// [node] 是不是 [ancestor] 的后代（含自身）。
bool _isInside(BuildContext node, BuildContext ancestor) {
  if (identical(node, ancestor)) return true;
  var found = false;
  node.visitAncestorElements((element) {
    if (identical(element, ancestor)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// 一级导航入口（顶栏 / 侧栏共用同一份）。
///
/// ⚠️ 「文件夹」紧跟在「媒体库」后面是**刻意的**：两者都是「找片子」的
/// 入口（一个是按作品找、一个是按网盘位置找），挨着放用户才不会来回扫。
/// 顺序就是分支下标（`shell.currentIndex`），改这里必须同步改
/// `app_router.dart` 里 `branches` 的顺序。
const List<({IconData icon, String label, String path})> _navItems = [
  (icon: Icons.grid_view_rounded, label: '媒体库', path: '/library'),
  (icon: Icons.folder_rounded, label: '文件夹', path: '/folders'),
  (icon: Icons.radar_rounded, label: '扫描', path: '/scan'),
  (icon: Icons.download_rounded, label: '下载', path: '/downloads'),
  (icon: Icons.settings_rounded, label: '设置', path: '/settings'),
];

/// 下载那一项在 `_navItems` 里的下标。
///
/// 写成常量而不是字面量 `3`：角标要挂在**特定的那一项**上，而入口顺序
/// 是会被调整的 —— 调了顺序却忘了改这个数字，表现是「扫描那项上挂着一个
/// 下载数」，一个看起来像数据错了的界面 bug。
const int _downloadsIndex = 3;

/// 顶栏那一行账号摘要：**已连接了几家网盘**。
///
/// ⛔ 不要写成某一个账号名。多家同时在线时，显示一个名字会让用户以为
///    「只连了那一家」—— 而连着两家的正是常态。
///
/// 一家时 = 那家的账号名（与以前一致）；两家及以上 = 「已连接 N 家」；
/// 零家 = 「未登录」。
String _accountSummary(AuthState? auth) {
  final accounts = auth?.accounts ?? const {};
  if (accounts.isEmpty) return '未登录';
  if (accounts.length == 1) return accounts.values.first.label;
  return '已连接 ${accounts.length} 家网盘';
}

/// TV 顶部一级导航（参考夸克网盘 TV 版媒体库首页）。
///
/// 布局 = 左 logo + 中间横排 5 个入口 + 右账号/诊断：
///   * 横排 Tab 让 864 宽的内容区完整让出来（左右分栏只剩 624）；
///   * 遥控器 ←→ 在顶栏内走，↑ 从内容区回到顶栏（靠壳里的方向键兜底），
///     ↓ 从顶栏进内容区（默认遍历即通）；
///   * 选中态 = 强调色 pill + 白字（与 OSD 选中 chip 同一种语言），
///     未选中 = 透明底 + muted 字，保证三米外一眼看出在哪。
class _TopBar extends ConsumerWidget {
  const _TopBar({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloading = ref.watch(downloadActiveCountProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;

    return SizedBox(
      height: AppTheme.tvTopBarHeight,
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, right: 12),
            child: AppLogo(showWordmark: false),
          ),
          for (var i = 0; i < _navItems.length; i++)
            _TopNavTab(
              icon: _navItems[i].icon,
              label: _navItems[i].label,
              selected: shell.currentIndex == i,
              badge: i == _downloadsIndex ? downloading : null,
              onTap: () => shell.goBranch(
                i,
                initialLocation: i == shell.currentIndex,
              ),
            ),
          const Spacer(),
          // ⛔ 多家网盘同时在线，所以这里显示的是**已连接了几家**，
          //    不是某一个账号名 —— 写死一个名字会让用户以为只连了那一家。
          Text(
            _accountSummary(auth),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: AppTheme.muted),
          ),
          const SizedBox(width: 8),
          TvIconLabel(
            label: '诊断',
            child: IconButton(
              tooltip: '诊断日志',
              iconSize: 19,
              onPressed: () => context.push('/diagnostics'),
              icon: const Icon(Icons.receipt_long_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopNavTab extends StatelessWidget {
  const _TopNavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final count = badge ?? 0;
    final tab = Material(
      color: selected ? AppTheme.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        hoverColor: AppTheme.panel2.withValues(alpha: 0.6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 19,
                color: selected ? Colors.white : AppTheme.muted,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.tvActionLabel,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? Colors.white : AppTheme.muted,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 7),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: selected ? Colors.white : AppTheme.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: selected ? AppTheme.accent : AppTheme.bg,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // 选中态已有实心 pill，焦点只需轻微放大（与侧栏同一套语言，不再叠色罩）。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: TvFocusable(
        borderRadius: BorderRadius.circular(22),
        focusScale: 1.05,
        child: tab,
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    // 「进行中」的下载数（排队 + 下载中）。**不含已暂停 / 失败** ——
    // 角标的意义是「有东西正在动」，把用户早就放弃的任务也算进去的话，
    // 它会永远挂着，点进去却发现什么都没在下。
    final downloading = ref.watch(downloadActiveCountProvider);

    return SizedBox(
      // 桌面侧栏固定 196（鼠标场景）。TV 走顶栏，不再进这一支；
      // 这里不再按 TV 加宽到 240。
      width: AppTheme.sidebarWidth,
      // ## ⚠️ 这一列的高度是**紧**的，改上面任何一项前先看这段
      //
      // 540 高的电视上可用高只有 540 − 过扫描 54 = **486**，要装下
      // logo + 6 个入口 + 账号块。原来它**溢出 25px**：`诊断日志` 整行掉在
      // 安全带外，而 Release 下溢出是**静默裁掉**的 —— 看起来像「那个入口
      // 本来就没有」，可它还在焦点链里（遥控器按得到、屏幕上看不见）。
      //
      // 现在收紧了 tile 的内外上下内边距（每个 61 → 55），实测余量是
      // **`Spacer` 的 23px**。⚠️ 要量余量就量 `Spacer` 的高度 ——
      // `诊断日志` 是被它顶到底部的，量那个 tile 的 `bottom` 只反映尾部间距，
      // 量不出余量。
      //
      // ⛔ 那个 `Spacer` **不是保险**：它是 flex，可用高不够时被压成 0，
      // 然后溢出照旧发生。加东西之前先确认余量够。
      //
      // ⚠️ 残留的脆弱点：侧栏**没有**套 `AppTheme.tvTextScaler`，字跟着系统
      // 字体缩放走。tile 高度是「图标 22 与文字取大」决定的，所以系统缩放
      // 超过 ~1.4 时 5 个 tile 一起长高、余量被吃光。真遇到，修法是给这一列
      // 夹住 `textScaler`（或把 `Column` 换成可滚动的），**不是**继续抠像素。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: AppLogo(showWordmark: true),
          ),
          const Divider(height: 0.5, color: AppTheme.line),
          const SizedBox(height: 8),
          for (var i = 0; i < _navItems.length; i++)
            _NavTile(
              icon: _navItems[i].icon,
              label: _navItems[i].label,
              selected: shell.currentIndex == i,
              badge: i == _downloadsIndex ? downloading : null,
              onTap: () => shell.goBranch(
                i,
                // 点已选中的项 = 「回到这个入口的根」，与大多数桌面应用一致。
                initialLocation: i == shell.currentIndex,
              ),
            ),
          const Spacer(),
          const Divider(height: 0.5, color: AppTheme.line),
          // ⛔ **每家已连接的网盘一行**，而不是只显示「一个账号」。
          //
          //    多家同时在线是常态。只画一行的话，用户连了百度却看不见它 ——
          //    而且完全不知道自己连着两家（他看到的就是「一个账号」）。
          //    这正是「没看到百度网盘的对接入口」的根因。
          ..._accountRows(ref, auth, context),
          // 还有能连但没连的网盘时，给一个「添加」入口。
          //
          // ⛔ 它是**唯一**不需要先登出就能到达登录页的地方 —— 以前登录页
          //    藏在「退出登录」之后，而退出登录看起来是把账号删掉，
          //    没人会为了「加一个网盘」去点它。
          ..._addDriveRow(ref, auth, context),
          _NavTile(
            icon: Icons.receipt_long_rounded,
            label: '诊断日志',
            selected: false,
            onTap: () => context.push('/diagnostics'),
          ),
          // ⛔ 底部只留 2：侧栏那一列在 540 高的电视上余量本来就紧（见上面
          // `SizedBox` 上那段），过扫描内边距已经给了 27px 底边距，
          // 这里再留 6 是纯浪费。
          const SizedBox(height: 2),
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
    this.badge,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 右上角的数字角标。`null` 或 `0` 时不画。
  ///
  /// 挂在这里而不是让调用方拼一个 `Stack`：角标要跟**这一项**一起被
  /// 选中态高亮、一起被 hover 背景覆盖，拼在外面的话它会浮在背景之上，
  /// 看起来像一个掉在侧栏上的独立小方块。
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final tv = AppTheme.isTvLayout(context);
    final color = selected ? AppTheme.text : AppTheme.muted;
    final count = badge ?? 0;

    final tile = Padding(
      // ⛔ TV 上这圈上下内边距从 5 收到 4、里面那圈从 14 收到 12：
      // 540 高的屏上 486 要装下 logo + 6 个入口 + 账号块，原来**溢出 25px**，
      // 溢出的正是最底下那项「诊断日志」（它落到了安全带之外，而 Release 下
      // 溢出是被**静默裁掉**的 —— 看起来像「那个入口本来就没有」，可它还在
      // 焦点链里：遥控器按得到、屏幕上看不见）。
      //
      // 实测（不是算的）：每个 tile 61 → 55，`_Sidebar` 那个 `Column` 的
      // **`Spacer` 余量 23px**（量 `Spacer` 自己的高度才对 —— `诊断日志` 是被
      // 它顶到底部的，量它的 `bottom` 只反映尾部间距，量不出余量）。
      padding: EdgeInsets.symmetric(
        horizontal: tv ? 12 : 10,
        vertical: tv ? 4 : 2,
      ),
      child: Material(
        color: selected ? AppTheme.panel2 : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppTheme.panel2.withValues(alpha: 0.6),
          child: Padding(
            // TV 上把这一行撑到 ~55：桌面那 ~38 意味着「两行挤在一起」，
            // 遥控器上看不出焦点落在哪一行。
            padding: EdgeInsets.symmetric(
              horizontal: tv ? 16 : 10,
              vertical: tv ? 12 : 9,
            ),
            child: Row(
              children: [
                Icon(icon, size: tv ? 22 : 17, color: color),
                SizedBox(width: tv ? 14 : 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: tv ? AppTheme.tvNavLabel : 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                  ),
                ),
                if (count > 0) ...[
                  const Spacer(),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: tv ? 7 : 5,
                      vertical: tv ? 3 : 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accent,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      // 两位数以上就不再精确了：99+ 已经足够说明「很多」，
                      // 而三位数会把侧栏那一行撑开。
                      count > 99 ? '99+' : '$count',
                      style: TextStyle(
                        fontSize: tv ? 12 : 9.5,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                        color: AppTheme.bg,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (!tv) return tile;

    // TV 上「整项轻微放大」是这一版的焦点语言（见 [TvFocusable] 的类文档）。
    // 侧栏项自己有 `Material`，ink 高亮本来画得出来，所以**不再叠色罩** ——
    // 用户的原话是「不需要背景蒙版色凸显，看起来有点多余，也不太美观」。
    return TvFocusable(
      borderRadius: BorderRadius.circular(8),
      focusScale: 1.04,
      child: tile,
    );
  }
}

class _AccountBlock extends StatelessWidget {
  const _AccountBlock({
    required this.name,
    required this.detail,
    required this.degraded,
    required this.busy,
    this.onSignOut,
    this.signOutLabel,
    this.onTap,
  });

  final String name;
  final String? detail;
  final bool degraded;
  final bool busy;

  /// 为 `null` 时不画退出按钮（「未登录」那一行就是这个情形）。
  final VoidCallback? onSignOut;

  /// 退出按钮的悬浮提示。多家并存时「退出登录」是有歧义的 ——
  /// 必须写清退出的是哪一家。
  final String? signOutLabel;

  /// 点整行要做什么（未登录时 = 去登录页）。为 `null` 时整行不可点。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      // ⛔ 上间距从 12 收到 8：侧栏那一列在 540 高的电视上本来就装不下
      // （原来溢出 25px），这里是给「系统字体被放大」留的余量 ——
      // 侧栏**没有**套 `AppTheme.tvTextScaler`，字会跟着系统缩放长高，
      // 而 tile 的高度是「图标 22 与文字取大」决定的，缩放一大就整列变高。
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 6),
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
                  degraded ? '凭证仅本次有效' : (detail ?? '网盘'),
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
          // 侧栏底部那个 ⤴ 是纯图标 —— TV 上补文字标签，
          // 否则它看起来和「关掉窗口」没什么区别。
          if (onSignOut != null)
            TvIconLabel(
              label: signOutLabel ?? '退出登录',
              enabled: !busy,
              child: IconButton(
                onPressed: busy ? null : onSignOut,
                iconSize: 15,
                // ⛔ 多家并存时「退出登录」是有歧义的 —— 必须写清哪一家。
                tooltip: signOutLabel ?? '退出登录',
                icon: const Icon(Icons.logout_rounded),
              ),
            ),
        ],
      ),
    );

    // 「未登录」那一行整行可点（去登录页）。已连接的行不可点 ——
    // 点它没有任何可去的地方，给反馈反而是噪音。
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// 侧栏底部每一家**已连接**网盘一行。
///
/// 一行一家，各自带一个退出按钮 —— 登出百度不该把夸克也踢掉。
List<Widget> _accountRows(WidgetRef ref, AuthState? auth, BuildContext context) {
  final accounts = auth?.accounts ?? const {};
  if (accounts.isEmpty) {
    // ⚠️ 一家都没连时也**要说一句**，否则这一块整片空白，用户不知道
    //    那是「没登录」还是「这一块坏了」。
    return [
      _AccountBlock(
        name: '未登录',
        detail: '点这里连接网盘',
        degraded: false,
        busy: false,
        onTap: () => context.push('/auth'),
      ),
    ];
  }

  return [
    for (final e in accounts.entries)
      _AccountBlock(
        name: e.value.label,
        detail: e.value.memberLabel ?? e.key.displayName,
        // 凭证存不下来（Web 端）时提示「本次会话有效」。
        degraded: auth?.canPersist == false,
        busy: auth?.busy ?? false,
        // ⛔ 只登出**这一家**。
        onSignOut: () =>
            ref.read(authControllerProvider.notifier).signOut(provider: e.key),
        signOutLabel: '退出${e.key.shortName}',
      ),
  ];
}

/// 「还没连的网盘 → 添加」那一行。全连上了就没有。
///
/// ## ⛔ 为什么它必须存在
///
/// 以前登录页唯一的入口是账号行上的「退出登录」（先登出，路由才把人踢到
/// `/auth`）。而「退出登录」看起来是**删掉账号** —— 没有人会为了「再加
/// 一家网盘」去点它。所以接了百度之后，用户在界面上找不到任何入口。
List<Widget> _addDriveRow(WidgetRef ref, AuthState? auth, BuildContext context) {
  final accounts = auth?.accounts ?? const {};
  final all = ref.watch(selectableDrivesProvider);
  final missing = [
    for (final p in all)
      if (!accounts.containsKey(p)) p,
  ];
  if (missing.isEmpty) return const [];

  return [
    _AddDriveTile(
      label: '添加网盘（${missing.map((p) => p.shortName).join('／')}）',
      onTap: () => context.push('/auth'),
    ),
  ];
}

/// 「添加网盘」那一行 —— 一个带 `+` 的朴素列表项。
///
/// 做成列表项而不是按钮：它和上面的账号行是同一列的东西，长得像按钮会
/// 让人以为它是个「动作」，而它其实是「另一家网盘的入口」。
class _AddDriveTile extends StatelessWidget {
  const _AddDriveTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
        child: Row(
          children: [
            const Icon(Icons.add_rounded, size: 16, color: AppTheme.dim),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppTheme.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「再按一次返回退出」的居中提示浮层。
///
/// 自绘而不是 SnackBar：TV 上浮动态 SnackBar 会溢出显示异常（屏幕宽 960、
/// 高 540，SnackBar 的浮动态在这么矮的屏上容易压爆）。这是一个简单的胶囊，
/// 由 AppShell 的 `_backTapTimer` 在 3 秒后清除。
class _BackHintToast extends StatelessWidget {
  const _BackHintToast({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.panel2.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 16,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 1,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: AppTheme.text,
        ),
      ),
    );
  }
}
