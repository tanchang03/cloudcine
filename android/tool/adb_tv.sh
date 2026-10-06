#!/usr/bin/env bash
#
# 云影 Android 端 —— 真机调试助手。
#
# **为什么要有这个脚本**：电视上调试只能靠 adb，而几条常用动作（连设备 / 装包 /
# 看日志 / 按遥控器键 / 截屏）每次都要手打一长串参数，还容易把包名、日志 tag
# 记错。这里把**本工程的真实值**固化下来：
#
#   · 包名          com.cloudcine.tv
#   · 主 Activity   com.cloudcine.tv/.MainActivity
#   · 日志 tag      **CloudCine**（`Log.i("CloudCine", …)`）
#                   ⛔ 这是**唯一**的业务日志出口，不是调试残留：有硬件视频层时
#                      `screencap` 拿不到画面、播放中 `uiautomator dump` 拿不到 UI
#                      （永不 idle），logcat 是唯一能看到状态的地方。
#                   ⛔ 调试浮层默认**关闭**（跨片跨重启记在 `cloudcine_prefs`）。
#                      要看 `[统计]` 行得先进 播放页 → 菜单 → 调试 → 开启。
#
# 电视 IP 用环境变量覆盖，默认 192.168.5.169：
#   TV_IP=192.168.5.170 android/tool/adb_tv.sh connect
#
# 用法：
#   android/tool/adb_tv.sh connect        连接 + 打印状态（unauthorized 时给出修法）
#   android/tool/adb_tv.sh install        装 APK（优先 release，其次 debug，-r 覆盖安装）
#   android/tool/adb_tv.sh log            只跟 CloudCine 这一个 tag（最常用）
#   android/tool/adb_tv.sh app            按 PID 跟本应用的全部日志
#   android/tool/adb_tv.sh logs [关键词]   跟全部日志，可只留含关键词的行
#   android/tool/adb_tv.sh key <键名>      按一次遥控器键
#   android/tool/adb_tv.sh keys <键名>...  依次按多个键（每个间隔 0.4s）
#   android/tool/adb_tv.sh shot [文件名]   截屏存到本地（默认 tv-<时间>.png）
#   android/tool/adb_tv.sh launch         冷启动应用
#   android/tool/adb_tv.sh restart        强停 + 冷启动（改完包想看干净状态时用）
#   android/tool/adb_tv.sh stop           强制停止应用
#   android/tool/adb_tv.sh uninstall      卸载（清缓存/凭证，测首次启动用）
#   android/tool/adb_tv.sh build [debug]  构建（默认 release），出品牌化产物
#   android/tool/adb_tv.sh shell <命令>    直通 adb shell（逃生口）
#
# 键名 → keycode 见下面 KEYCODES 表。`keys` 例：
#   android/tool/adb_tv.sh keys down down ok back

set -euo pipefail

TV_IP="${TV_IP:-192.168.5.169}"
TV_PORT="${TV_PORT:-5555}"
SERIAL="$TV_IP:$TV_PORT"

PKG="com.cloudcine.tv"
ACTIVITY="$PKG/.MainActivity"
TAG="CloudCine"

# 工程根 = 本脚本的上上级（`android/tool/` → `android/`）。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# adb / JDK / SDK 定位
# ---------------------------------------------------------------------------
# 注意 `which adb` 在装了 Homebrew 的机器上可能指向一个**不存在的** shim，
# 所以这里要 `-x` 验一下可执行，而不是只 `command -v`。
if ! command -v adb >/dev/null 2>&1; then
  for candidate in \
    "$HOME/Library/Android/sdk/platform-tools/adb" \
    /opt/homebrew/bin/adb \
    /usr/local/bin/adb \
    "$HOME/Android/Sdk/platform-tools/adb"
  do
    if [ -x "$candidate" ]; then
      export PATH="$(dirname "$candidate"):$PATH"
      break
    fi
  done
fi
command -v adb >/dev/null 2>&1 || {
  echo "找不到 adb —— 装 Android SDK Platform-Tools，或把它加进 PATH" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 遥控器键名表
# ---------------------------------------------------------------------------
# 只收本项目真正会用的键。方向键 + OK + BACK 是焦点遍历的主力；
# MENU 对应 `contextMenu`（播放页的 OSD 就是它唤起的）。
KEYCODES="
up=19
down=20
left=21
right=22
ok=23
center=23
enter=66
back=4
home=3
menu=82
info=165
search=84
play=126
pause=127
playpause=85
next=87
prev=88
rewind=89
ffwd=90
volup=24
voldown=25
mute=164
power=26
del=67
"

keycode_for() {
  local want="$1"
  # 允许直接传数字 keycode，省得查表
  case "$want" in
    ''|*[!0-9]*) ;;
    *) echo "$want"; return 0 ;;
  esac
  local line
  line="$(printf '%s\n' "$KEYCODES" | grep -E "^${want}=" || true)"
  if [ -z "$line" ]; then
    echo "未知键名：$want" >&2
    echo "可用键名：" >&2
    printf '%s\n' "$KEYCODES" | grep -E '=' | cut -d= -f1 | tr '\n' ' ' >&2
    echo >&2
    return 1
  fi
  echo "${line#*=}"
}

