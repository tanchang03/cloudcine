import 'package:flutter_test/flutter_test.dart';

import '../../tool/version.dart' as version;

/// 版本号一致性守卫（本地版）。
///
/// CI 侧同一份判定在 `.github/workflows/release.yml` 的 `version-guard` job 里跑
/// （`dart tool/version.dart --check --tag "$GITHUB_REF_NAME"`）。这里再放一遍，
/// 是为了**在本地就拦住** —— 发版时才红意味着已经打了 tag，而 tag 收不回来。
///
/// ⛔ 判定逻辑本身在 `tool/version.dart` 里，只有一份。本文件不解析任何文件。
void main() {
  test('pubspec / 设置页「关于」/ Android 三处版本号必须一致', () {
    final problems = version.checkVersionConsistency();

    expect(
      problems,
      isEmpty,
      reason: '版本号漂了：\n${problems.map((p) => '  · $p').join('\n')}\n'
          '修法：**只改 pubspec.yaml 的 `version:`**，然后跑 '
          '`dart tool/version.dart` 同步其余两处。\n'
          '（手改另外两处是 2026-10-11 那次事故的成因：tag v0.1.6 / '
          'pubspec 0.1.1 / 设置页 0.1.0 / Android 0.1.1）',
    );
  });

  test('versionCode 折算规则：x*10000 + y*100 + z，且严格单调递增', () {
    expect(version.versionCodeFor('0.1.6'), 106);
    expect(version.versionCodeFor('0.2.0'), 200);
    expect(version.versionCodeFor('1.0.0'), 10000);

    // 单调递增是 Android 覆盖安装的硬要求（回退 ⇒ 用户报「应用未安装」）。
    expect(
      version.versionCodeFor('0.1.7'),
      greaterThan(version.versionCodeFor('0.1.6')),
    );
    expect(
      version.versionCodeFor('0.2.0'),
      greaterThan(version.versionCodeFor('0.1.99')),
    );
    expect(
      version.versionCodeFor('1.0.0'),
      greaterThan(version.versionCodeFor('0.99.99')),
    );
  });

  test('versionCode 折算只认 x.y.z 三段式', () {
    expect(() => version.versionCodeFor('0.1'), throwsFormatException);
    expect(() => version.versionCodeFor('0.1.6.1'), throwsFormatException);
  });

  test('tag 归一化：认 v 前缀与 refs/tags 前缀，不认分支名', () {
    expect(version.parseTagVersion('v0.1.6'), '0.1.6');
    expect(version.parseTagVersion('0.1.6'), '0.1.6');
    expect(version.parseTagVersion('refs/tags/v0.1.6'), '0.1.6');

    // 手动触发 workflow 时 GITHUB_REF_NAME 是分支名 —— 必须被识别成
    // 「没有 tag 可比」而不是「tag 版本是 main」。
    expect(version.parseTagVersion('main'), isNull);
    expect(version.parseTagVersion('refs/heads/main'), isNull);
    expect(version.parseTagVersion(null), isNull);
  });
}
