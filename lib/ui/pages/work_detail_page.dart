import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_item.dart';
import '../../domain/entities/media_work.dart';
import '../providers/library_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/poster_image.dart';
import '../windows/desktop_play.dart';

/// 作品详情页。
///
/// 版式：左边海报与元数据，右边文件列表。这是「一部剧有很多集」时
/// 唯一说得通的结构 —— 把剧集摊成卡片墙会让「第 3 集」和「另一部电影」
/// 长得一样。
class WorkDetailPage extends ConsumerWidget {
  const WorkDetailPage({super.key, required this.workKey});

  final String workKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(workDetailProvider(workKey));

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
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
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => ref.invalidate(workDetailProvider(workKey)),
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                ),
              ],
            ),
          ),
          Expanded(
            child: detail.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline_rounded,
                danger: true,
                title: '读取失败',
                body: '$e',
                actionLabel: '重试',
                onAction: () => ref.invalidate(workDetailProvider(workKey)),
              ),
              data: (d) => d == null
                  ? const EmptyState(
                      icon: Icons.help_outline_rounded,
                      title: '找不到这部作品',
                      body: '它可能已被重新扫描移除。',
                    )
                  : _DetailBody(detail: d),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「播这部片」。
///
/// 桌面端交给**独立播放窗口**；其余平台（以及窗口起不来时）跳内置播放页。
///
/// 降级是**静默**的 —— 用户点播放的意图是看片，不是体验多窗口，
/// 所以「窗口开不出来」不该变成一个错误弹窗。降级原因会进诊断日志。
Future<void> _play(BuildContext context, WidgetRef ref, MediaItem item) async {
  if (await openInPlayerWindow(ref, item)) return;
  if (!context.mounted) return;
  await context.push('/play?item=${Uri.encodeComponent(item.id)}');
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.detail});

  final WorkDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final work = detail.work;
    final features = detail.features;
    final extras = detail.extras;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 138,
                height: 207,
                child: PosterImage(work: work, borderRadius: 10),
              ),
              const SizedBox(width: 20),
              Expanded(child: _InfoColumn(work: work, detail: detail)),
            ],
          ),
          const SizedBox(height: 24),
          if (features.isNotEmpty) ...[
            _SectionTitle(
              title: '文件',
              count: features.length,
              trailing: features.length > 1
                  ? Text(
                      '共 ${features.length} 个 · 点任意一行播放',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.dim,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < features.length; i++)
              _ItemRow(item: features[i], index: i),
          ],
          if (extras.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle(title: '花絮 / 样片', count: extras.length),
            const SizedBox(height: 8),
            for (var i = 0; i < extras.length; i++)
              _ItemRow(item: extras[i], index: i, dim: true),
          ],
        ],
      ),
    );
  }
}

class _InfoColumn extends ConsumerWidget {
  const _InfoColumn({required this.work, required this.detail});

  final MediaWork work;
  final WorkDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = detail.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          work.title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            height: 1.3,
            color: AppTheme.text,
          ),
        ),
        if (work.originalTitle != null &&
            work.originalTitle!.isNotEmpty &&
            work.originalTitle != work.title) ...[
          const SizedBox(height: 4),
          Text(
            work.originalTitle!,
            style: const TextStyle(fontSize: 12.5, color: AppTheme.muted),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            TagChip(label: work.kind.label, color: AppTheme.accent),
            if (work.year != null)
              TagChip(label: '${work.year}', color: AppTheme.muted),
            if (work.rating != null)
              TagChip(
                label: work.rating!.toStringAsFixed(1),
                icon: Icons.star_rounded,
                color: AppTheme.warn,
              ),
            TagChip(
              label: work.source.label,
              color: work.isScraped ? AppTheme.ok : AppTheme.dim,
              icon: work.isScraped
                  ? Icons.cloud_done_rounded
                  : Icons.description_outlined,
            ),
            for (final g in work.genres.take(4))
              TagChip(label: g, color: AppTheme.muted),
          ],
        ),
        if (work.overview != null && work.overview!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            work.overview!,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              height: 1.75,
              color: AppTheme.muted,
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            FilledButton.icon(
              onPressed:
                  primary == null ? null : () => _play(context, ref, primary),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 19),
              label: Text(
                primary == null
                    ? '没有可播文件'
                    : (detail.hasMultipleVersions ? '播放第一个版本' : '播放'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${detail.items.length} 个文件',
              style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.count, this.trailing});

  final String title;
  final int count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.text,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 一行文件。
class _ItemRow extends ConsumerWidget {
  const _ItemRow({required this.item, required this.index, this.dim = false});

  final MediaItem item;
  final int index;

  /// 花絮行整体降一级视觉权重。
  final bool dim;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolution = item.resolution;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: () => _play(context, ref, item),
          borderRadius: BorderRadius.circular(9),
          hoverColor: AppTheme.panel2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    '${index + 1}'.padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'Menlo',
                      color: dim ? AppTheme.dim : AppTheme.muted,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: dim ? AppTheme.muted : AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.technicalSummary.isEmpty
                            ? item.name
                            : item.technicalSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.dim,
                        ),
                      ),
                    ],
                  ),
                ),
                if (resolution != null) ...[
                  const SizedBox(width: 10),
                  TagChip(
                    label: resolution.marketingLabel,
                    color: AppTheme.resolutionColor(resolution),
                  ),
                ],
                const SizedBox(width: 8),
                const Icon(
                  Icons.play_circle_outline_rounded,
                  size: 19,
                  color: AppTheme.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
