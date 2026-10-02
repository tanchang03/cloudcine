import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/media_category.dart';
import '../../domain/adapters/media_repository.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/entities/subtitle_track.dart';
import '../../domain/services/missing_media.dart';
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
    this.sort = WorkSort.recentModified,
    this.query = '',
    this.years = const <int>{},
    this.genres = const <String>{},
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

  /// 年份多选，元素是**具体年份**（`2023` 只匹配 2023 年上映的作品）。
  ///
  /// 空集合 = 这一维不限。多选之间是「或」（一部片子只有一个上映年份，
  /// 取交集恒为空）。
  final Set<int> years;

  /// 类型多选（TMDB / 豆瓣的类型名，如 `动画` / `科幻`）。
  ///
  /// 空集合 = 这一维不限。多选之间是「或」—— 一部片子只会有一两个类型，
  /// 取交集几乎永远筛不出东西。与 [years] 之间是「与」。
  final Set<String> genres;

  /// 筛选面板里是否有生效的条件（决定「筛选」按钮要不要亮标记）。
  bool get hasExtra => years.isNotEmpty || genres.isNotEmpty;

  /// 「一个内容筛选都没设」。
  ///
  /// 注意它**不看 [sort]**：排序不是筛选。这个判据的用途是空态 ——
  /// 列表为空时，「有没有条件可以清」决定给不给「清空筛选」按钮。
  bool get isEmpty =>
      category == null &&
      !playedOnly &&
      query.trim().isEmpty &&
      !hasExtra;

  /// 是否有非默认条件（决定空态给不给「清空筛选」）。
  bool get isDefault =>
      category == null &&
      !playedOnly &&
      sort == WorkSort.recentModified &&
      query.trim().isEmpty &&
      !hasExtra;

  LibraryFilter copyWith({
    MediaCategory? category,
    bool? playedOnly,
    WorkSort? sort,
    String? query,
    Set<int>? years,
    Set<String>? genres,
    bool clearCategory = false,
  }) {
    return LibraryFilter(
      category: clearCategory ? null : (category ?? this.category),
      playedOnly: playedOnly ?? this.playedOnly,
      sort: sort ?? this.sort,
      query: query ?? this.query,
      // 空集合是一个**合法取值**（「这一维不限」），所以不能像 category 那样
      // 用 null 表达「清空」—— 传 `const <int>{}` 就是要清空。
      years: years ?? this.years,
      genres: genres ?? this.genres,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryFilter &&
      other.category == category &&
      other.playedOnly == playedOnly &&
      other.sort == sort &&
      other.query == query &&
      // Set 没重写 `==`（默认是**引用**相等），直接比会漏掉
      // 「内容一样但不是同一个对象」的更新，让 Riverpod 误判成「没变」。
      setEquals(other.years, years) &&
      setEquals(other.genres, genres);

  @override
  int get hashCode => Object.hash(
        category,
        playedOnly,
        sort,
        query,
        // 与顺序无关：`{2023, 2010}` 和 `{2010, 2023}` 是同一份条件。
        Object.hashAllUnordered(years),
        Object.hashAllUnordered(genres),
      );

  @override
  String toString() {
    final extra = [
      if (years.isNotEmpty) '年份 ${(years.toList()..sort()).join("/")}',
      if (genres.isNotEmpty) genres.join("/"),
    ];
    return 'LibraryFilter('
        '${playedOnly ? "最近播放" : (category?.label ?? "全部")}, '
        '${sort.label}, "$query"'
        '${extra.isEmpty ? "" : ", ${extra.join(" · ")}"})';
  }
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

  /// 切换一个年份的选中状态。
  ///
  /// 已选则取消、未选则加入 —— 与「清空」不同，用户点错一个年份时
  /// 只需要再点一下，不用清掉整组条件重来。
  void toggleYear(int year) {
    final next = Set<int>.of(state.years);
    if (!next.remove(year)) next.add(year);
    state = state.copyWith(years: next);
  }

  /// 切换一个类型的选中状态。语义与 [toggleYear] 一致。
  void toggleGenre(String genre) {
    final next = Set<String>.of(state.genres);
    if (!next.remove(genre)) next.add(genre);
    state = state.copyWith(genres: next);
  }

  /// 清空筛选面板里的两组条件（年份 + 类型）。
  ///
  /// **只清这两组**：分类栏与搜索框在面板之外、各有自己的清除入口，
  /// 面板上的「清空筛选」把它们一起抹掉会让用户莫名其妙地丢掉搜索词。
  void clearExtra() {
    state = state.copyWith(years: const <int>{}, genres: const <String>{});
  }

  void clear() => state = const LibraryFilter();
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilter>(
  LibraryFilterController.new,
);

/// 手动指定一部作品的**分类**与**类型标签**。
///
/// ## 为什么需要它
///
/// 这两样原本**完全由自动规则决定**：
///
///   - `category` 由 `MediaCategoryGuesser` 折算（genres → 目录名 → 片名/
///     文件名 → 结构兜底）；
///   - `genres` 由 TMDB / 豆瓣的刮削结果直接写入。
///
/// 两者都会错：目录名里没有「动漫」二字的动画电影会落进「电影」栏；被发布组
/// 插了字符的片名（`超z级z马z力z…`）会刮到完全不相干的条目；TMDB 也常常
/// 给不出「真人秀」这类类型。而用户**没有任何办法纠正** —— 详情页的「刮削」
/// 与「手动」都只改标题 / 年份 / 海报，碰不到这两列。
///
/// ## 手动改过的东西不该被下一次刮削冲掉
///
/// 这是本控制器存在的核心理由。用户为了修类型去重刮一次（顺便补张海报），
/// 结果刚改好的类型又被刮削覆盖 —— 那不是「覆盖」，那是「改了也白改」。
/// 所以落库时同时置 `categoryManual` / `genresManual`，由仓储层的合并逻辑
/// 保证后续 upsert 不再覆盖对应列。
///
/// ## 两条路，缺一不可
///
/// 每一维都有「设成手动」和「交回自动」（传 `null`）。只有前者的话，用户
/// 手滑点错一次就永远回不去了 —— 只能选另一个手动值，再也不能让刮削的结果
/// 生效。
///
/// ## 为什么要作废五个 provider
///
/// 与 `WorkScrapeController._refreshAfter` 里「分类变了」那一支**完全一致**
/// （那边有完整解释）：分类一改，详情页、海报墙，以及分类栏 / 筛选面板的
/// 三组角标都要重算。少作废任何一个，用户都会看到一个停在旧值的数字 ——
/// 而他点进去发现数量对不上，只会怀疑筛选坏了。
///
/// 改类型标签时同理：`genreCountsProvider` 直接由 `genres` 数出来，而
/// 分类可能跟着变（加了「动画」→ 从「电影」挪到「动漫」），所以三组角标
/// 一起作废最省心，反正这是一次点击一次的事，不在热路径上。
class WorkClassificationController {
  WorkClassificationController(this._ref);

  final Ref _ref;

  /// 手动指定分类。传 `null` 等价于 [restoreAutoCategory]。
  Future<void> setCategory(String workKey, MediaCategory? category) async {
    await _ref.read(mediaRepositoryProvider).setWorkCategory(workKey, category);
    _refresh(workKey);
  }

  /// 恢复分类的自动判定：按当前规则立刻重算一次。
  Future<void> restoreAutoCategory(String workKey) =>
      setCategory(workKey, null);

  /// 手动编辑类型标签。传 `null` 表示恢复自动（清掉手动标记，下次刮削可覆盖）。
  Future<void> setGenres(String workKey, List<String>? genres) async {
    await _ref.read(mediaRepositoryProvider).setWorkGenres(workKey, genres);
    _refresh(workKey);
  }

  void _refresh(String workKey) {
    _ref.invalidate(workDetailProvider(workKey));
    _ref.invalidate(workListProvider);
    _ref.invalidate(categoryCountsProvider);
    _ref.invalidate(yearCountsProvider);
    _ref.invalidate(genreCountsProvider);
  }
}

final workClassificationControllerProvider =
    Provider<WorkClassificationController>(
  (ref) => WorkClassificationController(ref),
);

/// 「网盘上这个文件已经没了」→ 从媒体库里移除它。
///
/// ## 为什么单独一个控制器
///
/// 这条路径要惊动的 provider 和 `WorkClassificationController` 一样多
/// （详情页 + 海报墙 + 三组角标 + 目录视图的「已入库」叠加层），但触发它的
/// 地方在**播放器**里（`playItem` 与播放页的错误浮层）。播放器不认识、也
/// 不该认识那五个 provider —— 所以把它们收在这里，播放器只需要喊一句
/// 「这个文件没了」。
class MissingMediaController {
  MissingMediaController(this._ref);

  final Ref _ref;

  /// 把「打不开的那个文件」翻译成对话框需要的全部信息。
  ///
  /// 文件数走 `itemsForWork`（**并集**口径）：它与详情页「文件」列表的长度
  /// 必须一致，用户据它判断「是不是整部都没了」—— 写着 24 而只坏了一集，
  /// 就该选「只移除这一集」。
  Future<MissingMediaPlan> planFor(MediaItem item) async {
    final repo = _ref.read(mediaRepositoryProvider);
    final work = await repo.workByKey(item.groupKey);
    final siblings = await repo.itemsForWork(item.groupKey);
    return MissingMediaPlan.of(
      item: item,
      work: work,
      fileCount: siblings.length,
    );
  }

  /// 按 [scope] 移除，并让所有读这张表的 provider 重取。
  ///
  /// 返回是否真的动了库 —— 调用方（播放页）据此决定要不要关掉自己。
  Future<bool> remove(
    MediaItem item, {
    required MediaRemovalScope scope,
  }) async {
    final repo = _ref.read(mediaRepositoryProvider);
    final removed = switch (scope) {
      MediaRemovalScope.singleItem => await _removeSingle(repo, item),
      MediaRemovalScope.wholeWork => await _removeWhole(repo, item),
    };
    _refresh(item.groupKey);
    return removed;
  }

  /// 只删这一个文件。
  ///
  /// ⚠️ 删完之后**还要回头看一眼作品行还有没有文件**。没有的话那一部就
  /// 只剩一张空卡片：点进去什么都没有，却仍然占着「电影」栏的角标
  /// （角标数的是作品行）。留着它，用户会看到一个「有 1 部电影、空的」
  /// 的媒体库。
  ///
  /// 这条决定**放在这里而不是仓储里**是刻意的：`deleteItem` 的契约是
  /// 「删一个文件」，让它在某种情况下顺带删掉作品行属于出乎调用方意料的
  /// 副作用 —— 而「删完之后要不要连带删作品」将来可能变成一次二次确认。
  Future<bool> _removeSingle(MediaRepository repo, MediaItem item) async {
    if (!await repo.deleteItem(item.id)) return false;
    final left = await repo.itemsForWork(item.groupKey);
    if (left.isEmpty) {
      diag.info('媒体库', '${item.groupKey} 名下已无文件，一并删除作品行');
      await repo.deleteWork(item.groupKey);
    }
    return true;
  }

  /// 整部一起删（含折叠进来的源作品）。
  Future<bool> _removeWhole(MediaRepository repo, MediaItem item) async {
    // 返回 0 表示这一部本来就不在库里、或名下没有文件。那时作品行同样
    // 已经被删掉了，对用户来说结果一致，所以不算失败。
    final n = await repo.deleteWork(item.groupKey);
    diag.info('媒体库', '整部移除 ${item.groupKey}：$n 个文件');
    return true;
  }

  /// 与 `WorkClassificationController._refresh` 同一套，另加两个：
  ///
  ///   - `playedCountProvider`：删掉的可能是「最近播放」里那部；
  ///   - `libraryWriteSignalProvider`：目录视图的「已入库」叠加层读的是
  ///     同一张 `media_items` 表，不喊一声的话，删掉的文件在那儿还标记着
  ///     「已在库」，而点它只会再失败一次。
  void _refresh(String workKey) {
    _ref.invalidate(workDetailProvider(workKey));
    _ref.invalidate(workListProvider);
    _ref.invalidate(categoryCountsProvider);
    _ref.invalidate(yearCountsProvider);
    _ref.invalidate(genreCountsProvider);
    _ref.invalidate(playedCountProvider);
    _ref.invalidate(libraryStatsProvider);
    _ref.read(libraryWriteSignalProvider.notifier).bump();
  }
}

final missingMediaControllerProvider = Provider<MissingMediaController>(
  (ref) => MissingMediaController(ref),
);

/// 把 `category` 列修正到当前规则下的正确值，**只跑一次**。
///
/// 它管两件事：老库的空分类回填，以及把**已经刮过**的作品的 `genres`
/// 折算进分类（理由见 `MediaRepository.backfillWorkCategories`）。
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
  final sw = Stopwatch()..start();

  // 先保证分类列有值，否则用户点「动漫」会看到空列表 —— 而库里明明有动漫。
  final wait = Stopwatch()..start();
  await ref.watch(categoryBackfillProvider.future);
  final waitMs = wait.elapsedMilliseconds;

  // 换条播放会让「最近播放」的内容与顺序都变（见 `PlaybackLibraryLink`）。
  // `invalidate` 语义上是「重新取」，Riverpod 会保留上一次的值进 loading，
  // 所以海报墙不会闪一下转圈。
  ref.watch(playbackLibraryLinkProvider);

  final filter = ref.watch(libraryFilterProvider);
  final query = filter.query.trim();
  final works = await ref.watch(mediaRepositoryProvider).listWorks(
        category: filter.category,
        playedOnly: filter.playedOnly,
        query: query.isEmpty ? null : query,
        // 空集合与 `null` 在仓储里是同一件事（「这一维不限」），
        // 但显式传 `null` 让 SQL 侧连条件都不用拼。
        years: filter.years.isEmpty ? null : filter.years,
        genres: filter.genres.isEmpty ? null : filter.genres,
        sort: filter.sort,
        limit: 500,
      );

  // 这条才是用户眼里的「进媒体库要等多久」：`listWorks` 只报 SQL 那一段，
  // 而首屏真正花掉的是「等分类回填 + 查询」两段之和。仓储那条日志回答
  // 「SQL 快不快」，这条回答「用户等了多久」—— 两个数字对不上时，
  // 差额就是回填或 Riverpod 侧的开销。
  //
  // 条件一起打出来：测试时要能一眼分清「切了分类所以慢」和「一直这么慢」。
  diag.debug(
    '媒体库',
    '列表就绪：${works.length} 部，${sw.elapsedMilliseconds}ms'
    '（等回填 $waitMs ms + 查询 ${sw.elapsedMilliseconds - waitMs}ms，$filter）',
  );
  return works;
});

