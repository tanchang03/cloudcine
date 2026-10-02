import '../entities/media_item.dart';

/// 层级选择器里的一「格」—— 一个季，或一个部。
class WorkLevelGroup {
  const WorkLevelGroup({
    required this.key,
    required this.label,
    required this.items,
  });

  /// 稳定键：季是 `s:3`，部是 `p:2`（`p:0` = 未标部，`p:9999` = 特别篇）。
  ///
  /// ⚠️ **不要用 label 当键**：label 是展示文本，将来改文案（「第三季」→
  /// 「Season 3」）就会让「记住的选中项」全部失效，而那是静默的 ——
  /// 表现为「打开详情页又跳回第一季」。
  final String key;

  /// 展示文本：`第三季` / `第 2 部` / `特别篇` / `未标季`。
  final String label;

  /// 这一格下的全部条目（含花絮），顺序沿用 `itemsForWork` 的「季→部→集」。
  final List<MediaItem> items;

  /// 正片条数 —— 与详情页「文件」那一节的计数口径一致（花絮单列）。
  int get count => items.where((i) => !i.isSampleOrExtra).length;

  /// 这一格下有没有正片。整格都是花絮时，列表区要给一句说明而不是空白。
  bool get hasFeatures => count > 0;

  @override
  String toString() => 'WorkLevelGroup($key "$label", ${items.length} 项)';
}

/// 详情页层级选择器的数据源。**纯函数、可单测**。
///
/// ## 它解决什么
///
/// 一部剧的条目本来是**平铺**的（`WorkDetail.items`）。5 季 60 集就是 60 行
/// 长列表，用户想找第二季第 3 集只能滚。这里把条目按「季 → 部」分好格，
/// 详情页据此画选择器。
///
/// ## 两个必须守住的规则
///
///   1. **只在数据里真的存在时才成层**（`hasSeasonLevel` / `partsOf().length`）。
///      只有一个选项的选择器是噪音 —— 单集电影、单季剧的版式必须与改造前
///      完全一致。
///   2. **季在外、部在内**（用户定的口径）。《进击的巨人》第三季
///      Part.1/Part.2 是典型：季 = 外层、部 = 内层。电影没有季，只有部。
///
/// ## 为什么是纯函数而不是塞进 `WorkDetail`
///
/// 「哪些层该出现」这条判断有三处要一致：选择器要不要画、默认选哪一格、
/// 列表怎么筛。写成一个纯函数就能穷举样本做单测（`S03 Part.1`、
/// 只有部、只有季、什么都没有），而不用起一个 widget。
class WorkLevels {
  const WorkLevels._({
    required this.seasons,
    required Map<String, List<WorkLevelGroup>> partsBySeason,
  }) : _partsBySeason = partsBySeason;

  /// 季层。**永远至少有一格**（条目为空时才是空列表）。
  ///
  /// 长度 < 2 时调用方**不该画**季选择器 —— 见 [hasSeasonLevel]。
  final List<WorkLevelGroup> seasons;

  final Map<String, List<WorkLevelGroup>> _partsBySeason;

  /// 条目为空时的空层级。
  static const WorkLevels empty = WorkLevels._(
    seasons: [],
    partsBySeason: {},
  );

  /// 该不该画「季」选择器。只有一个季（含「全是未标季」）时不画。
  bool get hasSeasonLevel => seasons.length >= 2;

  /// [seasonKey] 这一季下的部层。
  ///
  /// 返回长度 < 2 时调用方不该画「部」选择器。该季没标部时返回空列表 ——
  /// 注意这与「返回一个『未标部』格」不同：前者不画，后者会画一个
  /// 没有信息量的孤格。
  List<WorkLevelGroup> partsOf(String seasonKey) =>
      _partsBySeason[seasonKey] ?? const [];

