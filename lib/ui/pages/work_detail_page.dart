import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/follow_read.dart';
import '../../domain/services/item_sort.dart';
import '../../domain/services/work_levels.dart';
import '../../domain/services/work_merge_service.dart';
import '../providers/app_providers.dart';
import '../providers/follow_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scrape_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/copy_button.dart';
import '../widgets/customize_work_dialog.dart';
import '../widgets/genre_edit_dialog.dart';
import '../widgets/manual_scrape_dialog.dart';
import '../widgets/media_item_row.dart';
import '../widgets/merge_work_dialog.dart';
import '../widgets/play_action.dart';
import '../widgets/poster_image.dart';
import '../widgets/tv_affordance.dart';
import '../widgets/tv_focus.dart';

/// 「刮削」与「手动」两个按钮**共用**的那句「为什么按不动」。
///
/// 两处 tooltip 与 TV 上那行可见小字都从这里取。抄成三份的话，改了一处就会
/// 出现「tooltip 说去设置里开开关、屏幕上那行字说去别处」这种自相矛盾 ——
/// 而这句话是 TV 用户**唯一**的出路说明（电视上没有鼠标可以去悬停问一下）。
const String _noScrapeSourceReason = '还没有可用的在线刮削源。'
    '到「设置 → 刮削」打开开关，并填入 TMDB Key 或豆瓣 Cookie。';

/// 作品详情页。
///
/// 版式：左边海报与元数据，右边文件列表。这是「一部剧有很多集」时
/// 唯一说得通的结构 —— 把剧集摊成卡片墙会让「第 3 集」和「另一部电影」
/// 长得一样。
class WorkDetailPage extends ConsumerWidget {
  const WorkDetailPage({super.key, required this.workKey});

  final String workKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(workDetailProvider(workKey));

