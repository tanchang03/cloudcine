import '../../core/utils/format.dart';
import '../entities/drive_entry.dart';
import 'drive_batch.dart';

/// 一批待删除的网盘条目 —— 批量删除的**计划与文案**。
///
/// ## 为什么单独一个值对象，而不是让对话框自己拼
///
/// 「删几个、删的是什么、能腾出多少、删了能不能回来」这四句话，用户是按
/// 这个顺序读的，而它们各有一处容易写错的地方（下面每条都有注释）。把它们
/// 收在一个纯值对象里，测试就能**不渲染任何界面**地钉住这些措辞 ——
/// 而这类文案出错的方式是「看起来很正常，但少说了一句关键的」，靠肉眼看
/// 界面是发现不了的。
///
/// 与 `MissingMediaPlan`（`missing_media.dart`）同一个套路，区别在于那个
/// 处理的是「网盘上已经没了、清索引」，这个处理的是「用户要主动删网盘上
/// 的东西」—— 后者的后果不可逆，所以文案必须更明确。
class DriveDeletePlan {
  const DriveDeletePlan({required this.entries});

  /// 用户勾选的那些条目（可能既有目录也有文件）。
  final List<DriveEntry> entries;

  /// 一次请求最多带多少个 fid。
  ///
  /// 值本身在 `drive_batch.dart` —— 移动那边（`DriveMovePlan`）要守同一个数，
  /// 而两处各写一份就会漂移。理由与出处见 [driveMaxFidsPerRequest]。
  static const int maxIdsPerRequest = driveMaxFidsPerRequest;

  int get count => entries.length;

  /// 其中目录的个数。
  int get folderCount => entries.where((e) => e.isDirectory).length;

  int get fileCount => count - folderCount;

  /// 网盘**给了**体积的那些条目之和。
  ///
  /// ⚠️ 这只是「已知部分」。目录的体积在夸克列目录响应里通常是 `null` 或
  /// `0`（`DriveEntry.sizeBytes` 的文档），所以勾了一个 200 GB 的电影目录
  /// 时这个数可能是 0 —— 界面上绝不能说成「释放 0 B」。
  int get knownBytes =>
      entries.fold<int>(0, (sum, e) => sum + (e.sizeBytes ?? 0));

  /// [knownBytes] 是不是**下界**（真实释放只会更多）。
  ///
  /// 只要有一个条目的体积拿不到（目录一律算拿不到），总和就只能是下界。
  /// 界面上因此写「至少释放 X」而不是「释放 X」—— 后者在勾了目录时会
  /// 明显少报，用户删完看到容量条掉了 200 GB，会觉得这个预估是错的。
  bool get freedIsLowerBound =>
      entries.any((e) => e.isDirectory || (e.sizeBytes ?? 0) <= 0);

  /// 按 [maxIdsPerRequest] 切好的 fid 批次。空计划返回空列表。
  List<List<String>> idChunks() =>
      chunkFids([for (final e in entries) e.id]);

  /// 对话框标题。
  ///
  /// 写成问句，与 [confirmLabel]（按钮）区分开：两处若都是「删除 N 项」，
  /// 界面上会重复，测试里 `find.text` 也会同时命中两个 —— 而那种含糊正是
  /// 「用户以为自己点的是标题」的来源。
  String get title => '要删除这 $count 项吗？';

  /// 「能腾出多少」那一行。
  ///
  /// 三种说法对应三种**事实**，不能合并：数字准不准，用户是按它决定要不要
  /// 按下删除的。
  String get freedLabel {
    if (knownBytes <= 0) {
      return '释放空间未知（网盘没提供这些条目的体积）';
    }
    final size = formatBytes(knownBytes, fractionDigits: 1);
    return freedIsLowerBound ? '至少释放 $size' : '释放约 $size';
  }

  /// 勾选里有目录时的额外警告；没有目录时返回 `null`。
  ///
  /// 必须单独说这一句：用户以为自己在删「一个文件夹图标」，实际连带里面
  /// 几百 GB 的片子一起没了。列表里那一行只写着一个目录名，看不出这件事。
  String? get folderWarning => folderCount == 0
      ? null
      : '$folderCount 个目录会连同里面的全部文件一起删掉'
          '（这里不会逐个列出来）。';

  /// 不可逆警告。**这条不能省，也不能改软**。
  ///
  /// 删掉的东西本应用没有能力恢复（它只是网盘的一个客户端），而用户对
  /// 「删除」这个词的预期常常是「进回收站，还能捞回来」。写成
  /// 「不可撤销」而不是「请确认」，是因为后者读起来像一句客套话。
  String get irreversibleWarning =>
      '删除后不可撤销：夸克侧按永久删除处理，本应用无法恢复。';

  /// 确认按钮的文案。
  ///
  /// 带上数量而不是光写「删除」：按钮是用户最后一眼看到的东西，
  /// 「删除 37 项」比「删除」多提供一次核对机会。
  String get confirmLabel => '删除 $count 项';

  /// 结果提示（SnackBar）。
  ///
  /// ⚠️ 部分失败时**必须把失败数说出来**。只说「已删除 2900 项」会让用户
  /// 以为删干净了，而剩下那 100 项在列表里还好好待着 —— 他会以为界面没刷新。
  String deletedMessage({required int deleted, required int failed}) {
    if (failed == 0) return '已删除 $deleted 项，媒体库索引已同步清理。';
    if (deleted == 0) return '删除失败：$failed 项都没删掉，网盘上原样还在。';
    return '已删除 $deleted 项，$failed 项失败（多半是限流，可以再试一次）。';
  }

  @override
  String toString() => 'DriveDeletePlan($count 项, '
      '$folderCount 目录 / $fileCount 文件, ${knownBytes}B)';
}
