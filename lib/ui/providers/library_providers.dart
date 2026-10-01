import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/media_category.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/play_target.dart';
import 'app_providers.dart';
import 'library_refresh_providers.dart';

/// 媒体库筛选与排序条件。
///
/// 做成一个不可变值而不是几个独立 provider：它们会**同时**参与查询，
/// 拆开会让「切分类时要不要保留搜索词 / 排序」这类决定散在 UI 里。
class LibraryFilter {
  const LibraryFilter({
    this.category,
    this.playedOnly = false,
    this.sort = WorkSort.recentAdded,
    this.query = '',
  });

  /// `null` 表示全部（不分栏）
  final MediaCategory? category;

  /// 只看**播过**的作品 —— 分类栏上的「最近播放」那一栏。
  ///
  /// ## 为什么它不是一个 [MediaCategory] 取值
  ///
  /// [MediaCategory] 回答的是「这部作品属于哪个栏目」，它是**内容语义**，
  /// 由 `MediaCategoryGuesser` 在扫描期判定、落库在 `media_works.category`。
  /// 而「播过没有」是**播放记录**：它会随播放实时变化，而且同一部作品会在
  /// 「播过」和「没播过」之间来回横跳。
  ///
  /// 把它塞进枚举会立刻撞上两件事：
  ///   - 库里 `category` 那一列会出现「最近播放」这种**会过期**的值；
  ///   - `MediaCategoryGuesser` 永远猜不出它 —— 于是每次扫描都会把这个值
  ///     冲成别的（`mergeWorkForUpsert` 里分类是「永远取新值」的）。
  ///
  /// 所以它是一个**视图**：只影响查询，不落库、不参与分类判定。
  /// 这也让它和 [category] 天然互斥 —— 分类栏是单选组，两个同时高亮
  /// 只会让用户不知道列表到底在筛什么。
  final bool playedOnly;

  final WorkSort sort;

  final String query;

  bool get isEmpty =>
      category == null && !playedOnly && query.trim().isEmpty;

  /// 是否有非默认条件（决定空态给不给「清空筛选」）。
  bool get isDefault =>
      category == null &&
      !playedOnly &&
      sort == WorkSort.recentAdded &&
      query.trim().isEmpty;

