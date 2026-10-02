/// TV 上把「可划选的文本」降级成普通文本 —— 因为它在电视上是个**焦点陷阱**。
///
/// ## 为什么必须换（实测，不是推理）
///
/// `SelectableText` 内部是 `EditableText(readOnly: true)`，而 `EditableText`
/// 自带一个 `FocusNode`，并且 `canRequestFocus == true`。于是遥控器的 D-pad 会
/// **停在它上面**：
///
/// 实测（`test/ui/tv_remote_probe_test.dart`）在它上下各放一个按钮，从上面那个
/// 按钮连按 4 次 ↓ —— 焦点**一直留在 `SelectableText` 上**，永远到不了下面那个
/// 按钮，`canRequestFocus` 实测为 `true`。
///
/// 后果比「少一个功能」严重得多：用户走进一段长文本就**出不来**了。按 OK 毫无
/// 反应、按方向键也不动，唯一能想到的解释是「遥控器坏了」。
/// 而这一页恰恰是**诊断页** —— 用户是在出问题的时候才来这里的。
///
/// ## 为什么不是「TV 上干脆删掉这段文字」
///
/// 这些文字都是**内容**（日志路径、自检详情、Cookie 说明），删了页面就空了。
/// 换掉的只是「能不能划选」这个在电视上本来就没有对应手势的能力。
///
/// ## 为什么非 TV 上必须原样返回 `SelectableText`
///
/// 桌面/手机上划选是**刻意的设计**：`LogPathRow` 的注释写明「即使不点按钮，
/// 也能用鼠标划选带走」。所以这不是「统一简化」，是**按平台分工** ——
/// 别顺手把非 TV 分支也换成 `Text`。
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// TV 上退化成 [Text]，其余平台保持 [SelectableText]。
///
/// 参数只保留调用点真正用得到的那些。`focusNode` 是个例外 —— 它只在非 TV 上
/// 透传：TV 上**故意**不给焦点系统留任何落点，那正是这个组件存在的全部意义。
class TvSelectableText extends StatelessWidget {
  const TvSelectableText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.focusNode,
  });

  final String text;

  final TextStyle? style;

  final TextAlign? textAlign;

  final int? maxLines;

  /// 只在非 TV 上透传给 [SelectableText]。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    if (AppTheme.isTvLayout(context)) {
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
      );
    }

    return SelectableText(
      text,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      focusNode: focusNode,
    );
  }
}
