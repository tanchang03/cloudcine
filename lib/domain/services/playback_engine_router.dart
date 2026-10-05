import 'dart:async';

import '../../core/diagnostics/diag_log.dart';
import '../../core/utils/dolby_vision.dart';
import '../adapters/stream_relay.dart';
import 'playback_engine.dart';

/// 探测一条流的杜比视界信息。
///
/// 注入而不是在这里 new：实现要发网络请求
/// （`data/stream/dolby_vision_probe.dart`），而「怎么取字节」是实现细节；
/// 测试也靠它换成假实现。
///
/// [key] 是**缓存键**，由调用方给（`fileId|档位`）。同一个键只会真的探一次 ——
/// 探测要发一次 Range 请求，而续播、切档再切回来都会重开同一条流。
typedef DolbyVisionProbeFn = Future<DolbyVisionInfo?> Function({
  required String key,
  required Uri url,
  required Map<String, String> headers,
});

/// 一次内核选择的结论。
///
/// ## 为什么要把「换没换」显式带出来
///
/// 契约里的事件流是**广播且不重放**的（见 `PlaybackEngine` 的类文档），
/// 所以调用方必须在 `open()` 之前重新订阅。而「要不要重订」只有本类知道 ——
/// 让调用方拿 `identical(before, after)` 自己去比，等于把这条规则复制到每个
/// 调用点，迟早会有一处忘了比。
class EngineSelection {
  const EngineSelection({required this.engine, required this.changed});

  /// 这一次该用哪个内核。
  final PlaybackEngine engine;

  /// 与上一次相比**换了内核**。`true` 时调用方必须重新接订阅。
  final bool changed;

  @override
  String toString() => 'EngineSelection(${engine.runtimeType}, changed=$changed)';
}

/// 决定一条流用哪个内核 —— **两个播放器共用这一份**。
///
/// ## 为什么必须共用
///
/// 「什么时候换内核」有三条规则：只认 `profile == 5 && compat == 0`、
/// HLS 一律不探、探测结果按 `fileId|档位` 缓存。这三条一旦在两个播放器里
/// 各写一遍，就会出现「内置页切对了、独立窗口没切」这类**只在一条路径上
/// 复现**的故障 —— 而两个播放器跑在不同的 Flutter 引擎里，用户根本不会想到
/// 那是两套代码。
///
/// ## 它只管「选哪个」，不管「怎么用」
///
/// 订阅绑定、状态搬运、UI 重建都留在调用方（`PlaybackController` /
/// `player_window_app.dart`）—— 那两边的状态字段完全不同，硬凑一个基类
/// 只会得到一堆互相迁就的空钩子。本类只做两件事：
///   1. 按 [selectFor] 给出该用的内核，并在**换了**的时候把旧内核停掉；
///   2. 在 [dispose] 时把两个内核都释放。
///
/// ## 内核归属
///
/// 默认内核由调用方建、由 [dispose] 释放；DV 内核由本类**惰性**建
/// （DV 片源是少数，绝大多数用户一次都用不到，而 `FvpPlaybackEngine`
/// 一建出来就占住一份解码器配置），同样由 [dispose] 释放。
///
/// ## 第二条触发线（2026-10-05 恢复）
///
/// 「≥4K 或 DV」→ fvp；其余 → media_kit。
///
/// 10-04 的第二条线（≥1440p）失败过两轮，判据已收窄：2026-10-05 起按
/// `docs/解决4k片源不卡顿解析方案.md` 只保留「TV 上 ≥4K 或 DV」。
/// 传入 [highResTvRoute] = `Platform.isAndroid && isTvDevice()` 才开启
/// 这条线；macOS / 桌面仍只走 DV 判据。⛔ 不要 TV 全量替换（会丢掉
/// mpv 的格式覆盖 / ASS 渲染 / 音效 / 缓冲调优）。
class PlaybackEngineRouter {
  PlaybackEngineRouter({
    required PlaybackEngine defaultEngine,
    PlaybackEngine Function()? dolbyVisionEngine,
    DolbyVisionProbeFn? dolbyVisionProbe,
    this.highResTvRoute = false,
    this.logTag = '播放',
  })  : _defaultEngine = defaultEngine,
        _dvEngineFactory = dolbyVisionEngine,
        _dvProbe = dolbyVisionProbe,
        _engine = defaultEngine;

