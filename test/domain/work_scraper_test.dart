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
  Future<void> upsertWorks(
    List<MediaWork> works, {
    DateTime? now,
    bool overrideManual = false,
  }) async {
    written.addAll(works);
    return super.upsertWorks(works, now: now, overrideManual: overrideManual);
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

  // ⚠️ `implements` 不继承默认实现，这两个必须显式写出来（见接口文档）。
  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async => const [];

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async => null;
}

/// 支持**手动通道**的假刮削器：给候选、并能把候选解析成元数据。
class _Manual implements MetadataScraper {
  _Manual(
    this.id, {
    this.candidates = const [],
    this.resolvable = true,
  });

  @override
  final String id;

  final List<ScrapeCandidate> candidates;

  /// `false` = 详情接口失败 / 响应不是条目，`resolve` 返回 `null`。
  final bool resolvable;

  /// 搜过几次 —— 用来钉「指定了源时别的源一次都不发」。
  int searchCalls = 0;

  @override
  String get displayName => id;

  @override
  bool get isEnabled => true;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async => null;

  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async {
    searchCalls++;
    return candidates;
  }

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async {
    if (!resolvable) return null;
    return ScrapedMetadata(
      title: candidate.title,
      year: candidate.year,
      overview: '简介',
      posterUrl:
          'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg',
      rating: 8.0,
      genres: const ['动画'],
      onlineId: '${candidate.source}/${candidate.sourceId}',
      source: ScrapeSource.online,
      matchedQuery: candidate.title,
    );
  }
}

/// 手动通道的假源：`resolve` 返回**指定**的条目 id 与类型标签。
///
/// 用来钉两件事：
///   - 手动通道会拿「刮到的条目是电影还是剧集」（`movie/…` / `tv/…`）更新
///     媒体类型 —— 自动通道刻意不这么做；
///   - 语义档（动漫 / 综艺 / 纪录片）不会被这条结构证据冲掉。
class _ManualMeta implements MetadataScraper {
  _ManualMeta({required this.onlineId, this.genres = const []});

  final String onlineId;
  final List<String> genres;

  @override
  String get id => 'douban';

  @override
  String get displayName => '豆瓣';

  @override
  bool get isEnabled => true;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async => null;

  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async => const [];

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async =>
      ScrapedMetadata(
        title: candidate.title,
        year: candidate.year,
        genres: genres,
        onlineId: onlineId,
        source: ScrapeSource.online,
      );
}

/// 每次调用都抛 —— 钉住「一个源挂了不该让整个对话框空掉」。
class _Throwing implements MetadataScraper {  @override
  String get id => 'boom';

  @override
  String get displayName => 'boom';

  @override
  bool get isEnabled => true;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async =>
      throw StateError('boom');

  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async =>
      throw StateError('boom');

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async =>
      throw StateError('boom');
}

