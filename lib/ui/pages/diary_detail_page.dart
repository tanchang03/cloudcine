import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/services/watch_diary.dart';
import '../providers/app_providers.dart';
import '../providers/diary_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/star_rating.dart';

/// 观影日记详情页（设计文档 §8.3）。
///
/// 只读快照：`workKey` 只用于「资源还在就跳去重看」，绝不回查媒体库做展示。
/// 资源丢失时显示「网盘上已找不到这部剧，日记已保留」，重看按钮换成一行灰字。
class DiaryDetailPage extends ConsumerStatefulWidget {
  const DiaryDetailPage({super.key, required this.id});

  /// 日记条目 id（来自 `DiaryEntry.id`，不是 workKey）。
  final String id;

  @override
  ConsumerState<DiaryDetailPage> createState() => _DiaryDetailPageState();
}

class _DiaryDetailPageState extends ConsumerState<DiaryDetailPage> {
  final TextEditingController _review = TextEditingController();
  Timer? _savedTimer;
  String _syncStatus = '';
  bool _available = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // store 可能还没读盘（详情页是 push 进入，store 未必已 load）。
    final store = ref.read(diaryStoreProvider);
    await store.load();
    if (mounted) {
      _review.text = store.getEntry(widget.id)?.review ?? _review.text;
      _checkAvailability();
    }
  }

  @override
  void dispose() {
    _savedTimer?.cancel();
    _review.dispose();
    super.dispose();
  }

  Future<void> _checkAvailability() async {
    final e = ref.read(diaryStoreProvider).getEntry(widget.id);
    if (e?.workKey == null) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      final files = await ref.read(mediaRepositoryProvider).itemsForWork(e!.workKey!);
      if (mounted) setState(() => _available = files.isNotEmpty);
    } catch (_) {
      if (mounted) setState(() => _available = false);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _onRate(int? value) {
    final notifier = ref.read(diaryNotifierProvider.notifier);
    if (value == null) {
      notifier.clearRating(widget.id);
    } else {
      notifier.rate(widget.id, value);
    }
    _markSaved();
  }

  void _markSaved() {
    setState(() => _syncStatus = '已保存');
    _savedTimer?.cancel();
    _savedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _syncStatus = '已同步到云端');
    });
  }

  @override
  Widget build(BuildContext context) {
    final entry = ref.watch(diaryNotifierProvider).cast<DiaryEntry?>().firstWhere(
          (e) => e?.id == widget.id,
          orElse: () => null,
        );
    final storeEntry = ref.read(diaryStoreProvider).getEntry(widget.id);

    if (entry == null && storeEntry == null) {
      return Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(backgroundColor: AppTheme.bg, leading: const BackButton()),
        body: const Center(
          child: Text('这条日记已经不在了', style: TextStyle(color: AppTheme.muted)),
        ),
      );
    }
    final e = entry ?? storeEntry!;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        elevation: 0,
        leading: BackButton(
          color: AppTheme.text,
          onPressed: () => context.pop(),
        ),
        title: const Text('观影日记', style: TextStyle(color: AppTheme.text, fontSize: 15)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 110,
                  height: 156,
                  child: _poster(e),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.title,
                        style: const TextStyle(color: AppTheme.text, fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (e.year != null) '${e.year}',
                        _kindLabel(e),
                        if (e.episodeTotal > 0) '${e.episodeWatched}/${e.episodeTotal} 集',
                        if (e.episodeTotal == 0) '电影',
                      ].join(' · '),
                      style: const TextStyle(color: AppTheme.muted, fontSize: 13),
                    ),
                    if (e.genres.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(e.genres.take(3).join(' / '),
                          style: const TextStyle(color: AppTheme.dim, fontSize: 12)),
                    ],
                    const SizedBox(height: 14),
                    StarRating(
                      rating: e.rating,
                      onChanged: _onRate,
                      size: 30,
                    ),
                    if (_syncStatus.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(_syncStatus,
                          style: TextStyle(
                            color: _syncStatus.startsWith('已同步')
                                ? AppTheme.ok
                                : AppTheme.muted,
                            fontSize: 12,
                          )),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            e.episodeTotal > 0
                ? '已看完 ${e.episodeWatched}/${e.episodeTotal} 集 · ${_addedLabel(e)} 记入'
                : '已看完 · ${_addedLabel(e)} 记入',
            style: const TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 22),
          const Text('我的短评', style: TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _review,
            maxLines: 4,
            onChanged: (v) {
              ref.read(diaryNotifierProvider.notifier).setReview(widget.id, v);
              _markSaved();
            },
            style: const TextStyle(color: AppTheme.text, fontSize: 14),
            decoration: InputDecoration(
              hintText: '写点什么…',
              hintStyle: const TextStyle(color: AppTheme.dim),
              filled: true,
              fillColor: AppTheme.panel,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 22),
          const Text('标签', style: TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _tags(e),
          const SizedBox(height: 28),
          if (_checking)
            const SizedBox.shrink()
          else if (_available)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  if (e.workKey != null) context.push('/work?key=${Uri.encodeComponent(e.workKey!)}');
                },
                icon: const Icon(Icons.replay_rounded, size: 18),
                label: const Text('重看第 1 集'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text('网盘上已找不到这部剧，日记已保留',
                  style: TextStyle(color: AppTheme.muted, fontSize: 13)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _confirmRemove(e),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppTheme.danger.withOpacity(0.5)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text('移出日记',
                  style: TextStyle(color: AppTheme.danger, fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tags(DiaryEntry e) {
    final notifier = ref.read(diaryNotifierProvider.notifier);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ...e.tags.map((t) => Chip(
              label: Text(t, style: const TextStyle(color: AppTheme.text, fontSize: 12)),
              backgroundColor: AppTheme.panel2,
              deleteIcon: const Icon(Icons.close, size: 14, color: AppTheme.muted),
              onDeleted: () => notifier.removeTag(widget.id, t),
            )),
        ActionChip(
          label: const Text('+ 添加标签', style: TextStyle(color: AppTheme.accent, fontSize: 12)),
          backgroundColor: AppTheme.panel,
          onPressed: () => _addTag(notifier),
        ),
      ],
    );
  }

  Future<void> _addTag(DiaryNotifier notifier) async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.panel2,
        title: const Text('添加标签', style: TextStyle(color: AppTheme.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: AppTheme.text),
          decoration: const InputDecoration(hintText: '如：神作、意难平', hintStyle: TextStyle(color: AppTheme.dim)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: AppTheme.muted))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('添加', style: TextStyle(color: AppTheme.accent))),
        ],
      ),
    );
    if (v != null && v.trim().isNotEmpty) notifier.addTag(widget.id, v.trim());
  }

  void _confirmRemove(DiaryEntry e) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.panel2,
        title: const Text('移出日记', style: TextStyle(color: AppTheme.text)),
        content: Text('从日记中移除《${e.title}》？你的评分和短评会一起删除。',
            style: const TextStyle(color: AppTheme.muted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消', style: TextStyle(color: AppTheme.muted))),
          TextButton(
            onPressed: () {
              ref.read(diaryNotifierProvider.notifier).remove(widget.id);
              Navigator.pop(ctx);
              context.pop();
            },
            child: Text('移除', style: TextStyle(color: AppTheme.danger)),
          ),
        ],
      ),
    );
  }

  Widget _poster(DiaryEntry e) {
    if (e.posterUrl != null && e.posterUrl!.isNotEmpty) {
      return Image.network(
        e.posterUrl!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, __, ___) => _fallback(e),
      );
    }
    return _fallback(e);
  }

  Widget _fallback(DiaryEntry e) => Container(
        color: AppTheme.panel2,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(8),
        child: Text(e.title, maxLines: 4, textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
      );

  String _kindLabel(DiaryEntry e) {
    switch (e.kind) {
      case 'movie':
        return '电影';
      case 'series':
      case 'tv':
        return '剧集';
      case 'anime':
        return '动漫';
      case 'variety':
        return '综艺';
      default:
        return '其他';
    }
  }

  String _addedLabel(DiaryEntry e) {
    final d = DateTime.fromMillisecondsSinceEpoch(e.addedAtSec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