  /// 日志分类。两个播放器的分类不同（`播放` / `播放窗口`），
  /// 但**文案只有一份** —— 否则同一个故障在两份日志里长得不一样。
  final String logTag;

  /// 默认内核（media_kit）。**永远存在**，且由调用方建、由 [dispose] 释放。
  final PlaybackEngine _defaultEngine;

  /// 杜比视界内核的工厂。`null` = 这个平台不做 DV 路由（Android / TV）。
  final PlaybackEngine Function()? _dvEngineFactory;

  /// 杜比视界探测。`null` = 不探测（测试 / 不支持的路由）。
  final DolbyVisionProbeFn? _dvProbe;

  /// 惰性建出来的 DV 内核。建过一次就复用（换集不必重建）。
  PlaybackEngine? _dvEngine;

  /// 当前生效的内核。
  PlaybackEngine _engine;

  /// 当前内核。
  PlaybackEngine get engine => _engine;

  /// 当前内核的能力声明。UI 据此置灰（而不是静默失效）那些做不到的功能。
  EngineCapabilities get capabilities => _engine.capabilities;

  /// 默认内核。调用方在「想确认某个东西是不是它」时用得上（比如音效是
  /// mpv 专有能力，得先判断当前内核是不是 `MediaKitPlaybackEngine`）。
  PlaybackEngine get defaultEngine => _defaultEngine;

  /// 这个平台会不会做 DV 路由。
  bool get dolbyVisionEnabled => _dvEngineFactory != null && _dvProbe != null;

  /// 是否启用「TV ≥4K」那条触发线（仅 Android TV 调用方打开）。
  final bool highResTvRoute;

