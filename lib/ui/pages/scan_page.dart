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
import '../widgets/drive_tabs.dart';

/// 扫描页。
///
/// 剩下的两个开关都是**本次扫描**的参数，不是全局设置 —— 它们跟着
/// 「开始扫描」一起传下去，跑完就忘。做成全局设置的话，用户为了「这次想快
/// 一点」关掉续扫，下次就忘了打开。
///
/// 「扫描后刮削」**不在这一页**：它是个全局设置（默认关），因为自动刮削会
/// 烧掉额度小的数据源。刮削的默认入口是作品详情页的「刮削」按钮。
class ScanPage extends ConsumerStatefulWidget {
  const ScanPage({super.key});

  @override
  ConsumerState<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends ConsumerState<ScanPage> {
  bool _resume = true;
  bool _pruneStale = true;

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final stats = ref.watch(libraryStatsProvider).valueOrNull;
    final loggedIn = auth?.isAuthorized ?? false;
    // 扫哪一家由用户在这一页选（是一次只能扫一家的操作，没有「同时扫两家」）。
    final connected = ref.watch(connectedDrivesProvider);
    final drive = ref.watch(scanDriveProvider);

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
                  // ⚠️ `actionLabel` 与 `onAction` **必须成对**：
                  // `EmptyState` 里的判据是 `actionLabel != null &&
                  // onAction != null`，只写标签的话按钮**根本不渲染**，
                  // 而屏幕上看起来只是一个「说了去登录却没按钮」的空态。
                  // 原来这里正是漏了 `onAction`（评估文档 P2-7）。
                  //
                  // 说明：路由的 `redirect` 在未授权时会把任何非 `/auth`
                  // 的地址踢回 `/auth`，所以这一段当下几乎到不了（只在
                  // 退出登录那一两帧可能闪过）。补它不是为了修一个用户能
                  // 看见的 bug，而是**别在守卫万一改掉时留一个假按钮**，
                  // 且与 `library_page.dart` 的同名空态保持一致。
                  EmptyState(
                    icon: Icons.lock_outline_rounded,
                    title: '还没登录网盘账号',
                    body: '扫描要读网盘目录，先扫码登录夸克账号。',
                    actionLabel: '去登录',
                    onAction: () => context.go('/auth'),
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
                        _ScrapeHint(
                          canScrape: settings?.canScrapeOnline ?? false,
                          autoScrape: settings?.canAutoScrape ?? false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  DriveTabs(
                    drives: connected,
                    selected: drive,
                    enabled: !scan.running,
                    label: '扫描',
                    onChanged: (p) => ref
                        .read(scanDriveChoiceProvider.notifier)
                        .select(p),
                  ),
                  if (connected.length > 1) const SizedBox(height: 14),
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
                                  provider: drive,
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
                          .start(
                            resume: _resume,
                            pruneStale: _pruneStale,
                            provider: drive,
                          ),
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

/// 「刮削」在扫描页上的**只读**说明。
///
/// ## 为什么这里不再是一个开关
///
/// 原来这里有一个「联网刮削元数据」的勾选（默认勾上）。问题在于它对**额度小
/// 的源**是有害的：豆瓣匿名额度实测只有约 10 个搜索词，一次全盘扫描必然中途
/// 耗尽，而耗尽后是 `103 need_login` —— 用户看到的是「豆瓣一条都刮不到」，
/// 这个 IP 短时间内也不能用了。
///
/// 所以刮削的默认入口改成了**作品详情页的「刮削」按钮**（按需、一次一部），
/// 想省事的人在设置里打开「扫描后自动刮削」（默认关）。
///
/// 这一块保留成只读提示而不是直接删掉：用户会来这里找那个勾选，
/// 找不到时会以为功能被删了。写清楚「去哪点」比什么都不给好。
class _ScrapeHint extends StatelessWidget {
  const _ScrapeHint({required this.canScrape, required this.autoScrape});

  /// 是否配好了至少一个在线源（总开关 + Key/Cookie）。
  final bool canScrape;

  /// 扫描结束是否会自动刮。
  final bool autoScrape;

  @override
  Widget build(BuildContext context) {
    final String text;
    if (!canScrape) {
      text = '未启用。刮削是可选的：到「设置 → 刮削」打开开关并填入 '
          'TMDB Key 或豆瓣 Cookie 后，作品详情页会出现「刮削」按钮。';
    } else if (autoScrape) {
      text = '扫描结束后会自动刮一遍（已在设置里打开）。'
          '只想按需刮的话，把「扫描后自动刮削」关掉，改用详情页的按钮。';
    } else {
      text = '扫描只建索引，不会刮削。要补海报与简介，到作品详情页点「刮削」。';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.auto_awesome_outlined,
              size: 14,
              color: AppTheme.dim,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11,
                height: 1.7,
                color: AppTheme.dim,
              ),
            ),
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
