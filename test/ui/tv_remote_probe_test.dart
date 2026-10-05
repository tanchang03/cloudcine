import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android TV 遥控器行为探针。
///
/// 目的不是「测业务」，而是把几条**只能靠实测回答**的遥控器行为钉下来，
/// 因为 Android TV 的适配方案完全取决于它们：
///
///   1. 方向键（D-pad）能不能走进 `GridView.builder` 懒加载出来的深处 ——
///      海报墙只有视口附近那几行有 `FocusNode`，若走不过去，
///      「遥控器翻不到第二屏」就不是猜测而是事实；
///   2. **OK 键（`KEYCODE_DPAD_CENTER` → `LogicalKeyboardKey.select`）
///      能不能激活 `InkWell`** —— 这是「点一下能不能进详情/能不能播」的根；
///   3. `CallbackShortcuts` 只绑了 `space` 时，`select` 会不会也命中 ——
///      播放页的「OK 键暂停」全押在这一条上。
///
/// ⚠️ `flutter test` 下 `defaultTargetPlatform` 是 `android`，
/// 所以 `tester.sendKeyEvent` 走的是**真实的 Android 键码表**
/// （见 `keyboard_maps.g.dart`：23 → `select`，20 → `arrowDown`）。
/// 这正是我们要的：探针测的是 Android 那条路，不是 macOS 那条。
void main() {
  testWidgets('方向键在懒加载 GridView 里能走多远（海报墙可导航性）', (tester) async {
    const count = 60;
    final nodes = List<FocusNode>.generate(count, (i) => FocusNode(debugLabel: 'item$i'));
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            // 刻意做小：视口只放得下 1~2 行，其余全靠懒加载。
            child: SizedBox(
              width: 800,
              height: 300,
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 172,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 14,
                  childAspectRatio: AppTheme.posterAspect,
                ),
                itemCount: count,
                itemBuilder: (context, i) => Material(
                  child: InkWell(
                    focusNode: nodes[i],
                    onTap: () {},
                    child: ColoredBox(color: AppTheme.panel),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    nodes[0].requestFocus();
    await tester.pump();

    int? focusedIndex() {
      for (var i = 0; i < count; i++) {
        if (nodes[i].hasFocus) return i;
      }
      return null;
    }

    final trace = <int?>[focusedIndex()];
    for (var step = 0; step < 30; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final i = focusedIndex();
      if (trace.last == i) break;
      trace.add(i);
    }

    // ignore: avoid_print
    print('DPAD-DOWN 轨迹: $trace');

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    // ignore: avoid_print
    print('滚动位置: ${scrollable.position.pixels} / ${scrollable.position.maxScrollExtent}');
    expect(trace.length, greaterThan(1), reason: '方向键至少要能动一格，否则遥控器完全不可用');
  });

  testWidgets('OK 键（select）能激活 InkWell', (tester) async {
    var taps = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: Material(
              child: InkWell(
                focusNode: node,
                onTap: () => taps++,
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(taps, 1, reason: 'Android TV 的 OK 键就是 keyCode 23 → select，必须能当「确定」用');
  });

  testWidgets('设置页那批控件能不能被 OK 键操作', (tester) async {
    // 设置页/扫描页用到 Switch、Slider、FilterChip、DropdownButton、
    // ExpansionTile 五类控件。遥控器上「能不能改设置」全看它们认不认
    // `ActivateIntent`（OK 键 → select → ActivateIntent）。
    var switched = 0;
    var chipToggled = 0;
    var sliderValue = 0.5;
    var expanded = 0;
    var dropdownOpened = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ListView(
            children: [
              Switch(value: false, onChanged: (_) => switched++),
              Slider(value: 0.5, onChanged: (v) => sliderValue = v),
              FilterChip(label: const Text('只看问题'), selected: false, onSelected: (_) => chipToggled++),
              DropdownButton<String>(
                value: 'a',
                items: const [DropdownMenuItem(value: 'a', child: Text('a'))],
                onChanged: (_) => dropdownOpened++,
              ),
              ExpansionTile(title: const Text('怎么拿 Cookie'), onExpansionChanged: (v) => expanded += v ? 1 : 0, children: const [Text('步骤')]),
            ],
          ),
        ),
      ),
    );

    // 焦点怎么拿到：不用 `Focus.of()`（Switch 的 Focus 在它**子树里**，
    // 不是祖先，会直接抛），改用 Tab 逐个走 —— 这也顺便测出了
    // 「遥控器/键盘能不能走到这个控件上」。
    //
    // 每一步记录**哪个计数器动了**，因为 `primaryFocus.context.widget`
    // 永远是内层那个 `Focus`，认不出宿主控件。
    final hits = <String>[];
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final before = (switched, chipToggled, expanded, sliderValue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      if (switched != before.$1) hits.add('Switch');
      if (chipToggled != before.$2) hits.add('FilterChip');
      if (expanded != before.$3) hits.add('ExpansionTile');
      if (sliderValue != before.$4) hits.add('Slider');
      // 下拉被 OK 键打开后会弹一层路由，先关掉，否则后面几步都在菜单里走。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }

    // ignore: avoid_print
    print(
      'OK 键在 Tab 轨迹上打中了: $hits\n'
      '最终值: Switch=$switched Slider=$sliderValue FilterChip=$chipToggled '
      'Dropdown回调=$dropdownOpened ExpansionTile=$expanded',
    );

    expect(switched, greaterThanOrEqualTo(1), reason: '开关不认 OK 键的话，设置页在 TV 上就是只读的');
    expect(chipToggled, greaterThanOrEqualTo(1), reason: '诊断页的「只看问题」是 FilterChip');
    expect(expanded, greaterThanOrEqualTo(1), reason: '豆瓣 Cookie 帮助是 ExpansionTile');
  });

  testWidgets('方向键被聚焦的 Slider 吃掉（播放页 ExcludeFocus 的实证）', (tester) async {
    var value = 0.5;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: Slider(focusNode: node, value: value, onChanged: (v) => value = v),
            ),
          ),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    // ignore: avoid_print
    print('Slider 收到 → 之后的值: $value');
    expect(value, greaterThan(0.5), reason: '这就是播放页必须把控制栏 ExcludeFocus 的理由：焦点一旦落在滑块上，→ 不再是「快进 10 秒」');
  });

  testWidgets('焦点高亮的强度：已经换掉深色主题那个「白色 12%」的默认值', (tester) async {
    // Flutter 深色主题的默认焦点色（`theme_data.dart`）——
    // 这就是当初「3 米外看不出焦点在哪」的量化依据，留作对照。
    const flutterDefaultAlpha = 0.1216;

    final focus = AppTheme.dark().focusColor;
    // ignore: avoid_print
    print(
      'AppTheme.dark().focusColor = $focus (alpha=${focus.a})；'
      'Flutter 深色默认 alpha=$flutterDefaultAlpha',
    );

    expect(
      focus.a,
      greaterThan(flutterDefaultAlpha),
      reason: '默认的 12% 白色蒙层在电视上等于没有焦点指示，必须换掉',
    );
    // 中性提亮、不染色：真机反馈是带颜色的罩子（上一版 `accent @ 0.30`）
    // 把内容染蓝、「看起来有点多余，也不太美观」。r/g/b 必须相等，
    // 否则「焦点」会被读成「选中」。
    expect(
      focus.r == focus.g && focus.g == focus.b,
      isTrue,
      reason: 'focusColor 必须是中性白（只抬亮度、不动色相），与 TvFocusable '
          '的 brighten 是同一种语言',
    );
    // 海报墙的焦点不靠这一行（ink 画在海报下面，多亮都盖得住），
    // 靠 `TvFocusable` 的放大 + 提亮兜底 —— 所以这里不断言具体 alpha 下限，
    // 只要求比 Flutter 默认强。
  });

  testWidgets('筛选浮层（MenuAnchor）遥控器能不能进出', (tester) async {
    // 媒体库右上角「筛选」用的是 MenuAnchor。它**不是**一条路由
    // （源码里是 `OverlayPortal` + `OverlayPortalController`），
    // 关闭靠 `DismissIntent` —— 而那个键绑在 Esc 上。
    // Android TV 遥控器上没有 Esc，只有 BACK，所以「关不掉」这件事
    // 必须在 TV 上单独确认。
    var chipTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Center(
            child: MenuAnchor(
              menuChildren: [
                Material(
                  child: InkWell(
                    onTap: () => chipTaps++,
                    child: const SizedBox(
                      width: 120,
                      height: 40,
                      child: Center(child: Text('2020')),
                    ),
                  ),
                ),
              ],
              builder: (context, controller, child) => Material(
                child: InkWell(
                  onTap: () =>
                      controller.isOpen ? controller.close() : controller.open(),
                  child: const SizedBox(
                    width: 100,
                    height: 40,
                    child: Center(child: Text('筛选')),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 用 Tab 走到「筛选」按钮上（模拟遥控器把它选中的那一步）。
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final opened = find.text('2020').evaluate().isNotEmpty;

    // 面板开出来了之后，D-pad 能不能走到里面的 chip、OK 能不能选中它？
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final afterDownOk = chipTaps;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    // ignore: avoid_print
    print('筛选浮层: 打开了=$opened · 下+OK 命中=$afterDownOk · 累计=$chipTaps');

    // Esc 关掉（TV 上没有这个键，这里只用来确认「关得掉」这件事本身没问题）。
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('按 Esc 之后面板还在吗: ${find.text('2020').evaluate().isNotEmpty}');

    expect(opened, isTrue, reason: 'OK 键至少要能把筛选面板打开');
  });

  testWidgets('CallbackShortcuts 只绑 space 时，OK 键（select）不会命中', (tester) async {
    var hits = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.space): () => hits++,
          },
          child: const Focus(autofocus: true, child: Scaffold()),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    final afterSelect = hits;

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    // ignore: avoid_print
    print('select 命中次数=$afterSelect，space 命中次数=$hits');
    expect(afterSelect, 0, reason: '当前播放页只绑了 space，OK 键落不到它身上 —— 这就是「遥控器按不出暂停」的机制');
    expect(hits, 1);
  });

  testWidgets('控制栏：整块 ExcludeFocus 会让遥控器够不到按钮，只摘掉滑块才对', (tester) async {
    // 复刻控制栏的形状：一条滑块 + 一个按钮。
    // 两种包法各跑一遍 —— 这就是「修复前 / 修复后」的对照。
    Future<int> run({required bool blanket}) async {
      var pauseTaps = 0;
      var sliderValue = 0.5;

      final bar = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            child: ExcludeFocus(
              child: Slider(
                value: sliderValue,
                onChanged: (v) => sliderValue = v,
              ),
            ),
          ),
          IconButton(
            onPressed: () => pauseTaps++,
            icon: const Icon(Icons.pause_rounded),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(
                  child: Focus(autofocus: true, child: SizedBox.expand()),
                ),
                if (blanket) ExcludeFocus(child: bar) else bar,
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // 「焦点在画面上，按一下 ↓ 走进控制栏，再按 OK」—— TV 上最自然的一串操作。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      return pauseTaps;
    }

    final blanket = await run(blanket: true);
    final precise = await run(blanket: false);

    // ignore: avoid_print
    print('整块 ExcludeFocus → OK 命中 $blanket 次；只摘掉滑块 → OK 命中 $precise 次');

    expect(blanket, 0, reason: '这是原来的写法：控制栏整块 ExcludeFocus，遥控器够不到任何控件，于是没有暂停/清晰度/字幕');
    expect(precise, 1, reason: '把滑块单独摘出焦点链后，↓ 能走到暂停按钮、OK 能按下去');
  });

  testWidgets('SelectableText 是 TV 上的焦点陷阱，TvSelectableText 不是（P2-4 的判据）', (tester) async {
    // P2-4 原话是「TV 上把 `SelectableText` 换成普通 `Text`」。做之前得先分清
    // 它属于哪一种 —— 这两者的处理**完全不同**：
    //
    //   * **没用**（只是划选不了）→ 换不换都行。换了反而丢掉诊断页
    //     「不点按钮也能用鼠标选走」这个刻意的设计（见 `LogPathRow` 注释）；
    //   * **有害**（自带可聚焦的 `EditableText`）→ D-pad 会停在它上面，
    //     按 OK 什么都不发生，用户以为遥控器坏了。**这个必须换。**
    //
    // `SelectableText` 内部就是 `EditableText(readOnly: true)`，而 `EditableText`
    // 天生带一个 `FocusNode` —— 所以「有害」这个可能性一点都不小，不能靠猜。
    // 实测结果：**有害**（`canRequestFocus == true`，且焦点进去就出不来）。
    //
    // 这条用例同时钉两件事，缺一不可：
    //   1. 裸 `SelectableText` **确实**会卡住焦点 —— 这是 `tv_text.dart` 存在的
    //      唯一理由。哪天 Flutter 改了它的焦点行为，第 1 条会红，那时才该考虑
    //      能不能删掉那个包装；
    //   2. `TvSelectableText` **确实**不卡 —— 这是修复本身没白写的证明。
    //
    // 只钉第 2 条是不够的：那样「为什么要有这个包装」就只存在于注释里了。
    Future<List<String>> dpadTrace(Widget Function(FocusNode node) textOf) async {
      final selNode = FocusNode(debugLabel: 'text');
      final before = FocusNode(debugLabel: 'before');
      final after = FocusNode(debugLabel: 'after');
      addTearDown(() {
        selNode.dispose();
        before.dispose();
        after.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: MediaQuery(
            // ⚠️ 尺寸用 `MediaQuery` 显式给，**不用 `setSurfaceSize`** ——
            // 本项目的 TV 用例都走这条（见 `test/ui/theme/tv_layout_test.dart`），
            // 它直接决定 `AppTheme.isTvLayout` 看到的那个宽度。
            data: const MediaQueryData(size: Size(960, 540)),
            child: Scaffold(
              body: Column(
                children: [
                  FilledButton(
                    focusNode: before,
                    onPressed: () {},
                    child: const Text('上面'),
                  ),
                  textOf(selNode),
                  FilledButton(
                    focusNode: after,
                    onPressed: () {},
                    child: const Text('下面'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      before.requestFocus();
      await tester.pump();

      final trace = <String>[];
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        trace.add(
          selNode.hasFocus
              ? 'text'
              : (after.hasFocus ? 'after' : (before.hasFocus ? 'before' : '?')),
        );
        if (after.hasFocus) break;
      }
      return trace;
    }

    // ⚠️ 复位必须写在**测试体里**（这个 `finally`），`addTearDown` / `tearDown`
    // 都不行 —— Flutter 的 `_verifyInvariants` 排在它们前面，用错会得到一条
    // 与业务毫无关系的「foundation debug variable was changed by the test」。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final raw = await dpadTrace(
        (node) => SelectableText('这一段能不能被遥控器选中？', focusNode: node),
      );
      final wrapped = await dpadTrace(
        (node) => TvSelectableText('这一段能不能被遥控器选中？', focusNode: node),
      );

      // ignore: avoid_print
      print('裸 SelectableText 的 ↓ 轨迹: $raw\nTvSelectableText 的 ↓ 轨迹: $wrapped');

      expect(
        raw,
        contains('text'),
        reason: '裸 SelectableText 不再吃焦点了（Flutter 行为变了）—— '
            '`widgets/tv_text.dart` 这个包装可以撤掉，这条断言该跟着改',
      );
      expect(
        raw,
        isNot(contains('after')),
        reason: '裸 SelectableText 居然能走过去 —— 那就不是陷阱，包装也没必要了。'
            '实测它是**进去就出不来**：连按 4 次 ↓ 都停在原地',
      );
      expect(
        wrapped,
        isNot(contains('text')),
        reason: 'TvSelectableText 在 TV 上仍然把焦点让了出去 —— 修复失效了，'
            '诊断页/登录页在电视上会再次「方向键走不动」',
      );
      expect(
        wrapped,
        contains('after'),
        reason: 'TV 上必须能从文本**直接走到下面那个按钮** —— '
            '这才是「用户走进一段长文本不会被困住」',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
