import 'dart:typed_data';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/scrape/douban_client.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程的假 HTTP 客户端。记下每次请求的 url / query / headers。
class _FakeHttp implements HttpClientLike {
  _FakeHttp(this.handler);

  final Future<HttpResult> Function(_Call call) handler;

  final List<_Call> calls = [];

  List<_Call> get searchCalls =>
      calls.where((c) => c.path.endsWith('/search')).toList();

  List<_Call> get detailCalls =>
      calls.where((c) => c.path.contains('/movie/')).toList();

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) {
    final call = _Call(url, query ?? const {}, headers ?? const {});
    calls.add(call);
    return handler(call);
  }

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> putBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  Future<String> postBytes(
    String url, {
    required List<int> body,
    Map<String, String>? headers,
    Duration? timeout,
  }) =>
      throw UnimplementedError();

  @override
  void close() {}
}

class _Call {
  _Call(this.url, this.query, this.headers);

  final String url;
  final Map<String, Object?> query;
  final Map<String, String> headers;

  String get path => Uri.parse(url).path;

  @override
  String toString() => 'GET $url $query';
}

/// 可拨动的假时钟。
///
/// 冷却 / 退避都是纯时间函数。用真实时钟测就得 `await Future.delayed(61s)`，
/// 既慢又不稳（CI 上尤其）；拨表则是瞬时且确定的。
class _Clock {
  _Clock(this.now);

  DateTime now;

  DateTime call() => now;

  void advance(Duration d) => now = now.add(d);
}

HttpResult _ok(Map<String, Object?> json) =>
    HttpResult(statusCode: 200, json: json, rawBody: '{}');

/// 一条搜索候选（`subjects.items` / `smart_box` 里的元素形状相同）。
Map<String, Object?> _hit({
  required String id,
  required String title,
  required String targetType,
  String? year,
  double? rating,
  int? ratingCount,
}) =>
    <String, Object?>{
      'layout': 'subject',
      'target_type': targetType,
      'target': <String, Object?>{
        'id': id,
        'title': title,
        'year': year,
        // 搜索结果的封面是被套了 `h/120` 的**横条**，不能当海报用。
        // 这里刻意保留那个参数，好让「有没有误用」能被断言出来。
        'cover_url': 'https://qnmob3-sign.doubanio.com/view/photo/large/'
            'public/p$id.jpg?imageView2/0/q/80/w/9999/h/120/format/jpg',
        // 只要有评价人数就要给出 rating 对象 —— 真实响应里两者是一起的，
        // 少了它热度这一档就没法被验证。
        if (rating != null || ratingCount != null)
          'rating': {'value': rating, 'count': ratingCount ?? 0},
      },
    };

/// `smart_box` 里的「更多结果」占位项（`target` 为 null）。
Map<String, Object?> _moreResults() => <String, Object?>{
      'layout': 'more_results',
      'target_type': 'more_results',
      'target': null,
    };

/// 搜索响应。`subjects` 是**对象**（条目在 `items`），`smart_box` 是**数组**。
Map<String, Object?> _searchBody({
  List<Map<String, Object?>> subjects = const [],
  List<Map<String, Object?>> smartBox = const [],
}) =>
    <String, Object?>{
      'banned': '',
      'fuzzy': '',
      'subjects': {'items': subjects, 'target_name': '电影'},
      'smart_box': smartBox,
      'contents': <String, Object?>{},
    };

/// 详情响应。**77 个顶层字段**是实测的规模，这里只留用得到的。
Map<String, Object?> _detailBody({
  String id = '34874646',
  String type = 'tv',
  String title = '繁花',
  String year = '2023',
  String originalTitle = '',
  double? rating = 8.1,
  List<String> genres = const ['剧情'],
  String? intro = '九十年代的上海……',
  String? coverUrl =
      'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2902705337.jpg',
}) =>
    <String, Object?>{
      'id': id,
      'type': type,
      'is_tv': type == 'tv',
      'title': title,
      'original_title': originalTitle,
      'year': year,
      'rating': rating == null ? null : {'value': rating, 'count': 1429164},
      'genres': genres,
      'intro': intro,
      'cover_url': coverUrl,
      'pic': {'large': coverUrl, 'normal': coverUrl},
      'episodes_count': 30,
      'aka': ['繁花 电视剧版'],
      'pubdate': ['2023-12-27(中国大陆)'],
      'release_date': null,
    };

/// 一个「搜索 + 详情」都能应答的假服务端。
_FakeHttp _server({
  required Map<String, Object?> Function(String q) search,
  Map<String, Object?> Function(String id)? detail,
}) =>
    _FakeHttp((call) async {
      if (call.path.endsWith('/search')) {
        return _ok(search('${call.query['q']}'));
      }
      final id = call.path.split('/').last;
      return _ok(detail?.call(id) ?? _detailBody(id: id));
    });

const _qEpisode = ScrapeQuery(
  title: '仙逆',
  kind: MediaKind.episode,
  season: 1,
  episode: 1,
  year: 2023,
);

const _qMovie = ScrapeQuery(
  title: '流浪地球2',
  kind: MediaKind.movie,
  year: 2023,
);

