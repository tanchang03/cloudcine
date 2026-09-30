import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_work.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';

/// 海报。
///
/// 三级降级，**每一级都有明确的视觉结果**，不会出现空白：
///   1. 磁盘缓存命中 → 直接显示文件（打开媒体库秒出图的关键）；
///   2. 有远程地址 → 下载并缓存后再显示（期间显示占位）；
///   3. 都没有 → 渐变底 + 片名首字。
///
/// 不用 `Image.network`：它每次重建都可能重发请求，而海报墙一滚动
/// 就是几十次；而且断网时它会退化成一块灰，看不出是哪部片子。
class PosterImage extends ConsumerStatefulWidget {
  const PosterImage({
    super.key,
    required this.work,
    this.fit = BoxFit.cover,
    this.borderRadius = 10,
  });

  final MediaWork work;
  final BoxFit fit;
  final double borderRadius;

  @override
  ConsumerState<PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends ConsumerState<PosterImage> {
  String? _path;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(PosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一部片子被重新刮削后 `posterUrl` / `posterFile` 会变，
    // 不重新解析就会一直显示旧图。
    if (oldWidget.work.posterUrl != widget.work.posterUrl ||
        oldWidget.work.posterFile != widget.work.posterFile) {
      _resolved = false;
      _path = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final work = widget.work;
    final url = work.posterUrl;

    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _resolved = true);
      return;
    }

    final path = await ref.read(posterCacheProvider).pathFor(
          key: work.key,
          url: url,
          knownFile: work.posterFile,
        );

    if (!mounted) return;
    setState(() {
      _path = path;
      _resolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: path == null
          ? _Placeholder(
              title: widget.work.title,
              // 还在解析中时不要显示「无海报」的观感 —— 占位底色更安静。
              pending: !_resolved,
            )
          : Image.file(
              File(path),
              fit: widget.fit,
              width: double.infinity,
              height: double.infinity,
              // 图片文件可能被外部删掉/损坏，加载失败退回占位，
              // 而不是让整个海报墙抛异常。
              errorBuilder: (_, __, ___) => _Placeholder(
                title: widget.work.title,
                pending: false,
              ),
            ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.pending});

  final String title;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    if (pending) {
      return const ColoredBox(color: AppTheme.panel2);
    }

    final initial = title.trim().isEmpty ? '?' : title.trim().characters.first;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.panel3, AppTheme.panel2],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w300,
            color: AppTheme.dim,
          ),
        ),
      ),
    );
  }
}