/// 给首屏那几条**并发**查询各记一条耗时。
///
/// 它们与 [workListProvider] 同时发出，所以只看 `listWorks` 的数字回答不了
/// 「列表为什么慢」—— 真正拖住首帧的可能是这里某一条（分类角标要扫全表、
/// 年份/类型角标各读一列）。分开记，慢的那一条自己会露出来。
///
/// 全是 `debug` 级：它们每次改筛选都会重跑，`info` 会把日志刷满。
/// 排查性能时按 `[媒体库]` 过滤。
Future<T> _timedQuery<T>(String label, Future<T> Function() body) async {
  final sw = Stopwatch()..start();
  final value = await body();
  diag.debug('媒体库', '$label：${sw.elapsedMilliseconds}ms');
  return value;
}

/// 各分类的作品数（分类栏上的角标）。
///
/// 走仓储的 `countWorksByCategory`（一次 `GROUP BY`），而不是拉全表在 Dart
/// 里数 —— 分类栏每次进媒体库都要画，而作品表有十几列。
final categoryCountsProvider =
    FutureProvider<Map<MediaCategory, int>>((ref) async {
  await ref.watch(categoryBackfillProvider.future);
  return _timedQuery(
    '分类角标',
    () => ref.watch(mediaRepositoryProvider).countWorksByCategory(),
  );
});

