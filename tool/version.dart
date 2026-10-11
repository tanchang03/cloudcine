// 版本号真源与一致性守卫。
//
// ── 为什么需要它 ─────────────────────────────────────────────────────────────
// 版本号在本仓库里有**四个**落点，任何一个漂了都会以不同的方式露出来：
//
//   | 落点                                        | 谁在用                        |
//   |---------------------------------------------|-------------------------------|
//   | `pubspec.yaml` 的 `version: x.y.z+build`    | PC 端一切（见下）             |
//   | `lib/ui/pages/settings_page.dart` `_kAppVersion` | 设置页「关于」里给用户看的 |
//   | `android/app/build.gradle.kts` versionName  | APK 的版本名 + 产物文件名     |
//   | `android/app/build.gradle.kts` versionCode  | Android 覆盖安装的判据        |
//
// PC 端的 `version` 是**派生源头**：macOS 的 `CFBundleShortVersionString`
// 读 `$(FLUTTER_BUILD_NAME)`、Windows exe 的 VERSIONINFO 读 `FLUTTER_VERSION`、
// Windows 的 MSI 与 zip 文件名由 `windows/packaging/build_package.ps1` 读
// pubspec —— 这几处都是**构建期自动派生**的，不存在手改点。
//
// 真正会漂的是另外三处（都是手写字面量）。2026-10-11 实测到的漂移：
//
//     tag v0.1.6  ·  pubspec 0.1.1+2  ·  settings_page 0.1.0  ·  android 0.1.1
//
// 后果是同一个 Release 页上，标题写着 `v0.1.6`，下载的文件却叫
// `cloudcine-0.1.1-macos.dmg`，装进手机的应用内「关于」又显示 `0.1.0` ——
// 用户报 bug 时根本说不清是哪个版本。
//
// ⛔ Android 端**刻意不从 pubspec 读版本号**：`android/` 是独立原生工程
//    （见 `.workbuddy-ai/memory/MEMORY.md` 的「两个互不引用的工程」），
//    让 Gradle 去解析仓库根的 pubspec 会把两条构建链路重新焊死。
//    所以这里选择「**手写 + 机器守卫**」：字面量留在原处，一致性由本脚本兜。
//
// ── 唯一实现 ─────────────────────────────────────────────────────────────────
// 解析与判定逻辑**只在本文件里写一遍**，三个调用方共用：
//
//   * 本地 / 人工：`dart tool/version.dart`（同步）· `dart tool/version.dart --check`
//   * CI：`.github/workflows/release.yml` 的 `version-guard` job
//   * 单测：`test/core/version_consistency_test.dart`
//
// ⛔ 不要在 workflow 里再抄一份 `grep`/`sed` 解析 —— 那就是第二份实现，
//    改一处就分叉（这条教训在本仓库已经吃过一次，见 release.yml 里
//    「用 glob 而不是拼名字」那段注释）。
//
// ── versionCode 的算法 ───────────────────────────────────────────────────────
// `major * 10000 + minor * 100 + patch`，与 pubspec 的 `+build` 同值：
//
//     0.1.6  →  106        0.2.0  →  200        1.0.0  →  10000
//
// 好处是**天然单调递增**（Android 覆盖安装的硬要求），而且不用人工维护
// 一个「上次用到几了」的计数器 —— 那个计数器是漂移的温床。
// ⚠️ 代价：minor 超过 99、patch 超过 99 会进位撞号，本项目的发版节奏下不会碰到；
//    真碰到了就顺手升 minor。
// ⚠️ 历史值：0.1.1 时代 versionCode 是手写的 `2`，改成公式后跳到 `106`，
//    仍然是递增的（覆盖安装不会报「应用未安装」）。
//
// ── 用法 ─────────────────────────────────────────────────────────────────────
//     dart tool/version.dart                          # 按 pubspec 同步其它三处
//     dart tool/version.dart --check                  # 只校验，有问题退出码 1
//     dart tool/version.dart --check --tag v0.1.6     # 连 tag 一起校验（CI 用）
//     dart tool/version.dart --print                  # 只打印版本号（CI 取 outputs）
//     dart tool/version.dart --set 0.2.0              # 改版本号：写 pubspec + 同步
//
// ⛔ 手改版本号时**只改 pubspec.yaml 的 `version:`**，然后跑一次
//    `dart tool/version.dart`，别去手改另外两处。

