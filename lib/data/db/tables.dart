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
  TextColumn get title => text()();
  TextColumn get originalTitle => text().nullable()();
  IntColumn get year => integer().nullable()();
  TextColumn get overview => text().nullable()();

  TextColumn get posterUrl => text().nullable()();
  TextColumn get posterFile => text().nullable()();
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
