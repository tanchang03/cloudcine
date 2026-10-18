import 'package:flutter/material.dart';

import '../../domain/services/library_batch_delete.dart';
import '../theme/app_theme.dart';

/// 「要从媒体库移除这 N 部吗」—— 媒体库批量移除的**唯一**一道确认。
///
/// ## 为什么必须写清楚「网盘文件还在」
///
/// 用户对「移除 / 删除」的默认预期是「东西没了」，而这个按钮实际删的是
/// **本地索引行**（重新扫描就能找回）。好消息要说，但不能只说好消息 ——
/// 续播进度、播放偏好、学到的片头片尾会跟着索引一起走，那才是用户真正
/// 会怀念的东西。两句话都在正文里，缺一句都会让用户在按下去之后才发现。
///
/// ## ⚠️ 它删的不是网盘文件
///
/// 删网盘文件那条路在目录视图（`DriveDeleteDialog`），两边**刻意不是同一个
/// 弹窗：这里的确认色仍然是危险色（移除不可撤销），但正文第一句必须把
/// 「文件保留」讲在最前面，否则用户会以为自己刚删掉了一季的片子。
class LibraryBatchDeleteDialog extends StatelessWidget {
  const LibraryBatchDeleteDialog({super.key, required this.plan});

  final LibraryBatchDeletePlan plan;

  /// 最多摊开几个作品名。再多就折进「…等共 N 部」—— 一个能滚动的长列表
  /// 会把确认按钮顶出屏幕，而那正是要用户看清的东西。
  static const int previewLimit = 8;

  /// 弹出确认框。返回 `true` 表示用户确认移除；`null` / `false` 都是不移。
  static Future<bool?> show(
    BuildContext context,
    LibraryBatchDeletePlan plan,
  ) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LibraryBatchDeleteDialog(plan: plan),
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = plan.works.take(previewLimit).toList();
    final rest = plan.count - names.length;
    final mergedWarning = plan.mergedWarning;

    return AlertDialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.line),
      ),
      title: Row(
        children: [
          const Icon(Icons.playlist_remove_rounded,
              size: 20, color: AppTheme.danger),
          const SizedBox(width: 8),
          Text(plan.title, style: const TextStyle(fontSize: 15)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ① 「文件还在」放最前：它是用户按下这个按钮时最需要知道的
            //    一件事，也是这个按钮与「删除网盘文件」的全部区别。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: AppTheme.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.accent.withValues(alpha: 0.35),
                  width: 0.6,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.cloud_done_outlined,
                      size: 13, color: AppTheme.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      plan.keepFilesWarning,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: AppTheme.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              plan.localDataWarning,
              style: const TextStyle(
                fontSize: 12,
                height: 1.6,
                color: AppTheme.muted,
              ),
            ),
            if (mergedWarning != null) ...[
              const SizedBox(height: 6),
              Text(
                mergedWarning,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: AppTheme.warn,
                ),
              ),
            ],
            const SizedBox(height: 12),
            // ② 摊开要移除的名字。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: AppTheme.panel2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final w in names)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Row(
                        children: [
                          const Icon(Icons.movie_rounded,
                              size: 13, color: AppTheme.dim),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              w.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.text,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (rest > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '…等共 ${plan.count} 部',
                        style:
                            const TextStyle(fontSize: 11.5, color: AppTheme.dim),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // 「取消」在左：它是唯一没有代价的选择。
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          child: Text(plan.confirmLabel),
        ),
      ],
    );
  }
}
