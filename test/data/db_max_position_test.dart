import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「历史最大位置」在 **drift 实现**里的语义。
///
/// ## 为什么不能只测内存实现
///
/// 「只增不减」在这两个实现里是**两份不同的代码**：内存版是一句
/// `if (stored >= position) return`，drift 版是一条 SQL
/// （`SET max_position_ms = max(COALESCE(max_position_ms, 0), ?)`）。
/// 只测内存版的话，那条 SQL 写错了不会有任何用例变红 —— 而它正是真机上
/// 唯一跑的那一份。
///
/// 特别是 SQLite 那个 `max()`：**两个参数**是标量函数（取大者），
/// **一个参数**是聚合函数。写成 `max(?)` 就变成了对整表求最大值 ——
/// 一条写错方向的语句，不报错，只是把别人的进度盖到自己头上。
void main() {
  final ts = DateTime(2026, 10, 3);

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftMediaRepository(db);
  });
  tearDown(() => db.close());

  MediaItem item(String fileId) => MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: '$fileId.mkv',
        dirId: 'd1',
        dirPath: '/剧集/看过的剧/',
        groupKey: '看过的剧',
        kind: MediaKind.episode,
        firstSeenAt: ts,
        updatedAt: ts,
      );

  Future<List<String>> seeded(List<String> fileIds) async {
    final items = fileIds.map(item).toList();
    await repo.upsertItems(items);
    return items.map((i) => i.id).toList(growable: false);
  }

  test('存了就能按 id 读回来', () async {
    final ids = await seeded(['f1']);
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));
    expect((await repo.maxPositions(ids))[ids[0]], const Duration(minutes: 12));
  });

  test('只增不减 —— 后写的更小位置不会把进度拉回去', () async {
    final ids = await seeded(['f1']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 40));
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 5));

    expect(
      (await repo.maxPositions(ids))[ids[0]],
      const Duration(minutes: 40),
      reason: 'SQL 里那个 max() 必须是**两参数**的标量函数。写成单参数聚合，'
          '或者干脆直接赋值，用户回拖一次进度条就退回去一次。',
    );
  });

  test('每个条目的进度互不串台', () async {
    final ids = await seeded(['f1', 'f2']);

    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));
    await repo.saveMaxPosition(ids[1], const Duration(minutes: 47));

    final max = await repo.maxPositions(ids);
    expect(max[ids[0]], const Duration(minutes: 12));
    expect(max[ids[1]], const Duration(minutes: 47));
    expect(
      max.length,
      2,
      reason: 'WHERE id = ? 漏掉的话，一次落库会把整表都写成同一个位置 —— '
          '表现是「播一集，全库的进度条都跟着变」。',
    );
  });

  test('写 0 是无操作：既不建记录，也不会把已有的拉下来', () async {
    final ids = await seeded(['f1', 'f2']);

    // 没写过的：不该出现。
    await repo.saveMaxPosition(ids[0], Duration.zero);
    // 写过的：不该被拉下来。
    await repo.saveMaxPosition(ids[1], const Duration(minutes: 30));
    await repo.saveMaxPosition(ids[1], Duration.zero);

    final max = await repo.maxPositions(ids);
    expect(max.containsKey(ids[0]), isFalse);
    expect(max[ids[1]], const Duration(minutes: 30));
  });

  test('从没播过的条目列是 NULL，不返回给调用方', () async {
    final ids = await seeded(['f1', 'f2']);
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 12));

    final max = await repo.maxPositions(ids);
    expect(max.keys, [ids[0]]);
  });

  test('空 id 列表直接返回空表（不拼一条 `IN ()` 的空查询）', () async {
    await seeded(['f1']);
    expect(await repo.maxPositions(const []), isEmpty);
  });

  test('v15 迁移回填的下界也走同一条只增不减的规则', () async {
    final ids = await seeded(['f1']);

    // 模拟迁移刚回填完的样子：续播点 12 分钟 → 历史最大位置 12 分钟。
    // ⚠️ `customStatement` 的参数是**原始值**，不是 `Variable`。
    await db.customStatement(
      'UPDATE media_items SET max_position_ms = 720000 WHERE id = ?',
      [ids[0]],
    );

    // 用户接着从 12 分钟往后看。
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 20));
    expect((await repo.maxPositions(ids))[ids[0]], const Duration(minutes: 20));

    // 再回拖一次，仍然不回退。
    await repo.saveMaxPosition(ids[0], const Duration(minutes: 13));
    expect((await repo.maxPositions(ids))[ids[0]], const Duration(minutes: 20));
  });
}
