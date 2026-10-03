import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/format.dart';
import '../../domain/entities/download_task.dart';
import '../providers/download_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/copy_button.dart';
import '../widgets/tv_affordance.dart';

/// 下载记录页。
///
/// ## 它是「下载」这件事的**唯一落脚点**
///
/// 目录视图里点「下载」不再弹一个模态进度框，而是**入队**然后提示一句
/// 「已加入下载队列」。理由：网盘上的东西动辄几十 GB，一个必须盯着它跑完
/// 的模态框等于把用户钉在那一页上 —— 而他真正想干的是「丢进队列，回去继续
/// 翻别的」。模态框还有一个更硬的问题：它一旦被关掉（按 Esc / 切页），
/// 那个下载就再也没有界面能暂停或取消了。
///
/// 所以下载这件事的**全部操作**（暂停 / 继续 / 取消 / 看进度 / 找文件）
/// 都收在这一页，侧栏那个带角标的「下载」就是它的入口。
///
/// ## 分组而不是一条长列表
///
/// 下载记录会长到几十条（批量下载一个目录就是一次几十条）。按状态分组之后，
/// 「正在下的那几条」永远在最上面，不需要用户自己滚着找 —— 而这一页 90% 的
/// 访问就是来看那几条的。组内新的在前（与库里同序）。
///
/// ## 已完成的垫底，而且可以一键清掉
///
/// 已完成的记录除了「找文件」之外没有别的用途，而它们的数量只会增长。
/// 清掉它们**不删磁盘上的文件** —— 这一点在确认框里写明了，
/// 否则用户会以为「清空已完成 = 把下好的片子删了」而不敢点。
class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(downloadGroupsProvider);
    final tasks = ref.watch(downloadQueueProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final controller = ref.read(downloadQueueProvider.notifier);

    final concurrency = settings?.downloadConcurrency ??
        kDefaultDownloadConcurrency;
    final active = tasks
        .where((t) => t.status.isRunning || t.status.isPending)
        .length;
    final hasResumable = tasks.any((t) => t.status.canResume);
    final hasCompleted = tasks.any((t) => t.status == DownloadStatus.completed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '下载',
          subtitle: tasks.isEmpty
              ? '还没有下载任务'
              : '同时最多 $concurrency 个 · 进行中 $active · 共 ${tasks.length} 条记录',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '下载在后台进行，切到别的页面也不会停。'
                  '暂停 / 取消后的记录留在这一页，随时可以继续。',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppTheme.dim),
                ),
              ),
              const SizedBox(width: 10),
              // 只在真的有东西可暂停 / 可继续时才画那两个按钮 ——
              // 一排永远是灰的按钮比没有按钮更让人困惑。
              if (active > 0) ...[
                TextButton(
                  onPressed: () => controller.pauseAll(),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('全部暂停', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
              ],
              if (hasResumable)
                FilledButton.tonal(
                  onPressed: () => controller.resumeAll(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  child: const Text('全部继续', style: TextStyle(fontSize: 12)),
                ),
              if (hasCompleted) ...[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => _confirmClearCompleted(context, controller),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('清空已完成', style: TextStyle(fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? EmptyState(
                  icon: Icons.download_rounded,
                  title: '还没有下载任务',
                  body: '在「媒体库」的文件夹视图里，对着文件点右边的下载按钮，'
                      '它就会出现在这里 —— 可以暂停、继续、取消。',
                  actionLabel: '去文件夹视图',
                  onAction: () => context.go('/library'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 28),
                  itemCount: groups.length,
                  itemBuilder: (context, i) =>
                      _GroupSection(group: groups[i]),
                ),
        ),
      ],
    );
  }

  Future<void> _confirmClearCompleted(
    BuildContext context,
    DownloadQueueController controller,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.panel,
        title: const Text('清空已完成的记录？', style: TextStyle(fontSize: 15)),
        content: const Text(
          '只清掉这一页里的记录，**已经下到磁盘上的文件不会被删**。',
          style: TextStyle(fontSize: 12.5, height: 1.7, color: AppTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(fontSize: 12.5)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
    if (ok == true) await controller.clearCompleted();
  }
}

/// 一个状态分组：小标题 + 若干行。
class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.group});

  final DownloadGroup group;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
          child: Row(
            children: [
              Text(
                group.status.label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${group.count}',
                style: const TextStyle(fontSize: 11, color: AppTheme.dim),
              ),
            ],
          ),
        ),
        for (final task in group.tasks) _TaskRow(task: task),
      ],
    );
  }
}

