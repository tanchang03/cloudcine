import '../../core/utils/drive_paths.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/filename_parser.dart';
import '../../core/utils/media_category.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';
import '../entities/playback_preference.dart';
import '../entities/subtitle_track.dart';
import '../entities/drive_provider.dart';
import '../entities/scan_cursor.dart';
import '../entities/work_poster.dart';

/// 媒体库列表的排序方式。
///
/// 取值参考 VidHub 的排序菜单（按日期 / 评分 / 类型），并补上本项目
/// 数据模型里现成可用的排序。**枚举顺序就是菜单顺序**。
///
/// 「最近修改」排第一因为它是默认：用户打开媒体库时最常想看的是
/// 「我新存/替换的那几部在哪儿」—— 这比「入库时间」更能反映
/// 「用户刚在网盘上动过」这件事。
enum WorkSort {
  recentModified('最近修改'),
  recentAdded('最近添加'),
  recentPlayed('最近播放'),
  rating('评分'),
  year('年份'),
  title('标题');

  const WorkSort(this.label);

  final String label;
}

/// 媒体索引库契约。
///
/// 上层（扫描器、UI、播放器）只依赖这个抽象，不认识 drift / SQL。
/// 这样扫描调度与界面都能在单元测试里跑在**内存实现**上，
/// 不需要真开一个 SQLite 文件。
///
/// 三层数据模型：
///   - [MediaItem]：文件级（一个可播视频）
///   - [MediaWork]：作品级（海报/简介，按 `groupKey` 归并）
///   - [SubtitleTrack]：字幕引用（挂到 item 上）
abstract class MediaRepository {
  // -------------------------------------------------------------------
  // 写入
  // -------------------------------------------------------------------

  /// 批量 upsert 媒体项。
  ///
  /// **幂等**：重复扫描同一批文件不应产生重复行，也不应把
  /// `firstSeenAt`（「入库时间」）冲掉 —— 它决定「最近添加」排序。
  Future<void> upsertItems(List<MediaItem> items, {DateTime? now});

  /// 删除该网盘下**不在** [keepIds] 里的媒体项，返回删除条数。
  ///
  /// 用于「网盘侧已删除」的陈旧清理。⚠️ [keepIds] 必须是**本次扫描实际
  /// 扫到的** id 集合，不能用「库里现有的全部」—— 那等于永远删不掉。
  Future<int> deleteItemsNotIn(DriveProvider provider, Set<String> keepIds);

  /// 删除**一个**媒体项，连同挂在它上面的字幕引用。返回是否真的删掉了。
  ///
  /// 服务于「网盘上这个文件已经没了」之后的清理 —— 与 [deleteItemsNotIn]
  /// 的区别是范围：那一个是扫描收尾时的**整批**差集删除，这一个是用户
  /// 指着某一行说「删掉它」。
  ///
  /// ## 顺带把所属作品的三个计数重算一遍
  ///
  /// `itemCount` / `totalBytes` / `seasonCount` 是**冗余列**（卡片上要显示
  /// 「24 集」而不想每次 `COUNT(*)`）。删掉一个文件不重算的话，卡片会一直
  /// 写着删之前的数字，直到下一次全盘扫描 —— 用户刚点完「移除」，回头看到
  /// 数字没变，只会以为没删掉。
  ///
  /// ⚠️ 重算必须用**存值口径**（只看 `group_key` 等于这个 key 的行），
  /// 不能用 `listWorks` 那套并集口径：折叠进来的源作品的文件由
  /// `listWorks` 在**读的时候**并进去，这里若再并一次就会被数两遍。
  ///
  /// **不删作品行**。作品下还有没有文件由调用方判断（见
  /// `MissingMediaController._removeSingle`）：「删最后一个文件时顺手删掉
  /// 空作品」是一条产品决定，不是仓储该替调用方做的假设。
  Future<bool> deleteItem(String itemId);

  /// 删除一部作品，以及它名下的**全部**媒体项。返回删掉的文件数。
  ///
  /// 「整部一起删」在用户眼里就是「这一部彻底不见了」，所以作品行、它的
  /// 文件、那些文件的字幕引用必须一起走 —— 只删作品行会留下一堆
  /// 在任何界面上都看不到、却一直占着计数的孤儿文件。
  ///
  /// ## 折叠进来的源作品也一起删
  ///
  /// 归一（见 [mergeWorksInto]）从来不搬 `media_items.group_key`，所以
  /// 「这一部有多少文件」的正确答案是**并集**（`itemsForWork` 的口径）。
  /// 卡片上写 37 个文件、用户点了「移除整部剧」，结果只删掉目标自己名下
  /// 的 25 个、另外 12 个还在库里 —— 那是数据静默变脏，而没有界面会报错。
  ///
  /// 返回 `0` 表示这一部本来就不在库里（或名下没有文件），不是错误。
  Future<int> deleteWork(String groupKey);

  /// 批量 upsert 作品。
  ///
  /// [overrideManual] 只给**用户显式发起**的写入用（详情页的「刮削」/「手动」
  /// 两个按钮）。默认 `false` 时，`source == manual` 的作品（用户自定义过
  /// 片名 / 分类的那些）**不接受在线刮削结果的覆盖** —— 见
  /// `DriftMediaRepository.mergeWorkForUpsert` 里那条守卫。
  ///
  /// ## 为什么需要一个显式开关，而不是「一律保护」
  ///
  /// 一律保护的话，用户手工改过之后就**再也没法重新刮削**了：点「刮削」
  /// 按钮会走到这里、被守卫拦下、库里的行一个字段都不变，而 `WorkScraper`
  /// 已经按流水线的命中结果返回了「已刮削：xxx」—— 界面在撒谎。
  ///
  /// 反过来，一律不保护就会让**扫描期的自动刮削**（`ScanService` 那条）
  /// 每次重扫都拿同一个错条目把用户刚改对的片名糊回去。两者的区别是
  /// 「是不是用户点的」，只有调用方知道，所以由调用方声明。
  Future<void> upsertWorks(
    List<MediaWork> works, {
    DateTime? now,
    bool overrideManual = false,
  });

  /// **清除在线刮削信息 + 自定义片名与分类**（详情页「自定义」按钮）。
  ///
  /// 规则全在 [MediaWork.customized] 里（那是个纯函数，可脱离数据库单测）。
  /// 这里负责落库，返回写入后的作品行；作品已不在库里时返回 `null`。
  ///
  /// ## 为什么不能走 [upsertWorks]
  ///
  /// `mergeWorkForUpsert` 有一条「**海报地址永不为空**」的规则（为「某次扫描
  /// 恰好没拿到缩略图」准备的兜底）：本次地址为 `null` 时它会保留库里那个。
  /// 那正是这里要清掉的东西 —— 走合并等于**清了个寂寞**，而用户看到的是
  /// 「点了自定义，那张刮错的海报还挂在那儿」。
  ///
  /// 所以本方法直接整行写（与 [setWorkCategory] 同一种做法：用户明确要求的
  /// 状态变更不该被「为自动流程准备的容错」改写）。
  ///
  /// ## 清空之后，封面回落到网盘缩略图
  ///
  /// 「清除刮削」要去掉的是**刮错的那张海报**，不是「这部作品从此没有封面」。
  /// 所以实现要先查一遍这部作品名下的媒体项，用 [WorkPoster.fromItems] 挑一
  /// 张网盘缩略图（正片优先），连同人脸锚点一起写回 `posterUrl` /
  /// `posterFaceX`。少了这一步，用户点完「自定义」看到的就是一墙片名首字
  /// 的灰块 —— 而那张图一直都在库里（`MediaItem.thumbUrl`）。
  Future<MediaWork?> customizeWork(
    String key, {
    required String title,
    required MediaCategory category,
    DateTime? now,
  });

  /// 手动指定一部作品的分类；传 `null` 表示**恢复自动判定**。
  ///
  /// 传具体分类时写入 [category] 并标记 `categoryManual = true`，使后续
  /// 刮削 / 重扫不再覆盖它。传 `null` 时清掉标记并按当前规则重算一次
  /// （`MediaCategoryGuesser.guessFromWork`），把这部作品交回自动逻辑。
  ///
  /// ## 为什么必须有「恢复」这条路
  ///
  /// 只有「设成手动」没有「交回自动」的话，用户手滑点错一次分类就**永远
  /// 回不去**了 —— 他只能选另一个手动值，再也不能让刮削的类型（动画 /
  /// 纪录片）生效。那不是「覆盖」，那是「焊死」。
  ///
  /// 传与当前值相同的分类时仍写入（只翻 `categoryManual` 标记）——
  /// 用户点了一下当前分类就是在说「这个值我要锁住」。
  Future<void> setWorkCategory(String key, MediaCategory? category);