void main() {
  final now = DateTime(2026, 10, 1);
  const thumb = 'https://drive-pc.quark.cn/file/video/preview?fid=f1';

  MediaItem item({
    required String name,
    int episode = 1,
    bool extra = false,
    String fileId = 'f1',
    String dirPath = '/动漫/Show/',
  }) =>
      MediaItem(
        provider: DriveProvider.quark,
        fileId: fileId,
        name: name,
        dirId: 'd1',
        dirPath: dirPath,
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
  ///
  /// [category] 可指定 —— 分类是**扫描期的产物**（靠目录名 / 关键词 / 结构
  /// 判出来的），而刮削只应该在 TMDB 给出明确类型时才动它。
  MediaWork work({
    String? posterUrl = thumb,
    double? posterFaceX = 0.32,
    ScrapeSource source = ScrapeSource.local,
    MediaCategory category = MediaCategory.anime,
    bool categoryManual = false,
    DateTime? lastModifiedAt,
  }) =>
      MediaWork(
        key: 'show',
        provider: DriveProvider.quark,
        kind: MediaKind.episode,
        title: 'Show',
        category: category,
        categoryManual: categoryManual,
        year: 2023,
        posterUrl: posterUrl,
        posterFaceX: posterFaceX,
        source: source,
        itemCount: 3,
        totalBytes: 12345,
        lastModifiedAt: lastModifiedAt ?? DateTime(2026, 9, 28),
        lastPlayedAt: now.subtract(const Duration(days: 2)),
        updatedAt: now,
      );

  ScrapedMetadata online({
    String title = '仙逆 第一季',
    String? posterUrl =
        'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p1.jpg',
    double? rating = 8.0,
    List<String> genres = const ['动画'],
  }) =>
      ScrapedMetadata(
        title: title,
        year: 2023,
        overview: '简介',
        posterUrl: posterUrl,
        rating: rating,
        genres: genres,
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

    test('刮削后 lastModifiedAt 原样保留 —— 不会跳到列表末尾', () async {
      // 2026-10-02：用户反馈「手工刮削后影片排到了最后一个」。
      // 根因是 _apply 漏抄 lastModifiedAt，构造器默认 null，
      // 落库后 recentModified 倒序排里 NULL 垫底。
      final fileTime = DateTime(2026, 9, 28, 10, 30);
      final repo = await repoWith(
        work(lastModifiedAt: fileTime),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      );

      await subject.scrape(work(lastModifiedAt: fileTime));

      expect(
        repo.written.single.lastModifiedAt,
        fileTime,
        reason: 'lastModifiedAt 是网盘文件的修改时间，与刮削无关。'
            '漏抄会让它变成 null，而 NULL 在 DESC 排序里垫底 —— '
            '用户看到的是「刮完一部电影，它从前面跳到了最后」。',
      );
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
      // ⚠️ 目录名必须是**容器名**（`/电影/`）：2026-10-02 起「目录名可信且
      // 文件自己说不清楚」时，整目录会按目录名归组 —— 用默认的
      // `/动漫/Show/` 的话，`video.mkv` 会被救成一部叫「Show」的作品，
      // 这条用例就测不到「真的什么都提不出来」了。
      final repo = await repoWith(
        work(),
        [item(name: 'video.mkv', dirPath: '/电影/')],
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

  group('WorkScraper 手动通道', () {
    test('queryFor 预填的是**文件名解析出来的词**，不是库里已存的标题', () async {
      // 库里那个标题可能是上一次刮错的结果。预填它，用户得先意识到
      // 「这个框里是错的」才会去改；预填解析原文则直接展示了
      // 「自动刮削拿着这么个词去搜」。
      final repo = await repoWith(
        work(),
        [item(name: '超z级z马z力z欧z银z河z大z电影aa.2026.2160p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      );

      final q = await subject.queryFor(work());

      expect(q, isNotNull);
      expect(
        q!.title,
        contains('超z级z马z力z欧z银z河z大z电影aa'),
        reason: '预填库里那个 `Show`（或上一次刮错的名字）会让用户以为'
            '「框里是对的」，而他要改的恰恰是这个名字。',
      );
      expect(q.year, 2026);
    });

    test('queryFor 解析不出片名 → null，让对话框退回库里已有的标题', () async {
      // 同上：目录名得是容器名，否则目录名会兜底成一个可信片名。
      final repo = await repoWith(
        work(),
        [item(name: 'video.mkv', dirPath: '/电影/')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      );

      expect(await subject.queryFor(work()), isNull);
    });

    test('目录名可信时 queryFor 给出「目录名」查询 —— 与扫描期同一条解析路径', () async {
      // 2026-10-02 事故的正面用例：`182.格力空调显示E6如何维修.mp4` 这类
      // 「编号 + 描述」的文件名提不出片名，靠目录名才拿得到正确的查询词。
      // 备用词必须为空 —— 旧规则会把开头那个 `182` 当英文名再搜一次 TMDB，
      // 模糊搜索返回希腊纪录片《1821: Οι Ήρωες》并刮错。
      final repo = await repoWith(work(), [
        item(
          name: '182.格力空调显示E6如何维修.mp4',
          dirPath: '/来自：分享/姜松《家电维修视频教程》/',
        ),
      ]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      );

      final q = await subject.queryFor(work());

      expect(q, isNotNull);
      expect(q!.title, '姜松 家电维修视频教程');
      expect(q.kind, MediaKind.episode);
      expect(q.alternateTitle, isNull);
    });

    test('searchCandidates 把各源候选汇总返回', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _Manual('tmdb', candidates: const [
            ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
          ]),
          _Manual('douban', candidates: const [
            ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
          ]),
        ]),
        clock: () => now,
      );

      final found = await subject.searchCandidates(
        const ScrapeQuery(title: '某片', kind: MediaKind.movie),
      );

      expect(found.map((c) => c.title), ['甲', '乙']);
    });

    test('searchCandidates 在刮削器抛异常时返回空列表，不抛给对话框', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Throwing()]),
        clock: () => now,
      );

      expect(
        await subject.searchCandidates(
          const ScrapeQuery(title: '某片', kind: MediaKind.movie),
        ),
        isEmpty,
      );
    });

    test('searchCandidates 传 sourceId → 只搜那一个源', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final tmdb = _Manual('tmdb', candidates: const [
        ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '甲'),
      ]);
      final douban = _Manual('douban', candidates: const [
        ScrapeCandidate(source: 'douban', sourceId: '2', title: '乙'),
      ]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([tmdb, douban]),
        clock: () => now,
      );

      final found = await subject.searchCandidates(
        const ScrapeQuery(title: '某片', kind: MediaKind.movie),
        sourceId: 'douban',
      );

      expect(found.map((c) => c.title), ['乙']);
      expect(tmdb.searchCalls, 0, reason: '用户指定了只在豆瓣搜。');
      expect(douban.searchCalls, 1);
    });

    test('applyCandidate 的 outcome 带上来源展示名', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      final outcome = await subject.applyCandidate(
        work(),
        const ScrapeCandidate(source: 'douban', sourceId: '1', title: '某片'),
      );

      expect(outcome.status, WorkScrapeStatus.scraped);
      expect(
        outcome.sourceName,
        'douban',
        reason: '手动通道的结果要能告诉用户「这条是哪家给的」—— '
            '对话框与详情页的消息都靠它拼出「… · 豆瓣」。',
      );
    });

    test('applyCandidate 用 resolve 的结果落库，并保留与刮削无关的字段', () async {
      final repo = await repoWith(
        work(),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      final outcome = await subject.applyCandidate(
        work(),
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '35679839',
          title: '仙逆 第一季',
        ),
      );

      expect(outcome.status, WorkScrapeStatus.scraped);
      final w = repo.written.single;
      expect(w.title, '仙逆 第一季');
      expect(w.source, ScrapeSource.online);
      expect(w.category, MediaCategory.anime);
      expect(w.itemCount, 3);
      expect(w.totalBytes, 12345);
      expect(
        w.posterFile,
        isNull,
        reason: '换了海报就必须清掉 posterFile —— 缓存文件名是按 URL 散列'
            '出来的，不清的话详情页会继续显示上一版海报。',
      );
    });

    test('applyCandidate **不看匹配闸门** —— 用户已经做过判断了', () async {
      // 这正是手动通道存在的理由：目录名 `超z级z马z力z欧z银z河z大z电影aa`
      // 会被闸门正确地拦下（自动刮削认输），但用户手动选中
      // 《超级马力欧银河大电影》时，闸门必须让路。
      final repo = await repoWith(
        work(),
        [item(name: '超z级z马z力z欧z银z河z大z电影aa.2026.2160p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      final outcome = await subject.applyCandidate(
        work(),
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '35000001',
          title: '超级马力欧银河大电影',
          year: 2026,
        ),
      );

      expect(outcome.status, WorkScrapeStatus.scraped);
      expect(repo.written.single.title, '超级马力欧银河大电影');
    });

    test('applyCandidate 解析失败 → notFound，且**不写库**', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban', resolvable: false)]),
        clock: () => now,
      );

      final outcome = await subject.applyCandidate(
        work(),
        const ScrapeCandidate(source: 'douban', sourceId: '1', title: '某片'),
      );

      expect(outcome.status, WorkScrapeStatus.notFound);
      expect(
        repo.written,
        isEmpty,
        reason: '写一行「只有标题、没有海报简介」的假成功，用户看到的是'
            '「已刮削」但页面上什么都没变 —— 比明确报失败更难排查。',
      );
    });

    test('候选来源不在流水线里 → notFound（不猜、不退回别的源）', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      final outcome = await subject.applyCandidate(
        work(),
        const ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '某片'),
      );

      expect(outcome.status, WorkScrapeStatus.notFound);
      expect(repo.written, isEmpty);
    });
  });

  group('刮削结果文案按通道分开', () {
    // 这一组钉的是 2026-10-01 发现的一处文案错配：`notFound` 在两个通道里是
    // **两件不同的事**（算法没搜到 vs 用户点的那条解析不出来），一度共用
    // 同一句话，于是手动对话框里会冒出「在线源都没有找到匹配的条目，可能是
    // 片名解析不准」—— 用户刚刚亲手点了一条候选，看到这句只会以为界面坏了。

    Future<WorkScrapeOutcome> autoNotFound() async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      return WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _Fixed('online', null),
          const LocalFilenameScraper(),
        ]),
        clock: () => now,
      ).scrape(work());
    }

    Future<WorkScrapeOutcome> manualNotFound() async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      return WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban', resolvable: false)]),
        clock: () => now,
      ).applyCandidate(
        work(),
        const ScrapeCandidate(source: 'douban', sourceId: '1', title: '某片'),
      );
    }

    test('自动通道失败 → 文案给出「手动」这个下一步', () async {
      final outcome = await autoNotFound();

      expect(outcome.channel, ScrapeChannel.auto);
      expect(
        outcome.message,
        contains('手动'),
        reason: '自动这条路救不回来时，用户唯一的出路是自己敲片名。'
            '文案里不写这一步，用户只会得出「这个播放器刮削是坏的」。'
            '⚠️ 这句话里的「旁边」写死了按钮的位置 —— '
            '把「手动」藏进菜单就必须同步改这里。',
      );
    });

    test('手动通道失败 → 文案说「换一条候选」，不提片名解析', () async {
      final outcome = await manualNotFound();

      expect(outcome.channel, ScrapeChannel.manual);
      expect(
        outcome.message,
        contains('换一条'),
        reason: '用户已经搜到并点了一条候选，失败的原因是**这一条**解析不出来，'
            '下一步是换一条 —— 跟他敲的词没有关系。',
      );
      expect(
        outcome.message,
        isNot(contains('片名解析不准')),
        reason: '「片名解析不准」讲的是自动流程。用户在候选列表里刚刚看到'
            '十条结果，被告知「片名解析不准」会让他去改一个本来没错的词。',
      );
      expect(
        outcome.message,
        isNot(contains('在线源都没找到')),
        reason: '同上：用户明明看到了候选，说「没找到条目」等于说界面坏了。',
      );
    });

    test('两个通道的 notFound 文案确实不同（不是同一句）', () async {
      expect(
        (await autoNotFound()).message,
        isNot((await manualNotFound()).message),
      );
    });

    test('成功文案：两个通道共用「已刮削：片名（年份）」核心，手动多带来源', () async {
      final repo = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final auto = await WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online())]),
        clock: () => now,
      ).scrape(work());

      final repo2 = await repoWith(work(), [item(name: 'Show.S01E01.mkv')]);
      final manual = await WorkScraper(
        library: repo2,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      ).applyCandidate(
        work(),
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '1',
          title: '仙逆 第一季',
          year: 2023,
        ),
      );

      expect(auto.status, WorkScrapeStatus.scraped);
      expect(manual.status, WorkScrapeStatus.scraped);

      const core = '已刮削：仙逆 第一季（2023）';
      expect(auto.message, contains(core));
      expect(
        manual.message,
        contains(core),
        reason: '成功那条的核心没有歧义：两个通道都说「已刮削：片名（年份）」。'
            '按通道给它分叉出一套完全不同的说法，只会多一处要维护的重复。',
      );

      expect(
        manual.message,
        contains('douban'),
        reason: '手动通道**必须**在结果里点明来源：用户亲手从候选里挑了一条，'
            '「这条是哪家给的」正是他判断自己挑得对不对的依据。',
      );
      expect(
        auto.message,
        isNot(contains('douban')),
        reason: '自动通道的来源对用户没有意义（他没做选择，是算法挑的），'
            '所以不附来源名 —— 免得给一个用户无法据此行动的信息。',
      );
    });
  });

  group('刮削后分类跟着 TMDB 类型走', () {
    // 2026-10-01：用户反馈「刮削完毕后并没有合理的将影片进行分类」。
    // 根因是 `_apply` 把 `category` 原样抄了一遍，而 `MediaCategoryGuesser`
    // 自己却把 genres 排在第一优先级 —— 两处口径相反，`fromGenres` 这条路径
    // 在整个项目里**永远不会被执行**（扫描期调 guess 时不传 genres）。

    test('TMDB 说是动画 → 分类从「电影」挪到「动漫」', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _Fixed('fake', online(genres: const ['动画', '冒险', '喜剧'])),
        ]),
        clock: () => now,
      );

      await subject.scrape(work(category: MediaCategory.movie));

      expect(
        repo.written.single.category,
        MediaCategory.anime,
        reason: '目录名里没有「动漫」二字，扫描期只能按结构判成「电影」。'
            'TMDB 的「动画」是更可信的证据 —— 不然这部动画片永远留在电影栏。',
      );
    });

    test('genres 给不出结论 → 保留扫描期的判定，不许按 kind 冲掉', () async {
      // 用户把综艺放在 /综艺/ 目录里，扫描期靠目录名判成了 variety；
      // 而 TMDB 对国产综艺常常给不出「真人秀」，只给「剧情」。
      final repo = await repoWith(
        work(category: MediaCategory.variety),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _Fixed('fake', online(genres: const ['剧情'])),
        ]),
        clock: () => now,
      );

      await subject.scrape(work(category: MediaCategory.variety));

      expect(
        repo.written.single.category,
        MediaCategory.variety,
        reason: '这里如果调完整的 `MediaCategoryGuesser.guess`，它的最后一步'
            '「按 kind 落到电影 / 剧集」会按 kind=episode 把「综艺」冲成'
            '「剧集」—— 用户看到的是「我的综艺栏目空了」。'
            '`guess` 的兜底是替「没有任何证据」准备的，而这里已经有证据了。',
      );
    });

    test('genres 为空（离线源）→ 分类不动', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.1080p.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online(genres: const []))]),
        clock: () => now,
      );

      await subject.scrape(work(category: MediaCategory.movie));

      expect(repo.written.single.category, MediaCategory.movie);
    });

    test('手动通道同样折算分类', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        // `_Manual.resolve` 给的 genres 是 `['动画']`。
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.movie),
        const ScrapeCandidate(source: 'douban', sourceId: '1', title: '某片'),
      );

      expect(
        repo.written.single.category,
        MediaCategory.anime,
        reason: '手动和自动走的是同一个 `_apply`，分类折算不能只在一条路上生效 '
            '—— 那样「手动刮完分类不对、自动刮完才对」会变成一个玄学问题。',
      );
    });
  });

  group('手动刮削按条目结构更新媒体类型（2026-10-02）', () {
    // 用户反馈：手动刮削「需要根据刮削结果更新媒体类型」。原来的规则是
    // 「genres 说话才算」—— 类型标签给不出「动画 / 纪录片 / 真人秀」时分类
    // 一个字段都不动。而手动刮削最常见的场景恰恰是**文件名认不出类型**
    // （只剩 `2026.2160p.WEB-DL.mkv`），那时 genres 多半也只是「剧情」，
    // 于是分类永远停在扫描期那个「电影 / 其他」。
    //
    // 手动通道多了一条证据可用：用户亲手确认的条目自己带着
    // `movie/…` / `tv/…`（TMDB 与豆瓣都把类型编进 id）。自动通道**不开**
    // 这条 —— 它会让「靠目录名判成综艺」的作品被条目的 tv 前缀冲成剧集。

    test('手动刮到 tv 条目 → 分类从「电影」挪到「剧集」', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: '2026.2160p.WEB-DL.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _ManualMeta(onlineId: 'douban/tv/12345', genres: const ['剧情']),
        ]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.movie),
        const ScrapeCandidate(source: 'douban', sourceId: '1', title: '某剧'),
      );

      expect(repo.written.single.category, MediaCategory.series);
    });

    test('手动刮到 movie 条目 → 分类从「剧集」挪到「电影」', () async {
      final repo = await repoWith(
        work(category: MediaCategory.series),
        [item(name: '2026.2160p.WEB-DL.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _ManualMeta(onlineId: 'douban/movie/678', genres: const ['剧情']),
        ]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.series),
        const ScrapeCandidate(source: 'douban', sourceId: '2', title: '某片'),
      );

      expect(repo.written.single.category, MediaCategory.movie);
    });

    test('A：类型标签优先 —— 综艺给了「真人秀」就不被结构冲掉', () async {
      // 结构证据只是**兜底**：只要 genres 说得出语义结论（真人秀 → 综艺），
      // 就以 genres 为准，结构不参与。这保住了绝大多数综艺 —— TMDB 对综艺
      // 通常会给 Reality / Talk。
      final repo = await repoWith(
        work(category: MediaCategory.variety),
        [item(name: 'Show.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _ManualMeta(onlineId: 'douban/tv/12345', genres: const ['真人秀']),
        ]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.variety),
        const ScrapeCandidate(source: 'douban', sourceId: '3', title: '某综艺'),
      );

      expect(repo.written.single.category, MediaCategory.variety);
    });

    test('A：genres 说不出语义时，手动重刮按条目结构重判（含语义档）', () async {
      // ⚠️ 2026-10-02 的取舍：手动通道的「自动」= 按**本次**刮削重判，不再用
      // 「当前是语义档就不许被结构覆盖」来挡（旧版有这一条）。原因：一部被
      // 刮成「纪录片」的剧，其 TMDB 类型（剧情 / 悬疑）给不出语义结论，只能
      // 靠结构证据（`tv/…`）救回来 —— 旧守卫会让它永远翻不了身（就是用户报
      // 的那个 bug）。代价：放在 `/综艺/` 而 TMDB 又没给「真人秀」的片子，
      // 手动重刮会被判成「剧集」；要保住「综艺」，在对话框「媒体类型」里
      // 点一下即可。
      final repo = await repoWith(
        work(category: MediaCategory.variety),
        [item(name: 'Show.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _ManualMeta(onlineId: 'douban/tv/12345', genres: const ['剧情']),
        ]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.variety),
        const ScrapeCandidate(source: 'douban', sourceId: '3b', title: '某综艺'),
      );

      expect(repo.written.single.category, MediaCategory.series);
    });

    test('A：分类被锁（旧版「清空」留下的）→ 手动重刮照样按结构重判', () async {
      // 用户报的 bug 现场：自动刮成「纪录片」→ 清空（旧版把分类锁死）→
      // 手动刮到 `tv/…` 也改不动。A 让手动通道忽略分类锁。
      final repo = await repoWith(
        work(category: MediaCategory.documentary, categoryManual: true),
        [item(name: 'The.Glory.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _ManualMeta(
            onlineId: 'douban/tv/136283',
            genres: const ['剧情', '悬疑'],
          ),
        ]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.documentary, categoryManual: true),
        const ScrapeCandidate(
          source: 'douban',
          sourceId: 'tv/136283',
          title: '黑暗荣耀',
        ),
      );

      expect(
        repo.written.single.category,
        MediaCategory.series,
        reason: '「手动重刮 = 用户要求现在重判一次」，不该被旧锁卡住。',
      );
    });

    test('A：锁着的分类要**真的落库** —— 光算出对的不够', () async {
      // 用户报的 bug 有**两层**：`_categoryFor` 算出「剧集」是对的（日志里
      // 写着），但落库那一步被 `mergeWorkForUpsert` 的旧锁拦了回去，库里
      // 仍然是「纪录片」。上一条用例只看 `written`（WorkScraper 的产物），
      // 照不出第二层 —— 所以这条读回**库里那一行**。
      final repo = await repoWith(
        work(category: MediaCategory.documentary, categoryManual: true),
        [item(name: 'The.Glory.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([
          _ManualMeta(
            onlineId: 'douban/tv/136283',
            genres: const ['剧情', '悬疑'],
          ),
        ]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.documentary, categoryManual: true),
        const ScrapeCandidate(
          source: 'douban',
          sourceId: 'tv/136283',
          title: '黑暗荣耀',
        ),
        category: MediaCategory.series,
      );

      final stored = await repo.workByKey('show');
      expect(
        stored!.category,
        MediaCategory.series,
        reason: '用户看到的是**库里那一行**（列表按它分栏），不是 WorkScraper 的'
            '返回值。分类算对了却写不进去，界面照样弹「已刮削 · 类型：剧集」，'
            '而纪录片栏里它还在 —— 这正是用户报的「设置没生效」。',
      );
      expect(stored.categoryManual, isTrue);
    });

    test('A：**自动**通道仍然认锁 —— 锁只对手动通道让路', () async {
      final repo = await repoWith(
        work(category: MediaCategory.documentary, categoryManual: true),
        [item(name: 'The.Glory.S01E01.mkv')],
      );
      await WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Fixed('fake', online(genres: const ['动画']))]),
        clock: () => now,
      ).scrape(work(category: MediaCategory.documentary, categoryManual: true));

      expect(
        repo.written.single.category,
        MediaCategory.documentary,
        reason: '锁的本意就是挡无人值守的自动刮削 —— 自动通道不许绕过它，'
            '否则用户手动指定的分类会被 TMDB 的 genres 悄悄改写。',
      );
    });

    test('同一份数据：自动通道不动，手动通道才按条目结构更新', () async {
      // 自动通道（详情页「刮削」按钮）：genres 说不出结论 → 保留原值。
      final autoRepo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.mkv')],
      );
      await WorkScraper(
        library: autoRepo,
        pipeline: ScraperPipeline([_Fixed('fake', online(genres: const []))]),
        clock: () => now,
      ).scrape(work(category: MediaCategory.movie));
      expect(
        autoRepo.written.single.category,
        MediaCategory.movie,
        reason: '自动通道拿不到「用户确认过」这个前提，所以继续用保守规则。',
      );

      // 手动通道（对话框里用户亲手选了候选）：条目结构生效。
      final manualRepo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.mkv')],
      );
      await WorkScraper(
        library: manualRepo,
        pipeline: ScraperPipeline([
          _ManualMeta(onlineId: 'douban/tv/12345', genres: const []),
        ]),
        clock: () => now,
      ).applyCandidate(
        work(category: MediaCategory.movie),
        const ScrapeCandidate(source: 'douban', sourceId: '4', title: '某剧'),
      );
      expect(manualRepo.written.single.category, MediaCategory.series);
    });

    test('用户在对话框里选的类型 → 直接落库并锁住 categoryManual', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        // `_Manual.resolve` 给的 genres 是 `['动画']`。
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.movie),
        const ScrapeCandidate(source: 'douban', sourceId: '5', title: '某片'),
        category: MediaCategory.documentary,
      );

      expect(
        repo.written.single.category,
        MediaCategory.documentary,
        reason: '用户亲手选的类型是**结论**，优先于类型标签的折算'
            '（这里 genres 说「动画」，但用户要的是「纪录片」）。',
      );
      expect(
        repo.written.single.categoryManual,
        isTrue,
        reason: '他在「用这一条更新」那一步看过这个选择 —— 之后的自动刮削'
            '不该再改写它，否则等于「我选的没生效」。',
      );
    });

    test('没选（null）→ 不锁，类型仍交给自动规则', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.mkv')],
      );
      final subject = WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      );

      await subject.applyCandidate(
        work(category: MediaCategory.movie),
        const ScrapeCandidate(source: 'douban', sourceId: '6', title: '某片'),
      );

      expect(
        repo.written.single.categoryManual,
        isFalse,
        reason: '用户没动那个选择框 → 别顺手把它锁住；下次刮削 / 回填仍可以改它。',
      );
    });

    test('成功文案带上落库后的类型（用户当场核对有没有归错栏）', () async {
      final repo = await repoWith(
        work(category: MediaCategory.movie),
        [item(name: 'Show.S01E01.mkv')],
      );
      final outcome = await WorkScraper(
        library: repo,
        pipeline: ScraperPipeline([_Manual('douban')]),
        clock: () => now,
      ).applyCandidate(
        work(category: MediaCategory.movie),
        const ScrapeCandidate(source: 'douban', sourceId: '7', title: '某片'),
      );

      expect(outcome.message, contains('类型：动漫'));
    });
  });
}
