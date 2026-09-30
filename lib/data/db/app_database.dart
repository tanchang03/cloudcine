import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/diagnostics/diag_log.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// 本地索引库。
///
/// 全部数据都在本机：媒体项、作品元数据、字幕引用、续扫游标、设置。
/// **网盘侧只读** —— 本应用不上传、不移动、不删除、不分享用户的文件。
@DriftDatabase(
  tables: [MediaItems, MediaWorks, SubtitleRefs, ScanCursors, Settings],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 打开磁盘上的库文件。
  ///
  /// `createInBackground` 让建库/迁移跑在后台 isolate：媒体库首次扫描时
  /// 可能有几千次写入，放在主 isolate 会直接卡住 UI 线程。
  AppDatabase.openFile(File file)
      : super(NativeDatabase.createInBackground(file));

  /// 内存库（测试用）。
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          diag.info('数据库', '索引库已创建（schema v$schemaVersion）');
        },
        onUpgrade: (m, from, to) async {
          // v1 是首个版本，还没有需要迁移的历史。留一个显式的分支而不是
          // 空实现：将来加列时这里就是唯一的落点，而空的 onUpgrade
          // 会让「忘了写迁移」变成一个静默的数据损坏。
          diag.warn('数据库', '未预期的 schema 升级：$from → $to');
        },
        beforeOpen: (details) async {
          // 外键在 SQLite 里默认是关的，必须每个连接显式打开。
          await customStatement('PRAGMA foreign_keys = ON');
          diag.debug('数据库', '索引库已打开（v${details.versionNow}）');
        },
      );

  /// 清空全部索引数据（「重建媒体库」用）。
  ///
  /// ⚠️ 只清本地索引，**不动网盘**。
  Future<void> wipeIndex() async {
    await transaction(() async {
      await delete(subtitleRefs).go();
      await delete(mediaItems).go();
      await delete(mediaWorks).go();
      await delete(scanCursors).go();
    });
    diag.warn('数据库', '已清空本地索引（网盘侧未做任何改动）');
  }
}

/// 打开（必要时创建）应用数据库文件。
///
/// 路径放在 `getApplicationSupportDirectory()` 下：那是 macOS/Windows/Linux
/// 上「应用自己的数据」的标准位置，且**不会被系统清理**（临时目录会）。
Future<AppDatabase> openAppDatabase() async {
  final dir = await getApplicationSupportDirectory();
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File(p.join(dir.path, 'cloudcine.sqlite'));
  diag.info('数据库', '索引库路径：${file.path}');
  return AppDatabase.openFile(file);
}
