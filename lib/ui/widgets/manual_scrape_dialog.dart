import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/filename_parser.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/work_scraper.dart';
import '../providers/app_providers.dart';
import '../providers/scrape_providers.dart';
import '../theme/app_theme.dart';

/// **手动刮削**：自己敲片名 → 从候选里挑一条 → 确认更新。
///
/// ## 为什么自动刮削不够，必须有这条通道
///
/// 2026-10-01 实测的事故：目录名
/// `超z级z马z力z欧z银z河z大z电影aa(2026) 4K HDR & Dv`（真名《超级马力欧
/// 银河大电影》）被刮成了 **《低俗小说》(1994)**。发布组为了让分享链接
/// 不被关键词过滤，会在片名里插分隔字符（这里每个字之间塞了个 `z`）；
/// 也有的干脆只留 `2026.2160p.WEB-DL.mkv`。
///
/// 这种输入**任何自动算法都救不回来** —— 连人都得先知道「这串东西其实是
/// 《超级马力欧银河大电影》」才可能搜对。所以自动那侧的正确行为是
/// **认输**（匹配闸门拦下、按未命中处理，见 `scrape_match.dart`），
/// 然后把决定权交给人：这个对话框。
///
/// ## 三个交互决定
///
///   1. **预填的是「文件名解析出来的词」，不是库里已存的标题。**
///      库里那个可能是上一次刮错的结果（`低俗小说`），用户得先意识到
///      「这个框里是错的」才会去改；而预填解析原文
///      （`超z级z马z力z欧z银z河z大z电影aa`）反而直接展示了「自动刮削
///      拿着这么个词去搜」，用户一眼就知道该删掉那些 `z`。
///   2. **打开时不自带一次搜索。** 豆瓣的额度按**搜索词**计，匿名只有
///      约 10 个；预填的那个词正是自动刮削刚搜失败的那一个，替他再花
///      一次额度毫无价值。宁可让用户改完再点「搜索」。
///   3. **选中之后还要再点一次「用这一条更新」**，点候选行只是选中。
///      这是「确认」那一步 —— 刮削会覆盖标题、年份、海报、简介，
///      不该在用户只是「看看有哪些候选」的时候发生。
class ManualScrapeDialog extends ConsumerStatefulWidget {
  const ManualScrapeDialog({super.key, required this.work});

  final MediaWork work;

  /// 打开对话框。返回 `true` = 用户应用了一条候选（调用方据此决定要不要
  /// 再提示一次；列表刷新由控制器负责）。
  static Future<bool> show(BuildContext context, MediaWork work) async {
    final applied = await showDialog<bool>(
      context: context,
      // 刮削是「改数据」的操作，点外面关掉太容易误触 —— 而且用户可能
      // 已经把片名敲了一半。
      barrierDismissible: false,
      builder: (_) => ManualScrapeDialog(work: work),
    );
    return applied ?? false;
  }

  @override
  ConsumerState<ManualScrapeDialog> createState() => _ManualScrapeDialogState();
}

class _ManualScrapeDialogState extends ConsumerState<ManualScrapeDialog> {
  final _titleCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();

  MediaKind _kind = MediaKind.movie;

  /// 预填还没读完。读完之前输入框是灰的，免得用户敲到一半被覆盖。
  bool _prefilling = true;

  bool _searching = false;
  bool _applying = false;

  /// `null` = 还没搜过（与「搜过但零结果」是两件事，文案不同）。
  List<ScrapeCandidate>? _candidates;

  ScrapeCandidate? _selected;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  Future<void> _prefill() async {
    // 解析不出来不是错误 —— 退回用库里已有的标题，用户自己改。
    final q = await ref.read(workScraperProvider).queryFor(widget.work);
    if (!mounted) return;

    final kind = q?.kind ?? widget.work.kind;
    setState(() {
      _titleCtrl.text = (q?.title ?? widget.work.title).trim();
      final year = q?.year ?? widget.work.year;
      _yearCtrl.text = year?.toString() ?? '';
      // 下拉里只有电影 / 剧集两档：`unknown` 时按电影搜（TMDB 与豆瓣的
      // 搜索接口都要求二选一，而「认不出类型」的片子绝大多数是电影）。
      _kind = kind == MediaKind.episode ? MediaKind.episode : MediaKind.movie;
      _prefilling = false;
    });
  }

