/// 「这一集播完了，下一集是哪一条」的取舍规则。
///
/// ## 为什么是个泛型静态方法
///
/// 两个播放器各有一份**不同形状**的列表：
///   - 内置播放页手里是 `List<MediaItem>`（它跑在主引擎里，能直接读仓储）；
///   - 独立播放窗口手里是 `List<PlaylistEntry>`（跨引擎协议里的那一份，
///     见 `PlaylistEntry` 的类文档）。
///
/// 两者都只需要「按 id 找到当前位置，往后取第一条」。规则**只有这一份**：
/// 分开写的话，「播完跳到花絮」这种错会在一个播放器上出现、另一个上没有 ——
/// 而用户根本不会想到这是两套代码。
abstract final class EpisodeQueue {
  const EpisodeQueue._();

  /// [currentId] 之后的下一个可播条目；没有则 `null`（＝播完就停）。
  ///
  /// ## 三条刻意定下来的规则
  ///
  ///   1. **`currentId` 不在列表里就返回 `null`**，不猜、不从头开始。
  ///      找不到当前项说明状态已经不对（列表是别的一部剧的、或者库里
  ///      这一条被删了），此时**唯一安全的动作是不动**。猜错的表现是
  ///      「看第 8 集看到一半，播完自动跳回第 1 集」。
  ///   2. **往后扫，跳过 [isExtra]**，而不是撞到花絮就停。网盘上的剧集目录里
  ///      经常混着 `S01E01.预告.mp4` / `Sample.mkv`，而且顺序不固定 ——
  ///      只跳一格的话，第 2 集播完会开始播一个 30 秒的预告片。
  ///      （`PlayTarget` 里也有一条同样的排除，理由见那个文件的类文档。）
  ///   3. **不循环**：最后一集播完就停。自动跳回第一集等于让机器整夜重播，
  ///      而用户往往已经睡着了 —— 那是要命的（流量、屏幕、电费）。
  static T? nextAfter<T>({
    required List<T> entries,
    required String Function(T) idOf,
    required String currentId,
    bool Function(T)? isExtra,
  }) {
    if (entries.isEmpty || currentId.isEmpty) return null;

    final index = entries.indexWhere((e) => idOf(e) == currentId);
    if (index < 0) return null;

    for (var i = index + 1; i < entries.length; i++) {
      final candidate = entries[i];
      if (isExtra != null && isExtra(candidate)) continue;
      return candidate;
    }
    return null;
  }

  /// 列表里 [currentId] 的下标；找不到返回 -1。
  ///
  /// 单独抽出来是给「剧集面板要把当前集滚进视野」用的 —— 它与
  /// [nextAfter] 必须**同一套匹配口径**，否则会出现「面板高亮在第 5 集、
  /// 自动连播却从第 6 集开始」。
  static int indexOf<T>(
    List<T> entries,
    String Function(T) idOf,
    String currentId,
  ) {
    if (currentId.isEmpty) return -1;
    return entries.indexWhere((e) => idOf(e) == currentId);
  }
}
