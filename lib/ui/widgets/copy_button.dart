import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/diagnostics/diag_log.dart';
import '../theme/app_theme.dart';

/// 一个「复制这段文本」的小按钮。
///
/// 复制成功后弹一条轻提示。**不弹对话框**：复制是个高频的小动作，
/// 打断它去点「确定」会把「顺手存个路径」变成一件麻烦事。
///
/// 提到共用文件里是因为「网盘路径 / 文件 ID」这两类文本在详情页与目录视图
/// 都要能复制，而复制成功后的反馈口径必须一致 —— 各写一份迟早会出现
/// 「这里弹提示、那里什么都不弹」。
class CopyTextButton extends StatelessWidget {
  const CopyTextButton({
    super.key,
    required this.text,
    required this.label,
    required this.icon,
    this.tvLabel,
    this.logScope = '媒体库',
  });

  final String text;

  /// 既是 tooltip，也是复制成功提示里的名字。
  final String label;

  /// TV 上印在图标旁边的**短**标签。给 `null` 时退回 [label]。
  ///
  /// 为什么不直接用 [label]：它是一句完整的说明（「复制这个文件的网盘
  /// 路径」，11 个字），在电视上会把这行文件标题挤到只剩几个字 ——
  /// 而标题才是用户扫这一行时要看的东西。这里要的是「知道按下去会发生
  /// 什么」的下限，两三个字就够。
  final String? tvLabel;

  final IconData icon;

  /// 诊断日志的分类名。
  final String logScope;

  @override
  Widget build(BuildContext context) {
    // TV 上没有 hover，「这个 ⧉ 复制的是什么」只写在 tooltip 里 = 等于没写。
    // 所以电视上把短标签直接印在图标旁边。
    final isTv = AppTheme.isTvLayout(context);

    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            diag.info(logScope, '已复制到剪贴板：$label（${text.length} 字符）');
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 2),
                content: Text('已复制：$label'),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppTheme.muted),
                if (isTv) ...[
                  const SizedBox(width: 5),
                  Text(
                    tvLabel ?? label,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