  /// 手动编辑一部作品的**类型标签**（`genres`）；传 `null` 表示恢复自动。
  ///
  /// 传具体列表时写入并标记 `genresManual = true`，使后续刮削不再覆盖它
  /// —— 用户可能就是为了修「刮削返回的类型是错的」才动手的。同时把
  /// **分类**从新的类型折算一次（除非分类本身也是手动指定的），
  /// 否则会出现「类型标签写着『动画』、分类却是『电影』」的自相矛盾行。
  ///
  /// 传 `null` 时只清掉 `genresManual` 标记（类型本身保留）—— 下次刮削
  /// 会重新覆盖它。
  Future<void> setWorkGenres(String key, List<String>? genres);

  /// 记下这部作品的**片头起点**（毫秒）。终点原样保留。
  ///
  /// ## 为什么起点 / 终点 / 清除是三个方法，而不是一个带可空参数的
  ///
  /// 「传 `null` 表示清除」在 [setWorkCategory] 那边成立，是因为那里只有
  /// **一个**值。片头有起点和终点两个值，合成一个方法就会出现
  /// 「`startMs: null` 是『清掉起点』还是『不改起点』」这种必须靠约定
  /// 记住的歧义 —— 而写错的表现是「标了一半的片头被悄悄清掉」。
  ///
  /// ## 允许只标一半
  ///
  /// 用户可以只标起点（先记住片头从哪儿开始，回头再标终点），此时
  /// [MediaWork.introRange] 是 `null`（半个区间跳不了），但起点本身**存下来**
  /// 了 —— 不然「先标起点、退出播放器、明天再标终点」这条路走不通，
  /// 而它恰恰是最自然的用法（看片时顺手标一下）。
  Future<void> setWorkIntroStart(String key, int startMs);

  /// 记下这部作品的**片头终点**（毫秒）。起点原样保留。
  Future<void> setWorkIntroEnd(String key, int endMs);

  /// 清除这部作品的片头标记（两列一起清）。
  ///
  /// ⚠️ 不能用 `copyWith(introStartMs: null)` 代替 —— `copyWith` 的 `??`
  /// 把 `null` 当「不改」，那是**清不掉的**（与 `mergedInto` 同一个坑）。
  Future<void> clearWorkIntroRange(String key);

  /// 按归组键取作品。
  Future<MediaWork?> workByKey(String key);

  /// **全库作品，含已被折叠走的别名行**，按 `key` 升序。
  ///
  /// ## 为什么不能用 `listWorks` 代替
  ///
  /// [listWorks] 有三层与「归一」冲突的语义：
  ///
  ///   1. 它**滤掉** `merged_into` 非空的行 —— 而自动归一恰恰需要看到
  ///      「这一行已经被折走了」，否则同一个 `onlineId` 会在每次重跑时
  ///      被重新算成「还有两部独立的作品」；
  ///   2. 它有默认 `limit`（200）—— 拿它当全量会在大库上**静默漏掉**
  ///      后面的作品，表现为「归一只对前 200 部生效」；
  ///   3. 它按展示顺序排（最近修改等），而规划器需要的是**稳定**的顺序
  ///      （同一份数据两次运行必须给出同一个目标）。
  Future<List<MediaWork>> allWorks();

  /// 把 [sourceKeys] 这几部作品**折叠进** [targetKey]，返回实际改动的行数。
  ///
  /// ## 它做什么、不做什么
  ///
  /// 只做一件事：把这些源行的 `merged_into` 置为 [targetKey]。
  ///
  ///   - **不删行**、**不改 `media_items.group_key`**。源行的海报、片名、
  ///     `firstSeenAt` 全部原样留着，所以 [unmergeWorks] 能把一切还原；
  ///   - **不重算目标行的 `itemCount`** —— 目标行那一列一直只统计「自己
  ///     名下的文件」，折叠来的那些由 [itemsForWork] 在查询时并进来。
  ///     若在这里把数字加进去，撤销时就得减回来，而两处一旦漂移，
  ///     卡片上会显示一个既不是 A 也不是 B 的文件数；
  ///   - 已存在的源行 [targetKey] 或已经是目标的 [targetKey] 自身会被
  ///     忽略（源列表里出现 `targetKey` 是调用方的 bug，不该把目标
  ///     折进它自己）。
  ///
  /// ## 传进来的源必须是「根」
  ///
  /// 源行自己不能已经带 `merged_into`（会形成链）。实现里会跳过这种行，
  /// 但**这是兜底不是许可** —— 调用方（`WorkMergeService`）应当已经通过
  /// `WorkMergePlanner` 保证了这一点。
  Future<int> mergeWorksInto(String targetKey, List<String> sourceKeys);

  /// 撤销折叠：把这几行的 `merged_into` 清回 `null`，返回改动的行数。
  ///
  /// 折叠是**双向可逆**的 —— 这正是它选择「打标记」而不是「删行」的全部
  /// 理由。用户看到两个格子变成一个却不知道发生了什么时，得有个按钮
  /// 能退回去，否则他下次会直接关掉自动归一。
  Future<int> unmergeWorks(List<String> sourceKeys);

  /// 取「已折叠进 [targetKey] 的那些作品行」。
  ///
  /// 详情页用它显示「已并入 N 个来源」并生成撤销入口。返回空列表表示
  /// 这一部没有被折叠过任何东西 —— 与 [itemsForWork] 的并集口径**必须
  /// 一致**（详情页显示「并入了 2 个」而文件列表只多出来一个，是最难
  /// 查的那类不一致）。
  Future<List<MediaWork>> mergedSourcesOf(String targetKey);

  /// 批量 upsert 字幕引用。
  ///
  /// **只写引用**（哪个字幕属于哪个视频），不写正文 —— 正文等用户真的
  /// 打开那部片子时再读。理由见 `ScanService` 的说明。
  Future<void> upsertSubtitles(List<SubtitleRef> refs, {DateTime? now});

  /// 删除不在白名单里的字幕引用。
  ///
  /// 白名单口径是「本次确实建立了字幕引用的媒体项 id」，**不是**「扫过的
  /// 所有项」—— 网盘上大部分视频没有外挂字幕，用后者当白名单等于永不清理。
  Future<int> deleteSubtitlesNotIn(
    DriveProvider provider,
    Set<String> keepItemIds,
  );

  /// 保存续扫游标。
  Future<void> saveScanCursor(ScanCursor cursor);

  /// 记录一次播放（用于「最近播放」）。
  Future<void> markPlayed(String itemId, DateTime at);

  /// 保存续播位置。传 `null`（或零）表示**清除** —— 下次从头播。
  ///
  /// ## 为什么与 [markPlayed] 分开
  ///
  /// `markPlayed` 每次进度回报都要写（它决定「最近播放」排序），而这一列在
  /// 「已看完」时反而要被**清掉**。合成一个方法就得带一个「这次要不要清位置」
  /// 的开关，调用点会变成一串布尔字面量，比两个方法难读得多。
  Future<void> saveResumePosition(String itemId, Duration? position);

  /// 把「历史最大播放位置」往上顶到 [position]（**只增不减**）。
  ///
  /// ## 与 [saveResumePosition] 的分工
  ///
  /// 那个回答「这次该从哪儿接着播」，会变、也会被清掉；这个回答「这一集
  /// 看过没有 / 看到哪儿了」，**永不回退、永不清除**。详情页「文件」列表
  /// 靠它画每条的进度条（用续播点画的话，看完的一集会显示成 0%）。
  ///
  /// ## 为什么参数不可空、也不接受「清除」
  ///
  /// 「历史最大位置」没有「清除」这个操作 —— 看过就是看过。传零 / 负数
  /// 是**无操作**（而不是把已有的值抹掉）：调用方每 10 秒报一次位置，
  /// 起播那一刻位置就是 0，那时抹掉用户攒下的进度是最坏的结果。
  Future<void> saveMaxPosition(String itemId, Duration position);

