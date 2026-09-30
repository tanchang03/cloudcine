import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/settings_store.dart';
import 'app_providers.dart';

/// 应用设置的只读快照。
///
/// 做成一个不可变值而不是「一个设置一个 provider」：设置页要一次显示九项，
/// 九个 provider 会让页面重建九次，也让「哪些设置存在」这件事没有单一真源。
class AppSettings {
  const AppSettings({
    this.onlineScrape = false,
    this.tmdbApiKey = '',
    this.defaultQuality = '',
    this.autoLoadSubtitles = true,
    this.rememberPosition = true,
    this.playerVolume = 100,
    this.playerRate = 1,
    this.scanIntervalMs = 350,
    this.scanMaxDepth = 12,
    this.lastScanAt,
    this.logLevel = 'info',
  });

  /// 是否启用在线刮削（TMDB）
  final bool onlineScrape;

  /// TMDB API Key（v3 或 v4）。空串表示未配置。
  final String tmdbApiKey;

  /// 默认清晰度档位标识。空串 = 原画优先。
  final String defaultQuality;

  final bool autoLoadSubtitles;
  final bool rememberPosition;
  final double playerVolume;
  final double playerRate;

  /// 列目录请求的最小间隔（毫秒）。350ms ≈ 2.9 QPS。
  final int scanIntervalMs;

  final int scanMaxDepth;
  final DateTime? lastScanAt;
  final String logLevel;

  /// 在线刮削是否**真的**能用：开关打开 **且** 填了 Key。
  ///
  /// 两个条件缺一不可，而 UI 上必须把它们合成一个判断 —— 只开开关不填 Key
  /// 是最容易发生的一种「我明明开了刮削怎么没海报」。
  bool get canScrapeOnline => onlineScrape && tmdbApiKey.trim().isNotEmpty;

  AppSettings copyWith({
    bool? onlineScrape,
    String? tmdbApiKey,
    String? defaultQuality,
    bool? autoLoadSubtitles,
    bool? rememberPosition,
    double? playerVolume,
    double? playerRate,
    int? scanIntervalMs,
    int? scanMaxDepth,
    DateTime? lastScanAt,
    String? logLevel,
  }) {
    return AppSettings(
      onlineScrape: onlineScrape ?? this.onlineScrape,
      tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      autoLoadSubtitles: autoLoadSubtitles ?? this.autoLoadSubtitles,
      rememberPosition: rememberPosition ?? this.rememberPosition,
      playerVolume: playerVolume ?? this.playerVolume,
      playerRate: playerRate ?? this.playerRate,
      scanIntervalMs: scanIntervalMs ?? this.scanIntervalMs,
      scanMaxDepth: scanMaxDepth ?? this.scanMaxDepth,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      logLevel: logLevel ?? this.logLevel,
    );
  }
}

/// 设置的读写。
///
/// 每次写入都**立刻把新值反映到内存状态**，而不是写完再 invalidate 重读一遍：
/// 重读要走一次 SQLite + 一次异步重建，开关会「卡半拍」，
/// 用户看到的是「点了没反应」，于是再点一次 —— 状态就翻回去了。
class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final store = ref.watch(settingsStoreProvider);
    final v = await store.readAll(const [
      SettingKeys.onlineScrape,
      SettingKeys.tmdbApiKey,
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
      SettingKeys.rememberPosition,
      SettingKeys.playerVolume,
      SettingKeys.playerRate,
      SettingKeys.scanIntervalMs,
      SettingKeys.scanMaxDepth,
      SettingKeys.lastScanAt,
      SettingKeys.logLevel,
    ]);

    return AppSettings(
      onlineScrape: v[SettingKeys.onlineScrape] == 'true',
      tmdbApiKey: v[SettingKeys.tmdbApiKey] ?? '',
      defaultQuality: v[SettingKeys.defaultQuality] ?? '',
      // 缺失时取 `true`：默认自动加载字幕，与 `PlaybackController` 的
      // 缺省行为保持一致。两处不一致会出现「设置页显示开、实际没加载」。
      autoLoadSubtitles: v[SettingKeys.autoLoadSubtitles] != 'false',
      rememberPosition: v[SettingKeys.rememberPosition] != 'false',
      playerVolume:
          double.tryParse(v[SettingKeys.playerVolume] ?? '') ?? 100,
      playerRate: double.tryParse(v[SettingKeys.playerRate] ?? '') ?? 1,
      scanIntervalMs:
          int.tryParse(v[SettingKeys.scanIntervalMs] ?? '') ?? 350,
      scanMaxDepth: int.tryParse(v[SettingKeys.scanMaxDepth] ?? '') ?? 12,
      lastScanAt: DateTime.tryParse(v[SettingKeys.lastScanAt] ?? ''),
      logLevel: v[SettingKeys.logLevel] ?? 'info',
    );
  }

  /// 批量写。只处理传进来的字段。
  Future<void> set({
    bool? onlineScrape,
    String? tmdbApiKey,
    String? defaultQuality,
    bool? autoLoadSubtitles,
    bool? rememberPosition,
    double? playerVolume,
    double? playerRate,
    int? scanIntervalMs,
    int? scanMaxDepth,
    String? logLevel,
  }) async {
    final store = ref.read(settingsStoreProvider);
    final current = state.valueOrNull ?? const AppSettings();

    if (onlineScrape != null) {
      await store.writeBool(SettingKeys.onlineScrape, onlineScrape);
    }
    if (tmdbApiKey != null) {
      await store.write(SettingKeys.tmdbApiKey, tmdbApiKey.trim());
    }
    if (defaultQuality != null) {
      await store.write(SettingKeys.defaultQuality, defaultQuality);
    }
    if (autoLoadSubtitles != null) {
      await store.writeBool(SettingKeys.autoLoadSubtitles, autoLoadSubtitles);
    }
    if (rememberPosition != null) {
      await store.writeBool(SettingKeys.rememberPosition, rememberPosition);
    }
    if (playerVolume != null) {
      await store.write(SettingKeys.playerVolume, '$playerVolume');
    }
    if (playerRate != null) {
      await store.write(SettingKeys.playerRate, '$playerRate');
    }
    if (scanIntervalMs != null) {
      await store.write(SettingKeys.scanIntervalMs, '$scanIntervalMs');
    }
    if (scanMaxDepth != null) {
      await store.write(SettingKeys.scanMaxDepth, '$scanMaxDepth');
    }
    if (logLevel != null) {
      await store.write(SettingKeys.logLevel, logLevel);
    }

    state = AsyncData(
      current.copyWith(
        onlineScrape: onlineScrape,
        tmdbApiKey: tmdbApiKey?.trim(),
        defaultQuality: defaultQuality,
        autoLoadSubtitles: autoLoadSubtitles,
        rememberPosition: rememberPosition,
        playerVolume: playerVolume,
        playerRate: playerRate,
        scanIntervalMs: scanIntervalMs,
        scanMaxDepth: scanMaxDepth,
        logLevel: logLevel,
      ),
    );
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
