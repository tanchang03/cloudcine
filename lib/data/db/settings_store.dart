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

  /// 刮到同一条目的几部作品是否**自动折成一部**（跨目录归一）。
  ///
  /// ## 默认**开**，与 `autoScrapeOnScan` 的默认关是刻意的不对称
  ///
  /// 两项的代价完全不同：
  ///
  ///   - 自动刮削会**发网络请求**，而豆瓣的匿名额度约 10 个搜索词，开着
  ///     就可能把整批刮削拖垮 —— 代价不可逆（IP 短期不可用），所以默认关；
  ///   - 自动归一**只动本地库**，不发请求。而且它现在是「打标记」而不是
  ///     「删行」：列表里两个格子变成一个，但源作品的行与文件全部留着，
  ///     撤销是一条 `UPDATE`。误合的代价被压到了「点一下撤销」。
  ///
  /// 判据是 `onlineId` **完全相同**（同一条 TMDB / 豆瓣条目），这是本地能
  /// 拿到的最强信号 —— 本地片名相似度那套**绝不**参与自动合并。
  ///
  /// 关掉它的场景是「我不想让任何东西自动动我的库」：关掉之后仍然可以
  /// 在详情页手动合并。
  static const String autoMergeByOnlineId = 'auto_merge_by_online_id';

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
  /// 系统安全存储（`SecureCredentialStore`），而那一层目前是按
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

  /// 播放器「音效」预设（`auto` / `upmix` / `stereo` / `passthrough`）。
  ///
  /// ## 为什么它要落库，而不是每次播放重新选
  ///
  /// 它描述的是**这台设备怎么接音箱**（笔记本扬声器？HDMI 接功放？），
  /// 那是环境属性，不是「这一部片子的偏好」—— 换一集、换一部片子都不会变。
  /// 夸克播放器也明确写着「会记住常用的画质、**音效**和倍速设置」。
  /// 不记的话，用户每开一个视频都要重新选一次。
  ///
  /// 取值由 `PlayerAudioEffect.parse` 还原；读不懂一律退回 `auto`，
  /// 所以旧版本写坏的值不会让播放器起不来。
  static const String playerAudioEffect = 'player_audio_effect';

  /// 是否记住播放进度
  static const String rememberPosition = 'remember_position';

  /// 一集播完是否**自动播下一集**。
  ///
  /// ## 默认**开**
  ///
  /// 与 [autoScrapeOnScan] 的默认关不同，这一项没有任何代价：它只在
  /// `completed` 事件到来时动一下播放列表的游标，不发请求、不改库。
  /// 默认关的话，用户看剧时每集结束都要拿起遥控器 —— 而这个功能的意义
  /// 恰恰就是「躺在沙发上看完一整季」。
  ///
  /// 需要关掉的真实场景是「看网课 / 看演出录像，每集独立，不想被带着走」。
  static const String autoPlayNext = 'auto_play_next';

  /// 有片头标识时是否**自动跳过片头**。
  ///
  /// ## 默认**开**，判据与 [autoMergeByOnlineId] 同一族（缺失即开）
  ///
  /// 这一项默认开的前提是「没有标识就什么都不做」：片头区间只有两个来源
  /// （文件内章节名、用户手标的区间），两者都没有时这条规则是空转的。
  /// 所以开着它不会误跳 —— 不会出现「看的好好的忽然跳了 90 秒」。
  ///
  /// ⚠️ 判据必须是 `!= 'false'`。写成 `== 'true'` 的后果是「新装用户
  /// 永远不跳片头」，而设置页的开关是**开着**的 —— 一个没人会想到去查的
  /// 默认值问题（`autoMergeByOnlineId` 已经踩过同一个坑）。
  static const String skipIntro = 'skip_intro';

  /// 扫描节流间隔（毫秒）。默认 350ms ≈ 2.9 QPS。
  static const String scanIntervalMs = 'scan_interval_ms';

  /// 扫描最大深度
  static const String scanMaxDepth = 'scan_max_depth';

  /// 诊断日志级别（`debug` / `info` / `warn` / `error`）
  static const String logLevel = 'log_level';

  /// 是否在界面右上角常驻显示**实时调试指标浮层**
  /// （CPU / 内存 / FPS / 解码内核与硬解状态）。
  ///
  /// ## 默认**关**，而且是刻意关的
  ///
  /// 它是**排查工具**，不是功能：一排每秒刷新的数字叠在画面上，日常看片
  /// 只会挡视线，也会让人以为「这软件是不是还没做完」。要查的那一类问题是
  /// 「按这一下键的瞬间到底发生了什么」—— 那种问题靠事后翻日志或者
  /// `adb top` 都看不到瞬时值，所以入口必须留着，但**默认不占画面**。
  ///
  /// ⚠️ 判据必须是 `== 'true'`（缺失即关）。写成 `!= 'false'` 的后果是
  /// 每个用户一装上就顶着一排数字 —— 而这个开关在设置页里是**关着**的，
  /// 用户会以为「关不掉」。这与 `autoMergeByOnlineId` 那个坑是相反的方向，
  /// 但成因相同：默认值写在哪儿，界面就得跟哪儿一致。
  static const String debugOverlay = 'debug_overlay';

  /// 播网盘原画时是否走**本地中继**（多连接并发预取 + 本地缓存）。
  ///
  /// ## 默认**开**
  ///
  /// 夸克原画直链是一条 TCP 顺序读，而网盘对单连接普遍有吞吐上限，于是
  /// 4K 原画在一条连接上永远追不上播放 —— 症状就是「缓冲看着不少，却每隔
  /// 几十秒卡一下」。中继把它换成多条并发连接，正是夸克自己的播放器的做法。
  ///
  /// ⚠️ 判据必须是 `!= 'false'`：写成 `== 'true'` 的后果是「新装用户等于
  /// 没开」，而设置页的开关是开着的 —— 这类默认值问题没有任何报错。
  ///
  /// 关掉它的唯一理由是排查「是不是中继把播放搞坏了」。中继建不起来时会
  /// **静默退回直连**，所以关掉它永远只是回到老行为，不会让视频播不了。
  static const String streamRelay = 'stream_relay';

  /// 本地中继的并发连接数。默认 8，上限 16。
  static const String relayConnections = 'relay_connections';

  /// 目录视图（「文件夹」）列表的排序方式。取值见 `FolderSortMode`
  /// （`modifiedTime` / `fileName`）。
  ///
  /// 默认是**修改时间倒序**。与其它「缺失即用默认」的设置一样，判据只写在
  /// `FolderSortMode.parse` 一处 —— 它只认两个枚举名，其余（`null`、老版本
  /// 写坏的值、手工改过的）一律退回默认。在这里再写一遍 `== '...'` 只会
  /// 多出一处会漂移的默认值真源。
  static const String folderSortMode = 'folder_sort_mode';

  /// 作品详情页「文件」列表的排序方式。取值见 `ItemSortMode`
  /// （`episodeOrder` / `modifiedDesc` / `modifiedAsc`）。
  ///
  /// 默认是**修改时间倒序**。判据（含默认值）只写在 `ItemSortMode.parse`
  /// 一处，理由与 [folderSortMode] 完全相同 —— 在这里再写一遍 `== '...'`
  /// 只会多出一处会漂移的默认值真源。
  ///
  /// ## 与 [folderSortMode] 分开存是**刻意**的
  ///
  /// 两者排的是两种东西：目录视图列的是**网盘实时目录**（子目录 + 各种
  /// 文件），详情页列的是**已入库的媒体文件**（一部剧的 N 集）。合成一个
  /// 键的话，用户在目录视图把排序切成「名称」再进详情页，看到的会是按
  /// 文件名排的集 —— 而集号在文件名里未必是自然序。
  static const String itemSortMode = 'item_sort_mode';

  /// 备份同步的网盘目录名。空串 = 用默认目录名「云影备份」。
  static const String backupDirName = 'backup_dir_name';

  /// 是否在扫描完成后自动上传备份到网盘。
  /// 默认关闭 —— 自动上传可能消耗网盘配额，且用户可能不想频繁覆盖。
  static const String autoBackupOnScan = 'auto_backup_on_scan';

  /// 上次备份同步时间（ISO8601）。
  static const String lastBackupAt = 'last_backup_at';

  /// 同时最多跑几个下载任务。默认 5，上限 10。
  ///
  /// ## 为什么与「中继并发连接数」是两回事
  ///
  /// `relayConnections` 是**一条流**内部的连接数（为了一条视频播得动），
  /// 这一项是**同时下几个文件**。合成一个键的话，用户为了「多下几个文件」
  /// 把数字调大，会顺手把播放那条流也改成十几路并发 —— 而两者对网盘的
  /// 压力完全不同（一个文件几十 GB，十几路并发取链会被风控）。
  ///
  /// ## 为什么默认 5、上限 10
  ///
  /// 下载是**大块顺序读**，每个任务自己就能把带宽吃满；开太多只是让每个
  /// 任务都变慢，还会让网盘侧看到「同一账号短时间开了十几个大文件」。
  /// 10 是实测还能保持稳定的上界。设成 0 会让下载永远不动（队列空转），
  /// 所以下限是 1 —— 判据写在 `AppSettings.fromValues` 里做 clamp。
  static const String downloadConcurrency = 'download_concurrency';

  /// 最近用过的**移动目标目录**，JSON 数组（`[{fid,name,path}, …]`）。
  ///
  /// ## 为什么这个要落库，而不是每次重新选
  ///
  /// 整理网盘的真实动作是**反复的**：把这一批散片移进「待整理」、再把那一批
  /// 移进「电影」，中间要来回进出好几个目录。不记的话，每移一批都要在
  /// 目录树里重新点五六层 —— 而这个动作本身很快，找目录反而成了主要成本。
  ///
  /// ## 为什么是「值本身」而不是别的键名约定
  ///
  /// 它是一份**缓存**，不是偏好：读不懂（旧版本格式、手工改坏、被别的
  /// 程序写过）必须一律退回空列表，绝不能抛 —— 抛出去的后果是文件夹页
  /// 打不开，而用户丢掉的只是「最近记录」。判据只写在
  /// `MoveTargetsController._parse` 一处。
  static const String moveTargetRecents = 'move_target_recents';

  /// **追更检查的全局节流零点**（Unix **秒**的十进制字符串，如 `"1780000000"`）。
  ///
  /// ## 为什么需要它，而不是只看作品级的 `follow_checked_at`
  ///
  /// `media_works.follow_checked_at` 是**逐部作品**的（每部剧各自的水位线），
  /// 而「要不要现在就发起一次检查」是个**全局**问题 —— 没有这一列的话，
  /// 每次进媒体库都要把每一部在追的剧重新查一遍。
  ///
  /// ## ⛔ 为什么是 Unix 秒，而不是 ISO8601
  ///
  /// 这个键**跨端**（Android 也要读写同一个字符串）。ISO8601 在这里有个
  /// 隐蔽的坑：Dart 的 `DateTime.now().toIso8601String()` 是**本地时间且不带
  /// 时区后缀**，微秒位数还随值变化（`.912` / `.912123`）—— 两端各用各的
  /// 解析器（Dart `DateTime.tryParse` / Android `SimpleDateFormat`）时，
  /// 只要有一边按 UTC 解析就会差出整整一个时区，而**两边都不报错**，
  /// 表现是「节流窗口时灵时不灵」。
  ///
  /// Unix 秒是个纯整数，没有任何解释空间 —— 与全库时间列同一口径。
  /// 读用 `readInt`（不是 `readDateTime`）。
  ///
  /// ## ⛔ 为什么放在 `settings` 表，而不是 `media_works`
  ///
  /// 同步判据 `libraryModifiedAt` = `MAX(media_works.updated_at)` ∪
  /// `MAX(media_items.first_seen_at)` ∪ `MAX(media_items.last_played_at)`。
  /// **`settings` 表不在其中** —— 所以写这个键**不会**让本机「看起来更新」，
  /// 也就不会在下一次同步时无条件上传、把另一台设备的进度盖掉。
  ///
  /// 反过来，如果把它塞进 `media_works`（比如复用某个 `updated_at`），
  /// 那么**每次自动检查都会改同步判据** —— 一台常开机的设备会永远赢下
  /// LWW 比较，另一台设备看的进度就永远同步不上去。这是这个功能里最隐蔽的
  /// 一条红线。
  ///
  /// ⚠️ 键名与 Android 端 `LibrarySettings.FOLLOW_LAST_CHECK_AT` **逐字一致**
  /// （它在 `settings` 表里、随 `.ccbak` 备份包跨端走）。
  static const String followLastCheckAt = 'follow_last_check_at';

  /// 自动追更检查的策略。取值见 `FollowAutoCheck`：
  /// `off` / `on_launch`（默认）/ `every_6h`。
  ///
  /// 与其它「缺失即用默认」的设置一样，判据只写在 `FollowAutoCheck.parse`
  /// 一处 —— 它只认三个枚举名，其余（`null`、老版本写坏的值、手工改过的）
  /// 一律退回默认。在这里再写一遍 `== '...'` 只会多出一处会漂移的默认值真源。
  static const String followAutoCheck = 'follow_auto_check';
}

