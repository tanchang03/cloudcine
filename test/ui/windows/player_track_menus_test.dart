import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/anchored_menu.dart';
import 'package:cloudcine/ui/windows/player_protocol.dart';
import 'package:cloudcine/ui/windows/player_window_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

/// 播放窗口的字幕 / 音轨菜单。
///
/// ## 为什么这两个菜单必须单独渲染来测
///
/// 它们在**测试环境里点不开**。控制栏上那两个入口都写着
/// `_player == null ? null : …`，而 `Player()` 在 `flutter test` 里根本建不出来
/// —— 它抛 `Cannot find Mpv.framework … in the Frameworks folder`，因为测试跑在
/// 宿主 Dart VM 上，libmpv 不在 rpath 里。于是按钮永远是禁用的，弹菜单那条路径
/// **在测试里不可达**。
///
/// 所以 `player_window_app.dart` 开了两个 `@visibleForTesting` 入口
/// （[buildAudioMenuForTest] / [buildSubtitleMenuForTest]）直接构造菜单。
///
/// ## 这些用例在防什么
///
/// 菜单里全是**改错不报错**的规则：勾打错一行、少一个分组、文案没跟着状态变、
/// 点了 pop 回去一个错的载荷 —— 没有一条会抛异常。用户看到的只是「勾在错的地方」
/// 或者「点了没反应」。这类回归靠人眼查不出来，因为「坏了」和「本来就没有」
/// 长得一模一样。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------- 构造工具

  AudioTrack audio({
    String id = '1',
    String? title,
    String? language,
    String? codec,
    int? channelscount,
    String? channels,
    int? samplerate,
    int? bitrate,
  }) =>
      AudioTrack(
        id,
        title,
        language,
        codec: codec,
        channelscount: channelscount,
        channels: channels,
        samplerate: samplerate,
        bitrate: bitrate,
      );

  SubtitleTrack sub({
    String id = '1',
    String? title,
    String? language,
    String? codec,
    bool? isDefault,
  }) =>
      SubtitleTrack(
        id,
        title,
        language,
        codec: codec,
        isDefault: isDefault,
      );

  // ---------------------------------------------------------------- 渲染工具

  /// 把菜单挂进一个**真的 Navigator** 里再渲染，返回「读 pop 结果」的口子。
  ///
  /// 直接 `pumpWidget(menu)` 是不行的：两个菜单里的每一行都以
  /// `Navigator.of(context).pop(…)` 收尾，没有 Navigator 就会在**点下去的那一刻**
  /// 抛异常 —— 而这里要断言的恰恰是「点下去会发生什么」。
  ///
  /// 窗口刻意开得很大：字幕菜单满配时有 14 行，默认的 800×600 会让菜单面板
  /// 的内容溢出，而溢出在测试里是**报错**（不是「看不全」），会把用例带崩。
  Future<Object? Function()> openMenu(WidgetTester tester, Widget menu) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Object? popped;

    await tester.pumpWidget(MaterialApp(
      // 每次 openMenu 都换一棵全新的树。
      //
      // `pumpWidget` 遇到**同类型**的根组件是「原地更新」而不是重建，Navigator
      // 连同它栈上那条还没关掉的 DialogRoute 会一起留下来 —— 于是同一个用例里
      // 第二次 openMenu 时，「打开」按钮其实被上一个菜单盖着，点不到。
      key: UniqueKey(),
      theme: AppTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<Object>(
                  DialogRoute<Object>(
                    context: context,
                    builder: (_) => menu,
                    barrierDismissible: false,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    // 这里可以用 pumpAndSettle：菜单里没有任何永不停止的动画
    //（播放窗口那边不能用的原因是缓冲指示的 CircularProgressIndicator）。
    await tester.pumpAndSettle();

    return () => popped;
  }

  /// 菜单里某一行（按标题文案定位）。
  ListTile tileOf(WidgetTester tester, String label) =>
      tester.widget<ListTile>(find.ancestor(
        of: find.text(label),
        matching: find.byType(ListTile),
      ));

  /// 菜单里所有文案，按**从上到下**的顺序。
  ///
  /// 菜单的内容和顺序就是它对用户的全部承诺，所以这里直接按顺序整列比对。
  /// 只收 [AnchoredMenuPanel] 里面的 —— 外面那层测试脚手架（「打开」按钮）不算菜单。
  List<String> menuTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(
        of: find.byType(AnchoredMenuPanel),
        matching: find.byType(Text),
      ))
      .map((t) => t.data)
      .whereType<String>()
      .toList();

  /// 菜单 pop 回去的是私有类型 `_SubtitleChoice`。
  ///
  /// 测试库写不出它的**类型名**，但它的**成员名是公开的**（`kind` / `fileId` /
  /// `trackId` / `localPath` …），所以 `dynamic` 取得到。只读，不构造 ——
  /// 这样既能钉住「菜单 pop 了什么」，又不用为了测试把类型公开出去。
  String kindOf(Object? choice) => '${(choice as dynamic).kind}';

  // ================================================================== 音轨菜单

  group('音轨菜单', () {
    testWidgets('每行的标题与副标题就是 TrackLabels 给的那两句', (tester) async {
      await openMenu(
        tester,
        buildAudioMenuForTest(
          tracks: [
            audio(
              id: '1',
              language: 'chi',
              codec: 'aac',
              channelscount: 2,
              samplerate: 48000,
              bitrate: 320000,
            ),
            audio(id: '2', language: 'eng', codec: 'eac3', channelscount: 6),
          ],
          activeId: '1',
        ),
      );

      expect(find.text('音轨'), findsOneWidget);
      expect(find.text('简体中文'), findsOneWidget);
      expect(
        find.text('AAC · 立体声 · 48 kHz · 320 kbps'),
        findsOneWidget,
        reason: '副标题是「识别」那一半 —— 光有语言名，用户没法判断哪条才是原声',
      );
      expect(find.text('英语'), findsOneWidget);
      expect(find.text('Dolby Digital Plus · 5.1 声道'), findsOneWidget);
    });

    testWidgets('只有当前音轨打勾', (tester) async {
      await openMenu(
        tester,
        buildAudioMenuForTest(
          tracks: [audio(id: '1', language: 'chi'), audio(id: '2', language: 'eng')],
          activeId: '2',
        ),
      );

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tileOf(tester, '英语').selected, isTrue);
      expect(tileOf(tester, '简体中文').selected, isFalse);
    });

    testWidgets('轨号对不上任何一条时，一个勾都不打', (tester) async {
      // 这一支是真实会走到的：容器还没解析完时 `player.stream.track` 报的是
      // 合成轨，轨号是 'auto' / 'no'，过不了 `TrackLabels.realTracks` 就被丢了，
      // 于是 activeId 找不到对应行。
      //
      // 此时若「默认给第一条打勾」，用户会以为声音正走在第一条上。
      await openMenu(
        tester,
        buildAudioMenuForTest(
          tracks: [audio(id: '1', language: 'chi'), audio(id: '2', language: 'eng')],
          activeId: null,
        ),
      );

      expect(
        find.byIcon(Icons.check_rounded),
        findsNothing,
        reason: '没有选中态就不要打勾 —— 一个错的勾比没有勾更糟',
      );
    });

    testWidgets('字段全空时不建副标题行，而不是留一行空的', (tester) async {
      // mpv 只在**探到**的时候才填编码 / 声道 / 采样率 / 码率，内嵌音轨常常
      // 只有语言。`subtitle: Text('')` 也会占一行高度，让每一项看起来都像
      // 「有两行、第二行是空的」。
      await openMenu(
        tester,
        buildAudioMenuForTest(
          tracks: [audio(id: '1', title: '主音轨')],
          activeId: null,
        ),
      );

      expect(find.text('主音轨'), findsOneWidget);
      expect(
        tileOf(tester, '主音轨').subtitle,
        isNull,
        reason: '没有可说的就别建那个 Text —— 空串也占高度',
      );
    });

    testWidgets('点一条音轨，把那条轨道对象本身 pop 回去', (tester) async {
      final tracks = [
        audio(id: '1', language: 'chi'),
        audio(id: '2', language: 'eng'),
      ];

      final read = await openMenu(
        tester,
        buildAudioMenuForTest(tracks: tracks, activeId: '1'),
      );

      await tester.tap(find.text('英语'));
      await tester.pumpAndSettle();

      expect(
        read(),
        same(tracks[1]),
        reason: '切轨靠的是这个对象（`Player.setAudioTrack`），'
            '换个等价但不相同的实例会静默切成默认轨',
      );
    });
  });

  // ============================================================ 字幕菜单：顺序

  group('字幕菜单：分组与顺序', () {
    testWidgets('满配时的完整顺序：关闭 → 网盘 → 内嵌 → 在线 → 本地 → 从别处加载', (tester) async {
      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          tracks: [sub(id: '3', language: 'eng')],
          cloud: [
            SubtitleBrief(
              fileId: 'f1',
              label: '网盘中文',
              fileName: 'Movie.chs.srt',
            ),
          ],
          online: [
            OnlineSubtitleBrief(
              fileId: 7,
              fileName: 'b.srt',
              language: 'zh',
              title: '在线中文',
              downloadCount: 12,
            ),
          ],
          localPath: '/tmp/c.srt',
          localLabel: 'c.srt',
        ),
      );

      expect(
        menuTexts(tester),
        <String>[
          '字幕',
          '关闭字幕',
          '网盘字幕', '网盘中文', 'Movie.chs.srt',
          '内嵌字幕', '英语',
          '在线字幕', '在线中文', '简体中文 · b.srt · 12 次下载',
          '本地文件', 'c.srt', '/tmp/c.srt',
          '从别处加载', '重新搜索在线字幕…', '换一个本地字幕文件…',
        ],
        reason: '顺序就是「离用户最近 → 最远」：同目录的网盘字幕最可能对得上'
            '时间轴，在线字幕要下载、有额度，所以排最后',
      );
    });

    testWidgets('空的分组连小标题都不出现', (tester) async {
      await openMenu(
        tester,
        buildSubtitleMenuForTest(tracks: [sub(id: '3', language: 'eng')]),
      );

      expect(find.text('内嵌字幕'), findsOneWidget);
      expect(find.text('网盘字幕'), findsNothing);
      expect(find.text('在线字幕'), findsNothing);
      expect(find.text('本地文件'), findsNothing);
      expect(
        find.text('从别处加载'),
        findsOneWidget,
        reason: '两个动作入口永远在 —— 它们是没有字幕时**唯一**能点的东西',
      );
    });

    testWidgets('本地文件行只在挑过之后才出现，副标题是完整路径', (tester) async {
      await openMenu(tester, buildSubtitleMenuForTest());

      expect(find.text('本地文件'), findsNothing);
      expect(find.text('c.srt'), findsNothing);

      await openMenu(
        tester,
        buildSubtitleMenuForTest(localPath: '/tmp/c.srt', localLabel: 'c.srt'),
      );

      expect(find.text('本地文件'), findsOneWidget);
      expect(find.text('c.srt'), findsOneWidget);
      expect(
        find.text('/tmp/c.srt'),
        findsOneWidget,
        reason: '同名文件在不同目录很常见，只显示文件名会让用户分不清挑的是哪个',
      );
    });

    testWidgets('四种来源全空时给一句人话，而不是一个空菜单', (tester) async {
      await openMenu(tester, buildSubtitleMenuForTest());

      expect(
        find.textContaining('这个片源没有内嵌字幕'),
        findsOneWidget,
        reason: '什么都不显示的话，用户只会以为「这个功能还没做完」',
      );
    });

    testWidgets('只要有一种来源可用，就不再显示那句空态提示', (tester) async {
      await openMenu(
        tester,
        buildSubtitleMenuForTest(tracks: [sub(id: '3', language: 'eng')]),
      );

      expect(find.textContaining('这个片源没有内嵌字幕'), findsNothing);
    });
  });

  // ============================================================ 字幕菜单：打勾

  group('字幕菜单：打勾口径', () {
    testWidgets('没有任何字幕挂着时，「关闭字幕」打勾', (tester) async {
      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          tracks: [sub(id: '3', language: 'eng')],
          cloud: [SubtitleBrief(fileId: 'f1', label: '网盘中文')],
        ),
      );

      expect(
        menuTexts(tester)[1],
        '关闭字幕',
        reason: 'mpv 没有「上一条」的概念，想关掉字幕时必须有一条明确的退路 —— '
            '它必须永远在第一项',
      );
      expect(tileOf(tester, '关闭字幕').selected, isTrue);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });

    testWidgets('挂着外挂字幕时，内嵌轨一律不打勾 —— 哪怕轨号正好对得上', (tester) async {
      // 这是整个菜单里最容易写错的一条。
      //
      // mpv 认不出我们后挂上去的外挂字幕是哪一条，它只会把「有字幕轨被选中」
      // 报成一个数字。所以 `activeId` 完全可能等于某条内嵌轨的号（比如都是 3），
      // 靠轨号去高亮就会**在错误的那条内嵌轨上打勾**。
      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          tracks: [sub(id: '3', language: 'chi')],
          cloud: [
            SubtitleBrief(
              fileId: 'f1',
              label: '网盘中文',
              fileName: 'Movie.chs.srt',
            ),
          ],
          activeId: 3,
          activeCloudId: 'f1',
        ),
      );

      expect(
        tileOf(tester, '简体中文').selected,
        isFalse,
        reason: '内嵌轨的号跟 mpv 报回来的 sid 撞上了，但真正生效的是网盘那条 —— '
            '两个都打勾等于告诉用户「两条字幕同时在生效」',
      );
      expect(tileOf(tester, '网盘中文').selected, isTrue);
      expect(
        find.byIcon(Icons.check_rounded),
        findsOneWidget,
        reason: '整个菜单里只能有一个勾',
      );
    });

    testWidgets('没有外挂字幕时，选中的内嵌轨正常打勾', (tester) async {
      // 上一条的对照组：规则是「有外挂时**才**压住内嵌」，
      // 不是「内嵌永远不打勾」—— 后者会让内嵌字幕看起来不可选。
      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          tracks: [sub(id: '3', language: 'chi'), sub(id: '4', language: 'eng')],
          activeId: 3,
        ),
      );

      expect(tileOf(tester, '简体中文').selected, isTrue);
      expect(tileOf(tester, '英语').selected, isFalse);
    });

    testWidgets('挂着本地字幕时同样压住内嵌轨', (tester) async {
      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          tracks: [sub(id: '3', language: 'chi')],
          localPath: '/tmp/c.srt',
          localLabel: 'c.srt',
          activeId: 3,
          activeLocalPath: '/tmp/c.srt',
        ),
      );

      expect(tileOf(tester, '简体中文').selected, isFalse);
      expect(
        tileOf(tester, 'c.srt').selected,
        isTrue,
        reason: '本地字幕也是外挂的一种 —— 判据是「有没有后挂的字幕」，'
            '不是「后挂的字幕从哪来」',
      );
    });

    testWidgets('挂着本地字幕时，「关闭字幕」不打勾', (tester) async {
      // `_nothingActive` 是**四个**来源一起判的。漏判 `activeLocalPath`
      // （只判内嵌 / 网盘 / 在线三条）的后果很具体：本地字幕正在生效，
      // 菜单却把勾打在「关闭字幕」上 —— 用户会以为现在没挂字幕。
      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          localPath: '/tmp/c.srt',
          localLabel: 'c.srt',
          activeLocalPath: '/tmp/c.srt',
        ),
      );

      expect(tileOf(tester, 'c.srt').selected, isTrue);
      expect(tileOf(tester, '关闭字幕').selected, isFalse);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });

  // ======================================================== 字幕菜单：动作入口

  group('字幕菜单：两个动作入口', () {
    testWidgets('没搜过时写「搜索在线字幕…」，搜过之后写「重新搜索…」', (tester) async {
      await openMenu(tester, buildSubtitleMenuForTest());
      expect(find.text('搜索在线字幕…'), findsOneWidget);

      await openMenu(
        tester,
        buildSubtitleMenuForTest(
          online: [OnlineSubtitleBrief(fileId: 7, fileName: 'b.srt')],
        ),
      );
      expect(
        find.text('重新搜索在线字幕…'),
        findsOneWidget,
        reason: '搜过之后还写「搜索」，用户不知道点了会重新搜还是没反应 —— '
            '文案要让他知道会发生什么',
      );
    });

    testWidgets('搜索中：文案变「搜索中…」且点不动', (tester) async {
      final read = await openMenu(
        tester,
        buildSubtitleMenuForTest(searchingOnline: true),
      );

      expect(find.text('搜索中…'), findsOneWidget);
      expect(
        tileOf(tester, '搜索中…').enabled,
        isFalse,
        reason: '搜索会打接口、烧每日额度 —— 进行中必须点不动，'
            '否则连点几下就是把额度连着花掉',
      );

      await tester.tap(find.text('搜索中…'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(read(), isNull);
    });

    testWidgets('本地入口的文案跟着「挑过没有」变', (tester) async {
      await openMenu(tester, buildSubtitleMenuForTest());
      expect(find.text('选择本地字幕文件…'), findsOneWidget);

      await openMenu(
        tester,
        buildSubtitleMenuForTest(localPath: '/tmp/c.srt', localLabel: 'c.srt'),
      );
      expect(find.text('换一个本地字幕文件…'), findsOneWidget);
    });

    testWidgets('挑过文件之后搜索入口还在，文案也不受影响', (tester) async {
      // 两个入口是独立的：挑过本地文件不代表搜过在线字幕。
      await openMenu(
        tester,
        buildSubtitleMenuForTest(localPath: '/tmp/c.srt', localLabel: 'c.srt'),
      );

      expect(find.text('搜索在线字幕…'), findsOneWidget);
    });
  });

  // ====================================================== 字幕菜单：pop 的载荷

  group('字幕菜单：点了之后 pop 出什么', () {
    testWidgets('每一行 pop 回去的选择都带上了正确的载荷', (tester) async {
      // 这是菜单与处理器之间的**接口**：`_applySubtitleChoice` 按 kind 穷举，
      // 漏一种的表现就是「点了没反应」。所以每一种都要在这里出现一次 ——
      // 光测「菜单显示得对」是不够的，显示对了但 pop 错了同样是坏的。
      final tracks = [sub(id: '3', language: 'eng')];
      final cloud = [
        SubtitleBrief(fileId: 'f1', label: '网盘中文', fileName: 'a.srt'),
      ];
      final online = [
        OnlineSubtitleBrief(fileId: 7, fileName: 'b.srt', title: '在线中文'),
      ];

      Future<Object?> tap(String label) async {
        final read = await openMenu(
          tester,
          buildSubtitleMenuForTest(
            tracks: tracks,
            cloud: cloud,
            online: online,
            localPath: '/tmp/c.srt',
            localLabel: 'c.srt',
          ),
        );
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        return read();
      }

      expect(kindOf(await tap('关闭字幕')), '_SubtitleKind.off');

      final embedded = await tap('英语');
      expect(kindOf(embedded), '_SubtitleKind.embedded');
      expect(
        (embedded as dynamic).trackId,
        3,
        reason: '内嵌轨是**切轨**，要的是 mpv 的 sid 而不是轨道对象',
      );

      final cloudChoice = await tap('网盘中文');
      expect(kindOf(cloudChoice), '_SubtitleKind.cloud');
      expect((cloudChoice as dynamic).fileId, 'f1');

      final onlineChoice = await tap('在线中文');
      expect(kindOf(onlineChoice), '_SubtitleKind.online');
      expect((onlineChoice as dynamic).onlineId, 7);

      final localChoice = await tap('c.srt');
      expect(kindOf(localChoice), '_SubtitleKind.local');
      expect((localChoice as dynamic).localPath, '/tmp/c.srt');
      expect((localChoice as dynamic).localLabel, 'c.srt');

      expect(kindOf(await tap('重新搜索在线字幕…')), '_SubtitleKind.searchOnline');
      // 这一份菜单里已经挑过本地文件，所以入口写的是「换一个…」而不是
      // 「选择…」。两种文案 pop 的是同一个 kind（文案那一条另有用例盯着）。
      expect(kindOf(await tap('换一个本地字幕文件…')), '_SubtitleKind.pickLocal');
    });
  });
}
