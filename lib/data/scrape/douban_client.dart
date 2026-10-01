import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/filename_parser.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/scrape_match.dart';
import '../../domain/services/scraper.dart';
import '../http/http_client.dart';

/// 豆瓣刮削器。
///
/// ## 为什么在 TMDB 之外再加一个
///
/// TMDB 在境内**不可达**（`api.themoviedb.org` 被 DNS 污染、
/// `image.tmdb.org` 被 SNI 阻断，2026-10-01 实测），只能靠自建反代绕过。
/// 而 TMDB 最弱的一块恰好是**国产剧 / 国漫 / 综艺**——那正是这个媒体库里
/// 占比最大的内容。豆瓣两者都强，且境内直连可达。
///
/// ## 走的是 rexxar 接口（移动端 H5 在用的那一套）
///
///   - 搜索：`/rexxar/api/v2/search?q=<词>&type=movie&for_mobile=1`
///   - 详情：`/rexxar/api/v2/movie/{id}?for_mobile=1`
///
/// 官方 App 的 `frodo.douban.com` 需要签名（实测 `997 签名缺失`），公开
/// apikey 已作废（`1062`），所以那条路是死的。rexxar 只要带
/// `Referer: https://movie.douban.com/` 就能匿名调用。
///
/// ## 六个「改错了不报错、只是结果变空/变错」的坑
///
/// 1. **搜索结果是三段，不是一段。** 正片条目经常**不在** `subjects.items`
///    里 —— 实测搜「繁花」，`subjects.items` 只有两本书和一个 2028 年的
///    `繁花(影版)`，而真正的剧集（`tv/34874646`，2023，王家卫）只在
///    `smart_box` 里。只读 `subjects` 会**静默刮错片子**。
/// 2. **`type` 参数不是过滤器。** 传 `type=movie`，返回里照样混着
///    `book` / `music`。必须自己按 `target_type` 剔掉非影视条目。
/// 3. **搜索结果的 `cover_url` 不能当海报。** 它被服务端套了
///    `imageView2/…/h/120/format/jpg`，是一条 120px 高的横条。海报只能取
///    **详情接口**的 `cover_url`（`m_ratio_poster`，实测 540×803 = 2:3）。
/// 4. **详情接口对剧集会 301 到 `/tv/{id}`。** 所以类型不能靠请求的路径判断，
///    要读**最终响应体**里的 `type`（`movie` / `tv`）。
/// 5. **限流是显式的，但 HTTP 状态码不稳定。** 额度耗尽返回
///    `{"request":"GET /v2/search","msg":"need_login","code":103}`，
///    实测**既见过 200 也见过 403**。所以判成功必须在解析业务码**之后**，
///    只看状态码会把 403 那次的 103 当成普通失败而漏掉熔断。
/// 6. **海报 CDN 缺 `Referer` 一律 418。** 实测带 Referer 200 / 不带 418。
///    这条在 `imageHeaders()` 里给，由 `PosterCache` 在下载时调用。
///
/// ## 额度与节流
///
/// 匿名额度实测约 **10 个不同的搜索词**，之后就是 `103 need_login`；
/// 而**同一个词连打多次会命中缓存**（不扣额度），所以「多打几次看看」
/// 这种排查方式会得出完全错误的结论。
///
/// 应对：
///   - [isEnabled] 要求**配了 Cookie**（登录态额度宽得多）；
///   - 每个作品最多搜 **2 个词**，且**只在第一个词零命中时**才试第二个；
///   - 请求之间强制间隔 [minRequestInterval]；
///   - 一旦见到 `103` 立刻**熔断**（[isNeedLogin]），本次不再发任何豆瓣请求。
class DoubanScraper implements MetadataScraper {
  DoubanScraper({
    required HttpClientLike http,
    required String cookie,
    String baseUrl = defaultBaseUrl,
    Duration timeout = const Duration(seconds: 12),
    Duration minRequestInterval = const Duration(seconds: 3),
    DateTime Function()? clock,
  })  : _http = http,
        _cookie = cookie.trim(),
        _baseUrl = baseUrl,
        _timeout = timeout,
        _minInterval = minRequestInterval,
        _clock = clock ?? DateTime.now;

  /// rexxar 接口的根。**没有版本号之外的前缀**，路径直接接在后面。
  static const String defaultBaseUrl = 'https://m.douban.com/rexxar/api/v2';

  /// 必带的 `Referer`。少了它接口直接拒绝。
  static const String referer = 'https://movie.douban.com/';

  /// 服务端要求登录的业务码。
  static const int needLoginCode = 103;

  final HttpClientLike _http;
  final String _cookie;
  final String _baseUrl;
  final Duration _timeout;
  final Duration _minInterval;

  /// 取当前时间。**可注入** —— 冷却逻辑是纯时间函数，用真实时钟测就得
  /// `await Future.delayed`，既慢又不稳（CI 上尤其）。
  final DateTime Function() _clock;

