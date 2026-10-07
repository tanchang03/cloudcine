import 'package:flutter/material.dart';

import '../../domain/services/work_merge_suggester.dart';
import '../theme/app_theme.dart';
import 'tv_text.dart';

/// 「要把《源》并入《目标》吗？」—— 发现跑完之后那一次**主动追问**。
///
/// ## 为什么需要它，而不是让用户自己去列表里找
///
/// 2026-10-07 现场：用户在一个剧的目录里发现了一个新子目录，47 集全进了库、
/// 作品数也涨了，但那 47 集自成了一部新作品 —— 而它在「最近播放」排序里
/// 排在 30 部剧集的**最底下**，标题还被发布者插了 `z.` 规避过滤
/// （《兰z 香z 如z 故 去头去尾版》），用户在列表里根本认不出它。
/// 结果就是「提示说发现了新媒体文件，可我哪儿都没看到」。
///
/// 所以这个对话框要做的事情只有一件：**把那条已经成立、但用户看不出来的
/// 关系说出来**，并给一个一步到位的动作。
///
/// ## 三个刻意的设计
///
///   1. **必须用户点确认才落库**。归组判据救不回来的东西（片名被插字符、
///      目录名带「去头去尾版」这种版本后缀），任何自动算法都会合错 ——
///      这个对话框存在的意义正是「不自动」。所以它只问，不做。
///   2. **把两个目录都写出来**。用户判断「是不是同一部」靠的是
///      「哦，那是我上周放进《兰香如故》里的那个版本」—— 目录路径是他
///      唯一能核对的锚点。只写片名的话，两个名字都不像，他没法判断。
///   3. **说清「不会丢东西」**。合并这个动作听起来就危险（用户会以为
///      要删掉一部），所以按钮旁必须写明白：文件一个不删、随时能拆开。
///      不写的话，最需要这个功能的用户恰恰不敢点。
class MergeSuggestionDialog extends StatelessWidget {
  const MergeSuggestionDialog({
    super.key,
    required this.suggestion,
    this.remaining = 0,
  });

  final WorkMergeSuggestion suggestion;

  /// 还有几条同样的问题没问。>0 时在底部说明「处理完这条会接着问」——
  /// 否则用户点完一条又弹一条，会以为程序在循环。
  final int remaining;

  /// 打开它。返回 `true` = 用户选了「并入」。
  ///
  /// `barrierDismissible: false`：点外面关掉等于「暂不」，但用户会以为
  /// 自己还没回答 —— 而这个对话框的答案是要落库的，含糊不得。
  static Future<bool> show(
    BuildContext context,
    WorkMergeSuggestion suggestion, {
    int remaining = 0,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MergeSuggestionDialog(
        suggestion: suggestion,
        remaining: remaining,
      ),
    );
    return ok ?? false;
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
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              child: _body(),
            ),
            const Divider(height: 1),
            _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
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
                Text(
                  '要把《${suggestion.sourceTitle}》并入'
                  '《${suggestion.targetTitle}》吗？',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                    color: AppTheme.text,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  '刚才入库的这批文件自成了一部新作品，'
                  '但它们所在的目录像是另一部作品的子目录。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.65,
                    color: AppTheme.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final s = suggestion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathLine('新入库的', s.sourceDir, AppTheme.text),
        const SizedBox(height: 6),
        _pathLine('已有的', s.targetDir, AppTheme.text),
        const SizedBox(height: 14),
        Text(
          '两个名字不一样（发布者常往片名里插字符来避开关键词过滤，'
          '或加上「去头去尾版」这类版本后缀），所以被归成了两部作品。'
          '如果它们确实是同一部剧，并进来之后列表里只留'
          '《${s.targetTitle}》，共 ${s.mergedItemCount} 集。',
          style: const TextStyle(
            fontSize: 12,
            height: 1.7,
            color: AppTheme.muted,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: AppTheme.panel2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.line, width: 0.5),
          ),
          child: const Text(
            '并入不会删任何文件，也不动网盘上的目录 —— '
            '只是在媒体库里把两部合成一部，随时能在目标作品页点「拆开」恢复。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.7,
              color: AppTheme.muted,
            ),
          ),
        ),
        if (remaining > 0) ...[
          const SizedBox(height: 12),
          Text(
            '还有 $remaining 组类似的情况，处理完这一条会接着问。',
            style: const TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: AppTheme.dim,
            ),
          ),
        ],
      ],
    );
  }

  Widget _pathLine(String label, String path, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
          ),
        ),
        Expanded(
          // ⚠️ 必须是 `TvSelectableText` 而不是裸的 `SelectableText`：
          // 后者自带可聚焦的 `FocusNode`，在电视上会把 D-pad **卡死在这段
          // 路径上**，下面的「暂不 / 并入」按钮永远够不着（见 `tv_text.dart`
          // 里那次实测）。桌面/手机上仍然可划选带走。
          child: TvSelectableText(
            path,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: color),
          ),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final s = suggestion;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              foregroundColor: AppTheme.muted,
            ),
            child: const Text('暂不', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            child: Text(
              '并入《${s.targetTitle}》',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
