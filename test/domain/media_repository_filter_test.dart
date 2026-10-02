import 'dart:convert';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// 年份 / 类型筛选在两个实现上的**一致性**。
///
/// ## 为什么专门写一份「两个实现比一比」
///
/// `InMemoryMediaRepository` 是测试替身，它比真身弱的话，用它的那些测试
/// 会给出**错误的信心** —— 比如「空态逻辑看着没问题」，而真机上根本走不到
/// 那个分支。这类差异不会让任何测试变红，只会让测试变成摆设。
///
/// 所以这里用同一批数据喂两个实现，把筛选结果逐个对上。口径对不上的话，
/// 这个文件会立刻红，而不是等到某天在真机上发现「列表和替身跑的不一样」。
///
/// ## 为什么分类一律显式给值
///
/// 真身对「分类是空串」的历史行有一套 `kind` 兜底（见
/// `DriftMediaRepository._categoryCondition`），而替身没有 —— 那是**刻意**
/// 的简化（替身里不存在「还没判定过」这种中间态）。这里全部给合法分类，
/// 差异就不会被误报成 bug。
/// 一条作品的数据（两个实现从同一份 spec 各自落库）。
typedef Spec = ({
  String key,
  MediaKind kind,
  MediaCategory category,
  String title,
  int? year,
  List<String> genres,
});

/// 一份筛选条件。
typedef Filter = ({
  MediaCategory? category,
  bool playedOnly,
  String? query,
  Set<int>? years,
  Set<String>? genres,
});