  /// 上一次请求的时间，用于节流。
  DateTime? _lastRequestAt;

  /// 连续网络失败次数；达到阈值后进入 [_unreachableUntil] 冷却。
  ///
  /// 与 [TmdbScraper] 同一套判据：只认**网络层失败**，拿到任何 HTTP 响应
  /// 都算服务可达、计数归零 —— 否则「Cookie 过期」会被表现成「豆瓣连不上」，
  /// 用户会去查网络而不是去更新 Cookie。
  int _networkFailures = 0;

  /// 连续网络失败后的冷却截止时刻。`null` = 没被判定为不可达。
  ///
  /// 与 [_needLoginUntil] 一样**必须是会过期的**：用户「先开代理再回来刮」
  /// 是很正常的操作，而一次性的永久熔断会让他在修好网络之后依然刮不到，
  /// 且只有重启应用才恢复 —— 这正是「明明修好了却还是不行」的来源。
  DateTime? _unreachableUntil;

  static const int _maxConsecutiveFailures = 3;

  /// 网络层失败的冷却时长。比额度冷却短：网络是用户自己能立刻修好的。
  static const Duration unreachableBackoff = Duration(minutes: 2);

  /// 见到 `103 need_login` 后的**冷却截止时刻**。`null` = 现在可以试。
  ///
  /// ## 为什么不是「一次性熔断，本次进程内不恢复」
  ///
  /// 早先的实现是见到 103 就置一个单向的 `_needLogin = true`。它的理由
  /// （「额度耗尽后继续打只会被关得更久」）对**真的额度耗尽**成立，但
  /// 103 还有另一个来源：**瞬时风控**。2026-10-01 实测到过这一串 ——
  ///
  ///   17:25:32  豆瓣 403 + code 103 → 熔断
  ///   17:26:15  之后每一部作品都直接返回，**连请求都不发**
  ///
  /// 而同一个 Cookie、同一个出口 IP，几分钟后用同样的请求打回去是 **200**。
  /// 也就是说：一次瞬时风控把豆瓣在本进程内**永久**关掉了，用户看到的是
  /// 「豆瓣一条都刮不到」，而且只有重启应用才能恢复，界面上还什么都不说。
  ///
  /// 改成带**指数退避的冷却**之后两种情形都对：
  ///   - 真的额度耗尽 → 每次重试都还是 103 → 退避翻倍，实际退化成「不再打」；
  ///   - 瞬时风控 → 冷却结束后的那一次重试就成功，自动恢复。
  DateTime? _needLoginUntil;

  /// 下一次冷却的时长。每再吃到一次 103 就翻倍，封顶 [maxNeedLoginBackoff]。
  Duration _needLoginBackoff = initialNeedLoginBackoff;

  /// 首次冷却时长。够短，用户「等一会儿再点一次」就能恢复。
  static const Duration initialNeedLoginBackoff = Duration(seconds: 60);

  /// 冷却上限。**不是永久** —— 额度按天重置，留一个每天都会重试的口子。
  static const Duration maxNeedLoginBackoff = Duration(minutes: 30);

  @override
  String get id => 'douban';

  @override
  String get displayName => '豆瓣';

  /// 配了 Cookie 才算可用。
  ///
  /// 匿名额度只有约 10 个搜索词，走一遍媒体库必然不够；而额度耗尽时
  /// 刮削是**整批失败**的，用户看到的会是「豆瓣一条都刮不到」。
  /// 与其给一个必然失败的默认，不如要求先配 Cookie。
  @override
  bool get isEnabled => _cookie.isNotEmpty;

  /// 是否已被判定「连不上」（网络层），仍在冷却期内。
  bool get isUnreachable => _unreachableCooldown > Duration.zero;

