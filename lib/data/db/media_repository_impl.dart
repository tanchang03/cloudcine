import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/utils/filename_parser.dart';
import '../../core/utils/subtitle_formats.dart';
import '../../core/utils/video_formats.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/entities/drive_provider.dart';
import '../../domain/entities/scan_cursor.dart';
import 'app_database.dart';

/// 基于 drift 的媒体索引库实现。
///
/// ## 两处刻意为之的设计
///
/// 1. **upsert 不动 `firstSeenAt`**。它决定「最近添加」排序，被每次扫描
///    刷新的话，老片子会天天冒到列表最前。
/// 2. **刮削结果不被本地解析覆盖**。作品行的 upsert 在 `source == online`
///    时保留原有的标题/海报/简介 —— 否则「扫一遍」就会把辛苦刮来的海报
///    冲成文件名。
class DriftMediaRepository implements MediaRepository {
  DriftMediaRepository(this._db);

  final AppDatabase _db;

  // -------------------------------------------------------------------
  // 写入
  // -------------------------------------------------------------------

  @override
  Future<void> upsertItems(List<MediaItem> items, {DateTime? now}) async {
    if (items.isEmpty) return;
    final ts = now ?? DateTime.now();

    await _db.batch((batch) {
      for (final item in items) {
        // 两道写入：全量（含 firstSeenAt）用于插入；
        // 冲突时只更新「会变」的字段，firstSeenAt 保持原值。
        batch.insert(
          _db.mediaItems,
          _toCompanion(item, firstSeenAt: ts),
          onConflict: DoUpdate(
            (_) => _toCompanion(item, firstSeenAt: ts, skipFirstSeen: true),
            target: [_db.mediaItems.id],
          ),
        );
      }
    });
  }

  @override
  Future<int> deleteItemsNotIn(
    DriveProvider provider,
    Set<String> keepIds,
  ) async {
    final deleted = await (_db.delete(_db.mediaItems)
          ..where((t) =>
              t.provider.equals(provider.id) & t.id.isNotIn(keepIds.toList())))
        .go();

    // 关联的字幕引用一并清掉。**不做级联删除**（没建外键），
    // 因为外键会让「先写媒体项、后写作品」的续扫中间态无法落库。
    if (deleted > 0) {
      await _db.customStatement(
        'DELETE FROM subtitle_refs WHERE item_id NOT IN '
        '(SELECT id FROM media_items)',
      );
    }
    return deleted;
  }

  @override
  Future<void> upsertWorks(List<MediaWork> works, {DateTime? now}) async {
    if (works.isEmpty) return;
    final ts = now ?? DateTime.now();

    // 先读回这批 key 的已有行，在 Dart 侧完成合并。
    //
    // 为什么不用 SQL 的 `DO UPDATE ... SET title = <旧列>`：
    // 那要求把「保留哪几列」写成 SQL 表达式，既没法用纯 Dart 单测覆盖，
    // 也容易写错而**静默**生效 —— `Value(old.title)` 看着像「保留旧值」，
    // 实际是把列对象当成字面量写进去。作品数远小于媒体项数，
    // 多一次 SELECT 换确定的语义是划算的。
    final keys = works.map((w) => w.key).toList(growable: false);
    final existingRows = await (_db.select(_db.mediaWorks)
          ..where((t) => t.key.isIn(keys)))
        .get();
    final existing = <String, MediaWork>{
      for (final row in existingRows) row.key: _toWork(row),
    };

    await _db.batch((batch) {
      for (final w in works) {
        final merged = mergeWorkForUpsert(w, existing[w.key], ts);
        batch.insert(
          _db.mediaWorks,
          _workCompanion(merged),
          onConflict: DoUpdate(
            (_) => _workCompanion(merged),
            target: [_db.mediaWorks.key],
          ),
        );
      }
    });
  }

