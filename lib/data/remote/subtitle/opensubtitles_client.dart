import '../../../core/diagnostics/diag_log.dart';
import '../../../core/utils/text_encoding.dart';
import '../../http/http_client.dart';

/// OpenSubtitles.com 的配置。
///
/// [baseUrl] 可改的理由与 TMDB 那两个地址一样：用户在境内可能要指向一个反代。
/// 但 **OpenSubtitles 的 `/login` 会返回一个 `base_url` 字段**，要求后续请求
/// 打过去 —— 本项目目前只用 Api-Key（不登录），所以暂时用不上；等将来接登录
/// 提额时，那个值要优先于这里的配置。
class OpenSubtitlesConfig {
  const OpenSubtitlesConfig({
    this.apiKey = '',
    this.baseUrl = defaultBaseUrl,
  });

  static const String defaultBaseUrl = 'https://api.opensubtitles.com/api/v1';

  /// ⚠️ `User-Agent` 是**强制**的，而且不能是默认值（见 [OpenSubtitlesClient]
  /// 的类文档：没有它时接口直接 403，错误信息就是一句 `User agent required`）。
  static const String userAgent = 'cloudcine v0.1';

  final String apiKey;
  final String baseUrl;

  /// 没填 key 就是没配。空串与空白都要算空 —— 用户从设置页粘进来时
  /// 很容易带一个换行或空格。
  bool get isConfigured => apiKey.trim().isNotEmpty;
}

/// 失败的**种类**。
///
/// 分开而不是统一一句「在线字幕不可用」，是因为对应的处置完全不同：
///   - [notConfigured] / [badApiKey] → 让用户去设置页改 key；
///   - [quotaExceeded] → 今天就是下不了了，明天再来（要显示 `remaining`）；
///   - [network] / [server] → 可以重试；
///   - [missingUserAgent] → 这是**我们的 bug**，不是用户能修的。
enum OpenSubtitlesFailure {
  notConfigured,
  missingUserAgent,
  badApiKey,
  quotaExceeded,
  network,
  server,
  badResponse,
}

class OpenSubtitlesException implements Exception {
  const OpenSubtitlesException(
    this.failure,
    this.message, {
    this.statusCode,
  });

  final OpenSubtitlesFailure failure;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'OpenSubtitlesException(${failure.name}, $message)';
}

/// 搜到的一条字幕。
///
/// 与 `SubtitleTrack` 分开：那是「已经确定要加载的一条字幕」，而这是
/// **搜索结果里的一个候选** —— 用户还要挑。
class OnlineSubtitleHit {
  const OnlineSubtitleHit({
    required this.fileId,
    required this.fileName,
    this.language,
    this.title,
    this.release,
    this.downloadCount = 0,
    this.rating,
    this.hearingImpaired = false,
    this.foreignPartsOnly = false,
    this.season,
    this.episode,
  });

  /// 下载用的 `file_id`。**唯一**能换到下载地址的东西。
  final int fileId;

  final String fileName;
  final String? language;
  final String? title;
  final String? release;
  final int downloadCount;
  final double? rating;
  final bool hearingImpaired;
  final bool foreignPartsOnly;
  final int? season;
  final int? episode;

  @override
  String toString() => 'OnlineSubtitleHit($fileId, $fileName, ${language ?? "-"})';
}

/// 一次 `/download` 的结果。
class OnlineSubtitleDownload {
  const OnlineSubtitleDownload({
    required this.link,
    required this.fileName,
    this.remaining,
    this.resetTime,
  });

  /// 临时下载地址。**有效期很短**，拿到就要立刻取，不能存起来下次用。
  final String link;
  final String fileName;

  /// 今天还能下几条。额度耗尽时它是 0 —— 要显示给用户，否则「下不了」
  /// 会被理解成「这个功能坏了」。
  final int? remaining;
  final String? resetTime;

  @override
  String toString() => 'OnlineSubtitleDownload($fileName, 剩余 $remaining)';
}

