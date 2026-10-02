import 'dart:typed_data';

import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/remote/subtitle/opensubtitles_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// OpenSubtitles 客户端。
///
/// ## 为什么这些用例值得写
///
/// 这个接口的错误码**完全反直觉**，而反直觉的那一处如果写错，症状是
/// 「用户去排查错误的地方」：把「Api-Key 填错了」报成「连不上 / 服务不可用」，
/// 用户就会去换反代地址，而真正要做的只是改一行 key。
///
/// 这类错误**不抛、不崩、日志干净**，只能靠断言钉住。
/// `failureOf` 的全部数据来自 2026-10-01 的 `curl` 实测（见客户端类文档）。
void main() {
  /// 一条真实的 `/subtitles` 响应形状（来自官方文档，地址与名字改过）。
  Map<String, Object?> searchBody() => {
        'total_pages': 1,
        'total_count': 2,
        'per_page': 20,
        'page': 1,
        'data': [
          {
            'id': '1234567',
            'attributes': {
              'language': 'zh-cn',
              'download_count': 500000,
              'ratings': 8.0,
              'release': 'Inception.2010.1080p.BluRay',
              'movie_name': 'Inception',
              'hearing_impaired': false,
              'foreign_parts_only': false,
              'feature_details': {
                'title': 'Inception',
                'imdb_id': 'tt1375666',
                'year': 2010,
              },
              'files': [
                {
                  'file_id': 998877,
                  'file_name': 'Inception.2010.1080p.BluRay.x264.srt',
                },
              ],
            },
          },
          {
            'id': '1234568',
            'attributes': {
              'language': 'en',
              'download_count': 12,
              'files': [
                {'file_id': 998878, 'file_name': 'inception.en.srt'},
              ],
            },
          },
        ],
      };

  group('parseSearch', () {
    test('`file_id` 在 attributes.files[] 里，要挖到那一层', () {
      final hits = OpenSubtitlesClient.parseSearch(searchBody());

      expect(hits, hasLength(2));
      expect(hits.first.fileId, 998877,
          reason: '下载只能靠 file_id。它在 attributes.files[0] 里，'
              '拿错一层就永远换不到下载地址');
      expect(hits.first.fileName, 'Inception.2010.1080p.BluRay.x264.srt');
      expect(hits.first.language, 'zh-cn');
      expect(hits.first.title, 'Inception');
      expect(hits.first.downloadCount, 500000);
    });

    test('没有 files 的条目丢掉 —— 没 file_id 就下不了', () {
      final hits = OpenSubtitlesClient.parseSearch({
        'data': [
          {
            'attributes': {'language': 'en'},
          },
        ],
      });

      expect(
        hits,
        isEmpty,
        reason: '留着它会给出一条「点下去必然失败」的选项',
      );
    });

    test('空 data 是「确实没有」，不是「响应坏了」', () {
      expect(OpenSubtitlesClient.parseSearch({'data': <Object?>[]}), isEmpty);
      expect(OpenSubtitlesClient.parseSearch(<String, Object?>{}), isEmpty);
    });
  });

  group('parseDownload', () {
    test('有 link 才算成功', () {
      final d = OpenSubtitlesClient.parseDownload({
        'link': 'https://dl.opensubtitles.org/en/download/sub/1',
        'file_name': 'a.srt',
        'remaining': 95,
        'reset_time': '2026-10-02T00:00:00Z',
      });

      expect(d, isNotNull);
      expect(d!.remaining, 95);
      expect(d.fileName, 'a.srt');
    });

    test('没有 link 返回 null —— 那不是「成功但为空」', () {
      expect(
        OpenSubtitlesClient.parseDownload({'remaining': 0}),
        isNull,
        reason: '没有 link 就下不了。当成成功会变成「下载了一个空字幕」',
      );
    });
  });

  group('failureOf · 状态码与响应体的对应（实测）', () {
    HttpResult res(
      int status, {
      Map<String, Object?>? json,
    }) =>
        HttpResult(statusCode: status, json: json, rawBody: 'body');

    test('403 + "User agent required" → 缺 UA', () {
      expect(
        OpenSubtitlesClient.failureOf(
          res(403, json: {'error': 'User agent required'}),
        ),
        OpenSubtitlesFailure.missingUserAgent,
      );
    });

    test('403 + "You cannot consume this service" → Key 不被接受', () {
      // ⚠️ 这是最要紧的一条：同一个 403，只能靠响应体区分。
      // 按状态码判断的话，「Key 填错」会被当成别的东西报出去。
      expect(
        OpenSubtitlesClient.failureOf(
          res(403, json: {'message': 'You cannot consume this service'}),
        ),
        OpenSubtitlesFailure.badApiKey,
        reason: '实测：带 UA + 无效 Api-Key 就是 403 + 这句话。'
            '不是 401 —— 按 401 去判会永远判不出来',
      );
    });

    test('429 → 额度用完（要显示 remaining 的那种）', () {
      expect(
        OpenSubtitlesClient.failureOf(res(429)),
        OpenSubtitlesFailure.quotaExceeded,
      );
    });

    test('网络层失败 → network', () {
      expect(
        OpenSubtitlesClient.failureOf(HttpResult.networkFailure('no route')),
        OpenSubtitlesFailure.network,
      );
    });

    test('503 → 服务端出错', () {
      expect(
        OpenSubtitlesClient.failureOf(res(503)),
        OpenSubtitlesFailure.server,
        reason: '实测：POST /download 带无效 key 会回 503 —— 它同时也是 5xx，'
            '所以「服务挂了」和「key 不对」在这里分不开，只能先按 5xx 报',
      );
    });

    test('301 归到「响应不对」，而不是猜成服务端问题', () {
      expect(
        OpenSubtitlesClient.failureOf(res(301)),
        OpenSubtitlesFailure.badResponse,
        reason: '实测：完全不带 Api-Key 时接口回 301。猜成网络/服务端问题会'
            '把用户指向错误的排查方向',
      );
    });

    test('2xx 不算失败', () {
      expect(OpenSubtitlesClient.failureOf(res(200)), isNull);
    });
  });

  group('端到端', () {
    test('没填 Api-Key 时不发请求 —— 发也只会拿到一个会被误读的 403', () async {
      final http = _FakeHttp();
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(apiKey: '   '),
      );

      await expectLater(
        client.search(query: 'inception'),
        throwsA(
          isA<OpenSubtitlesException>().having(
            (e) => e.failure,
            'failure',
            OpenSubtitlesFailure.notConfigured,
          ),
        ),
      );
      expect(
        http.calls,
        isEmpty,
        reason: '没配 key 就别发请求：那条请求必然失败，而失败原因会被读成'
            '「服务拒绝」而不是「你还没配 key」',
      );
    });

    test('Key 不对时抛出的是 badApiKey，而不是笼统的「失败」', () async {
      final http = _FakeHttp()
        ..next = HttpResult(
          statusCode: 403,
          json: {'message': 'You cannot consume this service'},
        );
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(apiKey: 'wrong-key'),
      );

      await expectLater(
        client.search(query: 'inception'),
        throwsA(
          isA<OpenSubtitlesException>().having(
            (e) => e.failure,
            'failure',
            OpenSubtitlesFailure.badApiKey,
          ),
        ),
      );
    });

    test('搜到结果时返回候选列表（而不是抛「没有」）', () async {
      final http = _FakeHttp()..next = HttpResult(statusCode: 200, json: searchBody());
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(apiKey: 'good-key'),
      );

      final hits = await client.search(query: 'inception');

      expect(hits.map((h) => h.fileId).toList(), [998877, 998878]);
      // 请求必须带上那两个头，缺 UA 是 403。
      expect(http.lastHeaders?['Api-Key'], 'good-key');
      expect(http.lastHeaders?['User-Agent'], isNotEmpty);
    });

    test('空结果返回空列表 —— 与「请求失败」是两回事', () async {
      final http = _FakeHttp()
        ..next = HttpResult(statusCode: 200, json: {'data': <Object?>[]});
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(apiKey: 'good-key'),
      );

      expect(await client.search(query: '生僻片名'), isEmpty);
    });
  });

  group('probe · 设置页的「测试连接」', () {
    test('打的是 /subtitles，**不是** /infos/languages', () async {
      // ⚠️ 这条是整套用例里最容易写错的一处：实测 `/infos/languages`
      // **不校验 Api-Key**，不带 key 也返回 200。拿它当探针会得到
      // 「一切正常」，而真正的搜索照样 403 —— 探针本身在说谎。
      final http = _FakeHttp()
        ..next = HttpResult(statusCode: 200, json: {'data': <Object?>[]});
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(apiKey: 'good-key'),
      );

      await client.probe();

      expect(http.calls, hasLength(1));
      expect(http.calls.single, contains('/subtitles'));
      expect(http.calls.single, isNot(contains('/infos/')));
      expect(http.lastHeaders?['Api-Key'], 'good-key');
    });

    test('Key 不对时探针要如实报出来 —— 这正是它存在的理由', () async {
      final http = _FakeHttp()
        ..next = HttpResult(
          statusCode: 403,
          json: {'message': 'You cannot consume this service'},
        );
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(apiKey: 'wrong-key'),
      );

      await expectLater(
        client.probe(),
        throwsA(
          isA<OpenSubtitlesException>().having(
            (e) => e.failure,
            'failure',
            OpenSubtitlesFailure.badApiKey,
          ),
        ),
      );
    });

    test('没配 key 时探针不发请求', () async {
      final http = _FakeHttp();
      final client = OpenSubtitlesClient(
        http: http,
        config: const OpenSubtitlesConfig(),
      );

      await expectLater(
        client.probe(),
        throwsA(isA<OpenSubtitlesException>()),
      );
      expect(http.calls, isEmpty);
    });
  });
}

/// 极简假客户端：只回一个预置结果，并记下最后一次请求的头。
class _FakeHttp implements HttpClientLike {
  HttpResult next = HttpResult(statusCode: 200, json: <String, Object?>{});
  final List<String> calls = [];
  Map<String, String>? lastHeaders;

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
  }) async {
    calls.add(url);
    lastHeaders = headers;
    return next;
  }

  @override
  Future<HttpResult> post(
    String url, {
    Object? body,
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    calls.add(url);
    lastHeaders = headers;
    return next;
  }

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async =>
      null;

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
