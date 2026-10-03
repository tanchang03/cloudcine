import 'package:cloudcine/core/utils/filename_parser.dart';
import 'package:cloudcine/domain/entities/media_work.dart';
import 'package:flutter_test/flutter_test.dart';

/// `ScrapeQuery.fromParsed` 是**扫描期**与**详情页「刮削」按钮**共用的唯一
/// 查询词构造入口。
///
/// 它存在的理由就是「两处各拼各的」会静默分叉：同一部作品在扫描期刮出来是 A，
/// 点按钮刮出来是 B，而用户只会觉得「这个按钮有时候不准」。
///
/// 下面每条断言都写了「为什么这条规则重要」—— 因为这里全部属于
/// **改错了不报错，只是结果变空或变歪** 的那种规则。
void main() {
  const parser = MediaFilenameParser();

  ScrapeQuery? queryOf(String fileName) =>
      ScrapeQuery.fromParsed(parser.parse(fileName));

  group('中英混排：备用查询词', () {
    test('两种文字都有 → alternateTitle 是拉丁那半', () {
      final q = queryOf('流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.mkv');

      expect(q, isNotNull);
      expect(q!.title, '流浪地球2 The Wandering Earth II');
      expect(q.alternateTitle, 'The Wandering Earth II');
      expect(q.year, 2023);
      expect(q.kind, MediaKind.movie);
    });

    test('紧贴汉字的数字算中文名的一部分，不许漏进备用词', () {
      final q = queryOf('流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.mkv');

      expect(q!.alternateTitle, 'The Wandering Earth II',
          reason: '`流浪地球2` 的 2 属于中文片名。漏进 latin 会让备用查询词变成 '
              '`2 The Wandering Earth II` 这种**永远搜不到任何东西**的串，'
              '而它只会在主查询词失败后才被用到 —— 也就是最难被发现的时候');
    });

    test('纯中文 → alternateTitle 为 null', () {
      final q = queryOf('繁花.2023.2160p.WEB-DL.mkv');

      expect(q!.title, '繁花');
      expect(q.alternateTitle, isNull,
          reason: '只有一个书写系统时它已经就是 title 了，再搜一遍是白花一次配额 —— '
              '豆瓣匿名额度实测只有约 10 个搜索词');
    });

    test('纯拉丁 → alternateTitle 为 null', () {
      final q = queryOf('Oppenheimer.2023.2160p.WEB-DL.mkv');

      expect(q!.title, 'Oppenheimer');
      expect(q.alternateTitle, isNull);
    });
  });

  group('备用词必须是「名字」：数字堆不算（2026-10-02 事故）', () {
    test('开头的纯数字不配当备用词', () {
      // 事故现场：`182.格力空调显示E6如何维修.mp4` →
      // cjk=`格力空调显示`、latin=`182`，旧规则「两边都非空就用 latin」，
      // 于是又拿 `"182"` 搜了一次 TMDB，模糊搜索返回希腊纪录片
      // 《1821: Οι Ήρωες》，前缀档判 0.91 → 刮错。
      //
      // 备用词是为了「中英混排时用另一半再搜一次」（`流浪地球2 The Wandering
      // Earth II`）。一串编号**不是另一半名字**，它只会把查询带到一堆
      // 编号相同的无关条目上。
      //
      // 这里带上年份，是为了让这条用例**只**测「备用词」这一条规则：
      // 不带年份时它会走宽松档（`requireExactTitle`），那是另一条规则，
      // 混在一起失败时分不清是哪一处坏了。
      final q = queryOf('182.格力空调显示E6如何维修.2024.mp4');

      expect(q, isNotNull);
      expect(q!.alternateTitle, isNull,
          reason: 'latin 去掉数字与标点后只剩 1 个字母（E），不是名字');
    });

    test('⚠️ 含真实英文名的拉丁半仍然是备用词 —— 这条规则不许做过头', () {
      final q = queryOf('流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.mkv');

      expect(q!.alternateTitle, 'The Wandering Earth II');
    });

    test('以数字开头的英文片名也仍然放行 —— 3 Idiots 是名字不是编号', () {
      final q = queryOf('三傻大闹宝莱坞.3.Idiots.2009.1080p.mkv');

      expect(q!.alternateTitle, '3 Idiots');
    });
  });

  group('字段透传：季集与类型', () {
    test('剧集带出季号集号，年份可以缺', () {
      final q = queryOf('仙逆.S01E12.1080p.WEB-DL.mkv');

      expect(q, isNotNull);
      expect(q!.title, '仙逆');
      expect(q.kind, MediaKind.episode);
      expect(q.season, 1);
      expect(q.episode, 12);
      expect(q.year, isNull,
          reason: '剧集不靠年份消歧（一集一集按季集号定位），'
              '所以 `isConfident` 对剧集放开了年份要求');
      expect(q.alternateTitle, isNull);
    });
  });

  group('不可信就不查：返回 null', () {
    test('只有集号、提不出片名 → null', () {
      expect(queryOf('S01E01.1080p.WEB-DL.mkv'), isNull,
          reason: '剧集虽然不要求年份，但**仍然要求片名** —— '
              '拿「S01E01」去搜必然搜到别的剧');
    });

    test('完全提不出信息 → null', () {
      expect(queryOf('1080p.WEB-DL.mkv'), isNull);
    });

    test('片名只是一串编号 → null（**连宽松档都不给**）', () {
      expect(queryOf('159.mkv'), isNull,
          reason: '`159` 是编号不是名字。放宽到「无年份也搜」之后这条尤其要紧：'
              '拿编号去搜必然带回一堆编号相同的无关条目'
              '（2026-10-02「182 → 希腊纪录片」事故的同类）');
    });
  });

  group('两档查询：严格档 vs 宽松档（2026-10-03 起）', () {
    test('电影有年份 → 严格档', () {
      final q = queryOf('Oppenheimer.2023.1080p.WEB-DL.mkv');

      expect(q, isNotNull);
      expect(q!.year, 2023);
      expect(q.requireExactTitle, isFalse,
          reason: '有年份就交给常规闸门（年份硬闸门 + 标题相似度分档），'
              '前缀档正是它要救的（`仙逆` → `仙逆 第一季`）');
    });

    test('电影没有年份 → **宽松档**，不再直接放弃', () {
      final q = queryOf('Oppenheimer.1080p.WEB-DL.mkv');

      expect(q, isNotNull,
          reason: '无年份的电影曾经直接返回 null —— 连搜都不搜，'
              '于是 `/来自：分享/奥德赛/1080P.mkv` 永远刮不出来，'
              '用户只能手动敲一遍。现在放行');
      expect(q!.title, 'Oppenheimer');
      expect(q.year, isNull);
      expect(q.requireExactTitle, isTrue,
          reason: '没有年份可消歧，沿用 0.6 档会让**前缀误配**无条件通过'
              '（实测 奥德赛 → 奥德赛：归来 0.86、英雄 → 英雄本色 0.825），'
              '那是静默刮错。所以换判据：只认精确同名');
    });

    test('剧集没有年份 → 仍是严格档', () {
      final q = queryOf('仙逆.S01E12.1080p.WEB-DL.mkv');

      expect(q!.requireExactTitle, isFalse,
          reason: '剧集不靠年份消歧（季集号自能定位），前缀档'
              '（`仙逆` → `仙逆 第一季`）正是它要救的。'
              '给剧集上「精确同名」会把所有分季命名判死');
    });
  });

  group('候选链：文件名 → 目录名 → 上级目录（2026-10-03）', () {
    ScrapeQuery? chainOf(String fileName, String dirPath) => ScrapeQuery
        .fromParsed(parser.parse(fileName, dirPath: dirPath), dirPath: dirPath);

    test('文件名自带年份（自己说得清楚）→ 目录名接在后面当兜底', () {
      // 真实现场的等价形态：`/来自：分享/仙逆/126 纯享-仙踪-[4K][HEVC][2026-02-01].mp4`。
      // 这里刻意把日期换成裸年份，让解析层**不**归组（`_isStandaloneRelease`
      // 为真）—— 这样测的就是「兜底链」这一条规则，而不是解析层那条。
      final q = chainOf('126 纯享-仙踪.2026.1080p.mkv', '/来自：分享/仙逆/');

      expect(q, isNotNull);
      expect(q!.title, '126 纯享-仙踪');
      expect(q.year, 2026);
      expect(q.fallbacks.map((f) => f.title), ['仙逆'],
          reason: '文件名里没有作品名，`仙逆` 只写在目录上 —— '
              '不给兜底的话自动刮削只能拿 `126 纯享-仙踪` 去搜，必然一无所获');
    });

    test('目录候选一律当**剧集**、走**宽松档**、不带年份与备用词', () {
      final q = chainOf('126 纯享-仙踪.2026.1080p.mkv', '/来自：分享/仙逆/')!;
      final dir = q.fallbacks.single;

      expect(dir.kind, MediaKind.episode,
          reason: '目录名是**系列名**（`DirectoryTitle` 的口径），'
              '所以按剧集搜 TMDB 的 `/search/tv`');
      expect(dir.requireExactTitle, isTrue,
          reason: '目录名没有年份也没有季集号，闸门只剩标题相似度；'
              '0.6 档是为「有年份」定的，放行的是 `特洛伊奥德赛` 0.68、'
              '`奥德赛：史诗的诞生` 0.78 这种**别的片子**');
      expect(dir.year, isNull,
          reason: '目录名里的年份多是「合集整理于某年」，当过滤条件会把正主筛掉');
      expect(dir.alternateTitle, isNull,
          reason: '目录名极少中英混排，带上只会把一次失败变成两次请求');
      expect(dir.fallbacks, isEmpty,
          reason: '链只有一层深 —— 兜底自己不再带兜底，`ScraperPipeline` 的循环才不递归');
    });

    test('与主查询同名的目录名不生成兜底 —— 那是白花一次额度', () {
      // `/…/仙逆/仙逆.S01E01.mkv` 这种「目录名就是片名」的布局很常见。
      final q = chainOf('仙逆.S01E01.1080p.mkv', '/来自：分享/仙逆/');

      expect(q!.title, '仙逆');
      expect(q.fallbacks, isEmpty);
      expect(q.attemptCount, 1);
    });

    test('最多两级：文件所在目录 + 上级目录', () {
      final q = chainOf(
        '126 纯享-仙踪.2026.1080p.mkv',
        '/来自：分享/我的动漫/日漫精选/进击的巨人/第三季/',
      );

      expect(q!.fallbacks.map((f) => f.title), ['进击的巨人', '日漫精选'],
          reason: '每多一条就多花一个搜索词，而豆瓣匿名额度只有约 10 个。'
              '两级正好覆盖用户能一眼说清楚的那两件事（`第三季` 是容器，跳过）');
      expect(q.attemptCount, 3);
    });

    test('容器目录名不参与 —— `来自：分享` 拿出去搜只会搜到无关条目', () {
      final q = chainOf('126 纯享-仙踪.2026.1080p.mkv', '/来自：分享/');

      expect(q!.fallbacks, isEmpty);
    });

    test('不传 dirPath → 没有兜底（老调用点行为一字不变）', () {
      final q = queryOf('126 纯享-仙踪.2026.1080p.mkv');

      expect(q!.fallbacks, isEmpty);
      expect(q.attemptCount, 1);
    });

    test('两个调用点都传 dirPath —— 扫描期与详情页拿到的链必须一样', () {
      // 这条不测行为，测的是「别漏传」。漏了不会报错，只会让兜底永远不生效。
      final q = ScrapeQuery.fromParsed(
        parser.parse('126 纯享-仙踪.2026.1080p.mkv', dirPath: '/来自：分享/仙逆/'),
        dirPath: '/来自：分享/仙逆/',
      );

      expect(q!.fallbacks, isNotEmpty);
    });
  });
}
