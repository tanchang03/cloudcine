import '../../core/error/drive_error.dart';
import '../../core/utils/filename_parser.dart';
import '../entities/media_item.dart';
import '../entities/media_work.dart';

/// 播放时发现「网盘上已经没有这个文件」之后的处置。
///
/// ## 为什么要有这一层
///
/// 媒体库是网盘的一面**索引**：它记的是「上次扫描时在哪个目录下有个什么
/// 文件」。用户随后在夸克里删掉那个文件，索引不会知道 —— 它继续显示那张
/// 海报，直到用户点下去才发现播不了。
///
/// 这时候只有用户能回答「接下来怎么办」，而他能回答的其实是两个问题：
///   1. 这条索引还有没有用？（没有 → 删掉它）
///   2. 如果删，删到哪一层？（只是这一个文件坏了，还是整部都没了）
///
/// 本文件放的是这两个问题的**答案的形状**与文案规则，两个播放器（内置页
/// 与独立窗口）共用 —— 各写一份的话，用户会在两个入口看到两种措辞、两种
/// 范围，而他只会觉得「这个移除功能时灵时不灵」。

/// 从媒体库里移除的范围。
enum MediaRemovalScope {
  /// 只删这一个文件。同一部作品的其它集 / 其它版本**保留**。
  ///
  /// 典型场景：一部剧只丢了第 7 集的源文件，其余都在。
  singleItem,

  /// 整部作品连同名下全部文件一起删。
  ///
  /// 典型场景：用户在网盘上把整个目录删了 —— 那时逐个文件去点「这个文件
  /// 也打不开」是对用户耐心的消耗，他第一次就该能一次清干净。
  wholeWork,
}

/// 这次失败是不是「文件已经不在网盘上」。
///
/// ## 只认 [DriveErrorType.notFound]
///
/// 取链失败有很多种类，而它们的处置**完全不同**：
///
///   - `unauthorized` / `rateLimited` / `network` → 文件还在，只是这次没取到。
///     拿这种失败去问用户「要不要从媒体库移除」是最糟的一类误报：
///     他一点确认，一部好好的片子就没了，而原因只是刚才断了一下网；
///   - `fileTooLarge` → 文件在，只是这条取链路由不给（换条路由能播）；
///   - `notFound` → 服务端明确说**没有这个 fid**。这是唯一一个能支撑
///     「它可能已经被删了」这个推断的信号。
///
/// mpv 侧的 `HTTP error 4xx` 也不在这里判：那只说明**这条直链**失效了
/// （签名过期 / 换 IP），重新取一次链就好，与文件在不在是两回事。
bool isMissingFileError(Object? error) =>
    error is DriveException && error.type == DriveErrorType.notFound;

/// 「这个文件没了，要移除吗」这一个对话框需要的全部信息。
///
/// 它是**纯值对象**：读库由调用方做（控制器），渲染由调用方做（对话框），
/// 这里只负责把「删到哪一层」的文案与可选项算出来 —— 那正是最容易在两处
/// 写岔的地方（一处写「移除整部剧」、另一处写「移除全部」，用户分不清）。
class MissingMediaPlan {
  const MissingMediaPlan({
    required this.itemTitle,
    required this.itemPath,
    required this.workTitle,
    required this.kind,
    required this.fileCount,
  });

  /// 打不开的那个文件的展示名（`MediaItem.displayTitle`）。
  ///
  /// 存**字符串而不是 [MediaItem]**：独立播放窗口跑在另一个 Flutter 引擎
  /// 里，手上只有主窗口通过通道送过来的几个字段，构造不出 `MediaItem`
  /// （它带着 provider / fid / 二十来个列）。而两边必须渲染**同一个**
  /// 对话框 —— 措辞分叉了用户就会觉得这个功能时灵时不灵。
  final String itemTitle;

  /// 它在网盘上的完整路径。摊开给用户看，让他确认「这就是我删掉的那个」。
  final String itemPath;

  /// 它所属作品的片名。作品行缺失时退回文件自己解析出的片名。
  final String workTitle;

  final MediaKind kind;

  /// 这部作品下一共有多少个文件（**并集**口径，含折叠进来的那些目录）。
  ///
  /// 它与详情页「文件」列表的长度必须一致 —— 用户据它判断「是不是整部都
  /// 没了」：写着 24 而只坏了一集，就该选「只移除这一集」；写着 1 时那个
  /// 选项根本没有意义，不该出现。
  final int fileCount;

  /// 从库里的实体装配（主窗口那条路：实体就在手边）。
  ///
  /// [fileCount] 兜底成 1：`itemsForWork` 理论上一定包含 [item] 自己，
  /// 拿到 0 只可能是数据异常（比如这一行刚刚被别的路径删掉）。按 0 走会
  /// 让对话框显示「移除《X》（共 0 个文件）」并藏掉「只删这一个」——
  /// 一个自相矛盾的面板。
  factory MissingMediaPlan.of({
    required MediaItem item,
    required MediaWork? work,
    required int fileCount,
  }) {
    return MissingMediaPlan(
      itemTitle: item.displayTitle,
      itemPath: item.netdiskPath,
      workTitle:
          _nonEmpty(work?.title) ?? _nonEmpty(item.title) ?? item.displayTitle,
      kind: work?.kind ?? item.kind,
      fileCount: fileCount > 0 ? fileCount : 1,
    );
  }

  /// 值不值得单独给出「只删这一个」的选项。
  ///
  /// 一部电影只有一个文件时，「只删这个文件」和「删整部」是**同一件事** ——
  /// 给两个按钮等于逼用户猜它们有什么区别。
  bool get canRemoveSingle => fileCount > 1;

  /// 「只删这一个」的按钮文案。
  String get singleLabel =>
      kind == MediaKind.episode ? '只移除这一集' : '只移除这个文件';

  /// 「整部一起删」的按钮文案。
  ///
  /// ⚠️ 带上文件数。用户据它确认「我要删的是 24 个文件，不是 1 个」——
  /// 一次删掉一整部剧是不可撤销的（要回来得重扫），按钮上必须写清代价。
  String get wholeLabel {
    final unit = switch (kind) {
      MediaKind.episode => '整部剧',
      MediaKind.movie => '这部电影',
      MediaKind.unknown => '这部作品',
    };
    return canRemoveSingle
        ? '移除$unit《$workTitle》（$fileCount 个文件）'
        : '移除《$workTitle》';
  }

  /// 对话框正文的第一句。
  String get headline => '网盘上找不到这个文件了，它可能已经被删除。';

  /// 结果提示（SnackBar / toast）。
  String removedMessage(MediaRemovalScope scope) => switch (scope) {
        MediaRemovalScope.singleItem => '已从媒体库移除「$itemTitle」',
        MediaRemovalScope.wholeWork => '已从媒体库移除《$workTitle》'
            '（$fileCount 个文件）',
      };

  static String? _nonEmpty(String? v) {
    final s = v?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  @override
  String toString() =>
      'MissingMediaPlan($itemTitle, $kind, $fileCount 个文件)';
}
