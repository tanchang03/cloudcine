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

  /// 部号（`第X部` / `上部`·`下部` / `Part.2` / `CD1`）。
  ///
  /// 与 [season] 是两个维度：季是外层、部是内层（《进击的巨人》第三季
  /// Part.1/Part.2）。**NULL 语义是「没标部」** —— 详情页据此不画「部」
  /// 那一层，所以旧库升级后不需要回填，行为与升级前完全一致。
  IntColumn get part => integer().nullable()();

  /// 部的展示名（`特别篇` / `上部` / `下部`）。NULL 表示没有专名。
  ///
  /// 存文本而不是枚举：这是发布组自己起的名字，穷举不完。
  TextColumn get partLabel => text().nullable()();

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

  /// **历史最大播放位置**（毫秒）。`null` = 从没播过。
  ///
  /// ## 与 [resumePositionMs] 的分工（两者都是「看到哪儿了」，但不是一个东西）
  ///
  ///   - [resumePositionMs] 回答「**这次**该从哪儿接着播」—— 它会变，也会被
  ///     清掉（看完清、位置太靠前当没看过）；
  ///   - 这一列回答「**这一集我看过没有 / 看到哪儿了**」—— **只增不减**，
  ///     也永远不清。
  ///
  /// ## 为什么不能用续播点画进度条
  ///
  /// 详情页的文件列表要靠它画每一条的进度条。拿续播点画会有两个必然的错：
  /// 看完的一集续播点被清成了 `NULL` → 进度条归零，界面上「看过」这件事
  /// 直接消失；用户回拖重看一段 → 进度条跟着退回去。
  ///
  /// ## 为什么是「只增不减」
  ///
  /// 它记的是**历史最远位置**，不是播放头当前位置。回拖、重看都不该让它
  /// 倒退 —— 一旦倒退，这个条就不再回答「我看过没有」了。
  ///
  /// ## 为什么写完不清
  ///
  /// 它没有「过期」的概念：看过就是看过。清掉只会让用户在列表里
  /// 认不出哪些集已经看过。
  IntColumn get maxPositionMs => integer().nullable()();

  /// 网盘服务端生成的视频预览图地址（夸克 `preview_url` / `thumbnail`）。
  ///
  /// **只存地址，不存图片** —— 图片由 `PosterCache` 按需下载并落盘。
  /// 扫描期下载几千张图会让一次扫描多出几千次请求（夸克有 QPS 限制），
  /// 而用户可能根本不会翻到那些片子。
  ///
  /// 地址**不含 Cookie**（Cookie 在每次响应里轮换，冻进地址第二天就 401），
  /// 取图时必须由适配器现给请求头。
  TextColumn get thumbUrl => text().nullable()();

  /// [thumbUrl] 那张图里**人物的水平位置**（0~1），来自夸克的人脸框。
  ///
  /// 与 [thumbUrl] **同源成对**：谁提供缩略图，谁提供锚点（见
  /// `MediaItem.faceAnchorX`）。换封面来源时必须一起换。
  ///
  /// ## 为什么文件行也要留一份（作品行已有 `posterFaceX`）
  ///
  /// 作品级那份在**刮到在线海报时会被清成 NULL** —— 那张 2:3 的竖版海报
  /// 不需要锚点，留着反而是「拿视频帧的人脸位置去裁海报」。于是「自定义
  /// → 清掉刮削 → 封面回落到网盘缩略图」那一刻，锚点只能从**文件行**取回。
  /// 缺了这一列，回落出来的封面永远没有锚点，只能按画面正中裁。
  ///
  /// 旧库升级后是 NULL（见 v13 迁移）：人脸框随列目录响应下发，旧库没存过，
  /// 重扫一次即补上。
  RealColumn get faceAnchorX => real().nullable()();

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

  /// 用户是否手动指定了分类。
  ///
  /// `true` 时，[mergeWorkForUpsert] 与 `WorkScraper._categoryFor` **不再用
  /// `fromGenres` 覆盖** `category` 列 —— 用户说了算，刮削的 genres 说了不算。
  ///
  /// 为什么不直接复用 `source = manual`：`source` 是「整条元数据的来源」
  /// （标题 / 海报 / 简介），刮削过一次就会变成 `online`；而分类只是其中
  /// 一列，用户可以在保留在线标题的同时只改分类。两者语义不同，混在一起
  /// 会让「重新刮削」误判为「需要保护整行」或反过来。
  BoolColumn get categoryManual =>
      boolean().withDefault(const Constant(false))();

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

  /// 用户是否手动编辑过类型标签（[genres]）。
  ///
  /// `true` 时，`mergeWorkForUpsert` 与 `WorkScraper._apply` **不再用刮削
  /// 返回的 `meta.genres` 覆盖**这一列 —— 用户自己敲的「动画 / 科幻」不会被
  /// 下一次刮削（往往只是为了补张海报）整份冲掉。
  ///
  /// 与 `categoryManual` 分开：分类和类型是两个轴，用户可能只改其中一个。
  /// 两者都手动时互不干扰 —— 分类从**手动后的**类型折算，而不是从刮削的。
  BoolColumn get genresManual =>
      boolean().withDefault(const Constant(false))();

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

  /// 作品下**已标季号**的季数（去重；不含「未标季」那一桶）。
  ///
  /// 与 [itemCount] 同一条理由：列表页卡片要显示「3 季」，而按 `group_key`
  /// 去 `COUNT(DISTINCT season)` 是一次子查询 —— 几百个作品就是几百次。
  ///
  /// `0` 和 `1` 都表示**不该显示季数**（电影、单季剧、老库还没重扫）。
  /// 只有 `>= 2` 才有展示价值，见 `MediaWork.subtitleLine`。
  IntColumn get seasonCount => integer().withDefault(const Constant(0))();

  /// 作品下所有文件的**网盘修改时间**最大值（`MediaItem.modifiedAt`）。
  ///
  /// 取最大值是因为一部剧有多集：新增一集时这个值会变大，
  /// 整个作品在「最近修改」排序里就会浮到前面。
  DateTimeColumn get lastModifiedAt => dateTime().nullable()();

  /// 作品**首次入库**时间。决定「最近添加」排序，upsert 时必须保留旧值。
  DateTimeColumn get firstSeenAt => dateTime().nullable()();

  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 这一行**已被折叠进**哪一部作品（存目标的 `key`）。
  ///
  /// ## 为什么是「打个标记」而不是「删掉这一行」
  ///
  /// 跨目录归一（同一部片子在两个目录里各扫出一个作品）最初的设计是
  /// 「把源作品的 `media_items.group_key` 改写成目标的 key，然后删掉源行」。
  /// 那条路有个不可接受的后果：**合并错了就回不去**。用户看到两个格子
  /// 变成一个，既不知道发生了什么，也没有任何按钮能还原 —— 他只会
  /// 从此不敢让程序自动合并。
  ///
  /// 改成打标记之后：
  ///
  ///   - 列表 / 角标只认 `merged_into IS NULL` 的行 → 用户看到的仍然是
  ///     一个格子，与「删掉」在观感上完全一致；
  ///   - 源行的**所有列原样保留**（海报、片名、`firstSeenAt`……）；
  ///   - 撤销 = 把这一列改回 `NULL`，一条 `UPDATE`，没有任何信息丢失；
  ///   - `media_items.group_key` **永不改写**，所以「item.groupKey 一定
  ///     等于某个 work.key」这条全库不变量继续成立 —— `PlayTarget`、
  ///     续播点、字幕引用都不需要知道「合并」这件事存在。
  ///
  /// ## 链式合并是不允许的
  ///
  /// 只允许「源 → 根」一层：一个已经带标记的行**不会再被当成目标**。
  /// 否则撤销要沿着链回溯，而链上的中间节点一旦被用户单独撤销就会
  /// 把后面的节点孤儿化。
  TextColumn get mergedInto => text().nullable()();

  /// 用户手标的**片头**起点 / 终点（毫秒）。
  ///
  /// ## 为什么是「作品级」而不是「文件级」
  ///
  /// 同一部剧每一集的片头位置几乎完全一样（同一套片头、同一个位置），
  /// 让用户给 24 集各标一次是不可接受的。标一次，全剧生效。
  ///
  /// ## 为什么两列必须成对
  ///
  /// 只有起点没有终点（或反过来）**跳不了** —— 半个区间没有落点。
  /// 所以读取时（`IntroMarker.fromMilliseconds`）任一为空就整体当没有。
  ///
  /// ## 扫描不许把它清掉
  ///
  /// 与 [mergedInto] 同一条规矩：重扫造出来的新行这两列恒为 `NULL`，
  /// `mergeWorkForUpsert` 必须走「旧值优先」的受保护通道。照抄新值等于
  /// **每次重扫都把用户标好的片头抹掉**，而用户只看到「跳片头时灵时不灵」。
  IntColumn get introStartMs => integer().nullable()();
  IntColumn get introEndMs => integer().nullable()();

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

