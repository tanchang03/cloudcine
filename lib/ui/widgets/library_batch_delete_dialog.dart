import 'package:flutter/material.dart';

import '../../domain/services/library_batch_delete.dart';
import '../theme/app_theme.dart';

/// 用户在确认框里做的选择。
///
/// 之所以不是裸 `bool`：这个确认框有**两个维度**（确不确认 / 要不要连网盘
/// 一起删），用一个布尔表达不了。写成 `bool?` 时调用方一定会把
/// `null`（取消）和 `false`（只删索引）读混，而那个混淆的后果是**删掉
/// 用户没打算删的网盘文件**。
class LibraryBatchDeleteChoice {
  const LibraryBatchDeleteChoice({required this.alsoDeleteFromDrive});

  /// 是否连网盘上的文件一起删。
  final bool alsoDeleteFromDrive;
}

/// 「要从媒体库移除这 N 部吗」—— 媒体库批量移除的**唯一**一道确认。
///
/// ## 为什么必须写清楚「网盘文件还在」
///
/// 用户对「移除 / 删除」的默认预期是「东西没了」，而这个按钮实际删的是
/// **本地索引行**（重新扫描就能找回）。好消息要说，但不能只说好消息 ——
/// 续播进度、播放偏好、学到的片头片尾会跟着索引一起走，那才是用户真正
/// 会怀念的东西。两句话都在正文里，缺一句都会让用户在按下去之后才发现。
///
/// ## 但它现在也能真的删（2026-10-21 起）
///
/// 「网盘上还占着几十 GB，库里清掉了等于没清」是一个真实诉求，所以正文
/// 里多了一个**默认关闭**的开关（`plan.canDeleteFromDrive` 为假时整行都
/// 不出现）。勾上之后顶栏那一段从「文件原样保留」换成危险色的不可撤销
/// 警告 —— **两段互斥**，同时出现等于自相矛盾。
///
/// ## ⚠️ 与 `DriveDeleteDialog` 仍然不是同一个弹窗
///
/// 那个删的是目录视图里勾中的**网盘条目**（一个目录连带整棵子树）；
/// 这个删的是**作品**（含折叠进来的源作品名下的文件）。入口不同、口径
/// 不同、文案也不同 —— 合并成一个会让「我删的到底是哪个范围」变得要靠猜。
class LibraryBatchDeleteDialog extends StatefulWidget {
  const LibraryBatchDeleteDialog({super.key, required this.plan});

  final LibraryBatchDeletePlan plan;

  /// 最多摊开几个作品名。再多就折进「…等共 N 部」—— 一个能滚动的长列表
  /// 会把确认按钮顶出屏幕，而那正是要用户看清的东西。
  static const int previewLimit = 8;

  /// 弹出确认框。返回 `null` 表示取消（或点了遮罩）。
  static Future<LibraryBatchDeleteChoice?> show(
    BuildContext context,
    LibraryBatchDeletePlan plan,
  ) {
    return showDialog<LibraryBatchDeleteChoice>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LibraryBatchDeleteDialog(plan: plan),
    );
  }

  @override
  State<LibraryBatchDeleteDialog> createState() =>
      _LibraryBatchDeleteDialogState();
}

class _LibraryBatchDeleteDialogState extends State<LibraryBatchDeleteDialog> {
  /// ⛔ 初值一律从 `false` 开始（即使 plan 里带 `true` 也不认）：这个弹窗
  /// 的每一次打开都是一次新的决定，而「上次勾过」不该变成「这次默认删
  /// 网盘文件」—— 那是一条不可逆的路径，必须每次都重新勾。
  bool _alsoDrive = false;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan.withDriveDeletion(_alsoDrive);
    final names = plan.works.take(LibraryBatchDeleteDialog.previewLimit).toList();
    final rest = plan.count - names.length;
    final mergedWarning = plan.mergedWarning;
    final undeletable = plan.undeletableWarning;

    return AlertDialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.line),
      ),
      title: Row(
        children: [
          Icon(
            plan.alsoDeleteFromDrive
                ? Icons.delete_forever_rounded
                : Icons.playlist_remove_rounded,
            size: 20,
            color: AppTheme.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(plan.title, style: const TextStyle(fontSize: 15)),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ① 最要紧的那句话放最前，且**二选一**：不删网盘时说「文件还在」
            //    （它是这个按钮最需要被知道的一件事）；勾了之后就换成不可
            //    撤销警告 —— 两段同时出现会自相矛盾。
            if (plan.alsoDeleteFromDrive)
              _WarnBox(
                icon: Icons.warning_amber_rounded,
                text: plan.driveDeleteWarning,
                color: AppTheme.danger,
              )
            else
              _WarnBox(
                icon: Icons.cloud_done_outlined,
                text: plan.keepFilesWarning,
                color: AppTheme.accent,
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
            if (undeletable != null) ...[
              const SizedBox(height: 6),
              Text(
                undeletable,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: AppTheme.warn,
                ),
              ),
            ],
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
            // ② 开关。**整行可点**（与目录视图的多选行同一取舍：小方块
            //    在鼠标下也不好瞄准），右边那个图标只是状态显示。
            if (plan.canDeleteFromDrive) ...[
              const SizedBox(height: 10),
              _DriveToggle(
                value: plan.alsoDeleteFromDrive,
                fileCount: plan.driveFileCount,
                onChanged: (v) => setState(() => _alsoDrive = v),
              ),
            ],
            const SizedBox(height: 12),
            // ③ 摊开要移除的名字。
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            LibraryBatchDeleteChoice(alsoDeleteFromDrive: plan.alsoDeleteFromDrive),
          ),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          child: Text(plan.confirmLabel),
        ),
      ],
    );
  }
}

/// 顶部那一段带底色的话（提示 / 警告共用，只换颜色与图标）。
class _WarnBox extends StatelessWidget {
  const _WarnBox({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.6, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「同时删除网盘上的 N 个文件」这一行。
///
/// ⛔ 默认**不勾**，且没有任何记忆（每次打开都从 false 开始，见
/// `_LibraryBatchDeleteDialogState._alsoDrive`）：这是本页唯一一条不可逆
/// 的分支，让它「记住上次的选择」等于让用户在某次顺手确认时删掉一季的片子。
class _DriveToggle extends StatelessWidget {
  const _DriveToggle({
    required this.value,
    required this.fileCount,
    required this.onChanged,
  });

  final bool value;
  final int fileCount;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            color: value
                ? AppTheme.danger.withValues(alpha: 0.10)
                : AppTheme.panel2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: value
                  ? AppTheme.danger.withValues(alpha: 0.45)
                  : AppTheme.line,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              Icon(
                value ? Icons.check_box_rounded : Icons.check_box_outline_blank,
                size: 16,
                color: value ? AppTheme.danger : AppTheme.dim,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '同时删除网盘上的 $fileCount 个文件',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: value ? AppTheme.danger : AppTheme.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '不勾的话只清这台设备上的索引，网盘文件一个都不动。',
                      style: TextStyle(fontSize: 11, color: AppTheme.dim),
                    ),
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
