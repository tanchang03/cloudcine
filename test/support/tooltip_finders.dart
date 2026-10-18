import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按 tooltip 找控件的两种「松一点」的查法。
///
/// ## 为什么不直接 `find.byTooltip('整串')`
///
/// 项目里的 tooltip 常是「动作 + 括号补充」的形状：
/// `多选（批量合并 / 移除）`、`直接播放（不加入媒体库）`、`全屏（F）`。
/// 括号里那截**随功能演进而变**（多加了一个「移除」、换了快捷键），而用例
/// 真正关心的只是「那个入口还在不在」。锁死整串的后果是：一次产品改文案就
/// 让一片用例变红，而报错是 `Found 0 widgets with widget matching
/// predicate` —— 看不出是「文案变了」还是「控件没了」，排查方向会跑偏
/// （2026-10-18 就是这么红的）。
///
/// 所以按**前缀**找：`byTooltipPrefix('多选')`。
///
/// ⚠️ 只在「同一个前缀下有多个入口、必须区分」时才用 [byTooltipContaining]。
///    `findsOneWidget` 断言尤其要确认前缀没把兄弟入口一起捞进来。
///
/// ⚠️ 反过来，**tooltip 的内容本身就是要断言的东西**时（例如 `全屏（F）`
///    里的快捷键 `F` 是功能的一部分），仍然用 `find.byTooltip` 锁死整串 ——
///    松着找等于放弃了那条断言。
Finder byTooltipPrefix(String prefix) => find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith(prefix),
      description: 'tooltip 以「$prefix」开头',
    );

/// 按 tooltip 里的一段子串找。用于「前面还带变量」的文案
/// （`在媒体库《…》下`）。
Finder byTooltipContaining(String needle) => find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').contains(needle),
      description: 'tooltip 含「$needle」',
    );