/// 播过的作品数（「最近播放」栏的角标）。
///
/// **刻意不等 [categoryBackfillProvider]**：那个回填修的是 `category` 列，
/// 而「播过没有」看的是 `lastPlayedAt`，两者没有依赖关系。
final playedCountProvider = FutureProvider<int>((ref) {
  // 播过一部新片子，这个数字就变了。
  ref.watch(playbackLibraryLinkProvider);
  return _timedQuery(
    '最近播放角标',
    () => ref.watch(mediaRepositoryProvider).countPlayedWorks(),
  );
});

/// 筛选面板两组选项的**共同作用域**：当前分类 / 「最近播放」/ 搜索词。
///
/// ## 为什么只 `select` 这三个
///
/// 面板上的角标要严格等于「**把年份 / 类型清空后**列表里的条数」——
/// 这样每一个选项点下去都至少有结果。所以它跟着这三个条件收窄，
/// 却**不能**跟着 `years` / `genres` 收窄：否则用户每勾一个类型，
/// 剩下的类型角标就会跟着变，勾到第二个时列表已经空了。
///
/// 用 `select` 而不是直接 `watch(libraryFilterProvider)` 是必须的：
/// 后者会让「勾一个年份」也触发一次统计查询（白跑两遍全表扫描）。
/// 记录（record）有结构相等，所以只有这三个值真的变了才会重算。
({MediaCategory? category, bool playedOnly, String query}) _facetScope(
  Ref ref,
) {
  final (category, playedOnly, query) = ref.watch(
    libraryFilterProvider.select(
      (f) => (f.category, f.playedOnly, f.query),
    ),
  );
  return (
    category: category,
    playedOnly: playedOnly,
    query: query.trim().isEmpty ? '' : query.trim(),
  );
}

