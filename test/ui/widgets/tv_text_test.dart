import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:cloudcine/ui/widgets/tv_text.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `TvSelectableText` 的**按平台分工**契约。
///
/// 为什么值得单独测：这个组件在非 TV 上必须**原样**返回 `SelectableText`。
/// 那不是「没改完」，是刻意的 —— 桌面/手机上划选是设计的一部分
/// （`LogPathRow` 的注释写明「即使不点按钮，也能用鼠标划选带走」）。
/// 哪天有人觉得「统一用 `Text` 更省事」，这条会红。
///
/// 焦点行为本身（TV 上会不会卡住 D-pad）不在这里测 ——
/// 那是 Flutter 侧的行为，钉在 `test/ui/tv_remote_probe_test.dart` 里，
/// 那一条同时钉住「裸 `SelectableText` 确实有害」和「本组件确实修好了」。
void main() {
  /// 在指定平台 + 指定逻辑尺寸下渲染，然后报出屏幕上到底是什么。
  ///
  /// ⚠️ 复位 `debugDefaultTargetPlatformOverride` 只能写在**测试体里**
  /// （这个 `finally`）—— `tearDown` / `addTearDown` 都排在 Flutter 的
  /// `_verifyInvariants` 后面，用错会得到一条与业务毫无关系的
  /// 「The value of a foundation debug variable was changed by the test」。
  Future<({int text, int selectable})> render(
    WidgetTester tester, {
    required TargetPlatform platform,
    required Size size,
  }) async {
    late ({int text, int selectable}) found;
    debugDefaultTargetPlatformOverride = platform;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: MediaQuery(
            // 尺寸用 `MediaQuery` 显式给 —— 与 `tv_layout_test.dart` 同一套做法。
            data: MediaQueryData(size: size),
            child: const Scaffold(
              body: TvSelectableText('一段诊断文本'),
            ),
          ),
        ),
      );
      found = (
        text: find.byType(Text).evaluate().length,
        selectable: find.byType(SelectableText).evaluate().length,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    return found;
  }

  testWidgets('TV（android + 960 宽）→ 退化成普通 Text，不给焦点系统留落点', (tester) async {
    final r = await render(
      tester,
      platform: TargetPlatform.android,
      size: const Size(960, 540),
    );

    expect(r.selectable, 0, reason: 'TV 上还剩 SelectableText —— D-pad 会卡在它上面出不去');
    expect(r.text, 1);
  });

  testWidgets('桌面 → 原样是 SelectableText，划选这条路不能堵', (tester) async {
    final r = await render(
      tester,
      platform: TargetPlatform.macOS,
      size: const Size(1440, 900),
    );

    expect(
      r.selectable,
      1,
      reason: '桌面上划选是刻意的设计（不点按钮也能用鼠标带走）—— '
          '别为了「统一」把非 TV 分支也换成 Text',
    );
  });

  testWidgets('Android 手机（宽 412）→ 也不算 TV，保留划选', (tester) async {
    // 判据是「android **且** 宽 ≥ 960」。只按平台判的话，手机上会凭空少掉划选。
    final r = await render(
      tester,
      platform: TargetPlatform.android,
      size: const Size(412, 915),
    );

    expect(r.selectable, 1, reason: '手机宽度不是电视 —— 不该跟着 TV 一起退化');
  });

  testWidgets('桌面 + 960 宽也不算 TV（平台不对）', (tester) async {
    // 这一条防的是「只看宽度」这种改法：桌面窗口拉宽到 960 不该变成电视。
    final r = await render(
      tester,
      platform: TargetPlatform.macOS,
      size: const Size(960, 540),
    );

    expect(r.selectable, 1, reason: '桌面窗口再宽也不是电视 —— 判据必须带平台');
  });
}
