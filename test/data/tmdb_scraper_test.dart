import 'dart:typed_data';

import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/scrape/tmdb_client.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可编程的假 HTTP 客户端。
///
/// 记下每次请求的 url / query / headers，让测试能断言「打的是哪个端点、
/// 带了哪个参数、用的是哪种鉴权」。这三件事都是 TMDB 契约的一部分，
/// 而它们**改错了不会报错** —— 只会让结果悄悄变空，所以必须钉住。
class _FakeHttp implements HttpClientLike {
  _FakeHttp(this.handler);

  final Future<HttpResult> Function(_Call call) handler;

  final List<_Call> calls = [];

  /// 只保留搜索类请求。
  ///
  /// 类型表（`/genre/*/list`）是 [_toMetadata] 顺带打的副作用请求，
  /// 混进来会让「一共发了几次请求」这类断言莫名其妙多出 2。
  ///
  /// 注意用 `contains` 而不是 `startsWith`：baseUrl 自带版本段
  /// （`https://api.themoviedb.org/3`），所以路径是 `/3/search/movie`。
  List<_Call> get searchCalls =>
      calls.where((c) => c.path.contains('/search/')).toList();

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

  /// 去掉 baseUrl 的路径，断言起来更短。
  String get path => Uri.parse(url).path;

  @override
  String toString() => 'GET $url $query';
}

HttpResult _ok(Map<String, Object?> json) =>
    HttpResult(statusCode: 200, json: json, rawBody: '{}');

/// 一个「同时应付搜索与类型表」的假服务端。
///
/// 真实 TMDB 一次刮削会打两类端点，测试里必须都给出响应，否则类型表那次
/// 会拿到搜索的形状，把断言引到别处去。
_FakeHttp _server({
  required Map<String, Object?> Function() search,
  Map<String, Object?> Function()? genres,
}) =>
    _FakeHttp((call) async => _ok(
          call.path.contains('/genre/')
              ? (genres?.call() ?? const <String, Object?>{'genres': <Object?>[]})
              : search(),
        ));

/// 一条 TMDB **电影**搜索结果。字段名取自官方文档的 200 示例。
Map<String, Object?> _movieJson({
  int id = 550,
  String title = '搏击俱乐部',
  String originalTitle = 'Fight Club',
  String releaseDate = '1999-10-15',
  String? posterPath = '/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
  List<int> genreIds = const [18],
  double voteAverage = 8.433,
}) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'original_title': originalTitle,
      'release_date': releaseDate,
      'poster_path': posterPath,
      'backdrop_path': '/hZkgoQYus5vegHoetLkCJzb17zJ.jpg',
      'genre_ids': genreIds,
      'vote_average': voteAverage,
      'overview': '一个失眠的男人和一个卖肥皂的女人……',
    };

/// 一条 TMDB **剧集**搜索结果。
///
/// 剧集的标题字段叫 `name`、日期叫 `first_air_date` —— 和电影不是一套。
Map<String, Object?> _tvJson({
  int id = 1399,
  String name = '权力的游戏',
  String firstAirDate = '2011-04-17',
  List<int> genreIds = const [18, 10765],
}) =>
    <String, Object?>{
      'id': id,
      'name': name,
      'original_name': 'Game of Thrones',
      'first_air_date': firstAirDate,
      'poster_path': '/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg',
      'genre_ids': genreIds,
      'vote_average': 8.4,
    };

