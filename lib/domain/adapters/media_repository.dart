import '../../core/utils/drive_paths.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/filename_parser.dart';
import '../../core/utils/media_category.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';
import '../entities/subtitle_track.dart';
import '../entities/drive_provider.dart';
import '../entities/scan_cursor.dart';

/// 媒体库列表的排序方式。
///
/// 取值参考 VidHub 的排序菜单（按日期 / 评分 / 类型），并补上本项目
/// 数据模型里现成可用的两档。**枚举顺序就是菜单顺序** ——
/// 「最近添加」排第一是因为它是用户打开媒体库时最常想看的：
/// 「我新存的那几部在哪儿」。
enum WorkSort {
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

  /// 批量 upsert 作品。
  Future<void> upsertWorks(List<MediaWork> works, {DateTime? now});

  /// 按归组键取作品。
  Future<MediaWork?> workByKey(String key);

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
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
    WorkSort sort = WorkSort.recentAdded,
    int limit = 200,
    int offset = 0,
  });

  /// 给 `category` 还是空串的作品补算分类，返回补算条数。
  ///
  /// ## 为什么需要它
  ///
  /// `category` 是 v3 才加的列，老库里的行全是空串。若不管它们，
  /// 用户升级后点「动漫」栏会看到**空列表**，而库里明明有动漫 ——
  /// 那看起来像分类功能坏了，而不是「需要重新扫描」。
  ///
  /// ## 为什么不让扫描器负责
  ///
  /// 补算只需要「标题 + kind」，不必重新连网盘。放在这里意味着
  /// **升级后第一次打开媒体库就修好了**，用户不用为了一个展示字段
  /// 重扫几千个目录。
  ///
  /// 幂等：没有空串行时是一次 `COUNT`，可以直接在列表查询前调用。
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

  /// 只读视图，供测试断言。
  Map<String, Duration> get resume => Map.unmodifiable(_resume);

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
  Future<void> upsertWorks(List<MediaWork> works, {DateTime? now}) async {
    for (final w in works) {
      final existing = _works[w.key];
      if (existing == null) {
        _works[w.key] = w;
        continue;
      }
      // 刮削结果不能被「本地解析」的标题覆盖；反之可以。
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
              genres: existing.genres,
              onlineId: existing.onlineId,
              source: existing.source,
              scrapedAt: existing.scrapedAt,
              updatedAt: now ?? w.updatedAt,
            )
          : w.copyWith(updatedAt: now ?? w.updatedAt);
    }
  }

  @override
  Future<MediaWork?> workByKey(String key) async => _works[key];

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
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
    WorkSort sort = WorkSort.recentAdded,
    int limit = 200,
    int offset = 0,
  }) async {
    var list = _works.values.toList();
    if (kind != null) list = list.where((w) => w.kind == kind).toList();
    if (category != null) {
      list = list.where((w) => w.category == category).toList();
    }
    // 「播过没有」看的是作品行上的 `lastPlayedAt`，与分类无关。
    if (playedOnly) {
      list = list.where((w) => w.lastPlayedAt != null).toList();
    }
    final q = query?.trim().toLowerCase();
    if (q != null && q.isNotEmpty) {
      list = list.where((w) {
        if (w.title.toLowerCase().contains(q)) return true;
        return _items.values.any(
          (i) => i.groupKey == w.key && i.name.toLowerCase().contains(q),
        );
      }).toList();
    }
    list.sort((a, b) => _compareWorks(a, b, sort));
    return list.skip(offset).take(limit).toList();
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
      case WorkSort.recentAdded:
        final byAdded = b.updatedAt.compareTo(a.updatedAt);
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
    return 0;
  }

  @override
  Future<Map<MediaCategory, int>> countWorksByCategory() async {
    final out = <MediaCategory, int>{};
    for (final w in _works.values) {
      out[w.category] = (out[w.category] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<int> countPlayedWorks() async =>
      _works.values.where((w) => w.lastPlayedAt != null).length;

  @override
  Future<List<MediaItem>> itemsForWork(String groupKey) async {
    final list = _items.values.where((i) => i.groupKey == groupKey).toList();
    list.sort((a, b) {
      final s = (a.season ?? 0).compareTo(b.season ?? 0);
      if (s != 0) return s;
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
  Future<int> countWorks() async => _works.length;
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
