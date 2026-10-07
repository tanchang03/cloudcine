import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_item.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'copy_button.dart';
import 'modified_time_column.dart';
import 'play_action.dart';

/// 这一条文件「看过多少」（0..1）。**不该画进度条时返回 `null`**。
///
/// ## 为什么是 `null` 而不是 `0`
///
/// 两种「画不出来」的情况：
///   - [watched] 为空（从没播过）；
///   - 时长未知（`item.durationMs` 为空 —— 夸克没给 `duration`）。
///
/// 后一种返回 `0` 的话，一条**确实看过**的记录会画成 0% 的空槽 —— 用户看到
/// 的是「白看了」，而这与「没看过」在屏幕上完全一样。返回 `null` 让调用方
/// **什么都不画**，至少不撒谎。
///
/// ## 用的是历史最大位置，不是续播点
///
/// [watched] 传 `WorkDetail.maxPositions` 里的值（只增不减、永不清除），
/// **不是** `resumePositionMs`（看完会被清成 NULL）—— 否则用户刚看完一集
/// 回来，那一行会显示 0%，恰好是他最想看到 100% 的时刻。
///
/// 不做「接近结尾就吸附成 100%」的处理：那会让一个只看了 92% 的条目
/// 谎报成看完。真的播完时上报的位置本来就贴着时长，`clamp` 兜住越界即可。
double? itemProgressOf(MediaItem item, Duration? watched) {
  if (watched == null || watched <= Duration.zero) return null;
  final totalMs = item.durationMs;
  if (totalMs == null || totalMs <= 0) return null;
  return (watched.inMilliseconds / totalMs).clamp(0.0, 1.0);
}

/// 一行媒体文件。
///
/// 目前只有作品详情页的「文件」列表用它。媒体库的**目录视图刻意不共用**
/// （那里描述的是「网盘上的这个文件」，不是「已入库的媒体项」，见
/// `folder_browser.dart` 里那一段）—— 所以这一行总是有作品上下文，
/// [workTitle] 传得进来。
///
/// **点整行 = 直接起播**，与海报墙点卡片一致（走 `playItem`，全应用唯一的
/// 起播入口）。行内不再放「播放」按钮，只留一个静态的播放图标作提示。
class MediaItemRow extends ConsumerWidget {
  const MediaItemRow({
    super.key,
    required this.item,
    this.index,
    this.showPath = true,
    this.dim = false,
    this.onLocate,
    this.locateTooltip = '在目录中显示',
    this.workTitle,
    this.watched,
    this.isNew = false,
  });

  final MediaItem item;

  /// 这一条**看过的最远位置**（见 [itemProgressOf]）。`null` = 没播过。
  ///
  /// 由调用方从 `WorkDetail.maxPositions` 取好传进来 —— 这一行不自己去查库：
  /// 列表一屏几十行，每行各查一次会把「一次批量查询」变成 N 次。
  final Duration? watched;

  /// 这一条算不算「追剧之后才出现、而且还没看过」的新集。
  ///
  /// 判据由调用方用 `MediaWork.isNewSinceFollow(firstSeenAt:, played:)`
  /// 算好传进来 —— 与 [watched] 同一条理由（这一行不持有作品、也不查库），
  /// 而且「播过没有」这件事**恰好就是** [watched] 非空。
  ///
  /// ⛔ 别在这一行里自己算：`followStartedAt` 在作品上，不在这里。传进来
  ///    一个 `bool` 而不是 `DateTime? followStartedAt`，是为了让「哪几行是
  ///    新的」这个判断**只在一处**（详情页 `_DetailBody.build`）——
  ///    两个地方各判一遍，迟早会分叉成「列表标了 NEW、进度条却显示看过」。
  final bool isNew;

  /// 所属**作品行**的标题（刮削后的剧名），只用于主标题的组装。
  ///
  /// 提不出集号的那些条目主标题是 `剧名-文件名`（见 [MediaItem.listLabel]），
  /// 这个字段就是那个「剧名」。不传时退回条目自己解析出的片名。
  final String? workTitle;

  /// 行号。给 `null` 时不显示 —— 目录视图里「这一层的第几个」没有意义，
  /// 而详情页里「第几集」有意义。
  final int? index;

  /// 是否显示网盘上的真实位置。见下面 `netdiskPath` 那一段的说明。
  final bool showPath;

  /// 花絮行整体降一级视觉权重。
  final bool dim;

  /// 提供时在右侧多一个「定位所在目录」按钮。目录视图的搜索结果用它。
  final VoidCallback? onLocate;

