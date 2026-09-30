import '../../core/diagnostics/diag_log.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/scraper.dart';
import '../http/http_client.dart';

/// TMDB 刮削器。
///
/// ## 为什么选 TMDB
///
///   - 有**中文**数据（`language=zh-CN`），海报与简介都是现成的中文；
///   - 免费、注册即用（API Key 由用户在设置里自己填）；
///   - 电影与剧集分开的搜索接口，正好对应本应用的 `movie` / `episode` 分类。
///
/// ## 设计要点
///
/// 1. **默认关闭**。没填 Key 时 [isEnabled] 为 `false`，流水线直接跳过它。
///    这样「不想注册 TMDB」的用户也能有一个可用的媒体库。
/// 2. **中文搜不到就用原始标题再搜一次**。国内发布组的命名经常是
///    `流浪地球2.The.Wandering.Earth.II`，而 TMDB 的中文条目名可能是
///    `流浪地球2` —— 用整串去搜会搜不到，拆开就命中。
/// 3. **只取第一条结果**，不做相似度二次校验。TMDB 的搜索排序已经足够好，
///    自己再算一遍相似度只会在「中文名 vs 英文名」这类场景上帮倒忙。
///    宁可偶尔刮错，也不要为了防错把大部分正常条目也拒掉。
/// 4. **失败返回 `null` 不抛异常**（[MetadataScraper] 的契约）——
///    一部片子刮不到不能让整次扫描中断。
class TmdbScraper implements MetadataScraper {
  TmdbScraper({
    required HttpClientLike http,
    required String apiKey,
    String baseUrl = defaultBaseUrl,
    String imageBaseUrl = defaultImageBaseUrl,
    String language = 'zh-CN',
    Duration timeout = const Duration(seconds: 12),
  })  : _http = http,
        _apiKey = apiKey.trim(),
        _baseUrl = baseUrl,
        _imageBaseUrl = imageBaseUrl,
        _language = language,
        _timeout = timeout;

  static const String defaultBaseUrl = 'https://api.themoviedb.org/3';
  static const String defaultImageBaseUrl = 'https://image.tmdb.org/t/p';

  /// 海报尺寸档位。`w500` 对卡片墙足够清晰，且体积可控（~50KB）。
  static const String posterSize = 'w500';

  /// 背景图尺寸档位。
  static const String backdropSize = 'w1280';

  final HttpClientLike _http;
  final String _apiKey;
  final String _baseUrl;
  final String _imageBaseUrl;
  final String _language;
  final Duration _timeout;

  /// 类型 ID → 中文名。首次需要时拉一次，之后常驻内存。
  ///
  /// 拉不到时**不阻塞刮削** —— 类型只是列表页的一个标签，
  /// 为它多花一次请求失败就整条刮削失败是不划算的。
  Map<int, String>? _genreCache;

  @override
  String get id => 'tmdb';

  @override
  String get displayName => 'TMDB';

  @override
  bool get isEnabled => _apiKey.isNotEmpty;

  @override
  Future<ScrapedMetadata?> scrape(ScrapeQuery query) async {
    if (!isEnabled) return null;

    // 中英混排时两个名字都试：中文优先（TMDB 中文条目更可能带中文简介）
    final candidates = <String>{
      query.title.trim(),
      if ((query.alternateTitle ?? '').trim().isNotEmpty)
        query.alternateTitle!.trim(),
    }.where((s) => s.isNotEmpty).toList();

    for (final candidate in candidates) {
      final hit = await _searchOne(candidate, query);
      if (hit != null) return hit;
    }
    return null;
  }

  /// 用一个查询词搜一次。
  Future<ScrapedMetadata?> _searchOne(
    String title,
    ScrapeQuery query,
  ) async {
    final isTv = query.isEpisode;
    final path = isTv ? '/search/tv' : '/search/movie';

    final params = <String, Object?>{
      'query': title,
      'language': _language,
      'include_adult': 'false',
      'page': 1,
    };
    // 年份能显著提升命中率，但**只在有年份时带**：带错的年份会把正确
    // 条目直接过滤掉（TMDB 的 year 是硬过滤，不是加权）。
    final year = query.year;
    if (year != null) {
      params[isTv ? 'first_air_date_year' : 'year'] = year;
    }

    final res = await _get(path, params);
    if (res == null) return null;

    final results = res.dataListItems;
    if (results.isEmpty) {
      // 带年份搜不到时**去掉年份再试一次** —— 发布组标的年份经常是
      // 「发行年」而 TMDB 记的是「首播年」，差一年就搜不到了。
      if (year != null) {
        diag.info('刮削', 'TMDB "$title" ($year) 无结果，去掉年份重试');
        final retryParams = Map<String, Object?>.from(params)
          ..remove('year')
          ..remove('first_air_date_year');
        final retry = await _get(path, retryParams);
        if (retry == null) return null;
        final items = retry.dataListItems;
        if (items.isEmpty) return null;
        return _toMetadata(items.first, query, title, isTv);
      }
      return null;
    }

    return _toMetadata(results.first, query, title, isTv);
  }

