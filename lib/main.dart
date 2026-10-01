import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️ 必须在任何 `Player()` 构造之前调用。漏掉的表现是
  // 「应用能启动、一进播放页就崩」。
  //
  // 注意它必须在**分流之前**：播放窗口是独立引擎，同样要自己初始化一次
  // media_kit，不能指望主窗口那边初始化过。
  MediaKit.ensureInitialized();

  // 分流要尽可能早：播放窗口跑的是播放界面，不该做媒体库的启动工作
  // （开数据库、建海报缓存、起 Riverpod 容器）。
  //
  // 入口参数由 `desktop_multi_window` 注入，形状固定为
  // `['multi_window', <windowId>, <arguments>]`；普通启动时 `args` 为空，
  // 解析器会退回主窗口。
  final launch = parseWindowLaunch(args);
  if (launch.isPlayer) {
    await _startPlayerWindow(launch);
    return;
  }

  final support = await getApplicationSupportDirectory();

  // 日志要在 runApp 之前起 —— 否则启动阶段的日志会丢，
  // 而启动阶段恰恰是最需要日志的时候。
  await diag.start(supportDirPath: support.path);

  // 跨引擎通道必须在**任何播放窗口可能发出 ping 之前**注册好，
  // 否则播放窗口的自检会拿到 `CHANNEL_UNREGISTERED`。
  // 放在 diag 之后，是为了让「注册成功/失败」这条记录能落进日志文件。
  await registerPlayerWindowBridge();

  final db = await openAppDatabase();

  // 海报缓存目录。和数据库一样在启动时准备好：塞进同步 Provider 里
  // 就得在每次读海报时重新 await 一次平台通道。
  final posterDir = Directory('${support.path}${Platform.pathSeparator}posters');
  if (!posterDir.existsSync()) {
    posterDir.createSync(recursive: true);
  }

  diag.info('启动', '数据目录 ${support.path}');

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
Future<void> _startPlayerWindow(WindowLaunch launch) async {
  try {
    final support = await getApplicationSupportDirectory();
    await diag.start(supportDirPath: support.path);
    // 两个引擎都会写一行「会话开始」，这行用来区分是谁写的。
    diag.section('播放器窗口会话开始（windowId=${launch.windowId}）');
  } catch (e) {
    // 日志起不来不该挡住播放 —— 它只是让这次排查少一份材料。
    diag.warn('窗口', '播放器窗口无法启动日志：$e');
  }

  runApp(PlayerWindowApp(launch: launch));
}
