import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/filename_parser.dart';
import '../../domain/entities/media_work.dart';
import '../providers/auth_providers.dart';
import '../providers/library_providers.dart';
import '../providers/scan_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import '../widgets/poster_image.dart';

/// 媒体库主页（海报墙）。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  /// 搜索防抖。每敲一个字都打一次 SQLite 查询在本地库上不算贵，
  /// 但**每次都让整个海报墙重建**是真的卡 —— 250ms 足够覆盖打字间隔。
  static const Duration _debounceDelay = Duration(milliseconds: 250);

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      ref.read(libraryFilterProvider.notifier).setQuery(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final works = ref.watch(workListProvider);
    final stats = ref.watch(libraryStatsProvider).valueOrNull;
    final filter = ref.watch(libraryFilterProvider);
    final scanning = ref.watch(scanControllerProvider).running;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: '媒体库',
          subtitle: stats == null
              ? null
              : '${stats.items} 个视频 · ${stats.works} 部作品',
          actions: [
            if (scanning)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                    SizedBox(width: 7),
                    Text(
                      '正在扫描',
                      style: TextStyle(fontSize: 11.5, color: AppTheme.accent),
                    ),
                  ],
                ),
              ),
            _SearchBox(
              controller: _search,
              onChanged: _onSearchChanged,
            ),
            const SizedBox(width: 10),
            IconButton(
              tooltip: '刷新',
              onPressed: () {
                ref.invalidate(workListProvider);
                ref.invalidate(libraryStatsProvider);
              },
              icon: const Icon(Icons.refresh_rounded, size: 17),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
          child: Row(
            children: [
              _KindFilter(
                label: '全部',
                selected: filter.kind == null,
                onTap: () =>
                    ref.read(libraryFilterProvider.notifier).setKind(null),
              ),
              const SizedBox(width: 6),
              _KindFilter(
                label: '电影',
                selected: filter.kind == MediaKind.movie,
                onTap: () => ref
                    .read(libraryFilterProvider.notifier)
                    .setKind(MediaKind.movie),
              ),
              const SizedBox(width: 6),
              _KindFilter(
                label: '剧集',
                selected: filter.kind == MediaKind.episode,
                onTap: () => ref
                    .read(libraryFilterProvider.notifier)
                    .setKind(MediaKind.episode),
              ),
            ],
          ),
        ),
        Expanded(
          child: works.when(
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
              title: '读取媒体库失败',
              body: '$e',
              actionLabel: '重试',
              onAction: () => ref.invalidate(workListProvider),
            ),
            data: (list) {
              if (list.isEmpty) {
                // 两种空态要分开：**库里本来就没有**（该去扫描）与
                // **筛选没筛到**（该清条件）。给错行动按钮比不给更糟。
                return filter.isEmpty
                    ? const _NeverScannedState()
                    : EmptyState(
                        icon: Icons.search_off_rounded,
                        title: '没有匹配的作品',
                        body: '换个关键词，或者清掉筛选条件。',
                        actionLabel: '清空筛选',
                        onAction: () => ref
                            .read(libraryFilterProvider.notifier)
                            .clear(),
                      );
              }
              return _PosterGrid(works: list);
            },
          ),
        ),
      ],
    );
  }
}

class _PosterGrid extends StatelessWidget {
  const _PosterGrid({required this.works});

  final List<MediaWork> works;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // 用「最大宽度」而不是固定列数：侧栏固定宽 + 窗口可缩放，
        // 固定列数会让宽窗口下的海报被拉成巨幅。
        maxCrossAxisExtent: 172,
        mainAxisSpacing: 18,
        crossAxisSpacing: 14,
        childAspectRatio: 0.56,
      ),
      itemCount: works.length,
      itemBuilder: (context, i) => _WorkCard(work: works[i]),
    );
  }
}

class _WorkCard extends StatelessWidget {
  const _WorkCard({required this.work});

  final MediaWork work;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => context.push(
        '/work?key=${Uri.encodeComponent(work.key)}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                PosterImage(work: work),
                if (work.rating != null)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: TagChip(
                      label: work.rating!.toStringAsFixed(1),
                      icon: Icons.star_rounded,
                      color: AppTheme.warn,
                      filled: true,
                    ),
                  ),
                if (!work.isScraped)
                  const Positioned(
                    right: 6,
                    top: 6,
                    child: Tooltip(
                      message: '这些信息来自文件名解析，未联网刮削',
                      child: TagChip(
                        label: '文件名',
                        color: AppTheme.dim,
                        filled: true,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            work.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: AppTheme.text,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            work.subtitleLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: AppTheme.dim),
          ),
        ],
      ),
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 32,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
        cursorHeight: 14,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜片名或文件名…',
          hintStyle: const TextStyle(fontSize: 12, color: AppTheme.dim),
          prefixIcon: const Icon(Icons.search_rounded, size: 15),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          filled: true,
          fillColor: AppTheme.panel,
          contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.line, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppTheme.accent, width: 0.8),
          ),
        ),
      ),
    );
  }
}

class _KindFilter extends StatelessWidget {
  const _KindFilter({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppTheme.accent.withValues(alpha: 0.16) : AppTheme.panel,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? AppTheme.accent : AppTheme.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「库里什么都没有」的空态。
class _NeverScannedState extends ConsumerWidget {
  const _NeverScannedState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final loggedIn = auth?.isAuthorized ?? false;

    return EmptyState(
      icon: Icons.movie_filter_outlined,
      title: '媒体库还是空的',
      body: loggedIn
          ? '点「扫描」把网盘里的视频全部找出来。第一次扫描会遍历整个网盘，'
              '耗时取决于目录数量。'
          : '当前没有登录任何网盘账号。',
      actionLabel: loggedIn ? '去扫描' : '去登录',
      onAction: () => loggedIn ? context.go('/scan') : context.go('/auth'),
    );
  }
}
