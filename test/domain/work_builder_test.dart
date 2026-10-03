import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/domain/entities/drive_entry.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_item.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:cloudcine/domain/services/work_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// 归组与作品行构造 —— **全盘扫描与局部发现共用的那一份**。
///
/// 这些用例原先只能通过 `ScanService` 间接覆盖（见
/// `scan_service_incremental_test.dart` 的「封面人物锚点」组，那组仍然保留，
/// 它同时证明了这次抽取没有改变行为）。这里补的是**只有抽取之后才暴露出来**
/// 的东西：种子簿自己的状态机（dirty / clean）、以及「刮削海报与网盘缩略图
/// 之间必须换锚点」这条规则的直接断言。
void main() {
  final now = DateTime(2026, 1, 1);

  MediaItem item(
    String name, {
    String? thumb,
    double? faceX,
    int size = 1000,
    String dirPath = '/电影/',
  }) =>
      MediaItem.fromEntry(
        entry: DriveEntry(
          id: name,
          name: name,
          isDirectory: false,
          sizeBytes: size,
          thumbnailUrl: thumb,
          faceAnchorX: faceX,
        ),
        provider: DriveProvider.quark,
        dirPath: dirPath,
        parsed: const MediaFilenameParser().parse(name, dirPath: dirPath),
        now: now,
      );

  WorkSeedBook bookWith(List<MediaItem> items, {String dirPath = '/电影/'}) {
    final book = WorkSeedBook();
    for (final i in items) {
      book.add(
        parsed: const MediaFilenameParser().parse(i.name),
        item: i,
        dirPath: dirPath,
      );
    }
    return book;
  }

  group('收种子', () {
    test('片名解析不出来时不归组（但仍会作为媒体项入库）', () {
      final book = WorkSeedBook();
      final parsed = const MediaFilenameParser().parse('a.mkv');

      expect(
        book.add(parsed: parsed, item: item('a.mkv'), dirPath: '/'),
        isFalse,
        reason: '宁可让它以文件名示人，也不要拿半个名字去建一个注定要重刮的作品',
      );
      expect(book.groupCount, 0);
    });

    test('片名可信但缺年份的电影也要归组 —— 否则它在媒体库里永久看不到', () {
      // 现场（2026-10-03）：`/来自：分享/奥德赛/1080P.mkv`。文件名整串只有
      // 一个分辨率标记，片名靠**目录名**兜底成「奥德赛」，于是
      // `kind=movie` + `year=null` → 旧判据 `isConfident=false`
      // → `ScrapeQuery.fromParsed` 为 null → 这里直接 return false
      // → `media_works` 一条都没有 → 媒体库页面（读 `listWorks`）空空如也，
      // 而目录视图里那一条还标着「已入库」且能播。用户完全无从下手。
      const dirPath = '/来自：分享/奥德赛/';
      final parsed = const MediaFilenameParser().parse(
        '1080P.mkv',
        dirPath: dirPath,
      );

      expect(parsed.title, '奥德赛', reason: '片名是从目录名兜底来的');
      expect(parsed.year, isNull);
      expect(
        parsed.isConfident,
        isFalse,
        reason: '`isConfident` 为 false = 走**宽松档**（闸门改判精确同名），'
            '**不是**「不刮削」—— 这两件事在 2026-10-03 之前是同一件，'
            '现在分开了',
      );

      final book = WorkSeedBook();
      expect(
        book.add(
          parsed: parsed,
          item: item('1080P.mkv', dirPath: dirPath),
          dirPath: dirPath,
        ),
        isTrue,
        reason: '不建作品行 = 这条媒体在媒体库里永久看不到（列表读的是作品行）',
      );
      expect(book.groupCount, 1);

      final works = book.buildDirty(provider: DriveProvider.quark, now: now);
      expect(works.single.title, '奥德赛');
      expect(works.single.source, ScrapeSource.local);
      expect(works.single.year, isNull);
      expect(
        book.queries,
        hasLength(1),
        reason: '缺年份也**要**刮削（2026-10-03 起）：查询词照发，但走宽松档 —— '
            '闸门要求精确同名、且它得排在候选第一位，命中不了就退回手动。'
            '旧行为「缺年份就不刮」把这类片子彻底挡在在线源之外',
      );
      expect(
        book.queries.values.single.requireExactTitle,
        isTrue,
        reason: '没有年份可消歧，闸门必须换成「精确同名」；'
            '沿用 0.6 档会把「奥德赛」配到「奥德赛：归来」',
      );
    });

    test('同一组的多条累加到同一个种子上', () {
      final book = bookWith([
        item('Show.S01E01.1080p.mkv', size: 100),
        item('Show.S01E02.1080p.mkv', size: 200),
      ]);

      expect(book.groupCount, 1);
      final seed = book.seedOf(book.queries.keys.single)!;
      expect(seed.itemCount, 2);
      expect(seed.totalBytes, 300);
    });

    test('分组键与解析结果同源', () {
      final book = bookWith([item('Show.S01E01.1080p.mkv')]);
      final parsed = const MediaFilenameParser().parse('Show.S01E01.1080p.mkv');
      expect(book.queries.keys.single, parsed.groupKey);
    });

    test('扫描期把 dirPath 交给查询链 —— 与详情页同一条路（2026-10-03）', () {
      // 文件名自称独立发行物（自带裸年份）→ 解析层不归组 → 只能靠刮削层
      // 拿目录名兜一次。`WorkSeedBook.add` 漏传 `dirPath` 不会报错，
      // 只会让扫描期的这条兜底永远不生效。
      final book = bookWith(
        [item('126 纯享-仙踪.2026.1080p.mkv', dirPath: '/来自：分享/仙逆/')],
        dirPath: '/来自：分享/仙逆/',
      );

      final q = book.queries.values.single;
      expect(q.title, '126 纯享-仙踪');
      expect(q.fallbacks.map((f) => f.title), ['仙逆']);
    });

    test('分类看目录路径 —— 网盘上「动漫」几乎总写在目录名里', () {
      final book = bookWith(
        [item('Attack.on.Titan.S01E01.1080p.mkv')],
        dirPath: '/动漫/进击的巨人/',
      );
      final seed = book.seedOf(book.queries.keys.single)!;
      expect(seed.category, MediaCategory.anime);
    });
  });

  group('封面：地址与锚点必须成对', () {
    const thumbA = 'https://drive-pc.quark.cn/a.webp';
    const thumbB = 'https://drive-pc.quark.cn/b.webp';

    test('第一条有图的说了算，锚点跟着它一起来', () {
      final book = bookWith([
        item('Show.S01E01.1080p.mkv', thumb: thumbA, faceX: 0.42),
        item('Show.S01E02.1080p.mkv', thumb: thumbB, faceX: 0.9),
      ]);
      final seed = book.seedOf(book.queries.keys.single)!;

      expect(seed.posterUrl, thumbA);
      expect(seed.posterFaceX, 0.42);
    });

    test('第一条没人脸框 → 锚点是 null，不许借用第二条的', () {
      final book = bookWith([
        item('Show.S01E01.1080p.mkv', thumb: thumbA),
        item('Show.S01E02.1080p.mkv', thumb: thumbB, faceX: 0.72),
      ]);
      final seed = book.seedOf(book.queries.keys.single)!;

      expect(seed.posterUrl, thumbA);
      expect(
        seed.posterFaceX,
        isNull,
        reason: '拿第二集的人脸位置去裁第一集的图，封面会裁到一个莫名其妙的'
            '角落，而且不报任何错',
      );
    });

    test('第一条什么都没有 → 用第二条的地址和锚点（仍然是成对的）', () {
      final book = bookWith([
        item('Show.S01E01.1080p.mkv'),
        item('Show.S01E02.1080p.mkv', thumb: thumbB, faceX: 0.2),
      ]);
      final seed = book.seedOf(book.queries.keys.single)!;

      expect(seed.posterUrl, thumbB);
      expect(seed.posterFaceX, 0.2);
    });
  });

  group('建作品行', () {
    test('没有刮削结果时用本地解析的标题与年份', () {
      final book = bookWith([item('Movie.2024.1080p.mkv')]);
      final work = book.build(
        book.queries.keys.single,
        provider: DriveProvider.quark,
        meta: null,
        now: now,
      )!;

      expect(work.title, 'Movie');
      expect(work.year, 2024);
      expect(work.source, ScrapeSource.local);
      expect(work.scrapedAt, isNull);
    });

    test('用了刮削海报就必须丢掉网盘缩略图的锚点', () {
      final book = bookWith([
        item('Movie.2024.1080p.mkv', thumb: 'https://x/a.webp', faceX: 0.3),
      ]);
      final work = book.build(
        book.queries.keys.single,
        provider: DriveProvider.quark,
        meta: const ScrapedMetadata(
          title: '正经片名',
          posterUrl: 'https://image.tmdb.org/t/p/w500/p.jpg',
          source: ScrapeSource.online,
        ),
        now: now,
      )!;

      expect(work.title, '正经片名');
      expect(work.posterUrl, 'https://image.tmdb.org/t/p/w500/p.jpg');
      expect(
        work.posterFaceX,
        isNull,
        reason: 'TMDB 的海报是 2:3 竖版、铺满格子不裁切，拿视频帧的人脸位置'
            '去裁它只会裁错地方',
      );
      expect(work.scrapedAt, now);
    });

    test('刮削给了空白海报地址时仍然退回网盘缩略图', () {
      final book = bookWith([
        item('Movie.2024.1080p.mkv', thumb: 'https://x/a.webp', faceX: 0.3),
      ]);
      final work = book.build(
        book.queries.keys.single,
        provider: DriveProvider.quark,
        meta: const ScrapedMetadata(
          title: '正经片名',
          posterUrl: '   ',
          source: ScrapeSource.online,
        ),
        now: now,
      )!;

      expect(work.posterUrl, 'https://x/a.webp');
      expect(work.posterFaceX, 0.3);
    });

    test('分组不存在时返回 null（不抛）', () {
      expect(
        WorkSeedBook().build(
          '不存在',
          provider: DriveProvider.quark,
          meta: null,
          now: now,
        ),
        isNull,
      );
    });
  });

  group('dirty 状态机', () {
    test('收进来就是 dirty，buildDirty 只产出还没落库的那些', () {
      final book = bookWith([item('A.2024.1080p.mkv')]);
      expect(book.hasDirty, isTrue);

      final first = book.buildDirty(provider: DriveProvider.quark, now: now);
      expect(first, hasLength(1));
      expect(
        book.hasDirty,
        isTrue,
        reason: 'markClean 之前必须还是 dirty —— 落库失败时调用方要能重试',
      );

      book.markClean();
      expect(book.hasDirty, isFalse);
      expect(book.buildDirty(provider: DriveProvider.quark, now: now), isEmpty);
    });

    test('落库之后再收一条，只产出新那一条', () {
      final book = bookWith([item('A.2024.1080p.mkv')]);
      book.markClean();

      book.add(
        parsed: const MediaFilenameParser().parse('B.2024.1080p.mkv'),
        item: item('B.2024.1080p.mkv'),
        dirPath: '/电影/',
      );

      final works = book.buildDirty(provider: DriveProvider.quark, now: now);
      expect(works, hasLength(1));
      expect(works.single.title, 'B');
      expect(book.groupCount, 2, reason: '老的那一组仍然在簿子里，只是不 dirty');
    });
  });
}
