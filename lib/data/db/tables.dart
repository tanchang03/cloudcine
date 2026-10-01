import 'package:drift/drift.dart';

/// 媒体项表（文件级）。
///
/// ⚠️ 数据类名必须显式指定：drift 默认会用 `MediaItems` 的单数形式
/// `MediaItem` 作为生成类的名字，而领域层已经有一个 `MediaItem` ——
/// 两个同名类会让每个 import 都变成猜谜。
@DataClassName('MediaItemRow')
class MediaItems extends Table {
  /// 主键：`provider:fileId`（见 `MediaItem.id`）
  TextColumn get id => text()();

  TextColumn get provider => text()();
  TextColumn get fileId => text()();
  TextColumn get name => text()();
  TextColumn get dirId => text().withDefault(const Constant(''))();
  TextColumn get dirPath => text().withDefault(const Constant('/'))();

  /// 归组键 —— 作品表的关联字段。
  ///
  /// 刻意**不加外键约束**：作品行是在遍历结束后才统一写的，中途被杀时
  /// 会存在「有媒体项、没作品行」的中间态。外键会让那个中间态无法写入，
  /// 而它恰恰是「续扫」这个功能的正常状态。
  TextColumn get groupKey => text()();

  TextColumn get kind => text()();

  TextColumn get title => text().nullable()();
  IntColumn get year => integer().nullable()();
  IntColumn get season => integer().nullable()();
  IntColumn get episode => integer().nullable()();
  IntColumn get episodeEnd => integer().nullable()();

  /// 容器标识（`VideoContainer.name`）
  TextColumn get container => text().withDefault(const Constant('other'))();

  /// 分辨率档位标识（`VideoResolution.label`，如 `1080P`）。
  ///
  /// 存 label 而不是枚举 index：枚举顺序一旦调整（比如插一档 8K 到中间），
  /// index 会整体错位，而旧数据会**静默**变成另一档分辨率。
  TextColumn get resolution => text().nullable()();

  IntColumn get sizeBytes => integer().nullable()();
  DateTimeColumn get modifiedAt => dateTime().nullable()();
  IntColumn get durationMs => integer().nullable()();

  TextColumn get source => text().nullable()();
  TextColumn get videoCodec => text().nullable()();
  TextColumn get audioCodec => text().nullable()();

  /// 标记集合，存 JSON 数组字符串（`["HDR","10bit"]`）。
  TextColumn get flags => text().withDefault(const Constant('[]'))();

  TextColumn get releaseGroup => text().nullable()();
  BoolColumn get isSampleOrExtra =>
      boolean().withDefault(const Constant(false))();

  /// 入库时间。**决定「最近添加」排序**，因此 upsert 时必须保留旧值。
  DateTimeColumn get firstSeenAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 最近播放时间。`null` 表示没播过。
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  /// 续播位置（毫秒）。`null` = 没有可续的点（没播过 / 已看完 / 用户关了
  /// 「记住播放进度」）。
  ///
  /// ## 为什么是单独一列而不是复用 [lastPlayedAt]
  ///
  /// 两者**语义不同、更新频率差两个数量级**：`lastPlayedAt` 是「什么时候看的」
  /// （决定「最近播放」排序），每 10 秒一次进度回报都会刷新它；而这一列是
  /// 「看到哪儿了」，也每 10 秒写一次。合成一列就得塞 JSON，而那会让
  /// 「最近播放」的排序查询变成字符串解析。
  ///
  /// ## 为什么存毫秒而不是秒
  ///
  /// 时长本身就是毫秒（[MediaItems.durationMs]），统一单位省掉一处换算；
  /// 而换算正是这类字段最容易出错的地方（`inSeconds` 截断 vs 四舍五入）。
  IntColumn get resumePositionMs => integer().nullable()();

  /// 网盘服务端生成的视频预览图地址（夸克 `preview_url` / `thumbnail`）。
  ///
  /// **只存地址，不存图片** —— 图片由 `PosterCache` 按需下载并落盘。
  /// 扫描期下载几千张图会让一次扫描多出几千次请求（夸克有 QPS 限制），
  /// 而用户可能根本不会翻到那些片子。
  ///
  /// 地址**不含 Cookie**（Cookie 在每次响应里轮换，冻进地址第二天就 401），
  /// 取图时必须由适配器现给请求头。
  TextColumn get thumbUrl => text().nullable()();

  /// 网盘给出的**实测**视频像素尺寸（夸克 `video_width` / `video_height`）。
  ///
  /// 2026-10-01 实测：递归遍历 44 个目录、427 个视频，这两个字段覆盖率
  /// **100%**，且没有 0 值。它们比文件名可靠，所以 [resolution] 那一列在
  /// 它们存在时是**由它们归挡出来的**，而不是从文件名猜的。
  ///
  /// ## 为什么存原始像素，而不只存归挡结果
  ///
  /// 归挡规则将来可能调整（加档、改长边阈值），届时可以从原始值**重算**；
  /// 只存档位就只能重扫全盘。两者代价差一个数量级。
  IntColumn get videoWidth => integer().nullable()();
  IntColumn get videoHeight => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 作品表（作品级：海报、简介）。
@DataClassName('MediaWorkRow')
class MediaWorks extends Table {
  /// 主键：归组键
  TextColumn get key => text()();