import 'dart:io';

/// 版本号的三个落点，路径都相对仓库根。
const String pubspecPath = 'pubspec.yaml';
const String settingsPath = 'lib/ui/pages/settings_page.dart';
const String gradlePath = 'android/app/build.gradle.kts';

final RegExp _pubspecVersionRe =
    RegExp(r'^version:[ \t]*(\S+)[ \t]*$', multiLine: true);
final RegExp _appVersionRe = RegExp(r"_kAppVersion[ \t]*=[ \t]*'([^']*)'");
final RegExp _gradleNameRe = RegExp(r'versionName[ \t]*=[ \t]*"([^"]*)"');
final RegExp _gradleCodeRe = RegExp(r'versionCode[ \t]*=[ \t]*(\d+)');
final RegExp _versionTagRe = RegExp(r'^(?:refs/tags/)?v?(\d+\.\d+\.\d+)$');

Directory? _cachedRoot;

/// 仓库根：从当前工作目录**逐级向上**找那个同时含 `pubspec.yaml` 与
/// `android/app/build.gradle.kts` 的目录。
///
/// ⛔ 不能拿 `Platform.script` 推：本文件同时被单测 `import`，那时
///    `Platform.script` 指的是 flutter_test 的宿主脚本，推出来的是 SDK 目录。
///    cwd 在两个调用场景下都是可信的 —— CI 是 `$GITHUB_WORKSPACE`，
///    `flutter test` 是 package 根，`dart tool/version.dart` 是仓库根。
Directory get repoRoot {
  final cached = _cachedRoot;
  if (cached != null) return cached;

  var dir = Directory.current.absolute;
  while (true) {
    final isRoot = File('${dir.path}/$pubspecPath').existsSync() &&
        File('${dir.path}/$gradlePath').existsSync();
    if (isRoot) return _cachedRoot = dir;

    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError(
        '从 ${Directory.current.path} 往上找不到仓库根'
        '（需要同时有 $pubspecPath 与 $gradlePath）',
      );
    }
    dir = parent;
  }
}

/// 把 `x.y.z` 折算成 Android 的 `versionCode`（同时用作 pubspec 的 `+build`）。
int versionCodeFor(String name) {
  final parts = name.split('.');
  if (parts.length != 3) {
    throw FormatException('版本名必须是 x.y.z 三段式，实际是：$name');
  }
  final nums = parts.map(int.parse).toList();
  return nums[0] * 10000 + nums[1] * 100 + nums[2];
}

/// 一次快照：把三个文件里跟版本号有关的值都读出来（读不到就是 `null`）。
class VersionSnapshot {
  VersionSnapshot({
    required this.pubspecFull,
    required this.pubspecName,
    required this.pubspecBuild,
    required this.appVersion,
    required this.gradleName,
    required this.gradleCode,
  });

  final String? pubspecFull;
  final String? pubspecName;
  final int? pubspecBuild;
  final String? appVersion;
  final String? gradleName;
  final int? gradleCode;

  bool get pubspecLooksSane {
    final n = pubspecName;
    return n != null && RegExp(r'^\d+\.\d+\.\d+$').hasMatch(n);
  }
}

VersionSnapshot readSnapshot(Directory root) {
  String read(String rel) => File('${root.path}/$rel').readAsStringSync();

  final pubspecRaw =
      _pubspecVersionRe.firstMatch(read(pubspecPath))?.group(1)?.trim();
  final name = pubspecRaw?.split('+').first;
  int? build;
  if (pubspecRaw != null && pubspecRaw.contains('+')) {
    build = int.tryParse(pubspecRaw.split('+').last);
  }

  final appRaw = _appVersionRe.firstMatch(read(settingsPath))?.group(1);
  final gradleNameRaw = _gradleNameRe.firstMatch(read(gradlePath))?.group(1);
  final gradleCodeRaw = _gradleCodeRe.firstMatch(read(gradlePath))?.group(1);

  return VersionSnapshot(
    pubspecFull: pubspecRaw,
    pubspecName: name,
    pubspecBuild: build,
    appVersion: appRaw,
    gradleName: gradleNameRaw,
    gradleCode: gradleCodeRaw == null ? null : int.tryParse(gradleCodeRaw),
  );
}

