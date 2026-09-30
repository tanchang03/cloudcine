import '../../core/utils/filename_parser.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';
import '../entities/subtitle_track.dart';
import '../entities/drive_provider.dart';
import '../entities/scan_cursor.dart';

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

  // -------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------

  /// 作品列表（媒体库主界面）。
  ///
  /// [query] 会同时匹配作品标题与它下面任一文件的文件名 —— 用户记得的
  /// 往往是文件名（`S02E05` 这种），而列表上显示的是作品名。
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    String? query,
    int limit = 200,
    int offset = 0,
  });

  /// 某个作品下的全部媒体项，按「季 → 集 → 名称」排序。
  Future<List<MediaItem>> itemsForWork(String groupKey);

  /// 按 id 取媒体项。
  Future<MediaItem?> itemById(String id);

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
  }

  @override
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    String? query,
    int limit = 200,
    int offset = 0,
  }) async {
    var list = _works.values.toList();
    if (kind != null) list = list.where((w) => w.kind == kind).toList();
    final q = query?.trim().toLowerCase();
    if (q != null && q.isNotEmpty) {
      list = list.where((w) {
        if (w.title.toLowerCase().contains(q)) return true;
        return _items.values.any(
          (i) => i.groupKey == w.key && i.name.toLowerCase().contains(q),
        );
      }).toList();
    }
    list.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
    return list.skip(offset).take(limit).toList();
  }

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
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        durationMs: durationMs,
        source: source,
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        flags: flags,
        releaseGroup: releaseGroup,
        isSampleOrExtra: isSampleOrExtra,
        firstSeenAt: at,
        updatedAt: updatedAt,
      );
}