  /// 把一条 TMDB 结果映射成 [ScrapedMetadata]。
  Future<ScrapedMetadata> _toMetadata(
    Map<String, Object?> item,
    ScrapeQuery query,
    String matchedQuery,
    bool isTv,
  ) async {
    final id = _intOf(item['id']);
    final name = _stringOf(item['title']) ??
        _stringOf(item['name']) ??
        query.title;
    final original = _stringOf(item['original_title']) ??
        _stringOf(item['original_name']);

    final date = _stringOf(item['release_date']) ??
        _stringOf(item['first_air_date']);
    final year = _yearOf(date) ?? query.year;

    final posterPath = _stringOf(item['poster_path']);
    final backdropPath = _stringOf(item['backdrop_path']);

    final genreIds = (item['genre_ids'] is List)
        ? (item['genre_ids']! as List).whereType<int>().toList()
        : <int>[];
    final genres = await _genreNames(genreIds, isTv);

    return ScrapedMetadata(
      title: name,
      originalTitle: original,
      year: year,
      overview: _stringOf(item['overview']),
      posterUrl: posterPath == null
          ? null
          : '$_imageBaseUrl/$posterSize$posterPath',
      backdropUrl: backdropPath == null
          ? null
          : '$_imageBaseUrl/$backdropSize$backdropPath',
      rating: _doubleOf(item['vote_average']),
      genres: genres,
      onlineId: id == null ? null : '${isTv ? "tv" : "movie"}/$id',
      source: ScrapeSource.online,
      matchedQuery: matchedQuery,
    );
  }

  /// 类型 ID → 名称。拿不到就返回空列表（不阻塞）。
  Future<List<String>> _genreNames(List<int> ids, bool isTv) async {
    if (ids.isEmpty) return const [];
    var cache = _genreCache;
    if (cache == null) {
      cache = await _loadGenres();
      _genreCache = cache;
    }
    final out = <String>[];
    for (final id in ids) {
      final name = cache[id];
      if (name != null) out.add(name);
    }
    return out;
  }

  Future<Map<int, String>> _loadGenres() async {
    final out = <int, String>{};
    for (final kind in const ['movie', 'tv']) {
      final res = await _get('/genre/$kind/list', {'language': _language});
      final genres = res?.dataMap?['genres'];
      if (genres is! List) continue;
      for (final g in genres) {
        if (g is! Map) continue;
        final id = _intOf(g['id']);
        final name = _stringOf(g['name']);
        if (id != null && name != null) out[id] = name;
      }
    }
    diag.info('刮削', 'TMDB 类型表已缓存 ${out.length} 项');
    return out;
  }

  /// 带鉴权的 GET。
  ///
  /// 两种 Key 都支持：
  ///   - **v4 读取令牌**（`eyJ…` 的 JWT）→ 走 `Authorization: Bearer`
  ///   - **v3 API Key**（32 位十六进制）→ 走 `api_key` 查询参数
  ///
  /// 让用户直接粘贴他从 TMDB 页面复制到的那个串，不用先搞清楚自己拿的是哪种。
  Future<HttpResult?> _get(String path, Map<String, Object?> params) async {
    final headers = <String, String>{'Accept': 'application/json'};
    final query = Map<String, Object?>.from(params);

    if (_apiKey.startsWith('eyJ')) {
      headers['Authorization'] = 'Bearer $_apiKey';
    } else {
      query['api_key'] = _apiKey;
    }

    final res = await _http.get(
      '$_baseUrl$path',
      query: query,
      headers: headers,
      timeout: _timeout,
    );

    if (res.isNetworkFailure) {
      diag.warn('刮削', 'TMDB $path 网络失败：${res.rawBody}');
      return null;
    }
    if (!res.isSuccessStatus) {
      diag.warn('刮削', 'TMDB $path HTTP ${res.statusCode}');
      return null;
    }
    return res;
  }

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

  static String? _stringOf(Object? v) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  /// `2023-07-20` → `2023`。解析不出来返回 `null`。
  static int? _yearOf(String? date) {
    if (date == null || date.length < 4) return null;
    final y = int.tryParse(date.substring(0, 4));
    if (y == null || y < 1900 || y > DateTime.now().year + 2) return null;
    return y;
  }
}
