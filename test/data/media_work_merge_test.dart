import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个作品记录，只填关心的字段。
MediaWork _work({
  String key = 'movie#2023',
  ScrapeSource source = ScrapeSource.local,
  MediaKind kind = MediaKind.movie,
  String title = '标题',
  int? year,
  String? overview,
  String? posterUrl,
  String? posterFile,
  String? backdropUrl,
  String? backdropFile,
  double? rating,
  List<String> genres = const [],
  String? onlineId,
  DateTime? scrapedAt,
  int itemCount = 0,
  int totalBytes = 0,
  DateTime? lastPlayedAt,
}) =>
    MediaWork(
      key: key,
      provider: DriveProvider.quark,
      kind: kind,
      title: title,
      year: year,
      overview: overview,
      posterUrl: posterUrl,
      posterFile: posterFile,
      backdropUrl: backdropUrl,
      backdropFile: backdropFile,
      rating: rating,
      genres: genres,
      onlineId: onlineId,
      source: source,
      scrapedAt: scrapedAt,
      itemCount: itemCount,
      totalBytes: totalBytes,
      lastPlayedAt: lastPlayedAt,
      updatedAt: DateTime(2020),
    );

void main() {
  final ts = DateTime(2026, 9, 30, 12);

  /// 库里已有的一条**已刮削**作品（海报、简介、评分都在）。
  MediaWork scrapedExisting() => _work(
        source: ScrapeSource.online,
        title: '流浪地球2',
        year: 2023,
        overview: '太阳危机迫近，人类启动移山计划。',
        posterUrl: 'https://image.tmdb.org/a.jpg',
        posterFile: 'movie#2023_1a2b3c4d.jpg',
        backdropUrl: 'https://image.tmdb.org/b.jpg',
        backdropFile: 'movie#2023_5e6f7a8b.jpg',
        rating: 8.7,
        genres: const ['科幻', '灾难'],
        onlineId: 'movie/843527',
        scrapedAt: DateTime(2026, 1, 1),
        itemCount: 1,
        totalBytes: 100,
        lastPlayedAt: DateTime(2026, 2, 1),
      );

  group('首次插入', () {
    test('库里没有这条时直接用新值，只刷新 updatedAt', () {
      final incoming = _work(title: '新片', source: ScrapeSource.local, itemCount: 2);
      final merged = DriftMediaRepository.mergeWorkForUpsert(incoming, null, ts);

      expect(merged.title, '新片');
      expect(merged.source, ScrapeSource.local);
      expect(merged.itemCount, 2);
      expect(merged.updatedAt, ts);
    });
  });

  group('保护模式：本次是文件名解析、库里是刮削结果', () {
    test('元数据全部保留旧值（海报不会被文件名顶掉）', () {
      final incoming = _work(
        title: '流浪地球2 2023 2160p WEB-DL',
        source: ScrapeSource.local,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, scrapedExisting(), ts);

      expect(merged.title, '流浪地球2');
      expect(merged.year, 2023);
      expect(merged.overview, '太阳危机迫近，人类启动移山计划。');
      expect(merged.posterUrl, 'https://image.tmdb.org/a.jpg');
      expect(merged.posterFile, 'movie#2023_1a2b3c4d.jpg');
      expect(merged.backdropUrl, 'https://image.tmdb.org/b.jpg');
      expect(merged.backdropFile, 'movie#2023_5e6f7a8b.jpg');
      expect(merged.rating, 8.7);
      expect(merged.genres, ['科幻', '灾难']);
      expect(merged.onlineId, 'movie/843527');
      expect(merged.source, ScrapeSource.online);
      expect(merged.scrapedAt, DateTime(2026, 1, 1));
    });

    test('计数永远取新值 —— 它反映本次扫描看到的真实文件集合', () {
      final incoming = _work(
        source: ScrapeSource.local,
        itemCount: 3,
        totalBytes: 900,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, scrapedExisting(), ts);

      expect(merged.itemCount, 3);
      expect(merged.totalBytes, 900);
    });

    test('lastPlayedAt 永远保留旧值（播放记录与扫描无关）', () {
      final incoming = _work(
        source: ScrapeSource.local,
        lastPlayedAt: DateTime(2026, 3, 1),
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, scrapedExisting(), ts);

      expect(merged.lastPlayedAt, DateTime(2026, 2, 1));
    });

    test('旧值缺失时用新值补空（保护不等于把空值也保住）', () {
      final existing = _work(
        source: ScrapeSource.online,
        title: '某片',
        // 在线源没给简介与评分
      );
      final incoming = _work(
        source: ScrapeSource.local,
        overview: '文件名里当然没有简介',
        rating: 7.1,
      );

      final merged = DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.overview, '文件名里当然没有简介');
      expect(merged.rating, 7.1);
      // 标题是旧值（旧值存在）
      expect(merged.title, '某片');
    });

    test('手工修改过的作品同样受保护', () {
      final existing = _work(
        source: ScrapeSource.manual,
        title: '我改过的名字',
      );
      final incoming = _work(source: ScrapeSource.local, title: '文件名里的名字');

      final merged = DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.title, '我改过的名字');
      expect(merged.source, ScrapeSource.manual);
    });
  });

  group('重新刮削：本次就是刮削结果', () {
    test('元数据被覆盖 —— 这正是重新刮削的意义', () {
      final incoming = _work(
        source: ScrapeSource.online,
        title: '流浪地球2（重刮）',
        year: 2023,
        overview: '新的简介',
        posterUrl: 'https://image.tmdb.org/new.jpg',
        rating: 9.1,
        genres: const ['科幻'],
        onlineId: 'movie/843527',
        scrapedAt: DateTime(2026, 9, 30),
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, scrapedExisting(), ts);

      expect(merged.title, '流浪地球2（重刮）');
      expect(merged.overview, '新的简介');
      expect(merged.posterUrl, 'https://image.tmdb.org/new.jpg');
      expect(merged.rating, 9.1);
      expect(merged.genres, ['科幻']);
      expect(merged.scrapedAt, DateTime(2026, 9, 30));
    });

    test('海报换了地址时必须丢掉旧的本地缓存文件名', () {
      final incoming = _work(
        source: ScrapeSource.online,
        posterUrl: 'https://image.tmdb.org/new.jpg',
        // 新图还没下载，没有本地文件
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, scrapedExisting(), ts);

      expect(merged.posterUrl, 'https://image.tmdb.org/new.jpg');
      // 留着旧文件名的话，详情页会一直显示上一版海报
      expect(merged.posterFile, isNull);
    });

    test('海报地址没变时保留已下载的本地缓存文件名', () {
      final incoming = _work(
        source: ScrapeSource.online,
        posterUrl: 'https://image.tmdb.org/a.jpg',
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, scrapedExisting(), ts);

      expect(merged.posterFile, 'movie#2023_1a2b3c4d.jpg');
    });

    test('清空刮削结果（source 回到 local）不会被保护挡住', () {
      final existing = scrapedExisting();
      final incoming = _work(source: ScrapeSource.local, title: '文件名标题');

      final merged = DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      // existing.source 是 online、incoming 是 local → 保护模式生效
      expect(merged.source, ScrapeSource.online);

      // 反过来：库里是 local、本次是 online → 覆盖
      final back = DriftMediaRepository.mergeWorkForUpsert(
        _work(source: ScrapeSource.online, title: '刮削标题'),
        _work(source: ScrapeSource.local, title: '文件名标题'),
        ts,
      );
      expect(back.title, '刮削标题');
      expect(back.source, ScrapeSource.online);
    });
  });

  group('MediaWork 展示逻辑', () {
    test('副标题把类型/年份/数量/评分拼起来', () {
      final w = _work(
        kind: MediaKind.episode,
        title: '某剧',
        year: 2023,
        itemCount: 12,
        rating: 8.66,
      );

      expect(w.subtitleLine, '剧集 · 2023 · 12 集 · 8.7');
    });

    test('电影显示「个文件」而不是「集」', () {
      final w = _work(itemCount: 2, year: 2019);
      expect(w.subtitleLine, '电影 · 2019 · 2 个文件');
    });

    test('hasPoster 认本地文件也认远程地址', () {
      expect(_work().hasPoster, isFalse);
      expect(_work(posterFile: 'a.jpg').hasPoster, isTrue);
      expect(_work(posterUrl: 'https://x/a.jpg').hasPoster, isTrue);
    });

    test('isScraped 只认在线与手工，文件名解析不算刮削', () {
      expect(_work(source: ScrapeSource.local).isScraped, isFalse);
      expect(_work(source: ScrapeSource.online).isScraped, isTrue);
      expect(_work(source: ScrapeSource.manual).isScraped, isTrue);
    });
  });
}
