import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_work.dart';
import '../../domain/services/empty_work_removal.dart';
import '../providers/library_providers.dart';
import '../theme/app_theme.dart';

/// 「这部作品名下一条文件记录都没有」—— 说清原因 + 给一个移除出口。
///
/// ## 为什么必须是个对话框，而不是一条 SnackBar
///
/// 这个分支原先是一句 SnackBar（「这部作品下没有可播放的文件」），而它的
/// 真实含义（空壳作品行）用户从来没见过。SnackBar 装不下「为什么」和
/// 「怎么办」，装不下的结果就是用户按自己的猜想去行动 —— 而他能做的只有
/// 再点一次，再看到同一句读不懂的话。
///
/// 与 `MissingMediaDialog` 是同一族东西（都是「这条索引有问题，要不要
/// 清掉」），所以按钮顺序也照它：**没有副作用的那一个放在最前**。
class EmptyWorkDialog extends StatelessWidget {
  const EmptyWorkDialog({super.key, required this.plan});

  final EmptyWorkRemovalPlan plan;

  /// 弹出对话框。返回 `true` = 确认移除；`false` = 暂不移除（含点外面关掉）。
  static Future<bool?> show(BuildContext context, EmptyWorkRemovalPlan plan) {
    return showDialog<bool>(
      context: context,
      builder: (_) => EmptyWorkDialog(plan: plan),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.line),
      ),
      title: Row(
        children: const [
          Icon(Icons.link_off_rounded, size: 20, color: AppTheme.warn),
          SizedBox(width: 8),
          Text('这部作品下没有文件', style: TextStyle(fontSize: 15)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              plan.headline,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(height: 10),
            for (final reason in plan.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '· ',
                      style: TextStyle(fontSize: 12.5, color: AppTheme.dim),
                    ),
                    Expanded(
                      child: Text(
                        reason,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: AppTheme.dim,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              plan.keepFilesWarning,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: AppTheme.text,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(plan.dismissLabel),
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

/// 完整流程：弹窗 → 移除 → 提示。
///
/// 与 `removeMissingMedia` 并排存在，而**不**合并成一个函数：那边的最小
/// 单位是「文件」（同一个 `notFound` 可能只坏了一集），这边的最小单位是
/// 「作品」（它名下本来就没有文件）。合并起来就得在参数里分辩「这次是哪种
/// 空」，而那种分辩在调用方眼里只是噪声。
///
/// 返回是否真的移除了。
Future<bool> removeEmptyWork(
  BuildContext context,
  WidgetRef ref,
  MediaWork work,
) async {
  final plan = EmptyWorkRemovalPlan(work: work);
  final confirmed = await EmptyWorkDialog.show(context, plan);
  if (confirmed != true) return false;
  // 弹窗已经关掉，而 [ref] 与 [context] 可能都已失效 —— 每一步都要确认。
  if (!context.mounted) return false;

  final removedFiles =
      await ref.read(missingMediaControllerProvider).removeWorks([work.key]);
  if (!context.mounted) return false;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(plan.doneMessage(removedFiles: removedFiles)),
    ),
  );
  return true;
}
