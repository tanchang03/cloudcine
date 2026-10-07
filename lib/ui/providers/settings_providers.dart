import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/settings_store.dart';
import '../../domain/entities/download_task.dart';
import '../../domain/services/follow_auto_check.dart';
import '../../domain/services/folder_sort.dart';
import '../../domain/services/item_sort.dart';
import 'app_providers.dart';

/// 应用设置的只读快照。
///
/// 做成一个不可变值而不是「一个设置一个 provider」：设置页要一次显示九项，
/// 九个 provider 会让页面重建九次，也让「哪些设置存在」这件事没有单一真源。
class AppSettings {
  const AppSettings({
    this.onlineScrape = false,
    this.autoScrapeOnScan = false,
    this.followAutoCheck = FollowAutoCheck.onLaunch,
    this.autoMergeByOnlineId = true,
    this.tmdbApiKey = '',
    this.tmdbApiBase = '',
    this.tmdbImageBase = '',
    this.doubanCookie = '',
    this.opensubtitlesApiKey = '',
    this.opensubtitlesBase = '',
    this.defaultQuality = '',
    this.autoLoadSubtitles = true,
    this.rememberPosition = true,
    this.autoPlayNext = true,
    this.skipIntro = true,
    this.playerVolume = 100,
    this.playerRate = 1,
    this.scanIntervalMs = 350,
    this.scanMaxDepth = 12,
    this.lastScanAt,
    this.logLevel = 'info',
    this.debugOverlay = false,
    this.streamRelay = true,
    this.relayConnections = 8,
    this.folderSortMode = FolderSortMode.modifiedTime,
    this.itemSortMode = ItemSortMode.modifiedDesc,
    this.downloadConcurrency = kDefaultDownloadConcurrency,
  });

  /// 是否允许联网刮削（总开关）。
  ///
  /// 关掉之后**一条在线请求都不会发**：扫描期不刮，详情页的「刮削」按钮
  /// 也是灰的。想做「完全离线」就关它。
  final bool onlineScrape;

  /// 扫描结束后是否自动刮一遍。**默认关**，理由见
  /// `SettingKeys.autoScrapeOnScan`（豆瓣额度小、耗尽后整批失败）。
  final bool autoScrapeOnScan;

  /// **追剧自动检查**的策略：`off` / `on_launch`（默认）/ `every_6h`。
  ///
  /// 与 `autoScrapeOnScan` 不同，这一项默认**开**（`on_launch`）—— 追更检查
  /// 只列已追剧作品名下那几个目录（去重后通常 1~5 个），秒级完成，而它的
  /// 全部意义就是「不用自己想起来去查」。默认关的话这个功能等于不存在。
  ///
  /// ## ⛔ 它是三态，不是布尔
  ///
  /// 「每 6 小时查一次」这个档位没法用 `bool` 表达。硬塞成布尔的话，
  /// 用户要么每次启动都查、要么永远不查 —— 而「挂着不动也想查」是个
  /// 真实诉求（书房里常开机的 Mac mini）。
  ///
  /// ⛔ 判据（含默认值）只在 `FollowAutoCheck.parse` 一处，这里**不要**再写
  ///    一遍 `== 'on_launch'`：两处会漂开，症状是「设置页选了关闭，重启
  ///    之后又开始检查了」。
  final FollowAutoCheck followAutoCheck;

  /// 刮到同一条目的几部作品是否自动折成一部（跨目录归一）。**默认开**。
  ///
  /// 理由（默认值为什么与上一项相反）见 `SettingKeys.autoMergeByOnlineId`：
  /// 它不发网络请求，而且误合是可一键撤销的。
  final bool autoMergeByOnlineId;

  /// TMDB API Key（v3 或 v4）。空串表示未配置。
  final String tmdbApiKey;

  /// TMDB API 的 Base URL。空串 = 用官方地址。
  ///
  /// 2026-10-01 实测：境内直连 `api.themoviedb.org` 会被 DNS 污染
  /// （HTTP 000、20s 超时），在线刮削永远拿不到结果。留这个口子给可达的反代。
  /// 「空串 → 官方地址」的换算放在 `buildScanService` 里做，
  /// 这样默认值只有 `TmdbScraper` 一个真源。
  final String tmdbApiBase;

  /// TMDB 图片 CDN 的 Base URL。空串 = 用官方地址。
  ///
  /// 与 [tmdbApiBase] **分开配置**：两者是不同域名
  /// （`api.themoviedb.org` / `image.tmdb.org`），反代经常只覆盖其中一个。
  final String tmdbImageBase;

