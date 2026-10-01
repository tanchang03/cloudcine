import '../entities/media_item.dart';

/// 「点开这部作品，该播哪一条」的取舍规则。
///
/// ## 它解决的是哪个问题
///
/// 媒体库卡片点下去要**直接开始播**（这是 VidHub / Infuse 一类的标准行为：
/// 用户点海报的意图是看片，不是先看一页简介）。但一个作品下面挂着的东西
/// 可能有很多种：
///
///   - 电影：1 条，或者同一部片的多个版本（1080p / 2160p / 导演剪辑版）；
///   - 剧集：几十条，跨季；
///   - 花絮、预告、样片：一堆时长几分钟的碎片。
///
/// 随便挑一条会踩两个坑：
///   1. 挑到花絮 —— 用户点《流浪地球 2》看到 40 秒的预告片；
///   2. 挑到第一集，而他已经看到第 20 集了 —— 每次都要手动翻回去。
///
/// ## 为什么放在领域层
///
/// 它要在**至少两处**用同一套口径：
///   - 媒体库卡片点击（本文件的主要调用方）；
///   - 将来「继续观看」横向列表点进来。
///
/// 两处各写一份的话，「从海报墙点进去」和「从继续观看点进去」会落到不同的
/// 一集 —— 而这种不一致极难被发现。
///
/// 它是纯函数，不碰时钟也不碰存储，所以可以直接单元测试。
///
/// ## 输入契约
///
/// [items] 必须**已按「季 → 集 → 名称」排序**（`MediaRepository.itemsForWork`
/// 的承诺）。这里不重排，是为了让排序规则只有一份实现 —— 重排一次就多一处
/// 可能与仓储层不一致的地方。
abstract final class PlayTarget {
  const PlayTarget._();

  /// 选出该播的那一条。作品下没有任何条目时返回 `null`。
  ///
  /// [resume] 是「有续播点的条目 → 续播位置」。**没有续播点的条目不出现在
  /// 里面**（与 `MediaRepository.resumePositions` 同一口径），所以
  /// `resume.containsKey(id)` 本身就是「这一集看到一半」的判据。
  ///
  /// [lastPlayedAt] 是「条目 id → 最近播放时刻」，缺省表示没播过。
  static MediaItem? resolve({
    required List<MediaItem> items,
    Map<String, Duration> resume = const {},
    Map<String, DateTime> lastPlayedAt = const {},
  }) {
    final playable = _playable(items);
    if (playable.isEmpty) return null;
    if (playable.length == 1) return playable.first;

    // 1. 「接着看」：最近播过、且**还留着续播点**的那一集。
    //
    //    这是最高优先级：用户点卡片最常见的意图就是「接着上次看」。
    //    要求「还留着续播点」而不是「最近播过」，是因为看完的那一集续播点
    //    会被清掉 —— 那种情况下从片头重播那一集并不是用户想要的。
    final withResume = playable
        .where((i) => (resume[i.id] ?? Duration.zero) > Duration.zero)
        .toList(growable: false);
    if (withResume.isNotEmpty) {
      // 拿不到播放时刻（老库、或位置是手工导入的）时退到列表顺序的最后一个，
      // 也就是集号最大的那一集。比「列表第一个」更接近「他看到哪儿了」。
      return _mostRecentlyPlayed(withResume, lastPlayedAt) ?? withResume.last;
    }

    // 2. 有播放记录、但那一集已经看完（续播点被清）→ 仍然回到那一集。
    //
    //    为什么不去猜「下一集」：`lastPlayedAt` 有值 + 没有续播点，既可能是
    //    「看完了」，也可能是「点开 3 秒就关了」。猜错会直接把用户丢到
    //    一集他根本没看过的内容上，而猜错的代价远大于「重看一集的开头」。
    final playedPick = _mostRecentlyPlayed(playable, lastPlayedAt);
    if (playedPick != null) return playedPick;

    // 3. 全新的一集都没播过 → 第一集。
    return playable.first;
  }

  /// 从候选里挑出「最近播放」的那一条；全都没播过时返回 `null`。
  ///
  /// 排序键是 `lastPlayedAt`（降序），**同刻或缺失时用列表顺序兜底** ——
  /// 列表顺序是「季 → 集」，也就是「更靠后的一集更晚」。这样老库里
  /// `lastPlayedAt` 全为空时，行为退化成「播最后出现的那一集」，
  /// 而不是随 Map 迭代顺序抖动。
  static MediaItem? _mostRecentlyPlayed(
    List<MediaItem> candidates,
    Map<String, DateTime> lastPlayedAt,
  ) {
    MediaItem? best;
    DateTime? bestAt;
    for (final item in candidates) {
      final at = lastPlayedAt[item.id];
      if (at == null) continue;
      // 严格大于：同一时刻时保留**先出现**的（列表里更靠前的一集）。
      if (bestAt == null || at.isAfter(bestAt)) {
        best = item;
        bestAt = at;
      }
    }
    return best;
  }

  /// 可播条目：优先正片；一个正片都没有（整组都是花絮）时退回全部。
  ///
  /// 与 `WorkDetail.features` 同一口径，但**不做「正片为空就返回空」**——
  /// 只有花絮的作品也该能点开，否则那些条目在媒体库界面上等于不存在。
  static List<MediaItem> _playable(List<MediaItem> items) {
    final features =
        items.where((i) => !i.isSampleOrExtra).toList(growable: false);
    return features.isEmpty ? items : features;
  }
}
