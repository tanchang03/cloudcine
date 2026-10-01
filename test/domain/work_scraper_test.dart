import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:cloudcine/domain/services/work_scraper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记下**真正传给仓储**的作品行。
///
/// 断言这一层而不是断言读回来的值：`InMemoryMediaRepository` 的合并逻辑是
/// 简化版（刮削过的作品会被整体保护），而 `WorkScraper` 的职责正是**产出**
/// 那一行。仓储的合并规则由 `media_work_merge_test.dart` 单独覆盖。
class _RecordingRepo extends InMemoryMediaRepository {
  final List<MediaWork> written = [];

  @override
  Future<void> upsertWorks(List<MediaWork> works, {DateTime? now}) async {
    written.addAll(works);
    return super.upsertWorks(works, now: now);
  }
}

/// 一个返回固定结果的刮削器，并记下收到的查询。
class _Fixed implements MetadataScraper {
  _Fixed(this.id, this.result);

  @override
  final String id;

  final ScrapedMetadata? result;

  final List<ScrapeQuery> queries = [];

  @override
  String get displayName => id;

  @override
  bool get isEnabled => true;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async {
    queries.add(query);
    return result;
  }
}

void main() {
  final now = DateTime(2026, 10, 1);
  const thumb = 'https://drive-pc.quark.cn/file/video/preview?fid=f1';

  MediaItem item({
    required String name,
    int episode = 1,
    bool extra = false,
    String fileId = 'f1',
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: name,
        dirId: 'd1',
        dirPath: '/动漫/Show/',
        groupKey: 'show',
        kind: MediaKind.episode,
        title: 'Show',
        season: 1,
        episode: episode,
        isSampleOrExtra: extra,
        thumbUrl: thumb,
        firstSeenAt: now,
        updatedAt: now,
      );

  /// 一部**还没刮过**的作品：封面是夸克的视频帧，带人脸锚点。
  MediaWork work({
    String? posterUrl = thumb,
    double? posterFaceX = 0.32,
    ScrapeSource source = ScrapeSource.local,
  }) =>
      MediaWork(
        key: 'show',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: 'Show',
        category: MediaCategory.anime,
        year: 2023,
        posterUrl: posterUrl,
        posterFaceX: posterFaceX,
        source: source,
        itemCount: 3,
        totalBytes: 12345,
        lastPlayedAt: now.subtract(const Duration(days: 2)),
        updatedAt: now,
      );

  ScrapedMetadata online({
    String title = '仙逆 第一季',
    String? posterUrl =
        'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg',
    double? rating = 8.0,
  }) =>
      ScrapedMetadata(
        title: title,
        year: 2023,
        overview: '简介',
        posterUrl: posterUrl,
        rating: rating,
        genres: const ['动画'],
        onlineId: 'douban/tv/35679839',
        source: ScrapeSource.online,
      );

  Future<_RecordingRepo> repoWith(
    MediaWork w,
    List<MediaItem> items,
  ) async {
    final repo = _RecordingRepo();
    await repo.upsertWorks([w], now: now);
    await repo.upsertItems(items, now: now);
    repo.written.clear();
    return repo;
  }

  group('WorkScraper 命中', () {
    test('刮到之后元数据写进作品行，而与刮削无关的字段原样保留', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final scraper = _Fixed('fake', online());
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([scraper]),
        clock: () => now,
      );

      final outcome = await subject.scrape(work());

      expect(outcome.status, WorkScrapeStatus.scraped);
      expect(repo.written, hasLength(1));
      final w = repo.written.single;

      expect(w.title, '仙逆 第一季');
      expect(w.rating, 8.0);
      expect(w.overview, '简介');
      expect(w.genres, ['动画']);
      expect(w.onlineId, 'douban/tv/35679839');
      expect(w.source, ScrapeSource.online);
      expect(w.posterUrl, contains('doubanio.com'));

      // 这三样**不是刮削的产物**，被刮削顺手改掉是最难查的一类回归。
      expect(
        w.category,
        MediaCategory.anime,
        reason: '分类是「这些文件是什么」的判定（扫描期算出来的），'
            '刮削只补标题海报那类元数据。改成别的会让作品从「动漫」栏消失。',
      );
      expect(w.itemCount, 3);
      expect(w.totalBytes, 12345);
      expect(w.lastPlayedAt, now.subtract(const Duration(days: 2)));
    });

    test('海报换了 → 人脸锚点归零、缓存文件名清空', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      );

      await subject.scrape(work());

      final w = repo.written.single;
      expect(
        w.posterFaceX,
        isNull,
        reason: '刮削海报是 2:3 的竖版作品海报，铺满格子、不裁切，'
            '压根不需要人脸锚点。这里写 null 是**结论**不是缺失 —— '
            '留着旧的锚点，PosterImage 会拿视频帧的人脸位置去裁海报。',
      );
      expect(w.posterFile, isNull);
    });

    test('海报地址没变 → 锚点继续有效', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online(posterUrl: thumb))]),
        clock: () => now,
      );

      await subject.scrape(work());

      final w = repo.written.single;
      expect(
        w.posterFaceX,
        0.32,
        reason: '地址没换就说明还是同一张夸克视频帧，锚点自然还成立。'
            '这时清掉锚点会让封面从「凸显人物」退回「模糊底图 + contain」。',
      );
    });

    test('查询词来自文件名（不是库里已存的标题），花絮被跳过', () async {
      final repo = await repoWith(
        work(),
        [
          // 排序上它会排在正片前面（A < S），若不跳过就会用它解析。
          item(name: 'A其他片.S01E01.mkv', extra: true, fileId: 'fx'),
          item(name: 'Show.S01E01.1080p.mkv', fileId: 'f1'),
        ],
      );
      final scraper = _Fixed('fake', online());
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([scraper]),
        clock: () => now,
      );

      await subject.scrape(work());

      expect(scraper.queries.single.title, 'Show');
      expect(scraper.queries.single.season, 1);
      expect(scraper.queries.single.episode, 1);
    });
  });

  group('WorkScraper 未命中', () {
    test('只拿到本地兜底结果 → notFound，且不写库', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _Fixed('online', null),
          const LocalFilenameScraper(),
        ]),
        clock: () => now,
      );

      final outcome = await subject.scrape(work());

      expect(
        outcome.status,
        WorkScrapeStatus.notFound,
        reason: '流水线的兜底是本地文件名解析，它**永远成功**。'
            '只判「结果非空」会把「什么都没刮到」当成成功，'
            '然后把本地解析的结果标成 source=online 写进库 —— '
            '用户看到「已刮削」但海报简介一个都没有。',
      );
      expect(repo.written, isEmpty);
    });

    test('文件名解析不出可信片名 → noQuery，不发请求', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'video.mkv')],
      );
      final scraper = _Fixed('fake', online());
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([scraper]),
        clock: () => now,
      );

      final outcome = await subject.scrape(work());

      expect(outcome.status, WorkScrapeStatus.noQuery);
      expect(scraper.queries, isEmpty);
      expect(repo.written, isEmpty);
    });

    test('作品下没有任何文件 → noQuery', () async {
      final repo = await repoWith(work(), const []);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      );

      expect(
        (await subject.scrape(work())).status,
        WorkScrapeStatus.noQuery,
      );
    });

    test('刮削器抛异常 → notFound，不抛给 UI', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _Fixed('boom', null),
          const LocalFilenameScraper(),
        ]),
        clock: () => now,
      );

      expect(
        (await subject.scrape(work())).status,
        WorkScrapeStatus.notFound,
      );
    });
  });
}
