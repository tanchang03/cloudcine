import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/media_category.dart';
import '../../domain/entities/media_work.dart';
import '../../domain/services/work_scraper.dart';
import '../providers/scrape_providers.dart';
import '../theme/app_theme.dart';

/// **自定义作品信息**：清除在线刮削信息，改用自己敲的片名与分类。
///
/// ## 它解决的是哪一类问题
///
/// 库里总有一些**不是常规影视**的东西：自制视频、演唱会、赛事、课程、
/// 家庭录像。自动刮削会拿它们的文件名去 TMDB / 豆瓣搜，然后刮到一个
/// 毫不相干的条目 —— 片名有点像、年份碰巧对得上就够了。这类错误**没法
/// 靠调算法修**：数据源里根本没有对得上的条目，任何自动流程都只能猜。
///
/// 所以出路是「退出自动流程」：把在线源留下的痕迹（海报、简介、评分、
/// 类型、年份、原始标题）全部清掉，片名与分类由人写死，并标记成
/// [ScrapeSource.manual] —— 从此重扫与扫描期自动刮削都不再碰它。
///
/// ## 三个交互决定
///
///   1. **预填当前的片名与分类。** 用户多半只是想改掉其中一处（片名对了
///      但分类不对，或者反过来），从空白开始会让他重敲一遍；
///   2. **不放在 `canScrapeOnline` 的门槛后面。** 这条路**一次网络请求
///      都不发**，是纯本地的数据修正 —— 没配 TMDB / 豆瓣的用户同样需要
///      它，而且他们才最需要：没有在线源时作品全靠文件名解析，片名常常
///      就是 `2024.2160p.WEB-DL`；
///   3. **按钮写清后果**（「清除并保存」），正文里列出会被清掉的东西。
///      这个动作会**丢掉**刮来的海报与简介，而且不可撤销。
///
/// ## 清掉的东西会自己长回来吗
///
/// 会 —— 但只从**本地**来源，这正是想要的效果：
///
///   - 海报与年份会在下次重扫时回落（网盘缩略图 / 文件名里的年份）；
///   - 在线源那张**刮错了的海报**不会回来（`mergeWorkForUpsert` 里有
///     针对 `manual` 的守卫）。
///
/// 所以正文不必吓唬用户说「海报永远没了」，如实说清「清掉在线信息、
/// 改标记」即可。
class CustomizeWorkDialog extends ConsumerStatefulWidget {
  const CustomizeWorkDialog({super.key, required this.work});

  final MediaWork work;

  /// 打开对话框。返回 `true` = 已保存。
  static Future<bool> show(BuildContext context, MediaWork work) async {
    final saved = await showDialog<bool>(
      context: context,
      // 这是「改数据」的操作，点外面关掉太容易误触 —— 而且用户可能已经
      // 把片名敲了一半。
      barrierDismissible: false,
      builder: (_) => CustomizeWorkDialog(work: work),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<CustomizeWorkDialog> createState() =>
      _CustomizeWorkDialogState();
}

class _CustomizeWorkDialogState extends ConsumerState<CustomizeWorkDialog> {
  late final TextEditingController _titleCtrl;
  late MediaCategory _category;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 预填当前值：用户多半只改一处，不该让他重敲另一处。
    _titleCtrl = TextEditingController(text: widget.work.title);
    _category = widget.work.category;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '片名不能为空。');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final outcome = await ref
        .read(workScrapeControllerProvider.notifier)
        .customize(widget.work.key, title: title, category: _category);

    if (!mounted) return;

    if (outcome != null && outcome.status == WorkScrapeStatus.customized) {
      Navigator.of(context).pop(true);
      return;
    }

    // 失败就留在对话框里，用户敲的片名还在。
    //
    // `outcome == null` 不是「保存失败」而是**根本没跑**（作品已不在库里，
    // 或另一个写操作正占着互斥位），那时退回一句与原因无关的通用提示。
    setState(() {
      _saving = false;
      _error = outcome?.message ?? '保存失败，请重试。';
    });
  }

  @override
  Widget build(BuildContext context) {
    // 已经被刮削过的作品才需要说「会清掉刮来的东西」—— 没刮过时那句话
    // 是空话，而空话会让用户以为自己的操作有额外风险。
    final scraped = widget.work.isScraped;

    return Dialog(
      backgroundColor: AppTheme.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.line, width: 0.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1),
            Flexible(child: _body(scraped)),
            const Divider(height: 1),
            _footer(),
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
              Icons.edit_outlined,
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
                  '自定义作品信息',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '自动刮削刮错了、而数据源里根本没有这部片子时（自制视频、'
                  '演唱会、赛事、课程…），在这里自己写死片名和分类。',
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
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            iconSize: 17,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _body(bool scraped) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field(
            controller: _titleCtrl,
            label: '片名',
            hint: '想怎么叫就怎么写，例如「2024 演唱会现场」',
            enabled: !_saving,
            autofocus: true,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 14),
          const Text(
            '类型',
            style: TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
          const SizedBox(height: 7),
          _categoryPicker(),
          const SizedBox(height: 14),
          _consequenceNote(scraped),
          if (_error != null) ...[
            const SizedBox(height: 12),
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
        ],
      ),
    );
  }

  /// 「点下去会发生什么」。
  ///
  /// 单独抽出来是因为它按**当前状态**分叉：已经刮过的作品要如实说明会丢掉
  /// 什么，没刮过的作品说了就是空话。
  Widget _consequenceNote(bool scraped) {
    // 用户手敲并锁住的类型标签**不会**被清掉（见 `MediaWork.customized`），
    // 所以正文里不能再把它列进「会清除」的清单 —— 那是当面撒谎：
    // 用户以为清掉了，一看标签还在，只会以为这个按钮坏了。
    final lockedGenres = widget.work.genresManual;
    final lines = <String>[
      if (scraped)
        '会清除从在线源刮来的信息：海报、简介、评分、'
            '${lockedGenres ? "年份、原始标题" : "类型、年份、原始标题"}。'
      else
        '片名与分类将完全由你说了算。',
      if (lockedGenres) '你手动编辑过的类型标签会保留 —— 它们已经被锁定，刮削本来就动不了。',
      '这部作品会被标记为「手动修改」—— 之后重新扫描与扫描期自动刮削'
          '都不会再覆盖它。',
      '想再交给在线源，点详情页的「刮削」重新查一次即可。',
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(
                    Icons.circle,
                    size: 4,
                    color: AppTheme.dim,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lines[i],
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.65,
                      color: AppTheme.muted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 12),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '这个操作不可撤销。',
              style: TextStyle(fontSize: 11.5, color: AppTheme.dim),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(fontSize: 12.5)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: _saving
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '清除并保存',
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

  /// 分类选择器。
  ///
  /// 选项取自 [MediaCategory.displayOrder]（「其他」垫底），而不是 enum 的
  /// 声明顺序 —— 两个顺序不同是**故意的**（见那边的文档），这里抄 enum
  /// 顺序会让下拉里的「其他」跑到中间，与分类栏的顺序对不上。
  Widget _categoryPicker() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.line, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<MediaCategory>(
          value: _category,
          isDense: true,
          isExpanded: true,
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
          items: [
            for (final c in MediaCategory.displayOrder)
              DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged:
              _saving ? null : (v) => setState(() => _category = v ?? _category),
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