  /// 豆瓣登录后的 Cookie。空串 = 不启用豆瓣源。
  ///
  /// 实测匿名额度只有约 10 个搜索词，所以要求配 Cookie 才算可用
  /// （见 `SettingKeys.doubanCookie`）。
  final String doubanCookie;

  /// OpenSubtitles 的 Api-Key。空串 = 在线字幕不可用。
  ///
  /// 与 TMDB / 豆瓣那两个源不同，它**不是刮削源**：它只服务播放器里的
  /// 「在线字幕」。所以它不进 [canScrapeOnline] 的判据 —— 混进去会让
  /// 「没填字幕站的 Key」表现成「刮削被关掉了」。
  final String opensubtitlesApiKey;

  /// OpenSubtitles 的 Base URL。空串 = 用官方地址。
  ///
  /// 与 [tmdbApiBase] 同一个理由：留一个口子给可达的反代。
  /// 「空串 → 官方地址」的换算在 `player_bridge_host.dart` 里做，
  /// 这样默认值只有 `OpenSubtitlesConfig.defaultBaseUrl` 一个真源。
  final String opensubtitlesBase;

  /// 在线字幕是否**真的**能用：填了 Api-Key 才算。
  ///
  /// 合成一个判断而不是让调用方各自判空串：没填 Key 时接口一律 403，
  /// 而 403 的文案（「You cannot consume this service」）与「服务不可用」
  /// 长得一样 —— 用户会去换地址而不是填 Key。
  bool get canSearchOnlineSubtitles => opensubtitlesApiKey.trim().isNotEmpty;

  /// 默认清晰度档位标识。空串 = 原画优先。
  final String defaultQuality;

  final bool autoLoadSubtitles;
  final bool rememberPosition;

  /// 一集播完是否自动播下一集。**默认开**，理由见
  /// `SettingKeys.autoPlayNext`（这一项没有代价，而它的全部意义就是
  /// 「躺在沙发上看完一整季」）。
  ///
  /// 「下一集是哪一条」由 `EpisodeQueue.nextAfter` 决定，两个播放器共用：
  /// 往后扫、跳过花絮、不循环、当前项不在列表时**绝不从头开始**。
  final bool autoPlayNext;

  /// 有片头标识时是否自动跳过片头。**默认开**。
  ///
  /// 区间来源两路：文件内章节名（`IntroMarkerDetector`）优先，用户手标的
  /// 区间（`MediaWork.introRange`）兜底。两路都没有时这条规则空转，
  /// 所以开着它不会误跳。
  final bool skipIntro;

  final double playerVolume;
  final double playerRate;

  /// 列目录请求的最小间隔（毫秒）。350ms ≈ 2.9 QPS。
  final int scanIntervalMs;

  final int scanMaxDepth;
  final DateTime? lastScanAt;
  final String logLevel;

  /// 是否在右上角常驻显示实时调试指标浮层。**默认关**。
  ///
  /// 理由见 `SettingKeys.debugOverlay`：它是排查工具而不是功能，默认占着画面
  /// 只会挡视线。关掉时那个浮层**根本不会被创建**（不是隐藏），所以定时器
  /// 与逐帧回调都不存在 —— 不打开就没有开销。
  final bool debugOverlay;

  /// 播网盘原画时是否走本地中继（多连接并发预取）。**默认开**，理由见
  /// `SettingKeys.streamRelay`。
  ///
  /// 关掉只会退回「直连播放」这个老行为 —— 中继建不起来时走的也是这条路，
  /// 所以这一项**永远不可能让视频播不了**。
  final bool streamRelay;

  /// 本地中继的并发连接数。改它**只影响之后新建的会话**，正在播的不受影响。
  final int relayConnections;

  /// 目录视图（「文件夹」）列表的排序方式。**默认按修改时间倒序**。
  ///
  /// 它是一个**默认值**而不是「当前视图的状态」：目录视图工具条上的切换
  /// 直接改的就是它（两处读写同一个设置，见 `folderSortModeProvider`）。
  /// 做成一份而不是两份的理由 —— 用户把「名称」设成习惯之后，下次打开
  /// 目录视图却又是按时间排的，那种「设置没生效」比没有设置更让人费解。
  final FolderSortMode folderSortMode;

