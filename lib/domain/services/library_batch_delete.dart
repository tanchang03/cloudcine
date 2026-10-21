import '../entities/media_work.dart';

/// 一批要从媒体库里**移除**的作品 —— 批量移除的**计划与文案**。
///
/// ## 与 `DriveDeletePlan` 是两件事，别混
///
/// 那边删的是**网盘上的文件**（不可逆）；这里默认删的是**本地索引行**
/// （重新扫描就能找回）。同一个按钮位置上两种删除的后果完全不同，所以
/// 文案必须分开写、分开测 —— 而用户对「移除」这个词的预期恰恰是「文件
/// 还在」，所以这里要把这件事说在最前面。
///
/// ## 但「顺手把网盘上的也删了」是一个合法诉求
///
/// 用户清片时想做的常常是**真的清掉**：库里留着一条索引、网盘上还占着
/// 几十 GB，等于什么都没做。所以这里多了一个 [alsoDeleteFromDrive]：
/// 勾上之后这个计划**不再是「移除」**，而是「删除」，标题、正文、按钮、
/// 结果提示四处的措辞都要跟着换（[title] / [driveDeleteWarning] /
/// [confirmLabel] / [doneMessage]）。
///
/// ⛔ 默认必须是 `false`：不可逆的那一侧永远要用户主动勾。
///
/// ## 为什么单独一个值对象
///
/// 「移几部、移的是什么、移了会怎样、按钮写什么」这四句话各有一处容易
/// 写错的地方（下面每条都有注释）。收在纯值对象里，测试就能**不渲染任何
/// 界面**地钉住措辞 —— 这类文案出错的方式是「看起来很正常，但少说了一
/// 句关键的」，靠肉眼看界面发现不了。与 `DriveDeletePlan` 同一个套路。
class LibraryBatchDeletePlan {
  const LibraryBatchDeletePlan({
    required this.works,
    this.driveFileCount = 0,
    this.undeletableFileCount = 0,
    this.alsoDeleteFromDrive = false,
  });

  /// 勾选的这批量作品（已经**重新从库里读过**，不是列表上那份快照）。
  final List<MediaWork> works;

  /// 这些作品名下**能删的**网盘文件数（并集口径，含折叠进来的源作品）。
  ///
  /// 只有在它大于 0 时才该给出「一并删网盘」这个选项 —— 名下没有文件
  /// （空壳作品）时勾上它什么也不会发生，那是一个骗人的开关。
  final int driveFileCount;

  /// 落在**不支持删除的网盘**上的文件数（百度是只读接入）。
  ///
  /// 与 [driveFileCount] 分开数：勾上「一并删」时它们删不掉，只能从媒体库
  /// 移除。不提前说，用户会以为那几集也被清掉了。
  final int undeletableFileCount;

  /// 用户是否勾了「同时删除网盘文件」。
  final bool alsoDeleteFromDrive;

  int get count => works.length;

  bool get isEmpty => works.isEmpty;

  /// 值不值得给出「一并删网盘」这个选项。
  bool get canDeleteFromDrive => driveFileCount > 0;

  /// 勾选状态变化后的计划（对话框里那个开关用）。
  ///
  /// 不可删的时候**强制回到 `false`**：把一个什么都不会做的开关留在
  /// 「已勾上」的状态，用户会以为网盘那侧也清了。
  LibraryBatchDeletePlan withDriveDeletion(bool value) => LibraryBatchDeletePlan(
        works: works,
        driveFileCount: driveFileCount,
        undeletableFileCount: undeletableFileCount,
        alsoDeleteFromDrive: value && canDeleteFromDrive,
      );

  /// 其中是「别名行」的部数（`merged_into` 非空）。
  ///
  /// 非零时正文要多说一句：折叠关系会一起被移除 —— 与 `deleteWork` 的
  /// 口径一致（详见仓储里那段注释）。不说的话，用户会以为库里还剩几条
  /// 别名行，而下次扫描它们又回来了。
  ///
  /// ⚠️ 反方向（有人折进这一部）从作品行上**看不出来**（要知道得反查
  /// 全库），所以那句话只说「勾选的这批量里有别名行」这件事本身，不假装
  /// 数得出全部牵连。
  int get mergedInvolvedCount => works.where((w) => w.isMergedAway).length;