void main() {
  group('TmdbScraper 结果形状', () {
    test('从顶层 results 读结果 —— 套夸克信封会静默返回空', () async {
      final http = _server(search: () => <String, Object?>{
            'page': 1,
            'results': [_movieJson()],
            'total_pages': 1,
            'total_results': 1,
          });
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(title: '搏击俱乐部', kind: MediaKind.movie),
      );

      expect(
        md,
        isNotNull,
        reason: 'TMDB 把结果挂在**顶层** results 上（`{page, results, …}`），'
            '不是夸克那套 `data.list`。用 HttpResult.dataListItems 读会'
            '永远拿到空列表 —— 不报错、日志里也是 200，'
            '表现为「TMDB 上搜不到任何片子」，而不是任何可见的失败。',
      );
      expect(md!.title, '搏击俱乐部');
      expect(md.originalTitle, 'Fight Club');
      expect(md.year, 1999);
      expect(md.rating, 8.433);
      expect(
        md.posterUrl,
        'https://image.tmdb.org/t/p/w500/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
      );
      expect(md.onlineId, 'movie/550');
      expect(md.source, ScrapeSource.online);
      expect(md.matchedQuery, '搏击俱乐部');
    });

    test('剧集用 name / first_air_date（电影字段在剧集响应里根本不存在）', () async {
      final http = _server(search: () => <String, Object?>{
            'page': 1,
            'results': [_tvJson()],
            'total_pages': 1,
            'total_results': 1,
          });
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(
          title: '权力的游戏',
          kind: MediaKind.episode,
          season: 1,
          episode: 1,
        ),
      );

      expect(md!.title, '权力的游戏');
      expect(md.year, 2011);
      expect(md.onlineId, 'tv/1399');
      expect(http.searchCalls.map((c) => c.path), contains('/3/search/tv'));
    });

    test('results 为空 → null，不抛异常（一部刮不到不能中断整次扫描）', () async {
      final http = _server(
        search: () => const <String, Object?>{'page': 1, 'results': <Object?>[]},
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      expect(
        await scraper.scrape(
          const ScrapeQuery(title: '不存在的片子', kind: MediaKind.movie),
        ),
        isNull,
      );
    });

    test('形状不对（只有 data.list，没有 results）→ null，且不抛', () async {
      final http = _server(
        search: () => const <String, Object?>{
          'data': <String, Object?>{'list': <Object?>[]},
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      expect(
        await scraper.scrape(const ScrapeQuery(title: 'x', kind: MediaKind.movie)),
        isNull,
      );
    });
  });

  group('TmdbScraper 端点与参数', () {
    test('电影打 /search/movie，年份走 year', () async {
      final http = _server(search: () => <String, Object?>{
            'results': [_movieJson()],
          });
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      await scraper.scrape(
        const ScrapeQuery(title: '搏击俱乐部', kind: MediaKind.movie, year: 1999),
      );

      final call = http.searchCalls.single;
      expect(call.path, '/3/search/movie');
      expect(call.query['year'], 1999);
      expect(call.query['language'], 'zh-CN');
      expect(call.query['query'], '搏击俱乐部');
    });

    test('剧集年份走 first_air_date_year —— 参数名错了 TMDB 当没传', () async {
      final http = _server(search: () => <String, Object?>{
            'results': [_tvJson()],
          });
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      await scraper.scrape(
        const ScrapeQuery(title: '权力的游戏', kind: MediaKind.episode, year: 2011),
      );

      final call = http.searchCalls.single;
      expect(call.path, '/3/search/tv');
      expect(call.query['first_air_date_year'], 2011);
      expect(
        call.query.containsKey('year'),
        isFalse,
        reason: '剧集接口不认 year，带上它只会误导排查',
      );
    });

    test('带年份搜不到时去掉年份重试一次', () async {
      var n = 0;
      final http = _server(search: () {
        n++;
        // 第一次（带年份）没结果，第二次（不带年份）命中。
        //
        // ⚠️ 第二次必须返回**真的那部片子**（年份差 ≤1、片名对得上）。
        // 这里曾经直接返回默认的 `_movieJson()`（搏击俱乐部 / 1999），
        // 而查询是「流浪地球2 / 2024」—— 靠的是旧代码 `results.first`
        // 的「不校验」，那正是把《超级马力欧银河大电影》刮成
        // 《低俗小说》的同一个洞。夹具必须符合真实数据源的行为。
        return n == 1
            ? const <String, Object?>{'results': <Object?>[]}
            : <String, Object?>{
                'results': [
                  _movieJson(
                    title: '流浪地球2',
                    originalTitle: 'The Wandering Earth II',
                    releaseDate: '2023-01-22',
                  ),
                ],
              };
      });
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(title: '流浪地球2', kind: MediaKind.movie, year: 2024),
      );

      expect(
        md,
        isNotNull,
        reason: '发布组标的年份常是「发行年」，TMDB 记的是「首映年」，差一年就搜不到；'
            'TMDB 的 year 是硬过滤不是加权，所以只能去掉再搜一次',
      );
      final calls = http.searchCalls;
      expect(calls.length, 2);
      expect(calls[0].query['year'], 2024);
      expect(calls[1].query.containsKey('year'), isFalse);
    });

    test('没有年份时不发第二次请求（省一半请求量）', () async {
      final http = _server(
        search: () => const <String, Object?>{'results': <Object?>[]},
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      await scraper.scrape(
        const ScrapeQuery(title: '某片', kind: MediaKind.movie),
      );

      expect(http.searchCalls.length, 1);
    });

    test('中文候选搜不到时，用备用标题再搜一次', () async {
      final http = _FakeHttp((call) async {
        final q = call.query['query'];
        return _ok(<String, Object?>{
          'results': q == 'The Wandering Earth II'
              ? [
                  _movieJson(
                    title: '流浪地球2',
                    originalTitle: 'The Wandering Earth II',
                    genreIds: const [],
                  ),
                ]
              : <Object?>[],
        });
      });
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(
          title: '流浪地球2',
          alternateTitle: 'The Wandering Earth II',
          kind: MediaKind.movie,
        ),
      );

      expect(md, isNotNull);
      expect(md!.matchedQuery, 'The Wandering Earth II');
      expect(
        http.searchCalls.map((c) => c.query['query']).toList(),
        ['流浪地球2', 'The Wandering Earth II'],
      );
    });
  });

  group('TmdbScraper 鉴权', () {
    test('v4 读取令牌（eyJ…）走 Authorization: Bearer，且不带 api_key', () async {
      final http = _server(search: () => <String, Object?>{
            'results': [_movieJson()],
          });
      const token = 'eyJhbGciOiJIUzI1NiJ9.fake.payload';
      final scraper = TmdbScraper(http: http, apiKey: token);

      await scraper.scrape(const ScrapeQuery(title: 'x', kind: MediaKind.movie));

      final call = http.searchCalls.single;
      expect(call.headers['Authorization'], 'Bearer $token');
      expect(
        call.query.containsKey('api_key'),
        isFalse,
        reason: '两种 Key 混用会被 TMDB 当成无效请求，白白浪费一次刮削',
      );
    });

    test('v3 API Key 走 api_key 查询参数，且不带 Authorization', () async {
      final http = _server(search: () => <String, Object?>{
            'results': [_movieJson()],
          });
      const key = '0123456789abcdef0123456789abcdef';
      final scraper = TmdbScraper(http: http, apiKey: key);

      await scraper.scrape(const ScrapeQuery(title: 'x', kind: MediaKind.movie));

      final call = http.searchCalls.single;
      expect(call.query['api_key'], key);
      expect(call.headers.containsKey('Authorization'), isFalse);
    });

    test('没填 Key 时 isEnabled 为假 —— 流水线跳过它，媒体库不为空', () {
      final scraper = TmdbScraper(
        http: _FakeHttp((_) async => _ok(const <String, Object?>{})),
        apiKey: '   ',
      );
      expect(scraper.isEnabled, isFalse);
    });
  });

  group('TmdbScraper 类型表', () {
    test('类型表读顶层 genres —— 套 data.genres 会静默拿到空表', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [_movieJson(genreIds: const [18, 53])],
        },
        genres: () => <String, Object?>{
          'genres': [
            {'id': 18, 'name': '剧情'},
            {'id': 53, 'name': '惊悚'},
          ],
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(title: '搏击俱乐部', kind: MediaKind.movie),
      );

      expect(
        md!.genres,
        ['剧情', '惊悚'],
        reason: 'TMDB 的类型表在顶层 genres（`{genres:[{id,name}]}`），'
            '不是夸克的 data.genres。读错只会让类型标签全空，不会报错。',
      );
    });

    test('类型表拿不到时不影响出结果（类型只是列表页的一个标签）', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [_movieJson(genreIds: const [18])],
        },
        genres: () => const <String, Object?>{'unexpected': 'shape'},
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(title: '搏击俱乐部', kind: MediaKind.movie),
      );

      expect(md, isNotNull);
      expect(md!.genres, isEmpty);
    });

    test('类型表只拉一次（缓存在实例上，不随作品数增长）', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [_movieJson(genreIds: const [18])],
        },
        genres: () => <String, Object?>{
          'genres': [
            {'id': 18, 'name': '剧情'},
          ],
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      for (var i = 0; i < 3; i++) {
        await scraper.scrape(
          const ScrapeQuery(title: '搏击俱乐部', kind: MediaKind.movie),
        );
      }

      // movie + tv 各一次，之后走缓存。
      expect(http.calls.where((c) => c.path.contains('/genre/')).length, 2);
      expect(http.searchCalls.length, 3);
    });
  });

  group('TmdbScraper 熔断', () {
    const q = ScrapeQuery(title: '某片', kind: MediaKind.movie);

    test('连续 3 次网络失败即熔断，之后一次请求都不再发', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult.networkFailure('Connection timed out'),
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      for (var i = 0; i < 3; i++) {
        expect(await scraper.scrape(q), isNull);
      }
      expect(http.calls.length, 3);
      expect(scraper.isUnreachable, isTrue);

      // 第 4 次：已熔断，必须立刻返回。
      expect(await scraper.scrape(q), isNull);
      expect(
        http.calls.length,
        3,
        reason: '境内直连 api.themoviedb.org 会一直挂到超时（12s），'
            '而扫描对每部作品都要试 —— 145 部最坏约 1 小时纯等待，'
            '且结局必然是全部退回本地刮削。熔断就是为了不白等。',
      );
    });

    test('2 次网络失败还不熔断（可能只是抖动）', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult.networkFailure('timeout'),
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      await scraper.scrape(q);
      await scraper.scrape(q);

      expect(scraper.isUnreachable, isFalse);
      expect(http.calls.length, 2);
    });

    test('HTTP 401 不计入熔断 —— 服务是通的，问题在 Key', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult(
          statusCode: 401,
          rawBody: '{"status_message":"Invalid API key"}',
        ),
      );
      final scraper = TmdbScraper(http: http, apiKey: 'bad-key');

      for (var i = 0; i < 5; i++) {
        await scraper.scrape(q);
      }

      expect(
        scraper.isUnreachable,
        isFalse,
        reason: '把 401 当网络失败，会让「Key 填错了」表现成「TMDB 连不上」，'
            '用户会去换地址而不是改 Key —— 排查方向直接跑偏。',
      );
      expect(http.calls.length, 5, reason: '没有熔断，每次都会真的发请求');
    });

    test('中间拿到过 HTTP 响应会清零失败计数', () async {
      // 超时 → 超时 → 401（服务可达，计数归零）→ 超时 → 超时：不该熔断。
      const script = <HttpResult>[
        HttpResult.networkFailure('timeout'),
        HttpResult.networkFailure('timeout'),
        HttpResult(statusCode: 401, rawBody: '{}'),
        HttpResult.networkFailure('timeout'),
        HttpResult.networkFailure('timeout'),
      ];
      var i = 0;
      final http = _FakeHttp((_) async => script[i++]);
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      for (var n = 0; n < script.length; n++) {
        await scraper.scrape(q);
      }

      expect(
        scraper.isUnreachable,
        isFalse,
        reason: '「能拿到响应」本身就是服务可达的证据，失败计数必须归零；'
            '否则偶发抖动会把一次正常扫描提前掐断',
      );
    });

    test('熔断是单向的：判定不可达后网络恢复也不会再试', () async {
      // 这是刻意的取舍 —— 熔断的收益是「不再为每一部作品白等 12s」，
      // 代价是本次扫描放弃在线刮削。想恢复得重新扫描（刮削器会重建）。
      var down = true;
      final http = _FakeHttp(
        (_) async => down
            ? const HttpResult.networkFailure('timeout')
            : _ok(<String, Object?>{'results': [_movieJson()]}),
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      for (var i = 0; i < 3; i++) {
        await scraper.scrape(q);
      }
      expect(scraper.isUnreachable, isTrue);

      down = false;
      expect(await scraper.scrape(q), isNull);
      expect(http.calls.length, 3);
    });
  });

  group('TmdbScraper 匹配闸门（不再无条件取第一条）', () {
    test('第一条不匹配、第二条匹配 → 取第二条，而不是 results.first', () async {
      // TMDB 的 `/search/movie` 是**模糊搜索**：它返回「按相关度排序的猜测」。
      // 这条夹具刻意把不匹配的放在前面，钉住「逐条过闸、取第一条通过的」。
      final http = _server(
        search: () => <String, Object?>{
          'page': 1,
          'results': [
            _movieJson(
              id: 680,
              title: '低俗小说',
              originalTitle: 'Pulp Fiction',
              releaseDate: '1994-09-10',
            ),
            _movieJson(
              id: 999999,
              title: '超级马力欧银河大电影',
              originalTitle: 'The Super Mario Galaxy Movie',
              releaseDate: '2026-04-03',
            ),
          ],
          'total_results': 2,
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(
          title: '超级马力欧银河大电影',
          kind: MediaKind.movie,
          year: 2026,
        ),
      );

      expect(
        md!.title,
        '超级马力欧银河大电影',
        reason: '旧代码 `results.first` 会把《低俗小说》照单全收 —— '
            '查询里带着 year=2026，返回的是 1994 年的片子，差 32 年而毫无察觉。',
      );
      expect(md.onlineId, 'movie/999999');
    });

    test('全部候选都不过闸门 → null（宁可漏刮，也不刮错）', () async {
      final http = _server(
        search: () => <String, Object?>{
          'page': 1,
          'results': [
            _movieJson(
              id: 680,
              title: '低俗小说',
              originalTitle: 'Pulp Fiction',
              releaseDate: '1994-09-10',
            ),
          ],
          'total_results': 1,
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(
          // 目录名被发布组插了 `z` 规避关键词过滤。
          title: '超z级z马z力z欧z银z河z大z电影aa',
          kind: MediaKind.movie,
          year: 2026,
        ),
      );

      expect(
        md,
        isNull,
        reason: '这条查询在 TMDB 上**有**返回（模糊搜索永远有返回），'
            '但一条都不该被采纳。自动刮削在这里正确认输，'
            '决定权交给详情页的「手动」按钮。',
      );
    });

    test('年份差 1 年不算错（发布年 vs 首映年）', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [
            _movieJson(
              id: 1,
              title: '流浪地球2',
              originalTitle: 'The Wandering Earth II',
              releaseDate: '2023-01-22',
            ),
          ],
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final md = await scraper.scrape(
        const ScrapeQuery(title: '流浪地球2', kind: MediaKind.movie, year: 2024),
      );

      expect(md, isNotNull);
      expect(md!.year, 2023);
    });
  });

  group('TmdbScraper 手动通道（search / resolve）', () {
    test('search 不过闸门：不匹配的候选照样给出来', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [
            _movieJson(
              id: 680,
              title: '低俗小说',
              originalTitle: 'Pulp Fiction',
              releaseDate: '1994-09-10',
            ),
            _movieJson(
              id: 999999,
              title: '超级马力欧银河大电影',
              releaseDate: '2026-04-03',
            ),
          ],
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final found = await scraper.search(
        const ScrapeQuery(title: '马力欧', kind: MediaKind.movie),
      );

      expect(found.length, 2, reason: '用户要自己挑，所以一条都不能替他筛掉。');
      expect(found.map((c) => c.title), contains('低俗小说'));
    });

    test('search 的缩略图用 candidateSize（w154），不是海报的 w500', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [_movieJson(posterPath: '/abc.jpg')],
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final found = await scraper.search(
        const ScrapeQuery(title: '搏击俱乐部', kind: MediaKind.movie),
      );

      expect(
        found.single.posterUrl,
        contains('/${TmdbScraper.candidateSize}/'),
        reason: '候选列表可能有十几条，每条都下 w500（~50KB）就是几百 KB '
            '只为看一眼「是不是这部片子」。',
      );
      expect(found.single.posterUrl, isNot(contains('/w500/')));
    });

    test('search 的年份是用户填的才带（填错会把正主直接筛掉）', () async {
      final http = _server(
        search: () => <String, Object?>{'results': <Object?>[]},
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      await scraper.search(
        const ScrapeQuery(title: '某片', kind: MediaKind.movie),
      );
      expect(
        http.searchCalls.single.query.containsKey('year'),
        isFalse,
        reason: 'TMDB 的 year 是**硬过滤**不是加权。用户记错年份时，'
            '带上它会把正主直接筛掉，而用户只会看到「没有候选」。',
      );

      await scraper.search(
        const ScrapeQuery(title: '某片', kind: MediaKind.movie, year: 2026),
      );
      expect(http.searchCalls.last.query['year'], 2026);
    });

    test('剧集走 /search/tv 与 first_air_date_year', () async {
      final http = _server(
        search: () => <String, Object?>{'results': [_tvJson()]},
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      await scraper.search(
        const ScrapeQuery(
          title: '权力的游戏',
          kind: MediaKind.episode,
          year: 2011,
        ),
      );

      final call = http.searchCalls.single;
      expect(call.path, '/3/search/tv');
      expect(call.query['first_air_date_year'], 2011);
      expect(call.query.containsKey('year'), isFalse);
    });

    test('resolve 复用候选里的原始条目 —— 不打详情接口', () async {
      final http = _server(
        search: () => <String, Object?>{
          'results': [
            _movieJson(
              id: 999999,
              title: '超级马力欧银河大电影',
              releaseDate: '2026-04-03',
              posterPath: '/p.jpg',
            ),
          ],
        },
        genres: () => <String, Object?>{
          'genres': [
            {'id': 18, 'name': '剧情'},
          ],
        },
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      final found = await scraper.search(
        const ScrapeQuery(title: '超级马力欧银河大电影', kind: MediaKind.movie),
      );
      final md = await scraper.resolve(found.single);

      expect(md, isNotNull);
      expect(md!.title, '超级马力欧银河大电影');
      expect(md.year, 2026);
      expect(md.onlineId, 'movie/999999');
      expect(md.source, ScrapeSource.online);
      expect(md.genres, ['剧情'], reason: '类型名走的是缓存的类型表。');
      expect(
        md.posterUrl,
        contains('/${TmdbScraper.posterSize}/'),
        reason: '落库的海报必须是 w500 —— 候选列表那张 w154 只是缩略图。',
      );
      expect(
        http.searchCalls.length,
        1,
        reason: 'resolve 不该再搜一次：候选里已经带着完整条目（`raw`）。',
      );
    });

    test('resolve 拿到没有 raw 的候选 → null', () async {
      final http = _server(search: () => const <String, Object?>{});
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      expect(
        await scraper.resolve(
          const ScrapeCandidate(source: 'tmdb', sourceId: '1', title: '某片'),
        ),
        isNull,
      );
    });

    test('熔断后 search 直接返回空，不发请求', () async {
      final http = _FakeHttp(
        (_) async => const HttpResult.networkFailure('timeout'),
      );
      final scraper = TmdbScraper(http: http, apiKey: 'a' * 32);

      for (var i = 0; i < 3; i++) {
        await scraper.scrape(
          const ScrapeQuery(title: '某片', kind: MediaKind.movie),
        );
      }
      final before = http.calls.length;

      expect(
        await scraper.search(
          const ScrapeQuery(title: '某片', kind: MediaKind.movie),
        ),
        isEmpty,
      );
      expect(http.calls.length, before);
    });
  });
}
