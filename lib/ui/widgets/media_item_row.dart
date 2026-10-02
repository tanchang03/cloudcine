import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_item.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'copy_button.dart';
import 'play_action.dart';

/// 一行媒体文件。
///
/// 作品详情页的「文件」列表与媒体库的目录视图共用它。两处各写一份的话，
/// 「显示什么、点一下发生什么」很快会漂移 —— 而这两处是用户找片子的
/// 两条主要路径，行为不一致会让人以为功能时好时坏。
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
  });

  final MediaItem item;

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

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: () => playItem(context, ref, item),
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                      Text(
                        item.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: dim ? AppTheme.muted : AppTheme.text,
                        ),
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
        ),
      ),
    );
  }
}
