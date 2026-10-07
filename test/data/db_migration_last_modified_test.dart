import 'dart:io';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 索引库 v5 → v6 → v7 迁移：`media_works.lastModifiedAt` + `firstSeenAt`。
///
/// ## 为什么值得一个文件
///
/// 这一列是**默认排序**（`WorkSort.recentModified`）的唯一依据，所以
/// 「加了列但没写迁移」不是「某个细节显示不出来」，而是**媒体库一打开
/// 就整页报错**（`no such column: last_modified_at`）—— 用户拿到新版本
/// 的第一印象就是这个。
///
/// 而这类错误**编译期发现不了**：drift 在编译期只认 `tables.dart`，
/// 磁盘上那个旧库长什么样它管不着。唯一能兜住它的就是真的拿一个
/// **旧版本库文件**跑一遍迁移。
///
/// ## 老库是怎么造出来的
///
/// 不手写 v5 的建表 SQL（那等于把 schema 抄一份，抄错/漏更新都只会
/// 让测试假装通过）。这里反过来做：先按当前 schema 建出库，再把
/// v6 才有的那列 **DROP 掉**、把 `PRAGMA user_version` 指回 5 ——
/// 于是它就是一个货真价实的「v5 老库」，reopen 时 drift 必须走
/// `onUpgrade`。
void main() {
  final now = DateTime(2026, 10, 1);

  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('cloudcine_mig'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 造一个存着 [items] / [works] 的 **v5 老库**，返回它的库文件。
  ///
  /// [resumeByFileId] 用来给老库预置续播点（键是 `fileId`）—— v15 迁移要从
  /// 它回填历史最大位置的下界，所以必须能造出「老库里已经有续播点」的状态。
  Future<File> makeOldV5Database({
    required List<MediaItem> items,
    required List<MediaWork> works,
    Map<String, Duration> resumeByFileId = const {},
  }) async {
    final file = File('${dir.path}/cloudcine.sqlite');

    // 第一步：建一个当前版本（v6）的库，把数据塞进去。
    final seed = AppDatabase(NativeDatabase(file));
    final repo = DriftMediaRepository(seed);
    await repo.upsertItems(items, now: now);
    await repo.upsertWorks(works, now: now);
    for (final e in resumeByFileId.entries) {
      final target = items.firstWhere((i) => i.fileId == e.key);
      await repo.saveResumePosition(target.id, e.value);
    }
    addTearDown(seed.close);

    // 第二步：降回 v5 —— 删掉 v6/v7/v8 才有的列 + 改版本号。
    // 此后这个文件对 drift 来说就是一个「还没升级过的老库」。
    //
    // ⚠️ 加新列时**必须**把新列也 DROP 掉：建库用的是当前 schema，
    // 所有列一开始就都在。漏掉一列的话，reopen 时 `onUpgrade` 会对一个
    // 已经存在的列执行 `ADD COLUMN` → `duplicate column name`，
    // 而这条测试就会以一个和「迁移写没写」无关的理由变红。
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN last_modified_at',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN first_seen_at',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN category_manual',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN genres_manual',
    );
    // v9：`media_items` 的分部两列。
    await seed.customStatement('ALTER TABLE media_items DROP COLUMN part');
    await seed.customStatement('ALTER TABLE media_items DROP COLUMN part_label');
    // v10：`media_works` 的季数。
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN season_count',
    );
    // v11：`media_works` 的折叠标记。
    //
    // ⚠️ 加了新列就要在这里补一行 DROP —— 这个用例是「拿当前 schema 建库、
    // 再删掉新列、把 user_version 调回 5」来伪造老库的。漏删的话 `onUpgrade`
    // 会在 `addColumn` 上撞到 `duplicate column name`，而报错信息完全指不到
    // 这个用例。
    await seed.customStatement('ALTER TABLE media_works DROP COLUMN merged_into');
    // v12：手标片头区间两列。同样要 DROP —— 见上方整段注释：建库用的是当前
    // schema，漏删的话 `onUpgrade` 会在 `addColumn` 上撞 `duplicate column
    // name`。
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN intro_start_ms',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN intro_end_ms',
    );
    // v13：`media_items` 的文件级封面锚点。同一条规矩 —— 加列就要在这里
    // DROP，否则 reopen 时 `ADD COLUMN face_anchor_x` 撞 duplicate。
    await seed.customStatement(
      'ALTER TABLE media_items DROP COLUMN face_anchor_x',
    );
    // v15：`media_items` 的历史最大播放位置。同样是一条规矩 —— 加列就要在这里
    // DROP，否则 reopen 时 `ADD COLUMN max_position_ms` 撞 duplicate。
    //
    // ⚠️ v14 的 `playback_prefs`、v16 的 `download_tasks` 那种**新表**不用管：
    // `Migrator.createTable` 发的是 `CREATE TABLE IF NOT EXISTS`，本来就不会撞
    // —— 只有加**列**才需要在这里配一行。
    await seed.customStatement(
      'ALTER TABLE media_items DROP COLUMN max_position_ms',
    );
    // v17：`media_works` 的追剧 4 列。同一条规矩 —— 加列就要在这里配一行 DROP。
    //
    // ⛔ 2026-10-07 补：v17 落地时漏了这一组，于是这整份用例全红在
    //    `duplicate column name: followed` 上 —— 而报错信息完全指不到这里
    //    （加追剧列的人只跑了 `test/domain` 与 `test/ui`，没跑 `test/data`）。
    await seed.customStatement('ALTER TABLE media_works DROP COLUMN followed');
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN follow_started_at',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN follow_checked_at',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN new_item_count',
    );
    await seed.customStatement('PRAGMA user_version = 5');
    await seed.close();

    return file;
  }

  /// 打开 [file]（会触发迁移），返回查询入口。
  Future<DriftMediaRepository> reopen(File file) async {
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    return DriftMediaRepository(db);
  }

  MediaItem item(
    String name, {
    required String groupKey,
    DateTime? modifiedAt,
    int? season,
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: name,
        name: '$name.mkv',
        dirId: 'dir',
        dirPath: '/电影/',
        groupKey: groupKey,
        kind: MediaKind.movie,
        season: season,
        modifiedAt: modifiedAt,
        firstSeenAt: now,
        updatedAt: now,
      );

  MediaWork work(String key, {int itemCount = 0}) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: key,
        itemCount: itemCount,
        updatedAt: now,
      );

  test('升级后能按「最近修改」查询 —— 不再报 no such column', () async {
    final file = await makeOldV5Database(
      items: [item('a', groupKey: 'w', modifiedAt: DateTime(2026, 9, 1))],
      works: [work('w')],
    );

    final repo = await reopen(file);

    // 这一句就是用户实际崩掉的那条查询：迁移没写的话，drift 生成的
    // SQL 里会有 last_modified_at，而库里没这列 → SqliteException。
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(list.map((w) => w.key).toList(), ['w']);
  });

  test('回填值 = 该作品下所有文件 modifiedAt 的最大值', () async {
    final file = await makeOldV5Database(
      items: [
        item('ep1', groupKey: 'w', modifiedAt: DateTime(2026, 9, 1)),
        item('ep2', groupKey: 'w', modifiedAt: DateTime(2026, 9, 20)),
        item('ep3', groupKey: 'w', modifiedAt: DateTime(2026, 9, 10)),
      ],
      works: [work('w')],
    );

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(
      list.single.lastModifiedAt,
      DateTime(2026, 9, 20),
      reason: '取最大值而不是第一条 / 最后一条：新增或替换一集时这个值'
          '必须变大，作品才会浮到「最近修改」的前面。',
    );
  });

  test('文件都没有修改时间时保持 null，不编一个值出来', () async {
    final file = await makeOldV5Database(
      items: [item('ep1', groupKey: 'w')],
      works: [work('w')],
    );

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(
      list.single.lastModifiedAt,
      isNull,
      reason: '没有信息就是没有信息。编一个值（比如入库时间）会让「最近修改」'
          '退化成「最近添加」，用户就再也分不出这两件事了。',
    );
  });

  test('没有任何文件的作品保持 null', () async {
    final file = await makeOldV5Database(items: [], works: [work('w')]);

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(list.single.lastModifiedAt, isNull);
  });

  test('迁移不会顺手弄坏别的字段', () async {
    final file = await makeOldV5Database(
      items: [item('ep1', groupKey: 'w', modifiedAt: DateTime(2026, 9, 5))],
      works: [work('w', itemCount: 1)],
    );

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    // 迁移只碰了 last_modified_at 一列；标题/计数这类既有数据必须原样在。
    expect(list.single.title, 'w');
    expect(list.single.itemCount, 1);
  });

  test('v8 迁移后两个手动标记位都是 false（老库的分类仍是自动判定的）', () async {
    final file = await makeOldV5Database(
      items: [item('ep1', groupKey: 'w', modifiedAt: DateTime(2026, 9, 5))],
      works: [work('w', itemCount: 1)],
    );

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(
      list.single.categoryManual,
      isFalse,
      reason: '老库里的分类是自动判定的结果，不能因为加了这一列就把它'
          '「升级」成用户手动指定 —— 那会让后续刮削再也改不动它。',
    );
    expect(list.single.genresManual, isFalse);
  });

  test('v10 迁移回填季数 —— 去重、且不算「未标季」', () async {
    final file = await makeOldV5Database(
      items: [
        item('a', groupKey: 'w', season: 1),
        item('b', groupKey: 'w', season: 2),
        item('c', groupKey: 'w', season: 2),
        item('d', groupKey: 'w'), // 未标季
      ],
      works: [work('w', itemCount: 4)],
    );

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(
      list.single.seasonCount,
      2,
      reason: '4 集里有 2 个不同季号（1、2）+ 1 集未标季 → 2 季。'
          '不去重会数成 3；把「未标季」也算进去会数成 3。',
    );
  });

  test('v10 迁移：没有季号的作品季数是 0，卡片上不出现「N 季」', () async {
    final file = await makeOldV5Database(
      items: [item('a', groupKey: 'w')],
      works: [work('w', itemCount: 1)],
    );

    final repo = await reopen(file);
    final list = await repo.listWorks(sort: WorkSort.recentModified);

    expect(list.single.seasonCount, 0);
    expect(
      list.single.subtitleLine.contains('季'),
      isFalse,
      reason: '0 或 1 季写在卡片上都是废话，只有 >= 2 才有信息量',
    );
  });

  test('v15 迁移：历史最大位置从续播点回填 —— 老条目不再显示「没看过」', () async {
    final file = await makeOldV5Database(
      items: [item('ep1', groupKey: 'w'), item('ep2', groupKey: 'w')],
      works: [work('w', itemCount: 2)],
      resumeByFileId: {'ep1': const Duration(minutes: 12)},
    );

    final repo = await reopen(file);
    final items = await repo.itemsForWork('w');
    final ep1 = items.firstWhere((i) => i.fileId == 'ep1');
    final ep2 = items.firstWhere((i) => i.fileId == 'ep2');

    final max = await repo.maxPositions([ep1.id, ep2.id]);

    expect(
      max[ep1.id],
      const Duration(minutes: 12),
      reason: '续播点是历史最大位置的**下界**：库里存着「看到 12 分钟」，就说明'
          '用户至少到过 12 分钟。不回填的话，升级后所有老条目在详情页都显示'
          '「没看过」—— 而它们其实看过，只是那一刻之前我们没记过这个量。',
    );
    expect(
      max.containsKey(ep2.id),
      isFalse,
      reason: '没播过的条目不能被回填出一条记录：NULL 才是「没看过」，'
          '补一个 0 会让它的行底下出现一条空进度条。',
    );
  });

  test('v15 迁移：回填的是下界，之后播得更远会正常推进', () async {
    final file = await makeOldV5Database(
      items: [item('ep1', groupKey: 'w')],
      works: [work('w', itemCount: 1)],
      resumeByFileId: {'ep1': const Duration(minutes: 12)},
    );

    final repo = await reopen(file);
    final ep1 = (await repo.itemsForWork('w')).single;

    await repo.saveMaxPosition(ep1.id, const Duration(minutes: 40));

    expect(
      (await repo.maxPositions([ep1.id]))[ep1.id],
      const Duration(minutes: 40),
      reason: '回填值必须走同一条「只增不减」的路 —— 它只是初始值，不是天花板。',
    );
  });
}