/// 一行下载记录。
class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(downloadQueueProvider.notifier);
    final color = _statusColor(task.status);
    final progress = task.fraction;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
        decoration: BoxDecoration(
          color: AppTheme.panel,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppTheme.line, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(_statusIcon(task.status), size: 18, color: color),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          task.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TagChip(label: task.status.label, color: color),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    // 网盘路径：同一个 `a.zip` 在 `/电影/` 与 `/备份/` 下
                    // 是两个东西，不给路径就分不清自己下的是哪一个。
                    task.dirPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: AppTheme.dim),
                  ),
                  const SizedBox(height: 6),
                  _ProgressLine(task: task, progress: progress, color: color),
                  if (task.error != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      task.error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.5,
                        color: AppTheme.danger,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            _Actions(task: task, controller: controller),
          ],
        ),
      ),
    );
  }

  static Color _statusColor(DownloadStatus s) => switch (s) {
        DownloadStatus.downloading => AppTheme.accent,
        DownloadStatus.queued => AppTheme.muted,
        DownloadStatus.paused => AppTheme.warn,
        DownloadStatus.completed => AppTheme.ok,
        DownloadStatus.failed => AppTheme.danger,
      };

  static IconData _statusIcon(DownloadStatus s) => switch (s) {
        DownloadStatus.downloading => Icons.downloading_rounded,
        DownloadStatus.queued => Icons.schedule_rounded,
        DownloadStatus.paused => Icons.pause_circle_outline_rounded,
        DownloadStatus.completed => Icons.check_circle_outline_rounded,
        DownloadStatus.failed => Icons.error_outline_rounded,
      };
}

/// 进度条 + 一行数字。
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.task,
    required this.progress,
    required this.color,
  });

  final DownloadTask task;
  final double? progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final received = formatBytes(task.receivedBytes, fractionDigits: 1);
    final total = task.sizeBytes;

    final String label;
    if (task.status == DownloadStatus.completed) {
      label = total != null && total > 0 ? formatBytes(total, fractionDigits: 1) : received;
    } else if (total == null || total <= 0) {
      // 总长未知时**只说已下多少**，不编一个百分比出来。
      label = '已下载 $received';
    } else {
      final percent = ((task.receivedBytes / total) * 100).clamp(0, 100);
      label = '$received / ${formatBytes(total, fractionDigits: 1)}'
          ' · ${percent.toStringAsFixed(0)}%';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  // 总长未知时给 `null` → 不确定态。硬拿已下字节编一个
                  // 百分比是**假装知道**。
                  value: task.status == DownloadStatus.completed ? 1.0 : progress,
                  minHeight: 4,
                  color: color,
                  backgroundColor: AppTheme.panel2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (task.status == DownloadStatus.downloading)
              _SpeedText(received: task.receivedBytes)
            else
              Text(
                label,
                style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
              ),
          ],
        ),
        if (task.status == DownloadStatus.downloading) ...[
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
          ),
        ],
      ],
    );
  }
}

/// 下载速度。**在本组件里现算**，不从队列取。
///
/// 理由：速度是「两个采样点之间的差」，它没有任何持久化的意义（重启之后
/// 那个差值就不成立了），塞进 `DownloadTask` 只会让它多一个永远不该写库的
/// 字段。放在这里采样，生命周期正好跟着这一行 —— 行没了，速度也没了。
class _SpeedText extends StatefulWidget {
  const _SpeedText({required this.received});

