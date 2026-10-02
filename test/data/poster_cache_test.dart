import 'dart:io';
import 'dart:typed_data';

import 'package:cloudcine/data/http/http_client.dart';
import 'package:cloudcine/data/scrape/poster_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只关心「发了几次字节请求、带了什么头」的假客户端。
class _FakeHttp implements HttpClientLike {
  _FakeHttp(this.payload);

  final Uint8List payload;

  int byteCalls = 0;
  Map<String, String>? lastHeaders;

  @override
  Future<Uint8List?> getBytes(
    String url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    byteCalls++;
    lastHeaders = headers;
    return payload;
  }

  @override
  Future<HttpResult> get(
    String url, {
    Map<String, Object?>? query,
    Map<String, String>? headers,
    Duration? timeout,
    bool followRedirects = true,
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

void main() {
  group('PosterCache.fileNameFor', () {
    test('同输入同输出（跨进程稳定）', () {
      final a = PosterCache.fileNameFor(key: 'movie#2023', url: 'https://x/a.jpg');
      final b = PosterCache.fileNameFor(key: 'movie#2023', url: 'https://x/a.jpg');
      expect(a, b);
    });

    test('换 URL 换文件名（旧缓存不会被复用）', () {
      final a = PosterCache.fileNameFor(key: 'movie#2023', url: 'https://x/a.jpg');
      final b = PosterCache.fileNameFor(key: 'movie#2023', url: 'https://x/b.jpg');
      expect(a, isNot(b));
    });

    test('换作品键换文件名', () {
      final a = PosterCache.fileNameFor(key: 'a', url: 'https://x/p.jpg');
      final b = PosterCache.fileNameFor(key: 'b', url: 'https://x/p.jpg');
      expect(a, isNot(b));
    });

    test('路径分隔符被替换掉（不会写出子目录）', () {
      final name = PosterCache.fileNameFor(
        key: '/电影/流浪地球2 (2023)/',
        url: 'https://x/p.jpg',
      );
      expect(name.contains('/'), isFalse);
      expect(name.contains('\\'), isFalse);
      expect(name.contains(' '), isFalse);
      expect(name.endsWith('.jpg'), isTrue);
    });

    test('中文保留（便于人工排查缓存）', () {
      final name = PosterCache.fileNameFor(key: '流浪地球2#2023', url: 'u');
      expect(name.contains('流浪地球2'), isTrue);
    });

    test('超长键被截断但仍带上散列，避免重名', () {
      final long = 'a' * 200;
      final name = PosterCache.fileNameFor(key: long, url: 'https://x/p.jpg');
      expect(name.length, lessThan(90));
      // 截断后仍要能区分不同的超长键
      final other = PosterCache.fileNameFor(key: 'a' * 199, url: 'https://x/p.jpg');
      expect(name, isNot(other));
    });
  });

  group('PosterCache.relativeNameOf', () {
    test('把绝对路径还原成相对文件名', () {
      expect(
        PosterCache.relativeNameOf('/tmp/cache/abc.jpg', '/tmp/cache'),
        'abc.jpg',
      );
    });

    test('不在缓存目录下的路径返回 null', () {
      expect(PosterCache.relativeNameOf('/elsewhere/abc.jpg', '/tmp/cache'), isNull);
    });

    test('null 进 null 出', () {
      expect(PosterCache.relativeNameOf(null, '/tmp/cache'), isNull);
    });
  });

  group('PosterCache 磁盘命中', () {
    late Directory dir;
    late _FakeHttp http;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('poster_cache_test');
      http = _FakeHttp(Uint8List.fromList(List.filled(64, 7)));
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('第二次取同一张图不再发请求（缓存真的生效）', () async {
      final cache = PosterCache(http: http, dirPath: dir.path);
      const url = 'https://drive-pc.quark.cn/1/clouddrive/file/video/preview?fid=x';
      const key = '某剧';

      final first = await cache.pathFor(key: key, url: url);
      expect(first, isNotNull);
      expect(http.byteCalls, 1);

      // 关键：**不给 knownFile**。库里那一列从来没人写过，
      // 所以「盘上有没有文件」必须是缓存命中的唯一判据 ——
      // 少了这道判断，一千部作品会在每次启动时重下一千张图。
      final second = await cache.pathFor(key: key, url: url);
      expect(second, first);
      expect(http.byteCalls, 1, reason: '第二次不该再发请求');
    });

    test('换 URL 会重新下载（旧缓存不会被复用）', () async {
      final cache = PosterCache(http: http, dirPath: dir.path);
      await cache.pathFor(key: 'k', url: 'https://x/a.jpg');
      await cache.pathFor(key: 'k', url: 'https://x/b.jpg');
      expect(http.byteCalls, 2);
    });

    test('请求头由回调按地址现取 —— 网盘缩略图必须带 Cookie', () async {
      final cache = PosterCache(
        http: http,
        dirPath: dir.path,
        headersFor: (url) =>
            url.contains('quark.cn') ? const {'Cookie': '__puus=fresh'} : const {},
      );

      await cache.pathFor(key: 'k', url: 'https://drive-pc.quark.cn/x.webp');
      expect(http.lastHeaders, {'Cookie': '__puus=fresh'});

      await cache.pathFor(key: 'k', url: 'https://image.tmdb.org/a.jpg');
      expect(http.lastHeaders, isEmpty);
    });
  });
}
