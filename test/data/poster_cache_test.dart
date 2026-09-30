import 'package:cloudcine/data/scrape/poster_cache.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