  /// 作品详情页「文件」列表的排序方式。**默认按修改时间倒序**。
  ///
  /// 与 [folderSortMode] 分开存（理由见 `SettingKeys.itemSortMode`）：两者排的
  /// 是两种东西（网盘实时目录 / 已入库的媒体文件）。
  ///
  /// ⚠️ 它**不影响「点播放会播哪一集」**。那个目标由 `PlayTarget.resolve`
  /// 按「续播点 → 播过的那集 → 第一集」决定，与列表显示顺序无关 ——
  /// 让播放按钮跟着排序走的话，切一次「时间倒序」就会变成「点播放播最新
  /// 上传的那个文件」，而那几乎从不是用户想要的。
  final ItemSortMode itemSortMode;

  /// 同时最多跑几个下载任务。默认 5，上限 10。
  ///
  /// ## 它**不**等同于 [relayConnections]
  ///
  /// 那一项是「一条流内部开几条连接」（为了播得动），这一项是「同时下几个
  /// 文件」。合成一个的话，用户为了多下几个文件把它调大，会顺手把播放那条流
  /// 也改成十几路并发 —— 而两者对网盘的压力完全不同。
  ///
  /// 改它只影响**之后**的调度：已经跑着的任务不会被掐断，新空出来的并发位
  /// 才会按新值分配（见 `DownloadQueue.pump`）。理由与中继那一项一致 ——
  /// 拨一下滑块就把正在下的东西停掉，是没人预料得到的因果。
  final int downloadConcurrency;

  /// 在线刮削是否**真的**能用：总开关打开 **且** 至少配了一个数据源。
  ///
  /// 两个条件缺一不可，而 UI 上必须把它们合成一个判断 —— 只开开关不填
  /// Key（或豆瓣 Cookie）是最容易发生的一种「我明明开了刮削怎么没海报」。
  ///
  /// 「至少一个源」而不是「TMDB 一定有」：TMDB 在境内不可达，只用豆瓣
  /// 是完全正当的用法。
  bool get canScrapeOnline =>
      onlineScrape && (tmdbApiKey.trim().isNotEmpty || doubanCookie.trim().isNotEmpty);

  /// 扫描结束后是否**真的**会自动刮：还要 [autoScrapeOnScan] 也打开。
  ///
  /// 与 [canScrapeOnline] 一样合成一个判断，避免「开关是开的但没源」
  /// 这种看起来生效、实际什么都没发生的情况。
  bool get canAutoScrape => canScrapeOnline && autoScrapeOnScan;

  AppSettings copyWith({
    bool? onlineScrape,
    bool? autoScrapeOnScan,
    FollowAutoCheck? followAutoCheck,
    bool? autoMergeByOnlineId,
    String? tmdbApiKey,
    String? tmdbApiBase,
    String? tmdbImageBase,
    String? doubanCookie,
    String? opensubtitlesApiKey,
    String? opensubtitlesBase,
    String? defaultQuality,
    bool? autoLoadSubtitles,
    bool? rememberPosition,
    bool? autoPlayNext,
    bool? skipIntro,
    double? playerVolume,
    double? playerRate,
    int? scanIntervalMs,
    int? scanMaxDepth,
    DateTime? lastScanAt,
    String? logLevel,
    bool? debugOverlay,
    bool? streamRelay,
    int? relayConnections,
    FolderSortMode? folderSortMode,
    ItemSortMode? itemSortMode,
    int? downloadConcurrency,
  }) {
    return AppSettings(
      onlineScrape: onlineScrape ?? this.onlineScrape,
      autoScrapeOnScan: autoScrapeOnScan ?? this.autoScrapeOnScan,
      followAutoCheck: followAutoCheck ?? this.followAutoCheck,
      autoMergeByOnlineId: autoMergeByOnlineId ?? this.autoMergeByOnlineId,
      tmdbApiKey: tmdbApiKey ?? this.tmdbApiKey,
      tmdbApiBase: tmdbApiBase ?? this.tmdbApiBase,
      tmdbImageBase: tmdbImageBase ?? this.tmdbImageBase,
      doubanCookie: doubanCookie ?? this.doubanCookie,
      opensubtitlesApiKey: opensubtitlesApiKey ?? this.opensubtitlesApiKey,
      opensubtitlesBase: opensubtitlesBase ?? this.opensubtitlesBase,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      autoLoadSubtitles: autoLoadSubtitles ?? this.autoLoadSubtitles,
      rememberPosition: rememberPosition ?? this.rememberPosition,
      autoPlayNext: autoPlayNext ?? this.autoPlayNext,
      skipIntro: skipIntro ?? this.skipIntro,
      playerVolume: playerVolume ?? this.playerVolume,
      playerRate: playerRate ?? this.playerRate,
      scanIntervalMs: scanIntervalMs ?? this.scanIntervalMs,
      scanMaxDepth: scanMaxDepth ?? this.scanMaxDepth,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      logLevel: logLevel ?? this.logLevel,
      debugOverlay: debugOverlay ?? this.debugOverlay,
      streamRelay: streamRelay ?? this.streamRelay,
      relayConnections: relayConnections ?? this.relayConnections,
      folderSortMode: folderSortMode ?? this.folderSortMode,
      itemSortMode: itemSortMode ?? this.itemSortMode,
      downloadConcurrency: downloadConcurrency ?? this.downloadConcurrency,
    );
  }

