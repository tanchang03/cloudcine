import 'package:flutter/material.dart';

import '../../domain/entities/media_work.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';
import 'poster_image.dart';
import 'tv_focus.dart';

/// 一条候选**目标作品**（「合并到…」对话框里可点的那一行）。
///
/// 单独成一个文件是因为有**两个**对话框要用它：单部的
/// `MergeWorkDialog` 与批量的 `BatchMergeDialog`。两处各写一份的话，
/// 「批量那条路看到的封面 / 来源标记跟单部那条路不一样」只是时间问题 —— 而
/// 用户判断「是不是这一部」几乎全靠这两样。
///
/// ## 三种信息按权重排：缩略图 > 片名 > 副标题
///
/// 副标题里带上「N 个文件」与来源（文件名解析 / 在线刮削 / 手动修改）——
/// 来源这一项在这里特别要紧：把一个**手动改过**的作品并走，意味着用户
/// 手敲的片名与分类从此不再显示，值得让他看见。
class MergeTargetRow extends StatelessWidget {
  const MergeTargetRow({
    super.key,
    required this.work,
    required this.selected,
    required this.blockedReason,
    required this.onTap,
    this.badge,
  });

  final MediaWork work;

  final bool selected;

  /// 非 `null` = 这一条不能当目标（原因直接显示在行上）。
  final String? blockedReason;

  final VoidCallback? onTap;

  /// 可选的小角标（批量合并里标出「这一部在勾选的那一批里」）。
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final blocked = blockedReason != null;

    return TvFocusable(
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accent.withValues(alpha: 0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? AppTheme.accent : AppTheme.line,
              width: selected ? 1 : 0.5,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 与海报墙同一个缓存、同一套裁切规则 —— 候选里看到的封面
              // 就是合并后列表里会显示的那一张。
              Opacity(
                opacity: blocked ? 0.4 : 1,
                child: SizedBox(
                  width: 46,
                  height: 69,
                  child: PosterImage(work: work, borderRadius: 5),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            work.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.text,
                            ),
                          ),
                        ),
                        if (badge != null) ...[
                          const SizedBox(width: 6),
                          TagChip(label: badge!, color: AppTheme.accent),
                        ],
                        if (selected)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.check_circle_rounded,
                              size: 15,
                              color: AppTheme.accent,
                            ),
                          ),
                      ],
                    ),
                    if (work.originalTitle != null &&
                        work.originalTitle!.isNotEmpty &&
                        work.originalTitle != work.title) ...[
                      const SizedBox(height: 2),
                      Text(
                        work.originalTitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TagChip(label: work.kind.label, color: AppTheme.accent),
                        if (work.year != null)
                          TagChip(
                            label: '${work.year}',
                            color: AppTheme.muted,
                          ),
                        TagChip(
                          label: work.itemCount > 0
                              ? '${work.itemCount} 个文件'
                              : '未扫到文件',
                          color: AppTheme.muted,
                        ),
                        TagChip(
                          label: work.source.label,
                          color: work.isScraped ? AppTheme.ok : AppTheme.dim,
                        ),
                      ],
                    ),
                    if (blocked) ...[
                      const SizedBox(height: 5),
                      Text(
                        blockedReason!,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.6,
                          color: AppTheme.warn,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
