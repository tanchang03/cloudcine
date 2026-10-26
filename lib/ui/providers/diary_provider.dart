import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/diary_store.dart';
import '../../domain/services/watch_diary.dart';
import 'app_providers.dart';

/// 观影日记的**界面状态 + 变动入口**。
///
/// 真源是 [diaryStoreProvider]（落盘的 `watch_diary.json`）。这个 Notifier 不持有
/// 数据，只负责把 UI 的「打分 / 写短评 / 收藏 / 移出」翻译成对 store 的改动，
/// 并在每次改动后：
///
///   1. 刷新生效（[state] = 重新从 store 取的可见条目）；
///   2. 触发一次静默同步，把改动推到网盘（失败不阻塞，下一轮重试）。
///
/// 同步（含远程合并）是异步的、另一个时间线发生的；同步结束后由调度器调用
/// [reload] 把远程合进来的内容也映到界面上。
final diaryNotifierProvider =
    NotifierProvider<DiaryNotifier, List<DiaryEntry>>(DiaryNotifier.new);

class DiaryNotifier extends Notifier<List<DiaryEntry>> {
  DiaryStore get _store => ref.read(diaryStoreProvider);

  @override
  List<DiaryEntry> build() {
    // 首屏前 store 可能还没 load 完；这里先取当前内存态，页面会在 initState
    // 里 await load 后再 reload 一次。
    return _visible();
  }

  List<DiaryEntry> _visible() =>
      _store.book.visible.toList(growable: false);

  /// 从 store 重新取一份可见条目（同步合并 / 落盘后调用）。
  void reload() => state = _visible();

  DiaryEntry? entryById(String id) => _store.getEntry(id);

  // -------------------------------------------------------------------
  // 变动
  // -------------------------------------------------------------------

  void rate(String id, int rating) => _mutate(id, (e) => e.copyWith(rating: rating));
  void clearRating(String id) =>
      _mutate(id, (e) => e.copyWith(clearRating: true));
  void setReview(String id, String review) =>
      _mutate(id, (e) => e.copyWith(review: review));
  void toggleFavorite(String id) {
    final e = _store.getEntry(id);
    if (e == null) return;
    _mutate(id, (x) => x.copyWith(favorite: !x.favorite));
  }

  void addTag(String id, String tag) {
    final e = _store.getEntry(id);
    if (e == null) return;
    final t = tag.trim();
    if (t.isEmpty || e.tags.contains(t)) return;
    _mutate(id, (x) => x.copyWith(tags: [...x.tags, t]));
  }

  void removeTag(String id, String tag) {
    final e = _store.getEntry(id);
    if (e == null) return;
    _mutate(id, (x) => x.copyWith(tags: x.tags.where((t) => t != tag).toList()));
  }

  /// 移出日记（写墓碑）。见 [DiaryEntry.tombstoned]。
  void remove(String id) => _mutate(id, (e) => e.tombstoned());

  /// 恢复被移出的条目（清掉墓碑）。
  void restore(String id) => _mutate(id, (e) => e.copyWith(clearDeleted: true));

  void _mutate(String id, DiaryEntry Function(DiaryEntry) change) {
    final current = _store.getEntry(id);
    if (current == null) return;
    final next = change(current);
    if (!_store.put(next)) return; // 内容没变
    unawaited(_store.flush());
    state = _visible();
    // 推到网盘（失败不阻塞 UI，下一轮同步重试）。
    unawaited(syncDiaryOnce(ref).catchError((_) {}));
  }
}
