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
      // ⚠️ 这里必须带年份：不带年份的这部电影解析结果不可信
      // （`isConfident` 要求「有年份或有季集」），`fromParsed` 直接返回
      // null —— 那是另一条规则，测不到备用词。
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
    test('电影没有年份 → null', () {
      expect(queryOf('Oppenheimer.1080p.WEB-DL.mkv'), isNull,
          reason: '没有年份的电影查询词歧义太大：在线源会返回一堆同名候选，'
              '把**另一部作品**的海报挂到这部片上，比干脆没有海报更糟');
    });

    test('只有集号、提不出片名 → null', () {
      expect(queryOf('S01E01.1080p.WEB-DL.mkv'), isNull,
          reason: '剧集虽然不要求年份，但**仍然要求片名** —— '
              '拿「S01E01」去搜必然搜到别的剧');
    });

    test('完全提不出信息 → null', () {
      expect(queryOf('1080p.WEB-DL.mkv'), isNull);
    });
  });
}