  /// 读某一条的播放偏好（画质 / 音轨 / 字幕 / 字幕开关 / 音效）。
  ///
  /// ## 两级查找：先本文件，再同作品
  ///
  ///   1. **精确命中** `itemId` —— 「这个文件上次怎么播的」，最准；
  ///   2. 没命中时回退到**同一部作品里最近改过的那一条**（按 `updatedAt`
  ///      取最新）—— 用户给第 1 集选了粤语，第 2 集打开也该是粤语，
  ///      而不是每集重选一次。
  ///
  /// [groupKey] 为 `null` / 空串时**只做第一级**：手输直链、内置自检视频
  /// 这类没有库记录的播放不该去继承别人的偏好。
  ///
  /// ## 回退来的音轨 / 字幕必须做特征匹配
  ///
  /// 第二级拿到的可能是**另一集**的记录，里面的内嵌轨 id 在这一集里几乎
  /// 必然不存在。调用方要用 [TrackPreference.bestIndex] 去匹配，匹配不上
  /// 就退回默认 —— **绝不能直接拿 id 去设轨**（症状是「换集之后字幕变成
  /// 外语了」，或者干脆点了没反应）。
  Future<PlaybackPreference?> playbackPreferenceFor(
    String itemId, {
    String? groupKey,
  });

  /// 保存播放偏好（**整条覆盖写**）。
  ///
  /// ## 为什么是「整条覆盖」而不是「按项合并」
  ///
  /// 调用方（内置播放页 / 独立播放窗口）手里**始终有一份完整的偏好对象**：
  /// 打开时读出来的那一份，之后用户每改一项就地更新。所以写的时候直接覆盖
  /// 即可，不需要在仓储层再实现一套「哪些字段该保留」的合并语义 —— 那种
  /// 语义一旦有两处实现（这边和调用方），必然漂移。
  ///
  /// ⚠️ **「等于默认值」的偏好也要写**，不要自作聪明地跳过：用户可能是把
  /// 画质从 1080P 改回原画、或者主动把字幕关掉 —— 那些都是**有效的选择**，
  /// 不写下来下次就还原不出来（`subtitlesEnabled` 那一位尤其明显）。
  Future<void> savePlaybackPreference(
    String itemId,
    String groupKey,
    PlaybackPreference preference);

  // -------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------

  /// 作品列表（媒体库主界面）。
  ///
  /// [query] 会同时匹配作品标题与它下面任一文件的文件名 —— 用户记得的
  /// 往往是文件名（`S02E05` 这种），而列表上显示的是作品名。
  ///
  /// [category] 是媒体库的一级分类（电影 / 剧集 / 动漫 / 综艺 / 纪录片 /
  /// 其他）。`null` 表示全部。**筛选在 SQL 里做**：几千部作品在 Dart 侧
  /// 过滤会让「点一下分类栏」变成一次全表扫描 + 全量反序列化。
  ///
  /// [playedOnly] 只保留**播过**的作品（`lastPlayedAt` 非空），服务的是
  /// 「最近播放」那一栏。它与 [category] 是**正交**的两件事（一部电影既在
  /// 「电影」里，也在「最近播放」里），所以是一个独立的开关而不是分类的一个
  /// 取值 —— 理由见 `LibraryFilter.playedOnly`。
  ///
  /// [scrapedOnly] 只保留**已在线刮削**的作品（`source = 'online'`），
  /// 服务的是筛选面板上的「已刮削」那一项。与 [playedOnly] 一样是一个
  /// 正交的开关而不是分类的一个取值。
  ///
  /// ## 判据为什么是 `source`，而不是 `MediaWork.isScraped`
  ///
  /// `isScraped` 是 `online || manual`，它回答的是「这一行**要不要被
  /// 自动刮削覆盖**」—— 那是合并逻辑的保护位。而这里问的是「有没有刮到过
  /// 在线数据」，两者在「用户点过『自定义』」的行上分道扬镳：自定义会把
  /// 在线信息整份清掉（`scrapedAt` 也置 `null`），那一行**不该**算「已刮削」。
  ///
  /// 也正因为 `scrapedAt` 只由在线刮削写（`WorkSeed.build` /
  /// `WorkScraper._apply`），它与 `source = 'online'` 是同一件事的两列，
  /// 取 `source` 是因为那一列的文档本来就写着「刮削的幂等依据」。
  ///
  /// [years] 与 [genres] 是筛选面板里的两个条件，与上面几个**全部取交集**。
  ///
  ///   - [years] 是**具体年份**（`2023` 只匹配 2023 年上映的作品），不是年代。
  ///     一部片子只属于一个年份，所以多项之间是「或」；
  ///   - [genres] 是 TMDB / 豆瓣的类型名（`动画` / `科幻`…），**任一命中即可**
  ///     （多选是「或」，不是「与」—— 一部片子只会有一两个类型，
  ///     取交集几乎永远筛不出东西）。
  ///
  /// 两者为 `null` 或空集合都表示「这一维不限」。
  ///
  /// ## 返回行里的三个计数是**并集**，与库里的存值可能不同
  ///
  /// [MediaWork.itemCount] / `totalBytes` / `seasonCount` 在库里存的是
  /// 「这一行**自己名下**的文件」。而归一（见 [mergeWorksInto]）从来不搬
  /// `media_items.group_key`，所以被折叠走的那几部的文件**不在这三个数字里**。
  ///
  /// 卡片上显示的是这三个数字，详情页显示的是 [itemsForWork] 的并集 ——
  /// 不补这一层就会出现「两个格子并成一个，卡片还写 25 集、点进去 37 个文件」。
  /// 所以**本方法返回的行已经把它们并进去了**（只对「有折叠进来的作品」的
  /// 那些行生效；没有折叠过的行原样返回，不碰）。
  ///
  /// ## 为什么不把并集数字写回库里
  ///
  /// 重扫会把它冲掉：`mergeWorkForUpsert` 里 `item_count` 永远取本次扫描
  /// 看到的文件集合（那张表就在它上面）。写回去的结果是「合并后 37、重扫
  /// 一次变回 25」，而用户什么都没做。读时现算没有这个漂移面。
  ///
  /// [allWorks] / [workByKey] 返回的仍是**存值**（自己名下的文件）——
  /// 规划器挑「哪一部当目标」用的就是它，那是个启发式，不是展示数字。
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
    Set<int>? years,
    Set<String>? genres,
    WorkSort sort = WorkSort.recentModified,
    int limit = 200,
    int offset = 0,
  });

  /// 把 `category` 列修正到当前规则下的正确值，返回修正条数。
  ///
  /// ## 它管两件事
  ///
  ///   1. **老库回填**。`category` 是 v3 才加的列，老库里的行全是空串。
  ///      若不管它们，用户升级后点「动漫」栏会看到**空列表**，而库里明明
  ///      有动漫 —— 那看起来像分类功能坏了，而不是「需要重新扫描」。
  ///   2. **让刮削的类型对老数据也生效**。`WorkScraper` 会把 TMDB 的
  ///      `genres` 折算成栏目，但那只对**这次之后**的刮削有效；已经刮过的
  ///      作品 `genres` 早就在库、`category` 却还是旧值。这一遍负责对齐，
  ///      否则用户得逐部重刮才看得到分类变对。
  ///
  /// 两件事的判据不同：空串走完整的 `guessFromWork`；非空串**只看 `genres`**
  /// （走完整 guess 会把靠目录名判出来的「综艺」按 kind 冲成「剧集」）。
  /// 实现里的长注释解释了为什么不能合并。
  ///
  /// ## 为什么不让扫描器负责
  ///
  /// 补算只需要「库里已有的列」，不必重新连网盘。放在这里意味着
  /// **升级后第一次打开媒体库就修好了**，用户不用为了一个展示字段
  /// 重扫几千个目录。
  ///
  /// 幂等：只在结果**真的不同**时才写，所以修好之后每次调用都是
  /// 「读一遍、零写入」，可以直接在列表查询前调用。
  Future<int> backfillWorkCategories();

  /// 各分类的作品数（分类栏角标）。
  ///
  /// 单独一个方法而不是「拉全表在 Dart 里数」：作品表有十几列，
  /// 几千部作品的完整反序列化只为数个数是纯浪费，而且那个开销会落在
  /// **每次进媒体库**这个最热的路径上。
  Future<Map<MediaCategory, int>> countWorksByCategory();

  /// 播过的作品数（「最近播放」栏的角标）。
  ///
  /// 不能从 [countWorksByCategory] 的结果里推出来：那里按 `category` 分组，
  /// 而「播过没有」是另一个维度 —— 一部电影同时算在「电影」和「最近播放」
  /// 两栏里，两边的数字本来就不该相加。
  Future<int> countPlayedWorks();

  /// 各年份的作品数（筛选面板「年份」那一组的选项与角标）。
  ///
  /// 键是**具体年份**（`2023`）。只返回**库里真的有的**年份 —— 写死一张
  /// 年份表会让用户点一个永远是 0 的选项，然后怀疑筛选坏了。
  ///
  /// ## 计数口径：等于「把年份 / 类型清空后，列表里的条数」
  ///
  /// 所以它跟着 [category] / [playedOnly] / [scrapedOnly] / [query] 收窄，
  /// 但**不跟着 [years] / [genres] 收窄**（那两维由调用方保证不传进来）。
  /// 这条规则只有一个目的：**面板上出现的每一个选项，点下去至少有一条结果**。
  /// 整库统计做不到这一点 —— 用户切到「综艺」栏再打开面板，会看到一堆
  /// 综艺里根本不存在的类型，点下去是空列表。
  ///
  /// [scrapedOnly] 进这一组而 [years] / [genres] 不进，是因为它们**不是
  /// 同一类条件**：前者是面板顶部那个开关，改的是「这一份列表里有哪些
  /// 作品」，年份 / 类型正是在它筛出来的这批作品里再分面；而 [years] /
  /// [genres] 是分面本身 —— 让分面互相收窄，用户每勾一个类型，剩下的类型
  /// 角标就跟着变，勾到第二个时列表已经空了。
  ///
  /// 副作用是切换分类 / 搜索时面板上的数字会变（标准的分面筛选行为）。
  ///
  /// `year` 为空的作品不进这个表（它们归不进任何年份），
  /// 所以各年份之和**可能小于**作品总数。
  Future<Map<int, int>> countWorksByYear({
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
  });

  /// 各类型的作品数（筛选面板「类型」那一组的选项与角标）。
  ///
  /// 类型存在 `genres` 列里（JSON 数组文本），所以**数不出来就数不出来** ——
  /// 这里只能把那**一列**读出来在 Dart 里拆。与 [countWorksByCategory] 的
  /// 「一次 GROUP BY」不同，但代价仍然可控：只读一列、不反序列化整行。
  ///
  /// 计数口径与 [countWorksByYear] 完全一致（见那里的说明）。
  ///
  /// 没有任何类型的作品（没刮过）不进这个表。
  Future<Map<String, int>> countWorksByGenre({
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
  });

  /// 某个作品下的全部媒体项，按「季 → 集 → 名称」排序。
  Future<List<MediaItem>> itemsForWork(String groupKey);

  /// 全量媒体项，按「目录路径 → 文件名」排序。
  ///
  /// ## 为什么需要一条「不按作品」的读取
  ///
  /// 目录视图要的恰恰是**作品视角拿不到的东西**：文件在网盘上的位置。
  /// 走 [itemsForWork] 得先把作品全查一遍再逐个查文件（N+1），
  /// 而目录树本身只需要一次全表扫描就能在内存里重建。
  ///
  /// [pathPrefix] 只取某个目录（**含其子目录**）下的项，`null` / `/` 表示全部。
  /// 它接受扫描器那种带结尾斜杠的路径，也接受 `/电影` 这种不带的形式
  /// （内部统一走 `FolderTree.normalize`，避免两处各归一化一遍而漂移）。
  ///
  /// [query] 同时匹配**文件名**与**展示路径** —— 用户经常记得「在
  /// `/电影/科幻/` 下面」却记不住片名。
  ///
  /// [limit] 是防御性上限：目录树要算递归计数，所以必须一次拿全，
  /// 给一个远高于个人网盘量级的值，而不是让调用方去分页。
  Future<List<MediaItem>> listItems({
    String? pathPrefix,
    String? query,
    int limit = 20000,
    int offset = 0,
  });

  /// 按 id 取媒体项。
  Future<MediaItem?> itemById(String id);

  /// 批量读续播位置。
  ///
  /// 一次查询取回一整部剧的进度，供剧集列表面板画每集的进度条 ——
  /// 逐集查会在打开面板时打出几十次 SQLite 往返。
  ///
  /// **没存过的条目不出现在结果里**（而不是映射成 0）：调用方写
  /// `map[id] ?? Duration.zero` 拿值，而「到底有没有存过」这件事本来就该由
  /// 缺失来表达。
  Future<Map<String, Duration>> resumePositions(List<String> itemIds);

  /// 批量读**历史最大播放位置**（详情页「文件」列表画进度条用）。
  ///
  /// 与 [resumePositions] 同形、同一套「没存过就不出现在结果里」的口径，
  /// 但读的是另一列（见 [saveMaxPosition]）。两个都要查的时候**必须分成
  /// 两次调用**，不要试图合成一个返回两种值的查询 —— 调用方真正需要的
  /// 往往只有一个（剧集面板要续播点，详情页列表要历史最大位置），
  /// 合并只会让不需要的那一半也陪着查一遍。
  Future<Map<String, Duration>> maxPositions(List<String> itemIds);

  /// 某个媒体项的字幕引用。
  Future<List<SubtitleTrack>> subtitlesForItem(String itemId);

  /// 恢复续扫游标。从未扫描过返回 `null`。
  Future<ScanCursor?> loadScanCursor(DriveProvider provider);

  /// 最近播放的媒体项（按播放时间倒序）。
  Future<List<MediaItem>> recentlyPlayed({int limit = 20});

  /// 最近入库的媒体项（按入库时间倒序）。
  Future<List<MediaItem>> recentlyAdded({int limit = 20});

  /// 媒体项总数。
  Future<int> countItems();

  /// 作品总数。
  Future<int> countWorks();

  /// 本地媒体库**最后一次内容变更**的时间；空库返回 `null`。
  ///
  /// 只服务于备份同步的 Last-Write-Wins 判定。它必须回答「这台机器的库
  /// 最后什么时候真的变过」，而**不能**用「现在几点」——
  /// 后者会让本机在任何时刻都显得比远程新，于是同步永远只会上传，
  /// 新机器一同步就把网盘上的好备份覆盖成空库。
  Future<DateTime?> latestLibraryChangeAt();
}