  /// 从 `items` 派生层级。
  ///
  /// [items] 必须**已按「季 → 部 → 集」排序**（`MediaRepository.itemsForWork`
  /// 的承诺）。这里不重排 —— 排序规则只有一份实现，重排一次就多一处可能与
  /// 仓储层不一致的地方。
  static WorkLevels of(List<MediaItem> items) {
    if (items.isEmpty) return empty;

    final bySeason = <int, List<MediaItem>>{};
    for (final it in items) {
      bySeason.putIfAbsent(it.season ?? 0, () => <MediaItem>[]).add(it);
    }
    final seasonNumbers = bySeason.keys.toList()..sort();

    final seasons = <WorkLevelGroup>[];
    final partsBySeason = <String, List<WorkLevelGroup>>{};
    for (final n in seasonNumbers) {
      final bucket = bySeason[n]!;
      final group = WorkLevelGroup(
        key: 's:$n',
        // `0` 是「没标季号」的桶（与 `itemsForWork` 的 `?? 0` 同源）。
        label: n == 0 ? _unlabeledLabel(bucket) : '第 $n 季',
        items: bucket,
      );
      seasons.add(group);
      partsBySeason[group.key] = _partGroups(group.items);
    }

    return WorkLevels._(seasons: seasons, partsBySeason: partsBySeason);
  }

  /// 「未标季」那个桶的展示名。
  ///
  /// 整桶都是特别篇时改叫「特别篇」：用户定的口径是「特别篇归到所属季的
  /// 一个特别篇部」，而这些文件**一个季号都没声明过**，压根没有「所属季」
  /// 可挂。与其把它们塞进一个叫「未标季」的格里，不如让它们以自己的名字
  /// 示人 —— 用户看到「特别篇」就知道点进去是什么，看到「未标季」则不会。
  static String _unlabeledLabel(List<MediaItem> items) {
    final allSpecials = items.every(
      (i) => i.partLabel != null && i.partLabel!.isNotEmpty,
    );
    return allSpecials ? '特别篇' : '未标季';
  }

  /// 把一季的条目按「部」分组。
  static List<WorkLevelGroup> _partGroups(List<MediaItem> items) {
    final byPart = <int, List<MediaItem>>{};
    for (final it in items) {
      byPart.putIfAbsent(it.partOrder, () => <MediaItem>[]).add(it);
    }
    final orders = byPart.keys.toList()..sort();

    // 整季一条都没标部 → 部层**不存在**（返回空列表），而不是返回一个
    // 「未标部」孤格。
    //
    // ⚠️ 这一条不能省：漏了它，**每一部电影、每一部单季剧**都会多出一个
    // 只有一个选项的「未标部」选择器 —— 而那正是本设计反复强调要避免的
    // 噪音（`hasSeasonLevel` 用 `>= 2` 挡的是同一件事）。
    if (orders.length == 1 && orders.single == 0) return const [];

    return orders.map((o) {
      final group = byPart[o]!;
      // 展示名取组内第一个带 `partLabel` 的 —— 同一部的每一集标签一致
      // （都由同一个 `_partOf` 解析），取第一个就够，不必逐条比对。
      String? label;
      for (final it in group) {
        final l = it.partLabel;
        if (l != null && l.isNotEmpty) {
          label = l;
          break;
        }
      }
      return WorkLevelGroup(
        key: 'p:$o',
        label: label ?? _partLabelOf(o),
        items: group,
      );
    }).toList(growable: false);
  }

  static String _partLabelOf(int order) {
    if (order == 0) return '未标部';
    if (order == MediaItem.specialPartOrder) return '特别篇';
    return '第 $order 部';
  }

  /// [item] 落在 [groups] 的哪一格（按 id 匹配）；找不到返回 `null`。
  ///
  /// 详情页用它把「默认选中」对齐到 `PlayTarget` 选出的那一条 —— 这样
  /// 「打开详情页高亮的层」与「点播放会播的那一集」永远是同一格。
  static String? keyOf(List<WorkLevelGroup> groups, MediaItem? item) {
    if (item == null) return null;
    for (final g in groups) {
      for (final i in g.items) {
        if (i.id == item.id) return g.key;
      }
    }
    return null;
  }

  /// 按 (季, 部) 取条目。两者都为 `null` 时返回全部。
  List<MediaItem> itemsIn({String? seasonKey, String? partKey}) {
    final season = _groupByKey(seasons, seasonKey);
    if (season == null) {
      return const [];
    }
    if (partKey == null) return season.items;
    return _groupByKey(partsOf(season.key), partKey)?.items ?? const [];
  }

  static WorkLevelGroup? _groupByKey(
    List<WorkLevelGroup> groups,
    String? key,
  ) {
    if (key == null) return null;
    for (final g in groups) {
      if (g.key == key) return g;
    }
    return null;
  }
}