/// 各年份的作品数（筛选面板「年份」那一组的选项与角标）。
///
/// ## 为什么要等 [categoryBackfillProvider]
///
/// 这里数的是 `year`，看起来和分类回填无关 —— 但**统计范围**是按
/// `category` 收窄的，而老库里那一列还是空串（v3 之前入库的行）。
///
/// 不等的话会出现：`workListProvider` 已经按回填后的分类筛好了列表，
/// 面板上的数字却还是按回填前的分类算的 —— 两者对不上，而用户完全看不出
/// 为什么。而「角标 == 点下去之后的条数」正是这个面板唯一的承诺。
final yearCountsProvider = FutureProvider<Map<int, int>>((ref) async {
  await ref.watch(categoryBackfillProvider.future);
  final scope = _facetScope(ref);
  return _timedQuery(
    '年份角标（${scope.category?.label ?? "全部"}）',
    () => ref.watch(mediaRepositoryProvider).countWorksByYear(
          category: scope.category,
          playedOnly: scope.playedOnly,
          query: scope.query.isEmpty ? null : scope.query,
        ),
  );
});

/// 各类型的作品数（筛选面板「类型」那一组的选项与角标）。
///
/// 类型来自刮削（`genres` 列），所以**刮一部新片子这个表就可能变** ——
/// 由 `scrape_providers` 在刮削成功后 invalidate 它。
///
/// 等回填的理由与 [yearCountsProvider] 完全相同（范围按 `category` 收窄）。
final genreCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  await ref.watch(categoryBackfillProvider.future);
  final scope = _facetScope(ref);
  return _timedQuery(
    '类型角标（${scope.category?.label ?? "全部"}）',
    () => ref.watch(mediaRepositoryProvider).countWorksByGenre(
          category: scope.category,
          playedOnly: scope.playedOnly,
          query: scope.query.isEmpty ? null : scope.query,
        ),
  );
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
  const WorkDetail({
    required this.work,
    required this.items,
    this.mergedSources = const [],
  });

  final MediaWork work;

  /// 全部文件，已按「季 → 集 → 名称」排序
  final List<MediaItem> items;

  /// 已被折叠进这一部的**其他作品行**（跨目录归一的产物）。
  ///
  /// 详情页用它在标题下面写一句「已并入《X》」并给出撤销入口。空列表
  /// 表示这一部没有归一过任何东西 —— 版式与归一功能上线前完全一致。
  final List<MediaWork> mergedSources;

  /// 归一进来的文件数（撤销提示里说「会把 N 个文件分出去」用）。
  int get mergedItemCount =>
      mergedSources.fold(0, (n, w) => n + w.itemCount);

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
  var work = await repo.workByKey(key);
  if (work == null) return null;

  // 已被折叠走的行要**跟着走到目标**。
  //
  // 列表里看不到别名行，所以唯一还能打开它的路径是「用户正停在它的详情页
  // 上，而后台归一把它折走了」（刮削后的即时归一、扫描结束时的全库归一）。
  // 不跟的话，用户会停在一个「片名还在、但文件少了一半、而且从列表里
  // 再也找不到」的页面上 —— 而他刚刚只点了一下「刮削」。
  final targetKey = work.mergedInto;
  if (targetKey != null) {
    final resolved = await repo.workByKey(targetKey);
    if (resolved != null) work = resolved;
  }

  final items = await repo.itemsForWork(work.key);
  final merged = await repo.mergedSourcesOf(work.key);
  return WorkDetail(work: work, items: items, mergedSources: merged);
});

/// 某个媒体项的字幕引用（扫描期建立的，不含正文）。
final itemSubtitlesProvider =
    FutureProvider.family<List<SubtitleTrack>, String>((ref, itemId) {
  return ref.watch(mediaRepositoryProvider).subtitlesForItem(itemId);
});

/// 媒体库规模统计（设置页 / 空态提示用）。
final libraryStatsProvider = FutureProvider<({int items, int works})>((ref) async {
  final repo = ref.watch(mediaRepositoryProvider);
  return _timedQuery(
    '规模统计（文件数 + 作品数）',
    () async => (items: await repo.countItems(), works: await repo.countWorks()),
  );
});
