import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_work.dart';
import '../../domain/services/work_merge_planner.dart';
import '../../domain/services/work_merge_service.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import 'merge_target_row.dart';

/// **手动归一**：把当前这一部并到库里另一部作品上。
///
/// ## 为什么自动归一不够，必须有这条通道
///
/// 自动那条路（`WorkMergeService.mergeAll`）**只认 `onlineId`** —— 而且这个
/// 克制是对的：按片名模糊匹配正是 `182.格力空调` 那次事故的形态（纯数字前缀
/// 把「182」和「1821」认成一部）。但代价是三种情况它永远处理不了：
///
///   1. **本地片名差异大**：`流浪地球2` 与 `The.Wandering.Earth.II.2023`
///      是两部片子，只有人知道它们是同一部；
///   2. **压根没刮到**（没配源、或刮削失败）—— 两行都没有 `onlineId`；
///   3. **刮到了两个不同条目**，但其实还是同一部（豆瓣的电视剧 / 电影分列、
///      TMDB 的重映条目）。
///
/// 所以自动那侧的正确行为是**认输**，然后把决定权交给人：这个对话框。
///
/// ## 方向：选中哪一部，就留下哪一部
///
/// 按钮写的是「合并**到**…」，所以列表里留下的是**用户选中的那一部**，
/// 当前这一部变成别名行（从列表与角标里消失，行与文件全部保留）。
/// 这个方向在确认行里写得很直白（`《当前》→《目标》`）—— 反过来理解一次
/// 的代价是「用户想留的那部不见了」，而那正是必须写清楚的原因。
///
/// ## 四个交互决定
///
///   1. **搜索框预填当前片名，但不预搜也不限制。** 和「手动刮削」那个
///      对话框刻意相反：那边每次搜索要花一次豆瓣额度，所以打开时不搜；
///      这里是**纯本地内存过滤**，零成本，所以一打开就把候选摆出来。
///   2. **零匹配时给的不是「没找到」，而是「怎么找到」** —— 这一条通道
///      最常见的用法恰恰是「两个片名完全不一样」，所以空结果时明确写着
///      「把搜索框清空可以看到全部 N 部作品」，而不是让人以为库里没有。
///   3. **选中之后还要再点一次「合并到《目标》」**，点候选行只是选中。
///      合并会改掉两部作品在列表里的可见性，不该在用户只是「看看有哪些」
///      的时候发生。
///   4. **不能合的情况在点之前就说清楚**：判据全在
///      [WorkMergePlanner.manualBlocker]（纯函数、有单测），按钮变灰并把
///      原因写在旁边。等用户点了才弹错误，看起来就像应用坏了。
///
/// ## 撤销在哪
///
/// 合并后当前页会跟着 `mergedInto` 跳到目标作品，而目标页上有一条常驻的
/// 「已并入《X》／拆开」提示条（`_MergedSourcesBanner`）。调用方另外再弹一条
/// 带「撤销」的 SnackBar —— 那条只是**即时反馈**，不是唯一的退路。
class MergeWorkDialog extends ConsumerStatefulWidget {
  const MergeWorkDialog({super.key, required this.work});

  /// 要被并走的那一部（用户当前正在看的）。
  final MediaWork work;

  /// 打开对话框。返回非 `null` = 合并成功，调用方据此提示与刷新。
  static Future<WorkMergeResult?> show(
    BuildContext context,
    MediaWork work,
  ) {
    return showDialog<WorkMergeResult>(
      context: context,
      // 合并会改数据，点外面关掉太容易误触。
      barrierDismissible: false,
      builder: (_) => MergeWorkDialog(work: work),
    );
  }

  @override
  ConsumerState<MergeWorkDialog> createState() => _MergeWorkDialogState();
}

class _MergeWorkDialogState extends ConsumerState<MergeWorkDialog> {
  /// 候选上限。库大时一次铺几千行会卡；配合搜索框足够用。
  static const int _maxShown = 60;

  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _busy = false;

  /// 全库作品（含别名行）。一次读全，之后筛选都在内存里 —— 合并不改
  /// 数据源，不需要每次输入都查库。
  List<MediaWork> _all = const [];

