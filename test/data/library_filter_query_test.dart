import 'dart:convert';

import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// 筛选面板（年份 / 类型）的**真库**测试。
///
/// ## 为什么必须用真的 [AppDatabase.memory]
///
/// 这一整块能力都落在 SQL 上：
///   - `years` 走 `year IN (...)` 的等值匹配；
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
    bool scrapedOnly = false,
    String? query,
    Set<int>? years,
    Set<String>? genres,
  }) async {
    final list = await repo.listWorks(
      category: category,
      playedOnly: playedOnly,
      scrapedOnly: scrapedOnly,
      query: query,
      years: years,
      genres: genres,
    );
    return list.map((w) => w.key).toList()..sort();
  }

  group('listWorks · 年份筛选', () {
    setUp(() async {
      await seed(key: 'nolan-2023', title: '奥本海默', year: 2023);
      await seed(key: 'pulp-1994', title: '低俗小说', year: 1994);
      await seed(key: 'matrix-1999', title: '黑客帝国', year: 1999);
      await seed(key: 'no-year', title: '某部没有年份的片子');
    });

    test('一个年份 = 只匹配那一年', () async {
      expect(
        await keysOf(years: {2023}),
        ['nolan-2023'],
        reason: '2023 是**具体年份**，不是年代起始年 —— 只命中 2023 年上映的'
            '作品，1994 / 1999 都不该被带进来',
      );
    });

    test('多个年份之间是「或」', () async {
      expect(await keysOf(years: {2023, 1994}), ['nolan-2023', 'pulp-1994']);
    });

    test('年份为空的作品在任何年份条件下都不出现', () async {
      final hit = await keysOf(years: {1994, 2023});
      expect(hit.contains('no-year'), isFalse);
      expect(
        hit.length,
        2,
        reason: '没有年份就归不进任何年份。让它在选年份时留下来会得到一个'
            '「筛了却没筛掉」的列表，而用户完全看不出为什么',
      );
    });

    test('空集合 = 这一维不限', () async {
      expect(await keysOf(years: {}), hasLength(4));
      expect(await keysOf(years: null), hasLength(4));
    });

    test('按具体年份精确匹配：1999 与 2000 是两年，互不命中', () async {
      expect(await keysOf(years: {1999}), contains('matrix-1999'));
      expect(await keysOf(years: {2000}), isEmpty);
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

  group('listWorks · 已刮削筛选', () {
    setUp(() async {
      await seed(key: 'scraped', title: '刮过的片', source: 'online');
      await seed(key: 'bare', title: '没刮过的片', source: 'local');
      // 「自定义」：用户点过之后在线信息被整份清掉，`source` 落到 manual。
      await seed(key: 'custom', title: '自定义过的片', source: 'manual');
    });

    test('只保留 source = online 的作品', () async {
      expect(
        await keysOf(scrapedOnly: true),
        ['scraped'],
        reason: '判据是**有没有刮到过在线数据**，不是「有没有元数据」。'
            '「自定义」那一行的片名是用户自己敲的、在线信息已被清空，'
            '把它算成「已刮削」会让用户点开发现海报和简介都是空的',
      );
    });

    test('关掉这一项就一条都不筛', () async {
      expect(await keysOf(scrapedOnly: false), hasLength(3));
      expect(await keysOf(), hasLength(3), reason: '默认必须是关的');
    });

    test('与年份 / 类型取交集', () async {
      await seed(
        key: 'scraped-2021',
        title: '刮过的 2021',
        year: 2021,
        genres: const ['动画'],
        source: 'online',
      );
      await seed(
        key: 'local-2021',
        title: '没刮过的 2021',
        year: 2021,
        genres: const ['动画'],
        source: 'local',
      );

      expect(await keysOf(scrapedOnly: true, years: {2021}), ['scraped-2021']);
      expect(await keysOf(scrapedOnly: true, genres: {'动画'}), ['scraped-2021']);
    });
  });

  group('listWorks · 与其它条件取交集', () {
    test('年份 + 类型 + 分类是「与」的关系', () async {
      await seed(
        key: 'hit',
        kind: 'movie',
        category: 'movie',
        title: '命中',
        year: 2021,
        genres: const ['动画'],
      );
      // 差在年份
      await seed(
        key: 'miss-year',
        kind: 'movie',
        category: 'movie',
        title: '年份不对',
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
        await keysOf(category: MediaCategory.movie, years: {2021}, genres: {'动画'}),
        ['hit'],
      );
    });
  });

  group('countWorksByYear', () {
    setUp(() async {
      await seed(key: 'a', title: 'A', year: 2021, genres: const ['剧情']);
      // 标题里带「科幻」——搜索只匹配标题与文件名，不匹配类型名。
      await seed(key: 'b', title: '某科幻片', year: 2023, genres: const ['科幻']);
      await seed(key: 'c', title: 'C', year: 1995, genres: const ['剧情']);
      await seed(key: 'd', title: 'D');
    });

    test('只返回库里真的有的年份，且不含空年份', () async {
      expect(
        await repo.countWorksByYear(),
        {2021: 1, 2023: 1, 1995: 1},
        reason: '没有年份的作品不进表 —— 各年份之和（3）小于作品总数（4）'
            '是正常的，而多一个「未知年份」的桶只会让用户点了发现混着'
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
        await repo.countWorksByYear(category: MediaCategory.anime),
        {2011: 1},
        reason: '面板上的数字要等于「点了之后的条数」。整库统计的话，'
            '用户在「动漫」栏里会看到别的栏目的年份，点下去却是 0 条',
      );
    });

    test('跟着搜索词收窄', () async {
      expect(await repo.countWorksByYear(query: '科幻'), {2023: 1});
    });

    test('跟着「已刮削」收窄', () async {
      // 同一年里两部片子，一部刮过、一部没刮过。
      await seed(key: 'scraped', title: 'S', year: 2001, source: 'online');
      await seed(key: 'bare', title: 'B', year: 2001, source: 'local');

      expect(
        await repo.countWorksByYear(scrapedOnly: true),
        {2001: 1},
        reason: '角标必须等于「打开已刮削之后点这个年份」的条数。不跟着收窄的话，'
            '用户会看到一个只有没刮过的片子才有的年份，点下去是空列表',
      );
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

    test('跟着「已刮削」收窄', () async {
      await seed(
        key: 'scraped',
        title: 'S',
        genres: const ['剧情'],
        source: 'online',
      );
      expect(await repo.countWorksByGenre(scrapedOnly: true), {'剧情': 1});
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

    test('分类 / 播放状态 / 搜索词下，年份角标都等于实际条数', () async {
      for (final category in <MediaCategory?>[
        null,
        MediaCategory.movie,
        MediaCategory.anime,
      ]) {
        for (final query in <String?>[null, '电影', '一']) {
          final counts = await repo.countWorksByYear(
            category: category,
            query: query,
          );
          for (final entry in counts.entries) {
            final hit = await keysOf(
              category: category,
              query: query,
              years: {entry.key},
            );
            expect(
              hit.length,
              entry.value,
              reason: '「${category?.label ?? "全部"} / $query / '
                  '${entry.key} 年」角标说 ${entry.value} 条，实际 ${hit.length} 条',
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

    test('两个年份一起选，条数是两者之和（互不重叠）', () async {
      final counts = await repo.countWorksByYear();
      final both = await keysOf(years: counts.keys.toSet());
      expect(both.length, counts.values.fold<int>(0, (s, n) => s + n));
    });

    test('「已刮削」下的年份 / 类型角标也等于实际条数', () async {
      // 这个 group 的 setUp 里全是**没刮过**的行，只拿它们跑 `scrapedOnly`
      // 会得到空表 —— 下面的循环一次都不执行，那条不变量会以「零次比较」的
      // 方式通过（正是它要防的那种失败）。所以这里另起一批混着的数据。
      await seed(
        key: 's1',
        kind: 'movie',
        category: 'movie',
        title: '刮过的一',
        year: 2021,
        genres: const ['剧情'],
        source: 'online',
      );
      await seed(
        key: 's2',
        kind: 'movie',
        category: 'movie',
        title: '刮过的二',
        year: 1995,
        genres: const ['剧情', '科幻'],
        source: 'online',
      );

      final years = await repo.countWorksByYear(scrapedOnly: true);
      final genres = await repo.countWorksByGenre(scrapedOnly: true);

      expect(years, isNotEmpty, reason: '年份角标空了，下面的循环等于没跑');
      expect(genres, isNotEmpty, reason: '类型角标空了，下面的循环等于没跑');

      for (final entry in years.entries) {
        final hit = await keysOf(scrapedOnly: true, years: {entry.key});
        expect(hit.length, entry.value, reason: '${entry.key} 年');
      }
      for (final entry in genres.entries) {
        final hit = await keysOf(scrapedOnly: true, genres: {entry.key});
        expect(hit.length, entry.value, reason: entry.key);
      }
    });
  });
}
