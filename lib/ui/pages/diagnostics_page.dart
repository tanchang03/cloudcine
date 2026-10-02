import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tv_affordance.dart';
import '../windows/player_window_bridge.dart';

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
                    TvIconLabel(
                      label: '返回',
                      child: IconButton(
                        onPressed: () => context.pop(),
                        iconSize: 18,
                        tooltip: '返回',
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
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
                    const SizedBox(width: 10),
                    // 放在左组而不是右侧的日志操作组：它跟日志没关系，
                    // 是「另开一个窗口看看」这类排查动作，语义上属于页面入口。
                    TextButton.icon(
                      onPressed: _openPlayerWindow,
                      icon: const Icon(Icons.open_in_new_rounded, size: 15),
                      label: const Text('播放器窗口'),
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
                child: LogPathRow(
                  path: diag.filePath,
                  onCopy: _copyLogPath,
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

  /// 开一个 PC 端独立播放窗口。
  ///
  /// 这是阶段一的**验证入口**：真正接入播放流程（点片即开窗）在阶段二之后，
  /// 现在需要一个人工按钮，好让「子窗口引擎能否起来」这类问题能被单独复现，
  /// 不必依赖媒体库里恰好有一部能播的片子。
  Future<void> _openPlayerWindow() async {
    // 先取 messenger 再用：`await` 之后 context 可能已经失效。
    final messenger = ScaffoldMessenger.of(context);
    try {
      final controller = await const PlayerWindowLauncher().open();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            controller == null
                ? '当前平台不支持独立播放窗口'
                : '播放窗口 ${controller.windowId} 已打开',
          ),
        ),
      );
    } catch (e, st) {
      diag.error('窗口', '打开播放窗口失败', error: e, stackTrace: st);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('打开播放窗口失败：$e')));
    }
  }

  Future<void> _copy(List<String> lines) async {
    // 倒序复制：最新的在最上面，和页面上看到的一致。
    await copyToClipboard(lines.reversed.join('\n'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${lines.length} 行日志')),
    );
  }

  /// 复制日志文件的**绝对路径**（不是内容）。
  ///
  /// 这是排查链路里最常被卡住的一环：用户能看见日志、能全选复制，却没法把
  /// 「文件在哪」告诉别人 —— 而路径正是让人自己去翻、或者把日志整份发出来的
  /// 前提。只给路径不给内容是有意的：内容可能很长，粘贴到聊天窗口会被截断，
  /// 而路径一定能完整送达。
  Future<void> _copyLogPath(String path) async {
    await copyToClipboard(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制日志文件路径')),
    );
  }
}

/// 日志文件路径那一行：路径 + 「复制路径」。
///
/// 抽成独立 widget 而不是直接写在页面里，是为了让它成为
/// 「输入（[path]）→ 输出（界面）」的纯函数 —— 测试不必去启动那个全局日志
/// 单例、也不必造一个真实文件，就能把「有路径 / 没路径」两种形态钉住。
///
/// 路径用 [SelectableText] 而不是普通 [Text]：即使不点按钮，也能用鼠标
/// 划选带走。按钮只是让这一步更省事，不是唯一出口。
class LogPathRow extends StatelessWidget {
  const LogPathRow({super.key, required this.path, required this.onCopy});

  /// 日志文件的绝对路径；null 表示写盘失败，本次只有内存日志。
  final String? path;

  /// 点「复制路径」时调用，参数就是该复制的文本。
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    final p = path;
    return Row(
      children: [
        Expanded(
          child: SelectableText(
            p ?? '日志文件不可写（仅内存）',
            style: AppTheme.mono,
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          // 没有路径时禁用而不是复制空串：静默复制一段空文本会让用户以为
          // 「复制成功了但日志是空的」，比按钮灰掉更难查。
          onPressed: p == null ? null : () => onCopy(p),
          icon: const Icon(Icons.copy_rounded, size: 14),
          label: const Text('复制路径'),
        ),
      ],
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
