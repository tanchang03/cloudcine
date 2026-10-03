import '../../core/utils/drive_paths.dart';
import '../entities/drive_entry.dart';
import 'drive_batch.dart';

/// 移动的**目标目录** —— 网盘上的一个目录。
///
/// ## 为什么它和 `DriveCrumb` 长得一模一样
///
/// 两者都是「id + 显示名 + 展示路径」。没有合成一个类型，是因为 `DriveCrumb`
/// 住在 UI 层（`ui/providers/drive_browse_providers.dart`），而本文件在
/// `domain/` —— **domain 不 import UI** 是这个项目的分层底线。所以这里留一个
/// 领域侧的孪生体，转换在 UI 边界上做一次（3 个字段，见
/// `drive_move_dialog.dart`）。
///
/// 它同时是「最近用过的目录」的**持久化形状**，所以带 [toJson] / [fromJson]。
class MoveTarget {
  const MoveTarget({
    required this.fid,
    required this.name,
    required this.path,
  });

  /// 网盘目录 ID。根目录是适配器给的 `rootId`。
  final String fid;

  /// 目录名。根目录用 `/`。
  final String name;

  /// 归一化展示路径（不带结尾斜杠，根为 `/`）。
  final String path;

  bool get isRoot => normalizeDrivePath(path) == driveRootPath;

  /// 给人看的标签。
  ///
  /// 根目录写「我的网盘」而不是 `/`：`移动到 /` 读起来像一个笔误，
  /// 而「移动到 我的网盘」不会。这个字符串会出现在**确认按钮**上，
  /// 所以它必须一眼能读。
  String get label => isRoot ? '我的网盘' : normalizeDrivePath(path);

  Map<String, Object?> toJson() => {'fid': fid, 'name': name, 'path': path};

  /// 从持久化形状还原。**读不懂返回 `null`**，调用方把这一条丢掉。
  ///
  /// 刻意不抛异常：这个值只来自「最近用过的目录」这份缓存，它坏掉的唯一
  /// 后果应该是「这次没有最近记录」，绝不该让文件夹页打不开。
  ///
  /// [fid] 缺失或为空就整条作废（没有它这条记录根本没法用来移动）；
  /// [name] 缺失则退回路径末段 —— 那是能救回来的，不必连累整条。
  static MoveTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fid = raw['fid'];
    final path = raw['path'];
    if (fid is! String || fid.isEmpty) return null;
    if (path is! String) return null;

    final normalized = normalizeDrivePath(path);
    final name = raw['name'];
    return MoveTarget(
      fid: fid,
      name: name is String && name.isNotEmpty
          ? name
          : drivePathName(normalized),
      path: normalized,
    );
  }

  /// 按 fid 判等（路径只是显示用的附属信息）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MoveTarget && other.fid == fid;

  @override
  int get hashCode => fid.hashCode;

  @override
  String toString() => 'MoveTarget($label, $fid)';
}

/// 一次批量移动的**计划与文案**。
///
/// 与 `DriveDeletePlan` 是姊妹关系（同一套对话框套路、同一套分块），差别在
/// 后果：删除不可逆，移动可逆（再移回来）。所以两边文案的**重心不同** ——
/// 删除那边最重的是「不可撤销」，这边最重的是「**移到哪儿去了**」。
///
/// 用户移错目录时，唯一能自救的信息就是目标路径。所以它出现在确认按钮上，
/// 而不是只躺在正文里。
class DriveMovePlan {
  const DriveMovePlan({
    required this.entries,
    required this.sourceDirPath,
    required this.target,
  });

  /// 用户勾选的那些条目（可能既有目录也有文件）。
  final List<DriveEntry> entries;

  /// 这些条目**现在**所在目录的展示路径（不带结尾斜杠）。
  ///
  /// 两处用途都需要它：判断「目标是不是自己 / 自己的子孙」，以及算出每个
  /// 条目的完整路径。
  ///
  /// ⚠️ 不能用 `DriveEntry.path` 代替：列目录拿到的条目里那个字段是 `null`
  /// （只有扫描器会填），拿它做前缀比较会**静默地一条都匹配不到**，
  /// 于是「移进自己的子目录」这条检查形同不存在。
  final String sourceDirPath;

  /// 目标目录。
  final MoveTarget target;

  int get count => entries.length;

  /// 其中目录的个数。
  int get folderCount => entries.where((e) => e.isDirectory).length;

  int get fileCount => count - folderCount;

  /// 某个条目**现在**的完整路径（不带结尾斜杠）。
  String sourcePathOf(DriveEntry entry) =>
      normalizeDrivePath(drivePathJoin(sourceDirPath, entry.name));

  /// 「从哪来」那一端的标签。根目录写「我的网盘」。
  String get sourceLabel {
    final p = normalizeDrivePath(sourceDirPath);
    return p == driveRootPath ? '我的网盘' : p;
  }

