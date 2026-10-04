import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/pages/library_page.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/scan_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/common_widgets.dart';
import 'package:cloudcine/ui/widgets/tv_focus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/focus_reach.dart';

/// 媒体库页在**电视尺寸**下的排版。
///
/// ## 为什么这几条非写不可
///
/// 「TV 上排版乱、有东西遥控器够不到」这件事，在开发机上**永远复现不出来**：
/// macOS 窗口最小也就 800 宽，而 `isTvLayout` 只在 Android + ≥960 才成立，
/// 于是所有 TV 分支在本地跑应用时走的都是桌面那一支。
///
/// ## 为什么不能只把 view 设成 960 就完事
///
/// 页面拿到的**不是** 960。真实链路上被吃掉两层：
///
///   * 过扫描安全边距 48×2（官方 TV 规范，不躲开的话最外圈字会被切掉）
///   * 侧栏 240（`AppTheme.tvSidebarWidth`）
///
/// 960 − 96 − 240 = **624** —— 这是 `LibraryPage` 真正拿到的宽度。页头自己
/// 还有 22×2 的内边距，于是那一行操作只剩 **580**。
///
/// 而 `AppTheme.isTvLayout` 读的是 `MediaQuery.sizeOf`（= view 的 960），
/// 不是 624 —— 所以判据和约束宽度可以、也必须在测试里分开给。只把 view
/// 设成 960 而让页面占满，等于凭空多给 336px，测出来的「没溢出」是假的。
///
/// 实测：在 624 这个真实宽度下，媒体库页头那一行**溢出 145px**。
class FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

class FakeScan extends ScanController {
  @override
  ScanState build() => const ScanState();
}

