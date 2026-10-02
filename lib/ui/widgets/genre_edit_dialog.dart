import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/media_work.dart';
import '../providers/library_providers.dart';
import '../theme/app_theme.dart';

/// **编辑类型标签**：自己加 / 删一部作品的 `genres`。
///
/// ## 为什么自动刮削不够
///
/// 类型标签是 TMDB / 豆瓣**返回什么就存什么**，而它经常不全或不对：
///
///   - 国产综艺 / 国漫在 TMDB 上常常压根没有条目，刮到的是别的片子；
///   - 一部片子跨类型（「动画 + 科幻 + 冒险」）时，源只给一两个；
///   - 发布组把片名打散（`超z级z马z力z欧z银z河z大z电影aa`）时，
///     刮削会命中一个完全不相干的条目，连类型都是别人的。
///
/// 而类型标签有两个实打实的下游：详情页那几个 chip，以及筛选面板
/// 「类型」那一组的选项与角标。错了就是「按类型筛不到这部片」。
///
/// ## 保存之后会被锁住
///
/// 保存会同时置 `genresManual`，之后的刮削**不再覆盖**这一列 ——
/// 否则用户「为了补张海报再刮一次」就把刚改好的类型冲掉了，
/// 等于改了也白改。想交回自动判定就点「恢复自动判定」。
///
/// ## 为什么给一排常用类型
///
/// 筛选面板是**按字符串精确匹配**分组的：用户手敲「科幻片」而不是
/// 「科幻」，这部片就会自成一栏、和别的科幻片分不到一起。给一排 TMDB /
/// 豆瓣常用的写法，点一下就能加，比让他猜「官方叫什么」靠谱得多。
/// 但输入框仍然接受任意文本 —— 常用列表是便利，不是白名单。
class GenreEditDialog extends ConsumerStatefulWidget {
  const GenreEditDialog({super.key, required this.work});

  final MediaWork work;

