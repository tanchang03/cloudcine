#!/usr/bin/env bash
#
# 构建 Android release APK。
#
# **产物名不再是 `app-release.apk`**：`android/app/build.gradle.kts` 末尾给
# `assembleRelease` 挂了一个 finalizer，在 Flutter 工具链复制完之后把产物
# **另存一份**成 `cloudcine-<versionName>-b<versionCode>-android.apk` —— 与
# macOS 的 `cloudcine-<ver>-macos.dmg`、Windows 的
# `cloudcine-<ver>-windows-x64.msi` 对齐。
#
# ⚠️ 原文件 `app-release.apk` **必须保留**：Flutter 工具按**精确文件名**
# （`gradle.dart:132-143` 造名、`:1010-1022` 逐个 `existsSync()`）去
# `flutter-apk/` 里找产物，改名会让它直接报
# 「Gradle build failed to produce an .apk file」。所以 Gradle 那边做的是
# **复制**而不是重命名，两处逻辑不要分叉。
#
# 本脚本只负责：找到 flutter → 构建 → 校验品牌产物在 → 打印 sha256。
# **不再自己拼产物名** —— 那会与 Gradle 里的规则形成第二份实现，改用 glob。
#
# 用法：tool/build_android.sh

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

APK_DIR="build/app/outputs/flutter-apk"

flutter build apk --release

# Flutter 工具链自己那份。它必须还在：一旦不见了，说明产物发现逻辑被破坏，
# 而这个脚本能跑通只是碰巧（下次 `flutter install` / `flutter run` 就会炸）。
[ -f "$APK_DIR/app-release.apk" ] || {
  echo "构建结束，但没有找到 $APK_DIR/app-release.apk —— Flutter 工具链那条路坏了" >&2
  exit 1
}

# 品牌化产物：由 Gradle 的 brandReleaseApk 产出。用 glob 而不是拼名字，
# 免得这里成为产物命名规则的第二份实现。
NAMED="$(ls -1 "$APK_DIR"/cloudcine-*-android.apk 2>/dev/null | head -1 || true)"
[ -n "$NAMED" ] || {
  echo "构建结束，但没有找到品牌化产物（$APK_DIR/cloudcine-*-android.apk）" >&2
  echo "目录内容：" >&2
  ls -lh "$APK_DIR" >&2
  exit 1
}

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
