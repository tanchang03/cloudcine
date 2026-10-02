import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_work.dart';
import '../../domain/services/work_merge_planner.dart';
import '../../domain/services/work_merge_service.dart';
import '../providers/app_providers.dart';
import '../theme/app_theme.dart';
import 'merge_target_row.dart';

/// **批量**人工归一：把勾选的这几部一起并到库里另一部作品上。
///
/// ## 它和 [MergeWorkDialog] 是两件事
///
/// 单部那条路是「我在看《A》，它其实是《B》」。而批量是「我勾了 5 部，它们
/// 其实都是同一部」—— 典型现场是网盘上把一部剧拆成了
/// `S01` / `S02` / `番外` / `1080P版` 四个目录，扫描后成了四部作品。
/// 让用户一部一部去点四次「合并到…」是不可接受的：每点一次都要重新搜一遍
/// 目标，而目标从头到尾都是同一部。
///
/// ## 目标可以是**被勾中的某一部**
///
/// 这是这条通道最自然的用法：勾了 5 部之后，留下的往往就是其中内容最全的
/// 那一部。所以候选列表**包含**勾选的这几部本身，`badge` 标出「在已选中」，
/// 并且排序时把它们顶到前面 —— 用户不必先想清楚「我要留哪一部」再去别处找。
///
/// 判据那一侧对应的处理在 [WorkMergePlanner.batchPlan]：目标自己出现在
/// [sources] 里时**不算被折走**，而不是报一条「不能自己并自己」。
///
/// ## 合不上的不拖累其余的
///
/// 勾选的 5 部里若有 1 部自己折着别人（会成链），正确行为是**其余 4 部照常
/// 合并**，并把那 1 部的原因写清楚 —— 不是整批失败。整批失败的表现是
/// 「我勾了 5 部，点完什么都没发生，只弹一句我没勾过的片子的错」。
class BatchMergeDialog extends ConsumerStatefulWidget {
  const BatchMergeDialog({super.key, required this.sources});

  /// 被勾选、要被并走的那一批。
  final List<MediaWork> sources;

  /// 打开对话框。返回非 `null` = 至少合并成功一部，调用方据此提示与刷新。
  static Future<WorkMergeResult?> show(
    BuildContext context,
    List<MediaWork> sources,
  ) {
    return showDialog<WorkMergeResult>(
      context: context,
      // 合并会改数据，点外面关掉太容易误触。
      barrierDismissible: false,
      builder: (_) => BatchMergeDialog(sources: sources),
    );
  }

  @override
  ConsumerState<BatchMergeDialog> createState() => _BatchMergeDialogState();
}

class _BatchMergeDialogState extends ConsumerState<BatchMergeDialog> {
  /// 候选上限。库大时一次铺几千行会卡；配合搜索框足够用。
  static const int _maxShown = 60;

  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _busy = false;

  /// 全库作品（含别名行）。一次读全，之后筛选都在内存里。
  List<MediaWork> _all = const [];

  String? _selectedKey;
  String? _error;

  /// 勾选的这部的 key —— 判「候选是不是自己人」用。
  late final Set<String> _sourceKeys = {
    for (final w in widget.sources) w.key,
  };

  @override
  void initState() {
    super.initState();
    // ⚠️ 与单部那条路**刻意相反**：这里不预填片名。批量合并时这几部的片名
    // 往往各不相同（否则它们早就是一部了），预填任何一部的名字都会把其余
    // 的候选筛掉 —— 而用户要找的目标恰恰多半在「其余」里。
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

  WorkMergeBatchPlan _planFor(MediaWork target) =>
      WorkMergePlanner.batchPlan(
        target: target,
        sources: widget.sources,
        all: _all,
      );

  /// 这一条候选能不能当目标（`null` = 能）。
  String? _blockerFor(MediaWork target) {
    final plan = _planFor(target);
    if (plan.canMerge) return null;
    if (plan.blocked.isNotEmpty) return plan.blocked.values.first;
    // 走到这里只有一种可能：勾的那一批里唯一可合的就是目标自己
    // （比如只勾了一部）。
    return '勾选的这几部里没有能并入《${target.title}》的。';
  }

  /// 候选：排除别名行，再按搜索词过滤。
  ///
  /// **不排除勾选的这几部** —— 目标常常就在它们中间（理由见类文档）。
  List<MediaWork> get _candidates {
    final q = _searchCtrl.text.trim().toLowerCase();
    final pool = _all.where((w) => !w.isMergedAway).toList();

    final hits = q.isEmpty
        ? pool
        : pool.where((w) {
            if (w.title.toLowerCase().contains(q)) return true;
            final orig = w.originalTitle;
            return orig != null && orig.toLowerCase().contains(q);
          }).toList();

    hits.sort(_byPreference);
    return hits;
  }

  /// 排序：**勾选的排最前**（目标多半就在这一批里），然后文件多的在前
  /// （合并的目标通常是内容更全的那一部），最后按片名稳定收敛。
  int _byPreference(MediaWork a, MediaWork b) {
    final aIn = _sourceKeys.contains(a.key) ? 0 : 1;
    final bIn = _sourceKeys.contains(b.key) ? 0 : 1;
    if (aIn != bIn) return aIn - bIn;

    final byCount = b.itemCount.compareTo(a.itemCount);
    if (byCount != 0) return byCount;
    return a.title.compareTo(b.title);
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
    ).mergeManyInto(
      targetKey: target.key,
      sourceKeys: [for (final w in widget.sources) w.key],
    );

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
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
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
    final n = widget.sources.length;
    final preview = widget.sources
        .take(3)
        .map((w) => '《${w.title}》')
        .join('、');
    final rest = n > 3 ? ' 等 $n 部' : '';

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
                  '把 $preview$rest 并到同一部作品上。'
                  '列表里只留下你选中的那一部，合并不会删任何文件 —— '
                  '随时可以在目标作品页点「拆开」还原。',
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.65,
                    color: AppTheme.muted,
                  ),
                ),
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
                      onPressed:
                          _busy ? null : () => setState(_searchCtrl.clear),
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
                ? '共 ${candidates.length} 部作品，勾选的排在最前'
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
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Center(
            child: Text(
              '把上面的搜索框清空，可以看到全部作品。',
              textAlign: TextAlign.center,
              style: TextStyle(
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
                badge: _sourceKeys.contains(w.key) ? '已选中' : null,
                // 不能当目标的行**直接不可点**：让用户选中一个马上会被
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

    String text;
    if (blocked != null) {
      text = blocked;
    } else if (target == null) {
      text = '还没选要留下哪一部。';
    } else {
      final plan = _planFor(target);
      final n = plan.sourceKeys.length;
      final skipped = plan.blockedCount;
      text = skipped == 0
          ? '把 $n 部并入《${target.title}》，列表里只留下后者。'
          : '把 $n 部并入《${target.title}》，列表里只留下后者。'
              '另有 $skipped 部合不了：${plan.blocked.values.first}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 4,
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
