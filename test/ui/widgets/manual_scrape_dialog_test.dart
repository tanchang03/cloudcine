import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/scrape/poster_cache.dart';
import 'package:cloudcine/domain/adapters/media_repository.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/scraper.dart';
import 'package:cloudcine/domain/services/work_scraper.dart';
import 'package:cloudcine/ui/providers/app_providers.dart';
import 'package:cloudcine/ui/providers/scrape_providers.dart';
import 'package:cloudcine/ui/widgets/manual_scrape_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不下载任何图：候选缩略图拿不到就退成占位图标，测试不需要真图。
class _NoImageHttp implements HttpClientLike {
  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async =>
      const HttpResult(statusCode: 404, rawBody: '');

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      null;

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      const HttpResult(statusCode: 404, rawBody: '');

  @override
  Future<String> putBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  void close() {}
}

/// 记下**真正传给仓储**的作品行。
///
/// 断言这一层而不是断言读回来的值：内存仓储的合并逻辑是简化版
/// （刮削过的作品会被整体保护），而 `WorkScraper` 的职责正是**产出**那一行。
/// 与 `work_scraper_test.dart` 里的同名类同一取向。
class _RecordingRepo extends InMemoryMediaRepository {
  final List<MediaWork> written = [];

  @override
  Future<void> upsertWorks(List<MediaWork> works, {DateTime? now}) async {
    written.addAll(works);
    return super.upsertWorks(works, now: now);
  }
}

/// 只实现手动通道的假刮削器。
class _ManualScraper implements MetadataScraper {  _ManualScraper({this.candidates = const []});

  final List<ScrapeCandidate> candidates;

  /// 搜过几次 —— 用来钉「打开对话框时不自动搜索」。
  int searchCalls = 0;

  /// 被选中解析的是哪一条。
  ScrapeCandidate? resolved;

  @override
  String get id => 'douban';

  @override
  String get displayName => '豆瓣';

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
    resolved = candidate;
    return ScrapedMetadata(
      title: candidate.title,
      year: candidate.year,
      overview: '简介',
      posterUrl: 'https://img3.doubanio.com/view/photo/m_ratio_poster/p1.jpg',
      genres: const ['动画'],
      onlineId: 'douban/movie/${candidate.sourceId}',
      source: ScrapeSource.online,
    );
  }
}