/// 播放偏好表（**逐文件**）。
///
/// 「上次播这部片时选了什么」—— 画质、音轨、字幕、字幕开关、音效。
/// 下次打开同一个文件就还原回去，而不是每次都回到全局默认。
///
/// ## 为什么是独立一张表，而不是往 `media_items` 上加几列
///
///   1. `media_items` 的行是**扫描的产物**：`upsertItems` 会整行重写，
///      重扫一次就把用户的选择冲掉了 —— 而 `mergeWorkForUpsert` 那条
///      「旧值优先」的保护通道是给作品级的元数据用的，媒体项这边没有
///      对应的机制。独立一张表就不存在被扫描覆盖的问题。
///   2. 偏好的写入频率（用户点一次菜单）与扫描（几千行批量）差几个数量级，
///      混在同一张表里会让扫描的批量写多背一批无关列。
///
/// ## 为什么 `prefs` 存 JSON 而不是拆成一列一项
///
/// 与 `ScanCursors.pendingDirs` 同一条理由：这张表**没有任何按字段查询的
/// 需求**（只会按 `item_id` 精确取、或按 `group_key` 取最新一条），而
/// 偏好项是会长大的（将来可能加「字幕字体大小」「跳过片尾」）。拆成列的话
/// 每加一项都要一次 schema 迁移，而迁移写错是静默的数据损坏。
@DataClassName('PlaybackPrefRow')
class PlaybackPrefs extends Table {
  /// 主键：媒体项 id（`provider:fileId`）。
  TextColumn get itemId => text()();

