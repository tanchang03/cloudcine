import '../entities/media_work.dart';

/// 一批要从媒体库里**移除**的作品 —— 批量移除的**计划与文案**。
///
/// ## 与 `DriveDeletePlan` 是两件事，别混
///
/// 那边删的是**网盘上的文件**（不可逆）；这里删的是**本地索引行**
/// （重新扫描就能找回）。同一个按钮位置上两种删除的后果完全不同，所以
/// 文案必须分开写、分开测 —— 而用户对「移除」这个词的预期恰恰是「文件
/// 还在」，所以这里要把这件事说在最前面。
///
/// ## 为什么单独一个值对象
///
/// 「移几部、移的是什么、移了会怎样、按钮写什么」这四句话各有一处容易
/// 写错的地方（下面每条都有注释）。收在纯值对象里，测试就能**不渲染任何
/// 界面**地钉住措辞 —— 这类文案出错的方式是「看起来很正常，但少说了一
/// 句关键的」，靠肉眼看界面发现不了。与 `DriveDeletePlan` 同一个套路。
class LibraryBatchDeletePlan {
  const LibraryBatchDeletePlan({required this.works});

  /// 勾选的这批量作品（已经**重新从库里读过**，不是列表上那份快照）。
  final List<MediaWork> works;

  int get count => works.length;

  bool get isEmpty => works.isEmpty;

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
  String get title => '要从媒体库移除这 $count 部吗？';

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
  String get keepFilesWarning =>
      '只移除这台设备上的媒体库索引，网盘上的文件原样保留 —— '
      '之后「重新扫描」就能把它们找回来。';

  /// ⚠️ 但也不能说成「完全没有代价」：续播点、播放偏好、学习到的片头片尾
  /// 都挂在索引行上，会跟着一起走。这是用户做这个决定前该知道的事。
  String get localDataWarning =>
      '这些作品的续播进度、播放偏好和自动学到的片头/片尾会一起清掉'
      '（网盘文件本身不受影响）。';

  /// 确认按钮的文案。带上数量而不是光写「移除」：按钮是用户最后一眼看到
  /// 的东西，「移除 N 部」比「移除」多提供一次核对机会。
  String get confirmLabel => '移除 $count 部';

  /// 结果提示（SnackBar）。`removedItems` 是真正删掉的**文件行**数 ——
  /// 它是「这批量到底有多大」的唯一诚实的回答。
  String doneMessage({required int removedItems}) {
    final files = removedItems == 1 ? '1 个文件' : '$removedItems 个文件';
    return '已移除 $count 部作品（$files），网盘文件未动。';
  }

  @override
  String toString() => 'LibraryBatchDeletePlan($count 部)';
}
