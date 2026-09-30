import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// 诊断日志页。
///
/// 日志是**取证材料**，所以这一页的取向是「尽量不改动、尽量能带走」：
///   - 只提供「复制全部」与「清空内存缓冲」，**不提供删文件** ——
///     删了文件就再也没法回头看了，而用户点这个按钮时通常正在气头上；
///   - 文件路径直接可选中，方便去访达里取。
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  /// 只看 warn 以上。
  ///
  /// 默认**关闭**：默认打开会让「日志页是空的」变成一个常见困惑，
  /// 而全量日志在排查时又必须能一次看到。
  bool _onlyProblems = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<int>(
        valueListenable: diag.revision,
        builder: (context, _, __) {
          final all = diag.lines;
          final lines = _onlyProblems
              ? all.where(_looksLikeProblem).toList(growable: false)
              : all;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 14, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => context.pop(),
                      iconSize: 18,
                      tooltip: '返回',
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      '诊断日志',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.text,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${lines.length} 行',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.dim,
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilterChip(
                      label: const Text('只看问题'),
                      selected: _onlyProblems,
                      onSelected: (v) => setState(() => _onlyProblems = v),
                      backgroundColor: AppTheme.panel,
                      selectedColor: AppTheme.danger.withValues(alpha: 0.2),
                      checkmarkColor: AppTheme.danger,
                      labelStyle: const TextStyle(fontSize: 11.5),
                      side: const BorderSide(color: AppTheme.line, width: 0.5),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: lines.isEmpty ? null : () => _copy(lines),
                      icon: const Icon(Icons.copy_all_rounded, size: 15),
                      label: const Text('复制全部'),
                    ),
                    TextButton.icon(
                      onPressed: all.isEmpty
                          ? null
                          : () {
                              diag.clearBuffer();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('已清空内存缓冲（日志文件未删除）'),
                                ),
                              );
                            },
                      icon: const Icon(Icons.cleaning_services_rounded, size: 15),
                      label: const Text('清空缓冲'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    diag.filePath ?? '日志文件不可写（仅内存）',
                    style: AppTheme.mono,
                  ),
                ),
              ),
              Expanded(
                child: lines.isEmpty
                    ? const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: '暂无日志',
                        body: '应用运行过程中产生的关键事件会出现在这里。'
                            '播放异常、取链失败、扫描出错都值得看一眼。',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
                        itemCount: lines.length,
                        itemBuilder: (context, i) => _LogLine(text: lines[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  static bool _looksLikeProblem(String line) {
    final l = line.toLowerCase();
    return l.contains('[warn') ||
        l.contains('[error') ||
        l.contains('失败') ||
        l.contains('异常');
  }

  Future<void> _copy(List<String> lines) async {
    // 倒序复制：最新的在最上面，和页面上看到的一致。
    await copyToClipboard(lines.reversed.join('\n'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${lines.length} 行日志')),
    );
  }
}

/// 把文本放进系统剪贴板。
///
/// 单独抽出来是为了让这一页不直接依赖 `services.dart` —— 测试里
/// 可以替换实现，不需要真的去碰平台通道。
Future<void> copyToClipboard(String text) async {
  await Clipboard.setData(ClipboardData(text: text));
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final color = text.contains('[error')
        ? AppTheme.danger
        : (text.contains('[warn') ? AppTheme.warn : AppTheme.muted);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: SelectableText(
        text,
        style: TextStyle(
          fontFamily: 'Menlo',
          fontFamilyFallback: const ['Consolas', 'monospace'],
          fontSize: 11,
          height: 1.55,
          color: color,
        ),
      ),
    );
  }
}