/// 校验三处（可选第四处：git tag）是否一致。返回**人话描述的问题列表**，空表示全过。
///
/// [tag] 可以是 `v0.1.6` / `0.1.6` / `refs/tags/v0.1.6`；传了不是版本 tag 的值
/// （比如手动触发 workflow 时的分支名 `main`）就跳过这一项 —— 手动触发本来
/// 就没有 tag 可比，但代码内三处仍然要自洽。
List<String> checkVersionConsistency({String? tag}) {
  final root = repoRoot;
  final s = readSnapshot(root);
  final problems = <String>[];

  if (!s.pubspecLooksSane) {
    problems.add(
      'pubspec.yaml 里读不到合法的 `version: x.y.z+build`（读到的是 ${s.pubspecFull}）',
    );
    // 后面每一条都依赖它，早点返回，免得刷出一堆连带错误。
    return problems;
  }

  final version = s.pubspecName!;
  final expectedCode = versionCodeFor(version);

  if (s.appVersion != version) {
    problems.add(
      '设置页显示版本号不一致：$settingsPath 里 _kAppVersion = '
      "'${s.appVersion}'，pubspec.yaml 是 '$version'",
    );
  }
  if (s.gradleName != version) {
    problems.add(
      'Android versionName 不一致：$gradlePath 里是 "${s.gradleName}"，'
      'pubspec.yaml 是 "$version"',
    );
  }
  if (s.pubspecBuild != expectedCode) {
    problems.add(
      'pubspec.yaml 的构建号不一致：`version: $version+${s.pubspecBuild}`，'
      '按 x.y.z 折算应当是 +$expectedCode',
    );
  }
  if (s.gradleCode != expectedCode) {
    problems.add(
      'Android versionCode 不一致：$gradlePath 里是 ${s.gradleCode}，'
      '按 versionName 折算应当是 $expectedCode',
    );
  }

  final tagVersion = parseTagVersion(tag);
  if (tagVersion != null && tagVersion != version) {
    problems.add(
      'git tag 与代码内版本号不一致：tag 是 v$tagVersion，'
      'pubspec.yaml 是 $version —— 发版前先把 pubspec 改成 $tagVersion '
      '（或改用与代码一致的 tag）',
    );
  }

  return problems;
}

/// 把 tag 归一成 `x.y.z`；不是版本 tag（或没传）返回 `null`。
String? parseTagVersion(String? tag) {
  if (tag == null || tag.trim().isEmpty) return null;
  return _versionTagRe.firstMatch(tag.trim())?.group(1);
}

/// 把 pubspec 的版本同步到另外两处。返回实际发生的改动（人话），没改就是空。
List<String> syncVersions() {
  final root = repoRoot;
  final s = readSnapshot(root);
  if (!s.pubspecLooksSane) {
    throw StateError('pubspec.yaml 里读不到合法的 `version: x.y.z+build`');
  }
  final version = s.pubspecName!;
  final code = versionCodeFor(version);
  final changes = <String>[];

  // 1. 设置页「关于」里显示的版本
  final settingsFile = File('${root.path}/$settingsPath');
  final settingsSrc = settingsFile.readAsStringSync();
  final newSettings = settingsSrc.replaceFirstMapped(
    _appVersionRe,
    (m) => "_kAppVersion = '$version'",
  );
  if (newSettings != settingsSrc) {
    settingsFile.writeAsStringSync(newSettings);
    changes.add("$settingsPath: _kAppVersion → '$version'");
  }

  // 2. Android 的 versionName / versionCode
  final gradleFile = File('${root.path}/$gradlePath');
  final gradleSrc = gradleFile.readAsStringSync();
  var newGradle = gradleSrc;
  newGradle = newGradle.replaceFirstMapped(
    _gradleNameRe,
    (m) => 'versionName = "$version"',
  );
  newGradle = newGradle.replaceFirstMapped(
    _gradleCodeRe,
    (m) => 'versionCode = $code',
  );
  if (newGradle != gradleSrc) {
    gradleFile.writeAsStringSync(newGradle);
    changes.add('$gradlePath: versionName → "$version"，versionCode → $code');
  }

  return changes;
}

