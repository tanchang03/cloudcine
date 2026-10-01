import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:flutter_test/flutter_test.dart';

/// 媒体库一级分类的本地判定。
///
/// 这一层是**离线**的：没配 TMDB Key、断网、刮削全失败时，它给出的结果
/// 就是用户在分类栏里看到的全部。所以每条规则都对应一个真实网盘命名，
/// 而不是为了凑覆盖率造的字符串。
void main() {
  MediaCategory guess(
    String fileName, {
    String? dirPath,
    String? title,
    MediaKind kind = MediaKind.episode,
    List<String> genres = const [],
  }) =>
      MediaCategoryGuesser.guess(
        kind: kind,
        title: title,
        fileName: fileName,
        dirPath: dirPath,
        genres: genres,
      );

  group('结构判定（没有任何关键词时的兜底）', () {
    test('单片 → 电影', () {
      expect(
        guess('流浪地球2.2023.2160p.mkv', kind: MediaKind.movie),
        MediaCategory.movie,
      );
    });

    test('有季集号 → 剧集', () {
      expect(
        guess('无耻之徒.S03E03.1080p.WEB-DL.mkv'),
        MediaCategory.series,
      );
    });

    test('认不出片名 → 其他', () {
      expect(
        guess('a1b2c3d4e5.mkv', kind: MediaKind.unknown),
        MediaCategory.other,
      );
    });
  });

  group('目录路径优先于片名', () {
    test('/动漫/ 目录下的剧集判成动漫', () {
      // 这是最稳的信号：用户整理网盘时几乎一定把动漫放进 `动漫/`，
      // 而片名 `进击的巨人.S01E01` 本身看不出任何"动漫"信息。
      expect(
        guess('进击的巨人.S01E01.mkv', dirPath: '/动漫/进击的巨人/'),
        MediaCategory.anime,
      );
    });

    test('/纪录片/ 目录下的单片判成纪录片', () {
      expect(
        guess('地球脉动.2006.1080p.mkv',
            dirPath: '/纪录片/地球脉动/', kind: MediaKind.movie),
        MediaCategory.documentary,
      );
    });
  });

  group('综艺', () {
    test('「第 N 期」是综艺最稳的结构信号（电视剧用「集」不用「期」）', () {
      // 综艺通常提不出季集号，kind 会是 unknown —— 如果先按 kind 落到
      // 「其他」，关键词表就永远没机会生效。所以关键词必须先判。
      expect(
        guess('奔跑吧.2026-09-27.第12期.1080p.mkv', kind: MediaKind.unknown),
        MediaCategory.variety,
      );
    });

    test('目录里写着「综艺」也认', () {
      expect(
        guess('某节目.S01E01.mkv', dirPath: '/综艺/某节目/'),
        MediaCategory.variety,
      );
    });
  });

  group('在线刮削结果优先', () {
    test('TMDB 的类型覆盖本地判定', () {
      // 目录里没有「动漫」两个字、片名也没有，但 TMDB 知道它是动画。
      expect(
        guess(
          'Spider-Man.Into.the.Spider-Verse.2018.1080p.mkv',
          dirPath: '/电影/',
          kind: MediaKind.movie,
          genres: const ['动画', '动作', '冒险'],
        ),
        MediaCategory.anime,
      );
    });

    test('类型里没有可用信号时退回本地判定', () {
      expect(
        guess(
          '无耻之徒.S03E03.mkv',
          dirPath: '/剧/无耻之徒/',
          genres: const ['剧情', '喜剧'],
        ),
        MediaCategory.series,
      );
    });

    test('「真人秀」类型 → 综艺', () {
      expect(
        guess('某节目.S01E01.mkv', genres: const ['真人秀']),
        MediaCategory.variety,
      );
    });

    test('英文类型名也认（TMDB 语言切换时）', () {
      expect(
        guess('Some.Show.S01E01.mkv', genres: const ['Documentary']),
        MediaCategory.documentary,
      );
    });
  });

  group('已入库作品的兜底判定', () {
    test('只有标题和 kind 时仍能给出合理结果', () {
      expect(
        MediaCategoryGuesser.guessFromWork(
          kind: MediaKind.episode,
          title: '无耻之徒',
        ),
        MediaCategory.series,
      );
    });

    test('标题里带「动漫」照样能识别（老库没有路径可用）', () {
      expect(
        MediaCategoryGuesser.guessFromWork(
          kind: MediaKind.episode,
          title: '动漫 进击的巨人',
        ),
        MediaCategory.anime,
      );
    });
  });

  group('ASCII 关键词必须卡词边界（防误判）', () {
    test('`ova` 不该命中 `Nova`', () {
      // 误判的后果是「我的电影跑到动漫栏里不见了」—— 比漏判难发现得多。
      expect(
        guess('Nova.2023.1080p.BluRay.mkv', kind: MediaKind.movie),
        MediaCategory.movie,
      );
    });

    test('`bbc` 不该命中 `abBc` 这类偶然子串', () {
      // `abbc.2023.mkv` 里确实含有 "bbc"，但它前面紧挨着一个字母 ——
      // 卡边界就匹配不上，正是我们要的。
      expect(
        guess('AbBc.2023.1080p.mkv', kind: MediaKind.movie),
        MediaCategory.movie,
      );
      // 对照组：真的带 BBC 的片子要认出来。
      expect(
        guess('BBC.Earth.2006.1080p.mkv', kind: MediaKind.movie),
        MediaCategory.documentary,
      );
    });

    test('真正的 `[OVA]` 标记要认出来', () {
      expect(
        guess('[OVA] Some.Title.S01E01.mkv', kind: MediaKind.episode),
        MediaCategory.anime,
      );
    });

    test('中文词用子串匹配（中文没有词间空格，卡边界反而会漏）', () {
      expect(
        guess('动漫合集.2026.S01E01.mkv', kind: MediaKind.episode),
        MediaCategory.anime,
      );
    });
  });

  group('持久化字符串的往返', () {
    test('每个取值都能还原', () {
      for (final c in MediaCategory.values) {
        expect(MediaCategory.fromName(c.name), c);
      }
    });

    test('空串与陌生值都回落到「其他」，而不是抛异常', () {
      // 分类是展示维度。读到空串（v3 之前的行）或将来新增的取值时，
      // 降级显示远好于让整个媒体库打不开。
      expect(MediaCategory.fromName(''), MediaCategory.other);
      expect(MediaCategory.fromName(null), MediaCategory.other);
      expect(MediaCategory.fromName('podcast'), MediaCategory.other);
    });

    test('「其他」在展示顺序里垫底', () {
      // 它是个兜底桶，放在中间会让分类栏看起来没有主次。
      expect(MediaCategory.displayOrder.last, MediaCategory.other);
      expect(MediaCategory.displayOrder.length, MediaCategory.values.length);
    });
  });
}
