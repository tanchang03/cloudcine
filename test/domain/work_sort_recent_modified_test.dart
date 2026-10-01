import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/ui/providers/library_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// `WorkSort.recentModified`：按网盘文件修改时间倒序。
///
/// ## 为什么值得一个文件
///
/// 这是**默认排序** —— 任何写错都会影响用户打开媒体库时的第一眼印象。
/// 而且 `lastModifiedAt` 是 nullable 的，NULL 时的排序行为（垫底）必须
/// 与 SQL 侧 `OrderingTerm.desc` 的 NULL 行为对齐。
void main() {
  final now = DateTime(2026, 10, 1);

  /// 构造一部作品，只关心 `lastModifiedAt`。
  MediaWork work(String key, DateTime? lastModifiedAt) => MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: key,
        lastModifiedAt: lastModifiedAt,
        updatedAt: now,
      );

  group('recentModified · InMemoryMediaRepository', () {
    late InMemoryMediaRepository repo;

    setUp(() => repo = InMemoryMediaRepository());

    test('按 lastModifiedAt 倒序排', () async {
      final a = work('a', DateTime(2026, 9, 1)); // 最早
      final b = work('b', DateTime(2026, 9, 15)); // 中间
      final c = work('c', DateTime(2026, 9, 30)); // 最晚

      await repo.upsertWorks([a, b, c], now: now);
      final list = await repo.listWorks(sort: WorkSort.recentModified);

      expect(list.map((w) => w.key).toList(), ['c', 'b', 'a']);
    });

    test('lastModifiedAt 为 null 的垫底', () async {
      final a = work('a', DateTime(2026, 9, 15));
      final b = work('b', null);

      await repo.upsertWorks([a, b], now: now);
      final list = await repo.listWorks(sort: WorkSort.recentModified);

      expect(list.map((w) => w.key).toList(), ['a', 'b']);
    });

    test('全部 null 时按 tie-breaker（年份 + 标题）排', () async {
      final a = work('a', null);
      final b = work('b', null);

      await repo.upsertWorks([a, b], now: now);
      final list = await repo.listWorks(sort: WorkSort.recentModified);

      expect(list.map((w) => w.key).toList(), ['a', 'b']);
    });
  });

  group('recentModified · DriftMediaRepository', () {
    late AppDatabase db;
    late DriftMediaRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = DriftMediaRepository(db);
    });

    tearDown(() => db.close());

    test('按 lastModifiedAt 倒序排', () async {
      final a = work('a', DateTime(2026, 9, 1));
      final b = work('b', DateTime(2026, 9, 15));
      final c = work('c', DateTime(2026, 9, 30));

      await repo.upsertWorks([a, b, c], now: now);
      final list = await repo.listWorks(sort: WorkSort.recentModified);

      expect(list.map((w) => w.key).toList(), ['c', 'b', 'a']);
    });

    test('lastModifiedAt 为 null 的垫底', () async {
      final a = work('a', DateTime(2026, 9, 15));
      final b = work('b', null);

      await repo.upsertWorks([a, b], now: now);
      final list = await repo.listWorks(sort: WorkSort.recentModified);

      expect(list.map((w) => w.key).toList(), ['a', 'b']);
    });

    test('两个实现给出相同顺序', () async {
      final items = [
        work('old', DateTime(2026, 1, 1)),
        work('mid', DateTime(2026, 6, 1)),
        work('new', DateTime(2026, 9, 1)),
        work('none', null),
      ];

      final mem = InMemoryMediaRepository();
      await mem.upsertWorks(items, now: now);
      final memList =
          (await mem.listWorks(sort: WorkSort.recentModified)).map((w) => w.key);

      await repo.upsertWorks(items, now: now);
      final driftList =
          (await repo.listWorks(sort: WorkSort.recentModified)).map((w) => w.key);

      expect(driftList, memList,
          reason: '两个实现的排序口径必须完全一致，否则用户会看到「列表'
              '和内存测试跑出来的不一样」—— 而那通常意味着有一边写错了。');
    });
  });

  test('默认排序是 recentModified', () {
    expect(
      const LibraryFilter().sort,
      WorkSort.recentModified,
      reason: '用户打开媒体库时最常想看的是「我新存/替换的那几部在哪儿」。',
    );
  });
}