  /// 打开对话框。返回 `true` = 用户点了保存（无论内容有没有真的变）。
  static Future<bool> show(BuildContext context, MediaWork work) async {
    final saved = await showDialog<bool>(
      context: context,
      // 用户可能已经敲了一半 —— 点外面误关掉要重敲，代价太高。
      barrierDismissible: false,
      builder: (_) => GenreEditDialog(work: work),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<GenreEditDialog> createState() => _GenreEditDialogState();
}

class _GenreEditDialogState extends ConsumerState<GenreEditDialog> {
  final _input = TextEditingController();

  /// 编辑中的副本。**不直接改 `widget.work.genres`** —— 用户在对话框里
  /// 删了几个又点「取消」，库里的不该动。
  late List<String> _genres;

  /// 「刚才那一下为什么没反应」。
  ///
  /// 加重复的类型是**唯一**会静默失败的操作：输入框清空、列表没变，
  /// 看起来像点漏了。所以这一句必须说出来。
  String? _hint;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _genres = List.of(widget.work.genres);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 加一个类型。去重（大小写不敏感地比）并去掉首尾空白。
  ///
  /// 返回是否真的加进去了 —— 用来决定要不要给「已经加过了」的提示。
  bool _add(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return false;
    if (_genres.any((g) => g.toLowerCase() == v.toLowerCase())) return false;
    setState(() => _genres.add(v));
    return true;
  }

  /// 「添加」按钮 / 回车走这里。
  ///
  /// **无论成功失败都清空输入框**：留着的话，加重复项时输入框里那几个字
  /// 还在，用户会以为自己没点到而反复点。清空 + 一句提示才说得清
  /// 「这一下确实生效了，只是它本来就在列表里」。
  void _submit() {
    final v = _input.text.trim();
    if (v.isEmpty) return;
    final added = _add(v);
    setState(() {
      _input.clear();
      _hint = added ? null : '「$v」已经在列表里了。';
    });
  }

  void _remove(String genre) {
    setState(() {
      _genres.remove(genre);
      _hint = null;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await ref
        .read(workClassificationControllerProvider)
        .setGenres(widget.work.key, _genres);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _restoreAuto() async {
    setState(() => _saving = true);
    // 传 `null` = 清掉手动标记：类型本身留着，下次刮削可以再覆盖它。
    await ref
        .read(workClassificationControllerProvider)
        .setGenres(widget.work.key, null);
    if (!mounted) return;
    Navigator.of(context).pop(true);
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
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.local_offer_outlined,
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
                  '编辑类型标签',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.work.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: AppTheme.muted),
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

  Widget _body() {
    return SingleChildScrollView(
      // ⚠️ `primary: false` 不能省：对话框的 `ScrollView` 默认会去抢
      // `PrimaryScrollController`，而外层（详情页）已经有一个在用 ——
      // 抢到的结果是**一打开就抛异常**。
      primary: false,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !_saving,
                  autofocus: true,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '添加类型',
                    labelStyle: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.muted,
                    ),
                    hintText: '例如：动画、真人秀、科幻',
                    hintStyle: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.dim,
                    ),
                    filled: true,
                    fillColor: AppTheme.panel2,
                    contentPadding: const EdgeInsets.fromLTRB(11, 13, 11, 13),
                    border: _border(AppTheme.line, 0.5),
                    enabledBorder: _border(AppTheme.line, 0.5),
                    focusedBorder: _border(AppTheme.accent, 0.8),
                    disabledBorder: _border(AppTheme.line, 0.5),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: FilledButton(
                  onPressed: _saving ? null : _submit,
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
                  child: const Text(
                    '添加',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_hint != null) ...[
            const SizedBox(height: 8),
            Text(
              _hint!,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: AppTheme.warn,
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            '当前类型',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.muted,
            ),
          ),
          const SizedBox(height: 8),
          if (_genres.isEmpty)
            const Text(
              '还没有类型。加一个，或点下面的常用类型。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: AppTheme.dim),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in _genres)
                  _RemovableChip(
                    label: g,
                    onRemove: _saving ? null : () => _remove(g),
                  ),
              ],
            ),
          const SizedBox(height: 18),
          const Text(
            '常用类型',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppTheme.muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in _commonGenres)
                if (!_genres.any((x) => x.toLowerCase() == g.toLowerCase()))
                  _AddChip(
                    label: g,
                    onTap: _saving
                        ? null
                        : () {
                            _add(g);
                            setState(() => _hint = null);
                          },
                  ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '保存后这部作品的类型会被**锁定**，重新刮削不会再覆盖它。'
            '想让刮削重新接管，点「恢复自动判定」。',
            style: TextStyle(fontSize: 11, height: 1.7, color: AppTheme.dim),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 12),
      child: Row(
        children: [
          if (widget.work.genresManual)
            TextButton(
              onPressed: _saving ? null : _restoreAuto,
              child: const Text(
                '恢复自动判定',
                style: TextStyle(fontSize: 12.5, color: AppTheme.muted),
              ),
            ),
          const Spacer(),
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
                    '保存',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: color, width: width),
      );
}

/// TMDB / 豆瓣在中文语境下常见的类型写法。
///
/// 刻意用它们**惯用的词**（「动画」而不是「动漫」、「真人秀」而不是
/// 「综艺」）：筛选面板按字符串精确分组，写法和库里其他片子对不上，
/// 这部片就会自成一栏。
const List<String> _commonGenres = [
  '动画',
  '科幻',
  '动作',
  '冒险',
  '喜剧',
  '剧情',
  '悬疑',
  '犯罪',
  '恐怖',
  '爱情',
  '奇幻',
  '战争',
  '历史',
  '纪录片',
  '真人秀',
  '脱口秀',
  '家庭',
  '音乐',
];

/// 当前类型的一个 chip，右侧带删除按钮。
class _RemovableChip extends StatelessWidget {
  const _RemovableChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.accent,
            ),
          ),
          const SizedBox(width: 2),
          // tooltip 带上是哪一个类型：一来 hover 时说得清要删掉什么，
          // 二来测试能精确点到某一个 chip 的删除键 —— 头部那个「关闭」
          // 用的是同一个图标，只按图标找会点到对话框本身。
          Tooltip(
            message: '移除「$label」',
            child: InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 12, color: AppTheme.dim),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 常用类型的一个可点 chip（点一下就加进当前类型）。
class _AddChip extends StatelessWidget {
  const _AddChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.panel2,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.line, width: 0.5),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppTheme.muted),
        ),
      ),
    );
  }
}
