import 'package:flutter/material.dart';

import '../../domain/services/drive_cleanup.dart';
import '../theme/app_theme.dart';

/// 「要删掉这 N 项吗」—— 批量删除的**唯一**一道确认。
///
/// ## 为什么这个弹窗必须存在，且必须写清楚代价
///
/// 目录视图里勾选是很快的（长按一下、再连点几行），而删除是**不可逆**的。
/// 两者的手感必须不一样，否则用户会在一次顺手的连点之后丢掉一季的片子。
/// 这个弹窗就是那道落差。
///
/// 三件事必须出现在正文里，缺一条都会让用户「按下去才知道」：
///
///   1. **删的是什么** —— 把名字摊开。只写「37 项」的话，用户无法确认
///      自己勾的是不是心里想的那几个（列表可能刚被搜索词筛过、可能滚过）；
///   2. **能腾出多少** —— 他做这件事的动机。目录体积网盘常常不给，
///      那时要说「未知」，绝不能显示成 `0 B`（会被读成「删了也没用」）；
///   3. **不可撤销** —— 用危险色单独一行。用户对「删除」的预期通常是
///      「进回收站」，而这条路径不是。
///
/// 布局照 `MissingMediaDialog`（同类的二次确认）：正文里摊开细节，
/// 「取消」在左、危险动作在右，且危险按钮**带数量**。
class DriveDeleteDialog extends StatelessWidget {
  const DriveDeleteDialog({super.key, required this.plan});

  final DriveDeletePlan plan;

  /// 最多摊开几个名字。再多就折成「…等 N 项」——
  /// 一个能滚动的长列表会把「删除」按钮顶出屏幕，而那正是要用户看清的东西。
  static const int previewLimit = 8;

  /// 弹出确认框。返回 `true` 表示用户确认删除；`null` / `false` 都是不删。
  static Future<bool?> show(BuildContext context, DriveDeletePlan plan) {
    return showDialog<bool>(
      context: context,
      builder: (_) => DriveDeleteDialog(plan: plan),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = plan.entries.take(previewLimit).toList();
    final rest = plan.count - shown.length;
    final folderWarning = plan.folderWarning;

    return AlertDialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.line),
      ),
      title: Row(
        children: [
          const Icon(Icons.delete_forever_rounded,
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
            // ① 不可逆警告放最前：它是用户唯一无法事后补救的后果。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppTheme.danger.withValues(alpha: 0.35),
                  width: 0.6,
                ),
              ),
              child: Text(
                plan.irreversibleWarning,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: AppTheme.danger,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // ② 腾出多少 + 目录连带删的警告。
            Row(
              children: [
                const Icon(Icons.cloud_outlined, size: 13, color: AppTheme.dim),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    plan.freedLabel,
                    style: const TextStyle(fontSize: 12, color: AppTheme.muted),
                  ),
                ),
              ],
            ),
            if (folderWarning != null) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 13, color: AppTheme.warn),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      folderWarning,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: AppTheme.warn,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            // ③ 摊开要删的名字。
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
                  for (final entry in shown)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Row(
                        children: [
                          Icon(
                            entry.isDirectory
                                ? Icons.folder_rounded
                                : Icons.insert_drive_file_outlined,
                            size: 13,
                            color: entry.isDirectory
                                ? AppTheme.accent
                                : AppTheme.dim,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              entry.name,
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
                        '…等共 ${plan.count} 项',
                        style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // 「取消」在左。它是唯一没有副作用的选择，用户没看清时伸手就该
        // 能碰到它。
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
