import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/diagnostics/diag_log.dart';
import 'data/db/app_database.dart';
import 'ui/app.dart';
import 'ui/providers/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️ 必须在任何 `Player()` 构造之前调用。漏掉的表现是
  // 「应用能启动、一进播放页就崩」。
  MediaKit.ensureInitialized();

  final support = await getApplicationSupportDirectory();

  // 日志要在 runApp 之前起 —— 否则启动阶段的日志会丢，
  // 而启动阶段恰恰是最需要日志的时候。
  await diag.start(supportDirPath: support.path);

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
      ],
      child: const CloudCineApp(),
    ),
  );
}
