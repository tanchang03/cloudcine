import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/diagnostics/diag_log.dart';
import 'data/db/app_database.dart';
import 'ui/app.dart';
import 'ui/providers/app_providers.dart';
import 'ui/windows/player_window_app.dart';
import 'ui/windows/player_window_bridge.dart';
import 'ui/windows/window_launch.dart';

Future<void> main(List<String> args) async {
  // 启动计时的**零点**。放在最前面（连 `ensureInitialized` 都算进去）——
  // 用户感受到的「启动慢」就是从进程起来到看见东西为止，中间的每一段都该计入。
  final t0 = DateTime.now();

  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️ 必须在任何 `Player()` 构造之前调用。漏掉的表现是
  // 「应用能启动、一进播放页就崩」。
  //
  // 注意它必须在**分流之前**：播放窗口是独立引擎，同样要自己初始化一次
  // media_kit，不能指望主窗口那边初始化过。
  MediaKit.ensureInitialized();

  // 第二内核：fvp（libmdk）。**只服务杜比视界片源**，其余片源仍走 media_kit。
  //
  // ⛔ 必须**显式**注册，不能指望自动注册：fvp 的 pubspec 里 macOS 平台
  // 只有 `pluginClass`、**没有 `dartPluginClass`**（只有 linux/windows/ohos/
  // elinux 有 `VideoPlayerRegistrant`）。漏掉这一句，`video_player` 会用官方的
  // `video_player_avfoundation`（Apple 那套栈）——**DV 依然渲染不对，而且不报
  // 任何错**，排查时看起来像「换了内核也没用」。
  //
  // ⛔ **只注册 macOS**。2026-10-04 在 Android TV 上试过把它开到
  // `['macos','android']` 走 4K 直出，**两轮都失败，已回退**，别再试同一套：
  //
  //   1. 只设 `viewType: platformView`（SurfaceView）：用户报「更卡、音画不同步」。
  //   2. 再加 `tunnel: true`（零拷贝）：用户报「4K 看不到画面，只有声音」。
  //
  // 日志证据（`cloudcine-log-android-20261004-213519.txt` + `logcat -b crash`）：
  //   - 中继在推进（2MB→24MB→62MB），`[资源]` 显示进程 CPU 225~326%（单核口径），
  //     说明**解码在跑**，但屏上什么都没有 → 出画面那一层没present。
  //   - 同一次播放里进程**原生崩溃**：`libmdk.so` 的 `strlen→vfprintf→vsnprintf`
  //     （mdk 自己的工作线程），以及反复出现的 `SurfaceTextureWrapper.release`
  //     （FinalizerDaemon）。后者是 Flutter 引擎在 `SurfaceProducer` 被释放后
  //     二次释放 —— 换内核就会触发，与 viewType 无关。
  //
  // 回退后 4K 回到 mpv：画面正常，但 `hwdec-current=mediacodec-copy` 的卡顿
  // 仍在（那是 mpv 在 Android 上的结构性问题，见
  // `docs/AndroidTV-4K-丢帧-夸克对标.md`）。
  //
  // 位置与上面的 `MediaKit.ensureInitialized()` 同理，必须在**分流之前**：
  // 播放窗口跑的是**独立引擎**，而 Dart 侧的平台实现注册是**每个引擎各一份**的，
  // 主窗口注册过不代表播放窗口注册过。
  //
  // `platforms` 显式写出来是**双保险**：即便以后在别的平台也 import 了这里，
  // 也只有 macOS 会被 fvp 接管。
  if (Platform.isMacOS) {
    fvp.registerWith(options: <String, Object>{
      'platforms': <String>['macos'],
    });
    // 把实际下发的选项写进日志。
    //
    // **为什么值得占一行**：注册只让 `video_player` 改用 mdk 实现，是「配错了
    // 也不报错、只是静默走 Apple 那套栈」的那类开关，没有回读手段。它同时是
    // 独立播放窗口的判据：那个窗口有自己的引擎，这行会出现两次。
    diag.info('播放', 'fvp 注册：platforms=[macos]');
  }

  // 分流要尽可能早：播放窗口跑的是播放界面，不该做媒体库的启动工作
  // （开数据库、建海报缓存、起 Riverpod 容器）。
  //
  // 入口参数由 `desktop_multi_window` 注入，形状固定为
  // `['multi_window', <windowId>, <arguments>]`；普通启动时 `args` 为空，
  // 解析器会退回主窗口。
  final launch = parseWindowLaunch(args);
  if (launch.isPlayer) {
    await _startPlayerWindow(launch, t0);
    return;
  }

  // 每一段都单独计时：启动慢的时候，第一件要知道的事是**慢在哪一段**。
  // 直接打一个总数没有用 —— 网络、开库、插件注册的量级差着两个数量级。
  var sw = Stopwatch()..start();
  final support = await getApplicationSupportDirectory();
  final supportMs = sw.elapsedMilliseconds;

  // 日志要在 runApp 之前起 —— 否则启动阶段的日志会丢，
  // 而启动阶段恰恰是最需要日志的时候。
  sw = Stopwatch()..start();
  await diag.start(supportDirPath: support.path);
  final diagMs = sw.elapsedMilliseconds;

  // 跨引擎通道必须在**任何播放窗口可能发出 ping 之前**注册好，
  // 否则播放窗口的自检会拿到 `CHANNEL_UNREGISTERED`。
  // 放在 diag 之后，是为了让「注册成功/失败」这条记录能落进日志文件。
  sw = Stopwatch()..start();
  await registerPlayerWindowBridge();
  final bridgeMs = sw.elapsedMilliseconds;

  // ⚠️ 这一步**只申请、不真开**（drift 是懒打开，见 `openAppDatabase` 的文档），
  // 所以这里的数字几乎一定是 0 —— 真正的开库 + 迁移记在 `beforeOpen` 那条里。
  sw = Stopwatch()..start();
  final db = await openAppDatabase();
  final dbMs = sw.elapsedMilliseconds;

  // 海报缓存目录。和数据库一样在启动时准备好：塞进同步 Provider 里
  // 就得在每次读海报时重新 await 一次平台通道。
  sw = Stopwatch()..start();
  final posterDir = Directory('${support.path}${Platform.pathSeparator}posters');
  if (!posterDir.existsSync()) {
    posterDir.createSync(recursive: true);
  }
  final posterMs = sw.elapsedMilliseconds;

  diag.info('启动', '数据目录 ${support.path}');
  diag.info(
    '启动',
    '主窗口就绪：总 ${DateTime.now().difference(t0).inMilliseconds}ms ｜ '
        '支持目录 ${supportMs}ms、日志 ${diagMs}ms、跨窗口通道 ${bridgeMs}ms、'
        '申请开库 ${dbMs}ms、海报目录 ${posterMs}ms',
  );

  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        posterCacheDirProvider.overrideWithValue(posterDir.path),
        appSupportDirProvider.overrideWithValue(support.path),
      ],
      child: const CloudCineApp(),
    ),
  );

  // 「首帧已绘制」才是用户眼里的「启动完成」。它比 `runApp` 返回晚得多
  // （要等布局 + 光栅化），所以必须单独记一条 —— 否则「就绪 300ms」会让人
  // 以为启动只要 300ms，而实际白屏可能有两秒。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    diag.info(
      '启动',
      '首帧已绘制：从进程启动 ${DateTime.now().difference(t0).inMilliseconds}ms'
      '（此后才是媒体库列表自己的查询时间）',
    );
  });
}