  /// 网络层冷却还剩多久。未冷却时返回 [Duration.zero]。纯读，无副作用。
  Duration get _unreachableCooldown {
    final until = _unreachableUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// 网络层冷却是否仍生效。到点顺手清掉，让 [scrape] 放行。
  bool get _unreachableActive {
    if (_unreachableUntil == null) return false;
    if (_unreachableCooldown > Duration.zero) return true;
    _unreachableUntil = null;
    _networkFailures = 0;
    return false;
  }

  /// 是否正处于「额度 / 风控」冷却中。诊断与设置页用。
  bool get isNeedLogin => needLoginCooldown > Duration.zero;

  /// 冷却还剩多久。未冷却（含已到期）时返回 [Duration.zero]。
  ///
  /// 到点**不自动改写字段**，只按当前时间算 —— 这样它是纯读的，
  /// 任何调用方（含界面每帧重画）都不会有副作用。
  Duration get needLoginCooldown {
    final until = _needLoginUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// 冷却是否仍然生效。到点就顺手清掉，让 [scrape] 放行。
  bool get _coolingDown {
    if (_needLoginUntil == null) return false;
    if (needLoginCooldown > Duration.zero) return true;
    _needLoginUntil = null;
    // 冷却结束不代表额度恢复，退避档位保留到「真的成功一次」才归零。
    return false;
  }

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async {
    if (!isEnabled) return null;
    if (_unreachableActive || _coolingDown) return null;

    // 候选词：中文优先，另一个作为「第一个词零命中」时的补救。
    final words = <String>[
      query.title.trim(),
      if ((query.alternateTitle ?? '').trim().isNotEmpty)
        query.alternateTitle!.trim(),
    ].where((s) => s.isNotEmpty).toSet().toList();
    if (words.isEmpty) return null;

    for (final word in words) {
      final candidates = await _search(word);
      // `null` = 这次请求本身失败（网络/熔断），不必再试下一个词。
      if (candidates == null) return null;

      final best = _pickBest(candidates, query);
      if (best == null) {
        diag.info('刮削', '豆瓣 "$word" 没有可用条目');
        // 只在**这个词一个候选都没有**时才花第二个词的额度。
        continue;
      }

      final detail = await _detail(best.id);
      if (detail == null) continue;

      final meta = _toMetadata(detail, word);
      if (meta != null) return meta;
    }
    return null;
  }

  // -------------------------------------------------------------------
  // 手动刮削：候选列表
  // -------------------------------------------------------------------

  /// 按用户**重新输入的片名**搜一批候选，供手动挑选。
  ///
  /// ## 与 [scrape] 的三处刻意差别
  ///
  ///   1. **不过 [_pickBest]，也不打分。** 用户要看到尽可能多的候选自己判断 ——
  ///      而 `_pickBest` 的全部意义就是「替用户选一个」，两者目标相反。
  ///      实际被闸门拦下来的候选，往往正是用户想找的那一个：
  ///      目录名 `超z级z马z力z欧z银z河z大z电影aa` 被插了 `z`，闸门判它
  ///      与《超级马力欧银河大电影》不相似，自动刮削会正确地放弃 ——
  ///      但用户手动搜「超级马力欧银河大电影」时，那条候选必须出现在列表里。
  ///   2. **只搜一个词。** [scrape] 会在第一个词零命中时再花第二个词的额度
  ///      （共 2 个搜索词）；手动通道一次点击只花 1 个，且用户看得见结果，
  ///      不满意可以自己改了再搜。
  ///   3. **只剔非影视条目**（书 / 音乐 / 游戏），不做任何其他过滤。
  ///      `type=movie` 不是过滤器（见类文档坑 #2），不剔的话搜「繁花」
  ///      前两条就是两本书，用户会以为豆瓣上没这部片子。
  ///
  /// 返回空列表 = 没搜到（或熔断中），**不区分** —— 对话框那边两种情况
  /// 都只能说「换个词再试」，区分了对用户没有额外价值。
  @override
  Future<List<ScrapeCandidate>> search(ScrapeQuery query) async {
    if (!isEnabled) return const [];
    if (_unreachableActive || _coolingDown) return const [];

    final word = query.title.trim();
    if (word.isEmpty) return const [];

    final candidates = await _search(word);
    if (candidates == null) return const [];

    final out = <ScrapeCandidate>[];
    for (final c in candidates) {
      if (c.targetType != 'movie' && c.targetType != 'tv') continue;
      out.add(
        ScrapeCandidate(
          source: id,
          sourceId: c.id,
          title: c.title,
          year: c.year,
          // ⚠️ 只是**列表缩略图**：搜索结果的 `cover_url` 被服务端套了
          // `imageView2/…/h/120/…`，是一条 120px 横条，不能当作品海报
          // （见类文档坑 #3）。落库的海报一律来自 [resolve] 的详情接口。
          posterUrl: c.coverUrl,
          isEpisode: c.targetType == 'tv',
          // 豆瓣的搜索结果里既没有完整海报也没有简介，`resolve` 必须现打
          // 详情接口，所以这里没有可复用的原始条目。
          raw: null,
        ),
      );
    }
    diag.debug('刮削', '豆瓣 "$word" 给出 ${out.length} 条手动候选');
    return out;
  }

  /// 用户选中的候选 → 完整元数据。
  ///
  /// **必须打一次详情接口**：搜索结果里只有 id / 标题 / 年份，海报
  /// （`cover_url` 是 120px 横条）和简介都得从 `/movie/{id}` 拿。
  ///
  /// `matchedQuery` 记的是候选自己的标题而不是用户输入的原词 ——
  /// 这个字段是给排查「刮错了」用的，用户最终选中的是哪一个候选，
  /// 比他在搜索框里敲了什么更重要。
  @override
  Future<ScrapedMetadata?> resolve(ScrapeCandidate candidate) async {
    if (!isEnabled) return null;
    if (_unreachableActive || _coolingDown) return null;

    final detail = await _detail(candidate.sourceId);
    if (detail == null) return null;

    return _toMetadata(detail, candidate.title);
  }

  // -------------------------------------------------------------------
  // 探测（设置页的「测试连接」）
  // -------------------------------------------------------------------

  /// 探测用的搜索词。**必须选一个必定有结果的词**，否则区分不出
  /// 「接口通但这个词零命中」与「接口不通」。
  static const String probeWord = '流浪地球';

  /// 打一次真实搜索，把「地址通不通 / Cookie 是不是登录态 / 有没有被限流」
  /// 直接告诉用户。
  ///
  /// ## 为什么必须有它
  ///
  /// 用户填完 Cookie 之后，唯一能验证的方式是「刮一部看看」—— 而那要等
  /// TMDB 先超时 20 秒，最后只给一个「未命中」。三种完全不同的原因
  /// （地址不通 / Cookie 无效 / 被限流）在结果上长得一模一样。
  ///
  /// **不走 [_throttle]**：这是用户手动触发的单次请求，等 3 秒毫无意义。
  Future<DoubanProbeResult> probe() async {
    if (_cookie.isEmpty) {
      return const DoubanProbeResult(
        status: DoubanProbeStatus.noCookie,
        message: '还没填 Cookie。豆瓣的匿名额度实测只有约 10 个搜索词，'
            '全盘刮会中途耗尽 —— 所以这里要求先填。',
      );
    }

    final res = await _http.get(
      '$_baseUrl/search',
      query: {'q': probeWord, 'type': 'movie', 'for_mobile': '1'},
      headers: _headers,
      timeout: _timeout,
    );

    if (res.isNetworkFailure) {
      _noteNetworkFailure();
      return DoubanProbeResult(
        status: DoubanProbeStatus.unreachable,
        message: '连不上 $_baseUrl —— 网络层失败（${res.rawBody}）。'
            '豆瓣境内一般可直连；若开了系统代理，检查它是否把 m.douban.com '
            '也一并劫持了。',
      );
    }

    if (_isNeedLogin(res)) {
      _latchNeedLogin();
      return DoubanProbeResult(
        status: DoubanProbeStatus.needLogin,
        loggedIn: _looksLoggedIn,
        message: '接口可达，但豆瓣回了 103 need_login（HTTP ${res.statusCode}）'
            '—— 当前出口 IP 被限流，或这个 Cookie 已失效。'
            '${_looksLoggedIn ? '你填的 Cookie 含 dbcl2，形状是对的，多半是被限流；'
                : '你填的 Cookie 里没有 dbcl2，多半不是登录态。'}'
            '等 ${needLoginCooldown.inSeconds} 秒后可再试。',
      );
    }

    if (!res.isSuccessStatus) {
      return DoubanProbeResult(
        status: DoubanProbeStatus.httpError,
        message: '接口可达，但返回 HTTP ${res.statusCode}。',
      );
    }

    // 拿到了正常响应 = 服务可达、Cookie 没被拒。两套熔断都复位。
    _resetBackoff();

    final hits = <_Candidate>[
      ..._candidatesOf(res.json?['subjects']),
      ..._candidatesOf(res.json?['smart_box']),
    ];

    if (hits.isEmpty) {
      return DoubanProbeResult(
        status: DoubanProbeStatus.empty,
        loggedIn: _looksLoggedIn,
        message: '接口可达、Cookie 未被拒，但搜「$probeWord」零结果 —— '
            '多半是接口改版了，请提 issue。',
      );
    }

    return DoubanProbeResult(
      status: DoubanProbeStatus.ok,
      loggedIn: _looksLoggedIn,
      candidateCount: hits.length,
      message: '连接正常：搜「$probeWord」返回 ${hits.length} 条。'
          '${_looksLoggedIn ? 'Cookie 含 dbcl2，是登录态，额度宽。'
              : 'Cookie 里没有 dbcl2 —— 走的是匿名额度（约 10 个搜索词）。'}',
    );
  }