  String? _selectedKey;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 预填当前片名：绝大多数合并都是「同一个名字的两个版本」，这一下就
    // 把候选缩到几条。**不是**限制 —— 用户清空就能看到全部。
    _searchCtrl.text = widget.work.title.trim();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final all = await ref.read(mediaRepositoryProvider).allWorks();
      if (!mounted) return;
      setState(() {
        _all = all;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取作品列表失败：$e';
      });
    }
  }

  /// 当前这一部**自己折进了谁**。非空时整个对话框不给合（会成链）。
  List<MediaWork> get _foldedIntoMe =>
      _all.where((w) => w.mergedInto == widget.work.key).toList();

  /// 合并前的拦截原因（`null` = 可以合）。
  ///
  /// 与 `WorkMergeService.mergeInto` 用的是**同一个**判据函数 —— 按钮亮着
  /// 却点了没反应，是最让人以为应用坏了的那种失败。
  String? _blockerFor(MediaWork target) => WorkMergePlanner.manualBlocker(
        source: widget.work,
        target: target,
        all: _all,
      );

  /// 候选：排除自己与别名行，再按搜索词过滤。
  List<MediaWork> get _candidates {
    final q = _searchCtrl.text.trim().toLowerCase();
    final pool = _all
        .where((w) => w.key != widget.work.key && !w.isMergedAway)
        .toList();

    if (q.isEmpty) {
      // 清空搜索 = 「我就要看全部」。按文件数排，让「那一部有 60 集的」
      // 浮在上面 —— 用户要找的往往正是它。
      pool.sort((a, b) {
        final byCount = b.itemCount.compareTo(a.itemCount);
        return byCount != 0 ? byCount : a.title.compareTo(b.title);
      });
      return pool;
    }

    final hits = pool.where((w) {
      if (w.title.toLowerCase().contains(q)) return true;
      final orig = w.originalTitle;
      return orig != null && orig.toLowerCase().contains(q);
    }).toList();
    // 命中数相同时让「文件多的」在前：合并的目标通常是内容更全的那一部。
    hits.sort((a, b) {
      final byCount = b.itemCount.compareTo(a.itemCount);
      return byCount != 0 ? byCount : a.title.compareTo(b.title);
    });
    return hits;
  }

  MediaWork? get _selected {
    final key = _selectedKey;
    if (key == null) return null;
    for (final w in _all) {
      if (w.key == key) return w;
    }
    return null;
  }

  Future<void> _merge() async {
    final target = _selected;
    if (target == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await WorkMergeService(
      library: ref.read(mediaRepositoryProvider),
    ).mergeInto(targetKey: target.key, sourceKey: widget.work.key);

    if (!mounted) return;
    if (result == null) {
      // 到这一步才失败只有一种可能：期间库变了（另一处合并 / 重扫把它挪走）。
      setState(() {
        _busy = false;
        _error = '这次没合上 —— 库里的作品刚刚变过，关掉重开一次再试。';
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.line, width: 0.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1),
            Flexible(child: _body()),
            const Divider(height: 1),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final folded = _foldedIntoMe.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.merge_type_rounded,
              size: 18,
              color: AppTheme.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '合并到…',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '把《${widget.work.title}》并到另一部作品上，'
                  '列表里只留下选中的那一部。合并不会删文件，'
                  '随时可以在目标作品页点「拆开」。',
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.65,
                    color: AppTheme.muted,
                  ),
                ),
                if (folded > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '⚠️ 《${widget.work.title}》自己已经并入了 $folded 部作品，'
                    '先回到它的详情页点「拆开」，再回来合并。',
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.65,
                      color: AppTheme.warn,
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            iconSize: 17,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final candidates = _candidates;
    final shown = candidates.take(_maxShown).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchCtrl,
            enabled: !_busy,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
            decoration: InputDecoration(
              isDense: true,
              labelText: '找目标作品',
              labelStyle: const TextStyle(fontSize: 12, color: AppTheme.muted),
              hintText: '片名的一部分即可，中英文都行',
              hintStyle: const TextStyle(fontSize: 11, color: AppTheme.dim),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 16,
                color: AppTheme.muted,
              ),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空',
                      iconSize: 15,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _busy
                          ? null
                          : () => setState(_searchCtrl.clear),
                    ),
              filled: true,
              fillColor: AppTheme.panel2,
              contentPadding: const EdgeInsets.fromLTRB(11, 13, 11, 13),
              border: _fieldBorder(AppTheme.line, 0.5),
              enabledBorder: _fieldBorder(AppTheme.line, 0.5),
              focusedBorder: _fieldBorder(AppTheme.accent, 0.8),
              disabledBorder: _fieldBorder(AppTheme.line, 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _searchCtrl.text.trim().isEmpty
                ? '共 ${candidates.length} 部作品，按文件数排'
                    '${candidates.length > _maxShown ? "（只列出前 $_maxShown 部，输入片名可以筛）" : ""}。'
                : (candidates.isEmpty
                    ? '没有标题匹配的作品。'
                    : '${candidates.length} 部匹配'),
            style: const TextStyle(fontSize: 11, color: AppTheme.dim),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 14,
                  color: AppTheme.warn,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.65,
                      color: AppTheme.warn,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          ..._results(candidates, shown),
        ],
      ),
    );
  }

  List<Widget> _results(List<MediaWork> candidates, List<MediaWork> shown) {
    if (candidates.isEmpty) {
      // 空结果**不是死路**：清空搜索就能看到全部。这一句必须写出来 ——
      // 这条通道最常见的用法恰恰是「两个片名完全不一样」，用户在这里
      // 最容易的结论是「库里根本没有那一部」。
      final total = _all.where((w) => !w.isMergedAway).length - 1;
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: Text(
              '把上面的搜索框清空，可以看到全部 $total 部作品。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.7,
                color: AppTheme.muted,
              ),
            ),
          ),
        ),
      ];
    }

    return [
      for (final w in shown)
        Builder(
          builder: (context) {
            final blocked = _blockerFor(w);
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: MergeTargetRow(
                work: w,
                selected: w.key == _selectedKey,
                blockedReason: blocked,
                // 不能合的行**直接不可点**：让用户选中一个马上会被
                // 底部那行红字否掉的目标，是最没必要的一次往返。
                onTap: (_busy || blocked != null)
                    ? null
                    : () => setState(() => _selectedKey = w.key),
              ),
            );
          },
        ),
    ];
  }

  Widget _footer() {
    final target = _selected;
    final blocked = target == null ? null : _blockerFor(target);
    final canMerge = target != null && blocked == null && !_busy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              blocked ??
                  (target == null
                      ? '还没选目标作品。'
                      : '《${widget.work.title}》→《${target.title}》'
                          '，列表里保留后者。'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: blocked != null
                    ? AppTheme.warn
                    : (target == null ? AppTheme.dim : AppTheme.muted),
              ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消', style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: canMerge ? _merge : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: _busy
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '合并',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
          ),
        ],
      ),
    );
  }

  static OutlineInputBorder _fieldBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
}
