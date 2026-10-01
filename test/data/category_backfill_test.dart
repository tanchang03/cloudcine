import 'dart:convert';

import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// `backfillWorkCategories` 的**真库**测试。
///
/// ## 为什么这里必须用真的 [AppDatabase.memory]
///
/// 这个方法要验的恰恰是 **SQL 那一侧**的行为：「哪些行会被选中」、「只在
/// 结果真的不同时才写」。`InMemoryMediaRepository` 把整个 SQL 跳过了，
/// 拿它测只会得到「两边都是我写的，当然一致」。
///
/// ## 它为什么值得单独一个文件
///
/// 它挂在 `workListProvider` 前面 —— **每次进媒体库都会跑**。跑错了有两个
/// 方向：漏修（用户看到分类没生效）和过修（把靠目录名判出来的「综艺」冲成
/// 「剧集」）。后者更坏：用户不会想到是回填干的，只会觉得「我的综艺不见了」。
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
  /// 走 `MediaWorksCompanion.insert` 而不是仓储的 `upsertWorks`：只有它能
  /// 写出**空串分类**（v3 之前入库的老行长这样），而 `upsertWorks` 收的是
  /// `MediaWork`，`category` 那一列永远是个合法的枚举名。
  Future<void> seed({
    required String key,
    required String kind,
    required String title,
    String category = '',
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
            genres: Value(jsonEncode(genres)),
            source: source,
            updatedAt: now,
          ),
        );
  }

  Future<MediaCategory> categoryOf(String key) async {
    final row = await (db.select(db.mediaWorks)
          ..where((t) => t.key.equals(key)))
        .getSingle();
    return MediaCategory.fromName(row.category);
  }

  group('backfillWorkCategories · 老库回填', () {
    test('分类是空串的老行按 kind 补算', () async {
      await seed(key: 'a', kind: 'movie', title: '某电影');
      await seed(key: 'b', kind: 'episode', title: '某剧');

      final fixed = await repo.backfillWorkCategories();

      expect(fixed, 2);
      expect(await categoryOf('a'), MediaCategory.movie);
      expect(await categoryOf('b'), MediaCategory.series);
    });

    test('空分类 + 标题里有综艺关键词 → 关键词优先于 kind', () async {
      // 综艺的文件名解析不出季集号，kind 会是 unknown；先按 kind 落「其他」
      // 的话关键词表就永远没机会生效。
      await seed(key: 'a', kind: 'unknown', title: '某某综艺盛典');
      // 结构信号同理：`第12期` 是综艺最稳的标记，电视剧用「集」不用「期」。
      await seed(key: 'b', kind: 'unknown', title: '奔跑吧.第12期');

      await repo.backfillWorkCategories();

      expect(await categoryOf('a'), MediaCategory.variety);
      expect(await categoryOf('b'), MediaCategory.variety);
    });

    test('空表返回 0，不炸', () async {
      expect(await repo.backfillWorkCategories(), 0);
    });
  });

  group('backfillWorkCategories · 刮削类型折算', () {
    test('已刮削的作品：TMDB 说是动画 → 从「电影」挪到「动漫」', () async {
      await seed(
        key: 'a',
        kind: 'movie',
        title: '超级马力欧银河大电影',
        category: 'movie',
        genres: const ['动画', '冒险', '喜剧'],
        source: 'online',
      );

      final fixed = await repo.backfillWorkCategories();

      expect(fixed, 1);
      expect(
        await categoryOf('a'),
        MediaCategory.anime,
        reason: '目录名里没有「动漫」二字，扫描期只能按结构判成「电影」。'
            'TMDB 的「动画」是更可信的证据，而这条证据以前**永远用不上**：'
            '扫描期调 guess 时不传 genres（那时还没刮削），两个回填入口又只'
            '处理空分类的行 —— 刮过的作品分类非空，永远轮不到。',
      );
    });

    test('genres 给不出结论 → 保留扫描期的判定，不许按 kind 冲掉', () async {
      // 用户把综艺放在 /综艺/ 目录里，扫描期靠目录名正确地判成了 variety；
      // 而 TMDB 对国产综艺常常给不出「真人秀」这个类型，只给「剧情」。
      await seed(
        key: 'a',
        kind: 'episode',
        title: '奔跑吧',
        category: 'variety',
        genres: const ['剧情'],
        source: 'online',
      );

      final fixed = await repo.backfillWorkCategories();

      expect(fixed, 0);
      expect(
        await categoryOf('a'),
        MediaCategory.variety,
        reason: '这里如果走完整的 guessFromWork，它的兜底那步会按 '
            'kind=episode 把这一行冲成「剧集」—— 用户看到的是「我的综艺'
            '栏目空了」，而且怎么重扫都修不回来。',
      );
    });

    test('没刮过的作品（genres 空）不受影响', () async {
      await seed(
        key: 'a',
        kind: 'movie',
        title: '某电影',
        category: 'movie',
      );

      expect(await repo.backfillWorkCategories(), 0);
      expect(await categoryOf('a'), MediaCategory.movie);
    });

    test('纪录片 / 真人秀同样能折算过来', () async {
      await seed(
        key: 'doc',
        kind: 'episode',
        title: '蓝色星球',
        category: 'series',
        genres: const ['纪录'],
        source: 'online',
      );
      await seed(
        key: 'show',
        kind: 'episode',
        title: '某某秀',
        category: 'series',
        genres: const ['真人秀'],
        source: 'online',
      );

      expect(await repo.backfillWorkCategories(), 2);
      expect(await categoryOf('doc'), MediaCategory.documentary);
      expect(await categoryOf('show'), MediaCategory.variety);
    });
  });

  group('backfillWorkCategories · 幂等', () {
    test('修好之后再跑一遍不写任何东西', () async {
      await seed(
        key: 'a',
        kind: 'movie',
        title: '某片',
        category: 'movie',
        genres: const ['动画'],
        source: 'online',
      );

      expect(await repo.backfillWorkCategories(), 1);
      expect(
        await repo.backfillWorkCategories(),
        0,
        reason: '它挂在 workListProvider 前面，每次进媒体库都会跑。'
            '不幂等的话每次启动都要写一遍全表 —— 而这是个读路径。',
      );
      expect(await categoryOf('a'), MediaCategory.anime);
    });

    test('分类已经对的行不写（返回 0）', () async {
      await seed(
        key: 'a',
        kind: 'episode',
        title: '进击的巨人',
        category: 'anime',
        genres: const ['动画'],
        source: 'online',
      );

      expect(
        await repo.backfillWorkCategories(),
        0,
        reason: '扫描期靠目录名判成 anime、刮削又印证了 anime —— 结果相同，'
            '没有理由写库。',
      );
    });
  });
}