  /// 目标目录不能用的原因；能用时返回 `null`。
  ///
  /// 两种情况都必须在**客户端**拦下，理由各不相同：
  ///
  ///   1. **目标是被移动目录自己、或它的子孙**（把 `/电影` 移进
  ///      `/电影/科幻`）。服务端会不会拒绝我们没实测过；一旦它不拒绝，
  ///      结果是一个**自引用目录** —— 目录视图里点进去可以无限深，
  ///      而且没有任何撤销入口。这是这个功能里唯一可能造成结构性损坏的
  ///      操作，所以宁可误拦。
  ///   2. **目标就是这些条目现在所在的目录**。这不是错误，是一次**空操作**。
  ///      但我们会照样报「已移动 N 项」，用户以为动了、其实没动，然后去
  ///      目标目录里找那批「刚被移过去」的文件。报一个成功的空操作比报错
  ///      更坏 —— 错至少能被发现。
  String? invalidTargetReason() {
    final targetPath = normalizeDrivePath(target.path);

    for (final entry in entries) {
      if (!entry.isDirectory) continue;
      // `drivePathIsUnder` 含「等于」，所以这一条同时覆盖「移进自己」。
      if (drivePathIsUnder(targetPath, sourcePathOf(entry))) {
        return '不能把目录移动进它自己或它的子目录里。';
      }
    }

    if (targetPath == normalizeDrivePath(sourceDirPath)) {
      return '这些条目已经在这个目录里了。';
    }

    return null;
  }

  /// 按 [driveMaxFidsPerRequest] 切好的 fid 批次。空计划返回空列表。
  List<List<String>> idChunks() => chunkFids([for (final e in entries) e.id]);

  /// 对话框标题。写成问句，与 [confirmLabel]（按钮）区分开 ——
  /// 两处若都是「移动 N 项」，界面上会重复，测试里 `find.text` 也会同时
  /// 命中两个。
  String get title => titleFor(count);

  /// 标题的**静态版**。
  ///
  /// 存在的理由很实际：对话框要在「用户还没选目标目录」时就把标题画出来，
  /// 而那个时刻构造不出完整的计划（[target] 是必填的）。把它写成静态，
  /// 文案就仍然只有一份真源，而不是在界面里再拼一遍字面量。
  static String titleFor(int count) => '要移动这 $count 项吗？';

  /// 「从哪来 → 到哪去」一行。这是用户核对目标的主要位置。
  String get routeLabel => '$sourceLabel  →  ${target.label}';

  /// 勾选里有目录时的说明；没有目录时返回 `null`。
  ///
  /// 比删除那边**轻**：移动一个目录是把它整个搬走，不是抹掉，所以这里写
  /// 「一起移动」而不是「一起删掉」。这句仍然必要 —— 列表里那一行只有
  /// 一个目录名，看不出它后面挂着几百 GB。
  String? get folderNote => folderNoteFor(folderCount);

  /// [folderNote] 的**静态版**，理由与 [titleFor] 相同。
  static String? folderNoteFor(int folderCount) => folderCount == 0
      ? null
      : '$folderCount 个目录会连同里面的全部文件一起移动。';

  /// 确认按钮的文案。**必须带上目标目录**。
  ///
  /// 这是与删除最大的一处差异：删除按钮写个数量就够了（用户在正文里已经
  /// 确认过要删什么），而移动最常见的失误是**移错目录**，且用户按下去之前
  /// 最后一眼看到的就是这个按钮。只写「移动 37 项」等于把这唯一一次核对
  /// 机会浪费掉。
  String get confirmLabel => '移动到 ${target.label}';

  /// 同名冲突的说明。
  ///
  /// ⚠️ 这句是**如实说不知道**，不是客套：网盘这条接口的请求体里没有覆盖
  /// 开关，而「目标目录里已有同名文件时服务端会覆盖还是改名」我们没有实测
  /// 过。写成「不会覆盖已有文件」就是替服务端做承诺。
  String get sameNameNote =>
      '目标目录里若有同名文件，网盘会覆盖还是改名我们没有把握，请自行留意。';

  /// 结果提示（SnackBar）。
  ///
  /// ⚠️ 部分失败时必须把失败数说出来 —— 只说「已移动 2900 项」会让用户以为
  /// 全动完了，而剩下那 100 项还留在原来的目录里，他会以为界面没刷新。
  String movedMessage({required int moved, required int failed}) {
    if (failed == 0) return '已移动 $moved 项到「${target.label}」。';
    if (moved == 0) return '移动失败：$failed 项都没动，网盘上原样还在。';
    return '已移动 $moved 项到「${target.label}」，'
        '$failed 项失败（多半是限流，可以再试一次）。';
  }

  @override
  String toString() => 'DriveMovePlan($count 项, $sourceLabel → ${target.label})';
}