/// OpenSubtitles.com REST API v1 的客户端。
///
/// ## 错误码**不能按常识读** —— 2026-10-01 实测
///
/// 下面这些是 `curl` 打出来的，不是从文档抄的：
///
/// | 请求 | 实测 |
/// |---|---|
/// | 不带 `User-Agent` | `403 {"error":"User agent required"}` |
/// | 带 UA + **无效 `Api-Key`** | `403 {"message":"You cannot consume this service"}` |
/// | **完全不带 `Api-Key`** | `301` |
/// | `POST /download`（无效 key） | `503 {"message":"Service unavailable"}` |
/// | `GET /infos/languages` | `200` —— 它**不校验 key**，不能当鉴权探针 |
///
/// 两条结论，每条都会让「按状态码判断」的写法出错：
///
///   1. **Key 填错返回 `403`，不是 `401`**，而 `403` 同时还是「没带 UA」的码。
///      两者**只能靠响应体**区分。按状态码判断会把「Key 填错」报成「被墙 /
///      服务不可用」，用户就会去换地址而不是改 Key —— 这与 TMDB 熔断那个坑
///      是同一个形状。
///   2. **`/download` 对无效 key 返回 `503`**，与 `/subtitles` 的 `403` 不一致。
///      所以 `503` 不能直接当成「服务挂了」。
///
/// ## 「没搜到」与「请求失败」必须分开
///
/// [search] **返回空列表**表示「确实没有这条字幕」，**抛异常**表示「这次请求没
/// 成」。反过来（把两者都变成空列表）正是本项目反复踩的那类静默失败：用户看到
/// 「搜不到」会以为这部片没有字幕，而实际是 key 没配对。
class OpenSubtitlesClient {
  OpenSubtitlesClient({required this.http, required this.config});

  final HttpClientLike http;
  final OpenSubtitlesConfig config;

  Map<String, String> get _headers => <String, String>{
        'Api-Key': config.apiKey.trim(),
        'User-Agent': OpenSubtitlesConfig.userAgent,
        'Accept': 'application/json',
      };

  /// 搜字幕。**空列表 = 确实没有**，失败会抛 [OpenSubtitlesException]。
  Future<List<OnlineSubtitleHit>> search({
    String? query,
    String languages = 'zh-cn,zh-tw,en',
    int? tmdbId,
    String? imdbId,
    String? type,
    int? season,
    int? episode,
    int? year,
    int page = 1,
  }) async {
    // 没配 key 就不发请求：发也是 403，而 403 在这一层会被读成「服务拒绝」，
    // 与「key 错了」混在一起 —— 白白让用户去排查网络。
    if (!config.isConfigured) {
      throw const OpenSubtitlesException(
        OpenSubtitlesFailure.notConfigured,
        '还没填 OpenSubtitles 的 Api-Key（设置页 → 在线字幕）',
      );
    }

    final queryParams = <String, Object?>{
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (languages.isNotEmpty) 'languages': languages,
      if (tmdbId != null) 'tmdb_id': '$tmdbId',
      if (imdbId != null) 'imdb_id': imdbId,
      if (type != null) 'type': type,
      if (season != null) 'season_number': '$season',
      if (episode != null) 'episode_number': '$episode',
      if (year != null) 'year': '$year',
      'page': '$page',
    };

    final res = await http.get(
      '${config.baseUrl}/subtitles',
      query: queryParams,
      headers: _headers,
    );
    _throwIfFailed(res, what: '搜索字幕');

    final json = res.json;
    if (json == null) {
      throw OpenSubtitlesException(
        OpenSubtitlesFailure.badResponse,
        '搜索字幕的响应不是 JSON 对象',
        statusCode: res.statusCode,
      );
    }
    return parseSearch(json);
  }

