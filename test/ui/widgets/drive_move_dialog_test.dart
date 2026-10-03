import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/settings_store.dart';
import 'package:cloudcine/data/registry/adapter_registry.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/services/drive_move.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/auth_providers.dart';
import 'package:cloudcine/ui/providers/drive_move_providers.dart';
import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/drive_move_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_drive.dart';

/// 目标目录选择框 —— 用户的**核心诉求**就落在这一屏上。
///
/// ## 为什么必须有一个真的把它画出来的测试
///
/// 「最近用过的目录」这件事的价值全在**交互**上，而不在数据里：值存对了、
/// 读对了，但如果那一列没画出来、或者点它没反应、或者预选没生效，功能
/// 等于不存在 —— 而以上任何一种都不会让任何一条非 UI 测试变红。
///
/// 另外这里还守着一条与删除**刻意相反**的设计：确认按钮上必须写着目标
/// 目录（不是「确定」）。移动最常见的失误是移错目录，而这个按钮是用户
/// 按下去之前最后一眼看到的东西。
class _FakeAuth extends AuthController {
  @override
  Future<AuthState> build() async => const AuthState();
}

/// 读设置库慢一拍的替身：用来把「最近记录还没读回来」那一帧**稳定**截住。
class _SlowStore extends SettingsStore {
  _SlowStore(AppDatabase db, this.delay) : super(db);

  final Duration delay;

  @override
  Future<String?> read(String key) async {
    await Future<void>.delayed(delay);
    return super.read(key);
  }
}