    return Scaffold(
      backgroundColor: Colors.transparent,
      // ⛔ **壳外的整幅页要自己让开过扫描区**：`/work` 是 `StatefulShellRoute`
      // **之外**的一级路由（见 `app_router.dart`），它把整屏换掉，于是拿不到
      // `AppShell` 在 `app_shell.dart` 的 `body:` 那一层加的内边距
      // （⚠️ 不写行号 —— 那层一改行号就飘）。
      //
      // 不加的后果有两层，第二层更难受：最左边那个返回键会落进过扫描带里被切掉；
      // 而电视上从媒体库点进这一页时，内容会**整体左移 48px** —— 页头本该在
      // 同一个位置，跳一下会让人以为换了个应用。实测：不加时这一页拿满 960，
      // 顶栏左内边距只有 10。理由与「哪两种页面不需要加」见
      // `AppTheme.safeAreaInsets` 的文档。
      body: Padding(
        padding: AppTheme.safeAreaInsets(context),
        child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
            child: Row(
              children: [
                // 返回 / 刷新都是纯图标按钮 —— TV 上没有 hover，
                // 不补文字标签就等于「两个含义不明的图标」。
                TvIconLabel(
                  label: '返回',
                  child: IconButton(
                    onPressed: () => context.pop(),
                    iconSize: 18,
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
                const Spacer(),
                TvIconLabel(
                  label: '刷新',
                  child: IconButton(
                    tooltip: '刷新',
                    onPressed: () =>
                        ref.invalidate(workDetailProvider(workKey)),
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: detail.when(
              // ⚠️ **不能**删这两个开关，否则播放中这一页每 10 秒白一下。
              //
              // 依赖变化（进度刷新信号）在 Riverpod 里是 **reload**，
              // `skipLoadingOnReload` 默认 `false` —— 也就是默认会切到
              // `loading:` 分支。而播放页报进度是每 10 秒一次，用户会看到
              // 一个不停闪转圈的详情页。
              //
              // 关掉它保留上一份数据：进度条晚半秒更新，比整页闪一下好得多。
              // 首次加载没有上一份数据，仍然正常显示转圈。
              skipLoadingOnReload: true,
              loading: () => const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline_rounded,
                danger: true,
                title: '读取失败',
                body: '$e',
                actionLabel: '重试',
                onAction: () => ref.invalidate(workDetailProvider(workKey)),
              ),
              data: (d) => d == null
                  ? const EmptyState(
                      icon: Icons.help_outline_rounded,
                      title: '找不到这部作品',
                      body: '它可能已被重新扫描移除。',
                    )
                  : _DetailBody(detail: d),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// 「播这部片」+ 季 / 部层级。
///
/// 起播走 `playItem`（全应用唯一的起播入口），所以从这里点播与从海报墙
/// 点播的行为**完全一致**：桌面端开独立窗口，其余平台跳内置播放页。
///
/// ## 为什么它是 stateful
///
/// 「现在在看哪一季 / 哪一部」是**页面内的临时状态**，不该进 provider：
/// 它只是展示筛选，不参与落库、也不需要跨页共享。放进 provider 反而会让
/// 「换一部作品」时残留上一部的选中项。
class _DetailBody extends ConsumerStatefulWidget {
  const _DetailBody({required this.detail});

  final WorkDetail detail;

  @override
  ConsumerState<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends ConsumerState<_DetailBody> {
  /// 用户手选的层级键（`s:3` / `p:2`）。`null` = 还没选过，走默认。
  ///
  /// ⚠️ 存**键**而不是存 `WorkLevelGroup` 对象：provider 一刷新 group 就是
  /// 新实例，存对象会让「记住的选中项」永远指向上一份数据 —— 表现是
  /// 「每次刷新都跳回第一季」，而且不报错。
  String? _seasonKey;
  String? _partKey;

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final work = detail.work;
    final levels = WorkLevels.of(detail.items);

    final seasonKey = _resolveSeason(levels);
    final parts =
        seasonKey == null ? const <WorkLevelGroup>[] : levels.partsOf(seasonKey);
    final partKey = _resolvePart(parts);
    final visible = levels.itemsIn(seasonKey: seasonKey, partKey: partKey);

    final features =
        visible.where((i) => !i.isSampleOrExtra).toList(growable: false);
    final extras =
        visible.where((i) => i.isSampleOrExtra).toList(growable: false);
    final primary =
        features.isNotEmpty ? features.first : (visible.isEmpty ? null : visible.first);

    // 列表**显示**顺序。
    //
    // ⚠️ `primary` 是在这一步**之前**算的 —— 排序只改列表长什么样，不改
    // 「点播放会播哪一条」。让播放按钮跟着排序走的话，用户切一次「修改时间
    // 倒序」就变成「点播放播最新上传的那个文件」，而那几乎从不是他想要的
    // （他要的是续播那一集 / 第一集）。这条口径与 `PlayTarget.resolve` 一致。
    final sortMode = ref.watch(itemSortModeProvider);
    final shownFeatures = sortItems(features, sortMode);
    final shownExtras = sortItems(extras, sortMode);

    // 「追剧之后才出现、而且还没看过」—— 剧集行的 NEW 标签。
    //
    // ⛔ 判据**只在这一处**算：`isNewSinceFollow` 需要作品（`followStartedAt`
    //    水位线）与条目（`firstSeenAt`）两边，而这一层恰好两者都有。
    //    让 `MediaItemRow` 各自算一遍的话，两处一旦分叉就会得到
    //    「列表标了 NEW，行底进度条却显示看过」这种自相矛盾的样子。
    //
    // ⛔ 「播过没有」**不是**只看 `maxPositions`：那一列只在进度上报时写，
    //    而进度上报只在整十秒边界触发 —— 用户点开一集看了 2~3 秒就关掉时，
    //    库里一个字都没写，NEW 就不会消失（2026-10-07 现场）。
    //    判据与取舍统一收在 [isItemWatched]：`max_position_ms`（看到哪儿了）
    //    或 `last_played_at`（起播即写的已读回执）**任一有值**即算看过。
    //
    // ⛔ 续播点（`resumePositionMs`）仍然不能用：它看完会被清成 NULL，
    //    拿它当判据的话，用户刚看完一集回来，那一集反而重新变成 NEW。
    bool isNewItem(MediaItem i) => work.isNewSinceFollow(
          firstSeenAt: i.firstSeenAt,
          played: isItemWatched(i, detail.maxPositions),
        );

    // 每一格里有几条新的 —— 季 / 部选择器上的角标读它。
    //
    // ⛔ 与 [isNewItem] 必须用**同一个**判据。角标说「这一格里有 2 条新的」、
    //    点进去却一条都没标 NEW，是最容易让人不再相信角标的那个不一致。
    int newCountOf(WorkLevelGroup g) => g.items.where(isNewItem).length;

    final visibleNew = visible.where(isNewItem).length;

    // 「新集在**别的**格里」—— 必须主动指路。
    //
    // ## 为什么这一条不能省（2026-10-07 真实现场）
    //
    // 用户追的《遮天》新入库了 `183 4K.mp4` 和 `EP184.mkv`。这两个文件名里
    // **没有季号**，于是 `WorkLevels` 把它们归进「未标季」那一格；而他上一轮
    // 点过「第 1 季」（那一格才是 `S01E174~183` 这些看得懂的集），`_seasonKey`
    // 就一直停在 `s:1`。列表确实从 11 行刷成了 13 行，可他眼前那 6 行里
    // 一行新的都没有 —— **界面上也没有任何东西告诉他新集在另一格里**。
    // 于是他合理地得出「说有 2 个更新，但文件列表里找不到」。
    //
    // 所以：当前格一条新的都没有、而作品里别处有时，就在选择器下面挂一条
    // 可点击的指路条。只在**这种情况下**画 —— 正常情况下详情页版式不变。
    ({String seasonKey, String? partKey, String label, int count})? newElsewhere;
    if (visibleNew == 0) {
      // 先看当前这一季的「部」：用户就站在这部剧上，横跳一格代价最小。
      for (final g in parts) {
        final n = newCountOf(g);
        if (n > 0) {
          newElsewhere =
              (seasonKey: seasonKey!, partKey: g.key, label: g.label, count: n);
          break;
        }
      }
      // 再退到季这一层（含「当前这一季里没有任何部、但新集在别的季」）。
      if (newElsewhere == null) {
        for (final g in levels.seasons) {
          if (g.key == seasonKey) continue;
          final n = newCountOf(g);
          if (n > 0) {
            newElsewhere =
                (seasonKey: g.key, partKey: null, label: g.label, count: n);
            break;
          }
        }
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 138,
                height: 207,
                child: PosterImage(work: work, borderRadius: 10),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: _InfoColumn(
                  work: work,
                  detail: detail,
                  primary: primary,
                  visibleCount: visible.length,
                  featureCount: features.length,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _NetdiskLocation(detail: detail),
          // 「已并入」提示条。只在真的归一过东西时才画 ——
          // 没归一过的详情页版式与这个功能上线前完全一致。
          if (detail.mergedSources.isNotEmpty) ...[
            const SizedBox(height: 14),
            _MergedSourcesBanner(detail: detail),
          ],
          const SizedBox(height: 22),
          // 季 / 部选择器。**只在数据里真的成层时才画** ——
          // 单集电影、单季剧的版式与改造前完全一致。
          if (levels.hasSeasonLevel) ...[
            _LevelRow(
              label: '季',
              groups: levels.seasons,
              selectedKey: seasonKey,
              newCountOf: newCountOf,
              onSelect: (k) => setState(() {
                _seasonKey = k;
                // 换了季就把部重置 —— 上一季的部键落在这一季里没有意义。
                _partKey = null;
              }),
            ),
            const SizedBox(height: 10),
          ],
          if (parts.length >= 2) ...[
            _LevelRow(
              label: '部',
              groups: parts,
              selectedKey: partKey,
              newCountOf: newCountOf,
              onSelect: (k) => setState(() => _partKey = k),
            ),
            const SizedBox(height: 10),
          ],
          // 「新集不在这里」的指路条。**只在真的会挡住用户时**画 ——
          // 判据见上面 `newElsewhere` 那一段。
          if (newElsewhere != null) ...[
            _NewItemsHint(
              label: newElsewhere.label,
              count: newElsewhere.count,
              onJump: () => setState(() {
                _seasonKey = newElsewhere!.seasonKey;
                _partKey = newElsewhere.partKey;
              }),
            ),
            const SizedBox(height: 10),
          ],
          if (features.isNotEmpty) ...[
            _SectionTitle(
              title: '文件',
              count: features.length,
              // 「点任意一行播放」只在多行时才有意义；排序开关同理 ——
              // 只有一个文件时没有任何可排的东西，画出来是纯噪音
              // （与 `WorkLevels`「少于 2 个选项不画」同一条口径）。
              //
              // ⚠️ 门槛用 `visible.length` 而不是 `features.length`：这一格
              // 可能只有 1 条正片但有好几条花絮，那时列表里仍然有多行，
              // 排序开关必须画得出来（它同时作用于下面那一节）。
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (visible.length > 1) ...[
                    const Text(
                      '点任意一行播放',
                      style: TextStyle(fontSize: 11, color: AppTheme.dim),
                    ),
                    const SizedBox(width: 12),
                  ],
                  if (visible.length > 1) const _ItemSortMenu(),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < shownFeatures.length; i++)
              MediaItemRow(
                item: shownFeatures[i],
                index: i,
                workTitle: work.title,
                isNew: isNewItem(shownFeatures[i]),
                // 历史最大位置（不是续播点，见 `WorkDetail.maxPositions`）。
                // 缺键 = 没播过，行底不画进度条。
                watched: detail.maxPositions[shownFeatures[i].id],
              ),
          ],
          if (extras.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle(
              title: '花絮 / 样片',
              count: extras.length,
              // 整格都是花絮（一条正片都没有）时，上面那一节压根不画 ——
              // 排序开关要落在这里，否则这一页有排序能力却没有任何入口。
              trailing: features.isEmpty && visible.length > 1
                  ? const _ItemSortMenu()
                  : null,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < shownExtras.length; i++)
              MediaItemRow(
                item: shownExtras[i],
                index: i,
                dim: true,
                workTitle: work.title,
                isNew: isNewItem(shownExtras[i]),
                watched: detail.maxPositions[shownExtras[i].id],
              ),
          ],
        ],
      ),
    );
  }

  /// 当前该高亮哪一季。
  ///
  /// 优先级：**用户手选的**（只要它还在这一份数据里）→ 续播那一集所在的季
  /// → 第一季。第二步是关键：打开详情页时高亮的层，与「点播放会播的那一集」
  /// 永远是同一格 —— 两者都看 `detail.primary`。
  String? _resolveSeason(WorkLevels levels) {
    if (levels.seasons.isEmpty) return null;
    final keys = levels.seasons.map((g) => g.key).toSet();
    final kept = _seasonKey;
    if (kept != null && keys.contains(kept)) return kept;
    return WorkLevels.keyOf(levels.seasons, widget.detail.primary) ??
        levels.seasons.first.key;
  }

  /// 当前该高亮哪一个部；这一季没有分部时返回 `null`（不画部行）。
  String? _resolvePart(List<WorkLevelGroup> parts) {
    if (parts.length < 2) return null;
    final keys = parts.map((g) => g.key).toSet();
    final kept = _partKey;
    if (kept != null && keys.contains(kept)) return kept;
    return WorkLevels.keyOf(parts, widget.detail.primary) ?? parts.first.key;
  }
}

/// 「文件」列表的排序开关。
///
/// ## 为什么详情页需要这个（而目录视图那个不够用）
///
/// 两个列表**排的是两种东西**，所以是两个互不相干的设置：
///
///   - 目录视图（`folder_browser.dart` 的 `_SortMenu`）排的是**网盘上的实时
///     目录条目** —— 子目录、视频、字幕、压缩包混在一起；
///   - 这一个排的是**已入库的媒体文件** —— 一部剧的 N 集，本来就排好了
///     「季 → 部 → 集」。
///
/// 合成一个控件、共用一份状态的话，用户在目录视图切成「名称」，回到详情页
/// 就会看到按文件名排的集 —— 而集号在文件名里未必是自然序（`第10集` 会排到
/// `第2集` 前面）。
///
/// ## 三个选项里为什么必须留着「剧集顺序」
///
/// 见 `ItemSortMode`：只给「时间正序 / 倒序」就等于把原有的剧集顺序弄丢了，
/// 看剧时最常用的动作会变成「每次进详情页先手动切一次」。
///
/// ## 为什么默认「修改时间倒序」
///
/// 这一页除了看剧，另一个高频用途是**核对刚传上去的东西入库没有**。
/// 与目录视图的默认值同口径（`FolderSortMode.modifiedTime`）。
///
/// ## 选择结果**落库**
///
/// 走 `settingsProvider`（`SettingKeys.itemSortMode`）而不是页面内 `setState`：
/// 它是用户对列表的长期偏好，不是「这一次停留的临时筛选」（对比 `_seasonKey`
/// 那个「现在在看哪一季」—— 那个换一部作品就该重置）。
class _ItemSortMenu extends ConsumerWidget {
  const _ItemSortMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(itemSortModeProvider);
    return PopupMenuButton<ItemSortMode>(
      tooltip: '文件排序方式',
      initialValue: mode,
      position: PopupMenuPosition.under,
      onSelected: (v) => unawaited(
        ref.read(settingsProvider.notifier).set(itemSortMode: v),
      ),
      itemBuilder: (context) => [
        for (final option in ItemSortMode.values)
          PopupMenuItem(
            value: option,
            height: 34,
            child: Row(
              children: [
                Icon(
                  option == mode
                      ? Icons.check_rounded
                      : Icons.check_box_outline_blank,
                  size: 14,
                  color: option == mode ? AppTheme.accent : Colors.transparent,
                ),
                const SizedBox(width: 8),
                Text(
                  option.label,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
                ),
              ],
            ),
          ),
      ],
      // TV 上 `PopupMenuButton` 靠遥控器也能进（页头与目录视图那两个排序按钮
      // 就是同一套），所以这里只把「当前是什么排序」写成看得见的字 ——
      // 一个光秃秃的 ⇅ 图标在电视上猜不出它排的是哪一维、现在排的是什么。
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            const Icon(
              Icons.swap_vert_rounded,
              size: 15,
              color: AppTheme.muted,
            ),
            const SizedBox(width: 5),
            Text(
              mode.label,
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「已并入《X》《Y》」提示条 + 拆开。
///
/// ## 为什么这条提示是必须的，而不是「锦上添花」
///
/// 自动归一是**用户没发起**的动作：他只是刮了一部片子，两个格子就变成了
/// 一个。没有这条提示的话，他唯一能观察到的现象是「我的电影少了一部」——
/// 而「少了一部」既可以解释成合并，也可以解释成扫描把数据删了，**没有任何
/// 办法分辨**。提示条同时给了两样东西：一句「发生了什么事」，和一个撤销。
///
/// ## 撤销走的是「清标记」而不是「恢复备份」
///
/// 折叠从来没有删过东西：源作品的行、它的海报、它下面的文件全都还在，
/// 只是 `merged_into` 指向了这里。所以撤销是一条 `UPDATE`，零风险。
/// 这也是整个归一设计选「打标记」而不选「改 groupKey + 删行」的全部理由。
class _MergedSourcesBanner extends ConsumerStatefulWidget {
  const _MergedSourcesBanner({required this.detail});

  final WorkDetail detail;

  @override
  ConsumerState<_MergedSourcesBanner> createState() =>
      _MergedSourcesBannerState();
}

class _MergedSourcesBannerState extends ConsumerState<_MergedSourcesBanner> {
  bool _busy = false;

  Future<void> _undo() async {
    if (_busy) return;
    setState(() => _busy = true);
    final keys = widget.detail.mergedSources.map((w) => w.key).toList();
    try {
      final n = await WorkMergeService(
        library: ref.read(mediaRepositoryProvider),
      ).undo(keys);
      if (!mounted) return;
      // 撤销改了「哪些行算作品」，列表 / 角标 / 详情页三处都要重取。
      // 漏掉任何一个，用户会看到「列表里回来了、角标还是旧数」。
      ref.invalidate(workListProvider);
      ref.invalidate(categoryCountsProvider);
      ref.invalidate(libraryStatsProvider);
      ref.invalidate(workDetailProvider(widget.detail.work.key));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(n == 0 ? '这些作品已经分开了。' : '已拆回 $n 部独立作品。'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.detail.mergedSources;
    final names = sources.map((w) => '《${w.title}》').join('、');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child:
                Icon(Icons.merge_type_rounded, size: 15, color: AppTheme.muted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已并入 $names',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '刮削到同一条目，所以合成了这一部。它们的文件都在下面'
                  '（共 ${widget.detail.mergedItemCount} 个）。',
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: AppTheme.dim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _busy ? null : _undo,
            child: Text(_busy ? '处理中…' : '拆开'),
          ),
        ],
      ),
    );
  }
}

/// 层级选择器的一行（`季` 或 `部`）。
///
/// ## 为什么是常驻 chip 行而不是下拉
///
/// 本项目的首要目标是 TV。chip 是**方向键可达的焦点目标**；下拉在遥控器上
/// 要先聚焦、再展开、再选，多两步 —— 而层级切换是看剧时的高频动作。
///
/// ## 为什么用 `InkWell` 而不是 `MenuItemButton`
///
/// 与筛选面板同一条理由（见 `library_filter_panel`）：`MenuItemButton` 带着
/// 菜单语义，点一下会连带关掉宿主；这里根本没有宿主可关，用普通 `InkWell`
/// 最不容易出意外。
class _LevelRow extends StatelessWidget {
  const _LevelRow({
    required this.label,
    required this.groups,
    required this.selectedKey,
    required this.newCountOf,
    required this.onSelect,
  });

  final String label;
  final List<WorkLevelGroup> groups;
  final String? selectedKey;

  /// 某一格里有几条「追剧后新增、还没播过」的条目。0 表示不画角标。
  ///
  /// 传函数而不是 `Map<String, int>`：键是 group 的 `key`，而这一层只关心
  /// 「这一格几条」，多一层映射就多一处可能与数据不同步的地方。
  final int Function(WorkLevelGroup) newCountOf;

  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 16,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.dim,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            // ⚠️ `primary: false` 必须给：嵌套的 `SingleChildScrollView`
            // 会去抢外层滚动视图的 controller，不给就抛
            // 「attached to multiple scroll views」（筛选面板踩过同一个坑）。
            primary: false,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final g in groups) ...[
                  _LevelChip(
                    group: g,
                    selected: g.key == selectedKey,
                    newCount: newCountOf(g),
                    onTap: () => onSelect(g.key),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.group,
    required this.selected,
    required this.newCount,
    required this.onTap,
  });

  final WorkLevelGroup group;
  final bool selected;

  /// 这一格里有几条新的。> 0 时在格子上挂一个「N 新」小胶囊。
  ///
  /// ## 为什么角标必须挂在**格子**上
  ///
  /// 新集落在哪一格，取决于文件名里有没有季号 —— 而同一个目录里的命名
  /// 常常混着来（`S01E174.mkv` 有、`183 4K.mp4` 没有）。用户手上没有任何
  /// 线索能猜到「新集在未标季那一格」，不挂角标他就只能一格一格点过去试。
  final int newCount;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.accent : AppTheme.muted;

    return TvFocusable(
      borderRadius: BorderRadius.circular(8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.16) : AppTheme.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? color.withValues(alpha: 0.5) : AppTheme.line,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  group.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? color : AppTheme.text,
                  ),
                ),
                if (newCount > 0) ...[
                  const SizedBox(width: 6),
                  // 用**品牌色**而不是跟着选中态走：它的意思是「这里有新东西」，
                  // 与「你正站在这一格」是两件事 —— 跟着选中态变色的话，用户
                  // 切走之后角标就变暗，反而更容易被漏掉。
                  _NewCountBadge(count: newCount),
                ],
                const SizedBox(width: 6),
                // 集数角标：一眼看出哪一季还没看。
                Text(
                  '${group.count}',
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        selected ? color.withValues(alpha: 0.8) : AppTheme.dim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 季 / 部格子上的「N 新」小胶囊。
class _NewCountBadge extends StatelessWidget {
  const _NewCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$count 新',
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          height: 1.3,
          color: AppTheme.accent,
        ),
      ),
    );
  }
}

/// 「新集在别的格里」的指路条。
///
/// ## 它解决什么问题
///
/// 用户被告知「有 2 集更新」之后，打开这一页看到的却是一屏没有 NEW 的旧集
/// （新集在「未标季」那一格，而他停在「第 1 季」）。**光在格子上挂角标不够** ——
/// 角标说的是「那一格里有新的」，而用户此刻的疑问是「我被告知的新集到底在哪」。
/// 这条把两件事连起来：直接说出格子的名字，并且点一下就过去。
///
/// ## 为什么是整条可点，而不是只点「查看」两个字
///
/// 与详情页其它可点区域同一条口径：TV 上没有 hover，一个小文字热区既难瞄准、
/// 也看不出可点。整条做成 `InkWell`，文字里再给一个明确的动词。
class _NewItemsHint extends StatelessWidget {
  const _NewItemsHint({
    required this.label,
    required this.count,
    required this.onJump,
  });

  /// 目标格的展示名（`未标季` / `第 2 季` / `第 3 部`…）。
  final String label;

  final int count;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      borderRadius: BorderRadius.circular(8),
      child: Material(
        color: AppTheme.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onJump,
          borderRadius: BorderRadius.circular(8),
          hoverColor: AppTheme.accent.withValues(alpha: 0.16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.accent.withValues(alpha: 0.35),
                width: 0.5,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.fiber_new_rounded,
                  size: 16,
                  color: AppTheme.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '有 $count 集更新在「$label」里',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.text,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '去看看',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.accent,
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: AppTheme.accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoColumn extends ConsumerWidget {
  const _InfoColumn({
    required this.work,
    required this.detail,
    required this.primary,
    required this.visibleCount,
    required this.featureCount,
  });

  final MediaWork work;
  final WorkDetail detail;

  /// 当前层级下「点播放会播的那一条」。
  ///
  /// **由 `_DetailBody` 按选中的季 / 部算好传进来** —— 在这里重算一遍就等于
  /// 把「层级筛选」的逻辑抄了第二份，两处一旦分叉，会出现「列表显示第三季、
  /// 播放按钮却播第一季」。
  final MediaItem? primary;

  /// 当前层级下的文件数（角标与「N 个文件」都用它）。
  final int visibleCount;

  /// 当前层级下的正片条数。> 1 时播放按钮说明是「第一个版本」。
  final int featureCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 提到局部变量：`primary` 是**字段**，而 Dart 不对字段做类型提升，
    // 直接写 `primary == null ? null : playItem(..., primary)` 编译不过。
    final p = primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          work.title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            height: 1.3,
            color: AppTheme.text,
          ),
        ),
        if (work.originalTitle != null &&
            work.originalTitle!.isNotEmpty &&
            work.originalTitle != work.title) ...[
          const SizedBox(height: 4),
          Text(
            work.originalTitle!,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.muted),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TagChip(label: work.kind.label, color: AppTheme.accent),
            if (work.year != null)
              TagChip(label: '${work.year}', color: AppTheme.muted),
            if (work.rating != null)
              TagChip(
                label: work.rating!.toStringAsFixed(1),
                icon: Icons.star_rounded,
                color: AppTheme.warn,
              ),
            TagChip(
              label: work.source.label,
              color: work.isScraped ? AppTheme.ok : AppTheme.dim,
              icon: work.isScraped
                  ? Icons.cloud_done_rounded
                  : Icons.description_outlined,
            ),
            // 类型标签只展示前 4 个（多了会把这一行撑到换行好几排），
            // 全量在「编辑类型」对话框里看。所以后面那个入口是必须的 ——
            // 否则第 5 个之后的类型用户在详情页根本看不到。
            for (final g in work.genres.take(4))
              TagChip(label: g, color: AppTheme.muted),
            _EditGenresChip(work: work),
          ],
        ),
        if (work.overview != null && work.overview!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            work.overview!,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              height: 1.75,
              color: AppTheme.muted,
            ),
          ),
        ],
        const SizedBox(height: 18),
        // 用 `Wrap` 而不是 `Row`：这一行现在有六个按钮（播放 / 追剧 / 刮削 /
        // 手动 / 自定义 / 合并到…），主窗口没有最小宽度限制，用户把窗口拖窄时
        // `Row` 会直接溢出报黄条。`Wrap` 在空间不够时把「N 个文件」挤到
        // 下一行，按钮一个都不会变形。
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: p == null ? null : () => playItem(context, ref, p),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 19),
              label: Text(
                primary == null
                    ? '没有可播文件'
                    : (featureCount > 1 ? '播放第一个版本' : '播放'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _FollowButton(work: work),
            _ScrapeButton(work: work),
            _ManualScrapeButton(work: work),
            _CustomizeButton(work: work),
            _MergeButton(work: work),
            Text(
              '$visibleCount 个文件',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
            ),
          ],
        ),
        // 按钮变灰却没有任何解释 —— 桌面上悬停一下就有 tooltip，电视上
        // 用户唯一的结论是「这个应用坏了」。所以 TV 上把原因写成看得见的一行。
        //
        // 只放**一条**：两个按钮（刮削 / 手动）是同一个原因，各挂一条会把
        // 同一句话并排印两遍。「自定义」不受这个门槛限制，不在此列。
        if (!(ref.watch(settingsProvider).valueOrNull?.canScrapeOnline ?? false))
          const TvNote(text: _noScrapeSourceReason),
        // 刮削结果。**只在属于这部作品时显示** —— 否则刮完 A 再打开 B，
        // B 的页面上还挂着 A 的「已刮削：…」。
        _ScrapeMessage(workKey: work.key),
      ],
    );
  }
}

/// 「编辑类型标签」入口 —— 加 / 删这部作品的 `genres`。
///
/// ## 为什么类型需要手动编辑
///
/// `genres` 是 TMDB / 豆瓣**返回什么就存什么**，经常不全或不对：国产综艺 /
/// 国漫在 TMDB 上常常压根没有条目；跨类型的片子（「动画 + 科幻 + 冒险」）
/// 源只给一两个；片名被发布组打散时更会命中一个完全不相干的条目。
///
/// 而它有两个实打实的下游：详情页这几个 chip，以及筛选面板「类型」那一组
/// 的选项与角标 —— 错了就是「按类型筛不到这部片」。
///
/// ## 为什么是一个常驻 chip 而不是菜单项
///
/// 类型标签在详情页是**看得见**的东西，改它的入口就该在它旁边。藏进
/// 「更多」菜单里的话，用户看到标签写错了也找不到地方改 —— 只会以为
/// 这个应用不能改类型。
///
/// ## 已手动编辑过时会点亮
///
/// `genresManual == true` 时用强调色，让用户知道「这一列现在被锁住了，
/// 重新刮削不会再覆盖它」—— 否则他下次刮削发现类型没变，会以为刮削坏了。
class _EditGenresChip extends ConsumerWidget {
  const _EditGenresChip({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manual = work.genresManual;
    final color = manual ? AppTheme.accent : AppTheme.muted;

    return Tooltip(
      message: manual
          ? '类型标签已被你手动锁定，重新刮削不会覆盖。点一下继续编辑'
          : '加 / 删这部作品的类型标签',
      child: InkWell(
        onTap: () => GenreEditDialog.show(context, work),
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
          decoration: BoxDecoration(
            color: manual ? color.withValues(alpha: 0.14) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: manual ? color.withValues(alpha: 0.35) : AppTheme.line,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_outlined, size: 10, color: color),
              const SizedBox(width: 3),
              Text(
                work.genres.isEmpty ? '添加类型' : '编辑类型',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「追剧 / 已追剧」。
///
/// ## 它解决什么问题
///
/// 在播的剧每周多一集。全盘重扫能发现，代价是遍历几千个目录、几分钟 ——
/// 而用户心里这只是「看看更新了没有」。追剧把这部剧的网盘目录**记下来**，
/// 之后只列那几个目录，秒级完成（见 `FollowService`）。
///
/// ## 为什么它紧挨着「播放」
///
/// 这一行按钮是按用户会按的顺序排的：先播放，再决定要不要长期跟这部。
/// 而且它与 Android 电视端那颗胶囊**同序**（那边也放在播放之后、刮削之前，
/// 见 `WorkDetailFormat.actionLabels`）—— 「同一个功能在哪儿」这件事本身
/// 就是两端一致性的一部分，换设备时不该重新找一遍。
///
/// ## 已追剧时点亮
///
/// 与 `_EditGenresChip` 同一条理由：这是**一个被打开的状态**，不是一次性
/// 动作。不点亮的话用户看不出「我现在到底追没追」，只能靠再点一次来试 ——
/// 而再点一次恰好是取消，于是他会在两个状态之间来回撞。
///
/// ⛔ 写入走 `FollowController.toggleFollow` 而**不是**直接调仓储：那个方法
///    负责写完之后的四处刷新（列表 / 角标 / 页头统计 / **本页**）。
///    漏掉本页的表现是「点了按钮毫无反应」，而这类 bug 不报错。
class _FollowButton extends ConsumerWidget {
  const _FollowButton({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followed = work.followed;
    final news = work.newItemCount;
    final color = followed ? AppTheme.accent : AppTheme.muted;

    // 文案与 Android 端 `WorkDetailFormat.followLabel` 逐字同口径
    // （那边是「☆ 追剧 / ★ 已追剧 / ★ 已追剧 · N 新」，符号由图标承担）。
    final label = !followed
        ? '追剧'
        : (news > 0 ? '已追剧 · $news 集新' : '已追剧');

    return Tooltip(
      message: followed
          ? (news > 0
              ? '这部剧有 $news 条新文件还没看。点一下取消追剧'
              : '正在追这部剧：网盘里出现新文件时会自动同步并提醒。点一下取消')
          : '开启追剧：之后这部剧在网盘里出现新文件时，'
              '会自动同步进媒体库，并在媒体库页提醒你',
      child: OutlinedButton.icon(
        onPressed: () => ref
            .read(followControllerProvider.notifier)
            .toggleFollow(work.key, !followed),
        style: OutlinedButton.styleFrom(
          // 点亮用**实心面**而不是加粗描边：深色 UI 上「亮起来」靠的是
          // 面本身的明度（与电视端那颗胶囊同一条口径，用户两次点名
          // 「线框不高级」）。所以这里是半透明底 + 同色描边，不是纯描边。
          foregroundColor: color,
          backgroundColor: followed ? color.withValues(alpha: 0.14) : null,
          side: followed ? BorderSide(color: color.withValues(alpha: 0.5)) : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: Icon(
          followed
              ? Icons.notifications_active_rounded
              : Icons.notifications_none_rounded,
          size: 16,
        ),
        label: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 「刮削这一部」。
///
/// ## 为什么刮削要放在详情页，而不是跟着扫描跑
///
/// 豆瓣的匿名额度实测只有约 **10 个搜索词**，一次全盘扫描（上百部作品）
/// 必然中途耗尽，而耗尽之后是 `103 need_login` —— 用户看到的是「豆瓣一条
/// 都刮不到」，这个 IP 短时间内也不能用了。所以刮削改成**按需**：一次点击
/// 最多花 2 个搜索词，用户自己决定刮哪几部。
///
/// 想恢复自动刮削就在设置里打开「扫描后自动刮削」（默认关）。
///
/// ## 交互上的两个决定
///
///   - **没有源时按钮是灰的，且 tooltip 说清去哪开**。直接藏起来的话，
///     用户不会知道有这个功能，只会问「为什么别人的有海报」。
///   - **不用弹窗报结果**，只在按钮下面写一行。刮削是可以在墙上连点的小动作，
///     每次都弹一个「确定」会把「顺手补个海报」变成一件麻烦事。
class _ScrapeButton extends ConsumerWidget {
  const _ScrapeButton({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final state = ref.watch(workScrapeControllerProvider);
    final canScrape = settings?.canScrapeOnline ?? false;
    final running = state.isRunning(work.key);

    return Tooltip(
      message: canScrape
          ? '用在线源（TMDB / 豆瓣）重新查一次海报与简介'
          : _noScrapeSourceReason,
      child: OutlinedButton.icon(
        onPressed: (!canScrape || running)
            ? null
            : () => ref
                .read(workScrapeControllerProvider.notifier)
                .scrape(work.key),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: running
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_awesome_outlined, size: 16),
        label: Text(
          running ? '刮削中…' : '刮削',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 「手动指定片名」。
///
/// ## 为什么它必须和「刮削」并排出现
///
/// 自动刮削失败时用户看到的那句话里写死了「点旁边的『手动』自己敲片名再搜」
/// （`WorkScrapeOutcome.message` 的 auto 分支）—— 说的就是这个按钮。片名被
/// 发布组打散（`超z级z马z力z欧z银z河z大z电影aa`）或者只剩
/// `2026.2160p.WEB-DL.mkv` 时，任何自动算法都救不回来，唯一可行的动作就是
/// **人自己敲一个词**。
///
/// ⚠️ 这两处**必须一起改**：文案里写死了「旁边」，把这个按钮藏进菜单就等于
/// 让文案撒谎 —— 用户会去找一个看不见的东西。反过来，把这句引导从文案里
/// 删掉，这个按钮就变成「用户根本不知道它存在」。
class _ManualScrapeButton extends ConsumerWidget {
  const _ManualScrapeButton({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final state = ref.watch(workScrapeControllerProvider);
    final canScrape = settings?.canScrapeOnline ?? false;
    // 与自动刮削共用 runningKey —— 两个入口不能同时跑。
    final running = state.isRunning(work.key);

    return Tooltip(
      message: canScrape
          ? '自动刮削认不出片名时（文件名被插字符、或只剩分辨率信息），'
              '自己敲片名从候选里挑一条'
          : _noScrapeSourceReason,
      child: OutlinedButton.icon(
        onPressed: (!canScrape || running)
            ? null
            : () => ManualScrapeDialog.show(context, work),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: const Icon(Icons.manage_search_rounded, size: 16),
        label: const Text(
          '手动',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 「自定义」：清除在线刮削信息，自己写死片名与分类。
///
/// ## 为什么它和「刮削」「手动」并排
///
/// 前两个按钮是「**去网上找**」，这个按钮是「**网上找不到，我自己写**」。
/// 三者是同一个问题的三条出路，所以放在一起。自动那条失败时的文案
/// （`WorkScrapeOutcome.message` 的 auto 分支）也会把用户引到这里来 ——
/// 那句里写死了「点「自定义」直接写死片名和分类」，说的就是这个按钮。
///
/// ⚠️ 与「手动」那条一样，**文案与位置是绑定的**：把这个按钮挪进菜单，
/// 就得同步改 `WorkScrapeOutcome` 里的引导语，否则用户会去找一个看不见的
/// 东西。
///
/// ## 为什么它**没有** `canScrapeOnline` 门槛
///
/// 它一次网络请求都不发，是纯本地的数据修正。跟着那两个按钮一起变灰的话，
/// **没配 TMDB / 豆瓣的用户就永远用不了它** —— 而他们恰恰最需要：没有在线
/// 源时作品全靠文件名解析，片名常常就是 `2024.2160p.WEB-DL`。
class _CustomizeButton extends ConsumerWidget {
  const _CustomizeButton({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workScrapeControllerProvider);
    // 与两个刮削入口共用 runningKey —— 三个入口不能同时跑。
    final running = state.isRunning(work.key);

    return Tooltip(
      message: '自动刮削刮错了、而数据源里根本没有这部片子（自制 / 演唱会 / '
          '赛事…）时：清掉刮来的海报、简介、评分，自己敲片名和分类。'
          '保存后标记为「手动修改」，重扫与自动刮削都不会再覆盖它。',
      child: OutlinedButton.icon(
        onPressed:
            running ? null : () => CustomizeWorkDialog.show(context, work),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: const Icon(Icons.edit_outlined, size: 16),
        label: const Text(
          '自定义',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 「合并到…」：把这一部并到库里另一部作品上（手动归一）。
///
/// ## 为什么需要它，而自动归还不够
///
/// 自动那条路（`WorkMergeService.mergeAll`）**只认 `onlineId`** —— 这个克制
/// 是对的（按片名模糊匹配正是 `182.格力空调` 那次事故的形态），但代价是三种
/// 情况它永远处理不了：本地片名差异大（`流浪地球2` vs `The Wandering Earth II`）、
/// 压根没刮到（两行都没有 `onlineId`）、刮到两个不同条目但其实是同一部。
/// 这些只有人能判，所以这个按钮是「归一」那半不可缺的另一半。
///
/// ## 为什么它**没有** `canScrapeOnline` 门槛
///
/// 与「自定义」同一条理由：它一次网络请求都不发，是纯本地的数据修正。
/// 跟着「刮削」「手动」一起变灰的话，**没配 TMDB / 豆瓣的用户就永远用不了
/// 它** —— 而他们恰恰最需要（没有在线源时全靠文件名解析，最容易出现同一部
/// 片子被拆成两个格子）。
///
/// ## 合并完为什么会跳页
///
/// 合并后当前行变成别名行，而 `workDetailProvider` 会跟着 `mergedInto`
/// 走到目标作品（那是给「后台归一把我正看着的这部折走了」准备的路径，
/// 手动合并走的是同一条）。所以用户点完会落在**他选中的那一部**上 ——
/// 那正是他要的结果，而且目标页上就挂着「已并入《X》／拆开」。
class _MergeButton extends ConsumerWidget {
  const _MergeButton({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workScrapeControllerProvider);
    // 与「自定义」共用 runningKey：三个入口都在写同一行作品数据，
    // 同时跑会让「刮削写元数据」和「合并写 mergedInto」互相踩。
    final running = state.isRunning(work.key);

    return Tooltip(
      message: '同一部片子被扫成了两个格子（不同目录、片名不一样、或没刮到）时：'
          '把它并到库里另一部作品上，列表里只留一部。'
          '不会删文件，目标作品页上随时能「拆开」。',
      child: OutlinedButton.icon(
        onPressed: running ? null : () => _open(context, ref),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: const Icon(Icons.merge_type_rounded, size: 16),
        label: const Text(
          '合并到…',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final result = await MergeWorkDialog.show(context, work);
    if (result == null || !context.mounted) return;

    // 归一改的是「哪些行算作品」—— 列表、角标、详情页三处都要重取。
    // 漏掉任何一个，用户会看到「列表里少了一格、角标还是旧数」。
    _refresh(ref);

    // 提示里带一个**撤销**。目标页上那条常驻提示条才是主入口，这条 SnackBar
    // 只是即时反馈：用户刚点完那一下，眼前必须有东西确认「发生了什么」。
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await WorkMergeService(
              library: ref.read(mediaRepositoryProvider),
            ).undo([work.key]);
            _refresh(ref);
          },
        ),
      ),
    );
  }

  /// 三处一起失效 —— 它们从三个角度描述同一份数据（行 / 角标 / 详情）。
  void _refresh(WidgetRef ref) {
    ref.invalidate(workListProvider);
    ref.invalidate(categoryCountsProvider);
    ref.invalidate(libraryStatsProvider);
    ref.invalidate(workDetailProvider(work.key));
  }
}

/// 刮削结果那一行。
class _ScrapeMessage extends ConsumerWidget {
  const _ScrapeMessage({required this.workKey});

  final String workKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workScrapeControllerProvider);
    final message = state.messageFor(workKey);
    if (message == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            state.okFor(workKey)
                ? Icons.check_circle_outline_rounded
                : Icons.info_outline_rounded,
            size: 14,
            color: state.okFor(workKey) ? AppTheme.ok : AppTheme.warn,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.7,
                color: state.okFor(workKey) ? AppTheme.muted : AppTheme.warn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「网盘位置」。
///
/// ## 为什么这个信息必须出现在详情页
///
/// 媒体库里的标题是**解析出来的**（`流浪地球2`），而网盘上真实的名字可能是
/// `[高清影视之家发布] 流浪地球2.2023.2160p...mkv`。用户要做的很多事情都
/// 得回到网盘：核对是不是同一部、分享给朋友、在夸克 App 里重命名、
/// 或者干脆手动把文件挪个目录。
///
/// 没有这一块的话，用户只能靠猜 —— 而「猜路径」这件事在几千个目录里
/// 基本等于做不到。
///
/// ## 复制的是**路径文本**，不是链接
///
/// 夸克确实有网页版目录链接，但它的格式没有公开文档、随版本变化，而且
/// 拿到链接还得先登录才打得开。**路径文本**则是确定的：它能直接粘进
/// 夸克客户端的搜索框，也能用来人工核对。宁给一个确定能用的，不给一个
/// 看起来更"高级"但会失效的。
class _NetdiskLocation extends StatelessWidget {
  const _NetdiskLocation({required this.detail});

  final WorkDetail detail;

  @override
  Widget build(BuildContext context) {
    final items = detail.items;
    if (items.isEmpty) return const SizedBox.shrink();

    final dirs = items.map((i) => i.dirPath).toSet();
    final singleDir = dirs.length == 1;

    // 多目录时不展示「一个路径」：那时列出来的任何一条都只是**其中一部分**
    // 文件的位置，而用户会以为那是整部剧的位置。改成说明 + 让他按行复制。
    final value = singleDir ? dirs.first : '分布在 ${dirs.length} 个目录';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 12),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.folder_outlined,
                size: 14,
                color: AppTheme.muted,
              ),
              const SizedBox(width: 7),
              const Text(
                '网盘位置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'Menlo',
                    color: AppTheme.text,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              CopyTextButton(
                // 多目录时复制**全部**目录（每行一个），而不是"第一个"——
                // 复制一个不完整的结果比不给复制更糟。
                text: dirs.join('\n'),
                label: singleDir ? '复制路径' : '复制全部目录',
                tvLabel: singleDir ? '复制路径' : '复制全部',
                icon: Icons.folder_copy_outlined,
              ),
            ],
          ),
          const SizedBox(height: 7),
          // 文件 ID 是网盘侧的**稳定主键**。放在这里而不是藏进调试页：
          // 用户报「这部剧扫不出来」时，有这个 ID 就能直接在网盘里定位。
          // 用等宽字体 + 小字号压低视觉权重，它属于"需要时才找得到"的信息。
          Row(
            children: [
              const SizedBox(width: 21),
              Expanded(
                child: Text(
                  items.length == 1
                      ? '文件 ID ${items.first.fileId}'
                      : '文件 ID ${items.first.fileId} …（共 ${items.length} 个）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'Menlo',
                    color: AppTheme.dim,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              CopyTextButton(
                text: items.length == 1
                    ? items.first.fileId
                    : items.map((i) => i.fileId).join('\n'),
                label: '复制 ID',
                tvLabel: '复制 ID',
                icon: Icons.tag_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {  const _SectionTitle({required this.title, required this.count, this.trailing});

  final String title;
  final int count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}
