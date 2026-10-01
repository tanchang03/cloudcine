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
        'https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2902705337.jpg',
        reason: '搜索结果的 cover_url 被服务端套了 `imageView2/…/h/120/format/jpg`，'
            '是一条 120px 高的横条 —— 拿它当海报会是一道细缝。'
            '海报只能取自详情接口。',
      );
      expect(md.posterUrl, isNot(contains('h/120')));
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
          return _ok(_searchBody(
            subjects: [
              _hit(id: '1', title: '某片', targetType: 'movie', year: '2023'),
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
      final scraper = DoubanScraper(
        http: http,
        cookie: 'dbcl2=abc',
        minRequestInterval: Duration.zero,
      );

      expect(await scraper.scrape(_qMovie), isNull);
      expect(
        scraper.isNeedLogin,
        isTrue,
        reason: '实测同一个 `103 need_login` 既可能带 200 也可能带 403。'
            '先看状态码会把 403 那次的熔断信号漏掉 —— 表现是「豆瓣时好时坏」。',
      );
      expect(http.calls.length, 1);
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
        reason: '实测 img*.doubanio.com 缺 Referer 一律返回 418。',
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
}
