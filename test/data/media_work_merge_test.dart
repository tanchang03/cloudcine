import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/core/utils/media_category.dart';
import 'package:cloudcine/data/db/media_repository_impl.dart';
import 'package:cloudcine/domain/entities/drive_provider.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个作品记录，只填关心的字段。
///
/// [category] 默认按 [kind] 推 —— 与 `MediaCategoryGuesser` 在没有任何关键词
/// 命中时的结论一致。不这样默认的话，每个用例都得手写一个分类，
/// 而绝大多数用例根本不关心分类。
MediaWork _work({
  String key = 'movie#2023',
  ScrapeSource source = ScrapeSource.local,
  MediaKind kind = MediaKind.movie,
  MediaCategory? category,
  String title = '标题',
  int? year,
  String? overview,
  String? posterUrl,
  String? posterFile,
  double? posterFaceX,
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
      category: category ??
          switch (kind) {
            MediaKind.movie => MediaCategory.movie,
            MediaKind.episode => MediaCategory.series,
            MediaKind.unknown => MediaCategory.other,
          },
      title: title,
      year: year,
      overview: overview,
      posterUrl: posterUrl,
      posterFile: posterFile,
      posterFaceX: posterFaceX,
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

    test('分类永远取新值 —— 不受「保护刮削结果」影响', () {
      // 为什么不能放进保护分支：第一次扫描时判成「其他」的作品，之后
      // 无论重扫多少次都修不回来（保护模式会一直保留那个旧的「其他」），
      // 而用户在分类栏里会永远找不到它。
      final existing = _work(
        source: ScrapeSource.online,
        category: MediaCategory.other,
      );
      final incoming = _work(
        source: ScrapeSource.local,
        category: MediaCategory.anime,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      // 元数据被保护了（source 仍是 online），但分类跟着新扫描走。
      expect(merged.source, ScrapeSource.online);
      expect(merged.category, MediaCategory.anime);
    });

    test('本次算不出海报地址时保留旧的 —— 海报不会从墙上消失', () {
      // 网盘缩略图地址是「扫描那一刻服务端有没有生成预览图」的快照
      // （实测视频里约七成有）。某次扫描恰好没拿到就写 null 的话，
      // 用户看到的是「昨天还有海报，今天变灰块了」。
      final existing = _work(
        posterUrl: 'https://drive-pc.quark.cn/1/clouddrive/file/video/preview?fid=a',
        posterFile: 'movie#2023_1a2b3c4d.jpg',
      );
      final incoming = _work(); // posterUrl 为空

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.posterUrl, existing.posterUrl);
      // 地址没变 → 本地缓存文件名也该跟着保留，两个字段不能互相矛盾。
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

  group('分类与 genres：重扫不许把刮削修正过的分类冲回去', () {
    // 2026-10-01 发现。时间线：
    //   ① 扫描 → `guess(kind=movie)` → 「电影」
    //   ② 刮削 → TMDB 类型 `['动画']` → 分类修正成「动漫」
    //   ③ 用户往网盘里加了一集，**重扫**
    //
    // 重扫时 `_buildWork` 的分类仍然是 `guess(kind=movie)` —— 它**拿不到
    // genres**（那时还没刮削）。而分类这条规则是「永远取新值」，
    // 于是第 ③ 步会把分类退回「电影」，而库里的 `genres` 明明还是 `['动画']`。
    //
    // 用户看到的是「分类时好时坏」：刮完在动漫栏，扫一次又回电影栏。
    // （下次启动的回填确实会再修正一次 —— 但那要等重启，中间这段时间
    // 分类栏的角标和列表都是错的。）

    test('重扫一部已刮削的动画 → 分类仍是「动漫」', () {
      final existing = _work(
        source: ScrapeSource.online,
        kind: MediaKind.movie,
        category: MediaCategory.anime,
        genres: const ['动画', '冒险'],
        onlineId: 'movie/1',
      );
      // 重扫的 incoming：只有 kind 可用，分类是按结构算的旧口径。
      final incoming = _work(
        source: ScrapeSource.local,
        kind: MediaKind.movie,
        category: MediaCategory.movie,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(
        merged.category,
        MediaCategory.anime,
        reason: '`genres` 是比扫描期证据更强的证据（`MediaCategoryGuesser` '
            '自己也是把它排在第一优先级的）。重扫不许把它冲掉。',
      );
      expect(merged.genres, ['动画', '冒险']);
    });

    test('重扫时 genres 给不出结论 → 分类跟着本次扫描走', () {
      // 库里刮到的是 `['剧情']`（不改变栏目），而用户把片子挪进了 `/动漫/`
      // 目录 —— 这时扫描期的新判定才是对的，「永远取新值」不能被削弱。
      final existing = _work(
        source: ScrapeSource.online,
        category: MediaCategory.movie,
        genres: const ['剧情'],
      );
      final incoming = _work(
        source: ScrapeSource.local,
        category: MediaCategory.anime,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.category, MediaCategory.anime);
    });

    test('本次就是刮削结果 → 按本次的 genres 折算', () {
      final existing = _work(
        source: ScrapeSource.local,
        category: MediaCategory.movie,
        genres: const [],
      );
      final incoming = _work(
        source: ScrapeSource.online,
        category: MediaCategory.movie,
        genres: const ['纪录'],
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.category, MediaCategory.documentary);
    });

    test('分类与 genres 永远基于同一份输入（不会出现自相矛盾的行）', () {
      // 保护模式下 `genres` 保留旧值；那么分类也必须按**旧值**折算 ——
      // 否则会写出「genres 是 ['动画']、分类却按 ['剧情'] 算成电影」这种行，
      // 而它不会报错，只会在下一次刮削时算出一个莫名其妙的分类。
      final existing = _work(
        source: ScrapeSource.online,
        category: MediaCategory.anime,
        genres: const ['动画'],
      );
      // 扫描期拿不到 genres，但万一将来某条路径带上了别的类型……
      final incoming = _work(
        source: ScrapeSource.local,
        category: MediaCategory.movie,
        genres: const ['剧情'],
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      // genres 保留了旧值 ['动画']，分类就必须是动漫。
      expect(merged.genres, ['动画']);
      expect(merged.category, MediaCategory.anime);
    });
  });

  group('封面人物锚点：必须和海报地址同进同退', () {
    // 锚点（`posterFaceX`）说的是「这张图里人物在哪个水平位置」，
    // 它和 `posterUrl` 描述的是**同一张图**。配错了一不会报错、二不会崩，
    // 只会让封面裁到一个莫名其妙的角落 —— 所以这几条都得钉住。
    const quarkA = 'https://drive-pc.quark.cn/1/clouddrive/file/video/preview?fid=a';
    const tmdbPoster = 'https://image.tmdb.org/t/p/w500/p.jpg';

    test('地址换了 → 锚点跟着换；新图没有锚点时就是 null', () {
      // 从「夸克视频帧（有人脸）」换成「TMDB 真海报」。
      // 海报是 2:3 竖版、按 `contain` 画，根本不需要锚点；
      // 此时留着旧锚点会让海报被「剧中某帧的人脸位置」裁一刀。
      final existing = _work(posterUrl: quarkA, posterFaceX: 0.30);
      final incoming = _work(posterUrl: tmdbPoster);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.posterUrl, tmdbPoster);
      expect(
        merged.posterFaceX,
        isNull,
        reason: '这里的 null 是**结论**（新图没有人物锚点），不是缺失，'
            '所以不能像 posterUrl 那样「旧值兜底」。',
      );
    });

    test('地址没变 → 锚点保留旧值（本次没解析出人脸框也不该丢）', () {
      // 夸克的人脸框覆盖率实测 93%，也就是说同一张图某次扫描没带出人脸框
      // 是正常的。那种时候把锚点写成 null，封面就会从「突出人物」
      // 退回「画面正中」—— 而图根本没换。
      final existing = _work(posterUrl: quarkA, posterFaceX: 0.30);
      final incoming = _work(posterUrl: quarkA);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.posterFaceX, 0.30);
    });

    test('老库（v5 之前）锚点是空，地址没变时用本次的补上', () {
      // `posterFaceX` 是 v5 才加的列，升级后旧行全是 NULL。
      // 用户不重扫的话地址不会变，所以必须有这条 `?? incoming` 的补空路径。
      final existing = _work(posterUrl: quarkA);
      final incoming = _work(posterUrl: quarkA, posterFaceX: 0.72);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.posterFaceX, 0.72);
    });

    test('本次没算出海报地址（保护模式）→ 地址与锚点一起保留旧值', () {
      final existing = _work(posterUrl: quarkA, posterFaceX: 0.30);
      final incoming = _work(source: ScrapeSource.local, title: '文件名标题');

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.posterUrl, quarkA);
      expect(
        merged.posterFaceX,
        0.30,
        reason: '地址保留旧值 = 还是那张图，锚点就必须跟着保留。'
            '只保留地址、锚点却写 null，封面会从「突出人物」悄悄退回正中。',
      );
    });

    test('地址从无到有 → 锚点取本次的值', () {
      // 老库没有封面，本次扫描拿到了夸克缩略图与人脸框。
      final existing = _work();
      final incoming = _work(posterUrl: quarkA, posterFaceX: 0.18);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.posterUrl, quarkA);
      expect(merged.posterFaceX, 0.18);
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

    test('副标题第一段用**分类**而不是结构类型', () {
      // 动漫、综艺、纪录片的文件结构都是「剧集」（有季集号），
      // 用 kind 的话海报墙上看不出它们的区别 —— 而那正是分类栏想表达的。
      final anime = _work(
        kind: MediaKind.episode,
        category: MediaCategory.anime,
        itemCount: 24,
      );
      expect(anime.subtitleLine, '动漫 · 24 集');

      final variety = _work(
        kind: MediaKind.episode,
        category: MediaCategory.variety,
        itemCount: 12,
      );
      expect(variety.subtitleLine, '综艺 · 12 集');
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
