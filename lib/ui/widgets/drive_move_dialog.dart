import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/drive_entry.dart';
import '../../domain/services/drive_move.dart';
import '../providers/drive_browse_providers.dart';
import '../providers/drive_move_providers.dart';
import '../theme/app_theme.dart';

/// 「要移动这 N 项吗」+ 目标目录选择 —— 批量移动的**唯一**一道确认。
///
/// ## 为什么和删除的确认框不是同一个（哪怕布局很像）
///
/// 两边的后果方向相反：删除**不可逆**，所以那边最重的一句是「删了回不来」；
/// 移动**可逆**（再移回去就是），但最常见的失误是**移错目录** —— 而移错
/// 之后用户得先找到它到底去哪儿了。所以这个框的重心是「**目标目录**」：
/// 它出现在正文里、出现在确认按钮上，并且预选最近用过的那一个。
///
/// ## 预选最近用过的目录是刻意的
///
/// 「整理网盘」的真实节奏是**反复的**：把这一批散片移进「待整理」、再把
/// 那一批移进「电影」，中间要来回进出好几个目录。每次都从头点五层目录，
/// 找目录反而成了主要成本。所以第二次开始应该是一路回车。
///
/// 代价是「用户没看就按了确认」。两道防线：确认按钮上**写着目标路径**
/// （不是只写「确定」），并且正文里那一行把「从哪来 → 到哪去」摊开。
class DriveMoveDialog extends ConsumerStatefulWidget {
  const DriveMoveDialog({
    super.key,
    required this.entries,
    required this.sourceDirPath,
  });

  /// 用户勾选的那些条目（可能既有目录也有文件）。
  final List<DriveEntry> entries;

  /// 这些条目**现在**所在目录的展示路径。见 `DriveMovePlan.sourceDirPath`。
  final String sourceDirPath;

  /// 最多摊开几个名字。比删除那边少两个 —— 这里还要给「目标目录」那一块
  /// 留出位置，而目标才是这个框真正要用户看的东西。
  static const int previewLimit = 5;

  /// 弹出选择框。返回选好的计划；`null` / 取消都是不动。
  static Future<DriveMovePlan?> show(
    BuildContext context, {
    required List<DriveEntry> entries,
    required String sourceDirPath,
  }) {
    return showDialog<DriveMovePlan>(
      context: context,
      builder: (_) => DriveMoveDialog(
        entries: entries,
        sourceDirPath: sourceDirPath,
      ),
    );
  }

  @override
  ConsumerState<DriveMoveDialog> createState() => _DriveMoveDialogState();
}

class _DriveMoveDialogState extends ConsumerState<DriveMoveDialog> {
  /// 用户**显式**选过的目标；`null` = 还没选（此时用最近记录里的第一个）。
  MoveTarget? _picked;

  /// 非空表示正在「浏览目录」这一步，栈顶是当前所在目录。
  ///
  /// 用栈而不是只存一个 crumb：用户在对话框里也要能退回上一层，
  /// 而「上一层」在网盘接口里只能靠记住走过的路才知道。
  List<DriveCrumb>? _stack;

  /// 当前生效的目标。
  ///
  /// ⚠️ 写成「`_picked` 为空就取最近记录的第一个」，而**不是**在
  /// `initState` 里把最近记录写进 state：最近记录是异步读出来的，
  /// 写 state 的话「读得慢」会表现成「预选偶尔不生效」—— 一个只在冷启动
  /// 时复现、而且看起来像随机的问题。
  MoveTarget? _effective(List<MoveTarget> recents) =>
      _picked ?? (recents.isEmpty ? null : recents.first);

  DriveMovePlan _planFor(MoveTarget target) => DriveMovePlan(
        entries: widget.entries,
        sourceDirPath: widget.sourceDirPath,
        target: target,
      );

