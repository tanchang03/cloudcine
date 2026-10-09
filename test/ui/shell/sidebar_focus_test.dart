import 'package:cloudcine/domain/entities/capabilities.dart';
import 'package:cloudcine/domain/entities/cloud_account.dart';
import 'package:cloudcine/domain/entities/download_task.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/download_providers.dart';
import 'package:cloudcine/ui/shell/app_shell.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_focus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/focus_reach.dart';

/// **一级导航（TV 顶栏 / 桌面侧栏）能不能被遥控器方向键走到。**
///
/// ## 为什么值得单开一个文件
///
/// TV 已改走**顶部一级导航**（参考夸克网盘 TV 版）：左右分栏在 960 宽下
/// 吃掉 240 + 过扫描 96，只剩 624 给内容；顶栏只吃纵向 60，内容区拿到 864。
/// 而用户报的「很多区域遥控器无法触达」里，一级导航恰恰是重灾区：它被包在
/// 壳的过扫描内边距里、每一项的焦点宿主是 `InkWell`（不是 `TvFocusable`），而
/// `StatefulShellRoute.indexedStack` 又会把 5 个分支**全部**留在 widget 树里。
///
/// ## 结论
///
/// | 动作 | 结果 |
/// |---|---|
/// | 顶栏**内部** ← / → 走五个入口 | ✅ 正常 |
/// | 焦点在顶栏时按 ↓ 进内容区 | ✅ 正常 |
/// | OK 键（select）按在导航项上切分支 | ✅ 正常 |
/// | **焦点在内容区时按 ↑ 进顶栏** | ✅ 正常（**靠兜底**，见下） |
/// | 顶栏在 960 宽下是否溢出 | ✅ 不溢出 |
///
/// ## 根因：`StatefulShellRoute.indexedStack` 给每个分支一个独立 `Navigator`
///
/// 于是每个分支页各有一个自己的 `FocusScope`。`FocusTraversalPolicy.inDirection`
/// （`focus_traversal.dart:1070`）只在 `currentNode.nearestScope.traversalDescendants`
/// 里找候选，**找不到就直接返回 false，不会向上冒泡到父 scope**。而一级导航
/// 是分支页的**兄弟**，在外层 scope 里 —— 从内容区出发，最近的 scope 里只有
/// 它自己那一个节点。
///
/// 实测（探针打出来的）：焦点在内容区时 `nearestScope.traversalDescendants`
/// **只有 1 个节点**；焦点在导航时同一个方向键就能走通。Tab 两个方向都能跨
/// （`_moveFocus` 会爬 scope 边界），但**真机遥控器没有 Tab**。
///
/// 修法是 `AppShell` 里那层 `Focus(onKeyEvent:)` 兜底：先跑
/// `focusInDirection`（与框架默认逐字一致），**它返回 false 才**在导航子树里
/// 按几何找一个送过去。所以下面那条 ↑ 的用例顺带钉住了「兜底真的接上了」。
///
/// ## ⚠️ 判焦点为什么不能用 `find.text(label)`
///
/// 焦点宿主是 tile **里面**那个 `InkWell`，`Text` 是它的**后代**；而
/// [focusedInside] 是**往上**走祖先链的 —— 拿后代当靶子会永远返回 false，
/// 得到一条一直红的假警报。得用包在**外面**的 `TvFocusable`（它在焦点宿主
/// 之上）。理由与 `test/support/focus_reach.dart` 开头那段一致。
void main() {
  /// 分支顺序**必须**与 `app_shell.dart` 里 `_items` 一致 —— 侧栏那个
  /// `shell.currentIndex == i` 是按**下标**对的（见 `app_router.dart:112`）。
  const paths = ['/library', '/folders', '/scan', '/downloads', '/settings'];

  /// 顶栏上五个能拿焦点的入口（TvFocusable 包着的 tab），顺序即 `_navItems`。
  /// 「诊断」是右端 IconButton，不在 TvFocusable 计数里，单独覆盖。
  const navLabels = ['媒体库', '文件夹', '扫描', '下载', '设置'];

  /// 导航上「标签为 [label] 的那一项」。
  Finder navTile(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(TvFocusable),
      );

  /// 焦点现在在导航的哪一项上；不在导航就返回 `null`。
  String? focusedNavLabel(WidgetTester tester) {
    for (final label in navLabels) {
      if (focusedInside(tester, navTile(label))) return label;
    }
    return null;
  }

  /// 焦点是否落在顶栏那一行里（五个 tab 任一）。
  bool inTopNav(WidgetTester tester) => focusedNavLabel(tester) != null;

  /// 焦点当前落在哪 —— 只用于**失败时**把轨迹打出来，不参与断言。
  String whereIsFocus(WidgetTester tester) {
    final nav = focusedNavLabel(tester);
    if (nav != null) return '导航:$nav';
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return '无焦点';
    final r = primary.rect;
    return 'x=${r.left.round()} y=${r.top.round()}';
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(_FakeAuth.new),
        downloadQueueProvider.overrideWith(_FakeQueue.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 铺开**真的 `AppShell`**：真 `GoRouter` + 真 `StatefulShellRoute.indexedStack`，
  /// 只有五个分支页是占位。view 报电视尺寸（960×540），平台报 android ——
  /// 这样 `AppTheme.isTvLayout` 才为真，侧栏才走 240 那条分支。
  ///
  /// [onShell] 把 `StatefulNavigationShell` 交出来，用来断言「真的切了分支」。
  Future<void> pumpShell(
    WidgetTester tester, {
    required ProviderContainer container,
    required List<List<FocusNode>> contentNodes,
    void Function(StatefulNavigationShell)? onShell,
  }) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;

    final router = GoRouter(
      initialLocation: paths.first,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) {
            onShell?.call(shell);
            return AppShell(shell: shell);
          },
          branches: [
            for (var i = 0; i < paths.length; i++)
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: paths[i],
                    builder: (_, __) =>
                        _StubBranch(i, focusNodes: contentNodes[i]),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
  }

  /// 每个用例都要自己造内容区节点并负责释放。
  ///
  /// 每个分支给**上下两块**：这是为了能证明「← 的落点按几何算」——
  /// 只有一块的话，「落到最近的那一项」和「无脑 focus 第一项」两种实现
  /// 都会过（见那条 ← 用例）。
  List<List<FocusNode>> makeContentNodes() {
    final all = [
      for (var i = 0; i < paths.length; i++)
        [
          FocusNode(debugLabel: 'content$i-top'),
          FocusNode(debugLabel: 'content$i-bottom'),
        ],
    ];
    addTearDown(() {
      for (final branch in all) {
        for (final n in branch) {
          n.dispose();
        }
      }
    });
    return all;
  }

  /// 所有分支、所有块 —— 「内容区里有没有东西拿到焦点」用。
  Iterable<FocusNode> flatten(List<List<FocusNode>> nodes) =>
      nodes.expand((branch) => branch);

  /// 拿到侧栏某一项**真正的焦点宿主**（`InkWell` 里那个 `Focus` 节点）。
  ///
  /// ⚠️ 不能用 `Focus.of(tester.element(navTile(label)))`：`TvFocusable` 的
  /// element 是那个 `Focus` 的**父**，`Focus.of` 往上找只会找到更外层的东西。
  ///
  /// 这里**故意**按几何把节点捞出来、直接 `requestFocus`，而不是「从内容区按
  /// 方向键走过去」：那样测的是兜底那条路，而下面这几条要测的是**焦点已经在
  /// 侧栏上之后**的行为（↓/↑ 走不走得全、→ 回不回得去、OK 键按不按得动）。
  /// 混在一起的话，兜底一坏会连带把这几条也弄红，就看不出坏的是哪一半了。
  /// 侧栏内部那半边**本来就是好的**，同样需要回归保护。
  FocusNode tileNode(WidgetTester tester, String label) {
    final rect = tester.getRect(navTile(label));
    return FocusManager.instance.rootScope.descendants.firstWhere(
      (n) =>
          n.canRequestFocus &&
          n.context != null &&
          n is! FocusScopeNode &&
          rect.contains(n.rect.center),
      orElse: () => throw StateError('侧栏「$label」那一项里没找到可聚焦节点'),
    );
  }

  /// 跑一条用例的标准开场：平台设成 android，结尾复位。
  ///
  /// ⚠️ 复位只能写在**测试体里**（放进 `addTearDown` 时 widget 树已经拆完，
  /// 某些用例的 `expect` 会读到错的平台值）—— 这是本项目既有的坑。
  Future<T> onTv<T>(Future<T> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      return await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('顶栏第一项落在电视安全带之内 —— 过扫描不会切掉它', (tester) async {
    await onTv(() async {
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: makeContentNodes(),
      );

      // 防空转：顶栏没铺出来时，下面的几何断言全是废话。
      expect(
        find.byType(TvFocusable),
        findsNWidgets(navLabels.length),
        reason: '顶栏的五项没铺出来（或数量变了），这条用例测了个寂寞',
      );

      final first = tester.getRect(navTile('媒体库'));
      expect(
        first.left,
        greaterThanOrEqualTo(AppTheme.tvSafeHorizontal - 0.5),
        reason: '顶栏最左那一项探进了过扫描带 —— 真机上会被电视切掉。'
            '壳在 `app_shell.dart` 的 `body:` 那一层统一加了内边距，这里不该再漏。',
      );
      expect(
        first.top,
        greaterThanOrEqualTo(AppTheme.tvSafeVertical - 0.5),
        reason: '顶栏顶进了过扫描带',
      );
    });
  });

  // 顶栏在 960 宽下的宽度预算：五个 tab + logo + 账号/诊断必须装进
  // 960 − 过扫描 96 = 864。溢出在 Release 下是静默裁掉 —— 看起来就像
  // 「那个入口本来就没有」，而它还在焦点链里：遥控器按得到、屏幕上看不见。
  testWidgets('顶栏在 960 宽下不溢出，内容区拿到 864 宽', (tester) async {
    await onTv(() async {
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: makeContentNodes(),
      );

      expect(
        tester.takeException(),
        isNull,
        reason: '顶栏在 960 宽下溢出了 —— 右端入口会被静默裁掉',
      );
      final last = tester.getRect(navTile('设置'));
      expect(
        last.right,
        lessThanOrEqualTo(960 - AppTheme.tvSafeHorizontal + 0.5),
        reason: '顶栏右端探进了过扫描带',
      );
      // 内容区宽度 = 整屏 − 过扫描（顶栏只吃纵向，不再吃横向 240）。
      expect(
        960 - AppTheme.tvSafeHorizontal * 2,
        864,
        reason: '顶栏模式下内容区应为 864 宽（左右分栏时代只有 624）',
      );
    });
  });

  // 焦点在内容区时按 ↑ 能不能进顶栏。
  //
  // 根因不是几何 —— 顶栏那 5 项完全符合 `↑` 的筛选条件
  // （`node.rect.center.dy <= target.top`）—— 而是 **scope 隔离**：
  // `StatefulShellRoute.indexedStack` 给每个分支一个独立 `Navigator`，于是分支页
  // 有自己的 `FocusScope`；`FocusTraversalPolicy.inDirection` 只在
  // `nearestScope.traversalDescendants` 里找，找不到**不冒泡到父 scope**。
  // 探针实测：焦点在内容区时那个列表**只有 1 个节点**（就是它自己）。
  //
  // 现在靠 `AppShell` 里那层 `Focus(onKeyEvent:)` 兜底走通（`_onShellKey`）。
  // ⛔ 这条用例是那个兜底的**唯一**回归保护 —— 兜底一删它立刻变红。
  testWidgets('从内容区按 ↑ 能走进顶栏', (tester) async {
    await onTv(() async {
      final nodes = makeContentNodes();
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: nodes,
      );

      /// 从内容区的某一块按 ↑，断言最终落在顶栏。
      Future<void> pressUpFrom(FocusNode from, String what) async {
        from.requestFocus();
        await tester.pump();
        expect(
          from.hasFocus,
          isTrue,
          reason: '前置没成立：焦点没落到$what，后面的 ↑ 轨迹无法解读',
        );

        final trace = <String>[];
        var entered = false;
        for (var step = 0; step < 12; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pump();
          final where = whereIsFocus(tester);
          if (trace.isEmpty || trace.last != where) trace.add(where);
          if (inTopNav(tester)) {
            entered = true;
            break;
          }
        }
        expect(
          entered,
          isTrue,
          reason: '从$what按了 12 次 ↑ 也没能进顶栏。轨迹：$trace',
        );
      }

      await pressUpFrom(nodes.first.first, '内容区上半块');
      await pressUpFrom(nodes.first.last, '内容区下半块');
    });
  });

  testWidgets('顶栏内部：→ 从左走到右、← 从右走回左', (tester) async {
    await onTv(() async {
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: makeContentNodes(),
      );

      /// 从 [from] 出发按 [key]，一路记下焦点到过哪些项。
      Future<void> walk(
        String from,
        LogicalKeyboardKey key, {
        required List<String> expectAll,
      }) async {
        tileNode(tester, from).requestFocus();
        await tester.pump();
        expect(focusedNavLabel(tester), from, reason: '入场没成：起点不是「$from」');

        final seen = <String>{from};
        final trace = <String>[from];
        for (var step = 0; step < 16; step++) {
          await tester.sendKeyEvent(key);
          await tester.pump();
          final label = focusedNavLabel(tester);
          final where = label ?? whereIsFocus(tester);
          if (trace.last != where) trace.add(where);
          if (label != null) seen.add(label);
          if (seen.containsAll(expectAll)) break;
        }
        expect(
          seen,
          containsAll(expectAll),
          reason: '按 $key 走不全。期望至少到过 $expectAll，'
              '实际到过：$seen；轨迹：$trace',
        );
      }

      // 从最左一路往右：五个入口都要到得了。
      await walk('媒体库', LogicalKeyboardKey.arrowRight, expectAll: navLabels);

      // 再从最右一路往左回到「媒体库」。
      await walk(
        '设置',
        LogicalKeyboardKey.arrowLeft,
        expectAll: navLabels.where((l) => l != '设置').toList(),
      );
    });
  });

  testWidgets('焦点在顶栏时按 ↓ 能进内容区', (tester) async {
    await onTv(() async {
      final nodes = makeContentNodes();
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: nodes,
      );

      tileNode(tester, '媒体库').requestFocus();
      await tester.pump();

      var entered = false;
      for (var step = 0; step < 6 && !entered; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        entered = flatten(nodes).any((n) => n.hasFocus);
      }

      expect(
        entered,
        isTrue,
        reason: '从顶栏按 ↓ 进不了内容区 —— 两个方向都堵死的话顶栏就彻底是个摆设。'
            '轨迹：${whereIsFocus(tester)}',
      );
    });
  });

  testWidgets('OK 键（select）按在导航项上，真的切了分支', (tester) async {
    await onTv(() async {
      StatefulNavigationShell? shell;
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: makeContentNodes(),
        onShell: (s) => shell = s,
      );
      expect(shell, isNotNull, reason: '没拿到 shell，后面断言不了分支下标');

      // 直接落在「设置」上（侧栏最后一项，下标 4）。刻意**不**调
      // `shell.goBranch` —— 这里要验的正是「遥控器按下去能不能激活」。
      tileNode(tester, '设置').requestFocus();
      await tester.pump();
      expect(focusedNavLabel(tester), '设置', reason: '前置没成立');

      // Android TV 的 OK 键 = KEYCODE_DPAD_CENTER 23 → `select`。
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        shell!.currentIndex,
        4,
        reason: 'OK 键按在「设置」上，分支没切过去 —— 焦点拿得到却按不动，'
            '等于侧栏是死的',
      );
    });
  });
}