void main() {
  final ts = DateTime(2026, 10, 1);

  final specs = <Spec>[
    (
      key: 'nolan',
      kind: MediaKind.movie,
      category: MediaCategory.movie,
      title: '奥本海默',
      year: 2023,
      genres: ['剧情', '历史'],
    ),
    (
      key: 'pulp',
      kind: MediaKind.movie,
      category: MediaCategory.movie,
      title: '低俗小说',
      year: 1994,
      genres: ['犯罪', '剧情'],
    ),
    (
      key: 'gits',
      kind: MediaKind.movie,
      category: MediaCategory.anime,
      title: '攻壳机动队',
      year: 1995,
      genres: ['动画', '科幻'],
    ),
    (
      key: 'anime-word',
      kind: MediaKind.movie,
      category: MediaCategory.anime,
      title: '动画片大全',
      year: 2021,
      genres: ['动画片'],
    ),
    (
      key: 'no-year',
      kind: MediaKind.episode,
      category: MediaCategory.series,
      title: '某剧',
      year: null,
      genres: ['剧情'],
    ),
    (
      key: 'bare',
      kind: MediaKind.movie,
      category: MediaCategory.movie,
      title: '没刮过的片',
      year: null,
      genres: <String>[],
    ),
  ];

  late AppDatabase db;
  late DriftMediaRepository real;
  late InMemoryMediaRepository fake;

  setUp(() async {
    db = AppDatabase.memory();
    real = DriftMediaRepository(db);
    fake = InMemoryMediaRepository();

    for (final s in specs) {
      await db.into(db.mediaWorks).insert(
            MediaWorksCompanion.insert(
              key: s.key,
              provider: DriveProvider.quark.id,
              kind: s.kind.name,
              title: s.title,
              category: Value(s.category.name),
              year: Value(s.year),
              genres: Value(jsonEncode(s.genres)),
              source: 'local',
              updatedAt: ts,
            ),
          );
    }
    await fake.upsertWorks([
      for (final s in specs)
        MediaWork(
          key: s.key,
          provider: DriveProvider.quark,
          kind: s.kind,
          title: s.title,
          category: s.category,
          year: s.year,
          genres: s.genres,
          updatedAt: ts,
        ),
    ]);
  });

  tearDown(() => db.close());

  /// 一份筛选条件。
  final filters = <Filter>[
    (category: null, playedOnly: false, query: null, years: null, genres: null),
    (category: MediaCategory.movie, playedOnly: false, query: null, years: null, genres: null),
    (category: MediaCategory.anime, playedOnly: false, query: null, years: null, genres: null),
    (category: null, playedOnly: false, query: null, years: {2023}, genres: null),
    (category: null, playedOnly: false, query: null, years: {1994}, genres: null),
    (category: null, playedOnly: false, query: null, years: {1994, 2023}, genres: null),
    (category: null, playedOnly: false, query: null, years: null, genres: {'剧情'}),
    (category: null, playedOnly: false, query: null, years: null, genres: {'动画'}),
    (category: null, playedOnly: false, query: null, years: null, genres: {'动画片'}),
    (category: null, playedOnly: false, query: null, years: null, genres: {'动画', '科幻'}),
    (category: MediaCategory.anime, playedOnly: false, query: null, years: null, genres: {'动画'}),
    (category: MediaCategory.movie, playedOnly: false, query: null, years: {2023}, genres: {'剧情'}),
    (category: null, playedOnly: false, query: '小说', years: null, genres: null),
    (category: null, playedOnly: false, query: '某剧', years: null, genres: null),
  ];

  Future<List<String>> keys(
    MediaRepository repo,
    Filter f, {
    int limit = 200,
  }) async {
    final list = await repo.listWorks(
      category: f.category,
      playedOnly: f.playedOnly,
      query: f.query,
      years: f.years,
      genres: f.genres,
      limit: limit,
    );
    return list.map((w) => w.key).toList()..sort();
  }

  test('listWorks：每个筛选组合，两个实现给出同一批作品', () async {
    for (final f in filters) {
      final a = await keys(real, f);
      final b = await keys(fake, f);
      expect(
        b,
        a,
        reason: '条件 $f：真身给了 $a，替身给了 $b。替身比真身松或紧都会让'
            '用它的测试给出错误的信心 —— 而那种差异不会自己暴露出来',
      );
    }
  });

  test('countWorksByYear：两个实现一致，且等于实际条数', () async {
    for (final f in filters) {
      final a = await real.countWorksByYear(
        category: f.category,
        playedOnly: f.playedOnly,
        query: f.query,
      );
      final b = await fake.countWorksByYear(
        category: f.category,
        playedOnly: f.playedOnly,
        query: f.query,
      );
      expect(b, a, reason: '条件 $f 的年份分布：真身 $a，替身 $b');

      // 角标 == 点了之后的条数（面板上的数字必须能兑现）。
      for (final entry in a.entries) {
        final hit = await keys(real, (
          category: f.category,
          playedOnly: f.playedOnly,
          query: f.query,
          years: {entry.key},
          genres: null,
        ));
        expect(hit.length, entry.value, reason: '条件 $f / ${entry.key} 年');
      }
    }
  });

  test('countWorksByGenre：两个实现一致，且等于实际条数', () async {
    for (final f in filters) {
      final a = await real.countWorksByGenre(
        category: f.category,
        playedOnly: f.playedOnly,
        query: f.query,
      );
      final b = await fake.countWorksByGenre(
        category: f.category,
        playedOnly: f.playedOnly,
        query: f.query,
      );
      expect(b, a, reason: '条件 $f 的类型分布：真身 $a，替身 $b');

      for (final entry in a.entries) {
        final hit = await keys(real, (
          category: f.category,
          playedOnly: f.playedOnly,
          query: f.query,
          years: null,
          genres: {entry.key},
        ));
        expect(hit.length, entry.value, reason: '条件 $f / ${entry.key}');
      }
    }
  });

  test('替身与真身都遵守「空集合 = 这一维不限」', () async {
    for (final repo in <MediaRepository>[real, fake]) {
      expect((await keys(repo, (
        category: null,
        playedOnly: false,
        query: null,
        years: <int>{},
        genres: <String>{},
      ))).length, specs.length);
    }
  });
}