  final int received;

  @override
  State<_SpeedText> createState() => _SpeedTextState();
}

class _SpeedTextState extends State<_SpeedText> {
  int _lastBytes = 0;
  DateTime _lastAt = DateTime.now();
  double? _speed;

  @override
  void didUpdateWidget(covariant _SpeedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.received == oldWidget.received) return;
    final now = DateTime.now();
    final elapsedMs = now.difference(_lastAt).inMilliseconds;
    // 采样窗口太短的话，两次回调之间的抖动会把速度显示成一会儿 0
    // 一会儿 200MB/s。500ms 是个既不迟钝也不跳的折中。
    if (elapsedMs < 500) return;
    final delta = widget.received - _lastBytes;
    _speed = delta < 0 ? null : delta * 1000 / elapsedMs;
    _lastBytes = widget.received;
    _lastAt = now;
  }

  @override
  Widget build(BuildContext context) {
    final speed = _speed;
    final text = speed == null || speed <= 0
        ? '—'
        : '${formatBytes(speed.round(), fractionDigits: 1)}/s';
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: AppTheme.accent,
      ),
    );
  }
}

/// 一行右侧的动作。
class _Actions extends StatelessWidget {
  const _Actions({required this.task, required this.controller});

  final DownloadTask task;
  final DownloadQueueController controller;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[];

    if (task.status.canPause) {
      actions.add(_icon(
        context,
        icon: Icons.pause_rounded,
        tooltip: task.status == DownloadStatus.queued ? '取消排队' : '暂停',
        onPressed: () => controller.pause(task.id),
      ));
    }
    if (task.status.canResume) {
      actions.add(_icon(
        context,
        icon: Icons.play_arrow_rounded,
        tooltip: task.status == DownloadStatus.failed ? '重试' : '继续',
        onPressed: () => controller.resume(task.id),
      ));
    }
    if (task.status == DownloadStatus.completed) {
      actions.add(_icon(
        context,
        icon: Icons.folder_open_rounded,
        tooltip: '打开所在目录',
        onPressed: () => revealInFileManager(task.savePath),
      ));
      actions.add(CopyTextButton(
        text: task.savePath,
        label: '复制保存路径',
        tvLabel: '复制路径',
        icon: Icons.content_copy_rounded,
      ));
    }

    actions.add(_icon(
      context,
      icon: task.status.isFinished
          ? Icons.delete_outline_rounded
          : Icons.close_rounded,
      tooltip: task.status.isFinished ? '移除这条记录' : '取消下载',
      onPressed: () => controller.remove(task.id),
    ));

    return Row(mainAxisSize: MainAxisSize.min, children: actions);
  }

  Widget _icon(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return TvIconLabel(
      label: tooltip,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        iconSize: 17,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        icon: Icon(icon),
      ),
    );
  }
}

/// 在系统的文件管理器里定位到这个文件。
///
/// ## 为什么是「定位」而不是「打开」
///
/// 下下来的是 `.zip` / `.iso` / `.srt` —— 用默认程序打开它们不是用户想要的
/// 那件事（尤其 `.iso`，双击可能直接挂载）。用户点这个按钮的意图是
/// 「我要那个文件在哪」，所以三个平台都走「在文件夹里选中它」那条路。
///
/// 失败**静默**：这台机器上没有 `open`（容器里、裁剪过的 Linux）不是用户的
/// 问题，而弹一句「打开失败：ProcessException」只会让他更困惑。路径就在旁边
/// 的「复制路径」里，他总能自己找过去。
Future<void> revealInFileManager(String path) async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        await Process.run('open', ['-R', path]);
      case TargetPlatform.windows:
        // `/select,` 后面那个逗号是 explorer 的语法，不能省。
        await Process.run('explorer', ['/select,', path]);
      case TargetPlatform.linux:
        await Process.run('xdg-open', [p.dirname(path)]);
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return;
    }
  } catch (_) {
    // 见文档：静默。
  }
}