  TextColumn get provider => text()();
  TextColumn get kind => text()();

  /// 媒体库一级分类（`MediaCategory.name`）。
  ///
  /// 默认空串而不是 `other`：空串表示**这一行还没被判定过**，需要回填；
  /// 而 `other` 是一个**判定结果**（「判过了，就是认不出来」）。
  /// 两者混在一起的话，回填逻辑会反复把 `other` 当成待判定的行重算，
  /// 而真正的「其他」作品永远修不好（因为它本来就该是 other）。
  TextColumn get category => text().withDefault(const Constant(''))();

  TextColumn get title => text()();
  TextColumn get originalTitle => text().nullable()();
  IntColumn get year => integer().nullable()();
  TextColumn get overview => text().nullable()();

  TextColumn get posterUrl => text().nullable()();
  TextColumn get posterFile => text().nullable()();

  /// 封面里**人物所在的水平位置**（归一化 0~1），来自夸克的人脸框。
  ///
  /// 只有封面来自夸克的**视频帧**（16:9）时才有值：那时封面会被裁成竖版，
  /// 需要锚住人物，而不是裁到画面正中（双人对谈镜头的中点是两人之间的空隙）。
  /// 来自 TMDB 的海报本身就是 2:3，不需要锚点，此列为 `NULL`。
  ///
  /// 存**锚点**而不是「裁切偏移」：偏移量取决于卡片比例，换算放在渲染时
  /// （`FaceAnchor.alignmentX`），这样调整卡片比例不需要重新扫描。
  ///
  /// 与 `posterUrl` 是**成对**的 —— 换封面来源必须同时换锚点。
  RealColumn get posterFaceX => real().nullable()();

  TextColumn get backdropUrl => text().nullable()();
  TextColumn get backdropFile => text().nullable()();

  RealColumn get rating => real().nullable()();

  /// 类型列表，存 JSON 数组字符串。
  TextColumn get genres => text().withDefault(const Constant('[]'))();

  TextColumn get onlineId => text().nullable()();

  /// 元数据来源（`ScrapeSource.name`）。
  ///
  /// 这一列是**刮削的幂等依据**：扫描器只对 `source != online` 的作品
  /// 重新走在线刮削，否则每次扫描都会把整库的 TMDB 配额重烧一遍。
  TextColumn get source => text()();

  DateTimeColumn get scrapedAt => dateTime().nullable()();

  /// 冗余计数，避免列表页为每个作品做一次 count 查询（N+1）。
  IntColumn get itemCount => integer().withDefault(const Constant(0))();
  IntColumn get totalBytes => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 字幕引用表。
///
/// **只存引用，不存正文** —— 正文在播放时按需读取（见 `SubtitleResolver`）。
@DataClassName('SubtitleRefRow')
class SubtitleRefs extends Table {
  /// 主键：`itemId#fileId`（见 `SubtitleTrack.id`）
  TextColumn get id => text()();

  /// 所属媒体项 id
  TextColumn get itemId => text()();

  /// 来源（`SubtitleOrigin.name`）
  TextColumn get origin => text()();

  TextColumn get label => text()();
  TextColumn get format => text()();
  TextColumn get languageCode => text().nullable()();
  TextColumn get languageLabel => text().nullable()();

  TextColumn get fileId => text().nullable()();
  TextColumn get fileName => text().nullable()();
  TextColumn get localPath => text().nullable()();
  IntColumn get embeddedTrackId => integer().nullable()();

  BoolColumn get isForced => boolean().withDefault(const Constant(false))();
  BoolColumn get isSdh => boolean().withDefault(const Constant(false))();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 续扫游标表。每个网盘一行。
@DataClassName('ScanCursorRow')
class ScanCursors extends Table {
  TextColumn get provider => text()();
  TextColumn get rootId => text()();
  TextColumn get rootPath => text().withDefault(const Constant('/'))();

  /// BFS 待扫队列，JSON 数组字符串（见 `PendingDir.toJson`）。
  ///
  /// 存 JSON 而不是拆成关联表：它是一份**只在扫描期间有意义**的临时状态，
  /// 没有任何按字段查询的需求，而拆表会让「每页落盘」这个高频操作
  /// 变成多表写入。
  TextColumn get pendingDirs => text().withDefault(const Constant('[]'))();

  /// 当前目录，JSON 对象字符串。`null` 表示不在目录中途。
  TextColumn get currentDir => text().nullable()();
  TextColumn get currentPageToken => text().nullable()();

  /// 阶段（`ScanStage.name`）
  TextColumn get stage => text()();

  IntColumn get scannedDirs => integer().withDefault(const Constant(0))();
  IntColumn get scannedFiles => integer().withDefault(const Constant(0))();
  IntColumn get foundTracks => integer().withDefault(const Constant(0))();
  IntColumn get totalBytes => integer().withDefault(const Constant(0))();
  IntColumn get failedDirs => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {provider};
}

/// 通用键值设置表。
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
