import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/diag_log.dart';
import '../../domain/services/watch_diary.dart';
import '../providers/app_providers.dart';
import '../providers/diary_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/diary_toast.dart';
import '../widgets/star_rating.dart';

/// 观影日记主页（设计文档 §8.2）。
///
/// 三种视图：封面 / 列表 / 时间轴；筛选维度（分类/评分）与排序读的是日记本身，
/// 与媒体库的 `LibraryFilter` 同构但数据源不同。卡片只显示三样：封面、标题、评分
/// （未评分显示「待评」虚线星），右上角小角标表示资源是否还在。
class DiaryPage extends ConsumerStatefulWidget {
  const DiaryPage({super.key});

  @override
  ConsumerState<DiaryPage> createState() => _DiaryPageState();
}

enum _DiaryView { cover, list, timeline }

enum _RatingFilter {
  all('全部'),
  masterpiece('神作 9–10'),
  good('好看 7–8.5'),
  fair('一般 5–6.5'),
  poor('差评 <5'),
  unrated('待评分');

  const _RatingFilter(this.label);
  final String label;
}

enum _SortBy { recent, rating, title, earliest }

class _DiaryPageState extends ConsumerState<DiaryPage> {
  _DiaryView _view = _DiaryView.cover;
  String _category = '全部';
  _RatingFilter _rating = _RatingFilter.all;
  _SortBy _sort = _SortBy.recent;
  final TextEditingController _search = TextEditingController();
  final Set<String> _availableWorkKeys = {};
  bool _keysLoaded = false;

  static const List<String> _categories = [
    '全部',
    '电影',
    '剧集',
    '动漫',
    '综艺',
    '其他',
  ];