/// 分支占位页。
///
/// 给一个真的 `InkWell` 而不是一块纯文字：这样它和真页面一样**能拿焦点**，
/// 才能模拟「用户正停在内容里」。`StatefulShellRoute.indexedStack` 会把五个
/// 分支**全部**留在树里，所以这段在每一条用例里都存在五份。
///
/// ⚠️ 这里**不**包 `TvFocusable`：包了的话 `find.byType(TvFocusable)` 就不再是
/// 恰好 6 个，侧栏那几条断言会误判。
class _StubBranch extends StatelessWidget {
  const _StubBranch(this.index, {required this.focusNodes});

  final int index;

  /// 上下**两块**（各占半高），不是一块。
  ///
  /// ⛔ 别图省事合成一块：内容区只有一个可聚焦节点时，「← 的落点按几何算」
  /// 与「无脑 focus 侧栏第一项」两种实现**都能过**那条用例。要能分辨，就得
  /// 让内容区有上下两个不同高度的起点（见那条 ← 用例里的 `fromTop < fromBottom`）。
  final List<FocusNode> focusNodes;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.bg,
      child: Column(
        children: [
          for (var i = 0; i < focusNodes.length; i++)
            Expanded(
              child: InkWell(
                focusNode: focusNodes[i],
                onTap: () {},
                child: Center(
                  child: Text(
                    '内容区-$index-$i',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 只喂状态、不碰真适配器与凭证存储（照抄 `tv_pages_layout_test.dart`）。
class _FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => AuthState(
        accounts: {
          DriveProvider.quark: CloudAccount(
            provider: DriveProvider.quark,
            authMode: AuthMode.browserCookie,
            authorizedAt: DateTime(2026, 10, 4),
          ),
        },
      );
}

/// 真的那个 `build()` 会去建 SQLite、读适配器注册表 —— 侧栏只用它算角标。
class _FakeQueue extends DownloadQueueController {
  @override
  List<DownloadTask> build() => const [];
}