  /// 探一次「地址通不通、Api-Key 对不对」。通了就正常返回，否则抛
  /// [OpenSubtitlesException]（原因在 `failure` / `message` 里）。
  ///
  /// ## 为什么打 `/subtitles` 而不是 `/infos/languages`
  ///
  /// 实测：`GET /infos/languages` **不校验 Api-Key**，不带 key 也返回 200。
  /// 拿它当探针会得到「一切正常」，而真正的搜索照样 403 ——
  /// 这正是「探针本身说谎」那一类坑（与 TMDB 的 `/configuration` 相反，
  /// 那个是真校验）。
  ///
  /// `/subtitles` 的判据是干净的：Key 有效 → 200（搜不到东西也是 200 + 空数组），
  /// Key 无效 → 403。而且**搜索不消耗下载额度**，探多少次都不花钱。
  Future<void> probe() => search(query: 'cloudcine', languages: 'en');

  /// 换一条临时下载地址。
  Future<OnlineSubtitleDownload> requestDownload(int fileId) async {
    if (!config.isConfigured) {
      throw const OpenSubtitlesException(
        OpenSubtitlesFailure.notConfigured,
        '还没填 OpenSubtitles 的 Api-Key（设置页 → 在线字幕）',
      );
    }

    final res = await http.post(
      '${config.baseUrl}/download',
      body: <String, Object?>{'file_id': fileId},
      headers: <String, String>{
        ..._headers,
        'Content-Type': 'application/json',
      },
    );
    _throwIfFailed(res, what: '取字幕下载地址');

    final json = res.json;
    final parsed = json == null ? null : parseDownload(json);
    if (parsed == null) {
      throw OpenSubtitlesException(
        OpenSubtitlesFailure.badResponse,
        '取字幕下载地址的响应里没有 link',
        statusCode: res.statusCode,
      );
    }
    return parsed;
  }

  /// 下载并解码一条字幕的正文。失败返回 null。
  ///
  /// 解码放在这里（而不是把字节交给播放窗口）：`fast_gbk` 在主窗口这一侧，
  /// 而播放窗口刻意不背这些依赖 —— 与网盘字幕走的是同一条规矩。
  Future<String?> fetchText(int fileId) async {
    final download = await requestDownload(fileId);
    final bytes = await http.getBytes(download.link);
    if (bytes == null || bytes.isEmpty) {
      diag.warn('字幕', '在线字幕下载为空：fileId=$fileId');
      return null;
    }
    final text = decodeTextBytes(bytes);
    diag.info(
      '字幕',
      '在线字幕已下载：${download.fileName} '
      '${bytes.length}B → ${text.length} 字符（今日剩余 ${download.remaining ?? "-"}）',
    );
    return text;
  }

  void _throwIfFailed(HttpResult res, {required String what}) {
    final failure = failureOf(res);
    if (failure == null) return;
    diag.warn(
      '字幕',
      'OpenSubtitles $what失败：${failure.name} '
      'HTTP ${res.statusCode} ${res.businessMessage ?? res.rawBody}',
    );
    throw OpenSubtitlesException(
      failure,
      _messageFor(failure, res),
      statusCode: res.statusCode,
    );
  }

  /// **纯函数**：判定一次响应是不是失败、是哪一种。成功返回 `null`。
  ///
  /// 单独抽出来是因为它是这个文件里**唯一**必须被实测钉住的东西 ——
  /// 状态码与响应体的对应关系在这套 API 上完全反直觉（见类文档）。
  static OpenSubtitlesFailure? failureOf(HttpResult res) {
    if (res.isNetworkFailure) return OpenSubtitlesFailure.network;

    final status = res.statusCode;
    if (status >= 200 && status < 300) return null;
    if (status == 429) return OpenSubtitlesFailure.quotaExceeded;

    if (status == 403) {
      // ⚠️ 两个完全不同的原因共用 403，只能看响应体。
      final error = '${res.json?['error'] ?? ''}'.toLowerCase();
      return error.contains('user agent')
          ? OpenSubtitlesFailure.missingUserAgent
          : OpenSubtitlesFailure.badApiKey;
    }

    if (status >= 500) return OpenSubtitlesFailure.server;
    // 剩下的（含实测见过的 301 —— 完全没带 Api-Key 时）都归到「响应不对」，
    // 不猜它是哪一种：猜错会把用户指向错误的排查方向。
    return OpenSubtitlesFailure.badResponse;
  }