  /// 从数据库读出的原始键值对构造。
  ///
  /// ## 为什么值得抽成一个纯函数
  ///
  /// 这里有一组**刻意不对称**的默认值，而它们在代码里长得几乎一样：
  ///
  ///   - `autoScrapeOnScan` 缺失即 `false`（产品决定：默认**不**自动刮）
  ///   - `autoLoadSubtitles` / `rememberPosition` / `autoPlayNext` /
  ///     `skipIntro` 缺失即 `true`（与播放器的缺省行为一致）
  ///
  /// 判据因此必须写成两种形式（`== 'true'` 与 `!= 'false'`），写反了
  /// **不报错**，只会表现成「新装用户字幕不加载」或者「没打开开关却自动
  /// 刮了一整盘、豆瓣额度当场耗尽」。抽出来才钉得住。
  factory AppSettings.fromValues(Map<String, String?> v) {
    return AppSettings(
      onlineScrape: v[SettingKeys.onlineScrape] == 'true',
      // 缺失即 `false`：自动刮削**默认关**，这是产品决定而不是实现细节，
      // 所以判据写成「等于 true」而不是「不等于 false」。
      autoScrapeOnScan: v[SettingKeys.autoScrapeOnScan] == 'true',
      // 追剧自动检查：三态，判据（含默认 `on_launch`）只在
      // `FollowAutoCheck.parse` 一处。这里写 `==` 是**错的** ——
      // 它是一个枚举名而不是布尔串，写成布尔判断会让 `every_6h` 静默退化成
      // 默认值（表现是「选了每 6 小时，实际只在启动时查一次」）。
      followAutoCheck: FollowAutoCheck.parse(v[SettingKeys.followAutoCheck]),
      // ⚠️ 与上一行**刻意相反**：这一项缺失即 `true`，所以判据必须写成
      // 「不等于 false」。写反的后果不是报错，而是「新装用户永远不合库」
      // —— 一个没人会想到去查的默认值问题。理由见
      // `SettingKeys.autoMergeByOnlineId`。
      autoMergeByOnlineId: v[SettingKeys.autoMergeByOnlineId] != 'false',
      tmdbApiKey: v[SettingKeys.tmdbApiKey] ?? '',
      tmdbApiBase: v[SettingKeys.tmdbApiBase] ?? '',
      tmdbImageBase: v[SettingKeys.tmdbImageBase] ?? '',
      doubanCookie: v[SettingKeys.doubanCookie] ?? '',
      // 空串 = 在线字幕不可用。**刻意没有默认值**：这是一项要用户自己去
      // 申请的服务，塞一个占位值只会让第一次搜索得到一个 403。
      opensubtitlesApiKey: v[SettingKeys.opensubtitlesApiKey] ?? '',
      opensubtitlesBase: v[SettingKeys.opensubtitlesBase] ?? '',
      defaultQuality: v[SettingKeys.defaultQuality] ?? '',
      // 缺失时取 `true`：默认自动加载字幕，与 `PlaybackController` 的
      // 缺省行为保持一致。两处不一致会出现「设置页显示开、实际没加载」。
      autoLoadSubtitles: v[SettingKeys.autoLoadSubtitles] != 'false',
      rememberPosition: v[SettingKeys.rememberPosition] != 'false',
      // 连播与跳片头同属「缺失即开」这一族，判据也必须是 `!= 'false'`。
      //
      // ⚠️ 连播**不**依赖 `rememberPosition`：即使关了「记住进度」，
      // 一集播完照样该接下一集。把两者绑在一起（`rememberPosition &&
      // autoPlayNext`）看着省事，实际会造出「关了记住进度就再也不连播」
      // 这种没人预料得到的联动。
      autoPlayNext: v[SettingKeys.autoPlayNext] != 'false',
      skipIntro: v[SettingKeys.skipIntro] != 'false',
      playerVolume: double.tryParse(v[SettingKeys.playerVolume] ?? '') ?? 100,
      playerRate: double.tryParse(v[SettingKeys.playerRate] ?? '') ?? 1,
      scanIntervalMs: int.tryParse(v[SettingKeys.scanIntervalMs] ?? '') ?? 350,
      scanMaxDepth: int.tryParse(v[SettingKeys.scanMaxDepth] ?? '') ?? 12,
      lastScanAt: DateTime.tryParse(v[SettingKeys.lastScanAt] ?? ''),
      logLevel: v[SettingKeys.logLevel] ?? 'info',
      // ⚠️ 与紧邻的 `streamRelay` **刻意相反**：这一项缺失即**关**，判据必须
      // 写成「等于 true」。写反的后果是每个用户一装上就顶着一排数字，
      // 而设置页的开关是关着的（理由见 `SettingKeys.debugOverlay`）。
      debugOverlay: v[SettingKeys.debugOverlay] == 'true',
      // 中继两项都是「缺失即用默认」，判据与 autoPlayNext 同族。
      streamRelay: v[SettingKeys.streamRelay] != 'false',
      // 卡在 1..16：0 条会让流根本下不来（open 直接返回 null，等于静默关掉
      // 中继），而几十条一定会触发网盘风控 —— 两种都是「用户只是想调快点，
      // 结果变成了别的故障」。
      relayConnections:
          (int.tryParse(v[SettingKeys.relayConnections] ?? '') ?? 8)
              .clamp(1, 16)
              .toInt(),
      // 目录视图排序。判据（含默认值）只在 `FolderSortMode.parse` 一处 ——
      // 读不懂的值一律退回「修改时间倒序」，不抛异常。
      folderSortMode: FolderSortMode.parse(v[SettingKeys.folderSortMode]),
      // 详情页文件列表排序。同上：判据只在 `ItemSortMode.parse` 一处。
      itemSortMode: ItemSortMode.parse(v[SettingKeys.itemSortMode]),
      // 并发下载数。卡在 1..10：0 会让下载队列空转（永远没有空位），
      // 而几十个并发大文件一定会触发网盘风控 —— 两种都是「用户只是想快点，
      // 结果变成了别的故障」。与 `relayConnections` 同一套写法。
      downloadConcurrency:
          (int.tryParse(v[SettingKeys.downloadConcurrency] ?? '') ??
                  kDefaultDownloadConcurrency)
              .clamp(1, kMaxDownloadConcurrency)
              .toInt(),
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
      SettingKeys.autoScrapeOnScan,
      SettingKeys.followAutoCheck,
      SettingKeys.autoMergeByOnlineId,
      SettingKeys.tmdbApiKey,
      SettingKeys.tmdbApiBase,
      SettingKeys.tmdbImageBase,
      SettingKeys.doubanCookie,
      SettingKeys.opensubtitlesApiKey,
      SettingKeys.opensubtitlesBase,
      SettingKeys.defaultQuality,
      SettingKeys.autoLoadSubtitles,
      SettingKeys.rememberPosition,
      SettingKeys.autoPlayNext,
      SettingKeys.skipIntro,
      SettingKeys.playerVolume,
      SettingKeys.playerRate,
      SettingKeys.scanIntervalMs,
      SettingKeys.scanMaxDepth,
      SettingKeys.lastScanAt,
      SettingKeys.logLevel,
      SettingKeys.debugOverlay,
      SettingKeys.streamRelay,
      SettingKeys.relayConnections,
      SettingKeys.folderSortMode,
      SettingKeys.itemSortMode,
      SettingKeys.downloadConcurrency,
    ]);

