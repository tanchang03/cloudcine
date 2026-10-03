import '../../core/utils/file_names.dart';
import '../entities/drive_entry.dart';

/// 目录视图（「文件夹」）列表的排序方式。
///
/// ## 为什么是一个枚举 + 一组纯函数
///
/// 「按什么排」有**两个入口**（目录视图工具条、设置页的默认值），而
/// 「排出来到底是什么顺序」只能有一份实现 —— 尤其是两个**写错了不报错、
/// 只表现为列表顺序怪**的地方：
///
///   - `modifiedAt` 为 `null` 的条目排到哪一头；
///   - 时间**完全相同**的两条怎么定序（网盘批量上传时整批同一个秒级时间戳）。
///
/// 抽成纯函数才钉得住，也才能在 `test/domain/folder_sort_test.dart` 里直接断言。
enum FolderSortMode {
  /// 按修改时间**倒序**（新 → 旧）。**默认**。
  ///
  /// 目录视图存在的意义就是回答「我新传的东西在哪」，所以默认把最新的排
  /// 在第一行 —— 名称升序要一直翻到最后才看得见刚传的片子，那正是用户
  /// 最想第一眼看到的东西。
  modifiedTime('修改时间'),

  /// 按名称**自然序**升序（`第2期` 在 `第10期` 前面）。
  fileName('名称');

  const FolderSortMode(this.label);

  /// 界面上给用户看的名字（工具条、设置页下拉框共用一份）。
  final String label;

  /// 存进设置库的稳定字符串。
  ///
  /// ⚠️ 用**枚举名本身**，与 `AudioEffectPreset.value` 同一套口径：
  /// 改它等于让已经存下来的设置**静默失效**（读不懂就退回默认排序），
  /// 用户只会觉得「我设的排序自己变回去了」，不会有任何报错。
  String get value => name;

  /// 从设置里读到的值还原。
  ///
  /// 读不懂（老版本写的、手工改过的）一律退回 [modifiedTime] —— 也就是
  /// 默认值。**不要**在这里抛异常：一个坏掉的设置值不该让目录视图打不开。
  static FolderSortMode parse(String? raw) {
    for (final mode in values) {
      if (mode.value == raw) return mode;
    }
    return FolderSortMode.modifiedTime;
  }
}

/// 按 [mode] 排一组条目，返回**新列表**（不动入参）。
///
/// 只决定「组内顺序」；「目录整组排在视频前面」是**结构**而不是顺序，
/// 由 [sortListing] 保证 —— 排序模式换不了它。
List<DriveEntry> sortEntries(List<DriveEntry> entries, FolderSortMode mode) {
  final sorted = [...entries];
  sorted.sort((a, b) => compareEntries(a, b, mode));
  return sorted;
}

/// 一层目录的内容：**目录在前、视频居中、其他文件在后**，三组内部各自按
/// [mode] 排。
///
/// ## 组间顺序为什么是「结构」而不是「顺序」
///
/// 目录永远在前与排序模式无关：用户按修改时间找片子时，仍然要先能一眼看到
/// 有哪些子目录可以进；把子目录冲散到列表各处，等于把「导航」这件事弄丢了。
///
/// 其他文件（字幕 / 图片 / 文档 / 压缩包…）永远垫底，理由与目录相反 ——
/// 它们是**附属物**：同一个目录里往往一部片子配 3 条字幕 + 2 张图，
/// 混进视频里会把「这一层有几部片子」这件事冲散。但它们**必须列出来**
/// （以前只给一个数字），因为用户上传一个 `.zip` 就是想在这里把它拿回去。
({List<DriveEntry> folders, List<DriveEntry> videos, List<DriveEntry> others})
    sortListing(
  List<DriveEntry> folders,
  List<DriveEntry> videos,
  List<DriveEntry> others,
  FolderSortMode mode,
) {
  return (
    folders: sortEntries(folders, mode),
    videos: sortEntries(videos, mode),
    others: sortEntries(others, mode),
  );
}

/// 两条之间的比较。公开是为了让上面那两个边界能被**直接**测到，
/// 不用绕一层列表。
int compareEntries(DriveEntry a, DriveEntry b, FolderSortMode mode) {
  switch (mode) {
    case FolderSortMode.fileName:
      return naturalCompare(a.name, b.name);

    case FolderSortMode.modifiedTime:
      final ta = a.modifiedAt;
      final tb = b.modifiedAt;

      // 时间未知的**垫底**，与海报墙的 `WorkSort.recentModified` 同一口径。
      // 把它们当成 1970 年排到最前面的话，第一屏会变成一堆「不知道什么时候
      // 传的」条目 —— 而用户点这个排序正是想先看最新的。
      if (ta == null && tb == null) return naturalCompare(a.name, b.name);
      if (ta == null) return 1;
      if (tb == null) return -1;

      final byTime = tb.compareTo(ta);
      if (byTime != 0) return byTime;

      // 同一时刻必须再用名字定序。网盘对「一次批量上传」给出的时间戳精度
      // 只到秒，整批会撞在同一个值上；不定序的话它们的相对位置取决于
      // `List.sort` 的内部行为，**每次重新列目录都可能换位置** ——
      // 用户看到的是「列表在乱跳」，而且找不到任何原因。
      return naturalCompare(a.name, b.name);
  }
}
