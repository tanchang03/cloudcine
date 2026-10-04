#!/usr/bin/env bash
#
# Android TV 真机调试助手。
#
# **为什么要有这个脚本**：电视上调试只能靠 adb，而几条常用动作（连设备 / 装包 /
# 看日志 / 按遥控器键 / 截屏）每次都要手打一长串参数，还容易把包名、日志 tag
# 记错。这里把**本项目的具体值**固化下来，免得每次靠回忆：
#
#   · 包名          com.cloudcine.cloudcine
#   · 主 Activity   com.cloudcine.cloudcine/.MainActivity
#   · 日志 tag      ⚠️ **DiagLog 的行在 release 包里进不了 logcat**（实测，
#                   见下）。logcat 里能看到的只有三类：引擎自己的 `flutter`
#                   （如 Impeller 初始化）、原生库的 `media_kit`、以及被截成
#                   `dcine.cloudcin` 的 Java/ART 日志（进程名前 8 字符被截掉）。
#                   `-s cloudtune` / `-s flutter` **都拿不到业务日志**。
#
# ⚠️ **release 包的三个限制（都实测过）**：
#   1. `dart:developer` 的 `log()` **不落 logcat** —— DiagLog 的 `[播放] [中继]`
#      这些行只在**应用内「诊断日志」页**看得到（内存环形缓冲 800 行）。
#   2. `run-as` 被拒（`package not debuggable`），`/data/data/<pkg>/files/logs/`
#      也 Permission denied → **日志文件拿不出来**。
#   3. 没有 Dart VM service → `flutter attach` / 热重载不可用。
#   想要 logcat 里有业务日志、或想热重载，必须装 **debug / profile** 包：
#       flutter run --profile -d 192.168.5.169:5555
#   电视上调试优先 profile（AOT、跑得动），要看 `print` 输出才用 debug。
#
# 电视 IP 用环境变量覆盖，默认 192.168.5.169：
#   TV_IP=192.168.5.170 tool/adb_tv.sh connect
#
# 用法：
#   tool/adb_tv.sh connect          连接 + 打印状态（unauthorized 时给出修法）
#   tool/adb_tv.sh install          装最新的品牌化 release APK（-r 覆盖安装）
#   tool/adb_tv.sh app              只跟本应用的日志（按 PID 过滤）
#   tool/adb_tv.sh logs [关键词]     跟全部日志，可只留含关键词的行
#   tool/adb_tv.sh key <键名>        按一次遥控器键
#   tool/adb_tv.sh keys <键名>...    依次按多个键（每个间隔 0.4s）
#   tool/adb_tv.sh shot [文件名]     截屏存到本地（默认 tv-<时间>.png）
#   tool/adb_tv.sh launch           冷启动应用
#   tool/adb_tv.sh restart          强停 + 冷启动（改完包想看干净状态时用）
#   tool/adb_tv.sh stop             强制停止应用
#   tool/adb_tv.sh uninstall        卸载（清数据库/凭证，测首次启动用）
#   tool/adb_tv.sh shell <命令>      直通 adb shell（逃生口）
#
# 键名 → keycode 见下面 KEYCODES 表。`keys` 例：
#   tool/adb_tv.sh keys down down ok back

set -euo pipefail

TV_IP="${TV_IP:-192.168.5.169}"
TV_PORT="${TV_PORT:-5555}"
SERIAL="$TV_IP:$TV_PORT"

PKG="com.cloudcine.cloudcine"
ACTIVITY="$PKG/.MainActivity"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_DIR="$ROOT/build/app/outputs/flutter-apk"

# ---------------------------------------------------------------------------
# adb 定位
# ---------------------------------------------------------------------------
# 和 build_android.sh 同一套思路：PATH 上有就用，没有就试几个常见安装位置。
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
# MENU 对应 `contextMenu`（见 player_page 的遥控器键位表）。
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
cmd_install() {
  require_device
  # 用 glob 而不是拼名字 —— 与 build_android.sh 一致，避免这里成为
  # 产物命名规则的第二份实现。
  local apk
  apk="$(ls -1 "$APK_DIR"/cloudcine-*-android.apk 2>/dev/null | head -1 || true)"
  if [ -z "$apk" ]; then
    echo "没找到品牌化 APK（$APK_DIR/cloudcine-*-android.apk）" >&2
    echo "先跑：tool/build_android.sh" >&2
    exit 1
  fi
  echo "安装：$apk"
  # -r 覆盖安装并保留数据。想测「首次启动」先跑 uninstall。
  adb -s "$SERIAL" install -r "$apk"
  echo "✓ 已安装。启动：tool/adb_tv.sh launch"
}

cmd_app() {
  require_device
  # 按 **PID** 过滤，而不是按 tag。理由见文件头：release 包里业务日志压根
  # 不在 logcat，而能看到的那些 tag（`flutter` / `dcine.cloudcin` / `media_kit`）
  # 没有一个是我们自己设的 —— 只有 PID 是稳定的锚点。
  local pid
  pid="$(adb -s "$SERIAL" shell pidof "$PKG" | tr -d '\r' | awk '{print $1}')"
  if [ -z "$pid" ]; then
    echo "应用没在跑 —— 先 tool/adb_tv.sh launch" >&2
    return 1
  fi
  echo "跟随 $PKG 的日志（PID=$pid，Ctrl-C 退出）…"
  echo "⚠️ release 包看不到 DiagLog 的业务行；业务诊断看应用内「诊断日志」页。"
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
  [ "$#" -gt 0 ] || { echo "用法：tool/adb_tv.sh keys <键名>..." >&2; exit 1; }
  local name code
  for name in "$@"; do
    code="$(keycode_for "$name")" || exit 1
    adb -s "$SERIAL" shell input keyevent "$code"
    # 留一点时间让焦点动画/异步 setState 落定，否则连按会挤在一起看不出中间态。
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
  echo "✓ 已卸载（数据库 / 凭证一并清除）"
}

cmd_shell() {
  require_device
  [ "$#" -gt 0 ] || { echo "用法：tool/adb_tv.sh shell <命令>" >&2; exit 1; }
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
  install)   cmd_install ;;
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