    return AppSettings.fromValues(v);
  }

  /// 批量写。只处理传进来的字段。
  Future<void> set({
    bool? onlineScrape,
    bool? autoScrapeOnScan,
    FollowAutoCheck? followAutoCheck,
    bool? autoMergeByOnlineId,
    String? tmdbApiKey,
    String? tmdbApiBase,
    String? tmdbImageBase,
    String? doubanCookie,
    String? opensubtitlesApiKey,
    String? opensubtitlesBase,
    String? defaultQuality,
    bool? autoLoadSubtitles,
    bool? rememberPosition,
    bool? autoPlayNext,
    bool? skipIntro,
    double? playerVolume,
    double? playerRate,
    int? scanIntervalMs,
    int? scanMaxDepth,
    String? logLevel,
    bool? debugOverlay,
    bool? streamRelay,
    int? relayConnections,
    FolderSortMode? folderSortMode,
    ItemSortMode? itemSortMode,
    int? downloadConcurrency,
  }) async {
    final store = ref.read(settingsStoreProvider);
    final current = state.valueOrNull ?? const AppSettings();

    if (onlineScrape != null) {
      await store.writeBool(SettingKeys.onlineScrape, onlineScrape);
    }
    if (autoScrapeOnScan != null) {
      await store.writeBool(SettingKeys.autoScrapeOnScan, autoScrapeOnScan);
    }
    if (followAutoCheck != null) {
      // ⛔ 写 `id`（`off` / `on_launch` / `every_6h`）而不是 `toString()` ——
      //    枚举名与落库值刻意不同（`onLaunch` vs `on_launch`），写错了
      //    另一端解析不出来、只能退回默认值，而且不报错。
      await store.write(SettingKeys.followAutoCheck, followAutoCheck.id);
    }
    if (autoMergeByOnlineId != null) {
      await store.writeBool(
        SettingKeys.autoMergeByOnlineId,
        autoMergeByOnlineId,
      );
    }
    if (tmdbApiKey != null) {
      await store.write(SettingKeys.tmdbApiKey, tmdbApiKey.trim());
    }
    if (tmdbApiBase != null) {
      await store.write(SettingKeys.tmdbApiBase, tmdbApiBase.trim());
    }
    if (tmdbImageBase != null) {
      await store.write(SettingKeys.tmdbImageBase, tmdbImageBase.trim());
    }
    if (doubanCookie != null) {
      await store.write(SettingKeys.doubanCookie, doubanCookie.trim());
    }
    if (opensubtitlesApiKey != null) {
      await store.write(
        SettingKeys.opensubtitlesApiKey,
        opensubtitlesApiKey.trim(),
      );
    }
    if (opensubtitlesBase != null) {
      await store.write(SettingKeys.opensubtitlesBase, opensubtitlesBase.trim());
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
    if (autoPlayNext != null) {
      await store.writeBool(SettingKeys.autoPlayNext, autoPlayNext);
    }
    if (skipIntro != null) {
      await store.writeBool(SettingKeys.skipIntro, skipIntro);
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
    if (debugOverlay != null) {
      await store.writeBool(SettingKeys.debugOverlay, debugOverlay);
    }
    if (streamRelay != null) {
      await store.writeBool(SettingKeys.streamRelay, streamRelay);
    }
    if (relayConnections != null) {
      await store.write(
        SettingKeys.relayConnections,
        '${relayConnections.clamp(1, 16)}',
      );
    }
    if (folderSortMode != null) {
      await store.write(SettingKeys.folderSortMode, folderSortMode.value);
    }
    if (itemSortMode != null) {
      await store.write(SettingKeys.itemSortMode, itemSortMode.value);
    }
    if (downloadConcurrency != null) {
      await store.write(
        SettingKeys.downloadConcurrency,
        '${downloadConcurrency.clamp(1, kMaxDownloadConcurrency)}',
      );
    }

    state = AsyncData(
      current.copyWith(
        onlineScrape: onlineScrape,
        autoScrapeOnScan: autoScrapeOnScan,
        followAutoCheck: followAutoCheck,
        autoMergeByOnlineId: autoMergeByOnlineId,
        tmdbApiKey: tmdbApiKey?.trim(),
        tmdbApiBase: tmdbApiBase?.trim(),
        tmdbImageBase: tmdbImageBase?.trim(),
        doubanCookie: doubanCookie?.trim(),
        opensubtitlesApiKey: opensubtitlesApiKey?.trim(),
        opensubtitlesBase: opensubtitlesBase?.trim(),
        defaultQuality: defaultQuality,
        autoLoadSubtitles: autoLoadSubtitles,
        rememberPosition: rememberPosition,
        autoPlayNext: autoPlayNext,
        skipIntro: skipIntro,
        playerVolume: playerVolume,
        playerRate: playerRate,
        scanIntervalMs: scanIntervalMs,
        scanMaxDepth: scanMaxDepth,
        logLevel: logLevel,
        debugOverlay: debugOverlay,
        streamRelay: streamRelay,
        relayConnections: relayConnections?.clamp(1, 16).toInt(),
        folderSortMode: folderSortMode,
        itemSortMode: itemSortMode,
        downloadConcurrency:
            downloadConcurrency?.clamp(1, kMaxDownloadConcurrency).toInt(),
      ),
    );
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