# ---------------------------------------------------------------------------
# 连接
# ---------------------------------------------------------------------------
# 关键点：`adb connect` 失败**不代表**连不上。设备处在 `unauthorized` 时
# 会打印 "failed to authenticate"，但端口其实是通的 —— 此时要做的是去电视上
# 点「允许」，而不是反复重连（重连一百次也是同一个结果）。
do_connect() {
  adb start-server >/dev/null 2>&1 || true
  adb connect "$SERIAL" 2>&1 || true

  local state
  state="$(adb devices | awk -v s="$SERIAL" '$1 == s { print $2 }')"

  case "$state" in
    device)
      echo "✓ 已授权：$SERIAL"
      adb -s "$SERIAL" shell getprop ro.product.model 2>/dev/null || true
      ;;
    unauthorized)
      cat >&2 <<'EOF'

✗ 设备未授权（unauthorized）—— 端口是通的，卡在「电视没接受这台电脑的密钥」。

  去电视上处理，二选一：
    A. 电视屏幕上应当弹过「允许 USB 调试吗？」→ 勾「一律允许」→ 确定。
       如果当时点了取消、或弹窗已经超时消失，用 B 把它叫回来。
    B. 设置 → 关于 → 连续点「版本号」7 次进开发者模式 →
       开发者选项 → 「撤销 USB 调试授权」→ 然后重新执行本命令。
       撤销后再次 connect，弹窗一定会重新出现。

  电视必须**亮屏停在首页**，弹窗才会显示。

EOF
      return 1
      ;;
    '')
      echo "✗ 没连上 $SERIAL —— 检查电视是否开机、与本机同一网段、ADB 开关是否打开" >&2
      return 1
      ;;
    *)
      echo "✗ 设备状态异常：$state" >&2
      return 1
      ;;
  esac
}

require_device() {
  local state
  state="$(adb devices | awk -v s="$SERIAL" '$1 == s { print $2 }')"
  if [ "$state" != "device" ]; then
    do_connect
  fi
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------
cmd_build() {
  local variant="${1:-release}"
  cd "$ROOT"
  # ⛔ JDK 必须是 21。用 Android Studio 自带的 JBR（25）时 Kotlin 编译会失败。
  : "${JAVA_HOME:=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home}"
  export JAVA_HOME
  : "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
  export ANDROID_HOME
  case "$variant" in
    debug)   ./gradlew :app:assembleDebug ;;
    release) ./gradlew :app:testDebugUnitTest :app:assembleRelease ;;
    *) echo "用法：$0 build [debug|release]" >&2; exit 1 ;;
  esac
}

# 找最新的产物：优先品牌化 release，其次 app-release，最后 debug。
find_apk() {
  local f
  for pattern in \
    "$ROOT/app/build/outputs/apk/branded/cloudcine-*-android.apk" \
    "$ROOT/app/build/outputs/apk/release/app-release.apk" \
    "$ROOT/app/build/outputs/apk/debug/app-debug.apk"
  do
    # shellcheck disable=SC2086
    f="$(ls -1t $pattern 2>/dev/null | head -1 || true)"
    if [ -n "$f" ]; then echo "$f"; return 0; fi
  done
  return 1
}

cmd_install() {
  require_device
  local apk
  if ! apk="$(find_apk)"; then
    echo "没找到 APK。先跑：android/tool/adb_tv.sh build" >&2
    exit 1
  fi
  echo "安装：$apk"
  # -r 覆盖安装并保留数据（含磁盘缓存）。想测「首次启动」先跑 uninstall。
  adb -s "$SERIAL" install -r "$apk"
  echo "✓ 已安装。启动：android/tool/adb_tv.sh launch"
}

cmd_log() {
  require_device
  echo "跟随 tag=$TAG（Ctrl-C 退出）…"
  echo "⛔ 没输出 ≠ 没在播：调试浮层默认关闭，先进 播放页 → 菜单 → 调试 → 开启。"
  echo
  adb -s "$SERIAL" logcat -v time -s "$TAG"
}

cmd_app() {
  require_device
  # 按 **PID** 过滤，能看到本应用的全部 tag（`art` 的 OOM、`AndroidRuntime`
  # 的崩溃栈、`SurfaceFlinger` 相关）—— 查闪退时用它，`log` 只看业务日志。
  local pid
  pid="$(adb -s "$SERIAL" shell pidof "$PKG" | tr -d '\r' | awk '{print $1}')"
  if [ -z "$pid" ]; then
    echo "应用没在跑 —— 先 android/tool/adb_tv.sh launch" >&2
    return 1
  fi
  echo "跟随 $PKG 的全部日志（PID=$pid，Ctrl-C 退出）…"
  echo
  adb -s "$SERIAL" logcat -v time --pid="$pid"
}