/// 内存实现。**测试专用**：让扫描器与播放逻辑的单测不依赖 SQLite。
///
/// 刻意不做 SQL 等价的分页/排序优化 —— 它就是几张 Map，测试量级
/// （几百条）下性能无关紧要，而可读性直接决定单测好不好写。
class InMemoryMediaRepository implements MediaRepository {
  InMemoryMediaRepository();

  final Map<String, MediaItem> _items = {};
  final Map<String, MediaWork> _works = {};
  final Map<String, List<SubtitleTrack>> _subtitles = {};
  final Map<String, ScanCursor> _cursors = {};
  final Map<String, DateTime> _played = {};

  /// 续播位置。**没存过的条目不出现在这里**（与真实实现同一口径）。
  final Map<String, Duration> _resume = {};

  /// 历史最大播放位置（只增不减）。与 [_resume] 分开两张表 —— 它们是两个
  /// 不同的量，合并的话「看完清续播点」会顺手把历史进度也抹掉。
  final Map<String, Duration> _maxPositions = {};

  /// 逐文件的播放偏好。值里带上 `groupKey` 与写入时间 —— 前者供「同剧
  /// 继承」回退查询，后者是回退时的排序依据（取最新一条），与真实实现
  /// 的 `playback_prefs.group_key` / `updated_at` 两列一一对应。
  final Map<String, ({PlaybackPreference pref, String groupKey, DateTime at})>
      _prefs = {};

  /// 只读视图，供测试断言。
  Map<String, PlaybackPreference> get playbackPrefs =>
      Map.unmodifiable(_prefs.map((k, v) => MapEntry(k, v.pref)));

  /// 只读视图，供测试断言。
  Map<String, Duration> get resume => Map.unmodifiable(_resume);

  /// 只读视图，供测试断言。
  Map<String, Duration> get maxWatched => Map.unmodifiable(_maxPositions);

  /// 只读视图，供测试断言。
  Map<String, MediaItem> get items => Map.unmodifiable(_items);
  Map<String, MediaWork> get works => Map.unmodifiable(_works);

  @override
  Future<void> upsertItems(List<MediaItem> items, {DateTime? now}) async {
    for (final item in items) {
      final existing = _items[item.id];
      _items[item.id] = existing == null
          ? item
          : item.copyWith(updatedAt: now ?? item.updatedAt).withFirstSeenAt(
              existing.firstSeenAt,
            );
    }
  }

  @override
  Future<int> deleteItemsNotIn(
    DriveProvider provider,
    Set<String> keepIds,
  ) async {
    final doomed = _items.values
        .where((i) => i.provider == provider && !keepIds.contains(i.id))
        .map((i) => i.id)
        .toList();
    for (final id in doomed) {
      _items.remove(id);
      _subtitles.remove(id);
    }
    return doomed.length;
  }

