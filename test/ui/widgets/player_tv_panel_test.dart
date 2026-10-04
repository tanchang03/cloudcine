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
  /// 菜单的七行。几组用例共用一份 —— 各写一份的话，「加了一行却只改了其中
  /// 一处」会表现成「有一组用例在测一个六行的菜单」。
  ///
  /// ⚠️ 顺序与 `PlayerTvRow` 的枚举顺序一致（那份顺序**就是** ↑↓ 的遍历顺序，
  /// 也**就是**菜单上从上到下的顺序）。这里跟着改的时候别只改一处。
  ///
  /// ⚠️ 画质那一行的 `value` 故意写成「当前 超清」而不是「超清」：不然它和
  /// 选项条上那颗 chip 的字一模一样，`find.text('超清')` 会命中两个，
  /// 而按字找 chip 的那些断言（`chipScale`）会**随机**取到行值那一个。
  final rows = [
    const PlayerTvRowValue(
      row: PlayerTvRow.episode,
      value: '第 3 集',
      hint: '按 OK 打开选集',
    ),
    const PlayerTvRowValue(
      row: PlayerTvRow.quality,
      value: '当前 超清',
      options: [
        PlayerTvOption('原画'),
        // 夹在中间、灰掉的一档：服务端没给地址。
        // ⚠️ 特意放在**中间**而不是最后：放在最后的话「跳过它」和「撞到右墙
        // 停下」是同一个结果，那条断言就白写了。
        PlayerTvOption('4K', enabled: false),
        PlayerTvOption('超清'),
      ],
      selectedOption: 2,
    ),
    const PlayerTvRowValue(row: PlayerTvRow.subtitle, value: '关闭'),
    const PlayerTvRowValue(row: PlayerTvRow.audioTrack, value: '中文'),
    const PlayerTvRowValue(row: PlayerTvRow.audioEffect, value: '跟随片源'),
    const PlayerTvRowValue(row: PlayerTvRow.rate, value: '正常速度'),
    const PlayerTvRowValue(
      row: PlayerTvRow.intro,
      value: '未标记',
      adjustable: false,
      hint: '这部片没有片头标记',
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

  /// 选中（当前生效）的那一颗 chip 上的字。
  ///
  /// 认的是那颗**勾**，而不是底色：底色在 `AnimatedContainer` 的
  /// `decoration` 里、测试读不到，而「有勾」正是用户唯一能一眼认出的信号。
  String selectedChipLabel(WidgetTester tester) {
    final check = find.byIcon(Icons.check_rounded);
    expect(check, findsOneWidget, reason: '选项条上必须正好有一颗是「当前生效」');
    final row = find.ancestor(of: check, matching: find.byType(Row)).first;
    final text = find.descendant(of: row, matching: find.byType(Text)).first;
    return tester.widget<Text>(text).data!;
  }

  /// 光标所在那一颗 chip 的放大倍数（不是「当前生效」那一颗）。
  ///
  /// 要求 [label] 在整个树里只出现一次（见上面 `rows` 的注释）。
  double chipScale(WidgetTester tester, String label) {
    final finder = find.ancestor(
      of: find.text(label),
      matching: find.byType(AnimatedScale),
    );
    return tester.widget<AnimatedScale>(finder.first).scale;
  }

  /// 把菜单挂成**播放页里的样子**：整屏 `Stack`、贴底一条 `Positioned`。
  ///
  /// ⛔ 不要图省事写成 `SizedBox(height: 540, child: PlayerTvSheet(...))`：
  /// 那会给菜单一个**紧**约束，卡片会被拉满 540 高，于是「菜单有多高」
  /// 这类断言全都在测那个 `SizedBox`，而不是菜单自己。真机上的约束是松的
  /// （`Positioned(left:0, right:0, bottom:0)`），这里必须同形。
  Future<void> render(
    WidgetTester tester, {
    int selectedIndex = 0,
    List<PlayerTvRowValue>? rowList,
    List<int>? selected,
    void Function(PlayerTvRow, int)? onAdjust,
    void Function(PlayerTvRow, int)? onActivate,
    VoidCallback? onClose,
    VoidCallback? onActivity,
    List<LogicalKeyboardKey>? bubbled,
    FocusNode? focusNode,
  }) async {
    final list = rowList ?? rows;
    var index = selectedIndex;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          // 外层焦点节点不是摆设：遥控器的播放 / 暂停、快进、数字跳转都要从
          // 菜单这里冒泡出去才到得了播放器。菜单一旦把它们全吞掉，症状是
          // 「菜单一打开播放键就不灵了」—— 没有报错、没有提示、日志里也没有。
          body: Focus(
            onKeyEvent: (node, event) {
              // ⚠️ 只记 **KeyDown**。`sendKeyEvent` 会同时发按下与抬起，而
              // 菜单对抬起一律 `ignored`（它只处理 KeyDown / KeyRepeat，
              // 见 `TvSheetShell.onKeyEvent`）—— 把抬起也记进来的话，
              // 「方向键被菜单吃掉」这条断言会**因为抬起事件**而永远失败。
              if (event is KeyDownEvent) bubbled?.add(event.logicalKey);
              return KeyEventResult.ignored;
            },
            child: SizedBox(
              height: 540,
              child: StatefulBuilder(
                builder: (context, setState) => Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0xFF000000)),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: PlayerTvSheet(
                        focusNode: focusNode,
                        rows: list,
                        selectedIndex: index,
                        onSelectedChanged: (i) {
                          selected?.add(i);
                          setState(() => index = i);
                        },
                        onAdjust: onAdjust ?? (_, __) {},
                        onActivate: onActivate ?? (_, __) {},
                        onClose: onClose ?? () {},
                        onActivity: onActivity ?? () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 把测试视口设成电视（960×540）。`AppTheme.isTvLayout` 的两条判据里，
  /// 平台那条在 `flutter_test` 里**默认就是 android**，所以只要宽度够就行。
  void useTvView(WidgetTester tester) {
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1.0;
  }

  group('nextTvRowIndex', () {
    test('第一行按 ↑ 落到最后一行 —— 七行的列表循环比撞墙好用', () {
      // 这条是「取模方向写反」唯一的守卫：写成加完再 clamp 的话，边界那一下
      // 永远不动，而它既不报错也不崩溃，只有断言能钉住。
      expect(nextTvRowIndex(current: 0, delta: -1, total: 7), 6);
    });

    test('最后一行按 ↓ 回到第一行', () {
      expect(nextTvRowIndex(current: 6, delta: 1, total: 7), 0);
    });

    test('没有行时不越界（返回 0 而不是负数）', () {
      // 菜单刚打开、数据还没到的那一帧会走到这里。返回 -1 会让 `rows[-1]`
      // 直接抛 RangeError —— 而那是一条「用户什么都没做就崩」的路径。
      expect(nextTvRowIndex(current: 0, delta: -1, total: 0), 0);
    });

    test('delta 大于总数时仍然落在范围内', () {
      expect(nextTvRowIndex(current: 1, delta: 9, total: 7), 3);
    });
  });

  group('rateLabel', () {
    test('1.0 写「正常速度」而不是「1.0x」', () {
      // 用户找的是「怎么恢复原速」，写 1.0x 要他在心里先换算一次。
      expect(rateLabel(1.0), '正常速度');
      expect(rateLabel(1.5), '1.5x');
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

  // ⚠️ 这里曾经有一组 `audioLanguageLabel` 的用例（TV 菜单自带一张
  // 「chi → 中文」的表）。那张表已经删掉、改为调用 `TrackLabels`，用例也一并
  // 删掉而不是照抄一份 —— 照抄就等于把刚消灭掉的重复又搬进测试里，而且
  // `test/core/track_labels_test.dart` 覆盖得更全（含 `und`、空串、未知标记）。
  // 三处显示同一份文案这件事本身，靠的是「只有一处实现」，不是靠断言。

  group('PlayerTvSheet', () {
    testWidgets('测试数据必须覆盖 PlayerTvRow 的每一项', (tester) async {
      // 加一行枚举却忘了加进 `rows` 的话，下面那些「七行全部画出来」的用例
      // 会**照样全过**，而真机上少的那一行等于那个功能在电视上不存在。
      expect(rows.length, PlayerTvRow.values.length);
      expect(
        rows.map((r) => r.row).toList(),
        PlayerTvRow.values,
        reason: '顺序也要一致 —— 它就是 ↑↓ 的遍历顺序',
      );
    });

    testWidgets('七行全部画出来 —— 少一行就等于那个功能在电视上不存在',
        (tester) async {
      await render(tester);

      for (final row in PlayerTvRow.values) {
        expect(find.text(row.label), findsOneWidget, reason: row.label);
      }
      // 当前值也要看得见：只有标签没有值的话，用户要按一下才知道现在是什么。
      expect(find.text('第 3 集'), findsOneWidget);
      expect(find.text('当前 超清'), findsOneWidget);
    });

    testWidgets('没有可选项的那一行写「—」而不是留空', (tester) async {
      await render(
        tester,
        rowList: const [PlayerTvRowValue(row: PlayerTvRow.subtitle, value: '')],
      );

      // 空串会让那一行的值区域整块塌掉，看起来像「这一行画错了」；
      // 「—」则明确表示「这一项现在没有值」。
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('选中行下面铺开全部选项 —— 这是「照夸克做」的核心', (tester) async {
      await render(tester, selectedIndex: 1); // 画质

      // 三档全部看得见，包括不可用的那一档（灰掉但保留，见 PlayerTvOption）。
      expect(find.text('原画'), findsOneWidget);
      expect(find.text('4K'), findsOneWidget);
      expect(find.text('超清'), findsOneWidget);
      expect(selectedChipLabel(tester), '超清',
          reason: '带勾的必须是**当前生效**的那一档');
      expect(chipScale(tester, '超清'), 1.05,
          reason: '光标默认落在当前生效的那一档上');

      // 没选中的行不该铺选项条：七行全铺开的话菜单会长到屏幕外面去。
      await render(tester, selectedIndex: 2); // 字幕（没有选项）
      expect(find.text('原画'), findsNothing);
    });

    testWidgets('没有选项的行，那一格写「按 OK 会怎样」而不是空着', (tester) async {
      await render(tester, selectedIndex: 0);
      expect(find.text('按 OK 打开选集'), findsOneWidget);

      // ⚠️ 选项条那一格的高度与有没有选项**无关**：变高变矮的话，焦点上下走
      // 的时候整块菜单会跟着跳。所以这一条也顺带钉住「那一格确实占着位」。
      await render(tester, selectedIndex: 6); // 片头
      expect(find.text('这部片没有片头标记'), findsOneWidget);
    });

    testWidgets('菜单不铺满整屏 —— 换字幕时必须看得见画面', (tester) async {
      useTvView(tester);
      await render(tester);

      final sheet = tester.getRect(find.byType(TvSheetCard));

      // ⚠️ 这条守的是**高度预算**，不是「好看」。菜单是贴底的一整块，
      // 它越高，留给画面的那一条越窄 —— 而「换字幕 / 换画质时看得见画面」
      // 是这两项设置**唯一**的反馈。
      //
      // 360 这个上限来自设计稿：960×540 上菜单高 346.8、再避让 27 的过扫描带，
      // 画面还剩约 166。加一行（40）就会顶破它 —— 那时必须同时想清楚
      // 「少哪一行」或者「画面还看不看得见」，而不是把数字改大。
      expect(
        sheet.height,
        lessThanOrEqualTo(360),
        reason: '菜单长到 ${sheet.height} 了 —— 画面只剩 '
            '${540 - sheet.height - 27}px，换字幕时等于看不见字幕',
      );
      expect(sheet.height, kPlayerTvSheetHeight);
      expect(sheet.width, greaterThan(480),
          reason: '底部菜单是**横**排的（照夸克）—— 七行纵向挤在 400 宽里的话，'
              '每一行的可用宽度会窄到放不下「简体中文（强制）」这种值');
    });

    testWidgets('贴底，且内容让开电视的过扫描带', (tester) async {
      useTvView(tester);
      await render(tester);

      final card = tester.getRect(find.byType(TvSheetCard));
      expect(
        card.bottom,
        lessThanOrEqualTo(540 - AppTheme.tvSafeVertical + 0.5),
        reason: '菜单的下缘进了电视最下 ${AppTheme.tvSafeVertical}px 的过扫描带 '
            '—— 那一截在真机上是看不见的（卡片下面的圆角会被切平）',
      );
      expect(
        card.width,
        lessThanOrEqualTo(960 - AppTheme.tvSafeHorizontal * 2 + 0.5),
        reason: '左右也要避让 —— 行值右边那个箭头会探进最右 48px 的过扫描带',
      );
    });

    testWidgets('七行 + 选项条刚好装得下 —— 溢出 0.8px 也是溢出', (tester) async {
      useTvView(tester);
      // 只要渲染成功就说明没溢出：`RenderFlex` 溢出在测试里会抛断言。
      // ⚠️ 这条是被真事写出来的：`Container` 会把 `decoration` 上那条描边
      // 算成内容的内边距，于是内容实得高度比 `height` 少 0.8px ——
      // 当时行高刚从 46 收到 40，差这 0.8 就溢出，肉眼完全看不出来。
      await render(tester);
      expect(tester.takeException(), isNull);
    });
  });

  // ------------------------------------------------------------------
  // 按键语义
  //
  // 这一段才是「照夸克做 XY 轴导航」这条需求的**核心**：↑↓ 换行、←→ 在
  // 选中那一行的选项条里走、OK 应用。它出错的方式全是静默的 —— 少认一个键，
  // 用户按下去没反应，唯一的结论是「遥控器坏了」或「这应用卡了」。
  // 所以每一条都值得钉住。
  // ------------------------------------------------------------------
  group('PlayerTvSheet 按键', () {
    late List<int> selected;
    late List<(PlayerTvRow, int)> adjusted;
    late List<(PlayerTvRow, int)> activated;
    late int closed;
    late int activity;
    late List<LogicalKeyboardKey> bubbled;

    setUp(() {
      selected = [];
      adjusted = [];
      activated = [];
      closed = 0;
      activity = 0;
      bubbled = [];
    });

    Future<void> renderKeys(WidgetTester tester, {int selectedIndex = 0}) =>
        render(
          tester,
          selectedIndex: selectedIndex,
          selected: selected,
          onAdjust: (row, delta) => adjusted.add((row, delta)),
          onActivate: (row, i) => activated.add((row, i)),
          onClose: () => closed++,
          onActivity: () => activity++,
          bubbled: bubbled,
        );

    FontWeight? weightOf(WidgetTester tester, String label) =>
        tester.widget<Text>(find.text(label)).style?.fontWeight;

    testWidgets('↓ 落到下一行，且选中态**移走**（不能两行同时亮着）',
        (tester) async {
      await renderKeys(tester);
      expect(weightOf(tester, '选集'), FontWeight.w600,
          reason: '初始那一行要有可见的强调，否则用户不知道焦点在哪');

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(selected, [1]);
      expect(weightOf(tester, '画质'), FontWeight.w600);
      expect(weightOf(tester, '选集'), FontWeight.w400,
          reason: '选中态必须移走。两行同时亮着等于没有焦点 —— 在电视上'
              '用户只能靠这一条底色和字重判断「我按下去会改哪一项」');
    });

    testWidgets('↑ 从第一行绕到最后一行（短列表循环比撞墙好用）', (tester) async {
      await renderKeys(tester);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(selected, [rows.length - 1]);
    });

    testWidgets('← / → 只在**选中那一行**的选项条里挪，不报 onAdjust',
        (tester) async {
      await renderKeys(tester, selectedIndex: 1); // 画质，生效「超清」(2)

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(chipScale(tester, '超清'), 1.05,
          reason: '「超清」已经是最右一颗，撞到右墙就停、不绕回第一颗'
              '（选项条是看得见的一排，绕回去会让人觉得光标「跳」了）');

      await press(tester, LogicalKeyboardKey.arrowLeft); // 2 → 跳过 4K → 0
      expect(chipScale(tester, '原画'), 1.05);
      expect(chipScale(tester, '超清'), 1,
          reason: '光标只能有一个 —— 旧那颗必须复原');

      await press(tester, LogicalKeyboardKey.arrowLeft); // 0 已是第一颗
      expect(chipScale(tester, '原画'), 1.05, reason: '左墙同理');

      expect(adjusted, isEmpty,
          reason: '挪光标**不等于**换档 —— 每挪一格就重取一次流的话，'
              '用户连按 → 想看看有哪些档，会连取五次');
    });

    testWidgets('← / → 跳过灰掉的那一档', (tester) async {
      await renderKeys(tester, selectedIndex: 1); // 原画 / 4K(灰) / 超清
      await press(tester, LogicalKeyboardKey.arrowLeft);

      expect(chipScale(tester, '原画'), 1.05);
      expect(chipScale(tester, '4K'), 1,
          reason: '4K 不可用（服务端没给地址），光标不该停在它上面 —— '
              '停在上面的话用户得按一下 OK 才知道那一档不能用');
    });

    testWidgets('没有选项条的行，← / → 交给 onAdjust（选集靠它换集）',
        (tester) async {
      await renderKeys(tester); // 第 0 行是「选集」
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);

      expect(adjusted, [
        (PlayerTvRow.episode, 1),
        (PlayerTvRow.episode, -1),
      ], reason: '若恒定作用于别的行，用户会看到「我在选集，字幕却变了」');
    });

    testWidgets('OK 认的是 `select`（安卓电视的确定键），不是回车', (tester) async {
      await renderKeys(tester);
      await press(tester, LogicalKeyboardKey.select);

      expect(activated, [(PlayerTvRow.episode, -1)],
          reason: 'Android TV 的确定键是 KEYCODE_DPAD_CENTER → `select`，'
              '**不是** `enter` 也不是空格。只认 `enter` 的话真机上每个遥控器的'
              '确定键都会失灵 —— 而插着 USB 键盘的开发机按回车是好的。'
              '「选集」没有选项条，所以 optionIndex 是 -1（它进二级页）');
    });

    testWidgets('OK 交出去的是**光标那一颗**的下标，不是当前生效那一颗',
        (tester) async {
      await renderKeys(tester, selectedIndex: 1); // 画质，生效的是「超清」(2)
      await press(tester, LogicalKeyboardKey.arrowLeft); // 光标 → 原画 (0)
      await press(tester, LogicalKeyboardKey.select);

      expect(activated, [(PlayerTvRow.quality, 0)],
          reason: '交错了的话，用户挪到「原画」再按 OK 会什么都没发生'
              '（因为生效的本来就是超清）—— 而这一下看起来完全正常');
    });

    testWidgets('菜单键与 Esc 都能收起菜单', (tester) async {
      await renderKeys(tester);
      await press(tester, LogicalKeyboardKey.contextMenu);
      expect(closed, 1,
          reason: '菜单键 = KEYCODE_MENU(82) → `contextMenu`，'
              '这是这条需求点名要用的键');

      await press(tester, LogicalKeyboardKey.escape);
      expect(closed, 2,
          reason: 'Esc 在真机上不一定有（安卓的返回走 Activity），'
              '但插了 USB 键盘的电视上它是用户第一个会试的键');
    });

    testWidgets('放行数字键与媒体键 —— 菜单开着时播放 / 快进还要能用',
        (tester) async {
      await renderKeys(tester);
      await press(tester, LogicalKeyboardKey.digit5);
      await press(tester, LogicalKeyboardKey.mediaPlayPause);

      expect(bubbled, contains(LogicalKeyboardKey.digit5));
      expect(bubbled, contains(LogicalKeyboardKey.mediaPlayPause));
      expect(selected, isEmpty);
      expect(adjusted, isEmpty);
      expect(activated, isEmpty);
      expect(closed, 0,
          reason: '菜单若把媒体键也吞掉，用户会得到「菜单一打开播放键就不灵了」，'
              '而这件事没有任何日志能查');
    });

    testWidgets('方向键**不**放行 —— 否则按 ↓ 会同时被画面拿去快退',
        (tester) async {
      await renderKeys(tester);
      bubbled.clear();
      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(bubbled, isEmpty);
      expect(selected, [1], reason: '方向键被吃掉，才说明它真的作用在菜单上');
    });

    testWidgets('每一次按键都报「有操作」，连被放行的键也算', (tester) async {
      await renderKeys(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.digit5);

      expect(activity, 2,
          reason: '外层有个「无操作 30 秒收起控制栏」的倒计时。菜单吃掉按键却'
              '不报活动，倒计时会当着正在调字幕的用户把菜单收掉');
    });

    testWidgets('换行之后光标回到**新那一行**生效的档上', (tester) async {
      // ⚠️ 不重置的话，从「倍速」第 4 档按 ↑ 到「画质」会落在画质的第 4 档上
      // —— 而画质只有 3 档，`options[3]` 直接抛 RangeError。
      await renderKeys(tester, selectedIndex: 5); // 倍速（六档）
      await press(tester, LogicalKeyboardKey.arrowRight); // 光标挪到第 3 档

      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowUp); // 回到「画质」
      }

      expect(chipScale(tester, '超清'), 1.05,
          reason: '光标该落在画质当前生效的那一档上，而不是上一行留下的位置');
    });
  });

  group('PlayerTvEpisodeGrid 按键', () {
    Future<void> renderGrid(
      WidgetTester tester, {
      required void Function(int) onPick,
      int count = 12,
      int currentIndex = 2,
      VoidCallback? onClose,
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
                onClose: onClose ?? () {},
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
      await renderGrid(tester, onPick: picked.add);

      await tester.tap(find.text('3'));
      expect(picked, [2],
          reason: '集号是从文件名解析出来的，混了花絮 / 预告的目录里'
              '「格子上的字」与「第几个」并不相等 —— 交错了会跳到别的片子上');
    });

    testWidgets('遥控器 OK 能激活聚焦的那一格（不用鼠标）', (tester) async {
      final picked = <int>[];
      await renderGrid(tester, onPick: picked.add);

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

    testWidgets('菜单键在这里是「回行菜单」，不是关掉整个菜单', (tester) async {
      var back = 0;
      await renderGrid(tester, onPick: (_) {}, onClose: () => back++);

      expect(find.text('选集（12）'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.contextMenu);

      expect(back, 1,
          reason: '二级页的返回必须先于关闭发生。做反了的话，用户想退回上一层'
              '却整个菜单没了（还得重新按菜单键唤出）—— 而这两件事都「有反应」，'
              '所以不报错、只是难用');
    });
  });

  // ------------------------------------------------------------------
  // ⚠️ 「菜单键能弹出 OSD，但上下键按不动」—— 这条反馈的回归守卫
  //
  // 根因不在菜单内部（它的按键映射一直是对的），而在**焦点归属**：菜单里那个
  // `Focus(autofocus: true)` 在「所在 scope 已经有焦点」时是**空操作**，而播放页
  // 的画面节点（`_stageNode`）早就把焦点占住了。于是菜单画出来了、看着一切正常，
  // 但一个按键都收不到 —— 没有报错、没有日志，只有用户觉得遥控器坏了。
  //
  // 修法是播放页在打开菜单后显式 `requestFocus` 到菜单自己的节点上（菜单必须
  // 收下这个节点，不能自建）。这一段把这两半都钉住。
  // ------------------------------------------------------------------
  group('⚠️ 焦点归属（「菜单键能弹出、上下键按不动」的根因）', () {
    testWidgets('菜单自己挂 autofocus 收不到按键 —— 画面已经占着焦点', (tester) async {
      final stageNode = FocusNode(debugLabel: 'test-stage');
      final menuNode = FocusNode(debugLabel: 'test-menu');
      addTearDown(stageNode.dispose);
      addTearDown(menuNode.dispose);

      final selected = <int>[];
      var opened = false;
      late StateSetter rebuild;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: SizedBox(
              height: 540,
              child: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return Stack(
                    children: [
                      // 「画面」——播放页里它 `autofocus: true`，先拿到焦点。
                      Positioned.fill(
                        child: Focus(
                          focusNode: stageNode,
                          autofocus: true,
                          child: const ColoredBox(color: Color(0xFF000000)),
                        ),
                      ),
                      if (opened)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: PlayerTvSheet(
                            focusNode: menuNode,
                            rows: rows,
                            selectedIndex: 0,
                            onSelectedChanged: selected.add,
                            onAdjust: (_, __) {},
                            onActivate: (_, __) {},
                            onClose: () {},
                            onActivity: () {},
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(stageNode.hasPrimaryFocus, isTrue, reason: '前提：画面先占住焦点');

      // 「按菜单键打开菜单」。
      rebuild(() => opened = true);
      await tester.pump();
      expect(
        menuNode.hasPrimaryFocus,
        isFalse,
        reason: '`autofocus` 只在所在 scope **还没有焦点**时才生效 —— 这里已经有'
            '（画面节点），所以它是空操作。菜单必须由调用方显式 requestFocus。',
      );

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        selected,
        isEmpty,
        reason: '⚠️ 这就是用户报的那条：「点击遥控器菜单按钮可以弹出 osd 菜单，'
            '但是上下按钮按不动」。菜单看得见、却一个键都收不到。',
      );

      // 播放页的补救（`_PlayerPageState._openTvPanel` 里的 requestFocus）。
      menuNode.requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(
        selected,
        [1],
        reason: '焦点显式交给菜单之后，↑↓ 才真的作用在它上面',
      );
    });

    testWidgets('菜单真的挂在调用方给的节点上 —— 否则 requestFocus 是打空靶',
        (tester) async {
      // 这条守的是另一半：`TvSheetShell` 必须把外部节点交给自己的 `Focus`。
      // 少了这一步，播放页 requestFocus 到一个**没人用**的节点上 —— 表现与
      // 上面那条一模一样（菜单收不到按键），但改起来完全是另一处代码。
      final node = FocusNode(debugLabel: 'page-owned');
      addTearDown(node.dispose);

      await render(tester, focusNode: node);
      await tester.pump();

      expect(
        node.hasPrimaryFocus,
        isTrue,
        reason: '菜单没有真的挂在调用方给的节点上 —— 播放页的 requestFocus '
            '打在了空靶子上，遥控器按下去还是没反应',
      );
    });
  });
}