  Future<void> _search() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '片名不能为空。');
      return;
    }

    final query = ScrapeQuery(
      title: title,
      kind: _kind,
      year: int.tryParse(_yearCtrl.text.trim()),
    );

    setState(() {
      _searching = true;
      _error = null;
      // 清掉上一轮的结果与选中：留着旧列表会让用户误以为新搜索
      // 「结果一样」，而其实他改的就是片名。
      _candidates = null;
      _selected = null;
    });

    final found = await ref.read(workScraperProvider).searchCandidates(query);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _candidates = found;
    });
  }

  Future<void> _apply() async {
    final candidate = _selected;
    if (candidate == null) return;

    setState(() {
      _applying = true;
      _error = null;
    });

    final outcome = await ref
        .read(workScrapeControllerProvider.notifier)
        .applyCandidate(widget.work.key, candidate);

    if (!mounted) return;

    if (outcome != null && outcome.status == WorkScrapeStatus.scraped) {
      Navigator.of(context).pop(true);
      return;
    }

    // 失败就留在对话框里，让用户换一条再试 —— 关掉的话他还得重新敲片名。
    //
    // 文案直接取 `outcome.message`：它按**通道**分说法，手动通道那一句是
    // 「这一条解析不出完整信息…换一条候选再试」，正好是这里该说的话。
    // （曾经两个通道共用一句「在线源都没有找到匹配的条目」，用户明明刚看到
    // 一列候选，却被告知没找到条目。）
    //
    // `outcome == null` 不是「没找到」，而是**根本没跑**：作品已经不在库里，
    // 或另一个刮削正占着 `runningKey`。这时退回一句与原因无关的通用提示。
    setState(() {
      _applying = false;
      _error = outcome?.message ?? '更新失败，请换一条候选再试。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _searching || _applying;

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
            Flexible(child: _body(busy)),
            const Divider(height: 1),
            _footer(busy),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.manage_search_rounded,
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
                  '手动刮削',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '自己敲片名搜，从结果里挑一条。'
                  '文件名被发布组打散、插字符时（例如 '
                  '超z级z马z力z欧z银z河z大z电影aa），自动刮削认不出来，'
                  '这里可以手动指定。',
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
            onPressed: _applying ? null : () => Navigator.of(context).pop(false),
            iconSize: 17,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _body(bool busy) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _field(
                  controller: _titleCtrl,
                  label: '片名',
                  hint: '只留片名，去掉年份、分辨率与发布组信息',
                  enabled: !_prefilling && !busy,
                  autofocus: true,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 84,
                child: _field(
                  controller: _yearCtrl,
                  label: '年份',
                  hint: '可留空',
                  enabled: !_prefilling && !busy,
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 10),
              _kindPicker(busy),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: FilledButton(
                  onPressed: (_prefilling || busy) ? null : _search,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _searching
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '搜索',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '提示：年份留空能搜到更多候选（TMDB 的年份是硬过滤，'
            '填错会把正主直接筛掉）。',
            style: TextStyle(fontSize: 11, height: 1.6, color: AppTheme.dim),
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
          const SizedBox(height: 14),
          _results(),
        ],
      ),
    );
  }

  Widget _results() {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
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
    if (candidates == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: Text(
            '改好片名，点「搜索」看候选。',
            style: TextStyle(fontSize: 12, color: AppTheme.dim),
          ),
        ),
      );
    }

    if (candidates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            '没有候选。换个更短、更常见的词再试 —— '
            '比如只留片名主体，去掉副标题。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.7,
              color: AppTheme.muted,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${candidates.length} 条候选 · 点一条选中',
          style: const TextStyle(fontSize: 11, color: AppTheme.dim),
        ),
        const SizedBox(height: 8),
        for (final c in candidates)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _CandidateRow(
              candidate: c,
              selected: identical(c, _selected),
              onTap: _applying ? null : () => setState(() => _selected = c),
            ),
          ),
      ],
    );
  }

  Widget _footer(bool busy) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _selected == null
                  ? '还没选候选。'
                  : '将更新为「${_selected!.title}」'
                      '${_selected!.year == null ? "" : "（${_selected!.year}）"}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: _selected == null ? AppTheme.dim : AppTheme.muted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _applying ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: (_selected == null || busy) ? null : _apply,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: _applying
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '用这一条更新',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool enabled,
    bool autofocus = false,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: AppTheme.muted),
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11, color: AppTheme.dim),
        filled: true,
        fillColor: AppTheme.panel2,
        contentPadding: const EdgeInsets.fromLTRB(11, 13, 11, 13),
        border: _fieldBorder(AppTheme.line, 0.5),
        enabledBorder: _fieldBorder(AppTheme.line, 0.5),
        focusedBorder: _fieldBorder(AppTheme.accent, 0.8),
        disabledBorder: _fieldBorder(AppTheme.line, 0.5),
      ),
    );
  }

  Widget _kindPicker(bool busy) {
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: AppTheme.panel2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.line, width: 0.5),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<MediaKind>(
            value: _kind,
            isDense: true,
            dropdownColor: AppTheme.panel2,
            borderRadius: BorderRadius.circular(8),
            style: const TextStyle(
              fontSize: 12.5,
              color: AppTheme.text,
              fontFamily: AppTheme.fontFamily,
            ),
            icon: const Icon(
              Icons.expand_more_rounded,
              size: 16,
              color: AppTheme.muted,
            ),
            items: const [
              DropdownMenuItem(value: MediaKind.movie, child: Text('电影')),
              DropdownMenuItem(value: MediaKind.episode, child: Text('剧集')),
            ],
            onChanged: busy ? null : (v) => setState(() => _kind = v ?? _kind),
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _fieldBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
}