/// 换版本号：写 pubspec，再同步其余两处。
void setVersion(String next) {
  final root = repoRoot;
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(next)) {
    throw FormatException('版本号必须是 x.y.z 三段式，实际是：$next');
  }
  final code = versionCodeFor(next);
  final file = File('${root.path}/$pubspecPath');
  final src = file.readAsStringSync();
  if (!_pubspecVersionRe.hasMatch(src)) {
    throw StateError('$pubspecPath 里找不到 `version:` 行');
  }
  final patched = src.replaceFirstMapped(
    _pubspecVersionRe,
    (m) => 'version: $next+$code',
  );
  if (patched != src) file.writeAsStringSync(patched);
  stdout.writeln('$pubspecPath: version → $next+$code');
}

void main(List<String> args) {
  final check = args.contains('--check');

  /// 支持 `--tag=v0.1.6` 与 `--tag v0.1.6` 两种写法 —— 手敲时很容易写成后者，
  /// 而「参数被静默忽略、脚本照常成功退出」是最难查的一类错（本脚本自己踩过）。
  String? valueOf(String flag) {
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == flag) {
        if (i + 1 >= args.length) {
          throw FormatException('$flag 后面缺少取值');
        }
        return args[i + 1];
      }
      if (a.startsWith('$flag=')) return a.substring(flag.length + 1);
    }
    return null;
  }

  try {
    final tag = valueOf('--tag');
    final set = valueOf('--set');

    // 只把版本号打到 stdout（CI 用它填 job 的 outputs，别再抄一份解析）。
    if (args.contains('--print')) {
      final s = readSnapshot(repoRoot);
      if (!s.pubspecLooksSane) {
        stderr.writeln('pubspec.yaml 里读不到合法的 `version: x.y.z+build`');
        exit(1);
      }
      stdout.writeln(s.pubspecName);
      return;
    }

    if (set != null) {
      setVersion(set);
      final changes = syncVersions();
      if (changes.isEmpty) {
        stdout.writeln('其余两处本来就是一致的，没有改动。');
      } else {
        for (final c in changes) {
          stdout.writeln('已同步 $c');
        }
      }
      return;
    }

    if (check) {
      final problems = checkVersionConsistency(tag: tag);
      final root = repoRoot;
      final s = readSnapshot(root);
      stdout.writeln('版本号现状：');
      stdout.writeln('  pubspec.yaml          ${s.pubspecFull}');
      stdout.writeln('  设置页「关于」        ${s.appVersion}');
      stdout.writeln('  Android versionName   ${s.gradleName}');
      stdout.writeln('  Android versionCode   ${s.gradleCode}');
      final tagVersion = parseTagVersion(tag);
      stdout.writeln(
        '  git tag               ${tagVersion == null ? '（未提供，跳过）' : 'v$tagVersion'}',
      );
      stdout.writeln('');
      if (problems.isEmpty) {
        stdout.writeln('✅ 全部一致。');
        return;
      }
      stderr.writeln('❌ 发现 ${problems.length} 处不一致：');
      for (final p in problems) {
        stderr.writeln('  · $p');
      }
      stderr.writeln('');
      stderr.writeln('修法：只改 pubspec.yaml 的 `version:`，然后跑 '
          '`dart tool/version.dart` 同步其余两处。');
      exit(1);
    }

    // 默认：同步
    final changes = syncVersions();
    if (changes.isEmpty) {
      stdout.writeln('版本号本来就是一致的，没有改动。');
    } else {
      for (final c in changes) {
        stdout.writeln('已同步 $c');
      }
    }
  } on Object catch (e) {
    stderr.writeln('版本号处理失败：$e');
    exit(1);
  }
}
