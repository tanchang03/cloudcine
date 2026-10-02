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
  bool categoryManual = false,
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
  int seasonCount = 0,
  String? mergedInto,
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
      categoryManual: categoryManual,
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
      seasonCount: seasonCount,
      mergedInto: mergedInto,
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

  group('用户显式重刮（overrideManual）：本次算出的分类必须落库', () {
    // 2026-10-02 用户报的 bug 现场（《黑暗荣耀》）：
    //   ① 自动刮削把它判成「纪录片」；
    //   ② 用户点「自定义」清空刮削数据 → 库里 `category_manual = 1`；
    //   ③ 用户在手动对话框里选了「剧集」重刮。
    //
    // `WorkScraper._categoryFor` 已经算出「剧集」，日志里写着
    // 「分类判定：纪录片 → 剧集（对话框手选 override=剧集）」—— 但库里那一行
    // 仍然是 `documentary`。根因在**合并这一步**：无条件认旧锁，把刚算对的
    // 结论原地扔掉。界面弹的是「已刮削：黑暗荣耀 · 类型：剧集」，用户回头
    // 一看纪录片栏里它还在，而日志里查不出任何异常（因为判定那一步是对的）。
    MediaWork lockedDoc() => _work(
          source: ScrapeSource.online,
          category: MediaCategory.documentary,
          categoryManual: true,
          onlineId: 'tv/136283',
        );

    /// 手动重刮产出的 incoming —— 形状与 `WorkScraper._apply` 一致：
    /// 分类是这次算出来的「剧集」，锁沿用（用户这次也选了类型）。
    MediaWork rescraped() => _work(
          source: ScrapeSource.online,
          category: MediaCategory.series,
          categoryManual: true,
          onlineId: 'tv/136283',
          genres: const ['剧情', '悬疑'],
        );

    test('分类赢过旧锁', () {
      final merged = DriftMediaRepository.mergeWorkForUpsert(
        rescraped(),
        lockedDoc(),
        ts,
        overrideManual: true,
      );

      expect(
        merged.category,
        MediaCategory.series,
        reason: '`overrideManual` 是「用户亲手点了这个按钮」的标记，而 '
            '`_categoryFor` 已经按完整优先级算过一遍（含「手动通道忽略旧锁、'
            '按本次刮削重判」）。这里再认一次旧锁 = 用户重刮多少次都停在旧分类上。',
      );
      expect(merged.categoryManual, isTrue, reason: '这次也选了类型，锁必须还在。');
    });

    test('不传 overrideManual（扫描期自动刮削）→ 锁照样挡住', () {
      final merged = DriftMediaRepository.mergeWorkForUpsert(
        rescraped(),
        lockedDoc(),
        ts,
      );

      expect(
        merged.category,
        MediaCategory.documentary,
        reason: '锁的本意就是挡**无人值守**的自动刮削 —— 否则用户手动指定的分类'
            '会被 TMDB 的 genres 悄悄改写。让路的只有用户显式发起的那一次。',
      );
    });

    test('原本没锁、手动选了类型 → 这一次要把锁置上', () {
      final unlocked = _work(
        source: ScrapeSource.online,
        category: MediaCategory.documentary,
        onlineId: 'tv/136283',
      );

      final merged = DriftMediaRepository.mergeWorkForUpsert(
        rescraped(),
        unlocked,
        ts,
        overrideManual: true,
      );

      expect(merged.category, MediaCategory.series);
      expect(
        merged.categoryManual,
        isTrue,
        reason: '`_apply` 把「用户这次选了类型」写进了 `incoming.categoryManual`。'
            '合并只取旧值会把这个动作丢掉：分类当场是对的，但没锁上 —— '
            '下一次自动刮削就能把它冲回去，用户看到「改好的分类又变回去了」。',
      );
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

  group('用户自定义过的行（manual）不被自动刮削覆盖', () {
    /// 用户在详情页点了「自定义」之后，库里那一行长这样 ——
    /// 由 `MediaWork.customized` 产出（那条纯函数由
    /// `media_work_customized_test.dart` 单独覆盖）。
    MediaWork customized() => _work(
          source: ScrapeSource.manual,
          title: '2024 演唱会现场',
          category: MediaCategory.other,
          categoryManual: true,
          year: null,
          posterUrl: null,
          rating: null,
          genres: const [],
          itemCount: 1,
        );

    test('扫描期自动刮削（incoming=online）碰不到它', () {
      final incoming = _work(
        source: ScrapeSource.online,
        title: '低俗小说',
        year: 1994,
        overview: '两个杀手…',
        posterUrl: 'https://image.tmdb.org/wrong.jpg',
        rating: 8.9,
        genres: const ['犯罪'],
        onlineId: 'movie/680',
        scrapedAt: ts,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, customized(), ts);

      expect(
        merged.title,
        '2024 演唱会现场',
        reason: '这条守卫是「自定义」功能能站住的前提。没有它，开着'
            '「扫描后自动刮削」的用户每次重扫都会被在线源拿同一个错条目'
            '再糊一遍 —— 而他刚刚手工改对，界面上却什么都没有提示。',
      );
      expect(merged.category, MediaCategory.other);
      expect(merged.source, ScrapeSource.manual);
      expect(merged.year, isNull);
      expect(merged.posterUrl, isNull, reason: '刮错的那张海报不许回来。');
      expect(merged.overview, isNull);
      expect(merged.rating, isNull);
      expect(merged.genres, isEmpty);
      expect(merged.onlineId, isNull);
      expect(merged.scrapedAt, isNull);
    });

    test('计数照常更新 —— 它是扫描的产物，不是刮削的', () {
      final incoming = _work(
        source: ScrapeSource.online,
        itemCount: 7,
        totalBytes: 7000,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, customized(), ts);

      expect(merged.itemCount, 7);
      expect(merged.totalBytes, 7000);
      expect(merged.updatedAt, ts);
    });

    test('用户显式点「刮削」→ overrideManual 放行', () {
      final incoming = _work(
        source: ScrapeSource.online,
        title: '低俗小说',
        posterUrl: 'https://image.tmdb.org/a.jpg',
        scrapedAt: ts,
      );

      final merged = DriftMediaRepository.mergeWorkForUpsert(
        incoming,
        customized(),
        ts,
        overrideManual: true,
      );

      expect(
        merged.title,
        '低俗小说',
        reason: '「刮削」按钮是用户唯一能把作品交还给在线源的路。'
            '这里若也拦下，库里一个字段都不会变，而 `WorkScraper` 已经'
            '按流水线的命中结果返回了「已刮削：低俗小说」—— 界面在撒谎。',
      );
      expect(merged.source, ScrapeSource.online);
    });

    test('本地重扫（incoming=local）仍然进得来：年份与海报要能自愈', () {
      // 这一条钉住守卫的**边界**。拦宽一格（把本地重扫也冻住）会造出一个
      // 很难归因的现象：用户自定义完之后，这部作品永远既没有封面也没有
      // 年份 —— 因为「自愈」唯一的发生时机就是本地重扫。
      final incoming = _work(
        source: ScrapeSource.local,
        title: '2024演唱会现场.2160p.WEB-DL',
        year: 2024,
        posterUrl: 'https://drive-pc.quark.cn/file/video/preview?fid=f1',
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, customized(), ts);

      expect(merged.title, '2024 演唱会现场', reason: '片名仍是用户写死的。');
      expect(merged.source, ScrapeSource.manual, reason: '来源标记不回退。');
      expect(merged.category, MediaCategory.other, reason: '分类也不被改写。');
      expect(merged.year, 2024, reason: '年份由文件名解析补回。');
      expect(
        merged.posterUrl,
        contains('quark.cn'),
        reason: '海报回落到网盘缩略图（本地来源），而不是留空。',
      );
    });
  });

  group('季数（seasonCount）', () {
    test('合并时永远取本次扫描的值 —— 与 itemCount 同类', () {
      final incoming = _work(itemCount: 24, seasonCount: 3);
      final existing = _work(itemCount: 12, seasonCount: 1);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(
        merged.seasonCount,
        3,
        reason: '季数是「本次扫描看到的文件集合」的产物。留在旧值上的话，'
            '用户新加一季、重扫完，卡片上还是写着「1 季」—— 而重扫恰恰是'
            '他为了让这个数字变对才做的。',
      );
    });

    test('「自定义」过的行也照样更新季数（它跟刮削无关）', () {
      final existing = _work(
        source: ScrapeSource.manual,
        title: '用户手写的片名',
        itemCount: 12,
        seasonCount: 1,
      );
      // 扫描期自动刮削（online + 非 override）走的是「整行冻结」分支，
      // 但**计数类**字段必须照常更新 —— 否则自定义过的作品永远停在旧数字上。
      final incoming = _work(
        source: ScrapeSource.online,
        itemCount: 36,
        seasonCount: 3,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.title, '用户手写的片名', reason: '元数据仍然冻着。');
      expect(merged.seasonCount, 3, reason: '计数不冻。');
    });

    test('卡片副标题：>= 2 季才显示，0 / 1 季都不显示', () {
      expect(_work(seasonCount: 3, itemCount: 24).subtitleLine, contains('3 季'));
      expect(
        _work(seasonCount: 1, itemCount: 12).subtitleLine,
        isNot(contains('季')),
        reason: '「1 季」写在卡片上是废话，还会把有信息量的「12 集」'
            '挤到 ellipsis 后面。',
      );
      expect(
        _work(seasonCount: 0, itemCount: 1).subtitleLine,
        isNot(contains('季')),
        reason: '0 表示「电影 / 老库还没回填」，同样不该出现。',
      );
    });
  });

  group('折叠标记（mergedInto）', () {
    test('重扫不许把它清掉 —— 它是「已并入」而不是「本次扫描的产物」', () {
      // 本次扫描造出来的行 `mergedInto` 恒为 null（`WorkSeed.build` 不填
      // 这一列）。照抄新值 = 每次重扫都把所有合并悄悄拆开，而用户什么都
      // 没做，只看到「合过的片子又变回两个格子」。
      final existing = _work(
        source: ScrapeSource.local,
        title: 'The Wandering Earth II',
        mergedInto: '流浪地球2#2023',
      );
      final incoming = _work(
        source: ScrapeSource.local,
        title: 'The Wandering Earth II',
        itemCount: 2,
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.mergedInto, '流浪地球2#2023');
    });

    test('重刮削（保护模式关闭）同样不许清掉 —— 它跟刮削无关', () {
      // ⚠️ 这条与上一条**必须分开测**：合并那行如果写成
      // `_preferOld(protect, ...)`，保护模式下是对的、重刮削时会挂。
      final existing = _work(
        source: ScrapeSource.local,
        mergedInto: 'target',
      );
      final incoming = _work(
        source: ScrapeSource.online,
        title: '刮来的片名',
        onlineId: 'movie/1',
      );

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.mergedInto, 'target');
      expect(merged.title, '刮来的片名', reason: '元数据照常被覆盖。');
    });

    test('「自定义」过的行（manual 保护分支）也保留折叠标记', () {
      final existing = _work(
        source: ScrapeSource.manual,
        mergedInto: 'target',
      );
      final incoming = _work(source: ScrapeSource.online);

      final merged =
          DriftMediaRepository.mergeWorkForUpsert(incoming, existing, ts);

      expect(merged.mergedInto, 'target');
    });

    test('库里没有这一行时，新行就是独立的（null）', () {
      final merged = DriftMediaRepository.mergeWorkForUpsert(
        _work(source: ScrapeSource.local),
        null,
        ts,
      );

      expect(merged.mergedInto, isNull);
    });

    test('isMergedAway：空串也算「没折走」', () {
      // 空串理论上不该出现（写库只写 key 或 null），但它一旦出现，
      // 按「非 null 即折走」判会让一整行**从列表里静默消失**。
      expect(_work(mergedInto: 'a').isMergedAway, isTrue);
      expect(_work(mergedInto: null).isMergedAway, isFalse);
      expect(_work(mergedInto: '').isMergedAway, isFalse);
    });
  });
}