/// 一条候选。
///
/// 三种信息按「判断这部片子对不对」的权重排：**缩略图 > 标题 > 副标题**。
/// 简介只留一行 —— 它有用，但十条候选的完整简介会把列表撑到要滚很久。
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.candidate,
    required this.selected,
    required this.onTap,
  });

  final ScrapeCandidate candidate;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accent.withValues(alpha: 0.13)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? AppTheme.accent : AppTheme.line,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CandidateThumb(
              url: candidate.posterUrl,
              cacheKey: 'candidate-${candidate.source}-${candidate.sourceId}',
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          candidate.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.text,
                          ),
                        ),
                      ),
                      if (selected)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 15,
                            color: AppTheme.accent,
                          ),
                        ),
                    ],
                  ),
                  if (candidate.originalTitle != null &&
                      candidate.originalTitle!.isNotEmpty &&
                      candidate.originalTitle != candidate.title) ...[
                    const SizedBox(height: 2),
                    Text(
                      candidate.originalTitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.muted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    candidate.subtitle,
                    style: const TextStyle(fontSize: 10.5, color: AppTheme.dim),
                  ),
                  if ((candidate.overview ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      candidate.overview!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: AppTheme.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 候选缩略图。
///
/// 复用 [PosterCache]（和海报墙同一个缓存目录、同一套下载逻辑）：
/// 豆瓣的图必须带 `Referer`，而那个请求头是由缓存层的 `headersFor`
/// 回调按域名给的 —— 走 `Image.network` 就得把「哪家图要什么头」这件事
/// 复制一份到这里。
///
/// ⚠️ 这里只是**看一眼是不是这部片子**。落库的海报由 `resolve()` 重新取，
/// 豆瓣那条 120px 横条永远不会进库。
class _CandidateThumb extends ConsumerStatefulWidget {
  const _CandidateThumb({required this.url, required this.cacheKey});

  final String? url;
  final String cacheKey;

  @override
  ConsumerState<_CandidateThumb> createState() => _CandidateThumbState();
}

class _CandidateThumbState extends ConsumerState<_CandidateThumb> {
  static const double _width = 46;
  static const double _height = 69;

  String? _path;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_CandidateThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      setState(() {
        _path = null;
        _resolved = false;
      });
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final url = widget.url;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _resolved = true);
      return;
    }
    final path = await ref
        .read(posterCacheProvider)
        .pathFor(key: widget.cacheKey, url: url);
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
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        width: _width,
        height: _height,
        child: path == null
            ? ColoredBox(
                color: AppTheme.panel2,
                child: _resolved
                    ? const Icon(
                        Icons.image_not_supported_outlined,
                        size: 15,
                        color: AppTheme.dim,
                      )
                    : null,
              )
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                // 图片文件可能被清缓存删掉、或解码失败 —— 退成占位而不是
                // 让整个候选列表抛异常。
                errorBuilder: (_, __, ___) => const ColoredBox(
                  color: AppTheme.panel2,
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 15,
                    color: AppTheme.dim,
                  ),
                ),
              ),
      ),
    );
  }
}
