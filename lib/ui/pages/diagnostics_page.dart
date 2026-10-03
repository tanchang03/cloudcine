import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/format.dart';
import '../../domain/adapters/stream_relay.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/tv_affordance.dart';
import '../widgets/tv_text.dart';
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
      // ⛔ **壳外的整幅页要自己让开过扫描区**：`/diagnostics` 是
      // `StatefulShellRoute` **之外**的一级路由（见 `app_router.dart`），
      // 拿不到 `AppShell` 那层内边距。不加的话电视上最左那列（返回键、每条
      // 日志的开头几个字）会落进过扫描带被切掉 —— 而日志正是要一行行读的。
      // 理由与「哪两种页面不需要加」见 `AppTheme.safeAreaInsets` 的文档。
      body: Padding(
        padding: AppTheme.safeAreaInsets(context),
        child: ValueListenableBuilder<int>(
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
              const RelayStatusPanel(),
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
/// 路径用 [TvSelectableText] 而不是普通 [Text]：即使不点按钮，也能用鼠标
/// 划选带走。按钮只是让这一步更省事，不是唯一出口。
/// ⚠️ 但 TV 上必须退回普通 `Text` —— `SelectableText` 自带可聚焦的
/// `EditableText`，D-pad 会卡在它上面出不去（理由见 `widgets/tv_text.dart`）。
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
          child: TvSelectableText(
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

/// 本地中继的实时状态。
///
/// ## 为什么值得单独摆出来
///
/// 「原画卡顿」的因果链全在暗处：用户看不到开了几条连接、拉到了多少字节、
/// 上游失败了几次。没有这一块，实测只能凭手感说「好像快了点」；而万一还是
/// 卡，也分不清是「中继没生效」还是「总带宽本来就不够」—— 这两件事的处置
/// 完全不同（前者要翻日志，后者只能切转码档）。
///
/// ## ⚠️ 自己按 1 Hz 拉，不让中继广播
///
/// 中继的统计每秒都在变。让它去 `notifyListeners` 会让**整个播放页**每秒
/// 重建一次；而这里只要一个页面上的数字，按需拉取代价可以忽略。
class RelayStatusPanel extends ConsumerStatefulWidget {
  const RelayStatusPanel({super.key});

  @override
  ConsumerState<RelayStatusPanel> createState() => _RelayStatusPanelState();
}

class _RelayStatusPanelState extends ConsumerState<RelayStatusPanel> {
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 只在**确实有会话**时才跳秒。
  ///
  /// ⚠️ 不这么写的话，诊断页会在测试里留下一个永远在跑的 periodic timer，
  /// `pumpAndSettle` 会一直等它 —— 测试直接超时，而报错完全指不到这里。
  void _syncTicker(bool needed) {
    if (needed && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needed && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final relay = ref.watch(streamRelayProvider);
    final stats = relay.aggregateStats;
    _syncTicker(stats != null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
      child: _card(relay, stats),
    );
  }

  Widget _card(StreamRelay relay, RelayStats? stats) {
    final box = BoxDecoration(
      color: AppTheme.panel,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppTheme.line, width: 0.5),
    );

    if (stats == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: box,
        child: const Row(
          children: [
            Icon(Icons.hub_outlined, size: 15, color: AppTheme.dim),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '本地中继 · 当前没有走中继的流'
                '（未启用，或播的是转码档 / 本地文件）',
                style: TextStyle(fontSize: 11.5, color: AppTheme.dim),
              ),
            ),
          ],
        ),
      );
    }

    final total = relay.primaryContentLength;
    final progress = total == null ? null : stats.progressOf(total);
    final source = relay.sessionLabels.isEmpty ? '' : relay.sessionLabels.first;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: box,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, size: 15, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text(
                '本地中继 · ${stats.activeWorkers} 路在拉',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.text,
                ),
              ),
              const Spacer(),
              Text(
                progress == null
                    ? '已拉 ${formatBytes(stats.downloadedBytes)}'
                    : '已拉 ${formatBytes(stats.downloadedBytes)}'
                        ' / ${formatBytes(total)}'
                        '（${(progress * 100).toStringAsFixed(0)}%）',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              // 长度未知时给 0 而不是 null：null 会变成**无限循环**的动画，
              // 而这一页在 widget 测试里会被 `pumpAndSettle` 一直等下去。
              value: progress ?? 0,
              minHeight: 4,
              backgroundColor: AppTheme.line,
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  source,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono.copyWith(fontSize: 10.5),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '缓存 ${formatBytes(stats.cachedBytes)}'
                ' · 上游请求 ${stats.upstreamRequests}'
                ' · 连接 ${stats.upstreamConnects} 条'
                '${stats.upstreamFailures == 0 ? "" : " · 失败 ${stats.upstreamFailures}"}',
                style: TextStyle(
                  fontSize: 11,
                  color: stats.upstreamFailures == 0
                      ? AppTheme.dim
                      : AppTheme.warn,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
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
      child: TvSelectableText(
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
