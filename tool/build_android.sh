#!/usr/bin/env bash
#
# 构建 Android release APK，并按发布约定给它起名。
#
# **为什么需要这一步**：`flutter build apk` 的产物固定叫
# `build/app/outputs/flutter-apk/app-release.apk`。这个名字是 Flutter 工具链
# 定死的 —— Gradle 造出 APK 之后，`flutter.groovy` 会把它**复制**到
# `flutter-apk/` 并重命名（`gradle/.../flutter.groovy:1437-1443` 那段
# `project.copy { ... rename { ... } }`），所以在 `build.gradle.kts` 里改
# `outputFileName` 是改不掉它的：只会多出一个副本，而 `flutter build apk`
# 报出来的路径依旧是 `app-release.apk`。
#
# 而 `app-release.apk` 传到用户手里完全看不出是哪个应用、哪个版本，也和
# 另外两个平台的产物对不上：
#   macOS    cloudcine-<ver>-macos.dmg / .zip
#   Windows  cloudcine-<ver>-windows-x64.msi / .zip
# 所以这里补最后一步：构建完复制成 `cloudcine-<ver>-android.apk`。
#
# 用法：tool/build_android.sh
#
# ⚠️ 文件名刻意保持 **ASCII 小写**，和 dmg / msi 一致：`adb push`、CI 缓存、
# 旧版 Windows 处理中文与空格文件名的方式各不相同，而产物名不需要好看 ——
# 好看的显示名在应用里（AndroidManifest 的 `android:label`）。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 本机 flutter 在 PATH 上就用它；否则试几个常见安装位置（CI / 编辑器任务里兜底）。
if ! command -v flutter >/dev/null 2>&1; then
  for candidate in \
    /opt/homebrew/bin/flutter \
    /usr/local/bin/flutter \
    "$HOME/flutter/bin/flutter"
  do
    if [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):$PATH"
      break
    fi
  done
fi
command -v flutter >/dev/null 2>&1 || {
  echo "找不到 flutter —— 先让它出现在 PATH 上" >&2
  exit 1
}

# 版本号唯一源头是 pubspec.yaml 的 `version: X.Y.Z+B`，只取 `+` 前面那段
# （与 .github/workflows/release.yml 里取 VERSION 的方式一致）。
VERSION="$(grep '^version:' pubspec.yaml | cut -d' ' -f2 | cut -d'+' -f1)"
[ -n "$VERSION" ] || { echo "读不到 pubspec.yaml 的 version" >&2; exit 1; }

RAW="build/app/outputs/flutter-apk/app-release.apk"
NAMED="build/app/outputs/flutter-apk/cloudcine-${VERSION}-android.apk"

flutter build apk --release

[ -f "$RAW" ] || { echo "构建结束，但没有找到 $RAW" >&2; exit 1; }
cp -f "$RAW" "$NAMED"

echo
echo "产物：$NAMED"
ls -lh "$NAMED"

# macOS 只有 `shasum`，Ubuntu 只有 `sha256sum`（`shasum` 来自 libdigest-sha-perl，
# 精简镜像里不一定装了）。**这一步在 CI 上必须不能失败**：脚本是 `set -e` 的，
# 一个 command-not-found 会让「包其实已经构建好了」的 job 整体判红。
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$NAMED"
else
  shasum -a 256 "$NAMED"
fi