  /// 合并「本次扫描看到的作品」与「库里已有的作品」。
  ///
  /// ## 为什么需要这一步
  ///
  /// 场景：第一次扫描走了 TMDB，刮到了海报和简介；用户第二天往网盘里加了
  /// 一集再扫一遍，这部作品重新经过**文件名解析**。若不保护，海报就会被
  /// 文件名顶掉 —— 而且用户看不出发生了什么，只会觉得「海报怎么没了」。
  ///
  /// 反过来，当本次结果**就是**刮削结果时一定要覆盖：那正是重新刮削的意义。
  ///
  /// ## 三组字段的不同处理
  ///
  /// | 字段 | 规则 |
  /// |---|---|
  /// | 元数据（标题/简介/海报/评分…） | 保护模式下取旧值；旧值缺失时用新值补空 |
  /// | 计数（itemCount/totalBytes） | 永远取新值 —— 它反映本次扫描看到的真实文件集合 |
  /// | `lastPlayedAt` | 永远保留旧值 —— 播放记录与扫描无关 |
  ///
  /// 暴露成 `static` 是为了能脱离数据库单测。
  static MediaWork mergeWorkForUpsert(
    MediaWork incoming,
    MediaWork? existing,
    DateTime ts,
  ) {
    if (existing == null) return incoming.copyWith(updatedAt: ts);

    // 「保护模式」：本次是文件名解析，而库里已有的是刮削结果
    // （`manual` 也算 —— 用户手工改过的当然更不能被文件名顶掉）。
    final protect = incoming.source == ScrapeSource.local &&
        existing.source != ScrapeSource.local;

    // 海报/背景图**换了 URL** 时必须丢掉本地缓存文件名：缓存是按内容
    // 命名的旧图，留着会让详情页一直显示上一版海报。
    final keepPosterFile = protect || incoming.posterUrl == existing.posterUrl;
    final keepBackdropFile = protect || incoming.backdropUrl == existing.backdropUrl;

    return MediaWork(
      key: incoming.key,
      provider: incoming.provider,
      kind: incoming.kind,
      title: protect ? existing.title : incoming.title,
      originalTitle: _preferOld(protect, existing.originalTitle, incoming.originalTitle),
      year: _preferOld(protect, existing.year, incoming.year),
      overview: _preferOld(protect, existing.overview, incoming.overview),
      posterUrl: _preferOld(protect, existing.posterUrl, incoming.posterUrl),
      posterFile: keepPosterFile
          ? (existing.posterFile ?? incoming.posterFile)
          : incoming.posterFile,
      backdropUrl: _preferOld(protect, existing.backdropUrl, incoming.backdropUrl),
      backdropFile: keepBackdropFile
          ? (existing.backdropFile ?? incoming.backdropFile)
          : incoming.backdropFile,
      rating: _preferOld(protect, existing.rating, incoming.rating),
      genres: protect && existing.genres.isNotEmpty
          ? existing.genres
          : incoming.genres,
      onlineId: _preferOld(protect, existing.onlineId, incoming.onlineId),
      source: protect ? existing.source : incoming.source,
      scrapedAt: protect ? existing.scrapedAt : incoming.scrapedAt,
      itemCount: incoming.itemCount,
      totalBytes: incoming.totalBytes,
      lastPlayedAt: existing.lastPlayedAt ?? incoming.lastPlayedAt,
      updatedAt: ts,
    );
  }

  /// 保护模式下优先保留旧值；旧值缺失时用新值补空。
  ///
  /// 「旧值缺失就补空」是有意的：文件名解析至少能给出年份，
  /// 而 TMDB 偶尔返回没有年份的条目 —— 这时把 `2023` 丢掉是净损失。
  static T? _preferOld<T>(bool protect, T? oldValue, T? newValue) =>
      protect ? (oldValue ?? newValue) : newValue;

