/// 播放页的诊断开关（**编译期**，用 `--dart-define` 传）。
///
/// ## 为什么要做成编译期而不是设置项
///
/// 这两个开关是用来**做对照实验**的，不是给用户用的功能。做成设置项就得
/// 走一遍 UI（还要在 TV 上拿遥控器点），而且实验结束忘了关掉会悄悄改变
/// 线上行为。`--dart-define` 让「开了什么」在构建命令里留痕，也不会漏进正式包。
///
/// 用法：
/// ```
/// flutter build apk --debug --dart-define=CC_DIAG_BYPASS_RELAY=true
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 跳过本地中继，**直连**网盘原链接。
///
/// ## 它回答什么问题
///
/// 中继在 Dart 层转发数据（`LocalStreamRelay` 里**没有任何 `Isolate` /
/// `compute`** —— 上游 TLS 握手、TLS 记录解密、HTTP 解析、分块拷贝全都跑在
/// Dart isolate 上，而 Flutter 的 Dart isolate 就是 Android 主线程）。
/// 所以「播放页卡不卡」里有多少是**中继自己吃掉的主线程时间**，只有把它
/// 关掉才量得出来。
///
/// ⚠️ 关掉之后带宽会掉（单连接顺序读，见 `isRelayableUrl` 的文档），
/// 所以这个开关**只用来对比 CPU / 跟手，不能用来对比流畅度**。
const bool kDiagBypassRelay = bool.fromEnvironment('CC_DIAG_BYPASS_RELAY');

/// 「按键 → 下一帧」的直读埋点。
///
/// ## 为什么 HUD 上的 `FPS` 回答不了这个问题
///
/// `DebugOverlay` 数的是「引擎实际出了多少帧」。云影的视频走独立图层
/// 自渲染，Flutter 只在控制器每拍通知时重建一次 —— 于是 HUD 在 OSD 关着时
/// 报 1~3、OSD 开着时报 ~10，**那个数等于「每秒整页 rebuild 了几次」，
/// 不衡量跟手**。
///
/// 夸克原型那边（`prototype/kuake`）的原生 OSD 能直接量
/// 「按下 → 画面开始更新」（实测 0.3~8.3 ms，n=68）。要给云影拿到**同一个
/// 口径**的数，只能在按键入口埋点、量到下一帧提交为止。
///
/// ## 它量的是什么（以及不是什么）
///
/// 从 [mark] 被调用，到**下一个** Flutter 帧的 post-frame 回调结束：
/// 事件分发 → setState → build → layout → paint 提交。
/// **不含**光栅与上屏，也不含遥控器本身的链路延迟 —— 两边都不含，
/// 所以横向可比。
class KeyFrameLatency {
  KeyFrameLatency._();

  /// 只在 debug 构建里出声。正式包不带这个开销，也不往 logcat 里刷噪声。
  static bool get enabled => kDebugMode;

  static int _t0Us = 0;
  static int _samples = 0;
  static double _maxMs = 0;

  /// 记一次「用户按下了」。
  ///
  /// 必须在**改变 UI 的那一行之前**调用 —— 放在之后就把这一拍自己的工作
  /// 算进延迟里了，读数会随改动位置漂移。
  static void mark([String tag = '']) {
    if (!enabled) return;
    _t0Us = DateTime.now().microsecondsSinceEpoch;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_t0Us == 0) return;
      final ms = (DateTime.now().microsecondsSinceEpoch - _t0Us) / 1000.0;
      _t0Us = 0;
      _samples++;
      if (ms > _maxMs) _maxMs = ms;
      // ⛔ 用 `debugPrintSynchronously` 而不是 `debugPrint`：后者默认是
      //    `debugPrintThrottled`（1 KB/s 预算），遥控器连按时会把输出**攒起来**
      //    分批吐 —— 测量要的是确定性，不是「不刷屏」。
      //    ⚠️ 计时已经在上面算完了，所以这次同步写盘的开销**不计入**读数。
      debugPrintSynchronously(
        '[跟手] ${tag.isEmpty ? '按键' : tag} → 下一帧 '
        '${ms.toStringAsFixed(1)} ms（最大 ${_maxMs.toStringAsFixed(1)}，n=$_samples）',
      );
    });
    // 有些按键（比如只改焦点）不会自己弄脏布局，不主动排帧就永远等不到
    // post-frame 回调，读数会静默丢失。
    SchedulerBinding.instance.scheduleFrame();
  }

  /// 当前累计样本数，供自检。
  static int get samples => _samples;
}

/// 把一段同步工作包起来计时并打点，用于量「一次整页 rebuild 有多贵」。
///
/// 只在 debug 出声；[threshold] 以上的才打，免得把 logcat 刷满。
void diagMeasure(String label, void Function() body, {double threshold = 8}) {
  if (!kDebugMode) {
    body();
    return;
  }
  final t0 = DateTime.now().microsecondsSinceEpoch;
  body();
  final ms = (DateTime.now().microsecondsSinceEpoch - t0) / 1000.0;
  if (ms >= threshold) {
    debugPrintSynchronously('[耗时] $label ${ms.toStringAsFixed(1)} ms');
  }
}
