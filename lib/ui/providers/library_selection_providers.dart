import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 媒体库的**多选**状态。
///
/// ## 为什么「是否处于多选模式」和「选了哪些」必须在同一个对象里
///
/// 拆成两个 provider（一个 `bool`、一个 `Set<String>`）会多出一个必须自己
/// 维护的不变量：**退出多选时必须清空选中集合**。分开存的话，任何一处忘了
/// 清，用户下次点「选择」就会看到「刚进来就莫名其妙选着三部」—— 而那三部
/// 还是上一次的老选择，跟着去点「合并」就会合错。
///
/// 放在一起之后，[LibrarySelectionController.exit] 只能整体替换，这条
/// 不变量由类型保证，不靠记性。
///
/// ## 为什么选中集合存 `key` 而不是 `MediaWork`
///
/// 列表会因刷新 / 筛选变化而重建（`workListProvider` 每次给的都是新对象）。
/// 存对象的话「刷一次列表选中就丢了」—— 用户勾了 6 部去合并，中间列表
/// 自己刷新了一次，选择全没了。存 `key` 则只要那几部还在列表里就认得出来。
class LibrarySelection {
  const LibrarySelection({
    this.active = false,
    this.keys = const <String>{},
  });

  /// 是否处于多选模式。
  ///
  /// 它决定卡片的行为：**关闭时点卡片 = 开播**（这是媒体库的主口径，见
  /// `LibraryPage` 的类文档），**开启时点卡片 = 切换选中**。
  final bool active;

  /// 选中的作品 `key`。
  final Set<String> keys;

  int get count => keys.length;

  bool get isEmpty => keys.isEmpty;

  bool contains(String key) => keys.contains(key);

  LibrarySelection copyWith({
    bool? active,
    Set<String>? keys,
  }) =>
      LibrarySelection(
        active: active ?? this.active,
        keys: keys ?? this.keys,
      );

  @override
  bool operator ==(Object other) =>
      other is LibrarySelection &&
      other.active == active &&
      // `Set` 没重写 `==`（默认**引用**相等）。直接比会漏掉「内容一样但不是
      // 同一个对象」的更新，Riverpod 会误判成「没变」而不重建。
      setEquals(other.keys, keys);

  @override
  int get hashCode => Object.hash(active, Object.hashAllUnordered(keys));

  @override
  String toString() => 'LibrarySelection(active=$active, ${keys.length} 部)';
}

class LibrarySelectionController extends Notifier<LibrarySelection> {
  @override
  LibrarySelection build() => const LibrarySelection();

  /// 进入多选模式。
  ///
  /// [key] 非空时顺带把它勾上 —— 「长按某一张卡片」这条入口必须**连按的那
  /// 一下一起生效**：用户长按的意图是「我要选这部（以及别的）」，长按完还得
  /// 再点一次才能选上，等于那一次长按白做了。
  void enter([String? key]) {
    state = LibrarySelection(
      active: true,
      keys: key == null ? const <String>{} : <String>{key},
    );
  }

  /// 退出多选模式并清空选择（两者必须同时发生，理由见类文档）。
  void exit() => state = const LibrarySelection();

  /// 勾选 / 取消勾选一部作品。
  void toggle(String key) {
    final next = Set<String>.of(state.keys);
    if (!next.remove(key)) next.add(key);
    state = state.copyWith(keys: next);
  }

  /// 勾上一批（「全选」用）。
  ///
  /// **追加**而不是替换：全选按钮的文案是「全选」，而用户可能已经手动勾了
  /// 几部又改了筛选条件 —— 追加的语义在任何情况下都不会让已勾的丢掉。
  void addAll(Iterable<String> keys) {
    // ⚠️ Dart 的 `Set` **没有** `containsAll`（那是 `collection` 包给的扩展），
    // 写了会是一个编译错误。顺带这一句还是「没变就直接返回」—— 全选已经
    // 选满时不必再重建一次整个海报墙。
    if (keys.every(state.keys.contains)) return;
    state = state.copyWith(keys: {...state.keys, ...keys});
  }

  /// 只清空选择，**留在**多选模式里（「取消选择」按钮用）。
  void clearKeys() {
    if (state.keys.isEmpty) return;
    state = state.copyWith(keys: const <String>{});
  }
}

final librarySelectionProvider =
    NotifierProvider<LibrarySelectionController, LibrarySelection>(
  LibrarySelectionController.new,
);
