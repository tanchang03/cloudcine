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
  Future<File> makeOldV5Database({
    required List<MediaItem> items,
    required List<MediaWork> works,
  }) async {
    final file = File('${dir.path}/cloudcine.sqlite');

    // 第一步：建一个当前版本（v6）的库，把数据塞进去。
    final seed = AppDatabase(NativeDatabase(file));
    final repo = DriftMediaRepository(seed);
    await repo.upsertItems(items, now: now);
    await repo.upsertWorks(works, now: now);
    addTearDown(seed.close);

    // 第二步：降回 v5 —— 删掉 v6/v7 才有的列 + 改版本号。
    // 此后这个文件对 drift 来说就是一个「还没升级过的老库」。
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN last_modified_at',
    );
    await seed.customStatement(
      'ALTER TABLE media_works DROP COLUMN first_seen_at',
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
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: name,
        name: '$name.mkv',
        dirId: 'dir',
        dirPath: '/电影/',
        groupKey: groupKey,
        kind: MediaKind.movie,
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
}
