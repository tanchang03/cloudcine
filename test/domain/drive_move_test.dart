import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/services/drive_batch.dart';
import 'package:cloudcine/domain/services/drive_cleanup.dart';
import 'package:cloudcine/domain/services/drive_move.dart';
import 'package:flutter_test/flutter_test.dart';

/// 批量移动的**目标判据、计划与文案**。
///
/// ## 为什么这个类值得单独测
///
/// 它是这个功能里唯一一处「判错了不会报错」的地方：
///
///   1. **非法目标**：把 `/电影` 移进 `/电影/科幻` 会造出自引用目录，没有
///      撤销入口；而反过来判**过**（把 `/电影2` 当成 `/电影` 的子目录）
///      会让确认按钮永远灰着 —— 用户看到的是「这个按钮坏了」，不是
///      「网盘拒绝移动」。
///   2. **算路径用的是 `sourceDirPath` 而不是 `DriveEntry.path`**：列目录
///      拿到的条目里后者是 `null`（只有扫描器会填）。拿 `null` 做前缀比较
///      会**静默地一条都匹配不到**，于是第 1 条检查形同不存在。
///   3. **分块**：漏一条就是「我明明勾了它，移完还在」。
///   4. **文案**：移动最常见的失误是移错目录，而确认按钮是用户按下去之前
///      最后一眼看到的东西 —— 按钮上不带目标，等于把唯一一次核对机会
///      浪费掉。
void main() {
  DriveEntry file(String id, {String? name}) => DriveEntry(
        id: id,
        name: name ?? '$id.mkv',
        isDirectory: false,
      );

  DriveEntry dir(String id) =>
      DriveEntry(id: id, name: id, isDirectory: true);

  MoveTarget target(String fid, String path) => MoveTarget(
        fid: fid,
        name: path == '/' ? '/' : path.split('/').last,
        path: path,
      );

  /// 只关心「目标合不合法」时用这个：源目录固定为根。
  DriveMovePlan planAt(String sourceDirPath, List<DriveEntry> entries,
          MoveTarget t) =>
      DriveMovePlan(
        entries: entries,
        sourceDirPath: sourceDirPath,
        target: t,
      );

  group('MoveTarget', () {
    test('根目录的标签是「我的网盘」，不是 /', () {
      expect(target('root', '/').label, '我的网盘');
      expect(target('root', '/').isRoot, isTrue);

      expect(target('d1', '/电影').label, '/电影',
          reason: '确认按钮上写着「移动到 /」读起来像一个笔误，而「移动到 '
              '我的网盘」不会。这个字符串是用户按下移动之前最后看到的东西。');
    });

    test('isRoot 认归一化之后的路径（/ 与 /// 都是根）', () {
      expect(target('root', '///').isRoot, isTrue);
      expect(target('root', '').isRoot, isTrue);
      expect(target('d1', '/电影/').isRoot, isFalse);
    });

    test('相等只看 fid —— 路径只是显示用的附属信息', () {
      expect(
        MoveTarget(fid: 'd1', name: '电影', path: '/电影'),
        MoveTarget(fid: 'd1', name: '电影（新）', path: '/媒体/电影'),
        reason: '同一个目录被改名或挪位置之后，最近列表里不该出现两条 '
            '指向同一个 fid 的记录 —— 那样「最近用过」会变成一串看不出'
            '区别的重复项，而它恰恰是靠「一眼认出来」才有用的。',
      );
      expect(
        MoveTarget(fid: 'd1', name: '电影', path: '/电影'),
        isNot(MoveTarget(fid: 'd2', name: '电影', path: '/电影')),
      );
    });

    test('toJson / fromJson 往返，且路径在存的时候就被归一化', () {
      final restored = MoveTarget.fromJson(
        MoveTarget(fid: 'd1', name: '科幻', path: '/电影/科幻/').toJson(),
      );

      expect(restored, isNotNull);
      expect(restored!.fid, 'd1');
      expect(restored.name, '科幻');
      expect(restored.path, '/电影/科幻',
          reason: '存进去的是带尾斜杠的路径，取出来必须是归一化的 —— '
              '否则它会和 `drivePathIsUnder` 的比较口径对不上，'
              '表现为「上次用过的目录这次被判成非法」。');
    });

    test('fid 缺失 / 为空 / 不是字符串 → 整条作废', () {
      expect(MoveTarget.fromJson(null), isNull);
      expect(MoveTarget.fromJson('不是 map'), isNull);
      expect(MoveTarget.fromJson({'path': '/电影'}), isNull);
      expect(MoveTarget.fromJson({'fid': '', 'path': '/电影'}), isNull);
      expect(MoveTarget.fromJson({'fid': 42, 'path': '/电影'}), isNull,
          reason: '没有 fid 这条记录根本没法用来移动 —— 留着它只会在'
              '「最近用过」那一列里造出一个点了没反应的行。');
    });

    test('path 缺失 / 不是字符串 → 整条作废（拿不到展示路径就没法核对）', () {
      expect(MoveTarget.fromJson({'fid': 'd1'}), isNull);
      expect(MoveTarget.fromJson({'fid': 'd1', 'path': 7}), isNull);
    });

    test('name 缺失或为空 → 退回路径末段，不连累整条', () {
      final noName = MoveTarget.fromJson({'fid': 'd1', 'path': '/电影/科幻'});
      expect(noName!.name, '科幻',
          reason: '名字能从路径救回来，就没有理由把这条记录整条丢掉 —— '
              '丢掉它，用户会少一个「最近用过」的入口。');

      final blankName =
          MoveTarget.fromJson({'fid': 'd1', 'path': '/电影', 'name': ''});
      expect(blankName!.name, '电影');
    });

    test('根目录的名字退回路径末段是 /（可读，不炸）', () {
      expect(MoveTarget.fromJson({'fid': 'root', 'path': '/'})!.name, '/');
    });
  });

  group('非法目标', () {
    test('目标是兄弟目录 → 放行（前缀相同不算子孙）', () {
      final reason = planAt('/', [dir('电影')], target('d2', '/电影2'))
          .invalidTargetReason();

      expect(reason, isNull,
          reason: '`/电影2` 不是 `/电影` 的子目录。判成子目录的话，'
              '用户想把这批东西挪到隔壁那个目录时会发现确认按钮永远灰着 —— '
              '他看到的是「这个按钮坏了」，而不是任何一条能理解的提示。'
              '`drivePathIsUnder` 里补尾斜杠那一步就是为这个。');
    });

    test('目标是不相干的目录 → 放行', () {
      expect(
        planAt('/电影', [dir('科幻')], target('d2', '/纪录片'))
            .invalidTargetReason(),
        isNull,
      );
    });

    test('目标是「往上挪一层」→ 放行（源目录与目标不同层）', () {
      final reason =
          planAt('/电影/科幻', [dir('2023')], target('d1', '/电影'))
              .invalidTargetReason();

      expect(reason, isNull,
          reason: '把 `/电影/科幻/2023` 挪到 `/电影` 是最常见的一次整理，'
              '不是空操作 —— 空操作那条判的是「目标 == 这些条目现在所在的'
              '目录」，这里是它的上一层。');
    });

    test('目标就是被移动的目录自己 → 拦下', () {
      final reason = planAt('/', [dir('电影')], target('d1', '/电影'))
          .invalidTargetReason();

      expect(reason, contains('子目录'),
          reason: '把 `/电影` 移进 `/电影` 会造出一个自引用目录：目录视图里'
              '点进去可以无限深，而且没有任何撤销入口。这是这个功能里唯一'
              '可能造成结构性损坏的操作。');
    });

    test('目标是被移动目录的子孙 → 拦下', () {
      expect(
        planAt('/', [dir('电影')], target('d3', '/电影/科幻/2023'))
            .invalidTargetReason(),
        isNotNull,
      );
      expect(
        planAt('/', [dir('电影')], target('d2', '/电影/科幻'))
            .invalidTargetReason(),
        isNotNull,
      );
    });

    test('在根目录下移进任意子目录都不算「移进自己」', () {
      // 根是 `drivePathIsUnder` 的特例（`ancestor == '/'` 恒真）。若哪天
      // 有人「优化」掉那个特例，这一条会红 —— 而线上表现是所有移动都动不了。
      expect(
        planAt('/', [dir('电影')], target('d2', '/纪录片'))
            .invalidTargetReason(),
        isNull,
      );
    });

    test('只勾了文件时不会被路径前缀判据误伤', () {
      // 文件不是容器，没有「子目录」这回事。判据里那句 `if (!isDirectory)
      // continue` 就是为它留的。
      final reason = planAt(
        '/',
        [file('a', name: '电影.mkv')],
        target('d2', '/电影/科幻'),
      ).invalidTargetReason();

      expect(reason, isNull);
    });

    test('目标是这些条目现在所在的目录 → 拦下（那是一次空操作）', () {
      final reason =
          planAt('/电影', [file('a')], target('d1', '/电影')).invalidTargetReason();

      expect(reason, contains('已经在这个目录里'),
          reason: '空操作会照样报「已移动 1 项」：用户以为动了、其实没动，'
              '然后去目标目录里找那批「刚被移过去」的文件。报一个成功的'
              '空操作比报错更坏 —— 错至少能被发现。');
    });

    test('空操作判据与尾斜杠无关', () {
      expect(
        planAt('/电影', [file('a')], target('d1', '/电影/')).invalidTargetReason(),
        isNotNull,
      );
    });

    test('两条判据互斥：不存在「既是移进自己、又是空操作」的目标', () {
      // `/电影` 里勾了 `电影` 这个子目录、目标又填 `/电影`。看上去像
      // 「两条都命中」，其实只有空操作那条成立。
      //
      // 原因是 `sourcePathOf` 永远是 `sourceDirPath` 的**严格**子孙
      // （条目名非空），所以「目标 == 源目录」时不可能同时满足
      // 「目标 ≤ 某个条目的路径」。
      //
      // 记下这一点是为了说明**两段检查的先后顺序不重要** —— 免得有人
      // 日后看到「先遍历目录、再判空操作」，以为是刻意排的优先级，
      // 把它当成一条不能动的约定。
      final reason =
          planAt('/电影', [dir('电影')], target('d1', '/电影')).invalidTargetReason();

      expect(reason, contains('已经在这个目录里'));
      expect(reason, isNot(contains('子目录')),
          reason: '把 `/电影/电影` 挪到 `/电影` 只是原地不动，不是自引用 —— '
              '报「不能移动进它自己的子目录」会让用户以为换个目录就能成，'
              '而其实这一批本来就什么都不用做。');
    });
  });

  group('条目路径', () {
    test('sourcePathOf 用 sourceDirPath 算，不依赖 entry.path', () {
      final entries = [dir('电影')];
      final plan = planAt('/', entries, target('d2', '/纪录片'));

      expect(entries.single.path, isNull,
          reason: '列目录拿到的条目里 `path` 就是 null（只有扫描器会填）。'
              '这条断言把前提钉住：下面那句成立，不是因为凑巧有个 path。');
      expect(plan.sourcePathOf(entries.single), '/电影',
          reason: '拿 `entry.path`（null）去比前缀会**静默地一条都匹配不到**，'
              '于是「移进自己的子目录」那条检查形同不存在 —— 而它的失效'
              '方式恰恰是「什么都没发生」，没有报错可以查。');
    });

    test('sourcePathOf 在深层目录下也对', () {
      final plan = planAt('/电影/科幻', [dir('2023')], target('d1', '/电影'));
      expect(plan.sourcePathOf(plan.entries.single), '/电影/科幻/2023');
    });

    test('sourceLabel：根写「我的网盘」，其余写路径', () {
      expect(planAt('/', [file('a')], target('d1', '/电影')).sourceLabel,
          '我的网盘');
      expect(planAt('/电影/', [file('a')], target('d2', '/纪录片')).sourceLabel,
          '/电影');
    });
  });

  group('分块', () {
    test('与批量删除共用同一个上限（防「删得动、移不动」）', () {
      expect(
        DriveDeletePlan.maxIdsPerRequest,
        driveMaxFidsPerRequest,
        reason: '两个数一旦各写一份，就会出现「删除能成、移动报错」这类'
            '查起来毫无头绪的差异 —— 而两边都不会报错，只会让某一批'
            '静默失败。',
      );
    });

    test('不超过上限时只有一批', () {
      final plan = planAt('/', [for (var i = 0; i < 10; i++) file('f$i')],
          target('d1', '/电影'));
      expect(plan.idChunks().length, 1);
      expect(plan.idChunks().single.length, 10);
    });

    test('刚好等于上限时也只有一批（边界不是 off-by-one）', () {
      final n = driveMaxFidsPerRequest;
      final plan = planAt(
          '/', [for (var i = 0; i < n; i++) file('f$i')], target('d1', '/电影'));

      expect(plan.idChunks().length, 1,
          reason: '刚好 100 个却切成 2 批的话，第 2 批是空的 —— 一次白打的'
              '请求，而夸克那条限流线本来就很紧。');
    });

    test('超出一批时切多批，且一条不丢、一条不重', () {
      final n = driveMaxFidsPerRequest;
      final plan = planAt('/',
          [for (var i = 0; i < n + 3; i++) file('f$i')], target('d1', '/电影'));

      final chunks = plan.idChunks();
      expect(chunks.length, 2);
      expect(chunks.first.length, n);
      expect(chunks.last.length, 3);

      final flat = [for (final c in chunks) ...c];
      expect(flat.length, plan.count,
          reason: '丢一条 = 用户勾了它却没移走，而他不会知道是哪一条。');
      expect(flat.toSet().length, flat.length,
          reason: '重复一条 = 对同一个 fid 发两次移动，第二次必然报错，'
              '然后失败计数里多出一个假的失败。');
    });

    test('空计划不产生任何批次（不发请求）', () {
      expect(planAt('/', const [], target('d1', '/电影')).idChunks(), isEmpty,
          reason: '带空 `filelist` 的请求网盘多半直接报错 —— 而这次移动'
              '本来什么都不用做。');
    });
  });

  group('数量', () {
    test('count / folderCount / fileCount 三者的关系', () {
      final plan = planAt('/',
          [file('a'), file('b'), dir('d1')], target('d2', '/纪录片'));

      expect(plan.count, 3);
      expect(plan.folderCount, 1);
      expect(plan.fileCount, 2);
      expect(plan.folderCount + plan.fileCount, plan.count);
    });
  });

  group('文案', () {
    test('确认按钮**必须**带上目标目录', () {
      final plan = planAt('/电影', [file('a')], target('d2', '/纪录片'));

      expect(plan.confirmLabel, '移动到 /纪录片',
          reason: '这是与批量删除最大的一处差异：删除按钮写个数量就够了'
              '（正文里已经确认过要删什么），而移动最常见的失误是**移错'
              '目录** —— 用户按下去之前最后一眼看到的就是这个按钮。'
              '只写「移动 1 项」等于把这唯一一次核对机会浪费掉。');
    });

    test('确认按钮上根目录写「我的网盘」', () {
      expect(planAt('/电影', [file('a')], target('root', '/')).confirmLabel,
          '移动到 我的网盘');
    });

    test('标题是问句，且与按钮文案不重样', () {
      final plan = planAt('/电影', [file('a'), file('b')], target('d2', '/纪录片'));

      expect(plan.title, '要移动这 2 项吗？');
      expect(plan.title, isNot(plan.confirmLabel),
          reason: '两处文案一样的话，弹窗上会重复印同一句话，'
              '而测试里的 find.text 也会同时命中标题和按钮 —— 那种含糊'
              '正是「用户以为自己点的是标题」的来源。');
    });

    test('静态文案版与实例版一致（对话框要在选目标之前就画出标题）', () {
      final plan = planAt('/电影', [file('a'), dir('d1')], target('d2', '/纪录片'));

      expect(plan.title, DriveMovePlan.titleFor(plan.count),
          reason: '对话框在用户还没选目标目录时就要把标题画出来，而那个'
              '时刻构造不出完整的计划（target 是必填的）。静态版就是为它'
              '存在的 —— 一旦两份文案分叉，标题会在「选定目标」前后变一次，'
              '看起来像弹窗被换掉了。');
      expect(plan.folderNote, DriveMovePlan.folderNoteFor(plan.folderCount));
    });

    test('目录说明只在勾了目录时出现，且说「一起移动」而不是「一起删掉」', () {
      expect(
        planAt('/电影', [file('a')], target('d2', '/纪录片')).folderNote,
        isNull,
      );

      final note = planAt('/电影', [file('a'), dir('d1'), dir('d2')],
              target('d3', '/纪录片'))
          .folderNote;
      expect(note, isNotNull);
      expect(note, contains('2 个目录'));
      expect(note, contains('全部文件'),
          reason: '列表里那一行只写着一个目录名，看不出它后面挂着几百 GB —— '
              '不说这一句，用户以为自己在挪一个空文件夹。');
      expect(note, contains('移动'));
      expect(note, isNot(contains('删')),
          reason: '移动是把整个目录搬走，不是抹掉。写成「一起删掉」会让'
              '用户以为移一次等于删一次，于是不敢移。');
    });

    test('路线行写「从哪来 → 到哪去」，根写「我的网盘」', () {
      expect(
        planAt('/电影', [file('a')], target('d2', '/纪录片')).routeLabel,
        '/电影  →  /纪录片',
      );
      expect(
        planAt('/', [file('a')], target('root', '/')).routeLabel,
        '我的网盘  →  我的网盘',
      );
    });

    test('同名冲突只如实说「没把握」，不做承诺', () {
      final note = planAt('/电影', [file('a')], target('d2', '/纪录片'))
          .sameNameNote;

      expect(note, contains('没有把握'),
          reason: '这条接口的请求体里没有覆盖开关，而「目标目录里已有同名'
              '文件时服务端会覆盖还是改名」我们没有实测过。写成「不会覆盖'
              '已有文件」就是替服务端做承诺 —— 一旦它其实会覆盖，用户会'
              '在毫无预警的情况下丢掉一个文件。');
      expect(note, isNot(contains('不会覆盖')));
    });

    test('全部成功：说「已移动 N 项到「X」」', () {
      final plan = planAt('/电影', [file('a'), file('b')], target('d2', '/纪录片'));
      expect(
        plan.movedMessage(moved: 2, failed: 0),
        '已移动 2 项到「/纪录片」。',
      );
    });

    test('部分失败：必须把失败数说出来', () {
      final plan = planAt('/电影', [for (var i = 0; i < 5; i++) file('f$i')],
          target('d2', '/纪录片'));
      final msg = plan.movedMessage(moved: 3, failed: 2);

      expect(msg, contains('已移动 3 项'));
      expect(msg, contains('2 项失败'),
          reason: '只说「已移动 3 项」会让用户以为全动完了，而剩下那 2 项'
              '还留在原来的目录里 —— 他会以为界面没刷新，然后再移一次'
              '（于是目标目录里来了两份同名的）。');
    });

    test('全部失败：不能说「已移动」', () {
      final plan = planAt('/电影', [file('a'), file('b')], target('d2', '/纪录片'));
      final msg = plan.movedMessage(moved: 0, failed: 2);

      expect(msg, isNot(contains('已移动')));
      expect(msg, contains('2 项'));
      expect(msg, contains('原样还在'),
          reason: '一次都没成功时必须说清「网盘上原样还在」—— 否则用户'
              '不知道东西到底还在不在，可能去目标目录里找、也可能以为'
              '丢了。');
    });
  });
}