void main() {
  final now = DateTime(2026, 10, 1);

  const rawName = '超z级z马z力z欧z银z河z大z电影aa.2026.2160p.WEB-DL.mkv';

  MediaWork work() => MediaWork(
        key: 'galaxy',
        provider: DriveProvider.quark,
        kind: MediaKind.movie,
        title: '低俗小说',
        category: MediaCategory.movie,
        year: 1994,
        source: ScrapeSource.local,
        itemCount: 1,
        updatedAt: now,
      );

  MediaItem item() => MediaItem(
        provider: DriveProvider.quark,
        fileId: 'f1',
        name: rawName,
        dirId: 'd1',
        dirPath: '/来自：分享/超z级z马z力z欧z银z河z大z电影aa(2026) 4K HDR & Dv/',
        groupKey: 'galaxy',
        kind: MediaKind.movie,
        title: '超z级z马z力z欧z银z河z大z电影aa',
        isSampleOrExtra: false,
        firstSeenAt: now,
        updatedAt: now,
      );

  const candidate = ScrapeCandidate(
    source: 'douban',
    sourceId: '35000001',
    title: '超级马力欧银河大电影',
    year: 2026,
    overview: '马力欧与路易吉踏上银河冒险。',
  );

  late Directory posterDir;

  setUp(() {
    posterDir = Directory.systemTemp.createTempSync('cloudcine_manual_dlg');
  });

  tearDown(() {
    if (posterDir.existsSync()) posterDir.deleteSync(recursive: true);
  });

  /// 把对话框挂进一棵最小的树里，并返回「打开对话框」的那个按钮。
  Future<(_ManualScraper, _RecordingRepo)> open(
    WidgetTester tester, {
    List<ScrapeCandidate> candidates = const [candidate],
  }) async {
    final scraper = _ManualScraper(candidates: candidates);
    final repo = _RecordingRepo();
    await repo.upsertWorks([work()], now: now);
    await repo.upsertItems([item()], now: now);
    // 播种那一次不算「刮削写了什么」。
    repo.written.clear();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaRepositoryProvider.overrideWithValue(repo),
          workScraperProvider.overrideWith(
            (ref) => WorkScraper(
              library: repo,
              pipeline: ScraperPipeline([scraper]),
              clock: () => now,
            ),
          ),
          posterCacheProvider.overrideWithValue(
            PosterCache(http: _NoImageHttp(), dirPath: posterDir.path),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ManualScrapeDialog.show(context, work()),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    // 预填是一次异步读库（`queryFor`），要等它落地。
    await tester.pump();
    await tester.pump();

    return (scraper, repo);
  }

  /// 片名输入框的当前内容。
  String titleFieldText(WidgetTester tester) => tester
      .widget<TextField>(find.byType(TextField).first)
      .controller!
      .text;

  Finder applyButton() => find.widgetWithText(FilledButton, '用这一条更新');

  bool applyEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(applyButton()).onPressed != null;

  group('手动刮削对话框', () {
    testWidgets('预填的是**文件名解析出来的词**，不是库里已存的标题', (tester) async {
      await open(tester);

      expect(
        titleFieldText(tester),
        '超z级z马z力z欧z银z河z大z电影aa',
        reason: '库里那个标题是上一次刮错的结果（`低俗小说`）。预填它，'
            '用户得先意识到「这个框里是错的」才会去改；预填解析原文'
            '则直接展示了「自动刮削拿着这么个词去搜」。',
      );
      // 年份也跟着预填，用户改完片名不用再敲一遍。
      expect(
        tester
            .widget<TextField>(find.byType(TextField).at(1))
            .controller!
            .text,
        '2026',
      );
    });

    testWidgets('打开时**不自动搜索** —— 别替用户白花一个搜索词', (tester) async {
      final (scraper, _) = await open(tester);

      expect(
        scraper.searchCalls,
        0,
        reason: '豆瓣额度按搜索词计，匿名只有约 10 个；而预填的那个词'
            '正是自动刮削刚搜失败的那一个，替他再花一次毫无价值。',
      );
      expect(find.text('改好片名，点「搜索」看候选。'), findsOneWidget);
      expect(applyEnabled(tester), isFalse);
    });

    testWidgets('点搜索 → 出候选；选中之前「用这一条更新」是禁用的', (tester) async {
      final (scraper, _) = await open(tester);

      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pump();
      await tester.pump();

      expect(scraper.searchCalls, 1);
      expect(find.text('超级马力欧银河大电影'), findsOneWidget);
      expect(find.textContaining('2026 · 电影 · 豆瓣'), findsOneWidget);
      expect(
        applyEnabled(tester),
        isFalse,
        reason: '点候选只是**选中**。刮削会覆盖标题、年份、海报、简介，'
            '不该在用户只是「看看有哪些候选」的时候发生 —— 这就是'
            '「确认」那一步。',
      );
      expect(find.text('还没选候选。'), findsOneWidget);
    });

    testWidgets('选中 → 确认更新 → 落库并关闭对话框', (tester) async {
      final (scraper, repo) = await open(tester);

      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('超级马力欧银河大电影'));
      await tester.pump();

      expect(applyEnabled(tester), isTrue);
      expect(find.textContaining('将更新为「超级马力欧银河大电影」'), findsOneWidget);

      await tester.tap(applyButton());
      await tester.pump();
      await tester.pump();

      expect(scraper.resolved!.sourceId, '35000001');
      expect(repo.written, hasLength(1));
      expect(repo.written.single.title, '超级马力欧银河大电影');
      expect(repo.written.single.year, 2026);
      expect(repo.written.single.source, ScrapeSource.online);
      expect(
        find.text('手动刮削'),
        findsNothing,
        reason: '成功之后要关掉对话框，让用户直接看到详情页换好的标题与海报。',
      );
    });

    testWidgets('零候选时给一句「换个词再试」，而不是空白', (tester) async {
      await open(tester, candidates: const []);

      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('没有候选'), findsOneWidget);
    });

    testWidgets('片名为空 → 拒绝搜索，不花额度', (tester) async {
      final (scraper, _) = await open(tester);

      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pump();

      expect(find.text('片名不能为空。'), findsOneWidget);
      expect(scraper.searchCalls, 0);
    });

    testWidgets('应用失败时留在对话框里，让用户换一条再试', (tester) async {
      final scraper = _ManualScraper(candidates: const [candidate]);
      final repo = _RecordingRepo();
      await repo.upsertWorks([work()], now: now);
      await repo.upsertItems([item()], now: now);
      repo.written.clear();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaRepositoryProvider.overrideWithValue(repo),
            workScraperProvider.overrideWith(
              (ref) => WorkScraper(
                library: repo,
                // 解析永远失败：详情接口挂了 / 响应不是条目。
                pipeline: ScraperPipeline([_Unresolvable(scraper)]),
                clock: () => now,
              ),
            ),
            posterCacheProvider.overrideWithValue(
              PosterCache(http: _NoImageHttp(), dirPath: posterDir.path),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => ManualScrapeDialog.show(context, work()),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, '搜索'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('超级马力欧银河大电影'));
      await tester.pump();

      await tester.tap(applyButton());
      await tester.pump();
      await tester.pump();

      expect(
        find.text('手动刮削'),
        findsOneWidget,
        reason: '关掉的话用户还得重新敲一遍片名 —— 而他要做的只是换一条候选。',
      );
      expect(repo.written, isEmpty);

      // 报错文案必须是**手动通道**那一句。用户刚刚亲手点了一条候选，
      // 如果这里显示的是自动通道的「在线源都没找到匹配的条目 / 可能是片名
      // 解析不准」，他会以为界面坏了 —— 那正是这条测试要钉住的错配。
      expect(
        find.textContaining('换一条候选'),
        findsOneWidget,
        reason: '失败的原因是**这一条**解析不出完整信息，下一步是换一条。',
      );
      expect(
        find.textContaining('片名解析不准'),
        findsNothing,
        reason: '这句话讲的是自动流程（拿文件名解析出来的词去搜）。'
            '用户已经在候选列表里看到了结果，被告知「片名解析不准」'
            '只会让他去改一个本来没错的词。',
      );
    });
  });
}

/// 搜得出候选、但解析永远失败。
class _Unresolvable implements MetadataScraper {
  _Unresolvable(this._inner);

  final MetadataScraper _inner;

  @override
  String get id => _inner.id;

  @override
  String get displayName => _inner.displayName;

  @override
  bool get isEnabled => _inner.isEnabled;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) => _inner.scrape(query);

  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) =>
      _inner.search(query);

  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async => null;
}