  /// 对话框标题。写成问句，与 [confirmLabel] 区分开：两处都写「移除 N 部」
  /// 的话，界面上会重复，测试里 `find.text` 也会同时命中两个。
  ///
  /// ⛔ 勾了「一并删网盘」之后**不能还写「移除」**：那一次按下去是真的
  /// 删文件，用「移除」描述它会把最重的那件事说轻。
  String get title => alsoDeleteFromDrive
      ? '要从媒体库和网盘删除这 $count 部吗？'
      : '要从媒体库移除这 $count 部吗？';

  /// 「移的是什么」那一行 —— 摊开名字，折成「…等 N 部」。
  ///
  /// 只写「3 部」的话，用户无法确认自己勾的是不是心里想的那几部
  /// （列表可能刚被搜索词筛过、可能滚过位置）。
  String previewLine({int limit = 8}) {
    if (isEmpty) return '';
    final shown = works.take(limit).map((w) => '《${w.title}》').toList();
    final head = shown.join('、');
    final rest = count - shown.length;
    return rest <= 0 ? head : '$head 等共 $count 部';
  }

  /// 折叠相关作品存在时的额外一句；没有时返回 `null`。
  ///
  /// 必须单独说：合并过的作品在媒体库里是一个「一部 + 若干别名行」的结构，
  /// 移除目标行时那些别名行会一起走（`deleteWork` 的口径），而界面上
  /// 看不出这件事。
  String? get mergedWarning {
    final n = mergedInvolvedCount;
    if (n == 0) return null;
    return n == 1
        ? '其中 1 部是合并出来的别名行，它会连同目标作品一起移除。'
        : '其中 $n 部是合并出来的别名行，它们会连同各自的目标作品一起移除。';
  }

  /// **这条不能省，也不能改软**：用户对「移除 / 删除」的预期常常是
  /// 「文件也没了」，而这里恰恰相反 —— 必须把它说成一件好事。
  ///
  /// ⛔ 勾了「一并删网盘」之后这句话就是**假话**，绝不能出现
  /// （对话框据此二选一，见 [driveDeleteWarning]）。
  String get keepFilesWarning =>
      '只移除这台设备上的媒体库索引，网盘上的文件原样保留 —— '
      '之后「重新扫描」就能把它们找回来。';

  /// 勾了「一并删网盘」之后顶替 [keepFilesWarning] 的那一段。
  ///
  /// 必须把**三件事**一次说清：删多少、不可逆、本应用救不回来。少任何
  /// 一句，用户按下去之后才发现，而那时已经没有回头路。
  String get driveDeleteWarning =>
      '网盘上的 $driveFileCount 个文件会一起删掉，删完不可撤销 —— '
      '本应用只是网盘的一个客户端，没有能力把它们恢复回来。';

  /// 有文件落在只读网盘上时的补充一句；没有时返回 `null`。
  String? get undeletableWarning => undeletableFileCount == 0
      ? null
      : '$undeletableFileCount 个文件所在的网盘不支持删除，'
          '它们只会从媒体库移除，网盘上原样保留。';

  /// ⚠️ 但也不能说成「完全没有代价」：续播点、播放偏好、学习到的片头片尾
  /// 都挂在索引行上，会跟着一起走。这是用户做这个决定前该知道的事。
  ///
  /// ⛔ 括号里那句「网盘文件本身不受影响」只在**不删网盘**时成立。勾了
  /// 一并删还留着它，就是在一段说「文件会被删」的正文里保证文件没事。
  String get localDataWarning {
    const head = '这些作品的续播进度、播放偏好和自动学到的片头/片尾会一起清掉';
    return alsoDeleteFromDrive ? '$head。' : '$head（网盘文件本身不受影响）。';
  }

  /// 确认按钮的文案。带上数量而不是光写「移除」：按钮是用户最后一眼看到
  /// 的东西，「移除 N 部」比「移除」多提供一次核对机会。
  String get confirmLabel =>
      alsoDeleteFromDrive ? '删除 $count 部（含网盘文件）' : '移除 $count 部';

