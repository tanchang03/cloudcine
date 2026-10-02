import 'dart:convert';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/app_database.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// `customizeWork` 的**真库**测试。
///
/// ## 为什么必须用真的 [AppDatabase.memory]
///
/// 要验的是「海报那一列真的被写成 NULL 了没有」。`upsertWorks` 的合并规则里
/// 有一条「**海报地址永不为空**」的兜底（为「某次扫描恰好没拿到缩略图」
/// 准备的）：本次地址为 `null` 时它会保留库里那个旧地址。所以「自定义」
/// **不能**走合并，只能整行写 —— 而这件事在纯 Dart 层看不出来，那里没有
/// SQL，也就没有那条兜底。少了这个文件，最可能的回归是「清了个寂寞」：
/// 编译通过、测试全绿、界面上那张刮错的海报纹丝不动。
void main() {
  final now = DateTime(2026, 10, 2);

  late AppDatabase db;
  late DriftMediaRepository repo;

  setUp(() {
    db = AppDatabase.memory();
    repo = DriftMediaRepository(db);
  });

  tearDown(() => db.close());

  /// 直接写一行**已刮削**的作品（海报、简介、评分齐全）。
  ///
  /// 走 `MediaWorksCompanion.insert` 而不是仓储：这里要精确控制每一列，
  /// 而 `upsertWorks` 的合并规则会干扰。
  Future<void> seedScraped() async {
    await db.into(db.mediaWorks).insert(
          MediaWorksCompanion.insert(
            key: 'w',
            provider: DriveProvider.quark.id,
            kind: 'episode',
            title: '低俗小说',
            category: const Value('movie'),
            year: const Value(1994),
            overview: const Value('两个杀手…'),
            posterUrl: const Value('https://image.tmdb.org/wrong.jpg'),
            posterFile: const Value('w_abc.jpg'),
            posterFaceX: const Value(0.42),
            rating: const Value(8.9),
            genres: Value(jsonEncode(const ['犯罪'])),
            onlineId: const Value('movie/680'),
            source: 'online',
            scrapedAt: Value(DateTime(2026, 1, 1)),
            itemCount: const Value(12),
            totalBytes: const Value(9000000),
            updatedAt: now,
          ),
        );
  }

  Future<MediaWorkRow> row() async =>
      (db.select(db.mediaWorks)..where((t) => t.key.equals('w'))).getSingle();

  test('整行写：刮错的海报真的被清成 NULL', () async {
    await seedScraped();

    final written = await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    expect(written, isNotNull);
    final r = await row();

    expect(
      r.posterUrl,
      isNull,
      reason: '这是整个功能的**核心断言**。走 `upsertWorks` 的话，'
          '「海报地址永不为空」那条兜底会把旧地址补回来 —— '
          '用户点了「自定义」，那张刮错的海报还挂在详情页上，'
          '而且没有任何报错。',
    );
    expect(r.posterFile, isNull);
    expect(r.posterFaceX, isNull, reason: '锚点跟着地址一起走。');
    expect(r.overview, isNull);
    expect(r.rating, isNull);
    expect(r.year, isNull);
    expect(r.onlineId, isNull);
    expect(r.scrapedAt, isNull);
    expect(r.genres, '[]');
  });

  /// 插一条**这部作品名下**的文件，带网盘缩略图与人脸锚点。
  Future<void> seedItem({
    required String fileId,
    String? thumbUrl,
    double? faceX,
    bool extra = false,
  }) async {
    await db.into(db.mediaItems).insert(
          MediaItemsCompanion.insert(
            id: 'quark:$fileId',
            provider: DriveProvider.quark.id,
            fileId: fileId,
            name: '$fileId.mkv',
            dirId: const Value('d'),
            dirPath: const Value('/演唱会/'),
            groupKey: 'w',
            kind: 'episode',
            isSampleOrExtra: Value(extra),
            thumbUrl: Value(thumbUrl),
            faceAnchorX: Value(faceX),
            firstSeenAt: now,
            updatedAt: now,
          ),
        );
  }

  test('清掉刮错的海报后，封面回落到网盘缩略图', () async {
    await seedScraped();
    await seedItem(
      fileId: 'f01',
      thumbUrl: 'https://drive-pc.quark.cn/thumb?fid=f01',
      faceX: 0.28,
    );

    await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    final r = await row();
    expect(
      r.posterUrl,
      'https://drive-pc.quark.cn/thumb?fid=f01',
      reason: '「自定义」要去掉的是**刮错的那张**，不是「这部作品从此没有'
          '封面」。缩略图一直存在 item 行上（夸克给每个视频生成的服务端'
          '预览图），清成 NULL 的话用户点完就看到一墙灰块。',
    );
    expect(r.posterFaceX, 0.28, reason: '锚点必须与地址同源、成对。');
    expect(
      r.posterFile,
      isNull,
      reason: '图换了 → 缓存文件名必须换，否则 PosterCache 见 knownFile '
          '存在就返回旧文件，封面显示成前一张。',
    );
    // 该清的在线痕迹仍然清干净 —— 补回落不能顺手把「清空」这个功能弄坏。
    expect(r.overview, isNull);
    expect(r.rating, isNull);
    expect(r.onlineId, isNull);
    expect(r.scrapedAt, isNull);
  });

  test('名下文件都没缩略图 → 海报真的清空', () async {
    await seedScraped();
    await seedItem(fileId: 'f01'); // 夸克约 30% 的视频还没生成预览图

    await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    final r = await row();
    expect(r.posterUrl, isNull, reason: '没有本地可用来源时就是没有封面，不造地址。');
    expect(r.posterFaceX, isNull);
  });

  test('写入片名 / 分类，锁住分类，来源标成手动修改', () async {
    await seedScraped();

    await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    final work = await repo.workByKey('w');
    expect(work!.title, '2024 演唱会现场');
    expect(work.category, MediaCategory.other);
    expect(work.categoryManual, isTrue);
    expect(work.source, ScrapeSource.manual);
    expect(work.itemCount, 12, reason: '计数与刮削无关，必须原样保留。');
    expect(work.totalBytes, 9000000);
  });

  test('作品不在库里 → 返回 null，且不插新行', () async {
    expect(
      await repo.customizeWork(
        'nope',
        title: 'x',
        category: MediaCategory.other,
        now: now,
      ),
      isNull,
    );
    expect(await repo.countWorks(), 0);
  });

  test('自定义之后再走一次扫描期自动刮削 → 元数据不回退', () async {
    await seedScraped();
    await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    // 扫描期那条自动刮削：把在线结果当 incoming 写进去（**不传**
    // overrideManual —— 这正是它与详情页「刮削」按钮的区别）。
    await repo.upsertWorks(
      [
        MediaWork(
          key: 'w',
          provider: DriveProvider.quark,
          kind: MediaKind.episode,
          category: MediaCategory.movie,
          title: '低俗小说',
          year: 1994,
          overview: '两个杀手…',
          posterUrl: 'https://image.tmdb.org/wrong.jpg',
          rating: 8.9,
          genres: const ['犯罪'],
          onlineId: 'movie/680',
          source: ScrapeSource.online,
          scrapedAt: now,
          itemCount: 13,
          totalBytes: 9100000,
          updatedAt: now,
        ),
      ],
      now: now,
    );

    final work = await repo.workByKey('w');
    expect(work!.title, '2024 演唱会现场');
    expect(work.category, MediaCategory.other);
    expect(work.posterUrl, isNull);
    expect(work.source, ScrapeSource.manual);
    expect(work.itemCount, 13, reason: '文件数照常更新 —— 那是扫描的产物。');
  });

  test('用户显式刮削（overrideManual: true）→ 覆盖成功', () async {
    await seedScraped();
    await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    await repo.upsertWorks(
      [
        MediaWork(
          key: 'w',
          provider: DriveProvider.quark,
          kind: MediaKind.episode,
          category: MediaCategory.movie,
          title: '低俗小说',
          posterUrl: 'https://image.tmdb.org/right.jpg',
          source: ScrapeSource.online,
          scrapedAt: now,
          itemCount: 12,
          totalBytes: 9000000,
          updatedAt: now,
        ),
      ],
      now: now,
      overrideManual: true,
    );

    final work = await repo.workByKey('w');
    expect(
      work!.title,
      '低俗小说',
      reason: '「刮削」按钮是用户唯一能把作品交还给在线源的路。这里若也'
          '拦下，库里一个字段都不会变，而 WorkScraper 已经返回「已刮削：'
          '低俗小说」—— 界面在撒谎。',
    );
    expect(work.source, ScrapeSource.online);
    expect(work.posterUrl, 'https://image.tmdb.org/right.jpg');
  });

  test('用户锁住的类型标签：整行写也不许抹掉，锁也不许丢', () async {
    await seedScraped();
    // 用户先在详情页「编辑类型」里敲了两个类型 —— 那一步会置 `genresManual`。
    await repo.setWorkGenres('w', const ['真人秀', '脱口秀']);

    await repo.customizeWork(
      'w',
      title: '2024 演唱会现场',
      category: MediaCategory.other,
      now: now,
    );

    final work = await repo.workByKey('w');
    expect(
      work!.genres,
      const ['真人秀', '脱口秀'],
      reason: '`customizeWork` 是**整行写**，绕开了 `mergeWorkForUpsert` 里'
          '那条「`genresManual` 优先」的分支 —— 所以「保留用户手敲的类型」'
          '必须由 `customized()` 自己保证。漏了的话：标签被清光，而海报'
          '确实清掉了，看上去「功能是好的」，只有用户自己发现标签没了。',
    );
    expect(
      work.genresManual,
      isTrue,
      reason: '标记丢了就是**偷偷解锁**：下一次刮削会把刚保住的类型覆盖掉。',
    );
    // 顺带确认这一趟该清的还是清干净了 —— 别为了保住类型把清空弄坏。
    expect(work.posterUrl, isNull);
    expect(work.source, ScrapeSource.manual);
  });
}