/// 通用键值设置存储。
///
/// 放在数据库里而不是 `SharedPreferences`：设置与索引库是同一份应用数据，
/// 分开存会出现「清了索引但设置还在」「备份了库但设置丢了」这类不一致。
/// 唯一例外是凭证 —— 那个**必须**进系统安全存储（见 `SecureCredentialStore`：
/// iOS/Android/Windows 走钥匙串/Keystore/DPAPI，macOS 走加密文件）。
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

  /// 丢掉进程内缓存，下次读一律回到数据库。
  ///
  /// ## 什么时候必须调
  ///
  /// **媒体库被整体替换之后**（`LibraryBackupService.importBackup`）。
  /// 恢复备份是拿备份里的字节**覆盖整个 `cloudcine.sqlite` 文件**，
  /// `settings` 表随之一起被换掉 —— 但 [read] / [readAll] 走的是
  /// [_cache]，那份缓存对「文件被换了」这件事一无所知。
  ///
  /// 后果是**静默的**，而且很容易撞上：用户在新机器上打开设置页（此时
  /// `tmdb_api_key` 是空的，于是缓存里记下 `null`）→ 从网盘恢复电脑上那份
  /// 备份 → **设置页仍然显示空**、刮削仍然走匿名额度。重启应用才会好。
  /// 这一条正是「token / cookie 随备份恢复」需求的成败所在。
  ///
  /// ⛔ 只清缓存不够：`SettingsController` 手上那份 `AppSettings` 也是旧的，
  ///    调用方还要把 `settingsProvider` 一起 invalidate（见设置页的
  ///    `_refreshLibraryViews`）。
  void invalidate() {
    _cache.clear();
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
