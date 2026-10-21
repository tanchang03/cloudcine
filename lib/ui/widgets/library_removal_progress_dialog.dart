import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/services/library_batch_delete.dart';
import '../theme/app_theme.dart';

/// 跑一次「慢的」批量移除，期间盖一层**不可关闭**的进度。
///
/// ## 为什么需要这一层
///
/// 勾了「一并删网盘」之后，删的是几百个文件、每批 100 个往网盘打请求
/// （`driveMaxFidsPerRequest`），几秒到几十秒都正常。原来这段时间界面
/// 完全静默 —— 用户唯一的感受是「点了没反应」，于是再点一次「移除」，
/// 而第二次点击面对的是一个已经开始变的勾选集合。
///
/// ## 为什么不是内联进度条
///
/// 目录视图那边（`folder_browser.dart`）把「正在删除 x/N」写在多选工具条
/// 上，因为那条工具条本来就是操作区、一直可见。媒体库这边不一样：确认框
/// 已经关掉了，页面回到普通浏览态，此时任何**可交互**的东西（包括还能点
/// 的「移除」按钮）都是个陷阱。所以这里用模态：遮罩吃掉点击，Esc / 返回
/// 也关不掉（`PopScope(canPop: false)`）—— 中途退出去不会取消已经发出去
/// 的删除请求，只会让用户失去唯一的进度来源。
///
/// ## 返回值
///
/// 直接把 [task] 的结果透传出去，异常也原样透传（弹窗在 `finally` 里关）。
/// 调用方拿到的东西与不套这一层时**完全一样** —— 这层只负责显示。
Future<T> showRemovalProgress<T>({
  required BuildContext context,
  required Future<T> Function(void Function(RemovalProgress) report) task,
}) async {
  final progress = ValueNotifier<RemovalProgress>(RemovalProgress.starting);
  final finished = Completer<void>();

  // ⚠️ 先压栈、再跑任务。任务里第一个 `await` 之前就可能已经报过一次进度
  //    （「正在删除网盘文件…」），那时弹窗还没建出来也不要紧 —— 它建成时
  //    读的是 notifier 的**当前值**，不会漏掉。
  final closed = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _RemovalProgressDialog(
      progress: progress,
      finished: finished.future,
    ),
  );

  try {
    return await task((p) => progress.value = p);
  } finally {
    // 无论成功、失败还是抛异常，这一层都必须下去：留在屏幕上的进度条
    // 比没有进度条更糟（用户会一直等一个已经结束的任务）。
    if (!finished.isCompleted) finished.complete();
    // 等它真的从栈上下去，再让调用方去弹结果提示 —— 否则两层会叠在一起，
    // 用户看到的是「还在删除」上面压着「已删除 12 部」。
    await closed;
  }
}

/// 进度本身 —— 只读，关闭时机由 [finished] 决定。
class _RemovalProgressDialog extends StatefulWidget {
  const _RemovalProgressDialog({
    required this.progress,
    required this.finished,
  });

  final ValueListenable<RemovalProgress> progress;

  /// 任务结束（成功 / 失败都算）时完成。
  final Future<void> finished;

  @override
  State<_RemovalProgressDialog> createState() => _RemovalProgressDialogState();
}

class _RemovalProgressDialogState extends State<_RemovalProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.finished.whenComplete(() {
      // `mounted` 不能省：极端情况下整个页面先被销毁（切到别的 tab），
      // 这时 `Navigator.of(context)` 拿到的已经不是原来那棵树。
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 中途关掉它并不会取消任何东西 —— 请求已经发出去了。留着这一层
      // 至少能让用户看见「还剩多少」。
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppTheme.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.line),
        ),
        title: Row(
          children: const [
            Icon(Icons.cloud_sync_outlined, size: 20, color: AppTheme.danger),
            SizedBox(width: 8),
            Text('正在删除', style: TextStyle(fontSize: 15)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: ValueListenableBuilder<RemovalProgress>(
            valueListenable: widget.progress,
            builder: (context, progress, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // 文案在值对象里（`RemovalProgress.label`），这里只管显示。
                  progress.label,
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    // `null` = 不确定态（还没数出总数 / 还没发出第一批）。
                    value: progress.fraction,
                    minHeight: 5,
                    backgroundColor: AppTheme.panel3,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppTheme.accent),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  // 说清「关不掉」和「别关」不是一回事：用户会去点遮罩、
                  // 按 Esc，试两次之后开始怀疑界面卡死了。
                  '网盘文件删掉之后恢复不了，请等它走完，这一层会自动关闭。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: AppTheme.dim,
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
