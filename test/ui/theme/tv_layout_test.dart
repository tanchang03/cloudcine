import 'package:cloudcine/ui/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 布局判据与过扫描安全边距。
///
/// 为什么值得测：这两条一旦判错，坏法都很隐蔽 ——
///   * 判宽了 → 桌面/手机上凭空多出一圈 48px 的黑边，没人会想到是这里；
///   * 判窄了 → 真机电视把侧栏最左边那列字切掉，而开发机上**永远复现不出来**。
void main() {
  /// 在指定平台 + 指定逻辑尺寸下取一次判据。
  ///
  /// ⚠️ 复位 `debugDefaultTargetPlatformOverride` 必须**写在测试体里**
  /// （这里的 `finally`），`tearDown` 和 `addTearDown` **都不行**：
  /// Flutter 的 `_verifyInvariants`（它会断言「foundation 的调试变量都已复位」）
  /// 是在 `_runTestBody` **内部**调用的，两种 tearDown 都排在它后面。
  /// 用错会得到一条与业务毫无关系的
  /// 「The value of a foundation debug variable was changed by the test」。
  Future<({bool isTv, EdgeInsets insets})> probe(
    WidgetTester tester, {
    required TargetPlatform platform,
    required Size size,
  }) async {
    late ({bool isTv, EdgeInsets insets}) result;
    debugDefaultTargetPlatformOverride = platform;
    try {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              result = (
                isTv: AppTheme.isTvLayout(context),
                insets: AppTheme.safeAreaInsets(context),
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    return result;
  }

  testWidgets('Android + 960 宽（官方 TV 设计尺寸）→ 认成电视，让出 48/27', (tester) async {
    final r = await probe(
      tester,
      platform: TargetPlatform.android,
      size: const Size(960, 540),
    );

    expect(r.isTv, isTrue);
    expect(
      r.insets,
      const EdgeInsets.symmetric(horizontal: 48, vertical: 27),
      reason: '这是官方 TV 规范的过扫描安全边距；原来页边距只有 22，'
          '真机上侧栏最左边的字会被切掉',
    );
  });

  testWidgets('Android + 手机宽度 → 不是电视，不留边', (tester) async {
    final r = await probe(
      tester,
      platform: TargetPlatform.android,
      size: const Size(412, 915),
    );

    expect(r.isTv, isFalse);
    expect(
      r.insets,
      EdgeInsets.zero,
      reason: '手机逻辑宽度只有 360–430，给它套 48px 黑边纯属浪费',
    );
  });

  testWidgets('macOS 宽屏 → 不是电视（桌面绝不能多出一圈黑边）', (tester) async {
    final r = await probe(
      tester,
      platform: TargetPlatform.macOS,
      size: const Size(1920, 1080),
    );

    expect(r.isTv, isFalse);
    expect(
      r.insets,
      EdgeInsets.zero,
      reason: '判据必须带平台，不能只看宽度 —— 否则宽屏桌面会凭空多一圈边',
    );
  });
}