/// 播放器窗口引擎的启动路径。
///
/// 独立引擎里**没有**主窗口的 Riverpod 容器、没有 `databaseProvider`、
/// 也没有 `posterCacheDirProvider`，所以这里刻意不建数据库 —— 播放窗口需要
/// 什么，通过跨窗口通道向主窗口要（阶段一只要一句 `ping`）。
///
/// 唯一共享的是**日志文件**：播放失败的原因必须能在主窗口的诊断页里看到，
/// 否则「独立窗口不出画」就只剩肉眼观察，排查只能靠猜。两个引擎写同一个文件
/// 是安全的 —— [DiagLog] 每行都是一次 `FileMode.append` + flush，单行写入
/// 不会互相覆盖；两边的时间戳交织在一起，反而能看出
/// 「主窗口开窗 → 播放窗口失败」的因果顺序。
Future<void> _startPlayerWindow(WindowLaunch launch, DateTime t0) async {
  try {
    final sw = Stopwatch()..start();
    final support = await getApplicationSupportDirectory();
    final supportMs = sw.elapsedMilliseconds;
    sw.reset();
    await diag.start(supportDirPath: support.path);
    final diagMs = sw.elapsedMilliseconds;
    // 两个引擎都会写一行「会话开始」，这行用来区分是谁写的。
    diag.section('播放器窗口会话开始（windowId=${launch.windowId}）');
    // 播放窗口的启动耗时要和主窗口的分开看：它不做媒体库那套（不开库、
    // 不建海报缓存），所以这里的数字应该**明显更小**；一样大就说明
    // 分流没生效，播放窗口白背了主窗口的启动成本。
    diag.info(
      '启动',
      '播放器窗口就绪：总 ${DateTime.now().difference(t0).inMilliseconds}ms ｜ '
          '支持目录 ${supportMs}ms、日志 ${diagMs}ms',
    );
  } catch (e) {
    // 日志起不来不该挡住播放 —— 它只是让这次排查少一份材料。
    diag.warn('窗口', '播放器窗口无法启动日志：$e');
  }

  runApp(PlayerWindowApp(launch: launch));
}
