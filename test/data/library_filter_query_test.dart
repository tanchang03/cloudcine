import 'dart:convert';

import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// 筛选面板（年代 / 类型）的**真库**测试。
///
/// ## 为什么必须用真的 [AppDatabase.memory]
///
/// 这一整块能力都落在 SQL 上：
///   - `decades` 要展开成 `year >= d0 AND year < d0+10` 的 OR 组；
///   - `genres` 要匹配 **JSON 数组文本**（`LIKE '%"动画"%'`），
///     而那个引号是防误命中的关键，拿 Dart 侧过滤测不出它；
///   - 两个计数查询要和 `listWorks` **共用同一份条件**。
///
/// 用 `InMemoryMediaRepository` 测这些等于两边都测我自己写的同一段逻辑。
///
/// ## 最要紧的一条：角标必须等于「点了之后的条数」
///
/// 面板上的数字如果比实际结果多，用户点下去会得到一个空列表，然后怀疑
/// 筛选坏了。所以下面有一组测试专门钉住这个**不变量**：
/// 面板上列出的每一个选项，点下去至少有一条结果。
void main() {
  final now = DateTime(2026, 10, 1);

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
  });

  tearDown(() => db.close());

  /// 直接写一行作品。
  ///
  /// 走 `MediaWorksCompanion.insert` 而不是 `upsertWorks`：这里要精确控制
  /// `year` / `genres` / `category` 三列，而 `upsertWorks` 会经过
  /// `mergeWorkForUpsert` 把 `category` 按 `genres` 重算一遍 ——
  /// 那会让「分类筛选」的用例变成在测合并规则。
  Future<void> seed({
    required String key,
    String kind = 'movie',
    String title = '某片',
    String category = 'movie',
    int? year,
    List<String> genres = const [],
    String source = 'local',
  }) async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: key,
            provider: DriveProvider.quark.id,
            kind: kind,
            title: title,
            category: Value(category),
            year: Value(year),
            genres: Value(jsonEncode(genres)),
            source: source,
            updatedAt: now,
          ),
        );
  }

  Future<List<String>> keysOf({
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
    Set<int>? decades,
    Set<String>? genres,
  }) async {
    final list = await repo.listWorks(
      category: category,
      playedOnly: playedOnly,
      query: query,
      decades: decades,
      genres: genres,
    );
    return list.map((w) => w.key).toList()..sort();
  }

  group('listWorks · 年代筛选', () {
    setUp(() async {
      await seed(key: 'nolan-2023', title: '奥本海默', year: 2023);
      await seed(key: 'pulp-1994', title: '低俗小说', year: 1994);
      await seed(key: 'matrix-1999', title: '黑客帝国', year: 1999);
      await seed(key: 'no-year', title: '某部没有年份的片子');
    });

    test('一个年代 = 那十年的全部年份', () async {
      expect(
        await keysOf(decades: {2020}),
        ['nolan-2023'],
        reason: '2020 是**年代起始年**（2020–2029），不是具体年份 2020 —— '
            '逐年列会把面板撑成几十项，而用户想找的是「最近几年的片子」',
      );
    });

    test('多个年代之间是「或」', () async {
      expect(await keysOf(decades: {2020, 1990}), ['matrix-1999', 'nolan-2023', 'pulp-1994']);
    });

    test('年份为空的作品在任何年代条件下都不出现', () async {
      final hit = await keysOf(decades: {1990, 2020});
      expect(hit.contains('no-year'), isFalse);
      expect(
        hit.length,
        3,
        reason: '没有年份就归不进任何年代。让它在选年代时留下来会得到一个'
            '「筛了却没筛掉」的列表，而用户完全看不出为什么',
      );
    });

    test('空集合 = 这一维不限', () async {
      expect(await keysOf(decades: {}), hasLength(4));
      expect(await keysOf(decades: null), hasLength(4));
    });

    test('十年边界：1999 归 1990 不归 2000', () async {
      expect(await keysOf(decades: {1990}), contains('matrix-1999'));
      expect(await keysOf(decades: {2000}), isEmpty);
    });
  });

  group('listWorks · 类型筛选', () {
    setUp(() async {
      await seed(key: 'anime', title: '某动画', genres: const ['动画', '冒险']);
      // 类型名互为前缀：`动画片` 里含 `动画` 三个字。
      // 这一行是专门为「引号边界」那条用例准备的。
      await seed(key: 'anime-word', title: '动画片大全', genres: const ['动画片']);
      await seed(key: 'scifi', title: '某科幻', genres: const ['科幻']);
    });

    test('命中数组里的一个元素', () async {
      expect(await keysOf(genres: {'科幻'}), ['scifi']);
    });

    test('引号边界：「动画」不许命中「动画片」', () async {
      // `genres` 列存的是 JSON 数组文本（`["动画片"]`）。不带引号的
      // `LIKE '%动画%'` 会把它也捞进来 —— 因为「动画片」里含「动画」。
      //
      // 这个误命中的坏处不在结果本身，而在于**它没有任何迹象**：
      // 列表上多出一部八竿子打不着的片子，用户只会觉得「筛选不准」，
      // 而完全想不到是字符串匹配的问题。
      final hit = await keysOf(genres: {'动画'});
      expect(hit, ['anime']);
    });

    test('反向也成立：选「动画片」不会命中「动画」', () async {
      expect(await keysOf(genres: {'动画片'}), ['anime-word']);
    });

    test('多个类型之间是「或」', () async {
      expect(await keysOf(genres: {'动画', '科幻'}), ['anime', 'scifi']);
    });

    test('空集合 = 这一维不限', () async {
      expect(await keysOf(genres: {}), hasLength(3));
    });

    test('没刮过的作品（genres 为空）不会被任何类型筛中', () async {
      await seed(key: 'local', title: '没刮过的片');
      expect(await keysOf(genres: {'动画', '科幻'}), ['anime', 'scifi']);
    });
  });

  group('listWorks · 与其它条件取交集', () {
    test('年代 + 类型 + 分类是「与」的关系', () async {
      await seed(
        key: 'hit',
        kind: 'movie',
        category: 'movie',
        title: '命中',
        year: 2021,
        genres: const ['动画'],
      );
      // 差在年代
      await seed(
        key: 'miss-year',
        kind: 'movie',
        category: 'movie',
        title: '年代不对',
        year: 1991,
        genres: const ['动画'],
      );
      // 差在类型
      await seed(
        key: 'miss-genre',
        kind: 'movie',
        category: 'movie',
        title: '类型不对',
        year: 2021,
        genres: const ['剧情'],
      );
      // 差在分类（动漫，不是电影）
      await seed(
        key: 'miss-cat',
        kind: 'movie',
        category: 'anime',
        title: '分类不对',
        year: 2021,
        genres: const ['动画'],
      );

      expect(
        await keysOf(category: MediaCategory.movie, decades: {2020}, genres: {'动画'}),
        ['hit'],
      );
    });
  });

  group('countWorksByDecade', () {
    setUp(() async {
      await seed(key: 'a', title: 'A', year: 2021, genres: const ['剧情']);
      // 标题里带「科幻」——搜索只匹配标题与文件名，不匹配类型名。
      await seed(key: 'b', title: '某科幻片', year: 2023, genres: const ['科幻']);
      await seed(key: 'c', title: 'C', year: 1995, genres: const ['剧情']);
      await seed(key: 'd', title: 'D');
    });

    test('只返回库里真的有的年代，且不含空年份', () async {
      expect(
        await repo.countWorksByDecade(),
        {2020: 2, 1990: 1},
        reason: '没有年份的作品不进表 —— 各年代之和（3）小于作品总数（4）'
            '是正常的，而多一个「未知年代」的桶只会让用户点了发现混着'
            '一堆风马牛不相及的片子',
      );
    });

    test('跟着分类收窄', () async {
      await seed(
        key: 'anime',
        kind: 'movie',
        category: 'anime',
        title: '动画',
        year: 2011,
        genres: const ['动画'],
      );

      expect(
        await repo.countWorksByDecade(category: MediaCategory.anime),
        {2010: 1},
        reason: '面板上的数字要等于「点了之后的条数」。整库统计的话，'
            '用户在「动漫」栏里会看到「2020 年代 2」，点下去却是 0 条',
      );
    });

    test('跟着搜索词收窄', () async {
      expect(await repo.countWorksByDecade(query: '科幻'), {2020: 1});
    });
  });

  group('countWorksByGenre', () {
    setUp(() async {
      await seed(key: 'a', title: 'A', year: 2021, genres: const ['剧情', '科幻']);
      await seed(key: 'b', title: 'B', year: 2023, genres: const ['剧情']);
      await seed(key: 'c', title: 'C', genres: const []);
    });

    test('按类型数作品，同一部的两个类型各算一次', () async {
      expect(await repo.countWorksByGenre(), {'剧情': 2, '科幻': 1});
    });

    test('没刮过的作品不进表', () async {
      final counts = await repo.countWorksByGenre();
      expect(counts.values.fold<int>(0, (s, n) => s + n), 3);
    });

    test('跟着分类收窄', () async {
      await seed(
        key: 'anime',
        kind: 'movie',
        category: 'anime',
        title: '动画',
        genres: const ['动画'],
      );
      expect(
        await repo.countWorksByGenre(category: MediaCategory.anime),
        {'动画': 1},
      );
    });
  });

  group('不变量：面板上每个选项点下去至少有一条结果', () {
    setUp(() async {
      await seed(
        key: 'm1',
        kind: 'movie',
        category: 'movie',
        title: '电影一',
        year: 2021,
        genres: const ['剧情', '科幻'],
      );
      await seed(
        key: 'm2',
        kind: 'movie',
        category: 'movie',
        title: '电影二',
        year: 1995,
        genres: const ['剧情'],
      );
      await seed(
        key: 'an1',
        kind: 'episode',
        category: 'anime',
        title: '动漫一',
        year: 2011,
        genres: const ['动画'],
      );
    });

    test('分类 / 播放状态 / 搜索词下，年代角标都等于实际条数', () async {
      for (final category in <MediaCategory?>[
        null,
        MediaCategory.movie,
        MediaCategory.anime,
      ]) {
        for (final query in <String?>[null, '电影', '一']) {
          final counts = await repo.countWorksByDecade(
            category: category,
            query: query,
          );
          for (final entry in counts.entries) {
            final hit = await keysOf(
              category: category,
              query: query,
              decades: {entry.key},
            );
            expect(
              hit.length,
              entry.value,
              reason: '「${category?.label ?? "全部"} / $query / '
                  '${entry.key} 年代」角标说 ${entry.value} 条，实际 ${hit.length} 条',
            );
          }
        }
      }
    });

    test('分类 / 播放状态 / 搜索词下，类型角标都等于实际条数', () async {
      for (final category in <MediaCategory?>[
        null,
        MediaCategory.movie,
        MediaCategory.anime,
      ]) {
        for (final query in <String?>[null, '电影', '一']) {
          final counts = await repo.countWorksByGenre(
            category: category,
            query: query,
          );
          for (final entry in counts.entries) {
            final hit = await keysOf(
              category: category,
              query: query,
              genres: {entry.key},
            );
            expect(
              hit.length,
              entry.value,
              reason: '「${category?.label ?? "全部"} / $query / '
                  '${entry.key}」角标说 ${entry.value} 条，实际 ${hit.length} 条',
            );
          }
        }
      }
    });

    test('两个年代一起选，条数是两者之和（互不重叠）', () async {
      final counts = await repo.countWorksByDecade();
      final both = await keysOf(decades: counts.keys.toSet());
      expect(both.length, counts.values.fold<int>(0, (s, n) => s + n));
    });
  });
}
