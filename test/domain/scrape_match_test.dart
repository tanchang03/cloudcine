import 'package:cloudcine/domain/services/scrape_match.dart';
import 'package:flutter_test/flutter_test.dart';

/// 便利包装：只关心「过没过」，中间量在需要的用例里单独取。
bool _accepts({
  required String queryTitle,
  String? queryAlternateTitle,
  int? queryYear,
  required String resultTitle,
  String? resultOriginalTitle,
  int? resultYear,
}) =>
    ScrapeMatch.evaluate(
      queryTitle: queryTitle,
      queryAlternateTitle: queryAlternateTitle,
      queryYear: queryYear,
      resultTitle: resultTitle,
      resultOriginalTitle: resultOriginalTitle,
      resultYear: resultYear,
    ).accepted;

void main() {
  group('归一化', () {
    test('只留小写字母数字与汉字 —— 空格/标点/全角都不该影响判定', () {
      expect(normalizeForMatch('The Wandering Earth II'), 'thewanderingearthii');
      expect(normalizeForMatch('流浪地球 2'), '流浪地球2');
      expect(normalizeForMatch('仙逆·第一季'), '仙逆第一季');
      expect(normalizeForMatch('  '), '');
    });
  });

  group('titleSimilarity 分档', () {
    test('完全相同 → 1', () {
      expect(titleSimilarity('流浪地球2', '流浪地球2'), 1);
      expect(titleSimilarity('Fight Club', 'fight club'), 1);
    });

    test('前缀（同一部作品的分季命名）→ 高分', () {
      final s = titleSimilarity('流浪地球', '流浪地球2');
      expect(s, greaterThan(ScrapeMatch.strongSimilarity));
      expect(s, lessThan(1));
    });

    test('包含（一边带副标题）→ 中分', () {
      final s = titleSimilarity('流浪地球2', '流浪地球2 3D版');
      expect(s, greaterThan(ScrapeMatch.strongSimilarity));
    });

    test('字符顺序不同但高度重合 → Dice 兜底', () {
      // 中英混排的片名换语序时，「前缀 / 包含」两档都不成立。
      final s = titleSimilarity(
        'The Wandering Earth II',
        'Wandering Earth II The',
      );
      expect(s, greaterThan(ScrapeMatch.strongSimilarity));
    });

    test('毫无关系的两部片子 → 低分', () {
      expect(
        titleSimilarity('超级马力欧银河大电影', '低俗小说'),
        lessThan(ScrapeMatch.weakSimilarity),
      );
    });

    test('任一边归一化后为空 → 0（不抛、也不误判为相同）', () {
      expect(titleSimilarity('', '流浪地球'), 0);
      expect(titleSimilarity('!!!', '流浪地球'), 0);
      expect(titleSimilarity('', ''), 0);
    });
  });

  group('年份硬闸门', () {
    test('查询带年份、结果年份差得远 → 淘汰（**这就是本次事故**）', () {
      // 2026-10-01 实测：目录 `超z级z马z力z欧z银z河z大z电影aa(2026)` 被刮成
      // 《低俗小说》(1994)。查询里明明带着 year=2026，代码却直接取
      // `results.first` —— 差 32 年而毫无察觉。
      final r = ScrapeMatch.evaluate(
        queryTitle: '超z级z马z力z欧z银z河z大z电影aa',
        queryYear: 2026,
        resultTitle: '低俗小说',
        resultOriginalTitle: 'Pulp Fiction',
        resultYear: 1994,
      );

      expect(
        r.accepted,
        isFalse,
        reason: '年份差 32 年是这里最廉价也最可靠的判据。'
            '少了这道闸门，TMDB 的模糊搜索结果里「相关度第一名」'
            '会被当成精确命中写进库 —— 标题、简介、评分、海报全换成'
            '另一部片子的，而且**不报错**。',
      );
      expect(r.verdict, ScrapeMatchVerdict.rejectYear);
      expect(r.yearGap, 32);
    });

    test('年份差 1 年不算错（发行年 vs 首播年）', () {
      expect(
        _accepts(
          queryTitle: '流浪地球2',
          queryYear: 2024,
          resultTitle: '流浪地球2',
          resultYear: 2023,
        ),
        isTrue,
      );
    });

    test('年份差刚好 2 年 → 淘汰，即使标题完全相同', () {
      expect(
        _accepts(
          queryTitle: '某部重名片',
          queryYear: 2026,
          resultTitle: '某部重名片',
          resultYear: 2024,
        ),
        isFalse,
        reason: '阈值定 2 是**有意偏严**的：漏刮只是没有在线海报'
            '（夸克缩略图还在，用户照样看得到画面），刮错是静默地'
            '换掉整部片子的元数据。两者代价不对称，所以宁可漏。',
      );
    });

    test('任一边没年份 → 年份闸门不生效，交给标题判', () {
      expect(
        _accepts(
          queryTitle: '流浪地球2',
          resultTitle: '流浪地球2',
          resultYear: 1994,
        ),
        isTrue,
        reason: '查询侧没年份时不能因为「结果有年份」就淘汰 —— '
            '那会把「发布组没标年份」的片子全判死。',
      );
    });
  });

  group('标题闸门（年份不足兜底时的最后一道）', () {
    test('同一年份、标题完全对不上 → 淘汰', () {
      expect(
        _accepts(
          queryTitle: '超级马力欧银河大电影',
          queryYear: 2026,
          resultTitle: '低俗小说',
          resultYear: 2026,
        ),
        isFalse,
      );
    });

    test('被插字符的片名 vs 真名 → **自动刮削认输**，交给人工通道', () {
      // 这条是「为什么必须有手动刮削」的证据：连人都得先知道这串东西
      // 其实是《超级马力欧银河大电影》才可能搜对，任何自动算法都救不回来。
      final r = ScrapeMatch.evaluate(
        queryTitle: '超z级z马z力z欧z银z河z大z电影aa',
        queryYear: 2026,
        resultTitle: '超级马力欧银河大电影',
        resultYear: 2026,
      );

      expect(
        r.accepted,
        isFalse,
        reason: '插进去的 `z` 把字符 bigram 几乎全打散了。闸门在这里'
            '**必须**拒绝：它不知道那串乱码的真名是什么，凭年份相同就接受'
            '的话，同一年任何一部片子都能被选中。',
      );
      // 不是恰好 0：`超z级z…大z电影aa` 里 `电` 与 `影` 是相邻的，
      // 于是撞上了结果标题里的 `电影` 这一个 bigram。0.07 远低于
      // 沾边档下界 0.35，判定不受影响 —— 但要钉住「不是靠 0 才拒绝的」，
      // 否则以后有人调整 bigram 切法时会以为这里恒为 0。
      expect(r.similarity, lessThan(ScrapeMatch.weakSimilarity));
      expect(r.verdict, ScrapeMatchVerdict.rejectTitle);
    });

    test('沾边 + 年份差 ≤1 → 接受', () {
      // `Se7en` 与 `Seven` 是同一部片子（1995）的两种写法，归一化后
      // `se7en` / `seven` 只共享 `se`、`en` 两个 bigram，相似度 0.5 ——
      // 落在「沾边」档。这一档**必须靠年份兜底才接受**：光看标题，
      // 它和「两部不相关但共享几个字」的片子没法区分。
      final r = ScrapeMatch.evaluate(
        queryTitle: 'Se7en',
        queryYear: 1995,
        resultTitle: 'Seven',
        resultYear: 1995,
      );

      expect(r.similarity, greaterThanOrEqualTo(ScrapeMatch.weakSimilarity));
      expect(r.similarity, lessThan(ScrapeMatch.strongSimilarity));
      expect(r.accepted, isTrue);
      expect(r.yearGap, 0);
    });

    test('沾边但没年份兜底 → 淘汰', () {
      // `无间道`(2002, 中国香港) 与 `无间行者`(2006) 是两部**不同的**片子，
      // 但共享 `无间` 这个 bigram，相似度 0.4 —— 正好落在沾边档。
      // 没有年份时，「沾边」这一档里既有真的同片异名、也有不相关的片子，
      // 接受它等于把闸门退回「谁分高谁赢」，而那正是事故的成因。
      final r = ScrapeMatch.evaluate(
        queryTitle: '无间道',
        resultTitle: '无间行者',
      );

      expect(r.similarity, greaterThanOrEqualTo(ScrapeMatch.weakSimilarity));
      expect(r.similarity, lessThan(ScrapeMatch.strongSimilarity));
      expect(r.accepted, isFalse);
      expect(r.verdict, ScrapeMatchVerdict.rejectTitle);
    });

    test('前缀档是「无条件接受」：`仙逆` 对 `仙逆 第一季` 不需要年份', () {
      final r = ScrapeMatch.evaluate(
        queryTitle: '仙逆',
        resultTitle: '仙逆 第一季',
      );

      expect(
        r.similarity,
        greaterThanOrEqualTo(ScrapeMatch.strongSimilarity),
        reason: '前缀档的下界是 `0.65 + 0.35r ≥ 0.65`，**永远**高于'
            'strongSimilarity —— 也就是说「一个标题是另一个的前缀」'
            '这条判据本身已经足够强，不靠年份。'
            '同一部作品的分季命名（`仙逆 第一季` / `年番3`）全在这一档，'
            '给它们加年份要求会把分季条目全判死。',
      );
      expect(r.accepted, isTrue);
    });
  });

  group('跨书写系统', () {
    test('中文查询词 × 英文结果 + 年份接近 → 接受', () {
      // 用英文名搜时 `language=zh-CN` 会让结果标题是中文、原名才是英文，
      // 反过来也会发生；两边的字符集毫无交集，相似度天然为 0。
      expect(
        _accepts(
          queryTitle: '流浪地球2',
          queryYear: 2023,
          resultTitle: 'The Wandering Earth II',
          resultYear: 2023,
        ),
        isTrue,
      );
    });

    test('跨书写系统但年份差 2 年 → 仍然是淘汰', () {
      expect(
        _accepts(
          queryTitle: '流浪地球2',
          queryYear: 2026,
          resultTitle: 'The Wandering Earth II',
          resultYear: 2023,
        ),
        isFalse,
        reason: '跨书写系统这条兜底**必须有年份**：否则「中文词 × 任意英文片名」'
            '全都能过，闸门等于不存在。',
      );
    });

    test('跨书写系统且两边都没年份 → 淘汰', () {
      expect(
        _accepts(
          queryTitle: '流浪地球2',
          resultTitle: 'The Wandering Earth II',
        ),
        isFalse,
      );
    });
  });

  group('备用词（alternateTitle）', () {
    test('主词对不上、备用词对得上 → 接受', () {
      expect(
        _accepts(
          queryTitle: '超z级z马z力z欧z银z河z大z电影aa',
          queryAlternateTitle: '超级马力欧银河大电影',
          queryYear: 2026,
          resultTitle: '超级马力欧银河大电影',
          resultYear: 2026,
        ),
        isTrue,
        reason: '中英混排的片名会同时试两个词（`ScrapeQuery.alternateTitle`）。'
            '结果里 `title` 与 `originalTitle` 都要比 —— 只比一个会漏掉'
            '「用英文名搜到、结果是中文标题」这种常见情形。',
      );
    });

    test('结果的原名也要参与比较', () {
      expect(
        _accepts(
          queryTitle: 'The Wandering Earth II',
          queryYear: 2023,
          resultTitle: '流浪地球2',
          resultOriginalTitle: 'The Wandering Earth II',
          resultYear: 2023,
        ),
        isTrue,
      );
    });
  });

  group('判定理由（日志里给用户看的那句话）', () {
    test('三种结论都有非空理由，且带得上中间量', () {
      final accept = ScrapeMatch.evaluate(
        queryTitle: '流浪地球2',
        queryYear: 2023,
        resultTitle: '流浪地球2',
        resultYear: 2023,
      );
      final rejectYear = ScrapeMatch.evaluate(
        queryTitle: '流浪地球2',
        queryYear: 2026,
        resultTitle: '流浪地球2',
        resultYear: 1994,
      );
      final rejectTitle = ScrapeMatch.evaluate(
        queryTitle: '甲片',
        resultTitle: '乙片',
      );

      for (final r in [accept, rejectYear, rejectTitle]) {
        expect(r.reason, isNotEmpty);
      }
      expect(rejectYear.reason, contains('32'));
    });
  });

  group('纯数字不是名字（2026-10-02 实测事故）', () {
    // 事故现场：`/来自：分享/姜松《家电维修视频教程》/182.格力空调显示E6如何维修.mp4`
    // 的备用词是 "182"，TMDB 模糊搜索返回希腊纪录片《1821: Οι Ήρωες》，
    // 前缀档给出 0.91 —— 高于 strongSimilarity(0.6)，**无条件通过**。
    //
    // 前缀档本身是对的（`仙逆` → `仙逆第一季` 正是它要救的），问题在于它把
    // 「数字」当成了「名字」：`182` 与 `1821` 之间没有任何语义关系。
    // 而且比例也分不开这两者（0.75 vs 0.40），只有字符类型能。
    test('182 不该靠前缀命中 1821 —— 数字之间没有「分季命名」这回事', () {
      expect(
        titleSimilarity('182', '1821: Οι Ήρωες'),
        lessThan(ScrapeMatch.strongSimilarity),
      );
      expect(
        _accepts(
          queryTitle: '182',
          resultTitle: '1821: Οι Ήρωες',
          resultYear: 2021,
        ),
        isFalse,
      );
    });

    test('单字符数字更是如此 —— 1 不该命中 127 Hours', () {
      expect(
        titleSimilarity('1', '127 Hours'),
        lessThan(ScrapeMatch.strongSimilarity),
      );
    });

    test('包含档同样不认数字 —— 2 不该命中 2012', () {
      expect(
        titleSimilarity('2', '2012'),
        lessThan(ScrapeMatch.strongSimilarity),
      );
      expect(
        titleSimilarity('10', '10000 BC'),
        lessThan(ScrapeMatch.strongSimilarity),
      );
    });

    test('⚠️ 但完全相同的数字仍是命中 —— 片名就叫《2012》的电影要能刮到', () {
      expect(titleSimilarity('2012', '2012'), 1);
      expect(
        _accepts(
          queryTitle: '2012',
          resultTitle: '2012',
          resultYear: 2009,
        ),
        isTrue,
      );
    });

    test('汉字里带数字的片名不受影响 —— 流浪地球2 与 流浪地球 仍是包含关系', () {
      expect(
        titleSimilarity('流浪地球2', '流浪地球'),
        greaterThan(ScrapeMatch.weakSimilarity),
      );
    });
  });

  group('宽松档（无年份的电影）：只认精确同名', () {
    // 无年份时年份硬闸门完全失效，只剩标题相似度 —— 而 0.6 那个档是
    // **为「有年份」定的**（那时年份才是主力判据）。实测前缀档会放行
    // 另一部片子，且是静默的。所以这类查询改用精确同名。
    bool acceptsRelaxed({
      required String queryTitle,
      String? queryAlternateTitle,
      int? queryYear,
      required String resultTitle,
      String? resultOriginalTitle,
      int? resultYear,
    }) =>
        ScrapeMatch.evaluate(
          queryTitle: queryTitle,
          queryAlternateTitle: queryAlternateTitle,
          queryYear: queryYear,
          resultTitle: resultTitle,
          resultOriginalTitle: resultOriginalTitle,
          resultYear: resultYear,
          requireExactTitle: true,
        ).accepted;

    test('精确同名 → 接受', () {
      expect(acceptsRelaxed(queryTitle: '奥德赛', resultTitle: '奥德赛'), isTrue);
    });

    test('⚠️ 前缀同名 → 淘汰（严格档会无条件放行的正是这一档）', () {
      expect(
        acceptsRelaxed(queryTitle: '奥德赛', resultTitle: '奥德赛：归来'),
        isFalse,
        reason: '严格档下它是 0.86、无条件通过。无年份时没有年份兜底，'
            '「一个名字是另一个的前缀」既可能是同一部（仙逆 / 仙逆第一季）、'
            '也可能是**另一部片子**（奥德赛 / 奥德赛：归来）—— 分不开就只能拒',
      );
      expect(
        acceptsRelaxed(queryTitle: '英雄', resultTitle: '英雄本色'),
        isFalse,
        reason: '这两部片子毫无关系，却在严格档下拿 0.825 通过',
      );
    });

    test('包含 / Dice 各档同样不认', () {
      expect(
        acceptsRelaxed(queryTitle: '流浪地球2', resultTitle: '流浪地球2 3D版'),
        isFalse,
      );
      expect(acceptsRelaxed(queryTitle: 'Se7en', resultTitle: 'Seven'), isFalse);
    });

    test('跨书写系统也不再兜底 —— 那条兜底**必须有年份**', () {
      expect(
        acceptsRelaxed(
          queryTitle: '流浪地球2',
          resultTitle: 'The Wandering Earth II',
        ),
        isFalse,
        reason: '「中文词 × 任意英文片名」相似度天然为 0，没有年份就等于没有判据',
      );
    });

    test('备用词精确同名也算命中', () {
      expect(
        acceptsRelaxed(
          queryTitle: '某中文名',
          queryAlternateTitle: 'Some English Name',
          resultTitle: 'Some English Name',
        ),
        isTrue,
      );
    });

    test('⚠️ 年份硬闸门仍然生效（两边都有年份时）', () {
      final r = ScrapeMatch.evaluate(
        queryTitle: '某片',
        queryYear: 2026,
        resultTitle: '某片',
        resultYear: 1994,
        requireExactTitle: true,
      );

      expect(r.accepted, isFalse);
      expect(r.verdict, ScrapeMatchVerdict.rejectYear);
    });
  });
}