void main() {
  DriveEntry file(String id) =>
      DriveEntry(id: id, name: '$id.mkv', isDirectory: false);

  DriveEntry dir(String id) => DriveEntry(id: id, name: id, isDirectory: true);

  /// `root/电影/科幻` 三层，用来验浏览那一步。
  Map<String, List<DriveEntry>> tree() => {
        'root': [dir('电影'), dir('纪录片'), file('a'), file('b')],
        '电影': [dir('科幻'), file('c')],
        '科幻': [],
        '纪录片': [],
      };

  MoveTarget target(String fid, String path) => MoveTarget(
        fid: fid,
        name: path == '/' ? '/' : path.split('/').last,
        path: path,
      );

  /// 这次 `DriveMoveDialog.show` 的返回值（确认后非空，取消为 null）。
  DriveMovePlan? popped;

  setUp(() => popped = null);

  /// 打开对话框。
  ///
  /// [recents] 按**使用先后**给（最早的在前）—— 内部逐条调 `remember`，
  /// 那是「刚刚用过」的语义，所以**最后一条**才是会被预选的那个。
  /// 反过来传的话，预选就落在最旧的那一条上，而这里所有断言都会跟着错。
  Future<ProviderContainer> open(
    WidgetTester tester, {
    required List<DriveEntry> entries,
    String sourceDirPath = '/',
    List<MoveTarget> recents = const [],
  }) async {
    tester.view.physicalSize = const Size(900, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.memory();
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        adapterRegistryProvider
            .overrideWithValue(AdapterRegistry([FakeDriveAdapter(tree())])),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
    addTearDown(container.dispose);

    for (final r in recents) {
      await container.read(moveTargetsProvider.notifier).remember(r);
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  popped = await DriveMoveDialog.show(
                    ctx,
                    entries: entries,
                    sourceDirPath: sourceDirPath,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return container;
  }

  /// 确认按钮（对话框上唯一的 FilledButton）。
  FilledButton confirmButton(WidgetTester tester) => tester.widget<FilledButton>(
        find.byType(FilledButton),
      );

  testWidgets('还没用过任何目录：说明怎么才有，确认按钮置灰', (tester) async {
    await open(tester, entries: [file('a')]);

    expect(find.text('还没有用过的目录。选一次之后它就会出现在这里。'),
        findsOneWidget);
    expect(find.text('请选择目标目录'), findsOneWidget,
        reason: '没选目标时按钮不能是可点的 —— 点下去等于把一批东西'
            '「移到一个还不知道是哪儿的目录」。');
    expect(confirmButton(tester).onPressed, isNull);
  });

  testWidgets('有最近记录时预选最新那一条，且按钮上写着目标', (tester) async {
    await open(
      tester,
      entries: [file('a'), file('b')],
      sourceDirPath: '/电影',
      recents: [target('old', '/更早的'), target('dest', '/目标')],
    );

    // 预选 = 最新那条被选中，确认按钮直接可以按。
    expect(find.text('要移动这 2 项吗？'), findsOneWidget);
    expect(find.text('移动到 /目标'), findsOneWidget,
        reason: '按钮上必须写着目标目录，而不是「确定」。移动最常见的失误'
            '是移错目录，而这个按钮是用户按下去之前最后一眼看到的东西 —— '
            '只写「移动 2 项」等于把唯一一次核对机会浪费掉。');
    expect(find.text('/电影  →  /目标'), findsOneWidget,
        reason: '正文里要有一行把「从哪来 → 到哪去」摊开。只显示目标的话，'
            '用户没法判断「这个目录是不是我想要的」—— 他得先知道东西'
            '原来在哪儿。');
    expect(confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('点另一条最近记录就切过去（这就是「反复移」省下的那几次点选）',
      (tester) async {
    await open(
      tester,
      entries: [file('a')],
      sourceDirPath: '/电影',
      recents: [target('old', '/更早的'), target('dest', '/目标')],
    );

    expect(find.text('移动到 /目标'), findsOneWidget);

    await tester.tap(find.text('/更早的'));
    await tester.pumpAndSettle();

    expect(find.text('移动到 /更早的'), findsOneWidget,
        reason: '整件事的价值就在这一次点击上：整理网盘是反复的动作，'
            '第二批、第三批应该是一眼点中，而不是重新点五层目录。'
            '点不动的话，这一列就只是装饰。');
    expect(find.text('/电影  →  /更早的'), findsOneWidget);
  });

  testWidgets('目标是被移动目录的子目录：写明原因并置灰', (tester) async {
    await open(
      tester,
      entries: [dir('电影')],
      sourceDirPath: '/',
      recents: [target('sub', '/电影/科幻')],
    );

    expect(find.text('不能把目录移动进它自己或它的子目录里。'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNull,
        reason: '把 `/电影` 移进 `/电影/科幻` 会造出自引用目录，而它没有'
            '撤销入口。界面这一道只是省得用户白按一次 —— 真正的判据跟着'
            '控制器走，但按钮亮着会让用户以为这一步是允许的。');
  });

  testWidgets('目标是这些条目现在所在的目录：也置灰（空操作）', (tester) async {
    await open(
      tester,
      entries: [file('a')],
      sourceDirPath: '/电影',
      recents: [target('d1', '/电影')],
    );

    expect(find.text('这些条目已经在这个目录里了。'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNull,
        reason: '空操作会照样报「已移动 1 项」：用户以为动了、其实没动，'
            '然后去目标目录里找那批「刚被移过去」的文件。');
  });

  testWidgets('「选择其他目录」进浏览，一路钻进去再选定', (tester) async {
    await open(tester, entries: [file('a')], sourceDirPath: '/');

    await tester.tap(find.text('选择其他目录'));
    await tester.pumpAndSettle();

    // 根目录下只列子目录，文件不该混进来（这是「选目标」不是「选文件」）。
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('纪录片'), findsOneWidget);
    expect(find.text('a.mkv'), findsNothing,
        reason: '这一步是在选**目录**。把文件也列出来会让用户选中一个'
            '文件当目标 —— 那个 fid 根本不是目录，请求发出去必然失败。');
    expect(find.text('选定「我的网盘」'), findsOneWidget);

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(find.text('/电影'), findsOneWidget);
    expect(find.text('选定「电影」'), findsOneWidget);

    await tester.tap(find.text('科幻'));
    await tester.pumpAndSettle();
    expect(find.text('/电影/科幻'), findsOneWidget);

    await tester.tap(find.text('选定「科幻」'));
    await tester.pumpAndSettle();

    // 回到选目标那一屏，目标已经换成刚选的那个。
    expect(find.text('移动到 /电影/科幻'), findsOneWidget);
  });

  testWidgets('浏览时「上一层」能退回；根目录上它是灰的', (tester) async {
    await open(tester, entries: [file('a')]);

    await tester.tap(find.text('选择其他目录'));
    await tester.pumpAndSettle();

    // 按图标找，不按 tooltip 找 —— `find.byTooltip` 命中的是 Tooltip 那个
    // 包装 widget，不是里面的按钮。
    final up = find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
    expect(tester.widget<IconButton>(up).onPressed, isNull,
        reason: '根目录上没有「上一层」。置灰而不是隐藏：位置固定住，'
            '用户连点两下时不会因为按钮消失而点到别处。');

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(up).onPressed, isNotNull);

    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('选定「我的网盘」'), findsOneWidget);
  });

  testWidgets('浏览视图的「返回」不丢已经选好的目标', (tester) async {
    await open(
      tester,
      entries: [file('a')],
      sourceDirPath: '/',
      recents: [target('dest', '/目标')],
    );

    await tester.tap(find.text('选择其他目录'));
    await tester.pumpAndSettle();
    expect(find.text('返回'), findsOneWidget);

    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();

    expect(find.text('移动到 /目标'), findsOneWidget,
        reason: '「返回」是反悔「我要去别处找」，不是反悔「我刚才选的那个」。'
            '把它做成清空的话，用户翻了两层发现不对、退回来，还得重选一次。');
  });

  testWidgets('取消：什么都不返回（不会移）', (tester) async {
    await open(
      tester,
      entries: [file('a')],
      recents: [target('dest', '/目标')],
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(popped, isNull,
        reason: '返回 null 是「什么都没做」。返回一个「移动了 0 项」的'
            '计划会让调用方弹一条结果提示 —— 用户会以为失败了一次。');
  });

  testWidgets('确认：返回的计划带着刚选的目标与源目录', (tester) async {
    await open(
      tester,
      entries: [file('a'), dir('电影')],
      sourceDirPath: '/待整理',
      recents: [target('dest', '/目标')],
    );

    expect(find.text('1 个目录会连同里面的全部文件一起移动。'), findsOneWidget,
        reason: '列表里那一行只写着一个目录名，看不出它后面挂着几百 GB。');

    await tester.tap(find.text('移动到 /目标'));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.target.fid, 'dest');
    expect(popped!.sourceDirPath, '/待整理',
        reason: '源目录必须一起带出去 —— 控制器要用它算「目标是不是某个'
            '被移动目录的子目录」。丢了它，那道安全检查会静默失效。');
    expect(popped!.entries.length, 2);
  });

  testWidgets('列出的条目超过上限时只摊开前几个，并说明总数', (tester) async {
    await open(tester, entries: [for (var i = 0; i < 9; i++) file('f$i')]);

    expect(find.text('f0.mkv'), findsOneWidget);
    expect(find.text('f4.mkv'), findsOneWidget);
    expect(find.text('f5.mkv'), findsNothing,
        reason: '这个框真正要用户看的是「目标目录」，预览只是让他确认'
            '「勾的是不是这一批」。摊开九行会把目标那一块挤出屏幕。');
    expect(find.text('…等共 9 项'), findsOneWidget);
  });

  testWidgets('读取最近记录期间显示「正在读取」，而不是「还没有用过」',
      (tester) async {
    // 只 pump 一帧、不 settle：让 `moveTargetsProvider` 停在 loading。
    // 内存库的读几乎是立刻完成的，所以这里必须把读**拖慢**才看得到那一帧。
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        settingsStoreProvider
            .overrideWithValue(_SlowStore(db, const Duration(seconds: 1))),
        adapterRegistryProvider
            .overrideWithValue(AdapterRegistry([FakeDriveAdapter(tree())])),
        authControllerProvider.overrideWith(_FakeAuth.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: DriveMoveDialog(entries: [], sourceDirPath: '/'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在读取最近用过的目录…'), findsOneWidget,
        reason: '读设置库是异步的。这一刻若直接画「还没有用过的目录」，'
            '用户会以为记录丢了 —— 而它其实只是还没读回来。这两种状态'
            '必须能分开，否则「偶尔没记住」这个 bug 永远查不清。');

    // 读回来之后（这里库里是空的）才切到「还没有用过」。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('还没有用过的目录。选一次之后它就会出现在这里。'),
        findsOneWidget);
  });
}
