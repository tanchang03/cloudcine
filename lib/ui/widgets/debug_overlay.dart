import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' as mk;

import '../../core/diagnostics/resource_probe.dart';
import '../../data/playback/fvp_playback_engine.dart';
import '../../data/playback/media_kit_playback_engine.dart';
import '../../data/playback/video_player_exo_playback_engine.dart';
import '../../domain/services/playback_controller.dart';
import '../providers/app_providers.dart';

/// 调试浮层开关。
///
/// 调试期默认开（debug APK 里是真机联调，指标要随时可见）；release 构建里
/// 默认关 —— 用户不该看到一排数字叠在画面上。真机要看时把这里改回 `true`
/// 重新构建即可。
const bool kDebugOverlayEnabled = true;

/// 实时资源指标浮层：CPU / 内存 / FPS / 线程 / 负载 / **解码内核与硬解状态**。
///
/// 挂在 `MaterialApp.builder` 上（Navigator 之上），浮在画面右上角。
/// 用途是**真机调优时实时看资源** —— 之前「OSD 卡顿是不是 CPU 满」这种
/// 问题，要么靠事后拉日志、要么靠 `adb top`，都看不到「按那一下键的瞬间
/// 发生了什么」。这个浮层每秒刷新一次，CPU 是两次 `/proc/stat` 的增量口径
/// （与 `adb top` 一致，234% = 用了 2.34 个核）。
///
/// 解码信息：读 `PlaybackController` 的当前引擎 —— mpv（media_kit）显示
/// `hwdec-current`（mediacodec-copy = 硬解拷贝档，直通 = 硬解零拷贝）；
/// ExoPlayer / fvp 恒为 MediaCodec 硬解。这一行回答「到底是不是硬解、走的
/// 哪个内核」—— 之前要靠事后翻日志才能确认。
///
/// ⚠️ 数据源 [readDeviceResources] 依赖 `/proc`（Android / Linux）。在 macOS
/// 上跑开发时大半字段为空，浮层会显示「—」—— 这是预期，不是 bug。
class DebugOverlay extends ConsumerStatefulWidget {
  const DebugOverlay({super.key, this.refreshInterval = const Duration(seconds: 1)});

  /// 刷新周期。1 秒足够「实时」，再短会把 CPU 读数搅成噪声。
  final Duration refreshInterval;