cmd_logs() {
  require_device
  local filter="${1:-}"
  echo "跟随全部日志${filter:+（只留含 \"$filter\" 的行）}，Ctrl-C 退出…"
  echo
  if [ -n "$filter" ]; then
    adb -s "$SERIAL" logcat -v time | grep --line-buffered -E "$filter"
  else
    adb -s "$SERIAL" logcat -v time
  fi
}

cmd_key() {
  require_device
  local code
  code="$(keycode_for "$1")" || exit 1
  adb -s "$SERIAL" shell input keyevent "$code"
}

cmd_keys() {
  require_device
  [ "$#" -gt 0 ] || { echo "用法：$0 keys <键名>..." >&2; exit 1; }
  local name code
  for name in "$@"; do
    code="$(keycode_for "$name")" || exit 1
    adb -s "$SERIAL" shell input keyevent "$code"
    # 留一点时间让焦点动画/异步状态落定，否则连按会挤在一起看不出中间态。
    sleep 0.4
  done
}

cmd_shot() {
  require_device
  local out="${1:-tv-$(date +%Y%m%d-%H%M%S).png}"
  # ⛔ **不能**用 `exec-out screencap -p > file`：小米电视的 screencap 会先往
  # stdout 打一行 `Init wrapper sys mutex successful. Pid:NNNN`，再吐 PNG 字节。
  # 结果是**头部带垃圾的坏 PNG** —— `file` 只认成 "data"，`sips` 报
  # "Cannot extract image from file"，读图工具直接失败，而且**不会报错**到
  # 这里。改走「设备上落盘 → pull」，从根上绕开 stdout。
  local remote="/sdcard/cloudcine-shot.png"
  adb -s "$SERIAL" shell screencap -p "$remote" >/dev/null 2>&1
  adb -s "$SERIAL" pull "$remote" "$out" >/dev/null 2>&1
  adb -s "$SERIAL" shell rm -f "$remote" >/dev/null 2>&1
  if [ ! -s "$out" ]; then
    echo "✗ 截屏失败：$out 是空的（检查 /sdcard 是否可写）" >&2
    return 1
  fi
  # 路径提示：$out 可能是相对路径，也可能是绝对路径 —— 绝对路径前面不要再拼 pwd。
  case "$out" in
    /*) echo "✓ 已截屏：$out" ;;
    *)  echo "✓ 已截屏：$(pwd)/$out" ;;
  esac
  echo "⛔ 播放中这张图大概率**全黑**：视频走的是硬件视频层，不进 framebuffer 快照。"
  echo "   播放时的状态只能看 android/tool/adb_tv.sh log。"
}

cmd_launch() {
  require_device
  adb -s "$SERIAL" shell am start -n "$ACTIVITY"
}

cmd_restart() {
  require_device
  adb -s "$SERIAL" shell am force-stop "$PKG"
  sleep 1
  adb -s "$SERIAL" shell am start -n "$ACTIVITY"
}

cmd_stop() {
  require_device
  adb -s "$SERIAL" shell am force-stop "$PKG"
  echo "✓ 已强制停止 $PKG"
}

cmd_uninstall() {
  require_device
  adb -s "$SERIAL" uninstall "$PKG" || true
  echo "✓ 已卸载（凭证 / 磁盘缓存一并清除）"
}

cmd_shell() {
  require_device
  [ "$#" -gt 0 ] || { echo "用法：$0 shell <命令>" >&2; exit 1; }
  adb -s "$SERIAL" shell "$@"
}

# 从脚本自身的头部注释里摘出用法段。**不写死行号** —— 那种写法一改注释
# 就会多印或少印几行，而且不会报错，只会静静地给出错误的帮助。
usage() {
  awk '/^# 用法：/ { on = 1 }
       on && !/^#/ { exit }
       on { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

case "${1:-}" in
  connect)   do_connect ;;
  build)     shift; cmd_build "$@" ;;
  install)   cmd_install ;;
  log)       cmd_log ;;
  app)       cmd_app ;;
  logs)      shift; cmd_logs "$@" ;;
  key)       shift; cmd_key "$@" ;;
  keys)      shift; cmd_keys "$@" ;;
  shot)      shift; cmd_shot "$@" ;;
  launch)    cmd_launch ;;
  restart)   cmd_restart ;;
  stop)      cmd_stop ;;
  uninstall) cmd_uninstall ;;
  shell)     shift; cmd_shell "$@" ;;
  ''|-h|--help|help) usage ;;
  *) echo "未知子命令：$1" >&2; echo >&2; usage >&2; exit 1 ;;
esac
