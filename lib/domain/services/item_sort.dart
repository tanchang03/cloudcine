import '../../core/utils/file_names.dart';
import '../entities/media_item.dart';

/// 作品详情页「文件」列表的排序方式。
///
/// ## 为什么是「三档」而不是「一个方向开关」
///
/// 详情页的文件列表**原本只有一种顺序** —— `itemsForWork` 排好的
/// 「季 → 部 → 集 → 名称」。加了按时间排之后，如果只给「正序 / 倒序」两个
/// 选项，就等于**把原有的剧集顺序弄丢了**：看剧时最常用的动作（顺着集号
/// 往下看）会变成「每次进详情页都得先手动切一次排序」。
///
/// 所以 [episodeOrder] 是一个**真正的选项**，而不是「没排序」。
///
/// ## 默认值
///
/// [modifiedDesc] —— 「哪个是刚传上去的」是这个列表最常要回答的问题，
/// 与目录视图的 `FolderSortMode.modifiedTime` 同一口径（那个也是默认倒序）。
enum ItemSortMode {
  /// 季 → 部 → 集 → 名称。**沿用仓储层排好的顺序**，这里不重排。
  episodeOrder('剧集顺序'),

  /// 按网盘修改时间**倒序**（新 → 旧）。**默认**。
  modifiedDesc('修改时间倒序'),

  /// 按网盘修改时间**正序**（旧 → 新）。
  modifiedAsc('修改时间正序');

  const ItemSortMode(this.label);

  /// 界面上给用户看的名字。排序按钮与菜单项共用一份 —— 抄成两份的话，
  /// 按钮上写「时间倒序」而菜单里写「修改时间倒序」，用户会以为选错了。
  final String label;

  /// 存进设置库的稳定字符串。
  ///
  /// ⚠️ 用**枚举名本身**，与 `FolderSortMode.value` / `AudioEffectPreset.value`
  /// 同一套口径：改它等于让已经存下来的设置**静默失效**（读不懂就退回默认），
  /// 用户只会觉得「我设的排序自己变回去了」，不会有任何报错。
  String get value => name;

  /// 从设置里读到的值还原。
  ///
  /// 读不懂（老版本写的、手工改过的）一律退回 [modifiedDesc] —— 也就是默认值。
  /// **不要**在这里抛异常：一个坏掉的设置值不该让详情页打不开。
  static ItemSortMode parse(String? raw) {
    for (final mode in values) {
      if (mode.value == raw) return mode;
    }
    return ItemSortMode.modifiedDesc;
  }
}

/// 按 [mode] 排一组条目，返回**新列表**（不动入参）。
///
/// ## 为什么 [ItemSortMode.episodeOrder] 是「原样返回」而不是重排一遍
///
/// 「季 → 部 → 集 → 名称」这条规则的**唯一实现**在仓储层
/// （`MediaRepository.itemsForWork`）。详情页拿到的 `visible` 已经是排好的
/// 子序列（`WorkLevels.itemsIn` 保序），在这里再排一次就等于抄了第二份 ——
/// 两处一旦分叉，会出现「层级选择器高亮 Part.1、列表第一行却是 Part.2」
/// 这种对不上的情况，而且不报错。
///
/// ## 与 `sortEntries`（目录视图）的关系
///
/// 两个函数的**边界口径必须一致**，否则同一个网盘在同一页上会排出两种顺序：
///
///   - `modifiedAt` 为 `null` 的条目**垫底**（两个方向都垫底）；
///   - 时间**完全相同**的按名称自然序定序（网盘对一次批量上传只给到秒）。
List<MediaItem> sortItems(List<MediaItem> items, ItemSortMode mode) {
  if (mode == ItemSortMode.episodeOrder) {
    return List<MediaItem>.of(items);
  }
  final sorted = [...items];
  sorted.sort((a, b) => compareItemsByTime(
        a,
        b,
        descending: mode == ItemSortMode.modifiedDesc,
      ));
  return sorted;
}

/// 两条之间按修改时间比较。公开是为了让两个边界能被**直接**测到，
/// 不用绕一层列表（与 `compareEntries` 同一做法）。
///
/// [descending] 只翻转**时间**那一项：`null` 垫底与同名定序在两个方向上
/// 一致 —— 「网盘没给时间」是「不知道」，不是「最旧」，把它排到正序的
/// 第一行会造出一堆假装很新的条目。
int compareItemsByTime(MediaItem a, MediaItem b, {required bool descending}) {
  final ta = a.modifiedAt;
  final tb = b.modifiedAt;

  if (ta == null && tb == null) return naturalCompare(a.name, b.name);
  if (ta == null) return 1;
  if (tb == null) return -1;

  final byTime = descending ? tb.compareTo(ta) : ta.compareTo(tb);
  if (byTime != 0) return byTime;

  // 同一时刻必须再用名字定序。不定序的话它们的相对位置取决于
  // `List.sort` 的内部行为，**每次重开详情页都可能换位置** ——
  // 用户看到的是「列表在乱跳」，而且找不到任何原因。
  return naturalCompare(a.name, b.name);
}