void main() {
  group('DoubanScraper 搜索结果的两个来源', () {
    test('正主只在 smart_box 里时也能刮到 —— 只读 subjects 会静默刮错片子', () async {
      // 2026-10-01 实测搜「繁花」的真实形状：`subjects.items` 只有两本书和
      // 一个 2028 年的「繁花(影版)」，真正的剧集只在 `smart_box` 里。
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '22714154', title: '繁花', targetType: 'book'),
            _hit(id: '25698291', title: '繁花', targetType: 'book'),
            _hit(
              id: '26298999',
              title: '繁花(影版)',
              targetType: 'movie',
              year: '2028',
            ),
          ],
          smartBox: [
            _hit(
              id: '34874646',
              title: '繁花',
              targetType: 'tv',
              year: '2023',
              rating: 8.1,
              ratingCount: 300000,
            ),
            _moreResults(),
          ],
        ),
        detail: (id) => _detailBody(id: id, title: '繁花'),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(title: '繁花', kind: MediaKind.episode, year: 2023),
      );

      expect(
        md,
        isNotNull,
        reason: '豆瓣搜索的结果分三段（subjects / smart_box / contents），'
            '而正片条目经常**不在** subjects.items 里。只读 subjects 不会报错，'
            '只会把「繁花(影版)」或者一本书当成正主 —— 用户看到的是'
            '「刮错了」，而不是「刮不到」。',
      );
      expect(md!.onlineId, 'douban/tv/34874646');
      expect(http.detailCalls.single.path, contains('/movie/34874646'));
    });

    test('非影视条目（书 / 音乐）会被剔掉', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '22714154', title: '繁花', targetType: 'book'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(
        await scraper.scrape(
          const ScrapeQuery(title: '繁花', kind: MediaKind.episode),
        ),
        isNull,
        reason: '`type=movie` 参数**不是过滤器** —— 实测传 movie 也会返回 book。'
            '不自己按 target_type 剔掉，就会去查一本书的「详情」。',
      );
      expect(http.detailCalls, isEmpty);
    });

    test('标题对不上的候选直接出局，不做模糊兜底', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1', title: '完全无关的片子', targetType: 'movie', year: '2023'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(await scraper.scrape(_qMovie), isNull);
      expect(http.detailCalls, isEmpty);
    });
  });

  group('DoubanScraper 候选排序', () {
    test('前缀匹配 + 年份 + 类型：仙逆 → 第一季 而不是 年番3', () async {
      // 实测搜「仙逆」返回的就是这一串分季条目。
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(
              id: '37480076',
              title: '仙逆 年番3',
              targetType: 'tv',
              year: '2026',
              rating: 8.4,
              ratingCount: 2606,
            ),
            _hit(
              id: '35679839',
              title: '仙逆 第一季',
              targetType: 'tv',
              year: '2023',
              rating: 8.0,
              ratingCount: 26954,
            ),
            _hit(
              id: '99999999',
              title: '仙逆 年番2',
              targetType: 'tv',
              year: '2025',
              rating: 8.6,
              ratingCount: 4200,
            ),
          ],
        ),
        // 标题与年份来自**详情**接口，搜索候选只用来选 id。
        detail: (id) => _detailBody(
          id: id,
          type: 'tv',
          title: '仙逆 第一季',
          year: '2023',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(_qEpisode);

      expect(
        md!.onlineId,
        'douban/tv/35679839',
        reason: 'TMDB 那种「直接取第一条」在豆瓣会经常错：同一部作品被拆成'
            '第一季 / 年番2 / 年番3 多条，而错的那次是**静默**的。'
            '年份差 ≥2 年必须重罚，否则 2026 的年番会把 2023 的正主挤掉。',
      );
      expect(md.title, '仙逆 第一季');
    });

    test('年份相同、标题相同的两条 → 评价人数多的胜出', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(
              id: 'low',
              title: '某剧',
              targetType: 'tv',
              year: '2023',
              ratingCount: 120,
            ),
            _hit(
              id: 'high',
              title: '某剧',
              targetType: 'tv',
              year: '2023',
              ratingCount: 480000,
            ),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      await scraper.scrape(
        const ScrapeQuery(title: '某剧', kind: MediaKind.episode, year: 2023),
      );

      expect(http.detailCalls.single.path, contains('/movie/high'));
    });

    test('查询类型未知时不做 movie/tv 偏向（综艺解析不出季集号）', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(
              id: 'variety',
              title: '某综艺',
              targetType: 'tv',
              year: '2024',
              ratingCount: 90000,
            ),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(
          title: '某综艺',
          kind: MediaKind.unknown,
          year: 2024,
        ),
      );

      expect(
        md,
        isNotNull,
        reason: '综艺在豆瓣记为 tv，而 `第12期.mkv` 解析不出季集号、kind 是 unknown。'
            '这时若按「非剧集就偏向 movie」加分，会把综艺判出局。',
      );
      expect(md!.onlineId, 'douban/tv/variety');
    });
  });

  group('DoubanScraper 宽松档（无年份的电影）', () {
    // 无年份时年份硬闸门失效，闸门只认精确同名；并且要求**第一条影视候选**
    // 就是精确同名（第一位按「跳过书 / 音乐 / 游戏后的第一个影视条目」算）。
    // ⚠️ 不要求唯一 —— 实测「奥德赛」豆瓣上就有 2 条精确同名。
    const q = ScrapeQuery(
      title: '奥德赛',
      kind: MediaKind.movie,
      requireExactTitle: true,
    );

    test('精确同名 + 唯一 + 首位 → 命中', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(
              id: '36808876',
              title: '奥德赛',
              targetType: 'movie',
              year: '2026',
            ),
            // 后面跟着「前缀同名」的候选：它不该影响判定。
            _hit(id: '2', title: '奥德赛：归来', targetType: 'movie', year: '2024'),
          ],
        ),
        detail: (id) => _detailBody(
          id: id,
          type: 'movie',
          title: '奥德赛',
          year: '2026',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(q);

      expect(md, isNotNull);
      expect(md!.onlineId, 'douban/movie/36808876');
    });

    test('只有前缀同名 → null', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '2', title: '奥德赛：归来', targetType: 'movie', year: '2024'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(
        await scraper.scrape(q),
        isNull,
        reason: '「奥德赛：归来」在严格档下拿 0.86（> 0.6）通过 —— '
            '那是静默刮错。宽松档没有年份可兜底，只认精确同名',
      );
    });

    test('精确同名但**不在第一位** → null', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1', title: '特洛伊', targetType: 'movie', year: '2004'),
            _hit(id: '36808876', title: '奥德赛', targetType: 'movie', year: '2026'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(await scraper.scrape(q), isNull);
    });

    test('**多条**精确同名 → 取第一条（**不要求唯一**）', () async {
      // 实测 2026-10-03：搜「奥德赛」时豆瓣返回 **2 条**精确同名、TMDB 4 条。
      // 加「唯一」会把正主也挡掉。
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1', title: '英雄', targetType: 'movie', year: '2002'),
            _hit(id: '2', title: '英雄', targetType: 'movie', year: '2007'),
          ],
        ),
        detail: (id) => _detailBody(
          id: id,
          type: 'movie',
          title: '英雄',
          year: '2002',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(
          title: '英雄',
          kind: MediaKind.movie,
          requireExactTitle: true,
        ),
      );

      expect(md, isNotNull);
      expect(md!.onlineId, 'douban/movie/1');
    });

    test('⚠️ 「第一位」按跳过书 / 音乐 / 游戏之后的影视条目算', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            // 实测搜「繁花」的前两条就是两本书 —— 它们不该把「第一位」占掉。
            _hit(id: '22714154', title: '繁花', targetType: 'book'),
            _hit(id: '36808876', title: '奥德赛', targetType: 'movie', year: '2026'),
          ],
        ),
        detail: (id) => _detailBody(
          id: id,
          type: 'movie',
          title: '奥德赛',
          year: '2026',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(q);

      expect(
        md,
        isNotNull,
        reason: '书 / 音乐 / 游戏不是候选，不该占「第一位」—— 否则只要搜索'
            '结果里先冒出一本书，宽松档就永远不生效',
      );
      expect(md!.onlineId, 'douban/movie/36808876');
    });
  });

  group('DoubanScraper 详情与映射', () {
    test('类型读的是响应体的 type —— 301 跟随之后才知道是剧集', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '34874646', title: '繁花', targetType: 'tv', year: '2023'),
          ],
        ),
        detail: (id) => _detailBody(id: id, type: 'tv'),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(title: '繁花', kind: MediaKind.episode, year: 2023),
      );

      expect(md!.onlineId, 'douban/tv/34874646');
      expect(
        http.detailCalls.single.path,
        contains('/movie/34874646'),
        reason: '详情一律先打 `/movie/{id}`：剧集是服务端 301 到 `/tv/{id}`，'
            '由 HTTP 层跟随。自己按 kind 拼路径反而会漏掉'
            '「文件名没标出是剧集」的片子。',
      );
    });

    test('电影映射：onlineId 记 movie，字段按顶层读', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '35267208', title: '流浪地球2', targetType: 'movie', year: '2023'),
          ],
        ),
        detail: (id) => _detailBody(
          id: id,
          type: 'movie',
          title: '流浪地球2',
          year: '2023',
          genres: ['科幻', '冒险', '灾难'],
          rating: 8.3,
          intro: '太阳急速衰老与膨胀……',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(_qMovie);

      expect(md!.title, '流浪地球2');
      expect(md.year, 2023);
      expect(md.rating, 8.3);
      expect(md.genres, ['科幻', '冒险', '灾难']);
      expect(md.overview, contains('太阳'));
      expect(md.onlineId, 'douban/movie/35267208');
      expect(md.source, ScrapeSource.online);
      expect(md.matchedQuery, '流浪地球2');
    });

    test('海报只取详情接口的 cover_url，搜索里的 h/120 横条不会被用', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '34874646', title: '繁花', targetType: 'tv', year: '2023'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(title: '繁花', kind: MediaKind.episode, year: 2023),
      );

      expect(
        md!.posterUrl,
        'https://qnmob3-sign.doubanio.com/view/photo/m_ratio_poster/public/p2902705337.jpg',
        reason: '搜索结果的 cover_url 被服务端套了 `imageView2/…/h/120/format/jpg`，'
            '是一条 120px 高的横条 —— 拿它当海报会是一道细缝。'
            '海报只能取自详情接口。详情接口给的 `img*` 子域会被改写成'
            '`qnmob3-sign`（见类文档坑 #6：img* 子域即使带 Referer 也 403/418）。',
      );
      expect(md.posterUrl, isNot(contains('h/120')));
      expect(md.posterUrl, isNot(contains('img3.doubanio.com')));
    });

    test('详情 cover_url 的 img* 子域一律改写成 qnmob3-sign', () async {
      // 2026-10-02 日志：同一张图 p2616542123.jpg，同一个 Referer 头，
      // qnmob3-sign.doubanio.com → 200，img3.doubanio.com → 403，
      // img9.doubanio.com → 418。详情接口给的 cover_url 用的正是 img* 子域，
      // 不改写 → PosterCache 下载失败 → 刮削成功但没封面。
      final http = _FakeHttp((call) async {
        if (call.path.endsWith('/search')) {
          return _ok(_searchBody(
            subjects: [
              _hit(id: '35170001', title: '吞噬星空', targetType: 'tv', year: '2023'),
            ],
          ));
        }
        return _ok(_detailBody(
          id: '35170001',
          type: 'tv',
          title: '吞噬星空 第1季',
          coverUrl:
              'https://img9.doubanio.com/view/photo/m_ratio_poster/public/p2933465504.jpg',
        ));
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(title: '吞噬星空', kind: MediaKind.episode, year: 2023),
      );

      expect(md, isNotNull);
      expect(
        md!.posterUrl,
        'https://qnmob3-sign.doubanio.com/view/photo/m_ratio_poster/public/p2933465504.jpg',
        reason: 'img9.doubanio.com 在日志里返回 418。改写成 qnmob3-sign 后'
            '路径不变（m_ratio_poster），只是域名换了 —— PosterCache 下载时'
            '带 Referer 就能拿到 200。',
      );
    });

    test('详情缺字段时不抛：没有海报就 posterUrl 为 null', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1', title: '流浪地球2', targetType: 'movie', year: '2023'),
          ],
        ),
        detail: (id) => <String, Object?>{
          'id': id,
          'type': 'movie',
          'title': '流浪地球2',
          'year': '2023',
          // 没有 cover_url / rating / genres / intro
        },
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(_qMovie);

      expect(md, isNotNull);
      expect(md!.posterUrl, isNull);
      expect(md.rating, isNull);
      expect(md.genres, isEmpty);
    });

    test('详情请求失败 → null，不抛（一部刮不到不能中断整批）', () async {
      final http = _FakeHttp((call) async {
        if (call.path.endsWith('/search')) {
          // 片名必须与查询对得上，否则会被匹配闸门提前拦掉，
          // 这条用例就测不到「详情失败」这条路径了。
          return _ok(_searchBody(
            subjects: [
              _hit(id: '1', title: '流浪地球2', targetType: 'movie', year: '2023'),
            ],
          ));
        }
        return const HttpResult.networkFailure('Connection reset');
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(await scraper.scrape(_qMovie), isNull);
    });
  });

  group('DoubanScraper 额度与熔断', () {
    test('HTTP 200 带 code 103 → 熔断，之后一次请求都不发', () async {
      final http = _FakeHttp(
        (_) async => _ok(<String, Object?>{
          'request': 'GET /v2/search',
          'msg': 'need_login',
          'code': 103,
          'localized_message': null,
        }),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(await scraper.scrape(_qMovie), isNull);
      expect(scraper.isNeedLogin, isTrue);
      expect(http.calls.length, 1);

      expect(await scraper.scrape(_qMovie), isNull);
      expect(
        http.calls.length,
        1,
        reason: '额度耗尽后继续打只会让这个 IP 被关得更久，'
            '而且每一次都是白等。见到 103 就必须立刻停。',
      );
    });

    test('HTTP 403 带 code 103 同样要熔断 —— 状态码不是判据', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult(
          statusCode: 403,
          json: {
            'request': 'GET /v2/search',
            'msg': 'need_login',
            'code': 103,
            'localized_message': null,
          },
          rawBody: '{"code":103}',
        ),
      );
      // 注入时钟：冷却时长是「截止时刻 − 现在」，用真实时钟读出来会差
      // 几十微秒，断言相等就会随机失败。
      final clock = _Clock(DateTime(2026, 10, 1, 17, 25));
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
        clock: clock.call,
      );

      expect(await scraper.scrape(_qMovie), isNull);
      expect(
        scraper.isNeedLogin,
        isTrue,
        reason: '实测同一个 `103 need_login` 既可能带 200 也可能带 403。'
            '先看状态码会把 403 那次的熔断信号漏掉 —— 表现是「豆瓣时好时坏」。',
      );
      expect(http.calls.length, 1);
      expect(
        scraper.needLoginCooldown,
        DoubanScraper.initialNeedLoginBackoff,
        reason: '是**冷却**不是永久熔断。2026-10-01 实测：同一个 Cookie、'
            '同一个出口 IP，吃到 403+103 之后几分钟再打是 200 —— 那次 403 '
            '是瞬时风控。按永久熔断处理会把豆瓣在本进程内彻底关掉，'
            '用户只能重启应用，界面上还什么都不说。',
      );
    });

    test('连续 3 次网络失败熔断，之后不再发请求', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult.networkFailure('Connection timed out'),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      for (var i = 0; i < 3; i++) {
        expect(await scraper.scrape(_qMovie), isNull);
      }
      expect(http.calls.length, 3);
      expect(scraper.isUnreachable, isTrue);

      expect(await scraper.scrape(_qMovie), isNull);
      expect(http.calls.length, 3);
    });

    test('没配 Cookie 时 isEnabled 为假，一次请求都不发', () async {
      final http = _FakeHttp((_) async => _ok(const <String, Object?>{}));
      final scraper = DoubanScraper(
        http: http,
        cookie: '   ',
        minRequestInterval: Duration.zero,
      );

      expect(scraper.isEnabled, isFalse);
      expect(await scraper.scrape(_qMovie), isNull);
      expect(
        http.calls,
        isEmpty,
        reason: '匿名额度只有约 10 个搜索词，全盘刮必然中途耗尽。'
            '不给「配了也必然失败」的默认，所以没 Cookie 就整个不启用。',
      );
    });
  });

  group('DoubanScraper 查询词与请求头', () {
    test('第一个词就有候选时，不花第二个词的额度', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1', title: '流浪地球2', targetType: 'movie', year: '2023'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      await scraper.scrape(
        const ScrapeQuery(
          title: '流浪地球2',
          alternateTitle: 'The Wandering Earth II',
          kind: MediaKind.movie,
          year: 2023,
        ),
      );

      expect(
        http.searchCalls.length,
        1,
        reason: '额度按「不同的搜索词」计，多搜一个词就是多烧一格。'
            '第一个词已经有候选了就没有理由再花第二个。',
      );
      expect(http.searchCalls.single.query['q'], '流浪地球2');
    });

    test('第一个词零候选时才试备用标题', () async {
      final http = _server(
        search: (q) => _searchBody(
          subjects: q == 'The Wandering Earth II'
              ? [
                  _hit(
                    id: '2',
                    title: '流浪地球2',
                    targetType: 'movie',
                    year: '2023',
                  ),
                ]
              : const [],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.scrape(
        const ScrapeQuery(
          title: '流浪地球2',
          alternateTitle: 'The Wandering Earth II',
          kind: MediaKind.movie,
          year: 2023,
        ),
      );

      expect(md!.matchedQuery, 'The Wandering Earth II');
      expect(
        http.searchCalls.map((c) => c.query['q']).toList(),
        ['流浪地球2', 'The Wandering Earth II'],
      );
    });

    test('搜索请求带 Referer / Cookie / for_mobile', () async {
      final http = _server(search: (_) => _searchBody());
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc; bid=xyz',
        minRequestInterval: Duration.zero,
      );

      await scraper.scrape(_qMovie);

      final call = http.searchCalls.single;
      expect(
        call.headers['Referer'],
        'https://movie.douban.com/',
        reason: 'rexxar 接口少了 Referer 会被拒；这是它唯一的「鉴权」。',
      );
      expect(call.headers['Cookie'], 'dbcl2=abc; bid=xyz');
      expect(call.query['for_mobile'], '1');
      expect(call.query['type'], 'movie');
    });
  });

  group('DoubanScraper 海报请求头', () {
    test('豆瓣图片地址要带 Referer，否则 418', () {
      expect(
        DoubanScraper.imageHeaders()['Referer'],
        'https://movie.douban.com/',
        reason: '实测豆瓣图片 CDN 缺 Referer 一律返回 418。'
            '（但 img* 子域带 Referer 仍可能 403，所以落库时还做了域名改写。）',
      );
    });

    test('不把豆瓣 Cookie 送去图片 CDN', () {
      expect(
        DoubanScraper.imageHeaders().containsKey('Cookie'),
        isFalse,
        reason: '实测图片 CDN 只看 Referer。把登录凭证送到图片域名上没有'
            '任何收益，能少送一处就少送一处。',
      );
    });

    test('ownsImageUrl 认出豆瓣 CDN 的各种子域', () {
      expect(
        DoubanScraper.ownsImageUrl('https://img3.doubanio.com/view/photo/x.jpg'),
        isTrue,
      );
      expect(
        DoubanScraper.ownsImageUrl(
          'https://qnmob3-sign.doubanio.com/view/photo/x.jpg?sa_cv=1',
        ),
        isTrue,
      );
      expect(DoubanScraper.ownsImageUrl('https://image.tmdb.org/t/p/w500/x.jpg'),
          isFalse);
      expect(
        DoubanScraper.ownsImageUrl('https://notdoubanio.com.evil.test/x.jpg'),
        isFalse,
        reason: '必须按「.doubanio.com 结尾」判，不能用 contains —— '
            '否则一个叫 notdoubanio.com 的域名也会被当成豆瓣。',
      );
    });
  });

  group('DoubanScraper 冷却可以恢复', () {
    test('冷却到期 + 风控解除 → 自动恢复，不需要重启应用', () async {
      final clock = _Clock(DateTime(2026, 10, 1, 17, 25));
      var blocked = true;
      final http = _FakeHttp((call) async {
        if (call.path.endsWith('/search')) {
          if (blocked) {
            return const HttpResult(
              statusCode: 403,
              json: {'code': 103, 'msg': 'need_login'},
              rawBody: '{"code":103}',
            );
          }
          return _ok(_searchBody(
            subjects: [
              _hit(
                id: '35267208',
                title: '流浪地球2',
                targetType: 'movie',
                year: '2023',
              ),
            ],
          ));
        }
        return _ok(_detailBody(
          id: '35267208',
          type: 'movie',
          title: '流浪地球2',
          year: '2023',
        ));
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
        clock: clock.call,
      );

      expect(await scraper.scrape(_qMovie), isNull);
      expect(scraper.isNeedLogin, isTrue);

      // 冷却期内：一次请求都不发（省额度，也免得把 IP 关得更久）。
      await scraper.scrape(_qMovie);
      expect(http.calls.length, 1);

      // 风控解除 + 拨过冷却时间。
      blocked = false;
      clock.advance(const Duration(seconds: 61));

      expect(
        await scraper.scrape(_qMovie),
        isNotNull,
        reason: '2026-10-01 实测：日志 17:25:32 吃到 403+103 之后，'
            '17:26:15 与 17:27:07 两次刮削**连请求都没发**就返回了 —— '
            '旧的单向熔断把豆瓣在本进程内永久关掉。'
            '而同一 Cookie / 同一 IP 几分钟后打回去是 200。',
      );
      // 恢复后的那次刮削是「搜索 + 详情」两次请求，加上最初那次共 3 次。
      expect(http.calls.length, 3);
      expect(scraper.isNeedLogin, isFalse);
    });

    test('再吃一次 103 → 冷却时长翻倍', () async {
      final clock = _Clock(DateTime(2026, 10, 1, 17, 0));
      final http = _FakeHttp(
        (_) async => _ok(const <String, Object?>{
          'request': 'GET /v2/search',
          'msg': 'need_login',
          'code': 103,
        }),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
        clock: clock.call,
      );

      await scraper.scrape(_qMovie);
      expect(scraper.needLoginCooldown, DoubanScraper.initialNeedLoginBackoff);

      clock.advance(const Duration(seconds: 61));
      await scraper.scrape(_qMovie);

      expect(
        scraper.needLoginCooldown,
        DoubanScraper.initialNeedLoginBackoff * 2,
        reason: '退避必须翻倍。否则「额度真的耗尽」时会一直按 60 秒的节奏'
            '反复白打 —— 那正是原实现想避免的事。',
      );
    });

    test('冷却封顶：吃到多少次 103 都不会超过上限', () async {
      final clock = _Clock(DateTime(2026, 10, 1, 17, 0));
      final http = _FakeHttp(
        (_) async => _ok(const <String, Object?>{'code': 103, 'msg': 'need_login'}),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
        clock: clock.call,
      );

      for (var i = 0; i < 10; i++) {
        await scraper.scrape(_qMovie);
        expect(
          scraper.needLoginCooldown <= DoubanScraper.maxNeedLoginBackoff,
          isTrue,
        );
        clock.advance(
          DoubanScraper.maxNeedLoginBackoff + const Duration(seconds: 1),
        );
      }
    });

    test('网络失败熔断同样会过期 —— 用户先开代理再回来刮是常规操作', () async {
      final clock = _Clock(DateTime(2026, 10, 1, 17, 0));
      var offline = true;
      final http = _FakeHttp((call) async {
        if (offline) return const HttpResult.networkFailure('Connection timed out');
        if (call.path.endsWith('/search')) {
          return _ok(_searchBody(
            subjects: [
              _hit(
                id: '35267208',
                title: '流浪地球2',
                targetType: 'movie',
                year: '2023',
              ),
            ],
          ));
        }
        return _ok(_detailBody(id: '35267208', type: 'movie'));
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
        clock: clock.call,
      );

      for (var i = 0; i < 3; i++) {
        await scraper.scrape(_qMovie);
      }
      expect(scraper.isUnreachable, isTrue);

      offline = false;
      clock.advance(DoubanScraper.unreachableBackoff + const Duration(seconds: 1));

      expect(
        await scraper.scrape(_qMovie),
        isNotNull,
        reason: '永久熔断的代价是「用户修好了网络，豆瓣还是不动」。',
      );
      expect(scraper.isUnreachable, isFalse);
    });
  });

  group('DoubanScraper.probe（设置页的「测试连接」）', () {
    test('没填 Cookie → noCookie，一次请求都不发', () async {
      final http = _FakeHttp((_) async => _ok(const <String, Object?>{}));
      final r = await DoubanScraper(
        http: http,
        cookie: '   ',
        minRequestInterval: Duration.zero,
      ).probe();

      expect(r.status, DoubanProbeStatus.noCookie);
      expect(r.ok, isFalse);
      expect(http.calls, isEmpty);
    });

    test('网络层失败 → unreachable', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult.networkFailure('Connection timed out'),
      );
      final r = await DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      ).probe();

      expect(r.status, DoubanProbeStatus.unreachable);
      expect(r.message, contains('连不上'));
    });

    test('103 → needLogin，并指出 Cookie 里有没有 dbcl2', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult(
          statusCode: 403,
          json: {'code': 103, 'msg': 'need_login'},
          rawBody: '{"code":103}',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'll="108304"; bid=VNskJTU3PRo',
        minRequestInterval: Duration.zero,
      );

      final r = await scraper.probe();

      expect(r.status, DoubanProbeStatus.needLogin);
      expect(
        r.loggedIn,
        isFalse,
        reason: '只贴 bid 是匿名态。探测必须把这件事说出来 —— '
            '否则用户会一直以为「我填了 Cookie 啊」。',
      );
      expect(r.message, contains('没有 dbcl2'));
      expect(
        scraper.isNeedLogin,
        isTrue,
        reason: '探测吃到 103 也要进冷却，否则用户连点几次会把 IP 关得更久。',
      );
    });

    test('正常返回 → ok，报出候选数并说明是登录态', () async {
      final http = _FakeHttp(
        (_) async => _ok(_searchBody(
          subjects: [
            _hit(id: '1', title: '流浪地球', targetType: 'movie', year: '2019'),
            _hit(id: '2', title: '流浪地球2', targetType: 'movie', year: '2023'),
          ],
        )),
      );
      final r = await DoubanScraper(
        http: http,
        cookie: 'll="1"; bid=x; dbcl2="188770628:abc"',
        minRequestInterval: Duration.zero,
      ).probe();

      expect(r.status, DoubanProbeStatus.ok);
      expect(r.ok, isTrue);
      expect(r.candidateCount, 2);
      expect(r.loggedIn, isTrue);
      expect(r.message, contains('登录态'));
    });

    test('接口通但零结果 → empty（区分「接口不通」与「接口改版」）', () async {
      final http = _FakeHttp((_) async => _ok(_searchBody()));
      final r = await DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      ).probe();

      expect(r.status, DoubanProbeStatus.empty);
      expect(r.ok, isFalse);
    });

    test('探测词必出结果，且不受节流影响', () async {
      final http = _FakeHttp(
        (_) async => _ok(_searchBody(
          subjects: [
            _hit(id: '1', title: '流浪地球', targetType: 'movie', year: '2019'),
          ],
        )),
      );
      await DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: const Duration(seconds: 3),
      ).probe();

      expect(
        http.calls.single.query['q'],
        DoubanScraper.probeWord,
        reason: '探测词必须选一个必定有结果的，否则分不出'
            '「接口通但这个词零命中」与「接口根本不通」。',
      );
    });

    test('探测成功后清掉熔断 —— 修好了就该立刻能用', () async {
      var blocked = true;
      final http = _FakeHttp((_) async {
        if (blocked) {
          return const HttpResult(
            statusCode: 403,
            json: {'code': 103, 'msg': 'need_login'},
            rawBody: '{"code":103}',
          );
        }
        return _ok(_searchBody(
          subjects: [
            _hit(id: '1', title: '流浪地球', targetType: 'movie', year: '2019'),
          ],
        ));
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      await scraper.probe();
      expect(scraper.isNeedLogin, isTrue);

      blocked = false;
      final r = await scraper.probe();

      expect(r.status, DoubanProbeStatus.ok);
      expect(scraper.isNeedLogin, isFalse);
      expect(scraper.isUnreachable, isFalse);
    });
  });

  group('Cookie 形状校验', () {
    test('认出 dbcl2 —— 登录态的标志', () {
      expect(
        DoubanScraper.cookieHasLoginToken('ll="1"; bid=x; dbcl2="1:abc"'),
        isTrue,
      );
      expect(DoubanScraper.cookieHasLoginToken('dbcl2="1:abc"'), isTrue);
      expect(
        DoubanScraper.cookieHasLoginToken('ll="1";dbcl2=x'),
        isTrue,
        reason: '分号后没空格也要认 —— 从浏览器复制出来的常常没有空格。',
      );
    });

    test('只贴 bid 不算登录态', () {
      expect(
        DoubanScraper.cookieHasLoginToken('bid=VNskJTU3PRo'),
        isFalse,
        reason: '`bid` 只是匿名标识。只填它的额度仍是约 10 个搜索词，'
            '而失败表现是 103 —— 看起来跟被限流一模一样，'
            '用户会往完全错误的方向查。',
      );
    });

    test('不把 xdbcl2= 误判成 dbcl2=', () {
      expect(DoubanScraper.cookieHasLoginToken('xdbcl2=1'), isFalse);
    });

    test('认出「把 Cookie: 前缀一起贴进来」这种错法', () {
      expect(DoubanScraper.looksLikeRawHeader('Cookie: ll="1"; bid=x'), isTrue);
      expect(DoubanScraper.looksLikeRawHeader('cookie:ll="1"'), isTrue);
      expect(DoubanScraper.looksLikeRawHeader('ll="1"; bid=x'), isFalse);
    });
  });

  group('DoubanScraper 手动通道（search / resolve）', () {
    test('search 不过闸门：被自动流程拒掉的候选照样给出来', () async {
      // 这正是手动通道存在的理由。自动刮削拿目录名
      // `超z级z马z力z欧z银z河z大z电影aa` 去搜，闸门会因为标题不相似
      // 把它拦下（那是对的）；但用户手动搜「超级马力欧」时，
      // 这条候选**必须**出现在列表里让他自己挑。
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1291561', title: '低俗小说', targetType: 'movie', year: '1994'),
            _hit(
              id: '35000001',
              title: '超级马力欧银河大电影',
              targetType: 'movie',
              year: '2026',
            ),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final found = await scraper.search(
        const ScrapeQuery(
          title: '超z级z马z力z欧z银z河z大z电影aa',
          kind: MediaKind.movie,
          year: 2026,
        ),
      );

      expect(
        found.map((c) => c.title),
        containsAll(<String>['低俗小说', '超级马力欧银河大电影']),
        reason: '手动通道的语义是「用户要自己挑」—— 在这里套闸门等于'
            '把「自动没找对」的片子也一起藏起来，用户就永远纠不正了。',
      );
    });

    test('search 剔掉书 / 音乐，且**不打详情接口**（额度按搜索词计）', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '1', title: '繁花', targetType: 'book'),
            _hit(id: '2', title: '繁花', targetType: 'music'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final found = await scraper.search(
        const ScrapeQuery(title: '繁花', kind: MediaKind.episode),
      );

      expect(found, isEmpty);
      expect(
        http.detailCalls,
        isEmpty,
        reason: '候选列表要的是「有哪些片子」，不是「每部片子的完整资料」。'
            '每条候选都去打一次详情 = 一次点击烧掉十几个额度。',
      );
      expect(http.searchCalls.length, 1, reason: '手动搜一次只花 1 个搜索词。');
    });

    test('search 的缩略图是搜索结果的 cover_url（120px 横条），不是海报', () async {
      final http = _server(
        search: (_) => _searchBody(
          subjects: [
            _hit(id: '35000001', title: '某片', targetType: 'movie', year: '2026'),
          ],
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final found = await scraper.search(
        const ScrapeQuery(title: '某片', kind: MediaKind.movie),
      );

      expect(found.single.posterUrl, contains('h/120'));
      expect(found.single.source, 'douban');
      expect(found.single.sourceId, '35000001');
    });

    test('resolve 必须打详情接口 —— 完整海报与简介只在详情里', () async {
      final http = _server(
        search: (_) => _searchBody(),
        detail: (id) => _detailBody(
          id: id,
          type: 'movie',
          title: '超级马力欧银河大电影',
          year: '2026',
          originalTitle: 'The Super Mario Galaxy Movie',
          coverUrl: 'https://img3.doubanio.com/view/photo/m_ratio_poster/'
              'public/p999.jpg',
        ),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.resolve(
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '35000001',
          title: '超级马力欧银河大电影',
          year: 2026,
          // 候选上挂的是 120px 横条；resolve **不能**拿它当海报。
          posterUrl: 'https://qnmob3-sign.doubanio.com/x.jpg?h/120/format/jpg',
        ),
      );

      expect(md, isNotNull);
      expect(md!.title, '超级马力欧银河大电影');
      expect(md.year, 2026);
      expect(md.originalTitle, 'The Super Mario Galaxy Movie');
      expect(
        md.posterUrl,
        contains('m_ratio_poster'),
        reason: '落库的海报必须来自详情接口的 `cover_url`（`m_ratio_poster`，'
            '实测 540×803 = 2:3）。搜索结果的 `cover_url` 是一条 120px 高的'
            '横条，落库会让详情页显示一张被拉扁的图。',
      );
      expect(
        md.posterUrl,
        contains('qnmob3-sign.doubanio.com'),
        reason: '详情接口返回的 `cover_url` 用的是 `img3.doubanio.com` 子域，'
            '该子域即使带 Referer 也 403/418（2026-10-02 实测）。'
            '_toMetadata 必须把它改写成 `qnmob3-sign.doubanio.com`，'
            '否则 PosterCache 下载失败 → 手动刮削成功但没封面。',
      );
      expect(md.posterUrl, isNot(contains('img3.doubanio.com')));
      expect(md.onlineId, 'douban/movie/35000001');
      expect(md.source, ScrapeSource.online);
      expect(http.detailCalls.single.path, contains('/movie/35000001'));
    });

    test('resolve 的类型读响应体：`/movie/{id}` 对剧集会 301 到 /tv/{id}', () async {
      final http = _server(
        search: (_) => _searchBody(),
        detail: (id) => _detailBody(id: id, type: 'tv', title: '某剧'),
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.resolve(
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '34874646',
          title: '某剧',
          isEpisode: true,
        ),
      );

      expect(
        md!.onlineId,
        'douban/tv/34874646',
        reason: '按请求路径判断会把**所有剧集都记成电影**。',
      );
    });

    test('resolve 详情请求失败 → null（不是「用候选凑一个」）', () async {
      final http = _FakeHttp((call) async {
        if (call.path.endsWith('/search')) return _ok(_searchBody());
        // 非 2xx：`_get` 直接返回 null。
        return const HttpResult(statusCode: 500, rawBody: 'oops');
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.resolve(
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '1',
          title: '某片',
        ),
      );

      expect(
        md,
        isNull,
        reason: '拿候选里那点信息（标题 + 年份，没有海报没有简介）落库，'
            '会把作品标成「已刮削」而实际什么都没补上 —— '
            '用户看到的是一个有标题、没海报、没简介的「刮削成功」。',
      );
    });

    test('resolve 拿到 200 但内容不是条目 → null，不许拿查询词冒充标题', () async {
      final http = _FakeHttp((call) async {
        if (call.path.endsWith('/search')) return _ok(_searchBody());
        // 200，但 body 是错误对象（接口改版 / 风控页 / 网关兜底都会这样）。
        return _ok(const <String, Object?>{
          'code': 500,
          'msg': 'internal error',
          'request': 'GET /v2/movie/1',
        });
      });
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      final md = await scraper.resolve(
        const ScrapeCandidate(
          source: 'douban',
          sourceId: '1',
          title: '超级马力欧银河大电影',
        ),
      );

      expect(
        md,
        isNull,
        reason: '标题一旦允许用查询词兜底，这种响应就会产出「标题是对的、'
            '海报简介全空、source 记成 online」的假成功 —— 和「刮削成功但'
            '没有封面」这类现象一模一样，排查时最难想到根因在这里。',
      );
    });

    test('冷却期内 search 直接返回空，不发请求', () async {
      final clock = _Clock(DateTime(2026, 10, 1, 12));
      final http = _server(
        search: (_) => <String, Object?>{
          'code': DoubanScraper.needLoginCode,
          'msg': 'need_login',
        },
      );
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
        clock: clock.call,
      );

      // 先吃一次 103 把冷却打开。
      await scraper.scrape(_qMovie);
      final before = http.searchCalls.length;

      expect(await scraper.search(_qMovie), isEmpty);
      expect(
        http.searchCalls.length,
        before,
        reason: '冷却期内发请求既没用（必然还是 103）又会让限流更久。',
      );

      // 冷却过期后重新放行 —— 这是「会过期的冷却」而不是单向开关。
      clock.advance(DoubanScraper.initialNeedLoginBackoff);
      await scraper.search(_qMovie);
      expect(http.searchCalls.length, greaterThan(before));
    });
  });
}
