import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/filename_parser.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/entities/subtitle_track.dart';
import 'app_providers.dart';

/// 媒体库筛选条件。
///
/// 做成一个不可变值而不是两个独立 provider：`kind` 与 `query` 会**同时**
/// 参与查询，拆开会让「切类型时要不要保留搜索词」这类决定散在 UI 里。
class LibraryFilter {
  const LibraryFilter({this.kind, this.query = ''});

  /// `null` 表示全部（电影 + 剧集）
  final MediaKind? kind;

  final String query;

  bool get isEmpty => kind == null && query.trim().isEmpty;

  LibraryFilter copyWith({
    MediaKind? kind,
    String? query,
    bool clearKind = false,
  }) {
    return LibraryFilter(
      kind: clearKind ? null : (kind ?? this.kind),
      query: query ?? this.query,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryFilter && other.kind == kind && other.query == query;

  @override
  int get hashCode => Object.hash(kind, query);

  @override
  String toString() => 'LibraryFilter(${kind?.name ?? "全部"}, "$query")';
}

class LibraryFilterController extends Notifier<LibraryFilter> {
  @override
  LibraryFilter build() => const LibraryFilter();

  void setKind(MediaKind? kind) {
    state = kind == null
        ? state.copyWith(clearKind: true)
        : state.copyWith(kind: kind);
  }

  void setQuery(String query) => state = state.copyWith(query: query);

  void clear() => state = const LibraryFilter();
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilter>(
  LibraryFilterController.new,
);

/// 媒体库主列表（作品级）。
///
/// 上限取 500 而不是分页：作品数（一部剧算一条）在个人网盘量级下很少
/// 超过几百，而**分页会让海报墙的滚动体验变差**（滚到底要等加载）。
/// 真到了需要分页的量级，这里换 `PagedListView` 即可，UI 不用动。
final workListProvider = FutureProvider<List<MediaWork>>((ref) async {
  final filter = ref.watch(libraryFilterProvider);
  final query = filter.query.trim();
  return ref.watch(mediaRepositoryProvider).listWorks(
        kind: filter.kind,
        query: query.isEmpty ? null : query,
        limit: 500,
      );
});

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