  /// Cookie 里有没有登录态标志（`dbcl2`）。
  bool get _looksLoggedIn => cookieHasLoginToken(_cookie);

  /// Cookie 字符串的形状判断：是否含 `dbcl2=<uid>:<token>`。
  ///
  /// **只判形状，不验真伪** —— 真伪只有服务端说了算。它的价值是在用户
  /// 贴错东西（只贴了 `bid`、或者把整个 `Cookie: xxx` 前缀也贴进来）时
  /// 立刻给一句提示，而不是让他等一次刮削失败。
  ///
  /// 按「分号 + 可选空格」切分，所以 `ll="1";dbcl2=x` 与
  /// `ll="1"; dbcl2=x` 都能认出来；而 `xdbcl2=` 不会误判。
  static bool cookieHasLoginToken(String cookie) =>
      RegExp(r'(^|;)\s*dbcl2=').hasMatch(cookie);

  /// 用户把 `Cookie: ` 前缀一起贴进来是很常见的一种错法。
  static bool looksLikeRawHeader(String cookie) =>
      RegExp(r'^\s*cookie\s*:', caseSensitive: false).hasMatch(cookie);

  // -------------------------------------------------------------------
  // 搜索
  // -------------------------------------------------------------------

  /// 搜一个词。返回候选列表；**请求本身失败时返回 `null`**（与「零候选」区分）。
  Future<List<_Candidate>?> _search(String word) async {
    final res = await _get('/search', {
      'q': word,
      // 实测这个参数**不是过滤器**（传 movie 也会返回 book），
      // 但仍然带上：服务端会据此调整排序权重。
      'type': 'movie',
      'for_mobile': '1',
    });
    if (res == null) return null;

    // ⚠️ 两个来源都要读，理由见类文档的坑 #1。
    final out = <_Candidate>[
      ..._candidatesOf(res.json?['subjects']),
      ..._candidatesOf(res.json?['smart_box']),
    ];
    diag.debug('刮削', '豆瓣 "$word" 候选 ${out.length} 条');
    return out;
  }

