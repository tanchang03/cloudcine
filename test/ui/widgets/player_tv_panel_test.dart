import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/player_tv_overlay.dart';
import 'package:cloudcine/ui/widgets/player_tv_panel.dart';

MediaItem _item({int? episode, String? partLabel}) => MediaItem(
      provider: DriveProvider.quark,
      fileId: 'f1',
      name: 'A.S01E01.mkv',
      dirId: 'd1',
      dirPath: '/剧集/A/',
      groupKey: 'A',
      kind: MediaKind.episode,
      title: 'A',
      episode: episode,
      partLabel: partLabel,
      firstSeenAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  /// 面板的七行。两组用例共用一份 —— 各写一份的话，「加了一行却只改了其中
  /// 一处」会表现成「有一组用例在测一个六行的面板」。
  final rows = [
    const PlayerTvRowValue(row: PlayerTvRow.episode, value: '第 3 集'),
    const PlayerTvRowValue(row: PlayerTvRow.quality, value: '原画'),
    const PlayerTvRowValue(row: PlayerTvRow.subtitle, value: '关闭'),
    const PlayerTvRowValue(row: PlayerTvRow.audioTrack, value: '中文'),
    const PlayerTvRowValue(row: PlayerTvRow.audioEffect, value: '跟随片源'),
    const PlayerTvRowValue(row: PlayerTvRow.rate, value: '正常速度'),
    const PlayerTvRowValue(
      row: PlayerTvRow.intro,
      value: '未标记',
      adjustable: false,
    ),
  ];

  /// 发一个键，**并让重建落地**。
  ///
  /// ⚠️ `tester.sendKeyEvent` 只把事件派发下去，**不会 pump**。少了这一步，
  /// `onSelectedChanged` 里的 `setState` 不会反映到下一帧 —— 于是
  /// 「↓ 之后 ←→ 该作用在第二行」这类断言看到的还是第一行，测试会因为
  /// **测试自己没刷新**而红，而不是因为代码错了。
  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  group('nextTvRowIndex', () {
    test('第一行按 ↑ 落到最后一行 —— 六行的列表循环比撞墙好用', () {
      // 这条是「取模方向写反」唯一的守卫：写成加完再 clamp 的话，边界那一下
      // 永远不动，而它既不报错也不崩溃，只有断言能钉住。
      expect(nextTvRowIndex(current: 0, delta: -1, total: 6), 5);
    });

    test('最后一行按 ↓ 回到第一行', () {
      expect(nextTvRowIndex(current: 5, delta: 1, total: 6), 0);
    });

    test('没有行时不越界（返回 0 而不是负数）', () {
      // 面板刚打开、数据还没到的那一帧会走到这里。返回 -1 会让 `rows[-1]`
      // 直接抛 RangeError —— 而那是一条「用户什么都没做就崩」的路径。
      expect(nextTvRowIndex(current: 0, delta: -1, total: 0), 0);
    });

    test('delta 大于总数时仍然落在范围内', () {
      expect(nextTvRowIndex(current: 1, delta: 9, total: 6), 4);
    });
  });

  group('episodeCellLabel', () {
    test('有集号时显示集号，而不是它在列表里的下标', () {
      // 网盘目录里常混着花絮 / 预告（它们也在 `itemsForWork` 的返回值里），
      // 用下标会把用户带去一个不是正片的格子。
      expect(episodeCellLabel(_item(episode: 7), 0), '7');
    });

    test('没有集号时用「部」的标签（电影的上下部靠它区分）', () {
      expect(episodeCellLabel(_item(partLabel: '下部'), 3), '下部');
    });

    test('两者都没有才退回下标（+1，不给人看 0）', () {
      expect(episodeCellLabel(_item(), 3), '4');
    });
  });

  // ⚠️ 这里曾经有一组 `audioLanguageLabel` 的用例（TV 面板自带一张
  // 「chi → 中文」的表）。那张表已经删掉、改为调用 `TrackLabels`，用例也一并
  // 删掉而不是照抄一份 —— 照抄就等于把刚消灭掉的重复又搬进测试里，而且
  // `test/core/track_labels_test.dart` 覆盖得更全（含 `und`、空串、未知标记）。
  // 三处显示同一份文案这件事本身，靠的是「只有一处实现」，不是靠断言。

  group('PlayerTvPanel', () {
    Future<void> render(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              body: SizedBox(
                height: 540,
                child: PlayerTvPanel(
                  rows: rows,
                  selectedIndex: 0,
                  onSelectedChanged: (_) {},
                  onAdjust: (_, __) {},
                  onActivate: (_) {},
                  onClose: () {},
                  onActivity: () {},
                ),
              ),
            ),
          ),
        );

    testWidgets('七行全部画出来 —— 少一行就等于那个功能在电视上不存在',
        (tester) async {
      await render(tester);

      for (final row in PlayerTvRow.values) {
        expect(find.text(row.label), findsOneWidget, reason: row.label);
      }
      // 当前值也要看得见：只有标签没有值的话，用户要按一下才知道现在是什么。
      expect(find.text('第 3 集'), findsOneWidget);
      expect(find.text('原画'), findsOneWidget);
    });

    testWidgets('没有可选项的那一行写「—」而不是留空', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              height: 540,
              child: PlayerTvPanel(
                rows: const [
                  PlayerTvRowValue(row: PlayerTvRow.subtitle, value: ''),
                ],
                selectedIndex: 0,
                onSelectedChanged: (_) {},
                onAdjust: (_, __) {},
                onActivate: (_) {},
                onClose: () {},
                onActivity: () {},
              ),
            ),
          ),
        ),
      );

      // 空串会让那一行的值区域整块塌掉，看起来像「这一行画错了」；
      // 「—」则明确表示「这一项现在没有值」。
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('面板不铺满整屏 —— 调字幕时必须看得见画面', (tester) async {
      // 给一个 TV 逻辑屏（官方设计稿 960×540）再量面板宽度。
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      await render(tester);

      // 盖住整屏的话，用户换字幕时看不到字幕、换画质时看不出清不清楚 ——
      // 而那正是这两项设置**唯一的反馈**。
      expect(tester.getSize(find.byType(PlayerTvPanel)).width, lessThan(480));
    });

    testWidgets('面板内容要让开电视的过扫描带 —— 不让的话最右那个箭头会探进去',
        (tester) async {
      // 真机上这块面板是 `Positioned(top: 0, right: 0, bottom: 0)`：贴右、贴满高。
      // 而电视会把屏幕最右 48px 裁掉。
      //
      // ⚠️ **这条用例守的是「擦线」，不是「字被切掉」**：实测不避让时行内最右
      // 那个箭头在 x=914.25，安全线 912 —— 只探进去约 2px，行值本身还有余量。
      // 之所以照样钉住：这点余量随面板宽度 / 行内边距一变就会变成真切，
      // 而「探进去多少」是纯几何、只有断言看得出来。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        addTearDown(tester.view.reset);
        tester.view.physicalSize = const Size(960, 540);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: Scaffold(
              // 贴右 —— 与播放页里的 `Positioned(right: 0)` 同形。
              body: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  height: 540,
                  child: PlayerTvPanel(
                    rows: rows,
                    selectedIndex: 0,
                    onSelectedChanged: (_) {},
                    onAdjust: (_, __) {},
                    onActivate: (_) {},
                    onClose: () {},
                    onActivity: () {},
                  ),
                ),
              ),
            ),
          ),
        );

        // 面板**外框**仍然要贴到屏幕右缘：贴右是这个面板的设计（不铺满整屏、
        // 让画面留在左边）。避让只该发生在内容上，不该把整块面板推进来 ——
        // 推起来会在右边留一条露出视频的缝，看着像没对齐。
        expect(
          tester.getRect(find.byType(PlayerTvPanel)).right,
          moreOrLessEquals(960, epsilon: 0.5),
          reason: '面板外框没贴在屏幕右缘 —— 避让做成了「挪面板」，'
              '右边会留一条缝。',
        );

        // 每行最右边那个箭头是行内最右的控件，它的右缘就是「内容右缘」。
        final chevron =
            tester.getRect(find.byIcon(Icons.chevron_right_rounded).first);
        expect(
          chevron.right,
          lessThanOrEqualTo(960 - AppTheme.tvSafeHorizontal + 0.5),
          reason: '内容右缘到了 ${chevron.right}，已经进了电视最右 '
              '${AppTheme.tvSafeHorizontal}px 的过扫描带 —— 那一截在真机上是看不见的。',
        );

        // ⛔ 这条守的是**面板的高度预算**：面板是按「7 行正好塞满」做的 ——
        // 表头 56 + 分隔线 0.5 + 底部提示 60（那行会折成两行）+ 7×60 = 536.5，
        // 而面板只有 540 高 → 只剩 **3.5px** 余量。
        // 装不下的后果是最后一行「片头」要滚动才看得见，而**电视上没有滚动条**，
        // 用户根本不会知道下面还有一行。
        // ⚠️ 实测来历：给面板加上下各 27 的过扫描内边距 → 立刻溢出 50.5px。
        // 这条断言正是被那次改动「写出来」的，也是它把那次改动挡了下来。
        // 判据用 `maxScrollExtent == 0`：比量某一行的高度稳，也不受
        // `ListView` 的 `cacheExtent`（会预建屏幕外的行）干扰。
        final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
        expect(
          scrollable.position.maxScrollExtent,
          0,
          reason: '设置列表能滚动了（超出 '
              '${scrollable.position.maxScrollExtent}px）—— 第 7 行「片头」'
              '会被推到屏幕外，而电视上没有滚动条，用户不会知道下面还有一行。'
              '查行高（`Container(height: 60)`）/ 表头内边距是不是变大了',
        );
      } finally {
        // ⛔ 复位必须写在**测试体里**：`tearDown` / `addTearDown` 都排在
        // Flutter 的 `_verifyInvariants` 之后，会报「debug variable was changed」。
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  // ------------------------------------------------------------------
  // 按键语义
  //
  // 这一段才是「取消焦点按钮菜单」这条需求的**核心**：遥控器的键要作用在
  // 「行」上，而不是让用户把焦点一个个挪到按钮上再按 OK。它出错的方式全是
  // 静默的 —— 少认一个键，用户按下去没反应，唯一的结论是「遥控器坏了」或
  // 「这应用卡了」。所以每一条都值得钉住。
  // ------------------------------------------------------------------
  group('PlayerTvPanel 按键', () {
    late List<int> selected;
    late List<(PlayerTvRow, int)> adjusted;
    late List<PlayerTvRow> activated;
    late int closed;
    late int activity;

    /// 被面板**放行**（冒泡出去）的键。
    late List<LogicalKeyboardKey> bubbled;

    setUp(() {
      selected = [];
      adjusted = [];
      activated = [];
      closed = 0;
      activity = 0;
      bubbled = [];
    });

    /// 渲染面板，并在**外面**套一个焦点节点接住被放行的键。
    ///
    /// 外层节点不是摆设：遥控器的播放 / 暂停、快进、数字跳转都要从面板这里
    /// 冒泡出去才到得了播放器。面板一旦把它们全吞掉，症状是「面板一打开，
    /// 播放键就不灵了」—— 没有报错、没有提示、日志里也没有。
    Future<void> render(WidgetTester tester, {int selectedIndex = 0}) async {
      var index = selectedIndex;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Focus(
              onKeyEvent: (node, event) {
                // ⚠️ 只记 **KeyDown**。`sendKeyEvent` 会同时发按下与抬起，而
                // 面板对抬起一律 `ignored`（它只处理 KeyDown / KeyRepeat，
                // 见 `TvPanelShell.onKeyEvent`）—— 把抬起也记进来的话，
                // 「方向键被面板吃掉」这条断言会**因为抬起事件**而永远失败，
                // 看起来像「方向键漏出去了」，其实漏出去的只是抬起。
                if (event is KeyDownEvent) bubbled.add(event.logicalKey);
                return KeyEventResult.ignored;
              },
              child: SizedBox(
                height: 540,
                child: StatefulBuilder(
                  builder: (context, setState) => PlayerTvPanel(
                    rows: rows,
                    selectedIndex: index,
                    onSelectedChanged: (i) {
                      selected.add(i);
                      setState(() => index = i);
                    },
                    onAdjust: (row, delta) => adjusted.add((row, delta)),
                    onActivate: activated.add,
                    onClose: () => closed++,
                    onActivity: () => activity++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    FontWeight? weightOf(WidgetTester tester, String label) =>
        tester.widget<Text>(find.text(label)).style?.fontWeight;

    testWidgets('↓ 落到下一行，且选中态**移走**（不能两行同时亮着）',
        (tester) async {
      await render(tester);
      expect(weightOf(tester, '选集'), FontWeight.w600,
          reason: '初始那一行要有可见的强调，否则用户不知道焦点在哪');

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(selected, [1]);
      expect(weightOf(tester, '画质'), FontWeight.w600);
      expect(weightOf(tester, '选集'), FontWeight.w400,
          reason: '选中态必须移走。两行同时亮着等于没有焦点 —— 在电视上'
              '用户只能靠这一条竖线和字重判断「我按下去会改哪一项」');
    });

    testWidgets('↑ 从第一行绕到最后一行（六行列表循环比撞墙好用）', (tester) async {
      await render(tester);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(selected, [rows.length - 1]);
    });

    testWidgets('← / → 改的是**选中那一行**，不是第一行', (tester) async {
      await render(tester);
      await press(tester, LogicalKeyboardKey.arrowDown); // 落到「画质」
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);

      expect(adjusted, [
        (PlayerTvRow.quality, 1),
        (PlayerTvRow.quality, -1),
      ], reason: '若恒定作用于第 0 行，用户会看到「我在调画质，字幕却变了」');
    });

    testWidgets('OK 认的是 `select`（安卓电视的确定键），不是回车', (tester) async {
      await render(tester);
      await press(tester, LogicalKeyboardKey.select);
      expect(activated, [PlayerTvRow.episode],
          reason: 'Android TV 的确定键是 KEYCODE_DPAD_CENTER → `select`，'
              '**不是** `enter` 也不是空格。只认 `enter` 的话真机上每个遥控器的'
              '确定键都会失灵 —— 而插着 USB 键盘的开发机按回车是好的');
    });

    testWidgets('菜单键与 Esc 都能收起面板', (tester) async {
      await render(tester);
      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(closed, 1,
          reason: '菜单键 = KEYCODE_MENU(82) → `contextMenu`，'
              '这是这条需求点名要用的键');

      await press(tester, LogicalKeyboardKey.escape);
      expect(closed, 2,
          reason: 'Esc 在真机上不一定有（安卓的返回走 Activity），'
              '但插了 USB 键盘的电视上它是用户第一个会试的键');
    });

    testWidgets('放行数字键与媒体键 —— 面板开着时播放 / 快进还要能用',
        (tester) async {
      await render(tester);
      await press(tester, LogicalKeyboardKey.digit5);
      await press(tester, LogicalKeyboardKey.mediaPlayPause);

      expect(bubbled, contains(LogicalKeyboardKey.digit5));
      expect(bubbled, contains(LogicalKeyboardKey.mediaPlayPause));
      expect(selected, isEmpty);
      expect(adjusted, isEmpty);
      expect(activated, isEmpty);
      expect(closed, 0,
          reason: '面板若把媒体键也吞掉，用户会得到「面板一打开播放键就不灵了」，'
              '而这件事没有任何日志能查');
    });

    testWidgets('方向键**不**放行 —— 否则按 ↓ 会同时被画面拿去快退',
        (tester) async {
      await render(tester);
      bubbled.clear();
      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(bubbled, isEmpty);
      expect(selected, [1], reason: '方向键被吃掉，才说明它真的作用在面板上');
    });

    testWidgets('每一次按键都报「有操作」，连被放行的键也算', (tester) async {
      await render(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.digit5);

      expect(activity, 2,
          reason: '外层有个「无操作 30 秒收起控制栏」的倒计时。面板吃掉按键却'
              '不报活动，倒计时会当着正在调字幕的用户把面板收掉');
    });
  });

  group('PlayerTvEpisodeGrid 按键', () {
    Future<void> render(
      WidgetTester tester, {
      required void Function(int) onPick,
      int count = 12,
      int currentIndex = 2,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              height: 540,
              child: PlayerTvEpisodeGrid(
                count: count,
                currentIndex: currentIndex,
                labelOf: (i) => '${i + 1}',
                onPick: onPick,
                onClose: () {},
                onActivity: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('点一格交出去的是**下标**，不是格子上的文字', (tester) async {
      final picked = <int>[];
      await render(tester, onPick: picked.add);

      await tester.tap(find.text('3'));
      expect(picked, [2],
          reason: '集号是从文件名解析出来的，混了花絮 / 预告的目录里'
              '「格子上的字」与「第几个」并不相等 —— 交错了会跳到别的片子上');
    });

    testWidgets('遥控器 OK 能激活聚焦的那一格（不用鼠标）', (tester) async {
      final picked = <int>[];
      await render(tester, onPick: picked.add);

      // 真机上是 D-pad 走到某一格；测试里用 Tab 走焦点遍历 ——
      // 两者最终都落到同一个 Focusable 上。
      await press(tester, LogicalKeyboardKey.tab);
      await press(tester, LogicalKeyboardKey.select);

      expect(picked, isNotEmpty,
          reason: '格子是 `InkWell`，`select` → `ActivateIntent` → `onTap` '
              '这条路依赖 Flutter 默认的 `WidgetsApp` 快捷键表。'
              '它一旦不成立，电视上「按 OK 选一集」就是死的 —— '
              '而鼠标点得动，所以模拟器上完全看不出来');
    });

    testWidgets('菜单键在这里是「回行列表」，不是关掉整个面板', (tester) async {
      var back = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              height: 540,
              child: PlayerTvEpisodeGrid(
                count: 12,
                currentIndex: 2,
                labelOf: (i) => '${i + 1}',
                onPick: (_) {},
                onClose: () => back++,
                onActivity: () {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('选集（12）'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.contextMenu);

      expect(back, 1,
          reason: '二级页的返回必须先于关闭发生。做反了的话，用户想退回上一层'
              '却整个面板没了（还得重新按菜单键唤出）—— 而这两件事都「有反应」，'
              '所以不报错、只是难用');
    });
  });
}
