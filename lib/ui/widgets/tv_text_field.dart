import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// TV 安全输入框：焦点经过时不弹软键盘，只有按 OK（或点一下）才进入编辑态。
///
/// ## 为什么需要它
///
/// Android TV 上 `TextField` 一拿到焦点就建 `TextInputConnection` 弹出软
/// 键盘。设置页有 6 个自由文本框，遥控器 ↓ 一路走完会每经过一个就弹一次 ——
/// 焦点移动被键盘打断，用户根本走不到下面的开关。而键盘本身没错，
/// 错的是「只看一眼 / 路过」也要弹。
///
/// ## 行为
///
///   * 非 TV：原样就是一个 `TextField`，行为不变；
///   * TV 未编辑态：`readOnly: true`（焦点可落、可走，不建输入连接），
///     框内右端显示「按OK输入」提示；
///   * TV 上按 OK/Enter 或点一下：进入编辑态（`readOnly: false` + 重新拿
///     一次焦点把键盘叫出来）；
///   * TV 编辑态按 返回/Esc：退回只读，收键盘，焦点仍留在框上。
///
/// 构造参数与 `TextField` 对齐（controller/decoration/style/onChanged），
/// 调用方把原来的 `TextField(...)` 换成 `TvTextField(...)` 即可。
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    this.onChanged,
    this.onSaved,
    this.style,
    this.decoration,
    this.hintText,
    this.keyboardType,
    this.textInputAction = TextInputAction.done,
    this.maxLines = 1,
    this.cursorHeight,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  /// 只读态切回时（编辑结束）回调一次，调用方用来与 `_savableField` 的
  /// dirty 判据对齐。`null` 也没关系。
  final VoidCallback? onSaved;

  final TextStyle? style;
  final InputDecoration? decoration;
  final String? hintText;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final int? maxLines;
  final double? cursorHeight;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  /// 外层按键拦截用的假节点：`canRequestFocus: false` 让它不参与焦点遍历，
  // 但又能吃 `onKeyEvent`。真实焦点落在内层 TextField 的 node 上。
  late final FocusNode _keyNode = FocusNode(
    debugLabel: 'tv-text-field-key',
    canRequestFocus: false,
  );

  /// 内层真正参与焦点遍历 + 建输入连接的节点。
  late final FocusNode _focusNode;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'tv-text-field');
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _keyNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    // 焦点离开这一格 = 本次路过/编辑结束，退回只读并收键盘。
    // 不在这里调 onChanged（输入过程中已经调过），只做状态复位。
    if (!_focusNode.hasFocus && _editing) {
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      setState(() => _editing = false);
      widget.onSaved?.call();
    }
  }

  void _enterEditing() {
    if (_editing) return;
    setState(() => _editing = true);
    // readOnly 从 true 翻成 false 时，已在焦点上的节点不会自动重建
    // 输入连接 —— 先失焦再拿回，让框架重新走一遍「可编辑 + 有焦点 →
    // 打开键盘」。postFrame 里做，避免在按键回调里直接动焦点树。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusNode.requestFocus();
      });
    });
  }

  void _exitEditing() {
    if (!_editing) return;
    // 收键盘但**保留焦点**：用户按返回是想「继续往下走」，不是「焦点没了」。
    SystemChannels.textInput.invokeMethod('TextInput.hide');
    setState(() => _editing = false);
    widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tv = AppTheme.isTvLayout(context);
    if (!tv) {
      return TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        onChanged: widget.onChanged,
        style: widget.style,
        decoration: widget.decoration,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        maxLines: widget.maxLines,
        cursorHeight: widget.cursorHeight,
      );
    }

    final base = widget.decoration ??
        const InputDecoration(isDense: true, border: OutlineInputBorder());

    // 核心：只读态不建输入连接，焦点路过不弹键盘。
    // 点击/OK 进编辑态，返回/Esc 退回只读。
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      readOnly: !_editing,
      showCursor: true,
      cursorHeight: widget.cursorHeight,
      onChanged: widget.onChanged,
      onTap: _enterEditing,
      onEditingComplete: _exitEditing,
      onSubmitted: (_) => _exitEditing(),
      style: widget.style,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      maxLines: widget.maxLines,
      decoration: base.copyWith(
        suffixIcon: _editing
            ? (base.suffixIcon ??
                const Icon(Icons.keyboard_rounded, size: 18))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (base.suffixIcon != null) base.suffixIcon!,
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '按OK输入',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.accent,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