  @override
  Future<MediaWork?> workByKey(String key) async {
    final row = await (_db.select(_db.mediaWorks)
          ..where((t) => t.key.equals(key))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toWork(row);
  }

  @override
  Future<void> upsertSubtitles(
    List<SubtitleRef> refs, {
    DateTime? now,
  }) async {
    if (refs.isEmpty) return;
    await _db.batch((batch) {
      for (final ref in refs) {
        batch.insert(
          _db.subtitleRefs,
          _toSubtitleCompanion(ref),
          onConflict: DoUpdate(
            (_) => _toSubtitleCompanion(ref),
            target: [_db.subtitleRefs.id],
          ),
        );
      }
    });
  }

  @override
  Future<int> deleteSubtitlesNotIn(
    DriveProvider provider,
    Set<String> keepItemIds,
  ) async {
    // 白名单为空时**什么都不删**：那通常意味着「本次一个字幕都没配上」
    // （比如这个网盘的字幕本来就很少），按空白名单删会把整库字幕清空。
    if (keepItemIds.isEmpty) return 0;

    // 字幕表里没有 provider 列（字幕是挂到媒体项上的），所以先取该网盘
    // 的全部媒体项 id，在 Dart 侧算差集，再按 id 删。
    //
    // 不写成一条 SQL 的子查询：`NOT IN` 配上几千个 id 的占位符会撞上
    // SQLite 的变量数量上限（默认 999），而媒体库上万条是常态。
    final rows = await (_db.selectOnly(_db.mediaItems)
          ..addColumns([_db.mediaItems.id])
          ..where(_db.mediaItems.provider.equals(provider.id)))
        .get();
    final providerItemIds =
        rows.map((r) => r.read(_db.mediaItems.id)).whereType<String>().toSet();

    final doomed = providerItemIds
        .where((id) => !keepItemIds.contains(id))
        .toList(growable: false);
    if (doomed.isEmpty) return 0;

    return (_db.delete(_db.subtitleRefs)
          ..where((t) => t.itemId.isIn(doomed)))
        .go();
  }

  @override
  Future<void> saveScanCursor(ScanCursor cursor) async {
    await _db.into(_db.scanCursors).insertOnConflictUpdate(
          ScanCursorsCompanion.insert(
            provider: cursor.provider.id,
            rootId: cursor.rootId,
            rootPath: Value(cursor.rootPath),
            pendingDirs: Value(
              jsonEncode(cursor.pendingDirs.map((d) => d.toJson()).toList()),
            ),
            currentDir: Value(
              cursor.currentDir == null
                  ? null
                  : jsonEncode(cursor.currentDir!.toJson()),
            ),
            currentPageToken: Value(cursor.currentPageToken),
            stage: cursor.stage.name,
            scannedDirs: Value(cursor.scannedDirs),
            scannedFiles: Value(cursor.scannedFiles),
            foundTracks: Value(cursor.foundTracks),
            totalBytes: Value(cursor.totalBytes),
            failedDirs: Value(cursor.failedDirs),
            lastError: Value(cursor.lastError),
            updatedAt: cursor.updatedAt,
          ),
        );
  }

  @override
  Future<void> markPlayed(String itemId, DateTime at) async {
    await (_db.update(_db.mediaItems)..where((t) => t.id.equals(itemId)))
        .write(MediaItemsCompanion(lastPlayedAt: Value(at)));

    final item = await itemById(itemId);
    if (item != null) {
      await (_db.update(_db.mediaWorks)
            ..where((t) => t.key.equals(item.groupKey)))
          .write(MediaWorksCompanion(lastPlayedAt: Value(at)));
    }
  }

  // -------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------

  @override
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    String? query,
    int limit = 200,
    int offset = 0,
  }) async {
    final q = _db.select(_db.mediaWorks);

    if (kind != null) {
      q.where((t) => t.kind.equals(kind.name));
    }

    final trimmed = query?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      final like = '%$trimmed%';
      q.where((t) {
        // 标题命中，**或者**它下面任一文件的文件名命中。
        // 后者是必须的：用户记得的往往是 `S02E05` 这种文件名，
        // 而列表上显示的是作品名。
        final sub = _db.selectOnly(_db.mediaItems)
          ..addColumns([_db.mediaItems.id])
          ..where(_db.mediaItems.groupKey.equalsExp(t.key) &
              _db.mediaItems.name.like(like));
        return t.title.like(like) | existsQuery(sub);
      });
    }

    q
      ..orderBy([
        // 最近播放的排最前，其次是年份新的。
        (t) => OrderingTerm.desc(t.lastPlayedAt),
        (t) => OrderingTerm.desc(t.year),
        (t) => OrderingTerm.asc(t.title),
      ])
      ..limit(limit, offset: offset);

    final rows = await q.get();
    return rows.map(_toWork).toList();
  }

  @override
  Future<List<MediaItem>> itemsForWork(String groupKey) async {
    final rows = await (_db.select(_db.mediaItems)
          ..where((t) => t.groupKey.equals(groupKey))
          // 排序在 Dart 侧做（见下），SQL 侧只保证稳定
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
    final items = rows.map(_toItem).toList();
    // 「季 → 集 → 名称」。放在 Dart 里排是因为 SQL 的 NULL 排序行为
    // 在各驱动/版本上不一致（电影没有季集号），而这里必须稳定。
    items.sort((a, b) {
      final s = (a.season ?? 0).compareTo(b.season ?? 0);
      if (s != 0) return s;
      final e = (a.episode ?? 0).compareTo(b.episode ?? 0);
      if (e != 0) return e;
      return a.name.compareTo(b.name);
    });
    return items;
  }

  @override
  Future<MediaItem?> itemById(String id) async {
    final row = await (_db.select(_db.mediaItems)
          ..where((t) => t.id.equals(id))
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toItem(row);
  }

  @override
  Future<List<SubtitleTrack>> subtitlesForItem(String itemId) async {
    final rows = await (_db.select(_db.subtitleRefs)
          ..where((t) => t.itemId.equals(itemId)))
        .get();
    return rows.map(_toSubtitle).toList();
  }

  @override
  Future<ScanCursor?> loadScanCursor(DriveProvider provider) async {
    final row = await (_db.select(_db.scanCursors)
          ..where((t) => t.provider.equals(provider.id))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;

    List<PendingDir> pending = const [];
    try {
      final raw = jsonDecode(row.pendingDirs);
      if (raw is List) {
        pending = raw
            .whereType<Map>()
            .map((m) => PendingDir.fromJson(m.cast<String, Object?>()))
            .toList();
      }
    } catch (_) {
      pending = const [];
    }

    PendingDir? current;
    final cur = row.currentDir;
    if (cur != null && cur.isNotEmpty) {
      try {
        final raw = jsonDecode(cur);
        if (raw is Map) current = PendingDir.fromJson(raw.cast<String, Object?>());
      } catch (_) {
        current = null;
      }
    }

    return ScanCursor(
      provider: provider,
      rootId: row.rootId,
      rootPath: row.rootPath,
      pendingDirs: pending,
      currentDir: current,
      currentPageToken: row.currentPageToken,
      stage: ScanStage.values.firstWhere(
        (s) => s.name == row.stage,
        orElse: () => ScanStage.idle,
      ),
      scannedDirs: row.scannedDirs,
      scannedFiles: row.scannedFiles,
      foundTracks: row.foundTracks,
      totalBytes: row.totalBytes,
      failedDirs: row.failedDirs,
      lastError: row.lastError,
      updatedAt: row.updatedAt,
    );
  }

  @override
  Future<List<MediaItem>> recentlyPlayed({int limit = 20}) async {
    final rows = await (_db.select(_db.mediaItems)
          ..where((t) => t.lastPlayedAt.isNotNull())
          ..orderBy([(t) => OrderingTerm.desc(t.lastPlayedAt)])
          ..limit(limit))
        .get();
    return rows.map(_toItem).toList();
  }

  @override
  Future<List<MediaItem>> recentlyAdded({int limit = 20}) async {
    final rows = await (_db.select(_db.mediaItems)
          ..orderBy([(t) => OrderingTerm.desc(t.firstSeenAt)])
          ..limit(limit))
        .get();
    return rows.map(_toItem).toList();
  }

  @override
  Future<int> countItems() async {
    final expr = _db.mediaItems.id.count();
    final row = await (_db.selectOnly(_db.mediaItems)..addColumns([expr]))
        .getSingle();
    return row.read(expr) ?? 0;
  }

  @override
  Future<int> countWorks() async {
    final expr = _db.mediaWorks.key.count();
    final row = await (_db.selectOnly(_db.mediaWorks)..addColumns([expr]))
        .getSingle();
    return row.read(expr) ?? 0;
  }

  // -------------------------------------------------------------------
  // 映射
  // -------------------------------------------------------------------

  MediaItemsCompanion _toCompanion(
    MediaItem item, {
    required DateTime firstSeenAt,
    bool skipFirstSeen = false,
  }) =>
      MediaItemsCompanion(
        id: Value(item.id),
        provider: Value(item.provider.id),
        fileId: Value(item.fileId),
        name: Value(item.name),
        dirId: Value(item.dirId),
        dirPath: Value(item.dirPath),
        groupKey: Value(item.groupKey),
        kind: Value(item.kind.name),
        title: Value(item.title),
        year: Value(item.year),
        season: Value(item.season),
        episode: Value(item.episode),
        episodeEnd: Value(item.episodeEnd),
        container: Value(item.container.name),
        resolution: Value(item.resolution?.label),
        sizeBytes: Value(item.sizeBytes),
        modifiedAt: Value(item.modifiedAt),
        durationMs: Value(item.durationMs),
        source: Value(item.source),
        videoCodec: Value(item.videoCodec),
        audioCodec: Value(item.audioCodec),
        flags: Value(jsonEncode(item.flags.toList())),
        releaseGroup: Value(item.releaseGroup),
        isSampleOrExtra: Value(item.isSampleOrExtra),
        firstSeenAt: skipFirstSeen ? const Value.absent() : Value(firstSeenAt),
        updatedAt: Value(item.updatedAt),
      );

  MediaWorksCompanion _workCompanion(MediaWork w) =>
      MediaWorksCompanion(
        key: Value(w.key),
        provider: Value(w.provider.id),
        kind: Value(w.kind.name),
        title: Value(w.title),
        originalTitle: Value(w.originalTitle),
        year: Value(w.year),
        overview: Value(w.overview),
        posterUrl: Value(w.posterUrl),
        posterFile: Value(w.posterFile),
        backdropUrl: Value(w.backdropUrl),
        backdropFile: Value(w.backdropFile),
        rating: Value(w.rating),
        genres: Value(jsonEncode(w.genres)),
        onlineId: Value(w.onlineId),
        source: Value(w.source.name),
        scrapedAt: Value(w.scrapedAt),
        itemCount: Value(w.itemCount),
        totalBytes: Value(w.totalBytes),
        lastPlayedAt: Value(w.lastPlayedAt),
        updatedAt: Value(w.updatedAt),
      );

  SubtitleRefsCompanion _toSubtitleCompanion(SubtitleRef ref) {
    final t = ref.track;
    return SubtitleRefsCompanion(
      id: Value(t.id),
      itemId: Value(ref.itemId),
      origin: Value(t.origin.name),
      label: Value(t.label),
      format: Value(t.format.name),
      languageCode: Value(t.language?.code),
      languageLabel: Value(t.language?.label),
      fileId: Value(t.fileId),
      fileName: Value(t.fileName),
      localPath: Value(t.localPath),
      embeddedTrackId: Value(t.embeddedTrackId),
      isForced: Value(t.isForced),
      isSdh: Value(t.isSdh),
      isDefault: Value(t.isDefault),
    );
  }

  MediaItem _toItem(MediaItemRow row) => MediaItem(
        provider: DriveProvider.fromId(row.provider) ?? DriveProvider.quark,
        fileId: row.fileId,
        name: row.name,
        dirId: row.dirId,
        dirPath: row.dirPath,
        groupKey: row.groupKey,
        kind: MediaKind.values.firstWhere(
          (k) => k.name == row.kind,
          orElse: () => MediaKind.unknown,
        ),
        title: row.title,
        year: row.year,
        season: row.season,
        episode: row.episode,
        episodeEnd: row.episodeEnd,
        container: VideoContainer.values.firstWhere(
          (c) => c.name == row.container,
          orElse: () => VideoContainer.other,
        ),
        resolution: _resolutionFromLabel(row.resolution),
        sizeBytes: row.sizeBytes,
        modifiedAt: row.modifiedAt,
        durationMs: row.durationMs,
        source: row.source,
        videoCodec: row.videoCodec,
        audioCodec: row.audioCodec,
        flags: _stringSet(row.flags),
        releaseGroup: row.releaseGroup,
        isSampleOrExtra: row.isSampleOrExtra,
        firstSeenAt: row.firstSeenAt,
        updatedAt: row.updatedAt,
      );

  MediaWork _toWork(MediaWorkRow row) => MediaWork(
        key: row.key,
        provider: DriveProvider.fromId(row.provider) ?? DriveProvider.quark,
        kind: MediaKind.values.firstWhere(
          (k) => k.name == row.kind,
          orElse: () => MediaKind.unknown,
        ),
        title: row.title,
        originalTitle: row.originalTitle,
        year: row.year,
        overview: row.overview,
        posterUrl: row.posterUrl,
        posterFile: row.posterFile,
        backdropUrl: row.backdropUrl,
        backdropFile: row.backdropFile,
        rating: row.rating,
        genres: _stringList(row.genres),
        onlineId: row.onlineId,
        source: ScrapeSource.values.firstWhere(
          (s) => s.name == row.source,
          orElse: () => ScrapeSource.local,
        ),
        scrapedAt: row.scrapedAt,
        itemCount: row.itemCount,
        totalBytes: row.totalBytes,
        lastPlayedAt: row.lastPlayedAt,
        updatedAt: row.updatedAt,
      );

  SubtitleTrack _toSubtitle(SubtitleRefRow row) => SubtitleTrack(
        id: row.id,
        origin: SubtitleOrigin.values.firstWhere(
          (o) => o.name == row.origin,
          orElse: () => SubtitleOrigin.cloudFile,
        ),
        label: row.label,
        format: SubtitleFormat.values.firstWhere(
          (f) => f.name == row.format,
          orElse: () => SubtitleFormat.other,
        ),
        language: row.languageCode == null
            ? null
            : SubtitleLanguage(
                code: row.languageCode!,
                label: row.languageLabel ?? row.languageCode!,
              ),
        fileId: row.fileId,
        fileName: row.fileName,
        localPath: row.localPath,
        embeddedTrackId: row.embeddedTrackId,
        isForced: row.isForced,
        isSdh: row.isSdh,
        isDefault: row.isDefault,
        isExternal: row.origin != SubtitleOrigin.embedded.name,
      );

  /// 分辨率按 **label** 反查，见 `tables.dart` 里 `resolution` 列的注释。
  static VideoResolution? _resolutionFromLabel(String? label) {
    if (label == null || label.isEmpty) return null;
    for (final r in VideoResolution.values) {
      if (r.label == label) return r;
    }
    return null;
  }

  static Set<String> _stringSet(String? json) {
    final list = _stringList(json);
    return list.toSet();
  }

  static List<String> _stringList(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final raw = jsonDecode(json);
      if (raw is List) return raw.map((e) => '$e').toList();
    } catch (_) {
      // 脏数据不该让整行读不出来
    }
    return const [];
  }
}
