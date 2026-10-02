import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手动编辑**类型标签**（`genres`）之后的保护规则。
///
/// ## 为什么这一组规则必须钉住
///
/// 「改了也白改」是这类功能最典型的坏法：用户在详情页把类型从「犯罪」改成
/// 「动画」，过两天为了补张海报点了「刮削」—— 类型又被刮回去了。用户不会
/// 想到是刮削干的，只会觉得这个应用**根本不能改类型**。
///
/// 所以 `genresManual` 必须同时守住两条路径：
///
///   1. **重扫**（`incoming.source == local`）：文件名解析带不来类型，
///      但合并分支会拿 `incoming.genres`（空）当新值 —— 没有守卫就被清空；
///   2. **重刮削**（`incoming.source == online`）：这一条才是真危险，
///      因为「覆盖」在这里是**设计上的正常行为**（不保护的话就该覆盖）。
///
/// 两个方向都要有用例：只测「不覆盖」会让「守卫把重刮削也一起冻死了」
/// 这种反向 bug 溜过去。
///
/// ## 为什么类型和分类要一起测
///
/// 分类是从类型折算出来的（`MediaCategoryGuesser.fromGenres`）。类型改了
/// 而分类没跟着走，就会留下一行「类型写着『动画』、分类还是『电影』」——
/// 它不报错，只会让分类栏和详情页各说各话。
void main() {
  final ts = DateTime(2026, 10, 2, 12);

  MediaWork work({
    String key = 'k',
    ScrapeSource source = ScrapeSource.online,
    MediaKind kind = MediaKind.movie,
    MediaCategory? category,
    bool categoryManual = false,
    List<String> genres = const [],
    bool genresManual = false,
  }) =>
      MediaWork(
        key: key,
        provider: DriveProvider.quark,
        kind: kind,
        category: category ??
            switch (kind) {
              MediaKind.movie => MediaCategory.movie,
              MediaKind.episode => MediaCategory.series,
              MediaKind.unknown => MediaCategory.other,
            },
        categoryManual: categoryManual,
        title: '标题',
        genres: genres,
        genresManual: genresManual,
        source: source,
        updatedAt: ts,
      );

  group('mergeWorkForUpsert · 手动类型不被覆盖', () {
    test('重刮削（incoming=online）不覆盖手动编辑过的类型', () {
      final existing = work(genres: const ['动画'], genresManual: true);
      final incoming = work(genres: const ['犯罪', '剧情']);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(
        merged.genres,
        ['动画'],
        reason: '用户就是为了修类型才动手的，再刮一次又冲掉等于白改 —— '
            '而重刮削本来就会覆盖 genres，所以这条守卫必须显式存在。',
      );
      expect(merged.genresManual, isTrue, reason: '标记位不能被一次 upsert 抹掉');
    });

    test('重扫（incoming=local）不把手动类型清空', () {
      final existing = work(genres: const ['动画'], genresManual: true);
      // 文件名解析带不来类型，重扫时 incoming 的 genres 是空的。
      final incoming = work(source: ScrapeSource.local);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.genres, ['动画']);
    });

    test('没手动编辑过时，重刮削照常覆盖（对照）', () {
      final existing = work(genres: const ['科幻']);
      final incoming = work(genres: const ['犯罪']);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(
        merged.genres,
        ['犯罪'],
        reason: '守卫只能拦住「用户手动改过」的行。把它做成无条件的，'
            '「重新刮削」这个功能本身就没意义了。',
      );
    });

    test('手动类型折算出的分类不会被 incoming 的分类冲回去', () {
      final existing = work(
        category: MediaCategory.movie,
        genres: const ['动画'],
        genresManual: true,
      );
      final incoming = work(source: ScrapeSource.local);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(
        merged.category,
        MediaCategory.anime,
        reason: '类型是「动画」，分类就该落到「动漫」—— 两列必须基于同一份'
            '输入（`effectiveGenres`），各算各的会造出自相矛盾的行。',
      );
    });

    test('分类被手动指定时，类型折算不覆盖它', () {
      final existing = work(
        category: MediaCategory.documentary,
        categoryManual: true,
        genres: const ['动画'],
        genresManual: true,
      );
      final incoming = work();

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(
        merged.category,
        MediaCategory.documentary,
        reason: '两个轴各自独立：用户明确指定了分类，加个「动画」类型'
            '不该把它顶掉。',
      );
    });
  });

  group('setWorkGenres · 真库', () {
    late AppDatabase db;
    late DriftMediaRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = DriftMediaRepository(db);
    });

    tearDown(() => db.close());

    Future<MediaWork> reload(String key) async {
      final w = await repo.workByKey(key);
      expect(w, isNotNull, reason: '作品应该在库里');
      return w!;
    }

    test('落库 + 置 genresManual + 分类跟着新类型折算', () async {
      await repo.upsertWorks([work(genres: const ['科幻'])]);

      await repo.setWorkGenres('k', const ['动画', '科幻']);

      final w = await reload('k');
      expect(w.genres, ['动画', '科幻']);
      expect(w.genresManual, isTrue);
      expect(
        w.category,
        MediaCategory.anime,
        reason: '加了「动画」分类就要从电影挪到动漫 —— 否则详情页的类型标签'
            '写着「动画」、分类栏里却在「电影」，用户只会觉得分类坏了。',
      );
    });

    test('新类型给不出结论时保留原分类（不降级）', () async {
      await repo.upsertWorks([
        work(category: MediaCategory.variety, genres: const ['真人秀']),
      ]);

      // 「喜剧」不改变栏目（`fromGenres` 返回 null）。
      await repo.setWorkGenres('k', const ['喜剧']);

      expect(
        (await reload('k')).category,
        MediaCategory.variety,
        reason: '`fromGenres` 给不出结论时不能退回按结构重判 —— 那会把'
            '靠目录名判出来的「综艺」冲成「剧集」。与 `_categoryFor` 同一口径。',
      );
    });

    test('分类是手动指定时，改类型不动分类', () async {
      await repo.upsertWorks([work()]);
      await repo.setWorkCategory('k', MediaCategory.documentary);

      await repo.setWorkGenres('k', const ['动画']);

      final w = await reload('k');
      expect(w.category, MediaCategory.documentary);
      expect(w.genres, ['动画']);
      expect(w.categoryManual, isTrue);
    });

    test('传 null 只清标记、保留类型（交回自动）', () async {
      await repo.upsertWorks([work()]);
      await repo.setWorkGenres('k', const ['动画']);

      await repo.setWorkGenres('k', null);

      final w = await reload('k');
      expect(
        w.genres,
        ['动画'],
        reason: '「交回自动」不等于「清空」—— 清空是破坏性的，'
            '而用户只是想让刮削以后能再接管它。',
      );
      expect(w.genresManual, isFalse);
    });

    test('清掉标记之后，重刮削又能覆盖了', () async {
      await repo.upsertWorks([work(genres: const ['科幻'])]);
      await repo.setWorkGenres('k', const ['动画']);
      await repo.setWorkGenres('k', null);

      await repo.upsertWorks([work(genres: const ['犯罪'])]);

      expect((await reload('k')).genres, ['犯罪']);
    });

    test('手动改过之后，重扫与重刮削都碰不到它', () async {
      await repo.upsertWorks([work(genres: const ['科幻'])]);
      await repo.setWorkGenres('k', const ['动画']);

      // 重扫（本地解析，没有类型）。
      await repo.upsertWorks([work(source: ScrapeSource.local)]);
      expect((await reload('k')).genres, ['动画']);

      // 重刮削（在线源给了别的类型）。
      await repo.upsertWorks([work(genres: const ['犯罪'])]);
      expect((await reload('k')).genres, ['动画']);
    });

    test('作品不在库里时静默返回，不抛异常', () async {
      await expectLater(
        repo.setWorkGenres('不存在', const ['动画']),
        completes,
      );
    });
  });

  group('backfillWorkCategories · 不碰手动指定过的行', () {
    late AppDatabase db;
    late DriftMediaRepository repo;

    setUp(() {
      db = AppDatabase.memory();
      repo = DriftMediaRepository(db);
    });

    tearDown(() => db.close());

    test('手动指定的分类不会被回填按 genres 改回去', () async {
      await repo.upsertWorks([work()]);
      // 用户手动把分类定成「电影」，而类型标签里有「动画」——
      // 回填若只看 genres，会把它改成「动漫」。
      await repo.setWorkGenres('k', const ['动画']);
      await repo.setWorkCategory('k', MediaCategory.movie);

      await repo.backfillWorkCategories();

      final w = await repo.workByKey('k');
      expect(
        w!.category,
        MediaCategory.movie,
        reason: '回填每次开库都跑。不跳过手动行的话，用户手动指定的分类'
            '会在**下一次启动应用时**被悄悄改掉 —— 这是最难查的一种坏法。',
      );
      expect(w.categoryManual, isTrue);
    });
  });
}
