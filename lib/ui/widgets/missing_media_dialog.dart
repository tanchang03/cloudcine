import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_item.dart';
import '../../domain/services/missing_media.dart';
import '../providers/library_providers.dart';
import '../theme/app_theme.dart';

/// 「网盘上已经没有这个文件了，要从媒体库里移除吗」。
///
/// ## 为什么必须让用户选范围，而不是替他决定
///
/// 同一个症状（取链返回 `notFound`）后面的实际情况有两种，而我们**无从
/// 分辨**：
///
///   1. 用户只删了一集 —— 其余 23 集都还在，移除整部剧是灾难；
///   2. 用户把整个目录删了 —— 逐个文件去点「这个文件也打不开」是对耐心
///      的消耗，他第一次就该能一次清干净。
///
/// 所以只能问。而问的时候必须把**代价写清楚**（「移除整部剧《X》（24 个
/// 文件）」）：删掉一整部是不可撤销的 —— 要回来得重扫一次网盘。
///
/// ## 三个按钮的排列
///
/// 「暂不处理」永远在最前：这是唯一一个**没有副作用**的选择，用户没看懂
/// 另外两个的区别时，伸手就点到的应当是它。
class MissingMediaDialog extends StatelessWidget {
  const MissingMediaDialog({super.key, required this.plan});

  final MissingMediaPlan plan;

  /// 弹出对话框。返回用户选的范围；`null` = 暂不处理（含点外面关掉）。
  static Future<MediaRemovalScope?> show(
    BuildContext context,
    MissingMediaPlan plan,
  ) {
    return showDialog<MediaRemovalScope>(
      context: context,
      builder: (_) => MissingMediaDialog(plan: plan),
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
          Text('文件打不开了', style: TextStyle(fontSize: 15)),
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
            const SizedBox(height: 12),
            // 把**具体是哪个文件**摊开给用户看。
            //
            // 不写出来的话，用户面对的是一句抽象的「文件不存在」：他无法
            // 确认这是不是自己刚才真的删掉的那个（也可能是程序认错了行），
            // 于是只能取消 —— 而每一次「不敢点」都在消耗他对这个功能的信任。
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
                  Text(
                    plan.itemTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    plan.itemPath,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.5,
                      height: 1.5,
                      fontFamily: 'Menlo',
                      color: AppTheme.dim,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              '要把它的索引从媒体库里移除吗？（只影响本应用的媒体库，'
              '不会动网盘上的文件）',
              style: TextStyle(fontSize: 12.5, height: 1.7, color: AppTheme.text),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('暂不处理'),
        ),
        if (plan.canRemoveSingle)
          OutlinedButton(
            onPressed: () =>
                Navigator.of(context).pop(MediaRemovalScope.singleItem),
            child: Text(plan.singleLabel),
          ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(MediaRemovalScope.wholeWork),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          child: Text(plan.wholeLabel),
        ),
      ],
    );
  }
}

/// 完整流程：读库 → 弹窗 → 移除 → 提示。
///
/// 两个播放器共用这一条，**这是刻意的**：内置播放页在错误浮层上给这个出口，
/// 独立窗口那条路在起播前（`playItem`）就撞上同一个失败。两条路各写一遍的
/// 话，用户会在两个入口遇到两种措辞、两种范围 —— 而他只会觉得「这个移除
/// 功能时灵时不灵」。
///
/// 返回是否真的移除了（调用方据此决定要不要关掉播放页）。
Future<bool> removeMissingMedia(
  BuildContext context,
  WidgetRef ref,
  MediaItem item,
) async {
  final controller = ref.read(missingMediaControllerProvider);
  final plan = await controller.planFor(item);
  if (!context.mounted) return false;

  final scope = await MissingMediaDialog.show(context, plan);
  if (scope == null) return false;
  // 弹窗已经关掉，而 [ref] 与 [context] 可能都已失效 —— 每一步都要确认。
  if (!context.mounted) return false;

  final removed = await controller.remove(item, scope: scope);
  if (!context.mounted) return false;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(plan.removedMessage(scope)),
    ),
  );
  return removed;
}