void main() {
  /// 真机上电视页面区的宽度（960 − 过扫描 96 − 侧栏 240）。改动侧栏或安全
  /// 边距都要同步改这里 —— 它是这套测试唯一的「真机常数」。
  const double tvPageWidth = 624;

  final now = DateTime(2026, 10, 3);

  MediaWork work(String key, {required String title, int itemCount = 1}) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: title,
        itemCount: itemCount,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaItem item(String workKey, String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/电影/$workKey/',
        groupKey: workKey,
        kind: MediaKind.movie,
        title: fileId,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 铺开媒体库页：view 是电视尺寸（判据为真），但页面只拿到 [tvContentWidth]。
  Future<void> pumpTvPage(WidgetTester tester) async {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repo = DriftMediaRepository(db);
    await repo.upsertWorks([
      work('a', title: '片子甲', itemCount: 3),
      work('b', title: '片子乙', itemCount: 2),
    ], now: now);
    await repo.upsertItems([
      item('a', 'f1'),
      item('b', 'f2'),
    ], now: now);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mediaRepositoryProvider.overrideWithValue(repo),
        authControllerProvider.overrideWith(FakeAuth.new),
        scanControllerProvider.overrideWith(FakeScan.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: Key('tv-frame'),
                width: tvPageWidth,
                height: 486,
                child: LibraryPage(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('页头操作区在电视宽度下不横向溢出', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpTvPage(tester);

      // RenderFlex 溢出在真机上表现为「右上角一块黄黑斜纹」或（Release 下）
      // 直接被裁掉 —— 后者看起来就像「那几个按钮本来就不存在」，
      // 而它们其实还在、只是被画到了屏幕外，遥控器按得到却看不见。
      expect(
        tester.takeException(),
        isNull,
        reason: '页头那一行塞了视图切换 + 搜索框 + 排序 + 筛选 + 选择 + 刷新。'
            '它们必须能折行（`Wrap`）—— 换回 `Row` 就会在这个宽度下溢出 145px，'
            '而溢出在 Release 下只是「静静地少几个按钮」',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('页头与分类栏的每个控件都落在可见区内（遥控器够得到也看得见）',
      (tester) async {
    // 页头在 TV 上**不再折行**（见 `_LibraryHeader`）：八个控件被重新分区到
    // 「页头一带 / 分类栏一带 / 更多菜单」三处。分区之后任何一处算错宽度，
    // 控件都会跑出内容区 —— 而 `Row` 溢出在 Release 下只是**静静地画到屏幕
    // 外**：遥控器按得到、屏幕上看不见，用户只会以为遥控器坏了。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpTvPage(tester);

      final frame = tester.getRect(find.byKey(const Key('tv-frame')));

      // 页头的控件都在这两个 finder 里：搜索框与「视图切换 / 更多 / 排序 /
      // 筛选 / 分类胶囊」（后四个都套了 `TvFocusable`）。海报卡也在
      // `TvFocusable` 里，但它由 `GridView` 自己的宽度约束管着，顺带一起验。
      final groups = <Finder>[
        find.byType(HeaderSearchBox),
        find.byType(TvFocusable),
      ];

      var checked = 0;
      for (final group in groups) {
        for (var i = 0; i < group.evaluate().length; i++) {
          // 分类胶囊要跳过：八个胶囊在 580 里排不下，它们是**设计上就要横向
          // 滚动**的，排在后面的几个本来就被 `ListView` 布局到视口之外 ——
          // 那是「往右按还能看到更多」，不是「跑到区外看不见」。
          if (inHorizontalScroll(group.evaluate().elementAt(i))) continue;

          final rect = tester.getRect(group.at(i));
          expect(
            rect.left >= frame.left - 0.5 && rect.right <= frame.right + 0.5,
            isTrue,
            reason: '第 $checked 个控件横跨 ${rect.left}–${rect.right}，'
                '而内容区只有 ${frame.left}–${frame.right}。'
                '跑到区外的控件在电视上就是「按得到但看不见」——'
                '用户会以为遥控器坏了',
          );
          checked++;
        }
      }
      expect(
        checked,
        greaterThanOrEqualTo(3),
        reason: '页头 / 分类栏 / 海报墙都没渲染出来，这条用例测不到东西',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('页头只占一带，海报墙拿得下**完整两排**海报', (tester) async {
    // 诉求原话是「界面整体布局看起来有效空间过小，对于 4k 电视分辨率，
    // 将布局优化紧凑，重点突出」。实测的「过小」长这样（960×540、页面
    // 实得 624×486）：
    //
    //   上一版：页头 122 + 分类栏 50 = **172px** 的装饰，
    //          海报墙只剩 **294px** —— 而一张卡高 168，第二排只能露半个头。
    //
    // 这一版把八个控件重新分区（见 `_LibraryHeader` / `_CategoryBar.leading`），
    // 页头压到一带。这条用例把「海报墙拿得下两整排」钉住 —— 那是「紧凑」
    // 唯一有意义的验收口径，光断言「没溢出」是量不出改善的。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpTvPage(tester);

      final frame = tester.getRect(find.byKey(const Key('tv-frame')));
      final header = tester.getRect(find.byKey(const Key('library-header')));
      final grid = tester.getRect(find.byType(GridView));

      // ⛔ 80 不是「差一点」的边界，是「又折回两带」的信号：页头一旦折行
      // （任何一处宽度算错都会），实测回到 110px 以上，海报墙立刻掉到
      // 装不下两排 —— 而屏幕上看起来只是「第二排海报被切了一半」。
      expect(
        header.height,
        lessThan(80),
        reason: '页头占了 ${header.height}px（整页只有 ${frame.height}）。'
            'TV 上它必须只有**一带**：标题 / 视图切换 / 搜索 / 更多。'
            '折成两带就会把第二排海报顶出可视区。',
      );

      expect(
        grid.height,
        greaterThan(frame.height * 0.7),
        reason: '海报墙只有 ${grid.height}px（整页 ${frame.height}）。'
            '这一页的主体是海报，页头与分类栏加起来不该超过三成。',
      );

      // 「看得见一行」是底线，「**完整**看得见第二行」才是这一页读起来像
      // 海报墙的前提 —— 电视上没有滚动条，露半个头的第二排会被读成
      // 「这个应用把海报切坏了」。
      final card = tester.getRect(find.byType(TvFocusable).last);
      expect(
        grid.height,
        greaterThan(card.height * 2),
        reason: '卡片高 ${card.height}，海报墙只有 ${grid.height} —— '
            '装不下完整两排。查一下页头 / 分类栏是不是又长高了，'
            '或者海报网格的底边距（TV 上是 8）被改大了。',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('遥控器走得到页头、分类条、海报墙 —— 三块区域都不是死区',
      (tester) async {
    // 诉求原话里有半句是「**很多区域遥控器方式无法触达**」。
    // `test/ui/tv_remote_probe_test.dart` 证明的是「Flutter 的焦点机制成立」
    // （用的是自造的形状相同的 widget），**没有证明真页面上接线接对了** ——
    // 少包一个 `TvFocusable`、或者哪一块被顺手 `ExcludeFocus` 包住，
    // 探针文件不会响，这一条才会。
    //
    // 用 Tab 而不是方向键：方向键的可达性依赖几何位置（网格里 ↓ 到底走哪一格
    // 取决于间距），换一个 `posterAspect` 就会飘；Tab 走的是**阅读顺序**，
    // 稳定地枚举「这一页上哪些东西能拿到焦点」。真机上遥控器没有 Tab，
    // 这里把它当作「可达性」的代理 —— 与探针文件同一套用法。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpTvPage(tester);

      final header = find.byKey(const Key('library-header'));
      final focusables = find.byType(TvFocusable);
      expect(header, findsOneWidget, reason: '页头没渲染出来，这条用例测不到东西');
      expect(
        focusables.evaluate().length,
        greaterThanOrEqualTo(3),
        reason: '页头里的「更多」、分类胶囊与海报卡都是 TvFocusable。少于 3 个'
            '说明内容区根本没铺开，那样「走得通」是假的',
      );

      // 分类条上的胶囊、页面主体的海报卡 —— 分别代表「页头下面那条」与
      // 「页面主体」两块。
      //
      // ⚠️ 分类条那一项**不能**用 `focusables.first`：页头里的「更多」
      // 也套了 `TvFocusable`（它原本连焦点环都没有），而它在树里更靠前。
      // 用 `.first` 的话这一条会**悄悄变成在测「更多」**，仍然全绿 ——
      // 一条不再测它该测的东西的断言比没有更糟。所以按文案定位到「全部」那颗胶囊。
      final firstChip = find
          .ancestor(of: find.text('全部'), matching: find.byType(TvFocusable))
          .first;
      final hit = await walkReachability(
        tester,
        probes: {
          // ⚠️ 页头那一带用 key 而不是 `TvIconLabel`：TV 上「刮削 / 重扫 /
          // 选择 / 刷新」已经收进「更多」菜单，页头里一个 `TvIconLabel`
          // 都没有了 —— 拿它当探针会**永远**命中不了。
          '页头': (t) => focusedInside(t, header),
          '分类条': (t) => focusedInside(t, firstChip),
          '海报墙': (t) => focusedInside(t, focusables.last),
        },
      );

      expect(
        hit[0],
        isTrue,
        reason: '焦点走不到页头 —— 那里有视图切换、搜索框和「更多」'
            '（刮削 / 重扫 / 选择 / 刷新的入口）。够不到等于这些功能在电视上'
            '不存在。查一下这一块是不是被 ExcludeFocus 包住了'
            '（播放页控制栏原来就犯过这个错）',
      );
      expect(
        hit[1],
        isTrue,
        reason: '焦点走不到分类胶囊 —— 分类筛选在电视上就等于没有',
      );
      expect(
        hit[2],
        isTrue,
        reason: '焦点走不到海报卡 —— 那是这一页唯一能进详情 / 播放的入口，'
            '走不到就等于整页只读',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('焦点落到海报上时**看得见** —— 够得到 ≠ 看得见', (tester) async {
    // 上一条证明的是「焦点**走得到**」。而走得到但**看不见焦点在哪**，在电视上
    // 和够不到是同一种坏：用户只能盲按。
    //
    // 焦点提示的显示条件比可达性苛刻：
    //   `TvFocusable._showHighlight = _focused && highlightMode == traditional`
    // 而 Android 上 `highlightMode` 默认是 `touch`，**收到第一个按键事件才翻成
    // traditional**（见 `tv_focus.dart` 的类文档）。所以「焦点提示没出现」有两种
    // 完全不同的原因 —— 焦点没到位，或者档位还没翻 —— 只有断言能区分。
    //
    // 判据取 `AnimatedScale.scale`：全项目**只有海报卡**传了
    // `focusScale: 1.05`（grep `focusScale` 可证），而它与那层提亮罩
    // 由同一个 `_showHighlight` 控制 —— 于是「存在 scale > 1 的 AnimatedScale」
    // 就等于「焦点提示正在画」。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpTvPage(tester);

      Finder ringed() =>
          find.byWidgetPredicate((w) => w is AnimatedScale && w.scale > 1.0);

      // 反空转：还没按过任何键时 highlightMode 是 `touch`，一张卡都不该放大。
      // 少了这一句，下面那条断言在「焦点环压根没接上 highlightMode」时也会绿 ——
      // 而那正是桌面上「鼠标点过的卡片留一圈环」的成因。
      expect(
        ringed(),
        findsNothing,
        reason: '还没按过遥控器就把卡片放大了 —— 焦点提示的判据绕过了 '
            'highlightMode，桌面上鼠标点过的卡片会一直留一层亮罩',
      );

      final hit = await walkReachability(
        tester,
        probes: {
          '海报墙': (t) => focusedInside(t, find.byType(TvFocusable).last),
        },
      );
      expect(hit[0], isTrue, reason: '焦点没走到海报卡，这条用例测不到东西');

      expect(
        ringed(),
        findsWidgets,
        reason: '焦点已经在海报卡上、也按过键了，却没有一张卡在放大 —— '
            '焦点提示没画出来，电视上用户看不见焦点在哪，只能盲按。'
            '查 `TvFocusable._showHighlight` 的两个条件，以及有没有人把 '
            '`focusScale` 改回 1.0',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('电视上侧栏让出的宽度确实大于桌面（否则 580 这个数是拍的）',
      (tester) async {
    // 这条是上面两条的地基：如果哪天有人把 tvSidebarWidth 改小到跟桌面一样，
    // 上面那两条仍然会绿 —— 因为它们只断言「在自己算出来的宽度里没溢出」。
    expect(AppTheme.tvSidebarWidth, greaterThan(AppTheme.sidebarWidth));
    expect(
      tvPageWidth,
      960 - AppTheme.tvSafeHorizontal * 2 - AppTheme.tvSidebarWidth,
      reason: 'tvPageWidth 必须与真实链路算出来的一致，否则这几条测试'
          '测的是一个不存在的屏幕宽度',
    );
  });
}

/// 这个控件是不是落在某条**横向滚动列表**里。
///
/// 存在的唯一理由是分类胶囊：八个胶囊在 580 里排不下，`ListView` 会把排在
/// 后面的几个**布局到视口之外**（往右按才滚出来）。那是设计如此，
/// 不是「跑到区外看不见」—— 「每个控件都在可见区内」那条断言必须跳过它们，
/// 否则它会一直红，而界面完全正常。
bool inHorizontalScroll(Element element) {
  var hit = false;
  element.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Scrollable && w.axisDirection == AxisDirection.right) {
      hit = true;
      return false;
    }
    return true;
  });
  return hit;
}
