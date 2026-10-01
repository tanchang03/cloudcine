import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_work.dart';
import '../providers/library_providers.dart';
import '../providers/scrape_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/copy_button.dart';
import '../widgets/media_item_row.dart';
import '../widgets/play_action.dart';
import '../widgets/poster_image.dart';

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
/// 起播走 `playItem`（全应用唯一的起播入口），所以从这里点播与从海报墙
/// 点播的行为**完全一致**：桌面端开独立窗口，其余平台跳内置播放页。
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
          const SizedBox(height: 18),
          _NetdiskLocation(detail: detail),
          const SizedBox(height: 22),
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
              MediaItemRow(item: features[i], index: i),
          ],
          if (extras.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle(title: '花絮 / 样片', count: extras.length),
            const SizedBox(height: 8),
            for (var i = 0; i < extras.length; i++)
              MediaItemRow(item: extras[i], index: i, dim: true),
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
                  primary == null ? null : () => playItem(context, ref, primary),
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
            const SizedBox(width: 10),
            _ScrapeButton(workKey: work.key),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                '${detail.items.length} 个文件',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              ),
            ),
          ],
        ),
        // 刮削结果。**只在属于这部作品时显示** —— 否则刮完 A 再打开 B，
        // B 的页面上还挂着 A 的「已刮削：…」。
        _ScrapeMessage(workKey: work.key),
      ],
    );
  }
}

/// 「刮削这一部」。
///
/// ## 为什么刮削要放在详情页，而不是跟着扫描跑
///
/// 豆瓣的匿名额度实测只有约 **10 个搜索词**，一次全盘扫描（上百部作品）
/// 必然中途耗尽，而耗尽之后是 `103 need_login` —— 用户看到的是「豆瓣一条
/// 都刮不到」，这个 IP 短时间内也不能用了。所以刮削改成**按需**：一次点击
/// 最多花 2 个搜索词，用户自己决定刮哪几部。
///
/// 想恢复自动刮削就在设置里打开「扫描后自动刮削」（默认关）。
///
/// ## 交互上的两个决定
///
///   - **没有源时按钮是灰的，且 tooltip 说清去哪开**。直接藏起来的话，
///     用户不会知道有这个功能，只会问「为什么别人的有海报」。
///   - **不用弹窗报结果**，只在按钮下面写一行。刮削是可以在墙上连点的小动作，
///     每次都弹一个「确定」会把「顺手补个海报」变成一件麻烦事。
class _ScrapeButton extends ConsumerWidget {
  const _ScrapeButton({required this.workKey});

  final String workKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    final state = ref.watch(workScrapeControllerProvider);
    final canScrape = settings?.canScrapeOnline ?? false;
    final running = state.isRunning(workKey);

    return Tooltip(
      message: canScrape
          ? '用在线源（TMDB / 豆瓣）重新查一次海报与简介'
          : '还没有可用的在线刮削源。到「设置 → 刮削」打开开关，'
              '并填入 TMDB Key 或豆瓣 Cookie。',
      child: OutlinedButton.icon(
        onPressed: (!canScrape || running)
            ? null
            : () => ref
                .read(workScrapeControllerProvider.notifier)
                .scrape(workKey),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
        ),
        icon: running
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_awesome_outlined, size: 16),
        label: Text(
          running ? '刮削中…' : '刮削',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// 刮削结果那一行。
class _ScrapeMessage extends ConsumerWidget {
  const _ScrapeMessage({required this.workKey});

  final String workKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workScrapeControllerProvider);
    final message = state.messageFor(workKey);
    if (message == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            state.okFor(workKey)
                ? Icons.check_circle_outline_rounded
                : Icons.info_outline_rounded,
            size: 14,
            color: state.okFor(workKey) ? AppTheme.ok : AppTheme.warn,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.7,
                color: state.okFor(workKey) ? AppTheme.muted : AppTheme.warn,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「网盘位置」。
///
/// ## 为什么这个信息必须出现在详情页
///
/// 媒体库里的标题是**解析出来的**（`流浪地球2`），而网盘上真实的名字可能是
/// `[高清影视之家发布] 流浪地球2.2023.2160p...mkv`。用户要做的很多事情都
/// 得回到网盘：核对是不是同一部、分享给朋友、在夸克 App 里重命名、
/// 或者干脆手动把文件挪个目录。
///
/// 没有这一块的话，用户只能靠猜 —— 而「猜路径」这件事在几千个目录里
/// 基本等于做不到。
///
/// ## 复制的是**路径文本**，不是链接
///
/// 夸克确实有网页版目录链接，但它的格式没有公开文档、随版本变化，而且
/// 拿到链接还得先登录才打得开。**路径文本**则是确定的：它能直接粘进
/// 夸克客户端的搜索框，也能用来人工核对。宁给一个确定能用的，不给一个
/// 看起来更"高级"但会失效的。
class _NetdiskLocation extends StatelessWidget {
  const _NetdiskLocation({required this.detail});

  final WorkDetail detail;

  @override
  Widget build(BuildContext context) {
    final items = detail.items;
    if (items.isEmpty) return const SizedBox.shrink();

    final dirs = items.map((i) => i.dirPath).toSet();
    final singleDir = dirs.length == 1;

    // 多目录时不展示「一个路径」：那时列出来的任何一条都只是**其中一部分**
    // 文件的位置，而用户会以为那是整部剧的位置。改成说明 + 让他按行复制。
    final value = singleDir ? dirs.first : '分布在 ${dirs.length} 个目录';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 12),
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.folder_outlined,
                size: 14,
                color: AppTheme.muted,
              ),
              const SizedBox(width: 7),
              const Text(
                '网盘位置',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.muted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'Menlo',
                    color: AppTheme.text,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              CopyTextButton(
                // 多目录时复制**全部**目录（每行一个），而不是"第一个"——
                // 复制一个不完整的结果比不给复制更糟。
                text: dirs.join('\n'),
                label: singleDir ? '复制路径' : '复制全部目录',
                icon: Icons.folder_copy_outlined,
              ),
            ],
          ),
          const SizedBox(height: 7),
          // 文件 ID 是网盘侧的**稳定主键**。放在这里而不是藏进调试页：
          // 用户报「这部剧扫不出来」时，有这个 ID 就能直接在网盘里定位。
          // 用等宽字体 + 小字号压低视觉权重，它属于"需要时才找得到"的信息。
          Row(
            children: [
              const SizedBox(width: 21),
              Expanded(
                child: Text(
                  items.length == 1
                      ? '文件 ID ${items.first.fileId}'
                      : '文件 ID ${items.first.fileId} …（共 ${items.length} 个）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'Menlo',
                    color: AppTheme.dim,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              CopyTextButton(
                text: items.length == 1
                    ? items.first.fileId
                    : items.map((i) => i.fileId).join('\n'),
                label: '复制 ID',
                icon: Icons.tag_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {  const _SectionTitle({required this.title, required this.count, this.trailing});

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