  /// 内容区的固定宽度。
  ///
  /// ## 为什么必须是**固定**的（而不是 `maxWidth`）
  ///
  /// `AlertDialog` 会把 `content` 包进 `IntrinsicWidth` 量一次宽度。而
  /// 「浏览目录」那一屏里有 `ListView(shrinkWrap: true)` —— 它的渲染对象是
  /// `RenderShrinkWrappingViewport`，**拒绝提供 intrinsic 尺寸**（惰性列表
  /// 要算 intrinsic 就得把每个子项都建出来，那正是视口要避免的事）。
  ///
  /// 结果不是「宽一点窄一点」，而是抛
  /// `RenderShrinkWrappingViewport does not support returning intrinsic
  /// dimensions` —— 用户点「选择其他目录」时整个对话框白屏。
  ///
  /// 给一个**确定**宽度，量尺寸那一步就不会再往下问：`SizedBox` 在
  /// 宽度既紧又有界时直接把它当答案返回。
  ///
  /// ## 顺带解决的一个毛病
  ///
  /// 宽度由内容撑的话，对话框会在「选目标」和「浏览目录」两屏之间**变宽
  /// 变窄**（两屏的按钮文案长度不同：`移动到 X` / `选定「X」`），看起来
  /// 像弹窗被换掉了。固定住之后它只是内容在换。
  static double _contentWidth(BuildContext context) =>
      math.min(460, MediaQuery.sizeOf(context).width - 96);

  void _openBrowser() {
    // 根目录直接从主浏览栈上拿第一格 —— 那就是适配器给的 rootId，
    // 不必在这里再问一次适配器（两处取根会有取歪的可能）。
    setState(() => _stack = [ref.read(driveBrowseProvider).first]);
  }

