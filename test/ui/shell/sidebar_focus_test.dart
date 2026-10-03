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

/// **左侧导航栏能不能被遥控器方向键走到。**
///
/// ## 为什么值得单开一个文件
///
/// `tv_pages_layout_test.dart` / `library_tv_layout_test.dart` 把页面铺在
/// **624** 宽里 —— 那是 `960 − 过扫描 96 − 侧栏 240`，也就是说**侧栏那 240
/// 一直被当成「已经用掉的宽度」扣掉，它自己从没被测过**。而用户报的
/// 「很多区域遥控器无法触达」里，侧栏恰恰是重灾区：它被包在壳的过扫描内边距
/// 里、每一项的焦点宿主是 `InkWell`（不是 `TvFocusable`），而
/// `StatefulShellRoute.indexedStack` 又会把 5 个分支**全部**留在 widget 树里。
///
/// ## 结论（2026-10-04 实测）
///
/// | 动作 | 结果 |
/// |---|---|
/// | 侧栏**内部** ↓ / ↑ 走六个入口 | ✅ 正常 |
/// | 焦点在侧栏时按 → 进内容区 | ✅ 正常 |
/// | OK 键（select）按在侧栏项上切分支 | ✅ 正常 |
/// | **焦点在内容区时按 ← / ↑ 进侧栏** | ✅ 正常（**靠兜底**，见下） |
/// | 侧栏在 540 高下是否溢出 | ✅ 不溢出（修前溢出 25px） |
///
/// 后两条原本都是缺陷，各自的用例就是当时的实测记录 —— 它们先是红的，
/// 修完才转绿。**别把它们删掉**：它们是这两条修复唯一的回归保护。
///
/// ## 根因：`StatefulShellRoute.indexedStack` 给每个分支一个独立 `Navigator`
///
/// 于是每个分支页各有一个自己的 `FocusScope`。`FocusTraversalPolicy.inDirection`
/// （`focus_traversal.dart:1070`）只在 `currentNode.nearestScope.traversalDescendants`
/// 里找候选，**找不到就直接返回 false，不会向上冒泡到父 scope**。而侧栏是分支页的
/// **兄弟**，在外层 scope 里 —— 从内容区出发，最近的 scope 里只有它自己那一个节点。
///
/// 实测（探针打出来的）：焦点在内容区时 `nearestScope.traversalDescendants`
/// **只有 1 个节点**；焦点在侧栏时同一个方向键就能走通。Tab 两个方向都能跨
/// （`_moveFocus` 会爬 scope 边界），但**真机遥控器没有 Tab**。
///
/// 修法是 `AppShell` 里那层 `Focus(onKeyEvent:)` 兜底：先跑
/// `focusInDirection`（与框架默认逐字一致），**它返回 false 才**在侧栏子树里
/// 按几何找一个送过去。所以下面那条 ← 的用例顺带钉住了「兜底真的接上了」。
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

  /// 侧栏上六个能拿焦点的入口，顺序即 `_items` 顺序，外加底部的「诊断日志」。
  const navLabels = ['媒体库', '文件夹', '扫描', '下载', '设置', '诊断日志'];

  /// 侧栏上「标签为 [label] 的那一项」。
  Finder navTile(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(TvFocusable),
      );

  /// 焦点现在在侧栏的哪一项上；不在侧栏就返回 `null`。
  String? focusedNavLabel(WidgetTester tester) {
    for (final label in navLabels) {
      if (focusedInside(tester, navTile(label))) return label;
    }
    return null;
  }

  /// 焦点当前落在哪 —— 只用于**失败时**把轨迹打出来，不参与断言。
  String whereIsFocus(WidgetTester tester) {
    final nav = focusedNavLabel(tester);
    if (nav != null) return '侧栏:$nav';
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

  testWidgets('侧栏第一项落在电视安全带之内 —— 过扫描不会切掉它', (tester) async {
    await onTv(() async {
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: makeContentNodes(),
      );

      // 防空转：侧栏没铺出来时，下面的几何断言全是废话。
      expect(
        find.byType(TvFocusable),
        findsNWidgets(navLabels.length),
        reason: '侧栏的六项没铺出来（或数量变了），这条用例测了个寂寞',
      );

      final first = tester.getRect(navTile('媒体库'));
      expect(
        first.left,
        greaterThanOrEqualTo(AppTheme.tvSafeHorizontal - 0.5),
        reason: '侧栏最左那一列探进了过扫描带 —— 真机上会被电视切掉。'
            '壳在 `app_shell.dart` 的 `body:` 那一层统一加了内边距，这里不该再漏。',
      );
      expect(
        first.top,
        greaterThanOrEqualTo(AppTheme.tvSafeVertical - 0.5),
        reason: '侧栏第一项顶进了过扫描带',
      );
    });
  });

  // 侧栏在 540 高下的高度预算。
  //
  // 修之前这里**溢出 25px**：约束是 `w=240, h<=486`，而「诊断日志」的
  // `TvFocusable` 落在 `Rect.fromLTRB(48, 467, 288, 528)` —— 安全带下沿只有
  // **513**，这一行整行掉在安全带外，底部离屏幕边只剩 12px。
  //
  // ⛔ 后果比「不好看」重得多：Debug 下是黄黑斜纹，**Release 下溢出被静默裁掉**
  // —— 看起来就像「那个入口本来就没有」，而它还在焦点链里：遥控器按得到、
  // 屏幕上看不见，用户只会以为遥控器坏了。
  //
  // ⚠️ `_Sidebar` 的 `Column` 里那个 `Spacer` 是 flex，可用高不够时它会被压成
  // 0 而**不会**救场 —— 别把它当保险。修法是收紧 tile 的内外上下内边距
  // （每个 61 → 55，见 `_NavTile`）。
  //
  // ⚠️ **余量要量 `Spacer` 的高度**，不是量「诊断日志」的 `bottom`：
  // 那个 tile 是被 `Spacer` 顶到底部的，它的 `bottom` 永远贴在安全带下沿，
  // 量它只反映尾部间距，量不出还剩多少空间。
  testWidgets('侧栏在 540 高下不溢出，而且还有余量', (tester) async {
    await onTv(() async {
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: makeContentNodes(),
      );

      expect(
        tester.takeException(),
        isNull,
        reason: '侧栏在 540 高下溢出了 —— 底部那几个入口会被静默裁掉',
      );
      expect(
        tester.getRect(navTile('诊断日志')).bottom,
        lessThanOrEqualTo(540 - AppTheme.tvSafeVertical + 0.5),
        reason: '「诊断日志」整行掉到安全带之外了',
      );

      // 留一点余量，而不是「刚好卡进去」：tile 高度是「图标 22 与文字取大」
      // 决定的，而侧栏**没有**套 `tvTextScaler` —— 系统字体一放大，
      // 5 个 tile 会一起长高。10 这个数是给那点浮动留的，不是随手写的。
      //
      // ⚠️ 得**指定是侧栏那一列里的**那个 `Spacer`：`_NavTile` 内部还有一个
      // （角标非空时才画，用来把数字顶到右边）。这里恰好没有角标，所以全窗口
      // 只有一个 —— 但别依赖这个巧合，角标一出现 `getSize` 就会因为「找到 2 个」
      // 而抛错。按几何取祖先链上最近的那个 `Column`（`_NavTile` 里没有
      // `Column`，所以它一定是侧栏那一列）。
      final sidebarColumn = find
          .ancestor(of: navTile('媒体库'), matching: find.byType(Column))
          .first;
      final slack = tester
          .getSize(
            find.descendant(of: sidebarColumn, matching: find.byType(Spacer)),
          )
          .height;
      expect(
        slack,
        greaterThan(10),
        reason: '侧栏只剩 $slack px 余量 —— 再动一下就会溢出，'
            '而溢出在 Release 下是静默裁掉的',
      );
    });
  });

  // 焦点在内容区时按 ← 能不能进侧栏。
  //
  // 这条用例是**修复前**那个缺陷的实测记录：连按 12 次 ←，焦点停在原地
  // （轨迹 `[内容区]`）。根因不是几何 —— 侧栏那 6 项完全符合 `←` 的筛选条件
  // （`node.rect.center.dx <= target.left`）—— 而是 **scope 隔离**：
  // `StatefulShellRoute.indexedStack` 给每个分支一个独立 `Navigator`，于是分支页
  // 有自己的 `FocusScope`；`FocusTraversalPolicy.inDirection` 只在
  // `nearestScope.traversalDescendants` 里找，找不到**不冒泡到父 scope**。
  // 探针实测：焦点在内容区时那个列表**只有 1 个节点**（就是它自己）。
  //
  // 现在靠 `AppShell` 里那层 `Focus(onKeyEvent:)` 兜底走通（`_onShellKey`）。
  // ⛔ 这条用例是那个兜底的**唯一**回归保护 —— 兜底一删它立刻变红。
  testWidgets('从内容区按 ← 能走进侧栏，而且落点按几何算', (tester) async {
    await onTv(() async {
      final nodes = makeContentNodes();
      await pumpShell(
        tester,
        container: makeContainer(),
        contentNodes: nodes,
      );

      // 侧栏的右缘：判「焦点是不是已经在侧栏那一列里」用。
      final sidebarRight = tester.getRect(navTile('媒体库')).right;
      bool inSidebar() {
        final primary = FocusManager.instance.primaryFocus;
        final rect = primary?.rect;
        if (rect == null || rect.isEmpty) return false;
        return rect.center.dx <= sidebarRight;
      }

      /// 从内容区的某一半按 ←，返回焦点最终落在侧栏的哪个高度上。
      Future<double> pressLeftFrom(FocusNode from, String what) async {
        from.requestFocus();
        await tester.pump();
        expect(
          from.hasFocus,
          isTrue,
          reason: '前置没成立：焦点没落到$what，后面的 ← 轨迹无法解读',
        );

        final trace = <String>[];
        for (var step = 0; step < 12; step++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          final where = whereIsFocus(tester);
          if (trace.isEmpty || trace.last != where) trace.add(where);
          if (inSidebar()) return FocusManager.instance.primaryFocus!.rect.center.dy;
        }
        fail('从$what按了 12 次 ← 也没能进侧栏。轨迹：$trace');
      }

      final fromTop = await pressLeftFrom(nodes.first.first, '内容区上半块');
      final fromBottom = await pressLeftFrom(nodes.first.last, '内容区下半块');

      // ⛔ 这一条才是「按几何找」的证据：只断言「进得去」的话，
      // 「无脑 focus 侧栏第一项」那种实现照样过。
      expect(
        fromTop,
        lessThan(fromBottom),
        reason: '从上半块进侧栏落在 y=$fromTop、从下半块落在 y=$fromBottom —— '
            '从更高的地方进去却没落在更高的一项上，说明兜底不是按几何找的。',
      );
    });
  });

  testWidgets('侧栏内部：↓ 从顶走到底、↑ 从底走回顶', (tester) async {
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

      // 从最上面一路往下：六个入口（含底部的「诊断日志」）都要到得了。
      await walk('媒体库', LogicalKeyboardKey.arrowDown, expectAll: navLabels);

      // 再从最下面一路往上回到「媒体库」。
      //
      // ⚠️ 这里刻意**不**要求走到「诊断日志」：它是最底下那一项，从「媒体库」
      // 往上走几何上永远碰不到它（`↑` 的候选是 `center.dy <= 目标.top`），
      // 那是正确的几何，不是缺陷。所以起点选「诊断日志」，验的是**回程**。
      await walk(
        '诊断日志',
        LogicalKeyboardKey.arrowUp,
        expectAll: navLabels.where((l) => l != '诊断日志').toList(),
      );
    });
  });

  testWidgets('焦点在侧栏时按 → 能进内容区', (tester) async {
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
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        entered = flatten(nodes).any((n) => n.hasFocus);
      }

      expect(
        entered,
        isTrue,
        reason: '从侧栏按 → 进不了内容区 —— 两个方向都堵死的话侧栏就彻底是个摆设。'
            '轨迹：${whereIsFocus(tester)}',
      );
    });
  });

  testWidgets('OK 键（select）按在侧栏项上，真的切了分支', (tester) async {
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
        account: CloudAccount(
          provider: DriveProvider.quark,
          authMode: AuthMode.browserCookie,
          authorizedAt: DateTime(2026, 10, 4),
        ),
      );
}

/// 真的那个 `build()` 会去建 SQLite、读适配器注册表 —— 侧栏只用它算角标。
class _FakeQueue extends DownloadQueueController {
  @override
  List<DownloadTask> build() => const [];
}