  @override
  ConsumerState<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends ConsumerState<DebugOverlay> {
  Timer? _timer;

  /// 回调已随 dispose 失效。Flutter 3.29 的 `addPersistentFrameCallback` 没有
  /// 对应的 remove 方法（`_persistentCallbacks` 是私有的），所以用标志位让
  /// 空转 —— overlay 常驻 app 根，不会重复注册。
  bool _disposed = false;

  /// 本次周期内渲染的帧数，靠 [SchedulerBinding] 的持久帧回调累加。
  int _frames = 0;
  double _fps = 0;

  ResourceReading? _reading;

  /// 上一次的进程 CPU 累计 jiffies 与采样时刻 —— CPU% 要两条读数才成立。
  int? _prevTicks;
  DateTime? _prevAt;
  double _cpuPct = 0;

  /// 上一次的网络累计收 / 发字节 —— 速率也要两条读数做差。
  int? _prevRx;
  int? _prevTx;
  double _netRxKbs = 0;
  double _netTxKbs = 0;

  /// 当前解码内核标签（mpv / ExoPlayer / fvp）。
  String _kernel = '—';
  /// 解码机制标签（硬解直通 / 硬解拷贝 / 软解 / 解码器未起）。
  String _decode = '—';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    _timer = Timer.periodic(widget.refreshInterval, (_) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  void _onFrame(Duration _) {
    if (_disposed) return;
    _frames++;
  }

  Future<void> _refresh() async {
    final now = DateTime.now();
    final reading = await readDeviceResources();
    if (!mounted) return;

    final ticks = reading.procCpuTicks;
    if (ticks != null && _prevTicks != null && _prevAt != null) {
      final dtUs = now.difference(_prevAt!).inMicroseconds;
      if (dtUs > 0) {
        // 进程占用核数 × 100%（口径与 `adb top` 一致，234% = 2.34 核）：
        // jiffies 增量 / 墙钟秒 / 每核每秒节拍数，再 × 100。
        _cpuPct =
            (ticks - _prevTicks!) * 1e6 / dtUs / kProcClockTicksPerSecond * 100;
      }
    }
    _prevTicks = ticks;

    // 网络速率：两次采样做差 / 墙钟时间。
    // ⚠️ 必须用 `now.difference(_prevAt!)` —— `_prevAt` 是上一次采样的时刻，
    // 不能先把它更新成 `now` 再拿来算（那样除数是 0 → Infinity）。
    final rx = reading.netRxBytes;
    final tx = reading.netTxBytes;
    if (rx != null && _prevRx != null && _prevAt != null) {
      _netRxKbs =
          (rx - _prevRx!) * 1e6 / now.difference(_prevAt!).inMicroseconds / 1024;
    }
    if (tx != null && _prevTx != null && _prevAt != null) {
      _netTxKbs =
          (tx - _prevTx!) * 1e6 / now.difference(_prevAt!).inMicroseconds / 1024;
    }
    _prevRx = rx;
    _prevTx = tx;
    _prevAt = now;

    // 解码内核 + 硬解状态。读 `PlaybackController` 的当前引擎，1Hz 一次
    // channel 读取，开销可忽略。
    final (kernel, decode) = await _readDecoderInfo();

    if (!mounted) return;
    setState(() {
      _kernel = kernel;
      _decode = decode;
      _reading = reading;
      // 帧率 = 本周期帧数 / 周期时长。首帧回调在 initState 之前可能已跑，
      // 所以这里不算「启动第一秒」的失真 —— 它本来就该是瞬时的。
      _fps = _frames * 1000 / widget.refreshInterval.inMilliseconds;
      _frames = 0;
    });
  }

  /// 读当前解码内核与硬解状态。
  ///
  /// 内核按引擎类型区分；硬解状态：
  ///   * ExoPlayer / fvp —— MediaCodec 硬解（PlatformView 直通 Surface）；
  ///   * mpv —— 读 `hwdec-current` 属性：`mediacodec-copy` = 硬解但拷贝档
  ///     （每帧拷回 CPU），`mediacodec` = 硬解零拷贝，空串 = 解码器未起。
  Future<(String, String)> _readDecoderInfo() async {
    final PlaybackController controller;
    try {
      controller = ref.read(playbackControllerProvider);
    } catch (_) {
      return ('—', '—');
    }
    final engine = controller.engine;
    if (engine is VideoPlayerExoPlaybackEngine) {
      return ('ExoPlayer', '硬解(直通)');
    }
    if (engine is FvpPlaybackEngine) {
      return ('fvp/mdk', '硬解(直通)');
    }
    if (engine is MediaKitPlaybackEngine) {
      try {
        final platform = engine.player.platform;
        if (platform is! mk.NativePlayer) return ('mpv', '—');
        final hwdec = (await platform.getProperty('hwdec-current')).trim();
        if (hwdec.isEmpty) return ('mpv', '解码器未起');
        if (hwdec.contains('mediacodec-copy')) return ('mpv', '硬解(copy)');
        if (hwdec.contains('mediacodec')) return ('mpv', '硬解(直通)');
        return ('mpv', '软解($hwdec)');
      } catch (_) {
        return ('mpv', '—');
      }
    }
    return (engine.runtimeType.toString(), '—');
  }

  @override
  Widget build(BuildContext context) {
    final r = _reading;
    final cpu = _cpuPct;
    final color = cpu > 300
        ? const Color(0xFFFF6B6B)
        : cpu > 200
            ? const Color(0xFFFFB020)
            : const Color(0xFF6BCB77);

    final rssMb = r?.rssBytes != null ? r!.rssBytes! / (1 << 20) : null;
    final memAvail = r?.memAvailableBytes;
    final memTotal = r?.memTotalBytes;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xCC0B0D12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'CPU ${cpu.toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          // 解码内核 + 硬解状态：回答「是不是硬解、走的哪个内核」。
          Text(
            '内核  $_kernel',
            style: const TextStyle(
              fontSize: 11.5,
              color: Color(0xB3FFFFFF),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '解码  $_decode',
            style: TextStyle(
              fontSize: 11.5,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: _decode.startsWith('硬解')
                  ? const Color(0xFF6BCB77)
                  : const Color(0xFFFFB020),
            ),
          ),
          _line('RSS', rssMb == null ? '—' : '${rssMb.toStringAsFixed(0)} MB'),
          _line(
            '内存',
            memAvail == null
                ? '—'
                : '可用 ${(memAvail / (1 << 20)).toStringAsFixed(0)}/'
                    '${(memTotal! / (1 << 20)).toStringAsFixed(0)} MB',
          ),
          _line('FPS', _fps.toStringAsFixed(0)),
          _line('网络↓', _fmtRate(_netRxKbs)),
          _line('网络↑', _fmtRate(_netTxKbs)),
          _line('线程', r?.threads?.toString() ?? '—'),
          _line('运行中进程', r?.procsRunning?.toString() ?? '—'),
          _line('负载', r?.load1?.toStringAsFixed(1) ?? '—'),
        ],
      ),
    );
  }

  /// 把 KiB/s 格式化成可读的速率。
  static String _fmtRate(double kibPerSec) {
    if (kibPerSec >= 1024) return '${(kibPerSec / 1024).toStringAsFixed(1)} MB/s';
    return '${kibPerSec.toStringAsFixed(0)} KB/s';
  }

  Widget _line(String label, String value) {
    return Text(
      '$label  $value',
      style: const TextStyle(
        fontSize: 11.5,
        color: Color(0xB3FFFFFF),
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}