  void _choose(DriveCrumb crumb) {
    setState(() {
      _picked = MoveTarget(
        fid: crumb.id,
        name: crumb.name,
        path: crumb.path,
      );
      _stack = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final recentsAsync = ref.watch(moveTargetsProvider);
    final recents = recentsAsync.valueOrNull ?? const <MoveTarget>[];
    final target = _effective(recents);
    final plan = target == null ? null : _planFor(target);
    final invalid = plan?.invalidTargetReason();
    final stack = _stack;

    return AlertDialog(
      backgroundColor: AppTheme.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.line),
      ),
      title: Row(
        children: [
          const Icon(Icons.drive_file_move_outlined,
              size: 20, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              DriveMovePlan.titleFor(widget.entries.length),
              style: const TextStyle(fontSize: 15),
            ),
          ),
        ],
      ),
      content: SizedBox(
        // 固定宽度，理由见 [_contentWidth] —— 不只是为了好看：宽度不定的话
        // 「浏览目录」那一屏会因为里面的 `ListView` 拒绝提供 intrinsic 尺寸
        // 而直接抛异常，整个对话框白屏。
        width: _contentWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              stack == null
                  ? _pickView(
                      recents: recents,
                      loading: recentsAsync.isLoading && recents.isEmpty,
                      target: target,
                      plan: plan,
                      invalid: invalid,
                    )
                  : _browseView(stack),
            ],
          ),
        ),
      ),
      actions: stack == null
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                // 没选目标、或目标不合法（移进自己的子目录 / 已经在里面）
                // 时置灰。判据来自 `DriveMovePlan.invalidTargetReason`，
                // 控制器发请求前会**再拦一道** —— 界面这道只是省得用户
                // 白按一次。
                onPressed: (plan == null || invalid != null)
                    ? null
                    : () => Navigator.of(context).pop(plan),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                ),
                child: Text(
                  plan == null ? '请选择目标目录' : plan.confirmLabel,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ]
          : [
              TextButton(
                onPressed: () => setState(() => _stack = null),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => _choose(stack.last),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accent,
                ),
                child: Text(
                  '选定「${stack.last.isRoot ? '我的网盘' : stack.last.name}」',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
    );
  }

  // -------------------------------------------------------------------
  // 选目标
  // -------------------------------------------------------------------

  Widget _pickView({
    required List<MoveTarget> recents,
    required bool loading,
    required MoveTarget? target,
    required DriveMovePlan? plan,
    required String? invalid,
  }) {
    final folderNote =
        DriveMovePlan.folderNoteFor(widget.entries.where((e) => e.isDirectory).length);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _preview(),
        if (folderNote != null) ...[
          const SizedBox(height: 8),
          _note(Icons.info_outline_rounded, folderNote, AppTheme.muted),
        ],
        const SizedBox(height: 16),
        const Text(
          '目标目录',
          style: TextStyle(
            fontSize: 11.5,
            color: AppTheme.dim,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        // ① 当前目标：把「从哪来 → 到哪去」摊开。这是用户核对的主要位置。
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.panel2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: invalid == null
                  ? AppTheme.accent.withValues(alpha: 0.35)
                  : AppTheme.warn.withValues(alpha: 0.45),
              width: 0.6,
            ),
          ),
          child: Row(
            children: [
              Icon(
                invalid == null
                    ? Icons.folder_special_outlined
                    : Icons.report_problem_outlined,
                size: 15,
                color: invalid == null ? AppTheme.accent : AppTheme.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan?.routeLabel ?? '还没选',
                  style: TextStyle(
                    fontSize: 12,
                    color: invalid == null ? AppTheme.text : AppTheme.warn,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (invalid != null) ...[
          const SizedBox(height: 6),
          _note(Icons.block_rounded, invalid, AppTheme.warn),
        ],
        const SizedBox(height: 12),
        // ② 最近用过的目录：这一块就是「反复移」时省下的那几次点选。
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '正在读取最近用过的目录…',
              style: TextStyle(fontSize: 11.5, color: AppTheme.dim),
            ),
          )
        else if (recents.isEmpty)
          const Text(
            '还没有用过的目录。选一次之后它就会出现在这里。',
            style: TextStyle(fontSize: 11.5, height: 1.5, color: AppTheme.dim),
          )
        else ...[
          const Text(
            '最近用过',
            style: TextStyle(
              fontSize: 11.5,
              color: AppTheme.dim,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          for (final recent in recents)
            _RecentRow(
              target: recent,
              selected: recent == target,
              onTap: () => setState(() => _picked = recent),
            ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _openBrowser,
          icon: const Icon(Icons.folder_open_rounded, size: 15),
          label: const Text('选择其他目录', style: TextStyle(fontSize: 12.5)),
        ),
        if (plan != null) ...[
          const SizedBox(height: 12),
          _note(Icons.help_outline_rounded, plan.sameNameNote, AppTheme.dim),
        ],
      ],
    );
  }

  Widget _preview() {
    final shown = widget.entries.take(DriveMoveDialog.previewLimit).toList();
    final rest = widget.entries.length - shown.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: AppTheme.panel2,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Row(
                children: [
                  Icon(
                    entry.isDirectory
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_outlined,
                    size: 13,
                    color:
                        entry.isDirectory ? AppTheme.accent : AppTheme.dim,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (rest > 0)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '…等共 ${widget.entries.length} 项',
                style: const TextStyle(fontSize: 11.5, color: AppTheme.dim),
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------
  // 浏览目录（只列子目录）
  // -------------------------------------------------------------------

  Widget _browseView(List<DriveCrumb> stack) {
    final current = stack.last;
    final listing = ref.watch(driveListingProvider(current));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              // 根目录上不能再往上 —— 置灰而不是隐藏，位置固定住，
              // 用户连点两下「上一层」时不会因为按钮消失而点到别处。
              onPressed: stack.length > 1
                  ? () => setState(
                      () => _stack = stack.sublist(0, stack.length - 1))
                  : null,
              icon: const Icon(Icons.arrow_upward_rounded, size: 17),
              tooltip: '上一层',
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Text(
                current.isRoot ? '我的网盘' : current.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.text),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 230),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.panel2,
            borderRadius: BorderRadius.circular(8),
          ),
          child: listing.when(
            data: (data) {
              if (data.folders.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 9, vertical: 12),
                  child: Text(
                    '这个目录下没有子目录。\n可以点右上角「选定」把它本身作为目标。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.6,
                      color: AppTheme.dim,
                    ),
                  ),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                itemCount: data.folders.length,
                itemBuilder: (_, i) {
                  final dir = data.folders[i];
                  return InkWell(
                    onTap: () => setState(
                      () => _stack = [...stack, current.child(dir)],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 9),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_rounded,
                              size: 14, color: AppTheme.accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              dir.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: AppTheme.text,
                              ),
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded,
                              size: 15, color: AppTheme.dim),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(
                child: SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
              child: Text(
                '读取目录失败：$e',
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: AppTheme.warn,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _note(IconData icon, String text, Color color) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.55, color: color),
            ),
          ),
        ],
      );
}

/// 「最近用过」里的一行。
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.target,
    required this.selected,
    required this.onTap,
  });

  final MoveTarget target;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 15,
              color: selected ? AppTheme.accent : AppTheme.dim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                target.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: selected ? AppTheme.text : AppTheme.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
