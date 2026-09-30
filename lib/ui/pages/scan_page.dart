import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_item.dart';
import '../../domain/services/scan_service.dart';
import '../providers/auth_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scan_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// 扫描页。
///
/// 三个开关都是**本次扫描**的参数，不是全局设置 —— 它们跟着「开始扫描」
/// 一起传下去，跑完就忘。做成全局设置的话，用户为了「这次想快一点」
/// 关掉在线刮削，下次就忘了打开，然后来问「怎么没海报」。
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  bool _resume = true;
  bool _pruneStale = true;
  bool _scrape = true;

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final stats = ref.watch(libraryStatsProvider).valueOrNull;
    final loggedIn = auth?.isAuthorized ?? false;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: '扫描',
            subtitle: _lastScanLabel(settings?.lastScanAt),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!loggedIn)
                  const EmptyState(
                    icon: Icons.lock_outline_rounded,
                    title: '还没登录网盘账号',
                    body: '扫描要读网盘目录，先扫码登录夸克账号。',
                    actionLabel: '去登录',
                  ),
                if (!loggedIn) const SizedBox(height: 8),
                if (loggedIn) ...[
                  SectionCard(
                    title: '扫描选项',
                    description: '这些选项只对**本次**扫描生效，不会写进设置。',
                    child: Column(
                      children: [
                        _SwitchRow(
                          label: '从上次中断处继续',
                          hint: '上次没扫完时接着扫；已经扫完则自动从头开始。',
                          value: _resume,
                          enabled: !scan.running,
                          onChanged: (v) => setState(() => _resume = v),
                        ),
                        _SwitchRow(
                          label: '扫描后清理失效记录',
                          hint: '把网盘侧已删除的文件从媒体库里移除。'
                              '只在**完整扫完**时才执行，中途取消不会误删。',
                          value: _pruneStale,
                          enabled: !scan.running,
                          onChanged: (v) => setState(() => _pruneStale = v),
                        ),
                        _SwitchRow(
                          label: '联网刮削元数据',
                          hint: settings == null
                              ? '读取设置中…'
                              : (settings.canScrapeOnline
                                  ? '用 TMDB 补齐海报与简介。没刮到的作品退回文件名解析。'
                                  : '未启用：需要在「设置」里打开开关并填入 TMDB API Key。'),
                          value: _scrape && (settings?.canScrapeOnline ?? false),
                          enabled: !scan.running &&
                              (settings?.canScrapeOnline ?? false),
                          onChanged: (v) => setState(() => _scrape = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: scan.running
                            ? null
                            : () => ref
                                .read(scanControllerProvider.notifier)
                                .start(
                                  resume: _resume,
                                  pruneStale: _pruneStale,
                                  scrape: _scrape,
                                ),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accent,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 13,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                        icon: const Icon(Icons.radar_rounded, size: 18),
                        label: Text(
                          scan.running ? '正在扫描…' : '开始扫描',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (scan.running)
                        OutlinedButton.icon(
                          onPressed: () =>
                              ref.read(scanControllerProvider.notifier).cancel(),
                          icon: const Icon(Icons.stop_rounded, size: 17),
                          label: const Text('停止'),
                        ),
                      const Spacer(),
                      if (stats != null)
                        Text(
                          '库内 ${stats.items} 个视频 · ${stats.works} 部作品',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.dim,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (scan.running && scan.progress != null)
                    _ProgressCard(progress: scan.progress!),
                  if (scan.outcome != null) ...[
                    _OutcomeCard(outcome: scan.outcome!),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => context.go('/library'),
                        icon: const Icon(Icons.grid_view_rounded, size: 15),
                        label: const Text('去看媒体库'),
                      ),
                    ),
                  ],
                  if (scan.error != null)
                    EmptyState(
                      icon: Icons.error_outline_rounded,
                      danger: true,
                      title: '扫描失败',
                      body: scan.error,
                      actionLabel: '重试',
                      onAction: () => ref
                          .read(scanControllerProvider.notifier)
                          .start(resume: _resume, pruneStale: _pruneStale),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _lastScanLabel(DateTime? at) {
    if (at == null) return '还没有扫描过';
    final d = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '上次扫描：${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.hint,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: enabled ? AppTheme.text : AppTheme.dim,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: AppTheme.dim,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeColor: AppTheme.accent,
          ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final ScanProgress progress;

  @override
  Widget build(BuildContext context) {
    final scraping = progress.phase == ScanPhase.scraping;
    final total = progress.totalWorksToScrape;

    return SectionCard(
      title: progress.phase.label,
      description: progress.message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (scraping && total > 0) ...[
            LinearProgressIndicator(
              value: progress.scrapedWorks / total,
              minHeight: 4,
              backgroundColor: AppTheme.panel3,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              _Metric(label: '已扫目录', value: '${progress.scannedDirs}'),
              _Metric(label: '待扫目录', value: '${progress.pendingDirs}'),
              _Metric(label: '看过文件', value: '${progress.scannedFiles}'),
              _Metric(label: '命中视频', value: '${progress.foundMedia}'),
              if (scraping)
                _Metric(
                  label: '已刮削',
                  value: total > 0 ? '${progress.scrapedWorks}/$total' : '-',
                )
              else
                _Metric(
                  label: '累计体积',
                  value: formatBytes(progress.totalBytes),
                ),
              if (progress.failedDirs > 0)
                _Metric(
                  label: '失败目录',
                  value: '${progress.failedDirs}',
                  color: AppTheme.warn,
                ),
            ],
          ),
          if (progress.currentDirPath != null &&
              progress.currentDirPath!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              progress.currentDirPath!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono,
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: color ?? AppTheme.text,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutcomeCard extends StatelessWidget {
  const _OutcomeCard({required this.outcome});

  final ScanOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final cancelled = outcome.wasCancelled;
    final complete = outcome.isComplete;

    return SectionCard(
      title: cancelled
          ? '扫描已停止'
          : (complete ? '扫描完成' : '扫描结束（未扫完）'),
      description: cancelled
          ? '进度已保存，下次可以「从上次中断处继续」。'
          : (complete
              ? '媒体库已更新。'
              : '这次没扫完，进度已保存，下次接着扫即可。'),
      child: Row(
        children: [
          _Metric(label: '入库视频', value: '${outcome.itemsIndexed}'),
          _Metric(label: '清理失效', value: '${outcome.removedItems}'),
          _Metric(label: '字幕引用', value: '${outcome.subtitlesIndexed}'),
          _Metric(label: '刮削作品', value: '${outcome.worksScraped}'),
        ],
      ),
    );
  }
}