  /// 决定这条流**用哪个内核**，必要时切换。
  ///
   /// ## 判据：杜比视界 P5，或 TV 上 ≥4K
   ///
   /// 探测一次流的头部字节（`DolbyVisionProbe`），认出
   /// `profile == 5 && blSignalCompatibilityId == 0` 才切到 fvp；
   /// 在 [highResTvRoute] 打开时，`videoHeight >= 2160` 同样切 fvp。
   ///
   /// 这个判据很窄是有意的：P5 **没有**向后兼容的基础层，在只认 YCbCr 的
   /// 解码链上会渲染成**偏绿**（而不是变成黑白或黑屏）—— 也就是说它必须换
   /// 内核，否则用户看到的就是错的颜色。P8 有兼容层，走 media_kit 正常。
  ///
  /// ## 为什么要跳过 HLS
  ///
  /// 转码档签出来的是 `media.m3u8`，它永远是 SDR 转码产物，**不可能**是 DV。
  /// 探它只是白花一次往返 —— 而且探 m3u8 的头部字节本来就探不出容器信息。
  ///
  /// ## 为什么只探 http(s)
  ///
  /// 独立播放窗口还有两条**不是网络**的路：内置自检视频（`asset:///…`）和
  /// 用户手输的本地文件。给它们发 Range 请求只会得到一次
  /// `unsupported scheme` 异常 —— 结论（非 DV）虽然是对的，但日志里会多出
  /// 一条看着像故障的警告。所以非 http(s) 一律**静默跳过**。
  ///
  /// ## 探测是**同步等待**的，但它被缓存
  ///
  /// 必须等：内核必须在 `open()` 之前定下来。代价是一次小 Range 请求
  /// （最多 256 KiB），而 [key] 是 `fileId|档位`，所以同一集只有第一次付这个
  /// 代价（续播、切档再切回来都命中缓存）。
  ///
  /// ## 换了内核时会顺手停掉旧的那个
  ///
  /// 不停的话它会一直占着上一条流的资源（4K 上是几百 MB 内存 + 一条长连接），
  /// 而用户已经换到别的片源了。停止是**不等待**的：`stop()` 要跟原生打交道，
  /// 而调用方正等着 `open()` —— 卡在这里就是把换流的延迟翻倍。
  Future<EngineSelection> selectFor({
    required String key,
    required Uri url,
    required Map<String, String> headers,
    int? videoHeight,
  }) async {
    final factory = _dvEngineFactory;
    final probe = _dvProbe;

    var reason = '';
    final probeable = url.scheme == 'http' || url.scheme == 'https';
    if (factory != null && probe != null && probeable && !isHlsUrl(url)) {
      final info = await probe(key: key, url: url, headers: headers);
      if (info?.needsDolbyVisionEngine ?? false) {
        reason = '这条片源是杜比视界 P5';
      }
    }
    if (reason.isEmpty &&
        highResTvRoute &&
        videoHeight != null &&
        // ⚠️ 阈值 2048 而不是 2160：夸克 origin 原画的**视频高度**是
        // 3840×2152（宽银幕裁切），不是标准 3840×2160。写成 ≥2160 会把
        // 2152p 漏判成「非 4K」→ 走 mpv 渲染 4K（实测 CPU 234%、内存 1.2G，
        // 系统可用内存只剩 51MB）—— 正是 4K 方案要避免的。2048 以上
        // 都交给专用引擎（钳 1080p 渲染 + 硬解），CPU 降到 ~30%。
        // 1080p(1920×1080) / 1440p(2560×1440) 都在阈值之下，不受影响。
        videoHeight >= 2048) {
      reason = 'Android TV 上 4K（≥2048p）片源';
    }

    final target = reason.isEmpty || factory == null
        ? _defaultEngine
        : (_dvEngine ??= factory());
    if (identical(target, _engine)) {
      return EngineSelection(engine: _engine, changed: false);
    }

    final previous = _engine;
    _engine = target;
    diag.info(
      logTag,
      reason.isEmpty ? '切回 media_kit（mpv）内核' : '$reason，切到 fvp（libmdk）内核',
    );

    unawaited(
      previous.stop().catchError((Object e) {
        diag.debug(logTag, '停旧内核失败（不影响本次播放）：$e');
      }),
    );

    return EngineSelection(engine: target, changed: true);
  }

  /// 强制切回默认内核（media_kit / mpv）。
  ///
  /// 与 [selectFor] 的区别：它**不看任何判据**。用途是「ExoPlayer 打开失败
  /// 后回退」——那时 4K 判据依然成立，用 [selectFor] 会立刻把引擎又切回去
  /// 再失败一次。
  ///
  /// 幂等：已经在默认内核上时返回 `changed: false`，重复调用无副作用。
  Future<EngineSelection> switchToDefault() async {
    if (identical(_engine, _defaultEngine)) {
      return EngineSelection(engine: _engine, changed: false);
    }
    final previous = _engine;
    _engine = _defaultEngine;
    diag.info(logTag, '回退 media_kit（mpv）内核');
    unawaited(
      previous.stop().catchError((Object e) {
        diag.debug(logTag, '停旧内核失败（不影响本次播放）：$e');
      }),
    );
    return EngineSelection(engine: _engine, changed: true);
  }

  /// 释放两个内核。**两个都要释放** —— 它们各自占着原生解码器。
  Future<void> dispose() async {
    final engines = <PlaybackEngine>{
      _defaultEngine,
      if (_dvEngine != null) _dvEngine!,
    };
    for (final engine in engines) {
      try {
        await engine.dispose();
      } catch (e) {
        diag.debug(logTag, '释放内核失败（无所谓）：$e');
      }
    }
  }
}