  @override
  Future<bool> deleteItem(String itemId) async {
    final removed = _items.remove(itemId);
    if (removed == null) return false;
    // 五张挂在这条文件上的旁表一起走：`_played` 决定「最近播放」排序，
    // `_resume` 是续播点，`_maxPositions` 是历史进度，`_prefs` 是播放偏好。
    // 留着的话被删掉的文件仍然会出现在「最近播放」里 —— 而点它只会再失败一次。
    _subtitles.remove(itemId);
    _resume.remove(itemId);
    _maxPositions.remove(itemId);
    _played.remove(itemId);
    _prefs.remove(itemId);
    _recountWork(removed.groupKey);
    return true;
  }

  @override
  Future<int> deleteWork(String groupKey) async {
    // 折叠进来的源作品一起删：与 `itemsForWork` 的并集口径保持一致，
    // 否则「移除整部剧」会只删掉一半。
    final keys = <String>{groupKey};
    for (final w in _works.values) {
      if (w.mergedInto == groupKey) keys.add(w.key);
    }
    final doomed = _items.values
        .where((i) => keys.contains(i.groupKey))
        .map((i) => i.id)
        .toList(growable: false);
    for (final id in doomed) {
      _items.remove(id);
      _subtitles.remove(id);
      _resume.remove(id);
      _played.remove(id);
      _prefs.remove(id);
    }
    for (final k in keys) {
      _works.remove(k);
    }
    return doomed.length;
  }