  /// 从 `subjects`（对象，条目在 `items`）或 `smart_box`（**数组**）里取候选。
  ///
  /// 两处形状不同 —— `subjects` 是 `{items:[…], target_name:…}`，而
  /// `smart_box` 直接就是数组。写两个解析器很容易只维护其中一个。
  static List<_Candidate> _candidatesOf(Object? node) {
    final List<Object?> raw;
    if (node is Map) {
      final items = node['items'];
      raw = items is List ? items : const [];
    } else if (node is List) {
      raw = node;
    } else {
      return const [];
    }

    final out = <_Candidate>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final target = entry['target'];
      if (target is! Map) continue; // `layout: more_results` 这类占位项
      final c = _Candidate.fromJson(
        target.cast<String, Object?>(),
        entry['target_type'],
      );
      if (c != null) out.add(c);
    }
    return out;
  }

  /// 挑一条最像的。
  ///
  /// ## 为什么不能像 TMDB 那样「直接取第一条」
  ///
  /// 豆瓣的搜索结果会把**同一部作品的不同季/年番拆成多条**。实测搜「仙逆」：
  /// `仙逆 第一季`(2023, 26954 人评) / `仙逆 年番3`(2026, 2606) /
  /// `仙逆 年番4`… 取第一条有时对、有时错，而错的那次是**静默**的。
  ///
  /// 打分维度（分高者胜）：
  ///   - **标题**：完全相同 > 归一化后相同 > 前缀 > 包含。`仙逆` 对
  ///     `仙逆 第一季` 就是「前缀」，能赢过不相关的结果；
  ///   - **年份**：相同加分；差 ≥2 年重罚（`仙逆` 对 `年番3` 的 2026）。
  ///     差 1 年不罚 —— 发布组标「发行年」、豆瓣记「首播年」是常态；
  ///   - **类型**：查询是剧集时偏向 `tv`，是电影时偏向 `movie`；
  ///     查询类型未知（综艺 `第12期` 这类解析不出季集号）时**不加分**，
  ///     否则会把综艺（豆瓣记为 `tv`）误判；
  ///   - **热度**：`rating.count` 做**同分时的兜底**，让「第一季」赢过
  ///     「年番3」这类只有几千人评的分支。
  static _Candidate? _pickBest(
    List<_Candidate> candidates,
    ScrapeQuery query,
  ) {
    _Candidate? best;
    var bestScore = 0.0;

    for (final c in candidates) {
      // 非影视条目（书 / 音乐 / 游戏）直接排除。实测搜「繁花」的前两条
      // 就是两本书，不排掉会把它们当成候选去算分。
      if (c.targetType != 'movie' && c.targetType != 'tv') continue;

      // 与 TMDB 同一道闸门（见 `scrape_match.dart`）：标题对不上、或年份差
      // 得太多的候选**直接出局**，而不是靠打分把它压到第二名 ——
      // 打分是「谁的分数高」，闸门是「配不配」。少了它，一个全是垃圾候选的
      // 搜索结果里总会有个「第一名」被选中。
      final match = ScrapeMatch.evaluate(
        queryTitle: query.title,
        queryAlternateTitle: query.alternateTitle,
        queryYear: query.year,
        resultTitle: c.title,
        resultYear: c.year,
      );
      if (!match.accepted) {
        diag.debug('刮削', '豆瓣跳过候选 "${c.title}"：${match.reason}');
        continue;
      }

      final score = c.scoreFor(query);
      if (score <= 0) continue;
      if (best == null || score > bestScore) {
        best = c;
        bestScore = score;
      }
    }

    if (best != null) {
      diag.debug(
        '刮削',
        '豆瓣选中 ${best.targetType}/${best.id} "${best.title}"'
        '${best.year == null ? "" : " (${best.year})"} score=${bestScore.toStringAsFixed(0)}',
      );
    }
    return best;
  }

  // -------------------------------------------------------------------
  // 详情
  // -------------------------------------------------------------------

  /// 取详情。
  ///
  /// 剧集这里会 **301 到 `/tv/{id}`**，由 HTTP 层跟随（`followRedirects`
  /// 默认为真），所以拿到的就是剧集详情 —— 真实类型读响应体的 `type`。
  Future<Map<String, Object?>?> _detail(String id) async {
    final res = await _get('/movie/$id', {'for_mobile': '1'});
    return res?.json;
  }

  /// 把详情响应映射成元数据。**响应不是一个条目时返回 `null`。**
  ///
  /// [matchedQuery] 是实际用于命中的查询词（排查「刮错了」时看它）。
  ScrapedMetadata? _toMetadata(
    Map<String, Object?> detail,
    String matchedQuery,
  ) {
    final id = _stringOf(detail['id']);
    // 类型读**响应体**，不是请求路径：`/movie/{id}` 对剧集会跳到 `/tv/{id}`，
    // 按路径判断会把所有剧集都记成电影。
    final type = _stringOf(detail['type']) ?? 'movie';
    final isTv = type == 'tv';

    // ## 标题**只能**来自响应体，不许拿查询词兜底
    //
    // 曾经写成 `_stringOf(detail['title']) ?? query.title`。它看着更「健壮」，
    // 实际是把「详情没拿到」伪装成「刮削成功」：服务端返回一个 HTTP 200 但
    // 内容不是条目（错误对象、风控页、接口改版）时，兜底会把**用户搜的那个
    // 词**当成结果写进库 —— 标题是有的、海报简介一个都没有，而且 `source`
    // 记成 online。用户看到的是「已刮削」，与「刮削成功但没有封面」这类
    // 现象完全一样，排查时最难想到根因在这里。
    //
    // 正常的 `/movie/{id}` 响应**一定有** `title`（实测 77 个顶层字段里
    // `title` 是必有的），所以这个收紧不会误伤。
    final title = _stringOf(detail['title']);
    if (title == null || title.isEmpty) {
      diag.warn(
        '刮削',
        '豆瓣详情响应里没有 title，判定为无效条目（id=$id）——'
            '多半是接口改版或返回了错误对象，不是「这部片子没有标题」。',
      );
      return null;
    }

    final cover = _stringOf(detail['cover_url']);

    // 海报直接用详情给的 `cover_url`（`m_ratio_poster`，实测 540×803 = 2:3）。
    //
    // 不改写成 `l_ratio_poster`（1080×1606，但 299KB）：卡片墙的格子约
    // 170×255 逻辑像素，`m` 在 3 倍屏下也够（510×765），而体积只有三分之一。
    return ScrapedMetadata(
      title: title,
      // 国产片的 `original_title` 实测是空串（不是缺失），所以按空处理。
      // 不从 `aka` 里猜外语原名：实测「流浪地球2」的 `aka` 首项是
      // `流浪地球2(3D版)`，猜出来只会是错的。
      originalTitle: _stringOf(detail['original_title']),
      year: _yearOf(_stringOf(detail['year'])),
      overview: _stringOf(detail['intro']),
      posterUrl: cover,
      // 豆瓣详情里没有独立的剧照字段（`pic` 是同一张海报的大小档），
      // 所以背景图留空 —— 用同一张海报当背景只会糊成一片。
      backdropUrl: null,
      rating: _doubleOf(_mapOf(detail['rating'])?['value']),
      genres: _stringListOf(detail['genres']),
      // `ScrapedMetadata` 没有 kind 字段，所以把解析出的类型编进 onlineId：
      // 少了这一段，「这部电影」与「这部剧」在库里就无法区分了。
      onlineId: id == null ? null : 'douban/${isTv ? "tv" : "movie"}/$id',
      source: ScrapeSource.online,
      matchedQuery: matchedQuery,
    );
  }

  // -------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------

  Map<String, String> get _headers => {
        'Referer': referer,
        'Accept': 'application/json',
        // 实测用桌面版 UA 就能通；换成移动 UA 没有额外好处，反而多一个变量。
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
        if (_cookie.isNotEmpty) 'Cookie': _cookie,
      };

  Future<HttpResult?> _get(String path, Map<String, Object?> params) async {
    await _throttle();

    final res = await _http.get(
      '$_baseUrl$path',
      query: params,
      headers: _headers,
      timeout: _timeout,
    );

    if (res.isNetworkFailure) {
      diag.warn('刮削', '豆瓣 $path 网络失败：${res.rawBody}');
      _noteNetworkFailure();
      return null;
    }

    // 拿到了 HTTP 响应就说明服务可达 —— 无论状态码是几，都清掉失败计数。
    _networkFailures = 0;

    // ⚠️ 业务码判在状态码**之前**：实测 `103 need_login` 既可能带 200
    // 也可能带 403，先看状态码会把 403 那次的熔断信号漏掉。
    if (_isNeedLogin(res)) {
      _latchNeedLogin();
      return null;
    }

    if (!res.isSuccessStatus) {
      diag.warn('刮削', '豆瓣 $path HTTP ${res.statusCode}');
      return null;
    }

    // 真的拿到一次正常响应 = 冷却与退避档位都该归零。
    // 少了这一步，一次瞬时风控之后的退避会一直停在很长的档位上。
    _resetBackoff();
    return res;
  }

  /// 响应体是不是「额度耗尽 / 需要登录」。
  static bool _isNeedLogin(HttpResult res) {
    final j = res.json;
    if (j == null) return false;
    final code = j['code'];
    if (code == needLoginCode || code == '$needLoginCode') return true;
    return j['msg'] == 'need_login';
  }

  /// 进入冷却，并把下一次冷却时长翻倍（封顶 [maxNeedLoginBackoff]）。
  void _latchNeedLogin() {
    final wait = _needLoginBackoff;
    _needLoginUntil = _clock().add(wait);

    final doubled = wait * 2;
    _needLoginBackoff =
        doubled > maxNeedLoginBackoff ? maxNeedLoginBackoff : doubled;

    diag.warn(
      '刮削',
      '豆瓣返回 $needLoginCode（need_login）：额度耗尽或触发风控，'
          '冷却 ${wait.inSeconds}s 后再试（下次冷却 ${_needLoginBackoff.inSeconds}s）。'
          '匿名额度实测约 10 个搜索词，到「设置 → 刮削」粘贴登录后的 Cookie 可继续。',
    );
  }

  /// 探测成功后把两套熔断都复位。
  ///
  /// 「连点几次测试连接」不该把刮削的熔断打开，所以成功路径必须清计数。
  void _resetBackoff() {
    _networkFailures = 0;
    _unreachableUntil = null;
    _needLoginUntil = null;
    _needLoginBackoff = initialNeedLoginBackoff;
  }

  void _noteNetworkFailure() {
    if (_unreachableActive) return;
    _networkFailures++;
    if (_networkFailures < _maxConsecutiveFailures) return;

    _unreachableUntil = _clock().add(unreachableBackoff);
    // 计数归零，让冷却到期后的下一轮从 0 开始重新数 —— 否则冷却一结束
    // 就是「已经 3 次」，第一次失败又立刻进冷却。
    _networkFailures = 0;

    diag.warn(
      '刮削',
      '豆瓣连续 $_maxConsecutiveFailures 次网络失败，判定为不可达，'
          '冷却 ${unreachableBackoff.inMinutes} 分钟后再试（接口地址=$_baseUrl）。',
    );
  }

  /// 请求间最小间隔。
  ///
  /// 豆瓣对搜索接口的容忍度很低（额度本身就小），连打很容易直接进入
  /// `103`。宁可慢，也不要为了快把额度烧光 —— 烧光之后是**整批失败**。
  Future<void> _throttle() async {
    if (_minInterval <= Duration.zero) {
      _lastRequestAt = DateTime.now();
      return;
    }
    final last = _lastRequestAt;
    if (last != null) {
      final wait = _minInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequestAt = DateTime.now();
  }

  // -------------------------------------------------------------------
  // 海报
  // -------------------------------------------------------------------

  /// 这个图片地址是不是豆瓣的 CDN。
  static bool ownsImageUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == 'doubanio.com' || host.endsWith('.doubanio.com');
  }

  /// 下载豆瓣图片必须带的请求头。
  ///
  /// 实测 `img*.doubanio.com` 缺 `Referer` 一律 **418**（带则 200）。
  ///
  /// **不带 Cookie**：实测图片 CDN 只看 Referer，而把用户的豆瓣登录凭证
  /// 送到图片域名上没有必要 —— 能少送一处就少送一处。
  static Map<String, String> imageHeaders() => const {'Referer': referer};

  // -------------------------------------------------------------------
  // 解析小工具
  // -------------------------------------------------------------------

  static String? _stringOf(Object? v) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  static Map<String, Object?>? _mapOf(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;

  static int? _intOf(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static double? _doubleOf(Object? v) {
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static List<String> _stringListOf(Object? v) {
    if (v is! List) return const [];
    return v.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  }

  /// 豆瓣的 `year` 是**字符串**（`"2023"`），也可能整个缺失。
  static int? _yearOf(String? raw) {
    if (raw == null || raw.length < 4) return null;
    final y = int.tryParse(raw.substring(0, 4));
    if (y == null || y < 1900 || y > DateTime.now().year + 3) return null;
    return y;
  }
}

/// [DoubanScraper.probe] 的结论分类。
///
/// 分这么细是因为**用户要据此采取不同的动作**：
///   - [noCookie] / [unreachable] → 去改配置或网络；
///   - [needLogin] → 要么等冷却，要么换 Cookie；
///   - [httpError] / [empty] → 是服务端或接口改版，不是用户的错；
///   - [ok] → 不用管。
enum DoubanProbeStatus { ok, noCookie, unreachable, needLogin, httpError, empty }

/// 一次豆瓣探测的结果。
class DoubanProbeResult {
  const DoubanProbeResult({
    required this.status,
    required this.message,
    this.loggedIn = false,
    this.candidateCount = 0,
  });

  final DoubanProbeStatus status;

  /// 给用户看的一句话结论（已含下一步该做什么）。
  final String message;

  /// Cookie 是否**看起来**是登录态（含 `dbcl2`）。只判形状。
  final bool loggedIn;

  /// 探测词命中的候选数。只对 [DoubanProbeStatus.ok] 有意义。
  final int candidateCount;

  bool get ok => status == DoubanProbeStatus.ok;
}

/// 一条搜索候选。
class _Candidate {
  const _Candidate({
    required this.id,
    required this.title,
    required this.targetType,
    this.year,
    this.ratingCount,
    this.coverUrl,
  });

  final String id;
  final String title;

  /// `movie` / `tv` / `book` / `music` / `game` / `more_results` …
  ///
  /// 取自**外层条目**的 `target_type`（`target` 里面没有这个字段）。
  final String targetType;

  final int? year;

  /// 评价人数。**只用来做同分兜底**，不参与主排序 —— 它的量级差异太大，
  /// 当成主权重会把「名字对但小众」的条目压掉。
  final int? ratingCount;

  /// 搜索结果的 `cover_url`。
  ///
  /// ⚠️ 服务端在这条地址上套了 `imageView2/…/h/120/format/jpg`，它是一条
  /// **120px 高的横条**（宽度随原图比例），不是 2:3 的竖版海报。
  /// 所以它只能当候选列表的缩略图，**绝不能落库**（见类文档坑 #3）。
  final String? coverUrl;

  static _Candidate? fromJson(Map<String, Object?> json, Object? targetType) {
    final id = DoubanScraper._stringOf(json['id']) ??
        DoubanScraper._intOf(json['id'])?.toString();
    final title = DoubanScraper._stringOf(json['title']);
    if (id == null || title == null) return null;

    final rating = DoubanScraper._mapOf(json['rating']);

    return _Candidate(
      id: id,
      title: title,
      targetType: targetType is String ? targetType : 'unknown',
      year: DoubanScraper._yearOf(DoubanScraper._stringOf(json['year'])),
      ratingCount: DoubanScraper._intOf(rating?['count']),
      coverUrl: DoubanScraper._stringOf(json['cover_url']),
    );
  }

  /// 打分。`<= 0` 表示「不像」，调用方会跳过。
  double scoreFor(ScrapeQuery query) {
    final want = _normalize(query.title);
    final got = _normalize(title);
    if (want.isEmpty || got.isEmpty) return 0;

    var score = 0.0;

    // 1) 标题契合度。这是主信号。
    if (got == want) {
      score += 1000;
    } else if (got.startsWith(want)) {
      // `仙逆` → `仙逆 第一季`。同一部作品的分季命名都落在这一档。
      score += 700;
    } else if (got.contains(want)) {
      score += 450;
    } else if (want.contains(got)) {
      // 反过来包含（查询词带副标题、候选是主名）。
      score += 300;
    } else {
      return 0; // 标题对不上，直接出局
    }

    // 2) 年份。差 1 年不罚（发行年 vs 首播年），差得多说明是另一部。
    final y = year;
    final qy = query.year;
    if (y != null && qy != null) {
      final diff = (y - qy).abs();
      if (diff == 0) {
        score += 200;
      } else if (diff >= 2) {
        score -= 300;
      }
    }

    // 3) 类型。查询类型未知时**不加分** —— 综艺解析不出季集号，
    //    这时偏向 movie 会把豆瓣记成 tv 的综艺判出局。
    if (query.kind != MediaKind.unknown) {
      final wantTv = query.isEpisode;
      if ((wantTv && targetType == 'tv') || (!wantTv && targetType == 'movie')) {
        score += 150;
      }
    }

    // 4) 热度兜底：最多加 100 分，不会盖过任何一条上面的主信号。
    final count = ratingCount ?? 0;
    score += (count / 20000).clamp(0.0, 100.0);

    return score;
  }

  /// 归一化：只留小写字母数字与汉字。
  ///
  /// `仙逆 第一季` 与 `仙逆第一季` 必须归一化成同一个串，否则「前缀」这一档
  /// 会因为一个空格而失效。
  static String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]'), '');

  @override
  String toString() => '_Candidate($targetType/$id "$title" $year)';
}