  @override
  void initState() {
    super.initState();
    // 首屏前先把 store 读进来，并取一份「还在库里的作品键」用于角标判定。
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(diaryStoreProvider);
    await store.load();
    ref.read(diaryNotifierProvider.notifier).reload();
    // 调试标记：确认导航/路由通了、本地有多少条。下一次抓日志能直接看到。
    diag.info('日记', '日记页载入：本地可见 ${store.book.visibleCount} 条');
    try {
      final works = await ref.read(mediaRepositoryProvider).allWorks();
      if (mounted) {
        setState(() {
          _availableWorkKeys
            ..clear()
            ..addAll(works.map((w) => w.key));
          _keysLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _keysLoaded = true);
    }
  }

  bool _available(DiaryEntry e) =>
      e.workKey != null && _availableWorkKeys.contains(e.workKey);

  List<DiaryEntry> _filtered() {
    final q = _search.text.trim().toLowerCase();
    final list = ref
        .watch(diaryNotifierProvider)
        .where((e) {
          if (_category != '全部' && _categoryFor(e) != _category) {
            return false;
          }
          if (!_ratingMatches(e)) return false;
          if (q.isNotEmpty &&
              !e.title.toLowerCase().contains(q) &&
              !(e.originalTitle?.toLowerCase() ?? '').contains(q)) {
            return false;
          }
          return true;
        })
        .toList();
    list.sort(_compare);
    return list;
  }

  int _compare(DiaryEntry a, DiaryEntry b) {
    switch (_sort) {
      case _SortBy.rating:
        final ra = a.rating ?? -1;
        final rb = b.rating ?? -1;
        if (ra != rb) return rb.compareTo(ra);
        return b.addedAtSec.compareTo(a.addedAtSec);
      case _SortBy.title:
        return a.title.compareTo(b.title);
      case _SortBy.earliest:
        return a.addedAtSec.compareTo(b.addedAtSec);
      case _SortBy.recent:
        return b.addedAtSec.compareTo(a.addedAtSec);
    }
  }

  String _categoryFor(DiaryEntry e) {
    switch (e.category) {
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

  bool _ratingMatches(DiaryEntry e) {
    // 评分在存储层是 1..10 整数（= 0.5~5 星 ×2）。筛选区间直接按该整数划分：
    // 神作 ≥9、好看 7–8、一般 5–6、差评 <5。
    switch (_rating) {
      case _RatingFilter.all:
        return true;
      case _RatingFilter.unrated:
        return !e.isRated;
      case _RatingFilter.masterpiece:
        return e.rating != null && e.rating! >= 9;
      case _RatingFilter.good:
        return e.rating != null && e.rating! >= 7 && e.rating! <= 8;
      case _RatingFilter.fair:
        return e.rating != null && e.rating! >= 5 && e.rating! <= 6;
      case _RatingFilter.poor:
        return e.rating != null && e.rating! < 5;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filtered();
    final rated = entries.where((e) => e.isRated).toList();
    final avg = rated.isEmpty
        ? 0.0
        : rated.map((e) => e.rating!).reduce((a, b) => a + b) / rated.length;
    final masterpiece = entries.where((e) => e.rating != null && e.rating! >= 9).length;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DiaryRecordedToast(),
          _toolbar(entries.length, avg, masterpiece),
          Expanded(
            child: entries.isEmpty
                ? _empty(entries.isEmpty)
                : _view == _DiaryView.timeline
                    ? _timeline(entries)
                    : _view == _DiaryView.list
                        ? _listView(entries)
                        : _coverView(entries),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(int count, double avg, int masterpiece) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('观影日记',
                  style: TextStyle(
                      color: AppTheme.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 14),
              Text(
                '共 $count 部 · 平均 ${avg.toStringAsFixed(1)} 分 · $masterpiece 部神作',
                style: const TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
              const Spacer(),
              _viewToggle(),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chipGroup(
                  _categories,
                  _category,
                  (v) => setState(() => _category = v),
                ),
                const SizedBox(width: 10),
                _chipGroup(
                  _RatingFilter.values.map((e) => e.label).toList(),
                  _rating.label,
                  (v) => setState(() => _rating =
                      _RatingFilter.values.firstWhere((e) => e.label == v)),
                ),
                const SizedBox(width: 10),
                _sortMenu(),
                const SizedBox(width: 10),
                SizedBox(
                  width: 180,
                  height: 34,
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(color: AppTheme.text, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '搜索片名',
                      hintStyle:
                          const TextStyle(color: AppTheme.dim, fontSize: 13),
                      prefixIcon: const Icon(Icons.search,
                          size: 16, color: AppTheme.muted),
                      filled: true,
                      fillColor: AppTheme.panel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.panel,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          _viewBtn(_DiaryView.cover, '封面'),
          _viewBtn(_DiaryView.list, '列表'),
          _viewBtn(_DiaryView.timeline, '时间轴'),
        ],
      ),
    );
  }

  Widget _viewBtn(_DiaryView v, String label) {
    final active = _view == v;
    return InkWell(
      onTap: () => setState(() => _view = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppTheme.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : AppTheme.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _chipGroup(List<String> items, String selected, ValueChanged<String> onPick) {
    return Row(
      children: items
          .map((it) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _chip(it, it == selected, onPick),
              ))
          .toList(),
    );
  }

  Widget _chip(String label, bool active, ValueChanged<String> onPick) {
    return InkWell(
      onTap: () => onPick(label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppTheme.accent.withValues(alpha: 0.16) : AppTheme.panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? AppTheme.accent : AppTheme.line,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? AppTheme.accent : AppTheme.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _sortMenu() {
    return PopupMenuButton<_SortBy>(
      color: AppTheme.panel2,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.panel,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.line),
        ),
        child: Row(
          children: const [
            Icon(Icons.sort_rounded, size: 14, color: AppTheme.muted),
            SizedBox(width: 4),
            Text('排序', style: TextStyle(color: AppTheme.muted, fontSize: 12)),
          ],
        ),
      ),
      itemBuilder: (ctx) => [
        _sortItem(_SortBy.recent, '最近记入'),
        _sortItem(_SortBy.earliest, '记入时间最早'),
        _sortItem(_SortBy.rating, '评分最高'),
        _sortItem(_SortBy.title, '标题'),
      ],
      onSelected: (v) => setState(() => _sort = v),
    );
  }

  PopupMenuItem<_SortBy> _sortItem(_SortBy v, String label) =>
      PopupMenuItem(value: v, child: Text(label, style: const TextStyle(color: AppTheme.text, fontSize: 13)));

  Widget _coverView(List<DiaryEntry> list) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        mainAxisSpacing: 16,
        crossAxisSpacing: 14,
        childAspectRatio: 0.68,
      ),
      itemCount: list.length,
      itemBuilder: (ctx, i) => _coverCard(list[i]),
    );
  }

  Widget _coverCard(DiaryEntry e) {
    return InkWell(
      onTap: () => context.push('/diary/detail?id=${Uri.encodeComponent(e.id)}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _poster(e),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: _statusBadge(e),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(e.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          _ratingMini(e),
        ],
      ),
    );
  }

  Widget _ratingMini(DiaryEntry e) {
    if (!e.isRated) {
      return const Text('待评分',
          style: TextStyle(color: AppTheme.dim, fontSize: 11, fontWeight: FontWeight.w500));
    }
    return Row(
      children: [
        Icon(Icons.star_rounded, size: 13, color: AppTheme.warn),
        const SizedBox(width: 3),
        Text((e.rating! / 2).toStringAsFixed(1),
            style: const TextStyle(color: AppTheme.muted, fontSize: 11)),
      ],
    );
  }

  Widget _listView(List<DiaryEntry> list) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppTheme.line),
      itemBuilder: (ctx, i) {
        final e = list[i];
        return InkWell(
          onTap: () => context.push('/diary/detail?id=${Uri.encodeComponent(e.id)}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(width: 38, height: 54, child: _poster(e)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          style: const TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        '${_categoryFor(e)} · ${e.year ?? '—'} · ${e.episodeTotal > 0 ? '${e.episodeWatched}/${e.episodeTotal} 集' : '电影'}',
                        style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                _statusBadge(e),
                const SizedBox(width: 10),
                _ratingMini(e),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _timeline(List<DiaryEntry> list) {
    // 按 addedAt 的月份分组（不按 lastWatched，见设计文档 §8.2）。
    final groups = <String, List<DiaryEntry>>{};
    for (final e in list) {
      final d = DateTime.fromMillisecondsSinceEpoch(e.addedAtSec * 1000);
      final key = '${d.year} 年 ${d.month} 月';
      (groups[key] ??= []).add(e);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) => _monthRank(b).compareTo(_monthRank(a)));
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      itemCount: keys.length,
      itemBuilder: (ctx, i) {
        final k = keys[i];
        final items = groups[k]!;
        final rated = items.where((e) => e.isRated);
        final avg = rated.isEmpty
            ? 0.0
            : rated.map((e) => e.rating!).reduce((a, b) => a + b) / rated.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Text(k,
                      style: const TextStyle(color: AppTheme.text, fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 10),
                  Text('${items.length} 部 · 平均 ${avg.toStringAsFixed(1)} 分',
                      style: const TextStyle(color: AppTheme.muted, fontSize: 12)),
                ],
              ),
            ),
            ...items.map((e) => _timelineRow(e)),
          ],
        );
      },
    );
  }

  int _monthRank(String key) {
    final m = RegExp(r'(\d+) 年 (\d+) 月').firstMatch(key);
    if (m == null) return 0;
    return int.parse(m.group(1)!) * 12 + int.parse(m.group(2)!);
  }

  Widget _timelineRow(DiaryEntry e) {
    final d = DateTime.fromMillisecondsSinceEpoch(e.addedAtSec * 1000);
    return InkWell(
      onTap: () => context.push('/diary/detail?id=${Uri.encodeComponent(e.id)}'),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14, left: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 26,
              child: Text('${d.day}',
                  style: const TextStyle(color: AppTheme.muted, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(width: 34, height: 48, child: _poster(e)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title,
                      style: const TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(
                    e.episodeTotal > 0
                        ? '${_categoryFor(e)} · ${e.episodeWatched}/${e.episodeTotal} 集 · 已看完'
                        : '电影 · ${_minsLabel(e)}',
                    style: const TextStyle(color: AppTheme.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            _statusBadge(e),
            const SizedBox(width: 10),
            _ratingMini(e),
          ],
        ),
      ),
    );
  }

  String _minsLabel(DiaryEntry e) {
    if (e.durationMs == null || e.durationMs! <= 0) return '—';
    final m = (e.durationMs! / 60000).round();
    return '$m 分钟';
  }

  Widget _statusBadge(DiaryEntry e) {
    if (!_keysLoaded) return const SizedBox.shrink();
    final ok = _available(e);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: ok
            ? AppTheme.ok.withValues(alpha: 0.14)
            : AppTheme.dim.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        ok ? '可播放' : '已离线',
        style: TextStyle(
          color: ok ? AppTheme.ok : AppTheme.muted,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
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
        errorBuilder: (_, __, ___) => _posterFallback(e),
      );
    }
    return _posterFallback(e);
  }

  Widget _posterFallback(DiaryEntry e) {
    return Container(
      color: AppTheme.panel2,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      child: Text(
        e.title,
        maxLines: 3,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppTheme.muted, fontSize: 11),
      ),
    );
  }

  Widget _empty(bool filtered) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.auto_stories_rounded, size: 48, color: AppTheme.dim),
            const SizedBox(height: 16),
            Text(
              filtered ? '这个筛选条件下没有日记' : '还没有追完的剧',
              style: const TextStyle(color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              filtered ? '试试清除筛选条件' : '看完一部剧的 80%，它会自动出现在这里',
              style: const TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
            if (!filtered) ...[
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: () => context.go('/library'),
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.accent),
                child: const Text('去媒体库'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 把 `e.rating` 的「半星」显示封装给外部复用（评分详情页也用星条）。
Widget diaryStarsRow(DiaryEntry e) => StarRating(
      rating: e.rating,
      onChanged: (_) {},
      size: 22,
      showLabel: true,
    );