  static String _messageFor(OpenSubtitlesFailure failure, HttpResult res) =>
      switch (failure) {
        OpenSubtitlesFailure.notConfigured =>
          '还没填 OpenSubtitles 的 Api-Key（设置页 → 在线字幕）',
        OpenSubtitlesFailure.missingUserAgent =>
          '请求没带 User-Agent，被接口拒绝（这是程序的问题）',
        OpenSubtitlesFailure.badApiKey =>
          'OpenSubtitles 的 Api-Key 不被接受，去设置页检查一下',
        OpenSubtitlesFailure.quotaExceeded =>
          'OpenSubtitles 今天的下载额度用完了（HTTP 429）',
        OpenSubtitlesFailure.network => '连不上 OpenSubtitles（网络问题）',
        OpenSubtitlesFailure.server => 'OpenSubtitles 服务端出错，稍后再试',
        OpenSubtitlesFailure.badResponse =>
          'OpenSubtitles 的响应读不懂（HTTP ${res.statusCode}）',
      };

  /// 解析 `/subtitles` 的响应。**成功形状尚未实测**（手上没有有效 key），
  /// 是按官方文档写的 —— 第一次有 key 时要回来核对 `files[].file_id` 这层。
  static List<OnlineSubtitleHit> parseSearch(Map<String, Object?> json) {
    final data = json['data'];
    if (data is! List) return const <OnlineSubtitleHit>[];

    final hits = <OnlineSubtitleHit>[];
    for (final item in data) {
      if (item is! Map<String, Object?>) continue;
      final attrs = item['attributes'];
      if (attrs is! Map<String, Object?>) continue;

      // ⚠️ `file_id` 在 `attributes.files[]` 里，而且**可能有多条文件**。
      // 取第一条：搜索结果的一个条目通常只挂一个文件，而多出来的那些往往是
      // 同一个字幕的不同文件名写法。
      final files = attrs['files'];
      final first = files is List && files.isNotEmpty ? files.first : null;
      final fileId = first is Map ? _asInt(first['file_id']) : null;
      if (fileId == null) continue;

      final feature = attrs['feature_details'];
      hits.add(
        OnlineSubtitleHit(
          fileId: fileId,
          fileName: '${first?['file_name'] ?? ''}',
          language: attrs['language'] is String ? attrs['language'] as String : null,
          title: feature is Map ? _asStr(feature['title']) : _asStr(attrs['movie_name']),
          release: _asStr(attrs['release']),
          downloadCount: _asInt(attrs['download_count']) ?? 0,
          rating: _asDouble(attrs['ratings']),
          hearingImpaired: attrs['hearing_impaired'] == true,
          foreignPartsOnly: attrs['foreign_parts_only'] == true,
          season: feature is Map ? _asInt(feature['season_number']) : null,
          episode: feature is Map ? _asInt(feature['episode_number']) : null,
        ),
      );
    }
    return hits;
  }

  /// 解析 `/download` 的响应。没有 `link` 时返回 null ——
  /// 那不是「成功但为空」，是响应不对。
  static OnlineSubtitleDownload? parseDownload(Map<String, Object?> json) {
    final link = json['link'];
    if (link is! String || link.isEmpty) return null;
    return OnlineSubtitleDownload(
      link: link,
      fileName: '${json['file_name'] ?? ''}',
      remaining: _asInt(json['remaining']),
      resetTime: _asStr(json['reset_time']),
    );
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  static double? _asDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v');

  static String? _asStr(Object? v) {
    final s = '$v'.trim();
    return s.isEmpty || s == 'null' ? null : s;
  }
}