  /// 重算一个作品行的三个计数（**存值**口径：只看自己名下的文件）。
  void _recountWork(String groupKey) {
    final work = _works[groupKey];
    if (work == null) return;
    final mine = _items.values.where((i) => i.groupKey == groupKey).toList();
    DateTime? latest;
    for (final i in mine) {
      final t = i.modifiedAt;
      if (t == null) continue;
      if (latest == null || t.isAfter(latest)) latest = t;
    }
    _works[groupKey] = work.copyWith(
      itemCount: mine.length,
      totalBytes: mine.fold<int>(0, (n, i) => n + (i.sizeBytes ?? 0)),
      seasonCount:
          mine.map((i) => i.season ?? 0).where((s) => s > 0).toSet().length,
      lastModifiedAt: latest,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<void> upsertWorks(
    List<MediaWork> works, {
    DateTime? now,
    bool overrideManual = false,
  }) async {
    final ts = now ?? DateTime.now();
    for (final w in works) {
      final existing = _works[w.key];
      if (existing == null) {
        _works[w.key] = w.firstSeenAt == null
            ? w.copyWith(firstSeenAt: ts)
            : w;
        continue;
      }
      // 用户手工写死的行（`manual`）不接受**自动**在线刮削的覆盖：
      // 只更新扫描的产物（文件数 / 体积 / 网盘时间），元数据整行保留。
      // 与 drift 实现的早退分支同一口径 —— 两个实现给出不同的合并结果
      // 会让「用内存库跑过的用例在真库上失败」变成一个谜。
      if (existing.source == ScrapeSource.manual &&
          w.source == ScrapeSource.online &&
          !overrideManual) {
        _works[w.key] = existing.copyWith(
          itemCount: w.itemCount,
          totalBytes: w.totalBytes,
          lastModifiedAt: w.lastModifiedAt,
          updatedAt: ts,
        );
        continue;
      }
      // 刮削结果不能被「本地解析」的标题覆盖；反之可以。
      //
      // 用户手动改过的两个轴（`categoryManual` / `genresManual`）在两个分支里
      // 都保留 —— 用户改过的不能被重扫 / 重刮削冲掉。
      //
      // ⚠️ 这段规则的真源是 `DriftMediaRepository.mergeWorkForUpsert`
      // （有长注释解释每一条为什么）。替身在这里复刻它，是为了让
      // 「手动改过分类 / 类型后重扫」这类测试也能跑在内存库上；
      // 但真正守规则的是 `test/data/media_work_merge_test.dart`。
      final keepManualCategory = existing.categoryManual;

      // 生效后的类型：用户手敲的优先，其次保护模式沿用库里的，否则用本次的。
      final effectiveGenres = existing.genresManual
          ? existing.genres
          : (existing.isScraped ? existing.genres : w.genres);

      // 分类锁**只增不减** —— 这个项目里没有解锁入口，锁只由用户的显式操作
      // 置上。写成纯 `w.categoryManual` 会在某个调用方漏抄该字段时静默解锁。
      final effectiveCategoryManual = overrideManual
          ? (w.categoryManual || existing.categoryManual)
          : existing.categoryManual;

      // 分类：**显式发起的写入**（`overrideManual`）里，`WorkScraper._categoryFor`
      // 已经按完整优先级算过一遍（含「手动通道忽略旧锁、按本次刮削重判」）——
      // 这里再拦一次会把刚算对的结论扔掉（长注释在
      // `DriftMediaRepository.mergeWorkForUpsert`）。
      // 其余情况：用户手选的优先；否则从**生效后的**类型折算，再退回本次分类。
      final effectiveCategory = overrideManual
          ? w.category
          : (keepManualCategory
              ? existing.category
              : (MediaCategoryGuesser.fromGenres(effectiveGenres) ?? w.category));

      _works[w.key] = existing.isScraped
          ? w.copyWith(
              title: existing.title,
              originalTitle: existing.originalTitle,
              year: existing.year,
              overview: existing.overview,
              posterUrl: existing.posterUrl,
              posterFile: existing.posterFile,
              // 和 `posterUrl` 成对：上面保留了旧地址，锚点就必须跟着保留，
              // 否则会拿新图的人脸位置去裁旧图（详见 `mergeWorkForUpsert`）。
              posterFaceX: existing.posterFaceX,
              backdropUrl: existing.backdropUrl,
              backdropFile: existing.backdropFile,
              rating: existing.rating,
              genres: effectiveGenres,
              genresManual: existing.genresManual,
              onlineId: existing.onlineId,
              source: existing.source,
              scrapedAt: existing.scrapedAt,
              category: effectiveCategory,
              categoryManual: effectiveCategoryManual,
              // `firstSeenAt` 保留旧值：它决定「最近添加」排序。
              firstSeenAt: existing.firstSeenAt,
              // ⚠️ 折叠标记**必须保留旧值**。本次扫描造出来的行
              // `mergedInto` 恒为 `null`，照抄等于每次重扫都把用户
              // （或自动归一）合好的片子悄悄拆回两个格子。
              mergedInto: existing.mergedInto,
              // 片头区间同理：它是**用户标的播放偏好**，重扫造出来的行
              // 这两列恒为 `null`。照抄 = 每次重扫都抹掉用户标好的片头。
              introStartMs: existing.introStartMs,
              introEndMs: existing.introEndMs,
              updatedAt: now ?? w.updatedAt,
            )
          : w.copyWith(
              genres: effectiveGenres,
              genresManual: existing.genresManual,
              category: effectiveCategory,
              categoryManual: effectiveCategoryManual,
              firstSeenAt: existing.firstSeenAt,
              mergedInto: existing.mergedInto,
              introStartMs: existing.introStartMs,
              introEndMs: existing.introEndMs,
              updatedAt: now ?? w.updatedAt,
            );
    }
  }

  @override
  Future<MediaWork?> workByKey(String key) async => _works[key];

  @override
  Future<List<MediaWork>> allWorks() async {
    final list = _works.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  @override
  Future<int> mergeWorksInto(
    String targetKey,
    List<String> sourceKeys,
  ) async {
    final target = _works[targetKey];
    // 目标不存在 → 一条都不动（与 drift 实现同一口径）。全部失败比
    // 折一半好：折一半会留下一个「有源行指向不存在的目标」的库。
    if (target == null) return 0;

    var changed = 0;
    for (final key in sourceKeys) {
      if (key == targetKey) continue;
      final src = _works[key];
      if (src == null) continue;
      // 已经折走了、或它自己就是别人的目标 —— 都不许再折（防成链）。
      if (src.isMergedAway) continue;
      _works[key] = src.copyWith(mergedInto: targetKey);
      changed++;
    }
    return changed;
  }

  @override
  Future<int> unmergeWorks(List<String> sourceKeys) async {
    var changed = 0;
    for (final key in sourceKeys) {
      final src = _works[key];
      if (src == null || !src.isMergedAway) continue;
      // ⚠️ 这里不能用 `copyWith(mergedInto: null)` —— `copyWith` 的 `??`
      // 把 `null` 当成「不改」。必须整行重建，理由与 drift 侧相同。
      _works[key] = MediaWork(
        key: src.key,
        provider: src.provider,
        kind: src.kind,
        title: src.title,
        category: src.category,
        categoryManual: src.categoryManual,
        originalTitle: src.originalTitle,
        year: src.year,
        overview: src.overview,
        posterUrl: src.posterUrl,
        posterFile: src.posterFile,
        posterFaceX: src.posterFaceX,
        backdropUrl: src.backdropUrl,
        backdropFile: src.backdropFile,
        rating: src.rating,
        genres: src.genres,
        genresManual: src.genresManual,
        onlineId: src.onlineId,
        source: src.source,
        scrapedAt: src.scrapedAt,
        itemCount: src.itemCount,
        totalBytes: src.totalBytes,
        seasonCount: src.seasonCount,
        mergedInto: null,
        // 片头区间与「合并」无关 —— 撤销合并只是把这一列改回 null，
        // 顺手把用户标的片头丢掉是纯损失（而且没有任何提示）。
        introStartMs: src.introStartMs,
        introEndMs: src.introEndMs,
        lastModifiedAt: src.lastModifiedAt,
        firstSeenAt: src.firstSeenAt,
        lastPlayedAt: src.lastPlayedAt,
        updatedAt: src.updatedAt,
      );
      changed++;
    }
    return changed;
  }

  @override
  Future<List<MediaWork>> mergedSourcesOf(String targetKey) async {
    final list = _works.values
        .where((w) => w.mergedInto == targetKey)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  @override
  Future<void> upsertSubtitles(
    List<SubtitleRef> refs, {
    DateTime? now,
  }) async {
    for (final ref in refs) {
      final list = _subtitles.putIfAbsent(ref.itemId, () => <SubtitleTrack>[]);
      final idx = list.indexWhere((t) => t.id == ref.track.id);
      if (idx >= 0) {
        list[idx] = ref.track;
      } else {
        list.add(ref.track);
      }
    }
  }

  @override
  Future<int> deleteSubtitlesNotIn(
    DriveProvider provider,
    Set<String> keepItemIds,
  ) async {
    final doomed =
        _subtitles.keys.where((k) => !keepItemIds.contains(k)).toList();
    for (final k in doomed) {
      _subtitles.remove(k);
    }
    return doomed.length;
  }

  @override
  Future<void> saveScanCursor(ScanCursor cursor) async {
    _cursors[cursor.provider.id] = cursor;
  }

  @override
  Future<ScanCursor?> loadScanCursor(DriveProvider provider) async =>
      _cursors[provider.id];

  @override
  Future<void> markPlayed(String itemId, DateTime at) async {
    _played[itemId] = at;

    // ⚠️ 作品行上的 `lastPlayedAt` **也要跟着更新**，与 drift 实现同一口径。
    //
    // 「最近播放」那一栏筛的就是作品行上这一列（`listWorks(playedOnly: true)`）。
    // 只写 item 级那份的话，用这个替身写的测试里那一栏**永远是空的**，而真机
    // 上是好的 —— 这种「替身比真身弱」的差异不会让测试变红，只会让它给出
    // 错误的信心（比如「空态逻辑看着没问题」）。
    final key = _items[itemId]?.groupKey;
    if (key == null) return;
    final work = _works[key];
    if (work != null) _works[key] = work.copyWith(lastPlayedAt: at);
  }

  @override
  Future<void> saveResumePosition(String itemId, Duration? position) async {
    if (position == null || position <= Duration.zero) {
      _resume.remove(itemId);
      return;
    }
    _resume[itemId] = position;
  }

  @override
  Future<void> saveMaxPosition(String itemId, Duration position) async {
    // 零 / 负位置是**无操作**，不是「清零」（见接口文档）：每 10 秒一次
    // 的位置回报里，起播那一刻就是 0，那时抹掉已有进度是最坏的结果。
    if (position <= Duration.zero) return;
    final stored = _maxPositions[itemId];
    // 只增不减。回拖 / 重看都不该让它倒退。
    if (stored != null && stored >= position) return;
    _maxPositions[itemId] = position;
  }

  @override
  Future<PlaybackPreference?> playbackPreferenceFor(
    String itemId, {
    String? groupKey,
  }) async {
    // 第一级：本文件。`isEmpty` 的行按「没记过」处理 —— 真实实现那边
    // 空对象是可能的（`prefs` 列有 `DEFAULT '{}'`），两边口径必须一致。
    final own = _prefs[itemId];
    if (own != null && !own.pref.isEmpty) return own.pref;

    final key = groupKey;
    if (key == null || key.isEmpty) return null;

    // 第二级：同一部作品里最近改过的那一条。
    ({PlaybackPreference pref, String groupKey, DateTime at})? latest;
    for (final entry in _prefs.entries) {
      if (entry.key == itemId) continue;
      if (entry.value.groupKey != key) continue;
      if (entry.value.pref.isEmpty) continue;
      if (latest == null || entry.value.at.isAfter(latest.at)) {
        latest = entry.value;
      }
    }
    return latest?.pref;
  }

  @override
  Future<void> savePlaybackPreference(
    String itemId,
    String groupKey,
    PlaybackPreference preference,
  ) async {
    // 与真实实现同一口径：**整条覆盖**，且空偏好也照写。
    _prefs[itemId] = (
      pref: preference,
      groupKey: groupKey,
      at: DateTime.now(),
    );
  }

  @override
  Future<void> setWorkCategory(String key, MediaCategory? category) async {
    final work = _works[key];
    if (work == null) return;
    // `null` = 恢复自动判定：按当前规则重算一次（与 drift 实现同一口径）。
    final target = category ??
        MediaCategoryGuesser.guessFromWork(
          kind: work.kind,
          title: work.title,
          genres: work.genres,
        );
    _works[key] = work.copyWith(
      category: target,
      categoryManual: category != null,
    );
  }

  @override
  Future<MediaWork?> customizeWork(
    String key, {
    required String title,
    required MediaCategory category,
    DateTime? now,
  }) async {
    final work = _works[key];
    if (work == null) return null;
    // 与 drift 实现同一口径：清掉在线海报后回落到网盘缩略图。这里的
    // 「替身比真身弱」会直接让用它写的测试给出错误信心（界面测出「有图」，
    // 真机上却是一墙灰块）。
    final custom = work.customized(
      title: title,
      category: category,
      updatedAt: now ?? DateTime.now(),
      drivePoster: WorkPoster.fromItems(await itemsForWork(key)),
    );
    _works[key] = custom;
    return custom;
  }

  @override
  Future<void> setWorkGenres(String key, List<String>? genres) async {
    final work = _works[key];
    if (work == null) return;
    if (genres == null) {
      // 恢复自动：只清手动标记，类型留着（下次刮削会覆盖它）。
      _works[key] = work.copyWith(genresManual: false);
      return;
    }
    // 分类跟着新类型走（除非分类本身也是手选的）—— 与 drift 实现同一口径。
    final newCategory = work.categoryManual
        ? work.category
        : (MediaCategoryGuesser.fromGenres(genres) ?? work.category);
    _works[key] = work.copyWith(
      genres: genres,
      genresManual: true,
      category: newCategory,
    );
  }

  @override
  Future<void> setWorkIntroStart(String key, int startMs) async {
    final work = _works[key];
    if (work == null) return;
    _works[key] = _withIntro(work, startMs, work.introEndMs);
  }

  @override
  Future<void> setWorkIntroEnd(String key, int endMs) async {
    final work = _works[key];
    if (work == null) return;
    _works[key] = _withIntro(work, work.introStartMs, endMs);
  }

  @override
  Future<void> clearWorkIntroRange(String key) async {
    final work = _works[key];
    if (work == null) return;
    // 与 `unmergeWorks` 同一条：清空必须**整行重建** —— `copyWith` 的 `??`
    // 把 `null` 当「不改」，走它等于「清了个寂寞」。
    _works[key] = _withIntro(work, null, null);
  }

  /// 整行重建，只换片头那两列。
  ///
  /// ⚠️ 逐列抄一遍看着笨，但这是**唯一**能清空可空字段的写法（理由见
  /// [clearWorkIntroRange]）。漏抄一列的后果是静默丢数据：比如漏了
  /// `mergedInto`，清一次片头就会顺手把跨目录归一拆开。
  MediaWork _withIntro(MediaWork w, int? startMs, int? endMs) => MediaWork(
        key: w.key,
        provider: w.provider,
        kind: w.kind,
        title: w.title,
        category: w.category,
        categoryManual: w.categoryManual,
        originalTitle: w.originalTitle,
        year: w.year,
        overview: w.overview,
        posterUrl: w.posterUrl,
        posterFile: w.posterFile,
        posterFaceX: w.posterFaceX,
        backdropUrl: w.backdropUrl,
        backdropFile: w.backdropFile,
        rating: w.rating,
        genres: w.genres,
        genresManual: w.genresManual,
        onlineId: w.onlineId,
        source: w.source,
        scrapedAt: w.scrapedAt,
        itemCount: w.itemCount,
        totalBytes: w.totalBytes,
        seasonCount: w.seasonCount,
        mergedInto: w.mergedInto,
        introStartMs: startMs,
        introEndMs: endMs,
        lastModifiedAt: w.lastModifiedAt,
        firstSeenAt: w.firstSeenAt,
        lastPlayedAt: w.lastPlayedAt,
        updatedAt: w.updatedAt,
      );

  @override
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
    Set<int>? years,
    Set<String>? genres,
    // ⚠️ 默认值必须与接口声明、drift 实现三处一致：接口默认值只是个
    // 「文档」，真正生效的是**实现**上的默认值。这里漏改的话，调用方
    // 不显式传 sort 时两个实现会给出不同顺序，而这类差异在单测里
    // 看不出来（单测通常都会显式传 sort）。
    WorkSort sort = WorkSort.recentModified,
    int limit = 200,
    int offset = 0,
  }) async {
    var list = _works.values.toList();
    // 已被折叠走的别名行一律不出现在列表里 —— 这是「归一」在用户眼里的
    // 全部表现。**放在所有筛选之前**：后面的条件都假定「这是一部独立作品」。
    list = list.where((w) => !w.isMergedAway).toList();
    if (kind != null) list = list.where((w) => w.kind == kind).toList();
    if (category != null) {
      list = list.where((w) => w.category == category).toList();
    }
    // 「播过没有」看的是作品行上的 `lastPlayedAt`，与分类无关。
    if (playedOnly) {
      list = list.where((w) => w.lastPlayedAt != null).toList();
    }
    // 「刮过没有」只看 `source`。⚠️ **不是** `w.isScraped` —— 那一位还包含
    // `manual`（「用户点过自定义」的行），而自定义恰恰会把在线信息整份清掉。
    // 判据的完整理由见接口上 `listWorks` 的文档。
    //
    // 与 drift 侧的 `t.source.equals('online')` 必须同口径：替身松一点，
    // 用它的测试就会对「哪些算已刮削」给出与真库不同的结论。
    if (scrapedOnly) {
      list = list.where((w) => w.source == ScrapeSource.online).toList();
    }
    // 年份：`years` 存的是**具体年份**（2023 只匹配 2023 年上映的作品）。
    // 没有年份的作品（`year == null`）归不进任何年份 —— 选了年份就等于把
    // 它排掉，与 drift 实现里 `year IN (...)` 的口径一致。
    if (years != null && years.isNotEmpty) {
      list = list
          .where((w) => w.year != null && years.contains(w.year))
          .toList();
    }
    // 类型：**任一命中**（或，不是与）。与 drift 实现里 `LIKE '%"类型"%'`
    // 的口径一致 —— 那边靠引号避免「动画」误命中「动画片」，这边本来就是
    // 字符串精确比较，不需要额外处理。
    if (genres != null && genres.isNotEmpty) {
      list = list.where((w) => w.genres.any(genres.contains)).toList();
    }
    final q = query?.trim().toLowerCase();
    if (q != null && q.isNotEmpty) {
      list = list.where((w) {
        if (w.title.toLowerCase().contains(q)) return true;
        // 文件名命中：**包括被折叠进来的那些源作品的文件**。漏掉这一层
        // 会出现「搜 S02E05 搜不到」，而那一集明明就显示在这部剧的文件
        // 列表里 —— 与 drift 侧的 EXISTS 子查询必须同口径。
        return _items.values.any(
          (i) =>
              (i.groupKey == w.key ||
                  _works[i.groupKey]?.mergedInto == w.key) &&
              i.name.toLowerCase().contains(q),
        );
      }).toList();
    }
    list.sort((a, b) => _compareWorks(a, b, sort));
    return _withUnionStats(list.skip(offset).take(limit).toList());
  }

  /// 把「已被折叠进来的源作品」的文件数 / 体积 / 季数并进返回值。
  ///
  /// 口径与 `DriftMediaRepository._withUnionStats`（裸 SQL）**必须一致**：
  /// 只改有源折进来的那些行；季数是**绝对数**（`COUNT(DISTINCT …)` 不能
  /// 相加），不是增量。替身与真身在这里分叉的话，用内存库跑过的用例会给出
  /// 「列表计数对了」的错误信心，而真机上卡片仍然写少。
  List<MediaWork> _withUnionStats(List<MediaWork> works) {
    // 目标 key → 「目标自己 + 折进来的源」的 group_key 集合。
    final owners = <String, Set<String>>{};
    for (final w in _works.values) {
      final t = w.mergedInto;
      if (t == null || t.isEmpty) continue;
      owners.putIfAbsent(t, () => <String>{t}).add(w.key);
    }
    if (owners.isEmpty) return works;

    final out = <MediaWork>[];
    for (final w in works) {
      final keys = owners[w.key];
      if (keys == null) {
        out.add(w);
        continue;
      }
      final mine = _items.values.where((i) => keys.contains(i.groupKey));
      out.add(
        w.copyWith(
          itemCount: mine.length,
          // ⚠️ `fold<int>` 必须显式给类型参数：`copyWith` 的形参是 `int?`，
          // 上下文推断会让 `fold` 取 `int?`，于是累加器变成可空、编译不过。
          totalBytes: mine.fold<int>(0, (n, i) => n + (i.sizeBytes ?? 0)),
          seasonCount:
              mine.map((i) => i.season ?? 0).where((s) => s > 0).toSet().length,
        ),
      );
    }
    return out;
  }

  /// 与 drift 实现保持**同一口径**的排序。
  ///
  /// 内存实现是测试用的替身，它排序不一致的话，「单测全过但真机顺序不对」
  /// 这类问题会一直存在 —— 而顺序恰恰是列表页最容易出问题的地方。
  static int _compareWorks(MediaWork a, MediaWork b, WorkSort sort) {
    int tie() {
      final byYear = (b.year ?? 0).compareTo(a.year ?? 0);
      return byYear != 0 ? byYear : a.title.compareTo(b.title);
    }

    switch (sort) {
      case WorkSort.recentModified:
        final x = a.lastModifiedAt;
        final y = b.lastModifiedAt;
        // 没拿到网盘修改时间的一律垫底（与 SQL 侧 `OrderingTerm.desc`
        // 的 NULL 行为对齐：NULL 被视为最小值，排最后）。
        if (x == null && y == null) return tie();
        if (x == null) return 1;
        if (y == null) return -1;
        final byModified = y.compareTo(x);
        return byModified != 0 ? byModified : tie();
      case WorkSort.recentAdded:
        final x = a.firstSeenAt;
        final y = b.firstSeenAt;
        // 没拿到入库时间的一律垫底（与 SQL 侧 NULL 行为对齐）。
        if (x == null && y == null) return tie();
        if (x == null) return 1;
        if (y == null) return -1;
        final byAdded = y.compareTo(x);
        return byAdded != 0 ? byAdded : tie();
      case WorkSort.recentPlayed:
        final x = a.lastPlayedAt;
        final y = b.lastPlayedAt;
        // 没播过的一律垫底（SQL 里 NULL 排序行为不一致，两边都显式处理）。
        if (x == null && y == null) return tie();
        if (x == null) return 1;
        if (y == null) return -1;
        final byPlayed = y.compareTo(x);
        return byPlayed != 0 ? byPlayed : tie();
      case WorkSort.rating:
        final byRating = (b.rating ?? 0).compareTo(a.rating ?? 0);
        return byRating != 0 ? byRating : tie();
      case WorkSort.year:
        return tie();
      case WorkSort.title:
        return a.title.compareTo(b.title);
    }
  }

  @override
  Future<int> backfillWorkCategories() async {
    // 内存实现里不存在「分类还没判定过」这种中间态 —— 作品一进来就带着
    // 分类（构造函数的默认值）。所以这里恒为 0。
    //
    // **刻意不写成「把 other 重算一遍」**：`other` 是一个合法判定结果
    // （「判过了，就是认不出来」），重算会把它和「还没判」混为一谈，
    // 而真实实现正是靠这个区别避免反复重算的。
    //
    // ⚠️ 真实实现还多管一件事：把 `genres` 折算进分类（让刮削结果对
    // **已经刮过**的作品也生效）。这个替身**刻意不复刻**它 —— 本文件的
    // 合并/回填逻辑是简化版，规则的真源在 `DriftMediaRepository`
    // （`mergeWorkForUpsert` + `backfillWorkCategories`），
    // 覆盖它们的是 `test/data/media_work_merge_test.dart` 与
    // `test/data/category_backfill_test.dart`（两个都跑真库）。
    // 在替身里复制一份规则只会多出一份没有测试守着的实现。
    return 0;
  }

  @override
  Future<Map<MediaCategory, int>> countWorksByCategory() async {
    final out = <MediaCategory, int>{};
    for (final w in _works.values) {
      // 折叠走的别名行不进角标 —— 角标必须严格等于「列表里的条数」，
      // 否则「电影 12」点进去只有 11 部。
      if (w.isMergedAway) continue;
      out[w.category] = (out[w.category] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<int> countPlayedWorks() async => _works.values
      .where((w) => !w.isMergedAway && w.lastPlayedAt != null)
      .length;

  @override
  Future<Map<int, int>> countWorksByYear({
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
  }) async {
    // 直接复用 [listWorks] 的筛选，而不是把条件再抄一遍：口径要严格等于
    // 「清空年份 / 类型后列表里的条数」，抄一遍就迟早会漂移。
    final works = await listWorks(
      category: category,
      playedOnly: playedOnly,
      scrapedOnly: scrapedOnly,
      query: query,
      limit: _noLimit,
    );
    final out = <int, int>{};
    for (final w in works) {
      final y = w.year;
      // 没有年份的作品不进表 —— 与 `listWorks` 的年份过滤口径一致，
      // 否则面板上会冒出一个点了就空列表的年份。
      if (y == null) continue;
      out[y] = (out[y] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<Map<String, int>> countWorksByGenre({
    MediaCategory? category,
    bool playedOnly = false,
    bool scrapedOnly = false,
    String? query,
  }) async {
    final works = await listWorks(
      category: category,
      playedOnly: playedOnly,
      scrapedOnly: scrapedOnly,
      query: query,
      limit: _noLimit,
    );
    final out = <String, int>{};
    for (final w in works) {
      // 一部片子的同一个类型只数一次（`genres` 理论上不会重复，
      // 但去重能保证即使数据脏了，角标也不会大于作品数）。
      for (final g in w.genres.toSet()) {
        out[g] = (out[g] ?? 0) + 1;
      }
    }
    return out;
  }

  /// 「不分页」。测试量级（几百条）下没有区别，写成一个有名字的常量
  /// 是为了让调用点一眼看出这里**故意要全量**。
  static const int _noLimit = 1 << 30;

  @override
  Future<List<MediaItem>> itemsForWork(String groupKey) async {
    // **并集**：自己名下的文件 + 所有已折叠进来的源作品名下的文件。
    //
    // 归一之后目标作品必须真的「包含」另一部的内容，否则用户看到的是
    // 「两个格子变成一个，但里面的集数少了一半」。口径与
    // `DriftMediaRepository.itemsForWork` 的子查询一致。
    final owners = <String>{groupKey};
    for (final w in _works.values) {
      if (w.mergedInto == groupKey) owners.add(w.key);
    }
    final list =
        _items.values.where((i) => owners.contains(i.groupKey)).toList();
    // ⚠️ 必须与 `DriftMediaRepository.itemsForWork` 的排序**逐条一致**
    // （季 → 部 → 集 → 名称）。替身少排一段，用它的测试就会对
    // 「Part.1 在前还是 Part.2 在前」给出与真库不同的结论 ——
    // 而那种测试通过只说明替身和被测代码犯了同一个错。
    list.sort((a, b) {
      final s = (a.season ?? 0).compareTo(b.season ?? 0);
      if (s != 0) return s;
      final p = a.partOrder.compareTo(b.partOrder);
      if (p != 0) return p;
      final e = (a.episode ?? 0).compareTo(b.episode ?? 0);
      if (e != 0) return e;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  @override
  Future<MediaItem?> itemById(String id) async => _items[id];

  @override
  Future<List<MediaItem>> listItems({
    String? pathPrefix,
    String? query,
    int limit = 20000,
    int offset = 0,
  }) async {
    var list = _items.values.toList();

    final prefix = pathPrefix?.trim();
    if (prefix != null && prefix.isNotEmpty) {
      final normalized = normalizeDrivePath(prefix);
      if (normalized != driveRootPath) {
        final withSlash = drivePathWithTrailingSlash(normalized);
        list = list
            .where((i) =>
                i.dirPath == withSlash || i.dirPath.startsWith(withSlash))
            .toList();
      }
    }

    final q = query?.trim().toLowerCase();
    if (q != null && q.isNotEmpty) {
      list = list
          .where((i) =>
              i.name.toLowerCase().contains(q) ||
              i.dirPath.toLowerCase().contains(q))
          .toList();
    }

    list.sort((a, b) {
      final byDir = a.dirPath.compareTo(b.dirPath);
      return byDir != 0 ? byDir : naturalCompare(a.name, b.name);
    });
    return list.skip(offset).take(limit).toList();
  }

  @override
  Future<Map<String, Duration>> resumePositions(List<String> itemIds) async {
    final out = <String, Duration>{};
    for (final id in itemIds) {
      final d = _resume[id];
      if (d != null && d > Duration.zero) out[id] = d;
    }
    return out;
  }

  @override
  Future<Map<String, Duration>> maxPositions(List<String> itemIds) async {
    final out = <String, Duration>{};
    for (final id in itemIds) {
      final d = _maxPositions[id];
      if (d != null && d > Duration.zero) out[id] = d;
    }
    return out;
  }

  @override
  Future<List<SubtitleTrack>> subtitlesForItem(String itemId) async =>
      List.of(_subtitles[itemId] ?? const []);

  @override
  Future<List<MediaItem>> recentlyPlayed({int limit = 20}) async {
    final list = _played.entries
        .where((e) => _items.containsKey(e.key))
        .map((e) => (id: e.key, at: e.value))
        .toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return list.take(limit).map((e) => _items[e.id]!).toList();
  }

  @override
  Future<List<MediaItem>> recentlyAdded({int limit = 20}) async {
    final list = _items.values.toList()
      ..sort((a, b) => b.firstSeenAt.compareTo(a.firstSeenAt));
    return list.take(limit).toList();
  }

  @override
  Future<int> countItems() async => _items.length;

  @override
  Future<int> countWorks() async =>
      _works.values.where((w) => !w.isMergedAway).length;

  @override
  Future<DateTime?> latestLibraryChangeAt() async {
    // 空库返回 null（而不是 epoch）—— 调用方据此判定「这台机器还没内容」，
    // 从而让远程备份赢下 LWW。返回 epoch 也能工作，但 null 语义更直白。
    if (_works.isEmpty && _items.isEmpty) return null;
    DateTime? latest;
    for (final w in _works.values) {
      final t = w.updatedAt;
      if (latest == null || t.isAfter(latest)) latest = t;
    }
    for (final i in _items.values) {
      // 播放记录也算「库变过」：它决定「最近播放」，是要同步的内容。
      final t = i.lastPlayedAt ?? i.firstSeenAt;
      if (latest == null || t.isAfter(latest)) latest = t;
    }
    return latest;
  }
}

/// 内存实现需要「改 firstSeenAt」这一个实体层不支持的操作。
///
/// 放在这里而不是给 `MediaItem.copyWith` 加参数：`firstSeenAt` 是
/// **仓储层的事实**（这条记录什么时候第一次进库），业务代码不应该能改它。
extension MediaItemFirstSeen on MediaItem {
  MediaItem withFirstSeenAt(DateTime at) => MediaItem(
        provider: provider,
        fileId: fileId,
        name: name,
        dirId: dirId,
        dirPath: dirPath,
        groupKey: groupKey,
        kind: kind,
        title: title,
        year: year,
        season: season,
        episode: episode,
        episodeEnd: episodeEnd,
        container: container,
        resolution: resolution,
        videoWidth: videoWidth,
        videoHeight: videoHeight,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        durationMs: durationMs,
        source: source,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        flags: flags,
        releaseGroup: releaseGroup,
        isSampleOrExtra: isSampleOrExtra,
        thumbUrl: thumbUrl,
        lastPlayedAt: lastPlayedAt,
        firstSeenAt: at,
        updatedAt: updatedAt,
      );
}