  final String locateTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolution = item.resolution;
    final progress = itemProgressOf(item, watched);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: () => playItem(context, ref, item),
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    if (index != null)
                      SizedBox(
                        width: 34,
                        child: Text(
                          '${index! + 1}'.padLeft(2, '0'),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontFamily: 'Menlo',
                            color: dim ? AppTheme.dim : AppTheme.muted,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // NEW 标签与主标题**同一条基线**，所以放在同一个
                          // `Row` 里而不是上面另起一行：另起一行会让这一条
                          // 比没标 NEW 的行高出一截，一屏几十行参差不齐
                          // （与 `_WatchedBar` 压底边是同一条理由）。
                          Row(
                            children: [
                              if (isNew) ...[
                                const _NewTag(),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                child: Text(
                                  // ⚠️ **不能**用 `item.displayTitle` 一把梭：提不出集号时
                                  // 它就是片名，而这一整屏都是同一部剧。真实样本
                                  // `/来自：分享/F飞CC日  志2/` 下 12 个 `01.国语.mp4`…
                                  // 全被顶成同一个目录名，12 行主标题一模一样，只有下面
                                  // 那条暗色的网盘路径能看出区别。
                                  //
                                  // 取 `withTitle` 而不是 `compact`：有集号时**要**保留
                                  // 片名 —— 同一集常有多个版本（翡翠台 / MyTVSuper），
                                  // 版本之间只有片名不同（见 `RowLabelStyle`）。
                                  item.rowLabel(
                                    RowLabelStyle.withTitle,
                                    workTitle: workTitle,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                    color: dim ? AppTheme.muted : AppTheme.text,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.technicalSummary.isEmpty
                                ? item.name
                                : item.technicalSummary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppTheme.dim,
                            ),
                          ),
                          if (showPath) ...[
                            const SizedBox(height: 3),
                            // 网盘上的真实位置。**必须显示出来**，不能只藏在
                            // 复制按钮后面 —— 用户来这里的一大半目的是核对
                            // 「这一集在网盘上到底是哪个文件」，而上面那行是
                            // **解析出来的片名**，和真实文件名可能差很远。
                            Text(
                              item.netdiskPath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'Menlo',
                                color: AppTheme.dim,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (resolution != null) ...[
                      const SizedBox(width: 10),
                      TagChip(
                        label: resolution.marketingLabel,
                        color: AppTheme.resolutionColor(resolution),
                      ),
                    ],
                    // 网盘上的**修改时间**。单列 + 右对齐，与目录视图同一个
                    // widget（`ModifiedTimeColumn`）—— 时间戳对齐在同一条竖线上，
                    // 竖着扫一眼就能看出「哪几集是刚传上去的」。
                    //
                    // 为什么它值得占一列：这一页的排序默认就是「修改时间倒序」，
                    // 用户切到时间序之后，**必须能看见每一行的时间**才能核对
                    // 排得对不对 —— 只让列表换顺序、却不显示依据，等于让他
                    // 盲猜。`null`（网盘没给）显示 `—`，不参与排序（垫底）。
                    const SizedBox(width: 10),
                    ModifiedTimeColumn(modifiedAt: item.modifiedAt),
                    if (onLocate != null) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: locateTooltip,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: onLocate,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 4,
                              ),
                              child: Icon(
                                Icons.my_location_rounded,
                                size: 14,
                                color: AppTheme.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    // 每一行都能单独复制**这一条**的完整网盘路径。
                    // 作品级那一块给的是目录，而用户真正要发给别人的往往是
                    // 某个具体文件的位置。
                    CopyTextButton(
                      text: item.netdiskPath,
                      label: '复制这个文件的网盘路径',
                      tvLabel: '复制路径',
                      icon: Icons.content_copy_rounded,
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 19,
                      color: AppTheme.muted,
                    ),
                  ],
                ),
              ),
              // 「看过多少」压在这一行的**底边**上（见 [_WatchedBar]）。
              if (progress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _WatchedBar(fraction: progress),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 剧集行行首那个「■ NEW」。
///
/// ## 为什么是一个小方块 + 品牌色字，而不是一个实心胶囊
///
/// 与 Android 电视端的口径**逐字一致**（那边是 `SpannableString` 加一个
/// `■` 前缀 + `BRAND_TINT` 粗体，见 `LibraryActivity.newEpisodeTitle`）。
/// 两端同一件事长得不一样的话，用户换设备之后得重新学一遍「哪个标记是新的」。
///
/// 而它之所以不做成 `TagChip` 那样的实心块：这一行的右侧已经挤了分辨率
/// 胶囊、时间列、复制、播放四个东西，行首再来一块实心色，整行会变得
/// 「到处都在喊」。一个小方块 + 三个字母，是「一眼扫得到、又不抢主标题」的
/// 那个量级。
///
/// ## 为什么不带数字
///
/// 数字在**作品**这一层（海报角标「更新 2」、详情页按钮「已追剧 · 2 集新」）。
/// 行级只要回答「这一条是不是新的」—— 在每一行上重复一个同一个数字，
/// 既没有信息量，又会让 24 集里 24 行都写着「2」。
class _NewTag extends StatelessWidget {
  const _NewTag();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 方块与文字同色，缩到 5px —— 再大就会把 12.5sp 的主标题压下去。
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: AppTheme.accent,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 4),
        const Text(
          'NEW',
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            // 行高压到 1.2：这一行的高度由主标题（12.5sp）决定，
            // 标签不能反过来把它撑高。
            height: 1.2,
            letterSpacing: 0.6,
            color: AppTheme.accent,
          ),
        ),
      ],
    );
  }
}

/// 行底那条「看过多少」的细进度条。
///
/// ## 为什么压底边，而不是塞进文字列
///
/// 塞进文字列（像播放窗口剧集面板那样）会让**看过的行比没看过的行高几像素** ——
/// 一屏几十行就会参差不齐，右侧的时间列也跟着上下跳。压底边则完全不参与布局：
/// 有没有进度，行高都一模一样。
class _WatchedBar extends StatelessWidget {
  const _WatchedBar({required this.fraction});

  /// 0..1（见 [itemProgressOf]）。
  final double fraction;

  /// 条子高度。3px 与播放窗口剧集面板里那条一致，两处看到的是同一个东西。
  static const double height = 3;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      // 跟着面板自己的圆角走，否则满格时两个下角会露出方角。
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(9),
        bottomRight: Radius.circular(9),
      ),
      child: LinearProgressIndicator(
        value: fraction,
        minHeight: height,
        // 槽用比面板深一档的颜色，**不是透明**：只看了一两分钟时进度条本身
        // 只有几个像素宽，没有槽的话那一行看起来像什么都没有。
        backgroundColor: AppTheme.panel2,
        valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.accent),
      ),
    );
  }
}
