import 'package:drift/drift.dart';

import 'app_database.dart';

/// 设置键的唯一真源。
///
/// 全部集中在这里而不是散在各处写字符串字面量：键名打错的表现是
/// 「设置不生效」且**不报错**（读不到就退回默认值），是最难查的一类 bug。
class SettingKeys {
  const SettingKeys._();

  /// TMDB API Key（v3 或 v4 都接受）。空串表示不启用在线刮削。
  static const String tmdbApiKey = 'tmdb_api_key';

  /// TMDB API 的 Base URL。留空 = 用官方 `https://api.themoviedb.org/3`。
  ///
  /// ## 为什么要有这个设置
  ///
  /// 2026-10-01 实测：`api.themoviedb.org` 与 `image.tmdb.org` 在境内**不可达**
  /// （HTTP 000、20s 超时），而 `www.themoviedb.org`、`api.github.com` 都是 200
  /// —— 典型的 DNS 污染，**不是**「境外站一概不通」。后果是**在线刮削永远拿不到
  /// 结果**，真海报这条路彻底走不通，只能退回夸克的视频帧。
  ///
  /// `TmdbScraper` 的 `baseUrl` / `imageBaseUrl` 本来就是构造参数，
  /// 所以这里只需要让用户能填一个可达的反代地址，不用改刮削器本身。
  static const String tmdbApiBase = 'tmdb_api_base';

  /// TMDB 图片 CDN 的 Base URL。留空 = 用官方 `https://image.tmdb.org/t/p`。
  ///
  /// 必须与 [tmdbApiBase] **分开配置**：两者是不同域名
  /// （`api.themoviedb.org` / `image.tmdb.org`），而反代经常只覆盖其中一个。
  /// 合成一个的话，「API 通了但图片下不来」就没法修。
  static const String tmdbImageBase = 'tmdb_image_base';

  /// 是否启用在线刮削
  static const String onlineScrape = 'online_scrape';

  /// 扫描结束后是否**自动**跑一遍在线刮削。
  ///
  /// ## 默认关，而且是刻意关的
  ///
  /// 刮削的默认入口是**详情页的「刮削」按钮**（按需、一次一部）。
  /// 自动刮削对 TMDB 没坏处（额度宽），但对**豆瓣**有害：匿名额度实测只有
  /// 约 10 个搜索词，一次全盘扫描（145 部作品、每部最多 2 个词）必然中途
  /// 耗尽，而耗尽之后是 `103 need_login` —— 用户看到的是「豆瓣一条都刮不到」，
  /// 并且这个 IP 短时间内都用不了。
  ///
  /// 所以把「自动」做成显式选择：想要省事就在设置里打开，代价是更可能被风控。
  static const String autoScrapeOnScan = 'auto_scrape_on_scan';

  /// 豆瓣登录后的 Cookie。空串表示不启用豆瓣源。
  ///
  /// ## 为什么豆瓣必须配 Cookie 才能用
  ///
  /// 匿名额度实测约 **10 个不同的搜索词**，之后接口返回
  /// `{"code":103,"msg":"need_login"}`（显式错误，不是空结果）。
  /// 登录态额度宽得多。所以 `DoubanScraper.isEnabled` 要求这个值非空 ——
  /// 不给「配了也必然失败」的默认。
  ///
  /// 与 TMDB 的 API Key 一样存在本地数据库里（不是钥匙串）：它只是一个
  /// 会话 Cookie，不是账号密码，而放进钥匙串会让「设置页显示」多一层异步。
  static const String doubanCookie = 'douban_cookie';

  /// OpenSubtitles 的 Api-Key。空串表示不启用在线字幕搜索。
  ///
  /// ## 为什么只放 key、不放账号密码
  ///
  /// 登录能换来更高的下载额度，但**密码是凭证**，而这个项目的规矩是凭证必须进
  /// 系统钥匙串（`SecureCredentialStore`），而钥匙串那一层目前是按
  /// `DriveProvider` 索引的 —— 为了一个字幕站去改它，代价与收益不成比例。
  /// 所以先只支持 Api-Key（与 TMDB 同级，本来就在数据库里）。
  ///
  /// ## 额度
  ///
  /// 匿名（只带 key）的下载额度按天重置且很小。`/download` 的响应里带
  /// `remaining` / `reset_time`，**界面必须把它显示出来** —— 否则「今天下不了」
  /// 会被读成「这个功能坏了」。
  static const String opensubtitlesApiKey = 'opensubtitles_api_key';