  LibraryFilter copyWith({
    MediaCategory? category,
    bool? playedOnly,
    WorkSort? sort,
    String? query,
    bool clearCategory = false,
  }) {
    return LibraryFilter(
      category: clearCategory ? null : (category ?? this.category),
      playedOnly: playedOnly ?? this.playedOnly,
      sort: sort ?? this.sort,
      query: query ?? this.query,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryFilter &&
      other.category == category &&
      other.playedOnly == playedOnly &&
      other.sort == sort &&
      other.query == query;

  @override
  int get hashCode => Object.hash(category, playedOnly, sort, query);

  @override
  String toString() => 'LibraryFilter('
      '${playedOnly ? "最近播放" : (category?.label ?? "全部")}, '
      '${sort.label}, "$query")';
}

class LibraryFilterController extends Notifier<LibraryFilter> {
  @override
  LibraryFilter build() => const LibraryFilter();

  /// 传 `null` 表示「全部」。
  ///
  /// 选分类会**退出**「最近播放」视图（见 [LibraryFilter.playedOnly]）。
  void setCategory(MediaCategory? category) {
    state = category == null
        ? state.copyWith(clearCategory: true, playedOnly: false)
        : state.copyWith(category: category, playedOnly: false);
  }

  /// 切到「最近播放」视图。
  ///
  /// ## 为什么顺带把排序也切成「最近播放」
  ///
  /// 一个按「最近添加」排的「最近播放」列表是自相矛盾的：用户点这一栏要看
  /// 的就是「我最近看了什么」，而第一条却不是最近看的那部。
  ///
  /// 代价是**离开这一栏时不会自动切回**（[setCategory] 刻意不动排序）：
  /// 分不出「排序是刚被这里隐式设上的」还是「用户自己在排序菜单里选的」，
  /// 猜错就会把用户的选择静默改掉。好在排序菜单一直显示着当前排序，
  /// 所以这不是隐藏状态 —— 用户看得见，一键就能改。
  void setPlayedOnly() {
    state = state.copyWith(
      playedOnly: true,
      clearCategory: true,
      sort: WorkSort.recentPlayed,
    );
  }

  void setSort(WorkSort sort) => state = state.copyWith(sort: sort);

  void setQuery(String query) => state = state.copyWith(query: query);

  void clear() => state = const LibraryFilter();
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilter>(
  LibraryFilterController.new,
);

/// 老库的分类回填，**只跑一次**。
///
/// 单独一个 provider 而不是塞进 [workListProvider]：后者在每次改筛选条件时
/// 都会重跑，回填跟着跑就变成「点一下分类栏查一次全表」。
/// 放在这里由 Riverpod 缓存，只有换了仓储实现才会重跑。
final categoryBackfillProvider = FutureProvider<int>((ref) async {
  return ref.watch(mediaRepositoryProvider).backfillWorkCategories();
});

/// 媒体库主列表（作品级）。
///
/// 上限取 500 而不是分页：作品数（一部剧算一条）在个人网盘量级下很少
/// 超过几百，而**分页会让海报墙的滚动体验变差**（滚到底要等加载）。
/// 真到了需要分页的量级，这里换 `PagedListView` 即可，UI 不用动。
final workListProvider = FutureProvider<List<MediaWork>>((ref) async {
  // 先保证分类列有值，否则用户点「动漫」会看到空列表 —— 而库里明明有动漫。
  await ref.watch(categoryBackfillProvider.future);

  // 换条播放会让「最近播放」的内容与顺序都变（见 `PlaybackLibraryLink`）。
  // `invalidate` 语义上是「重新取」，Riverpod 会保留上一次的值进 loading，
  // 所以海报墙不会闪一下转圈。
  ref.watch(playbackLibraryLinkProvider);

  final filter = ref.watch(libraryFilterProvider);
  final query = filter.query.trim();
  return ref.watch(mediaRepositoryProvider).listWorks(
        category: filter.category,
        playedOnly: filter.playedOnly,
        query: query.isEmpty ? null : query,
        sort: filter.sort,
        limit: 500,
      );
});

/// 各分类的作品数（分类栏上的角标）。
///
/// 走仓储的 `countWorksByCategory`（一次 `GROUP BY`），而不是拉全表在 Dart
/// 里数 —— 分类栏每次进媒体库都要画，而作品表有十几列。
final categoryCountsProvider =
    FutureProvider<Map<MediaCategory, int>>((ref) async {
  await ref.watch(categoryBackfillProvider.future);
  return ref.watch(mediaRepositoryProvider).countWorksByCategory();
});

/// 播过的作品数（「最近播放」栏的角标）。
///
/// **刻意不等 [categoryBackfillProvider]**：那个回填修的是 `category` 列，
/// 而「播过没有」看的是 `lastPlayedAt`，两者没有依赖关系。
final playedCountProvider = FutureProvider<int>((ref) {
  // 播过一部新片子，这个数字就变了。
  ref.watch(playbackLibraryLinkProvider);
  return ref.watch(mediaRepositoryProvider).countPlayedWorks();
});

/// 「点这部作品该播哪一条」。
///
/// ## 为什么不做成 Provider
///
/// 它的输入里有 `lastPlayedAt`，而那个值**在播放过程中一直在变**。
/// 做成 `FutureProvider.family` 会被缓存住：用户在播放窗口看完一集回到
/// 媒体库，再点同一张卡片，会拿到缓存的旧目标（还是刚才那一集）。
/// 两次 SQLite 查询很便宜，每次现算比「记得在 N 个地方 invalidate」可靠。
Future<MediaItem?> resolvePlayTarget(
  MediaRepository repository,
  String workKey,
) async {
  final items = await repository.itemsForWork(workKey);
  if (items.isEmpty) return null;

  final resume = await repository.resumePositions(
    items.map((i) => i.id).toList(growable: false),
  );
  final played = <String, DateTime>{
    for (final i in items)
      if (i.lastPlayedAt != null) i.id: i.lastPlayedAt!,
  };

  return PlayTarget.resolve(items: items, resume: resume, lastPlayedAt: played);
}


/// 一个作品的详情：作品元数据 + 它下面的全部文件。
class WorkDetail {
  const WorkDetail({required this.work, required this.items});

  final MediaWork work;

  /// 全部文件，已按「季 → 集 → 名称」排序
  final List<MediaItem> items;

  /// 正片。默认列表只显示这些 —— 花絮会淹没正片，但不该被丢弃。
  List<MediaItem> get features =>
      items.where((i) => !i.isSampleOrExtra).toList(growable: false);

  /// 花絮 / 样片 / 预告
  List<MediaItem> get extras =>
      items.where((i) => i.isSampleOrExtra).toList(growable: false);

  /// 可播的第一项（用于「播放」按钮与详情页自动选中）。
  MediaItem? get primary =>
      features.isNotEmpty ? features.first : (items.isEmpty ? null : items.first);

  bool get hasMultipleVersions => features.length > 1;
}

final workDetailProvider =
    FutureProvider.family<WorkDetail?, String>((ref, key) async {
  final repo = ref.watch(mediaRepositoryProvider);
  final work = await repo.workByKey(key);
  if (work == null) return null;
  final items = await repo.itemsForWork(key);
  return WorkDetail(work: work, items: items);
});

/// 某个媒体项的字幕引用（扫描期建立的，不含正文）。
final itemSubtitlesProvider =
    FutureProvider.family<List<SubtitleTrack>, String>((ref, itemId) {
  return ref.watch(mediaRepositoryProvider).subtitlesForItem(itemId);
});

/// 媒体库规模统计（设置页 / 空态提示用）。
final libraryStatsProvider = FutureProvider<({int items, int works})>((ref) async {
  final repo = ref.watch(mediaRepositoryProvider);
  return (items: await repo.countItems(), works: await repo.countWorks());
});