  /// 归组键（`MediaItem.groupKey`）。
  ///
  /// 存在的唯一理由是**同剧继承**：某一集没记过偏好时，回退到同一部作品
  /// 里最近改过的那一条（用户给第 1 集选了粤语，第 2 集打开也该是粤语）。
  ///
  /// 冗余存一份而不是 JOIN `media_items`：回退查询发生在**每次打开播放页**
  /// 的热路径上，而 `media_items` 是被折叠归一反复改动的表（`group_key`
  /// 虽然不搬，但行会被删）。这里存的是「记下这条偏好时它属于哪部作品」，
  /// 是个历史事实，不需要跟着变。
  TextColumn get groupKey => text()();

  /// 偏好本体，`PlaybackPreference.toJson` 的字符串。空对象 `{}` = 没记过。
  TextColumn get prefs => text().withDefault(const Constant('{}'))();

  /// 最后修改时间。**同剧继承的排序依据**（取最新一条）。
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {itemId};
}

/// 下载任务表（**下载记录视图**的唯一数据源）。
///
/// ## 为什么要落库，而不是只放在内存里
///
/// 「下载」在这里不是一次几秒钟的动作：网盘上一部 4K 原盘是几十 GB，
/// 用户按下开始之后会去干别的、关掉应用、第二天再打开。只放内存的话，
/// 关一次窗口就等于**把已经下了一半的几十 GB 悄悄丢掉**（`.part` 还在
/// 磁盘上，但没有任何东西记得它属于哪个文件、该从第几个字节接下去）。
///
/// 所以每个任务的**目标路径**与**已下字节**都必须落库：前者决定
/// 「继续时往哪个文件追加」，后者决定「Range 从哪开始」。
///
/// ## 为什么主键是 `provider:fileId` 而不是自增 id
///
/// 与 `MediaItems.id` 同口径。取这个的自然结果是**同一个文件天然去重**：
/// 在目录视图里对同一个 `.zip` 连点两次下载，得到的是同一条记录被重新排队，
/// 而不是两条记录同时往同一个文件里写 —— 后者会把文件写成互相交错的垃圾。
///
/// 代价是「同一个文件想存两份到不同位置」做不到。这个取舍是刻意的：
/// 那种需求在网盘客户端里几乎不存在，而它换来的「不会自己写坏自己」
/// 是每天都在生效的。
///
/// ## `receivedBytes` 是**进度快照**，不是真源
///
/// 真源是磁盘上那个 `.part` 文件的实际长度（见 `DriveDownloadService`）。
/// 这一列按秒节流写入，进程被杀时最多丢一秒的进度；续传时服务会拿
/// `.part` 的真实长度**覆盖**它 —— 因为它可能比真实值**大**
/// （写完还没落盘就崩），而拿一个偏大的偏移去发 `Range` 会得到 416。
@DataClassName('DownloadTaskRow')
class DownloadTasks extends Table {
  /// 主键：`provider:fileId`（见 `DownloadTask.idFor`）
  TextColumn get id => text()();

  /// 所属网盘（`DriveProvider.name`）
  TextColumn get provider => text()();

  /// 网盘侧文件 ID
  TextColumn get fileId => text()();

  /// 文件名（含扩展名）。展示用。
  TextColumn get name => text()();

  /// 网盘上的目录路径（归一化，不带尾斜杠）。展示用 ——
  /// 同一个 `a.zip` 在 `/电影/` 与 `/备份/` 下是两个东西，不给路径就分不清。
  TextColumn get dirPath => text().withDefault(const Constant('/'))();

  /// **本地目标路径**（绝对路径）。续传时 `.part` 由它派生（`'$savePath.part'`）。
  TextColumn get savePath => text()();

  /// 文件总字节数。网盘没给时为 `null`，此时进度条只能是不确定态。
  IntColumn get sizeBytes => integer().nullable()();

  /// 已落盘字节数（进度快照，真源见类文档）。
  IntColumn get receivedBytes => integer().withDefault(const Constant(0))();

  /// 状态（`DownloadStatus.name`）。
  ///
  /// 存枚举名而不是序号：加一个状态时序号会整体错位，旧数据会**静默**
  /// 变成另一个状态（与 `media_items.resolution` 存 label 同一条理由）。
  TextColumn get status => text()();

  /// 失败原因（面向用户的一句话）。成功 / 未失败时为 `null`。
  TextColumn get error => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 通用键值设置表。
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
