import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「遥控器够不够得到」的判定工具。
///
/// ## 为什么不是 `Focus.of(...).hasFocus`
///
/// 项目里的 TV 焦点包装 `TvFocusable`（`ui/widgets/tv_focus.dart`）是
/// `Focus(canRequestFocus: false)`，它**只负责观察**焦点、画那圈描边；真正
/// 吃焦点的是它里面那个 `InkWell`。所以 `Focus.of(element).hasFocus` 拿到的
/// 是那个「观察者」，它**永远**是 false —— 用它会得到一条一直红的假警报，
/// 而界面其实完全正常。
///
/// 反过来从 `FocusManager.instance.primaryFocus` 出发、往上走祖先链找目标，
/// 就不关心谁才是真正的焦点宿主了。
bool focusedInside(WidgetTester tester, Finder target) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null || target.evaluate().isEmpty) return false;
  final el = tester.element(target);
  if (identical(focused, el)) return true;
  var found = false;
  focused.visitAncestorElements((e) {
    if (identical(e, el)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// [targets] 里只要有**任意一个**拿到了焦点就算命中。
bool anyFocusedInside(WidgetTester tester, Finder targets) {
  for (var i = 0; i < targets.evaluate().length; i++) {
    if (focusedInside(tester, targets.at(i))) return true;
  }
  return false;
}

/// 按 [key] 走一遍，看看 [probe] 描述的每一块区域是否都被焦点光顾过。
///
/// ## 为什么用 Tab 而不是方向键
///
/// 方向键的可达性依赖**几何位置**（网格里按 ↓ 落到哪一格取决于间距），
/// 换个 `posterAspect` 就会飘。Tab 走的是**阅读顺序**，稳定地枚举「这一页上
/// 哪些东西能拿到焦点」。真机上遥控器没有 Tab，这里只把它当作**可达性的
/// 代理** —— `test/ui/tv_remote_probe_test.dart` 用的是同一套用法。
///
/// 返回每个探针是否命中（与 [probes] 同序）。
Future<List<bool>> walkReachability(
  WidgetTester tester, {
  required Map<String, bool Function(WidgetTester)> probes,
  int maxSteps = 120,
  LogicalKeyboardKey key = LogicalKeyboardKey.tab,
}) async {
  final hit = List<bool>.filled(probes.length, false);
  for (var step = 0; step < maxSteps && hit.contains(false); step++) {
    await tester.sendKeyEvent(key);
    await tester.pump();
    var i = 0;
    for (final probe in probes.values) {
      if (!hit[i] && probe(tester)) hit[i] = true;
      i++;
    }
  }
  return hit;
}