  /// OpenSubtitles API 的 Base URL。留空 = 用官方
  /// `https://api.opensubtitles.com/api/v1`。
  ///
  /// 与 [tmdbApiBase] 同理：境内用户可能要指向反代。但注意**这一家境内是通的**
  /// （2026-10-01 实测 `api.opensubtitles.com` 正常响应），所以留空即可，
  /// 这个开关只是留条后路。
  static const String opensubtitlesBase = 'opensubtitles_base';

  /// 上次扫描完成时间（ISO8601）
  static const String lastScanAt = 'last_scan_at';

  /// 默认清晰度档位标识（`origin` / `super` / …）。空串表示「原画优先」。
  static const String defaultQuality = 'default_quality';

  /// 是否优先自动加载中文字幕
  static const String preferChineseSubtitle = 'prefer_zh_subtitle';

  /// 是否自动加载外挂字幕（关闭则要用户手动选）
  static const String autoLoadSubtitles = 'auto_load_subtitles';

  /// 播放器音量（0..1 的字符串）
  static const String playerVolume = 'player_volume';

  /// 播放倍速（如 `1.0`）
  static const String playerRate = 'player_rate';

  /// 是否记住播放进度
  static const String rememberPosition = 'remember_position';

  /// 扫描节流间隔（毫秒）。默认 350ms ≈ 2.9 QPS。
  static const String scanIntervalMs = 'scan_interval_ms';

  /// 扫描最大深度
  static const String scanMaxDepth = 'scan_max_depth';

  /// 诊断日志级别（`debug` / `info` / `warn` / `error`）
  static const String logLevel = 'log_level';
}

/// 通用键值设置存储。
///
/// 放在数据库里而不是 `SharedPreferences`：设置与索引库是同一份应用数据，
/// 分开存会出现「清了索引但设置还在」「备份了库但设置丢了」这类不一致。
/// 唯一例外是凭证 —— 那个**必须**在系统钥匙串（见 `SecureCredentialStore`）。
class SettingsStore {
  SettingsStore(this._db);

  final AppDatabase _db;

  /// 进程内缓存。
  ///
  /// 设置读得非常频繁（每次重建播放器都读一次默认音量/倍速），
  /// 每次都打一次 SQLite 是纯浪费。写操作会同步更新缓存。
  final Map<String, String?> _cache = {};

  Future<String?> read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    final row = await (_db.select(_db.settings)
          ..where((t) => t.key.equals(key))
          ..limit(1))
        .getSingleOrNull();
    _cache[key] = row?.value;
    return row?.value;
  }

  Future<void> write(String key, String value) async {
    await _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion(key: Value(key), value: Value(value)),
        );
    _cache[key] = value;
  }

  Future<void> remove(String key) async {
    await (_db.delete(_db.settings)..where((t) => t.key.equals(key))).go();
    _cache[key] = null;
  }

  // -------------------------------------------------------------------
  // 类型化读写
  // -------------------------------------------------------------------

  /// 读布尔。**缺失时返回 [fallback]** —— 不是 `false`。
  ///
  /// 这个区别很重要：`autoLoadSubtitles` 的默认值是 `true`，
  /// 如果缺失时返回 `false`，新装用户会发现字幕默认不加载。
  Future<bool> readBool(String key, {bool fallback = false}) async {
    final raw = await read(key);
    if (raw == null) return fallback;
    return raw == 'true' || raw == '1';
  }

  Future<void> writeBool(String key, bool value) =>
      write(key, value ? 'true' : 'false');

  Future<int?> readInt(String key) async {
    final raw = await read(key);
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  Future<double?> readDouble(String key) async {
    final raw = await read(key);
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  Future<DateTime?> readDateTime(String key) async {
    final raw = await read(key);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> writeDateTime(String key, DateTime value) =>
      write(key, value.toIso8601String());

  /// 批量读（一次查询取回多个键）。
  ///
  /// 首屏要读七八个设置，逐个 `read` 就是七八次 SQLite 往返。
  Future<Map<String, String?>> readAll(List<String> keys) async {
    final missing = keys.where((k) => !_cache.containsKey(k)).toList();
    if (missing.isNotEmpty) {
      final rows = await (_db.select(_db.settings)
            ..where((t) => t.key.isIn(missing)))
          .get();
      for (final k in missing) {
        _cache[k] = null;
      }
      for (final row in rows) {
        _cache[row.key] = row.value;
      }
    }
    return {for (final k in keys) k: _cache[k]};
  }
}