  /// 结果提示（SnackBar）。`removedItems` 是真正删掉的**文件行**数 ——
  /// 它是「这批量到底有多大」的唯一诚实的回答。
  ///
  /// [drive] 非空表示这次**试过**删网盘，必须把成功与失败两个数都说出来：
  /// 只说成功的话，用户以为清干净了，而网盘上还占着几十 GB；只说失败的话，
  /// 又像是一次都没动。
  String doneMessage({required int removedItems, DriveRemovalSummary? drive}) {
    final files = removedItems == 1 ? '1 个文件' : '$removedItems 个文件';
    final head = '已移除 $count 部作品（$files）';
    if (drive == null) return '$head，网盘文件未动。';

    if (drive.failed == 0) {
      return '$head，网盘上 ${drive.deleted} 个文件已删除。';
    }
    final why = drive.fatalError ?? '网盘拒绝了删除请求';
    if (drive.deleted == 0) {
      return '$head，但网盘文件一个都没删掉（$why）—— '
          '它们还在网盘上，重新扫描会再出现。';
    }
    return '$head，网盘删除 ${drive.deleted} 个成功、${drive.failed} 个失败'
        '（$why，可重新扫描后再试一次）。';
  }

  @override
  String toString() => 'LibraryBatchDeletePlan($count 部'
      '${alsoDeleteFromDrive ? ', 含网盘 $driveFileCount 个文件' : ''})';
}

/// 网盘那一侧删完之后的账 —— 只在用户勾了「一并删网盘」时才有。
///
/// 三个数字缺一不可（[deleted] / [failed] / [fatalError]），理由见
/// [LibraryBatchDeletePlan.doneMessage]：少一个就会出现「说成删干净了」
/// 或「说成一次都没动」这两种都不对的提示。
class DriveRemovalSummary {
  const DriveRemovalSummary({
    required this.deleted,
    required this.failed,
    this.fatalError,
  });

  /// 网盘侧确认删掉的文件数。
  final int deleted;

  /// 发出去但失败、以及**根本没发出去**的文件数（凭证失效时后面几批）。
  final int failed;

  /// 撞上「再试也没用」的错误（凭证失效 / 断网）时的说明；否则 `null`。
  final String? fatalError;

  /// 一个文件都没碰到（没有可删的、或适配器缺失）。
  bool get isEmpty => deleted == 0 && failed == 0;

  @override
  String toString() =>
      'DriveRemovalSummary(deleted=$deleted, failed=$failed, fatal=$fatalError)';
}

/// 批量移除走到哪一步了。
enum RemovalPhase {
  /// 正在删网盘文件（可能分很多批，这一步最慢）。
  drive,

  /// 网盘那边结束了，正在清本地索引（很快，但也要说一声 —— 否则进度条
  /// 在「x/N」满格之后突然消失，看起来像卡住了）。
  library,
}

/// 批量移除的进度快照 —— 给界面上那一层模态进度用。
///
/// 文案写在这个值对象里（与 [LibraryBatchDeletePlan] 同一套路）：界面只
/// 负责把 [label] 显示出来，措辞改动不必去翻 Widget。
///
/// ⚠️ [total] 是**可删文件总数**，不是「批数」：用户关心的是「还有多少个
/// 文件没删完」，而「第 3/7 批」这种说法对他毫无意义（每批 100 个是内部
/// 实现细节，见 `driveMaxFidsPerRequest`）。
class RemovalProgress {
  const RemovalProgress({required this.phase, this.done = 0, this.total = 0});

  /// 还没开始删网盘时的初值。
  static const RemovalProgress starting =
      RemovalProgress(phase: RemovalPhase.drive);

  final RemovalPhase phase;

  /// 已经处理完的文件数（成功 + 失败都算 —— 两者都代表「这一批结束了」）。
  final int done;

  /// 一共要处理多少个可删文件；`0` 表示还没数出来。
  final int total;

  /// 进度条取值；总数未知时给 `null`（`LinearProgressIndicator` 收到
  /// `null` 会画成不确定态，正好是「正在数/正在发第一批」）。
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  /// 界面上那一行字。
  ///
  /// 说清**在删什么**：只写「处理中…」的话，用户看到数字在跳却不知道是
  /// 在动网盘还是动本地 —— 前者不可撤销，后者重扫就能回来，两者的紧张
  /// 程度不一样。
  String get label => switch (phase) {
        RemovalPhase.drive =>
          total > 0 ? '正在删除网盘文件 $done/$total…' : '正在删除网盘文件…',
        RemovalPhase.library => '正在清理媒体库…',
      };

  @override
  String toString() => 'RemovalProgress(${phase.name}, $done/$total)';
}
