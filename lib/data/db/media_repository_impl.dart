import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/drive_paths.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/filename_parser.dart';
import '../../core/utils/media_category.dart';
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
    if (existing == null) {
      return incoming.copyWith(
        // 新作品首次入库时补 firstSeenAt：WorkSeedBook.build 没传这列，
        // 但「最近添加」排序需要它。用 ts（本次扫描时刻）兜底。
        firstSeenAt: incoming.firstSeenAt ?? ts,
        updatedAt: ts,
      );
    }

    // 「保护模式」：本次是文件名解析，而库里已有的是刮削结果
    // （`manual` 也算 —— 用户手工改过的当然更不能被文件名顶掉）。
    final protect = incoming.source == ScrapeSource.local &&
        existing.source != ScrapeSource.local;

    // 海报/背景图**换了 URL** 时必须丢掉本地缓存文件名：缓存是按内容
    // 命名的旧图，留着会让详情页一直显示上一版海报。
    //
    // `incoming.posterUrl == null` 也算「没换」：那种情况下上面保留了旧地址，
    // 缓存文件名自然也该跟着保留（否则两个字段会互相矛盾）。
    final keepPosterFile = protect ||
        incoming.posterUrl == null ||
        incoming.posterUrl == existing.posterUrl;
    final keepBackdropFile = protect || incoming.backdropUrl == existing.backdropUrl;

    // **生效后的类型列表**：保护模式下沿用库里的，否则用本次的。
    //
    // 抽出来只算一次，是为了让 `category` 与 `genres` 两列永远基于**同一份
    // 输入** —— 各算各的会造出「分类是按 A 折算的、`genres` 存的却是 B」
    // 这种自相矛盾的行，而它不会报错，只会在下一次刮削时算出一个莫名其妙的
    // 分类。
    final effectiveGenres = protect && existing.genres.isNotEmpty
        ? existing.genres
        : incoming.genres;

    // 海报地址**永不为空**：本次算不出新地址时保留旧的。
    //
    // 为什么不能让它变成 null：网盘缩略图地址是「扫描那一刻服务端有没有
    // 生成预览图」的快照（实测视频里约七成有）。某一次扫描恰好没拿到，
    // 写 null 会让这张海报从墙上消失 —— 而盘上的缓存文件还在，
    // 只是没人再去引用它。地址本身是稳定的（TMDB 内容寻址；
    // 夸克按 fid 固定），所以「旧的留着」没有任何副作用。
    final resolvedPosterUrl =
        _preferOld(protect, existing.posterUrl, incoming.posterUrl) ??
            existing.posterUrl;

    return MediaWork(
      key: incoming.key,
      provider: incoming.provider,
      kind: incoming.kind,
      // 分类：**永远取新值，但新值要先把 `genres` 折算进去**。
      //
      // 「永远取新值」这条不能改：放进 `protect` 分支会有一个很难查的后果 ——
      // 第一次扫描时判成「其他」的作品，之后无论怎么重扫都修不回来
      // （保护模式会一直保留那个旧的「其他」）。
      //
      // 但**只看 `incoming.category` 也不够**：扫描期的
      // `MediaCategoryGuesser.guess` 拿不到 `genres`（那时还没刮削），
      // 所以重扫一部已刮削的作品时，incoming 那个分类是按目录名 / 结构
      // 重算的**旧口径**。直接用它会把刮削刚修正过来的分类冲回去 ——
      // 用户看到的是「刮削后进了动漫栏，加一集重扫又回电影栏」。
      //
      // 所以这里拿 [effectiveGenres] 再折算一次；`fromGenres` 给不出结论时
      // （剧情 / 科幻这类不改变栏目）才退回 `incoming.category` ——
      // 与 `WorkScraper._categoryFor` 是同一套口径。
      category: MediaCategoryGuesser.fromGenres(effectiveGenres) ??
          incoming.category,
      title: protect ? existing.title : incoming.title,
      originalTitle: _preferOld(protect, existing.originalTitle, incoming.originalTitle),
      year: _preferOld(protect, existing.year, incoming.year),
      overview: _preferOld(protect, existing.overview, incoming.overview),
      // 海报地址**永不为空**：本次算不出新地址时保留旧的。
      //
      // 为什么不能让它变成 null：网盘缩略图地址是「扫描那一刻服务端有没有
      // 生成预览图」的快照（实测视频里约七成有）。某一次扫描恰好没拿到，
      // 写 null 会让这张海报从墙上消失 —— 而盘上的缓存文件还在，
      // 只是没人再去引用它。地址本身是稳定的（TMDB 内容寻址；
      // 夸克按 fid 固定），所以「旧的留着」没有任何副作用。
      posterUrl: resolvedPosterUrl,
      // 锚点跟着地址走：地址没换（`resolvedPosterUrl == existing.posterUrl`）
      // 就说明还是同一张图，旧的锚点继续有效 —— 用 `??` 兜一手老库里的
      // null（`posterFaceX` 是 v5 才加的列，v5 之前入库的作品该列都是空）。
      // 地址换了就必须取本次的锚点：新图可能是 2:3 的 TMDB 海报，
      // 那种图根本没有锚点，本次算出来就是 null —— 这里的 null 是**结论**，
      // 不是缺失，所以不能回退到旧值（否则会拿剧中帧的人脸位置去裁海报）。
      posterFaceX: resolvedPosterUrl == existing.posterUrl
          ? (existing.posterFaceX ?? incoming.posterFaceX)
          : incoming.posterFaceX,
      posterFile: keepPosterFile
          ? (existing.posterFile ?? incoming.posterFile)
          : incoming.posterFile,
      backdropUrl: _preferOld(protect, existing.backdropUrl, incoming.backdropUrl),
      backdropFile: keepBackdropFile
          ? (existing.backdropFile ?? incoming.backdropFile)
          : incoming.backdropFile,
      rating: _preferOld(protect, existing.rating, incoming.rating),
      genres: effectiveGenres,
      onlineId: _preferOld(protect, existing.onlineId, incoming.onlineId),
      source: protect ? existing.source : incoming.source,
      scrapedAt: protect ? existing.scrapedAt : incoming.scrapedAt,
      itemCount: incoming.itemCount,
      totalBytes: incoming.totalBytes,
      // `lastModifiedAt` 永远取本次扫描的值：它是作品下所有文件
      // `modifiedAt` 的最大值，重扫就是为了更新它。
      lastModifiedAt: incoming.lastModifiedAt,
      // `firstSeenAt` 保留旧值：它决定「最近添加」排序，被每次扫描刷新的话，
      // 老片子会天天冒到列表最前。
      firstSeenAt: existing.firstSeenAt ?? incoming.firstSeenAt,
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

  @override
  Future<void> saveResumePosition(String itemId, Duration? position) async {
    // 零 / 负位置与「没有」是同一件事：写 0 只会让 `resumePositions` 里多出
    // 一个恒假的值，而 NULL 才是这一列真正的「没存过」。
    final ms = (position == null || position <= Duration.zero)
        ? null
        : position.inMilliseconds;
    await (_db.update(_db.mediaItems)..where((t) => t.id.equals(itemId)))
        .write(MediaItemsCompanion(resumePositionMs: Value(ms)));
  }

  // -------------------------------------------------------------------
  // 读取
  // -------------------------------------------------------------------

  @override
  Future<List<MediaWork>> listWorks({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
    Set<int>? decades,
    Set<String>? genres,
    WorkSort sort = WorkSort.recentModified,
    int limit = 200,
    int offset = 0,
  }) async {
    final q = _db.select(_db.mediaWorks);

    // 分类 / 搜索 / 「播过没有」三件事走共用表达式 —— 两个计数查询要用
    // 同一份条件（理由见 `_workConditions`）。
    final base = _workConditions(
      kind: kind,
      category: category,
      playedOnly: playedOnly,
      query: query,
    );
    if (base != null) q.where((_) => base);

    // 年代：`decades` 里存的是**年代起始年**（2020 = 2020–2029），
    // 每项展开成 `year >= d0 AND year < d0+10`，多项之间是「或」。
    //
    // `year IS NULL` 的行（还没解析出年份）在任何年代条件下都不命中 ——
    // 这与 `InMemoryMediaRepository` 的口径一致（那边要求 `w.year != null`），
    // 也和面板上的角标一致（`countWorksByDecade` 不统计它们）。
    if (decades != null && decades.isNotEmpty) {
      q.where((t) {
        Expression<bool>? any;
        for (final d0 in decades) {
          final cond = t.year.isBiggerOrEqualValue(d0) &
              t.year.isSmallerThanValue(d0 + 10);
          any = any == null ? cond : (any | cond);
        }
        return any!;
      });
    }

    // 类型：`genres` 列是 JSON 数组文本（`["动画","科幻"]`），
    // 所以匹配串**必须带上引号** —— `LIKE '%动画%'` 会把「动画片」也捞进来，
    // 而 `LIKE '%"动画"%'` 只在它确实是数组里一个独立元素时命中。
    //
    // 多项之间是「或」（任一命中即可）：一部片子只会有一两个类型，
    // 取交集几乎永远筛不出东西 —— 这一点写进了接口文档。
    if (genres != null && genres.isNotEmpty) {
      q.where((t) {
        Expression<bool>? any;
        for (final g in genres) {
          // 类型名里理论上不会出现引号，但真要出现（脏数据）就会把 LIKE
          // 串截断。转义成本很低，顺手做掉。
          final escaped = g.replaceAll('"', '""');
          final cond = t.genres.like('%"$escaped"%');
          any = any == null ? cond : (any | cond);
        }
        return any!;
      });
    }

    q
      ..orderBy(_orderingFor(sort))
      ..limit(limit, offset: offset);

    final rows = await q.get();
    return rows.map(_toWork).toList();
  }

  /// 作品列表的**基础筛选条件**（分类 / 搜索 / 「播过没有」/ 结构）。
  ///
  /// 返回 `null` 表示「一条都不限」—— 调用方可以据此完全跳过 `WHERE`，
  /// 而不是塞一个恒真表达式进去。
  ///
  /// ## 为什么要抽出来
  ///
  /// [listWorks]、[countWorksByDecade]、[countWorksByGenre] 三处都要这一份
  /// 条件，而其中两条判据都很微妙：
  ///
  ///   - **分类**要处理「空串 = 还没判定过」的历史行（见 [_categoryCondition]）；
  ///   - **搜索**要同时命中标题与**文件名**（EXISTS 子查询）。
  ///
  /// 三处各写一遍迟早会漂移，而漂移的表现是「列表和面板角标对不上」——
  /// 用户看得见，却完全猜不出是哪一处的问题。
  Expression<bool>? _workConditions({
    MediaKind? kind,
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
  }) {
    final t = _db.mediaWorks;
    Expression<bool>? cond;

    void add(Expression<bool> c) => cond = cond == null ? c : (cond! & c);

    if (kind != null) add(t.kind.equals(kind.name));

    // 「最近播放」栏。判据是 `last_played_at IS NOT NULL` ——
    // **不是**「比某个时间新」：后者会把「上个月看过」也算成没看过，
    // 而这一栏的意思是「我看过的」，不是「我最近看的」（排序负责「最近」）。
    if (playedOnly) add(t.lastPlayedAt.isNotNull());

    if (category != null) add(_categoryCondition(category));

    final trimmed = query?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      final like = '%$trimmed%';
      // 标题命中，**或者**它下面任一文件的文件名命中。
      // 后者是必须的：用户记得的往往是 `S02E05` 这种文件名，
      // 而列表上显示的是作品名。
      final sub = _db.selectOnly(_db.mediaItems)
        ..addColumns([_db.mediaItems.id])
        ..where(_db.mediaItems.groupKey.equalsExp(t.key) &
            _db.mediaItems.name.like(like));
      add(t.title.like(like) | existsQuery(sub));
    }

    return cond;
  }

  /// 单个分类的 SQL 条件。
  ///
  /// 空串是「还没判定过」（v3 之前的行）。这里用与 `_categoryOf` 同一套口径
  /// 现算，等价于「空串时按 kind 猜」。写进 SQL 而不是拉回来在 Dart 里过滤，
  /// 是为了让分类筛选仍然是索引上的一次范围扫描 —— 几千部作品在 Dart 侧
  /// 过滤会让「点一下分类栏」卡住半秒。
  ///
  /// 判据与 `_categoryOf` 保持一致：**先看结构（kind），再看关键词**。
  /// 这里只能表达结构那一半（SQL 里做不了关键词匹配），所以命中的是
  /// 「电影 / 剧集 / 其他」这三档；关键词档（动漫 / 综艺 / 纪录片）只认
  /// 已经落库的值 —— 而落库由回填与扫描保证。
  Expression<bool> _categoryCondition(MediaCategory category) {
    final t = _db.mediaWorks;
    return switch (category) {
      MediaCategory.movie => t.category.equals(category.name) |
          (t.category.equals('') & t.kind.equals(MediaKind.movie.name)),
      MediaCategory.series => t.category.equals(category.name) |
          (t.category.equals('') & t.kind.equals(MediaKind.episode.name)),
      MediaCategory.other => t.category.equals(category.name) |
          (t.category.equals('') & t.kind.equals(MediaKind.unknown.name)),
      MediaCategory.anime ||
      MediaCategory.variety ||
      MediaCategory.documentary =>
        t.category.equals(category.name),
    };
  }

  /// 排序规则。
  ///
  /// 每一档都用「年份倒序 → 标题升序」收尾，保证**同一档内顺序稳定** ——
  /// 否则评分相同的一批作品每次刷新都会换位置，看起来像列表在乱跳。
  ///
  /// `lastPlayedAt` 的 NULL 用 `OrderingTerm.desc` 时在 SQLite 里排最后
  /// （NULL 被视为最小值），这正是「没播过的垫底」想要的效果，
  /// 所以不需要额外的 `NULLS LAST`（SQLite 也不支持那个语法）。
  List<OrderingTerm Function($MediaWorksTable)> _orderingFor(WorkSort sort) {
    final tie = <OrderingTerm Function($MediaWorksTable)>[
      (t) => OrderingTerm.desc(t.year),
      (t) => OrderingTerm.asc(t.title),
    ];
    return switch (sort) {
      WorkSort.recentModified => [
          // `lastModifiedAt` 为 NULL 时（没拿到网盘修改时间），
          // `OrderingTerm.desc` 会把它排最后 —— 正好是我们想要的效果。
          (t) => OrderingTerm.desc(t.lastModifiedAt),
          ...tie,
        ],
      WorkSort.recentAdded => [
          // `firstSeenAt` 为 NULL 时（老库 v6 之前没有这列），
          // `OrderingTerm.desc` 会把它排最后。
          (t) => OrderingTerm.desc(t.firstSeenAt),
          ...tie,
        ],
      WorkSort.recentPlayed => [
          (t) => OrderingTerm.desc(t.lastPlayedAt),
          ...tie,
        ],
      WorkSort.rating => [
          (t) => OrderingTerm.desc(t.rating),
          ...tie,
        ],
      WorkSort.year => [
          (t) => OrderingTerm.desc(t.year),
          (t) => OrderingTerm.asc(t.title),
        ],
      WorkSort.title => [(t) => OrderingTerm.asc(t.title)],
    };
  }

  /// 把 `category` 列修正到当前规则下的正确值。
  ///
  /// ## 它现在管两件事（以前只管一件）
  ///
  ///   1. **老库回填**：v3 之前入库的行 `category` 是空串（那时还没有这一列），
  ///      现算一次补上；
  ///   2. **让刮削结果对老数据也生效**：`WorkScraper` 会把 TMDB 的类型
  ///      （`genres`）折算成栏目，但那只对**这次之后**的刮削有效。用户已经
  ///      刮过的那批作品里 `genres` 早就在库、`category` 却还是扫描期判的
  ///      旧值 —— 这一遍负责对齐，否则用户得逐部重刮才看得到分类变对。
  ///
  /// ## 两件事的判据不同，别合并
  ///
  ///   - 空串 → 走完整的 [MediaCategoryGuesser.guessFromWork]（没有任何既往
  ///     判定可保留，只能从头猜）；
  ///   - 非空串 → **只看 `genres`**。绝不能走完整 `guess`：它的最后一步是
  ///     「按 kind 落电影/剧集」，会把扫描期靠目录名判出来的「综艺」冲成
  ///     「剧集」（理由见 `WorkScraper._categoryFor` 的长注释）。
  ///
  /// ## 为什么不再用 `where(category = '')` 缩小范围
  ///
  /// 加上第 2 件事之后，「哪些行需要修」取决于 `genres` 的内容，光看
  /// `category` 已经判断不出来了。多读几列的开销可以忽略（几千行 × 5 个短
  /// 文本列），而**只在真的要变时才写** —— 修好之后每次启动都是
  /// 「读一遍、零写入」，会自然收敛。
  @override
  Future<int> backfillWorkCategories() async {
    // 只取需要的五列：几千行作品表上做一次全列物化是浪费。
    final rows = await (_db.selectOnly(_db.mediaWorks)
          ..addColumns([
            _db.mediaWorks.key,
            _db.mediaWorks.kind,
            _db.mediaWorks.title,
            _db.mediaWorks.genres,
            _db.mediaWorks.category,
          ]))
        .get();

    if (rows.isEmpty) return 0;

    var fixed = 0;
    await _db.batch((batch) {
      for (final row in rows) {
        final key = row.read(_db.mediaWorks.key);
        if (key == null) continue;

        final stored = row.read(_db.mediaWorks.category) ?? '';
        final genres = _stringList(row.read(_db.mediaWorks.genres) ?? '[]');

        final MediaCategory? target;
        if (stored.isEmpty) {
          target = MediaCategoryGuesser.guessFromWork(
            kind: MediaKind.values.firstWhere(
              (k) => k.name == row.read(_db.mediaWorks.kind),
              orElse: () => MediaKind.unknown,
            ),
            title: row.read(_db.mediaWorks.title) ?? '',
            genres: genres,
          );
        } else {
          // 非空：只看 genres 能不能给出结论；给不出就**保留原值**
          // （null 表示「这条证据没意见」，不是「归到其他」）。
          target = MediaCategoryGuesser.fromGenres(genres);
        }

        if (target == null || target.name == stored) continue;

        batch.update(
          _db.mediaWorks,
          MediaWorksCompanion(category: Value(target.name)),
          where: (t) => t.key.equals(key),
        );
        fixed++;
      }
    });

    if (fixed > 0) {
      diag.info('数据库', '分类修正完成：$fixed 部作品（老库回填 + 刮削类型折算）');
    }
    return fixed;
  }

  @override
  Future<Map<MediaCategory, int>> countWorksByCategory() async {
    final count = _db.mediaWorks.key.count();
    final query = _db.selectOnly(_db.mediaWorks)
      ..addColumns([_db.mediaWorks.category, count])
      ..groupBy([_db.mediaWorks.category]);

    final out = <MediaCategory, int>{};
    for (final row in await query.get()) {
      final raw = row.read(_db.mediaWorks.category) ?? '';
      final n = row.read(count) ?? 0;
      // 空串（还没回填）不单独成栏 —— 归到「其他」，与 `_categoryOf` 的
      // 兜底口径一致：界面上的角标之和应当等于作品总数，
      // 多出一个「未分类」的隐藏桶只会让数字对不上。
      final category =
          raw.isEmpty ? MediaCategory.other : MediaCategory.fromName(raw);
      out[category] = (out[category] ?? 0) + n;
    }
    return out;
  }

  @override
  Future<int> countPlayedWorks() async {
    final expr = _db.mediaWorks.key.count();
    final row = await (_db.selectOnly(_db.mediaWorks)
          ..addColumns([expr])
          ..where(_db.mediaWorks.lastPlayedAt.isNotNull()))
        .getSingle();
    return row.read(expr) ?? 0;
  }

  @override
  Future<Map<int, int>> countWorksByDecade({
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
  }) async {
    // 只读 `year` 一列：作品表有十几列，为了一组数字把整行物化是浪费。
    //
    // 不在 SQL 里 `GROUP BY year / 10 * 10`：那要靠 SQLite 的整数除法
    // （两个 INTEGER 相除会截断），而 drift 的表达式类型是 `int`，
    // 一旦哪次 `year` 的列类型变成 REAL 就会静默变成浮点分组 ——
    // 在这里用 Dart 的 `~/` 算，行为是确定的，且与内存实现逐字一致。
    final q = _db.selectOnly(_db.mediaWorks)
      ..addColumns([_db.mediaWorks.year]);
    // 与 `listWorks` 共用条件：角标必须严格等于「清空年代/类型后列表里的
    // 条数」，否则用户会点到一个空列表（理由见接口文档）。
    final cond = _workConditions(
      category: category,
      playedOnly: playedOnly,
      query: query,
    );
    if (cond != null) q.where(cond);

    final out = <int, int>{};
    for (final row in await q.get()) {
      final y = row.read(_db.mediaWorks.year);
      // 没有年份的作品不进表 —— 与 `listWorks` 的年代过滤口径一致。
      if (y == null) continue;
      final d = y ~/ 10 * 10;
      out[d] = (out[d] ?? 0) + 1;
    }
    return out;
  }

  @override
  Future<Map<String, int>> countWorksByGenre({
    MediaCategory? category,
    bool playedOnly = false,
    String? query,
  }) async {
    // 类型存在 `genres` 列（JSON 数组文本）里，SQL 数不出来 ——
    // 只能读出这一列在 Dart 里拆。好在仍然只读一列、不碰整行。
    final q = _db.selectOnly(_db.mediaWorks)
      ..addColumns([_db.mediaWorks.genres]);
    final cond = _workConditions(
      category: category,
      playedOnly: playedOnly,
      query: query,
    );
    if (cond != null) q.where(cond);

    final out = <String, int>{};
    for (final row in await q.get()) {
      // 去重：`genres` 理论上不重复，但数据脏了时角标也不该大于作品数。
      for (final g in _stringList(row.read(_db.mediaWorks.genres)).toSet()) {
        out[g] = (out[g] ?? 0) + 1;
      }
    }
    return out;
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
  Future<List<MediaItem>> listItems({
    String? pathPrefix,
    String? query,
    int limit = 20000,
    int offset = 0,
  }) async {
    final q = _db.select(_db.mediaItems);

    final prefix = pathPrefix?.trim();
    if (prefix != null && prefix.isNotEmpty) {
      final normalized = normalizeDrivePath(prefix);
      // 根就是「全部」，不必加条件 —— 加了反而会因为 `dir_path LIKE '/%'`
      // 把根目录下的文件（`dir_path` 恰好是 `/`）漏掉。
      if (normalized != driveRootPath) {
        final withSlash = drivePathWithTrailingSlash(normalized);
        // `dir_path` 一律带结尾斜杠，所以「自己 + 自己的子孙」就是
        // 「等于前缀」或「以 前缀/ 开头」。用带斜杠的前缀做 LIKE 是关键：
        // 不带的话 `/电影2` 会被当成 `/电影` 的子目录。
        q.where(
          (t) => t.dirPath.equals(withSlash) | t.dirPath.like('$withSlash%'),
        );
      }
    }

    final trimmed = query?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      final like = '%$trimmed%';
      // 文件名与**展示路径**都要匹配：用户经常记得「在 /电影/科幻/ 下面」
      // 却记不住片名。LIKE 对 ASCII 大小写不敏感，中文按字节比 —— 够用。
      q.where((t) => t.name.like(like) | t.dirPath.like(like));
    }

    q
      ..orderBy([(t) => OrderingTerm.asc(t.dirPath)])
      ..limit(limit, offset: offset);

    final rows = await q.get();
    final items = rows.map(_toItem).toList();
    // 文件名在 SQL 里只能按字节序排（`第10期` 会跑到 `第2期` 前面），
    // 所以目录内再按自然序排一遍。行数受 [limit] 约束，这一遍很便宜。
    items.sort((a, b) {
      final byDir = a.dirPath.compareTo(b.dirPath);
      return byDir != 0 ? byDir : naturalCompare(a.name, b.name);
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
  Future<Map<String, Duration>> resumePositions(List<String> itemIds) async {
    if (itemIds.isEmpty) return const <String, Duration>{};

    // 用 `selectOnly` 只取两列：剧集列表可能一次问几十个 id，而
    // `select(mediaItems)` 会把每一行（含 flags、路径等）全部物化一遍 ——
    // 这一列在面板上只用来画一根细进度条。
    final query = _db.selectOnly(_db.mediaItems)
      ..addColumns([_db.mediaItems.id, _db.mediaItems.resumePositionMs])
      ..where(_db.mediaItems.id.isIn(itemIds));

    final out = <String, Duration>{};
    for (final row in await query.get()) {
      final ms = row.read(_db.mediaItems.resumePositionMs);
      final id = row.read(_db.mediaItems.id);
      if (id == null || ms == null || ms <= 0) continue;
      out[id] = Duration(milliseconds: ms);
    }
    return out;
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
        // 更新路径上**只在有新值时写**：夸克对「还没生成预览图」的文件
        // 不下发 `thumbnail` 字段，直接写 null 会把上一次扫描拿到的地址
        // 抹掉（而那个地址是有效的，只是这次响应里没带）。
        // 插入路径不受影响 —— 那时本来就没有旧值可丢。
        thumbUrl: skipFirstSeen && item.thumbUrl == null
            ? const Value.absent()
            : Value(item.thumbUrl),
        // 与 `thumbUrl` 同一条规则、同一个理由：夸克对「还没处理完」的文件
        // 不下发尺寸字段，直接写 null 会把上一次扫描拿到的实测值抹掉。
        videoWidth: skipFirstSeen && item.videoWidth == null
            ? const Value.absent()
            : Value(item.videoWidth),
        videoHeight: skipFirstSeen && item.videoHeight == null
            ? const Value.absent()
            : Value(item.videoHeight),
        firstSeenAt: skipFirstSeen ? const Value.absent() : Value(firstSeenAt),
        updatedAt: Value(item.updatedAt),
      );

  MediaWorksCompanion _workCompanion(MediaWork w) =>
      MediaWorksCompanion(
        key: Value(w.key),
        provider: Value(w.provider.id),
        kind: Value(w.kind.name),
        category: Value(w.category.name),
        title: Value(w.title),
        originalTitle: Value(w.originalTitle),
        year: Value(w.year),
        overview: Value(w.overview),
        posterUrl: Value(w.posterUrl),
        posterFile: Value(w.posterFile),
        posterFaceX: Value(w.posterFaceX),
        backdropUrl: Value(w.backdropUrl),
        backdropFile: Value(w.backdropFile),
        rating: Value(w.rating),
        genres: Value(jsonEncode(w.genres)),
        onlineId: Value(w.onlineId),
        source: Value(w.source.name),
        scrapedAt: Value(w.scrapedAt),
        itemCount: Value(w.itemCount),
        totalBytes: Value(w.totalBytes),
        lastModifiedAt: Value(w.lastModifiedAt),
        firstSeenAt: Value(w.firstSeenAt),
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
        // **实测优先**：库里存着原始像素时现算一遍，而不是直接信 `resolution`
        // 那一列。这样归挡规则改进后老数据不用重扫就能受益，也顺便让
        // 「列里存的是文件名猜的、像素却是实测的」这类历史行自动纠正过来。
        resolution: VideoFormats.resolutionFromDimensions(
              row.videoWidth,
              row.videoHeight,
            ) ??
            _resolutionFromLabel(row.resolution),
        videoWidth: row.videoWidth,
        videoHeight: row.videoHeight,
        sizeBytes: row.sizeBytes,
        modifiedAt: row.modifiedAt,
        durationMs: row.durationMs,
        source: row.source,
        videoCodec: row.videoCodec,
        audioCodec: row.audioCodec,
        flags: _stringSet(row.flags),
        releaseGroup: row.releaseGroup,
        isSampleOrExtra: row.isSampleOrExtra,
        thumbUrl: row.thumbUrl,
        lastPlayedAt: row.lastPlayedAt,
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
        category: _categoryOf(row),
        title: row.title,
        originalTitle: row.originalTitle,
        year: row.year,
        overview: row.overview,
        posterUrl: row.posterUrl,
        posterFile: row.posterFile,
        posterFaceX: row.posterFaceX,
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
        lastModifiedAt: row.lastModifiedAt,
        firstSeenAt: row.firstSeenAt,
        lastPlayedAt: row.lastPlayedAt,
        updatedAt: row.updatedAt,
      );

  /// 读出一个作品的分类。
  ///
  /// 库里存的是**判定结果**，空串表示「还没判定过」（v3 之前入库的行）。
  /// 后者在这里现算一次，而不是等回填 —— 这样即使用户从没触发过回填，
  /// 海报墙上也不会出现一整栏「其他」。
  ///
  /// 现算结果**不写回**：读路径里写库会让「打开媒体库」变成一次批量写，
  /// 而回填有专门的入口（`backfillWorkCategories`），职责分明。
  MediaCategory _categoryOf(MediaWorkRow row) {
    if (row.category.isNotEmpty) return MediaCategory.fromName(row.category);
    return MediaCategoryGuesser.guessFromWork(
      kind: MediaKind.values.firstWhere(
        (k) => k.name == row.kind,
        orElse: () => MediaKind.unknown,
      ),
      title: row.title,
      genres: _stringList(row.genres),
    );
  }

  SubtitleTrack _toSubtitle(SubtitleRefRow row) => SubtitleTrack(        id: row.id,
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
