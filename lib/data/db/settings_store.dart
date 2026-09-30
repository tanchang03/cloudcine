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

  /// 是否启用在线刮削
  static const String onlineScrape = 'online_scrape';

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
